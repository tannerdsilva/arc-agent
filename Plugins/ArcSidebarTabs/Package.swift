// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ArcSidebarTabs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ArcSidebarTabs", targets: ["ArcSidebarTabs"]),
    ],
    targets: [
        .target(name: "ArcSidebarTabs"),
        .testTarget(
            name: "ArcSidebarTabsTests",
            dependencies: [.target(name: "ArcSidebarTabs")]
        ),
    ]
)
