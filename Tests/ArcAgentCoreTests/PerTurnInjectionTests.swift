import Testing
@testable import ArcAgentCore
import Foundation

extension ArcCoreTestRoot {
    /// Per-turn injection parity: plugin `pre_llm_call` context and MoA advisory
    /// blocks must land in the CURRENT user message — not as extra system
    /// messages — so the cached system prompt stays byte-stable (reference:
    /// Hermes injects these into the user message only).
    @Suite("Per-Turn Injection", .serialized)
    struct PerTurnInjectionTests {

        @Test("advisory blocks append to the last user message, never the system side")
        func appendsToLastUserMessage() {
            var messages: [Message] = [
                Message(role: .system, content: "SYSTEM"),
                Message(role: .user, content: "hi"),
                Message(role: .assistant, content: "ok"),
                Message(role: .user, content: "second question"),
            ]
            ArcAgent.injectTurnAdvisories(
                into: &messages,
                blocks: ["Hook context:\nSESSION=1", "Advisory context:\nref advice"]
            )

            // No system / assistant messages added; no new messages at all.
            #expect(messages.count == 4)
            // Only the last user message changed.
            #expect(messages[0].content == "SYSTEM")
            #expect(messages[1].content == "hi")
            #expect(messages[2].content == "ok")
            #expect(messages[3].content == "second question\n\nHook context:\nSESSION=1\n\nAdvisory context:\nref advice")
            #expect(messages[3].role == .user)
        }

        @Test("empty block list is a no-op")
        func emptyBlocksNoop() {
            var messages: [Message] = [Message(role: .system, content: "SYSTEM"), Message(role: .user, content: "hi")]
            ArcAgent.injectTurnAdvisories(into: &messages, blocks: ["", "  "])
            #expect(messages.count == 2)
            #expect(messages[1].content == "hi")
        }

        @Test("no user message present → no-op, no crash")
        func noUserMessageNoop() {
            var messages: [Message] = [Message(role: .system, content: "SYSTEM")]
            ArcAgent.injectTurnAdvisories(into: &messages, blocks: ["Hook context:\nX"])
            #expect(messages.count == 1)
            #expect(messages[0].content == "SYSTEM")
        }

        @Test("injection preserves tool-call user-adjacent roles")
        func preservesOtherRoles() {
            var messages: [Message] = [
                Message(role: .system, content: "SYSTEM"),
                Message(role: .user, content: "q"),
                Message(role: .assistant, content: "a", toolCalls: [
                    ToolCall(id: "t1", type: "function", function: ToolCallFunction(name: "ls", arguments: "{}"))
                ]),
                Message(role: .tool, content: "out", name: "ls", toolCallID: "t1"),
                Message(role: .user, content: "follow-up"),
            ]
            ArcAgent.injectTurnAdvisories(into: &messages, blocks: ["hint"])
            #expect(messages.count == 5)
            #expect(messages[1].content == "q")
            #expect(messages[2].toolCalls?.count == 1)
            #expect(messages[3].content == "out")
            #expect(messages[4].content == "follow-up\n\nhint")
        }
    }
}
