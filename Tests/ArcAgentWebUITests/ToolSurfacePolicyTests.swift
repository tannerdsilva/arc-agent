import Testing
import Foundation
@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - tool and skill enablement is policy (settings backbone, slice 3)
//
// The tool/skill surface a session gets is `tools` in `~/.arc/config.json`,
// not a `settings.json` preference. Both surfaces — the web UI's per-turn
// agent and a daemon session — derive their surface from the same block, so
// they cannot disagree about which toolsets and skills a session may use.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("tool surface policy", .serialized)
    struct ToolSurfacePolicyTests {

        private static let preset = ModelConfigPreset(
            name: "surface-stub",
            model: "stub-model-1",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1"
        )

        private static func temporaryDirectory(_ label: String) -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-surface-\(label)-\(UUID().uuidString)", isDirectory: true)
        }

        /// Real skills on disk: discovery is the one call both surfaces make.
        private static func discoveredSkills() throws -> [Skill] {
            let dir = temporaryDirectory("skills")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["alpha", "beta", "gamma"] {
                let folder = dir.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let body = "---\nname: \(name)\ndescription: \(name) fixture\n---\n\n# \(name)\n"
                try Data(body.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            }
            return discoverSkills(in: dir)
        }

        private func state(_ arc: ArcConfig, skills: [Skill]) -> AppState {
            var f = AppState.RenderFixture()
            f.settings.workspaces = [WorkspaceEntry(
                name: "main", path: Self.temporaryDirectory("ws").path)]
            f.settings.activeWorkspace = "main"
            f.arcConfig = arc
            f.skills = skills
            return AppState(renderFixture: f)
        }

        // MARK: - the section

        @Test("the tools section decodes both disable lists")
        func decodesToolsSection() throws {
            let json = """
            {"tools":{"disabledToolsets":["browser"],"disabledSkills":["deploy"]}}
            """
            let arc = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
            #expect(arc.tools.disabledToolsets == ["browser"])
            #expect(arc.tools.disabledSkills == ["deploy"])
        }

        @Test("a missing tools section means nothing is disabled")
        func missingToolsSectionIsEmpty() throws {
            let arc = try JSONDecoder().decode(ArcConfig.self, from: Data("{}".utf8))
            #expect(arc.tools.disabledToolsets.isEmpty)
            #expect(arc.tools.disabledSkills.isEmpty)

            // and an empty object is the same statement.
            let partial = try JSONDecoder().decode(ArcConfig.self,
                                                   from: Data(#"{"tools":{}}"#.utf8))
            #expect(partial.tools == ToolsConfig())
        }

        @Test("a session's allowed skills are the discovered list minus the disabled ones")
        func allowedSkillsFiltersDiscovered() throws {
            let discovered = try Self.discoveredSkills()
            #expect(discovered.map(\.name) == ["alpha", "beta", "gamma"])

            var tools = ToolsConfig()
            tools.disabledSkills = ["beta"]
            #expect(tools.allowedSkills(from: discovered).map(\.name) == ["alpha", "gamma"])

            // a profile's override replaces the global list — it does not add
            // to it (the precedence the UI has always had).
            #expect(tools.allowedSkills(from: discovered, profileOverride: ["gamma"]).map(\.name)
                    == ["alpha", "beta"])
        }

        // MARK: - the agreement gate

        @Test("one ArcConfig: the UI turn agent and the daemon session get the same surface")
        func bothSurfacesAgree() async throws {
            let discovered = try Self.discoveredSkills()
            var arc = ArcConfig()
            arc.tools.disabledToolsets = ["browser", "cron"]
            arc.tools.disabledSkills = ["beta"]

            // the web UI's per-turn agent.
            let app = state(arc, skills: discovered)
            let (_, ui) = await app.makeTurnAgent(
                preset: Self.preset,
                thinking: "medium",
                headless: true,
                sessionID: "s-surface"
            )

            // exactly what ArcDaemon builds for its SessionRegistry…
            let daemon = SessionRegistry.AgentConfig(
                model: "m", provider: "p", baseURL: "http://127.0.0.1:9/v1",
                apiKey: "stub-key",
                disabledToolsets: arc.tools.disabledToolsetSet,
                skills: arc.tools.allowedSkills(from: discovered)
            )
            // …and the engine configuration SessionAgent assembles from it.
            let daemonConfig = SessionAgent.agentConfiguration(
                agentConfig: daemon,
                sessionID: "s-surface",
                registry: MutableToolRegistry(builtIn: CompileTimeToolRegistry()),
                sessionStore: VolatileSessionStore(),
                memoryProvider: FileMemoryProvider(),
                resolvedModel: "m",
                resolvedProvider: "p",
                resolvedBaseURL: URL(string: "http://127.0.0.1:9/v1")!,
                resolvedParams: nil,
                resolvedRecipe: ResolvedContextRecipe.resolve(global: nil, profile: nil, session: nil),
                profile: "default"
            )

            #expect(ui.skills.map(\.name) == ["alpha", "gamma"])
            #expect(daemonConfig.skills.map(\.name) == ui.skills.map(\.name),
                    "the daemon and the UI must carry the same skills for one config")
            #expect(daemonConfig.disabledToolsets == ui.disabledToolsets,
                    "the daemon and the UI must disable the same toolsets for one config")
            #expect(ui.disabledToolsets == Set(["browser", "cron"]))
        }

        @Test("a profile's skills override still beats the global list on the turn agent")
        func profileOverrideWinsOnTurnAgent() async throws {
            let discovered = try Self.discoveredSkills()
            var arc = ArcConfig()
            arc.tools.disabledToolsets = ["browser"]
            arc.tools.disabledSkills = ["alpha", "beta"]

            var f = AppState.RenderFixture()
            f.settings.workspaces = [WorkspaceEntry(
                name: "main", path: Self.temporaryDirectory("ws").path)]
            f.settings.activeWorkspace = "main"
            f.settings.sessionProfile["s-alpha"] = "alpha"
            // the profile disables only beta: the global list does not leak in.
            f.settings.profileSkills["alpha"] = ["beta"]
            f.arcConfig = arc
            f.skills = discovered
            let app = AppState(renderFixture: f)

            let (_, config) = await app.makeTurnAgent(
                preset: Self.preset, thinking: "medium",
                headless: true, sessionID: "s-alpha")

            #expect(config.skills.map(\.name) == ["alpha", "gamma"])
            #expect(config.disabledToolsets == Set(["browser"]))
        }

        // MARK: - the toggles write policy, not view state

        @Test("the toolset toggle writes config.tools")
        func toolsetToggleWritesConfig() async throws {
            let app = state(ArcConfig(), skills: [])

            await app.setToolset("terminal", enabled: false)
            var arc = await app.arcConfig
            #expect(arc.tools.disabledToolsets == ["terminal"])

            await app.setToolset("terminal", enabled: true)
            arc = await app.arcConfig
            #expect(arc.tools.disabledToolsets.isEmpty)

            // and the settings document carries no second copy of the toggle.
            let settings = await app.settings
            let text = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
            #expect(!text.contains("disabledToolsets"))
        }

        @Test("the skill toggle writes config.tools for the global context")
        func skillToggleWritesConfig() async throws {
            let app = state(ArcConfig(), skills: [])

            await app.toggleSkill("deploy", enable: false)
            let arc = await app.arcConfig
            #expect(arc.tools.disabledSkills == ["deploy"])

            let disabled = await app.skillContextDisabled()
            #expect(disabled == ["deploy"], "the panel reads the policy it just wrote")

            let settings = await app.settings
            let text = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
            #expect(!text.contains("disabledSkills"))
        }

        @Test("the tools panel renders the config's enablement")
        func toolsPanelReadsConfig() async throws {
            var arc = ArcConfig()
            arc.tools.disabledToolsets = ["terminal"]
            var f = AppState.RenderFixture()
            f.arcConfig = arc
            f.toolsets = [("terminal", [StubTool(name: "run_command", toolset: "terminal")])]
            let html = await AppState(renderFixture: f).toolsPanel().markup.html

            // the row's switch renders off; its title says the toolset is disabled.
            #expect(html.contains("Toolset disabled"))
            #expect(!html.contains("Toolset enabled"))
        }

        // MARK: - source shape

        @Test("SessionAgent never hardcodes an empty skill list")
        func sessionAgentNoEmptySkills() throws {
            let source = try String(contentsOfFile: "Sources/ArcAgentCore/Daemon/SessionAgent.swift",
                                    encoding: .utf8)
            #expect(!source.isEmpty)
            #expect(!source.contains("skills: []"),
                    "skills come from the AgentConfig, never a literal empty list")
            #expect(source.contains("skills: agentConfig.skills"))
            #expect(source.contains("disabledToolsets: agentConfig.disabledToolsets"))
        }

        @Test("ArcDaemon hands the config's tool policy to its session config")
        func daemonPassesToolPolicy() throws {
            let source = try String(contentsOfFile: "Sources/ArcDaemon/ArcDaemon.swift",
                                    encoding: .utf8)
            #expect(!source.isEmpty)
            #expect(source.contains("disabledToolsets: toolSurface.disabledToolsetSet"),
                    "ArcDaemon must pass the config's disabled toolsets")
            #expect(source.contains("skills: toolSurface.allowedSkills(from: discoverSkills())"),
                    "ArcDaemon must pass the discovered skills minus the config's disabled ones")
        }
    }

    @Suite("tool surface migration", .serialized)
    struct ToolSurfaceMigrationTests {

        /// A config file at a scratch path holding exactly `json` (nil = no file).
        private func configStore(_ json: String?) throws -> ConfigurationStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-surface-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            if let json { try Data(json.utf8).write(to: url) }
            return ConfigurationStore(url: url, environment: [:])
        }

        /// Settings decoded from exactly `json` — the shape an old
        /// `settings.json` has on disk.
        private func settings(_ json: String) throws -> AppSettings {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        }

        @Test("legacy settings keys lift into config.tools and are cleared")
        func liftsLegacyLists() async throws {
            let store = try configStore("{}")
            let configURL = await store.snapshot().url
            var s = try settings(#"{"disabledToolsets":["x"],"disabledSkills":["y"]}"#)

            let lift = await AppState.liftLegacyToolSurface(s, configStore: store)
            s = lift.settings

            let onDisk = await store.declared()
            #expect(lift.clearedLegacyKeys)
            #expect(lift.declared?.tools.disabledToolsets == ["x"])
            #expect(onDisk.tools.disabledToolsets == ["x"], "the lift is written through the store")
            #expect(onDisk.tools.disabledSkills == ["y"])
            #expect(s.disabledToolsets == nil, "the legacy key is cleared after the lift")
            #expect(s.disabledSkills == nil)

            let encoded = try JSONEncoder().encode(s)
            let text = String(decoding: encoded, as: UTF8.self)
            #expect(!text.contains("disabledToolsets"),
                    "a cleared legacy key must not be written back to settings.json")
            #expect(!text.contains("disabledSkills"))

            let written = try JSONDecoder().decode(ArcConfig.self,
                                                   from: Data(contentsOf: configURL))
            #expect(written.tools.disabledToolsets == ["x"])
        }

        @Test("a legacy list merges with what the file already disables")
        func mergesWithConfig() async throws {
            let store = try configStore(#"{"tools":{"disabledToolsets":["browser"],"disabledSkills":[]}}"#)
            var s = try settings(#"{"disabledToolsets":["x"],"disabledSkills":["y"]}"#)

            s = await AppState.liftLegacyToolSurface(s, configStore: store).settings

            let onDisk = await store.declared()
            #expect(onDisk.tools.disabledToolsets == ["browser", "x"])
            #expect(onDisk.tools.disabledSkills == ["y"])
            #expect(s.disabledToolsets == nil)
        }

        @Test("a legacy key equal to the config's value writes nothing")
        func equalValueIsNotAWrite() async throws {
            let store = try configStore(#"{"tools":{"disabledToolsets":["x"],"disabledSkills":["y"]}}"#)
            let configURL = await store.snapshot().url
            var s = try settings(#"{"disabledToolsets":["x"],"disabledSkills":["y"]}"#)

            let lift = await AppState.liftLegacyToolSurface(s, configStore: store)
            s = lift.settings

            #expect(lift.clearedLegacyKeys, "the settings key is still cleared")
            #expect(lift.declared == nil, "the target already equals the current value")
            #expect(!FileManager.default.fileExists(atPath: configURL.appendingPathExtension("bak").path),
                    "no backup means no write happened")
            #expect(s.disabledToolsets == nil)
        }

        @Test("a second boot after the lift writes nothing")
        func secondBootIsNoOp() async throws {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-surface-boot-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let configURL = home.appendingPathComponent("config.json")
            let settingsURL = home.appendingPathComponent("settings.json")
            try Data("{}".utf8).write(to: configURL)
            try Data(#"{"disabledToolsets":["x"],"disabledSkills":["y"],"theme":"dark"}"#.utf8)
                .write(to: settingsURL)
            let store = ConfigurationStore(url: configURL, environment: [:])

            // boot 1 — what `AppState.init` does: load, lift, persist.
            var settings = try SettingsStore.read(settingsURL)
            let first = await AppState.liftLegacyToolSurface(settings, configStore: store)
            settings = first.settings
            // write through the settings document, not `AppState.persist` —
            // that one addresses the process's real `~/.arc-agent-webui`.
            try SettingsStore.write(settings, to: settingsURL)
            #expect(first.clearedLegacyKeys)

            // the lift wrote once and backed the old file up; drop the backup so
            // any further write would recreate it.
            try FileManager.default.removeItem(at: configURL.appendingPathExtension("bak"))

            // boot 2 — the settings file no longer carries the legacy keys.
            var reloaded = try SettingsStore.read(settingsURL)
            #expect(reloaded.disabledToolsets == nil)
            #expect(reloaded.disabledSkills == nil)
            #expect(reloaded.theme == "dark", "the rest of the user's settings survive")
            let second = await AppState.liftLegacyToolSurface(reloaded, configStore: store)
            reloaded = second.settings

            #expect(second.clearedLegacyKeys == false)
            #expect(second.declared == nil)
            #expect(!FileManager.default.fileExists(atPath: configURL.appendingPathExtension("bak").path),
                    "the second boot must not write")
            let onDisk = await store.declared()
            #expect(onDisk.tools.disabledToolsets == ["x"])
            #expect(onDisk.tools.disabledSkills == ["y"])
        }

        @Test("a render fixture owns no store and migrates nothing")
        func noStoreNoWrite() async throws {
            var s = try settings(#"{"disabledToolsets":["x"],"disabledSkills":["y"]}"#)

            let lift = await AppState.liftLegacyToolSurface(s, configStore: nil)
            s = lift.settings

            #expect(lift.clearedLegacyKeys == false)
            #expect(lift.declared == nil)
            #expect(s.disabledToolsets == ["x"], "without a store the value stays in memory")
            #expect(s.disabledSkills == ["y"])
        }

        @Test("no legacy key means no read and no write")
        func absentKeysAreNoOp() async throws {
            let store = try configStore("{}")
            let s = try settings(#"{"theme":"dark"}"#)

            let lift = await AppState.liftLegacyToolSurface(s, configStore: store)

            #expect(lift.clearedLegacyKeys == false)
            #expect(lift.declared == nil)
            #expect(lift.settings == s)
        }
    }
}
