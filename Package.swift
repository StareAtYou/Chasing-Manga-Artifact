// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChasingManga",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MangaCore", targets: ["MangaCore"]), .executable(name: "MangaChecks", targets: ["MangaChecks"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .target(name: "MangaCore", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "MangaPlatform", dependencies: ["MangaCore"]),
        .target(name: "MangaChecksSupport", dependencies: ["MangaCore", "MangaPlatform"], path: "Tests/Checks", resources: [.copy("Fixtures")]),
        .executableTarget(name: "MangaChecks", dependencies: ["MangaChecksSupport"], path: "Tests/PortableChecks"),
        .testTarget(name: "MangaCoreTests", dependencies: ["MangaCore", "MangaChecksSupport"]),
        .testTarget(name: "MangaPlatformTests", dependencies: ["MangaPlatform", "MangaChecksSupport"])
    ]
)
