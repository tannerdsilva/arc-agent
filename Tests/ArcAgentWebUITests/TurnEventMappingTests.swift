import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

// ===========================================================================
// MARK: - Pure turn-event mappers (CONVERGE A4, §4 T4)
//
// These tests exercise `TurnTranscript` and `TurnLiveState` — value-in /
// value-out, no actor, no I/O, no `AppState` reference. One test per stored
// field per the plan's §3.3 mapping table.
// ===========================================================================

extension ArcWebUITestRoot {

    /// The mapping table (§3.3): events → assistant/tool `Message`s, and
    /// events → `LiveTurn` field updates.
    @Suite("turn event mapping", .serialized)
    struct TurnEventMappingTests {

        // MARK: TurnTranscript — stored fields

        @Test("assistant content accumulates textDelta; completed.finalText is the check")
        func assistantContentAccumulatesTextDeltas() throws {
            var transcript = TurnTranscript()
            transcript.apply(.textDelta("Hel"))
            transcript.apply(.textDelta("lo, "))
            transcript.apply(.textDelta("world"))
            transcript.apply(.completed(finalText: "Hello, world", terminalReason: nil))

            #expect(transcript.content == "Hello, world")
            #expect(transcript.assistantMessage().content == "Hello, world")
        }

        @Test("assistant reasoning accumulates reasoningDelta")
        func assistantReasoningAccumulatesReasoningDeltas() throws {
            var transcript = TurnTranscript()
            transcript.apply(.reasoningDelta("thinking "))
            transcript.apply(.reasoningDelta("hard"))
            transcript.apply(.completed(finalText: "answer", terminalReason: nil))

            #expect(transcript.reasoning == "thinking hard")
            #expect(transcript.assistantMessage().reasoning == "thinking hard")
        }

        @Test("assistant usage is the last usage of the round sequence")
        func assistantUsageIsLastUsageOfRound() throws {
            var transcript = TurnTranscript()
            transcript.apply(.usage(Usage(promptTokens: 10, completionTokens: 5, totalTokens: 15)))
            transcript.apply(.textDelta("first"))
            transcript.apply(.usage(Usage(promptTokens: 20, completionTokens: 10, totalTokens: 30)))
            transcript.apply(.textDelta("second"))
            transcript.apply(.completed(finalText: "firstsecond", terminalReason: nil))

            #expect(transcript.usage?.totalTokens == 30)
            #expect(transcript.usage?.completionTokens == 10)
            #expect(transcript.assistantMessage().usage?.totalTokens == 30)
        }

        @Test("assistant terminalReason comes from completed.terminalReason")
        func assistantTerminalReasonFromCompleted() throws {
            var transcript = TurnTranscript()
            transcript.apply(.textDelta("stopped"))
            transcript.apply(.completed(finalText: "stopped", terminalReason: "max_iterations"))

            #expect(transcript.terminalReason == "max_iterations")
            #expect(transcript.assistantMessage().terminalReason == "max_iterations")
        }

        @Test("normal completion carries nil terminalReason")
        func normalCompletionCarriesNilTerminalReason() throws {
            var transcript = TurnTranscript()
            transcript.apply(.completed(finalText: "done", terminalReason: nil))

            #expect(transcript.terminalReason == nil)
        }

        @Test("turnDuration is UI-side and unset by the mapper")
        func turnDurationIsUnsetByMapper() throws {
            var transcript = TurnTranscript()
            transcript.apply(.textDelta("x"))
            transcript.apply(.completed(finalText: "x", terminalReason: nil))

            let msg = transcript.assistantMessage()
            #expect(msg.turnDuration == nil)
            #expect(msg.displayText == nil)
        }

        @Test("tool content/name/toolCallID from toolCallFinished")
        func toolMessageFieldsFromToolCallFinished() throws {
            var transcript = TurnTranscript()
            transcript.apply(.toolCallStarted(id: "call_1", name: "terminal", arguments: "{\"cmd\":\"ls\"}"))
            transcript.apply(.toolCallFinished(id: "call_1", name: "terminal", result: "file1.txt\nfile2.txt"))

            #expect(transcript.toolMessages.count == 1)
            let toolMsg = transcript.toolMessages[0]
            #expect(toolMsg.content == "file1.txt\nfile2.txt")
            #expect(toolMsg.name == "terminal")
            #expect(toolMsg.toolCallID == "call_1")
            #expect(toolMsg.role == .tool)
        }

        @Test("multiple tool calls produce tool messages in arrival order")
        func multipleToolCallsInArrivalOrder() throws {
            var transcript = TurnTranscript()
            transcript.apply(.toolCallFinished(id: "call_a", name: "terminal", result: "a"))
            transcript.apply(.toolCallFinished(id: "call_b", name: "read_file", result: "b"))
            transcript.apply(.toolCallFinished(id: "call_c", name: "terminal", result: "c"))

            #expect(transcript.toolMessages.map { $0.toolCallID } == ["call_a", "call_b", "call_c"])
            #expect(transcript.toolMessages.map { $0.name } == ["terminal", "read_file", "terminal"])
            #expect(transcript.toolMessages.map { $0.content } == ["a", "b", "c"])
        }

        @Test("user message is untouched — no event populates user fields")
        func userMessageIsUntouched() throws {
            var transcript = TurnTranscript()
            transcript.apply(.textDelta("anything"))
            transcript.apply(.completed(finalText: "anything", terminalReason: nil))

            // the mapper never produces a user-role message at all.
            #expect(transcript.assistantMessage().role == .assistant)
            #expect(transcript.toolMessages.isEmpty)
        }

        @Test("failed turn does not populate terminalReason or content")
        func failedTurnLeavesFieldsEmpty() throws {
            var transcript = TurnTranscript()
            transcript.apply(.textDelta("partial"))
            transcript.apply(.failed("Error: provider disconnected"))

            #expect(transcript.content == "partial")
            #expect(transcript.terminalReason == nil)
            #expect(transcript.assistantMessage().content == "partial")
        }

        @Test("empty transcript yields an empty assistant message")
        func emptyTranscriptYieldsEmptyAssistantMessage() throws {
            let transcript = TurnTranscript()
            #expect(transcript.content.isEmpty)
            #expect(transcript.reasoning.isEmpty)
            #expect(transcript.usage == nil)
            #expect(transcript.terminalReason == nil)
            #expect(transcript.toolMessages.isEmpty)
            let msg = transcript.assistantMessage()
            #expect(msg.content == nil)
            #expect(msg.reasoning == nil)
            #expect(msg.usage == nil)
            #expect(msg.terminalReason == nil)
        }

        // MARK: TurnLiveState — field updates

        @Test("textDelta updates assistantText and keeps status running")
        func textDeltaUpdatesAssistantText() {
            let prior = LiveTurn(sessionID: "s1", userText: "hi", attachments: [])
            let next = TurnLiveState.apply(.textDelta("Hello"), to: prior)

            #expect(next.assistantText == "Hello")
            #expect(next.status == "running")
        }

        @Test("textDelta while a tool is active keeps status tool")
        func textDeltaDuringToolKeepsToolStatus() {
            let prior = LiveTurn(
                sessionID: "s1", userText: "hi", attachments: [], assistantText: "",
                thinking: "", toolChips: ["⚙ terminal"], status: "tool",
                toolName: "terminal", toolStartedAt: Date()
            )
            let next = TurnLiveState.apply(.textDelta("more"), to: prior)

            #expect(next.assistantText == "more")
            #expect(next.status == "tool")
        }

        @Test("reasoningDelta updates thinking")
        func reasoningDeltaUpdatesThinking() {
            let prior = LiveTurn(sessionID: "s1", userText: "hi", attachments: [])
            let next = TurnLiveState.apply(.reasoningDelta("thinking "), to: prior)
            let next2 = TurnLiveState.apply(.reasoningDelta("hard"), to: next)

            #expect(next2.thinking == "thinking hard")
        }

        @Test("toolCallStarted adds a chip and sets tool name / started at")
        func toolCallStartedAddsChip() {
            let prior = LiveTurn(sessionID: "s1", userText: "hi", attachments: [])
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            let next = TurnLiveState.apply(
                .toolCallStarted(id: "call_1", name: "terminal", arguments: "{}"),
                to: prior, now: started
            )

            #expect(next.toolChips == ["⚙ terminal"])
            #expect(next.toolName == "terminal")
            #expect(next.toolStartedAt == started)
            #expect(next.status == "tool")
        }

        @Test("toolCallFinished removes its chip; last chip returns status to running")
        func toolCallFinishedRemovesChip() {
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            var prior = LiveTurn(
                sessionID: "s1", userText: "hi", attachments: [], assistantText: "",
                thinking: "", toolChips: ["⚙ terminal"], status: "tool",
                toolName: "terminal", toolStartedAt: started
            )
            prior = TurnLiveState.apply(
                .toolCallStarted(id: "call_2", name: "read_file", arguments: "{}"),
                to: prior, now: started
            )
            let next = TurnLiveState.apply(
                .toolCallFinished(id: "call_1", name: "terminal", result: "ok"),
                to: prior, now: started
            )

            // terminal's chip removed, read_file's remains → still "tool".
            #expect(next.toolChips == ["⚙ read_file"])
            #expect(next.toolName == "read_file")
            #expect(next.status == "tool")

            let final = TurnLiveState.apply(
                .toolCallFinished(id: "call_2", name: "read_file", result: "ok"),
                to: next, now: started
            )
            #expect(final.toolChips.isEmpty)
            #expect(final.toolName == nil)
            #expect(final.status == "running")
        }

        @Test("completed sets status to done")
        func completedSetsStatusDone() {
            let prior = LiveTurn(
                sessionID: "s1", userText: "hi", attachments: [], assistantText: "Hello",
                thinking: "", toolChips: [], status: "running"
            )
            let next = TurnLiveState.apply(.completed(finalText: "Hello", terminalReason: nil), to: prior)

            #expect(next.status == "done")
        }

        @Test("failed sets status to error and records the message")
        func failedSetsStatusError() {
            let prior = LiveTurn(sessionID: "s1", userText: "hi", attachments: [])
            let next = TurnLiveState.apply(.failed("Error: timeout"), to: prior)

            #expect(next.status == "error")
            #expect(next.error == "Error: timeout")
        }

        @Test("usage computes tps from completion tokens and elapsed wall time")
        func usageComputesTps() {
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            let now = Date(timeIntervalSince1970: 1_700_000_010) // 10 s later
            let prior = LiveTurn(
                sessionID: "s1", userText: "hi", attachments: [], startedAt: started
            )
            let next = TurnLiveState.apply(
                .usage(Usage(promptTokens: 10, completionTokens: 40, totalTokens: 50)),
                to: prior, now: now
            )

            // 40 completion tokens / 10 s = 4 tokens/s.
            #expect(next.tps == 4.0)
        }

        @Test("tps is nil when no completion tokens")
        func tpsIsNilWithNoCompletionTokens() {
            let prior = LiveTurn(sessionID: "s1", userText: "hi", attachments: [])
            let next = TurnLiveState.apply(
                .usage(Usage(promptTokens: 10, completionTokens: 0, totalTokens: 10)),
                to: prior
            )

            #expect(next.tps == nil)
        }

        @Test("events are applied as a function of prior state — no in-place mutation")
        func eventsArePureFunctionsOfPriorState() {
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            let prior = LiveTurn(sessionID: "s1", userText: "hi", attachments: [])
            let afterText = TurnLiveState.apply(.textDelta("Hello"), to: prior)

            // prior is unchanged — the mapper returns a new value.
            #expect(prior.assistantText.isEmpty)
            #expect(afterText.assistantText == "Hello")

            let afterReasoning = TurnLiveState.apply(.reasoningDelta("thinking"), to: prior)
            #expect(afterReasoning.thinking == "thinking")
            #expect(afterText.thinking.isEmpty) // the first result is untouched by the second
        }

        @Test("a full turn sequence reproduces the live-state end state")
        func fullTurnSequenceReproducesEndState() {
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            var state = LiveTurn(sessionID: "s1", userText: "hi", attachments: [])
            state = TurnLiveState.apply(.textDelta("Hello "), to: state, now: started)
            state = TurnLiveState.apply(.reasoningDelta("thinking"), to: state, now: started)
            state = TurnLiveState.apply(
                .toolCallStarted(id: "call_1", name: "terminal", arguments: "{}"),
                to: state, now: started
            )
            state = TurnLiveState.apply(.textDelta(" world"), to: state, now: started)
            state = TurnLiveState.apply(
                .toolCallFinished(id: "call_1", name: "terminal", result: "ok"),
                to: state, now: started
            )
            state = TurnLiveState.apply(.completed(finalText: "Hello  world", terminalReason: nil), to: state, now: started)

            #expect(state.assistantText == "Hello  world")
            #expect(state.thinking == "thinking")
            #expect(state.toolChips.isEmpty)
            #expect(state.toolName == nil)
            #expect(state.status == "done")
            #expect(state.error == nil)
        }
    }
}
