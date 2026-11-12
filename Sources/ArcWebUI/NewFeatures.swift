import ArcAgentCore
import ArcTheme
import AsyncHTTPClient
import Foundation
import Logging
import NIO
import WebUI
import WebUIDesignSystem

// MARK: - arc-parity panels: Tasks (cron) + Todos, plus regenerate & vision.

/// A simple todo entry, mirrored from the arc agent webui todos panel.
struct TodoItem: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var text: String
    var done: Bool = false
    var createdAt: Date = Date()

    /// Storage key for todos saved before per-chat scoping; migrated into the
    /// active chat on first view.
    static let legacyKey = ""
}

// MARK: - AppState: todos + scheduled jobs

extension AppState {

    // MARK: Todos (per chat)

    /// Todos are scoped to the active chat. Returns the storage key.
    func todosKey() -> String {
        activeSessionID ?? TodoItem.legacyKey
    }

    /// Todos stored for a chat (empty when none).
    func todos(for chat: String) -> [TodoItem] {
        settings.todos[chat] ?? []
    }

    /// Text of one todo in the active chat (for the per-item run action).
    func todoText(for id: String) -> String? {
        todos(for: todosKey()).first { $0.id == id }?.text
    }

    /// Texts of all OPEN todos in the active chat (for run-all).
    func openTodoTexts() -> [String] {
        todos(for: todosKey()).filter { !$0.done }.map(\.text)
    }

    /// IDs of all OPEN todos in the active chat (for run-all completion).
    func openTodoIDs() -> [String] {
        todos(for: todosKey()).filter { !$0.done }.map(\.id)
    }

    /// Mark todo(s) as done (run action). Idempotent; saves only on change.
    func markTodosDone(_ ids: [String]) {
        let key = todosKey()
        guard var list = settings.todos[key], !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            if let i = list.firstIndex(where: { $0.id == id }), !list[i].done {
                list[i].done = true
                changed = true
            }
        }
        guard changed else { return }
        settings.todos[key] = list
        saveSettings()
    }

    /// Move the pre-per-chat list into the active chat on first use. Kept in
    /// the legacy bucket until a chat is open so nothing is lost.
    func migrateLegacyTodosIfNeeded() {
        guard let legacy = settings.todos.removeValue(forKey: TodoItem.legacyKey),
              !legacy.isEmpty else { return }
        guard let chat = activeSessionID, !chat.isEmpty else {
            settings.todos[TodoItem.legacyKey] = legacy
            return
        }
        settings.todos[chat, default: []].insert(contentsOf: legacy, at: 0)
        saveSettings()
    }

    func toggleTodo(_ id: String) {
        let key = todosKey()
        guard var list = settings.todos[key],
              let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].done.toggle()
        settings.todos[key] = list
        saveSettings()
    }

    func removeTodo(_ id: String) {
        let key = todosKey()
        settings.todos[key] = (settings.todos[key] ?? []).filter { $0.id != id }
        saveSettings()
    }

    func addTodo(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        settings.todos[todosKey(), default: []].append(TodoItem(text: t))
        saveSettings()
    }

    func clearDoneTodos() {
        let key = todosKey()
        settings.todos[key] = (settings.todos[key] ?? []).filter { !$0.done }
        saveSettings()
    }

    // MARK: Cron (store-backed)

    // The scheduling engine lives in the daemon (`CronScheduler` over
    // `RuntimeCronStore` — ONE engine, ONE store). This view keeps a render
    // cache (`scheduledJobs`) that `refreshScheduledJobs()` reloads from the
    // store; the CRUD below writes through to the store, and execution comes
    // back through `runScheduledJob` via the daemon's cron runner.

    /// Run one scheduled job fully headless: the job's turn runs on the same
    /// per-turn `ArcAgent` an interactive chat mints (CONVERGE A8) — one engine,
    /// one prompt builder, one tool dispatch — with the scheduler's approval
    /// policy (nobody can answer a card, critical commands are blocked and
    /// logged, never run), the job's own iteration cap, and the UI as the
    /// transcript's only writer.
    /// Runs the job's turn and returns the final assistant text — the daemon's
    /// cron runner consumes it (the UI's Run-now ignores it).
    @discardableResult
    func runScheduledJob(_ job: CronJob, now: Date = Date()) async -> String {
        let sid = jobSessionID(job)
        var session: Session
        if sessions.contains(where: { $0.id == sid }) {
            await ensureSessionMessages(sid)
            guard let existing = sessions.first(where: { $0.id == sid }) else { return "" }
            session = existing
        } else {
            session = Session(id: sid, createdAt: now, updatedAt: now, model: settings.modelConfig(named: settings.activeConfig)?.model ?? "")
            if let store {
                try? await store.create(session)
            }
            settings.sessionTitles[sid] = "Cron: \(job.name)"
            await reloadSessions(selecting: nil)
        }
        session.updatedAt = now

        // the same pre-flight a chat turn keeps: a configuration that cannot
        // build a client at all fails before the prompt is stored.
        guard let preset = settings.modelConfig(named: configName(for: sid)),
              turnClientOverride != nil || makeClient(for: preset) != nil else {
            // the caller (Run-now or the daemon scheduler) records lastOutput
            lastScheduledRunFailed = true
            return "Error: no model configuration"
        }

        let userMsg = Message(role: .user, content: job.prompt, createdAt: now)
        session.messages.append(userMsg)
        await persistMessage(userMsg, sessionID: sid, store: store, healWith: session.messages)

        // the job's turn on the same engine as a chat turn: same tiered prompt
        // builder, same progressive tool disclosure, same guardrails. the 25-round
        // cap is the retired loop's, so a job that used to stop stops here too.
        let minted = await makeTurnAgent(
            preset: preset,
            thinking: thinkingLevel(for: sid),
            headless: true,
            sessionID: sid,
            // the agent appends the job's prompt itself; the seed is everything
            // the job session already carried.
            initialHistory: Array(session.messages.dropLast()),
            maxIterations: Self.scheduledJobIterations,
            pusher: { _ in }
        )
        let agent = minted.agent

        var round = TurnTranscript()
        var heldToolRound: ScheduledToolRound?
        var streamed = ""
        var completedText: String?
        var failure: String?

        /// take the held tool round as the messages it stores: its assistant
        /// message (content, reasoning, tool calls) then one tool message per
        /// result — the transcript shape a chat turn writes, tool-call ids
        /// included, so the job session replays as a valid tool conversation.
        func takeToolRoundMessages() -> [Message] {
            guard let held = heldToolRound else { return [] }
            heldToolRound = nil
            var messages = [Message(
                role: .assistant,
                content: held.content.isEmpty ? nil : held.content,
                toolCalls: held.calls,
                createdAt: Date(),
                reasoning: held.reasoning.isEmpty ? nil : held.reasoning
            )]
            messages.append(contentsOf: held.results.map { result in
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

        func persist(_ message: Message) async {
            await persistMessage(message, sessionID: sid, store: store)
        }

        do {
            try await agent.prime()
            for try await event in agent.streamTurn(message: job.prompt) {
                // a round closes when the next round's stream begins: a text or
                // reasoning delta, the provider's usage report, or a terminal
                // event. the held tool round is written in one piece then.
                switch event {
                case .textDelta, .reasoningDelta, .usage, .completed, .failed:
                    for message in takeToolRoundMessages() {
                        await persist(message)
                    }
                case .toolCallStarted, .toolCallFinished, .compressing, .contextConstrained, .outputReservationExceedsWindow:
                    // mid-turn; the held tool round stays open.
                    break
                }

                switch event {
                case .textDelta(let text):
                    round.apply(event)
                    streamed += text
                case .reasoningDelta, .usage:
                    round.apply(event)
                case .toolCallStarted(let id, let name, let arguments):
                    if heldToolRound == nil {
                        heldToolRound = ScheduledToolRound(content: round.content, reasoning: round.reasoning)
                        round = TurnTranscript()
                    }
                    heldToolRound?.calls.append(ToolCall(
                        id: id,
                        type: "function",
                        function: ToolCallFunction(name: name, arguments: arguments)
                    ))
                case .toolCallFinished(let id, let name, let result):
                    heldToolRound?.results.append((id: id, name: name, result: result))
                case .compressing:
                    // display-only; a scheduled-job transcript stores no
                    // compression state.
                    break
                case .contextConstrained:
                    // display-only; same policy as .compressing here.
                    break
                case .outputReservationExceedsWindow:
                    // display-only; same policy as .compressing here.
                    break
                case .completed(let text, _):
                    round.apply(event)
                    completedText = text
                case .failed(let message):
                    failure = message
                }
            }
        } catch {
            // a throwing stream is a transport failure — the same shape as
            // `.failed`. a tool round that finished before it is still real
            // work, so it lands in the transcript.
            for message in takeToolRoundMessages() {
                await persist(message)
            }
            failure = "\(error)"
        }
        await agent.shutdownHTTPClient()

        // the reply: the core's terminal text once a turn completed, else the
        // streamed text, else the failure — the value `lastOutput` records.
        let finalText: String
        if let completedText, !completedText.isEmpty {
            finalText = completedText
        } else if let failure {
            finalText = failure
        } else if !round.content.isEmpty {
            finalText = round.content
        } else {
            finalText = streamed
        }
        let asstMsg = Message(
            role: .assistant,
            content: finalText,
            createdAt: Date(),
            reasoning: round.reasoning.isEmpty ? nil : round.reasoning,
            usage: round.usage,
            terminalReason: round.terminalReason
        )
        await persist(asstMsg)

        // Job bookkeeping is the caller's: the daemon's scheduler records
        // lastRunAt/runCount/lastOutput/nextRunAt, and Run-now does the same
        // through `updateJob`.
        // Never yank the user's active chat: the job's session belongs to the
        // scheduled-tasks area, not the main chat list.
        await reloadSessions(selecting: nil)
        // If this job's detail is open on the Tasks page, refresh its thread.
        if tasksSelectedID == job.id {
            await selectTaskJob(job.id)
        }
        lastScheduledRunFailed = (failure != nil)
        return finalText
    }

    /// The retired job loop's own ceiling: 25 LLM rounds per run. The core's
    /// `maxIterations` counts the same unit (one loop iteration per model call),
    /// so the cap means what it meant before the runner moved onto the engine.
    static let scheduledJobIterations = 25

    func jobSessionID(_ job: CronJob) -> String { "Cron-\(job.id)" }

    /// Persist a job mutation through the cron store (the single source of
    /// truth) and refresh the render cache. The mutation applies to the
    /// store's CURRENT copy — a stale render cache must never be written
    /// back, or the save silently reverts anything that landed in the store
    /// while the page was open (run counters, edits).
    private func updateJob(_ id: String, _ mutate: (inout CronJob) -> Void) async {
        guard var job = try? await cronStore.get(id: id), job != nil else { return }
        mutate(&job)
        try? await cronStore.save(job)
        await refreshScheduledJobs()
    }

    @discardableResult
    func addJob(name: String, schedule: String, prompt: String, firstRun: Date? = nil,
                deliver: String? = nil, profile: String? = nil, runBudget: Int? = nil) async -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty schedule is a MANUAL job — legal (fires only via Run
        // now). A one-shot with a recurring schedule is not.
        guard !n.isEmpty, !p.isEmpty else { return nil }
        if runBudget == 1, CronSchedule.isRecurring(s) { return nil }
        var job = CronJob(name: n, schedule: s, prompt: p)
        job.deliver = (deliver?.isEmpty ?? true) ? nil : deliver
        job.profile = (profile?.isEmpty ?? true) ? nil : profile
        if let runBudget {
            job.runBudget = runBudget
            job.runsRemaining = runBudget
        }
        // First run = the user's chosen start time (defaults to the next
        // interval tick); a manual job stays unarmed until Run now.
        job.nextRunAt = s.isEmpty ? firstRun : (firstRun ?? CronNext(expression: job.schedule, from: Date()))
        job.lastOutput = nil
        try? await cronStore.save(job)
        await refreshScheduledJobs()
        return job.id
    }

    /// Copy a job's configuration into a new paused job (" (copy)"), so a
    /// duplicated job never fires until the user resumes it.
    func duplicateJob(_ id: String) async {
        guard let src = settings.scheduledJobs.first(where: { $0.id == id }) else { return }
        var job = CronJob(name: "\(src.name) (copy)", schedule: src.schedule, prompt: src.prompt)
        job.deliver = src.deliver
        job.profile = src.profile
        job.script = src.script
        job.contextFrom = src.contextFrom
        job.runBudget = src.runBudget
        job.runsRemaining = src.runsRemaining
        job.resetEveryRuns = src.resetEveryRuns
        job.isActive = false
        try? await cronStore.save(job)
        tasksMode = .detail
        await selectTaskJob(job.id)
        await refreshScheduledJobs()
    }

    /// Apply an edit-form submit: rename / reschedule / re-prompt, recomputing
    /// the next fire date when the schedule changed.
    func editJob(_ id: String, name: String, schedule: String, prompt: String,
                 deliver: String?, profile: String?, runBudget: Int? = nil) async {
        // Compare-and-save against the store's current copy, never the page
        // cache — the cache can be stale by several scheduler runs.
        guard var job = try? await cronStore.get(id: id), job != nil else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !p.isEmpty else { return }
        if runBudget == 1, CronSchedule.isRecurring(s) { return }
        let scheduleChanged = job.schedule != s
        job.name = n
        job.schedule = s
        job.prompt = p
        job.deliver = (deliver?.isEmpty ?? true) ? nil : deliver
        job.profile = (profile?.isEmpty ?? true) ? nil : profile
        if let runBudget {
            // An edit is a deliberate reconfiguration — re-arm the countdown
            // unconditionally, so a spent one-shot being reshaped gets a
            // fresh single fire (a job never self-deactivates through edit).
            job.runBudget = runBudget
            job.runsRemaining = runBudget
        } else {
            job.runBudget = nil
            job.runsRemaining = nil
        }
        if scheduleChanged {
            job.nextRunAt = job.isActive && !s.isEmpty ? CronNext(expression: s, from: Date()) : nil
        }
        try? await cronStore.save(job)
        tasksMode = .detail
        await refreshScheduledJobs()
        if let next = job.nextRunAt { _ = next }
    }

    // MARK: Scheduled-tasks page mode

    func setTasksCategory(_ raw: String) {
        tasksCategory = TaskCategory(rawValue: raw) ?? .activePending
    }

    func setTasksSearch(_ raw: String) {
        tasksSearchDraft = raw
    }

    /// Open the add form (the sidebar "+"), resetting the schedule draft.
    func openTaskAdd() {
        tasksMode = .add
        taskJobKind = "recurring"
        taskSchedWhen = ""
        taskSchedPreset = "every"
        taskSchedEvery = "15"
        taskSchedUnit = "m"
        taskSchedTime = "09:00"
        taskSchedDow = "1"
        taskSchedCustom = ""
    }

    /// Open the edit form for the selected job, prefilled from its current
    /// config (including a parsed schedule draft).
    func openTaskEdit(_ id: String) async {
        guard let job = settings.scheduledJobs.first(where: { $0.id == id }) else { return }
        tasksSelectedID = id
        tasksMode = .edit
        await ensureSessionMessages(jobSessionID(job))
        await loadRunHistory(id)
        // Kind prefills from the job's shape; recurring keeps the preset
        // detection below.
        if job.isOneShot {
            taskJobKind = "oneshot"
            taskSchedWhen = job.schedule
            taskSchedPreset = "custom"
        } else if job.schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            taskJobKind = "manual"
            taskSchedPreset = "custom"
        } else {
            taskJobKind = "recurring"
            taskSchedPreset = "custom"
        }
        taskSchedEvery = "15"
        taskSchedUnit = "m"
        taskSchedTime = "09:00"
        taskSchedDow = "1"
        taskSchedCustom = job.schedule
        // Recognizable shapes prefill their native preset; anything else stays
        // custom with the raw expression in the text field.
        if let m = parseEverySchedule(job.schedule) {
            taskSchedPreset = "every"
            taskSchedEvery = String(m.n)
            taskSchedUnit = m.unit
        } else if let c = parseClockSchedule(job.schedule) {
            taskSchedTime = c.time
            if let dow = c.dow {
                taskSchedPreset = "weekly"
                taskSchedDow = String(dow)
            } else {
                taskSchedPreset = "daily"
            }
        }
    }

    func closeTaskForm() {
        tasksMode = .detail
    }

    // Schedule draft setters (change-event wires).
    func setTaskSchedPreset(_ v: String) { taskSchedPreset = v.isEmpty ? "every" : v }
    func setTaskJobKind(_ v: String) { taskJobKind = v.isEmpty ? "recurring" : v }
    func setTaskSchedWhen(_ v: String) { taskSchedWhen = v }
    func setTaskSchedEvery(_ v: String) { taskSchedEvery = v }
    func setTaskSchedUnit(_ v: String) { taskSchedUnit = v.isEmpty ? "m" : v }
    func setTaskSchedTime(_ v: String) { taskSchedTime = v }
    func setTaskSchedDow(_ v: String) { taskSchedDow = v.isEmpty ? "1" : v }
    func setTaskSchedCustom(_ v: String) { taskSchedCustom = v }

    func toggleTaskGroup(_ cat: String) {
        if taskExpanded.contains(cat) { taskExpanded.remove(cat) } else { taskExpanded.insert(cat) }
    }
    func setTaskDeliverPreset(_ v: String) { taskDeliverPreset = v.isEmpty ? "local" : v }

    /// The cron expression the current draft builds. The job kind comes
    /// first: a one-shot builds an ISO instant, a manual job builds an
    /// empty schedule, and only recurring uses the preset machinery.
    func taskScheduleExpression() -> String {
        switch taskJobKind {
        case "oneshot":
            return taskSchedWhen.trimmingCharacters(in: .whitespacesAndNewlines)
        case "manual":
            return ""
        default:
            break
        }
        switch taskSchedPreset {
        case "every":
            let n = max(1, Int(taskSchedEvery) ?? 15)
            return "every \(n)\(taskSchedUnit)"
        case "daily":
            return clockCron(taskSchedTime, dow: nil)
        case "weekly":
            return clockCron(taskSchedTime, dow: Int(taskSchedDow))
        default:
            return taskSchedCustom
        }
    }

    /// "every 15m" → (15, "m"); nil when the schedule is not an interval form.
    private func parseEverySchedule(_ s: String) -> (n: Int, unit: String)? {
        guard s.hasPrefix("every ") else { return nil }
        let body = s.dropFirst("every ".count)
        let unit = body.last.map { String($0) } ?? ""
        guard ["m", "h", "d"].contains(unit), let n = Int(body.dropLast()) else { return nil }
        return (n, unit)
    }

    /// "M H * * *" or "M H * * dow" → (time, dow?); nil when not a clock form.
    private func parseClockSchedule(_ s: String) -> (time: String, dow: Int?)? {
        let f = s.split(separator: " ").map(String.init)
        guard f.count == 5, f[2] == "*", f[3] == "*", let h = Int(f[1]), h >= 0, h <= 23 else { return nil }
        let mm = f[0].hasPrefix("0") ? String(f[0].dropFirst()) : f[0]
        guard Int(f[0]) != nil || f[0] == "0", mm.count <= 2, Int(mm) != nil, Int(mm)! <= 59 else { return nil }
        let time = String(format: "%02d:%02d", h, Int(mm)!)
        guard f[4] == "*" else {
            guard let dow = Int(f[4]), (0...6).contains(dow) else { return nil }
            return (time, dow)
        }
        return (time, nil)
    }

    /// "09:00" (+ optional dow) → a cron expression in the local zone.
    private func clockCron(_ time: String, dow: Int?) -> String {
        let p = time.split(separator: ":").map(String.init)
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else {
            return ""
        }
        if let dow {
            return "\(m) \(h) * * \(dow)"
        }
        return "\(m) \(h) * * *"
    }

    /// Load the job's recent runs (the per-attempt history) for the detail card.
    func loadRunHistory(_ jobID: String) async {
        let runs = (try? await cronHistory.listRuns(jobID: jobID, limit: 10)) ?? []
        taskRunHistory[jobID] = runs
    }

    func removeJob(_ id: String) async {
        try? await cronStore.delete(id: id)
        await refreshScheduledJobs()
    }

    /// Delete a scheduled task AND its chat session (the chat is owned by the
    /// task and is hidden from the main chat list).
    func deleteJob(_ id: String) async {
        guard let job = settings.scheduledJobs.first(where: { $0.id == id }) else { return }
        let sid = jobSessionID(job)
        try? await cronStore.delete(id: id)
        if tasksSelectedID == id { tasksSelectedID = nil }
        tasksMode = .detail
        taskRunHistory.removeValue(forKey: id)
        await refreshScheduledJobs()
        await confirmDeleteSession(sid)
        // confirmDeleteSession doesn't touch custom titles; drop the task's own
        // chat title so nothing lingers after the task is gone.
        settings.sessionTitles.removeValue(forKey: sid)
        saveSettings()
    }

    /// Select/deselect a scheduled task in the Tasks page. The job's chat
    /// session is materialized so the thread renders in the main pane.
    func selectTaskJob(_ id: String?) async {
        tasksSelectedID = id
        tasksMode = .detail
        if let jobID = id, let job = settings.scheduledJobs.first(where: { $0.id == jobID }) {
            await ensureSessionMessages(jobSessionID(job))
            await loadRunHistory(jobID)
        }
    }

    func toggleJob(_ id: String) async {
        // Route through CronOps, NOT a hand-rolled isActive.toggle(): pause
        // must stamp pausedAt (the category partition keys on it), and
        // CronOps refuses to pause one-shots. A nil job or a refusal is a
        // no-op; refreshScheduledJobs keeps the rows honest either way.
        guard let job = try? await cronStore.get(id: id) else { return }
        do {
            if job.pausedAt != nil {
                _ = try await CronOps.resume(store: cronStore, id: id)
            } else {
                _ = try await CronOps.pause(store: cronStore, id: id, reason: "paused from the scheduled-tasks page")
            }
        } catch {
            Logger(label: "com.arc-agent.webui").warning("toggleJob(\(id)) refused: \(error)")
        }
        await refreshScheduledJobs()
    }

    /// Jobs with a Run-now turn currently executing. The page reads this to
    /// show a Running state and disable the button; it lives on the actor
    /// so the flag and the completion stamp can never disagree.
    func runJobNow(_ id: String) async {
        guard let job = settings.scheduledJobs.first(where: { $0.id == id }),
              !runningCronJobs.contains(id),
              // One run per job at a time — a scheduler firing may already be
              // mid-turn for this job; double-firing would duplicate the turn
              // in the job's chat and its run record.
              await CronRunGate.shared.tryAcquire(id)
        else { return }
        runningCronJobs.insert(id)
        // The turn runs on a child task so the wire handler returns
        // immediately — an inline run blocked the whole fragment pipeline
        // for the job's duration (the whole-app freeze). When it lands,
        // push a structural change so every open page re-renders (the
        // event-driven update): no manual refresh.
        Task {
            await self.finishRunNow(id)
            await self.onBackgroundChange?()
        }
    }

    /// The half of Run-now that runs AFTER the click's fragment round-trip:
    /// executes the turn, stamps the per-attempt record, and clears the
    /// running flag. The handler pushes a structural change afterwards so
    /// every open page re-renders — no manual refresh.
    func finishRunNow(_ id: String) async {
        defer {
            runningCronJobs.remove(id)
            Task { await CronRunGate.shared.release(id) }
        }
        guard let job = settings.scheduledJobs.first(where: { $0.id == id }) else { return }
        let startedAt = Date()
        let text = await runScheduledJob(job)
        let ok = !lastScheduledRunFailed
        // Stamp the full per-attempt record the run history derives from —
        // an updateJob that sets only lastOutput produces a record with a
        // zero startedAt and no status (sorting "runs in a weird way").
        await updateJob(id) { j in
            j.lastStartedAt = startedAt
            j.lastRunAt = startedAt
            j.lastFinishedAt = Date()
            j.lastStatus = ok ? "ok" : "error"
            j.lastError = ok ? nil : (text.hasPrefix("Error: ") ? String(text.dropFirst("Error: ".count)) : text).prefix(500).description
            j.runCount += 1
            j.lastOutput = trunc(text, 240)
            // Re-arm RECURRING schedules only — a one-shot has fired its
            // only moment (the same rule the scheduler applies post-run).
            // The old unconditional CronNext re-armed a one-shot back to
            // its own future instant: the job sat Active forever.
            j.nextRunAt = CronSchedule.isRecurring(j.schedule)
                ? CronNext(expression: j.schedule, from: Date())
                : nil
        }
        await loadRunHistory(id)
    }
}

/// The tool round a scheduled job holds until the next round begins, so one
/// assistant message plus its tool results land as one unit. The same buffer
/// shape `runTurn` keeps; the job path has no live turn to report into.
private struct ScheduledToolRound {
    var content: String
    var reasoning: String
    var calls: [ToolCall] = []
    var results: [(id: String, name: String, result: String)] = []
}

/// Compute the next fire date for a cron expression.
///
/// **Wrapper** — the engine lives in ``CronSchedule`` (ArcAgentCore); the
/// duplicated parser that used to live here (and its `CronField` machinery,
/// which refused `*/15`, `1-5`, `0,30`, and day-of-week names outright, and
/// ANDed dom/dow) is deleted. This shim exists so the web UI keeps its
/// call sites and test signature; it resolves in the daemon's local zone
/// exactly as the old code did.
func CronNext(expression: String, from date: Date) -> Date? {
    CronSchedule.next(expression, after: date)
}

func parseInterval(_ s: String) -> TimeInterval? {
    let s = s.trimmingCharacters(in: .whitespaces)
    let units: [(String, TimeInterval)] = [
        ("m", 60), ("min", 60), ("h", 3600), ("hr", 3600), ("d", 86400),
        ("s", 1),
    ]
    for (suffix, mult) in units {
        if s.hasSuffix(suffix) {
            let num = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let v = Double(num), v > 0 { return v * mult }
        }
    }
    return nil
}

/// The "next" label for a scheduled task's row and detail card.
///
/// A schedule the parser cannot read leaves `nextRunAt` nil forever — the
/// scheduler never fires the job — but the UI rendered that exactly like a
/// spent one-shot or a deliberately stopped task: a bare "—". The dead case
/// now names itself. It is distinguishable without guessing: the job is
/// active, has never run, and the parser refuses its schedule both here
/// (`CronNext`) and in the daemon (`computeNextRun`).
func cronNextLabel(for job: CronJob, format: (Date) -> String, now: Date = Date()) -> String {
    if let next = job.nextRunAt { return format(next) }
    guard job.isActive, job.lastRunAt == nil, job.runCount == 0 else { return "—" }
    if CronNext(expression: job.schedule, from: now) == nil {
        return "schedule can't be parsed"
    }
    return "—"
}

// MARK: - Views for todos + cron panels

extension AppState {

    /// the todos view: the tab switcher (Tasks | Run queue) above whichever tab
    /// is active. this is the `main` region, not a `todos` panel — 17 push
    /// sites address it by that id.
    func todosPanelHTML() -> some WebUI.View {
        migrateLegacyTodosIfNeeded()
        return Div(id: "main", class: .todoPanel) {
            todosTabsHTML()
            if todosTab == .tasks {
                todosTasksHTML()
            } else {
                queuePanelHTML()
            }
        }
    }

    /// the Tasks tab body: this chat's todo list plus the add form.
    func todosTasksHTML() -> some WebUI.View {
        let chat = activeSessionID ?? ""
        let items = todos(for: chat)
        let pending = items.filter { !$0.done }.count
        let done = items.count - pending

        // the rows are materialized up front: a builder cannot take `[some View]`
        var rows: [any WebUI.View] = []
        for t in items {
            rows.append(
                Div(class: ClassName(t.done ? "todo-row done" : "todo-row")) {
                    ArcButton(id: "todo-toggle-\(t.id)", component: nil, class: .todoCheck) {
                        WebUIIcon(.check, size: .small)
                    }
                    .title(t.done ? "Mark not done" : "Mark done")
                    .aria(.label("Toggle"))
                    Span(class: .todoText) { Text(t.text) }
                    ArcButton(id: "todo-run-\(t.id)", component: nil, class: .todoRun) {
                        WebUIIcon(.play, size: .small)
                    }
                    .title("Run in chat")
                    .aria(.label("Run in chat"))
                    ArcButton(id: "todo-del-\(t.id)", component: nil, class: .todoX) {
                        WebUIIcon(.x, size: .small)
                    }
                    .title("Remove")
                    .aria(.label("Remove"))
                }
                .data("tid", t.id)
            )
        }

        let chatLabel: String
        if chat.isEmpty {
            chatLabel = "Open a chat from the sidebar — todos belong to the chat you are using."
        } else if let s = sessions.first(where: { $0.id == chat }) {
            chatLabel = "for “\(sessionTitle(s))”"
        } else {
            chatLabel = "for this chat"
        }

        return Div(class: .todoCard) {
            TodoHead {
                Div {
                    Element(.h2, class: .todoTitle) { Text("Todos") }
                    TodoSub { Text(chatLabel) }
                }
                TodoHeadActions {
                    if done > 0 {
                        ArcButton("Clear done (\(done))", id: "todo-clear-done",
                                  component: nil, class: .ghostBtn)
                            .title("Remove completed todos")
                    }
                    ArcButton(id: "todo-run-all", component: nil, class: .todoRunall) {
                        Span(class: .todoRunallIco) { WebUIIcon(.fastForward, size: .small) }
                        Text("Run all")
                    }
                    .title("Run all open todos in chat")
                    .aria(.label("Run all open todos in chat"))
                    Span(class: .todoPill) { Text("\(pending) open") }
                }
            }
            Div(class: "todo-list") {
                if items.isEmpty {
                    TodoEmpty {
                        TodoEmptyIco { WebUIIcon(.check, size: .extraLarge) }
                        Div { Text(chat.isEmpty ? "Select a chat to see its todos" : "No todos for this chat yet") }
                        Small("Add one below — it stays with this chat.")
                    }
                }
                rows
            }
            Div(class: .todoFoot) {
                // the add form declares the boundary; its field keeps only ids
                // (the engine reports the target, so the submit round-trips).
                Form(action: "", method: nil, id: "todo-add-form", class: .todoAdd) {
                    Input(id: "todo-add-text", name: "todo-text",
                          placeholder: "Add a todo for this chat…", type: .text,
                          attributes: [("autocomplete", "off")])
                        .data("no-restore", "")
                    ArcButton("Add", class: .primaryBtn, type: .submit)
                }
                .data("component-id", "todos")
            }
        }
        .wire("todos")
    }

    /// Scheduled Jobs page — left panel: category tabs, live search, one row
    /// per job in the selected category.

    /// Jobs shown in the sidebar for the selected category, filtered by the
    /// live search draft (case-insensitive against name + prompt contents).
    func filteredJobs() -> [CronJob] {
        let q = tasksSearchDraft.trimmingCharacters(in: .whitespaces).lowercased()
        return settings.scheduledJobs.filter { taskSearchMatches($0, query: q) }
    }

    /// search-only match (name + prompt); category grouping happens per group.
    nonisolated func taskSearchMatches(_ j: CronJob, query q: String) -> Bool {
        q.isEmpty || j.name.lowercased().contains(q) || j.prompt.lowercased().contains(q)
    }

    /// The exclusive lifecycle category of a job, in strict priority order:
    /// failed = LAST attempt errored (beats everything); completed = FULLY
    /// exhausted — every possible run used (budget spent, or a scheduled
    /// job that fired with no next fire); idle = no scheduled start time;
    /// paused = paused by the user (only catches jobs that would otherwise
    /// be Active/Pending); activePending = has a schedule (one-time or
    /// recurring), running or not. See ``AppState.TaskCategory``.
    nonisolated func taskCategory(for j: CronJob) -> AppState.TaskCategory {
        if j.lastStatus == "error" { return .failed }
        let budgetSpent = j.isBudgetSpent
        let firedWithNoNext = j.nextRunAt == nil && j.runCount > 0 && !j.schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if budgetSpent || firedWithNoNext { return .completed }
        if j.schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .idle }
        if j.pausedAt != nil { return .paused }
        return .activePending
    }

    /// Prefix a stored error with "Error: " exactly once — failure text can
    /// arrive from several stampers and some already carry the prefix.
    static func prefixError(_ raw: String, _ limit: Int) -> String {
        let body = raw.hasPrefix("Error: ") ? String(raw.dropFirst("Error: ".count)) : raw
        return "Error: \(trunc(body, limit))"
    }

    /// Server-side mirror of the per-category button matrix: a stale render
    /// or hand-crafted event cannot perform a verb the state no longer
    /// allows. Duplicate/delete are always permitted.
    func cronVerbAllowed(_ verb: String, _ id: String) -> Bool {
        guard let job = settings.scheduledJobs.first(where: { $0.id == id }) else { return false }
        let cat = taskCategory(for: job)
        switch verb {
        case "run": return cat == .activePending || cat == .idle
        case "toggle": return !job.isOneShot && (cat == .activePending || cat == .paused)
        case "edit": return cat != .completed && cat != .failed
        default: return true
        }
    }

    func taskCategoryCount(_ c: AppState.TaskCategory) -> Int {
        settings.scheduledJobs.filter { taskCategory(for: $0) == c }.count
    }

    func taskStatusLabel(_ j: CronJob) -> String {
        // Tags mirror the category — "completed" only ever appears for a
        // fully exhausted job. There is no "running" tag: a running job is
        // marked by the loading border on its row card instead.
        switch taskCategory(for: j) {
        case .failed: return "failed"
        case .completed: return "completed"
        case .idle: return "idle"
        case .paused: return "paused"
        case .activePending: return j.runCount == 0 ? "pending" : "active"
        }
    }

    func tasksPanel() -> some WebUI.View {
        // the boundary lives on the containers; the controls keep only ids, or
        // the engine never reports them (id + data-component-id on one element
        // is a dead control — the click identity contract).
        let cats: [(AppState.TaskCategory, String)] = [
            (.activePending, "Active/Pending"), (.idle, "Idle"), (.paused, "Paused"), (.failed, "Failed"), (.completed, "Completed"),
        ]
        let groups: [any WebUI.View] = cats.map { c in
            let open = taskExpanded.contains(c.0.rawValue)
            let q = tasksSearchDraft.trimmingCharacters(in: .whitespaces).lowercased()
            let rows: [any WebUI.View] = settings.scheduledJobs
                .filter { taskCategory(for: $0) == c.0 && taskSearchMatches($0, query: q) }
                .map { taskRowHTML($0) }
            return Div(class: .taskGroup) {
                ArcButton(id: "task-grp-\(c.0.rawValue)", component: nil, class: .taskGroupHead) {
                    WebUIIcon(open ? .chevronDown : .chevronRight, size: .small)
                    Text("\(c.1.uppercased()) (\(taskCategoryCount(c.0)))")
                }
                if open {
                    if !rows.isEmpty {
                        Div(class: .taskList) { rows }
                            .wire("tasks")
                    }
                    // An empty group renders nothing inside — just the
                    // collapsed-able header with its (0) count.
                }
            }
            .wire("tasks")
        }
        return Group {
            PanelHead {
                PanelTitle { Text("Scheduled Jobs") }
                PanelActions {
                    ArcButton(id: "task-refresh", component: nil, class: .plusBtn) {
                        WebUIIcon(.refreshCw, size: .medium)
                    }
                    .title("Refresh jobs")
                    ArcButton(id: "task-new", component: nil, class: .plusBtn) {
                        WebUIIcon(.plus, size: .medium)
                    }
                    .title("New scheduled job")
                }
            }
            .wire("tasks")
            PanelBody {
                Div(class: .taskSearch) {
                    Input(field: "task-search", placeholder: "Filter jobs by name or prompt…")
                        .wire("task-search", on: .input)
                        .attribute("spellcheck", "false")
                        .attribute("autocomplete", "off")
                }
                // groups always render; an empty group is just its header —
                // no filler body.
                Div(class: .taskGroups) { groups }
            }
        }
    }

    /// one scheduled job as a chat-list row. internal (not private) so the
    /// parity harness can pin it in isolation.
    func taskRowHTML(_ j: CronJob) -> some WebUI.View {
        let active = j.id == tasksSelectedID ? " active" : ""
        let running = runningCronJobs.contains(j.id) ? " task-running" : ""
        let status = taskStatusLabel(j)
        return ArcButton(id: "task-open-\(j.id)", component: nil, class: ClassName("task-row\(active)\(running)")) {
            Span(class: .taskRi) {
                Span(class: .taskRname) { Text(j.name) }
            }
            Span(class: .chip) { Text(j.profile ?? "default") }
            Span(class: .chip) { Text(status) }.data("st", status)
        }
        .title("\(j.schedule) · next \(cronNextLabel(for: j, format: fmtRel))")
    }

    /// Scheduled Jobs page — main pane: the selected job's detail + chat, the
    /// add form (sidebar “+”), or the edit form.
    func tasksMain() -> some WebUI.View {
        Group {
            if tasksMode == .add {
                taskFormPage(title: "New scheduled job", submitLabel: "Schedule job", job: nil)
            } else if tasksMode == .edit,
                      let sel = tasksSelectedID,
                      let job = settings.scheduledJobs.first(where: { $0.id == sel }) {
                taskFormPage(title: "Edit job", submitLabel: "Save changes", job: job)
            } else if let sel = tasksSelectedID,
                      let job = settings.scheduledJobs.first(where: { $0.id == sel }) {
                tasksMainBody(job)
            } else {
                taskMainEmpty()
            }
        }
    }

    /// the selected job's top bar (name left, actions right) + detail cards +
    /// its chat. one concrete return type so the builder sees a single view.
    private func tasksMainBody(_ job: CronJob) -> some WebUI.View {
        let sid = jobSessionID(job)
        let msgs = sessions.first(where: { $0.id == sid })?.messages ?? []
        let exhausted = job.nextRunAt == nil
        let next = cronNextLabel(for: job, format: fmtRel)
        let last = job.lastRunAt.map { fmtRel($0) } ?? "never"
        let out = job.lastOutput.map { trunc($0, 160) } ?? job.lastError.map { Self.prefixError($0, 140) } ?? "—"
        // One-shots cannot pause (one fire — nothing to pause); a spent
        // Per-category ability matrix: which verbs a lifecycle state allows.
        // completed/failed = terminal, dup+delete only; paused = no new run;
        // pending/idle = not yet pausable (nothing in flight or scheduled to
        // pause). The op layer enforces the hard invariants; this mirrors it.
        let cat = taskCategory(for: job)
        let canPause = !job.isOneShot && (cat == .activePending || cat == .paused)
        let canRun = (cat == .activePending || cat == .idle)
            && (!job.isBudgetSpent || job.lastStatus == "error")
        let canEdit = cat != .completed && cat != .failed
        let toggleLabel = job.isActive ? "Pause" : "Resume"
        let topbar = Div(class: .taskTopbar) {
            Div(class: .taskTopname) {
                Text(job.name)
            }
            RowActionsMain {
                let running = runningCronJobs.contains(job.id)
                ArcButton(id: "task-now-\(job.id)", component: nil, class: canRun && !running ? "ghost-btn" : "ghost-btn disabled") {
                    WebUIIcon(.skipForward, size: .small)
                }.title(running ? "Running…" : (canRun ? "Run now" : (cat == .completed ? "Completed — nothing to run" : cat == .failed ? "Failed — fix or delete the job" : "Run budget spent")))
                if canPause {
                    ArcButton(id: "task-toggle-\(job.id)", component: nil, class: .ghostBtn) {
                        WebUIIcon(job.pausedAt != nil ? .play : .pause, size: .small)
                    }.title(toggleLabel)
                }
                if canEdit {
                    ArcButton(id: "task-edit-\(job.id)", component: nil, class: .ghostBtn) {
                        WebUIIcon(.edit, size: .small)
                    }.title("Edit")
                }
                ArcButton(id: "task-dup-\(job.id)", component: nil, class: .ghostBtn) {
                    WebUIIcon(.copy, size: .small)
                }.title("Duplicate")
                ArcButton(id: "task-del-\(job.id)", component: nil, class: ClassName(.iconMini, .danger)) {
                    WebUIIcon(.trash2, size: .small)
                }
                .title("Delete job and its chat")
            }
            .margin(0)
            .wire("tasks")
        }
        let banner = Div(class: .taskBanner) {
            Element(.h3) { Text("Prompt") }
            Text(trunc(job.prompt, 240))
        }
        let ctrl = Div(class: ClassName(.detailCard, .taskCtrlCard)) {
            TaskCtrlLine {
                TaskCtrlKey { Text("Status") }
                TaskCtrlVal {
                    let st = taskStatusLabel(job)
                    Span(class: .chip) { Text(st) }.data("st", st)
                }
            }
            TaskCtrlLine {
                TaskCtrlKey { Text("Schedule") }
                TaskCtrlVal { Text(job.schedule) }
            }
            TaskCtrlLine {
                TaskCtrlKey { Text("Next run") }
                TaskCtrlVal { Text(exhausted ? "—" : next) }
            }
            TaskCtrlLine {
                TaskCtrlKey { Text("Last run") }
                TaskCtrlVal { Text(last) }
            }
            TaskCtrlLine {
                TaskCtrlKey { Text("Deliver to") }
                TaskCtrlVal { Text(job.deliver ?? "Local (this job's chat only)") }
            }
            TaskCtrlLine {
                TaskCtrlKey { Text("Profile") }
                TaskCtrlVal { Text(job.profile ?? "Server default") }
            }
            TaskCtrlLine {
                TaskCtrlKey { Text("Runs") }
                TaskCtrlVal {
                    if let budget = job.runBudget {
                        Text("\(job.runCount) of \(budget) — \(job.runsRemaining ?? budget) remaining")
                    } else {
                        Text("\(job.runCount) run\(job.runCount == 1 ? "" : "s")")
                    }
                }
            }
            TaskCtrlLine {
                TaskCtrlKey { Text("Last output") }
                TaskCtrlVal { Text(out) }
            }
        }
        let runs = taskRunHistory[job.id] ?? []
        let histRows: [any WebUI.View] = runs.map { r in
            let st = r.status ?? "ok"
            return Div(class: .taskHistRow) {
                Span(class: .taskHistTime) { Text(fmtRel(r.startedAt)) }
                Span(class: .taskHistStatus) { Text(st) }.data("st", st)
                Span(class: .taskHistOut) {
                    Text(r.error.map { Self.prefixError($0, 140) } ?? trunc(r.output, 160))
                }
            }
        }
        let hist = Div(class: ClassName(.detailCard, .taskHistCard)) {
            Element(.h3) { Text("Recent runs") }.margin(.bottom, .three)
            if histRows.isEmpty {
                Element(.p, class: .taskPreview) {
                    Text("No recorded runs yet — runs appear here as they fire.")
                }
            } else {
                Div(class: .taskHist) { histRows }
            }
        }
        // an empty job chat is noise — show nothing until the job has run
        let thread: [any WebUI.View] = msgs.isEmpty ? [] : [Div(class: .taskThread) {
            ChatScroll {
                // copy-only: a task thread has no session identity the chat
                // panel could open, so the fork action is not offered here.
                ChatInner { messagesHTML(msgs) }
                    .id("task-chat-inner")
            }
            .id("task-chat-scroll")
            .data("scroll-key", "tasks-thread")
        }]
        return Group {
            Div(class: ClassName(.mainView, .tasksMainView)) {
                MainScroll {
                    Div(class: .tasksMainWrap) {
                        topbar
                        banner
                        ctrl
                        hist
                        thread
                    }
                }
            }
        }
    }

    func taskMainEmpty() -> some WebUI.View {
        MainView {
            MainScroll {
                Element(.h2, class: .todoTitle) { Text("Scheduled jobs") }
                Element(.p, class: .todoSub) {
                    Text("Pick a job on the left to see its details and chat, or use “+” to schedule a new one. Each job gets its own chat, kept out of the main list.")
                }
            }
            .data("scroll-key", "tasks-main")
        }
    }

    /// The add / edit form. One field set for both modes: `job == nil` renders
    /// the add form, a job prefills every control (the schedule draft is kept
    /// on the actor and driven by the fields' change events, so the cron
    /// preview stays live as the user edits).
    func taskFormPage(title: String, submitLabel: String, job: CronJob?) -> some WebUI.View {
        let expr = taskScheduleExpression()
        let profileOpts: [SelectOption] = [SelectOption(value: "", label: "Server default")] +
            profiles.map { SelectOption(value: $0.name, label: $0.title.isEmpty ? $0.name : $0.title) }
        return MainView {
            MainScroll {
                // a real form: Enter in any field submits, and the boundary on the
                // form is what routes that submit to the cron handler. the field
                // basis layout (`task-add-row` / `task-field`) is a css pin.
                Form(action: "", method: nil, id: "task-form", class: .taskAdd) {
                    // Which job the form edits, carried in the payload — not
                    // in actor mode state. A mode reset (reload, a stray
                    // re-select) between opening the form and submitting used
                    // to fall the submit through to addJob: a duplicate.
                    Input(field: "task-edit-id", type: .hidden, value: job?.id ?? "")
                    Div(class: .taskFormTop) {
                        Element(.h2, class: .todoTitle) { Text(title) }
                        RowActionsMain {
                            ArcButton(id: "task-cancel", component: nil, class: .ghostBtn) {
                                WebUIIcon(.x, size: .small)
                            }.title("Cancel")
                            ArcButton(id: "task-submit", component: nil,
                                      class: .primaryBtn, type: .submit) {
                                WebUIIcon(.check, size: .small)
                            }.title("Save job")
                        }
                        .margin(0)
                        .wire("tasks")
                    }
                    FieldLabel(class: .taskField) {
                        Text("Name")
                        Span(class: .taskOpt) { Text("optional — defaults to Untitled job") }
                        Input(field: "task-name", placeholder: "Optional",
                              value: job?.name ?? "", attributes: [("autocomplete", "off")])
                    }
                        FieldLabel(class: .taskField) {
                            Text("Job kind")
                            Span(class: .taskSched) {
                                Select(field: "task-kind", options: [
                                    SelectOption(value: "recurring", label: "Recurring (cron / interval)"),
                                    SelectOption(value: "oneshot", label: "One-shot (runs once)"),
                                    SelectOption(value: "manual", label: "Run anytime (no schedule)"),
                                ], selected: taskJobKind)
                                    .wire("task-kind", on: .change)
                            }
                            Element(.p, class: .taskPreview) {
                                Text(taskJobKind == "oneshot"
                                    ? "Fires once — at the instant below or via Run now — then completes. Cannot be paused."
                                    : taskJobKind == "manual"
                                    ? "Never fires on its own — runs when you press Run now."
                                    : "Fires on the schedule below, forever.")
                            }
                        }
                        if taskJobKind == "oneshot" {
                            FieldLabel(class: .taskField) {
                                Text("When (ISO instant)")
                                Input(field: "task-when", placeholder: "2026-06-01T09:00:00",
                                      value: taskSchedWhen, attributes: [("autocomplete", "off")])
                                    .wire("task-when", on: .change)
                                Element(.p, class: .taskPreview) {
                                    Text(taskSchedWhen.isEmpty
                                        ? "Leave empty to arm only via Run now."
                                        : "Time is server time; an instant in the past is valid but already due.")
                                }
                            }
                        } else if taskJobKind == "recurring" {
                            FieldLabel(class: .taskField) {
                                Text("Schedule")
                            Span(class: .taskSched) {
                                Select(field: "task-preset", options: [
                                    SelectOption(value: "every", label: "Every …"),
                                    SelectOption(value: "daily", label: "Daily at time"),
                                    SelectOption(value: "weekly", label: "Weekly on weekday"),
                                    SelectOption(value: "custom", label: "Custom cron"),
                                ], selected: taskSchedPreset)
                                    .wire("task-sched-preset", on: .change)
                                if taskSchedPreset == "every" {
                                    Span(class: .taskEvery) {
                                        Input(field: "task-every", type: .number, value: taskSchedEvery,
                                              attributes: [("min", "1"), ("step", "1")])
                                            .wire("task-sched-every", on: .change)
                                        Select(field: "task-unit", options: [
                                            SelectOption(value: "m", label: "minutes"),
                                            SelectOption(value: "h", label: "hours"),
                                            SelectOption(value: "d", label: "days"),
                                        ], selected: taskSchedUnit)
                                            .wire("task-sched-unit", on: .change)
                                    }
                                } else if taskSchedPreset == "daily" {
                                    Input(field: "task-time", type: .time, value: taskSchedTime)
                                        .wire("task-sched-time", on: .change)
                                } else if taskSchedPreset == "weekly" {
                                    Span(class: .taskEvery) {
                                        Select(field: "task-dow", options: [
                                            SelectOption(value: "0", label: "Sunday"),
                                            SelectOption(value: "1", label: "Monday"),
                                            SelectOption(value: "2", label: "Tuesday"),
                                            SelectOption(value: "3", label: "Wednesday"),
                                            SelectOption(value: "4", label: "Thursday"),
                                            SelectOption(value: "5", label: "Friday"),
                                            SelectOption(value: "6", label: "Saturday"),
                                        ], selected: taskSchedDow)
                                            .wire("task-sched-dow", on: .change)
                                        Input(field: "task-time", type: .time, value: taskSchedTime)
                                            .wire("task-sched-time", on: .change)
                                    }
                                } else {
                                    Input(field: "task-custom", placeholder: "0 9 * * 1-5",
                                          value: taskSchedCustom)
                                        .wire("task-sched-custom", on: .change)
                                }
                            }
                            Element(.p, class: .taskPreview) {
                                Text(expr.isEmpty
                                    ? "Enter a cron expression (minute hour day month weekday)."
                                    : "\(expr) · Time is server time; cron runs server-side.")
                            }
                            }
                        }
                        FieldLabel(class: .taskField) {
                            Text("Prompt")
                            TextArea(field: "task-prompt",
                                     placeholder: "What should the agent run?",
                                     value: job?.prompt ?? "", rows: 4)
                        }
                        FieldLabel(class: .taskField) {
                            Text("Deliver output to")
                            Select(field: "task-deliver-preset", options: [
                                SelectOption(value: "local", label: "Local (save output only)"),
                                SelectOption(value: "custom", label: "Custom target…"),
                            ], selected: taskDeliverPreset)
                                .wire("task-deliver-preset", on: .change)
                            if taskDeliverPreset == "custom" {
                                Input(field: "task-deliver", placeholder: "e.g. telegram:12345678",
                                      value: job?.deliver ?? "", attributes: [("autocomplete", "off")])
                            }
                        }
                        FieldLabel(class: .taskField) {
                            Text("Profile")
                            Select(field: "task-profile", options: profileOpts,
                                   selected: job?.profile ?? "")
                            Span(class: .taskOpt) {
                                Text("Runs under the server default profile when unset.")
                            }
                        }
                    }
                    .data("component-id", "tasks")
            }
            .data("scroll-key", "tasks-main")
        }
    }

    func fmtRel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Controller wires (todos, cron, regenerate)

@WireGroup("todos")
extension Controller {

    @Wired("todos", events: [.click, .submit])
    func handleTodos(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            let text = event.string("todo-text") ?? ""
            await self.app.addTodo(text)
            return await self.changed()
        }
        guard let tid = event.string("targetId") else { return [] }
        // Clicks on the add-todo text field/form are cursor placement, not
        // actions — never re-render from them (that would wipe the draft).
        if tid.hasPrefix("todo-add") { return [] }
        if tid.hasPrefix("todo-toggle-") {
            await self.app.toggleTodo(String(tid.dropFirst("todo-toggle-".count)))
        } else if tid.hasPrefix("todo-del-") {
            await self.app.removeTodo(String(tid.dropFirst("todo-del-".count)))
        } else if tid == "todo-run-all" {
            let ids = await self.app.openTodoIDs()
            let texts = await self.app.openTodoTexts()
            guard !texts.isEmpty else {
                _ = await self.app.hint("No open todos to run.")
                return await self.changed()
            }
            // Running the set marks them done.
            await self.app.markTodosDone(ids)
            let prompt = texts.joined(separator: "\n")
            await self.app.switchView(.chat)
            return await self.submitChat(text: prompt)
        } else if tid.hasPrefix("todo-run-") {
            let id = String(tid.dropFirst("todo-run-".count))
            if let text = await self.app.todoText(for: id) {
                // Running a todo marks it done.
                await self.app.markTodosDone([id])
                // Run the todo as a real chat message: switch to the Chat
                // view and submit through the normal composer path.
                await self.app.switchView(.chat)
                return await self.submitChat(text: text)
            }
        } else if tid.hasPrefix("todo-clear-done") {
            await self.app.clearDoneTodos()
        }
        return await self.changed()
    }
}

@WireGroup("cron")
extension Controller {

    @Wired("tasks", events: [.click, .submit])
    func handleCron(_ event: EventData) async -> [FragmentUpdate] {
        if event.event == "submit" {
            // The name/prompt/deliver/profile ride the submit payload; the
            // schedule fields live in the actor draft (kept current by the
            // change wires below), so the preview the user saw is the
            // schedule that is saved.
            let name = event.string("task-name") ?? ""
            let prompt = event.string("task-prompt") ?? ""
            let preset = await self.app.taskDeliverPreset
            let deliver = preset == "custom" ? (event.string("task-deliver") ?? "") : ""
            let profile = event.string("task-profile") ?? ""
            let schedule = await self.app.taskScheduleExpression()
            let kind = await self.app.taskJobKind
            let runBudget: Int? = kind == "oneshot" ? 1 : nil
            // The edit target rides the form payload (hidden field), not
            // actor mode state — a mode reset between opening the form and
            // submitting used to fall through to addJob (the duplicate bug).
            let editID = event.string("task-edit-id") ?? ""
            let mode = await self.app.tasksMode
            if !editID.isEmpty {
                await self.app.editJob(editID, name: name, schedule: schedule, prompt: prompt,
                                       deliver: deliver, profile: profile, runBudget: runBudget)
            } else if mode == .edit, let sel = await self.app.tasksSelectedID {
                await self.app.editJob(sel, name: name, schedule: schedule, prompt: prompt,
                                       deliver: deliver, profile: profile, runBudget: runBudget)
            } else {
                let n = name.isEmpty ? "Untitled job" : name
                if let id = await self.app.addJob(name: n, schedule: schedule, prompt: prompt,
                                                  deliver: deliver, profile: profile, runBudget: runBudget) {
                    await self.app.selectTaskJob(id)
                }
            }
            return await self.changed()
        }
        guard let tid = event.string("targetId") else { return [] }
        if tid == "task-new" {
            await self.app.openTaskAdd()
        } else if tid == "task-refresh" {
            await self.app.refreshScheduledJobs()
        } else if tid.hasPrefix("task-grp-") {
            await self.app.toggleTaskGroup(String(tid.dropFirst("task-grp-".count)))
        } else if tid == "task-cancel" {
            await self.app.closeTaskForm()
        } else if tid.hasPrefix("task-cat-") {
            await self.app.setTasksCategory(String(tid.dropFirst("task-cat-".count)))
        } else if tid.hasPrefix("task-open-") {
            await self.app.selectTaskJob(String(tid.dropFirst("task-open-".count)))
        } else if tid.hasPrefix("task-edit-") {
            let id = String(tid.dropFirst("task-edit-".count))
            guard await self.app.cronVerbAllowed("edit", id) else { return await self.changed() }
            await self.app.openTaskEdit(id)
        } else if tid.hasPrefix("task-dup-") {
            await self.app.duplicateJob(String(tid.dropFirst("task-dup-".count)))
        } else if tid.hasPrefix("task-toggle-") {
            let id = String(tid.dropFirst("task-toggle-".count))
            guard await self.app.cronVerbAllowed("toggle", id) else { return await self.changed() }
            await self.app.toggleJob(id)
        } else if tid.hasPrefix("task-now-") {
            // Event-driven Run now: runJobNow arms + flags + spawns the turn
            // off-path; the changed() below re-renders to Running immediately,
            // and the completion push arrives via the change door when the
            // turn lands. Nothing here awaits the turn.
            let runID = String(tid.dropFirst("task-now-".count))
            guard await self.app.cronVerbAllowed("run", runID) else { return await self.changed() }
            await self.app.runJobNow(runID)
        } else if tid.hasPrefix("task-del-") {
            await self.app.deleteJob(String(tid.dropFirst("task-del-".count)))
        }
        return await self.changed()
    }

    // Schedule-editor change wires: each field keeps the actor draft in sync
    // so the live cron preview (and the submit) always match what is shown.
    // Change events do not carry a targetId — the field is the component — so
    // one wire per field identity.

    @Wired("task-kind", events: [.change])
    func handleTaskKind(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskJobKind(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-when", events: [.change])
    func handleTaskWhen(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskSchedWhen(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-sched-preset", events: [.change])
    func handleSchedPreset(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskSchedPreset(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-sched-every", events: [.change])
    func handleSchedEvery(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskSchedEvery(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-sched-unit", events: [.change])
    func handleSchedUnit(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskSchedUnit(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-sched-time", events: [.change])
    func handleSchedTime(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskSchedTime(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-sched-dow", events: [.change])
    func handleSchedDow(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskSchedDow(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-sched-custom", events: [.change])
    func handleSchedCustom(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskSchedCustom(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-search", events: [.input])
    func handleTaskSearch(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTasksSearch(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("task-deliver-preset", events: [.change])
    func handleDeliverPreset(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setTaskDeliverPreset(event.string("value") ?? "local")
        return await self.changed()
    }
}

@WireGroup("regen")
extension Controller {

    @Wired("regen", events: [.click])
    func handleRegen(_ event: EventData) async -> [FragmentUpdate] {
        // Two controls share this boundary: the per-message button names its turn
        // (`regen-<session>.<index>`) and the chat header's `#regen-btn` carries
        // no targetId at all. Requiring one left the header button inert — the
        // click reached the server and was answered with nothing, with no error
        // on either side. Both mean "redo this chat's last reply", so only a
        // foreign targetId is refused.
        if let tid = event.string("targetId"), !tid.hasPrefix("regen-") { return [] }
        guard let lastUser = await self.app.regenText() else { return [] }
        return await self.submitChat(text: lastUser)
    }
}

extension AppState {
    /// The text of the most recent user message (for the Regenerate control).
    /// Returns nil while a turn is running or when no user message exists.
    func regenText() async -> String? {
        guard let s = activeSession(), activeTurns[s.id] == nil else { return nil }
        await ensureSessionMessages(s.id)
        guard let lastUser = s.messages.reversed().first(where: { $0.role == .user }) else { return nil }
        return lastUser.content
    }

    /// Describe an attached image with the active (vision-capable) model and
    /// return a compact description. Empty string when unavailable.
    func describeImage(at path: String) async -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty else { return "" }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "heic", "heif": mime = "image/heic"
        default: mime = "image/jpeg"
        }
        let b64 = data.base64EncodedString()
        guard let preset = settings.modelConfig(named: configName(for: activeSessionID)),
              let hc = httpClient else { return "" }
        let base = preset.baseURL
        guard !base.isEmpty else { return "" }
        let urlStr = base.hasSuffix("/v1") ? base + "/chat/completions" : base + "/v1/chat/completions"
        guard URL(string: urlStr) != nil else { return "" }
        let body: [String: Any] = [
            "model": preset.model,
            "max_tokens": 640,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(b64)"]],
                    ["type": "text", "text": "Describe this image in detail: text, code, UI, data tables, diagrams, and anything an agent without vision would need. Be factual, 60-120 words."]
                ]
            ]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return "" }
        var req = HTTPClientRequest(url: urlStr)
        req.method = .POST
        req.headers.add(name: "Content-Type", value: "application/json")
        let key = preset.apiKey
        if !key.isEmpty {
            req.headers.add(name: "Authorization", value: "Bearer \(key)")
        }
        req.body = .bytes(ByteBuffer(data: bodyData))
        do {
            let resp = try await hc.execute(req, timeout: .seconds(120))
            guard let buf = try? await resp.body.collect(upTo: 1_048_576) else { return "" }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer: buf)) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any] else { return "" }
            let text = (msg["content"] as? String) ?? (msg["reasoning"] as? String) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
}
