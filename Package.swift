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
	.package(
		url: "https://github.com/tannerdsilva/no-webui.git",
		revision: "61b8bddc5907094e0c087f288f105933f5bd9089"
	)
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
                .target(name: "ArcDaemon"),
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
                // the signal type names in `HTTPServerService`'s initializer.
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
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

        // ── Daemon (the single composition root) ──────────────────
        // One ServiceGroup assembled from DaemonPlan; `arc serve` and the web
        // UI host both ride this. Core stays UI-free: the daemon links both
        // libraries.
        .target(
            name: "ArcDaemon",
            dependencies: [
                .target(name: "ArcAgentCore"),
                // the UI host mounts here (phase 2); core stays UI-free.
                .target(name: "ArcWebUI"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),

        // ── Web UI library (the UI surfaces; mounted by the daemon or the shim) ──
        .target(
            name: "ArcWebUI",
            dependencies: [
                .target(name: "ArcTheme"),
                .target(name: "ArcAgentCore"),
                .product(name: "WebUI", package: "no-webui"),
                .product(name: "WebUIServer", package: "no-webui"),
                .product(name: "WebUIDesignSystem", package: "no-webui"),
                // the shipped-asset protocol the generated ThemeSheetAssets conforms to.
                .product(name: "WebUICore", package: "no-webui"),
                .product(name: "SwiftSlash", package: "SwiftSlash"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ArcWebUI",
            exclude: [
                // Assets/ is consumed by WebUIEmbedPlugin, not compiled: excluding it keeps
                // SwiftPM from warning about files it does not know how to handle (the plugin
                // reads them through its own context, which exclusion does not affect).
                "Assets",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                "ArcAssetPlugin",
                // the file half: every build re-embeds Assets/webui-assets.json's files as
                // generated declarations the server feeds to WebUIAsset.
                .plugin(name: "WebUIEmbedPlugin", package: "no-webui"),
            ]
        ),

        // ── Asset codegen (build tool + plugin) ───────────────────
        // No shell script and no checked-in generated file: the tool is Swift
        // and the plugin runs it before every build of the web UI target, so
        // the embedded theme sheet is a build product of Sources/ArcTheme/ and
        // cannot drift from it. The overlay's file rides the framework's embed
        // plugin (no-webui's WebUIEmbedPlugin) for the same reason.
        .executableTarget(
            name: "ArcAssetTool",
            dependencies: [
                .target(name: "ArcTheme"),
                // the framework's build library: the tool emits through it, so the
                // address/gzip/escaping rules exist once and arc owns none of them.
                .product(name: "WebUIBuild", package: "no-webui"),
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
                // the shutdown-contract test builds a real ServiceGroup.
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),

        // The daemon composition matrix: plan resolution is pure, so these
        // tests bind nothing.
        .testTarget(
            name: "ArcDaemonTests",
            dependencies: [
                .target(name: "ArcDaemon"),
                .target(name: "ArcAgentCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),

        // The web UI under test is the ArcWebUI library (the shim is a shell): the
        // theme emission and the assembled page are the units under test, and they
        // are generated rather than hand-written.
        .testTarget(
            name: "ArcAgentWebUITests",
            dependencies: [
                .target(name: "ArcWebUI"),
                .target(name: "ArcTheme"),
                // the cron-store migration test constructs a FileCronStore.
                .target(name: "ArcAgentCore"),
                // the minifier the emitted sheet goes through: the drift test compares the
                // product against `minifyCSS(source)`.
                .product(name: "WebUICore", package: "no-webui"),
            ],
            resources: [
                // the palette pins: the values the painted sheet must still hold, extracted
                // from the verified sheet and re-read by the test on every run.
                .copy("Fixtures"),
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
    // The one CLI: chat/batch/serve (the daemon that hosts the web UI).
    .executable(name: "arc", targets: ["arc-agent"]),
]

