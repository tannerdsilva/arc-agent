import Testing
import Foundation
@testable import ArcAgentCore
@testable import ArcWebUI

/// Settings storage is instance-scoped: `ArcHome.webUISettings` relocates to
/// `<ARC_HOME>/webui/settings.json` when `ARC_HOME` is set, so a second daemon
/// instance no longer clobbers the shared `~/.arc-agent-webui/settings.json`
/// with its stale in-memory copy. The one-time seed lets a fresh relocated
/// instance inherit the shared settings, then diverge.
@Suite("Instance-Scoped Web UI Settings")
struct InstanceScopedSettingsTests {

    @Test("Relocated instance seeds once from the shared file")
    func seedsOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-inst-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = dir.appendingPathComponent("shared/settings.json")
        let target = dir.appendingPathComponent("home/webui/settings.json")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{\"theme\":\"dark\"}".utf8).write(to: shared)

        let seeded = AppState.seedSharedSettingsIfNeeded(
            target: target, shared: shared, relocated: true)

        #expect(seeded)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: target))["theme"] == "dark")

        // A second seed attempt must not overwrite what the instance saved.
        try Data("{\"theme\":\"light\"}".utf8).write(to: target)
        #expect(!AppState.seedSharedSettingsIfNeeded(
            target: target, shared: shared, relocated: true))
        #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: target))["theme"] == "light")
    }

    @Test("Default instance is never seeded (same path, no copy)")
    func defaultInstanceUntouched() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-inst-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = dir.appendingPathComponent("shared/settings.json")
        let target = dir.appendingPathComponent("home/webui/settings.json")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{\"theme\":\"dark\"}".utf8).write(to: shared)

        #expect(!AppState.seedSharedSettingsIfNeeded(
            target: target, shared: shared, relocated: false))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("Missing shared file is a no-op")
    func missingSharedNoOp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-inst-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("home/webui/settings.json")

        #expect(!AppState.seedSharedSettingsIfNeeded(
            target: target, shared: dir.appendingPathComponent("nope.json"), relocated: true))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("Insights URL routes through ArcHome.webUIInsights")
    func insightsURLMatchesArcHome() {
        #expect(AppState.insightsURL == ArcHome.webUIInsights)
    }
}
