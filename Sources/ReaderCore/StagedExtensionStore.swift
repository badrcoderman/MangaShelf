import Foundation
import CryptoKit

/// Explicitly reviewed publisher material and the source metadata for this version.
/// A repository fingerprint is a proposed identity; the caller must obtain the user's trust decision.
public struct ExtensionVerification: Codable, Equatable, Sendable {
    public let certificateSHA256: String
    public let versionName: String?
    public let sources: [SourceRecord]

    public init(certificateSHA256: String, versionName: String?, sources: [SourceRecord]) throws {
        var value = certificateSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("sha256:") { value = String(value.dropFirst(7)) }
        value = value.replacingOccurrences(of: ":", with: "")
        self.certificateSHA256 = value; self.versionName = versionName
        self.sources = sources.sorted { $0.id < $1.id }
        try validate()
    }
    public func validate() throws {
        guard certificateSHA256.utf8.count == 64,
              certificateSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              versionName.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              !sources.isEmpty, sources.count <= 4096, Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ source in
                  guard let id = Int64(source.id), String(id) == source.id else { return false }
                  return !source.language.isEmpty && source.language.utf8.count <= 32 && !source.language.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else { throw StagedExtensionError.invalidVerification }
    }
}

public struct StagedRuntimeCandidate: Sendable {
    public let url: URL
    public let manifest: ExtensionPackageManifest
    public let digest: String
    public let verification: ExtensionVerification
    struct Identity: Equatable, Sendable {
        let digest: String
        let manifest: ExtensionPackageManifest
        let verification: ExtensionVerification
    }
    var identity: Identity { Identity(digest: digest, manifest: manifest, verification: verification) }
}

public struct StagedExtension: Codable, Identifiable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let versionCode: UInt64
    public let digest: String
    public let stagedAt: Date
    public let inspection: JARInspection
    public var isTrusted: Bool
    public var isActive: Bool
    public var verification: ExtensionVerification?

    public init(packageName: String, versionCode: UInt64, digest: String,
                stagedAt: Date, inspection: JARInspection,
                isTrusted: Bool = false, isActive: Bool = false, verification: ExtensionVerification? = nil) {
        self.packageName = packageName
        self.versionCode = versionCode
        self.digest = digest
        self.stagedAt = stagedAt
        self.inspection = inspection
        self.isTrusted = isTrusted
        self.isActive = isActive
        self.verification = verification
    }

    public var displayName: String {
        let parts = packageName.split(separator: ".")
        if let last = parts.last {
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return packageName
    }

    enum CodingKeys: String, CodingKey {
        case packageName, versionCode, digest, stagedAt, inspection, isTrusted, isActive, verification
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageName = try container.decode(String.self, forKey: .packageName)
        versionCode = try container.decode(UInt64.self, forKey: .versionCode)
        digest = try container.decode(String.self, forKey: .digest)
        stagedAt = try container.decode(Date.self, forKey: .stagedAt)
        inspection = try container.decode(JARInspection.self, forKey: .inspection)
        isTrusted = try container.decodeIfPresent(Bool.self, forKey: .isTrusted) ?? false
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        verification = try container.decodeIfPresent(ExtensionVerification.self, forKey: .verification)
        try verification?.validate()
    }
}

/// Durable candidate packages. Staging never means installed, trusted, or activated in a JVM.
public actor StagedExtensionStore {
    private let root: URL
    private let index: URL
    private var records: [StagedExtension] = []

    public init(root: URL) throws {
        self.root = root; self.index = root.appendingPathComponent("staged.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: index.path) {
            let bytes = try LibraryStore.readBounded(index, maximum: 16 * 1024 * 1024)
            records = try JSONDecoder().decode([StagedExtension].self, from: bytes)
            guard records.count <= 10_000, Set(records.map(\.id)).count == records.count,
                  records.allSatisfy({ Self.validDigest($0.digest) && !$0.packageName.isEmpty }) else {
                throw StagedExtensionError.invalidIndex
            }
        } else { records = [] }
    }
    public func snapshot() -> [StagedExtension] { records }

    /// Expected digest must come from a separately trusted decision; no implicit trust is granted here.
    public func stage(packageName: String, versionCode: UInt64, data: Data, expectedDigest: String) throws -> StagedExtension {
        guard !packageName.isEmpty, packageName.utf8.count <= 512, Self.validDigest(expectedDigest) else {
            throw StagedExtensionError.invalidIdentity
        }
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw JARInspectionError.limit }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest else { throw StagedExtensionError.digestMismatch }
        if let existing = records.first(where: { $0.id == packageName }) {
            guard versionCode >= existing.versionCode else { throw StagedExtensionError.downgrade }
            guard versionCode != existing.versionCode || existing.digest == digest else {
                throw StagedExtensionError.versionConflict
            }
        }
        let inspection = try JARInspection.inspect(data)
        if let manifest = inspection.extensionManifest {
            guard manifest.packageName == packageName, manifest.versionCode == versionCode else {
                throw StagedExtensionError.invalidIdentity
            }
        }
        let record = StagedExtension(packageName: packageName, versionCode: versionCode,
                                     digest: digest, stagedAt: Date(), inspection: inspection,
                                     isTrusted: false, isActive: false)
        let candidate = records.filter { $0.id != packageName } + [record]
        guard candidate.count <= 10_000 else { throw StagedExtensionError.invalidIndex }
        // Blob first, atomic index last: failures never point the index at an incomplete JAR.
        try data.write(to: blob(digest), options: .atomic)
        try commit(candidate)
        return record
    }
    public func setTrust(packageName: String, trusted: Bool, verification: ExtensionVerification? = nil, expectedDigest: String? = nil) throws {
        guard let idx = records.firstIndex(where: { $0.id == packageName }) else {
            throw StagedExtensionError.notFound
        }
        var updated = records
        var item = updated[idx]
        if let expectedDigest, item.digest != expectedDigest { throw StagedExtensionError.digestMismatch }
        try verification?.validate()
        item.isTrusted = trusted
        item.verification = trusted ? verification : nil
        if !trusted { item.isActive = false }
        updated[idx] = item
        try commit(updated)
    }
    public func setActive(packageName: String, active: Bool) throws {
        guard let idx = records.firstIndex(where: { $0.id == packageName }) else {
            throw StagedExtensionError.notFound
        }
        var updated = records
        guard updated[idx].isTrusted || !active else {
            throw StagedExtensionError.untrustedActivation
        }
        var item = updated[idx]
        item.isActive = active
        updated[idx] = item
        try commit(updated)
    }
    public func remove(packageName: String) throws {
        let candidate = records.filter { $0.id != packageName }
        try commit(candidate)
        // Unreferenced blobs are retained until explicit cleanup; a future JVM may still hold them.
    }
    public func verifiedPackage(packageName: String) throws -> Data {
        guard let record = records.first(where: { $0.id == packageName }) else { throw StagedExtensionError.notFound }
        let data = try LibraryStore.readBounded(blob(record.digest), maximum: 64 * 1024 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == record.digest else { throw StagedExtensionError.digestMismatch }
        return data
    }
    /// Read the current record, trust intent, bytes and manifest in one actor
    /// operation. Persisted inspection data is never the authority for loading.
    func verifiedLoadCandidate(packageName: String) throws -> (url: URL, manifest: ExtensionPackageManifest) {
        guard let record = records.first(where: { $0.id == packageName }) else { throw StagedExtensionError.notFound }
        guard record.isTrusted else { throw StagedExtensionError.untrustedActivation }
        guard record.isActive else { throw StagedExtensionError.inactive }
        let bytes = try verifiedPackage(packageName: packageName)
        let inspection = try JARInspection.inspect(bytes)
        guard let manifest = inspection.extensionManifest,
              manifest.packageName == record.packageName,
              manifest.versionCode == record.versionCode else { throw StagedExtensionError.invalidIdentity }
        return (blob(record.digest), manifest)
    }

    public func packageForSource(_ sourceID: String) throws -> String {
        let found = records.filter { $0.isTrusted && $0.isActive && ($0.verification?.sources.contains { $0.id == sourceID } ?? false) }
        guard found.count <= 1 else { throw StagedExtensionError.conflictingSource }
        guard let record = found.first else { throw StagedExtensionError.notFound }
        return record.packageName
    }

    public func verifiedRuntimeCandidate(packageName: String) throws -> StagedRuntimeCandidate {
        let candidate = try verifiedLoadCandidate(packageName: packageName)
        guard let record = records.first(where: { $0.id == packageName }) else { throw StagedExtensionError.notFound }
        guard let verification = record.verification else { throw StagedExtensionError.verificationRequired }
        try verification.validate()
        guard verification.versionName == candidate.manifest.versionName else { throw StagedExtensionError.invalidIdentity }
        return StagedRuntimeCandidate(url: candidate.url, manifest: candidate.manifest, digest: record.digest, verification: verification)
    }
    /// Verifies package on disk and rolls back if file has been corrupted.
    public func verifiedPackageWithRollback(packageName: String) throws -> Data {
        do {
            return try verifiedPackage(packageName: packageName)
        } catch {
            try? remove(packageName: packageName)
            throw error
        }
    }
    public func blobURL(for digest: String) -> URL { blob(digest) }
    private func blob(_ digest: String) -> URL { root.appendingPathComponent(digest + ".jar") }
    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func commit(_ candidate: [StagedExtension]) throws {
        let bytes = try JSONEncoder().encode(candidate)
        guard bytes.count <= 16 * 1024 * 1024 else { throw StagedExtensionError.invalidIndex }
        try bytes.write(to: index, options: .atomic)
        records = candidate
    }
}

public enum StagedExtensionError: Error, Equatable {
    case invalidIndex, invalidIdentity, digestMismatch, downgrade, versionConflict, notFound, untrustedActivation, inactive
    case invalidVerification, verificationRequired, conflictingSource
}
