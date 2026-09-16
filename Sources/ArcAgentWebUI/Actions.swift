import ArcAgentCore
import Foundation
import NIOCore
import NIOWebSocket
import WebUI

// MARK: - Per-connection identity

enum TaskEnv {
    @TaskLocal static var clientID: Int?
}

// MARK: - Client hub

/// Serializes outbound WebSocket writes per connection. Concurrent pushes from
/// a streaming turn plus UI handlers must never interleave two frame writes.
actor ClientHub {
    private struct Client {
        let writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    }
    private var clients: [Int: Client] = [:]
    private var seq = 0

    func nextID() -> Int {
        seq += 1
        return seq
    }

    func register(_ id: Int, _ writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>) {
        clients[id] = Client(writer: writer)
    }

    func unregister(_ id: Int) {
        clients.removeValue(forKey: id)
    }

    func push(clientID: Int, updates: [FragmentUpdate]) async {
        guard let client = clients[clientID], !updates.isEmpty else { return }
        let out = WSOutgoing.update(fragments: updates)
        guard let data = try? JSONEncoder().encode(out) else { return }
        var buf = ByteBuffer()
        buf.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        try? await client.writer.write(frame)
    }

    /// Push the same updates to every connected client (used by the live log
    /// stream, which is shared across the single server-side app state).
    func broadcast(_ updates: [FragmentUpdate]) async {
        guard !clients.isEmpty, !updates.isEmpty else { return }
        let out = WSOutgoing.update(fragments: updates)
        guard let data = try? JSONEncoder().encode(out) else { return }
        var buf = ByteBuffer()
        buf.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        for client in clients.values {
            try? await client.writer.write(frame)
        }
    }
}

// MARK: - AppState extensions (turn engine)

extension AppState {

    /// Render fragments for the panels/main/toasts after a state change.
    func refreshFragments(includeApp: Bool = false) async -> [FragmentUpdate] {
        if includeApp {
            let shell = appShell()
            let toasts = toastsShell()
            return [
                FragmentUpdate(id: "app", html: shell),
                FragmentUpdate(id: "toasts", html: toasts),
            ]
        }
        var u: [FragmentUpdate] = [
            FragmentUpdate(id: "topbar", html: topbarHTML()),
            FragmentUpdate(id: "panel", html: panelHTML()),
            FragmentUpdate(id: "main", html: mainContentHTML()),
        ]
        // The right-hand workspace panel follows the active chat's workspace,
        // so re-render it on session switches and workspace changes too.
        u.append(FragmentUpdate(id: "ws-dock", html: workspaceDockHTML()))
        u.append(FragmentUpdate(id: "ws-panel", html: workspacePanelHTML()))
        let toastsDiv = "<div id=\"toasts\">\(toastsHTML())</div>"
        u.append(FragmentUpdate(id: "toasts", html: toastsDiv))
        let modalDiv = "<div id=\"modal-root\">\(modalRootHTML())</div>"
        u.append(FragmentUpdate(id: "modal-root", html: modalDiv))
        return u
    }

    /// Iterated when the Logs view or its controls change: re-render the left
    /// panel (stats + filter chips) and the live log box.
    /// Standard refresh plus the left iconbar (rail). Needed whenever sidebar
    /// tab visibility or order changes — refreshFragments alone leaves the
    /// rail untouched.
    func fragmentsWithIconbar() async -> [FragmentUpdate] {
        var u = await refreshFragments()
        u.append(FragmentUpdate(id: "iconbar", html: "<aside id=\"iconbar\">\(iconbarHTML())</aside>"))
        return u
    }

    func logsFragments() async -> [FragmentUpdate] {
        [
            FragmentUpdate(id: "topbar", html: topbarHTML()),
            FragmentUpdate(id: "panel", html: panelHTML()),
            FragmentUpdate(id: "log-lines", html: "<div id=\"log-lines\" class=\"logs-lines\">\(logLinesHTML())</div>"),
        ]
    }

    /// Build the system prompt for a chat, mirroring ArcAgent's construction:
    /// identity, optional profile SOUL, skills index, persistent memory.
    func buildSystemPrompt(config preset: ModelConfigPreset, sessionID: String?) async -> String {
        var parts = [
            "You are ARC, a Swift-native AI agent harness.",
            "You assist the user directly and precisely. When a task calls for a tool, use it confidently — tools are safe, isolated, and expected.",
        ]
        // Profile SOUL
        if let pname = profileName(for: sessionID),
           let p = profiles.first(where: { $0.name == pname }),
           let soul = p.soulMD, !soul.isEmpty {
            parts.append("[Profile: \(pname)]\n\(soul)")
        }
        parts.append("Active configuration: model \(preset.model) via \(preset.provider.isEmpty ? "custom" : preset.provider).")
        parts.append("Working directory: \(workspacePath(for: sessionID))")
        // Skills — per-profile override when the chat is bound to a profile,
        // otherwise the global list (inherited by profiles without overrides).
        let pname = profileName(for: sessionID)
        let disabledSkills = pname.flatMap { settings.profileSkills[$0] } ?? settings.disabledSkills
        var allowed: [Skill] = skills.filter { !disabledSkills.contains($0.name) }
        if !allowed.isEmpty {
            parts.append("Available skills:\n" + buildSkillsIndex(allowed))
        }
        // Memory
        if let mem = memory {
            if let m = try? await mem.readMemory(), !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("Persistent notes (internal memory):\n\(m)")
            }
            if let u = try? await mem.readUser(), !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("About the user:\n\(u)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Execute one tool call and return its result string. Terminal commands
    /// are gated by ApprovalManager (Hermes smart approval): dangerous ones
    /// pause on a permission card until the user approves or denies.
    func runTool(_ call: ToolCall, sessionID: String, pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void, headless: Bool = false) async -> String {
        guard let tool = registry.lookup(name: call.function.name) else {
            return "Error: tool '\(call.function.name)' is not registered."
        }
        var args: [String: Any] = [:]
        if let data = call.function.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = obj
        }
        // Tool guardrails (Hermes tool_guardrails parity): per-turn budgets,
        // repeated-call detection, and synthetic results.
        switch await Self.guardrails.decide(toolName: call.function.name, args: args) {
        case .synthetic(let message):
            return message
        case .allow:
            break
        }
        // Hermes-parity approval gate for the terminal tool.
        if tool.name == "terminal",
           let command = args["command"] as? String,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let manager = approvalManager,
           await manager.needsApproval(command: command, sessionKey: sessionID, yolo: isYolo(sessionID)) {
            let decision: ApprovalResult
            if headless {
                // Scheduled jobs run autonomously: the smart classifier alone
                // decides. Critical commands are blocked below (denied); the
                // rest are allowed — every run is logged to the job session.
                decision = await manager.requestApproval(
                    command: command,
                    description: "Scheduled: `\(trunc(command, 100))`",
                    sessionKey: sessionID
                )
                if case .denied = decision {
                    LogCollector.shared.append(level: .warning, text: "[cron] blocked critical command: \(trunc(command, 120))")
                    return "Error: command blocked by approval policy (classified critical; scheduled jobs cannot run destructive commands)."
                }
                return (try? await tool.handler(args)) ?? "Error: tool execution failed"
            }
            decision = await manager.requestApproval(
                command: command,
                description: "Run `\(trunc(command, 100))`",
                sessionKey: sessionID
            )
            switch decision {
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
        // Hermes-parity clarify tool: the webui intercepts the tool call and
        // renders the "Clarification needed" card above the composer. The
        // answer (or the 120 s best-judgement fallback) becomes the tool result.
        if tool.name == "clarify" {
            return await requestUserClarification(call: call, sessionID: sessionID, pusher: pusher)
        }
        do {
            let result = try await tool.handler(args)
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

    /// Hermes-parity clarify request: the agent's `clarify` tool pauses the
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
        // best-judgement notice (Hermes smart-mode fallback).
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

    /// Clarify timeout in seconds (Hermes default: 120). Overridable via the
    /// `ARC_CLARIFY_TIMEOUT` environment variable for tests.
    static func clarifyTimeoutSeconds() -> Double {
        if let raw = ProcessInfo.processInfo.environment["ARC_CLARIFY_TIMEOUT"],
           let v = Double(raw), v > 0 {
            return v
        }
        return 120
    }

    // MARK: Context compression (Hermes parity)

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

    /// Hermes-parity context compression. When the token estimate exceeds the
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
        let recent = Array(nonSystem.suffix(minRecent))
        let compressible = Array(nonSystem.prefix(nonSystem.count - minRecent))
        guard !compressible.isEmpty else { return (msgs, false) }

        let record = extractiveRecord(compressible)
        var summary = record
        if arcConfig.auxiliary.override(for: .compression)?.isSet == true,
           let hc = httpClient,
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

    /// Run a full agent turn (streaming) for the active chat and push updates
    /// to the originating client throughout.
    // MARK: - Core-service integrations (Hermes parity)

    private static let rateLimits = RateLimitTracker()
    private static let guardrails = ToolGuardrails()
    private static let usageLedger = UsageLedger()

    /// Bounded empty-response nudge (mirrors the core's recovery budget).
    static let emptyResponseNudge =
        "The previous turn ended without any response content. Using the tool results above, provide your answer now."

    /// Record a finished round in the durable usage ledger (~/.arc-agent/usage.json),
    /// the same file the CLI and gateway write (Hermes usage_pricing parity).
    static func recordUsage(_ usage: Usage, preset: ModelConfigPreset) async {
        await usageLedger.record(
            route: BillingRoute(provider: preset.provider, model: preset.model, baseURL: preset.baseURL),
            usage: CanonicalUsage(
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                cacheReadTokens: usage.cachedPromptTokens ?? 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                requestCount: 1
            )
        )
        await usageLedger.save()
    }

    /// Mixture-of-Agents advisory pass (Hermes moa_loop parity): run the
    /// reference fan-out and prepend the joined advisory to the context.
    private func appendMoAAdvisory(to messages: inout [Message], preset: ModelConfigPreset, userText: String) async {
        var cfg = arcConfig.moa
        cfg.enabled = true
        let service = MoAService(config: cfg, aggregatorModelName: preset.model) { [weak self] _, _ in
            guard let self else { return nil }
            return await self.makeClient(for: preset)
        }
        let userPrompt = userText
        let wire = messages.map { ["role": $0.role.rawValue, "content": $0.content ?? ""] }
        let result = await service.aggregate(userPrompt: userPrompt, apiMessages: wire)
        guard !result.advisoryBlock.isEmpty else { return }
        messages.insert(
            Message(role: .system, content: "Advisory context from reference models (Mixture of Agents):\n\(result.advisoryBlock)"),
            at: 1
        )
    }

    // MARK: - Tool-iteration budget (Hermes `max_turns` parity)

    /// Hermes `AIAgent` default tool-calling iterations (agent_init.py:470).
    static let defaultMaxTurns = 90

    /// The tool-iteration budget for a turn, read per-turn from
    /// `~/.arc/config.json` so edits apply without a restart (Hermes reads the
    /// config per request too). Key precedence matches Hermes
    /// (`api/streaming.py`): `agent.max_turns` → legacy root `max_turns` →
    /// `agent.maxIterations` (arc-agent's own key) → default 90.
    static func effectiveMaxTurns() -> Int {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return defaultMaxTurns
        }
        let agent = root["agent"] as? [String: Any]
        let raw = agent?["max_turns"] ?? root["max_turns"] ?? agent?["maxIterations"]
        if let n = raw as? Int, n > 0 { return n }
        if let s = raw as? String, let n = Int(s), n > 0 { return n }
        return defaultMaxTurns
    }

    /// Hermes parity: when the tool-iteration budget is exhausted, append the
    /// same nudge Hermes uses (`chat_completion_helpers.py`), take ONE final
    /// no-tools call for the closing summary, and mark the reply with
    /// `terminalReason = "max_iterations"` so the UI shows the status card.
    private func handleIterationLimit(
        history: inout [Message],
        sessionID: String,
        preset: ModelConfigPreset,
        store: (any SessionStore)?,
        effort: String?,
        throttle: @escaping () async -> Void,
        flush: @escaping () async -> Void
    ) async {
        let nudge = Message(
            role: .user,
            content: "You've reached the maximum number of tool-calling iterations allowed. "
                + "Please provide a final response summarizing what you've found and accomplished so far, "
                + "without calling any more tools.",
            createdAt: Date()
        )
        history.append(nudge)
        if let store { try? await store.appendMessage(sessionID: sessionID, message: nudge) }
        await flush()

        // One final no-tool call: the model cannot emit tool calls, so the
        // result is either a summary or empty → graceful fallback (Hermes
        // `final_response` fallback text).
        var summary = ""
        var reasoning = ""
        var usage: Usage?
        guard let client = makeClient(for: preset) else {
            // No client for the configured model: fall back to graceful text.
            let f = Message(role: .assistant, content: "I reached the iteration limit and couldn't generate a summary.", createdAt: Date(), terminalReason: "max_iterations")
            history.append(f)
            if let store { try? await store.appendMessage(sessionID: sessionID, message: f) }
            await flush()
            return
        }
        var msgs = [Message(role: .system, content: await buildSystemPrompt(config: preset, sessionID: sessionID))]
        msgs.append(contentsOf: history)
        let started = Date()
        do {
            let stream = client.stream(messages: msgs, tools: [], reasoningEffort: effort)
            for try await delta in stream {
                if activeTurns[sessionID]?.stopped == true { break }
                if let c = delta.content { summary += c; activeTurns[sessionID]?.assistantText = summary }
                if let r = delta.reasoning { reasoning += r; activeTurns[sessionID]?.thinking = reasoning }
                if let u = delta.usage { usage = u }
                await throttle()
            }
        } catch {
            // Provider fault during the final call: no retry (Hermes returns
            // the graceful fallback in this case); keep any partial text.
        }
        let elapsed = max(0.2, Date().timeIntervalSince(started))
        let tps: Double? = usage.flatMap { u in u.completionTokens > 0 ? Double(u.completionTokens) / elapsed : nil }
        let finalText = summary.isEmpty
            ? "I reached the iteration limit and couldn't generate a summary."
            : summary
        let final = Message(
            role: .assistant,
            content: finalText,
            createdAt: Date(),
            reasoning: reasoning.isEmpty ? nil : reasoning,
            usage: usage,
            tps: tps,
            terminalReason: "max_iterations"
        )
        history.append(final)
        if let store { try? await store.appendMessage(sessionID: sessionID, message: final) }
        if let u = usage { await Self.recordUsage(u, preset: preset) }
        await flush()
    }

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
            // Hermes parity: image attachments are described by the active
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
        guard let client = makeClient(for: effectivePreset) else {
            _ = toast("No usable model configuration '\(configName)'. Add one in Settings → Preferences.", kind: "error")
            _ = await refreshFragments()
            return
        }

        // Begin the turn.
        let turn = LiveTurn(sessionID: sessionID, userText: raw, attachments: atts)
        activeTurns[sessionID] = turn
        pendingDelete = false
        attachments = []
        storeComposerDraft("", sessionID: sessionID)

        let userMsg = Message(role: .user, content: userContent, createdAt: Date(), displayText: displayText)
        session.messages.append(userMsg)
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx] = session
        }
        sessionVersion += 1
        if let store {
            try? await store.appendMessage(sessionID: sessionID, message: userMsg)
        }

        // Hermes-parity: when a title_gen auxiliary model is assigned, name the
        // chat with it (best-effort + fire-and-forget so streaming is never
        // delayed; without an assignment the first-message auto title stays).
        if settings.sessionTitles[sessionID] == nil,
           arcConfig.auxiliary.override(for: .titleGeneration)?.isSet == true {
            Task { await self.maybeGenerateTitle(sessionID: sessionID, pusher: pusher) }
        }

        // Full chat render at turn start: the composer flips to the red stop
        // button and the running chat's row swaps ⋮ for a spinner.
        await pusher(await chatFragments())

        // Streaming loop with ~90 ms push coalescing. Only push live
        // fragments while the user is viewing the chat that owns the turn —
        // otherwise the active chat's scroll container is needlessly replaced
        // every ~90 ms and its scroll position fights the user.
        var lastPush = Date.distantPast
        let throttle: () async -> Void = { [weak self] in
            guard let self else { return }
            let now = Date()
            if now.timeIntervalSince(lastPush) > 0.09, await self.activeSessionID == sessionID {
                lastPush = now
                await pusher(await self.liveFragments())
            }
        }
        func flush() async {
            lastPush = .distantPast
            await throttle()
        }

        var history = session.messages
        // Hermes-parity context compression: when the estimate exceeds the
        // budget, the `compression` auxiliary model (Qwen3.6) summarizes the
        // older tail and a recent window replaces it for the model-facing
        // request. The stored transcript stays intact. Applies at most once
        // per session (durable summary).
        let (compressed, didCompress) = await compressHistoryIfNeeded(history, sessionID: sessionID)
        if didCompress {
            history = compressed
            _ = hint("Conversation history compressed (est. \(estimateTokens(history)) tokens now).")
        }
        var assistantText = ""
        var reasoningAccum = ""
        let tools = registry.buildToolSchemas(enabled: [], disabled: Set(settings.disabledToolsets))
        var finalError: String?
        var recovery = TurnRecoveryState()
        await Self.guardrails.resetTurn()
        let maxTurns = max(1, Self.effectiveMaxTurns())
        var turnCompleted = false

        turnLoop: for _ in 0..<maxTurns {
            if activeTurns[sessionID]?.stopped == true { break }
            let sys = await buildSystemPrompt(config: preset, sessionID: sessionID)
            var messages = [Message(role: .system, content: sys)]
            messages.append(contentsOf: history)

            // Mixture-of-Agents advisory (Hermes moa_loop parity): when enabled
            // in Settings and reference models are configured in
            // ~/.arc/config.json, fan out reference calls first and prepend the
            // joined advisory to the model-facing context.
            if settings.moaEnabled, !arcConfig.moa.referenceModels.isEmpty {
                await appendMoAAdvisory(to: &messages, preset: preset, userText: turn.userText)
            }

            var contentAccum = ""
            reasoningAccum = ""
            var toolAccum: [Int: (id: String?, name: String?, args: String)] = [:]
            var streamError: String?
            var roundUsage: Usage?
            var roundContentChars = 0
            let roundStart = Date()

            let thinkLevel = thinkingLevel(for: sessionID)
            let effort = pctx?.reasoningEffort ?? (thinkLevel == "off" ? nil : thinkLevel)
            var stream = client.stream(messages: messages, tools: tools, reasoningEffort: effort)
                var roundTokensRecorded = false
                var streamAttempts = 0
                while true {
                    streamAttempts += 1
                    do {
                    for try await delta in stream {
                    if activeTurns[sessionID]?.stopped == true { break }
                    if !roundTokensRecorded, let u = delta.usage {
                        roundTokensRecorded = true
                        recordTokensBurned(u.totalTokens > 0 ? u.totalTokens : u.promptTokens + u.completionTokens)
                    }
                    if let u = delta.usage { roundUsage = u }
                    if let c = delta.content {
                        contentAccum += c
                        assistantText += c
                        roundContentChars += c.count
                    }
                    if let r = delta.reasoning {
                        reasoningAccum += r
                        activeTurns[sessionID]?.thinking = reasoningAccum
                    }
                    if let tcs = delta.toolCalls {
                        for tc in tcs {
                            var entry = toolAccum[tc.index] ?? (nil, nil, "")
                            if let id = tc.id { entry.id = id }
                            if let name = tc.name { entry.name = name }
                            entry.args += tc.arguments ?? ""
                            toolAccum[tc.index] = entry
                        }
                    }
                    activeTurns[sessionID]?.assistantText = assistantText
                    activeTurns[sessionID]?.status = contentAccum.isEmpty && !toolAccum.isEmpty ? "tool" : "running"
                    // Hermes parity: live tokens-per-second estimate while streaming.
                    let roundElapsed = max(0.2, Date().timeIntervalSince(roundStart))
                    activeTurns[sessionID]?.tps = roundContentChars > 0 ? (Double(roundContentChars) / 4.0) / roundElapsed : nil
                    await throttle()
                }
                    break
                } catch {
                    // Provider fault recovery (Hermes parity): retry transient
                    // failures (429/5xx/timeouts/empty) with rate-limit-aware
                    // backoff — but only before any output was emitted, so the
                    // user never sees duplicate text.
                    let canRetry = activeTurns[sessionID]?.stopped != true
                        && contentAccum.isEmpty && toolAccum.isEmpty && reasoningAccum.isEmpty
                        && streamAttempts < 3 && classifyError(error) == .retryable
                    guard canRetry else {
                        streamError = "\(error)"
                        break
                    }
                    if case LLMError.rateLimited(let retryAfter) = error {
                        await Self.rateLimits.recordThrottle(route: "\(preset.provider)/\(preset.model)", retryAfter: retryAfter)
                    }
                    let backoff = await Self.rateLimits.backoffSeconds(route: "\(preset.provider)/\(preset.model)")
                    try? await Task.sleep(nanoseconds: UInt64(max(backoff, 0.75) * 1_000_000_000))
                    stream = client.stream(messages: messages, tools: tools, reasoningEffort: effort)
                }
                if streamError != nil { break }
                }

            let calls: [ToolCall] = toolAccum.sorted { $0.key < $1.key }.compactMap { _, e in
                guard let name = e.name, let id = e.id else { return nil }
                return ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: e.args))
            }

            if let streamError {
                finalError = streamError
                break
            }
            if activeTurns[sessionID]?.stopped == true { break }

            // Empty-round storm guard (Hermes bounded empty responses): a full
            // round that yields nothing is retried with a nudge, at most
            // `TurnRecoveryState.emptyStormThreshold` times.
            if streamError == nil, activeTurns[sessionID]?.stopped != true,
               contentAccum.isEmpty, reasoningAccum.isEmpty, toolAccum.isEmpty {
                recovery.emptyStormStreak += 1
                if recovery.emptyStormStreak < TurnRecoveryState.emptyStormThreshold {
                    history.append(Message(role: .user, content: Self.emptyResponseNudge))
                    _ = hint("Empty response from provider; nudging retry (\(recovery.emptyStormStreak)/\(TurnRecoveryState.emptyStormThreshold)).")
                    continue
                }
            }

            if calls.isEmpty {
                // Final assistant turn.
                // Hermes parity: final TPS = real output tokens / wall-clock
                // duration (matches the round's usage report when available).
                let finalElapsed = max(0.2, Date().timeIntervalSince(roundStart))
                let finalTps: Double? = roundUsage.flatMap { u in
                    u.completionTokens > 0 ? Double(u.completionTokens) / finalElapsed : nil
                }
                let asstMsg = Message(
                    role: .assistant,
                    content: contentAccum,
                    createdAt: Date(),
                    reasoning: reasoningAccum.isEmpty ? nil : reasoningAccum,
                    usage: roundUsage,
                    tps: finalTps
                )
                history.append(asstMsg)
                if let store {
                    try? await store.appendMessage(sessionID: sessionID, message: asstMsg)
                }
                if let u = roundUsage {
                    await Self.recordUsage(u, preset: preset)
                }
                turnCompleted = true
                break turnLoop
            }

            // Tool round.
            let asstMsg = Message(role: .assistant, content: contentAccum.isEmpty ? nil : contentAccum, toolCalls: calls, createdAt: Date(), reasoning: reasoningAccum.isEmpty ? nil : reasoningAccum)
            history.append(asstMsg)
            if let store {
                try? await store.appendMessage(sessionID: sessionID, message: asstMsg)
            }
            activeTurns[sessionID]?.toolChips = calls.map { "⚙ \($0.function.name)" }
            activeTurns[sessionID]?.status = "tool"
            await flush()

            for call in calls {
                if activeTurns[sessionID]?.stopped == true { break }
                let result = await runTool(call, sessionID: sessionID, pusher: pusher, headless: headless)
                let toolMsg = Message(role: .tool, content: result, name: call.function.name, toolCallID: call.id, createdAt: Date())
                history.append(toolMsg)
                if let store {
                    try? await store.appendMessage(sessionID: sessionID, message: toolMsg)
                }
            }
            // Steer injection at the tool-result boundary (Hermes parity):
            // pending user guidance is appended to the last tool result so the
            // model sees it on its next iteration. The stream is not
            // interrupted; steer is a live-run artifact and is not persisted.
            if let steer = activeTurns[sessionID]?.steerText, !steer.isEmpty {
                // Steer only ever arrives from THIS session's composer; the
                // submit path guarantees it (see submitChat).
                activeTurns[sessionID]?.steerText = nil
                if let lastIdx = history.indices.last, history[lastIdx].role == .tool {
                    let last = history[lastIdx]
                    let injected = (last.content ?? "") + "\n\n[User guidance: \(steer)]"
                    history[lastIdx] = Message(role: .tool, content: injected, name: last.name, toolCallID: last.toolCallID, createdAt: last.createdAt)
                }
            }
            activeTurns[sessionID]?.toolChips = []
            activeTurns[sessionID]?.status = "running"
        }

        // Finalize: drop the live bubble, resync from the store, rebuild.
        // Capture any unconsumed steer BEFORE clearing the live turn so it can
        // drain as the next normal turn (Hermes: leftover steer → queue).
        let leftoverSteer = activeTurns[sessionID]?.steerText
        let wasStopped = activeTurns[sessionID]?.stopped == true

        // Hermes parity: when the budget is exhausted cleanly (no error, no
        // user stop, no final answer yet), append the iteration-limit nudge,
        // take one final no-tool call for the summary, and mark it so the UI
        // can render the "Tool iteration limit reached" status card
        // (Hermes `handle_max_iterations` + webui fallback injection).
        if !turnCompleted, finalError == nil, !wasStopped {
            await handleIterationLimit(
                history: &history,
                sessionID: sessionID,
                preset: effectivePreset,
                store: store,
                effort: pctx?.reasoningEffort ?? (thinkingLevel(for: sessionID) == "off" ? nil : thinkingLevel(for: sessionID)),
                throttle: throttle,
                flush: flush
            )
        }

        activeTurns[sessionID] = nil
        if let finalError {
            _ = toast("Turn failed: \(trunc(finalError, 140))", kind: "error")
        }
        await reloadSessions(selecting: selectAfter ? sessionID : nil)
        await pusher(await refreshFragments())
        if let leftover = leftoverSteer, !leftover.isEmpty, !wasStopped {
            Task { await self.runTurn(userText: leftover, pusher: pusher, sessionID: sessionID) }
        }
    }

    /// Called by the red stop button: the in-flight turn ends as soon as the
    /// streaming / tool loops next poll the flag. Scoped to the owning session
    /// so stopping one chat never affects another's running turn.
    func requestStopTurn(sessionID: String) {
        activeTurns[sessionID]?.stopped = true
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

    /// Live-region fragments: only the chat-scroll (and nothing else), so the
    /// composer keeps focus and the panel keeps scrolling undisturbed.
    /// MUST mirror chatMain()'s structure (chat-scroll > chat-inner > messages)
    /// so the centered column, gutters and scrollbar-gutter survive streaming.
    func liveFragments() async -> [FragmentUpdate] {
        let session = activeSession()
        let scroll = messagesHTML(session?.messages ?? [])
        return [
            FragmentUpdate(id: "chat-scroll", html: "<div class=\"chat-scroll\" id=\"chat-scroll\" data-scroll-key=\"chat\"><div class=\"chat-inner\">\(scroll)</div></div>"),
            FragmentUpdate(id: "composer-flyout", html: "<div id=\"composer-flyout\">" + composerFlyoutHTML() + "</div>"),
        ]
    }

    /// Reload sessions from the store, optionally selecting one.
    func reloadSessions(selecting wanted: String? = nil) async {
        if let store {
            sessions = (try? await store.list(limit: 500)) ?? []
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
            activeSessionID = nil
        }
        if let keep = activeSessionID {
            await ensureSessionMessages(keep)
        }
    }
}

// MARK: - Controller (event wiring)

final class Controller {

    let app: AppState
    let hub: ClientHub

    init(app: AppState, hub: ClientHub) {
        self.app = app
        self.hub = hub
    }

    // Register a fixed-id component with event-type filtering (see the
    // hover-equals-click advisory: handlers must not fire on mouseover etc.).
    func wire(
        _ router: EventRouter,
        id: String,
        events: Set<String> = ["click", "change", "submit", "input"],
        _ handler: @escaping (EventData) async -> [FragmentUpdate]
    ) {
        router.register({ event in
            guard events.contains(event.event) else { return [] }
            return await handler(event)
        }, for: ComponentID(id))
    }

    /// A pusher bound to the originating client of the current event.
    func pusher(forClientID cid: Int) -> @Sendable ([FragmentUpdate]) async -> Void {
        { [hub] updates in
            await hub.push(clientID: cid, updates: updates)
        }
    }

    func wireAll(_ router: EventRouter) {
        wireNav(router)
        wireChat(router)
        wireChatMenu(router)
        wireSkills(router)
        wireProfiles(router)
        wireTools(router)
        wireWorkspaces(router)
        wireSettings(router)
        wirePlugins(router)
        wireToasts(router)
        wireLogs(router)
        wireInsights(router)
        wireTodos(router)
        wireQueue(router)
        wireCron(router)
        wireRegen(router)
    }

    // MARK: Nav

    private func wireNav(_ router: EventRouter) {
        for v in ViewID.allCases {
            wire(router, id: "nav-\(v.rawValue)", events: ["click"]) { _ in
                await self.app.switchView(v)
                return await self.app.refreshFragments(includeApp: true)
            }
        }
    }

    // MARK: Logs

    private func wireLogs(_ router: EventRouter) {
        // Severity filter chips (log-filter-all | info | warn | error).
        wire(router, id: "log-filter", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("log-filter-") else { return [] }
            let lvl = String(tid.dropFirst("log-filter-".count))
            await self.app.setLogFilter(lvl)
            return await self.app.logsFragments()
        }
        // Clear the in-memory log buffer.
        wire(router, id: "log-clear", events: ["click"]) { _ in
            LogCollector.shared.clear()
            return await self.app.logsFragments()
        }
    }

    // MARK: Insights

    private func wireInsights(_ router: EventRouter) {
        wire(router, id: "ins-range", events: ["change"]) { event in
            let days = Int(event.data["value"] ?? "30") ?? 30
            await self.app.setInsightsRange(days)
            return await self.app.refreshFragments()
        }
    }

    // MARK: Nav

    private func wireChat(_ router: EventRouter) {
        wire(router, id: "chat-new", events: ["click"]) { _ in
            await self.newChat()
            return await self.app.refreshFragments()
        }
        wire(router, id: "sess-list", events: ["click", "change"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            return await self.sessionListAction(tid)
        }
        wire(router, id: "chat-del", events: ["click"]) { _ in
            await self.deleteActiveChat()
            return await self.app.refreshFragments()
        }
        wire(router, id: "composer-input", events: ["input"]) { event in
            let sid = await self.app.activeSessionID ?? ""
            await self.app.storeComposerDraft(event.data["value"] ?? "", sessionID: sid)
            return []
        }
        wire(router, id: "composer-form", events: ["submit"]) { event in
            let text = event.data["composer-input"] ?? ""
            return await self.submitChat(text: text)
        }
        wire(router, id: "selection-context-add", events: ["click"]) { event in
            // "Reply with selection" button: the selected chat text rides in
            // `payload` (dynamic button, Hermes `_addNamedContextBlock`).
            guard let sel = event.data["payload"], !sel.isEmpty else { return [] }
            await self.app.addPendingContext(sel)
            return await self.app.chatFragments()
        }
        wire(router, id: "selection-context-del", events: ["click"]) { event in
            let tid = event.data["targetId"] ?? ""
            await self.app.removePendingContext(tid)
            return await self.app.chatFragments()
        }
        wire(router, id: "stop-turn", events: ["click"]) { _ in
            let sid = await self.app.activeSessionID ?? ""
            await self.app.requestStopTurn(sessionID: sid)
            return await self.app.chatFragments()
        }
        wire(router, id: "approval-once", events: ["click"]) { _ in
            await self.app.resolveApproval(.once)
            return []
        }
        wire(router, id: "approval-session", events: ["click"]) { _ in
            await self.app.resolveApproval(.session)
            return []
        }
        wire(router, id: "approval-always", events: ["click"]) { _ in
            await self.app.resolveApproval(.always)
            return []
        }
        wire(router, id: "approval-deny", events: ["click"]) { _ in
            await self.app.resolveApproval(.deny)
            return []
        }
        wire(router, id: "approval-dismiss", events: ["click"]) { _ in
            // X on the card = treat as deny (prevents a stuck turn).
            await self.app.resolveApproval(.deny)
            return []
        }
        wire(router, id: "approval-yolo", events: ["click"]) { _ in
            // "Skip all this session" (Hermes /api/session/yolo): enable the
            // session bypass and grant the current command.
            let sid = await self.app.activeSessionID ?? ""
            await self.app.setYolo(sid, true)
            await self.app.resolveApproval(.once)
            return await self.app.chatFragments()
        }
        wire(router, id: "yolo-off", events: ["click"]) { _ in
            let sid = await self.app.activeSessionID ?? ""
            await self.app.setYolo(sid, false)
            return await self.app.chatFragments()
        }
        wire(router, id: "clarify-choice", events: ["click"]) { event in
            // Element ids are clarify-choice-0..3; the index maps to the
            // pending request's choices array.
            let tid = event.data["targetId"] ?? ""
            guard tid.hasPrefix("clarify-choice-"),
                  let idx = Int(String(tid.dropFirst("clarify-choice-".count))),
                  let pc = await self.app.pendingClarify,
                  pc.choices.indices.contains(idx) else { return [] }
            await self.app.respondClarify(pc.choices[idx])
            return []
        }
        wire(router, id: "clarify-form", events: ["submit"]) { event in
            let ans = event.data["clarify-input"] ?? ""
            guard !ans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            await self.app.respondClarify(ans)
            return []
        }
        wire(router, id: "cb-file", events: ["click"]) { _ in
            await self.app.toggleFilePop()
            return await self.app.chatFragments()
        }
        wire(router, id: "file-path-input", events: ["input"]) { event in
            await self.app.storeFormValue("file-path-input", event.data["value"] ?? "")
            return []
        }
        wire(router, id: "file-attach", events: ["click"]) { _ in
            let path = await self.app.readFormValue("file-path-input")
            return await self.attachFile(path)
        }
        wire(router, id: "file-recents", events: ["click"]) { event in
            guard let tid = event.data["targetId"], let p = dec(tid.replacingOccurrences(of: "fr-", with: "")) else { return [] }
            return await self.attachFile(p)
        }
        wire(router, id: "att-chips", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("att-del-"),
                  let idx = Int(tid.dropFirst("att-del-".count)) else { return [] }
            await self.app.removeAttachment(idx)
            return await self.app.chatFragments()
        }
        wire(router, id: "cb-bookmark", events: ["click"]) { _ in
            await self.app.toggleBookmarkActive()
            return await self.app.refreshFragments()
        }
        // Composer dropdown panels (Hermes parity): trigger toggles, live
        // search filters, row picks, and footer actions.
        wire(router, id: "dd-dismiss", events: ["click"]) { _ in
            // Fired by the runtime when a click lands outside an open
            // dropdown panel — close all of them.
            await self.app.closeComposerSelectors()
            return await self.app.chatFragments()
        }
        wire(router, id: "cb-ws-toggle", events: ["click"]) { _ in
            await self.app.toggleWSSelect()
            return await self.app.chatFragments()
        }
        wire(router, id: "cb-profile-toggle", events: ["click"]) { _ in
            await self.app.toggleProfileSelect()
            return await self.app.chatFragments()
        }
        wire(router, id: "cb-model-toggle", events: ["click"]) { _ in
            await self.app.toggleModelSelect()
            return await self.app.chatFragments()
        }
        wire(router, id: "cb-think-toggle", events: ["click"]) { _ in
            await self.app.toggleThinkSelect()
            return await self.app.chatFragments()
        }
        wire(router, id: "ws-search-input", events: ["input"]) { event in
            await self.app.setWSSelectQuery(event.data["value"] ?? "")
            return await self.app.chatFragments()
        }
        wire(router, id: "ws-search-clear", events: ["click"]) { _ in
            await self.app.setWSSelectQuery("")
            return await self.app.chatFragments()
        }
        wire(router, id: "model-search-input", events: ["input"]) { event in
            await self.app.setModelSelectQuery(event.data["value"] ?? "")
            return await self.app.chatFragments()
        }
        wire(router, id: "model-search-clear", events: ["click"]) { _ in
            await self.app.setModelSelectQuery("")
            return await self.app.chatFragments()
        }
        wire(router, id: "ws-pick", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("ws-pick-"),
                  let name = dec(String(tid.dropFirst("ws-pick-".count))) else { return [] }
            await self.app.closeComposerSelectors()
            await self.app.setChatWorkspace(name)
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "profile-pick", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("pp-"),
                  let name = dec(String(tid.dropFirst("pp-".count))) else { return [] }
            await self.app.closeComposerSelectors()
            await self.app.setChatProfile(name)
            return await self.app.chatFragments()
        }
        wire(router, id: "model-pick", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("mc-"),
                  let name = dec(String(tid.dropFirst("mc-".count))) else { return [] }
            await self.app.closeComposerSelectors()
            await self.app.setChatConfig(name)
            return await self.app.chatFragments()
        }
        wire(router, id: "think-pick", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("tp-") else { return [] }
            await self.app.closeComposerSelectors()
            await self.app.setChatThinking(String(tid.dropFirst("tp-".count)))
            return await self.app.chatFragments()
        }
        wire(router, id: "ws-choose-path", events: ["click"]) { _ in
            await self.app.closeComposerSelectors()
            await self.app.setCreateWorkspace(true)
            await self.app.switchView(.workspaces)
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "ws-manage", events: ["click"]) { _ in
            await self.app.closeComposerSelectors()
            await self.app.switchView(.workspaces)
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "pp-manage", events: ["click"]) { _ in
            await self.app.closeComposerSelectors()
            await self.app.switchView(.profiles)
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "chat-search-input", events: ["input"]) { event in
            await self.app.setChatFilter(event.data["value"] ?? "")
            return await self.app.skillPanelFragment()
        }
        wire(router, id: "cat-pick", events: ["click", "contextmenu"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            if event.event == "contextmenu" {
                // Right-click on a category chip opens its edit menu.
                guard tid.hasPrefix("cat-"),
                      let id = dec(String(tid.dropFirst("cat-".count))),
                      await self.app.categoryExists(id)
                else { return [] }
                let x = Int(event.data["mouseX"] ?? "") ?? 0
                let y = Int(event.data["mouseY"] ?? "") ?? 0
                await self.app.openCategoryMenu(id: id, x: x, y: y)
                return await self.app.refreshFragments()
            }
            return await self.categoryAction(tid)
        }
        wire(router, id: "cat-menu", events: ["click", "submit"]) { event in
            let tid = event.data["targetId"] ?? ""
            if event.event == "submit" {
                guard let cid = await self.app.menuCategoryID(),
                      let name = event.data["cat-rename-input"] else { return [] }
                await self.app.renameCategory(cid, to: name)
                await self.app.closeCategoryMenu()
                return await self.app.refreshFragments()
            }
            if tid == "cat-menu-close" {
                await self.app.closeCategoryMenu()
                return await self.app.refreshFragments()
            }
            if tid.hasPrefix("cm-rename-") {
                await self.app.setCategoryMenuRename(true)
                return await self.app.refreshFragments()
            }
            if tid.hasPrefix("cm-color-") {
                guard let color = event.data["color"],
                      let cid = await self.app.menuCategoryID() else { return [] }
                await self.app.setCategoryColor(cid, color: color)
                return await self.app.refreshFragments()
            }
            if tid.hasPrefix("cm-del-") {
                guard let cid = await self.app.menuCategoryID() else { return [] }
                await self.app.deleteCategory(cid)
                return await self.app.refreshFragments()
            }
            return []
        }
        wire(router, id: "cat-add-form", events: ["submit", "click"]) { event in
            if event.event == "submit" {
                let name = event.data["cat-name-input"] ?? ""
                let color = event.data["cat-color-input"] ?? ""
                await self.app.addCategory(name: name, color: color)
                await self.app.setAddingCategory(false)
            } else if event.data["targetId"] != "cat-add-cancel" {
                return []   // swatch clicks are client-side
            } else {
                await self.app.setAddingCategory(false)
            }
            return await self.app.refreshFragments()
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
        wire(router, id: "chat-menu", events: ["click", "submit"]) { event in
            if event.event == "submit" {
                guard let sid = event.data["rename-id"], let name = event.data["rename-name"] else { return [] }
                await self.app.renameSession(sid, to: name)
                return await self.app.refreshFragments()
            }
            let tid = event.data["targetId"] ?? ""
            if tid.hasPrefix("sm-copy-") || tid.hasPrefix("sm-rename-") {
                return []   // handled client-side (clipboard copy / inline editor)
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
        wire(router, id: "modal", events: ["click"]) { event in
            if event.data["targetId"] == "modal-confirm" {
                if let pid = await self.app.confirmProfileDelete {
                    await self.app.cancelProfileDelete()
                    return await self.deleteProfile(pid)
                }
                let id = await self.app.confirmDeleteID
                await self.app.confirmDeleteSession(id)
            } else {
                await self.app.cancelDelete()
                await self.app.cancelProfileDelete()
            }
            return await self.app.refreshFragments()
        }
        wire(router, id: "chat-showarch", events: ["click"]) { _ in
            await self.app.setShowArchived(!self.app.showArchived)
            return await self.app.refreshFragments()
        }
    }

    private func newChat() async {
        await app.ensureRuntime()
        guard let store = await app.storeRef() else { return }
        let session = Session()
        try? await store.create(session)
        await app.reloadSessions(selecting: session.id)
        await app.setActiveSession(session.id)
        _ = await app.hint("New chat created.")
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
        guard !trimmed.isEmpty else { return [] }

        // Builtin slash commands are resolved locally (Hermes webui
        // COMMANDS) before anything else, including while a turn is running.
        if trimmed.hasPrefix("/") {
            if let updates = await handleBuiltinSlashCommand(trimmed) {
                return updates
            }
        }

        // Hermes `agent/skill_commands.py`: `/skill-name [instruction]` (and
        // stacked `/skill-a /skill-b do X`) expands into the model-facing
        // user message that embeds the full skill bodies. The transcript
        // shows the typed line via `displayText` (Hermes
        // `_slashDisplayTextOverride` pattern).
        var displayOverride: String? = nil
        var dispatchText = trimmed
        if let expanded = SkillCommands.expandSlashCommand(trimmed) {
            displayOverride = trimmed
            dispatchText = expanded
            await recordSlashSkillUse(trimmed)
        }

        // "Reply with selection" context blocks (Hermes
        // `_composerTextWithPendingSelections`): inline them as
        // `**Context N:**` + blockquote sections, then clear the chips.
        let withContexts = await app.composeWithPendingContexts(dispatchText)
        await app.clearPendingContexts()

        // Hermes parity: while a turn in THIS chat is running, a submitted
        // message is STEER — mid-run guidance injected at the next tool
        // boundary. A message typed in a different chat is NOT a steer: it
        // starts its own concurrent turn (the two runs are independent).
        let sid = await app.activeSessionID ?? ""
        if await app.isTurnActive(sessionID: sid) {
            await app.submitSteer(withContexts, sessionID: sid)
            _ = await app.hint("Steering current response…")
            return await app.chatFragments()
        }
        // Grab originating client id while inside the handler context.
        let cid = TaskEnv.clientID ?? 0
        let pusher = pusher(forClientID: cid)
        Task {
            await self.app.runTurn(userText: withContexts, pusher: pusher, sessionID: sid, displayText: displayOverride)
        }
        // Immediately clear the composer for the sender.
        return await self.app.chatFragments()
    }

    /// Resolve the skill a typed invocation refers to and bump its usage
    /// counter (Hermes `tools.skill_usage.bump_use`).
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

        // /usage — existing Hermes-parity toggle, kept verbatim.
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
                let names = ColorScheme.all.map { $0.id }
                await echoUserMessage(text)
                await pushAssistantNote("Available color schemes:\n\n" + names.map { "  `\($0)`" }.joined(separator: "\n"))
                return await app.chatFragments()
            }
            // Resolve by id first, then by label, case-insensitively.
            let byID = ColorScheme.all.first { $0.id.lowercased() == args.lowercased() }
            let byLabel = byID == nil ? ColorScheme.all.first { $0.label.lowercased() == args.lowercased() } : nil
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
            let cid = TaskEnv.clientID ?? 0
            let pusher = pusher(forClientID: cid)
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

    private func wireSkills(_ router: EventRouter) {
        wire(router, id: "skill-new", events: ["click"]) { _ in
            await self.app.setCreateSkill(true)
            return await self.app.refreshFragments()
        }
        wire(router, id: "skill-search-input", events: ["input"]) { event in
            await self.app.setSkillFilter(event.data["value"] ?? "")
            return await self.app.skillPanelFragment()
        }
        wire(router, id: "skill-list", events: ["click", "change"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            return await self.skillListAction(tid, checked: event.data["checked"])
        }
        wire(router, id: "skill-create-form", events: ["submit"]) { event in
            let name = (event.data["skill-name-input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cat = (event.data["skill-cat-input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = event.data["skill-desc-input"] ?? ""
            let content = event.data["skill-content-input"] ?? ""
            return await self.createSkill(name: name, desc: desc, content: content, category: cat)
        }
        for field in ["skill-name-input", "skill-cat-input", "skill-desc-input", "skill-content-input"] {
            wire(router, id: field, events: ["input"]) { event in
                await self.app.storeFormValue(field, event.data["value"] ?? "")
                return []
            }
        }
        wire(router, id: "skill-cancel", events: ["click"]) { _ in
            await self.app.setCreateSkill(false)
            return await self.app.refreshFragments()
        }
        wire(router, id: "side-tab-chips", events: ["change"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("st-") else { return [] }
            let key = dec(String(tid.dropFirst("st-".count))) ?? ""
            let on = event.data["checked"] == "true"
            await self.app.setSidebarTab(key, visible: on)
            return await self.app.fragmentsWithIconbar()
        }
        wire(router, id: "sidebar-tab-order", events: ["change"]) { event in
            let keys = (event.data["value"] ?? "").split(separator: ",").map(String.init)
            await self.app.setSidebarTabOrder(keys)
            return await self.app.fragmentsWithIconbar()
        }
        wire(router, id: "skill-edit", events: ["click"]) { _ in
            await self.app.startSkillEdit()
            return await self.app.refreshFragments()
        }
        wire(router, id: "sk-edit-form", events: ["submit", "click"]) { event in
            // Clicks on form children (the id-less Save button resolves to the
            // form) carry NO field values: only handle the named action
            // buttons here. The Save button's real work arrives as a "submit".
            if event.event == "click" {
                if event.data["targetId"] == "sk-edit-cancel" {
                    await self.app.cancelSkillEdit()
                    return await self.app.refreshFragments()
                }
                return []
            }
            let orig = event.data["sk-orig"] ?? ""
            let name = (event.data["sk-edit-name-input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cat = (event.data["sk-edit-cat-input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = event.data["sk-edit-desc-input"] ?? ""
            let content = event.data["sk-edit-content-input"] ?? ""
            return await self.saveSkill(original: orig, name: name, category: cat, desc: desc, content: content)
        }
        wire(router, id: "sk-edit-delete", events: ["click"]) { _ in
            guard let name = await self.app.selectedSkill, !name.isEmpty else { return [] }
            await self.deleteSkill(name)
            await self.app.cancelSkillEdit()
            return await self.app.refreshFragments()
        }
        for field in ["sk-edit-name-input", "sk-edit-cat-input", "sk-edit-desc-input", "sk-edit-content-input"] {
            wire(router, id: field, events: ["input"]) { event in
                await self.app.storeFormValue(field, event.data["value"] ?? "")
                return []
            }
        }
    }

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

    private func skillListAction(_ tid: String, checked: String? = nil) async -> [FragmentUpdate] {
        if tid.hasPrefix("sk-open-"), let name = dec(String(tid.dropFirst("sk-open-".count))) {
            await self.app.selectSkill(name)
            await self.app.recordSkillEvent(name: name, views: 1)
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("sk-toggle-"), let name = dec(String(tid.dropFirst("sk-toggle-".count))) {
            await self.app.toggleSkill(name, enable: checked == "true")
            return await self.app.refreshFragments()
        }
        if tid.hasPrefix("sk-del-"), let name = dec(String(tid.dropFirst("sk-del-".count))) {
            await self.deleteSkill(name)
            return await self.app.refreshFragments()
        }
        return []
    }

    private func createSkill(name: String, desc: String, content: String, category: String = "") async -> [FragmentUpdate] {
        guard !name.isEmpty, !desc.isEmpty else {
            _ = await app.hint("Skill needs at least a name and a description.", kind: "error")
            return await app.refreshFragments()
        }
        guard let dir = await app.skillsDir() else {
            _ = await app.hint("No skills directory available.", kind: "error")
            return await app.refreshFragments()
        }
        let skillDir = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            var body = "---\nname: \(name)\ndescription: \(desc)\n"
            if !category.isEmpty { body += "category: \(category)\n" }
            body += "---\n\n\(content)"
            try body.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            _ = await app.hint("Failed to create skill: \(error)", kind: "error")
            return await app.refreshFragments()
        }
        await app.reloadSkills()
        await app.setCreateSkill(false)
        await app.selectSkill(name)
        _ = await app.hint("Skill '\(name)' created.")
        return await app.refreshFragments()
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
        wire(router, id: "profile-new", events: ["click"]) { _ in
            await self.app.setCreateProfile(true)
            return await self.app.refreshFragments()
        }
        wire(router, id: "profile-create-form", events: ["submit"]) { event in
            let name = (event.data["profile-name-input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = event.data["profile-title-input"] ?? ""
            let desc = event.data["profile-desc-input"] ?? ""
            let ctxLength = AppState.optInt(event.data["profile-ctx-length"] ?? "")
            let maxOutput = AppState.optInt(event.data["profile-ctx-maxtok"] ?? "")
            let rawEffort = event.data["profile-ctx-effort"] ?? ""
            let effort = rawEffort.isEmpty ? nil : rawEffort
            let temperature = AppState.optDouble(event.data["profile-ctx-temp"] ?? "")
            let topP = AppState.optDouble(event.data["profile-ctx-topp"] ?? "")
            let budget = AppState.optInt(event.data["profile-ctx-budget"] ?? "")
            return await self.submitProfileForm(
                name: name, title: title, desc: desc,
                contextLength: ctxLength, maxOutputTokens: maxOutput,
                reasoningEffort: effort, temperature: temperature,
                topP: topP, compressionBudget: budget
            )
        }
        for field in ["profile-name-input", "profile-title-input", "profile-desc-input"] {
            wire(router, id: field, events: ["input"]) { event in
                await self.app.storeFormValue(field, event.data["value"] ?? "")
                return []
            }
        }
        wire(router, id: "profile-cancel", events: ["click"]) { _ in
            await self.app.setCreateProfile(false)
            await self.app.setEditingProfile(nil)
            return await self.app.refreshFragments()
        }
        wire(router, id: "profile-list", events: ["click"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            return await self.profileListAction(tid)
        }
        wire(router, id: "profile-skills", events: ["change"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            let rest = String(tid.dropFirst("ps-".count))
            let parts = rest.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pname = dec(parts[0]) else { return [] }
            let skillName = dec(parts[1]) ?? ""
            let on = event.data["checked"] == "true"
            await self.app.toggleProfileSkill(profile: pname, skill: skillName, on: on)
            return await self.app.refreshFragments()
        }
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

    private func createProfile(name: String, title: String, desc: String) async -> [FragmentUpdate] {
        return await self.submitProfileForm(name: name, title: title, desc: desc)
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
        compressionBudget: Int? = nil
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
        wire(router, id: "tool-list", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("tl-open-") else { return [] }
            let name = dec(String(tid.dropFirst("tl-open-".count))) ?? ""
            await self.app.selectTool(name)
            return await self.app.refreshFragments()
        }
        wire(router, id: "tools-toggle", events: ["change"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("ts-") else { return [] }
            let ts = dec(String(tid.dropFirst("ts-".count))) ?? ""
            let on = event.data["checked"] == "true"
            await self.app.setToolset(ts, enabled: on)
            return await self.app.refreshFragments()
        }
    }

    // MARK: Tool plugins (Settings)

    private func wirePlugins(_ router: EventRouter) {
        wire(router, id: "plugin-toggle", events: ["change"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("plgl-") else { return [] }
            let name = dec(String(tid.dropFirst("plgl-".count))) ?? ""
            let on = event.data["checked"] == "true"
            await self.app.setPluginEnabled(name, enabled: on)
            return await self.app.refreshFragments()
        }
        wire(router, id: "plugin-rescan", events: ["click"]) { _ in
            await self.app.refreshPlugins()
            return await self.app.refreshFragments()
        }
    }

    // MARK: Workspaces

    private func wireWorkspaces(_ router: EventRouter) {
        wire(router, id: "ws-new", events: ["click"]) { _ in
            await self.app.setCreateWorkspace(true)
            return await self.app.refreshFragments()
        }
        wire(router, id: "ws-create-form", events: ["submit"]) { event in
            let name = (event.data["ws-name-input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let path = (event.data["ws-path-input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return await self.createWorkspace(name: name, path: path)
        }
        wire(router, id: "ws-name-input", events: ["input"]) { event in
            await self.app.storeFormValue("ws-name-input", event.data["value"] ?? "")
            return []
        }
        wire(router, id: "ws-path-input", events: ["input"]) { event in
            await self.app.storeFormValue("ws-path-input", event.data["value"] ?? "")
            return []
        }
        wire(router, id: "ws-cancel", events: ["click"]) { _ in
            await self.app.setCreateWorkspace(false)
            return await self.app.refreshFragments()
        }
        wire(router, id: "workspace-list", events: ["click"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            return await self.workspaceListAction(tid)
        }
    }

    private func workspaceListAction(_ tid: String) async -> [FragmentUpdate] {
        if tid.hasPrefix("ws-open-"), let name = dec(String(tid.dropFirst("ws-open-".count))) {
            return await self.switchWorkspace(name)
        }
        if tid.hasPrefix("ws-del-"), let name = dec(String(tid.dropFirst("ws-del-".count))) {
            await self.deleteWorkspace(name)
            return await self.app.refreshFragments()
        }
        return []
    }

    private func createWorkspace(name rawName: String, path rawPath: String) async -> [FragmentUpdate] {
        let cleaned = rawName.lowercased().replacingOccurrences(of: " ", with: "-")
        let valid = !cleaned.isEmpty && cleaned.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard valid else {
            _ = await app.hint("Workspace names: letters, numbers, dashes, underscores.", kind: "error")
            return await self.app.refreshFragments()
        }
        if await app.workspaceNames().contains(cleaned) {
            _ = await app.hint("Workspace '\(cleaned)' already exists.", kind: "error")
            return await self.app.refreshFragments()
        }
        // Resolve the folder path (~ expansion) and validate it exists as a directory.
        var path = rawPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst(1)
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard path.hasPrefix("/"), exists, isDir.boolValue else {
            _ = await app.hint("Invalid folder path: '\(path)' is not an existing directory.", kind: "error")
            return await self.app.refreshFragments()
        }
        var entries = await app.workspaceEntries()
        entries.append(WorkspaceEntry(name: cleaned, path: (path as NSString).standardizingPath))
        await app.setWorkspaces(entries, active: cleaned)
        await app.rebuildAndReload()
        await app.setCreateWorkspace(false)
        _ = await app.hint("Workspace '\(cleaned)' created at \(path).")
        return await self.app.refreshFragments(includeApp: true)
    }

    private func switchWorkspace(_ name: String) async -> [FragmentUpdate] {
        let active = await app.activeWorkspaceName()
        if name == active { return [] }
        await app.setWorkspace(active: name)
        await app.rebuildAndReload()
        _ = await app.hint("Default workspace is now '\(name)'. Chats without their own workspace use it.")
        return await self.app.refreshFragments(includeApp: true)
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

    // MARK: Settings

    private func wireSettings(_ router: EventRouter) {
        wire(router, id: "set-theme", events: ["change"]) { event in
            await self.app.setTheme(event.data["value"] ?? "light")
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "set-size", events: ["change"]) { event in
            await self.app.setTextSize(event.data["value"] ?? "md")
            _ = await self.app.hint("Text size updated.")
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "theme-pick", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("thm-") else { return [] }
            let theme = String(tid.dropFirst("thm-".count))
            await self.app.setTheme(theme)
            _ = await self.app.hint("Theme set to \(theme).")
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "font-size-pick", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("fsz-") else { return [] }
            let size = String(tid.dropFirst("fsz-".count))
            await self.app.setTextSize(size)
            _ = await self.app.hint("Text size updated.")
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "scheme-pick", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("scheme-") else { return [] }
            if let name = dec(String(tid.dropFirst("scheme-".count))) {
                await self.app.setColorScheme(name)
            }
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "activity-display", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("actdisp-") else { return [] }
            let mode = String(tid.dropFirst("actdisp-".count))
            await self.app.setActivityDisplay(mode)
            _ = await self.app.hint("Activity display set to \(mode.replacingOccurrences(of: "_", with: " "))")
            return await self.app.refreshFragments()
        }
        wire(router, id: "set-think", events: ["change"]) { event in
            await self.app.setDefaultThinking(event.data["value"] ?? "medium")
            _ = await self.app.hint("Default thinking level updated.")
            return await self.app.refreshFragments()
        }
        wire(router, id: "set-showtokens", events: ["change"]) { event in
            await self.app.setShowTokenUsage(event.data["checked"] == "true")
            return await self.app.refreshFragments()
        }
        wire(router, id: "set-showtps", events: ["change"]) { event in
            await self.app.setShowTps(event.data["checked"] == "true")
            return await self.app.refreshFragments()
        }
        wire(router, id: "set-pinlimit", events: ["change"]) { event in
            let n = Int(event.data["value"] ?? "") ?? 3
            await self.app.setPinnedSessionsLimit(n)
            return await self.app.refreshFragments()
        }
        wire(router, id: "aux-edit", events: ["click"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
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
        wire(router, id: "aux-form", events: ["submit"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("aux-form-") else { return [] }
            let key = String(tid.dropFirst("aux-form-".count))
            guard let task = AuxiliaryTask(configKey: key) else { return [] }
            await self.app.setAuxOverride(
                task: task,
                provider: event.data["aux-provider"] ?? "",
                model: event.data["aux-model"] ?? "",
                baseURL: event.data["aux-base-url"] ?? "",
                apiKey: event.data["aux-api-key"] ?? ""
            )
            await self.app.setAuxEditing(nil)
            return await self.app.refreshFragments()
        }
        wire(router, id: "set-tessera", events: ["change"]) { event in
            let off = event.data["checked"] == "true"
            await self.app.setTesseraOff(off)
            await self.app.rebuildAndReload()
            _ = await self.app.hint(off ? "Switched to file storage." : "Switched to Tessera storage.", kind: off ? "" : "success")
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "set-moa", events: ["change"]) { event in
            let on = event.data["checked"] == "true"
            await self.app.setMoaEnabled(on)
            _ = await self.app.hint(on
                ? "Mixture of Agents enabled — reference models must be configured in ~/.arc/config.json."
                : "Mixture of Agents disabled.")
            return await self.app.refreshFragments(includeApp: true)
        }
        wire(router, id: "modelcfg-add-form", events: ["submit"]) { event in
            let name = (event.data["mc-name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (event.data["mc-model"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = (event.data["mc-provider"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let base = (event.data["mc-baseurl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = event.data["mc-apikey"] ?? ""
            let ctx = Int((event.data["mc-ctx"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            let maxtok = Int((event.data["mc-maxtok"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            return await self.addModelConfig(name: name, model: model, provider: provider, baseURL: base, apiKey: key, contextLength: ctx, maxOutputTokens: maxtok)
        }
        for field in ["mc-name", "mc-model", "mc-provider", "mc-baseurl", "mc-apikey", "mc-ctx", "mc-maxtok"] {
            wire(router, id: field, events: ["input"]) { event in
                await self.app.storeFormValue(field, event.data["value"] ?? "")
                return []
            }
        }
        wire(router, id: "modelcfg-list", events: ["click"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            return await self.modelConfigAction(tid)
        }
        wire(router, id: "kanban", events: ["click", "submit"]) { event in
            if event.event == "submit" {
                // The inline form always carries all four fields; branch on
                // which one is actually populated (empty strings are ignored).
                if let cid = event.data["kb-col-id"], !cid.isEmpty,
                   let name = event.data["kb-col-name"], !name.isEmpty {
                    await self.app.renameKanbanColumn(cid, to: name)
                } else if let cardid = event.data["kb-card-id"], !cardid.isEmpty,
                          let title = event.data["kb-card-title"], !title.isEmpty {
                    await self.app.renameKanbanCard(cardid, to: title)
                } else {
                    return []
                }
                return await self.app.refreshFragments()
            }
            guard let tid = event.data["targetId"] else { return [] }
            return await self.kanbanAction(tid)
        }
        wire(router, id: "kb-addcol-form", events: ["submit", "click"]) { event in
            if event.event == "submit" {
                let name = event.data["kb-addcol-name"] ?? ""
                let color = event.data["kb-addcol-color"] ?? ""
                await self.app.addKanbanColumn(name: name, color: color)
                await self.app.setAddingColumn(false)
            } else if event.data["targetId"] != "kb-addcol-cancel" {
                return []
            } else {
                await self.app.setAddingColumn(false)
            }
            return await self.app.refreshFragments()
        }
        wire(router, id: "kb-addcard-form", events: ["submit", "click"]) { event in
            if event.event == "submit" {
                let title = event.data["kb-addcard-name"] ?? ""
                let col = event.data["kb-addcard-col"] ?? ""
                await self.app.addKanbanCard(title, in: col)
            } else if event.data["targetId"] != "kb-addcard-cancel" {
                return []
            } else {
                await self.app.setAddingCard(nil)
            }
            return await self.app.refreshFragments()
        }
        wire(router, id: "memory", events: ["click"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            if tid.hasPrefix("mem-open-") {
                await self.app.openMemoryDoc(String(tid.dropFirst("mem-open-".count)))
            } else if tid == "mem-edit" {
                await self.app.startMemoryEdit()
            } else {
                return []
            }
            return await self.app.refreshFragments()
        }
        wire(router, id: "mem-save-form", events: ["submit", "click"]) { event in
            if event.event == "submit" {
                let key = event.data["mem-key"] ?? "memory"
                let content = event.data["mem-content"] ?? ""
                await self.app.saveMemoryDoc(key, content: content)
            } else if event.data["targetId"] == "mem-cancel" {
                await self.app.cancelMemoryEdit()
            } else {
                return []
            }
            return await self.app.refreshFragments()
        }
        wire(router, id: "workspace", events: ["click"]) { event in
            guard let tid = event.data["targetId"] else { return [] }
            return await self.workspaceAction(tid)
        }
        wire(router, id: "workspace-upload", events: ["submit"]) { event in
            let name = event.data["upl-name"] ?? ""
            let path = event.data["upl-path"] ?? ""
            let b64 = event.data["upl-b64"] ?? ""
            guard !path.isEmpty, !b64.isEmpty else { return [] }
            await self.app.uploadWorkspaceFile(name: name, relPath: path, b64: b64)
            return await self.workspaceFragments()
        }
        wire(router, id: "ws-new-form", events: ["submit", "click"]) { event in
            if event.event == "submit" {
                let name = event.data["ws-new-name"] ?? ""
                let kind = event.data["ws-new-kind"] ?? "file"
                await self.app.createWorkspaceEntry(name: name, kind: kind)
            } else if event.data["targetId"] == "ws-new-cancel" {
                await self.app.setWsNewMode("")
            } else {
                return []
            }
            return await self.workspaceFragments()
        }
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
            await app.deleteKanbanCard(id)
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
            _ = await app.hint("Workspace file: \(path)")
        } else {
            return []
        }
        return await self.workspaceFragments()
    }

    private func workspaceFragments() async -> [FragmentUpdate] {
        let dock = await app.workspaceDockHTML()
        let panel = await app.workspacePanelHTML()
        let toasts = await app.toastsShell()
        return [
            FragmentUpdate(id: "ws-dock", html: dock),
            FragmentUpdate(id: "ws-panel", html: panel),
            FragmentUpdate(id: "toasts", html: toasts),
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
        let preset = ModelConfigPreset(name: name, model: model, provider: provider.isEmpty ? "custom" : provider, baseURL: baseURL, apiKey: apiKey, contextLength: ctx, maxOutputTokens: maxtok)
        await app.addModelConfig(preset)
        _ = await app.hint("Configuration '\(name)' added.")
        return await self.app.refreshFragments()
    }

    private func modelConfigAction(_ tid: String) async -> [FragmentUpdate] {
        if tid.hasPrefix("mc-use-") {
            if let name = dec(String(tid.dropFirst("mc-use-".count))) {
                await self.app.useModelConfig(name)
                _ = await app.hint("Active configuration: \(name)")
            }
        } else if tid.hasPrefix("mc-del-") {
            if let name = dec(String(tid.dropFirst("mc-del-".count))) {
                await self.app.removeModelConfig(name)
                _ = await app.hint("Removed configuration '\(name)'.")
            }
        }
        return await self.app.refreshFragments()
    }

    // MARK: Toasts

    private func wireToasts(_ router: EventRouter) {
        wire(router, id: "toast-dismiss", events: ["click"]) { event in
            guard let tid = event.data["targetId"], tid.hasPrefix("t-"),
                  let id = Int(tid.dropFirst("t-".count)) else { return [] }
            await self.app.dismissToast(id: id)
            let html = await self.app.toastsHTML()
            let toastsDiv = "<div id=\"toasts\">\(html)</div>"
            return [FragmentUpdate(id: "toasts", html: toastsDiv)]
        }
    }
}
