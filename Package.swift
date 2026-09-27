// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCleaner",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CleanerCore"),
        .executableTarget(name: "MacCleaner", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
