import XCTest
import CryptoKit
@testable import ReaderCore

final class ExtensionManifestTests: XCTestCase {
    private let namespace = "http://schemas.android.com/apk/res/android"
    private let package = "com.example.extension"
    private let version: UInt64 = 4_200_000_000

    private func xml(className: String = ".SourceFactory", code: String = "4200000000") -> String {
        """
        <manifest xmlns:a="\(namespace)" package="\(package)" a:versionCode="\(code)" a:versionName="1.6.3">
        <uses-feature a:name="tachiyomi.extension"/>
        <application><meta-data a:name="tachiyomi.extension.class" a:value="\(className)"/></application>
        </manifest>
        """
    }

    private func fixture(_ name: String = "extension-manifest") throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jar", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRelativeClassNamespaceAliasAndUnsignedVersion() throws {
        let manifest = try ExtensionPackageManifest.parse(Data(xml().utf8))
        XCTAssertEqual(manifest.packageName, package)
        XCTAssertEqual(manifest.versionCode, version)
        XCTAssertEqual(manifest.versionName, "1.6.3")
        XCTAssertEqual(manifest.mainClass, package + ".SourceFactory")
    }

    func testFullyQualifiedClassIsNotPrefixedWithPackage() throws {
        let manifest = try ExtensionPackageManifest.parse(Data(xml(className: " other.namespace.Source$Nested ").utf8))
        XCTAssertEqual(manifest.mainClass, "other.namespace.Source$Nested")
    }

    func testManifestRequiresExtensionFeatureAndDirectApplicationMetadata() {
        let original = xml()
        let metadata = "<meta-data a:name=\"tachiyomi.extension.class\" a:value=\".SourceFactory\"/>"
        let invalid = [
            original.replacingOccurrences(of: "<uses-feature a:name=\"tachiyomi.extension\"/>", with: ""),
            original.replacingOccurrences(of: "<application>\(metadata)</application>", with: metadata),
            original.replacingOccurrences(of: metadata, with: "<activity>\(metadata)</activity>"),
            original.replacingOccurrences(of: metadata, with: ""),
            original.replacingOccurrences(of: "a:value=\".SourceFactory\"", with: "a:resource=\"@string/source\"")
        ]
        for text in invalid { XCTAssertThrowsError(try ExtensionPackageManifest.parse(Data(text.utf8))) }
    }

    func testAmbiguousAndSpoofedNamespaceMetadataIsRejected() {
        let original = xml()
        let invalid = [
            original.replacingOccurrences(of: namespace, with: "https://wrong.invalid/android"),
            original.replacingOccurrences(of: "<meta-data ", with: "<meta-data xmlns:a=\"https://wrong.invalid\" "),
            original.replacingOccurrences(of: "</application>", with: "<meta-data a:name=\"tachiyomi.extension.class\" a:value=\".Other\"/></application>"),
            original.replacingOccurrences(of: "</application>", with: "</application><application/>"),
            original.replacingOccurrences(of: "<manifest ", with: "<manifest xmlns=\"urn:other\" "),
            original.replacingOccurrences(of: "<manifest ", with: "<manifest xmlns:b=\"\(namespace)\" b:versionCode=\"9\" ")
        ]
        for text in invalid { XCTAssertThrowsError(try ExtensionPackageManifest.parse(Data(text.utf8))) }
    }

    func testEntitiesBinaryManifestAndNonUTF8AreRejected() {
        let invalid = [
            Data(("<!DOCTYPE manifest SYSTEM 'file:///must-not-be-read'>" + xml()).utf8),
            Data(("<!DOCTYPE manifest [<!ENTITY injected '.Other'>]>" + xml()).utf8),
            Data([0x03, 0x00, 0x08, 0x00]),
            xml().data(using: .utf16)!
        ]
        for data in invalid { XCTAssertThrowsError(try ExtensionPackageManifest.parse(data)) }
    }

    func testBoundsClassSyntaxAndVersionSyntaxAreEnforced() {
        for name in ["", ".", "../Other", "foo..Other", "foo/Other", "9Invalid", "@string/source"] {
            XCTAssertThrowsError(try ExtensionPackageManifest.parse(Data(xml(className: name).utf8)))
        }
        for code in ["", "-1", "1.5", "0x10", "18446744073709551616"] {
            XCTAssertThrowsError(try ExtensionPackageManifest.parse(Data(xml(code: code).utf8)))
        }
        XCTAssertThrowsError(try ExtensionPackageManifest.parse(Data(repeating: 32, count: 256 * 1024 + 1)))
        let deep = xml().replacingOccurrences(of: "</application>",
            with: String(repeating: "<x>", count: 33) + String(repeating: "</x>", count: 33) + "</application>")
        XCTAssertThrowsError(try ExtensionPackageManifest.parse(Data(deep.utf8)))
    }

    func testJARInspectionReadsManifestAndRequiresDeclaredClassEntry() throws {
        let result = try JARInspection.inspect(fixture())
        XCTAssertEqual(result.extensionManifest?.mainClass, package + ".SourceFactory")
        XCTAssertEqual(result.extensionManifest?.versionCode, version)
        XCTAssertThrowsError(try JARInspection.inspect(fixture("extension-missing-class")))
    }

    func testOldInspectionRecordsRemainDecodableWithoutManifest() throws {
        let json = Data(#"{"entries":1,"classes":["Probe.class"],"maximumClassVersion":61}"#.utf8)
        let result = try JSONDecoder().decode(JARInspection.self, from: json)
        XCTAssertNil(result.extensionManifest)
        XCTAssertEqual(result.maximumClassVersion, 61)
    }

    func testStagingRejectsPackageAndVersionMismatchWithoutReplacingCandidate() async throws {
        let store = try StagedExtensionStore(root: temporaryRoot())
        let bytes = try fixture()
        _ = try await store.stage(packageName: package, versionCode: version, data: bytes, expectedDigest: digest(bytes))
        for (name, code) in [("different.package", version), (package, version + 1)] {
            do {
                _ = try await store.stage(packageName: name, versionCode: code, data: bytes, expectedDigest: digest(bytes))
                XCTFail("Repository identity must match the manifest")
            } catch { XCTAssertEqual(error as? StagedExtensionError, .invalidIdentity) }
        }
        let records = await store.snapshot()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.packageName, package)
        XCTAssertEqual(records.first?.versionCode, version)
        XCTAssertFalse(records[0].isTrusted)
        XCTAssertFalse(records[0].isActive)
    }

    func testLoadPassesVerifiedManifestClassToDispatcher() async throws {
        let root = try temporaryRoot()
        let store = try StagedExtensionStore(root: root)
        let bytes = try fixture()
        _ = try await store.stage(packageName: package, versionCode: version, data: bytes, expectedDigest: digest(bytes))
        try await store.setTrust(packageName: package, trusted: true)
        try await store.setActive(packageName: package, active: true)
        var calls: [[String: String]] = []
        let runtime = ExtensionRuntime(dispatchHandler: { action, payload in
            XCTAssertEqual(action, "load")
            calls.append(try JSONDecoder().decode([String: String].self, from: Data(payload.utf8)))
            return "{\"status\":\"loaded\"}"
        })
        try await SourceEngineCoordinator(stagedStore: store, runtime: runtime).ensureExtensionLoaded(packageName: package)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["mainClass"], package + ".SourceFactory")
        XCTAssertEqual(calls.first?["package"], package)
        XCTAssertEqual(calls.first?["path"], root.appendingPathComponent(digest(bytes) + ".jar").path)
        // The dispatcher acknowledgment here is a fixture, not a JVM or source ABI test.
    }

    func testTamperedBlobCannotReachDispatcher() async throws {
        let root = try temporaryRoot()
        let store = try StagedExtensionStore(root: root)
        let bytes = try fixture()
        _ = try await store.stage(packageName: package, versionCode: version, data: bytes, expectedDigest: digest(bytes))
        try await store.setTrust(packageName: package, trusted: true)
        try await store.setActive(packageName: package, active: true)
        try Data("changed".utf8).write(to: root.appendingPathComponent(digest(bytes) + ".jar"))
        let runtime = ExtensionRuntime(dispatchHandler: { _, _ in XCTFail("Corrupted bytes must not load"); return "{}" })
        do {
            try await SourceEngineCoordinator(stagedStore: store, runtime: runtime).ensureExtensionLoaded(packageName: package)
            XCTFail("Expected digest mismatch")
        } catch { XCTAssertEqual(error as? StagedExtensionError, .digestMismatch) }
    }

    func testPersistedInspectionCannotOverrideArchiveEntryPoint() async throws {
        let root = try temporaryRoot()
        let store = try StagedExtensionStore(root: root)
        let bytes = try fixture()
        _ = try await store.stage(packageName: package, versionCode: version, data: bytes, expectedDigest: digest(bytes))
        try await store.setTrust(packageName: package, trusted: true)
        try await store.setActive(packageName: package, active: true)
        let indexURL = root.appendingPathComponent("staged.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        var inspection = try XCTUnwrap(records[0]["inspection"] as? [String: Any])
        var manifest = try XCTUnwrap(inspection["extensionManifest"] as? [String: Any])
        manifest["mainClass"] = "forged.WrongClass"
        inspection["extensionManifest"] = manifest
        records[0]["inspection"] = inspection
        try JSONSerialization.data(withJSONObject: records).write(to: indexURL)
        let reloaded = try StagedExtensionStore(root: root)
        var loadedClass: String?
        let runtime = ExtensionRuntime(dispatchHandler: { _, payload in
            loadedClass = try JSONDecoder().decode([String: String].self, from: Data(payload.utf8))["mainClass"]
            return "{\"status\":\"loaded\"}"
        })
        try await SourceEngineCoordinator(stagedStore: reloaded, runtime: runtime).ensureExtensionLoaded(packageName: package)
        XCTAssertEqual(loadedClass, package + ".SourceFactory")
    }

    func testMissingUntrustedAndInactiveCandidatesCannotReachDispatcher() async throws {
        let store = try StagedExtensionStore(root: temporaryRoot())
        let runtime = ExtensionRuntime(dispatchHandler: { _, _ in XCTFail("Candidate must not load"); return "{}" })
        let engine = SourceEngineCoordinator(stagedStore: store, runtime: runtime)
        do { try await engine.ensureExtensionLoaded(packageName: package); XCTFail("Expected missing package") }
        catch { XCTAssertEqual(error as? StagedExtensionError, .notFound) }
        let bytes = try fixture()
        _ = try await store.stage(packageName: package, versionCode: version, data: bytes, expectedDigest: digest(bytes))
        do { try await engine.ensureExtensionLoaded(packageName: package); XCTFail("Expected untrusted package") }
        catch { XCTAssertEqual(error as? StagedExtensionError, .untrustedActivation) }
        try await store.setTrust(packageName: package, trusted: true)
        do { try await engine.ensureExtensionLoaded(packageName: package); XCTFail("Expected inactive package") }
        catch { XCTAssertEqual(error as? StagedExtensionError, .inactive) }
    }

    func testClassOnlyJARCannotLoadAsAnExtension() async throws {
        let store = try StagedExtensionStore(root: temporaryRoot())
        let bytes = try fixture("plain-probe")
        _ = try await store.stage(packageName: package, versionCode: version, data: bytes, expectedDigest: digest(bytes))
        try await store.setTrust(packageName: package, trusted: true)
        try await store.setActive(packageName: package, active: true)
        let runtime = ExtensionRuntime(dispatchHandler: { _, _ in XCTFail("Missing manifest must not load"); return "{}" })
        do {
            try await SourceEngineCoordinator(stagedStore: store, runtime: runtime).ensureExtensionLoaded(packageName: package)
            XCTFail("Expected missing manifest")
        } catch { XCTAssertEqual(error as? StagedExtensionError, .invalidIdentity) }
    }
}
