import ArcAgentCore
import Foundation
import WebUI
import WebUIDesignSystem

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
        guard activeTabID == "todos" else { return }
        // A nudge: the queue's own view is `#main`'s todos panel, and the door
        // derives it from a fresh render instead of being handed its html here.
        await pusher(structuralChange())
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
    func todosTabsHTML() -> some WebUI.View {
        let tasksCls = todosTab == .tasks ? " todo-tab-active" : ""
        let queueCls = todosTab == .queue ? " todo-tab-active" : ""
        return Div(class: "todo-tabs") {
            ArcButton("Tasks", id: "queue-tab-tasks", component: nil, class: "todo-tab\(tasksCls)")
            ArcButton("Run queue", id: "queue-tab-queue", component: nil, class: "todo-tab\(queueCls)")
            Span(class: "todo-tabs-count") { Text("\(settings.queuePlan.count) queued") }
        }
        .wire("queue")
    }

    /// Row of a queue entry. `linkPop` renders the inline "feed output"
    /// checklist when the link button is open.
    func queueRowHTML(_ e: QueueEntry, index: Int, plan: [QueueEntry]) -> some WebUI.View {
        let todo = queueTodo(e)
        let missing = todo == nil ? " missing" : ""
        let status = queueStatuses[e.id] ?? ""
        let statusCls = status.isEmpty ? "" : " qst-" + status
        let statusText = status.isEmpty ? "" : (status == "done" ? "done" : status == "failed" ? "failed" : status)
        return Group {
            Div(class: "queue-row\(missing)\(statusCls)") {
                Span(class: "queue-grip") { WebUIIcon(.moreVertical, size: .small) }
                    .title("Drag to reorder")
                Span(class: "queue-idx") { Text("\(index + 1)") }
                Div(class: "queue-main") {
                    Div(class: "queue-text") { Text(todo?.text ?? "⚠︎ todo no longer exists") }
                    Div(class: "queue-meta") {
                        // the chat label and the separator are one text node; the feed
                        // chips follow it as their own views.
                        Text(queueChatLabel(e.chatID) + " · ")
                        queueFeedSummary(e)
                    }
                }
                ArcButton(id: "queue-inputs-\(e.id)", component: nil, class: "icon-mini queue-link-btn") {
                    WebUIIcon(.link, size: .small)
                }
                .title("Feed earlier task output into this task")
                Span(class: "queue-status\(statusCls)") { Text(statusText) }
                ArcButton(id: "queue-del-\(e.id)", component: nil, class: "icon-mini danger") {
                    WebUIIcon(.x, size: .small)
                }
                .title("Remove from queue")
            }
            .attribute("draggable", "true")
            .data("qid", e.id)
            if queueLinksOpen == e.id { queueLinkPopupHTML(e, plan: plan) }
        }
    }

    /// The "feeds:" line of a queue row — the named-context presentation the
    /// composer's "Reply with selection" blocks use (truncated + accent bar).
    /// The plan read here is the LIVE queue, not the caller's snapshot.
    private func queueFeedSummary(_ e: QueueEntry) -> some WebUI.View {
        let plan = settings.queuePlan
        let chips: [any WebUI.View] = e.inputs.compactMap { id -> (any WebUI.View)? in
            guard let i = plan.firstIndex(where: { $0.id == id }) else { return nil }
            let todo = queueTodo(plan[i])
            let label = trunc(todo?.text ?? "…", 60)
            return Span(class: "queue-feed-chip") {
                Span(class: "queue-feed-accent") {}
                Span(class: "queue-feed-label") { Text("Task \(i + 1): \(label)") }
            }
            .title(todo?.text ?? "")
        }
        return Group {
            if e.inputs.isEmpty {
                Span(class: "queue-in") { Text("no feed") }
            } else {
                Span(class: "queue-in") {
                    Text("feeds: ")
                    Span(class: "queue-feed-chips") { chips }
                }
            }
        }
    }

    /// Inline checklist: which OTHER tasks feed this task's context.
    /// Without the loop only earlier tasks may feed; with the loop on any
    /// task may feed — later tasks' output arrives on the next pass.
    func queueLinkPopupHTML(_ e: QueueEntry, plan: [QueueEntry]) -> some WebUI.View {
        let myIdx = plan.firstIndex(where: { $0.id == e.id }) ?? 0
        let loopOn = settings.queueLoopEnabled
        var rows: [any WebUI.View] = []
        for (i, prev) in plan.enumerated() where prev.id != e.id && (loopOn || i < myIdx) {
            let later = loopOn && i > myIdx
            let checked = queueLinkSel.contains(prev.id)
            let full = queueTodo(prev)?.text ?? ""
            rows.append(
                FieldLabel(class: "queue-link-row") {
                    Input(id: "qlink-\(prev.id)", type: .checkbox, value: prev.id)
                        .wire("qlink", on: .change)
                        .flag(.checked, when: checked)
                    Span(class: "queue-link-num") { Text("Task \(i + 1)") }
                    Span(class: "queue-link-title") { Text(trunc(full.isEmpty ? "…" : full, 80)) }
                        .title(full)
                    if later {
                        Span(class: "queue-link-loop") { Text("loops back") }
                    }
                }
            )
        }
        let head = loopOn ? "Feed output of other tasks into this task" : "Feed output of earlier tasks into this task"
        return Div(class: "queue-link") {
            Div(class: "queue-link-head") { Text(head) }
            if rows.isEmpty {
                Div(class: "queue-link-empty") { Text("No other tasks to feed from.") }
            } else {
                rows
            }
            if loopOn {
                Div(class: "queue-link-note") { Text("Loop is on: later tasks feed back on the next pass.") }
            }
            Div(class: "queue-link-actions") {
                ArcButton("Apply", id: "queue-link-apply", component: nil, class: "primary-btn")
                ArcButton("Clear", id: "queue-link-clear", component: nil, class: "ghost-btn")
            }
        }
    }

    /// "Add tasks" picker: every chat's open todos as checkboxes.
    func queuePickerHTML() -> some WebUI.View {
        let sections = queuePickerSections()
        let count = queueCandidates.count
        return Group {
            if queuePickerOpen {
                Div(class: "queue-picker") {
                    Div(class: "queue-picker-head") {
                        Span { Text("Add todos from your chats") }
                        ArcButton(id: "queue-picker-close", component: nil, class: "icon-mini") {
                            WebUIIcon(.x, size: .small)
                        }
                    }
                    if sections.isEmpty {
                        Div(class: "queue-pick-empty") { Text("No open todos in any chat.") }
                    } else {
                        sections
                    }
                    Div(class: "queue-picker-foot") {
                        ArcButton("Add \(count) selected", id: "queue-picker-add", component: nil, class: "primary-btn")
                    }
                }
            }
        }
    }

    /// one section per chat with open todos that are not already queued.
    private func queuePickerSections() -> [any WebUI.View] {
        var sections: [any WebUI.View] = []
        for s in sessions where !isArchived(s.id) {
            let list = (settings.todos[s.id] ?? []).filter { t in
                guard !t.done else { return false }
                // Already in the run queue: no longer an option to add.
                return !settings.queuePlan.contains(where: { $0.chatID == s.id && $0.todoID == t.id })
            }
            guard !list.isEmpty else { continue }
            let cbs: [any WebUI.View] = list.map { t in
                let checked = queueCandidates.contains(t.id)
                return FieldLabel(class: "queue-pick-row") {
                    Input(id: "qpick-\(t.id)", type: .checkbox, value: t.id)
                        .wire("qpick", on: .change)
                        .flag(.checked, when: checked)
                    Span(class: "queue-pick-text") { Text(t.text) }
                }
            }
            sections.append(
                Div(class: "queue-pick-chat") {
                    Div(class: "queue-pick-title") { Text(queueChatLabel(s.id)) }
                    cbs
                }
            )
        }
        return sections
    }

    /// The Run queue tab content.
    func queuePanelHTML() -> some WebUI.View {
        let plan = settings.queuePlan
        let running = queueRunActive
        let loopOn = settings.queueLoopEnabled
        // the rows are materialized up front: a builder cannot take `[some View]`
        let rows: [any WebUI.View] = plan.enumerated().map { i, e in queueRowHTML(e, index: i, plan: plan) }
        return Div(class: "todo-card queue-card") {
            Div(class: "todo-head") {
                Div {
                    Element(.h2, class: "todo-title") { Text("Run queue") }
                    Div(class: "todo-sub") {
                        Text("Tasks run in the order shown. Sequential feeds linked output; parallel runs each chat at once.")
                    }
                }
                Div(class: "todo-head-actions") {
                    Div(class: "queue-ctrl") {
                        if running {
                            queueRunningStatus()
                            ArcButton("Stop", id: "queue-stop", component: nil, class: "queue-stop-btn")
                                .title("Stop the queue run; prompts already running in chats keep going")
                        } else {
                            queueRunControls()
                            queueLoopRow(loopOn: loopOn)
                        }
                    }
                }
            }
            Div(class: "queue-list") {
                if plan.isEmpty { queueEmptyState() }
                rows
            }
            queuePickerHTML()
            Input(
                id: "queue-order",
                type: .hidden,
                attributes: [("value", "")]
            )
            .wire("queue-order", on: .change)
            .data("no-restore", "")
        }
        .wire("queue")
    }

    /// the "Running… · pass n/m" pill plus the stop button's sibling slot.
    private func queueRunningStatus() -> some WebUI.View {
        var passText = ""
        if queueLoopPass > 0 {
            passText = " · pass \(queueLoopPass)/\(max(1, settings.queueLoopCount))"
        }
        return Span(class: "queue-running") {
            Span(class: "queue-running-dot") {}
            Text("Running…" + passText)
        }
    }

    /// the three buttons that start a run or open the picker, idle state only.
    private func queueRunControls() -> some WebUI.View {
        Div(class: "queue-ctrl-btns") {
            ArcButton(id: "queue-run-sync", component: nil, class: "queue-run-btn") {
                Span(class: "queue-run-ico") { WebUIIcon(.play, size: .small) }
                Text("Run sequential")
            }
            .title("Run tasks in the shown order; linked tasks receive earlier output as context")
            ArcButton(id: "queue-run-async", component: nil, class: "queue-run-btn") {
                Span(class: "queue-run-ico") { WebUIIcon(.fastForward, size: .small) }
                Text("Run parallel")
            }
            .title("Run each chat at the same time; same-chat tasks are combined")
            ArcButton(id: "queue-picker-toggle", component: nil, class: "queue-add-btn") {
                WebUIIcon(.plus, size: .small)
                Text(" Add tasks")
            }
        }
    }

    /// the loop switch, plus the pass-count field when the loop is on.
    private func queueLoopRow(loopOn: Bool) -> some WebUI.View {
        Div(class: "queue-loop-row") {
            FieldLabel(class: "queue-loop-toggle") {
                Span(class: "switch") {
                    Input(id: "queue-loop-toggle", type: .checkbox, value: "1")
                        .wire("queue-loop-toggle", on: .change)
                        .flag(.checked, when: loopOn)
                    Span(class: "track") {}
                    Span(class: "knob") {}
                }
                Span(class: "queue-loop-label") { Text("Loop sequential") }
            }
            .title("Repeat the sequential run; linked later tasks feed back on the next pass")
            if loopOn {
                FieldLabel(class: "queue-loop-count") {
                    Span(class: "queue-loop-count-label") { Text("Loops") }
                    Input(
                        id: "queue-loop-count",
                        type: .number,
                        value: "\(settings.queueLoopCount)",
                        attributes: [("min", "1"), ("max", "99"), ("class", "queue-loop-count-input")]
                    )
                    .wire("queue-loop-count", on: .change)
                }
                .title("How many times to run the queue (1 = no loop)")
            }
        }
    }

    /// the empty-queue placeholder.
    private func queueEmptyState() -> some WebUI.View {
        Div(class: "todo-empty") {
            Div(class: "todo-empty-ico") { WebUIIcon(.fastForward, size: .extraLarge) }
            Div { Text("Nothing queued yet") }
            Small("Add todos from any chat below, drag to reorder, then run them.")
        }
    }
}

// MARK: - Controller wires (run queue)

@WireGroup("queue")
extension Controller {

    @Wired("queue", events: [.click, .submit])
    func handleQueue(_ event: EventData) async -> [FragmentUpdate] {
        guard let tid = event.string("targetId") else { return [] }

        if tid == "queue-tab-tasks" || tid == "queue-tab-queue" {
            await self.app.setTodosTab(tid == "queue-tab-tasks" ? .tasks : .queue)
            return await self.changed()
        }
        if tid == "queue-stop" {
            await self.app.requestQueueCancel()
            return await self.changed()
        }
        if tid == "queue-run-sync" || tid == "queue-run-async" {
            guard await self.app.queueRunActive == false else { return [] }
            let pusher = self.push
            let sequential = tid == "queue-run-sync"
            let app = self.app
            Task {
                if sequential {
                    await app.runQueueSequential(pusher: pusher)
                } else {
                    await app.runQueueParallel(pusher: pusher)
                }
            }
            return await self.changed()
        }
        if tid == "queue-picker-toggle" {
            await self.app.queueSetPickerOpen(!(await self.app.queuePickerOpen))
            return await self.changed()
        }
        if tid == "queue-picker-close" {
            await self.app.queueSetPickerOpen(false)
            return await self.changed()
        }
        if tid == "queue-picker-add" {
            await self.app.addQueueCandidates()
            return await self.changed()
        }
        if tid == "queue-link-apply" {
            let entryID = await self.app.queueLinksOpen ?? ""
            await self.app.setQueueInputs(entryID, await self.app.queueLinkSel)
            await self.app.queueClearLinkState()
            return await self.changed()
        }
        if tid == "queue-link-clear" {
            let entryID = await self.app.queueLinksOpen ?? ""
            await self.app.clearQueueInputs(entryID)
            await self.app.queueClearLinkState()
            return await self.changed()
        }
        if tid.hasPrefix("queue-inputs-") {
            let id = String(tid.dropFirst("queue-inputs-".count))
            let current: String? = await self.app.queueLinksOpen
            await self.app.queueOpenLinks(current == id ? nil : id)
            return await self.changed()
        }
        if tid.hasPrefix("queue-del-") {
            let id = String(tid.dropFirst("queue-del-".count))
            await self.app.removeQueueEntry(id)
            return await self.changed()
        }
        return await self.changed()
    }

    @Wired("queue-order", events: [.change])
    func handleQueueOrder(_ event: EventData) async -> [FragmentUpdate] {
        let order = (event.string("value") ?? "").split(separator: ",").map(String.init)
        guard !order.isEmpty else { return [] }
        await self.app.reorderQueue(order)
        return await self.changed()
    }

    @Wired("queue-loop-toggle", events: [.change])
    func handleQueueLoopToggle(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setQueueLoopEnabled(!(await self.app.settings.queueLoopEnabled))
        return await self.changed()
    }

    @Wired("queue-loop-count", events: [.change])
    func handleQueueLoopCount(_ event: EventData) async -> [FragmentUpdate] {
        await self.app.setQueueLoopCount(event.string("value") ?? "")
        return await self.changed()
    }

    @Wired("qpick", events: [.change])
    func handleQueuePick(_ event: EventData) async -> [FragmentUpdate] {
        let todoID = event.string("value") ?? ""
        guard !todoID.isEmpty else { return [] }
        await self.app.queueToggleCandidate(todoID)
        return await self.changed()
    }

    @Wired("qlink", events: [.change])
    func handleQueueLink(_ event: EventData) async -> [FragmentUpdate] {
        let entryID = event.string("value") ?? ""
        guard !entryID.isEmpty else { return [] }
        await self.app.queueToggleLinkSel(entryID)
        return await self.changed()
    }
}
