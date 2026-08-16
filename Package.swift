// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "arc-agent",

    platforms: [
        .macOS(.v15),
    ],

    dependencies: [
        .package(
            url: "https://github.com/swift-server/async-http-client.git",
            from: "1.21.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/tannerdsilva/QuickLMDB.git",
            from: "14.0.0"
        ),
    ],

    targets: [
        // ── Executable ────────────────────────────────────────────
        .executableTarget(
            name: "arc-agent",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "ArcAgentCore"),
            ]
        ),

        // ── Core library ──────────────────────────────────────────
        .target(
            name: "ArcAgentCore",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "QuickLMDB", package: "QuickLMDB"),
            ]
        ),

        // ── Tests ─────────────────────────────────────────────────
        .testTarget(
            name: "ArcAgentCoreTests",
            dependencies: [
                .target(name: "ArcAgentCore"),
            ]
        ),
    ]
)
