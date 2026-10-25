import ArcAgentCore
import ArcSidebarTabs
import ArcTheme
import Foundation
import Synchronization
import WebUI
import WebUIDesignSystem

// MARK: - AppState extensions (turn engine)

extension AppState {

    /// Render fragments for the panels/main/toasts after a state change.
    func refreshFragments(includeApp: Bool = false) async -> [FragmentUpdate] {
        if includeApp {
            let shell = await appShell()
            let toasts = toastsShell()
            return [
                fragment("app", shell),
                fragment("toasts", toasts),
            ]
        }
        var u: [FragmentUpdate] = [
            fragment("iconbar", iconbarHTML()),
            fragment("topbar", topbarHTML()),
            fragment("panel", await panelHTML()),
            FragmentUpdate(id: "main", html: render(await mainContentHTML())),
        ]
        // The right-hand workspace panel follows the active chat's workspace,
        // so re-render it on session switches and workspace changes too.
        u.append(fragment("ws-dock", workspaceDockHTML()))
        u.append(fragment("ws-panel", workspacePanelHTML()))
        // push the SHELL: the engine's replaceElement removes a target when the
        // fragment is empty, so an inner-only push of "no toasts" would delete
        // #toasts for the rest of the session and swallow every later toast.
        u.append(fragment("toasts", toastsShell()))
        u.append(fragment("modal-root", modalRootHTML()))
        return u
    }

    /// Iterated when the Logs view or its controls change: re-render the left
    /// panel (stats + filter chips) and the live log box.
    /// Standard refresh plus the left iconbar (rail). Needed whenever sidebar
    /// tab visibility or order changes — refreshFragments alone leaves the
    /// rail untouched.
    func fragmentsWithIconbar() async -> [FragmentUpdate] {
        // refreshFragments already carries the rail (iconbar), so the standard
        // targeted refresh is the full shell now.
        return await refreshFragments()
    }

    func logsFragments() async -> [FragmentUpdate] {
        [
            fragment("topbar", topbarHTML()),
            fragment("panel", await panelHTML()),
            fragment("log-lines", logLinesBox()),
        ]
    }

    /// Execute one tool call and return its result string. Terminal commands
    /// are gated by ApprovalManager (reference smart approval): dangerous ones
    /// pause on a permission card until the user approves or denies.
    ///
    /// This is the **ambient** path only: `execute_code` children dispatch back
    /// into this session through `ambientToolHost`, which is bound as the turn
    /// agent's code host. Every agent-dispatched tool call goes through
    /// `ArcAgent` instead, which binds `WorkspacePath.$root` itself.
    ///
    /// The `withValue` wrappers below therefore **stay**: the ambient host is
    /// invoked from `ToolRPCServer`'s NIO channel handler
    /// (`makeFutureWithTask` on the event loop), so the dispatch task's
    /// `WorkspacePath.$root` TaskLocal does not reach it. Removing them would
    /// resolve the child's relative paths against the process cwd.
    func runTool(_ call: ToolCall, sessionID: String, pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void, headless: Bool = false) async -> String {
        // Ambient dispatcher for execute_code: child Python processes dispatch
        // tools back into THIS webui session (same registry, guardrails, and
        // approval flows), bound to the session this tool call belongs to.
        // The process-wide box stays the single-agent fallback rung; a minted
        // turn agent gets its own host through `setCodeHost` (A6).
        await ExecuteCodeTool.dispatcher.setHost(
            ambientToolHost(sessionID: sessionID, headless: true, pusher: { _ in }))
        guard let tool = registry.lookup(name: call.function.name) else {
            return "Error: tool '\(call.function.name)' is not registered."
        }
        var args: [String: Any] = [:]
        if let data = call.function.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = obj
        }
        // Tool guardrails (reference tool_guardrails parity): per-turn budgets,
        // repeated-call detection, and synthetic results. `argsBox` carries the
        // non-Sendable args across the tool-handler boundary (the swift-6 idiom
        // ArcAgentCore already uses).
        let argsBox = NonSendableBox(args)
        switch await guardrails.decide(toolName: call.function.name, args: argsBox) {
        case .synthetic(let message):
            return message
        case .allow:
            break
        }
        // arc-parity approval gate for the terminal tool.
        if tool.name == "terminal",
           let command = args["command"] as? String,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let manager = approvalManager,
           await manager.needsApproval(command: command, sessionKey: sessionID, yolo: isYolo(sessionID)) {
            if headless {
                // Scheduled jobs run autonomously: nobody can answer a card, so
                // the pure policy decides. A critical command is refused on the
                // detector's verdict alone — the manager is not consulted, so no
                // presenter can ever approve one. Everything else proceeds and
                // the run is logged to the job session.
                let level = await detectDangerLevel(command)
                if case .block(let message) = HeadlessApprovalPolicy.verdict(dangerLevel: level) {
                    LogCollector.shared.append(level: .warning, text: "[cron] blocked critical command: \(trunc(command, 120))")
                    return message
                }
                let approval = await manager.requestApproval(
                    command: command,
                    description: "Scheduled: `\(trunc(command, 100))`",
                    sessionKey: sessionID
                )
                if case .block(let message) = HeadlessApprovalPolicy.verdict(
                    dangerLevel: level, approval: approval
                ) {
                    LogCollector.shared.append(level: .warning, text: "[cron] blocked critical command: \(trunc(command, 120))")
                    return message
                }
                return (try? await WorkspacePath.$root.withValue(workspacePath(for: sessionID)) {
                    try await tool.handler(argsBox.value)
                }) ?? "Error: tool execution failed"
            }
            switch await manager.requestApproval(
                command: command,
                description: "Run `\(trunc(command, 100))`",
                sessionKey: sessionID
            ) {
            case .denied:
                return "Error: command blocked by approval policy (classified dangerous)."
            case .requiresReview:
                let granted = await requestUserApproval(
                    command: command,
                    description: "Run `\(trunc(command, 100))`",
                    sessionID: sessionID,
                    pusher: pusher
                )
                if !granted {
                    return "Error: command rejected by user approval."
                }
            case .approved:
                break
            }
        }
        // arc-parity clarify tool: the webui intercepts the tool call and
        // renders the "Clarification needed" card above the composer. The
        // answer (or the 120 s best-judgement fallback) becomes the tool result.
        if tool.name == "clarify" {
            return await requestUserClarification(call: call, sessionID: sessionID, pusher: pusher)
        }
        do {
            let result = try await WorkspacePath.$root.withValue(workspacePath(for: sessionID)) {
                try await tool.handler(argsBox.value)
            }
            recordSkillToolUse(toolName: call.function.name, args: args)
            return result
        } catch {
            return "Error: \(error)"
        }
    }

    /// Pause the running turn on a permission card until the user clicks
    /// Approve / Deny (or stops the turn). Returns true when approved.
    func requestUserApproval(command: String, description: String, sessionID: String, pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void) async -> Bool {
        guard activeTurns[sessionID] != nil else { return false }
        let stream = AsyncStream<Bool>.makeStream()
        pendingApproval = PendingApproval(command: command, description: description, sessionID: sessionID, continuation: stream.continuation)
        activeTurns[sessionID]?.status = "approval"
        await pusher(await liveFragments())
        for await granted in stream.stream {
            activeTurns[sessionID]?.status = "running"
            await pusher(await liveFragments())
            return granted
        }
        activeTurns[sessionID]?.status = "running"
        return false
    }

    /// arc-parity clarify request: the agent's `clarify` tool pauses the
    /// turn and the webui renders the "Clarification needed" card above the
    /// composer with a 120 s countdown. The answer (or the best-judgement
    /// timeout notice) is returned as the tool result.
    func requestUserClarification(call: ToolCall, sessionID: String, pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void) async -> String {
        guard activeTurns[sessionID] != nil else {
            return "Error: no active turn to clarify in."
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any]
        let question = (args?["question"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !question.isEmpty else {
            return "Error: clarify requires a question."
        }
        let choices = Array(((args?["choices"] as? [String]) ?? []).prefix(4))
        // the turn exists (checked above), so the card path answers.
        return await requestUserClarification(
            question: question,
            choices: choices,
            sessionID: sessionID,
            pusher: pusher
        ) ?? Self.clarifyTimeoutText
    }

    /// The clarify card itself, without the tool-call parsing — the shape a
    /// per-turn ``ClarifyTool`` presenter needs (CONVERGE A6).
    ///
    /// `nil` means there is no live turn to clarify in; ``ClarifyTool`` reads
    /// that as "use your best judgement and proceed", which is the honest
    /// answer when no human can be reached.
    func requestUserClarification(
        question rawQuestion: String,
        choices rawChoices: [String],
        sessionID: String,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) async -> String? {
        guard activeTurns[sessionID] != nil else {
            return nil
        }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return "Error: clarify requires a question."
        }
        let choices = Array(rawChoices.prefix(4))
        let timeout = Self.clarifyTimeoutSeconds()

        let stream = AsyncStream<String>.makeStream()
        let now = Date()
        pendingClarify = PendingClarify(
            question: question,
            choices: choices,
            sessionID: sessionID,
            continuation: stream.continuation,
            expiresAt: now.addingTimeInterval(timeout)
        )
        activeTurns[sessionID]?.status = "clarify"
        await pusher(await liveFragments())

        // 120 s deadline: on timeout, finish the request with the
        // best-judgement notice (reference smart-mode fallback).
        let expiresAt = now.addingTimeInterval(timeout)
        clarifyTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self else { return }
            await self.finishClarifyTimeout(sessionID: sessionID, expiresAt: expiresAt)
        }

        var answer = Self.clarifyTimeoutText
        for await value in stream.stream {
            answer = value
            break
        }
        clarifyTimerTask?.cancel()
        clarifyTimerTask = nil
        activeTurns[sessionID]?.status = "running"
        await pusher(await liveFragments())
        return answer
    }

    /// Clarify timeout in seconds (reference default: 120). Overridable via the
    /// `ARC_CLARIFY_TIMEOUT` environment variable for tests.
    static func clarifyTimeoutSeconds() -> Double {
        if let raw = ProcessInfo.processInfo.environment["ARC_CLARIFY_TIMEOUT"],
           let v = Double(raw), v > 0 {
            return v
        }
        return 120
    }

    // MARK: - Turn presenter wiring (CONVERGE A6)

    /// Mint this turn's agent and wire the presenters it runs with: A5's
    /// factory plus the three bindings below. This is the entry point the turn
    /// loop uses once it runs on `streamTurn` — `makeTurnAgent` alone stays the
    /// configuration seam, so it can be pinned without a socket or a pusher.
    ///
    /// - Parameters:
    ///   - headless: Whether this turn runs without a human in the loop. It
    ///     decides the approval policy (card vs scheduler) and whether clarify
    ///     is bound at all.
    ///   - pusher: The turn's fragment pusher. The permission and clarify cards
    ///     are pushed through it, exactly as the UI's own gating does.
    ///   - maxIterations: The turn's tool-iteration budget (nil = session
    ///     policy). A scheduled job keeps its own cap through here.
    func makeTurnAgent(
        preset: ModelConfigPreset,
        profileContext: ProfileContextConfig?,
        thinking: String,
        headless: Bool,
        sessionID: String,
        initialHistory: [Message]? = nil,
        maxIterations: Int? = nil,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) async -> (agent: ArcAgent, config: ArcAgent.Configuration) {
        let minted = await makeTurnAgent(
            preset: preset,
            profileContext: profileContext,
            thinking: thinking,
            headless: headless,
            sessionID: sessionID,
            initialHistory: initialHistory,
            maxIterations: maxIterations
        )
        await installTurnPresenters(
            on: minted.agent,
            sessionID: sessionID,
            headless: headless,
            pusher: pusher
        )
        return minted
    }

    /// Install the three per-turn bindings on a minted agent.
    ///
    /// `ArcAgent` binds `ClarifyTool.$presenter` and `ExecuteCodeTool.$host`
    /// around the turn from these stored values (A3), and consults the approval
    /// presenter from its own `ApprovalManager`. Handing them over here — rather
    /// than binding the TaskLocals at the call site — keeps the binding scoped to
    /// the turn the agent runs, so two concurrent turns cannot cross-talk.
    func installTurnPresenters(
        on agent: ArcAgent,
        sessionID: String,
        headless: Bool,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) async {
        let presenters = turnPresenters(sessionID: sessionID, headless: headless, pusher: pusher)
        await agent.setApprovalPresenter(presenters.approval)
        await agent.setClarifyPresenter(presenters.clarify)
        await agent.setCodeHost(presenters.codeHost)
    }

    /// The presenters a turn agent runs with, as values — so a test can drive
    /// them without an agent, a socket or an LLM.
    func turnPresenters(
        sessionID: String,
        headless: Bool,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) -> TurnPresenters {
        TurnPresenters(
            approval: turnApprovalPresenter(sessionID: sessionID, headless: headless, pusher: pusher),
            // headless: nobody can answer a clarify card, so the tool keeps its
            // historic "not available in this execution context" answer instead
            // of a binding that could pretend a human replied.
            clarify: headless ? nil : turnClarifyPresenter(sessionID: sessionID, pusher: pusher),
            codeHost: ambientToolHost(sessionID: sessionID, headless: headless, pusher: pusher)
        )
    }

    /// The approval presenter for this turn.
    ///
    /// Interactive: the existing permission card (`requestUserApproval`) — the
    /// turn pauses, the user clicks, the click becomes the decision. A turn with
    /// no live entry denies: nothing can answer the card, so the command must
    /// not run.
    ///
    /// Headless: `HeadlessApprovalPolicy` decides, and no card is ever posted —
    /// a scheduled job has nobody to ask, and a card it cannot answer is a hang,
    /// not a safeguard.
    func turnApprovalPresenter(
        sessionID: String,
        headless: Bool,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) -> ApprovalPresenter {
        if headless {
            return { request in
                // classify the command, not the arguments wrapper: the
                // detector's critical patterns include an anchored form
                // (`^rm\s+-rf\s+/\s*$`) that cannot match inside json, and a
                // headless turn has no second line of defence.
                let command = Self.approvalCommand(for: request)
                let decision = HeadlessApprovalPolicy.decision(
                    dangerLevel: await detectDangerLevel(command)
                )
                if case .deny = decision {
                    LogCollector.shared.append(level: .warning, text: "[cron] blocked critical command: \(trunc(command, 120))")
                }
                return decision
            }
        }
        return { [weak self] request in
            guard let self else { return .deny }
            let granted = await self.requestUserApproval(
                command: Self.approvalCommand(for: request),
                description: request.description,
                sessionID: sessionID,
                pusher: pusher
            )
            return granted ? .approve : .deny
        }
    }

    /// The command text a card shows for an approval request.
    ///
    /// `ApprovalRequest.command` is the tool call's raw arguments JSON (the core
    /// gates the whole call), so a `terminal` request arrives wrapped. The card
    /// is a command card, so unwrap it; anything unrecognised is shown verbatim,
    /// never hidden.
    static func approvalCommand(for request: ApprovalRequest) -> String {
        guard let data = request.command.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return request.command }
        return command
    }

    /// The clarify presenter for this turn: the existing clarify card, keyed to
    /// this turn's session.
    func turnClarifyPresenter(
        sessionID: String,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) -> ClarifyTool.Presenter {
        { [weak self] question, choices in
            guard let self else { return nil }
            return await self.requestUserClarification(
                question: question,
                choices: choices,
                sessionID: sessionID,
                pusher: pusher
            )
        }
    }

    /// The executor an `execute_code` child dispatches through: this session's
    /// registry, guardrails and approval path.
    ///
    /// The process-wide `ExecuteCodeTool.dispatcher` box is the single-agent
    /// fallback rung; a turn agent gets this one instead, so a child process
    /// cannot dispatch into a sibling turn's session, guardrails or approvals.
    func ambientToolHost(
        sessionID: String,
        headless: Bool,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) -> @Sendable (String, [String: Any]) async throws -> String {
        { [weak self] name, args in
            guard let self else {
                throw ToolError.execution("webui host deallocated")
            }
            let data = try JSONSerialization.data(withJSONObject: args)
            let ambient = ToolCall(
                id: "ambient-\(name)", type: "function",
                function: .init(
                    name: name,
                    arguments: String(data: data, encoding: .utf8) ?? "{}"))
            return await self.runTool(
                ambient, sessionID: sessionID, pusher: pusher, headless: headless)
        }
    }

    // MARK: Context compression (arc parity)

    /// Rough token estimate for a message list (chars/4 + overhead).
    func estimateTokens(_ msgs: [Message]) -> Int {
        var n = 0
        for m in msgs {
            n += (m.content?.count ?? 0) / 4
            n += (m.reasoning?.count ?? 0) / 4
            n += 60
        }
        return n
    }

    /// Extractive record of older messages (fallback summary).
    func extractiveRecord(_ msgs: [Message]) -> String {
        msgs.compactMap { m -> String? in
            guard let c = m.content, !c.isEmpty else { return nil }
            let roleLabel: String
            switch m.role {
            case .system: roleLabel = "system"
            case .user: roleLabel = "user"
            case .assistant: roleLabel = "assistant"
            case .tool: roleLabel = m.name ?? "tool"
            }
            return "[\(roleLabel)] \(trunc(c, 900))"
        }
        .joined(separator: "\n")
    }

    /// Rebuild a model-facing history: system messages + the compression
    /// summary + the most recent 10 messages.
    static func compressedHistory(_ msgs: [Message], summary: String) -> [Message] {
        let systemMessages = msgs.filter { $0.role == .system }
        let nonSystem = msgs.filter { $0.role != .system }
        let recent = Array(nonSystem.suffix(min(10, nonSystem.count)))
        let summaryMessage = Message(
            role: .system,
            content: """
            The following is a compressed record of earlier conversation context. Key information, decisions, and facts from these exchanges are preserved below:

            \(summary)
            """
        )
        return systemMessages + [summaryMessage] + recent
    }

    /// arc-parity context compression. When the token estimate exceeds the
    /// budget, the `compression` auxiliary model (Qwen3.6 in the default
    /// config) summarizes the older tail and a recent window replaces it in
    /// the model-facing history. The durable session transcript stays intact;
    /// the summary is stored once per session. Env ARC_COMPRESSION_BUDGET
    /// overrides the default 32k budget (used by tests).
    func compressHistoryIfNeeded(_ msgs: [Message], sessionID: String) async -> ([Message], Bool) {
        guard !msgs.isEmpty else { return (msgs, false) }
        // Per-profile compression budget: the bound profile's setting wins,
        // then the env override, then the 32k default.
        let budget = compressionBudget(for: sessionID)
        guard estimateTokens(msgs) > budget else { return (msgs, false) }
        if let existing = settings.sessionCompressions[sessionID] {
            return (Self.compressedHistory(msgs, summary: existing), true)
        }
        let nonSystem = msgs.filter { $0.role != .system }
        let minRecent = min(10, nonSystem.count)
        let compressible = Array(nonSystem.prefix(nonSystem.count - minRecent))
        guard !compressible.isEmpty else { return (msgs, false) }

        let record = extractiveRecord(compressible)
        var summary = record
        if arcConfig.auxiliary.override(for: .compression)?.isSet == true,
           httpClient != nil,
           let client = makeAuxClient(for: .compression, sessionID: sessionID) {
            let prompt = """
            You are the context compressor for a long agent conversation. Produce a dense summary
            of the conversation excerpts below. Preserve every decision, fact, path, tool result,
            and instruction verbatim where practical. Target 150-400 words.

            \(record)
            """
            if let out = try? await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil,
                reasoningEffort: nil
            ).content,
            !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summary = out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        settings.sessionCompressions[sessionID] = summary
        saveSettings()
        return (Self.compressedHistory(msgs, summary: summary), true)
    }

    // MARK: - Core-service integrations (arc parity)

    /// Per-turn tool guardrails, rebuilt from `~/.arc/config.json` at the
    /// start of every turn so `guardrails.toolLoopCap` edits apply without a
    /// restart (reference reads config per request too).
    private static func freshGuardrails() -> ToolGuardrails {
        ToolGuardrails(limits: .init(loopCap: Self.rawArcConfig().effectiveToolLoopCap()))
    }

    // MARK: - Tool-iteration budget (reference `max_turns` parity)

    /// reference `AIAgent` default tool-calling iterations (agent_init.py:470).
    static let defaultMaxTurns = 90

    /// The tool-iteration budget for a turn, read per-turn from
    /// `~/.arc/config.json` so edits apply without a restart (reference reads the
    /// config per request too). Key precedence matches reference
    /// (`api/streaming.py`): `agent.max_turns` → legacy root `max_turns` →
    /// `agent.maxIterations` (arc-agent's own key) → default 90. A value of
    /// `0`/negative means **unlimited** (the turn runs until the prompt
    /// finishes); the settings UI writes `-1` for that state.
    static func effectiveMaxTurns() -> Int {
        Self.rawArcConfig().effectiveMaxTurns()
    }

    /// arc parity: when the tool-iteration budget is exhausted, append the
    /// same nudge reference uses (`chat_completion_helpers.py`), take ONE final
    /// no-tools call for the closing summary, and mark the reply with
    /// `terminalReason = "max_iterations"` so the UI shows the status card.
    /// Persist a message to the store, surfacing failures to the Logs panel AND
    /// healing the one recoverable case: a "ghost" session — the UI still renders
    /// it from the in-memory cache while its store file is gone, so every append
    /// fails `notFound` and the turn is lost silently. The heal rebuilds the
    /// store entry from the most complete in-memory snapshot (the running turn's
    /// `healWith` history when given, else the materialized cache) and retries
    /// the append once.
    func persistMessage(
        _ message: Message,
        sessionID: String,
        store: (any SessionStore)?,
        healWith history: [Message]? = nil
    ) async {
        guard let store else { return }
        do {
            try await store.appendMessage(sessionID: sessionID, message: message)
        } catch SessionError.notFound {
            switch await healGhostSession(sessionID: sessionID, store: store, history: history, pending: message) {
            case .landed:
                break
            case .retry:
                do {
                    try await store.appendMessage(sessionID: sessionID, message: message)
                } catch {
                    LogCollector.shared.append(level: .error, text: "[store] persist still failing after ghost recovery for session \(String(sessionID.prefix(8))): \(error)")
                    _ = toast("A message could not be saved — see Logs.", kind: "error")
                }
            case .dropped:
                LogCollector.shared.append(level: .error, text: "[store] ghost-session recovery failed for \(String(sessionID.prefix(8))) — message dropped: \(message.role.rawValue)")
                _ = toast("A message could not be saved — the chat's store file was missing and recovery failed. See Logs.", kind: "error")
            }
        } catch {
            LogCollector.shared.append(level: .error, text: "[store] failed to persist \(message.role.rawValue) message for session \(String(sessionID.prefix(8))): \(error)")
            _ = toast("A message could not be saved (store error) — see Logs.", kind: "error")
        }
    }

    /// Outcome of a ghost-session heal attempt.
    private enum GhostHealOutcome {
        /// The store entry exists again and already contains the pending message
        /// (the in-memory transcript included it) — nothing further to append.
        case landed
        /// The store entry exists again but lacks the pending message — retry the append.
        case retry
        /// The store entry could not be re-created.
        case dropped
    }

    /// Rebuild a missing session file from the best in-memory snapshot: the
    /// running turn's history when it is a superset of the cached transcript,
    /// else the materialized cache. Also keeps the session in `sessions` so its
    /// sidebar row does not vanish while the chat is open.
    private func healGhostSession(
        sessionID: String,
        store: any SessionStore,
        history: [Message]?,
        pending: Message
    ) async -> GhostHealOutcome {
        var snapshot = sessions.first(where: { $0.id == sessionID })
            ?? Session(id: sessionID, title: "Recovered chat")
        if let history, history.count >= snapshot.messages.count, !history.isEmpty {
            snapshot.messages = history
        }
        if snapshot.messages.isEmpty { snapshot.messages = [pending] }
        snapshot.updatedAt = Date()
        snapshot.messageCount = snapshot.messages.count
        // Callers append to their in-memory transcript before persisting, so the
        // snapshot usually already ends with the message that failed to land — a
        // retry would duplicate it. Only retry when it is genuinely absent.
        let alreadyLanded = snapshot.messages.last == pending
        do {
            try await store.create(snapshot)
            if !sessions.contains(where: { $0.id == sessionID }) {
                sessions.insert(snapshot, at: 0)
                sessionVersion += 1
            }
            LogCollector.shared.append(level: .warning, text: "[store] session \(String(sessionID.prefix(8))) was missing from the store — re-created from memory (\(snapshot.messages.count) messages)")
            return alreadyLanded ? .landed : .retry
        } catch {
            LogCollector.shared.append(level: .error, text: "[store] ghost-session re-create failed for \(String(sessionID.prefix(8))): \(error)")
            return .dropped
        }
    }

    /// The store's assistant message for a finished round (CONVERGE A7).
    ///
    /// `content`, `reasoning`, `usage` and `terminalReason` come from the round's
    /// ``TurnTranscript`` (the §3.3 mapping); `createdAt`, `tps` and
    /// `turnDuration` are the UI-side clock fields the core never sees. `tps` is
    /// the round's output tokens over its wall clock, the value the legacy loop
    /// computed for the same reply.
    static func storedAssistantMessage(
        transcript: TurnTranscript,
        createdAt: Date,
        tps: Double?,
        turnDuration: Double?
    ) -> Message {
        let mapped = transcript.assistantMessage()
        return Message(
            role: .assistant,
            content: mapped.content,
            createdAt: createdAt,
            reasoning: mapped.reasoning,
            usage: mapped.usage,
            tps: tps,
            terminalReason: mapped.terminalReason,
            turnDuration: turnDuration
        )
    }

    /// The core's notice when it honours an interrupt at an iteration boundary.
    /// The UI writes its own interruption message, so this text never becomes
    /// the stored reply's content.
    static let coreInterruptNotice = "Interrupted by user."

    /// Run a full agent turn for the active chat and push updates to the
    /// originating client throughout.
    ///
    /// The turn runs on a per-turn ``ArcAgent`` (CONVERGE A5/A6) and consumes its
    /// ``AgentTurnEvent`` stream on this same structured path: the UI keeps the
    /// live turn, the durable transcript, the fragments and the turn boundaries,
    /// while the core owns retry/backoff, recovery nudges, tool dispatch,
    /// approval/clarify presentation and usage accounting. Stored messages are
    /// rebuilt from the events (§3.3), so a turn persists what the legacy loop
    /// wrote — the golden transcript suite is the proof.
    func runTurn(
        userText raw: String,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void,
        sessionID: String,
        headless: Bool = false,
        selectAfter: Bool = true,
        displayText: String? = nil
    ) async {
        // Bind to the session the message was typed into — the active session
        // may change while the Task is queued or while another chat runs.
        guard activeTurns[sessionID] == nil,
              let idx = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }
        // Lazy design: materialize this session's messages (they may have
        // been evicted from the cache when another chat was opened). The
        // array is only mutated in place, so `idx` stays valid.
        await ensureSessionMessages(sessionID)
        var session = sessions[idx]

        let atts = attachments
        var userContent = raw
        if !atts.isEmpty {
            // arc parity: image attachments are described by the active
            // vision model and injected into the turn as a description.
            var lines: [String] = []
            for a in atts {
                let ext = (a as NSString).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
                    let desc = await describeImage(at: a)
                    lines.append("[attachment: \(a)]" + (desc.isEmpty ? "" : "\n[Image description: \(desc)]"))
                } else {
                    lines.append("[attachment: \(a)]")
                }
            }
            userContent = lines.joined(separator: "\n") + "\n\n" + raw
        }

        let configName = configName(for: sessionID)
        guard let preset = settings.modelConfig(named: configName) else {
            _ = toast("No usable model configuration '\(configName)'. Add one in Settings → Preferences.", kind: "error")
            _ = await refreshFragments()
            return
        }
        // Per-profile context overrides: when the chat is bound to a profile
        // that sets context parameters, the effective preset (and the request
        // effort below) follow the profile instead of the chat's config.
        let pctx = profileContext(for: sessionID)
        let effectivePreset = pctx.map { preset.applying($0) } ?? preset
        // The turn's agent builds its own provider client from the turn's
        // configuration. This pre-flight gate keeps the legacy behaviour for a
        // configuration that cannot build one at all (no http client), so the
        // user gets the toast instead of a turn that fails after the message is
        // stored.
        guard turnClientOverride != nil || makeClient(for: effectivePreset) != nil else {
            _ = toast("No usable model configuration '\(configName)'. Add one in Settings → Preferences.", kind: "error")
            _ = await refreshFragments()
            return
        }

        // Begin the turn.
        let turn = LiveTurn(sessionID: sessionID, userText: raw, attachments: atts)
        activeTurns[sessionID] = turn
        pendingDelete = false
        attachments = []
        // Remember what this submit consumed before clearing the draft: a
        // trailing input frame still carrying the sent text must not
        // resurrect it (the engine's debounce can land it after this clear).
        noteSubmittedDraft(settings.composerDrafts[sessionID] ?? "", sessionID: sessionID)
        storeComposerDraft("", sessionID: sessionID)

        let userMsg = Message(role: .user, content: userContent, createdAt: Date(), displayText: displayText)
        session.messages.append(userMsg)
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx] = session
        }
        sessionVersion += 1
        if let store {
            await persistMessage(userMsg, sessionID: sessionID, store: store, healWith: session.messages)
        }

        // arc-parity: when a title_gen auxiliary model is assigned, name the
        // chat with it (best-effort + fire-and-forget so streaming is never
        // delayed; without an assignment the first-message auto title stays).
        if settings.sessionTitles[sessionID] == nil,
           arcConfig.auxiliary.override(for: .titleGeneration)?.isSet == true {
            Task { await self.maybeGenerateTitle(sessionID: sessionID, pusher: pusher) }
        }

        // Turn-start boundary: chrome (composer flips to the red stop button, the
        // running chat's row swaps ⋮ for a spinner, the header meta) plus the
        // transcript (the new user message + the live turn block). NOT `#main`.
        let turnChrome = await turnChromeFragments()
        let transcript = await transcriptFragments()
        await pusher(turnChrome + transcript)

        // Streaming loop with ~90 ms push coalescing. Only push live
        // fragments while the user is viewing the chat that owns the turn —
        // otherwise the active chat's scroll container is needlessly replaced
        // every ~90 ms and its scroll position fights the user.
        //
        // Token pushes are text writes into the live block's stable spans
        // (`FragmentUpdate.text`): the only mutations during a text stream are
        // characterData writes. The node replace (`liveFragments`) is reserved
        // for structural changes — status, tool chips, an appearing/vanishing
        // thinking row, the quantized TPS chip.
        // shared by `throttle` and `flush`, both `@concurrent` local
        // functions, so it rides a `Mutex` rather than a captured `var`
        // (a plain capture is a swift-6 data-race error).
        let lastPush = Mutex(Date.distantPast)
        var lastStructure = ""
        var lastLiveText = ""
        var lastLiveThinking = ""
        func liveStructureSignature(_ live: LiveTurn) -> String {
            "\(live.status)|\(live.toolChips.joined(separator: "|"))|\(live.thinking.isEmpty)|\(live.assistantText.isEmpty)|\(Int((live.tps ?? 0) / 10))|\(live.toolName ?? "")"
        }
        func pushLive() async {
            // The turn's own guard plus the visible view: the 90 ms live pushes
            // must only fire while the user is actually looking at the chat
            // that owns the turn. Without the tab check the engine logs
            // "[WebUIEngine] Element not found: #live-turn-thinking" every
            // coalesced tick once the user has navigated to another tab.
            guard let live = activeTurns[sessionID], activeSessionID == sessionID,
                  self.activeTabID == "chat" else { return }
            let sig = liveStructureSignature(live)
            if sig != lastStructure {
                lastStructure = sig
                lastLiveText = live.assistantText
                lastLiveThinking = live.thinking
                await pusher(await liveFragments())
                return
            }
            var ops: [FragmentUpdate] = []
            if live.assistantText != lastLiveText {
                lastLiveText = live.assistantText
                ops.append(FragmentUpdate.text(id: "live-turn-text", value: live.assistantText, transition: false))
            }
            if live.thinking != lastLiveThinking && !live.thinking.isEmpty {
                lastLiveThinking = live.thinking
                ops.append(FragmentUpdate.text(id: "live-turn-thinking", value: live.thinking, transition: false))
            }
            if !ops.isEmpty {
                await pusher(ops)
            }
        }
        let throttle: () async -> Void = { [weak self] in
            guard let self else { return }
            let now = Date()
            if now.timeIntervalSince(lastPush.withLock { $0 }) > 0.09, await self.activeSessionID == sessionID {
                lastPush.withLock { $0 = now }
                await pushLive()
            }
        }
        func flush() async {
            lastPush.withLock { $0 = .distantPast }
            await throttle()
        }

        var history = session.messages
        // arc-parity context compression: when the estimate exceeds the
        // budget, the `compression` auxiliary model (Qwen3.6) summarizes the
        // older tail and a recent window replaces it for the model-facing
        // request. The stored transcript stays intact. Applies at most once
        // per session (durable summary).
        let (compressed, didCompress) = await compressHistoryIfNeeded(history, sessionID: sessionID)
        if didCompress {
            history = compressed
            _ = hint("Conversation history compressed (est. \(estimateTokens(history)) tokens now).")
        }
        // the agent appends this turn's user message itself, so the seed is the
        // model-facing history the UI built minus the message stored above.
        let seed = Array(history.dropLast())

        // the ambient `execute_code` path still consults the shared guardrails;
        // the turn's own budget lives on the agent's configuration.
        guardrails = Self.freshGuardrails()
        await guardrails.resetTurn()

        // A6's overload: the minted agent carries this turn's approval, clarify
        // and execute_code bindings — `headless` decides the approval policy, so
        // a queue run never waits on a card and an interactive run never
        // approves silently.
        let minted = await makeTurnAgent(
            preset: preset,
            profileContext: pctx,
            thinking: thinkingLevel(for: sessionID),
            headless: headless,
            sessionID: sessionID,
            initialHistory: seed,
            pusher: pusher
        )
        let agent = minted.agent
        // the stop button reaches the turn's own agent through this handle.
        turnAgents[sessionID] = agent

        // One round's stored output: content, reasoning, usage and
        // terminalReason through A4's mapper, plus the UI-side clock and the
        // tool calls the mapper does not model. A tool round is held until the
        // next round begins, so its assistant message is written in one piece —
        // the shape the legacy loop stored.
        var round = TurnTranscript()
        var roundStart = Date()
        var roundTokensRecorded = false
        var pendingToolRound: PendingToolRound?
        var toolArguments: [String: String] = [:]
        var streamedText = ""
        var turnCompleted = false
        var finalError: String?

        /// The store's reply for a turn that finished normally.
        func storedFinalMessage() -> Message {
            let elapsed = max(0.2, Date().timeIntervalSince(roundStart))
            let tps = round.usage.flatMap { usage in
                usage.completionTokens > 0 ? Double(usage.completionTokens) / elapsed : nil
            }
            return Self.storedAssistantMessage(
                transcript: round,
                createdAt: Date(),
                tps: tps,
                turnDuration: max(0, Date().timeIntervalSince(turn.startedAt))
            )
        }

        /// Write this event into the live turn. The mapper is a pure function of
        /// the prior value, so re-reading the turn here keeps a stop click's flag.
        func applyLive(_ event: AgentTurnEvent) {
            guard let live = activeTurns[sessionID] else { return }
            activeTurns[sessionID] = TurnLiveState.apply(event, to: live)
        }

        /// Take the held tool round as the messages it stores: its assistant
        /// message (content, reasoning, tool calls) then one tool message per
        /// result, in the order the legacy loop wrote them.
        func takeToolRoundMessages() -> [Message] {
            guard let pending = pendingToolRound else { return [] }
            pendingToolRound = nil
            var messages = [Message(
                role: .assistant,
                content: pending.content.isEmpty ? nil : pending.content,
                toolCalls: pending.calls,
                createdAt: Date(),
                reasoning: pending.reasoning.isEmpty ? nil : pending.reasoning
            )]
            messages.append(contentsOf: pending.results.map { result in
                Message(
                    role: .tool,
                    content: result.result,
                    name: result.name,
                    toolCallID: result.id,
                    createdAt: Date()
                )
            })
            return messages
        }

        do {
            try await agent.prime()
            for try await event in agent.streamTurn(message: userContent) {
                // A round closes when the next round's stream begins: a text or
                // reasoning delta, the provider's usage report, or a terminal
                // event. The held tool round is written in one piece then.
                switch event {
                case .textDelta, .reasoningDelta, .usage, .completed, .failed:
                    let stored = takeToolRoundMessages()
                    if !stored.isEmpty {
                        for message in stored {
                            history.append(message)
                            if let store {
                                await persistMessage(message, sessionID: sessionID, store: store, healWith: history)
                            }
                        }
                        // commit boundary: the round's messages are stored, so
                        // the transcript block can show them.
                        if activeSessionID == sessionID {
                            await pusher(await transcriptFragments())
                        }
                    }
                case .toolCallStarted, .toolCallFinished:
                    break
                }

                switch event {
                case .textDelta(let text):
                    round.apply(event)
                    // the core's own interrupt notice is not part of the reply —
                    // the UI writes its own interruption message below.
                    if !(activeTurns[sessionID]?.stopped == true && text == Self.coreInterruptNotice) {
                        streamedText += text
                    }
                    applyLive(event)
                    await throttle()
                case .reasoningDelta:
                    round.apply(event)
                    applyLive(event)
                    await throttle()
                case .usage(let usage):
                    round.apply(event)
                    if !roundTokensRecorded {
                        roundTokensRecorded = true
                        recordTokensBurned(usage.totalTokens > 0
                            ? usage.totalTokens
                            : usage.promptTokens + usage.completionTokens)
                    }
                    applyLive(event)
                    await flush()
                case .toolCallStarted(let id, let name, let arguments):
                    if pendingToolRound == nil {
                        pendingToolRound = PendingToolRound(content: round.content, reasoning: round.reasoning)
                        round = TurnTranscript()
                        roundStart = Date()
                        roundTokensRecorded = false
                    }
                    pendingToolRound?.calls.append(ToolCall(
                        id: id,
                        type: "function",
                        function: ToolCallFunction(name: name, arguments: arguments)
                    ))
                    toolArguments[id] = arguments
                    applyLive(event)
                    await flush()
                case .toolCallFinished(let id, let name, let result):
                    pendingToolRound?.results.append((id: id, name: name, result: result))
                    // skill telemetry moves to the result consumer (§3.5).
                    if let raw = toolArguments.removeValue(forKey: id),
                       let data = raw.data(using: .utf8),
                       let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        recordSkillToolUse(toolName: name, args: args)
                    }
                    applyLive(event)
                    await flush()
                case .completed(let finalText, _):
                    round.apply(event)
                    if finalText != round.content {
                        LogCollector.shared.append(level: .warning, text: "[turn] completed text diverged from the streamed text (\(round.content.count) streamed, \(finalText.count) reported)")
                    }
                    // a stop that lands before the terminal event is what the
                    // user asked for: the turn is stored as interrupted with the
                    // UI's own wording, not as a completed reply (the core's
                    // "Interrupted by user." is its notice, not the reply).
                    turnCompleted = activeTurns[sessionID]?.stopped != true
                case .failed(let message):
                    finalError = message
                    applyLive(event)
                }
            }
        } catch {
            // a throwing stream is a transport failure: the same shape as `.failed`.
            // a tool round that finished before the failure is still real work,
            // so it lands in the transcript.
            for message in takeToolRoundMessages() {
                history.append(message)
                if let store {
                    await persistMessage(message, sessionID: sessionID, store: store, healWith: history)
                }
            }
            finalError = "\(error)"
        }
        await agent.shutdownHTTPClient()
        turnAgents[sessionID] = nil

        // Finalize: drop the live bubble, resync from the store, rebuild.
        let wasStopped = activeTurns[sessionID]?.stopped == true

        if turnCompleted {
            // the normal path: the round's mapper state is the stored reply and
            // `completed.terminalReason` is what the status card reads.
            let final = storedFinalMessage()
            history.append(final)
            if let store {
                await persistMessage(final, sessionID: sessionID, store: store, healWith: history)
            }
        } else {
            // Interrupted turns (user stop or provider disconnect) still leave a
            // real assistant reply + status card in the transcript, so the
            // turn's dropdown ("Processed Xm Ys"), any partial output, and the
            // interruption reason survive reloads exactly like a normal turn.
            let reason = wasStopped ? "user_stopped" : "disconnected"
            let partial = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let notice = wasStopped
                ? "Turn interrupted — stopped by the user."
                : "Turn interrupted — the connection to the model was lost."
            let interrupt = Message(
                role: .assistant,
                content: partial.isEmpty ? notice : partial,
                createdAt: Date(),
                reasoning: activeTurns[sessionID]?.thinking,
                terminalReason: reason,
                turnDuration: max(0, Date().timeIntervalSince(turn.startedAt))
            )
            history.append(interrupt)
            if let store {
                await persistMessage(interrupt, sessionID: sessionID, store: store, healWith: history)
            }
        }

        activeTurns[sessionID] = nil
        if let finalError {
            // the core's failure text is already prefixed; the toast is not.
            let reason = finalError.hasPrefix("Error: ") ? String(finalError.dropFirst(7)) : finalError
            _ = toast("Turn failed: \(trunc(reason, 140))", kind: "error")
        }
        await reloadSessions(selecting: selectAfter ? sessionID : nil)
        // Turn-end boundary: transcript (final message in, live block out), the
        // session row spinner cleared, composer back to send, header meta, toasts.
        // NOT `#main` — a whole-chat replacement drops scroll and selection at
        // every turn end.
        let endChrome = await turnChromeFragments()
        // The transcript re-render is what removes `#live-turn` and shows the
        // persisted final message. It is only valid for the chat the client is
        // actually displaying, and `activeSessionID` is that invariant's proxy:
        // `reloadSessions` keeps the selection for a running turn's session (and
        // never strands it at nil while this chat is on screen). If the check
        // ever fails, make it visible in the Logs instead of leaving a stale
        // live block on screen silently — the block clears on the next view
        // switch, which re-renders this session's transcript from the store.
        let endTranscript: [FragmentUpdate]
        if activeSessionID == sessionID {
            endTranscript = await transcriptFragments()
        } else {
            endTranscript = []
            LogCollector.shared.append(level: .warning, text: "[turn] transcript push skipped for session \(String(sessionID.prefix(8))) — active is \(activeSessionID.map { String($0.prefix(8)) } ?? "nil")")
        }
        await pusher(endChrome + endTranscript)
        // UX-04: drain the honest queue one turn at a time — the next queued
        // message runs now, and runTurn's own end drains the one after that,
        // so order matches the chips. A stopped turn does not drain.
        if !wasStopped, let next = self.popQueuedSend(sessionID) {
            Task { await self.runTurn(userText: next.text, pusher: pusher, sessionID: sessionID) }
        }
    }

    /// Called by the red stop button: the live turn is flagged at once (the UI's
    /// own guard) and the turn's agent is asked to interrupt. The core honours
    /// the interrupt at its next iteration boundary — an in-flight call finishes
    /// first, exactly the semantics ``ArcAgent/interruptTurn()`` documents.
    /// Scoped to the owning session so stopping one chat never affects another's.
    func requestStopTurn(sessionID: String) async {
        activeTurns[sessionID]?.stopped = true
        // the turn's own agent, minted for this session by `runTurn` (A7).
        await turnAgents[sessionID]?.interruptTurn()
        // Resolve any pending approval so a waiting turn can finish promptly.
        if let pa = pendingApproval, pa.sessionID == sessionID {
            pendingApproval = nil
            pa.continuation.yield(false)
            pa.continuation.finish()
        }
        // Resolve any pending clarification the same way (card disappears).
        if let pc = pendingClarify, pc.sessionID == sessionID {
            pendingClarify = nil
            clarifyTimerTask?.cancel()
            clarifyTimerTask = nil
            pc.continuation.yield("Error: the turn was stopped by the user.")
            pc.continuation.finish()
        }
        activeTurns[sessionID]?.status = "done"
    }

    /// Live-region fragments: the in-progress turn node and the composer flyout —
    /// and nothing else, so a streaming turn never re-renders the transcript it is
    /// appending to. `live-turn` opts out of the client's view transition: a
    /// full-page cross-fade per push reads as a shimmer at token rate.
    func liveFragments() async -> [FragmentUpdate] {
        // The live turn and composer only exist while the chat view is showing;
        // pushing them from another tab logs "[WebUIEngine] Element not found:
        // #live-turn…" on every coalesced tick.
        guard activeTabID == "chat" else { return [] }
        var u: [FragmentUpdate] = []
        if let live = activeTurns[activeSessionID ?? ""] {
            u.append(FragmentUpdate(id: "live-turn", html: render(liveMessageHTML(live)), transition: false))
        }
        u.append(fragment("composer-flyout", Div { composerFlyoutHTML() }.attribute("id", "composer-flyout")))
        return u
    }

    /// The transcript node alone. Pushed at message commits, where a committed
    /// message must appear — stage 0 replaces the whole list; once the engine
    /// carries the append op this becomes one inserted subtree.
    func transcriptFragments() async -> [FragmentUpdate] {
        // The transcript node only exists while the chat view is showing; a
        // replacement push from another tab logs "[WebUIEngine] Element not
        // found: #chat-inner" for every committed turn that ends off-chat.
        guard activeTabID == "chat" else { return [] }
        let session = activeSession()
        let inner = Div(class: "chat-inner") {
            messagesHTML(session?.messages ?? [])
        }
        .attribute("id", "chat-inner")
        return [fragment("chat-inner", inner)]
    }

    /// The chrome that changes at turn boundaries: the session row spinner, the chat
    /// header meta, the composer (send ⇄ stop), and the toasts (compression hints,
    /// turn-failure notices). Deliberately NOT `#main` — a whole-chat replacement
    /// at a boundary kills selection, scroll and focus.
    func turnChromeFragments() async -> [FragmentUpdate] {
        return [
            // The top strip mirrors the active chat title; a turn boundary is
            // where auto-titles first exist (first-message default or the
            // title_gen aux model), so the topbar must ride this push — a
            // stale "New chat" strip is the UX-05 regression.
            fragment("topbar", topbarHTML()),
            fragment("panel", await panelHTML()),
            FragmentUpdate(id: "chat-header", html: render(chatHeaderHTML())),
            fragment("composer-wrap", composerHTML()),
            fragment("toasts", toastsShell()),
        ]
    }

    /// Reload sessions from the store, optionally selecting one.
    ///
    /// Ghost tolerance: a session the store list no longer carries but the
    /// in-memory cache still materializes is kept (its row stays, the selection
    /// survives) — the persist path re-creates its store entry. A list failure
    /// keeps the previous array instead of blanking the sidebar. With no
    /// selection at all, the newest real chat is opened rather than the blank
    /// canvas.
    func reloadSessions(selecting wanted: String? = nil) async {
        let previous = sessions
        if let store {
            do {
                sessions = try await store.list(limit: 500)
            } catch {
                LogCollector.shared.append(level: .error, text: "[store] session list failed: \(error) — keeping \(previous.count) cached sessions")
            }
        }
        sessionVersion += 1
        // list() returns metadata-only summaries: drop the lazy cache and
        // re-materialize whichever chat is now active.
        loadedSessionOrder.removeAll()
        if let wanted {
            if sessions.contains(where: { $0.id == wanted }) {
                activeSessionID = wanted
            }
        }
        if let current = activeSessionID, !sessions.contains(where: { $0.id == current }) {
            if let cached = previous.first(where: { $0.id == current }) {
                sessions.insert(cached, at: 0)
                LogCollector.shared.append(level: .warning, text: "[store] session \(String(current.prefix(8))) missing from the store list — kept from cache")
            } else {
                activeSessionID = nil
            }
        }
        if activeSessionID == nil, let newest = newestSessionID() {
            activeSessionID = newest
        }
        if let keep = activeSessionID {
            await ensureSessionMessages(keep)
        }
    }
}

// MARK: - Headless approval policy (CONVERGE A6)

/// One round's tool calls and their results, held until the round's boundary so
/// the assistant message that requested them is written in one piece — the shape
/// the legacy loop stored (CONVERGE A7).
///
/// The event stream reports a call's start and its result separately and gives
/// no explicit round boundary, so the turn loop closes a round when the next
/// round's stream begins (a text delta, a reasoning delta, or the provider's
/// usage report) and writes this value then.
private struct PendingToolRound {
    var content: String
    var reasoning: String
    var calls: [ToolCall] = []
    var results: [(id: String, name: String, result: String)] = []
}

/// The scheduler's approval policy for a turn with no human in the loop, as a
/// pure decision function: no agent, no socket and no turn are needed to test
/// it, and `runTool`'s live headless branch and a headless agent's presenter
/// both decide through it.
enum HeadlessApprovalPolicy {

    /// What a headless turn does with one gated command.
    enum Verdict: Equatable, Sendable {
        /// The command proceeds to execution (the caller logs the run).
        case proceed
        /// The command is refused; `message` is the tool result the model and
        /// the job transcript see.
        case block(String)
    }

    /// The scheduler's refusal text. Load-bearing: a user reads this instead of
    /// a silent run, and it is byte-for-byte the string the inline headless
    /// branch returned before this policy was extracted. Do not reword it.
    static let blockedCommandMessage =
        "Error: command blocked by approval policy (classified critical; scheduled jobs cannot run destructive commands)."

    /// Decide one command.
    ///
    /// - Parameters:
    ///   - dangerLevel: The classification from the built-in detector
    ///     (`detectDangerLevel`) — the same detector `ApprovalManager` gates
    ///     with, not a second classifier.
    ///   - approval: The manager's result, when it has been consulted. `nil`
    ///     lets a caller refuse a critical command before asking anyone.
    /// - Returns: `.block` for a critical command whatever `approval` says (an
    ///   approval can never resurrect a destructive command), and for a manager
    ///   denial (smart mode's hardline verdict); `.proceed` otherwise.
    static func verdict(dangerLevel: DangerLevel, approval: ApprovalResult? = nil) -> Verdict {
        if dangerLevel >= .critical {
            return .block(blockedCommandMessage)
        }
        if case .denied = approval {
            return .block(blockedCommandMessage)
        }
        return .proceed
    }

    /// The same policy as the decision an ``ApprovalPresenter`` returns.
    static func decision(dangerLevel: DangerLevel) -> ApprovalDecision {
        dangerLevel >= .critical ? .deny : .approve
    }
}

/// The approval and clarify presenters, plus the `execute_code` host, a minted
/// turn agent runs with.
///
/// A value type: the bindings are captured for one turn and never mutated, and
/// a test can drive each one directly instead of standing up a turn.
struct TurnPresenters: Sendable {

    /// The agent's approval gate: the permission card on an interactive turn,
    /// the scheduler policy when there is nobody to ask.
    let approval: ApprovalPresenter

    /// The agent's clarify tool. `nil` when headless — no one can answer a
    /// card, so the tool keeps its historic "not available" answer.
    let clarify: ClarifyTool.Presenter?

    /// The turn's `execute_code` host: child processes dispatch tools back into
    /// this session's registry, guardrails and approvals.
    let codeHost: @Sendable (String, [String: Any]) async throws -> String
}

// MARK: - Controller (event wiring)

final class Controller: Sendable {

    let app: AppState

    /// Pushes fragment updates to every connected page.
    ///
    /// arc keeps a single server-side `AppState`, so every connected page
    /// renders the same state: a push therefore fans out to all of them rather
    /// than to the originating connection. That also keeps multiple tabs in
    /// sync, which per-connection targeting did not.
    let push: @Sendable ([FragmentUpdate]) async -> Void

    init(app: AppState, push: @escaping @Sendable ([FragmentUpdate]) async -> Void) {
        self.app = app
        self.push = push
    }

    // The literal-id escape: registers a fixed-id component with event-type
    // filtering (see the hover-equals-click advisory: handlers must not fire
    // on mouseover etc.).
    //
    // Every other registration is generated, not typed. A type carrying
    // `@WireGroup(n)` gains `wireGroup_<n>(_ router:)`, and each
    // `@Wired(id, events:)` handler that group encloses becomes one
    // `register` call inside it. `@Wired` is a peer marker: on its own it
    // expands to nothing, so a `@Wired` handler in an `extension Controller`
    // that carries no `@WireGroup` compiles cleanly and is *silently never
    // registered*. That was the defect this adoption wave fixed, and
    // `EventRouter.handlerCount(in:)` is the only honest way to observe it.
    //
    // Three sanctioned escapes remain, each unexpressible as a `@Wired`
    // marker:
    // 1. `nav-\(id)` in `wireNav` — the ids are not static literals; they
    //    come from `app.railTabIDs()` and are interpolated in a loop.
    // 2. `sidebar-plugin-toggle` in `wireSidebarPluginToggles` — one fixed id
    //    covers every third-party plugin row, and the handler dispatches on
    //    the event's `targetId` (`sbpl-<key>`).
    // 3. `cat-pick` in `wireChat` — it carries `contextmenu`, which is not an
    //    `HTMLEvent` case, so the macro cannot express its event set.
    //
    // Any other literal id here is a regression: add a `@Wired` handler to the
    // owning `@WireGroup` instead.
    func wire(
        _ router: EventRouter,
        id: String,
        events: Set<String> = ["click", "change", "submit", "input"],
        _ handler: @escaping @Sendable (EventData) async -> [FragmentUpdate]
    ) {
        router.register({ event in
            guard events.contains(event.event) else { return [] }
            return await handler(event)
        }, for: ComponentID(id))
    }

    func wireAll(_ router: EventRouter) async {
        await wireNav(router)
        wireChat(router)
        wireChatMenu(router)
        wireSkills(router)
        wireProfiles(router)
        wireTools(router)
        wireWorkspaces(router)
        wireSettings(router)
        wirePlugins(router)
        wireMCP(router)
        wireSidebarPluginToggles(router)
        wireToasts(router)
        wireLogs(router)
        wireInsights(router)
        wireGroup_todos(router)
        wireGroup_queue(router)
        wireGroup_cron(router)
        wireGroup_regen(router)
        await installSidebarTabPlugins(router)
    }

    /// Install the event registrations of every third-party sidebar tab
    /// (see `SidebarTab.install`). Built-in tabs are wired natively in
    /// the functions above.
    private func installSidebarTabPlugins(_ router: EventRouter) async {
        let registrar = AppSidebarTabRegistrar(router: router)
        for id in app.pluginTabs.keys.sorted() {
            if let tab = app.pluginTabs[id] {
                await tab.install(SidebarTabRegistration(registrar))
            }
        }
    }

    // MARK: Nav

    private func wireNav(_ router: EventRouter) async {
        let ids = await app.railTabIDs()
        for id in ids {
            wire(router, id: "nav-\(id)", events: ["click"]) { _ in
                await self.app.switchTab(id)
                await self.app.notifyTabActivated(id)
                return await self.app.refreshFragments()
            }
        }
    }

    // MARK: Sidebar plugins

    /// Settings → Sidebar plugins: show/hide toggles for third-party tabs.
    private func wireSidebarPluginToggles(_ router: EventRouter) {
        wire(router, id: "sidebar-plugin-toggle", events: ["change"]) { event in
            let tid = event.string("targetId") ?? event.string("value") ?? ""
            guard tid.hasPrefix("sbpl-") else { return [] }
            let key = dec(String(tid.dropFirst("sbpl-".count))) ?? ""
            let on = event.checked == true
            await self.app.setSidebarPluginHidden(key, hidden: !on)
            return await self.app.fragmentsWithIconbar()
        }
    }

    // MARK: Logs

    private func wireLogs(_ router: EventRouter) {
        wireGroup_logs(router)
    }

    // MARK: Insights

    private func wireInsights(_ router: EventRouter) {
        wireGroup_insights(router)
    }
}

@WireGroup("chat")
extension Controller {
    @Wired("chat-new", events: [.click])
    func handleChatNew(_ event: EventData) async -> [FragmentUpdate] {
        await self.newChat()
        return await self.app.refreshFragments()
    }

    @Wired("blank-chat-new", events: [.click])
    func handleBlankChatNew(_ event: EventData) async -> [FragmentUpdate] {
        await self.newChat()
        return await self.app.refreshFragments()
    }

    @Wired("sess-list", events: [.click])
    func handleSessList(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        return await self.sessionListAction(tid)
    }

    @Wired("cat-menu-close", events: [.click])
    func handleCatMenuClose(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.closeCategoryMenu()
        return await self.app.refreshFragments()
    }

    @Wired("chat-del", events: [.click])
    func handleChatDel(_ event: EventData) async -> [FragmentUpdate] {
        await self.deleteActiveChat()
        return await self.app.refreshFragments()
    }

    @Wired("composer-input", events: [.input])
    func handleComposerInput(_ event: EventData) async -> [FragmentUpdate] {
        let sid = await self.app.activeSessionID ?? ""
        await self.app.storeComposerDraft(event.string("value") ?? "", sessionID: sid)
        return []
    }

    @Wired("composer-form", events: [.submit])
    func handleComposerForm(_ event: EventData) async -> [FragmentUpdate] {
        let text = event.string("composer-input") ?? ""
        return await self.submitChat(text: text)
    }

    @Wired("selection-context-add", events: [.click])
    func handleSelectionContextAdd(_ event: EventData) async -> [FragmentUpdate] {
        // "Reply with selection" button: the selected chat text rides in
        // `payload` (dynamic button, reference `_addNamedContextBlock`).
        guard let sel = event.string("payload"), !sel.isEmpty else { return [] }
        _ = await self.app.addPendingContext(sel)
        return [fragment("composer-wrap", await self.app.composerHTML())]
    }

    @Wired("selection-context-del", events: [.click])
    func handleSelectionContextDel(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? ""
        await self.app.removePendingContext(tid)
        return [fragment("composer-wrap", await self.app.composerHTML())]
    }

    @Wired("stop-turn", events: [.click])
    func handleStopTurn(_ event: EventData) async -> [FragmentUpdate] {
        let sid = await self.app.activeSessionID ?? ""
        await self.app.requestStopTurn(sessionID: sid)
        return await self.app.turnChromeFragments()
    }

    @Wired("approval-once", events: [.click])
    func handleApprovalOnce(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.resolveApproval(.once)
        return []
    }

    @Wired("approval-session", events: [.click])
    func handleApprovalSession(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.resolveApproval(.session)
        return []
    }

    @Wired("approval-always", events: [.click])
    func handleApprovalAlways(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.resolveApproval(.always)
        return []
    }

    @Wired("approval-deny", events: [.click])
    func handleApprovalDeny(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.resolveApproval(.deny)
        return []
    }

    @Wired("approval-dismiss", events: [.click])
    func handleApprovalDismiss(_ event: EventData) async -> [FragmentUpdate] {
        // X on the card = treat as deny (prevents a stuck turn).
        await self.app.resolveApproval(.deny)
        return []
    }

    @Wired("approval-yolo", events: [.click])
    func handleApprovalYolo(_ event: EventData) async -> [FragmentUpdate] {
        // "Skip all this session" (reference /api/session/yolo): enable the
        // session bypass and grant the current command.
        let sid = await self.app.activeSessionID ?? ""
        await self.app.setYolo(sid, true)
        await self.app.resolveApproval(.once)
        return await self.app.turnChromeFragments()
    }

    @Wired("yolo-off", events: [.click])
    func handleYoloOff(_ event: EventData) async -> [FragmentUpdate] {
        let sid = await self.app.activeSessionID ?? ""
        await self.app.setYolo(sid, false)
        return [fragment("composer-wrap", await self.app.composerHTML())]
    }

    @Wired("clarify-choice", events: [.click])
    func handleClarifyChoice(_ event: EventData) async -> [FragmentUpdate] {
        // Element ids are clarify-choice-0..3; the index maps to the
        // pending request's choices array.
        let tid = event.string("targetId") ?? ""
        guard tid.hasPrefix("clarify-choice-"),
              let idx = Int(String(tid.dropFirst("clarify-choice-".count))),
              let pc = await self.app.pendingClarify,
              pc.choices.indices.contains(idx) else { return [] }
        await self.app.respondClarify(pc.choices[idx])
        return []
    }

    @Wired("clarify-form", events: [.submit])
    func handleClarifyForm(_ event: EventData) async -> [FragmentUpdate] {
        let ans = event.string("clarify-input") ?? ""
        guard !ans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        await self.app.respondClarify(ans)
        return []
    }

    @Wired("cb-file", events: [.click])
    func handleCbFile(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.toggleFilePop()
        return await self.app.chatFragments()
    }

    @Wired("queued-sends", events: [.click])
    func handleQueuedSends(_ event: EventData) async -> [FragmentUpdate] {
        // Mid-stream queue chip ✕: remove the message before it runs
        // (UX-04). The chip's whole surface is the remove affordance.
        guard let tid = event.string("targetId"), tid.hasPrefix("qs-del-"),
              let id = Int(tid.dropFirst("qs-del-".count)) else { return [] }
        let sid = await self.app.activeSessionID ?? ""
        await self.app.removeQueuedSend(id, sessionID: sid)
        return await self.app.chatFragments()
    }

    @Wired("file-path-input", events: [.input])
    func handleFilePathInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("file-path-input", event.string("value") ?? "")
        return []
    }

    @Wired("file-attach", events: [.click])
    func handleFileAttach(_ event: EventData) async -> [FragmentUpdate] {
        let path = await self.app.readFormValue("file-path-input")
        return await self.attachFile(path)
    }

    @Wired("file-recents", events: [.click])
    func handleFileRecents(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), let p = dec(tid.replacingOccurrences(of: "fr-", with: "")) else { return [] }
        return await self.attachFile(p)
    }

    @Wired("att-chips", events: [.click])
    func handleAttChips(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("att-del-"),
              let idx = Int(tid.dropFirst("att-del-".count)) else { return [] }
        await self.app.removeAttachment(idx)
        return await self.app.chatFragments()
    }

    @Wired("cb-bookmark", events: [.click])
    func handleCbBookmark(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.toggleBookmarkActive()
        return await self.app.refreshFragments()
    }

    @Wired("dd-dismiss", events: [.click])
    func handleDdDismiss(_ event: EventData) async -> [FragmentUpdate] {
        // Fired by the runtime when a click lands outside an open
        // dropdown panel — close all of them.
        await self.app.closeComposerSelectors()
        return await self.app.chatFragments()
    }

    @Wired("cb-ws-toggle", events: [.click])
    func handleCbWsToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.toggleWSSelect()
        return await self.app.chatFragments()
    }

    @Wired("cb-profile-toggle", events: [.click])
    func handleCbProfileToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.toggleProfileSelect()
        return await self.app.chatFragments()
    }

    @Wired("cb-model-toggle", events: [.click])
    func handleCbModelToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.toggleModelSelect()
        return await self.app.chatFragments()
    }

    @Wired("cb-think-toggle", events: [.click])
    func handleCbThinkToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.toggleThinkSelect()
        return await self.app.chatFragments()
    }

    @Wired("ws-search-input", events: [.input])
    func handleWsSearchInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setWSSelectQuery(event.string("value") ?? "")
        return await self.app.chatFragments()
    }

    @Wired("ws-search-clear", events: [.click])
    func handleWsSearchClear(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setWSSelectQuery("")
        return await self.app.chatFragments()
    }

    @Wired("model-search-input", events: [.input])
    func handleModelSearchInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setModelSelectQuery(event.string("value") ?? "")
        return await self.app.chatFragments()
    }

    @Wired("model-search-clear", events: [.click])
    func handleModelSearchClear(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setModelSelectQuery("")
        return await self.app.chatFragments()
    }

    @Wired("ws-pick", events: [.click])
    func handleWsPick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("ws-pick-"),
              let name = dec(String(tid.dropFirst("ws-pick-".count))) else { return [] }
        await self.app.closeComposerSelectors()
        await self.app.setChatWorkspace(name)
        return await self.app.refreshFragments()
    }

    @Wired("profile-pick", events: [.click])
    func handleProfilePick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("pp-"),
              let name = dec(String(tid.dropFirst("pp-".count))) else { return [] }
        await self.app.closeComposerSelectors()
        await self.app.setChatProfile(name)
        return await self.app.chatFragments()
    }

    @Wired("model-pick", events: [.click])
    func handleModelPick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("mc-"),
              let name = dec(String(tid.dropFirst("mc-".count))) else { return [] }
        await self.app.closeComposerSelectors()
        await self.app.setChatConfig(name)
        return await self.app.chatFragments()
    }

    @Wired("think-pick", events: [.click])
    func handleThinkPick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("tp-") else { return [] }
        await self.app.closeComposerSelectors()
        await self.app.setChatThinking(String(tid.dropFirst("tp-".count)))
        return await self.app.chatFragments()
    }

    @Wired("ws-choose-path", events: [.click])
    func handleWsChoosePath(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.closeComposerSelectors()
        await self.app.openWorkspaceCreate(forChat: true)
        return await self.app.refreshFragments()
    }

    @Wired("ws-manage", events: [.click])
    func handleWsManage(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.closeComposerSelectors()
        await self.app.switchView(.workspaces)
        return await self.app.refreshFragments()
    }

    @Wired("pp-manage", events: [.click])
    func handlePpManage(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.closeComposerSelectors()
        await self.app.switchView(.profiles)
        return await self.app.refreshFragments()
    }

    @Wired("chat-search-input", events: [.input])
    func handleChatSearchInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setChatFilter(event.string("value") ?? "")
        return await self.app.skillPanelFragment()
    }

    @Wired("cat-menu", events: [.click, .submit])
    func handleCatMenu(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? ""
        if event.event == "submit" {
            guard let cid = await self.app.menuCategoryID(),
                  let name = event.string("cat-rename-input") else { return [] }
            await self.app.renameCategory(cid, to: name)
            await self.app.closeCategoryMenu()
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("cm-rename-") {
            await self.app.setCategoryMenuRename(true)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("cm-color-") {
            // The engine carries no attribute payloads, so the swatch's
            // colour rides its element id (`cm-color-<hex>`).
            let hex = String(tid.dropFirst("cm-color-".count))
            guard hex.allSatisfy({ $0.isHexDigit }),
                  let cid = await self.app.menuCategoryID() else { return [] }
            await self.app.setCategoryColor(cid, color: "#" + hex)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("cm-del-") {
            guard let cid = await self.app.menuCategoryID() else { return [] }
            await self.app.deleteCategory(cid)
            return await self.app.refreshFragments()
        }
        return []
    }

    @Wired("cat-add-form", events: [.submit, .click])
    func handleCatAddForm(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            let name = event.string("cat-name-input") ?? ""
            let color = event.string("cat-color-input") ?? ""
            await self.app.addCategory(name: name, color: color)
            await self.app.setAddingCategory(false)
        } else if event.string("targetId") != "cat-add-cancel" {
            return []   // swatch clicks are client-side
        } else {
            await self.app.setAddingCategory(false)
        }
        return await self.app.refreshFragments()
    }

    /// `cat-pick` stays hand-written: it carries `contextmenu`, which is not
    /// an `HTMLEvent` case, so the `@Wired` macro cannot express it.
    /// See the `Controller.wire` doc comment for the documented escape.
}

@WireGroup("skills")
extension Controller {
    @Wired("skill-new", events: [.click])
    func handleSkillNew(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setCreateSkill(true)
        return await self.app.refreshFragments()
    }

    @Wired("skill-search-input", events: [.input])
    func handleSkillSearchInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setSkillFilter(event.string("value") ?? "")
        return await self.app.skillPanelFragment()
    }

    @Wired("tool-search-input", events: [.input])
    func handleToolSearchInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setToolFilter(event.string("value") ?? "")
        return await self.app.refreshFragments()
    }

    @Wired("skill-list", events: [.click, .change])
    func handleSkillList(_ event: EventData) async -> [FragmentUpdate] {
        // Clicks resolve the row from targetId (the id inside the boundary);
        // a checkbox change carries no targetId, so the row identity rides
        // the input's `value` instead.
        let tid = event.string("targetId") ?? event.string("value") ?? ""
        return await self.skillListAction(tid, checked: event.checked)
    }

    @Wired("skill-create-form", events: [.submit])
    func handleSkillCreateForm(_ event: EventData) async -> [FragmentUpdate] {
        let name = (event.string("skill-name-input") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = (event.string("skill-cat-input") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = event.string("skill-desc-input") ?? ""
        let content = event.string("skill-content-input") ?? ""
        return await self.createSkill(name: name, desc: desc, content: content, category: cat)
    }

    @Wired("skill-cancel", events: [.click])
    func handleSkillCancel(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setCreateSkill(false)
        return await self.app.refreshFragments()
    }

    @Wired("side-tab-chips", events: [.click])
    func handleSideTabChips(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? ""
        guard tid.hasPrefix("st-") else { return [] }
        let key = dec(String(tid.dropFirst("st-".count))) ?? ""
        // UX-13: the chips are buttons now (no checkable state) — a click
        // flips the current visibility.
        let hidden = await self.app.settings.hiddenSidebarTabs.contains(key)
        await self.app.setSidebarTab(key, visible: hidden)
        return await self.app.fragmentsWithIconbar()
    }

    @Wired("sidebar-tab-order", events: [.change])
    func handleSidebarTabOrder(_ event: EventData) async -> [FragmentUpdate] {
        let keys = (event.string("value") ?? "").split(separator: ",").map(String.init)
        await self.app.setSidebarTabOrder(keys)
        return await self.app.fragmentsWithIconbar()
    }

    @Wired("skill-edit", events: [.click])
    func handleSkillEdit(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.startSkillEdit()
        return await self.app.refreshFragments()
    }

    @Wired("skill-delete", events: [.click])
    func handleSkillDelete(_ event: EventData) async -> [FragmentUpdate] {
        // The handler (`deleteSkill`) has existed all along with no trigger
        // rendered anywhere: the detail pane's trash button is that trigger,
        // and it arms the shared dialog because it removes a folder on disk.
        guard let name = await self.app.selectedSkill, !name.isEmpty else { return [] }
        await self.app.requestConfirm(ConfirmRequest(
            kind: "skill", id: name, title: "Delete skill?",
            body: "The skill “\(name)” and its folder under ~/.arc/skills will be removed. This cannot be undone."))
        return await self.app.refreshFragments()
    }

    @Wired("sk-edit-form", events: [.submit, .click])
    func handleSkEditForm(_ event: EventData) async -> [FragmentUpdate] {
        // Clicks on form children (the id-less Save button resolves to the
        // form) carry NO field values: only handle the named action
        // buttons here. The Save button's real work arrives as a "submit".
        if event.event == "click" {
            if event.string("targetId") == "«redacted:sk-…»" {
                await self.app.cancelSkillEdit()
                return await self.app.refreshFragments()
            }
            return []
        }
        let orig = event.string("sk-orig") ?? ""
        let name = (event.string("«redacted:sk-…»") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = (event.string("«redacted:sk-…»") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = event.string("«redacted:sk-…»") ?? ""
        let content = event.string("«redacted:sk-…»") ?? ""
        return await self.saveSkill(original: orig, name: name, category: cat, desc: desc, content: content)
    }

    @Wired("skill-name-input", events: [.input])
    func handleSkillNameInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("skill-name-input", event.string("value") ?? "")
        // UX-26: clear the inline error as the user types in a field —
        // only pay for a fragment when an error was actually showing
        // (the engine restores the field's value and caret across the
        // patch, so the clear lands without disturbing the keystroke).
        if await self.app.clearSkillCreateError(for: "skill-name-input") {
            return await self.app.refreshFragments()
        }
        return []
    }

    @Wired("skill-cat-input", events: [.input])
    func handleSkillCatInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("skill-cat-input", event.string("value") ?? "")
        return []
    }

    @Wired("skill-desc-input", events: [.input])
    func handleSkillDescInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("skill-desc-input", event.string("value") ?? "")
        if await self.app.clearSkillCreateError(for: "skill-desc-input") {
            return await self.app.refreshFragments()
        }
        return []
    }

    @Wired("skill-content-input", events: [.input])
    func handleSkillContentInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("skill-content-input", event.string("value") ?? "")
        return []
    }
}

@WireGroup("profiles")
extension Controller {
    @Wired("profile-new", events: [.click])
    func handleProfileNew(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setCreateProfile(true)
        return await self.app.refreshFragments()
    }

    @Wired("profile-create-form", events: [.submit])
    func handleProfileCreateForm(_ event: EventData) async -> [FragmentUpdate] {
        let name = (event.string("profile-name-input") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = event.string("profile-title-input") ?? ""
        let desc = event.string("profile-desc-input") ?? ""
        let ctxLength = AppState.optInt(event.string("profile-ctx-length") ?? "")
        let maxOutput = AppState.optInt(event.string("profile-ctx-maxtok") ?? "")
        let rawEffort = event.string("profile-ctx-effort") ?? ""
        let effort = rawEffort.isEmpty ? nil : rawEffort
        let temperature = AppState.optDouble(event.string("profile-ctx-temp") ?? "")
        let topP = AppState.optDouble(event.string("profile-ctx-topp") ?? "")
        let budget = AppState.optInt(event.string("profile-ctx-budget") ?? "")
        let skillsDraft = await self.app.profileSkillsDraft
        return await self.submitProfileForm(
            name: name, title: title, desc: desc,
            contextLength: ctxLength, maxOutputTokens: maxOutput,
            reasoningEffort: effort, temperature: temperature,
            topP: topP, compressionBudget: budget,
            contextSkills: skillsDraft.isEmpty ? nil : skillsDraft
        )
    }

    @Wired("pcs-toggle", events: [.click])
    func handlePcsToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setProfileSkillsPickerOpen(!(await self.app.profileSkillsPickerOpen))
        return await self.app.refreshFragments()
    }

    @Wired("pcs", events: [.click])
    func handlePcsPick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("pcs-pick-") else { return [] }
        guard let name = dec(String(tid.dropFirst("pcs-pick-".count))) else { return [] }
        await self.app.profileSkillsDraftAdd(name)
        await self.app.setProfileSkillsPickerOpen(false)
        return await self.app.refreshFragments()
    }

    @Wired("pcs-rm", events: [.click])
    func handlePcsRm(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("pcs-rm-") else { return [] }
        guard let name = dec(String(tid.dropFirst("pcs-rm-".count))) else { return [] }
        await self.app.profileSkillsDraftRemove(name)
        return await self.app.refreshFragments()
    }

    @Wired("profile-name-input", events: [.input])
    func handleProfileNameInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("profile-name-input", event.string("value") ?? "")
        return []
    }

    @Wired("profile-title-input", events: [.input])
    func handleProfileTitleInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("profile-title-input", event.string("value") ?? "")
        return []
    }

    @Wired("profile-desc-input", events: [.input])
    func handleProfileDescInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("profile-desc-input", event.string("value") ?? "")
        return []
    }

    @Wired("profile-cancel", events: [.click])
    func handleProfileCancel(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setCreateProfile(false)
        await self.app.setEditingProfile(nil)
        return await self.app.refreshFragments()
    }

    @Wired("profile-list", events: [.click])
    func handleProfileList(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        return await self.profileListAction(tid)
    }

    @Wired("profile-skills", events: [.change])
    func handleProfileSkills(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? event.string("value") ?? ""
        guard tid.hasPrefix("ps-") else { return [] }
        let rest = String(tid.dropFirst("ps-".count))
        let parts = rest.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pname = dec(parts[0]) else { return [] }
        let skillName = dec(parts[1]) ?? ""
        let on = event.checked == true
        await self.app.toggleProfileSkill(profile: pname, skill: skillName, on: on)
        return await self.app.refreshFragments()
    }
}

@WireGroup("chatmenu")
extension Controller {
    @Wired("chat-menu", events: [.click, .submit])
    func handleChatMenu(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            guard let sid = event.string("rename-id"), let name = event.string("rename-name") else { return [] }
            await self.app.renameSession(sid, to: name)
            return await self.app.refreshFragments()
        }
        let tid = event.string("targetId") ?? ""
        if tid.hasPrefix("sm-rename-") {
            return []   // client-side inline editor
        }
        if tid.hasPrefix("sm-copy-") {
            // The server hands the resolved URL back inside the #toasts
            // fragment as a hidden marker that the overlay's post-patch
            // pass writes to the clipboard. The overlay now owns the
            // toast: it flashes "Conversation link copied." on success
            // and "Could not copy the link." on failure — exactly one
            // toast, owned by the clipboard result (UX-24). The server
            // must not surface its own success toast, or a failed write
            // would show the wrong message first.
            guard let sid = dec(String(tid.dropFirst("sm-copy-".count))) else { return [] }
            await self.app.markCopyLink(sid)
            return [fragment("toasts", await self.app.toastsShell())]
        }
        if tid.hasPrefix("sm-pin-"), let id = dec(String(tid.dropFirst("sm-pin-".count))) {
            await self.app.toggleBookmark(id)
        } else if tid.hasPrefix("sm-arc-"), let id = dec(String(tid.dropFirst("sm-arc-".count))) {
            await self.app.toggleArchive(id)
        } else if tid.hasPrefix("sm-dup-"), let id = dec(String(tid.dropFirst("sm-dup-".count))) {
            await self.app.duplicateSession(id)
        } else if tid.hasPrefix("sm-del-"), let id = dec(String(tid.dropFirst("sm-del-".count))) {
            await self.app.requestDeleteSession(id)
        } else if tid.hasPrefix("sm-uncat-"), let id = dec(String(tid.dropFirst("sm-uncat-".count))) {
            await self.app.setChatCategory(id, to: nil)
        } else if tid.hasPrefix("sm-cat-") {
            let rest = String(tid.dropFirst("sm-cat-".count))
            let parts = rest.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let catID = dec(parts[0]), let sid = dec(parts[1]) else { return [] }
            await self.app.setChatCategory(sid, to: catID)
        } else {
            return []
        }
        return await self.app.refreshFragments()
    }

    @Wired("modal", events: [.click])
    func handleModal(_ event: EventData) async -> [FragmentUpdate] {
        // One dialog, one dispatch: `activeConfirm` exposes whichever
        // destructive action is armed (profile / chat keep their original
        // state fields; workspaces arm `pendingConfirm`).
        let confirmed = event.string("targetId") == "modal-confirm"
        guard confirmed, let req = await self.app.activeConfirm else {
            await self.app.cancelDelete()
            await self.app.cancelProfileDelete()
            await self.app.cancelConfirm()
            return await self.app.refreshFragments()
        }
        switch req.kind {
        case "profile":
            await self.app.cancelProfileDelete()
            return await self.deleteProfile(req.id)
        case "chat":
            await self.app.confirmDeleteSession(req.id)
        case "workspace":
            await self.app.cancelConfirm()
            await self.deleteWorkspace(req.id)
        case "mcp":
            await self.app.cancelConfirm()
            await self.app.removeMCPServer(req.id)
        case "skill":
            await self.app.cancelConfirm()
            await self.deleteSkill(req.id)
        case "empty-drafts":
            await self.app.cancelConfirm()
            await self.app.clearEmptyDrafts()
        default:
            await self.app.cancelConfirm()
        }
        return await self.app.refreshFragments()
    }

    @Wired("chat-showarch", events: [.click])
    func handleChatShowArch(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setShowArchived(!self.app.showArchived)
        return await self.app.refreshFragments()
    }

    @Wired("chat-clear-empty", events: [.click])
    func handleChatClearEmpty(_ event: EventData) async -> [FragmentUpdate] {
        let n = await self.app.emptyDraftCount()
        guard n > 0 else { return await self.app.refreshFragments() }
        await self.app.requestConfirm(ConfirmRequest(
            kind: "empty-drafts", id: "",
            title: n == 1 ? "Clear the empty chat?" : "Clear \(n) empty chats?",
            body: n == 1
                ? "1 conversation with no messages will be deleted. This cannot be undone."
                : "\(n) conversations with no messages will be deleted. This cannot be undone."))
        return await self.app.refreshFragments()
    }

    @Wired("drawer-toggle", events: [.click])
    func handleDrawerToggle(_ event: EventData) async -> [FragmentUpdate] {
        return []
    }

    @Wired("outline-toggle", events: [.click])
    func handleOutlineToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.toggleOutline()
        return [fragment("outline-panel", await self.app.outlinePanelHTML)]
    }

    @Wired("outline-close", events: [.click])
    func handleOutlineClose(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.closeOutline()
        return [fragment("outline-panel", await self.app.outlinePanelHTML)]
    }
}

@WireGroup("workspaces")
extension Controller {
    @Wired("ws-new", events: [.click])
    func handleWsNew(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.openWorkspaceCreate(forChat: false)
        return await self.app.refreshFragments()
    }

    @Wired("ws-create-form", events: [.submit])
    func handleWsCreateForm(_ event: EventData) async -> [FragmentUpdate] {
        let name = event.string("ws-name-input") ?? ""
        let path = event.string("ws-path-input") ?? ""
        return await self.createWorkspace(name: name, path: path)
    }

    @Wired("ws-name-input", events: [.input])
    func handleWsNameInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("ws-name-input", event.string("value") ?? "")
        return []
    }

    @Wired("ws-path-input", events: [.input])
    func handleWsPathInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("ws-path-input", event.string("value") ?? "")
        return []
    }

    @Wired("ws-cancel", events: [.click])
    func handleWsCancel(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.closeWorkspaceCreate()
        return await self.app.refreshFragments()
    }

    @Wired("workspace-list", events: [.click])
    func handleWorkspaceList(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        return await self.workspaceListAction(tid)
    }
}

@WireGroup("mcp")
extension Controller {
    @Wired("mcp-add", events: [.click])
    func handleMcpAdd(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.openMCPAdd()
        return await self.app.refreshFragments()
    }

    @Wired("mcp-cancel", events: [.click])
    func handleMcpCancel(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.closeMCPForm()
        return await self.app.refreshFragments()
    }

    @Wired("mcp-name-input", events: [.input])
    func handleMcpNameInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mcp-name-input", event.string("value") ?? "")
        return []
    }

    @Wired("mcp-command-input", events: [.input])
    func handleMcpCommandInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mcp-command-input", event.string("value") ?? "")
        return []
    }

    @Wired("mcp-args-input", events: [.input])
    func handleMcpArgsInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mcp-args-input", event.string("value") ?? "")
        return []
    }

    @Wired("mcp-env-input", events: [.input])
    func handleMcpEnvInput(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mcp-env-input", event.string("value") ?? "")
        return []
    }

    @Wired("mcp-form", events: [.submit])
    func handleMcpForm(_ event: EventData) async -> [FragmentUpdate] {
        return await self.saveMCPServer(
            name: event.string("mcp-name-input") ?? "",
            command: event.string("mcp-command-input") ?? "",
            argsText: event.string("mcp-args-input") ?? "",
            envText: event.string("mcp-env-input") ?? "")
    }

    @Wired("mcp-list", events: [.click])
    func handleMcpList(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        return await self.mcpListAction(tid)
    }
}

@WireGroup("tools")
extension Controller {
    @Wired("tool-list", events: [.click])
    func handleToolList(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("tl-open-") else { return [] }
        let name = dec(String(tid.dropFirst("tl-open-".count))) ?? ""
        await self.app.selectTool(name)
        return await self.app.refreshFragments()
    }

    @Wired("tools-toggle", events: [.change])
    func handleToolsToggle(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? event.string("value") ?? ""
        guard tid.hasPrefix("ts-") else { return [] }
        let ts = dec(String(tid.dropFirst("ts-".count))) ?? ""
        let on = event.checked == true
        await self.app.setToolset(ts, enabled: on)
        return await self.app.refreshFragments()
    }
}

@WireGroup("plugins")
extension Controller {
    @Wired("plugin-toggle", events: [.change])
    func handlePluginToggle(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? event.string("value") ?? ""
        guard tid.hasPrefix("plgl-") else { return [] }
        let name = dec(String(tid.dropFirst("plgl-".count))) ?? ""
        let on = event.checked == true
        await self.app.setPluginEnabled(name, enabled: on)
        return await self.app.refreshFragments()
    }

    @Wired("plugin-rescan", events: [.click])
    func handlePluginRescan(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.refreshPlugins()
        return await self.app.refreshFragments()
    }
}

@WireGroup("logs")
extension Controller {
    @Wired("log-filter", events: [.click])
    func handleLogFilter(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("log-filter-") else { return [] }
        let lvl = String(tid.dropFirst("log-filter-".count))
        await self.app.setLogFilter(lvl)
        return await self.app.logsFragments()
    }

    @Wired("log-clear", events: [.click])
    func handleLogClear(_ event: EventData) async -> [FragmentUpdate] {
        LogCollector.shared.clear()
        return await self.app.logsFragments()
    }
}

@WireGroup("insights")
extension Controller {
    @Wired("ins-range", events: [.change])
    func handleInsRange(_ event: EventData) async -> [FragmentUpdate] {
        let days = Int(event.string("value") ?? "30") ?? 30
        await self.app.setInsightsRange(days)
        return await self.app.refreshFragments()
    }
}

@WireGroup("toasts")
extension Controller {
    @Wired("toast-dismiss", events: [.click])
    func handleToastDismiss(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        if tid.hasPrefix("ta-") {
            // Toast action button: `ta-<actionId>-<toastId>`. The action id
            // may itself contain dashes, so split at the LAST dash.
            let rest = String(tid.dropFirst("ta-".count))
            guard let lastDash = rest.lastIndex(of: "-"),
                  Int(rest[rest.index(after: lastDash)...]) != nil else { return [] }
            let actionID = String(rest[..<lastDash])
            if actionID == "undo-delete" {
                let ok = await self.app.undoDeleteChat()
                if !ok {
                    _ = await self.app.surfaceToast("Could not restore the conversation.", kind: "error")
                } else if let toastID = Int(rest[rest.index(after: lastDash)...]) {
                    // The Undo was consumed — retire its own toast so it
                    // cannot offer a second, dead undo (refreshFragments
                    // below re-renders #toasts from the shorter list).
                    await self.app.dismissToast(id: toastID)
                }
                return await self.app.refreshFragments()
            }
            return []
        }
        guard tid.hasPrefix("t-"),
              let id = Int(tid.dropFirst("t-".count)) else { return [] }
        await self.app.dismissToast(id: id)
        return [fragment("toasts", await self.app.toastsShell())]
    }
}

extension Controller {

    private func wireSkills(_ router: EventRouter) {
        wireGroup_skills(router)
        // The redacted/interpolated `«redacted:sk-…»` ids stay hand-written
        // (documented escape): they are not static literals the macro can
        // register, and the 4-field input loop reuses one id for each field.
    }

    private func wireChat(_ router: EventRouter) {
        wireGroup_chat(router)
        // `cat-pick` stays hand-written: it carries `contextmenu`, which is not
        // an `HTMLEvent` case, so the `@Wired` macro cannot express it. It is
        // the only remaining literal-id `wire` site in this function.
        wire(router, id: "cat-pick", events: ["click", "contextmenu"]) { event in
            guard let tid = event.string("targetId") else { return [] }
            if event.event == "contextmenu" {
                // Right-click on a category chip opens its edit menu.
                guard tid.hasPrefix("cat-"),
                      let id = dec(String(tid.dropFirst("cat-".count))),
                      await self.app.categoryExists(id)
                else { return [] }
                let x = Int(event.string("mouseX") ?? "") ?? 0
                let y = Int(event.string("mouseY") ?? "") ?? 0
                await self.app.openCategoryMenu(id: id, x: x, y: y)
                return await self.app.refreshFragments()
            }
            return await self.categoryAction(tid)
        }
    }

    /// Category chip + add/delete actions above the chat list.
    private func categoryAction(_ tid: String) async -> [FragmentUpdate] {
        if tid == "cat-all" {
            await app.setActiveCategory("all")
        } else if tid == "cat-unassigned" {
            await app.setActiveCategory("unassigned")
        } else if tid == "cat-add" {
            await app.setAddingCategory(!app.addingCategory)
        } else if tid.hasPrefix("cat-del-") {
            if let id = dec(String(tid.dropFirst("cat-del-".count))) {
                await app.deleteCategory(id)
            }
        } else if tid.hasPrefix("cat-") {
            if let id = dec(String(tid.dropFirst("cat-".count))) {
                await app.setActiveCategory(id)
            }
        }
        return await app.refreshFragments()
    }

    /// Chat row “⋮” menu (copy link / rename / pin / archive / duplicate /
    /// delete), the centered delete-confirmation modal, and the archived list
    /// toggle.
    private func wireChatMenu(_ router: EventRouter) {
        wireGroup_chatmenu(router)
    }

    private func newChat() async {
        await app.ensureRuntime()
        // Reuse the current chat when it is still a pristine "New chat":
        // a double-click on + (or pressing + while the fresh chat is already
        // open) used to mint duplicate empty rows. A pristine empty chat is
        // indistinguishable from the one already on screen, so keep it.
        if let activeID = await app.activeSessionID,
           await app.isPristineNewChat(activeID) {
            await app.setActiveSession(activeID)
            return
        }
        // UX-10: do not persist an untouched new chat. Create a client-side
        // draft instead — it only hits the store on the first send.
        let session = Session()
        await app.setDraftSession(session)
        await app.setActiveSession(session.id)
        _ = await app.hint("New chat.")
    }

    private func sessionListAction(_ tid: String) async -> [FragmentUpdate] {
        if tid.hasPrefix("s-open-"), let id = dec(String(tid.dropFirst("s-open-".count))) {
            await app.setActiveSession(id)
            await app.clearPendingDelete()
            return await app.refreshFragments()
        }
        // The row menu (⋮) is toggled client-side; no server re-render so the
        // open menu survives the click that opened it.
        if tid.hasPrefix("s-menu-") {
            return []
        }
        return []
    }

    private func deleteActiveChat() async {
        guard let id = await app.activeSessionID else { return }
        await app.requestDeleteSession(id)
    }

    func submitChat(text raw: String) async -> [FragmentUpdate] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Context-only turns: an empty prompt is allowed when context blocks
        // are attached ("Reply with selection" chips) — the inlined contexts
        // become the message the agent receives (send contexts alone).
        if trimmed.isEmpty {
            if await app.pendingContexts.isEmpty { return [] }
        }

        // Builtin slash commands are resolved locally (arc agent webui
        // COMMANDS) before anything else, including while a turn is running.
        if trimmed.hasPrefix("/") {
            if let updates = await handleBuiltinSlashCommand(trimmed) {
                return updates
            }
        }

        // reference `agent/skill_commands.py`: `/skill-name [instruction]` (and
        // stacked `/skill-a /skill-b do X`) expands into the model-facing
        // user message that embeds the full skill bodies. The transcript
        // shows the typed line via `displayText` (reference
        // `_slashDisplayTextOverride` pattern).
        var displayOverride: String? = nil
        var dispatchText = trimmed
        if let expanded = SkillCommands.expandSlashCommand(trimmed) {
            displayOverride = trimmed
            dispatchText = expanded
            await recordSlashSkillUse(trimmed)
        }

        // "Reply with selection" context blocks (reference
        // `_composerTextWithPendingSelections`): inline them as
        // `**Context N:**` + blockquote sections, then clear the chips.
        let withContexts = await app.composeWithPendingContexts(dispatchText)
        await app.clearPendingContexts()

        // arc parity (UX-04): while a turn in THIS chat is running, a
        // submitted message is QUEUED — it shows as a "Queued · N" chip above
        // the composer, runs as its own turn after the current reply, and can
        // be removed before it runs. A message typed in a different chat is
        // not queued: it starts its own concurrent turn (the two runs are
        // independent).
        let sid = await app.activeSessionID ?? ""
        // UX-10: if this chat is still a client-side draft (created by `+` and
        // never sent), persist it to the store on the first send so the
        // conversation survives past this page. A draft that is navigated away
        // from before any send is simply dropped (see setActiveSession).
        if await app.isDraftSession(sid) {
            await app.persistDraftSession(sid)
        }
        if await app.isTurnActive(sessionID: sid) {
            await app.queueSend(withContexts, sessionID: sid)
            return await app.chatFragments()
        }
        let pusher = push
        Task {
            await self.app.runTurn(userText: withContexts, pusher: pusher, sessionID: sid, displayText: displayOverride)
        }
        // Sender-side response: clear the composer. The transcript and the turn
        // chrome reach every page through the turn-start broadcast a moment later
        // (runTurn), so returning them here would only replace `#main` and kill
        // the sender's scroll/selection for a frame.
        return [fragment("composer-wrap", await self.app.composerHTML())]
    }

    /// Resolve the skill a typed invocation refers to and bump its usage
    /// counter (reference `tools.skill_usage.bump_use`).
    private func recordSlashSkillUse(_ typed: String) async {
        let tokens = typed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first,
              let key = SkillCommands.resolveSkillCommandKey(first),
              let info = SkillCommands.getSkillCommands()[key]
        else { return }
        await app.recordSkillEvent(name: info.name, uses: 1)
    }

    /// Append a user message to the active session and persist it (for local
    /// slash-command echoes).
    private func echoUserMessage(_ text: String) async {
        guard let sid = await app.activeSessionID,
              let idx = await app.sessions.firstIndex(where: { $0.id == sid })
        else { return }
        let msg = Message(role: .user, content: text, createdAt: Date())
        await app.appendToSession(idx: idx, message: msg)
    }

    /// Append an assistant note to the active session and persist it (for
    /// local slash-command responses).
    private func pushAssistantNote(_ text: String) async {
        guard let sid = await app.activeSessionID,
              let idx = await app.sessions.firstIndex(where: { $0.id == sid })
        else { return }
        let msg = Message(role: .assistant, content: text, createdAt: Date())
        await app.appendToSession(idx: idx, message: msg)
    }

    /// Local slash-command dispatch. Returns `nil` when the text is not a
    /// recognized builtin (fall through to skill expansion / normal send).
    private func handleBuiltinSlashCommand(_ text: String) async -> [FragmentUpdate]? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let nameToken = parts.first else { return nil }
        let name = String(nameToken.dropFirst()).lowercased()
        let args = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let builtins = AppState.slashBuiltins.map { $0.name }
        guard builtins.contains(name) else { return nil }

        // /usage — existing arc-parity toggle, kept verbatim.
        if name == "usage" {
            await app.toggleShowTokenUsage()
            let on = await app.settings.showTokenUsage
            _ = await app.hint(on ? "Token usage on." : "Token usage off.")
            return await app.chatFragments()
        }
        if name == "stop" {
            let sid = await app.activeSessionID ?? ""
            await app.requestStopTurn(sessionID: sid)
            _ = await app.hint("Stopping current response…")
            return await app.chatFragments()
        }
        if name == "new" {
            await self.newChat()
            _ = await app.hint("Started a new chat.")
            return await app.chatFragments()
        }
        if name == "title" {
            if args.isEmpty {
                _ = await app.hint("Usage: /title <new title>", kind: "error")
                return await app.chatFragments()
            }
            let sid = await app.activeSessionID ?? ""
            await app.renameSession(sid, to: args)
            _ = await app.hint("Renamed chat to \(trunc(args, 60)).")
            return await app.chatFragments()
        }
        if name == "workspace" {
            if args.isEmpty {
                _ = await app.hint("Usage: /workspace <name>", kind: "error")
                return await app.chatFragments()
            }
            let workspaces = await app.settings.workspaces
            guard workspaces.contains(where: { $0.name == args }) else {
                _ = await app.hint("No workspace named '\(args)'.", kind: "error")
                return await app.chatFragments()
            }
            await app.setWorkspace(active: args)
            _ = await app.hint("Workspace '\(args)'.")
            return await app.chatFragments()
        }
        if name == "model" {
            if args.isEmpty {
                _ = await app.hint("Usage: /model <name>", kind: "error")
                return await app.chatFragments()
            }
            let configs = await app.settings.modelConfigs
            guard configs.contains(where: { $0.name == args }) else {
                _ = await app.hint("No model configuration '\(args)'.", kind: "error")
                return await app.chatFragments()
            }
            await app.useModelConfig(args)
            _ = await app.hint("Model '\(trunc(args, 40))'.")
            return await app.chatFragments()
        }
        if name == "theme" {
            if args.isEmpty {
                let names = ArcThemeCatalog.entries.map { $0.id }
                await echoUserMessage(text)
                await pushAssistantNote("Available color schemes:\n\n" + names.map { "  `\($0)`" }.joined(separator: "\n"))
                return await app.chatFragments()
            }
            // Resolve by id first, then by label, case-insensitively.
            let byID = ArcThemeCatalog.entries.first { $0.id.lowercased() == args.lowercased() }
            let byLabel = byID == nil ? ArcThemeCatalog.entries.first { $0.label.lowercased() == args.lowercased() } : nil
            guard let scheme = byID ?? byLabel else {
                _ = await app.hint("No scheme named '\(args)'. Use /theme to list.", kind: "error")
                return await app.chatFragments()
            }
            await app.setColorScheme(scheme.id)
            _ = await app.hint("Theme '\(scheme.label)'.")
            return await app.chatFragments()
        }
        if name == "help" {
            await echoUserMessage(text)
            var lines: [String] = []
            for b in AppState.slashBuiltins {
                let usage = b.arg.map { ($0.hasPrefix("[") || $0.hasPrefix("<")) ? " \($0)" : " <\($0)>" } ?? ""
                lines.append("  /`\(b.name)`\(usage) — \(b.desc)")
            }
            lines.append("")
            lines.append("Any installed skill can also be invoked directly: type `/` and autocomplete, or `/skill-name <instruction>` (stacked skills allowed: `/a /b do X`).")
            await pushAssistantNote("Available slash commands:\n\n" + lines.joined(separator: "\n"))
            return await app.chatFragments()
        }
        if name == "skills" {
            await echoUserMessage(text)
            let q = args.lowercased()
            let skills = await app.skills
            let filtered = q.isEmpty
                ? skills
                : skills.filter {
                    $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
                }
            guard !filtered.isEmpty else {
                await pushAssistantNote("No skills matching \"\(args)\".")
                return await app.chatFragments()
            }
            let grouped = Dictionary(grouping: filtered) { ($0.category?.isEmpty == false ? $0.category! : "General") }
            var out: [String] = []
            out.append(q.isEmpty ? "Available skills (\(filtered.count)):\n" : "Skills matching \"\(args)\" (\(filtered.count)):\n")
            for cat in grouped.keys.sorted() {
                out.append("**\(cat)**")
                for skill in grouped[cat]!.sorted(by: { $0.name < $1.name }) {
                    let d = skill.description.count > 80 ? String(skill.description.prefix(80)) + "..." : skill.description
                    out.append("  `\(skill.name)` — \(d)")
                }
                out.append("")
            }
            await pushAssistantNote(out.joined(separator: "\n"))
            return await app.chatFragments()
        }
        if name == "use" {
            guard !args.isEmpty else {
                await pushAssistantNote("Usage: `/use <skill-name>` — forces the agent to consult that skill before its next response.")
                return await app.chatFragments()
            }
            guard let key = SkillCommands.resolveSkillCommandKey(args),
                  let info = SkillCommands.getSkillCommands()[key],
                  let content = try? String(contentsOf: info.skillMDURL, encoding: .utf8)
            else {
                await echoUserMessage(text)
                await pushAssistantNote("No skill named `\(args)`. Use `/skills` to see available skills.")
                return await app.chatFragments()
            }
            await echoUserMessage(text)
            await pushAssistantNote("Next turn: skill `\(info.name)` will be forced.")
            let directive = "[USER OVERRIDE] You MUST follow the skill '\(info.name)' content provided below before responding to the next message."
            let forced = "[FORCED SKILL CONTEXT: \(info.name)]\n\(content)\n[/FORCED SKILL CONTEXT]"
            let sid = await app.activeSessionID ?? ""
            let pusher = push
            Task {
                await self.app.runTurn(
                    userText: directive + "\n\n" + forced + "\n\n" + (args.split(separator: " ", maxSplits: 1).dropFirst().joined(separator: " ")),
                    pusher: pusher, sessionID: sid, displayText: text
                )
            }
            return await app.chatFragments()
        }
        return nil
    }

    private func attachFile(_ path: String) async -> [FragmentUpdate] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = await app.hint("Enter a file path to attach.", kind: "error")
            return await app.chatFragments()
        }
        let exists = FileManager.default.fileExists(atPath: NSString(string: trimmed).expandingTildeInPath)
        guard exists else {
            _ = await app.hint("No such file: \(trunc(trimmed, 60))", kind: "error")
            return await app.chatFragments()
        }
        await app.addAttachment(trimmed)
        _ = await app.hint("Attached \(trunc(trimmed, 60))")
        return await app.chatFragments()
    }

    // MARK: Skills

    /// Rewrite the SKILL.md of an existing skill (renaming its directory when
    /// the name changes), mirroring createSkill's file format.
    private func saveSkill(original: String, name: String, category: String, desc: String, content: String) async -> [FragmentUpdate] {
        guard !name.isEmpty, !desc.isEmpty else {
            _ = await app.hint("Skill needs at least a name and a description.", kind: "error")
            return await app.refreshFragments()
        }
        guard let current = await app.skill(named: original) else { return await app.refreshFragments() }
        let fm = FileManager.default
        do {
            let oldDir = current.path.deletingLastPathComponent()
            var target = current.path
            if name != original {
                let newDir = oldDir.deletingLastPathComponent().appendingPathComponent(name)
                try fm.moveItem(at: oldDir, to: newDir)
                target = newDir.appendingPathComponent("SKILL.md")
            }
            var frontmatter = "---\nname: \(name)\ndescription: \(desc)\n"
            if !category.isEmpty { frontmatter += "category: \(category)\n" }
            frontmatter += "---\n\n"
            let body = await app.skillBody(content)
            try (frontmatter + body).write(to: target, atomically: true, encoding: .utf8)
        } catch {
            _ = await app.hint("Failed to save skill: \(error)", kind: "error")
            return await app.refreshFragments()
        }
        await app.reloadSkills()
        await app.cancelSkillEdit()
        await app.selectSkill(name)
        _ = await app.hint("Skill '\(name)' saved.")
        return await app.refreshFragments()
    }

    private func skillListAction(_ tid: String, checked: Bool? = nil) async -> [FragmentUpdate] {
        if tid.hasPrefix("sk-open-"), let name = dec(String(tid.dropFirst("sk-open-".count))) {
            await self.app.selectSkill(name)
            await self.app.recordSkillEvent(name: name, views: 1)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("sk-toggle-"), let name = dec(String(tid.dropFirst("sk-toggle-".count))) {
            await self.app.toggleSkill(name, enable: checked == true)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("sk-del-"), let name = dec(String(tid.dropFirst("sk-del-".count))) {
            await self.deleteSkill(name)
            return await self.app.refreshFragments()
        }
        return []
    }

    private func createSkill(name: String, desc: String, content: String, category: String = "") async -> [FragmentUpdate] {
        var errors: [String: String] = [:]
        if name.isEmpty { errors["skill-name-input"] = "Skill needs a name." }
        if desc.isEmpty { errors["skill-desc-input"] = "Skill needs a description." }
        if !errors.isEmpty {
            await self.app.setSkillCreateErrors(errors)
            _ = await self.app.hint("Skill needs at least a name and a description.", kind: "error")
            return await self.app.refreshFragments()
        }
        await self.app.setSkillCreateErrors([:])
        guard let dir = await self.app.skillsDir() else {
            _ = await self.app.hint("No skills directory available.", kind: "error")
            return await self.app.refreshFragments()
        }
        let skillDir = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            var body = "---\nname: \(name)\ndescription: \(desc)\n"
            if !category.isEmpty { body += "category: \(category)\n" }
            body += "---\n\n\(content)"
            try body.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            _ = await self.app.hint("Failed to create skill: \(error)", kind: "error")
            return await self.app.refreshFragments()
        }
        await self.app.reloadSkills()
        await self.app.setCreateSkill(false)
        await self.app.selectSkill(name)
        _ = await self.app.hint("Skill '\(name)' created.")
        return await self.app.refreshFragments()
    }

    private func deleteSkill(_ name: String) async {
        guard let skill = await app.skill(named: name) else { return }
        // Remove the skill's own directory (SKILL.md lives inside it); a bare
        // file removal would leave an empty folder behind.
        try? FileManager.default.removeItem(at: skill.path.deletingLastPathComponent())
        await app.reloadSkills()
        _ = await app.hint("Skill '\(name)' deleted.")
    }

    // MARK: Profiles

    private func wireProfiles(_ router: EventRouter) {
        wireGroup_profiles(router)
    }

    private func profileListAction(_ tid: String) async -> [FragmentUpdate] {
        if tid.hasPrefix("pr-edit-"), let name = dec(String(tid.dropFirst("pr-edit-".count))) {
            await self.app.setEditingProfile(name)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("pr-open-"), let name = dec(String(tid.dropFirst("pr-open-".count))) {
            await self.app.selectProfile(name)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("pr-sel-"), let name = dec(String(tid.dropFirst("pr-sel-".count))) {
            guard await self.app.activeSessionID != nil else {
                _ = await app.hint("Open a chat first, then select the profile for it.", kind: "error")
                return await self.app.refreshFragments()
            }
            await self.app.setChatProfile(name)
            await self.app.selectProfile(name)
            _ = await app.hint("Profile '\(name)' selected for this chat.")
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("pr-del-"), let name = dec(String(tid.dropFirst("pr-del-".count))) {
            if name == "default" {
                _ = await app.hint("The default profile cannot be deleted.", kind: "error")
                return await self.app.refreshFragments()
            }
            await self.app.requestProfileDelete(name)
            return await self.app.refreshFragments()
        }
        return []
    }

    /// Delete a non-default profile after the confirmation modal is confirmed,
    /// cleaning up session bindings and the profile's skills override.
    private func deleteProfile(_ name: String) async -> [FragmentUpdate] {
        guard name != "default" else {
            _ = await app.hint("The default profile cannot be deleted.", kind: "error")
            return await self.app.refreshFragments()
        }
        let pm = ProfileManager()
        do {
            try await pm.delete(name: name)
        } catch {
            _ = await app.hint("Failed to delete profile: \(error)", kind: "error")
            return await self.app.refreshFragments()
        }
        await self.app.reloadProfiles()
        await self.app.removeProfileRefs(name)
        _ = await app.hint("Profile '\(name)' deleted.")
        return await self.app.refreshFragments()
    }

    /// Create or update a profile from the profile form (the form doubles as
    /// the edit form; `editingProfile` selects the mode). Context parameters
    /// are stored per-profile via the core `Profile.context`.
    private func submitProfileForm(
        name: String,
        title: String,
        desc: String,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEffort: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        compressionBudget: Int? = nil,
        contextSkills: [String]? = nil
    ) async -> [FragmentUpdate] {
        let pm = ProfileManager()
        let ctx = ProfileContextConfig(
            contextLength: contextLength,
            maxOutputTokens: maxOutputTokens,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            topP: topP,
            compressionBudget: compressionBudget
        )
        let cleaned = ctx.isEmpty ? nil : ctx
        do {
            if let editName = await self.app.editingProfile {
                guard var p = try await pm.get(name: editName) else {
                    _ = await app.hint("Profile '\(editName)' no longer exists.", kind: "error")
                    return await self.app.refreshFragments()
                }
                p.title = title
                p.description = desc
                p.context = cleaned
                p.contextSkills = contextSkills
                try await pm.update(p)
                await self.app.setEditingProfile(nil)
                await app.reloadProfiles()
                await app.selectProfile(p.name)
                _ = await app.hint("Profile '\(p.name)' updated.")
            } else {
                guard !name.isEmpty else {
                    _ = await app.hint("Profile needs a name.", kind: "error")
                    return await self.app.refreshFragments()
                }
                var p = try await pm.create(name: name)
                p.title = title
                p.description = desc
                p.context = cleaned
                p.contextSkills = contextSkills
                try await pm.update(p)
                await app.reloadProfiles()
                await app.setCreateProfile(false)
                await app.selectProfile(name)
                _ = await app.hint("Profile '\(name)' created.")
            }
        } catch {
            _ = await app.hint("Failed to save profile: \(error)", kind: "error")
            return await self.app.refreshFragments()
        }
        return await self.app.refreshFragments()
    }

    // MARK: Tools

    private func wireTools(_ router: EventRouter) {
        wireGroup_tools(router)
    }

    // MARK: Tool plugins (Settings)

    private func wirePlugins(_ router: EventRouter) {
        wireGroup_plugins(router)
    }

    // MARK: MCP servers (Settings)

    /// Settings → MCP servers: the `mcp_servers` block of `~/.arc/config.json`.
    /// The row buttons need the server name, so they ride `targetId` from the
    /// `mcp-list` boundary (the form controls carry their own component ids —
    /// `extractFormData` keys the submit payload by their `name`).
    private func wireMCP(_ router: EventRouter) {
        wireGroup_mcp(router)
    }

    private func mcpListAction(_ tid: String) async -> [FragmentUpdate] {
        if tid.hasPrefix("mcp-test-"), let name = dec(String(tid.dropFirst("mcp-test-".count))) {
            await app.testMCPServer(name)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("mcp-edit-"), let name = dec(String(tid.dropFirst("mcp-edit-".count))) {
            await app.openMCPEdit(name)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("mcp-del-"), let name = dec(String(tid.dropFirst("mcp-del-".count))) {
            await app.requestConfirm(ConfirmRequest(
                kind: "mcp", id: name, title: "Delete MCP server?",
                body: "“\(name)” will be removed from ~/.arc/config.json. Its process stops and the agent loses whatever tools it exposed; nothing inside the server's own directory is touched."))
            return await self.app.refreshFragments()
        }
        return []
    }

    private func saveMCPServer(name: String, command: String, argsText: String, envText: String) async -> [FragmentUpdate] {
        let previous = await app.editingMCPServer
        var previousConfig: MCPServerConfig?
        if let previous { previousConfig = await app.mcpServerConfig(previous) }
        do {
            let planned = try MCPRules.planEntry(
                name: name, command: command, argsText: argsText, envText: envText,
                previousName: previous, previous: previousConfig,
                existingNames: await app.mcpServerNames())
            await app.upsertMCPServer(name: planned.name, config: planned.config, previousName: previous)
            await app.closeMCPForm()
            _ = await app.hint("MCP server '\(planned.name)' saved — press Test to start it and list its tools.")
        } catch let e as MCPRuleError {
            // Re-render exactly what was submitted: the form restores from
            // `formValues`, which the debounced input wire may lag behind.
            await app.storeMCPFormValues(name: name, command: command, argsText: argsText, envText: envText)
            _ = await app.hint(e.description, kind: "error")
        } catch {
            await app.storeMCPFormValues(name: name, command: command, argsText: argsText, envText: envText)
            _ = await app.hint("Could not save the MCP server: \(error)", kind: "error")
        }
        return await self.app.refreshFragments()
    }

    // MARK: Workspaces

    private func wireWorkspaces(_ router: EventRouter) {
        wireGroup_workspaces(router)
    }

    private func workspaceListAction(_ tid: String) async -> [FragmentUpdate] {
        if tid.hasPrefix("ws-open-"), let name = dec(String(tid.dropFirst("ws-open-".count))) {
            return await self.switchWorkspace(name)
        }
        if tid.hasPrefix("ws-del-"), let name = dec(String(tid.dropFirst("ws-del-".count))) {
            // Confirmed like every other named-thing delete (profiles, chats):
            // the row's ✕ arms the dialog instead of removing the workspace.
            await app.requestConfirm(ConfirmRequest(
                kind: "workspace", id: name, title: "Delete workspace?",
                body: "“\(name)” will be removed from the workspace list. The folder on disk is not touched."))
            return await self.app.refreshFragments()
        }
        return []
    }

    private func createWorkspace(name rawName: String, path rawPath: String) async -> [FragmentUpdate] {
        let existing = await app.workspaceEntries()
        let entry: WorkspaceEntry
        do {
            entry = try WorkspaceRules.planEntry(name: rawName, path: rawPath, existing: existing)
        } catch let e as WorkspaceRuleError {
            // Re-render exactly what was submitted: the form restores from
            // `formValues`, which the debounced input wire may lag behind.
            await app.storeFormValue("ws-name-input", rawName)
            await app.storeFormValue("ws-path-input", rawPath)
            _ = await app.hint(e.description, kind: "error")
            return await self.app.refreshFragments()
        } catch {
            await app.storeFormValue("ws-name-input", rawName)
            await app.storeFormValue("ws-path-input", rawPath)
            _ = await app.hint("Could not add the workspace: \(error)", kind: "error")
            return await self.app.refreshFragments()
        }

        // Intent: the composer flow binds THIS chat (falling back to the
        // default when no chat is open); the panel flow makes the preset the
        // new global default.
        let forChat = await app.workspaceCreateForChat
        let hasChat = (await app.activeSessionID) != nil
        let bindToChat = forChat && hasChat
        await app.addWorkspace(entry, makeDefault: !bindToChat)
        if bindToChat {
            await app.setChatWorkspace(entry.name)
        }
        await app.rebuildAndReload()
        await app.closeWorkspaceCreate()
        await app.clearWorkspaceCreateFields()
        let effect = bindToChat ? "this chat now uses it" : "it is now the default"
        _ = await app.hint("Workspace '\(entry.name)' created at \(entry.path) — \(effect).")
        return await self.app.refreshFragments()
    }

    private func switchWorkspace(_ name: String) async -> [FragmentUpdate] {
        let active = await app.activeWorkspaceName()
        if name == active { return [] }
        await app.setWorkspace(active: name)
        await app.rebuildAndReload()
        _ = await app.hint("Default workspace is now '\(name)'. Chats without their own workspace use it.")
        return await self.app.refreshFragments()
    }

    private func deleteWorkspace(_ name: String) async {
        guard name != "main" else {
            _ = await app.hint("The main workspace cannot be deleted.", kind: "error")
            return
        }
        await app.removeWorkspace(name)
        await app.rebuildAndReload()
        _ = await app.hint("Removed workspace '\(name)'. Its folder was kept on disk.")
    }

    // MARK: Settings — @WireGroup("settings")

}

@WireGroup("settings")
extension Controller {
    @Wired("set-theme", events: [.change])
    func handleSetTheme(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTheme(event.string("value") ?? "light")
        return await self.app.refreshFragments()
    }

    @Wired("set-size", events: [.change])
    func handleSetSize(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTextSize(event.string("value") ?? "md")
        _ = await self.app.hint("Text size updated.")
        return await self.app.refreshFragments()
    }

    @Wired("theme-pick", events: [.click])
    func handleThemePick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("thm-") else { return [] }
        let theme = String(tid.dropFirst("thm-".count))
        await self.app.setTheme(theme)
        _ = await self.app.hint("Theme set to \(theme).")
        return await self.app.refreshFragments()
    }

    @Wired("font-size-pick", events: [.click])
    func handleFontSizePick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("fsz-") else { return [] }
        let size = String(tid.dropFirst("fsz-".count))
        await self.app.setTextSize(size)
        // UX-22: apply text-size to the live page without a reload.
        // `refreshFragments(includeApp:)` re-renders the #app shell,
        // which carries `data-size` (Views.swift:75) — the live page
        // changes in the same tick as the hint.
        _ = await self.app.hint("Text size updated.")
        return await self.app.refreshFragments(includeApp: true)
    }

    @Wired("scheme-pick", events: [.click])
    func handleSchemePick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("scheme-") else { return [] }
        if let name = dec(String(tid.dropFirst("scheme-".count))) {
            await self.app.setColorScheme(name)
        }
        return await self.app.refreshFragments()
    }

    @Wired("activity-display", events: [.click])
    func handleActivityDisplay(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("actdisp-") else { return [] }
        let mode = String(tid.dropFirst("actdisp-".count))
        await self.app.setActivityDisplay(mode)
        _ = await self.app.hint("Activity display set to \(mode.replacingOccurrences(of: "_", with: " "))")
        return await self.app.refreshFragments()
    }

    @Wired("set-think", events: [.change])
    func handleSetThink(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setDefaultThinking(event.string("value") ?? "medium")
        _ = await self.app.hint("Default thinking level updated.")
        return await self.app.refreshFragments()
    }

    @Wired("set-showtokens", events: [.change])
    func handleSetShowTokens(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setShowTokenUsage(event.checked == true)
        return await self.app.refreshFragments()
    }

    @Wired("set-showoutline", events: [.change])
    func handleSetShowOutline(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setShowConversationOutline(event.checked == true)
        return await self.app.refreshFragments()
    }

    @Wired("set-showtps", events: [.change])
    func handleSetShowTps(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setShowTps(event.checked == true)
        return await self.app.refreshFragments()
    }

    @Wired("set-smart-approval", events: [.change])
    func handleSetSmartApproval(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setSmartApproval(event.checked == true)
        return await self.app.refreshFragments()
    }

    @Wired("set-smart-pickapath", events: [.change])
    func handleSetSmartPickAPath(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setSmartPickAPath(event.checked == true)
        return await self.app.refreshFragments()
    }

    @Wired("set-pinlimit", events: [.change])
    func handleSetPinLimit(_ event: EventData) async -> [FragmentUpdate] {
        let n = Int(event.string("value") ?? "") ?? 3
        await self.app.setPinnedSessionsLimit(n)
        return await self.app.refreshFragments()
    }

    @Wired("aux-edit", events: [.click])
    func handleAuxEdit(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        if tid.hasPrefix("aux-edit-") {
            await self.app.setAuxEditing(String(tid.dropFirst("aux-edit-".count)))
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("aux-cancel-") {
            await self.app.setAuxEditing(nil)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("aux-reset-") {
            let key = String(tid.dropFirst("aux-reset-".count))
            if let task = AuxiliaryTask(configKey: key) {
                await self.app.clearAuxOverride(task: task)
            }
            await self.app.setAuxEditing(nil)
            return await self.app.refreshFragments()
        }
        return []
    }

    @Wired("aux-form", events: [.submit])
    func handleAuxForm(_ event: EventData) async -> [FragmentUpdate] {
        guard let key = event.string("aux-task"), let task = AuxiliaryTask(configKey: key) else { return [] }
        let staged = await self.app.auxStagedConfig[key] ?? ""
        if staged.isEmpty {
            await self.app.clearAuxOverride(task: task)
        } else {
            await self.app.setAuxOverrideFromConfig(task: task, configName: staged)
        }
        await self.app.clearAuxStage(task: key)
        await self.app.setAuxEditing(nil)
        return await self.app.refreshFragments()
    }

    @Wired("auxmc-toggle", events: [.click])
    func handleAuxMcToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setAuxConfigPickerOpen(!(await self.app.auxConfigPickerOpen))
        return await self.app.refreshFragments()
    }

    @Wired("auxmc", events: [.click])
    func handleAuxMc(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        if tid.hasPrefix("auxmc-main-") {
            let key = String(tid.dropFirst("auxmc-main-".count))
            await self.app.stageAuxConfig(task: key, name: "")
        } else if tid.hasPrefix("auxmc-") {
            let rest = String(tid.dropFirst("auxmc-".count))
            if let dash = rest.firstIndex(of: "-") {
                let key = String(rest[..<dash])
                let name = dec(String(rest[rest.index(after: dash)...])) ?? ""
                await self.app.stageAuxConfig(task: key, name: name)
            }
        }
        await self.app.setAuxConfigPickerOpen(false)
        return await self.app.refreshFragments()
    }

    @Wired("mainmc-toggle", events: [.click])
    func handleMainMcToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setMainModelPickerOpen(!(await self.app.mainModelPickerOpen))
        return await self.app.refreshFragments()
    }

    @Wired("mainmc", events: [.click])
    func handleMainMc(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"), tid.hasPrefix("mainmc-pick-") else { return [] }
        if let name = dec(String(tid.dropFirst("mainmc-pick-".count))) {
            await self.app.useModelConfig(name)
            _ = await self.app.hint("Active configuration: \(name)")
        }
        await self.app.setMainModelPickerOpen(false)
        return await self.app.refreshFragments()
    }

    @Wired("set-tessera", events: [.change])
    func handleSetTessera(_ event: EventData) async -> [FragmentUpdate] {
        let off = event.checked == true
        await self.app.setTesseraOff(off)
        await self.app.rebuildAndReload()
        _ = await self.app.hint(off ? "Switched to file storage." : "Switched to Tessera storage.", kind: off ? "" : "success")
        return await self.app.refreshFragments()
    }

    @Wired("set-moa", events: [.change])
    func handleSetMoa(_ event: EventData) async -> [FragmentUpdate] {
        let on = event.checked == true
        await self.app.setMoaEnabled(on)
        _ = await self.app.hint(on
            ? "Mixture of Agents enabled — reference models must be configured in ~/.arc/config.json."
            : "Mixture of Agents disabled.")
        return await self.app.refreshFragments()
    }

    @Wired("storage-pick-toggle", events: [.click])
    func handleStoragePickToggle(_ event: EventData) async -> [FragmentUpdate] {
        let next = !(await self.app.storagePickOpen)
        await self.app.setStoragePickOpen(next)
        return await self.app.refreshFragments()
    }

    @Wired("storage-pick", events: [.click])
    func handleStoragePick(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        if tid == "storage-pick-file" {
            await self.app.setStagedStorage("file")
        } else if tid == "storage-pick-config" {
            await self.app.setStagedStorage("config")
        } else if tid.hasPrefix("storage-pick-conn-"),
                  let cid = dec(String(tid.dropFirst("storage-pick-conn-".count))) {
            await self.app.setStagedStorage(cid)
        } else {
            return []
        }
        return await self.app.refreshFragments()
    }

    @Wired("storage-connect", events: [.click])
    func handleStorageConnect(_ event: EventData) async -> [FragmentUpdate] {
        let ok = await self.app.connectStagedStorage()
        if !ok {
            _ = await self.app.hint("Pick a different storage medium first — Save and Connect needs a change.")
            return await self.app.refreshFragments()
        }
        return await self.app.refreshFragments()
    }

    @Wired("storage-conn-form", events: [.submit])
    func handleStorageConnForm(_ event: EventData) async -> [FragmentUpdate] {
        let editID = (event.string("storage-edit-id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (event.string("sc-name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = (event.string("sc-ip") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int((event.string("sc-port") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let appid = UInt16(event.string("sc-app")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1
        let pub = (event.string("sc-pub") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let priv = (event.string("sc-priv") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = await self.app.saveStorageConnection(
            id: editID.isEmpty ? nil : editID,
            name: name, serverIP: ip, serverPort: port,
            application: appid, serverPublicKey: pub, myPrivateKey: priv)
        if ok {
            await self.app.clearStorageForm()
            _ = await self.app.hint("Tessera storage saved — pick it above and press Save and Connect to use it.", kind: "success")
        } else {
            _ = await self.app.hint("Check the storage name, IP and port (1–65535).")
        }
        return await self.app.refreshFragments()
    }
}

// The settings surface is split across two extensions because the file's first
// settings block is already long; two extensions need two group names, and both
// registrars are called from `wireSettings`. Without the annotation these 30
// `@Wired` markers expand to nothing and the handlers are never registered.
@WireGroup("settings_admin")
extension Controller {

    @Wired("storage-edit", events: [.click])
    func handleStorageEdit(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"),
              let cid = dec(String(tid.dropFirst("storage-edit-".count))) else { return [] }
        await self.app.beginStorageEdit(id: cid)
        return await self.app.refreshFragments()
    }

    @Wired("storage-del", events: [.click])
    func handleStorageDel(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"),
              let cid = dec(String(tid.dropFirst("storage-del-".count))) else { return [] }
        await self.app.removeStorageConnection(id: cid)
        _ = await self.app.hint("Tessera storage removed.", kind: "success")
        return await self.app.refreshFragments()
    }

    @Wired("storage-cancel-edit", events: [.click])
    func handleStorageCancelEdit(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.cancelStorageEdit()
        return await self.app.refreshFragments()
    }

    @Wired("ap-skills-global", events: [.change])
    func handleApSkillsGlobal(_ event: EventData) async -> [FragmentUpdate] {
        let on = event.checked == true
        await self.app.updateAgentPowers { $0.skillsManage = on }
        _ = await self.app.hint(
            on ? "Agent can create/edit skills." : "Skill creation/editing locked — only skill_creation / skill_edit while unlocked.",
            kind: "success")
        return await self.app.refreshFragments()
    }

    @Wired("ap-profile-global", events: [.change])
    func handleApProfileGlobal(_ event: EventData) async -> [FragmentUpdate] {
        let on = event.checked == true
        await self.app.updateAgentPowers { $0.profileEdit = on }
        _ = await self.app.hint(
            on ? "Agent can edit MEMORY/USER/SOUL/AGENTS." : "Profile editing locked — only profile_edit while unlocked.",
            kind: "success")
        return await self.app.refreshFragments()
    }

    @Wired("ap-skill-locks", events: [.change])
    func handleApSkillLocks(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? event.string("value") ?? ""
        guard tid.hasPrefix("ap-skill-lock-") else { return [] }
        let name = String(tid.dropFirst("ap-skill-lock-".count))
        let locked = event.checked == true
        await self.app.updateAgentPowers { cfg in
            if locked {
                if !cfg.lockedSkills.contains(name) { cfg.lockedSkills.append(name) }
            } else {
                cfg.lockedSkills.removeAll { $0 == name }
            }
        }
        return await self.app.refreshFragments()
    }

    @Wired("ap-profilefile-locks", events: [.change])
    func handleApProfileFileLocks(_ event: EventData) async -> [FragmentUpdate] {
        let tid = event.string("targetId") ?? event.string("value") ?? ""
        guard tid.hasPrefix("ap-profilefile-lock-") else { return [] }
        let key = String(tid.dropFirst("ap-profilefile-lock-".count))
        guard ["memory", "user", "soul", "agents"].contains(key) else { return [] }
        let locked = event.checked == true
        await self.app.updateAgentPowers { cfg in
            if locked {
                if !cfg.lockedProfileFiles.contains(key) { cfg.lockedProfileFiles.append(key) }
            } else {
                cfg.lockedProfileFiles.removeAll { $0 == key }
            }
        }
        return await self.app.refreshFragments()
    }

    @Wired("al-max-turns", events: [.change])
    func handleAlMaxTurns(_ event: EventData) async -> [FragmentUpdate] {
        guard let v = Int(event.string("value") ?? ""), v > 0 else { return [] }
        await self.app.setToolIterationLimit(v)
        _ = await self.app.hint("Tool iteration limit set to \(v) (agent.max_turns).", kind: "success")
        return await self.app.refreshFragments()
    }

    @Wired("al-max-turns-unlimited", events: [.change])
    func handleAlMaxTurnsUnlimited(_ event: EventData) async -> [FragmentUpdate] {
        let on = event.checked == true
        await self.app.setToolIterationLimit(on ? -1 : 90)
        _ = await self.app.hint(
            on ? "Tool iteration limit disabled — turns run until the prompt finishes." : "Tool iteration limit restored to 90.",
            kind: "success")
        return await self.app.refreshFragments()
    }

    @Wired("al-tool-cap", events: [.change])
    func handleAlToolCap(_ event: EventData) async -> [FragmentUpdate] {
        guard let v = Int(event.string("value") ?? ""), v > 0 else { return [] }
        await self.app.setToolLoopCap(v)
        _ = await self.app.hint("Per-tool call cap set to \(v) (guardrails.toolLoopCap).", kind: "success")
        return await self.app.refreshFragments()
    }

    @Wired("al-tool-cap-unlimited", events: [.change])
    func handleAlToolCapUnlimited(_ event: EventData) async -> [FragmentUpdate] {
        let on = event.checked == true
        await self.app.setToolLoopCap(on ? -1 : 25)
        _ = await self.app.hint(
            on ? "Per-tool call cap disabled." : "Per-tool call cap restored to 25.",
            kind: "success")
        return await self.app.refreshFragments()
    }

    @Wired("modelcfg-add-form", events: [.submit])
    func handleModelCfgAddForm(_ event: EventData) async -> [FragmentUpdate] {
        let name = (event.string("mc-name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (event.string("mc-model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = (event.string("mc-provider") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (event.string("mc-baseurl") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = event.string("mc-apikey") ?? ""
        let ctx = Int((event.string("mc-ctx") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let maxtok = Int((event.string("mc-maxtok") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return await self.addModelConfig(name: name, model: model, provider: provider, baseURL: base, apiKey: key, contextLength: ctx, maxOutputTokens: maxtok)
    }

    @Wired("modelcfg-list", events: [.click])
    func handleModelCfgList(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        return await self.modelConfigAction(tid)
    }

    @Wired("kanban", events: [.click, .submit])
    func handleKanban(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            // The inline form always carries all four fields; branch on
            // which one is actually populated (empty strings are ignored).
            if let cid = event.string("kb-col-id"), !cid.isEmpty,
               let name = event.string("kb-col-name"), !name.isEmpty {
                await self.app.renameKanbanColumn(cid, to: name)
            } else if let cardid = event.string("kb-card-id"), !cardid.isEmpty,
                      let title = event.string("kb-card-title"), !title.isEmpty {
                await self.app.renameKanbanCard(cardid, to: title)
            } else {
                return []
            }
            return await self.app.refreshFragments()
        }
        guard let tid = event.string("targetId") else { return [] }
        return await self.kanbanAction(tid)
    }

    @Wired("kb-addcol", events: [.click])
    func handleKbAddCol(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setAddingColumn(!self.app.addingColumn)
        return await self.app.refreshFragments()
    }

    @Wired("kb-addcol-form", events: [.submit, .click])
    func handleKbAddColForm(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            let name = event.string("kb-addcol-name") ?? ""
            let color = event.string("kb-addcol-color") ?? ""
            await self.app.addKanbanColumn(name: name, color: color)
            await self.app.setAddingColumn(false)
        } else if event.string("targetId") != "kb-addcol-cancel" {
            return []
        } else {
            await self.app.setAddingColumn(false)
        }
        return await self.app.refreshFragments()
    }

    @Wired("kb-addcard-form", events: [.submit, .click])
    func handleKbAddCardForm(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            let title = event.string("kb-addcard-name") ?? ""
            let col = event.string("kb-addcard-col") ?? ""
            await self.app.addKanbanCard(title, in: col)
        } else if event.string("targetId") != "kb-addcard-cancel" {
            return []
        } else {
            await self.app.setAddingCard(nil)
        }
        return await self.app.refreshFragments()
    }

    @Wired("memory", events: [.click])
    func handleMemory(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        if tid.hasPrefix("mem-open-") {
            await self.app.openMemoryDoc(String(tid.dropFirst("mem-open-".count)))
        } else if tid == "mem-edit" {
            await self.app.startMemoryEdit()
        } else {
            return []
        }
        return await self.app.refreshFragments()
    }

    @Wired("mem-edit", events: [.click])
    func handleMemEdit(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.startMemoryEdit()
        return await self.app.refreshFragments()
    }

    @Wired("mem-save-form", events: [.submit, .click])
    func handleMemSaveForm(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            let key = event.string("mem-key") ?? "memory"
            let content = event.string("mem-content") ?? ""
            await self.app.saveMemoryDoc(key, content: content)
        } else if event.string("targetId") == "mem-cancel" {
            await self.app.cancelMemoryEdit()
        } else {
            return []
        }
        return await self.app.refreshFragments()
    }

    @Wired("workspace", events: [.click])
    func handleWorkspace(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }
        return await self.workspaceAction(tid)
    }

    @Wired("workspace-upload", events: [.submit])
    func handleWorkspaceUpload(_ event: EventData) async -> [FragmentUpdate] {
        let name = event.string("upl-name") ?? ""
        let path = event.string("upl-path") ?? ""
        let b64 = event.string("upl-b64") ?? ""
        guard !path.isEmpty, !b64.isEmpty else { return [] }
        await self.app.uploadWorkspaceFile(name: name, relPath: path, b64: b64)
        return await self.workspaceFragments()
    }

    @Wired("ws-new-form", events: [.submit, .click])
    func handleWsNewForm(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            let name = event.string("ws-new-name") ?? ""
            let kind = event.string("ws-new-kind") ?? "file"
            await self.app.createWorkspaceEntry(name: name, kind: kind)
        } else if event.string("targetId") == "ws-new-cancel" {
            await self.app.setWsNewMode("")
        } else {
            return []
        }
        return await self.workspaceFragments()
    }

    @Wired("mc-name", events: [.input])
    func handleMcName(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mc-name", event.string("value") ?? "")
        return []
    }

    @Wired("mc-model", events: [.input])
    func handleMcModel(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mc-model", event.string("value") ?? "")
        return []
    }

    @Wired("mc-provider", events: [.input])
    func handleMcProvider(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mc-provider", event.string("value") ?? "")
        return []
    }

    @Wired("mc-baseurl", events: [.input])
    func handleMcBaseUrl(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mc-baseurl", event.string("value") ?? "")
        return []
    }

    @Wired("mc-apikey", events: [.input])
    func handleMcApiKey(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mc-apikey", event.string("value") ?? "")
        return []
    }

    @Wired("mc-ctx", events: [.input])
    func handleMcCtx(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mc-ctx", event.string("value") ?? "")
        return []
    }

    @Wired("mc-maxtok", events: [.input])
    func handleMcMaxTok(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.storeFormValue("mc-maxtok", event.string("value") ?? "")
        return []
    }
}

extension Controller {

    private func wireSettings(_ router: EventRouter) {
        wireGroup_settings(router)
        wireGroup_settings_admin(router)
    }

    /// Kanban chip/row/board actions.
    private func kanbanAction(_ tid: String) async -> [FragmentUpdate] {
        if tid == "kb-addcol" {
            await app.setAddingColumn(!app.addingColumn)
        } else if tid.hasPrefix("kb-pdel-"), let id = dec(String(tid.dropFirst("kb-pdel-".count))) {
            await self.confirmDeleteKanban(id)
        } else if tid.hasPrefix("kb-bdel-"), let id = dec(String(tid.dropFirst("kb-bdel-".count))) {
            await self.confirmDeleteKanban(id)
        } else if tid.hasPrefix("kb-rencol-") || tid.hasPrefix("kb-edit-") {
            return []   // client-side inline rename / title edit; commit via hidden form submit
        } else if tid.hasPrefix("kb-movel-"), let id = dec(String(tid.dropFirst("kb-movel-".count))) {
            await app.moveKanbanCard(id, by: -1)
        } else if tid.hasPrefix("kb-mover-"), let id = dec(String(tid.dropFirst("kb-mover-".count))) {
            await app.moveKanbanCard(id, by: 1)
        } else if tid.hasPrefix("kb-del-"), let id = dec(String(tid.dropFirst("kb-del-".count))) {
            // Two-step, like the column header: the first click arms the card.
            if await app.confirmCard == id {
                await app.setConfirmCard(nil)
                await app.deleteKanbanCard(id)
            } else {
                await app.setConfirmCard(id)
            }
        } else if tid.hasPrefix("kb-addcard-"), let id = dec(String(tid.dropFirst("kb-addcard-".count))) {
            await app.setAddingCard(id)
        } else {
            return []
        }
        return await app.refreshFragments()
    }

    private func confirmDeleteKanban(_ id: String) async {
        let armed = await app.confirmColumn == id
        if armed {
            await app.deleteKanbanColumn(id)
        } else {
            await app.setConfirmColumn(id)
        }
    }

    /// Right-hand workspace panel actions (dock toggle, create, hidden files,
    /// folder expand/collapse). Uploads + the "⋮" menu are client-side.
    private func workspaceAction(_ tid: String) async -> [FragmentUpdate] {
        if tid == "w-dock" {
            await app.toggleWorkspace()
        } else if tid == "w-close" {
            await app.closeWorkspace()
        } else if tid == "w-new" {
            await app.setWsNewMode("file")
        } else if tid == "w-newfolder" {
            await app.setWsNewMode("folder")
        } else if tid == "w-menu" || tid == "w-upload" {
            return []   // client-side: menu toggle / file picker
        } else if tid == "w-hidden" {
            await app.toggleShowHiddenFiles()
        } else if tid.hasPrefix("w-toggle-"), let path = dec(String(tid.dropFirst("w-toggle-".count))) {
            await app.togglePath(path)
        } else if tid.hasPrefix("w-file-"), let path = dec(String(tid.dropFirst("w-file-".count))) {
            await app.openWorkspaceFile(path)
        } else if tid == "w-preview-back" {
            await app.closeWorkspacePreview()
        } else {
            return []
        }
        return await self.workspaceFragments()
    }

    private func workspaceFragments() async -> [FragmentUpdate] {
        let toasts = await app.toastsShell()
        return [
            fragment("ws-dock", await app.workspaceDockHTML()),
            fragment("ws-panel", await app.workspacePanelHTML()),
            FragmentUpdate(id: "toasts", html: toasts.markup.html),
        ]
    }

    private func addModelConfig(name: String, model: String, provider: String, baseURL: String, apiKey: String, contextLength ctx: Int?, maxOutputTokens maxtok: Int? = nil) async -> [FragmentUpdate] {
        guard !name.isEmpty, !model.isEmpty, !baseURL.isEmpty else {
            _ = await app.hint("Name, model and base URL are required.", kind: "error")
            return await self.app.refreshFragments()
        }
        guard URL(string: baseURL) != nil else {
            _ = await app.hint("Base URL is not a valid URL.", kind: "error")
            return await self.app.refreshFragments()
        }
        let preset = ModelConfigPreset(name: name, model: model, provider: provider.isEmpty ? "custom" : provider, baseURL: baseURL, apiKey: apiKey, contextLength: ctx, maxOutputTokens: maxtok, source: "ui")
        await app.addModelConfig(preset)
        _ = await app.hint("Configuration '\(name)' added.")
        return await self.app.refreshFragments()
    }

    private func modelConfigAction(_ tid: String) async -> [FragmentUpdate] {
        if tid.hasPrefix("mc-del-") {
            if let name = dec(String(tid.dropFirst("mc-del-".count))) {
                await self.app.removeModelConfig(name)
                _ = await self.app.hint("Removed configuration '\(name)'.")
            }
        }
        return await self.app.refreshFragments()
    }

    // MARK: Toasts

    private func wireToasts(_ router: EventRouter) {
        wireGroup_toasts(router)
    }
}
