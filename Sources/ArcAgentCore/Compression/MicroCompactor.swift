import Foundation

// MARK: - Micro-compaction
//
// Faithful port of Hermes `agent/context_compressor.py` micro-compaction
// (docs/micro-compaction.md): after every completed turn, absorb ONE full
// assistant exchange into a single rolling summary marker. User messages are
// never absorbed, the head (system + first exchange) and a token-budgeted tail
// are protected, and the transcript itself is the source of truth for the
// cursor (a resumed session rehydrates the rolling summary from the last
// marker). Off by default; the operator dials cost with
// `microCompactEveryNTurns` and `microCompactDefragThresholdTokens`.
//
// Pure logic over `[Message]` — the LLM summarization is injected as closures
// so the machinery is unit-testable without a provider.

public struct MicroCompactConfig: Sendable, Equatable {
    /// `compression.micro_compact` — off by default (Hermes parity).
    public var enabled: Bool
    /// `compression.micro_compact_every_n_turns` — cadence of passes.
    public var everyNTurns: Int
    /// `compression.micro_compact_defrag_threshold_tokens` — when the rolling
    /// summary itself gets re-summarized instead of growing forever.
    public var defragThresholdTokens: Int

    public init(enabled: Bool = false, everyNTurns: Int = 1, defragThresholdTokens: Int = 2000) {
        self.enabled = enabled
        self.everyNTurns = everyNTurns
        self.defragThresholdTokens = defragThresholdTokens
    }

    /// Hermes clamps values below 1 to 1 rather than silently disabling.
    public var clampedEveryNTurns: Int { max(1, everyNTurns) }
}

public struct MicroCompactState: Sendable, Equatable {
    /// Index of the first message not yet absorbed (in-memory; the transcript
    /// is the source of truth for recovery).
    public var cursor: Int = 0
    /// The one cumulative summary that every exchange is merged into.
    public var rollingSummary: String = ""
    /// Failure tracking so an unsummarizable exchange is skipped after three
    /// consecutive failures instead of being retried every turn.
    public var consecutiveFailures: Int = 0
    public var lastFailureCursor: Int = -1
    public var passes: Int = 0
    public var tokensSavedTotal: Int = 0
    public var turnsSincePass: Int = 0

    public init() {}
}

public enum MicroCompactOutcome: String, Sendable {
    case disabled
    case tooSmall
    case cadence
    case noWindow
    case noExchange
    case defrag
    case defragFailed
    case summarizeFailed
    case exchangeSkipped
    case absorbed
}

public struct MicroCompactRun: Sendable {
    public let messages: [Message]
    public let outcome: MicroCompactOutcome
    public let tokensBefore: Int
    public let tokensAfter: Int
    public let exchangeTokens: Int?
    public let durationMs: Int?

    public init(
        messages: [Message],
        outcome: MicroCompactOutcome,
        tokensBefore: Int,
        tokensAfter: Int,
        exchangeTokens: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.messages = messages
        self.outcome = outcome
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.exchangeTokens = exchangeTokens
        self.durationMs = durationMs
    }
}

public enum MicroCompactor {

    // MARK: Marker scaffolding (Hermes SUMMARY_PREFIX / HISTORICAL_TASK_HEADING
    // / _SUMMARY_END_MARKER — same constants the batch path uses so the two
    // interoperate; micro markers are ASSISTANT-role so alternation stays
    // valid: user → marker → user).

    public static let summaryPrefix = "The following is a compressed record of earlier conversation context."
    public static let historicalHeading = "## Historical Task Snapshot"
    public static let summaryEndMarker = "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"
    public static let maxConsecutiveFailures = 3

    public static func isMicroMarker(_ m: Message) -> Bool {
        m.role == .assistant && (m.content?.contains(historicalHeading) ?? false)
    }

    public static func isSummaryMarker(_ m: Message) -> Bool {
        (m.content?.hasPrefix(summaryPrefix) ?? false)
    }

    public static func markerContent(summary: String) -> String {
        summaryPrefix + "\n\n" + historicalHeading + "\n"
            + summary.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + summaryEndMarker
    }

    public static func rollingSummaryFromMarker(_ content: String?) -> String {
        guard let content,
              let heading = content.range(of: historicalHeading) else { return "" }
        var body = content[heading.upperBound...]
        if let end = body.range(of: summaryEndMarker) {
            body = body[..<end.lowerBound]
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Boundaries (same shape as the batch path: head = system prompt +
    // first exchange; tail = token-budgeted recent window).

    /// Index just past the protected head (system messages + the first two
    /// non-system messages, i.e. the opening user/assistant exchange).
    public static func headBoundary(_ messages: [Message]) -> Int {
        var i = 0
        while i < messages.count, messages[i].role == .system { i += 1 }
        var nonSystem = 0
        while i < messages.count, nonSystem < 2 {
            i += 1
            nonSystem += 1
        }
        return i
    }

    /// Start of the protected tail: a ~20K-token budget (at least 4 messages).
    public static func tailStart(
        _ messages: [Message],
        from head: Int,
        limit: Int,
        countTokens: (String) -> Int
    ) -> Int {
        let budget = min(20_000, limit / 3)
        var tokens = 0
        var count = 0
        var i = messages.count
        while i > head {
            i -= 1
            tokens += countTokens(messages[i].content ?? "") + 4
            count += 1
            if tokens >= budget && count >= 4 { break }
        }
        return i
    }

    // MARK: Exchange discovery

    /// The next complete exchange starting at or after `start`: the first real
    /// assistant message (with actual output) plus everything through the end
    /// of that turn — tool results and follow-up assistant iterations — up to
    /// (exclusive) the next user message. User messages and summary markers
    /// are walked past, never absorbed. Returns nil when no safe splice
    /// boundary exists before `tailStart`.
    public static func findOneExchange(
        _ messages: [Message],
        start: Int,
        tailStart: Int
    ) -> (Int, Int)? {
        let n = messages.count
        if start >= n || start >= tailStart { return nil }

        var idx = start
        while idx < tailStart && idx < n {
            let m = messages[idx]
            let hasOutput = !(m.content ?? "").isEmpty || !(m.toolCalls ?? []).isEmpty
            if m.role == .assistant && !isSummaryMarker(m) && !isMicroMarker(m) && hasOutput {
                break
            }
            idx += 1
        }
        if idx >= tailStart || idx >= n { return nil }
        let exchangeStart = idx

        idx += 1
        while idx < tailStart && idx < n {
            let role = messages[idx].role
            if role != .assistant && role != .tool { break }
            if isSummaryMarker(messages[idx]) || isMicroMarker(messages[idx]) { break }
            idx += 1
        }

        if idx <= exchangeStart { return nil }
        if idx >= n { return nil }
        // Splice-boundary guard (Hermes): a same-role boundary (assistant/tool,
        // including an assistant-role marker) would break role alternation.
        let boundary = messages[idx]
        if boundary.role == .assistant || boundary.role == .tool { return nil }
        return (exchangeStart, idx)
    }

    // MARK: Cursor

    /// Valid in-memory cursor wins. Otherwise scan the compressible window for
    /// the last micro marker and resume just past it, rehydrating the rolling
    /// summary so the next pass merges into the existing history instead of
    /// replacing it. The transcript is the source of truth.
    public static func resolveCursor(
        _ messages: [Message],
        headEnd: Int,
        tailStart: Int,
        state: inout MicroCompactState
    ) -> Int {
        if state.cursor > headEnd && state.cursor < tailStart { return state.cursor }
        var lastMarker = -1
        if headEnd < tailStart {
            for idx in headEnd..<tailStart where isMicroMarker(messages[idx]) {
                lastMarker = idx
            }
        }
        if lastMarker >= headEnd {
            let cursor = lastMarker + 1
            if state.rollingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let recovered = rollingSummaryFromMarker(messages[lastMarker].content)
                if !recovered.isEmpty {
                    state.rollingSummary = recovered
                }
            }
            state.cursor = cursor
            return cursor
        }
        state.cursor = headEnd
        return headEnd
    }

    // MARK: Splice

    /// Replace `messages[start..<end]` with the assistant-role summary marker.
    /// With `supersede` (the rolling summary was non-empty going into the
    /// pass) every earlier MICRO marker is dropped — the new marker already
    /// contains everything they held — and adjacent plain-text user turns left
    /// by that drop are merged, exactly like Hermes' repair pass.
    public static func splice(
        _ messages: [Message],
        start: Int,
        end: Int,
        rollingSummary: String,
        supersede: Bool
    ) -> [Message] {
        let marker = Message(role: .assistant, content: markerContent(summary: rollingSummary), createdAt: Date())
        var result = Array(messages[0..<start]) + [marker] + Array(messages[end...])
        if supersede {
            var filtered: [Message] = []
            for m in result {
                if isMicroMarker(m), m.content != marker.content {
                    continue // superseded — the new marker carries its content
                }
                filtered.append(m)
            }
            result = mergeAdjacentUserTurns(filtered)
        }
        return result
    }

    /// Merge consecutive plain-text real user turns (Hermes
    /// `_merge_adjacent_user_turns`) — restores alternation deliberately after
    /// a superseded marker is dropped.
    static func mergeAdjacentUserTurns(_ messages: [Message]) -> [Message] {
        var merged: [Message] = []
        for m in messages {
            if m.role == .user,
               let prev = merged.last, prev.role == .user,
               let prevContent = prev.content, let content = m.content,
               !prevContent.contains(summaryPrefix), !content.contains(summaryPrefix) {
                let joined = prevContent.isEmpty ? content
                    : (content.isEmpty ? prevContent : prevContent + "\n\n" + content)
                merged[merged.count - 1] = Message(
                    role: .user, content: joined, createdAt: prev.createdAt
                )
                continue
            }
            merged.append(m)
        }
        return merged
    }

    /// Cursor just past the newest micro marker in the spliced list. Always
    /// derived from the result — a splice collapses an entire exchange, so
    /// old indices are meaningless.
    public static func cursorAfterSplice(_ result: [Message], fallback: Int) -> Int {
        for idx in stride(from: result.count - 1, through: 0, by: -1)
        where isMicroMarker(result[idx]) {
            return idx + 1
        }
        return fallback
    }

    // MARK: Serialization for the summarizer

    /// One exchange, serialized for the micro-summarizer: role + content per
    /// message, per-message truncation cap, reasoning/thinking stripped,
    /// credential-bearing lines are instructed to be replaced by the prompt
    /// (the prompt itself carries the [REDACTED] directive, Hermes parity).
    public static func exchangeText(_ exchange: [Message], maxCharsPerMessage: Int = 4000) -> String {
        var out: [String] = []
        for m in exchange {
            let label: String
            switch m.role {
            case .assistant: label = "assistant"
            case .user: label = "user"
            case .tool: label = "tool result"
            case .system: label = "system"
            }
            let body = (m.content ?? "")
            let truncated = body.count > maxCharsPerMessage
                ? String(body.prefix(maxCharsPerMessage)) + " …[truncated]"
                : body
            if m.role == .tool, let callID = m.toolCallID {
                out.append("[\(label) :: \(callID)] \(truncated)")
            } else {
                out.append("[\(label)] \(truncated)")
            }
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: The pass

    /// One micro-compaction pass. Best-effort by contract: every failure mode
    /// returns the transcript unchanged (or the skipped-exchange marker state)
    /// and the turn the caller is finishing is never affected.
    public static func run(
        messages: [Message],
        state: inout MicroCompactState,
        config: MicroCompactConfig,
        limit: Int,
        countTokens: (String) -> Int,
        summarize: (String, String) async -> String?,
        defragSummarize: (String) async -> String?
    ) async -> MicroCompactRun {
        func noop(_ outcome: MicroCompactOutcome, msgs: [Message] = messages) -> MicroCompactRun {
            MicroCompactRun(messages: msgs, outcome: outcome, tokensBefore: 0, tokensAfter: 0)
        }

        guard config.enabled else { return noop(.disabled) }

        // Cadence gate (Hermes): counted per invocation — a turn with nothing
        // to absorb still advances the cadence and cannot wedge it.
        let everyN = config.clampedEveryNTurns
        if everyN > 1 {
            state.turnsSincePass += 1
            if state.turnsSincePass < everyN { return noop(.cadence) }
            state.turnsSincePass = 0
        }

        let n = messages.count
        if n < 4 { return noop(.tooSmall) }

        let headEnd = headBoundary(messages)
        let tail = tailStart(messages, from: headEnd, limit: limit, countTokens: countTokens)

        // Defrag runs before the window guard: rewriting the rolling summary
        // marker in place needs no compressible window (Hermes checks
        // `_needs_defrag` before exchange discovery and never gates it on the
        // tail budget — a fresh conversation with no middle yet can still
        // defrag a baggy summary).
        let summaryTokens = state.rollingSummary.isEmpty
            ? 0 : countTokens(state.rollingSummary)
        if summaryTokens >= config.defragThresholdTokens {
            let startedDefrag = Date()
            let fresh = await defragSummarize(state.rollingSummary)
            if let fresh, !fresh.isEmpty {
                state.rollingSummary = fresh
                var result = messages
                for idx in stride(from: result.count - 1, through: 0, by: -1)
                where isMicroMarker(result[idx]) {
                    result[idx] = Message(
                        role: .assistant,
                        content: markerContent(summary: fresh),
                        createdAt: result[idx].createdAt
                    )
                    break
                }
                let elapsed = Int(Date().timeIntervalSince(startedDefrag) * 1000)
                return MicroCompactRun(
                    messages: result,
                    outcome: .defrag,
                    tokensBefore: 0, tokensAfter: 0,
                    durationMs: elapsed
                )
            }
            let elapsed = Int(Date().timeIntervalSince(startedDefrag) * 1000)
            return MicroCompactRun(
                messages: messages,
                outcome: .defragFailed,
                tokensBefore: 0, tokensAfter: 0,
                durationMs: elapsed
            )
        }

        if headEnd >= tail { return noop(.noWindow) }

        let cursor = resolveCursor(messages, headEnd: headEnd, tailStart: tail, state: &state)
        if cursor >= tail { return noop(.noWindow) }

        let started = Date()

        guard let exchange = findOneExchange(messages, start: cursor, tailStart: tail) else {
            return noop(.noExchange)
        }
        let (start, end) = exchange

        let tokensBefore = countTokens(messages.map { $0.content ?? "" }.joined(separator: " "))
        let text = exchangeText(Array(messages[start..<end]))
        let exchangeTokens = countTokens(text)

        let wasCumulative = !state.rollingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let updated = await summarize(state.rollingSummary, text)

        guard let updated, !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if start == state.lastFailureCursor {
                state.consecutiveFailures += 1
            } else {
                state.consecutiveFailures = 1
                state.lastFailureCursor = start
            }
            let outcome: MicroCompactOutcome
            if state.consecutiveFailures >= maxConsecutiveFailures {
                outcome = .exchangeSkipped
                state.cursor = end
                state.consecutiveFailures = 0
                state.lastFailureCursor = -1
            } else {
                outcome = .summarizeFailed
            }
            return MicroCompactRun(
                messages: messages, outcome: outcome,
                tokensBefore: tokensBefore, tokensAfter: tokensBefore,
                exchangeTokens: exchangeTokens,
                durationMs: Int(Date().timeIntervalSince(started) * 1000)
            )
        }

        state.rollingSummary = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        state.consecutiveFailures = 0
        state.lastFailureCursor = -1

        let result = splice(
            messages, start: start, end: end,
            rollingSummary: state.rollingSummary,
            supersede: wasCumulative
        )
        state.cursor = cursorAfterSplice(result, fallback: start + 1)

        let tokensAfter = countTokens(result.map { $0.content ?? "" }.joined(separator: " "))
        state.passes += 1
        state.tokensSavedTotal += max(0, tokensBefore - tokensAfter)
        return MicroCompactRun(
            messages: result, outcome: .absorbed,
            tokensBefore: tokensBefore, tokensAfter: tokensAfter,
            exchangeTokens: exchangeTokens,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }
}
