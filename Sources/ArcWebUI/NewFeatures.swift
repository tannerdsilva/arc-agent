import ArcAgentCore
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
            profileContext: profileContext(for: sid),
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
                case .toolCallStarted, .toolCallFinished, .compressing:
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
        return finalText
    }

    /// The retired job loop's own ceiling: 25 LLM rounds per run. The core's
    /// `maxIterations` counts the same unit (one loop iteration per model call),
    /// so the cap means what it meant before the runner moved onto the engine.
    static let scheduledJobIterations = 25

    func jobSessionID(_ job: CronJob) -> String { "Cron-\(job.id)" }

    /// Persist a job mutation through the cron store (the single source of
    /// truth) and refresh the render cache.
    private func updateJob(_ id: String, _ mutate: (inout CronJob) -> Void) async {
        guard var job = settings.scheduledJobs.first(where: { $0.id == id }) else { return }
        mutate(&job)
        try? await cronStore.save(job)
        await refreshScheduledJobs()
    }

    func addJob(name: String, schedule: String, prompt: String, firstRun: Date? = nil) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !s.isEmpty, !p.isEmpty else { return }
        var job = CronJob(name: n, schedule: s, prompt: p)
        // First run = the user's chosen start time (defaults to the next
        // interval tick); subsequent runs are computed from the schedule.
        job.nextRunAt = firstRun ?? CronNext(expression: job.schedule, from: Date())
        job.lastOutput = nil
        try? await cronStore.save(job)
        await refreshScheduledJobs()
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
        if let jobID = id, let job = settings.scheduledJobs.first(where: { $0.id == jobID }) {
            await ensureSessionMessages(jobSessionID(job))
        }
    }

    func toggleJob(_ id: String) async {
        await updateJob(id) { job in
            job.isActive.toggle()
            if job.isActive {
                // Start = begin at the next start time (now + interval), then
                // keep firing every interval.
                if job.nextRunAt == nil || job.nextRunAt! <= Date() {
                    job.nextRunAt = CronNext(expression: job.schedule, from: Date())
                }
            }
        }
    }

    func runJobNow(_ id: String) async {
        guard let job = settings.scheduledJobs.first(where: { $0.id == id }) else { return }
        let text = await runScheduledJob(job)
        await updateJob(id) { j in
            j.lastRunAt = Date()
            j.runCount += 1
            j.lastOutput = trunc(text, 240)
            if let next = CronNext(expression: j.schedule, from: Date()) {
                j.nextRunAt = next
            }
        }
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

/// Compute the next fire date for a cron expression (supports "30m",
/// "every 2h", "0 9 * * *", and ISO timestamps).
func CronNext(expression: String, from date: Date) -> Date? {
    let cal = Calendar.current
    let expr = expression.trimmingCharacters(in: .whitespacesAndNewlines)
    if let iso = ISO8601DateFormatter().date(from: expr), iso > date { return iso }
    if expr.hasPrefix("every ") {
        let rest = expr.dropFirst("every ".count)
        if let interval = parseInterval(String(rest)) { return date.addingTimeInterval(interval) }
    }
    if let interval = parseInterval(expr) { return date.addingTimeInterval(interval) }
    // Cron 5-field: "m h dom mon dow"
    let fields = expr.split(separator: " ").map(String.init)
    guard fields.count == 5 else { return nil }
    var comps = DateComponents()
    comps.minute = Int(fields[0])
    comps.hour = Int(fields[1])
    comps.day = Int(fields[2])
    comps.month = Int(fields[3])
    comps.weekday = Int(fields[4])
    return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
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

// MARK: - Views for todos + cron panels

extension AppState {

    /// the todos view: the tab switcher (Tasks | Run queue) above whichever tab
    /// is active. this is the `main` region, not a `todos` panel — 17 push
    /// sites address it by that id.
    func todosPanelHTML() -> some WebUI.View {
        migrateLegacyTodosIfNeeded()
        return Div(id: "main", class: "todo-panel") {
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
                Div(class: t.done ? "todo-row done" : "todo-row") {
                    ArcButton(id: "todo-toggle-\(t.id)", component: nil, class: "todo-check") {
                        WebUIIcon(.check, size: .small)
                    }
                    .title(t.done ? "Mark not done" : "Mark done")
                    .aria(.label("Toggle"))
                    Span(class: "todo-text") { Text(t.text) }
                    ArcButton(id: "todo-run-\(t.id)", component: nil, class: "todo-run") {
                        WebUIIcon(.play, size: .small)
                    }
                    .title("Run in chat")
                    .aria(.label("Run in chat"))
                    ArcButton(id: "todo-del-\(t.id)", component: nil, class: "todo-x") {
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

        return Div(class: "todo-card") {
            Div(class: "todo-head") {
                Div {
                    Element(.h2, class: "todo-title") { Text("Todos") }
                    Div(class: "todo-sub") { Text(chatLabel) }
                }
                Div(class: "todo-head-actions") {
                    if done > 0 {
                        ArcButton("Clear done (\(done))", id: "todo-clear-done",
                                  component: nil, class: "ghost-btn")
                            .title("Remove completed todos")
                    }
                    ArcButton(id: "todo-run-all", component: nil, class: "todo-runall") {
                        Span(class: "todo-runall-ico") { WebUIIcon(.fastForward, size: .small) }
                        Text("Run all")
                    }
                    .title("Run all open todos in chat")
                    .aria(.label("Run all open todos in chat"))
                    Span(class: "todo-pill") { Text("\(pending) open") }
                }
            }
            Div(class: "todo-list") {
                if items.isEmpty {
                    Div(class: "todo-empty") {
                        Div(class: "todo-empty-ico") { WebUIIcon(.check, size: .extraLarge) }
                        Div { Text(chat.isEmpty ? "Select a chat to see its todos" : "No todos for this chat yet") }
                        Small("Add one below — it stays with this chat.")
                    }
                }
                rows
            }
            Div(class: "todo-foot") {
                // the add form declares the boundary; its field keeps only ids
                // (the engine reports the target, so the submit round-trips).
                Form(action: "", method: nil, id: "todo-add-form", class: "todo-add") {
                    Input(id: "todo-add-text", name: "todo-text",
                          placeholder: "Add a todo for this chat…", type: .text,
                          attributes: [("autocomplete", "off")])
                        .data("no-restore", "")
                    ArcButton("Add", class: "primary-btn", type: .submit)
                }
                .data("component-id", "todos")
            }
        }
        .wire("todos")
    }

    /// Scheduled Tasks page — left panel: one chat row per scheduled task.
    func tasksPanel() -> some WebUI.View {
        // the boundary lives on the containers; the controls keep only ids, or
        // the engine never reports them (id + data-component-id on one element
        // is a dead control — the click identity contract).
        let rows: [any WebUI.View] = settings.scheduledJobs.map { taskRowHTML($0) }
        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Scheduled Tasks") }
                Div(class: "panel-actions") {
                    ArcButton(id: "task-new", component: nil, class: "plus-btn") {
                        WebUIIcon(.plus, size: .medium)
                    }
                    .title("New scheduled task")
                }
            }
            .wire("tasks")
            Div(class: "panel-body") {
                if rows.isEmpty {
                    Div(class: "panel-note") {
                        Text("No scheduled tasks yet. Create one to run a prompt on a schedule — each task gets its own chat (kept out of the main chat list).")
                    }
                } else {
                    Div(class: "task-list") { rows }
                        .wire("tasks")
                }
            }
        }
    }

    /// one scheduled task as a chat-list row. internal (not private) so the
    /// parity harness can pin it in isolation.
    func taskRowHTML(_ j: CronJob) -> some WebUI.View {
        let active = j.id == tasksSelectedID ? " active" : ""
        let dot = j.isActive ? " on" : ""
        let next = j.nextRunAt.map { fmtRel($0) } ?? "—"
        let runs = j.runCount > 0 ? " · \(j.runCount) run\(j.runCount == 1 ? "" : "s")" : ""
        return ArcButton(id: "task-open-\(j.id)", component: nil, class: "task-row\(active)") {
            Span(class: "task-dot\(dot)") { Text("●") }
            Span(class: "task-ri") {
                Span(class: "task-rname") { Text(j.name) }
                Span(class: "task-rmeta") { Text("\(j.schedule) · next \(next)\(runs)") }
            }
        }
    }

    /// Scheduled Tasks page — main pane: selected task's controls + its chat,
    /// or the create form when nothing is selected.
    func tasksMain() -> some WebUI.View {
        Group {
            if let sel = tasksSelectedID,
               let job = settings.scheduledJobs.first(where: { $0.id == sel }) {
                tasksMainBody(job)
            } else {
                taskMainEmpty()
            }
        }
    }

    /// the selected task's controls + chat. one concrete return type so the
    /// builder sees a single view, never an opaque branch.
    private func tasksMainBody(_ job: CronJob) -> some WebUI.View {
        let sid = jobSessionID(job)
        let msgs = sessions.first(where: { $0.id == sid })?.messages ?? []
        let status = job.isActive ? "Active" : "Stopped"
        let statusCls = job.isActive ? "on" : "off"
        let next = job.nextRunAt.map { fmtRel($0) } ?? "—"
        let last = job.lastRunAt.map { fmtRel($0) } ?? "never"
        let out = job.lastOutput.map { trunc($0, 160) } ?? "—"
        let toggleLabel = job.isActive ? "Stop" : "Start"
        let ctrl = Div(class: "detail-card task-ctrl-card") {
            Div(class: "task-ctrl-head") {
                Div(class: "task-ctrl-main") {
                    Div(class: "task-ctrl-name") {
                        Text("\(job.name) ")
                        Span(class: "task-status \(statusCls)") { Text(status) }
                    }
                    Div(class: "task-ctrl-meta") {
                        Text("\(job.schedule) · next \(next) · last \(last) · \(job.runCount) run\(job.runCount == 1 ? "" : "s")")
                    }
                }
                Div(class: "row-actions-main") {
                    ArcButton(toggleLabel, id: "task-toggle-\(job.id)", component: nil, class: "ghost-btn")
                    ArcButton("Run now", id: "task-now-\(job.id)", component: nil, class: "ghost-btn")
                    ArcButton(id: "task-del-\(job.id)", component: nil, class: "icon-mini danger") {
                        WebUIIcon(.x, size: .small)
                    }
                    .title("Delete task and its chat")
                }
                .attribute("style", "margin:0")
                .wire("tasks")
            }
            Div(class: "task-ctrl-line") {
                Span(class: "task-ctrl-key") { Text("Prompt") }
                Span(class: "task-ctrl-val") { Text(job.prompt) }
            }
            Div(class: "task-ctrl-line") {
                Span(class: "task-ctrl-key") { Text("Last output") }
                Span(class: "task-ctrl-val") { Text(out) }
            }
        }
        let thread = Div(class: "task-thread") {
            Div(class: "chat-scroll") {
                Div(class: "chat-inner") { messagesHTML(msgs) }
                    .id("task-chat-inner")
            }
            .id("task-chat-scroll")
            .data("scroll-key", "tasks-thread")
        }
        return Group {
            Div(class: "main-view tasks-main-view") {
                Div(class: "tasks-main-wrap") {
                    ctrl
                    thread
                }
            }
        }
    }

    func taskMainEmpty() -> some WebUI.View {
        Div(class: "main-view") {
            Div(class: "main-scroll") {
                Element(.h2, class: "todo-title") { Text("Scheduled tasks") }
                Element(.p, class: "todo-sub") {
                    Text("Pick a task on the left to see its controls and chat, or create a new one below.")
                }
                taskFormHTML()
            }
            .data("scroll-key", "tasks-main")
        }
    }

    func taskFormHTML() -> some WebUI.View {
        Div(class: "detail-card") {
            Element(.h3) { Text("New scheduled task") }
                .attribute("style", "margin:0 0 10px")
            // a real form: Enter in any field submits, and the boundary on the
            // form is what routes that submit to the cron handler. the field
            // basis layout (`task-add-row` / `task-field`) is a css pin.
            Form(action: "", method: nil, id: "task-add-form", class: "task-add") {
                FieldLabel(class: "task-field") {
                    Text("Title")
                    Input(field: "task-title", placeholder: "e.g. Morning digest",
                          attributes: [("autocomplete", "off")])
                }
                Div(class: "task-add-row") {
                    FieldLabel(class: "task-field") {
                        Text("Start")
                        Span(class: "task-opt") { Text("optional — empty starts now") }
                        Input(field: "task-start", type: .datetimeLocal)
                    }
                    FieldLabel(class: "task-field") {
                        Text("Every")
                        Span(class: "task-every") {
                            Input(field: "task-every", type: .number, value: "15",
                                  attributes: [("min", "1"), ("step", "1")])
                            Select(field: "task-unit", options: [
                                SelectOption(value: "m", label: "minutes"),
                                SelectOption(value: "h", label: "hours"),
                                SelectOption(value: "d", label: "days"),
                            ])
                        }
                    }
                }
                FieldLabel(class: "task-field") {
                    Text("Prompt")
                    TextArea(field: "task-prompt",
                             placeholder: "What should the agent run?", rows: 4)
                }
                ArcButton("Schedule task", class: "primary-btn", type: .submit)
                Element(.p, class: "task-preview") {
                    Text("Runs on the interval you pick, starting immediately unless a Start time is set. Each run gets its own chat, kept out of the main list.")
                }
            }
            .data("component-id", "tasks")
        }
    }

    /// Parse a `<input type="datetime-local">` value ("yyyy-MM-dd'T'HH:mm") as
    /// a local-time Date; nil when empty/unparseable.
    func taskStartDate(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: t)
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
            let title = event.string("task-title") ?? ""
            let everyRaw = event.string("task-every") ?? ""
            let unit = event.string("task-unit") ?? "m"
            let prompt = event.string("task-prompt") ?? ""
            let first = await self.app.taskStartDate(event.string("task-start") ?? "")
            let n = max(1, Int(everyRaw) ?? 15)
            await self.app.addJob(name: title, schedule: "every \(n)\(unit)", prompt: prompt, firstRun: first)
            return await self.changed()
        }
        guard let tid = event.string("targetId") else { return [] }
        if tid == "task-new" {
            await self.app.selectTaskJob(nil)
        } else if tid.hasPrefix("task-open-") {
            await self.app.selectTaskJob(String(tid.dropFirst("task-open-".count)))
        } else if tid.hasPrefix("task-toggle-") {
            await self.app.toggleJob(String(tid.dropFirst("task-toggle-".count)))
        } else if tid.hasPrefix("task-now-") {
            await self.app.runJobNow(String(tid.dropFirst("task-now-".count)))
        } else if tid.hasPrefix("task-del-") {
            await self.app.deleteJob(String(tid.dropFirst("task-del-".count)))
        }
        return await self.changed()
    }
}

@WireGroup("regen")
extension Controller {

    @Wired("regen", events: [.click])
    func handleRegen(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId"),
              tid.hasPrefix("regen-"),
              let lastUser = await self.app.regenText() else { return [] }
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
