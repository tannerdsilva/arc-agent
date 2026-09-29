import Testing
@testable import ArcAgentCore
import Foundation

/// Browser extra-tool tests (reference browser_console/get_images/vision/
/// dialog/cdp): event-log semantics (no live CDP required) + registry
/// surface.
@Suite("Browser extras")
struct BrowserExtrasTests {

    @Test("event log buffers and drains console messages")
    func eventLogConsole() async {
        let log = CDPEventLog()
        await log.appendConsole(type: "log", text: "hello")
        await log.appendConsole(type: "error", text: "boom")
        await log.appendConsole(type: "warn", text: "")
        let drained = await log.drainConsole(clear: false)
        #expect(drained == ["[log] hello", "[error] boom"])
        // clear=true empties
        let again = await log.drainConsole(clear: true)
        #expect(again == drained)
        let empty = await log.drainConsole(clear: true)
        #expect(empty.isEmpty)
    }

    @Test("event log buffers dialogs and clears console on navigation")
    func eventLogDialogs() async {
        let log = CDPEventLog()
        await log.appendDialog(params: ["type": "confirm", "message": "proceed?"])
        let dialogs = await log.dialogs()
        #expect(dialogs.count == 1)
        #expect(dialogs[0]["type"] as? String == "confirm")
        await log.appendConsole(type: "log", text: "old")
        await log.clearConsole()
        let drained = await log.drainConsole(clear: false)
        #expect(drained.isEmpty)
    }

    @Test("browser tool family is registered with reference names")
    func registeredSurface() throws {
        let registry = try ArcAgentCore.buildDefaultRegistry()
        for name in ["browser_navigate", "browser_snapshot", "browser_console", "browser_get_images",
                     "browser_vision", "browser_dialog", "browser_cdp", "mcp_tool"] {
            #expect(registry.allTools.contains { $0.name == name }, "missing \(name)")
        }
        let console = registry.allTools.first { $0.name == "browser_console" }
        #expect(console?.toolset == "browser")
        let dialog = registry.allTools.first { $0.name == "browser_dialog" }
        #expect(dialog?.schema.asDictionary()["required"] as? [String] == ["action"])
    }

    @Test("browser_vision errors cleanly without a provider")
    func visionToolErrorsWithoutProvider() async {
        // No provider registered in this test process → must throw a
        // clean error, not crash (reference same wording family).
        let out = await MCPProxy.runSuppressingErrors {
            try await BrowserTools.vision.handler(["question": "what is shown?"])
        }
        // Full-suite runs register a real CDP provider (localhost:9222 is
        // typically down) — accept the clean not-connected error family.
        #expect(out.contains("CDP not connected") || out.contains("Could not connect"))
    }
}

/// Test helper: run a throwing handler and normalize to an error string.
enum MCPProxy {
    static func runSuppressingErrors(_ body: () async throws -> String) async -> String {
        do { return try await body() } catch { return "error: \(error)" }
    }
}
