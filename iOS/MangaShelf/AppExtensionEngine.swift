import Foundation
import CryptoKit
import ReaderCore

/// Owns the process VM startup task. UI cancellation cannot abandon VM creation.
actor AppExtensionEngine {
    static let shared = AppExtensionEngine()

    struct Configuration: Sendable, Equatable {
        let directory: URL
        let temporaryDirectory: URL
        let applicationID: String
        let versionName: String
        let versionCode: Int
        let platformRelease: String
    }

    private struct Manifest: Decodable {
        struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
        let format: Int
        let backendClass: String
        let backendMethod: String
        let javaHome: String
        let classpath: [String]
        let files: [File]
        enum CodingKeys: String, CodingKey {
            case format, classpath, files
            case backendClass = "backend_class", backendMethod = "backend_method", javaHome = "java_home"
        }
    }

    private var started: Task<Void, Error>?
    private var configuration: Configuration?

    func prepare(_ requested: Configuration) async throws {
        if let configuration, configuration != requested {
            throw ReaderFailure(L10n.string("The extension engine could not start. Reopen the app and try again."))
        }
        if let started { return try await started.value }
        configuration = requested
        let startup = Task.detached(priority: .userInitiated) {
            guard ms_app_engine_is_compiled() != 0, let root = Bundle.main.resourceURL else {
                throw ReaderFailure(L10n.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet."))
            }
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            func resource(_ path: String) throws -> URL {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                      !path.contains(":"), !path.contains("\\"), path.utf8.count <= 4096 else {
                    throw ReaderFailure(L10n.string("The extension runtime returned an invalid response."))
                }
                let url = canonical.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard url.path.hasPrefix(canonical.path + "/") else {
                    throw ReaderFailure(L10n.string("The extension runtime returned an invalid response."))
                }
                return url
            }
            let manifestURL = try resource("engine/manifest.json")
            let manifestData = try Data(contentsOf: manifestURL)
            guard manifestData.count <= 1024 * 1024 else {
                throw ReaderFailure(L10n.string("The extension runtime returned an invalid response."))
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.format == 1, manifest.backendClass == "mangashelf/host/SourceRuntime", manifest.backendMethod == "dispatch",
                  manifest.javaHome == "lib", !manifest.classpath.isEmpty, manifest.classpath.count <= 64,
                  Set(manifest.classpath).count == manifest.classpath.count,
                  manifest.files.count <= 2000, Set(manifest.files.map(\.path)).count == manifest.files.count else {
                throw ReaderFailure(L10n.string("The extension runtime returned an invalid response."))
            }
            let listed = Set(manifest.files.map(\.path))
            guard Set(manifest.classpath).isSubset(of: listed), listed.contains("lib/lib/modules"),
                  manifest.classpath.first == "engine/runtime-host.jar",
                  manifest.classpath.allSatisfy({ $0.hasPrefix("engine/") && $0.hasSuffix(".jar") }) else {
                throw ReaderFailure(L10n.string("The extension runtime returned an invalid response."))
            }
            for file in manifest.files {
                guard file.bytes >= 0, file.bytes <= 128 * 1024 * 1024 else {
                    throw ReaderFailure(L10n.string("The extension runtime returned an invalid response."))
                }
                let url = try resource(file.path)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size == file.bytes else { throw ReaderFailure(L10n.string("The extension runtime returned an invalid response.")) }
                let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw ReaderFailure(L10n.string("The extension runtime returned an invalid response."))
                }
            }
            try FileManager.default.createDirectory(at: requested.directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: requested.temporaryDirectory, withIntermediateDirectories: true)
            let home = try resource(manifest.javaHome)
            let classpath = try manifest.classpath.map { try resource($0).path }.joined(separator: ":")
            let status = ms_app_engine_start(home.path, classpath, requested.temporaryDirectory.path)
            guard status == 0 else {
                await MainActor.run {
                    DiagnosticsCenter.shared.record(L10n.string("Extension engine"), L10n.format("Engine startup failed with code %@.", String(status)))
                }
                throw ReaderFailure(L10n.string("The extension engine could not start. Reopen the app and try again."))
            }
            try await ExtensionRuntime.shared.configureHost(dataDirectory: requested.directory, applicationID: requested.applicationID,
                versionName: requested.versionName, versionCode: requested.versionCode,
                userAgent: "MangaShelf/\(requested.versionName) (\(requested.versionCode))", platformRelease: requested.platformRelease)
            await MainActor.run { DiagnosticsCenter.shared.record(L10n.string("Extension engine"), L10n.string("Extension engine started")) }
        }
        started = startup
        try await startup.value
    }
}
