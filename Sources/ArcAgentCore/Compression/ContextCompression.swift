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

    /// Render messages as the role-labeled record fed to the summarizer.
    public static func compressedRecord(_ messages: [Message]) -> String {
        messages.compactMap { msg -> String? in
            guard let content = msg.content, !content.isEmpty else { return nil }
            let roleLabel: String
            switch msg.role {
            case .user: roleLabel = "User"
            case .assistant: roleLabel = "Assistant"
            case .system: roleLabel = "System"
            case .tool: roleLabel = "Tool"
            }
            var line = "[\(roleLabel)]: \(content)"
            if msg.role == .tool, let name = msg.name {
                line = "[Tool \(name)]: \(content)"
            }
            return line
        }.joined(separator: "\n\n---\n\n")
    }
}
