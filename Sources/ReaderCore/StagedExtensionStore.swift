import Foundation
import CryptoKit

public struct StagedExtension: Codable, Identifiable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let versionCode: UInt64
    public let digest: String
    public let stagedAt: Date
    public let inspection: JARInspection
    public var isTrusted: Bool
    public var isActive: Bool

    public init(packageName: String, versionCode: UInt64, digest: String,
                stagedAt: Date, inspection: JARInspection,
                isTrusted: Bool = false, isActive: Bool = false) {
        self.packageName = packageName
        self.versionCode = versionCode
        self.digest = digest
        self.stagedAt = stagedAt
        self.inspection = inspection
        self.isTrusted = isTrusted
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case packageName, versionCode, digest, stagedAt, inspection, isTrusted, isActive
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
    public func setTrust(packageName: String, trusted: Bool) throws {
        guard let idx = records.firstIndex(where: { $0.id == packageName }) else {
            throw StagedExtensionError.notFound
        }
        var updated = records
        var item = updated[idx]
        item.isTrusted = trusted
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
    /// Verifies package on disk and rolls back if file has been corrupted.
    public func verifiedPackageWithRollback(packageName: String) throws -> Data {
        do {
            return try verifiedPackage(packageName: packageName)
        } catch {
            try? remove(packageName: packageName)
            throw error
        }
    }
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
    case invalidIndex, invalidIdentity, digestMismatch, downgrade, versionConflict, notFound, untrustedActivation
}
