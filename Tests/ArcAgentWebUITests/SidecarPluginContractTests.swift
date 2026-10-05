import ArcSidebarTabs
import Foundation
import Testing
@testable import ArcWebUI

/// Sidecar (separate-process) sidebar plugins: the install layout, the
/// discovery rules, and the host-side adapters.
@Suite("Sidecar plugin wiring")
struct SidecarPluginContractTests {

    // MARK: Manifest

    @Test("manifest decodes with defaults for optional fields")
    func manifestDefaults() throws {
        let data = Data(#"{"name": "gh"}"#.utf8)
        let manifest = try JSONDecoder().decode(SidecarPluginManifest.self, from: data)
        #expect(manifest.name == "gh")
        #expect(manifest.version == nil)
        #expect(manifest.executable == nil)
        #expect(manifest.description == nil)
    }

    @Test("manifest tolerates a missing name (discovery rejects it later)")
    func manifestToleratesMissingName() {
        let data = Data(#"{"version": "1.0"}"#.utf8)
        let manifest = try? JSONDecoder().decode(SidecarPluginManifest.self, from: data)
        #expect(manifest?.name == nil)
        #expect(manifest?.version == "1.0")
    }

    // MARK: Tab descriptor wire shape

    @Test("descriptor round-trips through the wire decoder")
    func descriptorDecode() {
        let wire: SidecarValue = .obj([
            "id": .string("github"),
            "title": .string("GitHub"),
            "tooltip": .string("GitHub"),
            "iconKind": .string("named"),
            "iconA": .string("git-branch"),
            "iconB": .string(""),
        ])
        guard let desc = SidecarPluginManager.decodeDescriptor(wire) else {
            Issue.record("decoder returned nil for a well-formed descriptor")
            return
        }
        #expect(desc.id == "github")
        #expect(desc.iconKind == "named")
        let tab = SidecarPluginTab(descriptor: desc, connection: SidecarConnection(
            binary: "/nonexistent",
            hostHandler: { _, _ in .null }
        ))
        #expect(tab.id == "github")
        #expect(tab.title == "GitHub")
        #expect(tab.icon == SidebarTabIcon.named("git-branch"))
        #expect(tab.tooltip == "GitHub")
    }

    @Test("decoder rejects descriptors without id or icon kind")
    func descriptorRejects() {
        #expect(SidecarPluginManager.decodeDescriptor(.obj(["iconKind": .string("named")])) == nil)
        #expect(SidecarPluginManager.decodeDescriptor(.obj(["id": .string("x")])) == nil)
        #expect(SidecarPluginManager.decodeDescriptor(.string("nope")) == nil)
    }

    // MARK: Discovery rules

    @Test("plugins root lives under ~/.arc/plugins unless overridden")
    func pluginsRoot() {
        let old = SidecarPluginManager.testPluginsRoot
        defer { SidecarPluginManager.testPluginsRoot = old }
        SidecarPluginManager.testPluginsRoot = "/tmp/arc-test-plugins"
        #expect(SidecarPluginManager.pluginsRoot.path == "/tmp/arc-test-plugins")
    }

    @Test("discovery skips a directory without a valid manifest")
    func discoverySkipsMissingManifest() async {
        let old = SidecarPluginManager.testPluginsRoot
        defer { SidecarPluginManager.testPluginsRoot = old }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-sidecar-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("no-manifest"), withIntermediateDirectories: true)
        SidecarPluginManager.testPluginsRoot = root.path
        let manager = SidecarPluginManager()
        let plugins = await manager.discover()
        #expect(plugins.isEmpty)
        await manager.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Source contracts

    @Test("host adapters exist and route through the sidecar protocol")
    func hostAdapters() {
        let src = Self.source("SidecarPlugin.swift")
        #expect(src.contains("public actor SidecarConnection"))
        #expect(src.contains("func call(_ method: String, params: SidecarValue? = nil)"))
        #expect(src.contains("public struct SidecarPluginTab: SidebarTab"))
        #expect(src.contains("public struct SidecarPluginClient: SidebarTabPlugin"))
        #expect(src.contains("SidecarMethod.render"))
        #expect(src.contains("SidecarMethod.dispatchEvent"))
        #expect(src.contains("SidecarMethod.install"))
        #expect(src.contains("SidecarMethod.activate"))
        let manager = Self.source("SidecarPluginManager.swift")
        #expect(manager.contains("func discover() async"))
        #expect(manager.contains(".arc/plugins"))
        #expect(manager.contains("manifest.json"))
        #expect(manager.contains("func shutdown()"))
        #expect(manager.contains("public struct SidecarPluginService: Service"))
        #expect(manager.contains("runUntilShutdown"))
    }

    @Test("the root package no longer pins the GitHub plugin")
    func rootPackageDecoupled() {
        let pkg = (try? String(contentsOfFile: "Package.swift", encoding: .utf8)) ?? ""
        #expect(!pkg.contains("Plugins/GitHubSidebarTab"))
        #expect(pkg.contains("Plugins/ArcSidebarTabs"))
    }

    private static func source(_ name: String) -> String {
        (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
    }
}
