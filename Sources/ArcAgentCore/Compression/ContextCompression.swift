import Foundation

/// reference `context_compressor` port — the pieces of the big (threshold)
/// compression that live outside the agent loop, kept pure and testable:
/// the structured summary template (with Resolved/Pending tracking), the
/// head/middle/tail window, the cheap tool-result pruning pre-pass, and
/// orphaned tool_call/tool_result cleanup.
public enum ContextCompression {

    public static let historicalHeading = "## Historical Task Snapshot"
    public static let noUserTaskSentinel = "None. This session contains no user-authored turns."

    // MARK: - Window selection (reference compress() steps 2-4)

    /// Split non-system messages into protected head, compressible middle,
    /// and protected tail. Head = the first exchange (2 messages). Tail =
    /// the most recent messages within `tailBudget` tokens, minimum 4.
    public static func window(
        _ messages: [Message],
        tailBudget: Int,
        countTokens: (String) -> Int
    ) -> (head: [Message], middle: [Message], tail: [Message]) {
        let nonSystem = messages.filter { $0.role != .system }
        let head = Array(nonSystem.prefix(min(2, nonSystem.count)))
        var tailTokens = 0
        var tailCount = 0
        let mid = Array(nonSystem.dropFirst(head.count))
        for msg in mid.reversed() {
            tailTokens += countTokens(msg.content ?? "") + 4
            tailCount += 1
            if tailTokens >= tailBudget && tailCount >= 4 { break }
        }
        let tail = Array(mid.suffix(tailCount))
        let compressible = Array(mid.prefix(max(0, mid.count - tailCount)))
        return (head, compressible, tail)
    }

    // MARK: - Request budgeting (overhead-aware)

    /// The compression budget split.
    ///
    /// `limit` is the FULL request budget the engine gates on — system prompt
    /// plus tool schemas plus history. `overhead` is the part compression
    /// cannot touch. Sizing the window off `limit` alone leaves no room for
    /// the summary the middle is replaced with, so the request stays over
    /// budget and the next turn iteration compresses again.
    public struct RequestBudget: Sendable, Equatable {
        public let limit: Int
        public let overhead: Int

        public init(limit: Int, overhead: Int) {
            self.limit = limit
            self.overhead = max(0, overhead)
        }

        /// Tokens available to the message history.
        public var historyBudget: Int { max(0, limit - overhead) }
    }

    /// Tail and summary token budgets for a history budget, after protecting
    /// the head.
    ///
    /// `compressibleTokens` is the size of the non-system history. It bounds
    /// the tail as well: a tail budget larger than half the compressible
    /// region swallows the whole middle, leaving nothing to summarize (the
    /// pass then degenerates into the emergency drop). `head` is never
    /// compressed, so it comes off the top of the budget; the tail never
    /// takes more than half of what remains, which guarantees the summary
    /// that replaces the middle always has room.
    public static func budgets(
        historyBudget: Int,
        headTokens: Int,
        compressibleTokens: Int,
        maxTail: Int = 20_000,
        maxSummary: Int = 6_000
    ) -> (tail: Int, summary: Int) {
        let available = max(0, historyBudget - max(0, headTokens))
        let compressible = max(0, compressibleTokens - max(0, headTokens))
        let tail = min(maxTail, available / 2, compressible / 2)
        let summary = min(maxSummary, max(0, available - tail))
        return (tail, summary)
    }

    /// Clamp `text` to `budget` tokens, keeping its head and tail around a
    /// truncation marker. The summarizer is an external model: its output is
    /// never trusted to respect the budget the prompt asks for.
    public static func boundToTokenBudget(
        _ text: String,
        budget: Int,
        countTokens: (String) -> Int
    ) -> String {
        guard budget > 0 else { return "" }
        guard countTokens(text) > budget else { return text }
        let marker = "\n...[summary truncated to fit the compression budget]...\n"
        var head = String(text.prefix(text.count / 2))
        var tail = String(text.suffix(text.count / 2))
        var out = head + marker + tail
        while countTokens(out) > budget, head.count > 64 || tail.count > 64 {
            if head.count > 64 { head = String(head.prefix(head.count * 3 / 4)) }
            if tail.count > 64 { tail = String(tail.suffix(tail.count * 3 / 4)) }
            out = head + marker + tail
        }
        // Pathological budget (smaller than the marker + two 64-char ends):
        // fall back to a hard prefix cut so the bound always holds.
        if countTokens(out) > budget {
            var chars = min(out.count, budget * 4)
            while chars > 0 && countTokens(String(out.prefix(chars))) > budget {
                chars = chars * 3 / 4
            }
            out = String(out.prefix(chars))
        }
        return out
    }

    /// Bounded extractive fallback used when no auxiliary summarizer is
    /// configured or the call fails.
    ///
    /// Folds the previous summary with an excerpt of the newest material, kept
    /// inside `budget`. Re-serializing the whole middle here (the old
    /// behaviour) made compression a no-op: the "summary" was as large as the
    /// messages it replaced, the request stayed over budget, and the loop
    /// compressed on every iteration while the previous summary was lost.
    public static func extractiveSummary(
        previous: String,
        material: [Message],
        budget: Int,
        countTokens: (String) -> Int
    ) -> String {
        guard budget > 0 else { return "" }
        var sections: [String] = []
        var remaining = budget

        let prior = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prior.isEmpty {
            let bounded = boundToTokenBudget(prior, budget: budget / 2, countTokens: countTokens)
            if !bounded.isEmpty {
                sections.append(bounded)
                remaining -= countTokens(bounded) + 8
            }
        }

        // Newest material first: it is closest to the live tail and the most
        // useful to keep. Oversized lines are truncated, not skipped, so a
        // single huge tool result cannot starve the whole excerpt.
        var lines: [String] = []
        var omitted = false
        for msg in material.reversed() {
            guard remaining > 32 else { omitted = true; break }
            guard var line = recordLine(msg, maxChars: min(4_000, remaining * 4)) else { continue }
            var cost = countTokens(line) + 2
            if cost > remaining {
                let capped = String(line.prefix(max(0, remaining * 4)))
                guard !capped.isEmpty else { omitted = true; break }
                line = capped + " …[truncated]"
                cost = countTokens(line) + 2
                guard cost <= remaining else { omitted = true; break }
            }
            lines.append(line)
            remaining -= cost
        }
        if !lines.isEmpty {
            sections.append(lines.reversed().joined(separator: "\n\n"))
        }
        if omitted {
            sections.append("[older material omitted: extractive fallback budget]")
        }
        let joined = sections.joined(separator: "\n\n")
        // Per-section accounting cannot see the join separators; the bound is
        // the contract, so enforce it on the assembled text.
        return countTokens(joined) <= budget
            ? joined
            : boundToTokenBudget(joined, budget: budget, countTokens: countTokens)
    }

    /// Drop the oldest tail messages until `messages` fits `budget`.
    ///
    /// The tail budget can overshoot by one large message, and the head is
    /// unbounded; this is the final guarantee that a compression pass returns
    /// a history the full request budget can hold. `protectedPrefix` counts
    /// the messages that must survive (system messages, the summary, the
    /// head); at least `minKeptTail` tail messages stay regardless.
    public static func clampToBudget(
        _ messages: [Message],
        protectedPrefix: Int,
        budget: Int,
        minKeptTail: Int = 2,
        countTokens: (String) -> Int
    ) -> [Message] {
        let protectedCount = max(0, min(protectedPrefix, messages.count))
        var total = 0
        for msg in messages { total += countTokens(msg.content ?? "") + 4 }
        guard total > budget else { return messages }

        var drop = 0
        var kept = messages.count - protectedCount
        while total > budget && kept > minKeptTail {
            let idx = protectedCount + drop
            guard idx < messages.count else { break }
            total -= countTokens(messages[idx].content ?? "") + 4
            drop += 1
            kept -= 1
        }
        guard drop > 0 else { return messages }
        return Array(messages[0..<protectedCount]) + Array(messages[(protectedCount + drop)...])
    }

    // MARK: - Cheap pre-pass: prune old tool results (reference Phase 1)

    /// Replace very large tool-result contents in the compressible region
    /// with the reference placeholder. The assistant tool-call row is kept.
    public static func pruneToolResults(_ messages: [Message], maxChars: Int = 3_000) -> [Message] {
        messages.map { msg in
            guard msg.role == .tool, let content = msg.content, content.count > maxChars else { return msg }
            return Message(
                role: .tool,
                content: "[Old tool output cleared to save context space]",
                name: msg.name,
                toolCallID: msg.toolCallID
            )
        }
    }

    // MARK: - Post-pass: orphaned tool_call/tool_result cleanup

    /// Remove tool-result rows whose tool-call id has no surviving assistant
    /// tool call in the list (reference: "orphaned tool_call / tool_result pairs
    /// are cleaned up so the API never receives mismatched IDs").
    public static func orphanCleanup(_ messages: [Message]) -> [Message] {
        var callIDs = Set<String>()
        for msg in messages where msg.role == .assistant {
            // Assistant messages declare calls via `toolCalls`; some legacy
            // shapes also set `toolCallID` directly — accept both.
            if let id = msg.toolCallID { callIDs.insert(id) }
            for call in msg.toolCalls ?? [] {
                callIDs.insert(call.id)
            }
        }
        return messages.filter { msg in
            if msg.role == .tool, let id = msg.toolCallID {
                return callIDs.contains(id)
            }
            return true
        }
    }

    // MARK: - Summary prompt templates (reference _template_sections)

    private static func resolvedQuestionsInstruction(hasUserTurns: Bool) -> String {
        hasUserTurns
            ? "[Questions the user asked that were ALREADY answered — include the "
                + "answer so it is not repeated]"
            : "[Write exactly: None. No user-authored questions exist.]"
    }

    private static func pendingAsksInstruction(hasUserTurns: Bool) -> String {
        hasUserTurns
            ? "[Questions or requests from the user that have NOT yet been answered "
                + "or fulfilled. These are STALE — they were from the compacted turns. "
                + "Write them here for reference only. The agent must NOT act on them "
                + "unless the latest user message explicitly requests it. If none, "
                + "write \"None.\"]"
            : "[Write exactly: None. No user-authored requests exist.]"
    }

    private static func historicalTaskInstruction(hasUserTurns: Bool) -> String {
        guard hasUserTurns else {
            return "[NO user-authored turn exists in this session. Write exactly:\n"
                + "\(noUserTaskSentinel)\n"
                + "Do not write \"User asked:\" or any translated equivalent anywhere "
                + "in the summary. Describe agent/tool work only as completed actions, "
                + "state, or historical work.]"
        }
        return "[THE SINGLE MOST IMPORTANT FIELD. Capture the user's most recent unfulfilled\n"
            + "input verbatim — the exact words they used. This includes:\n"
            + "- Explicit task assignments (\"<specific user task>\")\n"
            + "- Questions awaiting an answer (\"<specific user question>\")\n"
            + "- Decisions awaiting input (\"<option A or B?>\")\n"
            + "- Ongoing discussions where the assistant owes the next substantive reply\n"
            + "A conversation where the user just asked a question IS an active task — the\n"
            + "task is \"answer that question with full context\". Do NOT write \"None\" merely\n"
            + "because the user did not issue an imperative command; reserve \"None\" for the\n"
            + "rare case where the last exchange was fully resolved and the user said\n"
            + "something like \"thanks, that's all\".\n"
            + "If multiple items are outstanding, list only the ones NOT yet completed.\n"
            + "This historical snapshot must identify the latest unresolved user input precisely. Examples:\n"
            + "\"User asked: '<exact latest user request>'\"\n"
            + "\"User asked: '<exact latest user question>' — needs investigation + answer\"\n"
            + "\"User chose <option>; awaiting implementation of <specific next step>\"\n"
            + "If the user's most recent message was a reverse signal (stop, undo, roll\n"
            + "back, never mind, just verify, change of topic) that supersedes earlier\n"
            + "work, write the reverse signal verbatim and DO NOT carry forward the\n"
            + "cancelled task. Example: \"User asked: '<exact reverse signal>' — earlier\n"
            + "in-flight work is cancelled.\"\n"
            + "If no outstanding task exists, write \"None.\"]"
    }

    private static func templateSections(budget: Int, hasUserTurns: Bool) -> String {
        """
        \(historicalHeading)
        \(historicalTaskInstruction(hasUserTurns: hasUserTurns))

        ## Goal
        \(hasUserTurns ? "[What the user is trying to accomplish overall]"
            : "[Historical cron/agent objective inferred only from assistant and tool activity. Never call it a user goal.]")

        ## Constraints & Preferences
        \(hasUserTurns
            ? "[User preferences, coding style, constraints, important decisions]"
            : "[Runtime, configuration, and technical constraints only. Do not invent user preferences.]")

        ## Completed Actions
        [Numbered list of concrete actions taken — include tool used, target, and outcome.
        Format each as: N. ACTION target — outcome [tool: name]
        Example:
        1. READ config.py:45 — found `==` should be `!=` [tool: read_file]
        2. PATCH config.py:45 — changed `==` to `!=` [tool: patch]
        3. TEST `pytest tests/` — 3/50 failed: test_parse, test_validate, test_edge [tool: terminal]
        Be specific with file paths, commands, line numbers, and results.]

        ## Active State
        [Current working state — include:
        - Working directory and branch (if applicable)
        - Modified/created files with brief note on each
        - Test status (X/Y passing)
        - Any running processes or servers
        - Environment details that matter]

        ## Blocked
        [Any blockers, errors, or issues not yet resolved. Include exact error messages.]

        ## Key Decisions
        [Important technical decisions and WHY they were made]

        ## Resolved Questions
        \(resolvedQuestionsInstruction(hasUserTurns: hasUserTurns))

        ## Historical Pending User Asks
        \(pendingAsksInstruction(hasUserTurns: hasUserTurns))

        ## Relevant Files
        [Files read, modified, or created — with brief note on each]

        ## Critical Context
        [Any specific values, error messages, configuration details, or data that would be lost without explicit preservation. NEVER include API keys, tokens, passwords, or credentials — write [REDACTED] instead.]

        Target ~\(budget) tokens. Be CONCRETE — include file paths, command outputs, error messages, line numbers, and specific values. Avoid vague descriptions like \"made some changes\" — say exactly what changed.
        Write only the summary body. Do not include any preamble or prefix.
        """
    }

    /// Result of building a summary prompt.
    public struct SummaryPrompt {
        public let userContent: String
        public let hasUserTurns: Bool
    }

    private static let summarizerPreamble = (
        "You are a summarization agent creating a context checkpoint. "
        + "Treat the conversation turns below as source material for a "
        + "compact record of prior work. "
        + "Produce only the structured summary; do not add a greeting, "
        + "preamble, or prefix. "
        + "Never invent a user, and never translate or attribute any request "
        + "to a user that did not make one. "
        + "NEVER include API keys, tokens, passwords, secrets, credentials, "
        + "or connection strings in the summary — replace any that appear "
        + "with [REDACTED]. Note that credentials were present, but do not "
        + "preserve their values."
    )

    private static func memorySection(_ memoryContext: String) -> String {
        let trimmed = MemoryManager.scrub(memoryContext)
        guard !trimmed.isEmpty else { return "" }
        return "\n\nMEMORY CONTEXT (authoritative reference from persistent memory — do not contradict):\n\(trimmed)"
    }

    private static func focusSection(_ focus: String?) -> String {
        guard let focus, !focus.isEmpty else { return "" }
        return "\n\nFOCUS TOPIC: \"\(focus)\"\n"
            + "This compaction should PRIORITISE preserving all information related to the focus topic above. "
            + "For content related to \"\(focus)\", include full detail — exact values, file paths, command "
            + "outputs, error messages, and decisions. For content NOT related to the focus topic, summarise "
            + "more aggressively (brief one-liners or omit if truly irrelevant). The focus topic sections "
            + "should receive roughly 60-70% of the summary token budget. Even for the focus topic, NEVER "
            + "preserve API keys, tokens, passwords, or credentials — use [REDACTED]."
    }

    /// First compaction: summarize material from scratch.
    public static func firstSummaryPrompt(
        material: [Message],
        focus: String?,
        memoryContext: String,
        summaryBudget: Int = 6_000
    ) -> SummaryPrompt {
        let serialized = Self.compressedRecord(material)
        let hasUser = material.contains { $0.role == .user }
        let content = """
        \(summarizerPreamble)

        Create a structured checkpoint summary for the conversation after earlier turns are compacted. The summary should preserve enough detail for continuity without re-reading the original turns.

        TURNS TO SUMMARIZE:
        \(serialized)\(memorySection(memoryContext))

        Use this exact structure:

        \(templateSections(budget: summaryBudget, hasUserTurns: hasUser))\(focusSection(focus))
        """
        return SummaryPrompt(userContent: content, hasUserTurns: hasUser)
    }

    /// Iterative update: fold the previous summary with new turns.
    public static func updateSummaryPrompt(
        previousSummary: String,
        newTurns: [Message],
        focus: String?,
        memoryContext: String,
        summaryBudget: Int = 6_000
    ) -> SummaryPrompt {
        let serialized = Self.compressedRecord(newTurns)
        let boundedPrevious = boundSummaryInput(previousSummary, budget: summaryBudget)
        let hasUser = newTurns.contains { $0.role == .user }
        let content = """
        \(summarizerPreamble)

        You are updating a context compaction summary. A previous compaction produced the summary below. New conversation turns have occurred since then and need to be incorporated.

        PREVIOUS SUMMARY:
        \(boundedPrevious)

        NEW TURNS TO INCORPORATE:
        \(serialized)\(memorySection(memoryContext))

        Update the summary using this exact structure. PRESERVE all existing information that is still relevant. ADD new completed actions to the numbered list (continue numbering). Move items from "In Progress" to "Completed Actions" when done. Move answered questions to "Resolved Questions". Update "Active State" to reflect current state. Remove information only if it is clearly obsolete. CRITICAL: Update "## Historical Task Snapshot" to reflect the user's most recent unfulfilled input — this includes any question, decision request, or discussion turn that the assistant has not yet answered. Only write "None" if the last exchange was fully resolved.

        \(templateSections(budget: summaryBudget, hasUserTurns: hasUser))\(focusSection(focus))
        """
        return SummaryPrompt(userContent: content, hasUserTurns: hasUser)
    }

    /// Bound the previous-summary block (reference `_bound_summary_input`): a
    /// pathological persisted summary must not blow the prompt budget.
    public static func boundSummaryInput(_ summary: String, budget: Int) -> String {
        let chars = budget * 4
        guard summary.count > chars else { return summary }
        return String(summary.prefix(chars / 2))
            + "\n...[earlier summary truncated]...\n"
            + String(summary.suffix(chars / 2))
    }

    // MARK: - Record serialization

    /// One message rendered as a role-labeled record line, optionally capped
    /// at `maxChars` so a single huge tool result cannot dominate a bounded
    /// extract. Returns nil for empty messages (they carry nothing).
    public static func recordLine(_ msg: Message, maxChars: Int? = nil) -> String? {
        guard let content = msg.content, !content.isEmpty else { return nil }
        let body: String
        if let maxChars, content.count > maxChars {
            body = String(content.prefix(maxChars)) + " …[truncated]"
        } else {
            body = content
        }
        if msg.role == .tool, let name = msg.name {
            return "[Tool \(name)]: \(body)"
        }
        let roleLabel: String
        switch msg.role {
        case .user: roleLabel = "User"
        case .assistant: roleLabel = "Assistant"
        case .system: roleLabel = "System"
        case .tool: roleLabel = "Tool"
        }
        return "[\(roleLabel)]: \(body)"
    }

    /// Render messages as the role-labeled record fed to the summarizer.
    public static func compressedRecord(_ messages: [Message]) -> String {
        messages.compactMap { recordLine($0) }.joined(separator: "\n\n---\n\n")
    }
}
