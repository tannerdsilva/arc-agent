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

    @Test("browser tool family carries reference names when registered explicitly")
    func registeredSurface() throws {
        // The default surface is file IO + shell; hosts opt the browser family
        // in by registering its entries (exactly as this registry does).
        var registry = CompileTimeToolRegistry()
        for entry in [BrowserTools.navigate, BrowserTools.snapshot, BrowserTools.click,
                      BrowserTools.type, BrowserTools.press, BrowserTools.scroll,
                      BrowserTools.back, BrowserTools.console, BrowserTools.getImages,
                      BrowserTools.vision, BrowserTools.dialog, BrowserTools.cdp,
                      MCPClientTool.entry] {
            try registry.register(entry)
        }
        for name in ["browser_navigate", "browser_snapshot", "browser_console", "browser_get_images",
                     "browser_vision", "browser_dialog", "browser_cdp", "mcp_tool"] {
            #expect(registry.allTools.contains { $0.name == name }, "missing \(name)")
        }
        let console = registry.allTools.first { $0.name == "browser_console" }
        #expect(console?.toolset == "browser")
        let dialog = registry.allTools.first { $0.name == "browser_dialog" }
        #expect(dialog?.schema.asDictionary()["required"] as? [String] == ["action"])
    }

    @Test("browser tools error clearly when no browser is reachable")
    func browserUnavailable() async {
        await #expect(throws: (any Error).self) {
            _ = try await BrowserTools.snapshot.handler([:])
        }
    }

    @Test("browser registry picks the configured provider or cdp default")
    func browserRegistrySelection() async {
        await BrowserRegistry.shared.register(CDPBrowserProvider())
        let available = await BrowserRegistry.shared.available()
        #expect(available.contains("cdp"))
        let active = await BrowserRegistry.shared.active()
        #expect(active?.name == "cdp")
    }

    @Test("browser_vision errors cleanly without a provider")
    func visionToolErrorsWithoutProvider() async {
        // No provider registered in this test process → must throw a
        // clean error, not crash (reference same wording family).
        let out = await MCPProxy.runSuppressingErrors {
            try await BrowserTools.vision.handler(["question": "what is shown?"])
        }
        // Two legitimate process states:
        //  - no provider registered → the tool's own clean not-connected error
        //  - a sibling test registered the CDP provider and localhost:9222 is
        //    not a live CDP endpoint → URLSession's clean transport error
        // Either way the handler must surface a clean error, never crash.
        #expect(out.contains("CDP not connected") || out.contains("NSURLErrorDomain"),
            "out was: \(out)")
    }
}

/// Test helper: run a throwing handler and normalize to an error string.
enum MCPProxy {
    static func runSuppressingErrors(_ body: () async throws -> String) async -> String {
        do { return try await body() } catch { return "error: \(error)" }
    }
}
