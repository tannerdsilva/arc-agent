import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

extension ArcCoreTestRoot {
    /// api_content replay sidecar parity (reference `api_content`): each message
    /// records the byte-exact content that went on the wire at send time, and the
    /// assembly prefers that recorded content on replay so the provider's prompt
    /// cache prefix stays warm and the model sees identical bytes.
    @Suite("API Content Sidecar", .serialized)
    struct APIContentSidecarTests {

        // MARK: - Helpers

        private func tempStore() -> FileSessionStore {
            FileSessionStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("arc-apicontent-\(UUID().uuidString)")
            )
        }

        private func makeConfig() -> ArcAgent.Configuration {
            ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "test-key",
                registry: CompileTimeToolRegistry(),
                sessionStore: tempStore(),
                memoryProvider: nil,
                skills: [],
                maxIterations: 5,
                maxTurnDuration: 30,
                persistSessions: false,
                approvalMode: .off,
                query: nil,
                maxContextTokens: 64_000,
                sessionID: "apicontent-test",
                injectProjectContext: false,
                platformHint: "cli"
            )
        }

        // MARK: - Semantics

        @Test("snapshotAPI records the wire content as the sidecar")
        func snapshotRecordsWireContent() {
            let m = Message(role: .user, content: "hello world")
            let snap = m.snapshotAPI()
            #expect(snap.apiContent == "hello world")
            #expect(snap.content == "hello world")
        }

        @Test("replayAPI prefers the recorded sidecar content")
        func replayPrefersSidecar() {
            let stored = Message(role: .assistant, content: "stored text", apiContent: "wire text")
            let replay = stored.replayAPI()
            #expect(replay.content == "wire text")
            // Without a sidecar, replay returns the message unchanged.
            let plain = Message(role: .assistant, content: "stored text")
            #expect(plain.replayAPI().content == "stored text")
        }

        @Test("apiDict mirrors the canonical wire form for text and tool-call messages")
        func apiDictWireForm() {
            let user = Message(role: .user, content: "hi").apiDict()
            #expect((user["role"] as? String) == "user")
            #expect((user["content"] as? String) == "hi")

            let toolMsg = Message(
                role: .assistant,
                content: nil,
                toolCalls: [
                    ToolCall(id: "t1", type: "function", function: ToolCallFunction(name: "ls", arguments: "{\"p\":\".\"}"))
                ]
            ).apiDict()
            #expect((toolMsg["role"] as? String) == "assistant")
            let calls = toolMsg["tool_calls"] as? [[String: Any]]
            #expect(calls?.count == 1)
            #expect((calls?[0]["id"] as? String) == "t1")
            #expect((((calls?[0]["function"]) as? [String: Any])?["name"] as? String) == "ls")
        }

        @Test("legacy sessions without apiContent decode as nil (backward compatible)")
        func codecBackwardCompatible() throws {
            let json = #"{"role":"user","content":"hi"}"#.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(Message.self, from: json)
            #expect(decoded.content == "hi")
            #expect(decoded.apiContent == nil)
        }

        // MARK: - Integration

        @Test("turn send records the sidecar on the wire messages")
        func sendRecordsSidecar() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { httpClient.shutdown() }
            let box = ClientScripts(responses: [
                LLMResponse(content: "ok", finishReason: "stop"),
            ])
            let agent = ArcAgent(config: makeConfig())
            await agent.setupClient(httpClient: httpClient)
            await agent.setClient(ScriptedClient(box: box))
            _ = try await agent.runConversation(message: "hello")
            guard let sent = box.recordedCalls().first else {
                Issue.record("no LLM call recorded")
                return
            }
            // The wire array's user message carries the sidecar equal to its content.
            let userMsgs = sent.filter { $0.role == .user }
            #expect(!userMsgs.isEmpty)
            #expect(userMsgs.allSatisfy { $0.apiContent != nil && $0.apiContent == $0.content })
        }
    }
}
