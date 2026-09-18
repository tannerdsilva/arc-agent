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
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/apple/swift-system.git",
            from: "1.4.0"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.6.0"
        ),
        .package(path: "../tessera"),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.0.0"
        ),
		.package(path: "../swift-mcp"),
		.package(path: "../no-webui"),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.100.0"
        ),
    ],

    targets: [
        // ── Executable ────────────────────────────────────────────
        .executableTarget(
            name: "arc-agent",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "ArcAgentCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),

        // ── Core library ──────────────────────────────────────────
        .target(
            name: "ArcAgentCore",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "tessera-client", package: "tessera"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdRouter", package: "hummingbird"),
                .product(name: "MCP", package: "swift-mcp"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "WebUI", package: "no-webui"),
                .product(name: "WebUIDesignSystem", package: "no-webui"),
                .product(name: "WebUIAuth", package: "no-webui"),
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5),
            ]
        ),

        // ── Tests ─────────────────────────────────────────────────
        .testTarget(
            name: "ArcAgentCoreTests",
            dependencies: [
                .target(name: "ArcAgentCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)

// Library product so an external SwiftUI frontend can embed ArcAgentCore
// in-process.
package.products = [
    .library(name: "ArcAgentCore", targets: ["ArcAgentCore"]),
]
