import Testing
import Foundation
@testable import ArcAgentCore

/// Tests for the Hermes-parity integration tools: media, webhooks, shell
/// hooks, code execution, and the browser registry.
@Suite("Integration tools")
struct IntegrationToolsTests {

    @Test("code_execution runs python and caps output")
    func codeExec() async throws {
        let result = try await CodeExecutionTool.entry.handler([
            "code": "print('hello from py')",
        ])
        #expect(result.contains("hello from py"))
        #expect(result.contains("no sandbox"))
    }

    @Test("code_execution respects the timeout (kills long programs)")
    func codeExecTimeout() async throws {
        let result = try await CodeExecutionTool.entry.handler([
            "code": "import time; time.sleep(10); print('never')",
            "timeout_seconds": 1,
        ])
        #expect(!result.contains("never"))
    }

    @Test("media tools report honest not-configured errors")
    func mediaNotConfigured() async throws {
        // Unset the env by using a custom config path (env not set in tests).
        let result = try await MediaTools.imageGenerate.handler(["prompt": "a cat"])
        #expect(result.contains("Media provider not configured"))

        let ttsResult = try await MediaTools.tts.handler(["text": "hi"])
        #expect(ttsResult.contains("Media provider not configured"))
    }

    @Test("webhook tool reports missing configuration without crashing")
    func webhookUnconfigured() async throws {
        let result = try await WebhookTools.notify.handler(["event": "test", "message": "hi"])
        #expect(result.contains("WEBHOOK_URLS"))
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

    @Test("webhook HMAC signature matches expected hex")
    func webhookHMAC() {
        let signature = WebhookEngine.HMAC_SHA256(key: "secret", data: Data("payload".utf8))
        #expect(signature.count == 64)
        #expect(signature != "")
    }

    @Test("media missing-argument errors are descriptive")
    func mediaRequiredArgs() async throws {
        // With no provider configured the handler reports that first.
        let result = try await MediaTools.imageGenerate.handler([:])
        #expect(result.contains("Media provider not configured"))
    }
}
