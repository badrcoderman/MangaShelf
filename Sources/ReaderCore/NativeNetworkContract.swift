import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Independent implementation of the NativeNet wire contract. This does not start a JVM.
public struct NativeNetworkRequest: Codable, Sendable {
    public let url: String
    public let method: String
    public let headers: [String: String]?
    public let followRedirects: Bool?
    public let noCookie: Bool?

    public var allowsRedirects: Bool { followRedirects ?? true }
    public var allowsCookies: Bool { !(noCookie ?? false) }

    public static func decode(_ metadata: Data) throws -> Self {
        guard metadata.count <= 256 * 1024 else { throw NativeNetworkContractError.metadataTooLarge }
        return try JSONDecoder().decode(Self.self, from: metadata)
    }

    /// Body bytes are passed separately, as in NativeNet.call_utf8.
    /// The session delegate must independently enforce allowsRedirects on every redirect.
    public func urlRequest(body: Data?) throws -> URLRequest {
        guard let destination = URL(string: url),
              let scheme = destination.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = destination.host, !host.isEmpty,
              destination.user == nil, destination.password == nil else {
            throw NativeNetworkContractError.invalidURL
        }
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        guard !method.isEmpty, method.unicodeScalars.allSatisfy(token.contains) else {
            throw NativeNetworkContractError.invalidMethod
        }
        guard body.map({ $0.count <= 32 * 1024 * 1024 }) ?? true else {
            throw NativeNetworkContractError.bodyTooLarge
        }
        var request = URLRequest(url: destination, timeoutInterval: 60)
        request.httpMethod = method
        request.httpShouldHandleCookies = allowsCookies
        request.httpBody = body
        var seen = Set<String>()
        for (name, value) in headers ?? [:] {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains),
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }),
                  seen.insert(name.lowercased()).inserted else {
                throw NativeNetworkContractError.invalidHeader
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

public struct NativeNetworkResponse: Codable, Sendable {
    public let code: Int
    public let message: String?
    public let error: String?
    public let headers: [String: String]?
    public let currentUrl: String?

    public init(code: Int, message: String? = nil, error: String? = nil,
                headers: [String: String]? = nil, currentUrl: String? = nil) {
        self.code = code; self.message = message; self.error = error
        self.headers = headers; self.currentUrl = currentUrl
    }

    /// JNI returns metadata and response body as two distinct byte arrays.
    public func buffers(body: Data) throws -> [Data] {
        [try JSONEncoder().encode(self), body]
    }
}

public enum NativeNetworkContractError: Error, Equatable {
    case metadataTooLarge, invalidURL, invalidMethod, bodyTooLarge, invalidHeader
}
