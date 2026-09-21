import XCTest
@testable import ReaderCore

final class PhaseTwoBridgeTests: XCTestCase {
    func testNativeBridgeChannelDispatch() {
        let bridge = NativeBridge()
        var receivedTopic = ""
        var receivedContent = ""
        let expectation = expectation(description: "Channel listener invoked")

        bridge.registerChannelListener { topic, content in
            receivedTopic = topic
            receivedContent = content
            expectation.fulfill()
        }

        bridge.dispatchChannel(topic: "source.events", content: "{\"event\":\"ready\"}")
        waitForExpectations(timeout: 2.0)

        XCTAssertEqual(receivedTopic, "source.events")
        XCTAssertEqual(receivedContent, "{\"event\":\"ready\"}")
    }

    func testNativeBridgeNetCallErrorEncoding() {
        let bridge = NativeBridge()
        // Invalid request JSON to trigger error handling in handleNetCall
        let invalidData = Data("invalid json".utf8)
        let result = bridge.handleNetCall(reqJSON: invalidData, reqBody: nil)
        XCTAssertNotNil(result)
        if let result = result {
            XCTAssertTrue(result.body.isEmpty)
            let decoded = try? JSONDecoder().decode(NativeNetworkResponse.self, from: result.meta)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.code, 500)
        }
    }

    func testStagedExtensionStoreTrustAndActivation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mangashelf-stage-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try StagedExtensionStore(root: tempDir)
        XCTAssertTrue(await store.snapshot().isEmpty)

        // Generate a minimal valid zip file representing a JAR
        let dummyBytes = [UInt8]("PK\u{05}\u{06}\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0".utf8)
        let jarData = Data(dummyBytes)

        // Compute actual SHA256 digest
        var hasher = CryptoKit.SHA256()
        hasher.update(data: jarData)
        let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let staged = try await store.stage(packageName: "eu.kanade.tachiyomi.extension.test",
                                           versionCode: 1,
                                           data: jarData,
                                           expectedDigest: actualDigest)
        XCTAssertEqual(staged.packageName, "eu.kanade.tachiyomi.extension.test")
        XCTAssertFalse(staged.isTrusted)
        XCTAssertFalse(staged.isActive)

        // Attempt activation before trust should fail
        do {
            try await store.setActive(packageName: staged.packageName, active: true)
            XCTFail("Activation before trust must throw")
        } catch {
            // Expected untrustedActivation error
        }

        // Set trust
        try await store.setTrust(packageName: staged.packageName, trusted: true)
        var snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.first?.isTrusted == true)
        XCTAssertFalse(snapshot.first?.isActive == true)

        // Now activation should succeed
        try await store.setActive(packageName: staged.packageName, active: true)
        snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.first?.isActive == true)

        // Revoking trust should deactivate automatically
        try await store.setTrust(packageName: staged.packageName, trusted: false)
        snapshot = await store.snapshot()
        XCTAssertFalse(snapshot.first?.isTrusted == true)
        XCTAssertFalse(snapshot.first?.isActive == true)

        // Verified package check
        let verified = try await store.verifiedPackage(packageName: staged.packageName)
        XCTAssertEqual(verified, jarData)
    }

    func testStagedExtensionCorruptionRollback() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mangashelf-rollback-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try StagedExtensionStore(root: tempDir)
        let jarData = Data("PK\u{05}\u{06}\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0".utf8)
        var hasher = CryptoKit.SHA256()
        hasher.update(data: jarData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let pkgName = "org.tachimanga.corrupt.test"
        _ = try await store.stage(packageName: pkgName, versionCode: 1, data: jarData, expectedDigest: digest)

        // Tamper with the underlying blob on disk
        let blobURL = tempDir.appendingPathComponent("\(digest).jar")
        try Data("corrupted content".utf8).write(to: blobURL)

        // verifiedPackageWithRollback should fail verification and remove the record
        do {
            _ = try await store.verifiedPackageWithRollback(packageName: pkgName)
            XCTFail("Must fail when blob hash does not match")
        } catch {
            // Expected digest mismatch or inspection error
        }

        let afterRollback = await store.snapshot()
        XCTAssertTrue(afterRollback.filter { $0.id == pkgName }.isEmpty)
    }

    func testSourceEngineCoordinatorLifecycle() async throws {
        let coordinator = SourceEngineCoordinator.shared

        // Search bounds
        do {
            _ = try await coordinator.search(sourceId: "", query: "One", page: 1)
            XCTFail("Empty sourceId must throw")
        } catch {}

        do {
            _ = try await coordinator.search(sourceId: "src-1", query: "One", page: 0)
            XCTFail("Page 0 must throw")
        } catch {}

        // Query execution
        let searchResults = try await coordinator.search(sourceId: "src-1", query: "Solo", page: 1)
        XCTAssertFalse(searchResults.isEmpty)
        XCTAssertEqual(searchResults[0].id, "src-1-search-1")

        // Popular list
        let popular = try await coordinator.search(sourceId: "src-1", query: "", page: 1)
        XCTAssertEqual(popular.count, 2)

        // Details
        let details = try await coordinator.fetchDetails(sourceId: "src-1", mangaURL: "/manga/sample-1")
        XCTAssertEqual(details.title, "Sample Manga Details")
        XCTAssertEqual(details.genre, ["Action", "Adventure"])

        // Chapters
        let chapters = try await coordinator.fetchChapters(sourceId: "src-1", mangaURL: "/manga/sample-1")
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].chapterNumber, 2.0)

        // Pages
        let pages = try await coordinator.fetchPages(sourceId: "src-1", chapterURL: "/manga/sample-1/1")
        XCTAssertEqual(pages.count, 5)
        XCTAssertEqual(pages[0].index, 1)
    }
}
