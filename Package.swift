// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChasingManga",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MangaCore", targets: ["MangaCore"]), .executable(name: "MangaChecks", targets: ["MangaChecks"])],
    targets: [
        .target(name: "MangaCore"),
        .target(name: "MangaChecksSupport", dependencies: ["MangaCore"], path: "Tests/Checks"),
        .executableTarget(name: "MangaChecks", dependencies: ["MangaChecksSupport"], path: "Tests/PortableChecks"),
        .testTarget(name: "MangaCoreTests", dependencies: ["MangaCore", "MangaChecksSupport"])
    ]
)
