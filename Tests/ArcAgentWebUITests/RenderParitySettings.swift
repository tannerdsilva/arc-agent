import Testing
import Foundation
@testable import ArcWebUI
import ArcAgentCore

/// phase 5 goldens: captured from the LEGACY builders before conversion, so
/// every later typed rewrite is held to byte parity with what shipped.
@Suite("render parity — settings")
struct RenderParitySettings {

    private func app(_ configure: (inout AppState.RenderFixture) -> Void = { _ in }) -> AppState {
        var fixture = AppState.RenderFixture()
        fixture.settings.theme = "light"
        configure(&fixture)
        return AppState(renderFixture: fixture)
    }

    // MARK: - nav + whole page

    @Test("settings panel matches golden")
    func settingsPanelGolden() async {
        let html = await app().settingsPanel().markup.html
        Parity.capture(html, as: "settings-panel")
        Parity.expect(html, matches: "settings-panel")
    }

    @Test("settings main matches golden")
    func settingsMainGolden() async {
        let html = await app().settingsMain()
        Parity.capture(html, as: "settings-main")
        Parity.expect(html, matches: "settings-main")
    }

    @Test("settings main in a dark scheme matches golden")
    func settingsMainDarkGolden() async {
        let html = await app { $0.settings.theme = "dark" }.settingsMain()
        Parity.capture(html, as: "settings-main-dark")
        Parity.expect(html, matches: "settings-main-dark")
    }

    // MARK: - agent limits / powers

    @Test("agent limits matches golden")
    func agentLimitsGolden() async {
        let html = await app().agentLimitsSection().markup.html
        Parity.capture(html, as: "agent-limits")
        Parity.expect(html, matches: "agent-limits")
    }

    @Test("agent limits with unlimited iterations matches golden")
    func agentLimitsUnlimitedGolden() async {
        let html = await app { $0.arcConfig.agent.max_turns = 0 }.agentLimitsSection().markup.html
        Parity.capture(html, as: "agent-limits-unlimited")
        Parity.expect(html, matches: "agent-limits-unlimited")
    }

    @Test("agent powers with locks matches golden")
    func agentPowersGolden() async {
        let html = await app {
            $0.skills = [
                Skill(name: "deploy", description: "Ship a build", content: "", tags: [],
                      category: nil, path: URL(fileURLWithPath: "/tmp/deploy")),
                Skill(name: "migrate", description: "Run migrations", content: "", tags: [],
                      category: nil, path: URL(fileURLWithPath: "/tmp/migrate")),
            ]
            $0.arcConfig.agentPowers.skillsManage = true
            $0.arcConfig.agentPowers.lockedSkills = ["deploy", "migrate"]
            $0.arcConfig.agentPowers.profileEdit = true
            $0.arcConfig.agentPowers.lockedProfileFiles = ["memory"]
        }.agentPowersSection().markup.html
        Parity.capture(html, as: "agent-powers-locked")
        Parity.expect(html, matches: "agent-powers-locked")
    }

    // MARK: - storage

    @Test("file storage matches golden")
    func storageFileGolden() async {
        let html = await app { $0.settings.activeStorage = "file" }.storageSettingsHTML()
        Parity.capture(html, as: "storage-file")
        Parity.expect(html, matches: "storage-file")
    }

    @Test("tessera storage matches golden")
    func storageTesseraGolden() async {
        let conn = TesseraStorageConnection(
            id: "conn-1", name: "Home node", serverIP: "10.0.0.5", serverPort: 51921,
            application: 7, serverPublicKey: "npub1examplepublickey",
            myPrivateKey: "nsec1exampleprivatekey")
        let html = await app {
            $0.settings.storageConnections = [conn]
            $0.settings.activeStorage = "conn-1"
        }.storageSettingsHTML()
        Parity.capture(html, as: "storage-tessera")
        Parity.expect(html, matches: "storage-tessera")
    }

    @Test("incomplete storage shows the completeness note")
    func storageIncompleteGolden() async {
        let conn = TesseraStorageConnection(
            id: "conn-2", name: "", serverIP: "", serverPort: 51921,
            application: 1, serverPublicKey: "", myPrivateKey: "")
        let html = await app {
            $0.settings.storageConnections = [conn]
            $0.settings.activeStorage = "conn-2"
        }.storageSettingsHTML()
        Parity.capture(html, as: "storage-incomplete")
        Parity.expect(html, matches: "storage-incomplete")
    }

    // MARK: - MCP + plugins

    @Test("three MCP servers match golden")
    func settingsMCPThreeGolden() async {
        let html = await app {
            $0.arcConfig.mcpServers = [
                "filesystem": MCPServerConfig(command: "npx", args: ["-y", "@mcp/fs", "/tmp"]),
                "github": MCPServerConfig(command: "gh-mcp", args: ["serve"], env: ["TOKEN": "x"]),
                "postgres": MCPServerConfig(command: "pg-mcp", args: [], timeout: 120),
            ]
        }.settingsMain()
        Parity.capture(html, as: "settings-mcp-three")
        Parity.expect(html, matches: "settings-mcp-three")
    }

    @Test("MCP form matches golden")
    func mcpFormGolden() async {
        let html = await app().mcpFormHTML()
        Parity.capture(html, as: "mcp-form")
        Parity.expect(html, matches: "mcp-form")
    }

    @Test("plugin settings match golden")
    func pluginSettingsGolden() async {
        let html = await app().pluginSettingsHTML()
        Parity.capture(html, as: "settings-plugins")
        Parity.expect(html, matches: "settings-plugins")
    }

    @Test("sidebar plugin settings match golden")
    func sidebarPluginsGolden() async {
        let html = await app().sidebarPluginsSettingsHTML()
        Parity.capture(html, as: "settings-sidebar-plugins")
        Parity.expect(html, matches: "settings-sidebar-plugins")
    }

    @Test("running and failed plugins match goldens")
    func pluginStatusGoldens() async {
        let manifests: [String: PluginManifest] = [
            "formatter": PluginManifest(
                name: "formatter", version: "1.2.0",
                description: "Formats things",
                tools: [.init(name: "format_json", description: "Format JSON",
                              command: "./fmt")]),
            "broken": PluginManifest(
                name: "broken", version: "0.0.1",
                description: "Breaks",
                tools: [.init(name: "explode", description: "Explode",
                              command: "./boom")]),
        ]
        let app = app {
            $0.pluginManifests = manifests
            $0.pluginStartupOutcome = ["broken": "exit status 1: permission denied"]
            $0.arcConfig.plugins.enabled = ["formatter"]
        }
        let running = await app.pluginSettingsHTML()
        Parity.capture(running, as: "settings-plugins-status")
        Parity.expect(running, matches: "settings-plugins-status")
    }

    // MARK: - schema + small fragments

    @Test("simple schema matches golden")
    func schemaSimpleGolden() async {
        let schema = JSONSchema.object(
            description: "Search parameters",
            properties: [
                "query": .string(description: "What to search for"),
                "limit": .integer(description: "Max results"),
            ],
            required: ["query"])
        let html = await app().schemaHTML(schema).markup.html
        Parity.capture(html, as: "schema-simple")
        Parity.expect(html, matches: "schema-simple")
    }

    @Test("nested schema matches golden")
    func schemaNestedGolden() async {
        let schema = JSONSchema.object(
            description: nil,
            properties: [
                "filter": .object(description: "Filter block",
                                  properties: ["tag": .string(description: "tag name")],
                                  required: []),
                "ids": .array(description: "Identifiers", items: .string(description: "an id")),
                "mode": .enum(description: "Mode", values: ["fast", "thorough"]),
            ],
            required: ["ids"])
        let html = await app().schemaHTML(schema).markup.html
        Parity.capture(html, as: "schema-nested")
        Parity.expect(html, matches: "schema-nested")
    }

    @Test("effort options match golden")
    func effortOptionsGolden() async {
        let html = AppState.effortOptions(selected: "high")
        Parity.capture(html, as: "effort-options")
        Parity.expect(html, matches: "effort-options")
    }
}