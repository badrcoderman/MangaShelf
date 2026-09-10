// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MangaShelf",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ReaderCore", targets: ["ReaderCore"])],
    targets: [
        .target(name: "CSafeArchive", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "ReaderCore", dependencies: ["CSafeArchive"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"], resources: [.copy("Fixtures")])
    ]
)
