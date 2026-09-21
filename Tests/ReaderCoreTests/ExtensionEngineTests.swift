import XCTest
import CSafeArchive
@testable import ReaderCore

final class ExtensionEngineTests: XCTestCase {
    func testExtensionRuntimeLifecycle() async throws {
        let runtime = ExtensionRuntime()

        // Unloaded initially
        XCTAssertFalse(runtime.isLoaded(package: "com.example.mocksource"))

        // Load extension
        let loaded = try await runtime.loadExtension(package: "com.example.mocksource")
        XCTAssertTrue(loaded)
        XCTAssertTrue(runtime.isLoaded(package: "com.example.mocksource"))

        // Query popular
        let popular = try await runtime.popular(sourceId: "mocksource", page: 1)
        XCTAssertFalse(popular.isEmpty)
        XCTAssertEqual(popular.first?.id, "mocksource-pop-1")

        // Query search
        let searchResults = try await runtime.search(sourceId: "mocksource", query: "Solo", page: 1)
        XCTAssertFalse(searchResults.isEmpty)
        XCTAssertTrue(searchResults.first?.title.contains("Solo") == true)

        // Query details
        let details = try await runtime.details(sourceId: "mocksource", mangaURL: "/manga/mocksource/1")
        XCTAssertFalse(details.title.isEmpty)

        // Query chapters
        let chapters = try await runtime.chapters(sourceId: "mocksource", mangaURL: "/manga/mocksource/1")
        XCTAssertFalse(chapters.isEmpty)
        XCTAssertEqual(chapters.first?.id, "ch-2")

        // Query pages
        let pages = try await runtime.pages(sourceId: "mocksource", chapterURL: "/chapter/1")
        XCTAssertEqual(pages.count, 5)
        XCTAssertEqual(pages.first?.index, 1)

        // Unload extension
        let unloaded = try await runtime.unloadExtension(package: "com.example.mocksource")
        XCTAssertTrue(unloaded)
        XCTAssertFalse(runtime.isLoaded(package: "com.example.mocksource"))
    }

    func testSourceEngineCoordinatorWithExtensionRuntime() async throws {
        let runtime = ExtensionRuntime()
        let coordinator = SourceEngineCoordinator(stagedStore: nil, runtime: runtime)

        let popular = try await coordinator.search(sourceId: "ext-test", query: "", page: 1)
        XCTAssertFalse(popular.isEmpty)

        let search = try await coordinator.search(sourceId: "ext-test", query: "Hero", page: 1)
        XCTAssertFalse(search.isEmpty)

        let details = try await coordinator.fetchDetails(sourceId: "ext-test", mangaURL: "/manga/hero")
        XCTAssertFalse(details.title.isEmpty)

        let chapters = try await coordinator.fetchChapters(sourceId: "ext-test", mangaURL: "/manga/hero")
        XCTAssertFalse(chapters.isEmpty)

        let pages = try await coordinator.fetchPages(sourceId: "ext-test", chapterURL: "/manga/hero/ch-1")
        XCTAssertEqual(pages.count, 5)
    }

    func testStagedExtensionDisplayName() {
        let inspection = JARInspection(entries: 1, classes: ["Test.class"], maximumClassVersion: 52, manifest: nil)
        let ext1 = StagedExtension(packageName: "eu.kanade.tachiyomi.extension.all.mangadex",
                                   versionCode: 1,
                                   digest: "a" + String(repeating: "0", count: 63),
                                   stagedAt: Date(),
                                   inspection: inspection)
        XCTAssertEqual(ext1.displayName, "Mangadex")

        let ext2 = StagedExtension(packageName: "mangashelf.extension.probe",
                                   versionCode: 1,
                                   digest: "b" + String(repeating: "0", count: 63),
                                   stagedAt: Date(),
                                   inspection: inspection)
        XCTAssertEqual(ext2.displayName, "Probe")
    }

    func testMSJNIBridgeExecution() {
        XCTAssertEqual(ms_bridge_is_vm_available(), 0)

        // Register custom dispatcher
        ms_bridge_register_dispatcher { action, payload, output, capacity, needed in
            guard let action = action, let output = output else { return Int32(MS_BRIDGE_INVALID_ARG) }
            let actionStr = String(cString: action)
            if actionStr == "ping" {
                let response = "{\"status\":\"custom-pong\"}"
                if response.utf8.count < capacity {
                    response.withCString { ptr in
                        strcpy(output, ptr)
                    }
                    needed?.pointee = response.utf8.count
                    return Int32(MS_BRIDGE_OK)
                } else {
                    needed?.pointee = response.utf8.count
                    return Int32(MS_BRIDGE_BUFFER_TOO_SMALL)
                }
            }
            return Int32(MS_BRIDGE_METHOD_NOT_FOUND)
        }

        XCTAssertEqual(ms_bridge_is_vm_available(), 1)

        var buffer = [CChar](repeating: 0, count: 64)
        var needed: size_t = 0
        let rc = ms_bridge_dispatch("ping", "{}", &buffer, 64, &needed)
        XCTAssertEqual(rc, Int32(MS_BRIDGE_OK))
        XCTAssertEqual(String(cString: buffer), "{\"status\":\"custom-pong\"}")

        // Reset VM availability
        ms_bridge_set_vm_available(0)
        XCTAssertEqual(ms_bridge_is_vm_available(), 0)
    }
}
