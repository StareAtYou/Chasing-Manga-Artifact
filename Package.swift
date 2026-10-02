// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChasingManga",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MangaCore", targets: ["MangaCore"]), .library(name: "MangaUI", targets: ["MangaUI"]), .executable(name: "MangaChecks", targets: ["MangaChecks"]), .executable(name: "SourceProbe", targets: ["SourceProbe"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .target(name: "MangaUI", dependencies: ["MangaCore", "MangaPlatform"]),
        .target(name: "MangaCore", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "MangaPlatform", dependencies: ["MangaCore"]),
        .executableTarget(name: "SourceProbe", dependencies: ["MangaCore", "MangaPlatform"], path: "Tools/SourceProbe"),
        .target(name: "MangaChecksSupport", dependencies: ["MangaCore", "MangaPlatform"], path: "Tests/Checks", resources: [.copy("Fixtures")]),
        .executableTarget(name: "MangaChecks", dependencies: ["MangaChecksSupport"], path: "Tests/PortableChecks"),
        .testTarget(name: "MangaCoreTests", dependencies: ["MangaCore", "MangaChecksSupport"]),
        .testTarget(name: "MangaPlatformTests", dependencies: ["MangaPlatform", "MangaChecksSupport"])
    ]
)
