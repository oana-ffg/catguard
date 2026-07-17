// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CatGuard",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "catguard", targets: ["CatGuardCLI"]),
        .library(name: "CatGuardCore", targets: ["CatGuardCore"]),
    ],
    targets: [
        .target(name: "CatGuardCore"),
        .executableTarget(
            name: "CatGuardCLI",
            dependencies: ["CatGuardCore"]
        ),
        .testTarget(
            name: "CatGuardCoreTests",
            dependencies: ["CatGuardCore"]
        ),
    ]
)
