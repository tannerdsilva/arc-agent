import ArcAgentCore
import ArcSidebarTabs
import ArcTheme
import Foundation
import Logging
import WebUI

// MARK: - Views (actor methods on AppState)

/// All HTML builders live on `AppState` so they can read actor state directly.
/// Fragment builders render the target ELEMENT (outerHTML semantics), so each
/// one re-emits its root `<div id="…">`.
extension AppState {

    // MARK: - Code fencing

    /// Render markdown with fenced code blocks (` ``` `) handled: code runs are
    /// escaped and wrapped in `<pre><code>`, the rest goes through
    /// `markdownToHTML`. Splitting on the fence string makes the parts
    /// alternate text / code / text / code…
    func renderMarkdown(_ markdown: String) -> String {
        let parts = markdown.components(separatedBy: "```")
        var out = ""
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                // Code block — optional language tag on the first line becomes
                // `class="language-…"` on the code element (reference smd sets the
                // same class from the fence label).
                var code = part
                var lang = ""
                if let nl = code.firstIndex(of: "\n") {
                    let firstLine = code[..<nl].trimmingCharacters(in: .whitespaces)
                    if !firstLine.isEmpty {
                        lang = firstLine
                        code = String(code[code.index(after: nl)...])
                    }
                } else {
                    lang = code.trimmingCharacters(in: .whitespaces)
                    code = ""
                }
                let clean = code.trimmingCharacters(in: .newlines)
                let langAttr = lang.isEmpty ? "" : " class=\"language-\(esc(lang))\""
                out += "<div class=\"code-wrap\"><button type=\"button\" class=\"copy-code\" data-copy=\"\(esc(clean))\" title=\"Copy code\">Copy</button><pre><code\(langAttr)>\(esc(clean))</code></pre></div>"
            } else {
                // arc-parity renderer (ArcAgentCore/WebUI): headings,
                // tables, blockquotes, nested lists, task checkboxes, math
                // elements, sanitized images/autolinks — identical to the
                // tested parity output, engine-independent.
                out += MarkdownRenderer.render(part)
            }
        }
        return out
    }

    /// Wrap markdown fragment HTML in the `.md` container class.
    func mdBox(_ markdown: String) -> String {
        "<div class=\"md\">\(renderMarkdown(markdown))</div>"
    }

    // MARK: - Shell

    /// The complete application shell (topbar + iconbar + panel + main). Toasts
    /// are rendered separately so each region is a single-rooted fragment.
    ///
    /// Returns the typed page body. arc's chrome is hand-built html, so this is
    /// the one place arc mints trust for it (`.trusted(_:)`) — and from here the
    /// compiler carries that type to `HTMLDocument(body:)`, so no unlabelled
    /// string can become a page. a fragment patch that needs the bytes reads
    /// `.html`.
    func appShell() async -> some WebUI.View {
        let panel = await panelHTML()
        // the builder closure is synchronous, so anything async is resolved
        // before it: the main region crosses in as an already-built view.
        let main = await mainContentHTML()

        return Div {
            Link("Skip to composer", href: "#composer-input", class: "skip-link")
            topbarHTML()
            Div {
                iconbarHTML()
                panel                    // panelHTML() is now a View (phase 2.2); bridge retired
                main
                legacy(workspaceDockHTML())  // TODO(phase 7)
                legacy(workspacePanelHTML()) // TODO(phase 7)
                Div(id: "drawer-scrim", class: "drawer-scrim") {}
                    .attribute("aria-hidden", "true")
            }.attribute("id", "app-body")
            modalRootHTML()
            toastsShell()
        }
        .attribute("id", "app")
        .attribute("data-size", settings.textSize)
    }

    /// Thin full-width bar across the top of the screen (arc-style): a
    /// colorless lightning mark centred with the current chat's name beside it.
    func topbarHTML() -> some WebUI.View {
        Header {
            // UX-19/T12: below 1024px the left panel becomes an overlay drawer
            // opened from this toggle. The open/closed CLASS stays client-owned
            // (overlay.js flips `#app.drawer-open` — it survives every fragment
            // patch and owns both the visual and the aria truth). The control
            // itself is wired to the engine (`data-component-id` + a click handler
            // in Actions) so clicks route instead of logging the engine's
            // "click on unwired control #drawer-toggle" warning.
            ArcButton("\u{2630}",          // ☰ — the &#9776; entity in the golden; Text escapes, so emit the char
                      id: "drawer-toggle",
                      component: "drawer-toggle",
                      class: "drawer-toggle-btn")
                .attribute("aria-label", "Toggle sidebar")
                .attribute("aria-expanded", "false")
                .attribute("data-event", "click")
            Div(class: "topbar-center") {
                Span(class: "topbar-bolt") { WebUIIcon(.zap, size: .medium) }
                Span(class: "topbar-name") { Text(topbarLabel()) }
            }
        }
        .attribute("id", "topbar")
    }

    /// The chat name the top bar shows: the active conversation's title when
    /// one is open, otherwise a short app label.
    func topbarLabel() -> String {
        // UX-11: the topbar is app-level chrome on chat views — the session
        // title lives in the chat header, not in the topbar. Rendering it
        // twice (38px topbar + 68px chat header) wastes ~18% of a 577px
        // window on a duplicate of the same truncated sentence.
        return "ARC Agent"
    }

    func toastsShell() -> some WebUI.View {
        Div(id: "toasts") {
            toastsHTML()
        }
        .attribute("data-component-id", "toast-dismiss")
        .attribute("data-event", "click")
    }

    func iconbarHTML() -> some WebUI.View {
        // Registry-driven: Chat is always first, Settings is pinned in the
        // bottom slot, the rest follow the user's settings order minus the
        // tabs they hid. Built-ins and plugin tabs render alike.
        Aside {
            Div(class: "iconbar-top") {
                for id in railTabIDs() where id != "settings" {
                    if let tab = sidebarTab(id) { railButton(tab, active: id == activeTabID) }
                }
            }
            Div(class: "iconbar-bottom") {
                if let settings = sidebarTab("settings") { railButton(settings, active: activeTabID == "settings") }
            }
        }
        .attribute("id", "iconbar")
    }

    /// One rail tab as a button.
    ///
    /// UX-07 roving rail: the ACTIVE nav item is the single tab stop; every other
    /// tab is `tabindex="-1"` and reached with ArrowUp/ArrowDown (overlay.js roves
    /// tabindex with focus). UX-08: an icon-only button still needs an accessible
    /// name — the `data-tip` pill is hover-only, so assistive tech and touch never
    /// see it.
    ///
    /// The only thing that changes between the active and inactive states is
    /// `aria-current="page"` plus `class="icon-btn active"` / `tabindex="0"` —
    /// `Group` keeps it as exactly one `<button>` (no wrapper element), so the
    /// rail renders one button per tab.
    private func railButton(_ tab: any SidebarTab, active: Bool) -> some WebUI.View {
        let base = ArcButton(
            id: "nav-\(tab.id)",
            component: "nav-\(tab.id)",
            class: active ? "icon-btn active" : "icon-btn",
            tabIndex: active ? 0 : -1
        ) {
            SidebarTabIconRenderer.view(tab.icon)
        }
        .attribute("data-tip", tab.title)
        .attribute("aria-label", tab.title)

        // only the active tab announces itself as the current page; the others
        // stay reachable but out of the tab order.
        return Group {
            if active {
                base.attribute("aria-current", "page")
            } else {
                base
            }
        }
    }

    func toastsHTML() -> some WebUI.View {
        // UX-27: cap the visible stack so it can never cover the chat header.
        // The newest toasts win (the most recent action is the one the user is
        // still reacting to); anything older collapses into a "+N more" marker
        // that is informational only (the toasts themselves still expire on
        // their TTL tick).
        let visible = toasts.suffix(3)
        let overflow = toasts.count - visible.count
        // Clipboard side-channel for the shared-link copy (UX-06): consumed
        // by the overlay's post-patch pass; single-shot — the state is read
        // and cleared here so a later toast push never re-emits it.
        let marker = pendingCopyURL
        pendingCopyURL = nil
        return Group {
            for t in visible {
                Div(class: "toast \(t.kind)") {
                    Span(class: "toast-dot") { }
                    Span { Text(t.text) }
                    if let a = t.action {
                        ArcButton(a.label, id: "ta-\(a.id)-\(t.id)", component: nil, class: "toast-action")
                    }
                    ArcButton(id: "t-\(t.id)", component: nil, class: "toast-x") {
                        WebUIIcon(.x, size: .small)
                    }
                }
            }
            if overflow > 0 {
                Div(class: "toast toast-more") { Text("+\(overflow) more") }
            }
            if let marker {
                Span {}.attribute("id", "pending-copy").attribute("data-copy-url", marker)
            }
        }
    }

    /// The one confirmation dialog. Chat and profile deletes arm their original
    /// state fields; newer guards (workspaces) arm `pendingConfirm` — so every
    /// destructive action gets the same dialog, the same Cancel/Delete pair, a
    /// real dialog role, and (via the overlay) the same focus + Escape handling.
    func modalHTML() -> some WebUI.View {
        guard let req = activeConfirm else { return Group {} }
        return Group {
            Div(id: "modal-overlay", class: "modal-overlay") {
                Div(class: "modal-card") {
                    Heading(req.title, level: .h3)
                        .attribute("id", "modal-title")
                    Paragraph(req.body)
                    Div(class: "modal-actions") {
                        ArcButton("Cancel", id: "modal-cancel", component: nil, class: "ghost-btn")
                        ArcButton("Delete", id: "modal-confirm", component: nil, class: "danger-btn")
                    }
                    .attribute("data-component-id", "modal")
                    .attribute("data-event", "click")
                }
                .attribute("role", "dialog")
                .attribute("aria-modal", "true")
                .attribute("aria-labelledby", "modal-title")
            }
        }
    }

    /// The armed destructive action, from whichever source carries it. Deriving
    /// one shape here keeps the dialog identical everywhere while leaving the
    /// chat/profile delete paths (the riskiest in the app) exactly as they were.
    var activeConfirm: ConfirmRequest? {
        if let pid = confirmProfileDelete,
           let p = profiles.first(where: { $0.name == pid }) {
            let title = trunc(p.title.isEmpty ? p.name : p.title, 48)
            return ConfirmRequest(
                kind: "profile", id: pid, title: "Delete profile?",
                body: "The profile “\(title)” will be permanently deleted. This cannot be undone.")
        }
        if let mid = confirmDeleteID,
           let s = sessions.first(where: { $0.id == mid }) {
            let title = trunc(sessionTitle(s), 48)
            return ConfirmRequest(
                kind: "chat", id: mid, title: "Delete conversation?",
                body: "The chat “\(title)” will be deleted. You can undo this for 10 seconds.")
        }
        return pendingConfirm
    }

    /// Right-click menu for a category chip: rename, color palette, divider,
    /// and a red delete action. Rendered over a transparent click-to-close
    /// backdrop at the mouse's viewport position.
    func categoryMenuHTML() -> some WebUI.View {
        guard let menu = categoryMenu,
              let cat = settings.chatCategories.first(where: { $0.id == menu.categoryID }) else {
            return Group {}
        }
        let left = max(8, min(menu.x, 1080))
        let top = max(8, min(menu.y, 760))
        let cid = enc(cat.id)
        let catColor = cat.color
        let catName = cat.name

        return Group {
            Div(id: "cat-menu-close", class: "ctx-backdrop") {}
                .attribute("data-component-id", "cat-menu-close")

            Div(id: "cat-menu", class: "ctx-menu") {
                if categoryMenuRename {
                    Form(method: nil, id: "cm-rename-form-\(cid)", class: "ctx-rename") {
                        Input(id: "cat-rename-input", name: "cat-rename-input", type: nil, value: catName, attributes: [("autofocus", "")])
                        ArcButton("Save", id: nil, component: nil, class: "primary-btn", type: .submit)
                    }
                    .attribute("data-prevent-enter", "false")
                } else {
                    ArcButton("\u{270E} Rename", id: "cm-rename-\(cid)", component: nil, class: "ctx-item")
                }

                Div(class: "ctx-swatches") {
                    Div(class: "ctx-label") { Text("Color") }
                    Div(class: "ctx-swatch-row") {
                        ForEach(AppState.palette) { c in
                            let sel = c == catColor ? " sel" : ""
                            let hex = c.hasPrefix("#") ? String(c.dropFirst()) : c
                            ArcButton("", id: "cm-color-\(hex)", component: nil, class: "menu-swatch\(sel)")
                                .attribute("data-color", c)
                                .attribute("aria-label", c)
                                .attribute("style", "background:\(c)")
                        }
                    }
                }

                Div(class: "ctx-divider") {}

                ArcButton("Delete", id: "cm-del-\(cid)", component: nil, class: "ctx-item ctx-danger")
            }
            .attribute("data-component-id", "cat-menu")
            .attribute("style", "left:\(left)px;top:\(top)px")
        }
    }
    /// Everything rendered in #modal-root (delete confirmation + category menu).
    /// Owns the `#modal-root` wrapper so the fragment id rides beside the builder
    /// that emits it.
    func modalRootHTML() -> some WebUI.View {
        Div(id: "modal-root") {
            modalHTML()
            categoryMenuHTML()
        }
    }

    // MARK: - Panel

    func panelHTML() async -> some WebUI.View {
        // resolve the plugin seam before the synchronous view builder runs
        let plugin: String?
        if let tab = sidebarTab(activeTabID) {
            plugin = await tab.panelHTML()
        } else {
            plugin = nil
        }
        return Div {
            if let plugin {
                // plugin seam: the third-party ABI is a plain html fragment
                // (`SidebarTab.panelHTML()`), sanitized by the kit. this Raw
                // is permanent and is the one documented Raw in this file;
                // it is not a `legacy(...)` bridge and not counted in the
                // bridge budget.
                Raw(.trusted(plugin))
            } else {
                // chatPanel() still returns String (2.3's target); bridge it.
                legacy(chatPanel()) // TODO(phase 2.3)
            }
        }.attribute("id", "panel")
    }

    /// Panel content for a built-in view id (dispatched through the tab
    /// protocol adapter).
    func renderPanel(for kind: ViewID) -> some WebUI.View {
        Group {
            switch kind {
            case .chat:
                legacy(chatPanel()) // TODO(phase 2.3)
            case .skills:
                skillsPanel()
            case .profiles:
                profilesPanel()
            case .tools:
                toolsPanel()
            case .workspaces:
                workspacesPanel()
            case .kanban:
                legacy(kanbanPanel())        // TODO(phase 7)
            case .memory:
                legacy(memoryPanel())        // TODO(phase 7)
            case .insights:
                legacy(insightsPanel())      // TODO(phase 7) — Insights.swift
            case .settings:
                settingsPanel()
            case .logs:
                legacy(logsPanel())          // TODO(phase 7)
            case .tasks:
                legacy(tasksPanel())         // TODO(phase 7) — NewFeatures.swift
            case .todos:
                legacy(chatPanel(todos: true)) // TODO(phase 2.3)
            }
        }
    }

    // MARK: Chat panel

    func chatPanel(todos: Bool = false) -> String {
        let newBtn = btn("chat-new", "chat-new", "plus-btn", WebUIIcon(.plus, size: .medium).markup.html, " title=\"New chat\"")
        // UX-18: one archive affordance. The text link below the filter bar
        // owns "Show/Hide archived conversations" (explicit label, chevron
        // state, and it is back in the tab order — it is the only control
        // now). The header's bare archive glyph is gone: two controls doing
        // the same thing read as noise.
        let actions = todos ? "" : newBtn
        // UX-62: empty drafts pile up from a stray `+` — three identical
        // "New chat · 0 msg" rows is exactly the clutter this clears — and
        // there was no way to remove them. Offer the cleanup only where it
        // applies (the Chats list, not the archived view) and only when there
        // is something to clear. The chat you are currently in is never
        // counted: clearing must not close the composer out from under you.
        let activeEmpty = sessions.first(where: { $0.id == activeSessionID })
            .map { $0.messageCount == 0 } ?? false
        let emptyDrafts = sessions.filter {
            !$0.id.hasPrefix("Cron-") && !isArchived($0.id) && $0.messageCount == 0
        }.count
        let clearableDrafts = max(0, emptyDrafts - (activeEmpty ? 1 : 0))
        let clearBtn = (!todos && !showArchived && clearableDrafts > 0)
            ? btn(
                "chat-clear-empty", "chat-clear-empty", "arch-link",
                "<span class=\"arch-ico\">\(WebUIIcon(.trash, size: .small).markup.html)</span><span> Clear \(clearableDrafts) empty chat\(clearableDrafts == 1 ? "" : "s")</span>",
                " data-tip=\"Delete conversations with no messages\"")
            : ""
        let head = """
        <div class="panel-head">
          <span class="panel-title">\(todos ? "Todos" : "Chats")</span>
          <div class="panel-actions">\(actions)</div>
        </div>
        <div class="filter-bar">
          <span class="filter-ico">\(WebUIIcon(.search, size: .small).markup.html)</span>
          <input id="chat-search-input" data-component-id="chat-search-input" type="search" placeholder="Filter conversations…" aria-label="Filter conversations" value="\(esc(chatFilter))">
        </div>
        \(render(categoryCloudHTML()))
        \(todos ? "" : """
        <button type="button" id="chat-showarch-link" data-component-id="chat-showarch" class="arch-link" title="Toggle archived">
          <span class="arch-ico">\(WebUIIcon(showArchived ? .chevronDown : .chevronRight, size: .small).markup.html)</span><span>\(showArchived ? " Hide archived conversations" : " Show archived conversations")</span>
        </button>
        \(showArchived ? "<div class=\"arch-mode-note\">Showing archived conversations only.</div>" : "")
        """)
        \(clearBtn)
        """
        var rows: [String] = []
        let bookmarks = settings.bookmarkedSessions
        // On the Todos page archived chats are never shown (no toggle exists).
        var visible = todos
            ? sessions.filter { !$0.id.hasPrefix("Cron-") && !isArchived($0.id) }
            : sessions.filter { !$0.id.hasPrefix("Cron-") && (showArchived ? isArchived($0.id) : !isArchived($0.id)) }
        if activeCategory != "all" {
            visible = visible.filter { activeCategory == "unassigned" ? categoryID(for: $0.id) == nil : categoryID(for: $0.id) == activeCategory }
        }
        if !chatFilter.isEmpty {
            visible = visible.filter { sessionTitle($0).localizedCaseInsensitiveContains(chatFilter) }
        }
        let ordered = visible.sorted { $0.updatedAt > $1.updatedAt }
                // Round-3 UX-27: a pin is a promise that the chat floats to the top.
                // Sorting bookmarked-first and THEN bucketing by date threw that order
                // away (the pinned row stayed in its day bucket with just a badge), so
                // pinned chats now get their own group above the date buckets.
                let pinned = ordered.filter { bookmarks.contains($0.id) }
                let unpinned = ordered.filter { !bookmarks.contains($0.id) }
                if !pinned.isEmpty {
                    rows.append(render(groupHTML(key: "pinned", title: "Pinned", sessions: pinned, todos: todos)))
                }
                // arc parity: chats are bucketed into Today / Yesterday / Earlier this
                // week / Older (youngest first within each bucket); each bucket is
                // collapsible. Yesterday splits out of the 1-6 day band so a chat from
                // last night is not mislabelled "a week old" every morning.
                let buckets: [(String, String)] = [("today", "Today"), ("yesterday", "Yesterday"), ("week", "Earlier this week"), ("older", "Older")]
                var grouped: [String: [Session]] = [:]
                for s in unpinned { grouped[bucketKey(s.updatedAt), default: []].append(s) }
        for (key, title) in buckets {
            if let list = grouped[key], !list.isEmpty {
                rows.append(render(groupHTML(key: key, title: title, sessions: list, todos: todos)))
            }
        }
        if rows.isEmpty {
            // Tell the truth about WHY the list is empty: an unmatched filter
            // must not claim the workspace has no chats at all.
            let msg: String
            if !chatFilter.isEmpty {
                msg = "No chats match “\(chatFilter)”."
            } else if todos {
                msg = "No chats yet."
            } else if showArchived {
                msg = "No archived chats."
            } else if activeCategory != "all" && activeCategory != "unassigned" {
                msg = "No chats in this category yet."
            } else {
                msg = "No chats yet — press + to start one."
            }
            rows.append("<div class=\"empty-hint\">\(esc(msg))</div>")
        }
        return """
        \(head)
        <div class="panel-body" id="sess-list-body" data-scroll-key="sessions" data-component-id="sess-list" data-event="click">
          \(rows.joined())
        </div>
        """
    }

    /// The category chips row: All / Unassigned / one chip per category, plus
    /// the add (or, in manage mode, cancel) button. Chips carry `aria-pressed`
    /// because they are filters, not navigation.
    func categoryCloudHTML() -> some WebUI.View {
        let allActive = activeCategory == "all" ? " active" : ""
        let unActive = activeCategory == "unassigned" ? " active" : ""
        let plusIcon = addingCategory ? WebUIIcon(.x, size: .small) : WebUIIcon(.plus, size: .small)
        return Group {
            Div(class: "cat-bar") {
                ArcButton(id: "cat-all", component: nil, class: "cat-chip\(allActive)", tabIndex: -1) {
                    Text("All")
                }
                .attribute("aria-pressed", "\(activeCategory == "all")")
                ArcButton(id: "cat-unassigned", component: nil, class: "cat-chip\(unActive)", tabIndex: -1) {
                    Text("Unassigned")
                }
                .attribute("aria-pressed", "\(activeCategory == "unassigned")")
                for cat in settings.chatCategories {
                    let cid = enc(cat.id)
                    let active = activeCategory == cat.id ? " active" : ""
                    if addingCategory {
                        // Manage mode: container chip with a filter button + delete ✕ as
                        // SIBLINGS (nested <button> elements would be split by the HTML
                        // parser and break the layout).
                        Div(class: "cat-chip\(active)") {
                            ArcButton(id: "cat-\(cid)", component: nil, class: "cat-chip-btn") {
                                Span(class: "cat-dot") {}
                                    .attribute("style", "background:\(cat.color)")
                                Span { Text(cat.name) }
                            }
                            ArcButton(id: "cat-del-\(cid)", component: nil, class: "chip-x") {
                                WebUIIcon(.x, size: .small)
                            }
                            .attribute("title", "Delete category")
                        }
                    } else {
                        ArcButton(id: "cat-\(cid)", component: nil, class: "cat-chip\(active)") {
                            Span(class: "cat-dot") {}
                                .attribute("style", "background:\(cat.color)")
                            Span { Text(cat.name) }
                        }
                        .attribute("aria-pressed", "\(activeCategory == cat.id)")
                    }
                }
                ArcButton(id: "cat-add", component: nil, class: "cat-chip cat-add", tabIndex: -1) {
                    plusIcon
                }
                .attribute("title", addingCategory ? "Cancel" : "Add category")
            }
            .attribute("data-component-id", "cat-pick")
            .attribute("data-event", "click")

            if addingCategory {
                Form(action: "", method: nil, id: "cat-add-form", class: "cat-add-form") {
                    Input(id: "cat-name-input", name: "cat-name-input",
                          placeholder: "Category name", type: .text)
                        .attribute("data-component-id", "cat-name-input")
                        .attribute("autofocus", "")
                    Input(id: "cat-color-input", name: "cat-color-input", type: .hidden)
                        .attribute("class", "color-value")
                        .attribute("value", AppState.palette[0])
                    Div(class: "cat-swatches") {
                        for (i, c) in AppState.palette.enumerated() {
                            ArcButton(id: nil, component: nil, class: "cat-swatch\(i == 0 ? " sel" : "")") {}
                                .attribute("data-color", c)
                                .attribute("style", "background:\(c)")
                                .attribute("aria-label", c)
                        }
                    }
                    Div(class: "cat-add-actions") {
                        ArcButton("Add", class: "primary-btn", type: .submit)
                        ArcButton("Cancel", id: "cat-add-cancel", component: nil, class: "ghost-btn")
                    }
                }
                .attribute("data-component-id", "cat-add-form")
            }
        }
    }

    /// The running turn's state as a one-line label (`Responding…`, `Running
    /// <tool>…`, `Awaiting approval…`), shared by the sidebar's status pill.
    func liveStatusLabel(_ live: LiveTurn) -> String {
        switch live.status {
        case "tool": return live.toolName.map { "Running \(trunc($0, 18))…" } ?? "Running a tool…"
        case "approval": return "Awaiting approval…"
        case "error": return "Turn failed"
        case "done": return ""
        default: return "Responding…"
        }
    }

    /// Sidebar live-status pill: the running turn shown on its own session row
    /// (replaces the floating "Responding…" hint that read as list noise).
    func liveStatusPill(_ sessionID: String) -> some WebUI.View {
        let label = activeTurns[sessionID].map { liveStatusLabel($0) } ?? ""
        // the label is its own node so a tight row ellipsises it
        // (`.sess-status-label`) instead of overflowing the count/time — or, as
        // it did, wrapping the meta line and growing the row 56 -> 92px.
        return Group {
            if !label.isEmpty {
                Span(class: "sess-status") {
                    Span(class: "sess-status-dot") {}
                    Span(class: "sess-status-label") { Text(label) }
                }
            }
        }
    }

    /// arc-parity relative time: 1m / 12m / 3h / 4d / Aug 28 (+year if older
    /// than this year). Mirrors the client-side ladder in init.js.
    func relTimeLabel(_ d: Date) -> String {
        let now = Date()
        let diff = max(0, now.timeIntervalSince(d))
        if diff < 60 { return "1m" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(max(days, 1))d" }
        let comps = cal.dateComponents([.month, .day, .year], from: d)
        guard let m = comps.month, let day = comps.day else { return "" }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if let y = comps.year, y != cal.component(.year, from: now) {
            return "\(months[m - 1]) \(day), \(String(y).suffix(2))"
        }
        return "\(months[m - 1]) \(day)"
    }

    /// Bucket key: today (same calendar day), yesterday (1 day ago), week
    /// (2-6 days ago), older (7+). Yesterday splits out of the old 1-6 day
    /// band so a chat from last night is not mislabelled "a week old".
    func bucketKey(_ d: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "week" }
        return "older"
    }

    /// One collapsible bucket: caret + title + count + the session rows.
    /// `sessionRow` still returns `String` (2.3b) — bridged through the
    /// sanctioned `legacy(...)` with a `// TODO(phase 2.3b)`.
    func groupHTML(key: String, title: String, sessions: [Session], todos: Bool = false) -> some WebUI.View {
        Div(class: "sess-group") {
            ArcButton(
                id: "sess-grp-\(key)",
                component: nil,                 // the group head owns no boundary
                class: "sess-group-head",
                tabIndex: -1                    // quiet utility, not a tab stop
            ) {
                Span(class: "sess-caret") { WebUIIcon(.chevronDown, size: .small) }
                Span(class: "sess-group-title") { Text(title) }
            }
            .attribute("title", title)
            // no aria-label: the head's own `.sess-group-title` span already names
            // it, so a label would be a redundant second name — and the phase's
            // contract is that a conversion changes NO bytes.
            Div(class: "sess-group-rows") {
                for s in sessions {
                    sessionRow(s, todos: todos)
                }
            }
        }
        .attribute("data-grp", key)
    }

func sessionRow(_ s: Session, todos: Bool = false) -> some WebUI.View {
        let encID = enc(s.id)
        let isActiveRow = s.id == activeSessionID
        let active = isActiveRow ? " active" : ""
        let archived = isArchived(s.id) ? " archived" : ""
        // UX-06: the VISIBLE title stays clamped to 40 chars, but the full
        // stored title rides the row's `title` (hover), its accessible name
        // (aria-label) and a `data-full-title` the rename flow seeds from
        // (wave 4) — identical truncated rows are otherwise indistinguishable.
        let full = sessionTitle(s)
        let title = trunc(full, 40)
        // UX-07 roving: the ROW is the single tab stop (active row tabindex
        // 0, everyone else -1; ArrowUp/Down moves focus between rows). The
        // open button and the ⋮ menu are quiet utilities: out of the tab
        // order, but still reachable by keyboard through the row (Enter opens,
        // Menu/Shift+F10 opens the ⋮ menu).
        let rowTab = isActiveRow ? 0 : -1
        let rowClass = "sess-row\(active)\(archived)"
        if todos {
            // Minimal variant for the Todos page: chat title only — no meta,
            // no ⋮ menu, no category dot, no pin badge.
            let row = Div(class: rowClass) {
                ArcButton(id: "s-open-\(encID)", component: nil, class: "sess-open", tabIndex: -1) {
                    Span(class: "sess-title") { Text(title) }
                }
            }
            .attribute("tabindex", "\(rowTab)")
            .attribute("role", "group")
            .attribute("title", full)
            .attribute("aria-label", full)
            .attribute("data-full-title", full)
            .attribute("data-sid", s.id)
            // aria-current is presence-only and `.attribute` takes a value, so
            // the active shape is a second branch rather than `aria-current=""`.
            return Group {
                if isActiveRow {
                    row.attribute("aria-current", "true")
                } else {
                    row
                }
            }
        }
        let booked = isBookmarked(s.id)
        // Summaries carry the metadata count; loaded sessions use the live array.
        let count = s.messages.isEmpty ? s.messageCount : s.messages.count
        let epochMs = Int(s.updatedAt.timeIntervalSince1970 * 1000)
        let pinLabel = booked ? "Unpin conversation" : "Pin conversation"
        let arcLabel = archived.isEmpty ? "Archive conversation" : "Unarchive conversation"
        let catID = categoryID(for: s.id)
        let catColor = categoryColor(for: catID)
        let catName = categoryName(for: catID)
        let row = Div(class: rowClass) {
            ArcButton(id: "s-open-\(encID)", component: nil, class: "sess-open", tabIndex: -1) {
                Span(class: "sess-title") {
                    if booked {
                        Span(class: "pin-badge") { WebUIIcon(.bookmark, size: .small) }
                            .attribute("title", "Pinned")
                    }
                    Text(title)
                }
                Span(class: "sess-meta") {
                    Text("\(count) msg • ")
                    Span(class: "rel-time") { Text(relTimeLabel(s.updatedAt)) }
                        .attribute("data-reltime", "\(epochMs)")
                    if !archived.isEmpty { Text(" • Archived") }
                    liveStatusPill(s.id)
                }
            }
            Div(class: "row-actions") {
                Div(class: "menu-wrap") {
                    Div(class: "menu-left") {
                        if !catColor.isEmpty {
                            Span(class: "cat-dot cat-rowdot") {}
                                .attribute("style", "background:\(catColor)")
                                .attribute("title", catName)
                        }
                    }
                    ArcButton(id: "s-menu-\(encID)", component: nil, class: "menu-dots", tabIndex: -1) {
                        if activeTurns[s.id] != nil {
                            Span(class: "row-spin") {}
                            Span(class: "row-dots") { Text("⋮") }
                        } else {
                            Text("⋮")
                        }
                    }
                    .attribute("title", "Chat actions")
                    Div(class: "chat-menu") {
                        Div(class: "chat-menu-items") {
                            ArcButton("Copy conversation link", id: "sm-copy-\(encID)", class: "")
                                .attribute("data-sid", s.id)
                            ArcButton("Rename conversation", id: "sm-rename-\(encID)", class: "")
                                .attribute("data-sid", s.id)
                            ArcButton(pinLabel, id: "sm-pin-\(encID)", class: "")
                                .attribute("data-sid", s.id)
                            ArcButton(arcLabel, id: "sm-arc-\(encID)", class: "")
                                .attribute("data-sid", s.id)
                            // Category picker inside the "⋮" menu: a hover flyout
                            // submenu to the right of "Set category" (arc parity),
                            // keeping category option button ids so the existing
                            // chat-menu wire handles them unchanged.
                            ArcButton(id: "sm-catmenu-\(encID)", component: nil, class: "menu-item-head catmenu-head") {
                                Span { Text("Move to Category") }
                                Span(class: "menu-arrow") { WebUIIcon(.chevronRight, size: .small) }
                            }
                            ArcButton("Duplicate conversation", id: "sm-dup-\(encID)", class: "")
                                .attribute("data-sid", s.id)
                            ArcButton("Delete conversation", id: "sm-del-\(encID)", class: "danger")
                                .attribute("data-sid", s.id)
                        }
                        // "Move to Category" swaps this menu's items for a
                        // category panel (client-side panel swap; the category
                        // buttons keep their wire ids).
                        // The panel must be a SIBLING of .chat-menu-items: when JS
                        // hides the items container, a nested panel would be
                        // hidden with it.
                        Div(class: "chat-menu-panel") {
                            Div(class: "cat-panel-head") {
                                ArcButton(id: "sm-catback-\(encID)", component: nil, class: "cat-panel-back") {
                                    WebUIIcon(.chevronLeft, size: .small)
                                }
                                .attribute("title", "Back")
                                Span(class: "cat-panel-title") { Text("Move to Category") }
                            }
                            Div(class: "cat-panel-list") {
                                ArcButton(id: "sm-uncat-\(encID)", component: nil, class: catID == nil ? "menu-sel" : "") {
                                    Text("No Project")
                                    if catID == nil { WebUIIcon(.check, size: .small) }
                                }
                                for c in settings.chatCategories {
                                    ArcButton(id: "sm-cat-\(enc(c.id)).\(encID)", component: nil, class: c.id == catID ? "menu-sel" : "") {
                                        Span(class: "cat-dot") {}
                                            .attribute("style", "background:\(c.color)")
                                        Span {
                                            Text(c.name)
                                            if c.id == catID { WebUIIcon(.check, size: .small) }
                                        }
                                    }
                                    .attribute("data-sid", s.id)
                                }
                            }
                        }
                        .attribute("id", "catpanel-\(encID)")
                        .attribute("hidden", "")
                    }
                    .attribute("data-component-id", "chat-menu")
                    .attribute("data-event", "click")
                    .attribute("id", "menu-\(encID)")
                }
            }
        }
        .attribute("tabindex", "\(rowTab)")
        .attribute("role", "group")
        .attribute("title", full)
        .attribute("aria-label", full)
        .attribute("data-full-title", full)
        .attribute("data-sid", s.id)
        return Group {
            if isActiveRow {
                row.attribute("aria-current", "true")
            } else {
                row
            }
        }
    }

    // MARK: Skills panel

    func skillsPanel() -> some WebUI.View {
        let filtered = skills.filter {
            skillFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(skillFilter)
        }
        var groups: [String: [Skill]] = [:]
        for skill in filtered {
            let cat = (skill.category?.isEmpty == false ? skill.category! : "General")
            groups[cat, default: []].append(skill)
        }
        let cats = groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        // Zero skills is not the same as "nothing matched a filter".
        let emptyMessage: String? = cats.isEmpty
            ? (skills.isEmpty ? "No skills yet." : "No skills match “\(skillFilter)”.")
            : nil

        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Skills") }
                Div(class: "panel-actions") {
                    ArcButton(id: "skill-new", component: "skill-new", class: "plus-btn", type: .button) {
                        WebUIIcon(.plus, size: .medium)
                    }
                    .attribute("title", "Add skill")
                }
            }
            Div(class: "filter-bar") {
                Input(id: "skill-search-input", placeholder: "Filter skills…",
                      type: .search, value: skillFilter,
                      attributes: [("data-component-id", "skill-search-input"),
                                   ("aria-label", "Filter skills")])
            }
            Div(class: "panel-body") {
                for cat in cats {
                    let list = groups[cat] ?? []
                    Div(class: "skill-group") {
                        ArcButton(id: "skcat-\(enc(cat))", class: "skill-cat-head", type: .button) {
                            Span(class: "skill-cat-caret") { WebUIIcon(.chevronDown, size: .small) }
                            Span(class: "skill-cat-title") { Text(cat) }
                            Span(class: "skill-cat-count") { Text("(\(list.count))") }
                        }
                        .attribute("title", "Toggle section")
                        Div(class: "skill-cat-rows") {
                            for skill in list {
                                skillRowHTML(skill)
                            }
                        }
                        .attribute("data-component-id", "skill-list")
                    }
                    .attribute("data-grp-skill", cat)
                }
                if let emptyMessage {
                    Div(class: "empty-hint") { Text(emptyMessage) }
                }
            }
        }
    }
    /// One skill row for the sidebar: toggle pill on the left, then bold name
    /// and a truncated one-line description (arc-style skill list).
    func skillRowHTML(_ skill: Skill) -> some WebUI.View {
        let encName = enc(skill.name)
        let active = skill.name == selectedSkill
        let enabled = !skillContextDisabled().contains(skill.name)
        let name = enabled ? "Included in this chat" : "Excluded from this chat"
        return Div(class: "skill-row\(active ? " active" : "")\(enabled ? "" : " disabled")") {
            ArcButton(id: "sk-open-\(encName)", class: "sess-open skill-open", type: .button) {
                Span(class: "sk-name") { Text(skill.name) }
                Span(class: "sk-desc") { Text(trunc(skill.description, 64)) }
            }
            ArcSwitch(id: "sk-toggle-\(encName)", on: enabled, event: "change",
                      value: "sk-toggle-\(encName)", ariaLabel: name)
                .attribute("title", name)
        }
    }
    // MARK: Profiles panel

    func profilesPanel() -> some WebUI.View {
        Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Profiles") }
                Div(class: "panel-actions") {
                    ArcButton(id: "profile-new", component: "profile-new", class: "plus-btn", type: .button) {
                        WebUIIcon(.plus, size: .medium)
                    }
                    .attribute("title", "Add profile")
                }
            }
            Div(class: "panel-body") {
                if profiles.isEmpty {
                    Div(class: "empty-hint") { Text("No profiles — press + to create one.") }
                } else {
                    for p in profiles {
                        let encName = enc(p.name)
                        Div(class: "list-row\(p.name == selectedProfile ? " active" : "")") {
                            ArcButton(id: "pr-open-\(encName)", class: "sess-open sess-open-flush", type: .button) {
                                Span(class: "lr-name") { Text(p.title.isEmpty ? p.name : p.title) }
                                Span(class: "lr-sub") { Text(p.model ?? "") }
                            }
                        }
                        .attribute("data-component-id", "profile-list")
                    }
                }
            }
        }
    }

    // MARK: Tools panel

    func toolsPanel() -> some WebUI.View {
        // round-3 UX-28: a filter with no matches used to render every toolset
        // header reading "0 tools" and keep a detail pane for a tool that was
        // not in the list. say it once, and hide empty groups.
        let matchCount = toolsets.reduce(0) { acc, entry in
            acc + entry.tools.filter { toolFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(toolFilter) }.count
        }
        let noMatch = !toolFilter.isEmpty && matchCount == 0
        // the `mcp` group is ONE bridge tool however many servers are
        // configured, so a bare "1 tool" misleads — the count is meaningless
        // without knowing whether anything is behind it.
        let mcpServers = arcConfig.mcpServers.count

        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Tools") }
            }
            Div(class: "filter-bar") {
                Input(id: "tool-search-input", placeholder: "Filter tools…",
                      type: .search, value: toolFilter,
                      attributes: [("data-component-id", "tool-search-input"),
                                   ("aria-label", "Filter tools")])
            }
            Div(class: "panel-body") {
                if noMatch {
                    Div(class: "empty-hint") { Text("No tools match “\(toolFilter)”.") }
                } else {
                    for entry in toolsets {
                        let toolset = entry.name
                        let tools = entry.tools
                        let encTS = enc(toolset)
                        let disabled = settings.disabledToolsets.contains(toolset)
                        // UX-15: filter tools by name so the catalog is searchable.
                        let filtered = toolFilter.isEmpty
                            ? tools
                            : tools.filter { $0.name.localizedCaseInsensitiveContains(toolFilter) }
                        if toolFilter.isEmpty || !filtered.isEmpty {
                            Div(class: "tool-group") { Text(toolset) }
                            Div(class: "list-row ts-row") {
                                Span(class: "lr-sub lr-sub-grow") {
                                    if toolset == "mcp" {
                                        Text("\(filtered.count) tool · \(mcpServers) server\(mcpServers == 1 ? "" : "s") configured")
                                    } else {
                                        Text("\(filtered.count) tool\(filtered.count == 1 ? "" : "s")")
                                    }
                                }
                                ArcSwitch(id: "ts-\(encTS)", on: !disabled, component: "tools-toggle",
                                          event: "change", value: "ts-\(encTS)",
                                          ariaLabel: "Enable \(toolset) tools")
                                    .attribute("title", disabled ? "Toolset disabled" : "Toolset enabled")
                            }
                            if toolset == "mcp" && mcpServers == 0 {
                                Div(class: "empty-hint") {
                                    Text("No MCP servers configured — add one in Settings → MCP servers. Until then this bridge has nothing to call.")
                                }
                            }
                            for t in filtered {
                                let encT = enc(t.name)
                                let active = t.name == selectedTool
                                let avail = (t.checkFn?() ?? true)
                                Div(class: "list-row\(active ? " active" : "")") {
                                    ArcButton(id: "tl-open-\(encT)", class: "sess-open sess-open-flush", type: .button) {
                                        Span(class: "lr-name") {
                                            toolIcon(t.emoji)
                                            Text(t.name)
                                            if !avail {
                                                Span(class: "lr-sub") { Text(" (needs env)") }
                                            }
                                        }
                                    }
                                }
                                .attribute("data-component-id", "tool-list")
                                .attribute("aria-current", active ? "true" : "")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Workspaces panel

    func workspacesPanel() -> some WebUI.View {
        Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Workspaces") }
                Div(class: "panel-actions") {
                    ArcButton(id: "ws-new", component: "ws-new", class: "plus-btn", type: .button) {
                        WebUIIcon(.plus, size: .medium)
                    }
                    .attribute("title", "New workspace")
                }
            }
            Div(class: "panel-body") {
                for entry in settings.workspaces {
                    let encWS = enc(entry.name)
                    let isMain = entry.name == "main"
                    Div(class: "list-row\(entry.name == settings.activeWorkspace ? " active" : "")") {
                        ArcButton(id: "ws-open-\(encWS)", class: "sess-open sess-open-flush", type: .button) {
                            Span(class: "lr-name") { Text(entry.name) }
                            Span(class: "lr-sub lr-sub-path") {
                                Text(entry.path == WorkspaceEntry.defaultPath(for: "main")
                                     ? "home folder (default)"
                                     : trunc(entry.path, 58))
                            }
                            .attribute("title", entry.path)
                        }
                        Div(class: "row-actions") {
                            // `main` has no delete control: the default workspace
                            // cannot be removed, and the absence is the contract.
                            if !isMain {
                                ArcButton(id: "ws-del-\(encWS)", class: "icon-mini danger", type: .button) {
                                    WebUIIcon(.x, size: .small)
                                }
                                .attribute("title", "Delete")
                            }
                        }
                    }
                    .attribute("data-component-id", "workspace-list")
                }
            }
        }
    }

    // MARK: Settings panel

    func settingsPanel() -> some WebUI.View {
        let rows: [(String, String)] = [
            ("Appearance", "appearance"),
            ("Preferences", "preferences"),
            ("Storage", "storage"),
            ("Tool plugins", "tool-plugins"),
            ("MCP servers", "mcp-servers"),
            ("Sidebar plugins", "sidebar-plugins"),
            ("About", "about"),
        ]
        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Settings") }
            }
            Div(class: "panel-body") {
                // every row anchors to its <section id> in the main pane
                for r in rows {
                    PanelNavRow(r.0, href: "#" + r.1)
                }
            }
        }
    }

    // MARK: - Main

    func mainContentHTML() async -> some WebUI.View {
        // the sidebar tab is a third-party plugin: `mainHTML()` is a String by
        // the SidebarTab contract, so its markup crosses the boundary as
        // trusted raw. everything arc itself emits stays typed.
        let inner: String
        if let tab = sidebarTab(activeTabID) {
            inner = await tab.mainHTML()
        } else {
            inner = render(chatMain())
        }
        return Div(id: "main", class: activeTabID == "chat" ? "chat-main" : nil) {
            Raw(.trusted(inner))
        }
    }

    /// Main content for a built-in view id (dispatched through the tab
    /// protocol adapter).
    func renderMain(for kind: ViewID) -> String {
        switch kind {
        case .chat:
            return render(chatMain())
        case .skills:
            return skillsMain()
        case .profiles:
            return profilesMain()
        case .tools:
            return render(toolsMain())
        case .workspaces:
            return render(workspacesMain())
        case .kanban:
            return kanbanMain()
        case .memory:
            return memoryMain()
        case .insights:
            return insightsMain()
        case .settings:
            return render(settingsMain())
        case .logs:
            return logsMain()
        case .tasks:
            return tasksMain()
        case .todos:
            return todosPanelHTML()
        }
    }

    // MARK: Chat main

    /// The chat header (title + meta + regenerate/delete) as its own node, so a turn
    /// boundary can refresh it without replacing the whole chat region.
    func chatHeaderHTML() -> some WebUI.View {
        let session = activeSession()
        let configName = configName(for: activeSessionID)
        let title = session.map { trunc(sessionTitle($0), 60) } ?? "Chat"
        let count = session.map { $0.messages.isEmpty ? $0.messageCount : $0.messages.count } ?? 0
        let model = settings.modelConfig(named: configName)?.model ?? configName
        let delClass = pendingDelete ? "sess-confirm" : "icon-mini danger"
        return Header(class: "chat-header") {
            Div {
                Div(class: "chat-title") { Text(title) }
                // UX-59: a fresh chat rendered "· 0 messages" — noise before there
                // is anything to count. The count appears only once there are
                // messages; the model name always does.
                Div(class: "chat-meta") {
                    Text(model)
                    if count > 0 {
                        Text(" • \(count) \(count == 1 ? "message" : "messages")")
                    }
                }
            }
            Div(class: "row-actions-main") {
                ArcButton(id: "regen-btn", component: nil, class: "icon-mini") {
                    WebUIIcon(.refreshCw, size: .small)
                }
                .attribute("data-tip", "Regenerate last reply")
                .attribute("aria-label", "Regenerate last reply")
                .attribute("title", "Regenerate last reply")
                ArcButton(id: "chat-del", component: "chat-del", class: delClass) {
                    if pendingDelete {
                        Text("Confirm?")
                    } else {
                        WebUIIcon(.trash, size: .small)
                    }
                }
                .attribute("data-tip", "Delete chat")
                .attribute("aria-label", "Delete chat")
            }
            .attribute("style", "margin:0")
            .attribute("data-component-id", "regen")
            .attribute("data-event", "click")
        }
        .attribute("id", "chat-header")
    }

    func chatMain() -> some WebUI.View {
        let hasSession = activeSessionID != nil
        let session = activeSession()
        // the follow flag is consumed once: the render that scrolls to the
        // bottom clears it, so a later re-render must not re-scroll.
        let follow = forceScrollBottom
        forceScrollBottom = false
        // `.attribute` decorates the NEXT element opened, so the scroller is
        // built on its own and decorated before it is nested in the wrapper —
        // otherwise `data-follow` lands on `.chat-scroll-wrap`.
        let scroller = Div(class: "chat-scroll") {
            Div(class: "chat-inner") {
                messagesHTML(session?.messages ?? [])
            }
            .attribute("id", "chat-inner")
        }
        .attribute("id", "chat-scroll")
        .attribute("data-scroll-key", "chat")
        .attribute("data-session", activeSessionID ?? "")
        // `data-follow` is presence-only, so the scrolling shape is a branch
        // rather than an empty attribute.
        let followedScroller = Group {
            if follow {
                scroller.attribute("data-follow", "bottom")
            } else {
                scroller
            }
        }
        let scroll = Div(class: "chat-scroll-wrap") {
            followedScroller
            // The jump button anchors to its own wrapping container so it sits
            // just above the composer (never overlapping it), at the bottom-right
            // of the scroll viewport.
            ArcButton(id: "scroll-to-bottom", component: "scroll-to-bottom",
                      class: "scroll-to-bottom-btn") {
                Text("↓")
            }
            .attribute("title", "Jump to latest")
            .attribute("aria-label", "Jump to latest")
            .attribute("hidden", "")
            outlineToggleHTML
            outlinePanelHTML
        }
        return Group {
            if hasSession {
                chatHeaderHTML()
                scroll
                composerHTML()
            } else {
                Div(class: "main-view") {
                    Div(class: "blank") {
                        Div(class: "blank-ico") { WebUIIcon(.messageSquare, size: .extraLarge) }
                        Div(class: "blank-title") { Text("Welcome to ARC Agent") }
                        Div(class: "blank-sub") { Text("Pick a conversation on the left, or start a new one.") }
                        ArcButton(id: "blank-chat-new", component: "blank-chat-new",
                                  class: "primary-btn blank-cta") {
                            WebUIIcon(.plus, size: .small)
                            Span { Text("New chat") }
                        }
                    }
                }
                .attribute("style", "justify-content:center")
            }
        }
    }

    /// Floating "Conversation outline" button (reference #2124 parity); hidden
    /// entirely when the appearance setting is off.
    var outlineToggleHTML: some WebUI.View {
        Group {
            if settings.showConversationOutline {
                ArcButton(id: "outline-toggle", component: "outline-toggle",
                          class: "outline-toggle-btn") {
                    Text("☰")
                }
                .attribute("data-event", "click")
                .attribute("data-tip", "Conversation outline")
                .attribute("aria-label", "Toggle conversation outline")
            }
        }
    }

    /// The outline panel itself (server-rendered shell; the JS fills entries
    /// from the rendered user message anchors and handles jumps). Open state is
    /// server-owned — see `AppState.outlineOpen`.
    var outlinePanelHTML: some WebUI.View {
        Group {
            if settings.showConversationOutline {
                Div {
                    Div(class: "outline-header") {
                        Span { Text("Outline") }
                        ArcButton(id: "outline-close", component: "outline-close",
                                  class: "outline-close-btn") {
                            Text("×")
                        }
                        .attribute("data-event", "click")
                        .attribute("title", "Close outline")
                        .attribute("aria-label", "Close outline")
                    }
                    Div(class: "outline-entries") {}
                        .attribute("id", "outline-entries")
                }
                .attribute("id", "outline-panel")
                .attribute("role", "navigation")
                .attribute("aria-label", "Conversation outline")
                .attribute("hidden", outlineOpen ? "" : "")
            }
        }
    }

    func messagesHTML(_ messages: [Message]) -> some WebUI.View {
        var blocks: [any WebUI.View] = []
        var i = 0
        let mode = settings.activityDisplay
        while i < messages.count {
            if messages[i].role == .user {
                blocks.append(messageHTML(messages[i], rawIdx: i))
                i += 1
                continue
            }
            // This assistant segment runs until the next user message. Once a
            // turn has completed, all of its thinking + tool rounds collapse
            // behind one turn-level dropdown with a "Processed Xm Ys" label
            // and a chevron (arc agent webui parity). `transparent_stream` keeps
            // the same block but pre-opened; `hide_all_activity` keeps the
            // legacy final-answer-only rendering.
            var j = i
            while j < messages.count, messages[j].role != .user { j += 1 }
            let seg = Array(messages[i..<j])
            if let block = turnBlockHTML(seg, mode: mode, turnIndex: i) {
                blocks.append(block)
            } else {
                blocks.append(contentsOf: legacySegmentHTML(seg, mode: mode))
            }
            i = j
        }
        // Live turn belongs to its owning session only.
        if let live = activeTurns[activeSessionID ?? ""] {
            blocks.append(liveMessageHTML(live))
        }
        return Group {
            for b in blocks { b }
            if blocks.isEmpty {
                Div(class: "blank") {
                    Div(class: "blank-ico") { WebUIIcon(.messageSquare, size: .extraLarge) }
                    Div(class: "blank-title") { Text("This chat is empty") }
                    Div(class: "blank-sub") { Text("Say hello below — or type / for the command list.") }
                    ArcButton(id: nil, component: nil, class: "ghost-btn blank-cta") {
                        WebUIIcon(.edit, size: .small)
                        Span { Text("Start typing") }
                    }
                    .attribute("data-focus-composer", "")
                }
            }
        }
    }

    /// The role header for an assistant reply: sparkle icon + "ARC Agent" on
    /// the left; the grouped meta row carries the tokens-per-second chip, the
    /// token usage and the produced-at time on the right (arc parity).
    func assistantRoleHeaderHTML(_ m: Message) -> some WebUI.View {
        let tp = m.tps ?? 0
        let ts = fmtMessageTime(m.createdAt)
        // the right group exists only when it would have content: an empty
        // `.mm-right` would still claim layout space beside the spacer.
        let hasUsage = settings.showTokenUsage && m.usage != nil
        let hasTime = !ts.isEmpty
        return Div(class: "msg-meta") {
            Span(class: "mm-left") {
                Span(class: "role-icon assistant") { WebUIIcon(.star, size: .small) }
                Text(" ARC Agent")
                if settings.showTps && tp > 0 {
                    Span(class: "msg-tps-inline") { Text(fmtTps(tp)) }
                        .attribute("title", "Tokens per second")
                }
            }
            Span(class: "mm-spacer") {}
            if hasUsage || hasTime {
                Span(class: "mm-right") {
                    if hasUsage { usageInlineHTML(m) }
                    if hasTime {
                        Span(class: "msg-time") { Text(ts) }
                    }
                }
            }
        }
    }

    /// The body (markdown + tool cards) of an assistant reply.
    func assistantBodyHTML(_ m: Message) -> some WebUI.View {
        let content = m.content ?? ""
        // markdown becomes HTML inside the renderer; it enters the tree as
        // trusted raw at this one seam rather than as an untyped string.
        return Group {
            if !content.isEmpty {
                Div(class: "msg-body") { Raw(.trusted(mdBox(content))) }
            }
            toolChipsHTML(m.toolCalls)
        }
    }

    /// arc parity: input/output token usage, rendered inside the meta row.
    func usageInlineHTML(_ m: Message) -> some WebUI.View {
        Group {
            if settings.showTokenUsage, let u = m.usage {
                Span(class: "msg-usage-inline") {
                    Text("\(fmtTokens(u.promptTokens)) in · \(fmtTokens(u.completionTokens)) out")
                }
            }
        }
    }

    /// reference `_formatTurnDuration`: <60s → "Ns"; else "Xh Ym" / "Xm Ys".
    func formatTurnDuration(_ seconds: Double) -> String {
        let n = Int(max(0, seconds.rounded()))
        if n < 60 { return "\(n)s" }
        let h = n / 3600
        let m = (n % 3600) / 60
        let s = n % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m \(s)s"
    }

    /// `0:42` style clock for the running turn. The live node re-renders on every
    /// push, so the client repaints this label from `data-started` on a 1 s tick
    /// (`overlay.js`) instead of the server recomputing it per push.
    func fmtElapsed(_ since: Date) -> String {
        let n = Int(max(0, Date().timeIntervalSince(since)))
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }

    /// One-line, escaped summary of a tool call's arguments: the first scalar
    /// entries as `key: value · key: value` (keys sorted, so re-renders diff
    /// clean); falls back to the raw text when the JSON does not parse.
    func toolArgSummary(_ raw: String, limit: Int = 68) -> String {
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
        let parsed = (try? JSONSerialization.jsonObject(with: Data(oneLine.utf8))) as? [String: Any]
        guard let parsed, !parsed.isEmpty else { return esc(trunc(oneLine, limit)) }
        let pairs = parsed.sorted { $0.key < $1.key }.prefix(3).map { key, value -> String in
            let val: String
            if let s = value as? String {
                val = s.replacingOccurrences(of: "\n", with: " ")
            } else if let n = value as? NSNumber {
                // JSON numbers and booleans both bridge to NSNumber; the
                // `objCType` "c" marks the boolean case.
                val = String(cString: n.objCType) == "c" ? (n.boolValue ? "true" : "false") : n.stringValue
            } else if value is NSNull {
                val = "null"
            } else {
                val = "…"
            }
            return key + ": " + trunc(val, 24)
        }
        let joined = pairs.joined(separator: " · ")
        return esc(trunc(joined.isEmpty ? oneLine : joined, limit))
    }

    /// `data-webui-key` attribute for a stable engine identity. Empty key in,
    /// empty attribute out — the engine then falls back to its id/index keying,
    /// exactly as before.
    func webuiKeyAttr(_ key: String) -> String {
        key.isEmpty ? "" : " data-webui-key=\"\(key)\""
    }

    /// Stable identity for a message-derived row: creation time in ms. Legacy
    /// messages carry no timestamp and keep the engine's index keying.
    func msgWebuiKey(_ m: Message) -> String {
        guard let d = m.createdAt else { return "" }
        return String(Int(d.timeIntervalSince1970 * 1000))
    }

    func thinkingRowHTML(_ text: String, key: String, innerID: String? = nil, hidden: Bool = false) -> some WebUI.View {
        let row = Details(summary: {
            WebUIIcon(.edit, size: .small)
            Span(class: "tw-label") { Text("Thinking") }
            Span(class: "tw-spacer") {}
            Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
        }, content: {
            Div(class: "tc-detail") {
                if let innerID {
                    Span { Text(text) }.attribute("id", innerID)
                } else {
                    Text(text)
                }
            }
        })
        .attribute("class", "thinking-row")
        // the webui key and the hidden flag are both presence-only
        let keyed = Group {
            if key.isEmpty {
                row
            } else {
                row.attribute("data-webui-key", key)
            }
        }
        return Group {
            if hidden {
                keyed.attribute("hidden", "")
            } else {
                keyed
            }
        }
    }

    func turnBlockHTML(_ seg: [Message], mode: String, turnIndex: Int) -> (any WebUI.View)? {
        guard mode == "compact_worklog" || mode == "transparent_stream" else { return nil }
        guard let finalIdx = seg.lastIndex(where: { $0.role == .assistant && ($0.toolCalls ?? []).isEmpty }) else { return nil }
        var rounds: [(Message, [String: String])] = []
        var i = 0
        while i < seg.count {
            let m = seg[i]
            if m.role == .assistant, let tc = m.toolCalls, !tc.isEmpty {
                var results: [String: String] = [:]
                var j = i + 1
                while j < seg.count, seg[j].role == .tool {
                    if let cid = seg[j].toolCallID { results[cid] = seg[j].content ?? "" }
                    j += 1
                }
                rounds.append((m, results))
                i = j
                continue
            }
            i += 1
        }
        let finalMsg = seg[finalIdx]
        let reasons = rounds.compactMap { $0.0.reasoning } + [finalMsg.reasoning].compactMap { $0 }
        let hasActivity = !rounds.isEmpty || reasons.contains { !$0.isEmpty }
        guard hasActivity else { return nil }

        var rows: [any WebUI.View] = []
        if mode == "compact_worklog" {
            // One aggregated "Thinking" row + one "Ran N commands/tools" row
            // per tool round with a copy button (reference worklog look).
            let allReasoning = reasons.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !allReasoning.isEmpty {
                rows.append(thinkingRowHTML(allReasoning, key: "think-\(turnIndex)"))
            }
            for (idx, pair) in rounds.enumerated() {
                let target = "twc-\(turnIndex)-\(idx)"
                let m = pair.0
                let calls = m.toolCalls ?? []
                let names = calls.map { $0.function.name }
                let summary: String
                if names.allSatisfy({ $0 == "terminal" }) {
                    summary = calls.count == 1 ? "Ran a command" : "Ran \(calls.count) commands"
                } else {
                    summary = calls.count == 1 ? "Ran a tool" : "Ran \(calls.count) tools"
                }
                let row = Details(summary: {
                    WebUIIcon(.tool, size: .small)
                    Span { Text(summary) }
                    Span(class: "tw-spacer") {}
                    ArcButton(id: nil, component: nil, class: "tw-copy", tabIndex: -1) {
                        WebUIIcon(.copy, size: .small)
                    }
                    .attribute("data-copy-target", target)
                    .attribute("title", "Copy this activity")
                    Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
                }, content: {
                    Div(class: "wl-detail") {
                        if let interim = m.content, !interim.isEmpty {
                            Div(class: "msg-body interim") { Raw(.trusted(mdBox(interim))) }
                        }
                        toolChipsHTML(calls, results: pair.1)
                    }
                })
                .attribute("class", "worklog-summary")
                .attribute("id", target)
                .attribute("data-webui-key", target)
                rows.append(row)
            }
        } else {
            // transparent_stream: full cards, block pre-opened.
            for pair in rounds {
                rows.append(activityGroupHTML(pair.0, calls: pair.0.toolCalls ?? [], results: pair.1, mode: "transparent_stream"))
            }
            // Direct replies (no tool rounds) still stream reasoning: surface
            // it as a thinking row so the dropdown body is never empty.
            if let r = finalMsg.reasoning, !r.isEmpty {
                rows.append(thinkingRowHTML(r, key: "think-\(turnIndex)-final"))
            }
        }

        let label = finalMsg.turnDuration.map { "Processed " + formatTurnDuration($0) } ?? "Turn activity"
        // UX-55: a tool-using turn collapsed to a bare "Processed Xs",
        // indistinguishable from a plain reply. Count tools across the turn's
        // rounds and annotate the summary (cards stay behind the disclosure).
        let totalTools = rounds.reduce(0) { $0 + (($1.0.toolCalls ?? []).count) }
        let worklogKey = "tw-\(turnIndex)-\(String(format: "%.3f", finalMsg.createdAt?.timeIntervalSince1970 ?? 0))"
        return Div(class: "assistant-turn") {
            assistantRoleHeaderHTML(finalMsg)
            Details(summary: {
                Span(class: "tw-dot") {}
                Span(class: "tw-label") { Text(label) }
                if totalTools > 0 {
                    Span(class: "tw-tools") { Text("· \(totalTools) tool\(totalTools == 1 ? "" : "s")") }
                }
                Span(class: "tw-spacer") {}
                Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
            }, content: {
                Div(class: "wl-detail tw-body") {
                    for r in rows { r }
                }
            })
            .attribute("class", "turn-worklog")
            .attribute("data-tw-session", activeSessionID ?? "")
            .attribute("data-webui-key", worklogKey)
            Div(class: "msg assistant") {
                Div {
                    assistantBodyHTML(finalMsg)
                    if let reason = finalMsg.terminalReason {
                        terminalCardHTML(for: reason)
                    }
                    msgFootHTML(finalMsg)
                }
                .attribute("style", "max-width:100%;width:100%")
            }
        }
        .attribute("id", "turn-\(turnIndex)")
        .attribute("data-turn-duration", String(format: "%.0f", finalMsg.turnDuration ?? 0))
    }

    /// Legacy per-piece rendering for a completed assistant segment (used when
    /// `turnBlockHTML` declines — e.g. stop/error trunks, hide mode).
    func legacySegmentHTML(_ seg: [Message], mode: String) -> [any WebUI.View] {
        var out: [any WebUI.View] = []
        var i = 0
        while i < seg.count {
            let m = seg[i]
            if m.role == .assistant, let tc = m.toolCalls, !tc.isEmpty {
                var results: [String: String] = [:]
                var j = i + 1
                while j < seg.count, seg[j].role == .tool {
                    if let cid = seg[j].toolCallID { results[cid] = seg[j].content ?? "" }
                    j += 1
                }
                out.append(activityGroupHTML(m, calls: tc, results: results, mode: mode))
                i = j
                continue
            }
            out.append(messageHTML(m))
            i += 1
        }
        return out
    }

    func activityGroupHTML(_ m: Message, calls: [ToolCall], results: [String: String], mode: String) -> some WebUI.View {
        let mk = msgWebuiKey(m)
        return Group {
            switch mode {
            case "hide_all_activity":
                // Final answer only: drop the whole execution trace.
                Group {}
            case "transparent_stream":
                if let r = m.reasoning, !r.isEmpty {
                    thinkingRowHTML(r, key: mk.isEmpty ? "" : "think-r\(mk)")
                }
                if let interim = m.content, !interim.isEmpty {
                    Div(class: "msg-body interim") { Raw(.trusted(mdBox(interim))) }
                }
                for c in calls {
                    toolCardHTML(c, result: results[c.id])
                }
            default:
                // compact_worklog: one quiet, collapsible summary per turn.
                let names = calls.map { $0.function.name }
                let summary = "Ran " + String(calls.count) + " tool call" + (calls.count == 1 ? "" : "s") + " · " + names.joined(separator: ", ")
                let row = Details(summary: {
                    WebUIIcon(.tool, size: .small)
                    Span { Text(summary) }
                    Span(class: "tw-spacer") {}
                    Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
                }, content: {
                    Div(class: "wl-detail") {
                        if let r = m.reasoning, !r.isEmpty {
                            Div(class: "tc-detail thinking-detail") { Text(r) }
                        }
                        if let interim = m.content, !interim.isEmpty {
                            Div(class: "msg-body interim") { Raw(.trusted(mdBox(interim))) }
                        }
                        toolChipsHTML(calls, results: results)
                    }
                })
                .attribute("class", "worklog-summary")
                if !mk.isEmpty {
                    row.attribute("data-webui-key", "ws-" + mk)
                } else {
                    row
                }
            }
        }
    }

    func toolCardHTML(_ c: ToolCall, result: String?) -> some WebUI.View {
        let args = c.function.arguments
        let card = Details(summary: {
            WebUIIcon(.tool, size: .small)
            Span(class: "tc-name") { Text(c.function.name) }
            Span(class: "tc-arg") { Raw(.trusted(toolArgSummary(args))) }
            Span(class: "tw-spacer") {}
            ArcButton(id: nil, component: nil, class: "tc-copy", tabIndex: -1) {
                WebUIIcon(.copy, size: .small)
            }
            .attribute("data-copy", args)
            .attribute("title", "Copy arguments")
            Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
        }, content: {
            Div(class: "tc-detail") {
                Div(class: "tc-label") { Text("Arguments") }
                Preformatted(args).attribute("class", "tc-block")
                if let result, !result.isEmpty {
                    Div(class: "tc-label") { Text("Result") }
                    Preformatted(result).attribute("class", "tc-block")
                }
            }
        })
        .attribute("class", "tool-card")
        return Group {
            if c.id.isEmpty {
                card
            } else {
                card.attribute("data-webui-key", "tc-\(c.id)")
            }
        }
    }

    func messageHTML(_ m: Message, rawIdx: Int = -1) -> some WebUI.View {
        return Group {
            switch m.role {
            case .user:
                // Slash-command rewrites (skill invocation scaffolding) keep the
                // typed line as the display text; the model sees `content`.
                let content = m.displayText ?? m.content ?? ""
                let bubble = Div(class: "msg user") {
                    Div(class: "msg-body user-bubble") { Raw(.trusted(mdBox(content))) }
                }
                if rawIdx >= 0 {
                    bubble.attribute("id", "msg-user-\(rawIdx)")
                } else {
                    bubble
                }
            case .assistant:
                // Terminal-state status card (e.g. tool iteration limit reached,
                // turn stopped, model connection lost) under the reply that ended
                // the turn.
                let block = Div(class: "msg assistant") {
                    Div {
                        assistantRoleHeaderHTML(m)
                        assistantBodyHTML(m)
                        if let reason = m.terminalReason {
                            terminalCardHTML(for: reason)
                        }
                        msgFootHTML(m)
                    }
                    .attribute("style", "max-width:100%;width:100%")
                }
                if rawIdx >= 0 {
                    block.attribute("id", "msg-\(rawIdx)")
                } else {
                    block
                }
            case .tool:
                // Tool results render as the same expandable card family as calls:
                // icon + name + a one-line preview, expanding to the full output.
                let content = m.content ?? ""
                let preview = trunc(content.replacingOccurrences(of: "\n", with: " "), 96)
                let resultKey = m.toolCallID.map { "tr-\($0)" }
                    ?? m.createdAt.map { "tr-\(Int($0.timeIntervalSince1970 * 1000))" } ?? ""
                let card = Details(summary: {
                    WebUIIcon(.tool, size: .small)
                    Span(class: "tc-name") { Text(m.name ?? "tool") }
                    Span(class: "tc-arg") { Text(preview) }
                    Span(class: "tw-spacer") {}
                    Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
                }, content: {
                    Div(class: "tc-detail") {
                        Div(class: "tc-label") { Text("Result") }
                        Preformatted(content).attribute("class", "tc-block")
                    }
                })
                .attribute("class", "tool-card")
                let keyed = Group {
                    if resultKey.isEmpty {
                        card
                    } else {
                        card.attribute("data-webui-key", resultKey)
                    }
                }
                let block = Div(class: "msg assistant") {
                    Div { keyed }.attribute("style", "width:100%")
                }
                if rawIdx >= 0 {
                    block.attribute("id", "msg-\(rawIdx)")
                } else {
                    block
                }
            case .system:
                // system prompts are the model's, never the reader's
                Group {}
            }
        }
    }

    /// Arc-parity terminal-state card: rendered under the reply that ended a
    /// turn abnormally. Covers the tool-iteration limit (the classic case)
    /// and interrupted turns — user stop or model connection loss — so the
    /// UI always explains WHY the turn ended the way it did.
    func terminalCardHTML(for reason: String) -> some WebUI.View {
        Group {
            switch reason {
            case "user_stopped":
                interruptionCardHTML(
                    icon: .square, title: "Turn stopped",
                    sub: "Stopped by the user before the reply finished.",
                    state: "Stopped by user", next: "Start a new turn to continue.")
            case "disconnected":
                interruptionCardHTML(
                    icon: .alertTriangle, title: "Model connection lost",
                    sub: "The connection to the model was lost, so the turn was interrupted.",
                    state: "Disconnected", next: "Start a new turn to continue.")
            default:
                limitCardHTML()
            }
        }
    }

    /// The tool-iteration-limit status card (shown under the final reply when
    /// the tool-iteration budget was exhausted). Same shell as every other
    /// terminal card — it only pre-dates the shared builder.
    func limitCardHTML() -> some WebUI.View {
        interruptionCardHTML(
            icon: .zap, title: "Tool iteration limit reached",
            sub: "Stopped because the tool iteration limit was reached.",
            state: "Limit reached", next: "Start a new turn to continue.")
    }

    /// Shared shell for interruption status cards (same look as the limit
    /// card, distinct icon/colors per terminal reason).
    func interruptionCardHTML(icon: IconName, title: String, sub: String, state: String, next: String) -> some WebUI.View {
        Div(class: "limit-card") {
            Div(class: "limit-head") {
                Span(class: "limit-ico") { WebUIIcon(icon, size: .small) }
                Span(class: "limit-title") { Text(title) }
            }
            Div(class: "limit-sub") { Text(sub) }
            Div(class: "limit-rows") {
                Div(class: "limit-row") {
                    Span(class: "limit-k") { Text("State") }
                    Span(class: "limit-v") { Text(state) }
                }
                Div(class: "limit-row") {
                    Span(class: "limit-k") { Text("Next step") }
                    Span(class: "limit-v") { Text(next) }
                }
            }
        }
    }

    /// Tool calls as compact cards (icon + name + argument summary, expanding
    /// to the full JSON and — when paired — the result). `results` pairs a
    /// call with the tool message carrying its output.
    func toolChipsHTML(_ calls: [ToolCall]?, results: [String: String] = [:]) -> some WebUI.View {
        Group {
            if let calls, !calls.isEmpty {
                Div(class: "tool-pills") {
                    for c in calls { toolCardHTML(c, result: results[c.id]) }
                }
            }
        }
    }

    func liveMessageHTML(_ live: LiveTurn) -> some WebUI.View {
        let mode = settings.activityDisplay
        // The thinking row's `#live-turn-thinking` span must exist in the served
        // markup from the turn's first render: the streaming push writes its
        // reasoning into that span with `FragmentUpdate.text` ops, and a span
        // that only materializes alongside the first reasoning chunk lets a
        // coalesced early op hit "[WebUIEngine] Element not found:
        // #live-turn-thinking". The row is hidden at rest (no reasoning yet,
        // or the activity-display mode suppresses it) and the structural
        // re-render unhides it the moment reasoning begins — the span is
        // always present, invisible or not.
        let thinkingRow = thinkingRowHTML(live.thinking, key: "live-think", innerID: "live-turn-thinking",
            hidden: mode == "hide_all_activity" || live.thinking.isEmpty)
        // arc parity: live tokens-per-second chip in the streaming header.
        let liveTps = live.tps ?? 0
        return Div(class: "msg assistant streaming") {
            Div {
                Div(class: "msg-meta") {
                    Span(class: "mm-left") {
                        Span(class: "role-icon assistant") { WebUIIcon(.star, size: .small) }
                        Text(" ARC Agent")
                        if settings.showTps && liveTps > 0 {
                            Span(class: "msg-tps-inline") { Text(fmtTps(liveTps)) }
                                .attribute("title", "Tokens per second")
                        }
                    }
                    Span(class: "mm-spacer") {}
                    Span(class: "mm-right") {
                        Span(class: "msg-elapsed") { Text(fmtElapsed(live.startedAt)) }
                            .attribute("data-elapsed", "")
                            .attribute("data-started", "\(Int(live.startedAt.timeIntervalSince1970 * 1000))")
                    }
                }
                // the status line sits first: everything that grows below it
                // (reasoning, streamed text, tool pills) then reflows behind it,
                // so nothing above the growth ever moves (CLS: the status line
                // was being pushed down per token).
                switch live.status {
                case "tool":
                    if mode != "hide_all_activity" {
                        Div(class: "live-status") {
                            Span {
                                WebUIIcon(.tool, size: .small)
                                Text(" Running")
                                if let name = live.toolName {
                                    Text(" " + name)
                                }
                                Text("…")
                            }
                            if let started = live.toolStartedAt {
                                Span(class: "msg-elapsed") { Text(fmtElapsed(started)) }
                                    .attribute("data-elapsed", "")
                                    .attribute("data-started", "\(Int(started.timeIntervalSince1970 * 1000))")
                            }
                        }
                    }
                case "error":
                    Div(class: "live-status") {
                        Span {
                            WebUIIcon(.alertTriangle, size: .small)
                            Text(" " + (live.error ?? "Turn failed"))
                        }
                    }
                    .attribute("style", "color:var(--danger)")
                case "approval":
                    Div(class: "live-status") {
                        Span {
                            WebUIIcon(.alertTriangle, size: .small)
                            Text(" Waiting for your approval…")
                        }
                    }
                case "done":
                    // nothing: the committed message replaces this node
                    Group {}
                default:
                    if mode != "hide_all_activity" {
                        Div(class: "live-status") {
                            Span {
                                WebUIIcon(.edit, size: .small)
                                Text(" Responding…")
                            }
                        }
                    }
                }
                thinkingRow
                Div(class: "msg-body") {
                    Span { Text(live.assistantText) }
                        .attribute("id", "live-turn-text")
                    if live.status == "running" {
                        Span(class: "stream-cursor") {}
                    }
                }
                .attribute("id", "live-turn-body")
                .attribute("style", "white-space:pre-wrap")
                if mode == "transparent_stream" && !live.toolChips.isEmpty {
                    Div(class: "tool-pills") { Raw(.trusted(live.toolChips.joined())) }
                }
            }
            .attribute("style", "width:100%")
        }
        .attribute("id", "live-turn")
        .attribute("data-streaming", "true")
        .attribute("data-session", live.sessionID)
    }

    // MARK: Composer flyout (arc parity: approval + clarification cards)

    func composerFlyoutHTML() -> some WebUI.View {
        let sid = activeSessionID ?? ""
        return Group {
            if let pa = pendingApproval, pa.sessionID == sid {
                approvalCardHTML(command: pa.command, description: pa.description)
            } else if let pc = pendingClarify, pc.sessionID == sid {
                clarifyCardHTML(pc)
            } else if isYolo(sid) {
                yoloPillHTML()
            }
        }
    }

    /// arc-style approval card: attached to the composer, orange header,
    /// command code block, Allow once / session / always / deny + skip-all.
    func approvalCardHTML(command: String, description: String) -> some WebUI.View {
        Div(class: "approval-card visible") {
            Div(class: "approval-inner") {
                Div(class: "approval-head") {
                    Span(class: "approval-ico") { WebUIIcon(.alertTriangle, size: .small) }
                    Span(class: "approval-title") { Text("Approval required") }
                    ArcButton(id: "approval-collapse", component: nil, class: "approval-collapse") {
                        WebUIIcon(.chevronDown, size: .small)
                    }
                    .attribute("title", "Collapse")
                    ArcButton(id: "approval-dismiss", component: "approval-dismiss", class: "approval-dismiss") {
                        WebUIIcon(.x, size: .small)
                    }
                    .attribute("data-event", "click")
                    .attribute("title", "Dismiss")
                }
                if !description.isEmpty {
                    Div(class: "approval-desc") { Text(description) }
                }
                Div(class: "approval-cmd") {
                    InlineCode(command)
                }
                Div(class: "approval-btns") {
                    ArcButton(id: "approval-once", component: "approval-once", class: "approval-btn once") {
                        WebUIIcon(.check, size: .small)
                        Span(class: "approval-btn-label") { Text("Allow once") }
                    }
                    .attribute("data-event", "click")
                    ArcButton(id: "approval-session", component: "approval-session", class: "approval-btn session") {
                        WebUIIcon(.lock, size: .small)
                        Span(class: "approval-btn-label") { Text("Allow session") }
                    }
                    .attribute("data-event", "click")
                    ArcButton(id: "approval-always", component: "approval-always", class: "approval-btn always") {
                        WebUIIcon(.star, size: .small)
                        Span(class: "approval-btn-label") { Text("Always allow") }
                    }
                    .attribute("data-event", "click")
                    ArcButton(id: "approval-deny", component: "approval-deny", class: "approval-btn deny") {
                        WebUIIcon(.x, size: .small)
                        Span(class: "approval-btn-label") { Text("Deny") }
                    }
                    .attribute("data-event", "click")
                }
                Div(class: "approval-yolo-row") {
                    ArcButton(id: "approval-yolo", component: "approval-yolo", class: "approval-btn yolo") {
                        WebUIIcon(.zap, size: .small)
                        Span(class: "approval-btn-label") { Text("Skip all this session") }
                    }
                    .attribute("data-event", "click")
                }
            }
        }
    }

    /// arc-style clarification card: question, numbered choices (up to 4),
    /// free-form response row and a 120 s countdown, attached to the composer.
    func clarifyCardHTML(_ pc: PendingClarify) -> some WebUI.View {
        let expiryMs = Int(pc.expiresAt.timeIntervalSince1970 * 1000)
        let remaining = max(1, Int(pc.expiresAt.timeIntervalSinceNow.rounded(.up)))
        return Div(class: "clarify-card visible") {
            Div(class: "clarify-inner") {
                Div(class: "clarify-head") {
                    Span(class: "clarify-ico") { WebUIIcon(.badgeQuestionMark, size: .small) }
                    Span(class: "clarify-title") { Text("Clarification needed") }
                    Span(class: "clarify-countdown") { Text("\(remaining)s") }
                        .attribute("id", "clarify-countdown")
                        .attribute("data-expires", "\(expiryMs)")
                    ArcButton(id: "clarify-collapse", component: nil, class: "clarify-collapse") {
                        WebUIIcon(.chevronDown, size: .small)
                    }
                    .attribute("title", "Collapse")
                }
                Div(class: "clarify-question") { Text(pc.question) }
                if !pc.choices.isEmpty {
                    Div(class: "clarify-choices") {
                        for (i, c) in pc.choices.enumerated() {
                            ArcButton(id: "clarify-choice-\(i)", component: nil, class: "clarify-choice") {
                                Span(class: "clarify-choice-badge") { Text("\(i + 1)") }
                                Span(class: "clarify-choice-text") { Text(c) }
                            }
                        }
                    }
                    .attribute("data-component-id", "clarify-choice")
                    .attribute("data-event", "click")
                }
                Div(class: "clarify-response") {
                    ArcButton(id: "clarify-other", component: nil, class: "clarify-pill pill-other") {
                        Text("Other")
                    }
                    .attribute("title", "Type your own answer")
                    Form(action: "", method: nil, id: "clarify-form", class: "clarify-free") {
                        Input(id: "clarify-input", name: "clarify-input",
                              placeholder: "Type your response...", type: .text)
                            .attribute("data-component-id", "clarify-input")
                            .attribute("autocomplete", "off")
                        ArcButton(id: "clarify-submit", component: nil, class: "clarify-submit", type: .submit) {
                            Text("Send")
                        }
                    }
                    .attribute("data-component-id", "clarify-form")
                    .attribute("data-event", "submit")
                }
                Div(class: "clarify-hint") { Text("Pick a choice, or type your own answer below.") }
            }
        }
    }

    /// Session-level "approvals skipped" pill (reference yolo indicator) with a
    /// restore control.
    func yoloPillHTML() -> some WebUI.View {
        Div(class: "yolo-pill") {
            Span(class: "yolo-ico") { WebUIIcon(.zap, size: .small) }
            Span(class: "yolo-text") { Text("Approvals skipped for this session") }
            ArcButton(id: "yolo-off", component: "yolo-off", class: "yolo-off") {
                Text("Restore")
            }
            .attribute("data-event", "click")
        }
    }
        // MARK: Composer

    // MARK: - Message hover footer (arc parity)

    /// "8:31 AM" for today; "Sep 7, 6:20 PM" for earlier days.
    func fmtMessageTime(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: Date()) ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: d)
    }

    func msgFootHTML(_ m: Message) -> some WebUI.View {
        Div(class: "msg-foot") {
            Span(class: "msg-actions") {
                ArcButton(id: nil, component: nil, class: "msg-copy-btn msg-action-btn", tabIndex: -1) {
                    WebUIIcon(.copy, size: .small)
                }
                .attribute("data-copy", m.content ?? "")
                .attribute("title", "Copy response")
            }
        }
    }

    // MARK: - Context window indicator (arc parity)

    struct CtxSnapshot {
        var usedTokens: Int
        var contextLength: Int
        var threshold: Int
        var cacheRead: Int?
        var cacheWrite: Int?
        var cacheHitPercent: Int?
    }

    /// Token estimate mirroring the compression estimator (chars/4 + 60/msg).
    func estimateTokenCount(_ msgs: [Message]) -> Int {
        var n = 0
        for m in msgs {
            n += (m.content?.count ?? 0) / 4
            n += (m.reasoning?.count ?? 0) / 4
            n += 60
        }
        return n
    }

    /// Snapshot for the context-window ring/tooltip: the prompt tokens the
    /// model last saw (or an estimate), the model's context length, the
    /// auto-compress threshold, and per-session lifetime cache stats.
    func ctxSnapshot(for s: Session) -> CtxSnapshot {
        let presetForChat = settings.modelConfig(named: configName(for: s.id))
        let limit = profileContext(for: s.id)?.contextLength
            ?? presetForChat?.contextLength
            ?? 1_048_576
        let last = s.messages.reversed().compactMap { $0.usage }.first
        let used = last?.promptTokens ?? estimateTokenCount(s.messages)
        let budget = compressionBudget(for: s.id)
        var read = 0
        var total = 0
        var haveCache = false
        for m in s.messages {
            guard let u = m.usage, let c = u.cachedPromptTokens else { continue }
            read += c
            total += u.promptTokens
            haveCache = true
        }
        return CtxSnapshot(
            usedTokens: used,
            contextLength: limit,
            threshold: budget,
            cacheRead: haveCache ? read : nil,
            cacheWrite: haveCache ? max(0, total - read) : nil,
            cacheHitPercent: haveCache && total > 0 ? Int((Double(read) / Double(total) * 100).rounded()) : nil
        )
    }

    /// arc-style token formatter: 254.7k / 1.0M.
    func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(n)
    }

    func ctxIndicatorHTML(_ s: Session) -> some WebUI.View {
        let snap = ctxSnapshot(for: s)
        let pct = snap.contextLength > 0 ? min(100, Int((Double(snap.usedTokens) / Double(snap.contextLength) * 100).rounded())) : 0
        let level = pct > 75 ? " ctx-high" : (pct > 50 ? " ctx-mid" : "")
        let thrPct = snap.contextLength > 0 ? Int((Double(snap.threshold) / Double(snap.contextLength) * 100).rounded()) : 0
        return Group {
            if !s.messages.isEmpty {
                Div(class: "ctx-indicator-wrap") {
                    ArcButton(id: nil, component: nil, class: "ctx-indicator\(level)") {
                        Span(class: "ctx-ring") {
                            // the ring geometry lives in ArcRing: one typed view
                            // instead of an inline <svg> string.
                            ArcRing(percentage: pct)
                            Span(class: "ctx-ring-center") {
                                Text(pct >= 100 ? "99+" : "\(pct)%")
                            }
                        }
                    }
                    .attribute("title", "Context window usage")
                    .attribute("aria-label", "Context window usage")
                    Div(class: "ctx-tooltip") {
                        Div(class: "ctx-tooltip-title") { Text("Context window") }
                        Div(class: "ctx-tooltip-line") { Text("\(pct)% used · \(100 - pct)% left") }
                        Div(class: "ctx-tooltip-line") {
                            Text("\(fmtTokens(snap.usedTokens)) of \(fmtTokens(snap.contextLength)) tokens used")
                        }
                        Div(class: "ctx-tooltip-line") {
                            Text("Auto-compress at \(fmtTokens(snap.threshold)) (\(thrPct)%)")
                        }
                        if let hit = snap.cacheHitPercent, let read = snap.cacheRead, let write = snap.cacheWrite {
                            Div(class: "ctx-tooltip-line") {
                                Text("Cache: \(hit)% hit (\(fmtTokens(read)) read / \(fmtTokens(write)) write)")
                            }
                        }
                    }
                    .attribute("role", "tooltip")
                }
            }
        }
    }

    // MARK: Slash autocomplete + selection context (arc parity)

    /// Slash commands available from the composer (arc agent webui COMMANDS
    /// subset that arc implements). Shared by the autocomplete payload and
    /// `submitChat` dispatch.
    static let slashBuiltins: [(name: String, desc: String, arg: String?)] = [
        ("help", "Show available slash commands", nil),
        ("new", "Start a new chat", nil),
        ("usage", "Toggle token usage display", nil),
        ("theme", "Set or list the color scheme", "[name]"),
        ("skills", "List installed skills", "[query]"),
        ("use", "Force a skill for the next turn", "<skill-name>"),
        ("stop", "Stop the current turn", nil),
        ("title", "Rename this chat", "[title]"),
        ("workspace", "Switch workspace", "<name>"),
        ("model", "Switch model configuration", "<name>"),
    ]

    /// JSON payload for the client-side slash autocomplete (reference
    /// `/api/skills` + COMMANDS merged into one list).
    func slashDataJSON() -> String {
        func jstr(_ v: String) -> String {
            var out = ""
            for ch in v {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return "\"\(out)\""
        }
        var items: [String] = []
        for b in Self.slashBuiltins {
            let arg = b.arg.map { ",\"arg\":" + jstr($0) } ?? ""
            items.append("{\"name\":\(jstr(b.name)),\"desc\":\(jstr(b.desc)),\"kind\":\"builtin\"\(arg)}")
        }
        for skill in skills {
            items.append("{\"name\":\(jstr(skill.name)),\"desc\":\(jstr(skill.description)),\"kind\":\"skill\"}")
        }
        return "{\"items\":[\n      " + items.joined(separator: ",\n      ") + "\n    ]}"
    }

    /// "Context N" chips above the composer (reference `_renderSelectionChips`).
    func selectionChipsHTML() -> some WebUI.View {
        Group {
            if !pendingContexts.isEmpty {
                Div(class: "selection-chips-wrap") {
                    for block in pendingContexts {
                        let preview = AppState.contextPreview(block.text)
                        Article {
                            Div(class: "selection-context-accent") {}
                                .attribute("aria-hidden", "true")
                            Div(class: "selection-context-body") {
                                Div(class: "selection-context-header") {
                                    Span(class: "selection-context-name") { Text(block.name) }
                                    ArcButton(id: block.id, component: nil, class: "selection-context-remove") {
                                        Text("✕")
                                    }
                                    .attribute("title", "Remove context block")
                                }
                                Blockquote(preview)
                                    .attribute("class", "selection-context-quote")
                            }
                        }
                        .attribute("class", "selection-context-card")
                        .attribute("data-selection-id", block.id)
                    }
                }
                .attribute("id", "composer-selection-chips")
                .attribute("data-component-id", "selection-context-del")
                .attribute("data-event", "click")
            }
        }
    }

    func composerHTML() -> some WebUI.View {
        let running = activeTurns[activeSessionID ?? ""] != nil
        let sid = activeSessionID ?? ""
        let draft = settings.composerDrafts[sid] ?? ""
        let isBooked = activeSessionID.map { isBookmarked($0) } ?? false
        let selOpen = wsSelectOpen || profileSelectOpen || modelSelectOpen || thinkSelectOpen
        return Div(class: "composer-wrap") {
            Div { composerFlyoutHTML() }
                .attribute("id", "composer-flyout")
            Div(class: "cmd-dropdown") {}
                .attribute("id", "cmd-dropdown")
                .attribute("aria-label", "Slash commands")
            queuedSendsHTML()
            selectionChipsHTML()
            Form(action: "", method: nil, id: "composer-form",
                 class: "composer-bar" + (selOpen ? " sel-open" : "")) {
                Div(class: "attach-chips") {
                    for (i, path) in attachments.enumerated() {
                        Span(class: "chip") {
                            Text("@\(trunc(path, 50))")
                            ArcButton(id: "att-del-\(i)", component: nil, class: "chip-x") {
                                WebUIIcon(.x, size: .small)
                            }
                        }
                    }
                }
                .attribute("id", "attach-chips")
                .attribute("data-component-id", "att-chips")
                .attribute("data-event", "click")
                TextArea(id: "composer-input", name: "composer-input",
                         placeholder: running ? "Send another message — queued after this reply." : "Message ARC…",
                         value: draft, rows: 1)
                    .attribute("data-component-id", "composer-input")
                    .attribute("data-session", sid)
                    .attribute("data-draft", draft)
                    .attribute("data-prevent-enter", "send")
                    .attribute("style", "min-height:24px")
                Div(class: "composer-toolbar") {
                    ArcButton(id: "cb-file", component: "cb-file",
                              class: "tool-btn" + (filePopOpen ? " on" : "")) {
                        WebUIIcon(.paperclip, size: .medium)
                    }
                    .attribute("data-tip", "Attach a file")
                    .attribute("aria-label", "Attach a file")
                    // the star is the same glyph whether or not the chat is
                    // bookmarked — `.on` is what shows state (legacy parity).
                    ArcButton(id: "cb-bookmark", component: "cb-bookmark",
                              class: "tool-btn" + (isBooked ? " on" : "")) {
                        WebUIIcon(.star, size: .small)
                    }
                    .attribute("data-tip", "Bookmark this chat")
                    .attribute("aria-label", "Bookmark this chat")
                    composerSelectorsHTML()
                    Span(class: "spacer") {}
                    if let s = activeSession() {
                        ctxIndicatorHTML(s)
                    }
                    if running {
                        // While a turn runs, the send control becomes a red stop button.
                        ArcButton(id: "cb-send", component: "stop-turn", class: "send-btn stop") {
                            WebUIIcon(.square, size: .medium)
                        }
                        .attribute("title", "Stop")
                        .attribute("aria-label", "Stop")
                    } else {
                        ArcButton(id: "cb-send", component: "cb-send", class: "send-btn", type: .submit) {
                            WebUIIcon(.arrowUp, size: .medium)
                        }
                        .attribute("title", "Send")
                        .attribute("aria-label", "Send")
                    }
                }
            }
            .attribute("data-component-id", "composer-form")
            Span {}
                .attribute("id", "dd-dismiss")
                .attribute("data-component-id", "dd-dismiss")
                .attribute("data-event", "click")
                .attribute("hidden", "")
            Div(class: "file-pop" + (filePopOpen ? "" : " hidden")) {
                Div(class: "fp-row") {
                    Input(id: "file-path-input", placeholder: "/absolute/path/to/file", type: .text)
                        .attribute("data-component-id", "file-path-input")
                        .attribute("value", formValues["file-path-input"] ?? "")
                    ArcButton(id: "file-attach", component: "file-attach", class: "primary-btn") {
                        Text("Attach")
                    }
                }
                Div(class: "fp-recents") { Text("Recent") }
                for r in settings.recentFiles.prefix(6) {
                    ArcButton(id: "fr-\(enc(r))", component: nil, class: "fp-recent") {
                        Text("@\(trunc(r, 60))")
                    }
                }
            }
            .attribute("id", "file-pop")
            .attribute("data-component-id", "file-recents")
            .attribute("data-event", "click")
            Div { Text(slashDataJSON()) }
                .attribute("id", "slash-data")
                .attribute("hidden", "")
        }
        .attribute("id", "composer-wrap")
    }

    // MARK: Mid-stream queue chips (UX-04)

    /// The "Queued · N" row above the composer: mid-stream sends that will run
    /// as their own turns after the current reply, oldest first. Each chip
    /// carries a ✕ that removes it before it runs. Only rendered for the
    /// active chat, so a queue never leaks across sessions.
    func queuedSendsHTML() -> some WebUI.View {
        let sid = activeSessionID ?? ""
        let list = queuedSends[sid] ?? []
        // UX-29: the instruction lives ONCE — in the running composer
        // placeholder. A chip carries count + excerpt + remove control, and
        // the remove control's title/aria-label explains what removing does.
        let removeTip = "Remove queued message — it runs after the current reply finishes."
        return Group {
            if !list.isEmpty {
                Div(class: "queued-sends") {
                    Span(class: "queued-count") { Text("Queued · \(list.count)") }
                    for q in list {
                        ArcButton(id: "qs-del-\(q.id)", component: nil, class: "queued-chip") {
                            Span(class: "queued-chip-text") { Text(trunc(q.text, 90)) }
                            Span(class: "queued-chip-x") { Text("✕") }
                                .attribute("aria-label", removeTip)
                        }
                        .attribute("title", removeTip)
                    }
                }
                .attribute("id", "queued-sends")
                .attribute("data-component-id", "queued-sends")
                .attribute("data-event", "click")
            }
        }
    }

    // MARK: Composer dropdown selectors (arc parity)

    /// Renders the four composer dropdown widgets (workspace, profile,
    /// model, thinking) as trigger buttons with server-rendered popovers,
    /// matching the arc agent webui look.
    func composerSelectorsHTML() -> some WebUI.View {
        let ws = workspaceName(for: activeSessionID)
        let profile = (profileName(for: activeSessionID) ?? "")
        let config = configName(for: activeSessionID)
        let model = settings.modelConfig(named: config)?.model ?? config
        let think = thinkingLevel(for: activeSessionID)
        return Group {
            wsDropdown(ddTrigger(id: "cb-ws-toggle", icon: .folder,
                                 label: ws.isEmpty ? "Workspace" : ws, title: "Workspace"))
            ppDropdown(ddTrigger(id: "cb-profile-toggle", icon: .user,
                                 label: profile.isEmpty ? "Default" : profile, title: "Profile"))
            mdDropdown(ddTrigger(id: "cb-model-toggle", icon: .box,
                                 label: model.isEmpty ? "Model" : model, title: "Model"))
            thDropdown(ddTrigger(id: "cb-think-toggle", icon: .circleGauge,
                                 label: think.isEmpty ? "Off" : think.capitalized, title: "Thinking"))
        }
    }

    private func ddTrigger(id: String, icon: IconName, iconSize: IconSize = .small,
                           label: String, title: String) -> some WebUI.View {
        // the full label rides the DOM — the chip's CSS ellipsis handles
        // overflow and `title` carries the whole name, so a clipped chip stays
        // hover-readable (the old server-side truncation lost the tail of the
        // name permanently, mid-word).
        let tip = label.isEmpty ? title : "\(title) — \(label)"
        return ArcButton(id: id, component: id, class: "dd-trigger") {
            WebUIIcon(icon, size: iconSize)
            Span(class: "dd-trigger-label") { Text(label) }
            WebUIIcon(.chevronDown, size: .small)
        }
        .attribute("title", tip)
        .attribute("aria-label", tip)
    }

    /// one dropdown row. the row carries only its id: the wire dispatches on
    /// `targetId`, and the engine reports the nearest id *inside* the boundary —
    /// so the boundary lives on the popover (`dd-pop`), never on the row.
    private func ddRow(id: String, extraClass: String = "",
                       @ViewBuilder body: () -> [any WebUI.View]) -> some WebUI.View {
        let cls = extraClass.isEmpty ? "dd-row" : "dd-row \(extraClass)"
        return ArcButton(id: id, component: nil, class: cls) { body() }
    }

    /// string-bodied row for the builders that are still `-> String` (profile
    /// skills picker, storage picker). TODO(phase 5/6): delete with its callers —
    /// it exists so the dropdown cluster could convert without dragging two
    /// unrelated panels along.
    private func ddRow(id: String, body: String, extraClass: String = "") -> String {
        let cls = extraClass.isEmpty ? "dd-row" : "dd-row \(extraClass)"
        return "<button type=\"button\" id=\"\(id)\" class=\"\(cls)\">\(body)</button>"
    }

    /// The model configuration whose values match an auxiliary override
    /// (name for the row summary), or nil when the override is custom/empty.
    func auxOverrideConfigName(_ ov: AuxiliaryOverride?) -> String? {
        guard let ov, ov.isSet else { return nil }
        return settings.modelConfigs.first { c in
            !c.model.isEmpty
                && c.model == ov.model
                && (ov.provider.isEmpty || c.provider == ov.provider)
                && (ov.baseURL.isEmpty || c.baseURL == ov.baseURL)
        }?.name
    }

    /// Preferences → Main model: styled dropdown over the model configs. The
    /// trigger shows the active configuration; choosing a row switches it
    /// (same state the old per-row "Use" buttons set).
    func mainModelDropdown() -> some WebUI.View {
        let active = settings.modelConfigs.first(where: { $0.name == settings.activeConfig })
        let label = active.map { "\($0.name) · \($0.model)" } ?? "No configuration selected"
        var rows: [any WebUI.View] = []
        for c in settings.modelConfigs {
            let sel = c.name == settings.activeConfig
            rows.append(ddRow(id: "mainmc-pick-\(enc(c.name))") {
                Span(class: "dd-model-main") {
                    Span(class: "dd-row-title") {
                        Text(c.name)
                        if sel {
                            Span(class: "dd-badge sel") { Text("SELECTED") }
                        }
                    }
                    Span(class: "dd-row-sub") {
                        Text(c.provider.isEmpty ? c.model : c.model + " @ " + c.provider)
                    }
                }
            })
        }
        return Div(class: "dd") {
            ddTrigger(id: "mainmc-toggle", icon: .zap, label: label, title: "Main model")
            Div(class: "dd-pop dd-pop-ws" + (mainModelPickerOpen ? "" : " hidden")) {
                Div(class: "dd-list") {
                    for r in rows { r }
                    if rows.isEmpty {
                        Div(class: "dd-empty") { Text("No model configurations yet — add one above.") }
                    }
                }
            }
            .attribute("data-component-id", "mainmc")
            .attribute("data-event", "click")
        }
    }

    /// Workspace dropdown: search + list + (Choose path | Manage spaces).
    func wsDropdown(_ trigger: some WebUI.View) -> some WebUI.View {
        let q = wsSelectQuery.lowercased()
        var rows: [any WebUI.View] = []
        for ws in settings.workspaces {
            if !q.isEmpty && !ws.name.lowercased().contains(q) && !ws.path.lowercased().contains(q) { continue }
            rows.append(ddRow(id: "ws-pick-\(enc(ws.name))") {
                Span(class: "dd-row-title") { Text(ws.name) }
                Span(class: "dd-row-sub") { Text(trunc(ws.path, 58)) }
            })
        }
        return Div(class: "dd") {
            trigger
            Div(class: "dd-pop dd-pop-ws" + (wsSelectOpen ? "" : " hidden")) {
                Div(class: "dd-search") {
                    Input(id: "ws-search-input", placeholder: "Search workspaces…", type: .text)
                        .attribute("data-component-id", "ws-search-input")
                        .attribute("data-event", "input")
                        .attribute("data-no-restore", "")
                        .attribute("aria-label", "Search workspaces")
                        .attribute("spellcheck", "false")
                        .attribute("autocomplete", "off")
                        .attribute("value", wsSelectQuery)
                    if !wsSelectQuery.isEmpty {
                        ArcButton(id: "ws-search-clear", component: "ws-search-clear", class: "dd-clear") {
                            WebUIIcon(.x, size: .small)
                        }
                    }
                }
                Div(class: "dd-list") {
                    for r in rows { r }
                    if rows.isEmpty {
                        Div(class: "dd-empty") { Text("No workspaces match “\(wsSelectQuery)”") }
                    }
                }
                Div(class: "dd-foot") {
                    ArcButton(id: "ws-choose-path", component: "ws-choose-path", class: "dd-foot-row") {
                        Span(class: "dd-foot-ico") { WebUIIcon(.folderPlus, size: .small) }
                        Span(class: "dd-foot-txt") {
                            Span(class: "dd-row-title") { Text("Choose workspace path") }
                            Span(class: "dd-row-sub") { Text("Add a validated path and switch this conversation") }
                        }
                    }
                    ArcButton(id: "ws-manage", component: "ws-manage", class: "dd-foot-row") {
                        Span(class: "dd-foot-ico") { WebUIIcon(.settings, size: .small) }
                        Span(class: "dd-foot-txt") {
                            Span(class: "dd-row-title") { Text("Manage workspaces") }
                            Span(class: "dd-row-sub") { Text("Open the Spaces panel") }
                        }
                    }
                }
            }
            .attribute("data-component-id", "ws-pick")
            .attribute("data-event", "click")
        }
    }

    func ppDropdown(_ trigger: some WebUI.View) -> some WebUI.View {
        let activeProfileName = profileName(for: activeSessionID) ?? ""
        let total = skills.count
        var rows: [any WebUI.View] = []
        for p in profiles {
            let on = !activeProfileName.isEmpty && p.name == activeProfileName
            let model = p.model ?? settings.modelConfig(named: settings.activeConfig)?.model ?? "inherit"
            // Skills are active by default; the runtime gates on
            // settings.disabledSkills (see Actions.swift), not profileSkills.
            let onCount = enabledSkillCount(for: p.name)
            let titleSuffix = p.title.isEmpty || p.title == p.name ? "" : " (\(p.title))"
            rows.append(ddRow(id: "pp-\(enc(p.name))", extraClass: "dd-profile-row") {
                Span(class: "dd-dot" + (on ? " on" : "")) {}
                Span(class: "dd-profile-main") {
                    Span(class: "dd-row-title") {
                        Text(p.name + titleSuffix)
                        if on { Text(" "); WebUIIcon(.check, size: .small) }
                    }
                    Span(class: "dd-row-sub") { Text("\(model) · \(onCount) / \(total)") }
                    Span(class: "dd-row-sub") { Text("skills") }
                }
            })
        }
        return Div(class: "dd") {
            trigger
            Div(class: "dd-pop" + (profileSelectOpen ? "" : " hidden")) {
                Div(class: "dd-list dd-list-profile") {
                    for r in rows { r }
                }
                Div(class: "dd-foot") {
                    ArcButton(id: "pp-manage", component: "pp-manage", class: "dd-foot-row") {
                        Span(class: "dd-foot-ico") { WebUIIcon(.settings, size: .small) }
                        Span(class: "dd-foot-txt") {
                            Span(class: "dd-row-title") { Text("Manage profiles") }
                        }
                    }
                }
            }
            .attribute("data-component-id", "profile-pick")
            .attribute("data-event", "click")
        }
    }

    func mdDropdown(_ trigger: some WebUI.View) -> some WebUI.View {
        let active = configName(for: activeSessionID)
        let q = modelSelectQuery.lowercased()
        var rows: [any WebUI.View] = []
        for c in settings.modelConfigs {
            if !q.isEmpty && !c.name.lowercased().contains(q) && !c.model.lowercased().contains(q) { continue }
            let sel = c.name == active
            // UX-35: the secondary line carries provider + endpoint only — the
            // model id is already the row's title, so repeating it here wraps
            // the row and reads as noise. Quant/context would also belong here.
            var meta: [String] = []
            if !c.provider.isEmpty { meta.append(c.provider) }
            if !c.baseURL.isEmpty { meta.append(shortURL(c.baseURL)) }
            let sub = meta.joined(separator: " · ")
            rows.append(ddRow(id: "mc-\(enc(c.name))", extraClass: "dd-model-row") {
                Span(class: "dd-dot" + (sel ? " on" : "")) {}
                Span(class: "dd-model-main") {
                    Span(class: "dd-row-title") {
                        Text(c.name)
                        if sel { Text(" "); WebUIIcon(.check, size: .small) }
                    }
                    Span(class: "dd-row-sub") { Text(sub) }
                }
            })
        }
        return Div(class: "dd") {
            trigger
            Div(class: "dd-pop dd-pop-model" + (modelSelectOpen ? "" : " hidden")) {
                Div(class: "dd-note") { Text("Applies to this conversation from your next message.") }
                Div(class: "dd-search") {
                    Input(id: "model-search-input", placeholder: "Search models…", type: .text)
                        .attribute("data-component-id", "model-search-input")
                        .attribute("data-event", "input")
                        .attribute("data-no-restore", "")
                        .attribute("aria-label", "Search models")
                        .attribute("spellcheck", "false")
                        .attribute("autocomplete", "off")
                        .attribute("value", modelSelectQuery)
                    if !modelSelectQuery.isEmpty {
                        ArcButton(id: "model-search-clear", component: "model-search-clear", class: "dd-clear") {
                            WebUIIcon(.x, size: .small)
                        }
                    }
                }
                Div(class: "dd-list") {
                    for r in rows { r }
                    if rows.isEmpty {
                        Div(class: "dd-empty") { Text("No models match “\(modelSelectQuery)”") }
                    }
                }
            }
            .attribute("data-component-id", "model-pick")
            .attribute("data-event", "click")
        }
    }

    /// Thinking-level dropdown (arc-style pill trigger + level list).
    func thDropdown(_ trigger: some WebUI.View) -> some WebUI.View {
        let current = thinkingLevel(for: activeSessionID)
        var rows: [any WebUI.View] = []
        for lv in ["off", "low", "medium", "high", "max"] {
            let on = lv == current
            rows.append(ddRow(id: "tp-\(lv)") {
                Span(class: "dd-row-title") {
                    Text(lv.capitalized)
                    if on { Text(" "); WebUIIcon(.check, size: .small) }
                }
            })
        }
        return Div(class: "dd") {
            trigger
            Div(class: "dd-pop" + (thinkSelectOpen ? "" : " hidden")) {
                Div(class: "dd-list") {
                    for r in rows { r }
                }
            }
            .attribute("data-component-id", "think-pick")
            .attribute("data-event", "click")
        }
    }

    // MARK: Skills main

    /// The markdown body of a skill file with its YAML frontmatter stripped
    /// (the metadata is for the editor, not the reader — arc parity).
    func skillBodyOnly(_ content: String) -> String {
        guard let fm = skillFrontmatterRange(content) else { return content }
        let lines = content.components(separatedBy: .newlines)
        return lines[fm.upperBound...].joined(separator: "\n")
    }

    /// The raw YAML frontmatter block between the `---` fences, if present.
    func skillFrontmatterRange(_ content: String) -> Range<Int>? {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return 1..<i
        }
        return nil
    }

    func skillsMain() -> String {
        if createSkill {
            return skillCreateForm()
        }
        guard let name = selectedSkill,
              let skill = skills.first(where: { $0.name == name })
        else {
            // UX-16: one empty state, one CTA. A real "Create skill" button
            // in the canvas (the sidebar + is the other path).
            let createBtn = btn("skill-new-main", "skill-new", "primary-btn", WebUIIcon(.plus, size: .medium).markup.html + " Create skill", " title=\"Create skill\"")
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.star, size: .extraLarge).markup.html)</div>
                <div>\(skills.isEmpty ? "No skills yet." : "Select a skill to see its description.")</div>
                <div style="margin-top:12px">\(createBtn)</div>
              </div>
            </div>
            """
        }
        let body = mdBox(skillBodyOnly(skill.content).isEmpty ? skill.description : skillBodyOnly(skill.content))
        if skillEdit {
            return skillEditForm(skill)
        }
        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
            <div class="detail-card">
              <div class="mem-head">
                <div><h1 class="detail-title" style="margin:0">\(esc(skill.name))</h1>
                <div class="detail-sub">\(esc(skill.category ?? ""))\(skill.tags.isEmpty ? "" : " • " + skill.tags.map(esc).joined(separator: ", "))</div></div>
                \(btn("sk-edit", "skill-edit", "icon-mini", WebUIIcon(.edit, size: .small).markup.html, " title=\"Edit skill\""))
                \(btn("sk-delete", "skill-delete", "icon-mini danger", WebUIIcon(.trash, size: .small).markup.html, " title=\"Delete skill\""))
              </div>
              <p style="color:var(--text);font-size:0.98em;margin:0 0 12px">\(esc(skill.description))</p>
              <div class="detail-body" style="margin-top:14px">\(body)</div>
            </div>
          </div>
        </div>
        """
    }

    /// Inline edit form for the selected skill (mirrors the memory/doc editor).
    func skillEditForm(_ skill: Skill) -> String {
        let nameV = formValues["sk-edit-name-input"] ?? skill.name
        let catV = formValues["sk-edit-cat-input"] ?? skill.category ?? ""
        let descV = formValues["sk-edit-desc-input"] ?? skill.description
        let contentV = formValues["sk-edit-content-input"] ?? skill.content
        return """
        <div class="main-view"><div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
          <form id="sk-edit-form" data-component-id="sk-edit-form" class="detail-card" style="max-width:720px">
            <h1 class="detail-title">Edit skill</h1>
            <div class="detail-sub">Editing \(esc(skill.name)) — saves back to \(esc(skill.path.path))</div>
            \(skillMetadataHTML(skill))
            <input type="hidden" name="sk-orig" value="\(esc(skill.name))">
            <div class="form-grid">
              <div><label for="sk-edit-name-input">Name</label><input id="sk-edit-name-input" name="sk-edit-name-input" data-component-id="sk-edit-name-input" data-event="input" value="\(esc(nameV))"></div>
              <div><label for="sk-edit-cat-input">Category</label><input id="sk-edit-cat-input" name="sk-edit-cat-input" data-component-id="sk-edit-cat-input" data-event="input" value="\(esc(catV))" placeholder="e.g. devops"></div>
              <div><label for="sk-edit-desc-input">Description</label><input id="sk-edit-desc-input" name="sk-edit-desc-input" data-component-id="sk-edit-desc-input" data-event="input" value="\(esc(descV))"></div>
              <div><label for="sk-edit-content-input">Content (Markdown)</label><textarea id="sk-edit-content-input" name="sk-edit-content-input" data-component-id="sk-edit-content-input" data-event="input">\(esc(contentV))</textarea></div>
            </div>
            <div class="row-actions-main">
              <button type="submit" class="primary-btn">Save changes</button>
              \(btn("sk-edit-delete", "sk-edit-delete", "ghost-btn danger", "Delete"))
              \(btn("sk-edit-cancel", "", "ghost-btn", "Cancel"))
            </div>
          </form>
        </div></div>
        """
    }

    /// reference metadata box: a rounded monospace panel with the raw YAML
    /// frontmatter. Shown only in the skill EDITOR (never in the reader).
    func skillMetadataHTML(_ skill: Skill) -> String {
        let lines = skill.content.components(separatedBy: .newlines)
        guard let r = skillFrontmatterRange(skill.content) else { return "" }
        let block = lines[r].joined(separator: "\n")
        return """
        <div class="skill-meta-box">
          <div class="skill-meta-head">Metadata</div>
          <pre class="skill-meta-pre">\(esc(block))</pre>
        </div>
        """
    }

    func skillCreateForm() -> String {
        let nameErr = self.skillCreateErrors["skill-name-input"]
        let descErr = self.skillCreateErrors["skill-desc-input"]
        let nameAria = nameErr != nil ? "aria-invalid=\"true\" aria-describedby=\"skill-name-err\"" : ""
        let descAria = descErr != nil ? "aria-invalid=\"true\" aria-describedby=\"skill-desc-err\"" : ""
        // Round-3 UX-35: mark the invalid field, and ask the post-patch seam to
        // put the caret in the first one that failed.
        let nameCls = nameErr != nil ? " input-invalid" : ""
        let descCls = descErr != nil ? " input-invalid" : ""
        let nameFocus = nameErr != nil ? " data-focus-after-patch" : ""
        let descFocus = (descErr != nil && nameErr == nil) ? " data-focus-after-patch" : ""
        let reqTags = "<span class=\"req-tag\">Required</span>"
        let nameErrHidden = nameErr == nil ? "hidden" : ""
        let descErrHidden = descErr == nil ? "hidden" : ""
        let nameErrText = esc(nameErr ?? "")
        let descErrText = esc(descErr ?? "")
        let form = """
        <form id="skill-create-form" data-component-id="skill-create-form" class="detail-card" style="max-width:720px">
          <h1 class="detail-title">New skill</h1>
          <div class="detail-sub">A skill is a SKILL.md file with YAML frontmatter (name, description) found under the skills directory.</div>
          <div class="form-grid">
            <div><label for="skill-name-input">Name\(reqTags)</label><input id="skill-name-input" name="skill-name-input" data-component-id="skill-name-input" data-event="input" placeholder="my-skill" class="text-input\(nameCls)" \(nameAria)\(nameFocus)><span id="skill-name-err" class="inline-err" \(nameErrHidden)>\(nameErrText)</span></div>
            <div><label for="skill-cat-input">Category</label><input id="skill-cat-input" name="skill-cat-input" data-component-id="skill-cat-input" data-event="input" placeholder="e.g. devops"></div>
            <div><label for="skill-desc-input">Description\(reqTags)</label><input id="skill-desc-input" name="skill-desc-input" data-component-id="skill-desc-input" data-event="input" placeholder="Short description" class="text-input\(descCls)" \(descAria)\(descFocus)><span id="skill-desc-err" class="inline-err" \(descErrHidden)>\(descErrText)</span></div>
            <div><label for="skill-content-input">Content (Markdown)</label><textarea id="skill-content-input" name="skill-content-input" data-component-id="skill-content-input" data-event="input" placeholder="How to use this skill…"></textarea></div>
          </div>
          <div class="row-actions-main">
            <button type="submit" class="primary-btn">Create skill</button>
            \(btn("skill-cancel", "skill-cancel", "ghost-btn", "Cancel"))
          </div>
        </form>
        """
        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">\(form)</div>
        </div>
        """
    }

    // MARK: Profiles main

    func profilesMain() -> String {
        if createProfile || editingProfile != nil {
            let editing = editingProfile.flatMap { n in profiles.first { $0.name == n } }
            let isEdit = editing != nil
            let ectx = editing?.context
            let nameVal = editing.map { " value=\"\(esc($0.name))\"" } ?? ""
            let titleVal = editing.map { " value=\"\(esc($0.title))\"" } ?? ""
            let descVal = editing.map { " value=\"\(esc($0.description))\"" } ?? ""
            let ctxLen = ectx?.contextLength.map { String($0) } ?? ""
            let maxTok = ectx?.maxOutputTokens.map { String($0) } ?? ""
            let tempVal = ectx?.temperature.map { String($0) } ?? ""
            let topPVal = ectx?.topP.map { String($0) } ?? ""
            let budgetVal = ectx?.compressionBudget.map { String($0) } ?? ""
            let effortSel = ectx?.reasoningEffort ?? ""
            let effortOptions = AppState.effortOptions(selected: effortSel)
            let formTitle = isEdit ? "Edit profile" : "New profile"
            let formSub = isEdit ? "Edit the profile identity and its context parameters." : "A named, isolated agent configuration."
            let formSubmit = isEdit ? "Save changes" : "Create profile"
            let form = """
            <form id="profile-create-form" data-component-id="profile-create-form" class="detail-card" style="max-width:560px">
              <h1 class="detail-title">\(formTitle)</h1>
              <div class="detail-sub">\(formSub)</div>
              <div class="form-grid">
                <div><label for="profile-name-input">Name</label><input id="profile-name-input" name="profile-name-input" data-component-id="profile-name-input" placeholder="researcher"\(nameVal)\(isEdit ? " readonly" : "")></div>
                <div><label for="profile-title-input">Title</label><input id="profile-title-input" name="profile-title-input" data-component-id="profile-title-input" placeholder="Research Analyst"\(titleVal)></div>
                <div><label for="profile-desc-input">Description</label><input id="profile-desc-input" name="profile-desc-input" data-component-id="profile-desc-input" placeholder="One-line mission"\(descVal)></div>
              </div>
              <h3 style="margin:16px 0 6px">Context parameters</h3>
              <div class="detail-sub">Model context overrides for chats bound to this profile. Leave blank to inherit the chat's model config.</div>
              <div class="form-grid">
                <div><label for="profile-ctx-length">Context window (tokens)</label><input id="profile-ctx-length" name="profile-ctx-length" type="number" min="1024" step="1024" placeholder="e.g. 128000" value="\(ctxLen)"></div>
                <div><label for="profile-ctx-maxtok">Max output (tokens)</label><input id="profile-ctx-maxtok" name="profile-ctx-maxtok" type="number" min="1" placeholder="e.g. 8192" value="\(maxTok)"></div>
                <div><label for="profile-ctx-effort">Reasoning effort</label><select id="profile-ctx-effort" name="profile-ctx-effort" data-component-id="profile-ctx-effort">\(effortOptions)</select></div>
                <div><label for="profile-ctx-temp">Temperature</label><input id="profile-ctx-temp" name="profile-ctx-temp" type="number" min="0" max="2" step="0.1" placeholder="e.g. 0.7" value="\(tempVal)"></div>
                <div><label for="profile-ctx-topp">Top P</label><input id="profile-ctx-topp" name="profile-ctx-topp" type="number" min="0" max="1" step="0.05" placeholder="e.g. 0.9" value="\(topPVal)"></div>
                <div><label for="profile-ctx-budget">Compress at (tokens)</label><input id="profile-ctx-budget" name="profile-ctx-budget" type="number" min="1024" step="1024" placeholder="e.g. 32000" value="\(budgetVal)"></div>
              </div>
              <h3 style="margin:16px 0 6px">Context skills</h3>
              <div class="detail-sub">Skills pinned to this profile: their full content is loaded into every prompt for chats bound to this profile (as if the user had asked for them).</div>
              \(profileContextSkillsHTML())
              <div class="row-actions-main">
                <button type="submit" class="primary-btn">\(formSubmit)</button>
                \(btn("profile-cancel", "profile-cancel", "ghost-btn", "Cancel"))
              </div>
            </form>
            """
            return """
            <div class="main-view">
              <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">\(form)</div>
            </div>
            """
        }
        // UX-13: with exactly one profile there is nothing to "select" —
        // auto-select it so the canvas is never a dead end. Only when two
        // or more profiles exist does the empty "Select a profile" state
        // stay on screen.
        if selectedProfile == nil && profiles.count == 1 {
            selectedProfile = profiles[0].name
        }
        guard let name = selectedProfile,
              let p = profiles.first(where: { $0.name == name })
        else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.user, size: .extraLarge).markup.html)</div><div>Select a profile to see its details.</div></div>
            </div>
            """
        }
        let card = profileCardHTML(p)
        let set = p.enabledToolsets ?? []
        let toolsetsNote = set.isEmpty ? "all (not overridden)" : set.joined(separator: ", ")
        let encName = enc(p.name)
        let isDefault = p.name == "default"
        let headIcons = btn("pr-edit-\(encName)", "", "icon-mini", WebUIIcon(.edit, size: .medium).markup.html, " title=\"Edit profile\"")
            + btn("pr-sel-\(encName)", "", "icon-mini", WebUIIcon(.check, size: .medium).markup.html, " title=\"Select profile for this chat\"")
            + (isDefault ? "" : btn("pr-del-\(encName)", "", "icon-mini danger", WebUIIcon(.trash, size: .medium).markup.html, " title=\"Delete profile\""))
        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
            <div class="detail-card">
              <div class="mem-head">
                <div>
                  <h1 class="detail-title" style="margin:0">\(esc(p.title.isEmpty ? p.name : p.title))</h1>
                  <div class="detail-sub">\(esc(p.description.isEmpty ? "No description." : p.description))</div>
                </div>
                <div class="row-actions" data-component-id="profile-list" data-event="click">\(headIcons)</div>
              </div>
              \(card)
              <h3 style="margin:16px 0 6px">Tool sets</h3>
              <div class="detail-sub">Overrides configured on the profile: \(esc(toolsetsNote))</div>
              <h3 style="margin:16px 0 6px">Context parameters</h3>
              \(profileContextHTML(p))
              <h3 style="margin:16px 0 6px">Agent powers</h3>
              <div class="detail-sub">Lockdowns for this profile's skills and profile files (MEMORY / USER / SOUL).</div>
              \(render(agentPowersSection()))
            </div>
          </div>
        </div>
        """
    }

    func profileKV(_ p: Profile) -> String {
        var rows = ""
        rows += "<div class=\"akv\"><span class=\"akv-k\">Name</span><span class=\"akv-v\">\(esc(p.name))</span></div>"
        rows += "<div class=\"akv\"><span class=\"akv-k\">Model</span><span class=\"akv-v\">\(esc(p.model ?? "inherit"))</span></div>"
        rows += "<div class=\"akv\"><span class=\"akv-k\">Provider</span><span class=\"akv-v\">\(esc(p.provider ?? "inherit"))</span></div>"
        if let b = p.baseURL { rows += "<div class=\"akv\"><span class=\"akv-k\">Base URL</span><span class=\"akv-v\">\(esc(b))</span></div>" }
        return rows
    }

    /// Per-profile context parameters summary (kv rows; "inherit" when unset)
    /// plus the pinned context skills, if any.
    func profileContextHTML(_ p: Profile) -> String {
        var rows = ""
        if let ctx = p.context, !ctx.isEmpty {
            rows += "<div class=\"akv\"><span class=\"akv-k\">Context window</span><span class=\"akv-v\">\(ctx.contextLength.map { "\($0) tokens" } ?? "inherit")</span></div>"
            rows += "<div class=\"akv\"><span class=\"akv-k\">Max output</span><span class=\"akv-v\">\(ctx.maxOutputTokens.map { "\($0) tokens" } ?? "inherit")</span></div>"
            rows += "<div class=\"akv\"><span class=\"akv-k\">Reasoning effort</span><span class=\"akv-v\">\(esc(ctx.reasoningEffort ?? "inherit"))</span></div>"
            rows += "<div class=\"akv\"><span class=\"akv-k\">Temperature</span><span class=\"akv-v\">\(ctx.temperature.map { String($0) } ?? "inherit")</span></div>"
            rows += "<div class=\"akv\"><span class=\"akv-k\">Top P</span><span class=\"akv-v\">\(ctx.topP.map { String($0) } ?? "inherit")</span></div>"
            rows += "<div class=\"akv\"><span class=\"akv-k\">Compress at</span><span class=\"akv-v\">\(ctx.compressionBudget.map { "\($0) tokens" } ?? "inherit")</span></div>"
        } else {
            rows += "<div class=\"akv\"><span class=\"akv-k\">Context</span><span class=\"akv-v\">inherit (no overrides)</span></div>"
        }
        if let pinned = p.contextSkills, !pinned.isEmpty {
            let names = pinned.map { esc($0) }.joined(separator: ", ")
            rows += "<div class=\"akv\"><span class=\"akv-k\">Context skills</span><span class=\"akv-v\">\(names)</span></div>"
        }
        return rows
    }

    /// The profile edit form's "Context skills" section: pinned-skill rows
    /// with remove buttons, an "Add skill" dropdown over the discovered
    /// skills, and a hidden CSV field the submit wire reads.
    func profileContextSkillsHTML() -> String {
        let draft = profileSkillsDraft
        var rows = ""
        for name in draft {
            let known = skills.first(where: { $0.name == name })
            let label = known?.name ?? name
            let desc = known?.description ?? "missing"
            rows += """
            <div class="pn-draft-row">
              <span class="pn-draft-name">\(esc(label))</span>
              <span class="pn-draft-desc">\(esc(desc))</span>
              \(btn("pcs-rm-\(enc(name))", "", "icon-mini danger", WebUIIcon(.x, size: .small).markup.html, " title=\"Remove skill\""))
            </div>
            """
        }
        let empty = draft.isEmpty ? "<div class=\"pn-draft-empty\">No pinned skills — every prompt uses the regular skill index.</div>" : ""
        let open = profileSkillsPickerOpen ? "" : " hidden"
        let chosen = Set(draft)
        let available = skills.filter { !chosen.contains($0.name) }
        var optRows = ""
        for s in available {
            optRows += ddRow(id: "pcs-pick-\(enc(s.name))", body: """
            <span class="dd-row-title">\(esc(s.name))</span>
            <span class="dd-row-sub">\(esc(s.description))</span>
            """)
        }
        let noOpts = available.isEmpty
            ? "<div class=\"dd-empty\">All discovered skills are already pinned.</div>"
            : ""
        let picker = """
        <div class="dd pn-picker">
          \(render(ddTrigger(id: "pcs-toggle", icon: .plus, iconSize: .medium, label: "Add skill", title: "Pin a skill into this profile's context")))
          <div class="dd-pop dd-pop-ws\(open)" data-component-id="pcs" data-event="click">
            <div class="dd-list">\(optRows)\(noOpts)</div>
          </div>
        </div>
        """
        return """
        <div class="pn-draft" data-component-id="pcs-rm" data-event="click">
          \(rows)\(empty)
        </div>
        \(picker)
        """
    }

    /// <option> tags for the reasoning-effort picker ("" = inherit).
    static func effortOptions(selected: String) -> String {
        let levels = ["", "minimal", "low", "medium", "high", "max"]
        return levels.map { lv in
            let label = lv.isEmpty ? "Inherit" : lv
            let sel = lv == selected ? " selected" : ""
            return "<option value=\"\(lv)\"\(sel)>\(label)</option>"
        }.joined()
    }

    /// arc-parity profile card: PROFILE eyebrow + key/value rows with
    /// badges (ACTIVE / (default) / Daemon running / code-block model).
    func profileCardHTML(_ p: Profile) -> String {
        let activeProfile = profileName(for: activeSessionID) ?? ""
        let isActive = !activeProfile.isEmpty && activeProfile == p.name
        let isDefault = p.name == "default"
        let skillCount = enabledSkillCount(for: p.name)
        let modelName = p.model ?? settings.modelConfig(named: settings.activeConfig)?.model ?? "inherit"
        let providerName = p.provider ?? "custom"
        let keyCount = settings.modelConfigs.filter { !$0.apiKey.isEmpty }.count
        let keyLabel = keyCount > 0 ? "\(keyCount) \(keyCount == 1 ? "key" : "keys") configured" : "None"
        let statusBadges = (isActive ? "<span class=\"pl-badge badge-active\">ACTIVE</span>" : "<span class=\"pl-badge badge-inactive\">IDLE</span>")
            + (isDefault ? " <span class=\"pl-badge badge-default\">DEFAULT</span>" : "")
        let daemon = daemonRunning
            ? "<span class=\"pl-badge badge-green\"><span class=\"pl-dot\"></span>Daemon running</span>"
            : "<span class=\"pl-badge badge-red\">Daemon stopped</span>"
        return """
        <div class="pl-card">
          <div class="pl-eyebrow">PROFILE</div>
          <div class="pl-row"><span class="pl-k">Status</span><span class="pl-v">\(statusBadges)</span></div>
          <div class="pl-row"><span class="pl-k">Daemon</span><span class="pl-v">\(daemon)</span></div>
          <div class="pl-row"><span class="pl-k">Model</span><span class="pl-v"><code class="pl-code">\(esc(modelName))</code></span></div>
          <div class="pl-row"><span class="pl-k">Provider</span><span class="pl-v">\(esc(providerName))</span></div>
          <div class="pl-row"><span class="pl-k">API key</span><span class="pl-v">\(esc(keyLabel))</span></div>
          <div class="pl-row"><span class="pl-k">Skills</span><span class="pl-v">\(skillCount) of \(skills.count) active</span></div>
        </div>
        """
    }

    // MARK: Tools main

    func toolsMain() -> some WebUI.View {
        Group {
            if let name = selectedTool, let tool = registry.lookup(name: name) {
                // round-3 UX-28: the panel filter must also govern the detail pane
                // — otherwise it describes a tool the list no longer shows.
                if !toolFilter.isEmpty && !name.localizedCaseInsensitiveContains(toolFilter) {
                    blankMain("No tools match “\(toolFilter)”.")
                } else {
                    mainScroll {
                        Div(class: "detail-card") {
                            DetailTitle(tool.name, icon: toolIconName(tool.emoji))
                            Div(class: "detail-sub") { Text(tool.toolset) }
                            AkvRow(key: "Description", value: tool.description)
                            AkvRow(key: "Toolset", value: tool.toolset)
                            AkvRow(key: "Requires env",
                                   value: tool.requiresEnv.isEmpty
                                       ? "none"
                                       : tool.requiresEnv.joined(separator: ", "))
                            Heading("Parameters", level: .h3, class: "detail-h3")
                            schemaHTML(tool.schema)
                        }
                    }
                }
            } else {
                blankMain("Select a tool to see its definition and parameters.")
            }
        }
    }

    /// the "nothing selected" pane every main uses. centres its card, so the
    /// two callers cannot drift apart.
    func blankMain(_ message: String) -> some WebUI.View {
        Div(class: "main-view") {
            Div(class: "blank") {
                Div(class: "big") { WebUIIcon(.tool, size: .extraLarge) }
                Div { Text(message) }
            }
        }
        .attribute("style", "justify-content:center")
    }

    /// the scroll container every detail main wraps its card in.
    func mainScroll(@ViewBuilder _ content: () -> [any WebUI.View]) -> some WebUI.View {
        Div(class: "main-view") {
            Div(id: "main-scroll", class: "main-scroll") {
                content()
            }
            .attribute("data-scroll-key", "main-scroll")
        }
    }

    /// Settings → Sidebar plugins: one card per registered plugin bundle,
    /// listing its tabs with a show/hide switch. Mirrors the tool-plugin
    /// cards (name/version/description + enable toggle).
    func sidebarPluginsSettingsHTML() -> some WebUI.View {
        Group {
            if sidebarPlugins.isEmpty {
                Div(class: "set-row set-row-stack") {
                    Div(class: "set-label") { Text("No third-party sidebar tabs registered.") }
                    Div(class: "set-hint") {
                        Text("Add a sidebar-tab package to the arc-agent build and pass its tabs to the application at startup — see ")
                        InlineCode("docs/sidebar-tab-plugins.md")
                        Text(".")
                    }
                }
            } else {
                for plugin in sidebarPlugins {
                    let tabs = plugin.tabs()
                    Div(class: "set-row set-row-stack") {
                        Div(class: "set-label") {
                            Text("\(plugin.name) ")
                            Small("v\(plugin.version)")
                        }
                        Div(class: "set-hint") { Text(plugin.description) }
                        for tab in tabs {
                            let on = !settings.hiddenSidebarTabs.contains(tab.id)
                            Div(class: "row-split") {
                                Div(class: "row-icon") {
                                    // a plugin renders its own icon markup; this is
                                    // the same trusted-renderer seam as markdown.
                                    Raw(.trusted(SidebarTabIconRenderer.render(tab.icon, size: .medium)))
                                    Span(class: "set-label") {
                                        Text("\(tab.title) ")
                                        Small(tab.id)
                                    }
                                }
                                ArcSwitch(id: "sbpl-\(enc(tab.id))", on: on,
                                          component: "sidebar-plugin-toggle", event: "change",
                                          value: "sbpl-\(enc(tab.id))")
                            }
                        }
                    }
                }
            }
        }
    }

    func pluginSettingsHTML() -> some WebUI.View {
        let names = pluginManifests.keys.sorted()
        return Group {
            if names.isEmpty {
                Div(class: "set-row set-row-stack") {
                Div(class: "set-label") { Text("No tool plugins found.") }
                Div(class: "set-hint") {
                    Text("Drop a directory with a ")
                    InlineCode("manifest.json")
                    Text(" into ")
                    InlineCode("~/.arc/plugins/<name>/")
                    Text(" and press Rescan. Each tool is an executable (or interpreter + script pair, e.g. ")
                    InlineCode("python3")
                    Text(" + ")
                    InlineCode("tool.py")
                    Text(") that reads ")
                    InlineCode("{\"tool\": name, \"args\": {...}}")
                    Text(" on stdin and writes ")
                    InlineCode("{\"result\": \"...\"}")
                    Text(" on stdout. See ")
                    InlineCode("docs/plugin-tools.md")
                    Text(" in the arc-agent repository for the full contract and examples.")
                    }
                }
            } else {
                let allow = arcConfig.plugins.enabled
                for name in names {
                let m = pluginManifests[name]
                let on = allow?.contains(name) ?? true
                let tools = (m?.tools ?? []).map { $0.name }
                Div(class: "set-row set-row-stack-tight") {
                    Div(class: "row-split") {
                        Div(class: "set-label") {
                            Text("\(name) ")
                            Small("v\(m?.version ?? "0.0.0")")
                        }
                        ArcSwitch(id: "plgl-\(enc(name))", on: on,
                                  component: "plugin-toggle", event: "change",
                                  value: "plgl-\(enc(name))")
                    }
                    Div(class: "set-hint") { Text(m?.description ?? "") }
                    Div(class: "set-hint") {
                        if tools.isEmpty {
                            Text("No tools")
                        } else {
                            // UX-22: the chips live in a wrapping flex row so a long
                            // package token breaks inside the badge instead of being
                            // cut at the card edge.
                            Text("Tools: ")
                            Span(class: "plug-chips") {
                                for t in tools {
                                    Span(class: "mc-badge") { Text(t) }
                                }
                            }
                        }
                    }
                    if let reason = pluginStartupOutcome[name] {
                        Div(class: "set-hint plugin-failed") {
                            Text("Sidecar failed to start: \(reason)")
                        }
                    } else if on {
                        Div(class: "set-hint plugin-running") { Text("Sidecar running") }
                    }
                }
            }
            Div(class: "set-row") {
                Div(class: "set-label") {
                    Text("Rescan")
                    Small {
                        Text("Re-read ")
                        InlineCode("~/.arc/plugins")
                        Text(" after adding or editing a plugin.")
                    }
                }
                ArcButton("Rescan plugins", id: "plugin-rescan",
                          component: "plugin-rescan", class: "btn")
                    .attribute("data-event", "click")
                }
            }
        }
    }

    // MARK: MCP servers (Settings)

    /// Settings → MCP servers: the `mcp_servers` block of `~/.arc/config.json`,
    /// editable in place.
    ///
    /// The agent never sees one tool per server — it sees the single `mcp_tool`
    /// bridge (Tools panel). What this panel owns is the launch spec of each
    /// server process, which is why the useful action on a row is Test: it
    /// starts the server and lists the tools it actually exposes, the only way
    /// to learn a server's tool names before the agent tries to call one.
    func mcpSettingsHTML() -> some WebUI.View {
        Group {
            if addingMCPServer {
                mcpFormHTML()
            } else {
                let names = arcConfig.mcpServers.keys.sorted()
                if names.isEmpty {
                    Div(class: "set-row set-row-stack") {
                        Div(class: "set-label") { Text("No MCP servers configured.") }
                        Div(class: "set-hint") {
                            Text("A server is a child process that speaks the Model Context Protocol over stdio — filesystem access, GitHub, databases. Once added it is started on first use, and the agent reaches its tools through the single ")
                            InlineCode("mcp_tool")
                            Text(" bridge (Tools panel): ask the agent to call ")
                            InlineCode("mcp_tool")
                            Text(" with ")
                            InlineCode("action: \"list\"")
                            Text(" to see every server and tool. ")
                            InlineCode("mcp_servers")
                            Text(" in ")
                            InlineCode("~/.arc/config.json")
                            Text(" is the source of truth, and this panel edits exactly that block. Arguments reach the process verbatim; nothing is run through a shell.")
                        }
                        ArcButton("Add server", id: "mcp-add", component: "mcp-add", class: "btn")
                    }
                } else {
                    for name in names {
                        mcpRowHTML(name)
                    }
                    Div(class: "set-row") {
                        Div(class: "set-label") {
                            Text("Add a server")
                            Small {
                                Text("Written to ")
                                InlineCode("~/.arc/config.json")
                                Text("; the running agent is re-pointed immediately.")
                            }
                        }
                        ArcButton("Add server", id: "mcp-add", component: "mcp-add", class: "btn")
                    }
                }
            }
        }
    }

    /// one configured server: name, its three actions, the argv hint and the
    /// probe status. the row owns the `mcp-list` boundary; the action buttons
    /// carry ids only, so the wire dispatches on `targetId`.
    private func mcpRowHTML(_ name: String) -> some WebUI.View {
        let cfg = arcConfig.mcpServers[name]
        let argv = ([cfg?.command ?? ""] + (cfg?.args ?? [])).joined(separator: " ")
        return Div(class: "set-row set-row-stack-tight") {
            Div(class: "row-split") {
                Div(class: "set-label") { Text(name) }
                Div(class: "row-actions row-actions-inline") {
                    ArcButton("Test", id: "mcp-test-\(enc(name))", class: "btn")
                    ArcButton("Edit", id: "mcp-edit-\(enc(name))", class: "btn")
                    ArcButton(id: "mcp-del-\(enc(name))", class: "icon-mini danger") {
                        WebUIIcon(.x, size: .small)
                    }
                    .attribute("title", "Delete")
                }
            }
            Div(class: "set-hint") {
                InlineCode(trunc(argv, 140))
            }
            if let error = mcpTestError[name] {
                Div(class: "set-hint probe-error") {
                    Text("Probe failed: \(trunc(error, 220))")
                }
            } else if let tools = mcpToolCatalog[name] {
                Div(class: "set-hint") {
                    Text("Tools: ")
                    Span(class: "plug-chips") {
                        if tools.isEmpty {
                            InlineCode("no tools")
                        } else {
                            for t in tools {
                                Span(class: "mc-badge") { Text(t) }
                            }
                        }
                    }
                }
            } else {
                Div(class: "set-hint") {
                    Text("Not probed yet — press Test to start it and list its tools.")
                }
            }
        }
        .attribute("data-component-id", "mcp-list")
    }

    func mcpFormHTML() -> some WebUI.View {
        let title = editingMCPServer == nil ? "New MCP server" : "Edit MCP server"
        // input `name` attributes are the submit payload keys the engine builds
        // (`extractFormData` keys by `name`): renaming one silently kills Save.
        return Form(action: "", method: nil, id: "mcp-form", class: "detail-card mcp-form") {
            Heading(title, level: .h1, class: "detail-title")
            Div(class: "detail-sub") {
                Text("The server is launched directly, as ")
                InlineCode("/usr/bin/env <command> <args…>")
                Text(" — never through a shell — with arc's own credentials stripped from its environment. Save, then press Test on the row to start it and list the tools it exposes.")
            }
            Div(class: "form-grid") {
                Div {
                    Label("Name", for: "mcp-name-input")
                    Input(id: "mcp-name-input", name: "mcp-name-input",
                          placeholder: "filesystem", type: .text,
                          value: formValues["mcp-name-input"] ?? "",
                          attributes: [("data-component-id", "mcp-name-input"),
                                       ("autofocus", "")])
                    Small("How the agent selects this server. Lowercase letters, digits, '-' and '_'.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
                Div {
                    Label("Command", for: "mcp-command-input")
                    Input(id: "mcp-command-input", name: "mcp-command-input",
                          placeholder: "npx", type: .text,
                          value: formValues["mcp-command-input"] ?? "",
                          attributes: [("data-component-id", "mcp-command-input")])
                    Small("One executable, resolved through PATH. Everything else belongs in Arguments.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
                Div {
                    Label("Arguments (one per line)", for: "mcp-args-input")
                    TextArea(id: "mcp-args-input", name: "mcp-args-input",
                             placeholder: "-y\n@modelcontextprotocol/server-filesystem\n/Users/you/project",
                             value: formValues["mcp-args-input"] ?? "", rows: 4)
                        .attribute("data-component-id", "mcp-args-input")
                    Small("Passed verbatim as argv — quotes are not interpreted, so an argument containing spaces works as typed.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
                Div {
                    Label("Environment (KEY=VALUE, one per line)", for: "mcp-env-input")
                    TextArea(id: "mcp-env-input", name: "mcp-env-input",
                             placeholder: "GITHUB_PERSONAL_ACCESS_TOKEN=ghp_…",
                             value: formValues["mcp-env-input"] ?? "", rows: 3)
                        .attribute("data-component-id", "mcp-env-input")
                    Small("arc strips its own ARC_/OPENAI_/ANTHROPIC_ variables from every MCP server — this is how a server gets its own credentials.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
            }
            Div(class: "row-actions-main") {
                ArcButton("Save", class: "primary-btn", type: .submit)
                ArcButton("Cancel", id: "mcp-cancel", component: "mcp-cancel", class: "ghost-btn")
            }
        }
        .attribute("data-component-id", "mcp-form")
    }

    func schemaHTML(_ schema: JSONSchema) -> some WebUI.View {
        Group {
            switch schema {
            case .object(let desc, let properties, let required):
                if let d = desc {
                    AkvRow(key: "Object", value: d)
                }
                let req = Set(required ?? [])
                // sorted: a dictionary's iteration order must never reach the page
                for (key, prop) in properties.sorted(by: { $0.key < $1.key }) {
                    AkvRow {
                        Text(key)
                        Small(" (\(schemaTypeLabel(prop)))")
                            .attribute("style", "color:var(--muted)")
                    } value: {
                        Text(schemaOneLine(prop))
                        if req.contains(key) {
                            Span(class: "mc-badge") { Text("required") }
                                .attribute("style", "margin-left:6px")
                        }
                    }
                }
            case .array(let desc, let items):
                AkvRow(key: "Array of", value: "\(schemaTypeLabel(items)) — \(desc ?? "")")
            default:
                AkvRow(key: "Type", value: schemaTypeLabel(schema))
                if let d = schemaDescription(schema) {
                    AkvRow(key: "Description", value: d)
                }
            }
        }
    }

    func schemaTypeLabel(_ s: JSONSchema) -> String {
        switch s {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .object: return "object"
        case .array: return "array"
        case .enum: return "enum"
        }
    }

    func schemaDescription(_ s: JSONSchema) -> String? {
        switch s {
        case .string(let d, _): return d
        case .integer(let d, _): return d
        case .number(let d, _): return d
        case .boolean(let d, _): return d
        case .object(let d, _, _): return d ?? ""
        case .array(let d, _): return d ?? ""
        case .enum(let d, _): return d
        }
    }

    func schemaOneLine(_ s: JSONSchema) -> String {
        switch s {
        case .enum(let d, let values):
            return d + " — " + values.joined(separator: " | ")
        default:
            return schemaDescription(s) ?? ""
        }
    }

    // MARK: Workspaces main

    func workspacesMain() -> some WebUI.View {
        if createWorkspace {
            return mainScroll {
                Form(method: nil, id: "ws-create-form", class: "detail-card ws-form") {
                    Heading("New workspace", level: .h1, class: "detail-title")
                    Div(class: "detail-sub") {
                        Text("A workspace points at any folder on this computer. The folder path is required and follows Unix path rules; the name is an optional label — leave it blank and it is derived from the folder. Sessions keep their own workspace per chat; you pick it in the chat composer.")
                    }
                    Div(class: "form-grid") {
                        Div {
                            Label("Folder path", for: "ws-path-input")
                            Input(id: "ws-path-input", name: "ws-path-input", placeholder: "/Users/you/research or ~/research",
                                  type: .text, value: formValues["ws-path-input"] ?? "",
                                  attributes: [("data-component-id", "ws-path-input"),
                                               ("autofocus", "")])
                            Small("Required. An absolute path; ~ means your home folder.")
                                .attribute("class", "form-hint")
                        }
                        Div {
                            Label("Name (optional)", for: "ws-name-input")
                            Input(id: "ws-name-input", name: "ws-name-input", placeholder: "derived from the folder name",
                                  type: .text, value: formValues["ws-name-input"] ?? "",
                                  attributes: [("data-component-id", "ws-name-input")])
                            Small("A label for the switcher — any text except '/'.")
                                .attribute("class", "form-hint")
                        }
                    }
                    Div(class: "row-actions-main") {
                        ArcButton("Create", class: "primary-btn", type: .submit)
                        ArcButton("Cancel", id: "ws-cancel", component: "ws-cancel", class: "ghost-btn")
                    }
                }
                .attribute("data-component-id", "ws-create-form")
            }
        }
        let ws = settings.activeWorkspace
        let path = workspacePath(for: nil)
        return mainScroll {
            Div(class: "detail-card") {
                DetailTitle("Workspaces", icon: .grid)
                Div(class: "detail-sub") {
                    Text("Workspaces are folders on this computer. Each chat keeps its own workspace, chosen in the chat composer.")
                }
                AkvRow(key: "Default", value: ws)
                AkvRow(key: "Folder", value: path)
                AkvRow(key: "Sessions", value: "\(sessions.count)")
                AkvRow(key: "Note", value: "All chats share one session list; switching a chat's workspace changes its working folder, not the conversation list.")
            }
        }
    }

    // MARK: Settings main

    /// Settings → Agent powers: lockdown toggles for skill and profile
    /// (MEMORY/USER/SOUL/AGENTS) mutation. These write `agentPowers` in
    /// ~/.arc/config.json; the running agent picks them up on next start and
    /// the dedicated tools (skill_creation / skill_edit / profile_edit) refuse
    /// locked surfaces.

    /// Settings: editable tool-iteration limit and per-tool call cap
    /// (`agent.max_turns` + `guardrails.toolLoopCap`, arc parity). Values
    /// of 0/negative mean unlimited; the UI writes -1 for that state.
    func agentLimitsSection() -> some WebUI.View {
        let rawMax: Int? = arcConfig.agent.max_turns ?? arcConfig.max_turns
        let maxUnlimited = (rawMax ?? 1) <= 0
        let effMax = arcConfig.effectiveMaxTurns()
        let maxValue = effMax == Int.max ? 90 : effMax
        let rawLoop: Int? = arcConfig.guardrails.toolLoopCap
        let loopUnlimited = (rawLoop ?? 1) <= 0
        let effLoop = arcConfig.effectiveToolLoopCap()
        let loopValue = effLoop == Int.max ? 25 : effLoop

        // `disabled` is presence-only and `.attribute` takes a non-optional
        // String, so the two shapes are built rather than passed a nil.
        func numField(_ id: String, _ value: Int, disabled: Bool) -> some WebUI.View {
            Group {
                if disabled {
                    Input(id: id, type: .number, value: "\(value)")
                        .attribute("min", "1")
                        .attribute("step", "1")
                        .attribute("disabled", "")
                        .attribute("class", "num-input")
                } else {
                    Input(id: id, type: .number, value: "\(value)")
                        .attribute("min", "1")
                        .attribute("step", "1")
                        .attribute("class", "num-input")
                }
            }
        }

        return Section(id: "agent-limits", class: "set-section") {
            Heading("Agent limits", level: .h2)
            DetailCard {
                SettingRow {
                    Text("Tool iteration limit")
                    Small("Tool-calling iterations allowed per turn before the agent is asked to wrap up (reference max_turns, default 90).")
                } control: {
                    Div {
                        numField("al-max-turns", maxValue, disabled: maxUnlimited)
                    }
                    .attribute("id", "al-max-turns-wrap")
                    .attribute("data-component-id", "al-max-turns")
                    .attribute("data-event", "change")
                }
                SettingRow {
                    Text("Unlimited tool iterations")
                    Small("No iteration cap: the turn keeps running until the agent finishes the prompt on its own.")
                } control: {
                    Div {
                        ArcSwitch(id: "al-max-turns-unlimited", on: maxUnlimited)
                    }
                    .attribute("id", "al-max-turns-unl-wrap")
                    .attribute("data-component-id", "al-max-turns-unlimited")
                    .attribute("data-event", "change")
                }
                SettingRow {
                    Text("Per-tool call cap")
                    Small("How many times one tool may run per turn before a synthetic \"N calls (cap N)\" reply (default 25).")
                } control: {
                    Div {
                        numField("al-tool-cap", loopValue, disabled: loopUnlimited)
                    }
                    .attribute("id", "al-tool-cap-wrap")
                    .attribute("data-component-id", "al-tool-cap")
                    .attribute("data-event", "change")
                }
                .attribute("style", "margin-top:14px")
                SettingRow {
                    Text("Unlimited per-tool calls")
                    Small("No synthetic call cap for any tool in a turn.")
                } control: {
                    Div {
                        ArcSwitch(id: "al-tool-cap-unlimited", on: loopUnlimited)
                    }
                    .attribute("id", "al-tool-cap-unl-wrap")
                    .attribute("data-component-id", "al-tool-cap-unlimited")
                    .attribute("data-event", "change")
                }
            }
        }
    }

    func agentPowersSection() -> some WebUI.View {
        let powers = arcConfig.agentPowers
        let lockedNames = Set(powers.lockedSkills)

        // two switch shapes, deliberately:
        // - the recurring switches carry their own data-component-id so the
        //   runtime can address the input directly;
        // - per-item rows carry NONE, so the runtime resolves the component to
        //   the container below (whose wire dispatches on `targetId`). an id on
        //   the input would make the client address the checkbox and the
        //   container wire would never fire.
        let profileFiles: [(key: String, label: String, detail: String)] = [
            ("memory", "MEMORY.md", "the agent's persistent notes (memory tool, profile_edit)"),
            ("user", "USER.md", "the user profile"),
            ("soul", "SOUL.md", "the profile persona/prompt"),
        ]

        return Div {
            DetailCard {
                Heading("Skills", level: .h3)
                    .attribute("style", "margin:0 0 6px")
                SettingRow {
                    Text("Agent can create/edit skills")
                    Small("When off, skill_creation and skill_edit refuse, and write_file/terminal refuse writes under the skills directory. Skills become readable-only.")
                } control: {
                    ArcSwitch(id: "ap-skills-global", on: powers.skillsManage,
                              component: "ap-skills-global", event: "change")
                }
                Div(class: "detail-sub") {
                    Text("Locked skills")
                    Small("Individually locked skills cannot be edited (skill_edit refuses them).")
                }
                .attribute("style", "margin:10px 0 4px")
                Div(class: "ap-skills-scroll") {
                    if skills.isEmpty {
                        Div(class: "empty-hint") { Text("No skills discovered yet.") }
                    } else {
                        for sk in skills {
                            SettingRow {
                                Text(sk.name)
                                Small("Locked: skill_edit refuses this skill.")
                            } control: {
                                ArcSwitch(id: "ap-skill-lock-\(sk.name)",
                                          on: lockedNames.contains(sk.name),
                                          value: "ap-skill-lock-\(sk.name)")
                            }
                        }
                    }
                }
                .attribute("id", "ap-skill-locks")
                .attribute("data-component-id", "ap-skill-locks")
                .attribute("data-event", "change")
            }
            DetailCard {
                Heading("Profile (MEMORY / USER / SOUL)", level: .h3)
                    .attribute("style", "margin:0 0 6px")
                SettingRow {
                    Text("Agent can edit the profile")
                    Small("When off, profile_edit and the memory tool refuse writes to MEMORY/USER/SOUL, and write_file/terminal refuse those files.")
                } control: {
                    ArcSwitch(id: "ap-profile-global", on: powers.profileEdit,
                              component: "ap-profile-global", event: "change")
                }
                Div(class: "detail-sub") {
                    Text("Locked profile files")
                    Small("These cannot be edited by the agent while locked. AGENTS.md is workspace-scoped and stays outside the profile.")
                }
                .attribute("style", "margin:10px 0 4px")
                Div {
                    for f in profileFiles {
                        SettingRow {
                            Text(f.label)
                            Small("\(f.detail).")
                        } control: {
                            ArcSwitch(id: "ap-profilefile-lock-\(f.key)",
                                      on: powers.lockedProfileFiles.contains(f.key),
                                      value: "ap-profilefile-lock-\(f.key)")
                        }
                    }
                }
                .attribute("id", "ap-profilefile-locks")
                .attribute("data-component-id", "ap-profilefile-locks")
                .attribute("data-event", "change")
            }
            .attribute("style", "margin-top:12px")
        }
        .attribute("id", "agent-powers")
    }


    func storageSettingsHTML() -> some WebUI.View {
        func mediumLabel(_ medium: String) -> String {
            if medium == "file" { return "Local file storage" }
            if medium == "config" { return "Default (config.json)" }
            return settings.storageConnections.first(where: { $0.id == medium })?.name ?? "Unknown storage"
        }
        // The effective medium = what the RUNTIME is actually using. A hosted
        // daemon always boots config.json's tessera (or file), so while the
        // AppState is attached to the daemon's pair the truth is "config",
        // NOT the persisted picker choice (which may be stale after the user
        // saved a connection the daemon never applied). Once the picker has
        // actually connected (attach detached), the choice is the truth.
        let effectiveFile = runtimeBackend == "file"
        let effectiveMedium = effectiveFile ? "file" : (attachedStorage != nil ? "config" : settings.activeStorage)
        let canConnect = stagedStorage != nil && stagedStorage != effectiveMedium

        func badges(active: Bool, staged: Bool) -> [any WebUI.View] {
            var out: [any WebUI.View] = []
            if active { out.append(Span(class: "dd-badge sel") { Text("ACTIVE") }) }
            if staged { out.append(Span(class: "dd-badge") { Text("SELECTED") }) }
            return out
        }
        func incomplete(_ conn: TesseraStorageConnection) -> [any WebUI.View] {
            guard let note = conn.completenessNote else { return [] }
            return [Text(" — "), Span(class: "set-warn") { Text(note) }]
        }

        let connections = settings.storageConnections
        return Section(id: "storage", class: "set-section") {
            Heading("Storage", level: .h2)
            DetailCard {
                Heading("Storage medium", level: .h3)
                    .attribute("style", "margin:0 0 6px")
                Div(class: "detail-sub") {
                    Text("Where sessions, memory and profiles are saved. Picking a medium only stages it — press ")
                    Strong("Save and Connect")
                    Text(" to actually switch.")
                }
                .attribute("style", "margin-bottom:10px")
                Div(class: "set-row set-row-stack-lg") {
                    Div(class: "set-label") {
                        Text("Connected storage")
                        Small("\(storageDescription()).")
                    }
                    Div(class: "storage-picker-row") {
                        Div(class: "dd dd-settings") {
                            ddTrigger(id: "storage-pick-toggle", icon: .database,
                                      label: mediumLabel(effectiveMedium),
                                      title: "Storage medium in use")
                            Div(class: storagePickOpen ? "dd-pop dd-pop-down" : "dd-pop dd-pop-down hidden") {
                                Div(class: "dd-note") {
                                    Text("Pick a medium, then press ")
                                    Strong("Save and Connect")
                                    Text(" to switch.")
                                }
                                Div(class: "dd-list") {
                                    ddRow(id: "storage-pick-file") {
                                        Span(class: "dd-row-title") {
                                            Text("Local file storage ")
                                            Span(class: "dd-badges") {
                                                for b in badges(active: effectiveFile,
                                                                staged: stagedStorage == "file") { b }
                                            }
                                        }
                                        Span(class: "dd-row-sub") {
                                            Text("~/.arc/sessions + memories — always available, needs no relay")
                                        }
                                    }
                                    ddRow(id: "storage-pick-config") {
                                        Span(class: "dd-row-title") {
                                            Text("Default (config.json) ")
                                            Span(class: "dd-badges") {
                                                for b in badges(active: !effectiveFile && effectiveMedium == "config",
                                                                staged: stagedStorage == "config") { b }
                                            }
                                        }
                                        Span(class: "dd-row-sub") {
                                            Text("Tessera from the tessera block of ~/.arc/config.json")
                                        }
                                    }
                                    for conn in connections {
                                        ddRow(id: "storage-pick-conn-\(enc(conn.id))") {
                                            Span(class: "dd-row-title") {
                                                Text("\(conn.name) ")
                                                Span(class: "dd-badges") {
                                                    for b in badges(active: !effectiveFile && effectiveMedium == conn.id,
                                                                    staged: stagedStorage == conn.id) { b }
                                                }
                                            }
                                            Span(class: "dd-row-sub") {
                                                Text("\(conn.endpointLabel) — app \(conn.application)")
                                                for n in incomplete(conn) { n }
                                            }
                                        }
                                    }
                                }
                            }
                            .attribute("data-component-id", "storage-pick")
                            .attribute("data-event", "click")
                        }
                        ArcButton("Save and Connect", id: "storage-connect",
                                  component: "storage-connect", class: "primary-btn",
                                  disabled: !canConnect)
                    }
                    if let st = stagedStorage {
                        Div(class: "set-hint") {
                            Text("Selected: ")
                            Strong(mediumLabel(st))
                            Text(" — not connected yet. Press ")
                            Strong("Save and Connect")
                            Text(".")
                        }
                        .attribute("style", "margin:2px 0 0 0")
                    }
                }
            }
            DetailCard {
                Heading("Tessera storages", level: .h3)
                    .attribute("style", "margin:0 0 6px")
                Div(class: "detail-sub") {
                    Text("Connections to different Tessera relays (signed NOSTR event stores). A connection must be complete (IP, port, public key, client private key) before it can be picked and connected to.")
                }
                .attribute("style", "margin-bottom:10px")
                if connections.isEmpty {
                    Div(class: "empty-hint") { Text("No tessera storages configured.") }
                } else {
                    for conn in connections {
                        let encID = enc(conn.id)
                        Div(class: "mc-row") {
                            Span(class: "mc-name") {
                                Text("\(conn.name) ")
                                if !effectiveFile && effectiveMedium == conn.id {
                                    Span(class: "mc-badge") { Text("connected") }
                                }
                                if stagedStorage == conn.id {
                                    Span(class: "mc-badge") { Text("selected") }
                                }
                            }
                            Span(class: "mc-model") {
                                Text("\(conn.endpointLabel) · app \(conn.application)")
                                for n in incomplete(conn) { n }
                            }
                            Div(class: "storage-row-actions") {
                                Div {
                                    ArcButton("Edit", id: "storage-edit-\(encID)",
                                              class: "ghost-btn btn-sm")
                                }
                                .attribute("data-component-id", "storage-edit")
                                .attribute("data-event", "click")
                                Div {
                                    ArcButton("Remove", id: "storage-del-\(encID)",
                                              class: "danger-btn btn-sm")
                                }
                                .attribute("data-component-id", "storage-del")
                                .attribute("data-event", "click")
                            }
                        }
                    }
                }
                storageConnForm(connections: connections)
            }
            .attribute("style", "margin-top:12px")
            DetailCard {
                SettingRow {
                    Text("Mixture of Agents")
                    Small {
                        Text("Fan out reference-model advice before the main call. Reference models come from the ")
                        InlineCode("moa")
                        Text(" block of ~/.arc/config.json; without them this does nothing.")
                    }
                } control: {
                    ArcSwitch(id: "set-moa", on: settings.moaEnabled,
                              component: "set-moa", event: "change")
                }
            }
            .attribute("style", "margin-top:12px")
        }
    }

    /// the saved-connection form: the `sc-*` field names are the submit payload
    /// keys the engine's form extractor builds, so they must not drift.
    private func storageConnForm(connections: [TesseraStorageConnection]) -> some WebUI.View {
        let se = storageEdit
        return Form(method: nil, id: "storage-conn-form", class: "form-grid form-sep") {
            Input(id: "storage-edit-id", name: "storage-edit-id", type: .hidden,
                  value: se?.id ?? "",
                  attributes: [("data-component-id", "storage-edit-id")])
            Div(class: "form-grid-3") {
                Div {
                    Label("Name", for: "sc-name")
                    Input(id: "sc-name", name: "sc-name", placeholder: "Home relay",
                          type: nil, value: se?.name ?? "",
                          attributes: [("data-component-id", "sc-name"), ("autocomplete", "off")])
                }
                Div {
                    Label("Server IP / host", for: "sc-ip")
                    Input(id: "sc-ip", name: "sc-ip", placeholder: "10.0.0.1",
                          type: nil, value: se?.serverIP ?? "",
                          attributes: [("data-component-id", "sc-ip"), ("autocomplete", "off")])
                }
                Div {
                    Label("Port", for: "sc-port")
                    Input(id: "sc-port", name: "sc-port", placeholder: "51820",
                          type: .number, value: se.map { String($0.serverPort) } ?? "",
                          attributes: [("data-component-id", "sc-port"),
                                       ("autocomplete", "off"),
                                       ("min", "1"), ("max", "65535")])
                }
            }
            Div {
                Label("Application id", for: "sc-app")
                Input(id: "sc-app", name: "sc-app", placeholder: "1",
                      type: .number, value: se.map { String($0.application) } ?? "",
                      attributes: [("data-component-id", "sc-app"),
                                   ("min", "0"), ("max", "65535")])
            }
            Div(class: "form-grid-2") {
                Div {
                    Label("Server public key", for: "sc-pub")
                    Input(id: "sc-pub", name: "sc-pub", placeholder: "base64 (32 bytes)",
                          type: nil, value: se?.serverPublicKey ?? "",
                          attributes: [("data-component-id", "sc-pub"), ("autocomplete", "off")])
                }
                Div {
                    Label("Client private key", for: "sc-priv")
                    // a private key is never a password-manager login: this input
                    // opts out of autofill (pinned).
                    Input(id: "sc-priv", name: "sc-priv", placeholder: "base64 (32 bytes)",
                          type: .password, value: se?.myPrivateKey ?? "",
                          attributes: [("data-component-id", "sc-priv"),
                                       ("autocomplete", "new-password")])
                }
            }
            Div(class: "row-actions-main row-actions-flush") {
                ArcButton(se == nil ? "Add storage" : "Update storage",
                          class: "primary-btn", type: .submit)
                if se != nil {
                    ArcButton("Cancel", id: "storage-cancel-edit",
                              component: "storage-cancel-edit", class: "ghost-btn btn-sm")
                }
            }
        }
        .attribute("data-component-id", "storage-conn-form")
    }

    func settingsMain() -> some WebUI.View {
        Div(class: "main-view") {
            Div(id: "main-scroll", class: "main-scroll settings-wrap") {
                settingsAppearanceSection()
                settingsPreferencesSection()
                settingsAssistanceSection()
                agentLimitsSection()
                storageSettingsHTML()
                settingsToolPluginsSection()
                settingsMCPSection()
                settingsSidebarPluginsSection()
                settingsAboutSection()
            }
            .attribute("data-scroll-key", "main-scroll")
        }
    }

    // MARK: - settings · appearance

    private func settingsAppearanceSection() -> some WebUI.View {
        let themeDefs: [(key: String, label: String, icon: IconName, preview: String)] = [
            ("light", "Light", .sun,
             "background:#FFFFFF;border:1px solid rgba(0,0,0,0.14)"),
            ("dark", "Dark", .moon,
             "background:#0D1117;border:1px solid rgba(255,255,255,0.10)"),
            ("system", "System", .monitor,
             "background:linear-gradient(100deg,#FFFFFF 0%,#8B8B93 52%,#15151A 100%);border:1px solid rgba(0,0,0,0.12)"),
        ]
        let actOpts: [(String, String)] = [
            ("compact_worklog", "Compact Worklog"),
            ("transparent_stream", "Transparent Stream"),
            ("hide_all_activity", "Final answer only"),
        ]
        var tabDefs: [(key: String, label: String)] = [
            ("skills", "Skills"), ("profiles", "Profiles"), ("tools", "Tools"),
            ("workspaces", "Workspace"), ("kanban", "Kanban"), ("memory", "Memory"),
            ("insights", "Insights"), ("logs", "Logs"), ("tasks", "Tasks"), ("todos", "Todos"),
        ]
        for id in pluginTabs.keys.sorted() {
            if let tab = pluginTabs[id] {
                tabDefs.append((id, tab.title))
            }
        }
        // Chips follow the canonical sidebar order; state = hidden set.
        let chipKeys = settings.sidebarTabs.filter { key in tabDefs.contains { $0.key == key } }
            + tabDefs.map(\.key).filter { key in !settings.sidebarTabs.contains(key) }

        return Section(id: "appearance", class: "set-section") {
            Heading("Appearance", level: .h2)
            DetailCard {
                Div(class: "set-row set-row-stack") {
                    Div(class: "set-label") {
                        Text("Theme")
                        Small("Light, dark, or follow the system.")
                    }
                    Div(class: "thm-grid") {
                        for t in themeDefs {
                            let active = settings.theme == t.key
                            // UX-08: the card marks selection visually (.active) — the
                            // pressed state must reach assistive tech too.
                            ArcButton(id: "thm-\(t.key)",
                                      class: "theme-pick-btn\(active ? " active" : "")") {
                                Span(class: "thm-preview") {
                                    Span(class: "thm-ic") { WebUIIcon(t.icon, size: .medium) }
                                }
                                .attribute("style", t.preview)
                                Span(class: "thm-label") { Text(t.label) }
                            }
                            .attribute("data-theme-choice", t.key)
                            .attribute("title", t.label)
                            .attribute("aria-pressed", active ? "true" : "false")
                        }
                    }
                    .attribute("data-component-id", "theme-pick")
                    .attribute("data-event", "click")
                }
                Div(class: "set-row set-row-stack") {
                    Div(class: "set-label") {
                        Text("Text size")
                        Small("Chat content, session names, workspace files, and memory text.")
                    }
                    Div(class: "fsz-grid") {
                        for s in ThemeSize.allCases {
                            let active = settings.textSize == s.rawValue
                            ArcButton(id: "fsz-\(s.rawValue)",
                                      class: "font-size-pick-btn\(active ? " active" : "")") {
                                Span(class: "fsz-preview") { Text("Aa") }
                                    .attribute("style", "font-size:\(s.previewPx)")
                                Span(class: "fsz-label") { Text(s.label) }
                            }
                            .attribute("title", s.label)
                            .attribute("aria-pressed", active ? "true" : "false")
                        }
                    }
                    .attribute("data-component-id", "font-size-pick")
                    .attribute("data-event", "click")
                }
                Div(class: "set-row set-row-stack") {
                    Div(class: "set-label") {
                        Text("Color scheme")
                        Small("Full palette for the interface.")
                    }
                    // the scheme grid renders from the catalog: identity — id, label,
                    // swatch — comes from the providers themselves, so the picker cannot
                    // list a scheme the sheet does not carry, and adding one is a single
                    // declaration. `swatch[0]` is the accent (the tile's border), the
                    // rest are the preview dots.
                    Div(class: "scheme-grid") {
                        for entry in ArcThemeCatalog.entries {
                            let active = settings.colorScheme == entry.id
                            let accent = entry.swatch.first ?? ""
                            ArcButton(id: "scheme-\(enc(entry.id))",
                                      class: "scheme-tile\(active ? " active" : "")") {
                                Span(class: "scheme-dots") {
                                    for d in entry.swatch.dropFirst() {
                                        Span(class: "scheme-dot") {}
                                            .attribute("style", "background:\(d)")
                                    }
                                }
                                Span(class: "scheme-name") { Text(entry.label) }
                            }
                            .attribute("data-scheme-choice", entry.id)
                            .attribute("title", entry.label)
                            .attribute("aria-pressed", active ? "true" : "false")
                            .attribute("style", "--sw-accent:\(accent)")
                        }
                    }
                    .attribute("data-component-id", "scheme-pick")
                    .attribute("data-event", "click")
                }
                SettingRow {
                    Text("Show conversation outline")
                    Small("Adds a floating button to the chat view that lists your sent messages; clicking one jumps to it.")
                } control: {
                    ArcSwitch(id: "set-showoutline", on: settings.showConversationOutline,
                              component: "set-showoutline", event: "change")
                }
                SettingRow {
                    Text("Activity display")
                    Small("How thinking and tool activity appear in chats.")
                } control: {
                    Div(class: "bubble-opts") {
                        for (mode, label) in actOpts {
                            let active = settings.activityDisplay == mode
                            ArcButton(label, id: "actdisp-\(mode)",
                                      class: "bubble-opt\(active ? " active" : "")")
                                .attribute("aria-pressed", active ? "true" : "false")
                        }
                    }
                    .attribute("data-component-id", "activity-display")
                    .attribute("data-event", "click")
                }
                Div(class: "set-row set-row-stack-lg") {
                    Div(class: "set-label") { Text("Sidebar tabs") }
                    Div(class: "side-tab-chips") {
                        for key in chipKeys {
                            let label = tabDefs.first { $0.key == key }?.label ?? key
                            let on = !settings.hiddenSidebarTabs.contains(key)
                            // UX-13: real buttons (keyboard-operable) with a visible
                            // pressed state; the off chip is dimmed and labels itself "Hidden".
                            ArcButton(id: "st-\(enc(key))",
                                      class: "side-tab-chip\(on ? " on" : " off")") {
                                Span { Text(label) }
                                if !on {
                                    Emphasis("Hidden").attribute("class", "chip-hint")
                                }
                            }
                            .attribute("value", "st-\(enc(key))")
                            .attribute("aria-pressed", on ? "true" : "false")
                            .attribute("data-no-restore", "")
                            .attribute("draggable", "true")
                        }
                    }
                    .attribute("data-component-id", "side-tab-chips")
                    .attribute("data-event", "click")
                    Input(id: "sidebar-tab-order", type: .hidden,
                          value: settings.sidebarTabs.joined(separator: ","),
                          attributes: [("data-component-id", "sidebar-tab-order"),
                                       ("data-event", "change")])
                    Div(class: "set-hint") {
                        Text("Choose which tabs appear in the sidebar and rail. Drag chips to reorder them. Chat and Settings are always visible.")
                    }
                }
            }
        }
    }

    // MARK: - settings · preferences

    private func settingsPreferencesSection() -> some WebUI.View {
        let levels = ["off", "low", "medium", "high", "max"]
        return Section(id: "preferences", class: "set-section") {
            Heading("Preferences", level: .h2)
            DetailCard(extraClass: "card-lead") {
                SettingRow {
                    Text("Default thinking level")
                    Small("Applied to new chats; per-chat override in the composer.")
                } control: {
                    Select(id: "set-think",
                           options: levels.map { SelectOption(value: $0, label: $0.capitalized) },
                           selected: settings.thinkingLevel)
                        .attribute("data-component-id", "set-think")
                        .attribute("data-event", "change")
                }
            }
            DetailCard(extraClass: "card-stack") {
                Heading("Chat", level: .h3, class: "card-h3")
                SettingRow {
                    Text("Show token usage")
                    Small {
                        Text("Displays input/output token count below each assistant reply. Also toggled with ")
                        InlineCode("/usage")
                        Text(".")
                    }
                } control: {
                    ArcSwitch(id: "set-showtokens", on: settings.showTokenUsage,
                              component: "set-showtokens", event: "change")
                }
                SettingRow {
                    Text("Show token speed (TPS)")
                    Small("Displays tokens per second in assistant message headers while streaming and after a response completes. Off by default.")
                } control: {
                    ArcSwitch(id: "set-showtps", on: settings.showTps,
                              component: "set-showtps", event: "change")
                }
                SettingRow {
                    Text("Pinned conversations limit")
                    Small("Maximum number of active conversations that can be pinned in the sidebar. Default is 3.")
                } control: {
                    Input(id: "set-pinlimit", type: .number,
                          value: "\(settings.pinnedSessionsLimit)",
                          attributes: [("data-component-id", "set-pinlimit"),
                                       ("data-event", "change"),
                                       ("min", "1"), ("max", "99"), ("step", "1"),
                                       ("class", "num-input")])
                }
            }
            DetailCard {
                Heading("Model configurations", level: .h3, class: "card-h3")
                Div(class: "detail-sub card-sub") {
                    Text("Add or remove the model configurations available in every chat's config selector.")
                }
                Div {
                    if settings.modelConfigs.isEmpty {
                        Div(class: "empty-hint") { Text("No model configurations.") }
                    } else {
                        for c in settings.modelConfigs {
                            let encName = enc(c.name)
                            Div(class: "mc-row") {
                                Span(class: "mc-name") {
                                    Text("\(c.name) ")
                                    if c.name == settings.activeConfig {
                                        Span(class: "mc-badge") { Text("active") }
                                    }
                                }
                                Span(class: "mc-model") { Text(c.model) }
                                Div(class: "row-actions-main row-actions-flush") {
                                    ArcButton("Remove", id: "mc-del-\(encName)",
                                              class: "danger-btn btn-sm")
                                }
                            }
                        }
                    }
                }
                .attribute("data-component-id", "modelcfg-list")
                .attribute("data-event", "click")
                modelConfigAddForm()
            }
            DetailCard(extraClass: "card-stack") {
                Heading("Main model", level: .h3, class: "card-h3")
                Div(class: "detail-sub card-sub") {
                    Text("The model used for new chats by default. Picked from the Model configurations above.")
                }
                Div(class: "set-row set-row-stack-lg") {
                    mainModelDropdown()
                }
            }
            DetailCard(extraClass: "card-stack") {
                Heading("Auxiliary models", level: .h3, class: "card-h3")
                Div(class: "detail-sub card-sub") {
                    Text("Auxiliary tasks (vision, compression, approval, titles, …) use a dedicated model from the ")
                    InlineCode("auxiliary")
                    Text(" block of ~/.arc/config.json. Empty overrides fall back to the chat's main model.")
                }
                Div(class: "aux-list") {
                    for task in AuxiliaryTask.allCases {
                        auxiliaryRow(task)
                    }
                }
            }
        }
    }

    private func modelConfigAddForm() -> some WebUI.View {
        Form(method: nil, id: "modelcfg-add-form", class: "form-grid form-sep") {
            Div(class: "form-grid-3") {
                Div {
                    Label("Name", for: "mc-name")
                    Input(id: "mc-name", name: "mc-name", placeholder: "deepseek-v4-flash",
                          type: nil,
                          attributes: [("data-component-id", "mc-name"),
                                       ("autocomplete", "off"), ("spellcheck", "false")])
                }
                Div {
                    Label("Model", for: "mc-model")
                    Input(id: "mc-model", name: "mc-model", placeholder: "deepseek-v4-flash",
                          type: nil,
                          attributes: [("data-component-id", "mc-model"),
                                       ("autocomplete", "off"), ("spellcheck", "false")])
                }
                Div {
                    Label("Provider", for: "mc-provider")
                    Input(id: "mc-provider", name: "mc-provider", placeholder: "custom",
                          type: nil,
                          attributes: [("data-component-id", "mc-provider"),
                                       ("autocomplete", "off"), ("spellcheck", "false")])
                }
            }
            Div {
                Label("Base URL", for: "mc-baseurl")
                Input(id: "mc-baseurl", name: "mc-baseurl",
                      placeholder: "https://api.openai.com/v1", type: nil,
                      attributes: [("data-component-id", "mc-baseurl"),
                                   ("autocomplete", "off"), ("spellcheck", "false")])
            }
            Div(class: "form-grid-2") {
                Div {
                    Label("API key (optional)", for: "mc-apikey")
                    Input(id: "mc-apikey", name: "mc-apikey", placeholder: "sk-…",
                          type: .password,
                          attributes: [("data-component-id", "mc-apikey"),
                                       ("autocomplete", "new-password"),
                                       ("spellcheck", "false")])
                }
                Div {
                    Label("Context length (optional)", for: "mc-ctx")
                    Input(id: "mc-ctx", name: "mc-ctx", placeholder: "128000",
                          type: .text,
                          attributes: [("data-component-id", "mc-ctx"),
                                       ("autocomplete", "off")])
                }
                Div {
                    Label("Max output tokens (optional)", for: "mc-maxtok")
                    Input(id: "mc-maxtok", name: "mc-maxtok", placeholder: "32768",
                          type: .text,
                          attributes: [("data-component-id", "mc-maxtok"),
                                       ("autocomplete", "off")])
                }
            }
            Div(class: "row-actions-main row-actions-flush") {
                ArcButton("Add configuration", class: "primary-btn", type: .submit)
            }
        }
        .attribute("data-component-id", "modelcfg-add-form")
    }

    /// one auxiliary task: either the inline editor (when it is the task being
    /// edited) or its summary row. the summary text is the five-way fallback the
    /// overrides allow, and `Main model` when nothing is set.
    private func auxiliaryRow(_ task: AuxiliaryTask) -> some WebUI.View {
        let ov = arcConfig.auxiliary.override(for: task)
        let has = ov?.isSet == true

        if auxEditingTask == task.key {
            let stagedName = auxStagedConfig[task.key] ?? auxOverrideConfigName(ov) ?? ""
            let stagedKnown = settings.modelConfigs.contains { $0.name == stagedName }
            let triggerLabel: String
            if stagedName.isEmpty || !stagedKnown {
                triggerLabel = "Main model (auto)"
            } else {
                triggerLabel = stagedName
            }
            return Group {
                Div(class: "aux-editing") {
                    Form(method: nil, id: "aux-form-\(task.key)") {
                        Div(class: "aux-fields") {
                            Input(name: "aux-task", type: .hidden, value: task.key)
                            FieldLabel(class: "aux-field") {
                                Text("Model configuration")
                                Div(class: "dd") {
                                    ArcButton(id: "auxmc-toggle-\(task.key)",
                                              component: "auxmc-toggle", class: "dd-trigger") {
                                        Span(class: "dd-trigger-label") { Text(triggerLabel) }
                                        WebUIIcon(.chevronDown, size: .small)
                                    }
                                    .attribute("title", "Auxiliary model configuration")
                                    Div(class: auxConfigPickerOpen ? "dd-pop dd-pop-ws" : "dd-pop dd-pop-ws hidden") {
                                        Div(class: "dd-list") {
                                            ddRow(id: "auxmc-main-\(task.key)") {
                                                Span(class: "dd-model-main") {
                                                    Span(class: "dd-row-title") {
                                                        Text("Main model (auto)")
                                                        if stagedName.isEmpty || !stagedKnown {
                                                            Span(class: "dd-badge sel") { Text("SELECTED") }
                                                        }
                                                    }
                                                    Span(class: "dd-row-sub") {
                                                        Text("Use the chat's main model")
                                                    }
                                                }
                                            }
                                            for c in settings.modelConfigs {
                                                ddRow(id: "auxmc-\(task.key)-\(enc(c.name))") {
                                                    Span(class: "dd-model-main") {
                                                        Span(class: "dd-row-title") {
                                                            Text(c.name)
                                                            if c.name == stagedName {
                                                                Span(class: "dd-badge sel") { Text("SELECTED") }
                                                            }
                                                        }
                                                        Span(class: "dd-row-sub") {
                                                            Text(c.model)
                                                            if !c.provider.isEmpty {
                                                                Text(" @ " + c.provider)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .attribute("data-component-id", "auxmc")
                                    .attribute("data-event", "click")
                                }
                            }
                            if let ov, has, auxOverrideConfigName(ov) == nil {
                                let raw = ov.model.isEmpty
                                    ? (ov.provider.isEmpty ? "custom override" : "provider: \(ov.provider)")
                                    : ov.model + (ov.provider.isEmpty ? "" : " @ " + ov.provider)
                                Div(class: "aux-custom-note") {
                                    Text("Currently: ")
                                    InlineCode(raw)
                                    Text(" — pick a configuration below (or Main model) and Save to replace it; Cancel keeps it.")
                                }
                            }
                        }
                        Div(class: "aux-actions") {
                            ArcButton("Save", class: "primary-btn", type: .submit)
                            ArcButton("Cancel", id: "aux-cancel-\(task.key)", class: "ghost-btn")
                        }
                        .attribute("data-component-id", "aux-edit")
                        .attribute("data-event", "click")
                    }
                    .attribute("data-component-id", "aux-form")
                }
            }
        }

        let summary: String
        if let ov, has {
            if let cfgName = auxOverrideConfigName(ov) {
                summary = cfgName
            } else if !ov.model.isEmpty {
                summary = ov.model + (ov.provider.isEmpty ? "" : " @ " + ov.provider)
            } else if !ov.provider.isEmpty {
                summary = "provider: " + ov.provider
            } else if !ov.baseURL.isEmpty {
                summary = "custom base URL"
            } else {
                summary = "API key override"
            }
        } else {
            summary = "Main model"
        }

        return Group {
            SettingRow {
            Text(task.displayName)
            Small("\(task.detail). Currently: \(summary).")
        } control: {
            Div(class: "aux-right") {
                ArcButton(has ? "Edit" : "Configure", id: "aux-edit-\(task.key)", class: "ghost-btn")
                if has {
                    ArcButton("Reset", id: "aux-reset-\(task.key)", class: "ghost-btn")
                }
            }
            .attribute("data-component-id", "aux-edit")
            .attribute("data-event", "click")
        }
            .attribute("title", task.detail)
        }
    }

    // MARK: - settings · remaining sections

    private func settingsAssistanceSection() -> some WebUI.View {
        Section(id: "assistance", class: "set-section") {
            Heading("Assistance & approvals", level: .h2)
            DetailCard {
                SettingRow {
                    Text("Smart approval")
                    Small {
                        Text("Flagged commands are assessed by the ")
                        InlineCode("approval")
                        Text(" auxiliary model (reference smart mode): low risk auto-approves, high risk is denied, uncertainty still prompts. Off = classic prompt for every flagged command. ")
                        InlineCode("approvals: off")
                        Text(" in ~/.arc/config.json always wins.")
                    }
                } control: {
                    ArcSwitch(id: "set-smart-approval", on: settings.smartApproval,
                              component: "set-smart-approval", event: "change")
                }
                SettingRow {
                    Text("Smart pick-a-path")
                    Small {
                        Text("When a pick-a-path question times out (120 s), the ")
                        InlineCode("clarify")
                        Text(" auxiliary model chooses the best offered answer instead of the agent's unguided judgement.")
                    }
                } control: {
                    ArcSwitch(id: "set-smart-pickapath", on: settings.smartPickAPath,
                              component: "set-smart-pickapath", event: "change")
                }
            }
        }
    }

    private func settingsToolPluginsSection() -> some WebUI.View {
        Section(id: "tool-plugins", class: "set-section") {
            Heading("Tool plugins", level: .h2)
            DetailCard {
                Div(class: "set-row set-row-stack") {
                    Div(class: "set-label") {
                        Text("Integrate tools")
                        Small {
                            Text("Tools written as Python scripts or Swift executables, discovered from ")
                            InlineCode("~/.arc/plugins/")
                            Text(" (arc plugin parity). Enablement is stored in the ")
                            InlineCode("plugins.enabled")
                            Text(" allow-list of ")
                            InlineCode("~/.arc/config.json")
                            Text(".")
                        }
                    }
                }
                pluginSettingsHTML()
            }
        }
    }

    private func settingsMCPSection() -> some WebUI.View {
        Section(id: "mcp-servers", class: "set-section") {
            Heading("MCP servers", level: .h2)
            DetailCard {
                Div(class: "set-row set-row-stack") {
                    Div(class: "set-label") {
                        Text("External tool servers")
                        Small {
                            Text("Child processes speaking the Model Context Protocol over stdio. The agent reaches every one of their tools through the single ")
                            InlineCode("mcp_tool")
                            Text(" bridge; this panel owns the ")
                            InlineCode("mcp_servers")
                            Text(" block of ")
                            InlineCode("~/.arc/config.json")
                            Text(".")
                        }
                    }
                }
                mcpSettingsHTML()
            }
        }
    }

    private func settingsSidebarPluginsSection() -> some WebUI.View {
        Section(id: "sidebar-plugins", class: "set-section") {
            Heading("Sidebar plugins", level: .h2)
            DetailCard {
                Div(class: "set-row set-row-stack") {
                    Div(class: "set-label") {
                        Text("Third-party sidebar tabs")
                        Small {
                            Text("Tab packages added to the arc-agent build (see ")
                            InlineCode("docs/sidebar-tab-plugins.md")
                            Text("). Each tab appears in the rail and renders through the ")
                            InlineCode("SidebarTab")
                            Text(" protocol. Hide/show any plugin tab; reordering happens in the Sidebar tabs chips above.")
                        }
                    }
                }
                sidebarPluginsSettingsHTML()
            }
        }
    }

    private func settingsAboutSection() -> some WebUI.View {
        Section(id: "about", class: "set-section") {
            Heading("About", level: .h2)
            DetailCard {
                AkvRow(key: "Version",
                       value: "\(ArcAgentCore.version) (webui \(WebUIVersion.version))")
                // `.akv-v nowrap` carries a hover title: AkvRow does not expose the
                // span's own attributes, so this row is built directly.
                Div(class: "akv") {
                    Span(class: "akv-k") { Text("Workspace") }
                    Span(class: "akv-v nowrap") {
                        Text("\(workspaceName(for: activeSessionID)) — \(workspacePath(for: activeSessionID))")
                    }
                    .attribute("title", workspacePath(for: activeSessionID))
                }
                AkvRow(key: "Sessions", value: "\(sessions.count)")
                AkvRow(key: "Skills", value: "\(skills.count)")
                AkvRow(key: "Tools", value: "\(registry.allTools.count)")
                AkvRow(key: "Profiles", value: "\(profiles.count)")
            }
        }
    }
}

extension AppState {
    // MARK: Kanban

    func kanbanPanel() -> String {
        let newBtn = btn("kb-addcol", "kb-addcol", "plus-btn", addingColumn ? WebUIIcon(.x, size: .small).markup.html : WebUIIcon(.plus, size: .small).markup.html, " title=\"" + (addingColumn ? "Cancel" : "Add column") + "\"")
        let head = """
        <div class="panel-head">
          <span class="panel-title">Kanban</span>
          <div class="panel-actions">\(newBtn)</div>
        </div>
        """
        var rows: [String] = []
        for col in settings.kanbanColumns {
            let cid = enc(col.id)
            let count = settings.kanbanCards.filter { $0.columnID == col.id }.count
            let confirm = confirmColumn == col.id ? " Confirm?" : WebUIIcon(.x, size: .small).markup.html
            let delCls = confirmColumn == col.id ? "sess-confirm" : "icon-mini danger"
            rows.append("""
            <div class="list-row">
              <div class="kb-pcol" style="flex:1">
                <span class="cat-dot" style="background:\(col.color)"></span>
                <span class="lr-name">\(esc(col.name))</span>
                <span class="lr-sub">\(count) card\(count == 1 ? "" : "s")</span>
              </div>
              <div class="row-actions">\(btn("kb-pdel-\(cid)", "", delCls, confirm, " title=\"Delete column\""))</div>
            </div>
            """)
        }
        if rows.isEmpty {
            rows.append("<div class=\"empty-hint\">No columns — press + to add one.</div>")
        }
        let addForm: String
        if addingColumn {
            let swatches = AppState.palette.enumerated().map { j, c in
                let sel = j == 0 ? " sel" : ""
                return "<button type=\"button\" class=\"cat-swatch\(sel)\" data-color=\"\(c)\" style=\"background:\(c)\"></button>"
            }.joined()
            addForm = """
            <form id="kb-addcol-form" data-component-id="kb-addcol-form" class="cat-add-form">
              <input id="kb-addcol-name" name="kb-addcol-name" data-component-id="kb-addcol-name" type="text" placeholder="Column name" autofocus>
              <input type="hidden" name="kb-addcol-color" id="kb-addcol-color" class="color-value" value="\(AppState.palette[0])">
              <div class="cat-swatches">\(swatches)</div>
              <div class="cat-add-actions">
                <button type="submit" class="primary-btn">Add</button>
                \(btn("kb-addcol-cancel", "", "ghost-btn", "Cancel"))
              </div>
            </form>
            """
        } else {
            addForm = ""
        }
        return """
        \(head)
        <div class="panel-body" data-component-id="kanban" data-event="click">
          \(addForm)
          \(rows.joined())
        </div>
        """
    }

    /// Board: one scrollable row of columns with their cards (arc-style).
    func kanbanMain() -> String {
        guard !settings.kanbanColumns.isEmpty else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.columns, size: .extraLarge).markup.html)</div><div>No columns yet — add one in the panel.</div></div>
            </div>
            """
        }
        let cols = settings.kanbanColumns.map { kanbanColumnHTML($0) }.joined()
        return """
        <div class="kanban-main main-view" style="padding:0">
          <div class="kanban-board" data-component-id="kanban" data-event="click">\(cols)</div>
        </div>
        """
    }

    func kanbanColumnHTML(_ col: KBColumn) -> String {
        let cid = enc(col.id)
        let cards = settings.kanbanCards.filter { $0.columnID == col.id }
        var cardHTML = cards.map { kanbanCardHTML($0) }.joined()
        if cardHTML.isEmpty { cardHTML = "<div class=\"kb-empty\">No cards</div>" }
        let add: String
        if addingCardColumnID == col.id {
            let addErr = kanbanAddError
            add = """
            <form id="kb-addcard-form" data-component-id="kb-addcard-form" class="kb-addcard-form">
              <input id="kb-addcard-name" name="kb-addcard-name" data-component-id="kb-addcard-name" type="text" placeholder="Card title" class="text-input\(addErr != nil ? " input-invalid" : "")" aria-invalid="\(addErr != nil ? "true" : "false")"\(addErr != nil ? " aria-describedby=\"kb-addcard-err\"" : "") data-focus-after-patch>
              \(addErr.map { "<span id=\"kb-addcard-err\" class=\"inline-err\">\(esc($0))</span>" } ?? "")
              <input type="hidden" name="kb-addcard-col" value="\(col.id)">
              <div class="cat-add-actions" style="justify-content:flex-end">
                <button type="submit" class="primary-btn">Add</button>
                \(btn("kb-addcard-cancel", "", "ghost-btn", "Cancel"))
              </div>
            </form>
            """
        } else {
            add = btn("kb-addcard-\(cid)", "", "kb-addcard", "+ Add card")
        }
        return """
        <div class="kb-col">
          <div class="kb-col-head" style="--colc:\(col.color)">
            <span class="kb-col-name">\(esc(col.name))</span>
            <span class="kb-col-count">\(cards.count)</span>
            <div class="kb-col-actions">
              \(btn("kb-rencol-\(cid)", "", "icon-mini", WebUIIcon(.edit, size: .small).markup.html, " title=\"Rename column\" data-colid=\"\(col.id)\""))
              \(btn("kb-bdel-\(cid)", "", confirmColumn == col.id ? "sess-confirm" : "icon-mini danger", confirmColumn == col.id ? "Confirm?" : WebUIIcon(.x, size: .small).markup.html, " title=\"Delete column\""))
            </div>
          </div>
          <div class="kb-cards">\(cardHTML)</div>
          \(add)
        </div>
        """
    }

    func kanbanCardHTML(_ card: KBCard) -> String {
        let encc = enc(card.id)
        let idx = settings.kanbanColumns.firstIndex { $0.id == card.columnID } ?? 0
        let left = idx > 0 ? btn("kb-movel-\(encc)", "", "icon-mini", WebUIIcon(.chevronLeft, size: .small).markup.html, " title=\"Move left\"") : ""
        let right = idx < settings.kanbanColumns.count - 1 ? btn("kb-mover-\(encc)", "", "icon-mini", WebUIIcon(.chevronRight, size: .small).markup.html, " title=\"Move right\"") : ""
        // Two-step delete, matching the column header: the first click arms the
        // card and the button becomes "Confirm?" (a single click used to bin it).
        let armed = confirmCard == card.id
        let delCls = armed ? "sess-confirm" : "icon-mini danger"
        let delLabel = armed ? "Confirm?" : WebUIIcon(.x, size: .small).markup.html
        return """
        <div class="kb-card">
          <div class="kb-card-title" data-cardid="\(card.id)">\(esc(trunc(card.title, 70)))</div>
          <div class="kb-card-actions">
            \(btn("kb-edit-\(encc)", "", "icon-mini", WebUIIcon(.edit, size: .small).markup.html, " title=\"Edit title\" data-cardid=\"\(card.id)\""))
            \(left)\(right)
            \(btn("kb-del-\(encc)", "", delCls, delLabel, " title=\"Delete card\""))
          </div>
        </div>
        """
    }

    // MARK: Memory

    func memoryPanel() -> String {
        let head = """
        <div class="panel-head">
          <span class="panel-title">Personal Memory</span>
        </div>
        """
        let items: [(key: String, title: String, sub: String, glyph: String)] = [
            ("memory", "My Notes", "MEMORY.md", WebUIIcon(.fileText, size: .large).markup.html),
            ("user", "User Profile", "USER.md", WebUIIcon(.user, size: .large).markup.html),
            ("soul", "Agent Soul", "SOUL.md", WebUIIcon(.star, size: .large).markup.html),
            ("context", "Project Context", "AGENTS.md", WebUIIcon(.folder, size: .large).markup.html),
        ]
        let boxes = items.map { it in
            let active = memoryDoc == it.key ? " active" : ""
            return """
            <button type="button" id="mem-open-\(it.key)" class="mem-box\(active)">
              <span class="mem-glyph">\(it.glyph)</span>
              <span class="mem-txt"><span class="mem-title">\(it.title)</span><span class="mem-sub">\(it.sub)</span></span>
              <span class="mem-arrow">›</span>
            </button>
            """
        }.joined()
        return head + "<div class=\"panel-body\" data-component-id=\"memory\" data-event=\"click\">\(boxes)</div>"
    }

    func memoryMain() -> String {
        guard let doc = memoryDoc else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.database, size: .extraLarge).markup.html)</div><div>Select a document from the panel.</div></div>
            </div>
            """
        }
        if doc == "context" {
            let rootPath = workspaceContextURL()?.path ?? panelWorkspacePath()
            let title = "Project Context"
            let sub = rootPath
            var body: String
            if let url = workspaceContextURL(), let s = try? String(contentsOf: url, encoding: .utf8) {
                body = mdBox(s)
            } else {
                body = """
                <div class="empty-hint" style="font-size:1em;padding:18px 6px">
                  No AGENTS.md file was found in this workspace (<code>\(esc(panelWorkspacePath()))</code>).<br><br>
                  Project context is read automatically when an AGENTS.md is present.
                </div>
                """
            }
            return """
            <div class="main-view"><div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
              <div class="detail-card">
                <div class="mem-head"><div><h1 class="detail-title" style="margin:0">\(title)</h1><div class="detail-sub">\(esc(sub))</div></div></div>
                <div class="detail-body" style="margin-top:14px">\(body)</div>
              </div>
            </div></div>
            """
        }
        let meta = memoryMeta(doc)
        let title = meta.title, sub = meta.file
        if memoryEdit {
            return """
            <div class="main-view"><div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
              <form id="mem-save-form" data-component-id="mem-save-form" class="detail-card">
                <h1 class="detail-title" style="margin:0">Edit \(esc(sub))</h1>
                <div class="detail-sub">\(esc(meta.note))</div>
                <input type="hidden" name="mem-key" value="\(doc)">
                <textarea id="mem-content" name="mem-content" data-component-id="mem-content" class="mem-textarea" spellcheck="false">\(esc(memoryContent))</textarea>
                <div class="row-actions-main">
                  <button type="submit" class="primary-btn">Save changes</button>
                  \(btn("mem-cancel", "", "ghost-btn", "Cancel"))
                </div>
              </form>
            </div></div>
            """
        }
        let contentHTML = memoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "<div class=\"empty-hint\">\(esc(sub)) is empty. Press " + WebUIIcon(.edit, size: .small).markup.html + " to start writing.</div>"
            : mdBox(memoryContent)
        return """
        <div class="main-view"><div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
          <div class="detail-card">
            <div class="mem-head">
              <div><h1 class="detail-title" style="margin:0">\(title)</h1><div class="detail-sub">\(esc(sub)) — \(esc(meta.note))</div></div>
              \(btn("mem-edit", "mem-edit", "icon-mini", WebUIIcon(.edit, size: .small).markup.html, " title=\"Edit \(esc(sub))\""))
            </div>
            <div class="detail-body" style="margin-top:14px">\(contentHTML)</div>
          </div>
        </div></div>
        """
    }

    func memoryMeta(_ key: String) -> (title: String, file: String, note: String) {
        switch key {
        case "user": return ("User Profile", "USER.md", "persistent facts about the user")
        case "soul": return ("Agent Soul", "SOUL.md", "agent identity and disposition")
        case "context": return ("Project Context", "AGENTS.md", "workspace project context")
        default: return ("My Notes", "MEMORY.md", "persistent notes")
        }
    }

    // MARK: Logs

    func logsPanel() -> String {
        let lines = LogCollector.shared.snapshot()
        let info = lines.filter { $0.level == .info }.count
        let warn = lines.filter { $0.level == .warning }.count
        let err = lines.filter { $0.level == .error || $0.level == .critical }.count
        let head = """
        <div class="panel-head">
          <span class="panel-title">Logs</span>
          \(btn("log-clear", "log-clear", "icon-mini", WebUIIcon(.trash, size: .small).markup.html, " title=\"Clear logs\""))
        </div>
        """
        let chips = ["all", "info", "warn", "error"].map { lvl -> String in
            let label = lvl == "all" ? "All" : (lvl == "info" ? "Info" : (lvl == "warn" ? "Warn" : "Error"))
            let active = logFilter == lvl ? " active" : ""
            return "<button type=\"button\" id=\"log-filter-\(lvl)\" class=\"chip-btn\(active)\" aria-pressed=\"\(logFilter == lvl)\">\(label)</button>"
        }.joined()
        return """
        \(head)
        <div class="panel-body">
          <div class="log-stats">
            <span class="log-stat" title="Info lines"><span class="dot dot-info"></span>\(info) info</span>
            <span class="log-stat" title="Warning lines"><span class="dot dot-warn"></span>\(warn) warn</span>
            <span class="log-stat" title="Error lines"><span class="dot dot-err"></span>\(err) error</span>
          </div>
          <div class="log-chips" data-component-id="log-filter" data-event="click">\(chips)</div>
          <div class="log-panel-note">In-app log stream. Captured lines from this process appear here instead of the terminal.</div>
        </div>
        """
    }

    /// Severity filter for the log box: "all" | "info" | "warn" | "error".
    func logMatches(_ line: LogLine) -> Bool {
        switch logFilter {
        case "info": return line.level == .info
        case "warn": return line.level == .warning
        case "error": return line.level == .error || line.level == .critical
        default: return true
        }
    }

    func logLevelClass(_ level: Logger.Level) -> String {
        switch level {
        case .error, .critical: return "lvl-err"
        case .warning: return "lvl-warn"
        case .info: return "lvl-info"
        default: return "lvl-debug"
        }
    }

    func logLineHTML(_ line: LogLine) -> String {
        let t = logTime(line.time)
        let level = line.level.rawValue
        return "<div class=\"log-line \(logLevelClass(line.level))\"><span class=\"log-time\">\(t)</span><span class=\"log-lvl\">\(level)</span><span class=\"log-msg\">\(esc(line.text))</span></div>"
    }

    /// The filtered, newest-last log body, capped for a responsive live box.
    func logLinesHTML(max: Int = 500) -> String {
        let all = LogCollector.shared.snapshot().filter { logMatches($0) }
        let shown = all.suffix(max)
        let rows = shown.map { logLineHTML($0) }.joined()
        return rows.isEmpty
            ? "<div class=\"empty-hint\">No log lines yet.</div>"
            : rows
    }

    func logsMain() -> String {
        let total = LogCollector.shared.count
        return """
        <div class="logs-view">
          <div class="logs-box">
            <div class="logs-head">
              <span class="logs-title">Live log stream</span>
              <span class="logs-meta">\(total) lines in buffer</span>
            </div>
            <div id="log-lines" class="logs-lines">\(logLinesHTML())</div>
          </div>
        </div>
        """
    }

    /// Live fragment: only the log box, so the view updates in place while the
    /// server streams new lines.
    func liveLogFragments() async -> [FragmentUpdate] {
        [FragmentUpdate(id: "log-lines", html: "<div id=\"log-lines\" class=\"logs-lines\">\(logLinesHTML())</div>")]
    }

        // MARK: Workspace panel (right side)

    /// The fixed, vertically-centered rounded toggle on the far right edge.
    /// Rendered in BOTH states — while closed it is the open handle, while
    /// open it becomes the collapse tab (chevron flips, symmetric affordance).
    /// The wrapper must keep its `data-component-id="workspace"` anchor across
    /// both states: a re-render that drops it makes the engine drop routing
    /// for the region (`[WebUIEngine] Patch for #ws-dock dropped routing
    /// anchor data-component-id=workspace`), which is exactly how closes
    /// used to dead-end.
    func workspaceDockHTML() -> String {
        let open = workspaceOpen
        let icon = open ? WebUIIcon(.chevronRight, size: .medium).markup.html
                        : WebUIIcon(.chevronLeft, size: .medium).markup.html
        let title = open ? "Collapse workspace" : "Open workspace"
        // UX-30: while the panel is open, exactly ONE close control is visible
        // — the header ✕. The dock's collapse tab used to float at the panel's
        // mid-right edge over the file rows (two competing close affordances).
        // When open the tab is hidden, but the anchored wrapper keeps its
        // `data-component-id` — the engine's routing anchor is stable in both
        // states (UX-03); when closed the dock returns as the open handle.
        let cls = open ? "ws-dock-btn ws-dock-open" : "ws-dock-btn"
        let attrHidden = open ? " hidden" : ""
        return """
        <div id="ws-dock" data-component-id="workspace" data-event="click">
          <button type="button" id="w-dock" class="\(cls)"\(attrHidden) title="\(title)">\(icon)</button>
        </div>
        """
    }

    /// The right-hand workspace panel (same width as the left panel).
    func workspacePanelHTML() -> String {
        let hidden = workspaceOpen ? "" : " hidden"
        // ws-enter plays the slide-in animation only on the open transition
        // (set right after toggling open); the flag is consumed/reset here so
        // background re-renders of an already-open panel don't re-animate.
        let anim = wsEnterAnim ? " ws-enter" : ""
        wsEnterAnim = false
        let wsMenu = """
        <div class="ws-menu-wrap" data-component-id="workspace" data-event="click">
          <button type="button" id="w-menu" class="icon-mini" title="Workspace options">⋮</button>
          <div class="chat-menu ws-menu" id="ws-menu">
            <button type="button" id="w-hidden" class="\(showHiddenFiles ? "menu-sel" : "")">\(showHiddenFiles ? "<span class=\"chk\">" + WebUIIcon(.checkSquare, size: .small).markup.html + "</span>" : "<span class=\"chk\">" + WebUIIcon(.square, size: .small).markup.html + "</span>") Show hidden files</button>
          </div>
        </div>
        """
        var create: String = ""
        if wsNewMode != "" {
            let placeholder = wsNewMode == "file" ? "file name (e.g. notes.txt)" : "folder name"
            let note = wsNewMode == "file" ? "New file" : "New folder"
            create = """
            <form id="ws-new-form" data-component-id="ws-new-form" class="cat-add-form">
              <div class="detail-sub" style="margin-bottom:6px">\(note)</div>
              <input id="ws-new-name" name="ws-new-name" data-component-id="ws-new-name" type="text" placeholder="\(placeholder)" autofocus>
              <input type="hidden" name="ws-new-kind" value="\(wsNewMode)">
              <div class="cat-add-actions" style="margin-top:8px">
                <button type="submit" class="primary-btn">Create</button>
                \(btn("ws-new-cancel", "", "ghost-btn", "Cancel"))
              </div>
            </form>
            """
        }
        return """
        <div id="ws-panel" class="ws-panel\(hidden)\(anim)">
          <div class="panel-head ws-head">
            <span class="panel-title">Workspace</span>
            <div class="ws-tools" data-component-id="workspace" data-event="click">
              \(btn("w-new", "", "icon-mini", WebUIIcon(.plus, size: .small).markup.html, " title=\"New file\""))
              \(btn("w-newfolder", "", "icon-mini", WebUIIcon(.folder, size: .small).markup.html, " title=\"New folder\""))
              \(btn("w-upload", "", "icon-mini", WebUIIcon(.upload, size: .small).markup.html, " title=\"Upload files or drop them here\""))
              \(wsMenu)
              \(btn("w-close", "", "icon-mini", WebUIIcon(.x, size: .small).markup.html, " title=\"Close workspace\""))
            </div>
          </div>
          \(create)
          <div class="ws-body" id="ws-tree" data-component-id="workspace" data-event="click" data-root="\(esc(panelWorkspacePath()))">
            \(workspaceBodyHTML())
          </div>
        </div>
        """
    }

    /// The workspace panel body: a file preview pane when a file is open,
    /// otherwise the breadcrumb + file tree (Hermes parity: the right panel
    /// shows both the tree and a preview of the selected file).
    func workspaceBodyHTML() -> String {
        // Never scan the directory for a hidden panel: `workspacePanelHTML`
        // is rendered on every shell build, and the tree walk is synchronous
        // disk I/O — doing it when the panel isn't visible caused the lag
        // spikes. The scan happens on first render after the panel opens.
        guard workspaceOpen else { return "" }
        if let path = previewPath {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let isMarkdown = path.lowercased().hasSuffix(".md")
            // UX-12: wrap text previews (pre-wrap) and render markdown for
            // .md files — the dock is for glancing, raw markdown syntax is
            // not readable. Code keeps `white-space: pre` (via the monospace
            // pre-wrap body, which still wraps).
            let body: String
            if let content = previewContent {
                if isMarkdown {
                    body = "<div class=\"ws-preview-body\">\(renderMarkdown(content))</div>"
                } else {
                    body = "<pre class=\"ws-preview-body\">\(esc(content))</pre>"
                }
            } else {
                // UX-12: an unreadable preview keeps its reason on screen —
                // `previewNote` names the cause (binary, too large, not utf-8,
                // read failure); an empty <pre> told the reader nothing.
                body = "<div class=\"empty-hint\">\(esc(previewNote ?? "No preview."))</div>"
            }
            return """
            <div class="ws-preview">
              <div class="ws-preview-head">
                <button type="button" id="w-preview-back" class="icon-mini" title="Back to files">\(WebUIIcon(.chevronLeft, size: .small).markup.html)</button>
                <span class="ws-preview-name" title="\(esc(path))\(isMarkdown ? " (markdown)" : "")">\(esc(name))</span>
                <button type="button" id="ws-preview-copy" class="icon-mini" title="Copy content">\(WebUIIcon(.copy, size: .small).markup.html)</button>
              </div>
              <div class="ws-preview-scroll">\(body)</div>
            </div>
            """
        }
        return """
        <div class="ws-path" title="\(esc(panelWorkspacePath()))">\(esc(panelWorkspacePath()))</div>
        \(workspaceTreeHTML())
        """
    }

    func workspaceTreeHTML() -> String {
        // Render-path cache: repeated shell re-renders of an OPEN panel reuse
        // the last listing instead of rescanning the directory. Keyed by
        // (path, showHidden, expanded set), so switching the workspace,
        // toggling hidden files, or expanding/collapsing a folder all change
        // the key and force a rescan; content mutations clear the cache.
        let path = panelWorkspacePath()
        let key = wsTreeCacheKey(path: path)
        if let k = workspaceTreeCacheKey, k == key, let html = workspaceTreeCacheHTML {
            return html
        }
        let html = Self.renderWorkspaceTree(
            root: URL(fileURLWithPath: path),
            showHidden: showHiddenFiles,
            expanded: expandedPaths
        )
        workspaceTreeCacheKey = key
        workspaceTreeCacheHTML = html
        return html
    }

    /// Fresh (non-cached) listing, used by the live workspace scanner so it
    /// detects real filesystem changes rather than serving the render cache.
    func freshWorkspaceTreeHTML() -> String {
        Self.renderWorkspaceTree(
            root: URL(fileURLWithPath: panelWorkspacePath()),
            showHidden: showHiddenFiles,
            expanded: expandedPaths
        )
    }

    /// Clear the render-path tree cache (called on open + on mutations).
    func clearWorkspaceTreeCache() {
        workspaceTreeCacheKey = nil
        workspaceTreeCacheHTML = nil
    }

    private func wsTreeCacheKey(path: String) -> String {
        "\(path)|\(showHiddenFiles)|\(expandedPaths.sorted().joined(separator: "\u{1F}"))"
    }

    /// The workspace file tree, bounded (depth ≤ 8, ≤ 600 entries). Reads
    /// `.isDirectory` once per entry and sorts by the cached bool — the old
    /// code re-stat'ed every entry on every sort comparison (O(n·log n) stats),
    /// the dominant cost of an otherwise small listing.
    static func renderWorkspaceTree(root: URL, showHidden: Bool, expanded: Set<String>) -> String {
        var lines: [String] = []
        var count = 0
        func rel(_ prefix: String, _ name: String) -> String { prefix.isEmpty ? name : prefix + "/" + name }
        func walk(_ dir: URL, prefix: String, depth: Int) {
            guard depth <= 8, count < 600 else { return }
            guard let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
            var entries = all
            if !showHidden { entries = entries.filter { !$0.lastPathComponent.hasPrefix(".") } }
            let tagged = entries.compactMap { u -> (URL, Bool)? in
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return (u, isDir)
            }
            let sorted = tagged.sorted { a, b in
                if a.1 != b.1 { return a.1 }
                return a.0.lastPathComponent.localizedCaseInsensitiveCompare(b.0.lastPathComponent) == .orderedAscending
            }
            let pad = 12 + depth * 15
            for (entry, isDir) in sorted {
                let name = entry.lastPathComponent
                let rp = rel(prefix, name)
                count += 1
                if count > 600 { return }
                let encPath = enc(rp)
                if isDir {
                    let isExp = expanded.contains(rp)
                    let caret = isExp ? WebUIIcon(.chevronDown, size: .small).markup.html : WebUIIcon(.chevronRight, size: .small).markup.html
                    lines.append("<button type=\"button\" id=\"w-toggle-\(encPath)\" class=\"ws-row\" style=\"padding-left:\(pad)px\" title=\"\(esc(rp))\"><span class=\"ws-caret\">\(caret)</span><span class=\"ws-ic\">\(WebUIIcon(.folder, size: .small).markup.html)</span><span class=\"ws-name\">\(esc(name))</span></button>")
                    if isExp { walk(entry, prefix: rp, depth: depth + 1) }
                } else {
                    lines.append("<button type=\"button\" id=\"w-file-\(encPath)\" class=\"ws-row\" style=\"padding-left:\(pad + 4)px\" title=\"\(esc(rp))\"><span class=\"ws-ic\">\(WebUIIcon(.file, size: .small).markup.html)</span><span class=\"ws-name\">\(esc(name))</span></button>")
                }
            }
        }
        walk(root, prefix: "", depth: 0)
        if lines.isEmpty { lines.append("<div class=\"empty-hint\">This workspace is empty.</div>") }
        return lines.joined()
    }

    func wsFileIcon(_ name: String) -> String {
        return WebUIIcon(.file, size: .small).markup.html
    }
}

// MARK: - Memory / workspace file helpers

extension AppState {
    /// The folder the right-hand workspace panel shows: the active chat's
    /// workspace, or the global default workspace when no chat is open.
    func panelWorkspacePath() -> String {
        workspacePath(for: activeSessionID)
    }

    /// URL of the workspace root directory shown in the right panel.
    func workspaceRootURL() -> URL {
        URL(fileURLWithPath: panelWorkspacePath())
    }

    /// The editable memory file for a doc key (memory/user/soul); nil for the
    /// read-only project context.
    func memoryFileURL(_ key: String) -> URL? {
        let name: String
        switch key {
        case "user": name = "USER.md"
        case "soul": name = "SOUL.md"
        case "memory": name = "MEMORY.md"
        default: return nil
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc-agent-webui").appendingPathComponent(name)
    }

    /// AGENTS.md / AGENT.md in the workspace root, if present.
    func workspaceContextURL() -> URL? {
        for candidate in ["AGENTS.md", "AGENT.md"] {
            let u = workspaceRootURL().appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

/// Map a harness tool emoji to its colorless line-drawing equivalent.
/// Unknown or nil emoji render nothing (or a generic file glyph for a
/// non-nil unknown), so no colored emoji ever reaches the UI.
/// the icon a tool's emoji maps to. one table: the view calls it, the legacy
/// string helper calls it, so a new emoji cannot light up in one surface only.
func toolIconName(_ emoji: String?) -> IconName? {
    guard let e = emoji, !e.isEmpty else { return nil }
    switch e {
    case "📋": return .fileText
    case "🔍": return .search
    case "💬": return .messageSquare
    case "➕": return .plus
    case "🗑️", "🗑": return .trash
    case "👥": return .user
    case "📄": return .file
    case "🌐": return .globe
    case "🔄": return .refreshCw
    case "💻": return .terminal
    case "🧠": return .database
    case "✏️", "✏": return .edit
    case "🎯": return .target
    case "⏹️", "⏹": return .stopCircle
    case "📚", "📖": return .book
    case "✅": return .check
    case "🚫": return .x
    default: return .file
    }
}

/// the same table as a view, so a typed row does not carry icon markup.
func toolIcon(_ emoji: String?) -> some WebUI.View {
    Group {
        if let name = toolIconName(emoji) {
            WebUIIcon(name, size: .small)
        }
    }
}

func toolEmojiIcon(_ emoji: String?) -> String {
    guard let name = toolIconName(emoji) else { return "" }
    return WebUIIcon(name, size: .small).markup.html
}


enum WebUIVersion {
    static let version = "1.0.0"
}

// MARK: - Log timestamps

private let logTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// Wall-clock label for a log line ("08:19:04").
func logTime(_ date: Date) -> String {
    logTimeFormatter.string(from: date)
}
