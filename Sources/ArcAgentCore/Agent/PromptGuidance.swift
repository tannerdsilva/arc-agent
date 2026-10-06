import Foundation

// MARK: - Prompt Guidance (arc parity: hermes-agent `agent/prompt_builder.py`)

/// Universal behavioral guidance ported from the hermes-agent system prompt
/// and injected into ARC's stable prompt tier (cache-friendly). These are
/// the blocks that make the agent finish the job, batch independent tool
/// calls, and use its persistence tools correctly — without them, models
/// (notably DeepSeek v4-flash, ARC's reference model) fabricate results,
/// stop after stubs, and emit one tool call per turn.
enum PromptGuidance {

    /// `TASK_COMPLETION_GUIDANCE` — deliverable = working artifact backed by
    /// real tool output; never fabricate; report blockers honestly.
    static let taskCompletion = """
        ## Finishing the job

        When the user asks you to build, run, or verify something, the deliverable is a working
        artifact backed by real tool output — not a description of one. Do not stop after writing
        a stub, a plan, or a single command. Keep working until you have actually exercised the
        code or produced the requested result, then report what real execution returned.

        If a tool, install, or network call fails and blocks the real path, say so directly and
        try an alternative (different package manager, different approach, ask the user). NEVER
        substitute plausible-looking fabricated output (made-up data, invented file contents,
        synthesized API responses) for results you couldn't actually produce. Reporting a blocker
        honestly is always better than inventing a result.
        """

    /// `PARALLEL_TOOL_CALL_GUIDANCE` — batch independent calls into one turn.
    static let parallelToolCalls = """
        ## Parallel tool calls

        When you need several pieces of information that don't depend on each other, request
        them together in a single response instead of one tool call per turn. Independent reads,
        searches, web fetches, and read-only commands should be batched into the same assistant
        turn — the runtime executes independent calls concurrently, and batching avoids resending
        the whole conversation on every extra round-trip.

        Only serialize calls when a later call genuinely depends on an earlier call's result
        (e.g. you must read a file before you can patch it). When in doubt and the calls are
        independent, batch them.
        """

    /// `MEMORY_GUIDANCE` — what belongs in durable memory (and what doesn't).
    static let memory = """
        You have persistent memory across sessions. Save durable facts using the memory tool:
        user preferences, environment details, tool quirks, and stable conventions. Memory is
        injected into every turn, so keep it compact and focused on facts that will still matter
        later.

        Prioritize what reduces future user steering — the most valuable memory is one that
        prevents the user from having to correct or remind you again. User preferences and
        recurring corrections matter more than procedural task details.

        Do NOT save task progress, session outcomes, completed-work logs, or temporary TODO
        state to memory; use session_search to recall those from past transcripts. Specifically:
        do not record PR numbers, issue numbers, commit SHAs, "fixed bug X", "submitted PR Y",
        "Phase N done", file counts, or any artifact that will be stale in 7 days. If a fact
        will be stale in a week, it does not belong in memory. If you've discovered a new way
        to do something, solved a problem that could be necessary later, save it as a skill.

        Write memories as declarative facts, not instructions to yourself. "User prefers concise
        responses" — yes; "Always respond concisely" — no. Imperative phrasing gets re-read as a
        directive in later sessions and can cause repeated work or override the user's current
        request. Procedures and workflows belong in skills, not memory.
        """

    /// `SESSION_SEARCH_GUIDANCE` — recall past sessions before asking to repeat.
    static let sessionSearch = """
        When the user references something from a past conversation or you suspect relevant
        cross-session context exists, use session_search to recall it before asking them to
        repeat themselves.
        """

    /// `SKILLS_GUIDANCE` — keep skills maintained; the pruned-skill safety rule.
    static let skills = """
        After completing a complex task (5+ tool calls), fixing a tricky error, or discovering
        a non-trivial workflow, save the approach as a skill with skill_manage so you can reuse
        it next time.

        When using a skill and finding it outdated, incomplete, or wrong, patch it immediately
        with skill_manage(action='patch') — don't wait to be asked. Skills that aren't
        maintained become liabilities.

        ## Skill Safety Rule
        1. **UNAVAILABLE** — If a skill placeholder contains `[SKILL_PRUNED]`, the skill content
           was lost in compression and is inaccessible.
        2. **RELOAD** — Before performing any action that depends on a skill, re-check its
           content with skill_view(name='...') if it shows `[SKILL_PRUNED]`.
        3. **WAIT** — If a skill is loading or was just pruned, wait for the reload confirmation
           before proceeding.
        4. **DEDUP** — After reloading a pruned skill, ignore any remaining `[SKILL_PRUNED]`
           markers for that same skill — they are historical artifacts from previous compactions
           and do not need further action.
        """

    /// The tool-aware blocks, concatenated (Hermes joins them into one block).
    static func toolAware(hasMemory: Bool, hasSessionSearch: Bool, hasSkillTools: Bool) -> [String] {
        var blocks: [String] = []
        if hasMemory { blocks.append(memory) }
        if hasSessionSearch { blocks.append(sessionSearch) }
        if hasSkillTools { blocks.append(skills) }
        return blocks
    }
}
