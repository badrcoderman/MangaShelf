import XCTest
@testable import ReaderCore

final class NativeNetworkContractTests: XCTestCase {
    func testUpstreamRequestAndSeparateBody() throws {
        let data = Data(#"{"url":"https://example.com/chapter","method":"POST","headers":{"Content-Type":"application/json"},"followRedirects":false,"noCookie":true}"#.utf8)
        let metadata = try NativeNetworkRequest.decode(data)
        let body = Data("{}".utf8)
        let request = try metadata.urlRequest(body: body)
        XCTAssertFalse(metadata.allowsRedirects)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testNullBooleanDefaults() throws {
        let metadata = try NativeNetworkRequest.decode(Data(#"{"url":"https://example.com","method":"GET","followRedirects":null,"noCookie":null}"#.utf8))
        XCTAssertTrue(metadata.allowsCookies)
        XCTAssertTrue(metadata.allowsRedirects)
    }

    func testRejectNonNetworkURLAndHeaderLineBreak() throws {
        for json in [
            #"{"url":"file:///tmp/book","method":"GET"}"#,
            #"{"url":"https://example.com","method":"GET","headers":{"X-Test":"a\r\nb"}}"#,
            #"{"url":"https://example.com","method":"GET","headers":{"X-Test":"a","x-test":"b"}}"#
        ] {
            XCTAssertThrowsError(try NativeNetworkRequest.decode(Data(json.utf8)).urlRequest(body: nil))
        }
    }

    func testResponseBodyIsNotEmbeddedInMetadata() throws {
        let body = Data([0, 255, 42])
        let buffers = try NativeNetworkResponse(code: 200, currentUrl: "https://example.com/final").buffers(body: body)
        XCTAssertEqual(buffers.count, 2)
        XCTAssertEqual(buffers[1], body)
        let metadata = try JSONDecoder().decode(NativeNetworkResponse.self, from: buffers[0])
        XCTAssertEqual(metadata.code, 200)
        XCTAssertEqual(metadata.currentUrl, "https://example.com/final")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: buffers[0]) as? [String: Any])
        XCTAssertNil(object["byteBuffer"])
    }
}
