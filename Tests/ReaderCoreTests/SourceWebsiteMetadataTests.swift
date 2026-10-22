import XCTest
import CryptoKit
@testable import ReaderCore

final class SourceWebsiteMetadataTests: XCTestCase {
    private func data(home: String, jar: String = "https://example.org/source.jar",
                      icon: String = "https://example.org/icon.png") throws -> Data {
        try JSONSerialization.data(withJSONObject: [[
            "name": "Fixture", "pkg": "com.example.fixture", "jarUrl": jar, "iconUrl": icon,
            "sources": [["id": "123", "name": "Fixture", "lang": "en", "baseUrl": home]]
        ]])
    }

    func testHTTPSourceWebsiteMetadataDoesNotRejectSecureStore() throws {
        for home in ["http://example.org", "http://example.org:8080/reader", "https://example.org:8443"] {
            let index = try RepositoryDecoder.decode(data(home: home))
            XCTAssertEqual(index.extensions.first?.sources.first?.homeURL, home)
            XCTAssertNoThrow(try index.validate())
        }
    }

    func testSourceWebsiteRequiresAbsoluteWebURLWithoutCredentials() throws {
        for home in ["", "/relative", "file:///tmp/source", "javascript:alert(1)", "ftp://example.org",
                     "https:///path", "http://user:pass@example.org", "http://example.org:70000",
                     "http://example.org/has space", "http://example.org/\n", "http://example.org/\0"] {
            XCTAssertThrowsError(try RepositoryDecoder.decode(data(home: home)), home)
        }
    }

    func testPackageAndIconURLsStillRequireHTTPS() throws {
        XCTAssertThrowsError(try RepositoryDecoder.decode(data(home: "http://example.org", jar: "http://example.org/source.jar")))
        XCTAssertThrowsError(try RepositoryDecoder.decode(data(home: "http://example.org", icon: "http://example.org/icon.png")))
    }

    func testPinnedKeiyoushiJSONAndGzipProtobufDecodeConsistently() throws {
        guard let directory = ProcessInfo.processInfo.environment["MSL_REFERENCE_INDEX_DIR"] else {
            throw XCTSkip("Set MSL_REFERENCE_INDEX_DIR using the pinned repository download helper.")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let json = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let protobuf = try Data(contentsOf: root.appendingPathComponent("index.pb"))
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(sha(json), "567c190d85020531f9a71a2cf3148a8e23face92dacb5787f3081ab8d788c722")
        XCTAssertEqual(sha(protobuf), "c0ef5ec28b646dbce0064210c05004a4cdbbce01f5f4711999da4463543eea68")
        let a = try RepositoryDecoder.decode(json), b = try RepositoryDecoder.decode(protobuf)
        XCTAssertEqual(a.name, "Keiyoushi")
        XCTAssertEqual(a.name, b.name)
        XCTAssertEqual(a.signingKey, b.signingKey)
        XCTAssertEqual(a.extensionListURL, b.extensionListURL)
        XCTAssertEqual(a.hasEmbeddedList, b.hasEmbeddedList)
        XCTAssertEqual(a.extensions.count, 1420)
        XCTAssertEqual(a.extensions, b.extensions)
        XCTAssertEqual(a.extensions.flatMap(\.sources).count, 2393)
        let httpSources = a.extensions.flatMap(\.sources).filter { $0.homeURL?.hasPrefix("http://") == true }
        XCTAssertEqual(httpSources.count, 9)
        let mangaDex = try XCTUnwrap(a.extensions.first { $0.packageName == "eu.kanade.tachiyomi.extension.all.mangadex" })
        XCTAssertEqual(mangaDex.sources.count, 61)
        XCTAssertEqual(mangaDex.sources.first { $0.language == "ar" }?.id, "3339599426223341161")
        XCTAssertEqual(mangaDex.sources.first { $0.language == "en" }?.id, "2499283573021220255")
        XCTAssertEqual(mangaDex.jarURL, "https://github.com/keiyoushi/extensions/releases/download/f303b9c/tachiyomi-all.mangadex-v1.6.0.jar")
    }
}
