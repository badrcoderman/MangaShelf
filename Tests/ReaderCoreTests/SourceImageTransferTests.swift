import XCTest
import CryptoKit
@testable import ReaderCore

final class SourceImageTransferTests: XCTestCase {
    private let fileName = "f09b82fe-e25b-46a2-8d53-debe30d2dcb1.bin"
    private let bytes = Data([0, 1, 127, 255, 4, 0, 12])
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func response(name: String? = nil, count: Int? = nil, digest: String? = nil) throws -> String {
        let digest = digest ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fields: [String: Any] = ["fileName": name ?? fileName, "bytes": count ?? bytes.count, "sha256": digest]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }

    func testImageUsesSourceStateAndConsumesVerifiedBinaryFile() async throws {
        let directory = try root(), file = directory.appendingPathComponent(fileName)
        let body = bytes, descriptor = try response()
        let runtime = ExtensionRuntime(imageDirectory: directory, dispatchHandler: { action, payload in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(action, "image")
            let fields = try JSONDecoder().decode([String: String].self, from: Data(payload.utf8))
            XCTAssertEqual(fields, ["sourceId": "73", "sourceMetadataJSON": "raw-source-page"])
            try body.write(to: file)
            return descriptor
        })
        let result = try await SourceEngineCoordinator(runtime: runtime).fetchImage(sourceId: "73", sourceMetadataJSON: "raw-source-page")
        XCTAssertEqual(result, body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInvalidImageHashOrLengthRemovesTheHandoffFile() async throws {
        let directory = try root(), file = directory.appendingPathComponent(fileName)
        let body = bytes
        for descriptor in [try response(digest: String(repeating: "0", count: 64)), try response(count: bytes.count + 1)] {
            let runtime = ExtensionRuntime(imageDirectory: directory, dispatchHandler: { _, _ in
                try body.write(to: file)
                return descriptor
            })
            do { _ = try await runtime.image(sourceId: "73", sourceMetadataJSON: "raw"); XCTFail("Invalid image accepted") }
            catch { XCTAssertTrue(error is ReaderFailure) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testImageDescriptorCannotReadOrDeleteAnOutsideFileOrFollowASymlink() async throws {
        let parent = try root(), directory = parent.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("outside.bin")
        try bytes.write(to: outside)
        let link = directory.appendingPathComponent(fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for descriptor in [try response(name: "../outside.bin"), try response()] {
            let runtime = ExtensionRuntime(imageDirectory: directory, dispatchHandler: { _, _ in descriptor })
            do { _ = try await runtime.image(sourceId: "73", sourceMetadataJSON: "raw"); XCTFail("Outside image accepted") }
            catch { XCTAssertTrue(error is ReaderFailure) }
            XCTAssertEqual(try Data(contentsOf: outside), bytes)
        }
    }

    func testCancelledImageConsumesCommittedDescriptorAndDeletesItsFile() async throws {
        let directory = try root(), file = directory.appendingPathComponent(fileName)
        let body = bytes, descriptor = try response()
        let entered = expectation(description: "Image committed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let runtime = ExtensionRuntime(imageDirectory: directory, dispatchHandler: { _, _ in
            try body.write(to: file)
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw ReaderFailure("Authored image gate timed out") }
            return descriptor
        })
        let task = Task { try await runtime.image(sourceId: "73", sourceMetadataJSON: "raw") }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("Cancelled caller received image data") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
