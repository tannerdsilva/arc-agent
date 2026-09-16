import ArcAgentCore
import AsyncHTTPClient
import Foundation
import Logging
import NIO
import WebUI

// MARK: - Hermes-parity panels: Tasks (cron) + Todos, plus regenerate & vision.

/// A simple todo entry, mirrored from the Hermes WebUI todos panel.
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

    // MARK: Cron engine

    /// Start the recurring tick that fires due scheduled jobs. One structured
    /// Task owned by the actor; cancel via stopCronEngine().
    func startCronEngine() {
        guard cronTask == nil else { return }
        cronTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.cronTick()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopCronEngine() {
        cronTask?.cancel()
        cronTask = nil
    }

    /// Fire every scheduled job whose `nextRunAt` is due (or never set).
    func cronTick() async {
        let now = Date()
        var fired: [CronJob] = []
        for job in settings.scheduledJobs where job.isActive {
            let due: Bool
            if let next = job.nextRunAt {
                due = next <= now
            } else {
                due = true
            }
            if due { fired.append(job) }
        }
        for job in fired {
            await runScheduledJob(job, now: now)
        }
    }

    /// Run one scheduled job fully headless: the agent turn is executed with
    /// the scheduled prompt in a per-job session, tools allowed, with smart
    /// classification deciding dangerous commands (no interactive prompt —
    /// critical commands are blocked and logged, never run).
    func runScheduledJob(_ job: CronJob, now: Date = Date()) async {
        let sid = jobSessionID(job)
        var session: Session
        if let existing = sessions.first(where: { $0.id == sid }) {
            await ensureSessionMessages(sid)
            guard let existing = sessions.first(where: { $0.id == sid }) else { return }
            session = existing
        } else {
            session = Session(id: sid, createdAt: now, updatedAt: now, model: settings.modelConfig(named: settings.activeConfig)?.model ?? "")
            if let store {
                try? await store.create(session)
            }
            settings.sessionTitles[sid] = "Cron: \(job.name)"
            await reloadSessions(selecting: sid)
        }
        session.updatedAt = now

        guard let preset = settings.modelConfig(named: configName(for: sid)),
              let client = makeClient(for: preset) else {
            updateJob(job.id) { $0.lastOutput = "Error: no model configuration" }
            return
        }

        let userMsg = Message(role: .user, content: job.prompt, createdAt: now)
        session.messages.append(userMsg)
        await persistMessage(userMsg, sessionID: sid, store: store)

        let system = Message(role: .system, content: await buildSystemPrompt(config: preset, sessionID: sid))
        let tools = registry.buildToolSchemas(enabled: [], disabled: Set(settings.disabledToolsets))
        var history = session.messages
        var finalText = ""
        var iterations = 0
        while iterations < 25 {
            iterations += 1
            var msgs = [system]
            msgs.append(contentsOf: history)
            guard let response = try? await client.complete(messages: msgs, tools: tools, reasoningEffort: nil) else {
                finalText = "Error: LLM request failed"
                break
            }
            if let t = response.content, !t.isEmpty {
                finalText = t
            }
            if let calls = response.toolCalls, !calls.isEmpty {
                for call in calls {
                    let result = await runTool(call, sessionID: sid, pusher: { _ in }, headless: true)
                    let toolMsg = Message(role: .tool, content: result, name: call.function.name, createdAt: Date())
                    history.append(toolMsg)
                    await persistMessage(toolMsg, sessionID: sid, store: store)
                }
                let asst = Message(role: .assistant, content: "Ran \(calls.count) tool call(s).", createdAt: Date())
                history.append(asst)
                await persistMessage(asst, sessionID: sid, store: store)
                continue
            }
            break
        }
        let asstMsg = Message(role: .assistant, content: finalText, createdAt: Date())
        history.append(asstMsg)
        await persistMessage(asstMsg, sessionID: sid, store: store)
        updateJob(job.id) {
            $0.lastRunAt = now
            $0.runCount += 1
            $0.lastOutput = trunc(finalText, 240)
            let next = CronNext(expression: $0.schedule, from: now)
            $0.nextRunAt = next
        }
        await reloadSessions(selecting: sid)
    }

    func jobSessionID(_ job: CronJob) -> String { "Cron-\(job.id)" }

    private func updateJob(_ id: String, _ mutate: (inout CronJob) -> Void) {
        guard let i = settings.scheduledJobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&settings.scheduledJobs[i])
        saveSettings()
    }

    func addJob(name: String, schedule: String, prompt: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !s.isEmpty, !p.isEmpty else { return }
        var job = CronJob(name: n, schedule: s, prompt: p)
        job.nextRunAt = CronNext(expression: job.schedule, from: Date())
        job.lastOutput = nil
        settings.scheduledJobs.append(job)
        saveSettings()
    }

    func removeJob(_ id: String) {
        settings.scheduledJobs.removeAll { $0.id == id }
        saveSettings()
    }

    func toggleJob(_ id: String) {
        updateJob(id) { $0.isActive.toggle() }
    }

    func runJobNow(_ id: String) {
        guard let job = settings.scheduledJobs.first(where: { $0.id == id }) else { return }
        Task { await self.runScheduledJob(job) }
    }
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

    /// The Todos view: tab switcher (Tasks | Run queue) + active tab body.
    func todosPanelHTML() -> String {
        migrateLegacyTodosIfNeeded()
        let tabs = todosTabsHTML()
        let body = todosTab == .tasks ? todosTasksHTML() : queuePanelHTML()
        return "<div id=\"main\" class=\"todo-panel\">" + tabs + body + "</div>"
    }

    /// The Tasks tab body (per-chat todo list).
    func todosTasksHTML() -> String {
        let chat = activeSessionID ?? ""
        let items = todos(for: chat)
        let pending = items.filter { !$0.done }.count
        let done = items.count - pending

        var rows: [String] = []
        for t in items {
            rows.append("""
            <div class="todo-row\(t.done ? " done" : "")" data-tid="\(t.id)">
              <button type="button" id="todo-toggle-\(t.id)" data-component-id="todos" class="todo-check" title="\(t.done ? "Mark not done" : "Mark done")" aria-label="Toggle">
                \(svgIcon("check", 12))
              </button>
              <span class="todo-text">\(esc(t.text))</span>
              <button type="button" id="todo-run-\(t.id)" data-component-id="todos" class="todo-run" title="Run in chat" aria-label="Run in chat">
                \(svgIcon("play", 11))
              </button>
              <button type="button" id="todo-del-\(t.id)" data-component-id="todos" class="todo-x" title="Remove" aria-label="Remove">
                \(svgIcon("x", 11))
              </button>
            </div>
            """)
        }

        let chatLabel: String
        if chat.isEmpty {
            chatLabel = "Open a chat from the sidebar — todos belong to the chat you are using."
        } else if let s = sessions.first(where: { $0.id == chat }) {
            chatLabel = "for “\(esc(sessionTitle(s)))”"
        } else {
            chatLabel = "for this chat"
        }

        let empty = items.isEmpty ? """
            <div class="todo-empty">
              <div class="todo-empty-ico">\(svgIcon("check", 26))</div>
              <div>\(chat.isEmpty ? "Select a chat to see its todos" : "No todos for this chat yet")</div>
              <small>Add one below — it stays with this chat.</small>
            </div>
            """ : ""
        let clearBtn = done > 0
            ? btn("todo-clear-done", "todos", "ghost-btn", "Clear done (\(done))", " title=\"Remove completed todos\"")
            : ""
        return """
        <div class="todo-card">
          <div class="todo-head">
            <div>
              <h2 class="todo-title">Todos</h2>
                <div class="todo-sub">\(chatLabel)</div>
              </div>
              <div class="todo-head-actions">
                \(clearBtn)
                <button type="button" id="todo-run-all" data-component-id="todos" class="todo-runall" title="Run all open todos in chat" aria-label="Run all open todos in chat">
                  <span class="todo-runall-ico">\(svgIcon("fast-forward", 10))</span>Run all
                </button>
                <span class="todo-pill">\(pending) open</span>
              </div>
            </div>
            <div class="todo-list">
              \(empty)
              \(rows.joined())
            </div>
            <div class="todo-foot">
              <form id="todo-add-form" data-component-id="todos" class="todo-add">
                <input type="text" id="todo-add-text" data-component-id="todos" data-no-restore name="todo-text" placeholder="Add a todo for this chat…" autocomplete="off">
                <button type="submit" class="primary-btn">Add</button>
              </form>
            </div>
          </div>
        """
    }

    func cronPanelHTML() -> String {
        let rows = settings.scheduledJobs.map { j in
            let next = j.nextRunAt.map { fmtRel($0) } ?? "—"
            let out = j.lastOutput.map { trunc($0, 60) } ?? "—"
            return """
            <div class="cron-row">
              <button type="button" id="cron-toggle-\(j.id)" data-component-id="cron" class="cron-dot\(j.isActive ? " on" : "")" title="\(j.isActive ? "Pause" : "Resume")">\(j.isActive ? "●" : "○")</button>
              <div class="cron-info">
                <div class="cron-name">\(esc(j.name)) <span class="cron-sched">\(esc(j.schedule))</span>\(j.runCount > 0 ? " · \(j.runCount) runs" : "")</div>
                <div class="cron-meta">next: \(next) · last: \(out)</div>
              </div>
              <button type="button" id="cron-now-\(j.id)" data-component-id="cron" class="icon-mini" title="Run now">\(svgIcon("play", 11))</button>
              <button type="button" id="cron-del-\(j.id)" data-component-id="cron" class="icon-mini danger" title="Delete">\(svgIcon("x", 11))</button>
            </div>
            """
        }.joined()
        let empty = rows.isEmpty ? "<div class=\"todo-empty\">No scheduled jobs yet. Recurring prompts run headless in their own chat (critical commands are auto-blocked).</div>" : ""
        return """
        <div id="main" class="cron-panel">
          <h2 class="todo-title">Scheduled tasks</h2>
          \(empty)
          \(rows)
          <form id="cron-add-form" data-component-id="cron" class="cron-add">
            <input type="text" id="cron-name" data-component-id="cron" name="cron-name" placeholder="Name" autocomplete="off">
            <input type="text" id="cron-schedule" data-component-id="cron" name="cron-schedule" placeholder="Schedule (e.g. 30m, every 2h, 0 9 * * *)" autocomplete="off">
            <input type="text" id="cron-prompt" data-component-id="cron" name="cron-prompt" placeholder="Prompt to run" autocomplete="off">
            <button type="submit" class="primary-btn">Schedule</button>
          </form>
        </div>
        """
    }

    func fmtRel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Controller wires (todos, cron, regenerate)

extension Controller {

    func wireTodos(_ router: EventRouter) {
        wire(router, id: "todos", events: ["click", "submit"]) { event in
            if event.event == "submit" {
                let text = event.data["todo-text"] ?? ""
                await self.app.addTodo(text)
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            guard let tid = event.data["targetId"] else { return [] }
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
                    return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
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
            return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
        }
    }

    func wireCron(_ router: EventRouter) {
        wire(router, id: "cron", events: ["click", "submit"]) { event in
            if event.event == "submit" {
                let name = event.data["cron-name"] ?? ""
                let sched = event.data["cron-schedule"] ?? ""
                let prompt = event.data["cron-prompt"] ?? ""
                await self.app.addJob(name: name, schedule: sched, prompt: prompt)
                return [FragmentUpdate(id: "main", html: await self.app.cronPanelHTML())]
            }
            guard let tid = event.data["targetId"] else { return [] }
            if tid.hasPrefix("cron-toggle-") {
                await self.app.toggleJob(String(tid.dropFirst("cron-toggle-".count)))
            } else if tid.hasPrefix("cron-now-") {
                await self.app.runJobNow(String(tid.dropFirst("cron-now-".count)))
            } else if tid.hasPrefix("cron-del-") {
                await self.app.removeJob(String(tid.dropFirst("cron-del-".count)))
            }
            return [FragmentUpdate(id: "main", html: await self.app.cronPanelHTML())]
        }
    }

    func wireRegen(_ router: EventRouter) {
        wire(router, id: "regen", events: ["click"]) { event in
            guard let tid = event.data["targetId"],
                  tid.hasPrefix("regen-"),
                  let lastUser = await self.app.regenText() else { return [] }
            return await self.submitChat(text: lastUser)
        }
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
