// swift-tools-version: 6.3

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
		.package(
			url: "https://github.com/tannerdsilva/swift-mcp.git",
			"2.0.0"..<"3.0.0"
		),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.100.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            from: "2.37.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-extras.git",
            from: "1.26.0"
        ),
        .package(
            url: "https://github.com/apple/swift-http-types.git",
            from: "1.3.0"
        ),
        .package(
            url: "https://github.com/tannerdsilva/SwiftSlash.git",
            from: "5.0.1"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.0"
        ),
        // local co-development pin: the ../no-webui checkout carries the server
        // seams this migration needs (WebUIServerService, host assets, a
        // request-aware render, and server-initiated broadcast). swap back to
        // the remote pin once those land.
        .package(path: "../no-webui"),
    ],

    targets: [
        // ── Theme (shared with the asset tool) ────────────────────
        // arc's chrome stylesheet and the 27-scheme catalog live in their own target so the
        // build tool can render the whole sheet, hash it and gzip it at build time — the
        // served bytes are then a build product of the theme source, and the runtime neither
        // compresses nor hashes them. `public` because the macro mirrors the type's own
        // access and these cross a target boundary.
        .target(
            name: "ArcTheme",
            dependencies: [
                .product(name: "WebUI", package: "no-webui"),
                .product(name: "WebUIDesignSystem", package: "no-webui"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),

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
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "SwiftSlash", package: "SwiftSlash"),
            ],
            exclude: [
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5),
            ]
        ),

        // ── Web UI (merged from arc-agent-webui) ───────────────────
        .executableTarget(
            name: "arc-agent-webui",
            dependencies: [
                .target(name: "ArcTheme"),
                .target(name: "ArcAgentCore"),
                .product(name: "WebUI", package: "no-webui"),
                .product(name: "WebUIServer", package: "no-webui"),
                .product(name: "WebUIDesignSystem", package: "no-webui"),
                .product(name: "SwiftSlash", package: "SwiftSlash"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ArcAgentWebUI",
            exclude: [
                // Vendored KaTeX and the canonical client runtime live here as
                // plain files: the runtime is embedded by RuntimeAsset.swift,
                // and KaTeXAssets.swift is a build product of the plugin below.
                "Assets",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                "ArcAssetPlugin",
            ]
        ),

        // ── Asset codegen (build tool + plugin) ───────────────────
        // No shell script and no checked-in generated file: the tool is Swift
        // and the plugin runs it before every build of the web UI target, so
        // the embedded KaTeX asset is a build product of its input and cannot
        // drift from Assets/vendor/katex/.
        .executableTarget(
            name: "ArcAssetTool",
            dependencies: [
                .target(name: "ArcTheme"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .plugin(
            name: "ArcAssetPlugin",
            capability: .buildTool(),
            dependencies: [
                .target(name: "ArcAssetTool"),
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
        // The web UI is an executable target, so this test target depends on it
        // directly: the theme emission and the assembled page are the units under
        // test, and they are generated rather than hand-written.
        .testTarget(
            name: "ArcAgentWebUITests",
            dependencies: [
                .target(name: "arc-agent-webui"),
                .target(name: "ArcTheme"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)

// Library product so external packages (e.g. the no-webui-based webui) can
// embed ArcAgentCore in-process.
package.products = [
    .library(name: "ArcAgentCore", targets: ["ArcAgentCore"]),
    .executable(name: "arc-agent-webui", targets: ["arc-agent-webui"]),
]
