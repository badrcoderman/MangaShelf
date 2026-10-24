import XCTest
import CSafeArchive
@testable import ReaderCore

/// Synthetic source data belongs in the test target, never the app runtime.
func extensionTestDispatch(action: String, payload: String) throws -> String {
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let sourceID = fields["sourceId"] as? String ?? "fixture-source"
    let url = fields["url"] as? String ?? "/fixture"
    func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    switch action {
    case "load": return "{\"status\":\"loaded\"}"
    case "unload": return "{\"status\":\"unloaded\"}"
    case "popular":
        return try encode(SourceMangaPage(mangas: [
            SourceMangaItem(id: "\(sourceID)-pop-1", title: "Fixture 1", url: "/fixture/1"),
            SourceMangaItem(id: "\(sourceID)-pop-2", title: "Fixture 2", url: "/fixture/2")
        ], hasNextPage: true))
    case "latest":
        return try encode(SourceMangaPage(mangas: [
            SourceMangaItem(id: "\(sourceID)-latest-1", title: "Latest Fixture", url: "/fixture/latest")
        ], hasNextPage: false))
    case "search":
        return try encode(SourceMangaPage(mangas: [SourceMangaItem(id: "\(sourceID)-search-1", title: fields["query"] as? String ?? "Fixture", url: "/fixture/search")], hasNextPage: false))
    case "details":
        return try encode(SourceMangaDetails(title: "Fixture Details", genre: ["Action", "Adventure"]))
    case "chapters":
        return try encode([
            SourceChapterItem(id: "ch-2", name: "Chapter 2", url: "\(url)/2", chapterNumber: 2),
            SourceChapterItem(id: "ch-1", name: "Chapter 1", url: "\(url)/1", chapterNumber: 1)
        ])
    case "pages":
        return try encode((1...5).map { SourcePageItem(index: $0, url: "\(url)/page/\($0)") })
    default:
        throw ReaderFailure("Unexpected test action: \(action)")
    }
}

func makeExtensionTestRuntime() -> ExtensionRuntime {
    ExtensionRuntime(dispatchHandler: extensionTestDispatch)
}

private final class NativeDispatchCounter {
    static let shared = NativeDispatchCounter()
    private let lock = NSLock()
    private var calls = 0
    func reset() { lock.lock(); calls = 0; lock.unlock() }
    func record() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

final class ExtensionEngineTests: XCTestCase {
    func testExtensionRuntimeLifecycle() async throws {
        let runtime = makeExtensionTestRuntime()

        // Unloaded initially
        XCTAssertFalse(runtime.isLoaded(package: "com.example.mocksource"))

        // Load extension
        let loaded = try await runtime.loadExtension(package: "com.example.mocksource")
        XCTAssertTrue(loaded)
        XCTAssertTrue(runtime.isLoaded(package: "com.example.mocksource"))

        // Query popular
        let popular = try await runtime.popular(sourceId: "mocksource", page: 1)
        XCTAssertFalse(popular.mangas.isEmpty)
        XCTAssertEqual(popular.mangas.first?.id, "mocksource-pop-1")

        // Query search
        let searchResults = try await runtime.search(sourceId: "mocksource", query: "Solo", page: 1)
        XCTAssertFalse(searchResults.mangas.isEmpty)
        XCTAssertTrue(searchResults.mangas.first?.title.contains("Solo") == true)

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
        let runtime = makeExtensionTestRuntime()
        let coordinator = SourceEngineCoordinator(stagedStore: nil, runtime: runtime)

        let popular = try await coordinator.search(sourceId: "ext-test", query: "", page: 1)
        XCTAssertFalse(popular.mangas.isEmpty)

        let search = try await coordinator.search(sourceId: "ext-test", query: "Hero", page: 1)
        XCTAssertFalse(search.mangas.isEmpty)

        let details = try await coordinator.fetchDetails(sourceId: "ext-test", mangaURL: "/manga/hero")
        XCTAssertFalse(details.title.isEmpty)

        let chapters = try await coordinator.fetchChapters(sourceId: "ext-test", mangaURL: "/manga/hero")
        XCTAssertFalse(chapters.isEmpty)

        let pages = try await coordinator.fetchPages(sourceId: "ext-test", chapterURL: "/manga/hero/ch-1")
        XCTAssertEqual(pages.count, 5)
    }

    func testUnavailableNativeRuntimeDoesNotFabricateSourceData() async throws {
        ms_bridge_register_dispatcher(nil)
        ms_bridge_set_vm_available(0)
        let runtime = ExtensionRuntime()
        let message = ReaderText.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet.")
        for action in ["load", "unload", "popular", "latest", "search", "details", "chapters", "pages"] {
            XCTAssertThrowsError(try runtime.dispatch(action: action)) { error in
                XCTAssertEqual((error as? ReaderFailure)?.message, message)
            }
        }
        do {
            _ = try await runtime.loadExtension(package: "fixture.source")
            XCTFail("An unavailable runtime must not report a successful load")
        } catch {
            XCTAssertEqual((error as? ReaderFailure)?.message, message)
        }
        XCTAssertFalse(runtime.isLoaded(package: "fixture.source"))
    }

    func testLifecycleRequiresSuccessfulAcknowledgment() async throws {
        for invalidResponse in ["{}", "not JSON", "{\"status\":\"failed\"}", "{\"status\":\"loaded\",\"error\":\"failure\"}"] {
            let runtime = ExtensionRuntime(dispatchHandler: { _, _ in invalidResponse })
            do {
                _ = try await runtime.loadExtension(package: "fixture.source")
                XCTFail("A failed load must not mark the package loaded")
            } catch {}
            XCTAssertFalse(runtime.isLoaded(package: "fixture.source"))
        }
        let runtime = ExtensionRuntime(dispatchHandler: { action, _ in
            action == "load" ? "{\"status\":\"loaded\"}" : "{\"status\":\"failed\"}"
        })
        let loaded = try await runtime.loadExtension(package: "fixture.source")
        XCTAssertTrue(loaded)
        do {
            _ = try await runtime.unloadExtension(package: "fixture.source")
            XCTFail("A failed unload must preserve the loaded state")
        } catch {}
        XCTAssertTrue(runtime.isLoaded(package: "fixture.source"))
    }

    func testEveryCommandSerializesUnmodifiedStringsAsJSON() async throws {
        let text = "quote\" slash\\ newline\n tab\t العربية😀\u{0000}"
        var calls: [(String, [String: Any])] = []
        let runtime = ExtensionRuntime(dispatchHandler: { action, payload in
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            calls.append((action, fields))
            return try extensionTestDispatch(action: action, payload: payload)
        })

        _ = try await runtime.loadExtension(package: text, path: text, mainClass: text)
        _ = try await runtime.unloadExtension(package: text)
        _ = try await runtime.popular(sourceId: text, page: 7)
        _ = try await runtime.search(sourceId: text, query: text, page: 8)
        _ = try await runtime.details(sourceId: text, mangaURL: text)
        _ = try await runtime.chapters(sourceId: text, mangaURL: text)
        _ = try await runtime.pages(sourceId: text, chapterURL: text)
        _ = try await runtime.latest(sourceId: text, page: 9)

        XCTAssertEqual(calls.map { $0.0 }, ["load", "unload", "popular", "search", "details", "chapters", "pages", "latest"])
        XCTAssertEqual(calls[0].1["package"] as? String, text)
        XCTAssertEqual(calls[0].1["path"] as? String, text)
        XCTAssertEqual(calls[0].1["mainClass"] as? String, text)
        XCTAssertEqual(calls[0].1.count, 3)
        XCTAssertEqual(calls[1].1["package"] as? String, text)
        XCTAssertEqual(calls[1].1.count, 1)
        for (_, fields) in calls.dropFirst(2) { XCTAssertEqual(fields["sourceId"] as? String, text) }
        XCTAssertEqual(calls[2].1["page"] as? Int, 7)
        XCTAssertEqual(calls[2].1.count, 2)
        XCTAssertEqual(calls[3].1["query"] as? String, text)
        XCTAssertEqual(calls[3].1["page"] as? Int, 8)
        XCTAssertEqual(calls[3].1.count, 3)
        for (_, fields) in calls[4...6] {
            XCTAssertEqual(fields["url"] as? String, text)
            XCTAssertEqual(fields.count, 2)
        }
        XCTAssertEqual(calls[7].1["page"] as? Int, 9)
        XCTAssertEqual(calls[7].1.count, 2)
    }

    func testOversizedNativeResponseDoesNotAllocateOrReplay() {
        NativeDispatchCounter.shared.reset()
        ms_bridge_register_dispatcher { _, _, _, _, needed in
            NativeDispatchCounter.shared.record()
            needed?.pointee = Int.max
            return Int32(MS_BRIDGE_BUFFER_TOO_SMALL)
        }
        defer { ms_bridge_register_dispatcher(nil) }

        XCTAssertThrowsError(try ExtensionRuntime().dispatch(action: "load")) { error in
            XCTAssertEqual((error as? ReaderFailure)?.message,
                           ReaderText.string("The extension runtime returned an invalid response."))
        }
        XCTAssertEqual(NativeDispatchCounter.shared.count, 1)
    }

    func testNativeSuccessRejectsOversizedReportedLength() {
        ms_bridge_register_dispatcher { _, _, _, _, needed in
            needed?.pointee = Int.max
            return Int32(MS_BRIDGE_OK)
        }
        defer { ms_bridge_register_dispatcher(nil) }

        XCTAssertThrowsError(try ExtensionRuntime().dispatch(action: "ping")) { error in
            XCTAssertEqual((error as? ReaderFailure)?.message,
                           ReaderText.string("The extension runtime returned an invalid response."))
        }
    }

    func testNativeSuccessRequiresTerminatorInsideResponseBuffer() {
        ms_bridge_register_dispatcher { _, _, output, capacity, needed in
            guard let output else { return Int32(MS_BRIDGE_INVALID_ARG) }
            for index in 0..<capacity { output[index] = 65 }
            needed?.pointee = capacity
            return Int32(MS_BRIDGE_OK)
        }
        defer { ms_bridge_register_dispatcher(nil) }

        XCTAssertThrowsError(try ExtensionRuntime().dispatch(action: "ping")) { error in
            XCTAssertEqual((error as? ReaderFailure)?.message,
                           ReaderText.string("The extension runtime returned an invalid response."))
        }
    }

    func testNativeSuccessRequiresValidUTF8() {
        ms_bridge_register_dispatcher { _, _, output, capacity, needed in
            guard let output, capacity >= 2 else { return Int32(MS_BRIDGE_INVALID_ARG) }
            output[0] = CChar(bitPattern: 0xff)
            output[1] = 0
            needed?.pointee = 2
            return Int32(MS_BRIDGE_OK)
        }
        defer { ms_bridge_register_dispatcher(nil) }

        XCTAssertThrowsError(try ExtensionRuntime().dispatch(action: "ping")) { error in
            XCTAssertEqual((error as? ReaderFailure)?.message,
                           ReaderText.string("The extension runtime returned an invalid response."))
        }
    }

    func testNativeDispatchSuccessDecodesBoundedResponseOnce() throws {
        NativeDispatchCounter.shared.reset()
        ms_bridge_register_dispatcher { _, _, output, capacity, needed in
            NativeDispatchCounter.shared.record()
            let bytes = Array("{\"title\":\"عنوان😀\"}".utf8)
            guard let output, capacity > bytes.count else { return Int32(MS_BRIDGE_INVALID_ARG) }
            for (index, byte) in bytes.enumerated() { output[index] = CChar(bitPattern: byte) }
            output[bytes.count] = 0
            // Non-UTF-8 data beyond the terminator must not be decoded.
            if bytes.count + 1 < capacity { output[bytes.count + 1] = CChar(bitPattern: 0xff) }
            needed?.pointee = bytes.count + 1
            return Int32(MS_BRIDGE_OK)
        }
        defer { ms_bridge_register_dispatcher(nil) }

        XCTAssertEqual(try ExtensionRuntime().dispatch(action: "details"), "{\"title\":\"عنوان😀\"}")
        XCTAssertEqual(NativeDispatchCounter.shared.count, 1)
    }

    func testNativeNotStartedRaceUsesUnavailableMessage() {
        ms_bridge_register_dispatcher { _, _, _, _, _ in Int32(MS_BRIDGE_NOT_STARTED) }
        defer { ms_bridge_register_dispatcher(nil) }

        XCTAssertThrowsError(try ExtensionRuntime().dispatch(action: "ping")) { error in
            XCTAssertEqual((error as? ReaderFailure)?.message,
                           ReaderText.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet."))
        }
    }

    func testOwnedNativeResponseDecodesLargeUnicodeResultOnce() throws {
        NativeDispatchCounter.shared.reset()
        ms_bridge_register_dispatchers(nil, { _, _, output, length in
            NativeDispatchCounter.shared.record()
            let bytes = Array((String(repeating: "a", count: 100_000) + "العربية📚").utf8)
            guard let output, let length, let allocation = malloc(bytes.count + 1) else {
                return Int32(MS_BRIDGE_JNI_ERROR)
            }
            let target = allocation.assumingMemoryBound(to: CChar.self)
            for (index, byte) in bytes.enumerated() { target[index] = CChar(bitPattern: byte) }
            target[bytes.count] = 0
            output.pointee = target
            length.pointee = bytes.count
            return Int32(MS_BRIDGE_OK)
        })
        defer { ms_bridge_register_dispatcher(nil) }

        let result = try ExtensionRuntime().dispatch(action: "details")
        XCTAssertEqual(result, String(repeating: "a", count: 100_000) + "العربية📚")
        XCTAssertEqual(NativeDispatchCounter.shared.count, 1)
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
        ms_bridge_register_dispatcher(nil)
        ms_bridge_set_vm_available(0)
        defer {
            ms_bridge_register_dispatcher(nil)
            ms_bridge_set_vm_available(0)
        }
        XCTAssertEqual(ms_bridge_is_vm_available(), 0)

        // Register custom dispatcher
        ms_bridge_register_dispatcher { action, payload, output, capacity, needed in
            guard let action = action, let output = output else { return Int32(MS_BRIDGE_INVALID_ARG) }
            let actionStr = String(cString: action)
            if actionStr == "ping" {
                let response = "{\"status\":\"custom-pong\"}"
                if response.utf8.count < capacity {
                    _ = response.withCString { ptr in
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
