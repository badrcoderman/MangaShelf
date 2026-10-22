import Foundation

/// Repository metadata for browsing, not a registry of instantiated JVM sources.
public struct IndexedExtensionSource: Identifiable, Equatable, Sendable {
    public var id: String { source.id }
    public let source: SourceRecord
    public let packageName: String
    public let extensionName: String

    /// Only use metadata for the staged version. Conflicting ownership or
    /// metadata is ambiguous, so no repository is silently given precedence.
    public static func available(indexes: [RepositoryIndex], staged: [StagedExtension]) -> [Self] {
        let active = Set(staged.filter { $0.isActive && $0.isTrusted }
            .map { PackageVersion(package: $0.packageName, version: $0.versionCode) })
        var candidates: [String: Set<Self>] = [:]
        for index in indexes {
            for entry in index.extensions where active.contains(PackageVersion(
                package: entry.packageName, version: entry.versionCode)) {
                for source in entry.sources where !source.id.isEmpty && source.id != "local" && source.id != "mangadex" {
                    candidates[source.id, default: []].insert(Self(source: source,
                        packageName: entry.packageName, extensionName: entry.name))
                }
            }
        }
        return candidates.values.compactMap { $0.count == 1 ? $0.first : nil }
            .sorted { $0.id < $1.id }
    }

    private struct PackageVersion: Hashable { let package: String; let version: UInt64 }
}

extension IndexedExtensionSource: Hashable {}
