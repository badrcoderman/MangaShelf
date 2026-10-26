import Foundation

/// Only known categories, HTTP status and numeric retry delays enter reports. Remote exception text,
/// URLs, headers and response bodies are never included.
public struct SourceRequestFailure: LocalizedError, Sendable {
    public enum Reason: String, Sendable {
        case http = "source_http_error"
        case browserVerification = "source_browser_verification"
        case tls = "source_tls_failed"
        case network = "source_network_failed"
        case timeout = "source_timeout"
        case dependency = "source_dependency_failed"
        case invalidResponse = "invalid_response"
        case responseLimit = "response_limit"
        case imageStorage = "image_storage_failed"
        case imageTransferLimit = "image_transfer_limit"
        case imageTransport = "unsupported_image_source"
    }
    public let reason: Reason
    public let httpStatus: Int?
    public let retryAfterSeconds: TimeInterval?
    public init(reason: Reason, httpStatus: Int? = nil, retryAfterSeconds: TimeInterval? = nil) {
        self.retryAfterSeconds = retryAfterSeconds.flatMap { $0.isFinite && $0 >= 0 && $0 <= 3_153_600_000 ? $0 : nil }
        self.reason = reason
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    }
    public var errorDescription: String? {
        switch reason {
        case .http:
            if let httpStatus { return ReaderText.format("The source returned HTTP %@. Try again or check the source website.", String(httpStatus)) }
            return ReaderText.string("The source request failed. Try again.")
        case .browserVerification:
            return ReaderText.string("This source requires browser verification, which MSL does not support yet.")
        case .tls:
            return ReaderText.string("The secure connection to this source failed.")
        case .timeout:
            return ReaderText.string("The source took too long to respond. Try again.")
        case .network:
            return ReaderText.string("Could not connect to this source. Check your connection and try again.")
        case .dependency:
            return ReaderText.string("This extension needs a host API that MSL does not support yet.")
        case .invalidResponse:
            return ReaderText.string("The source returned data MSL could not read. Update the extension and try again.")
        case .responseLimit:
            return ReaderText.string("The source response exceeded the supported size.")
        case .imageStorage:
            return ReaderText.string("Could not store the source image. Check available storage and try again.")
        case .imageTransferLimit:
            return ReaderText.string("Too many source images are waiting to be read. Try again shortly.")
        case .imageTransport:
            return ReaderText.string("This source uses an image transport MSL does not support yet.")
        }
    }
}
