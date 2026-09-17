import ArcAgentCore
import Foundation
import WebUI

// MARK: - Run-queue model

/// One task in the run queue: a todo from a chosen chat, plus optional links
/// to earlier queue entries whose output is fed into this task's context.
struct QueueEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var chatID: String
    var todoID: String
    /// Queue entry ids (must precede this entry) whose final output is
    /// appended to this task's prompt as context.
    var inputs: [String] = []
}

/// Which tab is shown inside the Todos panel.
enum TodosTab: String {
    case tasks
    case queue
}

// MARK: - AppState: run queue

extension AppState {

    // MARK: Queue CRUD

    /// The todo referenced by a queue entry (nil once deleted).
    func queueTodo(_ e: QueueEntry) -> TodoItem? {
        settings.todos[e.chatID]?.first { $0.id == e.todoID }
    }

    /// Human label for the chat of a queue entry.
    func queueChatLabel(_ chatID: String) -> String {
        if let s = sessions.first(where: { $0.id == chatID }) { return sessionTitle(s) }
        return "Deleted chat"
    }

    func setTodosTab(_ t: TodosTab) {
        todosTab = t
    }

    /// Append queue entries for the given (open) todos of one chat.
    func addQueueEntries(chatID: String, todoIDs: [String]) {
        var added = false
        for tid in todoIDs {
            guard !settings.queuePlan.contains(where: { $0.chatID == chatID && $0.todoID == tid }) else { continue }
            settings.queuePlan.append(QueueEntry(chatID: chatID, todoID: tid))
            added = true
        }
        if added { saveSettings() }
    }

    /// Append queue entries for every checked candidate, in chat order.
    func addQueueCandidates() {
        guard !queueCandidates.isEmpty else { return }
        let cands = queueCandidates
        var added = false
        for s in sessions {
            guard let list = settings.todos[s.id] else { continue }
            for t in list.sorted(by: { $0.createdAt < $1.createdAt }) where cands.contains(t.id) {
                guard !settings.queuePlan.contains(where: { $0.todoID == t.id && $0.chatID == s.id }) else { continue }
                settings.queuePlan.append(QueueEntry(chatID: s.id, todoID: t.id))
                added = true
            }
        }
        queueCandidates = []
        if added { saveSettings() }
    }

    func removeQueueEntry(_ id: String) {
        settings.queuePlan.removeAll { $0.id == id }
        if queueLinksOpen == id { queueLinksOpen = nil }
        saveSettings()
    }

    /// Apply a user drag-and-drop order (ids in display order).
    func reorderQueue(_ ids: [String]) {
        var byId: [String: QueueEntry] = [:]
        for e in settings.queuePlan { byId[e.id] = e }
        var next: [QueueEntry] = []
        for id in ids {
            if let e = byId.removeValue(forKey: id) { next.append(e) }
        }
        // Anything not reported (edge case) keeps its relative position.
        next.append(contentsOf: settings.queuePlan.filter { byId[$0.id] != nil })
        guard next != settings.queuePlan else { return }
        settings.queuePlan = next
        saveSettings()
    }

    /// Set (or clear) the input links of one entry. Only entries that come
    /// BEFORE it in the current order are allowed — unless the loop toggle
    /// is on, in which case any OTHER task may feed (later tasks' output
    /// arrives on the next pass of the loop).
    func setQueueInputs(_ entryID: String, _ inputs: Set<String>) {
        guard let i = settings.queuePlan.firstIndex(where: { $0.id == entryID }) else { return }
        let allowed: Set<String>
        let order: [String]
        if settings.queueLoopEnabled {
            allowed = Set(settings.queuePlan.filter { $0.id != entryID }.map(\.id))
            order = settings.queuePlan.map(\.id)
        } else {
            allowed = Set(settings.queuePlan.prefix(i).map(\.id))
            order = settings.queuePlan.prefix(i).map(\.id)
        }
        settings.queuePlan[i].inputs = order.filter { allowed.contains($0) && inputs.contains($0) }
        saveSettings()
    }

    /// Toggle the sequential loop. Turning it OFF also drops backward
    /// references (they are meaningless without a loop) but keeps forward ones.
    func setQueueLoopEnabled(_ on: Bool) {
        guard settings.queueLoopEnabled != on else { return }
        settings.queueLoopEnabled = on
        if !on {
            for i in settings.queuePlan.indices {
                let e = settings.queuePlan[i]
                let earlier = Set(settings.queuePlan.prefix(i).map(\.id))
                settings.queuePlan[i].inputs = e.inputs.filter { earlier.contains($0) }
            }
        }
        saveSettings()
    }

    /// Clamp the loop count to 1...99 passes (1 = no loop).
    func setQueueLoopCount(_ raw: String) {
        let v = Int(raw.trimmingCharacters(in: .whitespaces)) ?? settings.queueLoopCount
        let clamped = min(max(v, 1), 99)
        guard clamped != settings.queueLoopCount else { return }
        settings.queueLoopCount = clamped
        saveSettings()
    }

    func clearQueueInputs(_ entryID: String) {
        guard let i = settings.queuePlan.firstIndex(where: { $0.id == entryID }) else { return }
        guard !settings.queuePlan[i].inputs.isEmpty else { return }
        settings.queuePlan[i].inputs = []
        saveSettings()
    }

    /// Move a single queue entry relative to another ("move:<srcID>:<b|a>:<refID>").
    /// The runtime only reports source + hovered ref + direction during a drag;
    /// the reorder itself happens here so drag-and-drop never depends on the
    /// DOM order having been mutated mid-drag.
    func reorderQueueMove(_ move: String) {
        let parts = move.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count == 4 else { return }
        let src = parts[1]
        let before = parts[2] == "b"
        let refID = parts[3]
        guard let si = settings.queuePlan.firstIndex(where: { $0.id == src }) else { return }
        guard let ri = settings.queuePlan.firstIndex(where: { $0.id == refID }), ri != si else { return }
        let entry = settings.queuePlan.remove(at: si)
        let ni = settings.queuePlan.firstIndex(where: { $0.id == refID }) ?? settings.queuePlan.count
        settings.queuePlan.insert(entry, at: before ? ni : ni + 1)
        saveSettings()
    }

    /// Display names of the entries feeding this one ("Task 1", "Task 3"…).
    func queueInputLabels(_ entryID: String) -> [String] {
        guard let e = settings.queuePlan.first(where: { $0.id == entryID }) else { return [] }
        let plan = settings.queuePlan
        return e.inputs.compactMap { id in
            plan.firstIndex(where: { $0.id == id }).map { "Task \($0 + 1)" }
        }
    }

    // MARK: Queue UI state (actor-isolated setters for the wire)

    func queueSetPickerOpen(_ open: Bool) {
        queuePickerOpen = open
    }

    func queueToggleCandidate(_ todoID: String) {
        if queueCandidates.contains(todoID) {
            queueCandidates.remove(todoID)
        } else {
            queueCandidates.insert(todoID)
        }
    }

    func queueToggleLinkSel(_ entryID: String) {
        if queueLinkSel.contains(entryID) {
            queueLinkSel.remove(entryID)
        } else {
            queueLinkSel.insert(entryID)
        }
    }

    /// Open (or close) the feed-output popup for an entry; the working
    /// selection starts from the entry's existing inputs.
    func queueOpenLinks(_ entryID: String?) {
        queueLinksOpen = entryID
        queueLinkSel = []
        if let id = entryID,
           let e = settings.queuePlan.first(where: { $0.id == id }) {
            queueLinkSel = Set(e.inputs)
        }
    }

    func queueClearLinkState() {
        queueLinksOpen = nil
        queueLinkSel = []
    }

    /// Mark a queue task's todo done (successful runs only).
    func markQueueTodoDone(_ e: QueueEntry) {
        markTodosDone([e.todoID], chat: e.chatID)
    }

    /// Chat-scoped variant of markTodosDone (queue tasks run in any chat).
    func markTodosDone(_ ids: [String], chat: String) {
        guard var list = settings.todos[chat], !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            if let i = list.firstIndex(where: { $0.id == id }), !list[i].done {
                list[i].done = true
                changed = true
            }
        }
        guard changed else { return }
        settings.todos[chat] = list
        saveSettings()
    }

    // MARK: Prompt building (output chaining)

    /// Todo prompt plus the output of linked earlier tasks, appended as
    /// context so later tasks can build on earlier results.
    func queuePrompt(text: String, priorOutputs: [String]) -> String {
        guard !priorOutputs.isEmpty else { return text }
        let ctx = priorOutputs.enumerated().map { i, out in
            "--- Task \(i + 1) output ---\n\(out)"
        }.joined(separator: "\n")
        return text + "\n\n[Context from earlier queue tasks]\n" + ctx
    }

    /// The last assistant reply in a chat (the runnable "output" of a task).
    func lastAssistantReply(_ chatID: String) async -> String {
        await ensureSessionMessages(chatID)
        guard let s = sessions.first(where: { $0.id == chatID }) else { return "" }
        return s.messages.reversed().first { $0.role == .assistant && !(($0.content ?? "").isEmpty) }?.content ?? ""
    }

    // MARK: Run engine

    /// Repaint the Todos panel when it is on screen (run progress updates
    /// never clobber the chat view).
    /// Request the running queue to stop between entries (or before a
    /// parallel group starts). Already-running prompts keep running.
    func requestQueueCancel() {
        queueCancelRequested = true
    }

    /// Clear queue-qued statuses (used when a run stops early) and reset the
    /// cancel flag + pass indicator.
    private func finishQueueRun(_ pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void) async {
        queueCancelRequested = false
        queueLoopPass = 0
        queueRunActive = false
        for (id, st) in queueStatuses where st == "queued" {
            queueStatuses[id] = ""
        }
        await notifyQueueView(pusher)
    }

    func notifyQueueView(_ pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void) async {
        guard activeView == .todos else { return }
        await pusher([FragmentUpdate(id: "main", html: await self.todosPanelHTML())])
    }

    /// Run one queue task in its own chat (waiting for the chat to be free).
    /// Headless: the smart classifier alone decides approvals, critical
    /// commands are blocked — queue runs are background work.
    func runQueueTurn(
        chatID: String,
        prompt: String,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) async -> Bool {
        guard sessions.contains(where: { $0.id == chatID }) else { return false }
        var waited = 0
        while activeTurns[chatID] != nil && waited < 180 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        guard activeTurns[chatID] == nil else { return false }
        await runTurn(userText: prompt, pusher: pusher, sessionID: chatID, headless: true, selectAfter: false)
        return true
    }

    /// Sequential run: tasks execute in the displayed order; each task's
    /// final reply is recorded and fed into linked tasks.
    func runQueueSequential(pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void) async {
        guard !queueRunActive else { return }
        let plan = settings.queuePlan
        guard !plan.isEmpty else {
            _ = toast("Queue is empty — add tasks first.", kind: "error")
            return
        }
        queueCancelRequested = false
        queueRunActive = true
        queueStatuses = [:]
        for e in plan { queueStatuses[e.id] = "queued" }
        await notifyQueueView(pusher)

        var outputs: [String: String] = [:]
        let passes = settings.queueLoopEnabled ? max(1, settings.queueLoopCount) : 1
        for pass in 1...passes {
            if queueCancelRequested { break }
            queueLoopPass = pass
            queueStatuses = [:]
            for e in plan {
                if queueCancelRequested { break }
                if queueTodo(e) == nil {
                    queueStatuses[e.id] = "failed"
                    await notifyQueueView(pusher)
                    continue
                }
                queueStatuses[e.id] = "running"
                await notifyQueueView(pusher)
                let todoText = queueTodo(e)?.text ?? ""
                // With the loop on, `outputs` may hold a LATER task's reply
                // from the previous pass — that is what makes backward feed
                // links resolve (TaskB's output feeds TaskA on pass 2).
                let ctx = e.inputs.compactMap { outputs[$0] }
                let prompt = queuePrompt(text: todoText, priorOutputs: ctx)
                let ok = await runQueueTurn(chatID: e.chatID, prompt: prompt, pusher: pusher)
                let reply = await lastAssistantReply(e.chatID)
                if !reply.isEmpty { outputs[e.id] = reply }
                // Only the final pass closes the todo; earlier passes keep it open.
                if ok, pass == passes { markQueueTodoDone(e) }
                queueStatuses[e.id] = ok ? "done" : "failed"
                await notifyQueueView(pusher)
            }
        }
        await finishQueueRun(pusher)
    }

    /// Parallel run: each chat's tasks run at the same time; tasks from the
    /// same chat are combined into one prompt (like Run all, per chat).
    func runQueueParallel(pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void) async {
        guard !queueRunActive else { return }
        let plan = settings.queuePlan
        guard !plan.isEmpty else {
            _ = toast("Queue is empty — add tasks first.", kind: "error")
            return
        }
        queueCancelRequested = false
        queueRunActive = true
        queueStatuses = [:]
        for e in plan { queueStatuses[e.id] = "queued" }
        await notifyQueueView(pusher)

        var groups: [(chat: String, entries: [QueueEntry])] = []
        for e in plan {
            if let i = groups.firstIndex(where: { $0.chat == e.chatID }) {
                groups[i].entries.append(e)
            } else {
                groups.append((e.chatID, [e]))
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for g in groups {
                if queueCancelRequested { break }
                group.addTask {
                    await self.runQueueGroup(g, pusher: pusher)
                }
            }
        }

        await finishQueueRun(pusher)
    }

    /// One parallel chat group: mark running, combine the chat's tasks into a
    /// single prompt (Run-all style), execute, report.
    private func runQueueGroup(
        _ g: (chat: String, entries: [QueueEntry]),
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) async {
        guard !queueCancelRequested else { return }
        for e in g.entries { queueStatuses[e.id] = "running" }
        await notifyQueueView(pusher)
        let texts = g.entries.compactMap { queueTodo($0)?.text }
        let prompt = texts.isEmpty ? "" : texts.joined(separator: "\n")
        let ok = await runQueueTurn(chatID: g.chat, prompt: prompt, pusher: pusher)
        for e in g.entries {
            if ok, queueTodo(e) != nil { markQueueTodoDone(e) }
            queueStatuses[e.id] = ok ? "done" : "failed"
        }
        await notifyQueueView(pusher)
    }
}

// MARK: - Views: run queue (part of the Todos panel)

extension AppState {

    /// Tab buttons for the Todos panel (Tasks | Run queue).
    func todosTabsHTML() -> String {
        let tasksCls = todosTab == .tasks ? " todo-tab-active" : ""
        let queueCls = todosTab == .queue ? " todo-tab-active" : ""
        return """
        <div class="todo-tabs">
          <button type="button" id="queue-tab-tasks" data-component-id="queue" data-event="click" class="todo-tab\(tasksCls)">Tasks</button>
          <button type="button" id="queue-tab-queue" data-component-id="queue" data-event="click" class="todo-tab\(queueCls)">Run queue</button>
          <span class="todo-tabs-count">\(settings.queuePlan.count) queued</span>
        </div>
        """
    }

    /// Row of a queue entry. `linkPop` renders the inline "feed output"
    /// checklist when the link button is open.
    func queueRowHTML(_ e: QueueEntry, index: Int, plan: [QueueEntry]) -> String {
        let todo = queueTodo(e)
        let missing = todo == nil ? " missing" : ""
        let status = queueStatuses[e.id] ?? ""
        let statusCls = status.isEmpty ? "" : " qst-" + status
        let statusText = status.isEmpty ? "" : (status == "done" ? "done" : status == "failed" ? "failed" : status)
        // Feed chips: same named-context presentation as the composer's
        // "Reply with selection" context blocks (truncated + accent bar).
        let inputsChips: String
        if e.inputs.isEmpty {
            inputsChips = "<span class=\"queue-in\">no feed</span>"
        } else {
            let plan = settings.queuePlan
            let chips = e.inputs.compactMap { id -> String? in
                guard let i = plan.firstIndex(where: { $0.id == id }) else { return nil }
                let todo = queueTodo(plan[i])
                let label = trunc(todo?.text ?? "…", 60)
                let full = todo?.text ?? ""
                return "<span class=\"queue-feed-chip\" title=\"\(esc(full))\">"
                    + "<span class=\"queue-feed-accent\"></span>"
                    + "<span class=\"queue-feed-label\">Task \(i + 1): \(esc(label))</span></span>"
            }.joined()
            inputsChips = "<span class=\"queue-in\">feeds: <span class=\"queue-feed-chips\">\(chips)</span></span>"
        }
        let linkPop = queueLinksOpen == e.id ? queueLinkPopupHTML(e, plan: plan) : ""
        return """
        <div class="queue-row\(missing)\(statusCls)" draggable="true" data-qid="\(e.id)">
          <span class="queue-grip" title="Drag to reorder">\(svgIcon("grip", 13))</span>
          <span class="queue-idx">\(index + 1)</span>
          <div class="queue-main">
            <div class="queue-text">\(esc(todo?.text ?? "⚠︎ todo no longer exists"))</div>
            <div class="queue-meta">\(esc(queueChatLabel(e.chatID))) · \(inputsChips)</div>
          </div>
          <button type="button" id="queue-inputs-\(e.id)" data-component-id="queue" data-event="click" class="icon-mini queue-link-btn" title="Feed earlier task output into this task">\(svgIcon("link", 12))</button>
          <span class="queue-status\(statusCls)">\(esc(statusText))</span>
          <button type="button" id="queue-del-\(e.id)" data-component-id="queue" data-event="click" class="icon-mini danger" title="Remove from queue">\(svgIcon("x", 11))</button>
        </div>
        \(linkPop)
        """
    }

    /// Inline checklist: which OTHER tasks feed this task's context.
    /// Without the loop only earlier tasks may feed; with the loop on any
    /// task may feed — later tasks' output arrives on the next pass.
    func queueLinkPopupHTML(_ e: QueueEntry, plan: [QueueEntry]) -> String {
        let myIdx = plan.firstIndex(where: { $0.id == e.id }) ?? 0
        let loopOn = settings.queueLoopEnabled
        var rows: [String] = []
        for (i, prev) in plan.enumerated() where prev.id != e.id && (loopOn || i < myIdx) {
            let later = loopOn && i > myIdx
            let checked = queueLinkSel.contains(prev.id) ? " checked" : ""
            let laterTag = later ? "<span class='queue-link-loop'>loops back</span>" : ""
            rows.append("<label class='queue-link-row'><input type='checkbox' id='qlink-\(prev.id)' data-component-id='queue' data-event='change'\(checked)><span class='queue-link-num'>Task \(i + 1)</span><span class='queue-link-title' title='\(esc(queueTodo(prev)?.text ?? ""))'>\(esc(trunc(queueTodo(prev)?.text ?? "…", 80)))</span>\(laterTag)</label>")
        }
        let body: String
        if rows.isEmpty {
            body = "<div class='queue-link-empty'>No other tasks to feed from.</div>"
        } else {
            body = rows.joined()
        }
        let head = loopOn ? "Feed output of other tasks into this task" : "Feed output of earlier tasks into this task"
        let note = loopOn ? "<div class='queue-link-note'>Loop is on: later tasks feed back on the next pass.</div>" : ""
        return """
        <div class="queue-link">
          <div class="queue-link-head">\(head)</div>
          \(body)
          \(note)
          <div class="queue-link-actions">
            <button type="button" id="queue-link-apply" data-component-id="queue" data-event="click" class="primary-btn">Apply</button>
            <button type="button" id="queue-link-clear" data-component-id="queue" data-event="click" class="ghost-btn">Clear</button>
          </div>
        </div>
        """
    }

    /// "Add tasks" picker: every chat's open todos as checkboxes.
    func queuePickerHTML() -> String {
        guard queuePickerOpen else { return "" }
        var sections: [String] = []
        for s in sessions where !isArchived(s.id) {
            let list = (settings.todos[s.id] ?? []).filter { t in
                guard !t.done else { return false }
                // Already in the run queue: no longer an option to add.
                return !settings.queuePlan.contains(where: { $0.chatID == s.id && $0.todoID == t.id })
            }
            guard !list.isEmpty else { continue }
            let cbs = list.map { t -> String in
                let checked = queueCandidates.contains(t.id) ? " checked" : ""
                return "<label class='queue-pick-row'><input type='checkbox' id='qpick-\(t.id)' data-component-id='queue' data-event='change'\(checked)><span class='queue-pick-text'>\(esc(t.text))</span></label>"
            }.joined()
            sections.append("<div class='queue-pick-chat'><div class='queue-pick-title'>\(esc(queueChatLabel(s.id)))</div>\(cbs)</div>")
        }
        let body = sections.isEmpty
            ? "<div class='queue-pick-empty'>No open todos in any chat.</div>"
            : sections.joined()
        let count = queueCandidates.count
        return """
        <div class="queue-picker">
          <div class="queue-picker-head">
            <span>Add todos from your chats</span>
            <button type="button" id="queue-picker-close" data-component-id="queue" data-event="click" class="icon-mini">\(svgIcon("x", 11))</button>
          </div>
          \(body)
          <div class="queue-picker-foot">
            <button type="button" id="queue-picker-add" data-component-id="queue" data-event="click" class="primary-btn">Add \(count) selected</button>
          </div>
        </div>
        """
    }

    /// The Run queue tab content.
    func queuePanelHTML() -> String {
        let plan = settings.queuePlan
        let rows = plan.enumerated().map { i, e in queueRowHTML(e, index: i, plan: plan) }.joined()
        let empty = plan.isEmpty ? """
            <div class="todo-empty">
              <div class="todo-empty-ico">\(svgIcon("fast-forward", 26))</div>
              <div>Nothing queued yet</div>
              <small>Add todos from any chat below, drag to reorder, then run them.</small>
            </div>
            """ : ""
        let picker = queuePickerHTML()
        let running = queueRunActive
        let loopOn = settings.queueLoopEnabled
        var runBtns: String
        if running {
            var passText = ""
            if queueLoopPass > 0 {
                passText = " · pass \(queueLoopPass)/\(max(1, settings.queueLoopCount))"
            }
            runBtns = "<span class='queue-running'><span class='queue-running-dot'></span>Running…\(esc(passText))</span>"
            runBtns += "<button type=\"button\" id=\"queue-stop\" data-component-id=\"queue\" data-event=\"click\" class=\"queue-stop-btn\" title=\"Stop the queue run; prompts already running in chats keep going\">Stop</button>"
        } else {
            let checked = loopOn ? " checked" : ""
            let countField = loopOn ? """
            <label class="queue-loop-count" title="How many times to run the queue (1 = no loop)">
              <span class="queue-loop-count-label">Loops</span>
              <input type="number" id="queue-loop-count" data-component-id="queue" data-event="change" min="1" max="99" value="\(settings.queueLoopCount)" class="queue-loop-count-input">
            </label>
            """ : ""
            runBtns = """
            <div class="queue-ctrl-btns">
              <button type="button" id="queue-run-sync" data-component-id="queue" data-event="click" class="queue-run-btn" title="Run tasks in the shown order; linked tasks receive earlier output as context">
                <span class="queue-run-ico">\(svgIcon("play", 10))</span>Run sequential
              </button>
              <button type="button" id="queue-run-async" data-component-id="queue" data-event="click" class="queue-run-btn" title="Run each chat at the same time; same-chat tasks are combined">
                <span class="queue-run-ico">\(svgIcon("fast-forward", 10))</span>Run parallel
              </button>
              <button type="button" id="queue-picker-toggle" data-component-id="queue" data-event="click" class="queue-add-btn">\(svgIcon("plus", 11)) Add tasks</button>
            </div>
            <div class="queue-loop-row">
              <label class="queue-loop-toggle" title="Repeat the sequential run; linked later tasks feed back on the next pass">
                <span class="switch"><input type="checkbox" id="queue-loop-toggle" data-component-id="queue" data-event="change"\(checked)><span class="track"></span><span class="knob"></span></span>
                <span class="queue-loop-label">Loop sequential</span>
              </label>
              \(countField)
            </div>
            """
        }
        return """
        <div class="todo-card queue-card">
          <div class="todo-head">
            <div>
              <h2 class="todo-title">Run queue</h2>
              <div class="todo-sub">Tasks run in the order shown. Sequential feeds linked output; parallel runs each chat at once.</div>
            </div>
            <div class="todo-head-actions"><div class="queue-ctrl">\(runBtns)</div></div>
          </div>
          <div class="queue-list">
            \(empty)
            \(rows)
          </div>
          \(picker)
          <button type="button" id="queue-reorder" data-component-id="queue" data-event="click" class="queue-hidden-btn">reorder</button>
        </div>
        """
    }
}

// MARK: - Controller wire (run queue)

extension Controller {

    func wireQueue(_ router: EventRouter) {
        wire(router, id: "queue", events: ["click", "submit", "change"]) { event in
            if event.event == "change" {
                guard let tid = event.string("targetId") else { return [] }
                if tid == "queue-loop-toggle" {
                    await self.app.setQueueLoopEnabled(!(await self.app.settings.queueLoopEnabled))
                    return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
                }
                if tid == "queue-loop-count" {
                    await self.app.setQueueLoopCount(event.string("value") ?? "")
                    return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
                }
                if tid.hasPrefix("qpick-") {
                    let todoID = String(tid.dropFirst("qpick-".count))
                    await self.app.queueToggleCandidate(todoID)
                    return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
                }
                if tid.hasPrefix("qlink-") {
                    let entryID = String(tid.dropFirst("qlink-".count))
                    await self.app.queueToggleLinkSel(entryID)
                    return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
                }
                return []
            }
            guard let tid = event.string("targetId") else { return [] }

            if tid == "queue-tab-tasks" || tid == "queue-tab-queue" {
                await self.app.setTodosTab(tid == "queue-tab-tasks" ? .tasks : .queue)
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-stop" {
                await self.app.requestQueueCancel()
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-run-sync" || tid == "queue-run-async" {
                guard await self.app.queueRunActive == false else { return [] }
                let cid = TaskEnv.clientID ?? 0
                let pusher = self.pusher(forClientID: cid)
                let sequential = tid == "queue-run-sync"
                Task {
                    if sequential {
                        await self.app.runQueueSequential(pusher: pusher)
                    } else {
                        await self.app.runQueueParallel(pusher: pusher)
                    }
                }
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-reorder" {
                let payload = event.string("payload") ?? ""
                if payload.hasPrefix("move:") {
                    await self.app.reorderQueueMove(payload)
                } else {
                    let order = payload.split(separator: ",").map(String.init)
                    guard !order.isEmpty else { return [] }
                    await self.app.reorderQueue(order)
                }
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-picker-toggle" {
                await self.app.queueSetPickerOpen(!(await self.app.queuePickerOpen))
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-picker-close" {
                await self.app.queueSetPickerOpen(false)
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-picker-add" {
                await self.app.addQueueCandidates()
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-link-apply" {
                let entryID = await self.app.queueLinksOpen ?? ""
                await self.app.setQueueInputs(entryID, await self.app.queueLinkSel)
                await self.app.queueClearLinkState()
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid == "queue-link-clear" {
                let entryID = await self.app.queueLinksOpen ?? ""
                await self.app.clearQueueInputs(entryID)
                await self.app.queueClearLinkState()
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid.hasPrefix("queue-inputs-") {
                let id = String(tid.dropFirst("queue-inputs-".count))
                let current: String? = await self.app.queueLinksOpen
                await self.app.queueOpenLinks(current == id ? nil : id)
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            if tid.hasPrefix("queue-del-") {
                let id = String(tid.dropFirst("queue-del-".count))
                await self.app.removeQueueEntry(id)
                return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
            }
            return [FragmentUpdate(id: "main", html: await self.app.todosPanelHTML())]
        }
    }
}
