// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "GitHubSidebarTab",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GitHubSidebarTab", targets: ["GitHubSidebarTab"]),
    ],
    dependencies: [
        .package(path: "../ArcSidebarTabs"),
        .package(url: "https://github.com/tannerdsilva/SwiftSlash.git", from: "5.0.1"),
        .package(
            url: "https://github.com/tannerdsilva/no-webui.git",
            revision: "61b8bddc5907094e0c087f288f105933f5bd9089"
        ),
    ],
    targets: [
        .target(
            name: "GitHubSidebarTab",
            dependencies: [
                .product(name: "ArcSidebarTabs", package: "ArcSidebarTabs"),
                .product(name: "SwiftSlash", package: "SwiftSlash"),
                .product(name: "WebUI", package: "no-webui"),
            ]
        ),
    ]
)
