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
    /// and protected tail (reference `_find_tail_cut_by_tokens`).
    ///
    /// - head: the first `protectFirst` non-system messages (decayed to 0
    ///   by the caller after the first compression — reference #11996).
    /// - tail: walked backward from the end until the soft ceiling
    ///   (`tailBudget × 1.5`) is hit, subject to a minimum floor of
    ///   `minTailFloor` messages (capped so a run of bulky outputs cannot be
    ///   frozen verbatim).
    /// - Boundaries never split a tool_call/tool_result group: if the cut
    ///   lands between an assistant call row and its results, the tail
    ///   extends backward to keep the group atomic.
    /// - The most recent user message always lands in the tail.
    public static func window(
        _ messages: [Message],
        tailBudget: Int,
        minTailFloor: Int = 4,
        protectFirst: Int = 2,
        countTokens: (String) -> Int
    ) -> (head: [Message], middle: [Message], tail: [Message]) {
        let nonSystem = messages.filter { $0.role != .system }
        let head = Array(nonSystem.prefix(min(protectFirst, nonSystem.count)))
        let softCeiling = tailBudget * 3 / 2
        var tailTokens = 0
        var tailCount = 0
        let mid = Array(nonSystem.dropFirst(head.count))
        for msg in mid.reversed() {
            let cost = countTokens(msg.content ?? "") + 4
            // stop conditions: soft ceiling hit, or the soft budget reached
            // once the floor is satisfied
            if tailCount > 0
                && (tailTokens + cost > softCeiling
                    || (tailCount >= minTailFloor && tailTokens >= tailBudget)) {
                break
            }
            tailTokens += cost
            tailCount += 1
            if tailCount >= minTailFloor && tailTokens >= tailBudget { break }
        }
        var tailStart = max(0, mid.count - tailCount)

        // Atomic tool groups: walk the tail start backward while it would
        // orphan a tool result from its parent assistant call.
        func declaresCall(_ msg: Message, id: String) -> Bool {
            guard msg.role == .assistant else { return false }
            if msg.toolCallID == id { return true }
            return (msg.toolCalls ?? []).contains { $0.id == id }
        }
        while tailStart > 0,
              mid[tailStart].role == .tool,
              let callID = mid[tailStart].toolCallID,
              declaresCall(mid[tailStart - 1], id: callID) {
            tailStart -= 1
        }

        // The most recent user message always lands in the tail.
        if let lastUser = mid.lastIndex(where: { $0.role == .user }), lastUser < tailStart {
            tailStart = lastUser
        }

        let tail = Array(mid.suffix(mid.count - tailStart))
        let compressible = Array(mid.prefix(tailStart))
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
    ///
    /// The **latest user message is immutable**: the model cannot answer a
    /// prompt it never sees, so the clamp skips over it instead of dropping
    /// it — even when it is older than trailing tool traffic (a pending
    /// question followed by tool calls is exactly the shape where the old
    /// oldest-first drop erased the request). It may still be summarized by a
    /// LATER pass, after the turn it belongs to has completed.
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

        var lastUserIndex = messages.lastIndex(where: { $0.role == .user })
        var work = messages
        var idx = protectedCount
        var kept = work.count - protectedCount
        while total > budget && kept > minKeptTail && idx < work.count {
            if idx == lastUserIndex {
                // immutable: skip over the pending user request
                idx += 1
                continue
            }
            total -= countTokens(work[idx].content ?? "") + 4
            work.remove(at: idx)
            if let lu = lastUserIndex, lu > idx { lastUserIndex = lu - 1 }
            kept -= 1
        }
        guard work.count < messages.count else { return messages }
        return work
    }

    // MARK: - Cheap pre-pass: prune old tool results (reference Phase 1)

    /// One-line summary for a demoted tool result (reference Phase 1: old
    /// tool results become informative one-liners, not blank placeholders —
    /// "[terminal] npm test → exit 0, 47 lines").
    static func toolResultSummary(_ msg: Message, maxChars: Int = 3_000) -> String {
        let content = msg.content ?? ""
        let tool = msg.name ?? "tool"
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let head = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let brief = head.count > 120 ? String(head.prefix(120)) + "…" : head
        if content.count <= maxChars {
            // Small enough to keep verbatim — nothing to demote.
            return content
        }
        return "[Tool \(tool)]: \(brief) … (pruned: \(lineCount) lines, \(content.count) chars)"
    }

    /// Extract the skill name from a `skill_view` tool result (frontmatter
    /// `name:` line) for the ghost-skill tombstone.
    static func skillName(from content: String) -> String? {
        for line in content.split(separator: "\n").prefix(12) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                let name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return String(name) }
            }
        }
        return nil
    }

    /// Reference Phase 1, applied everywhere EXCEPT the protected tail:
    ///
    /// 1. Demote old tool results to one-line summaries; `skill_view` bodies
    ///    become `[SKILL_PRUNED: name]` tombstones instead of bare summaries
    ///    (the ghost-skill defense keys on the exact marker later).
    /// 2. Deduplicate identical tool results — keep the newest verbatim.
    /// 3. Truncate bulky tool_call arguments in assistant messages.
    ///
    /// Returns nil for a message that is unchanged (callers rebuild rows).
    public static func pruneOutsideTail(
        _ messages: [Message],
        maxChars: Int = 3_000,
        argChars: Int = 1_000
    ) -> [Message] {
        // Dedup map: the last occurrence of each identical tool result stays
        // verbatim; earlier ones are demoted. Keyed on name + content.
        var lastSeen: [String: Int] = [:]
        for (idx, msg) in messages.enumerated() where msg.role == .tool {
            let key = (msg.name ?? "") + "|" + (msg.content ?? "")
            lastSeen[key] = idx
        }

        var out: [Message] = []
        out.reserveCapacity(messages.count)
        for (idx, msg) in messages.enumerated() {
            if msg.role == .tool {
                let key = (msg.name ?? "") + "|" + (msg.content ?? "")
                var content = msg.content ?? ""
                let isSkillView = msg.name == "skill_view"
                if idx != lastSeen[key] {
                    // duplicate of a newer identical result — always demoted,
                    // regardless of size (reference: keep newest verbatim only)
                    content = isSkillView
                        ? "[SKILL_PRUNED: \(skillName(from: content) ?? "unknown")]"
                        : toolResultSummary(msg, maxChars: 0)
                } else if isSkillView, content.count > maxChars {
                    content = "[SKILL_PRUNED: \(skillName(from: content) ?? "unknown")]"
                } else if content.count > maxChars {
                    content = toolResultSummary(msg, maxChars: maxChars)
                }
                if content != msg.content {
                    out.append(Message(
                        role: .tool,
                        content: content,
                        name: msg.name,
                        toolCallID: msg.toolCallID
                    ))
                    continue
                }
                out.append(msg)
                continue
            }
            if msg.role == .assistant, let calls = msg.toolCalls, !calls.isEmpty {
                var changed = false
                var newCalls: [ToolCall] = []
                newCalls.reserveCapacity(calls.count)
                for call in calls {
                    if call.function.arguments.count > argChars {
                        newCalls.append(ToolCall(
                            id: call.id,
                            type: call.type,
                            function: ToolCallFunction(
                                name: call.function.name,
                                arguments: String(call.function.arguments.prefix(argChars)) + " …[args truncated]"
                            )
                        ))
                        changed = true
                    } else {
                        newCalls.append(call)
                    }
                }
                if changed {
                    out.append(Message(
                        role: .assistant,
                        content: msg.content,
                        toolCalls: newCalls,
                        createdAt: msg.createdAt,
                        reasoning: msg.reasoning,
                        usage: msg.usage
                    ))
                    continue
                }
                out.append(msg)
                continue
            }
            out.append(msg)
        }
        return out
    }

    /// Legacy single-region variant kept for the pluggable engine and tests:
    /// prune one contiguous region (typically the compressible middle).
    public static func pruneToolResults(_ messages: [Message], maxChars: Int = 3_000) -> [Message] {
        pruneOutsideTail(messages, maxChars: maxChars)
            .map { msg in
                // the legacy contract used the reference placeholder text
                guard msg.role == .tool,
                      let content = msg.content,
                      content.hasPrefix("[Tool "),
                      content.contains("… (pruned: ") else { return msg }
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

    // MARK: - Reference helpers: redaction, ghost skills, pressure, echo rows

    /// Deterministic secret redaction applied at serialization time
    /// (reference `_serialize_for_summary`): common credential shapes and
    /// labeled values become [REDACTED] before anything reaches the
    /// summary LLM — the prompt's instruction alone is not a guarantee.
    static let secretPatterns: [NSRegularExpression] = [
        // labeled assignments: api_key = ..., Authorization: Bearer x, password: ...
        try! NSRegularExpression(
            pattern: #"(?i)\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|pwd|token|credential|private[_-]?key|client[_-]?secret|bearer)\b\s*[:=]\s*")[^"]{8,}"([^"]|$)"#),
        try! NSRegularExpression(
            pattern: #"(?i)\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|pwd|token|credential|private[_-]?key|client[_-]?secret)\b\s*[:=]\s*')[^']{8,}'"#),
        try! NSRegularExpression(
            pattern: #"(?i)\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|pwd|token|credential|private[_-]?key|client[_-]?secret)\b\s*[:=]\s*)[^\s"']{8,}"#),
        // bearer headers
        try! NSRegularExpression(pattern: #"(?i)bearer\s+[a-z0-9._\-]{16,}"#),
        // well-known token shapes
        try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_\-]{16,}"#),
        try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
        try! NSRegularExpression(pattern: #"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#),
        try! NSRegularExpression(pattern: #"\bAKIA[0-9A-Z]{16}\b"#),
    ]

    /// Redact secret-shaped text. Best-effort line-level defense; the
    /// summarizer prompt still instructs [REDACTED] as the second layer.
    public static func redactSecrets(_ text: String) -> String {
        var out = text
        for regex in secretPatterns {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1[REDACTED]$2"
            )
        }
        return out
    }

    /// Ghost-skill defense (reference `_reinject_pruned_skill_markers`):
    /// collect the exact `[SKILL_PRUNED: name]` markers from the material
    /// deterministically BEFORE the summarizer call (LLMs paraphrase them
    /// into "some skills were loaded", erasing the reload instruction).
    public static func collectSkillMarkers(_ messages: [Message]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for msg in messages {
            guard let content = msg.content else { continue }
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("[SKILL_PRUNED: "), trimmed.hasSuffix("]") else { continue }
                if seen.insert(trimmed).inserted { ordered.append(trimmed) }
            }
        }
        return ordered
    }

    /// Reinject the exact markers into a summary that lost them.
    public static func reinjectSkillMarkers(_ summary: String, markers: [String]) -> String {
        guard !markers.isEmpty else { return summary }
        let missing = markers.filter { !summary.contains($0) }
        guard !missing.isEmpty else { return summary }
        return summary
            + "\n\nPRUNED SKILLS — these were loaded earlier and then pruned from "
            + "context; if needed again they must be re-read via skill_view "
            + "before any reliance on their contents:\n"
            + missing.joined(separator: "\n")
    }

    /// Strip blank platform-echo user rows trailing the latest actionable
    /// turn (reference: done deliberately before any abort point so even an
    /// aborted compression keeps this win).
    public static func stripTrailingBlankUserRows(_ messages: [Message]) -> [Message] {
        var result = messages
        while let last = result.last,
              last.role == .user,
              (last.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeLast()
        }
        return result
    }

    /// Pass 4 — pressure demotion (reference `_prune_old_tool_results`):
    /// fires only when the protected region alone exceeds
    /// `tailBudget × 1.5`. Overrides skill protections in the tail and keeps
    /// a short recent floor (`keepLast`) verbatim.
    public static func pressureDemote(
        _ head: [Message],
        _ tail: [Message],
        tailBudget: Int,
        countTokens: (String) -> Int,
        keepLast: Int = 4
    ) -> (head: [Message], tail: [Message], fired: Bool) {
        let protectedTokens =
            head.reduce(0) { $0 + countTokens($1.content ?? "") + 4 }
            + tail.reduce(0) { $0 + countTokens($1.content ?? "") + 4 }
        guard protectedTokens > tailBudget * 3 / 2 else {
            return (head, tail, false)
        }
        let demoteUpTo = max(0, tail.count - min(keepLast, max(1, tail.count - 1)))
        let demotedTail = tail.enumerated().map { idx, msg -> Message in
            guard msg.role == .tool, idx < demoteUpTo else { return msg }
            return Message(
                role: .tool,
                content: toolResultSummary(msg, maxChars: 0),
                name: msg.name,
                toolCallID: msg.toolCallID
            )
        }
        return (head, demotedTail, true)
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
    /// Secrets are redacted deterministically here (reference
    /// `_serialize_for_summary`), before anything reaches the aux model.
    public static func compressedRecord(_ messages: [Message]) -> String {
        messages.compactMap { recordLine($0) }
            .map { redactSecrets($0) }
            .joined(separator: "\n\n---\n\n")
    }
}
