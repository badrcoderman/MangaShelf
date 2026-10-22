import XCTest
@testable import ReaderCore

final class IndexedExtensionSourceTests: XCTestCase {
    private func source(_ id: String, name: String = "Source", language: String = "ar") -> SourceRecord {
        SourceRecord(id: id, name: name, language: language, homeURL: nil)
    }

    private func entry(_ package: String = "com.example.factory", version: UInt64 = 1,
                       sources: [SourceRecord]) -> ExtensionRecord {
        ExtensionRecord(name: "Factory", packageName: package, versionName: "1.0",
                        versionCode: version, jarURL: nil, iconURL: nil, sources: sources)
    }

    private func index(_ entries: [ExtensionRecord]) -> RepositoryIndex {
        RepositoryIndex(name: "Test", signingKey: nil, extensionListURL: nil,
                        extensions: entries, hasEmbeddedList: true)
    }

    private func staged(_ package: String = "com.example.factory", version: UInt64 = 1,
                        trusted: Bool = true, active: Bool = true) -> StagedExtension {
        StagedExtension(packageName: package, versionCode: version, digest: String(repeating: "0", count: 64),
                        stagedAt: Date(timeIntervalSince1970: 0),
                        inspection: JARInspection(entries: 1, classes: [], maximumClassVersion: 52, manifest: nil),
                        isTrusted: trusted, isActive: active)
    }

    func testFactorySourcesKeepSeparateIDsNamesAndLanguages() {
        let arabic = source("9223372036854775809", name: "المصدر", language: "ar")
        let english = source("9223372036854775810", name: "Source", language: "en")
        let result = IndexedExtensionSource.available(indexes: [index([entry(sources: [english, arabic])])],
                                                      staged: [staged()])
        XCTAssertEqual(result.map(\.id), [arabic.id, english.id])
        XCTAssertEqual(result.map(\.source), [arabic, english])
        XCTAssertEqual(result.map(\.packageName), ["com.example.factory", "com.example.factory"])
        XCTAssertFalse(result.contains { $0.id == $0.packageName })
    }

    func testOnlyMatchingActiveTrustedStagedVersionIsListed() {
        let indexes = [index([entry(sources: [source("123")])])]
        for record in [staged(trusted: false), staged(active: false), staged(version: 2), staged("other.package")] {
            XCTAssertTrue(IndexedExtensionSource.available(indexes: indexes, staged: [record]).isEmpty)
        }
        XCTAssertEqual(IndexedExtensionSource.available(indexes: indexes, staged: [staged()]).count, 1)
        XCTAssertTrue(IndexedExtensionSource.available(indexes: indexes, staged: []).isEmpty)
        XCTAssertTrue(IndexedExtensionSource.available(indexes: [], staged: [staged()]).isEmpty)
    }

    func testRepeatedRepositoryMetadataIsCollapsed() {
        let repository = index([entry(sources: [source("123")])])
        let result = IndexedExtensionSource.available(indexes: [repository, repository], staged: [staged()])
        XCTAssertEqual(result.count, 1)
    }

    func testConflictingPackageOwnershipDoesNotPickRepositoryOrder() {
        let first = index([entry(sources: [source("123"), source("456")])])
        let second = index([entry("other.package", sources: [source("123")])])
        let records = [staged(), staged("other.package")]
        for indexes in [[first, second], [second, first]] {
            XCTAssertEqual(IndexedExtensionSource.available(indexes: indexes, staged: records).map(\.id), ["456"])
        }
    }

    func testConflictingMetadataAndReservedOrMissingIDsAreNotRouted() {
        let first = index([entry(sources: [source("123"), source(""), source("local"), source("mangadex")])])
        let second = index([entry(sources: [source("123", name: "Different")])])
        XCTAssertTrue(IndexedExtensionSource.available(indexes: [first, second], staged: [staged()]).isEmpty)
    }
}
