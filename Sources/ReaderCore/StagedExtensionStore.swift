import Foundation
import CryptoKit

public struct StagedExtension: Codable, Identifiable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let versionCode: UInt64
    public let digest: String
    public let stagedAt: Date
    public let inspection: JARInspection
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
                                     digest: digest, stagedAt: Date(), inspection: inspection)
        let candidate = records.filter { $0.id != packageName } + [record]
        guard candidate.count <= 10_000 else { throw StagedExtensionError.invalidIndex }
        // Blob first, atomic index last: failures never point the index at an incomplete JAR.
        try data.write(to: blob(digest), options: .atomic)
        try commit(candidate)
        return record
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
    case invalidIndex, invalidIdentity, digestMismatch, downgrade, versionConflict, notFound
}
