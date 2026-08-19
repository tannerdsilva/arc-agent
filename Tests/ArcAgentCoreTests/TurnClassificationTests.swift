import Testing
import Foundation
@testable import ArcAgentCore

/// Regression tests for the tool-call parsing precedence fix.
///
/// Qwen3-family reasoning models emit a whitespace-only `content` field
/// (e.g. "\n\n") alongside a real `tool_calls` array. If the agent returns
/// that content as the final answer, the tool calls are silently discarded
/// and the user's tool-driven request never executes.
///
/// `ArcAgent.classifyTurn` is the single source of truth used by BOTH the
/// streaming and non-streaming turn loops, so testing it covers both paths.
struct TurnClassificationTests {

    private func makeToolCall(name: String = "write_file", args: String = "{}") -> ToolCall {
        ToolCall(
            id: "call_test",
            type: "function",
            function: ToolCallFunction(name: name, arguments: args)
        )
    }

    // MARK: - Tool calls take precedence

    @Test("tool calls win even when content is non-empty")
    func toolCallsWinOverContent() {
        let outcome = ArcAgent.classifyTurn(
            content: "I'll write that file now.",
            toolCalls: [makeToolCall()]
        )
        guard case .toolCalls(let calls) = outcome else {
            Issue.record("expected .toolCalls, got \(outcome)")
            return
        }
        #expect(calls.count == 1)
        #expect(calls[0].function.name == "write_file")
    }

    @Test("tool calls win even when content is the whitespace prefix")
    func toolCallsWinOverWhitespacePrefix() {
        // The exact shape observed from the live endpoint:
        // content="\n\n", finish_reason=tool_calls
        let outcome = ArcAgent.classifyTurn(
            content: "\n\n",
            toolCalls: [makeToolCall()]
        )
        guard case .toolCalls = outcome else {
            Issue.record("expected .toolCalls, got \(outcome)")
            return
        }
    }

    // MARK: - Plain text answers

    @Test("non-empty text with no tool calls is .text")
    func textWithoutToolCalls() {
        let outcome = ArcAgent.classifyTurn(
            content: "Done! The file is on your Desktop.",
            toolCalls: nil
        )
        guard case .text(let text) = outcome else {
            Issue.record("expected .text, got \(outcome)")
            return
        }
        #expect(text == "Done! The file is on your Desktop.")
    }

    @Test("empty tool_calls array is not treated as a tool call turn")
    func emptyToolCallsArrayFallsThroughToText() {
        // finish_reason can be "tool_calls" with an empty array on some
        // providers; that must not be classified as a tool-call turn.
        let outcome = ArcAgent.classifyTurn(
            content: "Here is your answer.",
            toolCalls: []
        )
        guard case .text = outcome else {
            Issue.record("expected .text, got \(outcome)")
            return
        }
    }

    // MARK: - Whitespace-only content

    @Test("whitespace-only content with no tool calls is .empty")
    func whitespaceOnlyContentIsEmpty() {
        let outcome = ArcAgent.classifyTurn(
            content: "\n\n  \n",
            toolCalls: nil
        )
        guard case .empty = outcome else {
            Issue.record("expected .empty, got \(outcome)")
            return
        }
    }

    @Test("nil content and nil tool calls is .empty")
    func allNilIsEmpty() {
        let outcome = ArcAgent.classifyTurn(content: nil, toolCalls: nil)
        guard case .empty = outcome else {
            Issue.record("expected .empty, got \(outcome)")
            return
        }
    }

    @Test("nil content with tool calls is .toolCalls")
    func nilContentWithToolCalls() {
        let outcome = ArcAgent.classifyTurn(content: nil, toolCalls: [makeToolCall()])
        guard case .toolCalls(let calls) = outcome else {
            Issue.record("expected .toolCalls, got \(outcome)")
            return
        }
        #expect(calls.count == 1)
    }
}
