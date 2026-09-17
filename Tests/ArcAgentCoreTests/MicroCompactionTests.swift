import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Micro-compaction (Hermes docs/micro-compaction.md) parity tests

@Suite("Micro-compaction")
struct MicroCompactionTests {

    // MARK: Fixtures

    private var counter: TokenCounter { TokenCounter(calibrationFactor: 1.0) }

    private func user(_ text: String, at date: Date = Date()) -> Message {
        Message(role: .user, content: text, createdAt: date)
    }

    private func assistant(_ text: String, at date: Date = Date()) -> Message {
        Message(role: .assistant, content: text, createdAt: date)
    }

    private func tool(_ result: String, callID: String) -> Message {
        Message(role: .tool, content: result, toolCallID: callID, createdAt: Date())
    }

    private func system(_ text: String) -> Message {
        Message(role: .system, content: text, createdAt: Date())
    }

    /// A scripted summary closure: returns the exchange text prefixed with "SUMMARY:".
    private func scriptedSummary() -> (String, String) async -> String? {
        { existing, exchange in
            existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "SUMMARY: " + String(exchange.prefix(20))
                : existing + " + " + String(exchange.prefix(10))
        }
    }

    private func neverFails() -> (String) async -> String? {
        { _ in "DEFRAGGED" }
    }

    private func defaultConfig(enabled: Bool = true, everyN: Int = 1, defrag: Int = 2000) -> MicroCompactConfig {
        MicroCompactConfig(enabled: enabled, everyNTurns: everyN, defragThresholdTokens: defrag)
    }

    /// ~1700 chars ≈ 425 rough tokens each; enough to overflow a 6.6K-token
    /// tail budget so the compressible middle exists.
    private func big(_ n: Int = 20) -> String {
        String(repeating: "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor ", count: n)
    }

    /// system + opening user/assistant (protected head) + N exchanges (each:
    /// assistant, tool, assistant, user) — large enough to overflow a 6.6K-token
    /// tail budget so a compressible middle exists.
    private func bigTranscript(pairs: Int = 12) -> [Message] {
        var msgs: [Message] = [system("sys"), user("opening prompt"), assistant("opening reply")]
        for i in 0..<pairs {
            msgs.append(assistant(big()))
            msgs.append(tool("tool-result-\(i)", callID: "t\(i)"))
            msgs.append(assistant(big()))
            msgs.append(user("prompt number \(i)"))
        }
        return msgs
    }

    // MARK: Marker scaffold

    @Test("marker content round-trips through rollingSummaryFromMarker")
    func markerRoundTrip() {
        let summary = "Key decisions:\n- use tessera\n- keep the laws"
        let content = MicroCompactor.markerContent(summary: summary)
        #expect(content.contains(MicroCompactor.summaryPrefix))
        #expect(content.contains(MicroCompactor.historicalHeading))
        #expect(content.contains(MicroCompactor.summaryEndMarker))
        #expect(MicroCompactor.rollingSummaryFromMarker(content) == summary)
    }

    @Test("micro markers are assistant-role; batch summary markers are not micro")
    func markerDetection() {
        let micro = assistant(MicroCompactor.markerContent(summary: "s"))
        #expect(MicroCompactor.isMicroMarker(micro))
        #expect(MicroCompactor.isSummaryMarker(micro))
        let batch = system(MicroCompactor.summaryPrefix + "\n...")
        #expect(!MicroCompactor.isMicroMarker(batch))
        #expect(MicroCompactor.isSummaryMarker(batch))
        let plain = assistant("hello")
        #expect(!MicroCompactor.isMicroMarker(plain))
        #expect(!MicroCompactor.isSummaryMarker(plain))
    }

    // MARK: Boundaries

    @Test("head boundary protects system prompt plus first exchange")
    func headBoundaryTest() {
        let msgs = [system("sys"), user("hello"), assistant("hi"), user("next"), assistant("x"), tool("r", callID: "c")]
        #expect(MicroCompactor.headBoundary(msgs) == 3)
        let noSystem = [user("a"), assistant("b"), user("c"), assistant("d")]
        #expect(MicroCompactor.headBoundary(noSystem) == 2)
    }

    @Test("tail boundary budgets ~20k tokens and keeps at least 4 messages")
    func tailBoundaryTest() {
        // Each message ~100 chars ≈ 25 tokens under the rough counter; build
        // enough to exceed the budget.
        let msgs = (0..<100).map { user("message body number \($0) with some filler") }
        let start = MicroCompactor.tailStart(msgs, from: 0, limit: 1000) { counter.count($0) }
        #expect(start > 0)
        #expect(start < msgs.count)
    }

    // MARK: Exchange discovery

    @Test("exchange spans assistant + tool results + follow-up, stops at user")
    func exchangeSpan() {
        let msgs = [
            system("sys"), user("hello"),
            assistant("let me check"), tool("result", callID: "t1"), assistant("found it"),
            user("thanks"), assistant("welcome"),
        ]
        let (start, end) = MicroCompactor.findOneExchange(msgs, start: 2, tailStart: msgs.count)!
        #expect(start == 2)
        #expect(end == 5) // assistant+tool+assistant, stops before the user
    }

    @Test("user messages and markers are walked past, never absorbed")
    func exchangeSkipsUserAndMarkers() {
        // start lands ON a user message; discovery walks it and starts at the
        // following assistant instead.
        let msgs = [
            system("sys"), user("a"), assistant("A1"),
            user("b"), assistant("walk past me?"), user("c"),
        ]
        let (start, _) = MicroCompactor.findOneExchange(msgs, start: 3, tailStart: msgs.count)!
        #expect(start == 4)
        // A marker in the middle is never an exchange start: discovery skips it.
        let marker = assistant(MicroCompactor.markerContent(summary: "s"))
        let withMarker = [
            system("sys"), user("a"), marker, user("b"), assistant("A2"), user("c"),
        ]
        let (s2, _) = MicroCompactor.findOneExchange(withMarker, start: 2, tailStart: withMarker.count)!
        #expect(s2 == 4)
    }

    @Test("empty assistant (no output) is not an exchange start")
    func emptyAssistantNotExchange() {
        let msgs = [
            system("sys"), user("a"),
            assistant(""), user("b"), assistant("A2"), user("c"),
        ]
        // start=2 is an empty assistant; discovery walks to the real one at 4.
        let (start, _) = MicroCompactor.findOneExchange(msgs, start: 2, tailStart: msgs.count)!
        #expect(start == 4)
    }

    @Test("alternation guard: an exchange ending at an assistant marker refuses the splice")
    func markerBoundaryRejected() {
        // The consume walk stops when the FIRST non-assistant/tool message is a
        // summary marker (assistant role). Splicing there would produce two
        // adjacent assistant turns (marker + marker) — the guard returns nil.
        let hazard = [
            system("sys"), user("a"),
            assistant("A2"),
            assistant(MicroCompactor.markerContent(summary: "existing")),
        ]
        let found = MicroCompactor.findOneExchange(hazard, start: 2, tailStart: hazard.count)
        #expect(found == nil)
    }

    @Test("consecutive assistant messages are one turn and are consumed together")
    func consecutiveAssistantsConsumed() {
        let msgs = [
            system("sys"), user("a"),
            assistant("A1"), assistant("A2"), user("b"), assistant("A3"), user("c"),
        ]
        let (start, end) = MicroCompactor.findOneExchange(msgs, start: 2, tailStart: msgs.count)!
        #expect(start == 2)
        #expect(end == 4) // A1 + A2 consumed as one exchange, stops at user "b"
    }

    @Test("no exchange found at or past tail")
    func noExchangeAtTail() {
        let msgs = [system("sys"), user("a"), assistant("A1"), user("b")]
        #expect(MicroCompactor.findOneExchange(msgs, start: 3, tailStart: 4) == nil)
    }

    // MARK: Cursor

    @Test("valid in-memory cursor wins")
    func cursorValidWins() {
        var state = MicroCompactState()
        state.cursor = 3
        let msgs = [system("s"), user("u"), assistant("a"), user("u2"), assistant("a2"), user("u3")]
        let resolved = MicroCompactor.resolveCursor(msgs, headEnd: 2, tailStart: 5, state: &state)
        #expect(resolved == 3)
    }

    @Test("invalid cursor recovers from newest marker and rehydrates summary")
    func cursorRecovery() {
        let marker = assistant(MicroCompactor.markerContent(summary: "early decisions"))
        let msgs = [system("s"), user("u"), marker, user("u2"), assistant("a2"), user("u3")]
        var state = MicroCompactState()
        state.cursor = 0
        let resolved = MicroCompactor.resolveCursor(msgs, headEnd: 2, tailStart: msgs.count, state: &state)
        #expect(resolved == 3)
        #expect(state.rollingSummary == "early decisions")
    }

    // MARK: Splice

    @Test("splice replaces exchange with marker; supersede drops old micro markers and merges users")
    func spliceSupersede() {
        let old = assistant(MicroCompactor.markerContent(summary: "old"))
        let msgs = [
            system("s"), user("u1"), old,
            user("u2"), assistant("A"), tool("r", callID: "t"), assistant("A2"),
            user("merged with?"), user("the previous user"), assistant("a3"),
        ]
        let result = MicroCompactor.splice(
            msgs, start: 4, end: 7, rollingSummary: "new summary", supersede: true
        )
        // Old micro marker dropped.
        #expect(!result.contains(where: { MicroCompactor.isMicroMarker($0) && $0.content == old.content }))
        // Adjacent user turns merged.
        var adjacentUsers = 0
        for i in 0..<(result.count - 1) where result[i].role == .user && result[i + 1].role == .user {
            adjacentUsers += 1
        }
        #expect(adjacentUsers == 0)
        // New marker present with new summary.
        let markers = result.filter { MicroCompactor.isMicroMarker($0) }
        #expect(markers.count == 1)
        #expect(MicroCompactor.rollingSummaryFromMarker(markers[0].content) == "new summary")
    }

    @Test("splice without supersede keeps earlier micro markers")
    func spliceNoSupersede() {
        let old = assistant(MicroCompactor.markerContent(summary: "old"))
        let msgs = [system("s"), user("u1"), old, user("u2"), assistant("A"), assistant("A2"), user("u3")]
        let result = MicroCompactor.splice(
            msgs, start: 4, end: 6, rollingSummary: "new", supersede: false
        )
        #expect(result.filter { MicroCompactor.isMicroMarker($0) }.count == 2)
    }

    @Test("cursor after splice lands past the newest marker")
    func cursorAfterSpliceTest() {
        let result = [
            system("s"), user("u1"),
            assistant(MicroCompactor.markerContent(summary: "new")),
            user("u2"), assistant("a"),
        ]
        #expect(MicroCompactor.cursorAfterSplice(result, fallback: 1) == 3)
    }

    // MARK: The pass

    @Test("absorbed pass merges the exchange and user messages survive verbatim")
    func passAbsorbed() async {
        let msgs = bigTranscript()
        var state = MicroCompactState()
        let run = await MicroCompactor.run(
            messages: msgs,
            state: &state,
            config: defaultConfig(),
            limit: 20_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(),
            defragSummarize: neverFails()
        )
        #expect(run.outcome == .absorbed)
        #expect(run.messages.contains(where: { $0.content == "prompt number 0" }))
        #expect(run.messages.contains(where: { $0.content == "prompt number 11" }))
        #expect(state.passes == 1)
        #expect(state.rollingSummary.hasPrefix("SUMMARY:"))
        #expect(run.messages.count == msgs.count - 2) // 3 exchange msgs -> 1 marker
        // Roles must alternate: user -> assistant marker -> user.
        var lastRole: Message.Role?
        for m in run.messages {
            if let lastRole, m.role == lastRole, m.role == .user {
                Issue.record("adjacent user turns after splice")
            }
            lastRole = m.role
        }
    }

    @Test("a pass never absorbs the opening user message")
    func openingUserSurvives() async {
        let msgs = [
            system("sys"), user("FIRST USER MESSAGE"),
            assistant("a1"), user("second"), assistant("a2"), user("third"),
        ]
        var state = MicroCompactState()
        let run = await MicroCompactor.run(
            messages: msgs,
            state: &state,
            config: defaultConfig(),
            limit: 100_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(),
            defragSummarize: neverFails()
        )
        #expect(run.messages.contains(where: { $0.content == "FIRST USER MESSAGE" }))
    }

    @Test("disabled config returns the transcript untouched")
    func passDisabled() async {
        var state = MicroCompactState()
        let run = await MicroCompactor.run(
            messages: [system("s"), user("u"), assistant("a"), user("u2"), assistant("a2"), user("u3")],
            state: &state,
            config: defaultConfig(enabled: false),
            limit: 100_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(),
            defragSummarize: neverFails()
        )
        #expect(run.outcome == .disabled)
    }

    @Test("summarizer failure leaves transcript unchanged; three strikes skip the exchange")
    func passFailureThenSkip() async {
        let failing: (String, String) async -> String? = { _, _ in nil }
        let msgs = bigTranscript()
        var state = MicroCompactState()
        var run = await MicroCompactor.run(
            messages: msgs, state: &state,
            config: defaultConfig(), limit: 20_000,
            countTokens: { counter.count($0) },
            summarize: failing, defragSummarize: neverFails()
        )
        #expect(run.outcome == .summarizeFailed)
        #expect(run.messages == msgs)

        _ = await MicroCompactor.run(
            messages: msgs, state: &state,
            config: defaultConfig(), limit: 20_000,
            countTokens: { counter.count($0) },
            summarize: failing, defragSummarize: neverFails()
        )
        run = await MicroCompactor.run(
            messages: msgs, state: &state,
            config: defaultConfig(), limit: 20_000,
            countTokens: { counter.count($0) },
            summarize: failing, defragSummarize: neverFails()
        )
        #expect(run.outcome == .exchangeSkipped)
        #expect(state.cursor > 0)
        #expect(state.consecutiveFailures == 0)
    }

    @Test("cadence every 2 turns: first invocation noops, second runs")
    func passCadence() async {
        let msgs = bigTranscript()
        var state = MicroCompactState()
        var run = await MicroCompactor.run(
            messages: msgs, state: &state,
            config: defaultConfig(everyN: 2), limit: 20_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(), defragSummarize: neverFails()
        )
        #expect(run.outcome == .cadence)
        run = await MicroCompactor.run(
            messages: msgs, state: &state,
            config: defaultConfig(everyN: 2), limit: 20_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(), defragSummarize: neverFails()
        )
        #expect(run.outcome == .absorbed)
    }

    @Test("defrag rewrites the newest marker when summary hits the threshold")
    func passDefrag() async {
        let marker = assistant(MicroCompactor.markerContent(summary: "a very long baggy summary"))
        let msgs = [system("s"), user("u"), marker, user("u2"), assistant("a2"), user("u3")]
        var state = MicroCompactState()
        state.rollingSummary = "a very long baggy summary"
        state.cursor = 3
        var called = false
        let run = await MicroCompactor.run(
            messages: msgs, state: &state,
            config: defaultConfig(defrag: 3), limit: 100_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(),
            defragSummarize: { _ in
                called = true
                return "FRESH TIGHT SUMMARY"
            }
        )
        #expect(run.outcome == .defrag)
        #expect(called)
        #expect(state.rollingSummary == "FRESH TIGHT SUMMARY")
        #expect(run.messages.count == msgs.count) // no splice, shape-neutral
        let last = run.messages.last { MicroCompactor.isMicroMarker($0) }!
        #expect(MicroCompactor.rollingSummaryFromMarker(last.content) == "FRESH TIGHT SUMMARY")
    }

    @Test("defrag failure keeps the old summary and transcript")
    func passDefragFailure() async {
        let marker = assistant(MicroCompactor.markerContent(summary: "baggy"))
        let msgs = [system("s"), user("u"), marker, user("u2"), assistant("a2"), user("u3")]
        var state = MicroCompactState()
        state.rollingSummary = "baggy"
        state.cursor = 3
        let run = await MicroCompactor.run(
            messages: msgs, state: &state,
            config: defaultConfig(defrag: 3), limit: 100_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(),
            defragSummarize: { _ in nil }
        )
        #expect(run.outcome == .defragFailed)
        #expect(state.rollingSummary == "baggy")
        #expect(run.messages == msgs)
    }

    @Test("too-small transcript is a noop")
    func passTooSmall() async {
        var state = MicroCompactState()
        let run = await MicroCompactor.run(
            messages: [system("s"), user("u"), assistant("a")],
            state: &state,
            config: defaultConfig(), limit: 100_000,
            countTokens: { counter.count($0) },
            summarize: scriptedSummary(), defragSummarize: neverFails()
        )
        #expect(run.outcome == .tooSmall)
    }
}
