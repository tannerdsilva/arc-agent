import ArcAgentCore
import ArcSidebarTabs
import ArcTheme
import Foundation
import Logging
import WebUI
import WebUIDesignSystem

// MARK: - Views (actor methods on AppState)

/// Every builder lives on `AppState` so it can read actor state directly, and
/// every one of them **renders a typed `View`** — no builder returns html text.
/// A fragment builder renders the target ELEMENT (outerHTML semantics), so its
/// root carries the fragment id the push pipeline patches by.
///
/// the two trusted-markup seams are deliberate and enumerated by
/// `NoMarkupStringsTests`: the third-party panel ABI (`SidebarTab.panelHTML()`)
/// and sanitized markdown content. arc's own chrome is typed, and that test
/// fails if a `<div>` literal comes back.
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
    /// Returns the typed page body. Every region of the chrome is a typed `View`
    /// tree, so nothing here mints trust: from here the compiler carries that
    /// type to `HTMLDocument(body:)`, and no unlabelled string can become a
    /// page. a fragment patch that needs the bytes reads `.html`.
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
                workspaceDockHTML()          // phase 7.4: typed, bridge retired
                workspacePanelHTML()         // phase 7.4: typed, bridge retired
                Div(id: "drawer-scrim", class: "drawer-scrim") {}
                    .aria(.hidden(.yes))
            }.id("app-body")
            modalRootHTML()
            toastsShell()
        }
        .id("app")
        .data("size", settings.textSize)
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
                .aria(.label("Toggle sidebar"))
                .aria(.expanded(.no))
                .data("event", "click")
            Div(class: "topbar-center") {
                Span(class: "topbar-bolt") { WebUIIcon(.zap, size: .medium) }
                Span(class: "topbar-name") { Text(topbarLabel()) }
            }
        }
        .id("topbar")
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
        .wire("toast-dismiss")
    }

    func iconbarHTML() -> some WebUI.View {
        // Registry-driven: Chat is always first, Settings is pinned in the
        // bottom slot, the rest follow the user's settings order minus the
        // tabs they hid. Built-ins and plugin tabs render alike.
        Aside {
            Div(class: "iconbar-top") {
                for id in railTabIDs() where id != "settings" {
                    if let tab = sidebarTab(id) { ErasedViews([railButton(tab, active: id == activeTabID)]) }
                }
            }
            Div(class: "iconbar-bottom") {
                if let settings = sidebarTab("settings") { railButton(settings, active: activeTabID == "settings") }
            }
        }
        .id("iconbar")
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
        .data("tip", tab.title)
        .aria(.label(tab.title))

        // only the active tab announces itself as the current page; the others
        // stay reachable but out of the tab order.
        return Group {
            if active {
                base.aria(.current(.page))
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
                Span {}.id("pending-copy").data("copy-url", marker)
            }
        }
    }

    /// The one confirmation dialog. Chat and profile deletes arm their original
    /// state fields; newer guards (workspaces) arm `pendingConfirm` — so every
    /// destructive action gets the same dialog, the same Cancel/Delete pair, a
    /// real dialog role, and (via the overlay) the same focus + Escape handling.
    func modalHTML() -> some WebUI.View {
        Group {
            if let req = activeConfirm {
                Div(id: "modal-overlay", class: "modal-overlay") {
                    Div(class: "modal-card") {
                        Heading(req.title, level: .h3)
                            .id("modal-title")
                        Paragraph(req.body)
                        Div(class: "modal-actions") {
                            ArcButton("Cancel", id: "modal-cancel", component: nil, class: "ghost-btn")
                            ArcButton("Delete", id: "modal-confirm", component: nil, class: "danger-btn")
                        }
                        .wire("modal")
                    }
                    .attribute("role", "dialog")
                    .aria(.modal(.yes))
                    .aria(.labelledby("modal-title"))
                }
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
        Group {
            if let menu = categoryMenu,
               let cat = settings.chatCategories.first(where: { $0.id == menu.categoryID }) {
                let left = max(8, min(menu.x, 1080))
                let top = max(8, min(menu.y, 760))
                let cid = enc(cat.id)
                let catColor = cat.color
                let catName = cat.name

                Div(id: "cat-menu-close", class: "ctx-backdrop") {}
                    .data("component-id", "cat-menu-close")

                Div(id: "cat-menu", class: "ctx-menu") {
                    if categoryMenuRename {
                        Form(method: nil, id: "cm-rename-form-\(cid)", class: "ctx-rename") {
                            Input(field: "cat-rename-input", type: nil, value: catName, attributes: [("autofocus", "")])
                            ArcButton("Save", id: nil, component: nil, class: "primary-btn", type: .submit)
                        }
                        .data("prevent-enter", "false")
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
                                    .data("color", c)
                                    .aria(.label(c))
                                    .attribute("style", "background:\(c)")
                            }
                        }
                    }

                    Div(class: "ctx-divider") {}

                    ArcButton("Delete", id: "cm-del-\(cid)", component: nil, class: "ctx-item ctx-danger")
                }
                .data("component-id", "cat-menu")
                .attribute("style", "left:\(left)px;top:\(top)px")
            }
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
                // is permanent — the seam crosses a module boundary whose
                // conformers are third-party, so no arc-side type can carry it.
                TrustedMarkup(plugin, from: .plugin("sidebar-tab"))
            } else {
                chatPanel()
            }
        }.id("panel")
    }

    /// Panel content for a built-in view id (dispatched through the tab
    /// protocol adapter).
    func renderPanel(for kind: ViewID) -> some WebUI.View {
        Group {
            switch kind {
            case .chat:
                chatPanel()
            case .skills:
                skillsPanel()
            case .profiles:
                profilesPanel()
            case .tools:
                toolsPanel()
            case .workspaces:
                workspacesPanel()
            case .kanban:
                kanbanPanel()
            case .memory:
                memoryPanel()
            case .insights:
                insightsPanel()
            case .settings:
                settingsPanel()
            case .logs:
                logsPanel()
            case .tasks:
                tasksPanel()
            case .todos:
                chatPanel(todos: true)
            }
        }
    }

    // MARK: Chat panel

    /// the chat list panel: header + new-chat action, filter bar, category
    /// cloud, the archived toggle, the empty-draft cleanup link and the
    /// bucketed session rows. typed as of phase 2.3 — every branch is a
    /// `Div`/`Group`, and the rows come from the already-typed `groupHTML`.
    func chatPanel(todos: Bool = false) -> some WebUI.View {
        // UX-18: one archive affordance. The text link below the filter bar
        // owns "Show/Hide archived conversations" (explicit label, chevron
        // state, and it is back in the tab order — it is the only control
        // now). The header's bare archive glyph is gone: two controls doing
        // the same thing read as noise.
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
        // arc parity: chats are bucketed into Today / Yesterday / Earlier this
        // week / Older (youngest first within each bucket); each bucket is
        // collapsible. Yesterday splits out of the 1-6 day band so a chat from
        // last night is not mislabelled "a week old" every morning.
        let buckets: [(String, String)] = [("today", "Today"), ("yesterday", "Yesterday"), ("week", "Earlier this week"), ("older", "Older")]
        var grouped: [String: [Session]] = [:]
        for s in unpinned { grouped[bucketKey(s.updatedAt), default: []].append(s) }
        let bucketRows: [(key: String, title: String, sessions: [Session])] = buckets.compactMap { key, title in
            guard let list = grouped[key], !list.isEmpty else { return nil }
            return (key, title, list)
        }
        // Tell the truth about WHY the list is empty: an unmatched filter
        // must not claim the workspace has no chats at all.
        let emptyMsg: String
        if !chatFilter.isEmpty {
            emptyMsg = "No chats match “\(chatFilter)”."
        } else if todos {
            emptyMsg = "No chats yet."
        } else if showArchived {
            emptyMsg = "No archived chats."
        } else if activeCategory != "all" && activeCategory != "unassigned" {
            emptyMsg = "No chats in this category yet."
        } else {
            emptyMsg = "No chats yet — press + to start one."
        }
        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text(todos ? "Todos" : "Chats") }
                Div(class: "panel-actions") {
                    if !todos {
                        ArcButton(id: "chat-new", component: "chat-new", class: "plus-btn") {
                            WebUIIcon(.plus, size: .medium)
                        }
                        .title("New chat")
                    }
                }
            }
            Div(class: "filter-bar") {
                Span(class: "filter-ico") { WebUIIcon(.search, size: .small) }
                // the filter value rides the attribute list because
                // `Input(value:)` omits an empty value while the pre-conversion
                // markup always spelled `value=""`.
                Input(
                    id: "chat-search-input",
                    placeholder: "Filter conversations…",
                    type: .search,
                    attributes: [
                        ("value", chatFilter),
                        ("data-component-id", "chat-search-input"),
                    ]
                )
                .aria(.label("Filter conversations"))
            }
            categoryCloudHTML()
            if !todos {
                ArcButton(id: "chat-showarch-link", component: "chat-showarch", class: "arch-link") {
                    Span(class: "arch-ico") {
                        WebUIIcon(showArchived ? .chevronDown : .chevronRight, size: .small)
                    }
                    Span { Text(showArchived ? " Hide archived conversations" : " Show archived conversations") }
                }
                .title("Toggle archived")
                if showArchived {
                    Div(class: "arch-mode-note") { Text("Showing archived conversations only.") }
                }
            }
            if !todos && !showArchived && clearableDrafts > 0 {
                ArcButton(id: "chat-clear-empty", component: "chat-clear-empty", class: "arch-link") {
                    Span(class: "arch-ico") { WebUIIcon(.trash, size: .small) }
                    Span { Text(" Clear \(clearableDrafts) empty chat\(clearableDrafts == 1 ? "" : "s")") }
                }
                .data("tip", "Delete conversations with no messages")
            }
            Div(class: "panel-body") {
                if !pinned.isEmpty {
                    groupHTML(key: "pinned", title: "Pinned", sessions: pinned, todos: todos)
                }
                for bucket in bucketRows {
                    ErasedViews([groupHTML(key: bucket.key, title: bucket.title, sessions: bucket.sessions, todos: todos)])
                }
                if pinned.isEmpty && bucketRows.isEmpty {
                    Div(class: "empty-hint") { Text(emptyMsg) }
                }
            }
            .id("sess-list-body")
            .data("scroll-key", "sessions")
            .data("component-id", "sess-list")
            .data("event", "click")
        }
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
                .aria(.pressed(activeCategory == "all" ? .yes : .no))
                ArcButton(id: "cat-unassigned", component: nil, class: "cat-chip\(unActive)", tabIndex: -1) {
                    Text("Unassigned")
                }
                .aria(.pressed(activeCategory == "unassigned" ? .yes : .no))
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
                            .title("Delete category")
                        }
                    } else {
                        ArcButton(id: "cat-\(cid)", component: nil, class: "cat-chip\(active)") {
                            Span(class: "cat-dot") {}
                                .attribute("style", "background:\(cat.color)")
                            Span { Text(cat.name) }
                        }
                        .aria(.pressed(activeCategory == cat.id ? .yes : .no))
                    }
                }
                ArcButton(id: "cat-add", component: nil, class: "cat-chip cat-add", tabIndex: -1) {
                    plusIcon
                }
                .title(addingCategory ? "Cancel" : "Add category")
            }
            .wire("cat-pick")

            if addingCategory {
                Form(action: "", method: nil, id: "cat-add-form", class: "cat-add-form") {
                    Input(field: "cat-name-input",
                          placeholder: "Category name", type: .text)
                        .data("component-id", "cat-name-input")
                        .attribute("autofocus", "")
                    Input(field: "cat-color-input", type: .hidden)
                        .class("color-value")
                        .value(AppState.palette[0])
                    Div(class: "cat-swatches") {
                        for (i, c) in AppState.palette.enumerated() {
                            ErasedViews([ArcButton(id: nil, component: nil, class: "cat-swatch\(i == 0 ? " sel" : "")") {}
                                .data("color", c)
                                .attribute("style", "background:\(c)")
                                .aria(.label(c))])
                        }
                    }
                    Div(class: "cat-add-actions") {
                        ArcButton("Add", class: "primary-btn", type: .submit)
                        ArcButton("Cancel", id: "cat-add-cancel", component: nil, class: "ghost-btn")
                    }
                }
                .data("component-id", "cat-add-form")
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
            .title(title)
            // no aria-label: the head's own `.sess-group-title` span already names
            // it, so a label would be a redundant second name — and the phase's
            // contract is that a conversion changes NO bytes.
            Div(class: "sess-group-rows") {
                for s in sessions {
                    ErasedViews([sessionRow(s, todos: todos)])
                }
            }
        }
        .data("grp", key)
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
    return Group {
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
            .title(full)
            .aria(.label(full))
            .data("full-title", full)
            .data("sid", s.id)
            // aria-current is presence-only and `.attribute` takes a value, so
            // the active shape is a second branch rather than `aria-current=""`.
            Group {
                if isActiveRow {
                    row.aria(.current(.yes))
                } else {
                    row
                }
            }
        } else {
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
                                .title("Pinned")
                        }
                        Text(title)
                    }
                    Span(class: "sess-meta") {
                        Text("\(count) msg • ")
                        Span(class: "rel-time") { Text(relTimeLabel(s.updatedAt)) }
                            .data("reltime", "\(epochMs)")
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
                                    .title(catName)
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
                        .title("Chat actions")
                        Div(class: "chat-menu") {
                            Div(class: "chat-menu-items") {
                                ArcButton("Copy conversation link", id: "sm-copy-\(encID)", class: "")
                                    .data("sid", s.id)
                                ArcButton("Rename conversation", id: "sm-rename-\(encID)", class: "")
                                    .data("sid", s.id)
                                ArcButton(pinLabel, id: "sm-pin-\(encID)", class: "")
                                    .data("sid", s.id)
                                ArcButton(arcLabel, id: "sm-arc-\(encID)", class: "")
                                    .data("sid", s.id)
                                // Category picker inside the "⋮" menu: a hover flyout
                                // submenu to the right of "Set category" (arc parity),
                                // keeping category option button ids so the existing
                                // chat-menu wire handles them unchanged.
                                ArcButton(id: "sm-catmenu-\(encID)", component: nil, class: "menu-item-head catmenu-head") {
                                    Span { Text("Move to Category") }
                                    Span(class: "menu-arrow") { WebUIIcon(.chevronRight, size: .small) }
                                }
                                ArcButton("Duplicate conversation", id: "sm-dup-\(encID)", class: "")
                                    .data("sid", s.id)
                                ArcButton("Delete conversation", id: "sm-del-\(encID)", class: "danger")
                                    .data("sid", s.id)
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
                                    .title("Back")
                                    Span(class: "cat-panel-title") { Text("Move to Category") }
                                }
                                Div(class: "cat-panel-list") {
                                    ArcButton(id: "sm-uncat-\(encID)", component: nil, class: catID == nil ? "menu-sel" : "") {
                                        Text("No Project")
                                        if catID == nil { WebUIIcon(.check, size: .small) }
                                    }
                                    for c in settings.chatCategories {
                                        ErasedViews([ArcButton(id: "sm-cat-\(enc(c.id)).\(encID)", component: nil, class: c.id == catID ? "menu-sel" : "") {
                                            Span(class: "cat-dot") {}
                                                .attribute("style", "background:\(c.color)")
                                            Span {
                                                Text(c.name)
                                                if c.id == catID { WebUIIcon(.check, size: .small) }
                                            }
                                        }
                                        .data("sid", s.id)])
                                    }
                                }
                            }
                            .id("catpanel-\(encID)")
                            .flag(.hidden)
                        }
                        .wire("chat-menu")
                        .id("menu-\(encID)")
                    }
                }
            }
            .attribute("tabindex", "\(rowTab)")
            .attribute("role", "group")
            .title(full)
            .aria(.label(full))
            .data("full-title", full)
            .data("sid", s.id)
            Group {
                if isActiveRow {
                    row.aria(.current(.yes))
                } else {
                    row
                }
            }
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
                    .title("Add skill")
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
                    ErasedViews([Div(class: "skill-group") {
                        ArcButton(id: "skcat-\(enc(cat))", class: "skill-cat-head", type: .button) {
                            Span(class: "skill-cat-caret") { WebUIIcon(.chevronDown, size: .small) }
                            Span(class: "skill-cat-title") { Text(cat) }
                            Span(class: "skill-cat-count") { Text("(\(list.count))") }
                        }
                        .title("Toggle section")
                        Div(class: "skill-cat-rows") {
                            for skill in list {
                                ErasedViews([skillRowHTML(skill)])
                            }
                        }
                        .data("component-id", "skill-list")
                    }
                    .data("grp-skill", cat)])
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
                .title(name)
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
                    .title("Add profile")
                }
            }
            Div(class: "panel-body") {
                if profiles.isEmpty {
                    Div(class: "empty-hint") { Text("No profiles — press + to create one.") }
                } else {
                    for p in profiles {
                        let encName = enc(p.name)
                        ErasedViews([Div(class: "list-row\(p.name == selectedProfile ? " active" : "")") {
                            ArcButton(id: "pr-open-\(encName)", class: "sess-open sess-open-flush", type: .button) {
                                Span(class: "lr-name") { Text(p.title.isEmpty ? p.name : p.title) }
                                Span(class: "lr-sub") { Text(p.model ?? "") }
                            }
                        }
                        .data("component-id", "profile-list")])
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
                                    .title(disabled ? "Toolset disabled" : "Toolset enabled")
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
                                ErasedViews([Div(class: "list-row\(active ? " active" : "")") {
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
                                .data("component-id", "tool-list")
                                .aria([.current(.yes)], when: active)])
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
                    .title("New workspace")
                }
            }
            Div(class: "panel-body") {
                for entry in settings.workspaces {
                    let encWS = enc(entry.name)
                    let isMain = entry.name == "main"
                    ErasedViews([Div(class: "list-row\(entry.name == settings.activeWorkspace ? " active" : "")") {
                        ArcButton(id: "ws-open-\(encWS)", class: "sess-open sess-open-flush", type: .button) {
                            Span(class: "lr-name") { Text(entry.name) }
                            Span(class: "lr-sub lr-sub-path") {
                                Text(entry.path == WorkspaceEntry.defaultPath(for: "main")
                                     ? "home folder (default)"
                                     : trunc(entry.path, 58))
                            }
                            .title(entry.path)
                        }
                        Div(class: "row-actions") {
                            // `main` has no delete control: the default workspace
                            // cannot be removed, and the absence is the contract.
                            if !isMain {
                                ArcButton(id: "ws-del-\(encWS)", class: "icon-mini danger", type: .button) {
                                    WebUIIcon(.x, size: .small)
                                }
                                .title("Delete")
                            }
                        }
                    }
                    .data("component-id", "workspace-list")])
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
            TrustedMarkup(inner, from: .plugin("tab-main"))
        }
    }

    /// Main content for a built-in view id (dispatched through the tab
    /// protocol adapter).
    func renderMain(for kind: ViewID) -> String {
        switch kind {
        case .chat:
            return render(chatMain())
        case .skills:
            return render(skillsMain())
        case .profiles:
            return render(profilesMain())
        case .tools:
            return render(toolsMain())
        case .workspaces:
            return render(workspacesMain())
        case .kanban:
            return render(kanbanMain())
        case .memory:
            return render(memoryMain())
        case .insights:
            return render(insightsMain())
        case .settings:
            return render(settingsMain())
        case .logs:
            return render(logsMain())
        case .tasks:
            return render(tasksMain())
        case .todos:
            return render(todosPanelHTML())
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
                .data("tip", "Regenerate last reply")
                .aria(.label("Regenerate last reply"))
                .title("Regenerate last reply")
                ArcButton(id: "chat-del", component: "chat-del", class: delClass) {
                    if pendingDelete {
                        Text("Confirm?")
                    } else {
                        WebUIIcon(.trash, size: .small)
                    }
                }
                .data("tip", "Delete chat")
                .aria(.label("Delete chat"))
            }
            .attribute("style", "margin:0")
            .wire("regen")
        }
        .id("chat-header")
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
            .id("chat-inner")
        }
        .id("chat-scroll")
        .data("scroll-key", "chat")
        .data("session", activeSessionID ?? "")
        // `data-follow` is presence-only, so the scrolling shape is a branch
        // rather than an empty attribute.
        let followedScroller = Group {
            if follow {
                scroller.data("follow", "bottom")
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
            .title("Jump to latest")
            .aria(.label("Jump to latest"))
            .flag(.hidden)
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
                .data("event", "click")
                .data("tip", "Conversation outline")
                .aria(.label("Toggle conversation outline"))
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
                        .data("event", "click")
                        .title("Close outline")
                        .aria(.label("Close outline"))
                    }
                    Div(class: "outline-entries") {}
                        .id("outline-entries")
                }
                .id("outline-panel")
                .attribute("role", "navigation")
                .aria(.label("Conversation outline"))
                .flag(.hidden)
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
            blocks
            if blocks.isEmpty {
                Div(class: "blank") {
                    Div(class: "blank-ico") { WebUIIcon(.messageSquare, size: .extraLarge) }
                    Div(class: "blank-title") { Text("This chat is empty") }
                    Div(class: "blank-sub") { Text("Say hello below — or type / for the command list.") }
                    ArcButton(id: nil, component: nil, class: "ghost-btn blank-cta") {
                        WebUIIcon(.edit, size: .small)
                        Span { Text("Start typing") }
                    }
                    .data("focus-composer", "")
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
                        .title("Tokens per second")
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
                Div(class: "msg-body") { TrustedMarkup(mdBox(content), from: .markdown) }
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
                    Span { Text(text) }.id(innerID)
                } else {
                    Text(text)
                }
            }
        })
        .class("thinking-row")
        // the webui key and the hidden flag are both presence-only
        let keyed = Group {
            if key.isEmpty {
                row
            } else {
                row.webuiKey(key)
            }
        }
        return Group {
            if hidden {
                keyed.flag(.hidden)
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
                    .data("copy-target", target)
                    .title("Copy this activity")
                    Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
                }, content: {
                    Div(class: "wl-detail") {
                        if let interim = m.content, !interim.isEmpty {
                            Div(class: "msg-body interim") { TrustedMarkup(mdBox(interim), from: .markdown) }
                        }
                        toolChipsHTML(calls, results: pair.1)
                    }
                })
                .class("worklog-summary")
                .id(target)
                .webuiKey(target)
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
                    rows
                }
            })
            .class("turn-worklog")
            .data("tw-session", activeSessionID ?? "")
            .webuiKey(worklogKey)
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
        .id("turn-\(turnIndex)")
        .data("turn-duration", String(format: "%.0f", finalMsg.turnDuration ?? 0))
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
                    Div(class: "msg-body interim") { TrustedMarkup(mdBox(interim), from: .markdown) }
                }
                for c in calls {
                    ErasedViews([toolCardHTML(c, result: results[c.id])])
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
                            Div(class: "msg-body interim") { TrustedMarkup(mdBox(interim), from: .markdown) }
                        }
                        toolChipsHTML(calls, results: results)
                    }
                })
                .class("worklog-summary")
                if !mk.isEmpty {
                    row.webuiKey("ws-" + mk)
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
            Span(class: "tc-arg") { TrustedMarkup(toolArgSummary(args), from: .other("tool-args")) }
            Span(class: "tw-spacer") {}
            ArcButton(id: nil, component: nil, class: "tc-copy", tabIndex: -1) {
                WebUIIcon(.copy, size: .small)
            }
            .data("copy", args)
            .title("Copy arguments")
            Span(class: "tw-caret") { WebUIIcon(.chevronRight, size: .small) }
        }, content: {
            Div(class: "tc-detail") {
                Div(class: "tc-label") { Text("Arguments") }
                Preformatted(args).class("tc-block")
                if let result, !result.isEmpty {
                    Div(class: "tc-label") { Text("Result") }
                    Preformatted(result).class("tc-block")
                }
            }
        })
        .class("tool-card")
        return Group {
            if c.id.isEmpty {
                card
            } else {
                card.data("webui-key", "tc-\(c.id)")
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
                    Div(class: "msg-body user-bubble") { TrustedMarkup(mdBox(content), from: .markdown) }
                }
                if rawIdx >= 0 {
                    bubble.id("msg-user-\(rawIdx)")
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
                    block.id("msg-\(rawIdx)")
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
                        Preformatted(content).class("tc-block")
                    }
                })
                .class("tool-card")
                let keyed = Group {
                    if resultKey.isEmpty {
                        card
                    } else {
                        card.webuiKey(resultKey)
                    }
                }
                let block = Div(class: "msg assistant") {
                    Div { keyed }.attribute("style", "width:100%")
                }
                if rawIdx >= 0 {
                    block.id("msg-\(rawIdx)")
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
                    for c in calls { ErasedViews([toolCardHTML(c, result: results[c.id])]) }
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
                                .title("Tokens per second")
                        }
                    }
                    Span(class: "mm-spacer") {}
                    Span(class: "mm-right") {
                        Span(class: "msg-elapsed") { Text(fmtElapsed(live.startedAt)) }
                            .data("elapsed", "")
                            .data("started", "\(Int(live.startedAt.timeIntervalSince1970 * 1000))")
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
                                    .data("elapsed", "")
                                    .data("started", "\(Int(started.timeIntervalSince1970 * 1000))")
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
                        .id("live-turn-text")
                    if live.status == "running" {
                        Span(class: "stream-cursor") {}
                    }
                }
                .id("live-turn-body")
                .attribute("style", "white-space:pre-wrap")
                if mode == "transparent_stream" && !live.toolChips.isEmpty {
                    Div(class: "tool-pills") { TrustedMarkup(live.toolChips.joined(), from: .other("tool-chips")) }
                }
            }
            .attribute("style", "width:100%")
        }
        .id("live-turn")
        .data("streaming", "true")
        .data("session", live.sessionID)
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
                    .title("Collapse")
                    ArcButton(id: "approval-dismiss", component: "approval-dismiss", class: "approval-dismiss") {
                        WebUIIcon(.x, size: .small)
                    }
                    .data("event", "click")
                    .title("Dismiss")
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
                    .data("event", "click")
                    ArcButton(id: "approval-session", component: "approval-session", class: "approval-btn session") {
                        WebUIIcon(.lock, size: .small)
                        Span(class: "approval-btn-label") { Text("Allow session") }
                    }
                    .data("event", "click")
                    ArcButton(id: "approval-always", component: "approval-always", class: "approval-btn always") {
                        WebUIIcon(.star, size: .small)
                        Span(class: "approval-btn-label") { Text("Always allow") }
                    }
                    .data("event", "click")
                    ArcButton(id: "approval-deny", component: "approval-deny", class: "approval-btn deny") {
                        WebUIIcon(.x, size: .small)
                        Span(class: "approval-btn-label") { Text("Deny") }
                    }
                    .data("event", "click")
                }
                Div(class: "approval-yolo-row") {
                    ArcButton(id: "approval-yolo", component: "approval-yolo", class: "approval-btn yolo") {
                        WebUIIcon(.zap, size: .small)
                        Span(class: "approval-btn-label") { Text("Skip all this session") }
                    }
                    .data("event", "click")
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
                        .id("clarify-countdown")
                        .data("expires", "\(expiryMs)")
                    ArcButton(id: "clarify-collapse", component: nil, class: "clarify-collapse") {
                        WebUIIcon(.chevronDown, size: .small)
                    }
                    .title("Collapse")
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
                    .wire("clarify-choice")
                }
                Div(class: "clarify-response") {
                    ArcButton(id: "clarify-other", component: nil, class: "clarify-pill pill-other") {
                        Text("Other")
                    }
                    .title("Type your own answer")
                    Form(action: "", method: nil, id: "clarify-form", class: "clarify-free") {
                        Input(field: "clarify-input",
                              placeholder: "Type your response...", type: .text)
                            .data("component-id", "clarify-input")
                            .attribute("autocomplete", "off")
                        ArcButton(id: "clarify-submit", component: nil, class: "clarify-submit", type: .submit) {
                            Text("Send")
                        }
                    }
                    .wire("clarify-form", on: .submit)
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
            .data("event", "click")
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
                .data("copy", m.content ?? "")
                .title("Copy response")
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
                    .title("Context window usage")
                    .aria(.label("Context window usage"))
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
                        ErasedViews([Article {
                            Div(class: "selection-context-accent") {}
                                .aria(.hidden(.yes))
                            Div(class: "selection-context-body") {
                                Div(class: "selection-context-header") {
                                    Span(class: "selection-context-name") { Text(block.name) }
                                    ArcButton(id: block.id, component: nil, class: "selection-context-remove") {
                                        Text("✕")
                                    }
                                    .title("Remove context block")
                                }
                                Blockquote(preview)
                                    .class("selection-context-quote")
                            }
                        }
                        .class("selection-context-card")
                        .data("selection-id", block.id)])
                    }
                }
                .id("composer-selection-chips")
                .wire("selection-context-del")
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
                .id("composer-flyout")
            Div(class: "cmd-dropdown") {}
                .id("cmd-dropdown")
                .aria(.label("Slash commands"))
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
                .id("attach-chips")
                .wire("att-chips")
                TextArea(field: "composer-input",
                         placeholder: running ? "Send another message — queued after this reply." : "Message ARC…",
                         value: draft, rows: 1)
                    .data("component-id", "composer-input")
                    .data("session", sid)
                    .data("draft", draft)
                    .data("prevent-enter", "send")
                    .attribute("style", "min-height:24px")
                Div(class: "composer-toolbar") {
                    ArcButton(id: "cb-file", component: "cb-file",
                              class: "tool-btn" + (filePopOpen ? " on" : "")) {
                        WebUIIcon(.paperclip, size: .medium)
                    }
                    .data("tip", "Attach a file")
                    .aria(.label("Attach a file"))
                    // the star is the same glyph whether or not the chat is
                    // bookmarked — `.on` is what shows state (legacy parity).
                    ArcButton(id: "cb-bookmark", component: "cb-bookmark",
                              class: "tool-btn" + (isBooked ? " on" : "")) {
                        WebUIIcon(.star, size: .small)
                    }
                    .data("tip", "Bookmark this chat")
                    .aria(.label("Bookmark this chat"))
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
                        .title("Stop")
                        .aria(.label("Stop"))
                    } else {
                        ArcButton(id: "cb-send", component: "cb-send", class: "send-btn", type: .submit) {
                            WebUIIcon(.arrowUp, size: .medium)
                        }
                        .title("Send")
                        .aria(.label("Send"))
                    }
                }
            }
            .data("component-id", "composer-form")
            Span {}
                .id("dd-dismiss")
                .wire("dd-dismiss")
                .flag(.hidden)
            Div(class: "file-pop" + (filePopOpen ? "" : " hidden")) {
                Div(class: "fp-row") {
                    Input(id: "file-path-input", placeholder: "/absolute/path/to/file", type: .text)
                        .data("component-id", "file-path-input")
                        .value(formValues["file-path-input"] ?? "")
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
            .id("file-pop")
            .wire("file-recents")
            Div { Text(slashDataJSON()) }
                .id("slash-data")
                .flag(.hidden)
        }
        .id("composer-wrap")
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
                                .aria(.label(removeTip))
                        }
                        .title(removeTip)
                    }
                }
                .id("queued-sends")
                .wire("queued-sends")
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
        .title(tip)
        .aria(.label(tip))
    }

    /// one dropdown row. the row carries only its id: the wire dispatches on
    /// `targetId`, and the engine reports the nearest id *inside* the boundary —
    /// so the boundary lives on the popover (`dd-pop`), never on the row.
    private func ddRow<Content: WebUI.View>(id: String, extraClass: String = "",
                       @ElementBuilder body: () -> Content) -> some WebUI.View {
        let cls = extraClass.isEmpty ? "dd-row" : "dd-row \(extraClass)"
        return ArcButton(id: id, component: nil, class: cls) { body() }
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
            WebUIDropdown(isOpen: mainModelPickerOpen) {
                ddTrigger(id: "mainmc-toggle", icon: .zap, label: label, title: "Main model")
            } panel: {
                // only `isOpen` goes to the component: the trigger above is the
                // boundary and `id:`/`onSelect:` here are register-only, so
                // passing them would register a second handler for the same id.
                //
                // the panel is the component's and carries no routing
                // attributes of its own, so the popover wire rides one plain
                // wrapper inside it and the rows keep dispatching on `targetId`.
                Div {
                    Div(class: "dd-list") {
                        rows
                        if rows.isEmpty {
                            Div(class: "dd-empty") { Text("No model configurations yet — add one above.") }
                        }
                    }
                }
                .wire("mainmc")
            }
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
                        .wire("ws-search-input", on: .input)
                        .data("no-restore", "")
                        .aria(.label("Search workspaces"))
                        .attribute("spellcheck", "false")
                        .attribute("autocomplete", "off")
                        .value(wsSelectQuery)
                    if !wsSelectQuery.isEmpty {
                        ArcButton(id: "ws-search-clear", component: "ws-search-clear", class: "dd-clear") {
                            WebUIIcon(.x, size: .small)
                        }
                    }
                }
                Div(class: "dd-list") {
                    rows
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
            .wire("ws-pick")
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
                    rows
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
            .wire("profile-pick")
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
                        .wire("model-search-input", on: .input)
                        .data("no-restore", "")
                        .aria(.label("Search models"))
                        .attribute("spellcheck", "false")
                        .attribute("autocomplete", "off")
                        .value(modelSelectQuery)
                    if !modelSelectQuery.isEmpty {
                        ArcButton(id: "model-search-clear", component: "model-search-clear", class: "dd-clear") {
                            WebUIIcon(.x, size: .small)
                        }
                    }
                }
                Div(class: "dd-list") {
                    rows
                    if rows.isEmpty {
                        Div(class: "dd-empty") { Text("No models match “\(modelSelectQuery)”") }
                    }
                }
            }
            .wire("model-pick")
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
                    rows
                }
            }
            .wire("think-pick")
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

    func skillsMain() -> some WebUI.View {
        Group {
            if createSkill {
                skillCreateForm()
            } else if let name = selectedSkill, let skill = skills.first(where: { $0.name == name }) {
                if skillEdit {
                    skillEditForm(skill)
                } else {
                    let raw = skillBodyOnly(skill.content).isEmpty ? skill.description : skillBodyOnly(skill.content)
                    mainScroll {
                        Div(class: "detail-card") {
                            Div(class: "mem-head") {
                                Div {
                                    DetailTitle(skill.name, class: "mem-head-title")
                                    Div(class: "detail-sub") {
                                        Text(skill.category ?? "")
                                        if !skill.tags.isEmpty {
                                            Text(" • " + skill.tags.joined(separator: ", "))
                                        }
                                    }
                                }
                                ArcButton(id: "sk-edit", component: "skill-edit", class: "icon-mini", type: .button) {
                                    WebUIIcon(.edit, size: .small)
                                }
                                .title("Edit skill")
                                ArcButton(id: "sk-delete", component: "skill-delete", class: "icon-mini danger", type: .button) {
                                    WebUIIcon(.trash, size: .small)
                                }
                                .title("Delete skill")
                            }
                            Paragraph(skill.description).class("skill-desc")
                            // markdown crosses here — the one parser seam in this pane
                            Div(class: "detail-body detail-body-lead") {
                                TrustedMarkup(mdBox(raw), from: .markdown)
                            }
                        }
                    }
                }
            } else {
                // UX-16: one empty state, one CTA. A real "Create skill" button
                // in the canvas (the sidebar + is the other path).
                Div(class: "main-view") {
                    Div(class: "blank") {
                        Div(class: "big") { WebUIIcon(.star, size: .extraLarge) }
                        Div { Text(skills.isEmpty ? "No skills yet." : "Select a skill to see its description.") }
                        Div(class: "blank-cta") {
                            ArcButton(id: "skill-new-main", component: "skill-new", class: "primary-btn", type: .button) {
                                WebUIIcon(.plus, size: .medium)
                                Text(" Create skill")
                            }
                            .title("Create skill")
                        }
                    }
                }
                .attribute("style", "justify-content:center")
            }
        }
    }

    /// Inline edit form for the selected skill (mirrors the memory/doc editor).
    /// inline edit form for the selected skill (mirrors the memory/doc editor).
    func skillEditForm(_ skill: Skill) -> some WebUI.View {
        let nameV = formValues["sk-edit-name-input"] ?? skill.name
        let catV = formValues["sk-edit-cat-input"] ?? skill.category ?? ""
        let descV = formValues["sk-edit-desc-input"] ?? skill.description
        let contentV = formValues["sk-edit-content-input"] ?? skill.content
        return mainScroll {
            Form(method: nil, id: "sk-edit-form", class: "detail-card skill-form") {
                Heading("Edit skill", level: .h1, class: "detail-title")
                Div(class: "detail-sub") {
                    Text("Editing ")
                    Text(skill.name)
                    Text(" — saves back to ")
                    Text(skill.path.path)
                }
                skillMetadataHTML(skill)
                Input(name: "sk-orig", type: .hidden, value: skill.name)
                Div(class: "form-grid") {
                    WebUIField(label: "Name", controlID: "sk-edit-name-input") {
                        Input(field: "sk-edit-name-input", type: nil, value: nameV,
                              attributes: [("data-component-id", "sk-edit-name-input"), ("data-event", "input")])
                    }
                    WebUIField(label: "Category", controlID: "sk-edit-cat-input") {
                        Input(field: "sk-edit-cat-input", placeholder: "e.g. devops", type: nil, value: catV,
                              attributes: [("data-component-id", "sk-edit-cat-input"), ("data-event", "input")])
                    }
                    WebUIField(label: "Description", controlID: "sk-edit-desc-input") {
                        Input(field: "sk-edit-desc-input", type: nil, value: descV,
                              attributes: [("data-component-id", "sk-edit-desc-input"), ("data-event", "input")])
                    }
                    WebUIField(label: "Content (Markdown)", controlID: "sk-edit-content-input") {
                        TextArea(field: "sk-edit-content-input", value: contentV, rows: 0)
                            .wire("sk-edit-content-input", on: .input)
                    }
                }
                Div(class: "row-actions-main") {
                    ArcButton("Save changes", class: "primary-btn", type: .submit)
                    ArcButton("Delete", id: "sk-edit-delete", component: "sk-edit-delete", class: "ghost-btn danger", type: .button)
                    ArcButton("Cancel", id: "sk-edit-cancel", class: "ghost-btn", type: .button)
                }
            }
            .data("component-id", "sk-edit-form")
        }
    }

    /// reference metadata box: a rounded monospace panel with the raw YAML
    /// frontmatter. Shown only in the skill EDITOR (never in the reader).
    /// reference metadata box: a rounded monospace panel with the raw YAML
    /// frontmatter. shown only in the skill EDITOR (never in the reader).
    func skillMetadataHTML(_ skill: Skill) -> some WebUI.View {
        let lines = skill.content.components(separatedBy: .newlines)
        return Group {
            if let r = skillFrontmatterRange(skill.content) {
                Div(class: "skill-meta-box") {
                    Div(class: "skill-meta-head") { Text("Metadata") }
                    Preformatted(lines[r].joined(separator: "\n"))
                        .class("skill-meta-pre")
                }
            }
        }
    }

    func skillCreateForm() -> some WebUI.View {
        let nameErr = self.skillCreateErrors["skill-name-input"]
        let descErr = self.skillCreateErrors["skill-desc-input"]
        // round-3 UX-35: mark the invalid field, and ask the post-patch seam to
        // put the caret in the first one that failed.
        let nameFocus = nameErr != nil
        let descFocus = descErr != nil && nameErr == nil

        func errSpan(id: String, message: String?) -> some WebUI.View {
            Group {
                if let message {
                    Span(class: "inline-err") { Text(message) }.id(id)
                } else {
                    Span(class: "inline-err") { Text("") }
                        .id(id)
                        .flag(.hidden)
                }
            }
        }

        return mainScroll {
            Form(method: nil, id: "skill-create-form", class: "detail-card skill-form") {
                Heading("New skill", level: .h1, class: "detail-title")
                Div(class: "detail-sub") {
                    Text("A skill is a SKILL.md file with YAML frontmatter (name, description) found under the skills directory.")
                }
                Div(class: "form-grid") {
                    Div {
                        FormLabel(for: "skill-name-input") {
                            Text("Name")
                            Span(class: "req-tag") { Text("Required") }
                        }
                        invalidField(
                            Input(field: "skill-name-input", placeholder: "my-skill", type: nil,
                                  attributes: [("data-component-id", "skill-name-input"),
                                               ("data-event", "input"),
                                               ("class", "text-input")]),
                            message: nameErr, describedBy: "skill-name-err", focus: nameFocus)
                        errSpan(id: "skill-name-err", message: nameErr)
                    }
                    WebUIField(label: "Category", controlID: "skill-cat-input") {
                        Input(field: "skill-cat-input", placeholder: "e.g. devops", type: nil,
                              attributes: [("data-component-id", "skill-cat-input"), ("data-event", "input")])
                    }
                    Div {
                        FormLabel(for: "skill-desc-input") {
                            Text("Description")
                            Span(class: "req-tag") { Text("Required") }
                        }
                        invalidField(
                            Input(field: "skill-desc-input", placeholder: "Short description", type: nil,
                                  attributes: [("data-component-id", "skill-desc-input"),
                                               ("data-event", "input"),
                                               ("class", "text-input")]),
                            message: descErr, describedBy: "skill-desc-err", focus: descFocus)
                        errSpan(id: "skill-desc-err", message: descErr)
                    }
                    WebUIField(label: "Content (Markdown)", controlID: "skill-content-input") {
                        TextArea(field: "skill-content-input",
                                 placeholder: "How to use this skill…", rows: 0)
                            .wire("skill-content-input", on: .input)
                    }
                }
                Div(class: "row-actions-main") {
                    ArcButton("Create skill", class: "primary-btn", type: .submit)
                    ArcButton("Cancel", id: "skill-cancel", component: "skill-cancel", class: "ghost-btn", type: .button)
                }
            }
            .data("component-id", "skill-create-form")
        }.class("main-view")
    }

    // MARK: Profiles main

    func profilesMain() -> some WebUI.View {
        // UX-13: with exactly one profile there is nothing to "select" —
        // auto-select it so the canvas is never a dead end. Only when two
        // or more profiles exist does the empty "Select a profile" state
        // stay on screen.
        if selectedProfile == nil && profiles.count == 1 {
            selectedProfile = profiles[0].name
        }
        return Group {
            if createProfile || editingProfile != nil {
                profileFormView()
            } else if let name = selectedProfile, let p = profiles.first(where: { $0.name == name }) {
                let set = p.enabledToolsets ?? []
                let toolsetsNote = set.isEmpty ? "all (not overridden)" : set.joined(separator: ", ")
                let encName = enc(p.name)
                let isDefault = p.name == "default"
                mainScroll {
                    Div(class: "detail-card") {
                        Div(class: "mem-head") {
                            Div {
                                DetailTitle(p.title.isEmpty ? p.name : p.title, class: "mem-head-title")
                                Div(class: "detail-sub") {
                                    Text(p.description.isEmpty ? "No description." : p.description)
                                }
                            }
                            Div(class: "row-actions") {
                                ArcButton(id: "pr-edit-\(encName)", class: "icon-mini", type: .button) {
                                    WebUIIcon(.edit, size: .medium)
                                }
                                .title("Edit profile")
                                ArcButton(id: "pr-sel-\(encName)", class: "icon-mini", type: .button) {
                                    WebUIIcon(.check, size: .medium)
                                }
                                .title("Select profile for this chat")
                                if !isDefault {
                                    ArcButton(id: "pr-del-\(encName)", class: "icon-mini danger", type: .button) {
                                        WebUIIcon(.trash, size: .medium)
                                    }
                                    .title("Delete profile")
                                }
                            }
                            .wire("profile-list")
                        }
                        profileCardHTML(p)
                        Heading("Tool sets", level: .h3, class: "detail-h3")
                        Div(class: "detail-sub") {
                            Text("Overrides configured on the profile: \(toolsetsNote)")
                        }
                        Heading("Context parameters", level: .h3, class: "detail-h3")
                        profileContextHTML(p)
                        Heading("Agent powers", level: .h3, class: "detail-h3")
                        Div(class: "detail-sub") {
                            Text("Lockdowns for this profile's skills and profile files (MEMORY / USER / SOUL).")
                        }
                        agentPowersSection()
                    }
                }
            } else {
                Div(class: "main-view") {
                    Div(class: "blank") {
                        Div(class: "big") { WebUIIcon(.user, size: .extraLarge) }
                        Div { Text("Select a profile to see its details.") }
                    }
                }
                .attribute("style", "justify-content:center")
            }
        }
    }

    /// the create/edit profile form. one shape for both: `editingProfile`
    /// decides the title, the submit verb, and whether the name is locked.
    private func profileFormView() -> some WebUI.View {
        let editing = editingProfile.flatMap { n in profiles.first { $0.name == n } }
        let isEdit = editing != nil
        let ectx = editing?.context
        let effortSel = ectx?.reasoningEffort ?? ""
        return mainScroll {
            Form(method: nil, id: "profile-create-form", class: "detail-card profile-form") {
                Heading(isEdit ? "Edit profile" : "New profile", level: .h1, class: "detail-title")
                Div(class: "detail-sub") {
                    Text(isEdit
                         ? "Edit the profile identity and its context parameters."
                         : "A named, isolated agent configuration.")
                }
                Div(class: "form-grid") {
                    WebUIField(label: "Name", controlID: "profile-name-input") {
                        if isEdit {
                            Input(field: "profile-name-input",
                                  placeholder: "researcher", type: nil, value: editing?.name ?? "")
                                .data("component-id", "profile-name-input")
                                .flag(.readonly)
                        } else {
                            Input(field: "profile-name-input",
                                  placeholder: "researcher", type: nil, value: "")
                                .data("component-id", "profile-name-input")
                        }
                    }
                    WebUIField(label: "Title", controlID: "profile-title-input") {
                        Input(field: "profile-title-input",
                              placeholder: "Research Analyst", type: nil, value: editing?.title ?? "")
                            .data("component-id", "profile-title-input")
                    }
                    WebUIField(label: "Description", controlID: "profile-desc-input") {
                        Input(field: "profile-desc-input",
                              placeholder: "One-line mission", type: nil, value: editing?.description ?? "")
                            .data("component-id", "profile-desc-input")
                    }
                }
                Heading("Context parameters", level: .h3, class: "detail-h3")
                Div(class: "detail-sub") {
                    Text("Model context overrides for chats bound to this profile. Leave blank to inherit the chat's model config.")
                }
                Div(class: "form-grid") {
                    WebUIField(label: "Context window (tokens)", controlID: "profile-ctx-length") {
                        Input(field: "profile-ctx-length",
                              placeholder: "e.g. 128000", type: .number,
                              value: ectx?.contextLength.map(String.init) ?? "",
                              attributes: [("min", "1024"), ("step", "1024")])
                    }
                    WebUIField(label: "Max output (tokens)", controlID: "profile-ctx-maxtok") {
                        Input(field: "profile-ctx-maxtok",
                              placeholder: "e.g. 8192", type: .number,
                              value: ectx?.maxOutputTokens.map(String.init) ?? "",
                              attributes: [("min", "1")])
                    }
                    Div {
                        Label("Reasoning effort", for: "profile-ctx-effort")
                        Select(field: "profile-ctx-effort",
                               options: AppState.effortOptions, selected: effortSel)
                            .data("component-id", "profile-ctx-effort")
                    }
                    WebUIField(label: "Temperature", controlID: "profile-ctx-temp") {
                        Input(field: "profile-ctx-temp",
                              placeholder: "e.g. 0.7", type: .number,
                              value: ectx?.temperature.map { String($0) } ?? "",
                              attributes: [("min", "0"), ("max", "2"), ("step", "0.1")])
                    }
                    WebUIField(label: "Top P", controlID: "profile-ctx-topp") {
                        Input(field: "profile-ctx-topp",
                              placeholder: "e.g. 0.9", type: .number,
                              value: ectx?.topP.map { String($0) } ?? "",
                              attributes: [("min", "0"), ("max", "1"), ("step", "0.05")])
                    }
                    WebUIField(label: "Compress at (tokens)", controlID: "profile-ctx-budget") {
                        Input(field: "profile-ctx-budget",
                              placeholder: "e.g. 32000", type: .number,
                              value: ectx?.compressionBudget.map(String.init) ?? "",
                              attributes: [("min", "1024"), ("step", "1024")])
                    }
                }
                Heading("Context skills", level: .h3, class: "detail-h3")
                Div(class: "detail-sub") {
                    Text("Skills pinned to this profile: their full content is loaded into every prompt for chats bound to this profile (as if the user had asked for them).")
                }
                profileContextSkillsHTML()
                Div(class: "row-actions-main") {
                    ArcButton(isEdit ? "Save changes" : "Create profile", class: "primary-btn", type: .submit)
                    ArcButton("Cancel", id: "profile-cancel", component: "profile-cancel", class: "ghost-btn", type: .button)
                }
            }
            .data("component-id", "profile-create-form")
        }
    }

    /// Per-profile context parameters summary (kv rows; "inherit" when unset)
    /// plus the pinned context skills, if any.
    func profileContextHTML(_ p: Profile) -> some WebUI.View {
        Group {
            if let ctx = p.context, !ctx.isEmpty {
                AkvRow(key: "Context window",
                       value: ctx.contextLength.map { "\($0) tokens" } ?? "inherit")
                AkvRow(key: "Max output",
                       value: ctx.maxOutputTokens.map { "\($0) tokens" } ?? "inherit")
                AkvRow(key: "Reasoning effort", value: ctx.reasoningEffort ?? "inherit")
                AkvRow(key: "Temperature", value: ctx.temperature.map { String($0) } ?? "inherit")
                AkvRow(key: "Top P", value: ctx.topP.map { String($0) } ?? "inherit")
                AkvRow(key: "Compress at",
                       value: ctx.compressionBudget.map { "\($0) tokens" } ?? "inherit")
            } else {
                AkvRow(key: "Context", value: "inherit (no overrides)")
            }
            if let pinned = p.contextSkills, !pinned.isEmpty {
                AkvRow(key: "Context skills", value: pinned.joined(separator: ", "))
            }
        }
    }

    /// The profile edit form's "Context skills" section: pinned-skill rows
    /// with remove buttons, an "Add skill" dropdown over the discovered
    /// skills, and a hidden CSV field the submit wire reads.
    ///
    /// the rows only — the popover frame and the click boundary belong to the
    /// `WebUIDropdown` that hosts them (see `profileContextSkillsHTML`).
    func profileSkillsPickerList(_ available: [Skill]) -> some WebUI.View {
        Div(class: "dd-list") {
            for s in available {
                ErasedViews([ddRow(id: "pcs-pick-\(enc(s.name))") {
                    Span(class: "dd-row-title") { Text(s.name) }
                    Span(class: "dd-row-sub") { Text(s.description) }
                }])
            }
            if available.isEmpty {
                Div(class: "dd-empty") { Text("All discovered skills are already pinned.") }
            }
        }
    }

    func profileContextSkillsHTML() -> some WebUI.View {
        let draft = profileSkillsDraft
        let chosen = Set(draft)
        let available = skills.filter { !chosen.contains($0.name) }
        return Group {
            Div(class: "pn-draft") {
                for name in draft {
                    let known = skills.first(where: { $0.name == name })
                    Div(class: "pn-draft-row") {
                        Span(class: "pn-draft-name") { Text(known?.name ?? name) }
                        Span(class: "pn-draft-desc") { Text(known?.description ?? "missing") }
                        ArcButton(id: "pcs-rm-\(enc(name))", class: "icon-mini danger", type: .button) {
                            WebUIIcon(.x, size: .small)
                        }
                        .title("Remove skill")
                    }
                }
                if draft.isEmpty {
                    Div(class: "pn-draft-empty") {
                        Text("No pinned skills — every prompt uses the regular skill index.")
                    }
                }
            }
            .wire("pcs-rm")
            Div(class: "dd pn-picker") {
                WebUIDropdown(isOpen: profileSkillsPickerOpen) {
                    ddTrigger(id: "pcs-toggle", icon: .plus, iconSize: .medium,
                              label: "Add skill", title: "Pin a skill into this profile's context")
                } panel: {
                    // only `isOpen` goes to the component (the trigger is the
                    // boundary); the panel emits no routing attributes, so the
                    // picker's wire rides one plain wrapper inside it — the
                    // engine wires by component id, and dropping that attribute
                    // leaves a popover that renders and never responds.
                    Div { profileSkillsPickerList(available) }
                        .wire("pcs")
                }
            }
        }
    }

    /// <option> tags for the reasoning-effort picker ("" = inherit).
    /// the reasoning-effort options ("" = inherit). compile-time constant: the
    /// ladder is a product decision, not a runtime lookup.
    static let effortOptions: [SelectOption] = ["", "minimal", "low", "medium", "high", "max"]
        .map { SelectOption(value: $0, label: $0.isEmpty ? "Inherit" : $0) }

    /// arc-parity profile card: PROFILE eyebrow + key/value rows with
    /// badges (ACTIVE / (default) / Daemon running / code-block model).
    func profileCardHTML(_ p: Profile) -> some WebUI.View {
        let activeProfile = profileName(for: activeSessionID) ?? ""
        let isActive = !activeProfile.isEmpty && activeProfile == p.name
        let isDefault = p.name == "default"
        let skillCount = enabledSkillCount(for: p.name)
        let modelName = p.model ?? settings.modelConfig(named: settings.activeConfig)?.model ?? "inherit"
        let providerName = p.provider ?? "custom"
        let keyCount = settings.modelConfigs.filter { !$0.apiKey.isEmpty }.count
        let keyLabel = keyCount > 0 ? "\(keyCount) \(keyCount == 1 ? "key" : "keys") configured" : "None"
        return Div(class: "pl-card") {
            Div(class: "pl-eyebrow") { Text("PROFILE") }
            Div(class: "pl-row") {
                Span(class: "pl-k") { Text("Status") }
                Span(class: "pl-v") {
                    if isActive {
                        Span(class: "pl-badge badge-active") { Text("ACTIVE") }
                    } else {
                        Span(class: "pl-badge badge-inactive") { Text("IDLE") }
                    }
                    if isDefault {
                        Text(" ")
                        Span(class: "pl-badge badge-default") { Text("DEFAULT") }
                    }
                }
            }
            Div(class: "pl-row") {
                Span(class: "pl-k") { Text("Daemon") }
                Span(class: "pl-v") {
                    if daemonRunning {
                        Span(class: "pl-badge badge-green") {
                            Span(class: "pl-dot") { Text("") }
                            Text("Daemon running")
                        }
                    } else {
                        Span(class: "pl-badge badge-red") { Text("Daemon stopped") }
                    }
                }
            }
            Div(class: "pl-row") {
                Span(class: "pl-k") { Text("Model") }
                Span(class: "pl-v") {
                    InlineCode(modelName).class("pl-code")
                }
            }
            Div(class: "pl-row") {
                Span(class: "pl-k") { Text("Provider") }
                Span(class: "pl-v") { Text(providerName) }
            }
            Div(class: "pl-row") {
                Span(class: "pl-k") { Text("API key") }
                Span(class: "pl-v") { Text(keyLabel) }
            }
            Div(class: "pl-row") {
                Span(class: "pl-k") { Text("Skills") }
                Span(class: "pl-v") { Text("\(skillCount) of \(skills.count) active") }
            }
        }
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

    /// a form field that carries its error state. the aria pair and the
    /// post-patch caret hint are PRESENCE-only: an empty `aria-invalid=""` is
    /// worse than none, so each case emits a different shape rather than a
    /// blank value.
    func invalidField(_ field: some WebUI.View, message: String?,
                      describedBy: String, focus: Bool) -> some WebUI.View {
        Group {
            if message != nil {
                if focus {
                    field
                        .aria(.invalid(true))
                        .aria(.describedby(describedBy))
                        .data("focus-after-patch", "")
                } else {
                    field
                        .aria(.invalid(true))
                        .aria(.describedby(describedBy))
                }
            } else {
                field
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
    func mainScroll<Content: WebUI.View>(@ElementBuilder _ content: () -> Content) -> some WebUI.View {
        Div(class: "main-view") {
            Div(id: "main-scroll", class: "main-scroll") {
                content()
            }
            .data("scroll-key", "main-scroll")
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
                                    TrustedMarkup(SidebarTabIconRenderer.render(tab.icon, size: .medium), from: .icon)
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
                    .data("event", "click")
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
                            Text("A server is a child process that speaks the Model Context Protocol over stdio — a local executable, usually built with swift-mcp. Once added it is started on first use, and the agent reaches its tools through the single ")
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
                        ErasedViews([mcpRowHTML(name)])
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
                    .title("Delete")
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
        .data("component-id", "mcp-list")
    }

    func mcpFormHTML() -> some WebUI.View {
        let title = editingMCPServer == nil ? "New MCP server" : "Edit MCP server"
        // input `name` attributes are the submit payload keys the engine builds
        // (`extractFormData` keys by `name`): renaming one silently kills Save.
        return Form(action: "", method: nil, id: "mcp-form", class: "detail-card mcp-form") {
            Heading(title, level: .h1, class: "detail-title")
            Div(class: "detail-sub") {
                Text("The server is a local executable that speaks MCP over stdio — built with swift-mcp, or any other MCP SDK, and already on this machine. It is launched directly, as ")
                InlineCode("<command> <args…>")
                Text(" — never through a shell and never through a package manager — with arc's own credentials stripped from its environment. Save, then press Test on the row to start it and list the tools it exposes.")
            }
            Div(class: "form-grid") {
                WebUIField(label: "Name", controlID: "mcp-name-input") {
                    Input(field: "mcp-name-input",
                          placeholder: "filesystem", type: .text,
                          value: formValues["mcp-name-input"] ?? "",
                          attributes: [("data-component-id", "mcp-name-input"),
                                       ("autofocus", "")])
                    Small("How the agent selects this server. Lowercase letters, digits, '-' and '_'.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
                WebUIField(label: "Command", controlID: "mcp-command-input") {
                    Input(field: "mcp-command-input",
                          placeholder: "arc", type: .text,
                          value: formValues["mcp-command-input"] ?? "",
                          attributes: [("data-component-id", "mcp-command-input")])
                    Small("One executable, resolved through PATH. arc ships its own MCP server: Command `arc`, Arguments `tools`, `mcp`, `serve`.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
                WebUIField(label: "Arguments (one per line)", controlID: "mcp-args-input") {
                    TextArea(field: "mcp-args-input",
                             placeholder: "tools\nmcp\nserve",
                             value: formValues["mcp-args-input"] ?? "", rows: 4)
                        .data("component-id", "mcp-args-input")
                    Small("Passed verbatim as argv — quotes are not interpreted, so an argument containing spaces works as typed.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
                WebUIField(label: "Environment (KEY=VALUE, one per line)", controlID: "mcp-env-input") {
                    TextArea(field: "mcp-env-input",
                             placeholder: "GITHUB_PERSONAL_ACCESS_TOKEN=ghp_…",
                             value: formValues["mcp-env-input"] ?? "", rows: 3)
                        .data("component-id", "mcp-env-input")
                    Small("arc strips its own ARC_/OPENAI_/ANTHROPIC_ variables from every MCP server — this is how a server gets its own credentials.")
                        .attribute("style", "color:var(--muted);font-size:0.75em")
                }
            }
            Div(class: "row-actions-main") {
                ArcButton("Save", class: "primary-btn", type: .submit)
                ArcButton("Cancel", id: "mcp-cancel", component: "mcp-cancel", class: "ghost-btn")
            }
        }
        .data("component-id", "mcp-form")
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
            // the two branches render different `mainScroll` content types, and
            // this function has one opaque return type — so the one-value
            // erasure is what lets both returns agree.
            return ErasedViews([mainScroll {
                Form(method: nil, id: "ws-create-form", class: "detail-card ws-form") {
                    Heading("New workspace", level: .h1, class: "detail-title")
                    Div(class: "detail-sub") {
                        Text("A workspace points at any folder on this computer. The folder path is required and follows Unix path rules; the name is an optional label — leave it blank and it is derived from the folder. Sessions keep their own workspace per chat; you pick it in the chat composer.")
                    }
                    Div(class: "form-grid") {
                        WebUIField(label: "Folder path", controlID: "ws-path-input") {
                            Input(field: "ws-path-input", placeholder: "/Users/you/research or ~/research",
                                  type: .text, value: formValues["ws-path-input"] ?? "",
                                  attributes: [("data-component-id", "ws-path-input"),
                                               ("autofocus", "")])
                            Small("Required. An absolute path; ~ means your home folder.")
                                .class("form-hint")
                        }
                        WebUIField(label: "Name (optional)", controlID: "ws-name-input") {
                            Input(field: "ws-name-input", placeholder: "derived from the folder name",
                                  type: .text, value: formValues["ws-name-input"] ?? "",
                                  attributes: [("data-component-id", "ws-name-input")])
                            Small("A label for the switcher — any text except '/'.")
                                .class("form-hint")
                        }
                    }
                    Div(class: "row-actions-main") {
                        ArcButton("Create", class: "primary-btn", type: .submit)
                        ArcButton("Cancel", id: "ws-cancel", component: "ws-cancel", class: "ghost-btn")
                    }
                }
                .data("component-id", "ws-create-form")
            }])
        }
        let ws = settings.activeWorkspace
        let path = workspacePath(for: nil)
        return ErasedViews([mainScroll {
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
        }])
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
                        .flag(.disabled)
                        .class("num-input")
                } else {
                    Input(id: id, type: .number, value: "\(value)")
                        .attribute("min", "1")
                        .attribute("step", "1")
                        .class("num-input")
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
                    .id("al-max-turns-wrap")
                    .wire("al-max-turns", on: .change)
                }
                SettingRow {
                    Text("Unlimited tool iterations")
                    Small("No iteration cap: the turn keeps running until the agent finishes the prompt on its own.")
                } control: {
                    Div {
                        ArcSwitch(id: "al-max-turns-unlimited", on: maxUnlimited)
                    }
                    .id("al-max-turns-unl-wrap")
                    .wire("al-max-turns-unlimited", on: .change)
                }
                SettingRow {
                    Text("Per-tool call cap")
                    Small("How many times one tool may run per turn before a synthetic \"N calls (cap N)\" reply (default 25).")
                } control: {
                    Div {
                        numField("al-tool-cap", loopValue, disabled: loopUnlimited)
                    }
                    .id("al-tool-cap-wrap")
                    .wire("al-tool-cap", on: .change)
                }
                .attribute("style", "margin-top:14px")
                SettingRow {
                    Text("Unlimited per-tool calls")
                    Small("No synthetic call cap for any tool in a turn.")
                } control: {
                    Div {
                        ArcSwitch(id: "al-tool-cap-unlimited", on: loopUnlimited)
                    }
                    .id("al-tool-cap-unl-wrap")
                    .wire("al-tool-cap-unlimited", on: .change)
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
                .id("ap-skill-locks")
                .wire("ap-skill-locks", on: .change)
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
                .id("ap-profilefile-locks")
                .wire("ap-profilefile-locks", on: .change)
            }
            .attribute("style", "margin-top:12px")
        }
        .id("agent-powers")
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
                            WebUIDropdown(isOpen: storagePickOpen) {
                                ddTrigger(id: "storage-pick-toggle", icon: .database,
                                          label: mediumLabel(effectiveMedium),
                                          title: "Storage medium in use")
                            } panel: {
                                // only `isOpen` goes to the component: this trigger is
                                // the boundary, and `id:`/`onSelect:` here are register-
                                // only, which would be a second handler for the same id.
                                //
                                // the panel carries no routing attributes of its own, so
                                // the popover wire rides one plain wrapper inside it and the
                                // rows keep dispatching on `targetId`.
                                Div {
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
                                                    badges(active: effectiveFile,
                                                           staged: stagedStorage == "file")
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
                                                    badges(active: !effectiveFile && effectiveMedium == "config",
                                                           staged: stagedStorage == "config")
                                                }
                                            }
                                            Span(class: "dd-row-sub") {
                                                Text("Tessera from the tessera block of ~/.arc/config.json")
                                            }
                                        }
                                        for conn in connections {
                                            ErasedViews([ddRow(id: "storage-pick-conn-\(enc(conn.id))") {
                                                Span(class: "dd-row-title") {
                                                    Text("\(conn.name) ")
                                                    Span(class: "dd-badges") {
                                                        badges(active: !effectiveFile && effectiveMedium == conn.id,
                                                               staged: stagedStorage == conn.id)
                                                    }
                                                }
                                                Span(class: "dd-row-sub") {
                                                    Text("\(conn.endpointLabel) — app \(conn.application)")
                                                    incomplete(conn)
                                                }
                                            }])
                                        }
                                    }
                                }
                                .wire("storage-pick")
                            }
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
                        // the row's type holds opaque `some View` modifiers
                        // (`.wire`), which `buildArray` rejects — one erased
                        // value is the documented shape for this loop.
                        ErasedViews([Div(class: "mc-row") {
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
                                incomplete(conn)
                            }
                            Div(class: "storage-row-actions") {
                                Div {
                                    ArcButton("Edit", id: "storage-edit-\(encID)",
                                              class: "ghost-btn btn-sm")
                                }
                                .wire("storage-edit")
                                Div {
                                    ArcButton("Remove", id: "storage-del-\(encID)",
                                              class: "danger-btn btn-sm")
                                }
                                .wire("storage-del")
                            }
                        }])
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
            Input(field: "storage-edit-id", type: .hidden,
                  value: se?.id ?? "",
                  attributes: [("data-component-id", "storage-edit-id")])
            Div(class: "form-grid-3") {
                WebUIField(label: "Name", controlID: "sc-name") {
                    Input(field: "sc-name", placeholder: "Home relay",
                          type: nil, value: se?.name ?? "",
                          attributes: [("data-component-id", "sc-name"), ("autocomplete", "off")])
                }
                WebUIField(label: "Server IP / host", controlID: "sc-ip") {
                    Input(field: "sc-ip", placeholder: "10.0.0.1",
                          type: nil, value: se?.serverIP ?? "",
                          attributes: [("data-component-id", "sc-ip"), ("autocomplete", "off")])
                }
                WebUIField(label: "Port", controlID: "sc-port") {
                    Input(field: "sc-port", placeholder: "51820",
                          type: .number, value: se.map { String($0.serverPort) } ?? "",
                          attributes: [("data-component-id", "sc-port"),
                                       ("autocomplete", "off"),
                                       ("min", "1"), ("max", "65535")])
                }
            }
            WebUIField(label: "Application id", controlID: "sc-app") {
                Input(field: "sc-app", placeholder: "1",
                      type: .number, value: se.map { String($0.application) } ?? "",
                      attributes: [("data-component-id", "sc-app"),
                                   ("min", "0"), ("max", "65535")])
            }
            Div(class: "form-grid-2") {
                WebUIField(label: "Server public key", controlID: "sc-pub") {
                    Input(field: "sc-pub", placeholder: "base64 (32 bytes)",
                          type: nil, value: se?.serverPublicKey ?? "",
                          attributes: [("data-component-id", "sc-pub"), ("autocomplete", "off")])
                }
                WebUIField(label: "Client private key", controlID: "sc-priv") {
                    // a private key is never a password-manager login: this input
                    // opts out of autofill (pinned).
                    Input(field: "sc-priv", placeholder: "base64 (32 bytes)",
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
        .data("component-id", "storage-conn-form")
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
            .data("scroll-key", "main-scroll")
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
                            ErasedViews([ArcButton(id: "thm-\(t.key)",
                                      class: "theme-pick-btn\(active ? " active" : "")") {
                                Span(class: "thm-preview") {
                                    Span(class: "thm-ic") { WebUIIcon(t.icon, size: .medium) }
                                }
                                .attribute("style", t.preview)
                                Span(class: "thm-label") { Text(t.label) }
                            }
                            .data("theme-choice", t.key)
                            .title(t.label)
                            .aria(.pressed(active ? .yes : .no))])
                        }
                    }
                    .wire("theme-pick")
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
                            .title(s.label)
                            .aria(.pressed(active ? .yes : .no))
                        }
                    }
                    .wire("font-size-pick")
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
                            ErasedViews([ArcButton(id: "scheme-\(enc(entry.id))",
                                      class: "scheme-tile\(active ? " active" : "")") {
                                Span(class: "scheme-dots") {
                                    for d in entry.swatch.dropFirst() {
                                        Span(class: "scheme-dot") {}
                                            .attribute("style", "background:\(d)")
                                    }
                                }
                                Span(class: "scheme-name") { Text(entry.label) }
                            }
                            .data("scheme-choice", entry.id)
                            .title(entry.label)
                            .aria(.pressed(active ? .yes : .no))
                            .attribute("style", "--sw-accent:\(accent)")])
                        }
                    }
                    .wire("scheme-pick")
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
                                .aria(.pressed(active ? .yes : .no))
                        }
                    }
                    .wire("activity-display")
                }
                Div(class: "set-row set-row-stack-lg") {
                    Div(class: "set-label") { Text("Sidebar tabs") }
                    Div(class: "side-tab-chips") {
                        for key in chipKeys {
                            let label = tabDefs.first { $0.key == key }?.label ?? key
                            let on = !settings.hiddenSidebarTabs.contains(key)
                            // UX-13: real buttons (keyboard-operable) with a visible
                            // pressed state; the off chip is dimmed and labels itself "Hidden".
                            ErasedViews([ArcButton(id: "st-\(enc(key))",
                                      class: "side-tab-chip\(on ? " on" : " off")") {
                                Span { Text(label) }
                                if !on {
                                    Emphasis("Hidden").class("chip-hint")
                                }
                            }
                            .value("st-\(enc(key))")
                            .aria(.pressed(on ? .yes : .no))
                            .data("no-restore", "")
                            .attribute("draggable", "true")])
                        }
                    }
                    .wire("side-tab-chips")
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
                        .wire("set-think", on: .change)
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
                .wire("modelcfg-list")
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
                        ErasedViews([auxiliaryRow(task)])
                    }
                }
            }
        }
    }

    private func modelConfigAddForm() -> some WebUI.View {
        Form(method: nil, id: "modelcfg-add-form", class: "form-grid form-sep") {
            Div(class: "form-grid-3") {
                WebUIField(label: "Name", controlID: "mc-name") {
                    Input(field: "mc-name", placeholder: "deepseek-v4-flash",
                          type: nil,
                          attributes: [("data-component-id", "mc-name"),
                                       ("autocomplete", "off"), ("spellcheck", "false")])
                }
                WebUIField(label: "Model", controlID: "mc-model") {
                    Input(field: "mc-model", placeholder: "deepseek-v4-flash",
                          type: nil,
                          attributes: [("data-component-id", "mc-model"),
                                       ("autocomplete", "off"), ("spellcheck", "false")])
                }
                WebUIField(label: "Provider", controlID: "mc-provider") {
                    Input(field: "mc-provider", placeholder: "custom",
                          type: nil,
                          attributes: [("data-component-id", "mc-provider"),
                                       ("autocomplete", "off"), ("spellcheck", "false")])
                }
            }
            WebUIField(label: "Base URL", controlID: "mc-baseurl") {
                Input(field: "mc-baseurl",
                      placeholder: "https://api.openai.com/v1", type: nil,
                      attributes: [("data-component-id", "mc-baseurl"),
                                   ("autocomplete", "off"), ("spellcheck", "false")])
            }
            Div(class: "form-grid-2") {
                WebUIField(label: "API key (optional)", controlID: "mc-apikey") {
                    Input(field: "mc-apikey", placeholder: "sk-…",
                          type: .password,
                          attributes: [("data-component-id", "mc-apikey"),
                                       ("autocomplete", "new-password"),
                                       ("spellcheck", "false")])
                }
                WebUIField(label: "Context length (optional)", controlID: "mc-ctx") {
                    Input(field: "mc-ctx", placeholder: "128000",
                          type: .text,
                          attributes: [("data-component-id", "mc-ctx"),
                                       ("autocomplete", "off")])
                }
                WebUIField(label: "Max output tokens (optional)", controlID: "mc-maxtok") {
                    Input(field: "mc-maxtok", placeholder: "32768",
                          type: .text,
                          attributes: [("data-component-id", "mc-maxtok"),
                                       ("autocomplete", "off")])
                }
            }
            Div(class: "row-actions-main row-actions-flush") {
                ArcButton("Add configuration", class: "primary-btn", type: .submit)
            }
        }
        .data("component-id", "modelcfg-add-form")
    }

    /// one auxiliary task: either the inline editor (when it is the task being
    /// edited) or its summary row. the summary text is the five-way fallback the
    /// overrides allow, and `Main model` when nothing is set.
    private func auxiliaryRow(_ task: AuxiliaryTask) -> some WebUI.View {
        Group {
            if auxEditingTask == task.key {
                auxiliaryEditingHTML(task)
            } else {
                auxiliarySummaryHTML(task)
            }
        }
    }

    /// the inline editor for one auxiliary task. a plain function body, so
    /// the staging fallbacks stay ordinary `if`s outside the builder.
    private func auxiliaryEditingHTML(_ task: AuxiliaryTask) -> some WebUI.View {
        let ov = arcConfig.auxiliary.override(for: task)
        let has = ov?.isSet == true
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
                                WebUIDropdown(isOpen: auxConfigPickerOpen) {
                                    ArcButton(id: "auxmc-toggle-\(task.key)",
                                              component: "auxmc-toggle", class: "dd-trigger") {
                                        Span(class: "dd-trigger-label") { Text(triggerLabel) }
                                        WebUIIcon(.chevronDown, size: .small)
                                    }
                                    .title("Auxiliary model configuration")
                                } panel: {
                                    // only `isOpen` goes to the component: this trigger
                                    // is the boundary, and `id:`/`onSelect:` here are
                                    // register-only (a second handler for the same id).
                                    //
                                    // the panel carries no routing attributes of its own,
                                    // so the picker's wire rides one plain wrapper inside it
                                    // and the rows keep dispatching on `targetId`.
                                    Div {
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
                                                ErasedViews([ddRow(id: "auxmc-\(task.key)-\(enc(c.name))") {
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
                                                }])
                                            }
                                        }
                                    }
                                    .wire("auxmc")
                                }
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
                    .wire("aux-edit")
                }
                .data("component-id", "aux-form")
            }
        }
    }

    /// one auxiliary task's summary row.
    private func auxiliarySummaryHTML(_ task: AuxiliaryTask) -> some WebUI.View {
        let ov = arcConfig.auxiliary.override(for: task)
        let has = ov?.isSet == true

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
            .wire("aux-edit")
        }
            .title(task.detail)
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
                    .title(workspacePath(for: activeSessionID))
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

    func kanbanPanel() -> some WebUI.View {
        Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Kanban") }
                Div(class: "panel-actions") {
                    ArcButton(id: "kb-addcol", component: "kb-addcol", class: "plus-btn") {
                        if addingColumn {
                            WebUIIcon(.x, size: .small)
                        } else {
                            WebUIIcon(.plus, size: .small)
                        }
                    }
                    .title(addingColumn ? "Cancel" : "Add column")
                }
            }
            Div(class: "panel-body") {
                if addingColumn {
                    Form(action: "", method: nil, id: "kb-addcol-form", class: "cat-add-form") {
                        Input(field: "kb-addcol-name",
                              placeholder: "Column name", type: .text,
                              attributes: [
                                ("data-component-id", "kb-addcol-name"),
                                ("autofocus", ""),
                              ])
                        Input(name: "kb-addcol-color", type: .hidden,
                              attributes: [
                                ("id", "kb-addcol-color"),
                                ("class", "color-value"),
                                ("value", AppState.palette[0]),
                              ])
                        Div(class: "cat-swatches") {
                            for (j, c) in AppState.palette.enumerated() {
                                ErasedViews([ArcButton(id: nil, component: nil, class: "cat-swatch\(j == 0 ? " sel" : "")") {}
                                    .data("color", c)
                                    .attribute("style", "background:\(c)")])
                            }
                        }
                        Div(class: "cat-add-actions") {
                            ArcButton("Add", class: "primary-btn", type: .submit)
                            ArcButton("Cancel", id: "kb-addcol-cancel", component: nil, class: "ghost-btn")
                        }
                    }
                    .data("component-id", "kb-addcol-form")
                }
                for col in settings.kanbanColumns {
                    let cid = enc(col.id)
                    let count = settings.kanbanCards.filter { $0.columnID == col.id }.count
                    Div(class: "list-row") {
                        Div(class: "kb-pcol") {
                            Span(class: "cat-dot") {}
                                .attribute("style", "background:\(col.color)")
                            Span(class: "lr-name") { Text(col.name) }
                            Span(class: "lr-sub") { Text("\(count) card\(count == 1 ? "" : "s")") }
                        }
                        .attribute("style", "flex:1")
                        Div(class: "row-actions") {
                            // a column delete arms first (matching the board's
                            // column header), so one stray click never drops a
                            // column and its cards.
                            ArcButton(id: "kb-pdel-\(cid)", component: nil,
                                      class: confirmColumn == col.id ? "sess-confirm" : "icon-mini danger") {
                                if confirmColumn == col.id {
                                    Text(" Confirm?")
                                } else {
                                    WebUIIcon(.x, size: .small)
                                }
                            }
                            .title("Delete column")
                        }
                    }
                }
                if settings.kanbanColumns.isEmpty {
                    Div(class: "empty-hint") { Text("No columns — press + to add one.") }
                }
            }
            .data("component-id", "kanban")
            .data("event", "click")
        }
    }

    /// Board: one scrollable row of columns with their cards (arc-style).
    func kanbanMain() -> some WebUI.View {
        Group {
            if settings.kanbanColumns.isEmpty {
                Div(class: "main-view") {
                    Div(class: "blank") {
                        Div(class: "big") { WebUIIcon(.columns, size: .extraLarge) }
                        Div { Text("No columns yet — add one in the panel.") }
                    }
                }
                .attribute("style", "justify-content:center")
            } else {
                Div(class: "kanban-main main-view") {
                    Div(class: "kanban-board") {
                        for col in settings.kanbanColumns {
                            ErasedViews([kanbanColumnHTML(col)])
                        }
                    }
                    .data("component-id", "kanban")
                    .data("event", "click")
                }
                .attribute("style", "padding:0")
            }
        }
    }

    func kanbanColumnHTML(_ col: KBColumn) -> some WebUI.View {
        let cid = enc(col.id)
        let cards = settings.kanbanCards.filter { $0.columnID == col.id }
        let armed = confirmColumn == col.id
        let addErr = kanbanAddError
        // the error node exists even while empty: the client fills
        // `#kb-addcard-err` after a rejected submit.
        let describedBy: [(String, String)] = addErr == nil ? [] : [("aria-describedby", "kb-addcard-err")]
        return Div(class: "kb-col") {
            Div(class: "kb-col-head") {
                Span(class: "kb-col-name") { Text(col.name) }
                Span(class: "kb-col-count") { Text("\(cards.count)") }
                Div(class: "kb-col-actions") {
                    ArcButton(id: "kb-rencol-\(cid)", component: nil, class: "icon-mini") {
                        WebUIIcon(.edit, size: .small)
                    }
                    .title("Rename column")
                    .data("colid", col.id)
                    ArcButton(id: "kb-bdel-\(cid)", component: nil,
                              class: armed ? "sess-confirm" : "icon-mini danger") {
                        if armed {
                            Text("Confirm?")
                        } else {
                            WebUIIcon(.x, size: .small)
                        }
                    }
                    .title("Delete column")
                }
            }
            .attribute("style", "--colc:\(col.color)")
            Div(class: "kb-cards") {
                if cards.isEmpty {
                    Div(class: "kb-empty") { Text("No cards") }
                } else {
                    for card in cards {
                        ErasedViews([kanbanCardHTML(card)])
                    }
                }
            }
            if addingCardColumnID == col.id {
                Form(action: "", method: nil, id: "kb-addcard-form", class: "kb-addcard-form") {
                    Input(field: "kb-addcard-name",
                          placeholder: "Card title", type: .text,
                          attributes: [
                            ("data-component-id", "kb-addcard-name"),
                            ("class", addErr == nil ? "text-input" : "text-input input-invalid"),
                            ("aria-invalid", addErr == nil ? "false" : "true"),
                            ("data-focus-after-patch", ""),
                          ] + describedBy)
                    Span { Text(addErr ?? "") }
                        .id("kb-addcard-err")
                        .class("inline-err")
                    Input(name: "kb-addcard-col", type: .hidden,
                          attributes: [("value", col.id)])
                    Div(class: "cat-add-actions") {
                        ArcButton("Add", class: "primary-btn", type: .submit)
                        ArcButton("Cancel", id: "kb-addcard-cancel", component: nil, class: "ghost-btn")
                    }
                    .attribute("style", "justify-content:flex-end")
                }
                .data("component-id", "kb-addcard-form")
            } else {
                ArcButton(id: "kb-addcard-\(cid)", component: nil, class: "kb-addcard") {
                    Text("+ Add card")
                }
            }
        }
    }

    func kanbanCardHTML(_ card: KBCard) -> some WebUI.View {
        let encc = enc(card.id)
        let idx = settings.kanbanColumns.firstIndex { $0.id == card.columnID } ?? 0
        // Two-step delete, matching the column header: the first click arms the
        // card and the button becomes "Confirm?" (a single click used to bin it).
        let armed = confirmCard == card.id
        return Div(class: "kb-card") {
            Div(class: "kb-card-title") { Text(trunc(card.title, 70)) }
                .data("cardid", card.id)
            Div(class: "kb-card-actions") {
                ArcButton(id: "kb-edit-\(encc)", component: nil, class: "icon-mini") {
                    WebUIIcon(.edit, size: .small)
                }
                .title("Edit title")
                .data("cardid", card.id)
                if idx > 0 {
                    ArcButton(id: "kb-movel-\(encc)", component: nil, class: "icon-mini") {
                        WebUIIcon(.chevronLeft, size: .small)
                    }
                    .title("Move left")
                }
                if idx < settings.kanbanColumns.count - 1 {
                    ArcButton(id: "kb-mover-\(encc)", component: nil, class: "icon-mini") {
                        WebUIIcon(.chevronRight, size: .small)
                    }
                    .title("Move right")
                }
                ArcButton(id: "kb-del-\(encc)", component: nil,
                          class: armed ? "sess-confirm" : "icon-mini danger") {
                    if armed {
                        Text("Confirm?")
                    } else {
                        WebUIIcon(.x, size: .small)
                    }
                }
                .title("Delete card")
            }
        }
    }

    // MARK: Memory

    func memoryPanel() -> some WebUI.View {
        let items: [(key: String, title: String, sub: String, icon: IconName)] = [
            ("memory", "My Notes", "MEMORY.md", .fileText),
            ("user", "User Profile", "USER.md", .user),
            ("soul", "Agent Soul", "SOUL.md", .star),
            ("context", "Project Context", "AGENTS.md", .folder),
        ]
        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Personal Memory") }
            }
            Div(class: "panel-body") {
                for it in items {
                    ArcButton(id: "mem-open-\(it.key)", component: nil,
                              class: "mem-box\(memoryDoc == it.key ? " active" : "")") {
                        Span(class: "mem-glyph") { WebUIIcon(it.icon, size: .large) }
                        Span(class: "mem-txt") {
                            Span(class: "mem-title") { Text(it.title) }
                            Span(class: "mem-sub") { Text(it.sub) }
                        }
                        Span(class: "mem-arrow") { Text("›") }
                    }
                }
            }
            .data("component-id", "memory")
            .data("event", "click")
        }
    }

    func memoryMain() -> some WebUI.View {
        Group {
            if let doc = memoryDoc {
                let meta = memoryMeta(doc)
                if doc == "context" {
                    let rootPath = workspaceContextURL()?.path ?? panelWorkspacePath()
                    mainScroll {
                        Div(class: "detail-card") {
                            Div(class: "mem-head") {
                                Div {
                                    Heading("Project Context", level: .h1, class: "detail-title")
                                        .attribute("style", "margin:0")
                                    Div(class: "detail-sub") { Text(rootPath) }
                                }
                            }
                            Div(class: "detail-body") {
                                if let url = workspaceContextURL(),
                                   let s = try? String(contentsOf: url, encoding: .utf8) {
                                    TrustedMarkup(mdBox(s), from: .markdown)
                                } else {
                                    Div(class: "empty-hint") {
                                        Div {
                                            Text("No AGENTS.md file was found in this workspace (")
                                            InlineCode(panelWorkspacePath())
                                            Text(").")
                                        }
                                        Div { Text("Project context is read automatically when an AGENTS.md is present.") }
                                    }
                                    .attribute("style", "font-size:1em;padding:18px 6px")
                                }
                            }
                            .attribute("style", "margin-top:14px")
                        }
                    }
                } else if memoryEdit {
                    mainScroll {
                        Form(action: "", method: nil, id: "mem-save-form", class: "detail-card") {
                            Heading("Edit \(meta.file)", level: .h1, class: "detail-title")
                                .attribute("style", "margin:0")
                            Div(class: "detail-sub") { Text(meta.note) }
                            Input(name: "mem-key", type: .hidden, attributes: [("value", doc)])
                            // the raw markdown, escaped by `TextArea` — the editor
                            // edits what the file holds, not its rendered form.
                            TextArea(field: "mem-content", value: memoryContent, rows: 3)
                                .class("mem-textarea")
                                .data("component-id", "mem-content")
                                .attribute("spellcheck", "false")
                            Div(class: "row-actions-main") {
                                ArcButton("Save changes", class: "primary-btn", type: .submit)
                                ArcButton("Cancel", id: "mem-cancel", component: nil, class: "ghost-btn")
                            }
                        }
                        .data("component-id", "mem-save-form")
                    }
                } else {
                    let contentHTML = mdBox(memoryContent)
                    let empty = memoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    mainScroll {
                        Div(class: "detail-card") {
                            Div(class: "mem-head") {
                                Div {
                                    Heading(meta.title, level: .h1, class: "detail-title")
                                        .attribute("style", "margin:0")
                                    Div(class: "detail-sub") { Text("\(meta.file) — \(meta.note)") }
                                }
                                ArcButton(id: "mem-edit", component: "mem-edit", class: "icon-mini") {
                                    WebUIIcon(.edit, size: .small)
                                }
                                .title("Edit \(meta.file)")
                            }
                            Div(class: "detail-body") {
                                if empty {
                                    Div(class: "empty-hint") {
                                        Text("\(meta.file) is empty. Press ")
                                        WebUIIcon(.edit, size: .small)
                                        Text(" to start writing.")
                                    }
                                } else {
                                    TrustedMarkup(contentHTML, from: .markdown)
                                }
                            }
                            .attribute("style", "margin-top:14px")
                        }
                    }
                }
            } else {
                Div(class: "main-view") {
                    Div(class: "blank") {
                        Div(class: "big") { WebUIIcon(.database, size: .extraLarge) }
                        Div { Text("Select a document from the panel.") }
                    }
                }
                .attribute("style", "justify-content:center")
            }
        }
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

    func logsPanel() -> some WebUI.View {
        let lines = LogCollector.shared.snapshot()
        let info = lines.filter { $0.level == .info }.count
        let warn = lines.filter { $0.level == .warning }.count
        let err = lines.filter { $0.level == .error || $0.level == .critical }.count
        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Logs") }
                ArcButton(id: "log-clear", component: "log-clear", class: "icon-mini") {
                    WebUIIcon(.trash, size: .small)
                }
                .title("Clear logs")
            }
            Div(class: "panel-body") {
                Div(class: "log-stats") {
                    Span(class: "log-stat") {
                        Span(class: "dot dot-info") {}
                        Text("\(info) info")
                    }
                    .title("Info lines")
                    Span(class: "log-stat") {
                        Span(class: "dot dot-warn") {}
                        Text("\(warn) warn")
                    }
                    .title("Warning lines")
                    Span(class: "log-stat") {
                        Span(class: "dot dot-err") {}
                        Text("\(err) error")
                    }
                    .title("Error lines")
                }
                Div(class: "log-chips") {
                    for (lvl, label) in [("all", "All"), ("info", "Info"), ("warn", "Warn"), ("error", "Error")] {
                        let active = logFilter == lvl
                        ArcButton(label, id: "log-filter-\(lvl)", component: nil, class: "chip-btn\(active ? " active" : "")")
                            .aria(.pressed(active ? .yes : .no))
                    }
                }
                .wire("log-filter")
                Div(class: "log-panel-note") { Text("In-app log stream. Captured lines from this process appear here instead of the terminal.") }
            }
        }
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

    func logLineHTML(_ line: LogLine) -> some WebUI.View {
        Div(class: "log-line \(logLevelClass(line.level))") {
            Span(class: "log-time") { Text(logTime(line.time)) }
            Span(class: "log-lvl") { Text(line.level.rawValue) }
            Span(class: "log-msg") { Text(line.text) }
        }
    }

    /// The filtered, newest-last log body, capped for a responsive live box.
    func logLinesHTML(max: Int = 500) -> some WebUI.View {
        let all = LogCollector.shared.snapshot().filter { logMatches($0) }
        let shown = all.suffix(max)
        return Group {
            if shown.isEmpty {
                Div(class: "empty-hint") { Text("No log lines yet.") }
            } else {
                for line in shown {
                    ErasedViews([logLineHTML(line)])
                }
            }
        }
    }

    /// The `#log-lines` box — the live fragment target. This is the only place
    /// the element is emitted: fragment payloads replace the element they name
    /// (outerHTML semantics), so `logsMain` and both push sites render it here
    /// rather than each spelling the wrapper string.
    func logLinesBox() -> some WebUI.View {
        Div(id: "log-lines", class: "logs-lines") {
            logLinesHTML()
        }
    }

    func logsMain() -> some WebUI.View {
        let total = LogCollector.shared.count
        return Div(class: "logs-view") {
            Div(class: "logs-box") {
                Div(class: "logs-head") {
                    Span(class: "logs-title") { Text("Live log stream") }
                    Span(class: "logs-meta") { Text("\(total) lines in buffer") }
                }
                logLinesBox()
            }
        }
    }

    /// Live fragment: only the log box, so the view updates in place while the
    /// server streams new lines.
    func liveLogFragments() async -> [FragmentUpdate] {
        [fragment("log-lines", logLinesBox())]
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
    func workspaceDockHTML() -> some WebUI.View {
        let open = workspaceOpen
        let title = open ? "Collapse workspace" : "Open workspace"
        // UX-30: while the panel is open, exactly ONE close control is visible
        // — the header ✕. The dock's collapse tab used to float at the panel's
        // mid-right edge over the file rows (two competing close affordances).
        // When open the tab is hidden, but the anchored wrapper keeps its
        // `data-component-id` — the engine's routing anchor is stable in both
        // states (UX-03); when closed the dock returns as the open handle.
        return Div(id: "ws-dock") {
            ArcButton(id: "w-dock", component: nil,
                      class: open ? "ws-dock-btn ws-dock-open" : "ws-dock-btn",
                      type: .button, hidden: open) {
                if open {
                    WebUIIcon(.chevronRight, size: .medium)
                } else {
                    WebUIIcon(.chevronLeft, size: .medium)
                }
            }
            .title(title)
        }
        .wire(ComponentID("workspace"))
    }

    /// The right-hand workspace panel (same width as the left panel).
    func workspacePanelHTML() -> some WebUI.View {
        // ws-enter plays the slide-in animation only on the open transition
        // (set right after toggling open); the flag is consumed/reset here so
        // background re-renders of an already-open panel don't re-animate.
        let anim = wsEnterAnim ? " ws-enter" : ""
        wsEnterAnim = false
        // `hidden` is a CLASS on this element, not the attribute: the sheet
        // hides the panel with `.ws-panel.hidden`, which an attribute could not
        // win against (`.ws-panel` sets `display: flex`).
        let cls = "ws-panel" + (workspaceOpen ? "" : " hidden") + anim
        return Div(id: "ws-panel", class: cls) {
            Div(class: "panel-head ws-head") {
                Span(class: "panel-title") { Text("Workspace") }
                Div(class: "ws-tools") {
                    ArcButton(id: "w-new", component: nil, class: "icon-mini") {
                        WebUIIcon(.plus, size: .small)
                    }
                    .title("New file")
                    ArcButton(id: "w-newfolder", component: nil, class: "icon-mini") {
                        WebUIIcon(.folder, size: .small)
                    }
                    .title("New folder")
                    ArcButton(id: "w-upload", component: nil, class: "icon-mini") {
                        WebUIIcon(.upload, size: .small)
                    }
                    .title("Upload files or drop them here")
                    Div(class: "ws-menu-wrap") {
                        ArcButton(id: "w-menu", component: nil, class: "icon-mini") {
                            Text("\u{22EE}")   // ⋮ — Text escapes, so emit the char
                        }
                        .title("Workspace options")
                        Div(id: "ws-menu", class: "chat-menu ws-menu") {
                            ArcButton(id: "w-hidden", component: nil,
                                      class: showHiddenFiles ? "menu-sel" : "") {
                                Span(class: "chk") {
                                    if showHiddenFiles {
                                        WebUIIcon(.checkSquare, size: .small)
                                    } else {
                                        WebUIIcon(.square, size: .small)
                                    }
                                }
                                Text("Show hidden files")
                            }
                        }
                    }
                    .wire(ComponentID("workspace"))
                    // the header ✕ is the panel's single close control while open
                    ArcButton(id: "w-close", component: nil, class: "icon-mini") {
                        WebUIIcon(.x, size: .small)
                    }
                    .title("Close workspace")
                }
                .wire(ComponentID("workspace"))
            }
            if wsNewMode != "" {
                Form(action: "", method: nil, id: "ws-new-form", class: "cat-add-form") {
                    Div(class: "detail-sub") {
                        Text(wsNewMode == "file" ? "New file" : "New folder")
                    }
                    .attribute("style", "margin-bottom:6px")
                    Input(field: "ws-new-name",
                          placeholder: wsNewMode == "file" ? "file name (e.g. notes.txt)" : "folder name",
                          attributes: [
                            ("data-component-id", "ws-new-name"),
                            ("autofocus", ""),
                          ])
                    Input(name: "ws-new-kind", type: .hidden, value: wsNewMode)
                    Div(class: "cat-add-actions") {
                        ArcButton("Create", class: "primary-btn", type: .submit)
                        ArcButton("Cancel", id: "ws-new-cancel", component: nil, class: "ghost-btn")
                    }
                    .attribute("style", "margin-top:8px")
                }
                .data("component-id", "ws-new-form")
            }
            wsTreeShell(workspaceBodyHTML())
        }
    }

    /// the `#ws-tree` element: the routing anchor every live patch keys on, with
    /// whatever body it currently shows. the static render passes the panel body
    /// (a preview, or the cached tree); the live scan passes the listing it just
    /// measured. one wrapper, so the anchor and the wire cannot drift apart.
    func wsTreeShell(_ body: some WebUI.View) -> some WebUI.View {
        Div(id: "ws-tree", class: "ws-body") { body }
            .data("root", panelWorkspacePath())
            .wire(ComponentID("workspace"))
    }

    /// The workspace panel body: a file preview pane when a file is open,
    /// otherwise the breadcrumb + file tree (Hermes parity: the right panel
    /// shows both the tree and a preview of the selected file).
    func workspaceBodyHTML() -> some WebUI.View {
        // Never scan the directory for a hidden panel: `workspacePanelHTML`
        // is rendered on every shell build, and the tree walk is synchronous
        // disk I/O — doing it when the panel isn't visible caused the lag
        // spikes. The scan happens on first render after the panel opens.
        Group {
            if workspaceOpen {
                if let path = previewPath {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    let isMarkdown = path.lowercased().hasSuffix(".md")
                    Div(class: "ws-preview") {
                        Div(class: "ws-preview-head") {
                            ArcButton(id: "w-preview-back", component: nil, class: "icon-mini") {
                                WebUIIcon(.chevronLeft, size: .small)
                            }
                            .title("Back to files")
                            Span(class: "ws-preview-name") { Text(name) }
                                .title(path + (isMarkdown ? " (markdown)" : ""))
                            ArcButton(id: "ws-preview-copy", component: nil, class: "icon-mini") {
                                WebUIIcon(.copy, size: .small)
                            }
                            .title("Copy content")
                        }
                        Div(class: "ws-preview-scroll") {
                            // UX-12: wrap text previews (pre-wrap) and render markdown
                            // for .md files — the dock is for glancing, raw markdown
                            // syntax is not readable. Code keeps `white-space: pre`
                            // (via the monospace pre-wrap body, which still wraps).
                            if let content = previewContent {
                                if isMarkdown {
                                    Div(class: "ws-preview-body") {
                                        TrustedMarkup(renderMarkdown(content), from: .markdown)
                                    }
                                } else {
                                    Element(.pre, class: "ws-preview-body") { Text(content) }
                                }
                            } else {
                                // UX-12: an unreadable preview keeps its reason on screen —
                                // `previewNote` names the cause (binary, too large, not utf-8,
                                // read failure); an empty <pre> told the reader nothing.
                                Div(class: "empty-hint") { Text(previewNote ?? "No preview.") }
                            }
                        }
                    }
                } else {
                    Div(class: "ws-path") { Text(panelWorkspacePath()) }
                        .title(panelWorkspacePath())
                    workspaceTreeHTML()
                }
            }
        }
    }

    func workspaceTreeHTML() -> some WebUI.View {
        // Render-path cache: repeated shell re-renders of an OPEN panel reuse
        // the last listing instead of rescanning the directory. Keyed by
        // (path, showHidden, expanded set), so switching the workspace,
        // toggling hidden files, or expanding/collapsing a folder all change
        // the key and force a rescan; content mutations clear the cache.
        //
        // the cache holds the built VIEW, not its bytes: a tree is a `Group` of
        // rows, so the fixed point a cache needs is the existential — no second
        // string seam, and no re-render of the rows it already built.
        let path = panelWorkspacePath()
        let key = wsTreeCacheKey(path: path)
        if workspaceTreeCacheKey != key {
            workspaceTreeCacheView = Self.renderWorkspaceTree(
                root: URL(fileURLWithPath: path),
                showHidden: showHiddenFiles,
                expanded: expandedPaths
            )
            workspaceTreeCacheKey = key
        }
        return Group {
            if let cached = workspaceTreeCacheView { ErasedViews([cached]) }
        }
    }

    /// Fresh (non-cached) listing, used by the live workspace scanner so it
    /// detects real filesystem changes rather than serving the render cache.
    /// Stays `-> String`: the scanner diffs bytes against the last pushed
    /// listing, so it wants the wire text, not a view.
    func freshWorkspaceTreeHTML() -> String {
        render(Self.renderWorkspaceTree(
            root: URL(fileURLWithPath: panelWorkspacePath()),
            showHidden: showHiddenFiles,
            expanded: expandedPaths
        ))
    }

    /// Clear the render-path tree cache (called on open + on mutations).
    func clearWorkspaceTreeCache() {
        workspaceTreeCacheKey = nil
        workspaceTreeCacheView = nil
    }

    private func wsTreeCacheKey(path: String) -> String {
        "\(path)|\(showHiddenFiles)|\(expandedPaths.sorted().joined(separator: "\u{1F}"))"
    }

    /// The workspace file tree, bounded (depth ≤ 8, ≤ 600 entries). Reads
    /// `.isDirectory` once per entry and sorts by the cached bool — the old
    /// code re-stat'ed every entry on every sort comparison (O(n·log n) stats),
    /// the dominant cost of an otherwise small listing.
    ///
    /// the walk recurses over the ENTRY LIST, not over a view type: a folder
    /// appends its own row and then its children to the same array, so the
    /// result is one flat `[any View]` and the recursion needs neither
    /// `AnyView` nor a recursive view struct to express.
    static func renderWorkspaceTree(root: URL, showHidden: Bool, expanded: Set<String>) -> some WebUI.View {
        var rows: [any WebUI.View] = []
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
                    rows.append(
                        ArcButton(id: "w-toggle-\(encPath)", component: nil, class: "ws-row") {
                            Span(class: "ws-caret") {
                                if isExp {
                                    WebUIIcon(.chevronDown, size: .small)
                                } else {
                                    WebUIIcon(.chevronRight, size: .small)
                                }
                            }
                            Span(class: "ws-ic") { WebUIIcon(.folder, size: .small) }
                            Span(class: "ws-name") { Text(name) }
                        }
                        .attribute("style", "padding-left:\(pad)px")
                        .title(rp)
                    )
                    if isExp { walk(entry, prefix: rp, depth: depth + 1) }
                } else {
                    rows.append(
                        ArcButton(id: "w-file-\(encPath)", component: nil, class: "ws-row") {
                            Span(class: "ws-ic") { WebUIIcon(.file, size: .small) }
                            Span(class: "ws-name") { Text(name) }
                        }
                        .attribute("style", "padding-left:\(pad + 4)px")
                        .title(rp)
                    )
                }
            }
        }
        walk(root, prefix: "", depth: 0)
        if rows.isEmpty { rows.append(Div(class: "empty-hint") { Text("This workspace is empty.") }) }
        return Group { rows }
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
