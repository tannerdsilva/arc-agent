import ArcAgentCore
import Foundation

/// Pure turn-event mapper: accumulates `AgentTurnEvent`s into the stored
/// fields of assistant/tool `Message`s per §3.3 of the convergence plan.
///
/// Value in / value out. No actor, no I/O — the UI owns the live turn; this
/// type only receives events and returns values.
struct TurnTranscript: Sendable {

    /// Accumulated assistant content from `textDelta` events.
    private(set) var content: String = ""

    /// Accumulated reasoning from `reasoningDelta` events.
    private(set) var reasoning: String = ""

    /// Last `usage` event of the round sequence.
    private(set) var usage: Usage? = nil

    /// `terminalReason` from the terminal `completed` event.
    private(set) var terminalReason: String? = nil

    /// Tool messages built from `toolCallFinished` events, in arrival order.
    private(set) var toolMessages: [Message] = []

    init() {}

    /// Fold one event into the accumulator.
    mutating func apply(_ event: AgentTurnEvent) {
        switch event {
        case .textDelta(let text):
            content += text
        case .reasoningDelta(let text):
            reasoning += text
        case .usage(let u):
            usage = u
        case .completed(_, let reason):
            terminalReason = reason
        case .toolCallFinished(let id, let name, let result):
            toolMessages.append(
                Message(role: .tool, content: result, name: name, toolCallID: id)
            )
        case .toolCallStarted, .failed:
            break
        }
    }

    /// Build the assistant `Message` from the accumulated state.
    ///
    /// `content` is the accumulated `textDelta` payload; `completed.finalText`
    /// is the check that the caller verifies against this accumulator.
    /// `turnDuration` and `displayText` are UI-side and left unset here.
    func assistantMessage() -> Message {
        Message(
            role: .assistant,
            content: content.isEmpty ? nil : content,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            usage: usage,
            terminalReason: terminalReason
        )
    }
}

/// Pure live-state mapper: computes `LiveTurn` field updates from a stream of
/// `AgentTurnEvent`s.
///
/// Each update is a function of one event and the prior state — no mutation
/// in place. Returns a new `LiveTurn`.
struct TurnLiveState: Sendable {

    init() {}

    /// Apply one event to a prior `LiveTurn`, returning the updated turn.
    ///
    /// `now` is the wall clock used for `tps` and `toolStartedAt`; defaults to
    /// `Date()`. Pass an explicit value in tests for deterministic results.
    static func apply(_ event: AgentTurnEvent, to prior: LiveTurn, now: Date = Date()) -> LiveTurn {
        var next = prior
        switch event {
        case .textDelta(let text):
            next.assistantText += text
            next.status = next.toolChips.isEmpty ? "running" : "tool"
        case .reasoningDelta(let text):
            next.thinking += text
        case .usage(let u):
            let elapsed = max(0.2, now.timeIntervalSince(prior.startedAt))
            next.tps = u.completionTokens > 0 ? Double(u.completionTokens) / elapsed : nil
        case .toolCallStarted(_, let name, _):
            next.toolChips.append("⚙ \(name)")
            next.toolName = name
            next.toolStartedAt = now
            next.status = "tool"
        case .toolCallFinished(_, let name, _):
            next.toolChips.removeAll { $0 == "⚙ \(name)" }
            if next.toolChips.isEmpty {
                next.toolName = nil
                next.status = "running"
            } else {
                next.status = "tool"
            }
        case .completed:
            next.status = "done"
        case .failed(let message):
            next.status = "error"
            next.error = message
        }
        return next
    }
}
