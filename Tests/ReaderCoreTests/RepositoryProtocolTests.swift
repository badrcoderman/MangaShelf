import XCTest
@testable import ReaderCore

final class RepositoryProtocolTests: XCTestCase {
    private let metadata = #"{"meta":{"name":"Legacy","shortName":"L","website":"https://example.invalid","signingKeyFingerprint":"publisher"}}"#
    private let legacyList = #"[{"name":"Legacy source","pkg":"legacy.source","jar":"jar/legacy.jar","sources":[{"id":7,"name":"Legacy","lang":"en"}]}]"#
    private let modern = #"{"name":"Modern","badgeLabel":"M","signingKey":"publisher","contact":{},"extensionList":{"extensions":[{"name":"Modern source","packageName":"modern.source","resources":{"jarUrl":"jar/source.jar","iconUrl":"icons/source.png"},"extensionLib":"1.6","versionCode":4200000000,"versionName":"1.6.3","contentWarning":"SFW","sources":[{"id":-1,"name":"Modern","language":"ar","homeUrl":"https://source.invalid"}]}]}}"#
    private let modernMetadata = #"{"name":"Modern","badgeLabel":"M","signingKey":"publisher","contact":{}}"#

    private func response(_ text: String, at url: String) -> SourceHTTPResponse {
        SourceHTTPResponse(data: Data(text.utf8), url: URL(string: url)!)
    }

    func testModernStoreJSONResourcesAndSignedSourceID() throws {
        let index = try RepositoryDecoder.decode(Data(modern.utf8), relativeTo: URL(string: "https://example.invalid/repo/index.json")!)
        XCTAssertEqual(index.name, "Modern")
        XCTAssertEqual(index.signingKey, "publisher")
        XCTAssertTrue(index.hasEmbeddedList)
        XCTAssertEqual(index.extensions.first?.versionCode, 4_200_000_000)
        XCTAssertEqual(index.extensions.first?.jarURL, "https://example.invalid/repo/jar/source.jar")
        XCTAssertEqual(index.extensions.first?.iconURL, "https://example.invalid/repo/icons/source.png")
        XCTAssertEqual(index.extensions.first?.sources.first?.id, "-1")
        XCTAssertEqual(index.extensions.first?.sources.first?.language, "ar")
    }

    func testUnsignedJSONSourceIDMatchesProtobufLongBitPattern() throws {
        let json = #"[{"name":"Long","pkg":"long.source","sources":[{"id":18446744073709551615,"lang":"en"}]}]"#
        XCTAssertEqual(try RepositoryDecoder.decode(Data(json.utf8)).extensions.first?.sources.first?.id, "-1")
    }

    func testLegacyListUsesMetadataWithoutDownloadingListTwice() async throws {
        let list = "https://example.invalid/repo/index.min.json"
        let meta = "https://example.invalid/repo/repo.json"
        let transport = RepositoryScenarioTransport(responses: [
            list: [response(legacyList, at: list)],
            meta: [response(metadata, at: meta)]
        ])
        let repository = try await RepositoryClient(transport: transport).fetch(url: list)
        XCTAssertEqual(repository.index.name, "Legacy")
        XCTAssertEqual(repository.index.signingKey, "publisher")
        XCTAssertEqual(repository.index.extensions.first?.packageName, "legacy.source")
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [list, meta])
    }

    func testLegacyMetadataLoadsSiblingList() async throws {
        let list = "https://example.invalid/repo/index.min.json"
        let meta = "https://example.invalid/repo/repo.json"
        let transport = RepositoryScenarioTransport(responses: [
            list: [response(legacyList, at: list)],
            meta: [response(metadata, at: meta)]
        ])
        let repository = try await RepositoryClient(transport: transport).fetch(url: meta)
        XCTAssertEqual(repository.index.name, "Legacy")
        XCTAssertEqual(repository.index.signingKey, "publisher")
        XCTAssertEqual(repository.index.extensions.first?.jarURL, "https://example.invalid/repo/jar/legacy.jar")
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [meta, list])
    }

    func testIndexV2UsesTargetDocumentAndPreservesSavedURL() async throws {
        let meta = "https://example.invalid/repo/repo.json"
        let next = "https://example.invalid/repo/v2/index.json"
        let redirected = #"{"index_v2":"v2/index.json","meta":{"name":"Legacy","signingKeyFingerprint":"publisher"}}"#
        let transport = RepositoryScenarioTransport(responses: [
            meta: [response(redirected, at: meta)],
            next: [response(modern, at: next)]
        ])
        let repository = try await RepositoryClient(transport: transport).fetch(url: meta)
        XCTAssertEqual(repository.url, meta)
        XCTAssertEqual(repository.index.name, "Modern")
        XCTAssertEqual(repository.index.extensions.first?.jarURL, "https://example.invalid/repo/v2/jar/source.jar")
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [meta, next])
    }

    func testSecondIndexV2RedirectStopsBeforeThirdRequest() async throws {
        let first = "https://example.invalid/repo/repo.json"
        let second = "https://example.invalid/repo/v2/repo.json"
        let firstData = #"{"index_v2":"v2/repo.json","meta":{"name":"One","signingKeyFingerprint":"publisher"}}"#
        let secondData = #"{"index_v2":"third.json","meta":{"name":"Two","signingKeyFingerprint":"publisher"}}"#
        let transport = RepositoryScenarioTransport(responses: [
            first: [response(firstData, at: first)],
            second: [response(secondData, at: second)]
        ])
        do {
            _ = try await RepositoryClient(transport: transport).fetch(url: first)
            XCTFail("A second index_v2 must fail")
        } catch { XCTAssertTrue(error is ReaderFailure) }
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [first, second])
    }

    func testUnsafeIndexV2DoesNotFallBackToAnotherIndex() async throws {
        let url = "https://example.invalid/repo/repo.json"
        let data = #"{"index_v2":"http://example.invalid/insecure.json","meta":{"name":"Legacy","signingKeyFingerprint":"publisher"}}"#
        let transport = RepositoryScenarioTransport(responses: [url: [response(data, at: url)]])
        do {
            _ = try await RepositoryClient(transport: transport).fetch(url: url)
            XCTFail("Insecure redirect must fail")
        } catch { XCTAssertTrue(error is ReaderFailure) }
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [url])
    }

    func testOnly404OnIndexMinUsesProtobufFallback() async throws {
        let json = "https://example.invalid/repo/index.min.json"
        let protobuf = "https://example.invalid/repo/index.pb"
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "index", withExtension: "pb", subdirectory: "Fixtures"))
        let fixture = SourceHTTPResponse(data: try Data(contentsOf: fixtureURL), url: URL(string: protobuf)!)
        let missing = RepositoryScenarioTransport(responses: [protobuf: [fixture]], statuses: [json: 404])
        let recovered = try await RepositoryClient(transport: missing).fetch(url: json)
        XCTAssertEqual(recovered.index.name, "Test repository")
        let requests = await missing.requestedURLs()
        XCTAssertEqual(requests, [json, protobuf])
        let forbidden = RepositoryScenarioTransport(responses: [protobuf: [fixture]], statuses: [json: 403])
        do {
            _ = try await RepositoryClient(transport: forbidden).fetch(url: json)
            XCTFail("403 must not be hidden by a protobuf request")
        } catch { XCTAssertEqual((error as? SourceHTTPFailure)?.statusCode, 403) }
        let forbiddenRequests = await forbidden.requestedURLs()
        XCTAssertEqual(forbiddenRequests, [json])
    }

    func testModernMetadataReloadsOnceAndKeepsFirstHeader() async throws {
        let url = "https://example.invalid/repo/index.json"
        let transport = RepositoryScenarioTransport(responses: [url: [
            response(modernMetadata, at: url), response(modern.replacingOccurrences(of: #""name":"Modern""#, with: #""name":"New label""#), at: url)
        ]])
        let repository = try await RepositoryClient(transport: transport).fetch(url: url)
        XCTAssertEqual(repository.index.name, "Modern")
        XCTAssertEqual(repository.index.extensions.first?.packageName, "modern.source")
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [url, url])
    }

    func testMetadataOnlyDoesNotCreateAnEmptySuccessfulRepository() async throws {
        let url = "https://example.invalid/repo/index.json"
        let transport = RepositoryScenarioTransport(responses: [url: [
            response(modernMetadata, at: url), response(modernMetadata, at: url)
        ]])
        do {
            _ = try await RepositoryClient(transport: transport).fetch(url: url)
            XCTFail("Missing list after one reload must fail")
        } catch { XCTAssertTrue(error is ReaderFailure) }
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [url, url])
    }

    func testReloadCannotChangePublisherIdentity() async throws {
        let url = "https://example.invalid/repo/index.json"
        let changed = modern.replacingOccurrences(of: #""signingKey":"publisher""#, with: #""signingKey":"another""#)
        let transport = RepositoryScenarioTransport(responses: [url: [
            response(modernMetadata, at: url), response(changed, at: url)
        ]])
        do {
            _ = try await RepositoryClient(transport: transport).fetch(url: url)
            XCTFail("Reload must not bypass identity continuity")
        } catch { XCTAssertTrue(error is ReaderFailure) }
    }

    func testExternalListUsesFinalHTTPDocumentURLAndNestedResources() async throws {
        let index = "https://example.invalid/index.json"
        let list = "https://example.invalid/lists/index.json"
        let finalList = "https://cdn.example.invalid/releases/current/list.json"
        let header = #"{"name":"Separated","signingKey":"publisher","extensionListUrl":"lists/index.json"}"#
        let entries = #"{"extensions":[{"name":"Source","packageName":"nested.source","resources":{"jarUrl":"../jar/source.jar"}}]}"#
        let transport = RepositoryScenarioTransport(responses: [
            index: [response(header, at: index)], list: [response(entries, at: finalList)]
        ])
        let repository = try await RepositoryClient(transport: transport).fetch(url: index)
        XCTAssertEqual(repository.index.extensions.first?.jarURL, "https://cdn.example.invalid/releases/jar/source.jar")
    }

    func testMetadataIsNotMistakenForAnExternalEmptyList() throws {
        let data = Data(#"{"name":"No list","extensionListUrl":"somewhere.json"}"#.utf8)
        XCTAssertThrowsError(try RepositoryDecoder.decodeExternalList(data))
    }

    func testInsecureFinalHTTPURLStopsBeforeSiblingFallback() async throws {
        let url = "https://example.invalid/index.pb"
        let transport = RepositoryScenarioTransport(responses: [url: [response(modern, at: "http://example.invalid/index.json")]])
        do {
            _ = try await RepositoryClient(transport: transport).fetch(url: url)
            XCTFail("Final response URL must obey HTTPS policy")
        } catch { XCTAssertTrue(error is ReaderFailure) }
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests, [url])
    }
}

private actor RepositoryScenarioTransport: SourceTransport {
    private var responses: [String: [SourceHTTPResponse]]
    private let statuses: [String: Int]
    private var requests: [String] = []
    init(responses: [String: [SourceHTTPResponse]], statuses: [String: Int] = [:]) {
        self.responses = responses
        self.statuses = statuses
    }
    func get(_ url: URL) async throws -> Data { try await response(url).data }
    func response(_ url: URL) async throws -> SourceHTTPResponse {
        let key = url.absoluteString
        requests.append(key)
        if let status = statuses[key] { throw SourceHTTPFailure(statusCode: status, message: "Synthetic HTTP failure") }
        guard var sequence = responses[key], !sequence.isEmpty else { throw URLError(.fileDoesNotExist) }
        let result = sequence.removeFirst()
        responses[key] = sequence
        return result
    }
    func requestedURLs() -> [String] { requests }
}
