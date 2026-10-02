import ArcAgentCore
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
    func appShell() -> String {
        let iconbar = iconbarHTML()
        let panel = panelHTML()
        let main = mainContentHTML()

        return """
        <div id="app" data-size="\(esc(settings.textSize))">
        \(topbarHTML())
        <div id="app-body">
        <aside id="iconbar">\(iconbar)</aside>
        \(panel)
        \(main)
        \(workspaceDockHTML())
        \(workspacePanelHTML())
        </div>
        <div id="modal-root">\(modalRootHTML())</div>
        <div id="toasts" data-component-id="toast-dismiss" data-event="click">\(toastsHTML())</div>
        </div>
        """
    }

    /// Thin full-width bar across the top of the screen (arc-style): a
    /// colorless lightning mark centred with the current chat's name beside it.
    func topbarHTML() -> String {
        let name = esc(topbarLabel())
        let bolt = WebUIIcon(.zap, size: .medium).render()
        return """
        <header id="topbar">
          <div class="topbar-center">
            <span class="topbar-bolt">\(bolt)</span>
            <span class="topbar-name">\(name)</span>
          </div>
        </header>
        """
    }

    /// The chat name the top bar shows: the active conversation's title when
    /// one is open, otherwise a short app label.
    func topbarLabel() -> String {
        if activeView == .chat, let s = activeSession() {
            let t = sessionTitle(s)
            return t.isEmpty ? "ARC Agent" : t
        }
        return "ARC Agent"
    }

    func toastsShell() -> String {
        "<div id=\"toasts\" data-component-id=\"toast-dismiss\" data-event=\"click\">\(toastsHTML())</div>"
    }

    func iconbarHTML() -> String {
        // Chat is always first; the rest follow settings.sidebarTabs order.
        // Hidden tabs are simply absent; Chat and Settings can never be hidden.
        var topIDs: [ViewID] = [.chat]
        for key in settings.sidebarTabs {
            if let v = ViewID(rawValue: key), v != .chat, v != .settings, !topIDs.contains(v),
               !settings.hiddenSidebarTabs.contains(key) {
                topIDs.append(v)
            }
        }
        let top = topIDs
            .map { v -> String in
                let cls = v == activeView ? "icon-btn active" : "icon-btn"
                return btn("nav-\(v.rawValue)", "nav-\(v.rawValue)", cls, v.icon, " title=\"\(v.title)\" data-tip=\"\(v.tip)\"")
            }
            .joined()
        let settingsBtn = btn("nav-settings", "nav-settings",
                              activeView == .settings ? "icon-btn active" : "icon-btn",
                              ViewID.settings.icon, " title=\"Settings\" data-tip=\"Settings\"")
        return """
        <div class="iconbar-top" style="display:flex;flex-direction:column;gap:6px;align-items:center;">\(top)</div>
        <div class="iconbar-bottom" style="display:flex;flex-direction:column;gap:6px;align-items:center;">\(settingsBtn)</div>
        """
    }

    func toastsHTML() -> String {
        let items = toasts.map { t -> String in
            let dot = "<span class=\"toast-dot\"></span>"
            let x = btn("t-\(t.id)", "", "toast-x", WebUIIcon(.x, size: .small).render())
            return "<div class=\"toast \(t.kind)\">\(dot)<span>\(esc(t.text))</span>\(x)</div>"
        }
        return items.joined()
    }

    /// Centered confirmation surfaced when a chat or profile delete is requested.
    func modalHTML() -> String {
        if let pid = confirmProfileDelete,
           let p = profiles.first(where: { $0.name == pid }) {
            let title = trunc(p.title.isEmpty ? p.name : p.title, 48)
            return """
            <div class="modal-overlay" id="modal-overlay">
              <div class="modal-card">
                <h3>Delete profile?</h3>
                <p>The profile “\(esc(title))” will be permanently deleted. This cannot be undone.</p>
                <div class="modal-actions" data-component-id="modal" data-event="click">
                  <button type="button" id="modal-cancel" class="ghost-btn">Cancel</button>
                  <button type="button" id="modal-confirm" class="danger-btn">Delete</button>
                </div>
              </div>
            </div>
            """
        }
        guard let mid = confirmDeleteID,
              let s = sessions.first(where: { $0.id == mid }) else {
            return ""
        }
        let title = trunc(sessionTitle(s), 48)
        return """
        <div class="modal-overlay" id="modal-overlay">
          <div class=\"modal-card\">
            <h3>Delete conversation?</h3>
            <p>The chat “\(esc(title))” will be permanently deleted. This cannot be undone.</p>
            <div class=\"modal-actions\" data-component-id=\"modal\" data-event=\"click\">
              <button type=\"button\" id=\"modal-cancel\" class=\"ghost-btn\">Cancel</button>
              <button type=\"button\" id=\"modal-confirm\" class=\"danger-btn\">Delete</button>
            </div>
          </div>
        </div>
        """
    }

    /// Right-click menu for a category chip: rename, color palette, divider,
    /// and a red delete action. Rendered over a transparent click-to-close
    /// backdrop at the mouse's viewport position.
    func categoryMenuHTML() -> String {
        guard let menu = categoryMenu,
              let cat = settings.chatCategories.first(where: { $0.id == menu.categoryID }) else {
            return ""
        }
        let left = max(8, min(menu.x, 1080))
        let top = max(8, min(menu.y, 760))
        let cid = enc(cat.id)
        let swatches = AppState.palette.map { c in
            let sel = c == cat.color ? " sel" : ""
            return """
            <button type="button" id="cm-color-\(c.hasPrefix("#") ? String(c.dropFirst()) : c)" data-color="\(c)" class="menu-swatch\(sel)" style="background:\(c)" aria-label="\(c)"></button>
            """
        }.joined()
        let head: String
        if categoryMenuRename {
            head = """
            <form class="ctx-rename" id="cm-rename-form-\(cid)" data-prevent-enter="false">
              <input id="cat-rename-input" name="cat-rename-input" value="\(esc(cat.name))" autofocus>
              <button type="submit" class="primary-btn">Save</button>
            </form>
            """
        } else {
            head = btn("cm-rename-\(cid)", "", "ctx-item", "✎ Rename")
        }
        return """
        <div class="ctx-backdrop" id="cat-menu-close" data-component-id="cat-menu-close"></div>
        <div class="ctx-menu" data-component-id="cat-menu" id="cat-menu" style="left:\(left)px;top:\(top)px">
          \(head)
          <div class="ctx-swatches">
            <div class="ctx-label">Color</div>
            <div class="ctx-swatch-row">\(swatches)</div>
          </div>
          <div class="ctx-divider"></div>
          <button type="button" id="cm-del-\(cid)" class="ctx-item ctx-danger">Delete</button>
        </div>
        """
    }

    /// Everything rendered in #modal-root (delete confirmation + category menu).
    func modalRootHTML() -> String {
        modalHTML() + categoryMenuHTML()
    }

    // MARK: - Panel

    func panelHTML() -> String {
        let id = "panel"
        switch activeView {
        case .chat:
            return "<div id=\"\(id)\">\(chatPanel())</div>"
        case .skills:
            return "<div id=\"\(id)\">\(skillsPanel())</div>"
        case .profiles:
            return "<div id=\"\(id)\">\(profilesPanel())</div>"
        case .tools:
            return "<div id=\"\(id)\">\(toolsPanel())</div>"
        case .workspaces:
            return "<div id=\"\(id)\">\(workspacesPanel())</div>"
        case .github:
            return "<div id=\"\(id)\">\(githubPanel())</div>"
        case .kanban:
            return "<div id=\"\(id)\">\(kanbanPanel())</div>"
        case .memory:
            return "<div id=\"\(id)\">\(memoryPanel())</div>"
        case .insights:
            return "<div id=\"\(id)\">\(insightsPanel())</div>"
        case .settings:
            return "<div id=\"\(id)\">\(settingsPanel())</div>"
        case .logs:
            return "<div id=\"\(id)\">\(logsPanel())</div>"
        case .tasks:
            return "<div id=\"\(id)\">\(tasksPanel())</div>"
        case .todos:
            return "<div id=\"\(id)\">\(chatPanel(todos: true))</div>"
        }
    }

    // MARK: Chat panel

    func chatPanel(todos: Bool = false) -> String {
        let newBtn = btn("chat-new", "chat-new", "plus-btn", WebUIIcon(.plus, size: .medium).render(), " title=\"New chat\"")
        let archBtn = btn("chat-showarch", "chat-showarch", "icon-btn" + (showArchived ? " active" : ""), WebUIIcon(.archive, size: .medium).render(), " title=\"Show archived\"")
        // The Todos page reuses this panel but stripped down: title "Todos",
        // no archived toggle, no "+" new chat, minimal rows.
        let actions = todos ? "" : archBtn + newBtn
        let head = """
        <div class="panel-head">
          <span class="panel-title">\(todos ? "Todos" : "Chats")</span>
          <div class="panel-actions">\(actions)</div>
        </div>
        <div class="filter-bar">
          <span class="filter-ico">\(WebUIIcon(.search, size: .small).render())</span>
          <input id="chat-search-input" data-component-id="chat-search-input" type="text" placeholder="Filter conversations…" value="\(esc(chatFilter))">
        </div>
        \(categoryCloudHTML())
        \(todos ? "" : """
        <button type="button" id="chat-showarch-link" data-component-id="chat-showarch" class="arch-link" title="Toggle archived">
          <span class="arch-ico">\(WebUIIcon(showArchived ? .chevronDown : .chevronRight, size: .small).render())</span><span>\(showArchived ? " Hide archived conversations" : " Show archived conversations")</span>
        </button>
        """)
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
        let sorted = ordered.sorted { a, b in
            let ab = bookmarks.contains(a.id), bb = bookmarks.contains(b.id)
            if ab != bb { return ab }
            return a.updatedAt > b.updatedAt
        }
        // arc parity: chats are bucketed into Today / Last Week / Older
        // (youngest first within each bucket); each bucket is collapsible.
        let buckets: [(String, String)] = [("today", "Today"), ("week", "Last Week"), ("older", "Older")]
        var grouped: [String: [Session]] = [:]
        for s in sorted { grouped[bucketKey(s.updatedAt), default: []].append(s) }
        for (key, title) in buckets {
            if let list = grouped[key], !list.isEmpty {
                rows.append(groupHTML(key: key, title: title, sessions: list, todos: todos))
            }
        }
        if rows.isEmpty {
            let msg = todos ? "No chats yet."
                : (showArchived ? "No archived chats." : "No chats yet — press + to start one.")
            rows.append("<div class=\"empty-hint\">\(msg)</div>")
        }
        return """
        \(head)
        <div class="panel-body" id="sess-list-body" data-component-id="sess-list" data-event="click">
          \(rows.joined())
        </div>
        """
    }

    /// Search + category filter controls above the chat list: the "All" /
    /// "Unassigned" chips, one rounded chip per user category (name + color
    /// dot), a "+" chip that opens an inline create form, plus the optional
    /// delete ✕ per chip while the create form is open.
    func categoryCloudHTML() -> String {
        let allActive = activeCategory == "all" ? " active" : ""
        let unActive = activeCategory == "unassigned" ? " active" : ""
        var chips = """
        <div class="cat-bar" data-component-id="cat-pick" data-event="click">
          <button type="button" id="cat-all" class="cat-chip\(allActive)">All</button>
          <button type="button" id="cat-unassigned" class="cat-chip\(unActive)">Unassigned</button>
        """
        for cat in settings.chatCategories {
            let cid = enc(cat.id)
            let active = activeCategory == cat.id ? " active" : ""
            if addingCategory {
                // Manage mode: container chip with a filter button + delete ✕ as
                // SIBLINGS (nested <button> elements would be split by the HTML
                // parser and break the layout).
                chips += """
                <div class="cat-chip\(active)">
                  <button type="button" id="cat-\(cid)" class="cat-chip-btn">
                    <span class="cat-dot" style="background:\(cat.color)"></span>
                    <span>\(esc(cat.name))</span>
                  </button>
                  \(btn("cat-del-\(cid)", "", "chip-x", WebUIIcon(.x, size: .small).render(), " title=\"Delete category\""))
                </div>
                """
            } else {
                chips += """
                <button type="button" id="cat-\(cid)" class="cat-chip\(active)">
                  <span class="cat-dot" style="background:\(cat.color)"></span>
                  <span>\(esc(cat.name))</span>
                </button>
                """
            }
        }
        let plusLabel = addingCategory ? WebUIIcon(.x, size: .small).render() : WebUIIcon(.plus, size: .small).render()
        chips += btn("cat-add", "", "cat-chip cat-add", plusLabel, " title=\"" + (addingCategory ? "Cancel" : "Add category") + "\"")
        chips += "</div>"
        if addingCategory {
            let swatches = AppState.palette.enumerated().map { i, c in
                let sel = i == 0 ? " sel" : ""
                return "<button type=\"button\" class=\"cat-swatch\(sel)\" data-color=\"\(c)\" style=\"background:\(c)\" aria-label=\"\(c)\"></button>"
            }.joined()
            chips += """
            <form id="cat-add-form" data-component-id="cat-add-form" class="cat-add-form">
              <input id="cat-name-input" name="cat-name-input" data-component-id="cat-name-input" type="text" placeholder="Category name" autofocus>
              <input type="hidden" name="cat-color-input" id="cat-color-input" class="color-value" value="\(AppState.palette[0])">
              <div class="cat-swatches">\(swatches)</div>
              <div class="cat-add-actions">
                <button type="submit" class="primary-btn">Add</button>
                \(btn("cat-add-cancel", "", "ghost-btn", "Cancel"))
              </div>
            </form>
            """
        }
        return chips
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
    func liveStatusPill(_ sessionID: String) -> String {
        guard let live = activeTurns[sessionID] else { return "" }
        let label = liveStatusLabel(live)
        guard !label.isEmpty else { return "" }
        return "<span class=\"sess-status\"><span class=\"sess-status-dot\"></span>\(esc(label))</span>"
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

    /// Bucket key: today (same calendar day), week (1–6 days ago), older (7+).
    func bucketKey(_ d: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return "today" }
        if days < 7 { return "week" }
        return "older"
    }

    /// One collapsible bucket: caret + title + count + the session rows.
    func groupHTML(key: String, title: String, sessions: [Session], todos: Bool = false) -> String {
        let rows = sessions.map { sessionRow($0, todos: todos) }.joined()
        return """
        <div class="sess-group" data-grp="\(key)">
          <button type="button" class="sess-group-head" id="sess-grp-\(key)" title="\(esc(title))">
            <span class="sess-caret">\(WebUIIcon(.chevronDown, size: .small).render())</span>
            <span class="sess-group-title">\(esc(title))</span>
          </button>
          <div class="sess-group-rows">\(rows)</div>
        </div>
        """
    }

    func sessionRow(_ s: Session, todos: Bool = false) -> String {
        let encID = enc(s.id)
        let active = s.id == activeSessionID ? " active" : ""
        let archived = isArchived(s.id) ? " archived" : ""
        let title = trunc(sessionTitle(s), 40)
        if todos {
            // Minimal variant for the Todos page: chat title only — no meta,
            // no ⋮ menu, no category dot, no pin badge.
            return """
            <div class="sess-row\(active)\(archived)">
              <button type="button" id="s-open-\(encID)" class="sess-open">
                <span class="sess-title">\(esc(title))</span>
              </button>
            </div>
            """
        }
        let booked = isBookmarked(s.id)
        // Summaries carry the metadata count; loaded sessions use the live array.
        let count = s.messages.isEmpty ? s.messageCount : s.messages.count
        let epochMs = Int(s.updatedAt.timeIntervalSince1970 * 1000)
        let meta = "\(count) msg • <span class=\"rel-time\" data-reltime=\"\(epochMs)\">\(relTimeLabel(s.updatedAt))</span>" + (archived.isEmpty ? "" : " • Archived") + liveStatusPill(s.id)
        let pinBadge = booked ? "<span class=\"pin-badge\" title=\"Pinned\">" + WebUIIcon(.bookmark, size: .small).render() + "</span>" : ""
        let pinLabel = booked ? "Unpin conversation" : "Pin conversation"
        let arcLabel = archived.isEmpty ? "Archive conversation" : "Unarchive conversation"
        let catID = categoryID(for: s.id)
        let catColor = categoryColor(for: catID)
        let catDot = catColor.isEmpty ? "" : "<span class=\"cat-dot cat-rowdot\" style=\"background:\(catColor)\" title=\"\(esc(categoryName(for: catID)))\"></span>"
        // Category picker inside the "⋮" menu: a hover flyout submenu to the
        // right of "Set category" (arc parity), keeping category option
        // button ids so the existing chat-menu wire handles them unchanged.
        let noneCls = catID == nil ? " menu-sel" : ""
        var catSub = "<button type=\"button\" id=\"sm-uncat-\(encID)\" class=\"" + noneCls.trimmingCharacters(in: .whitespaces) + "\">No Project" + (catID == nil ? " " + WebUIIcon(.check, size: .small).render() : "") + "</button>"
        for c in settings.chatCategories {
            let sel = c.id == catID ? " menu-sel" : ""
            let check = c.id == catID ? " " + WebUIIcon(.check, size: .small).render() : ""
            catSub += """
            <button type="button" id="sm-cat-\(enc(c.id)).\(encID)" class="\(sel)" data-sid="\(s.id)">
              <span class="cat-dot" style="background:\(c.color)"></span><span>\(esc(c.name))\(check)</span>
            </button>
            """
        }
        // "Move to Category" swaps this menu's items for a category panel
        // (client-side panel swap; the category buttons keep their wire ids).
        // The panel must be a SIBLING of .chat-menu-items: when JS hides the
        // items container, a nested panel would be hidden with it.
        let catPanel = """
        <div class="chat-menu-panel" id="catpanel-\(encID)" hidden>
          <div class="cat-panel-head">
            <button type="button" id="sm-catback-\(encID)" class="cat-panel-back" title="Back">\(WebUIIcon(.chevronLeft, size: .small).render())</button>
            <span class="cat-panel-title">Move to Category</span>
          </div>
          <div class="cat-panel-list">\(catSub)</div>
        </div>
        """
        let catOpts = """
        <button type="button" id="sm-catmenu-\(encID)" class="menu-item-head catmenu-head">
          <span>Move to Category</span><span class="menu-arrow">\(WebUIIcon(.chevronRight, size: .small).render())</span>
        </button>
        """
        let rowDotContent: String
        if activeTurns[s.id] != nil {
            rowDotContent = #"<span class="row-spin"></span><span class="row-dots">⋮</span>"#
        } else {
            rowDotContent = "⋮"
        }
        let menu = """
        <div class="menu-wrap">
          <div class="menu-left">\(catDot)</div>
          <button type="button" id="s-menu-\(encID)" class="menu-dots" title="Chat actions">\(rowDotContent)</button>
          <div class="chat-menu" data-component-id="chat-menu" data-event="click" id="menu-\(encID)">
            <div class="chat-menu-items">
            <button type="button" id="sm-copy-\(encID)" data-sid="\(s.id)">Copy conversation link</button>
            <button type="button" id="sm-rename-\(encID)" data-sid="\(s.id)">Rename conversation</button>
            <button type="button" id="sm-pin-\(encID)" data-sid="\(s.id)">\(pinLabel)</button>
            <button type="button" id="sm-arc-\(encID)" data-sid="\(s.id)">\(arcLabel)</button>
            \(catOpts)
            <button type="button" id="sm-dup-\(encID)" data-sid="\(s.id)">Duplicate conversation</button>
            <button type="button" id="sm-del-\(encID)" class="danger" data-sid="\(s.id)">Delete conversation</button>
            </div>
            \(catPanel)
          </div>
        </div>
        """
        return """
        <div class="sess-row\(active)\(archived)">
          <button type="button" id="s-open-\(encID)" class="sess-open">
            <span class="sess-title">\(pinBadge)\(esc(title))</span>
            <span class="sess-meta">\(meta)</span>
          </button>
          <div class="row-actions">\(menu)</div>
        </div>
        """
    }

    // MARK: Skills panel

    func skillsPanel() -> String {
        let newBtn = btn("skill-new", "skill-new", "plus-btn", WebUIIcon(.plus, size: .medium).render(), " title=\"Add skill\"")
        let head = """
        <div class="panel-head">
          <span class="panel-title">Skills</span>
          <div class="panel-actions">\(newBtn)</div>
        </div>
        <div class="filter-bar">
          <input id="skill-search-input" data-component-id="skill-search-input" type="text" placeholder="Search skills…" value="\(esc(skillFilter))">
        </div>
        """
        let filtered = skills.filter {
            skillFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(skillFilter)
        }
        var groups: [String: [Skill]] = [:]
        for skill in filtered {
            let cat = (skill.category?.isEmpty == false ? skill.category! : "General")
            groups[cat, default: []].append(skill)
        }
        var rows = groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { cat -> String in
                let list = groups[cat]!
                let inner = list.map { skillRowHTML($0) }.joined()
                return """
                <div class="skill-group" data-grp-skill="\(esc(cat))">
                  <button type="button" class="skill-cat-head" id="skcat-\(enc(cat))" title="Toggle section">
                    <span class="skill-cat-caret">\(WebUIIcon(.chevronDown, size: .small).render())</span>
                    <span class="skill-cat-title">\(esc(cat))</span>
                    <span class="skill-cat-count">(\(list.count))</span>
                  </button>
                  <div class="skill-cat-rows" data-component-id="skill-list">\(inner)</div>
                </div>
                """
            }
        if rows.isEmpty {
            rows.append("<div class=\"empty-hint\">No skills match.</div>")
        }
        return """
        \(head)
        <div class="panel-body">\(rows.joined())</div>
        """
    }

    /// One skill row for the sidebar: toggle pill on the left, then bold name
    /// and a truncated one-line description (arc-style skill list).
    func skillRowHTML(_ skill: Skill) -> String {
        let encName = enc(skill.name)
        let active = skill.name == selectedSkill ? " active" : ""
        let enabled = !skillContextDisabled().contains(skill.name)
        let dis = enabled ? "" : " disabled"
        return """
        <div class="skill-row\(active)\(dis)">
          <label class="switch" title="\(enabled ? "Enabled" : "Disabled")">
            <input type="checkbox" id="sk-toggle-\(encName)" value="sk-toggle-\(encName)" data-event="change" data-no-restore \(enabled ? "checked" : "")>
            <span class="track"></span><span class="knob"></span>
          </label>
          <button type="button" id="sk-open-\(encName)" class="sess-open skill-open">
            <span class="sk-name">\(esc(skill.name))</span>
            <span class="sk-desc">\(esc(trunc(skill.description, 64)))</span>
          </button>
        </div>
        """
    }

    // MARK: Profiles panel

    func profilesPanel() -> String {
        let newBtn = btn("profile-new", "profile-new", "plus-btn", WebUIIcon(.plus, size: .medium).render(), " title=\"Add profile\"")
        let head = """
        <div class="panel-head">
          <span class="panel-title">Profiles</span>
          <div class="panel-actions">\(newBtn)</div>
        </div>
        """
        var rows: [String] = []
        for p in profiles {
            let encName = enc(p.name)
            let active = p.name == selectedProfile ? " active" : ""
            let sub = p.model ?? ""
            rows.append("""
            <div class="list-row\(active)" data-component-id="profile-list">
              <button type="button" id="pr-open-\(encName)" class="sess-open" style="padding:0">
                <span class="lr-name">\(esc(p.title.isEmpty ? p.name : p.title))</span>
                <span class="lr-sub">\(esc(sub))</span>
              </button>
            </div>
            """)
        }
        if rows.isEmpty {
            rows.append("<div class=\"empty-hint\">No profiles — press + to create one.</div>")
        }
        return """
        \(head)
        <div class="panel-body">\(rows.joined())</div>
        """
    }

    // MARK: Tools panel

    func toolsPanel() -> String {
        let head = """
        <div class="panel-head">
          <span class="panel-title">Tools</span>
        </div>
        """
        var rows: [String] = []
        for (toolset, tools) in toolsets {
            let encTS = enc(toolset)
            let disabled = settings.disabledToolsets.contains(toolset)
            let group = "<div class=\"tool-group\">\(esc(toolset))</div>"
            let toggle = """
            <div class="list-row" style="padding:6px 10px">
              <span class="lr-sub" style="flex:1">\(tools.count) tool\(tools.count == 1 ? "" : "s")</span>
              <label class="switch" title="\(disabled ? "Toolset disabled" : "Toolset enabled")">
                <input type="checkbox" id="ts-\(encTS)" value="ts-\(encTS)" data-component-id="tools-toggle" data-event="change" data-no-restore \(disabled ? "" : "checked")>
                <span class="track"></span><span class="knob"></span>
              </label>
            </div>
            """
            var toolRows: [String] = []
            for t in tools {
                let encT = enc(t.name)
                let active = t.name == selectedTool ? " active" : ""
                let avail = (t.checkFn?() ?? true)
                let badge = avail ? "" : " <span class='lr-sub'>(needs env)</span>"
                toolRows.append("""
                <div class="list-row\(active)" data-component-id="tool-list">
                  <button type="button" id="tl-open-\(encT)" class="sess-open" style="padding:0">
                    <span class="lr-name">\(toolEmojiIcon(t.emoji))\(esc(t.name))\(badge)</span>
                  </button>
                </div>
                """)
            }
            rows.append(group + toggle + toolRows.joined())
        }
        return """
        \(head)
        <div class="panel-body">\(rows.joined())</div>
        """
    }

    // MARK: Workspaces panel

    func workspacesPanel() -> String {
        let newBtn = btn("ws-new", "ws-new", "plus-btn", WebUIIcon(.plus, size: .medium).render(), " title=\"New workspace\"")
        let head = """
        <div class="panel-head">
          <span class="panel-title">Workspaces</span>
          <div class="panel-actions">\(newBtn)</div>
        </div>
        """
        var rows: [String] = []
        for entry in settings.workspaces {
            let encWS = enc(entry.name)
            let active = entry.name == settings.activeWorkspace ? " active" : ""
            rows.append("""
            <div class="list-row\(active)" data-component-id="workspace-list">
              <button type="button" id="ws-open-\(encWS)" class="sess-open" style="padding:0">
                <span class="lr-name">\(esc(entry.name))</span>
                <span class="lr-sub">\(esc(entry.path == WorkspaceEntry.defaultPath(for: "main") ? "home folder (default)" : trunc(entry.path, 58)))</span>
              </button>
              <div class="row-actions">\(btn("ws-del-\(encWS)", "", "icon-mini danger", WebUIIcon(.x, size: .small).render(), " title=\"Delete\""))</div>
            </div>
            """)
        }
        return """
        \(head)
        <div class="panel-body">\(rows.joined())</div>
        """
    }

    // MARK: Settings panel

    func settingsPanel() -> String {
        let head = """
        <div class="panel-head">
          <span class="panel-title">Settings</span>
        </div>
        """
        let nav = """
        <div class="panel-body">
          <div class="list-row"><a href="#appearance" style="color:inherit;text-decoration:none;flex:1"><span class="lr-name">Appearance</span></a></div>
          <div class="list-row"><a href="#preferences" style="color:inherit;text-decoration:none;flex:1"><span class="lr-name">Preferences</span></a></div>
          <div class="list-row"><a href="#storage" style="color:inherit;text-decoration:none;flex:1"><span class="lr-name">Storage</span></a></div>
          <div class="list-row"><a href="#tool-plugins" style="color:inherit;text-decoration:none;flex:1"><span class="lr-name">Tool plugins</span></a></div>
          <div class="list-row"><a href="#about" style="color:inherit;text-decoration:none;flex:1"><span class="lr-name">About</span></a></div>
        </div>
        """
        return head + nav
    }

    // MARK: - Main

    func mainContentHTML() -> String {
        let id = "main"
        switch activeView {
        case .chat:
            return "<div id=\"\(id)\" class=\"chat-main\">\(chatMain())</div>"
        case .skills:
            return "<div id=\"\(id)\">\(skillsMain())</div>"
        case .profiles:
            return "<div id=\"\(id)\">\(profilesMain())</div>"
        case .tools:
            return "<div id=\"\(id)\">\(toolsMain())</div>"
        case .workspaces:
            return "<div id=\"\(id)\">\(workspacesMain())</div>"
        case .github:
            return "<div id=\"\(id)\">\(githubMain())</div>"
        case .kanban:
            return "<div id=\"\(id)\">\(kanbanMain())</div>"
        case .memory:
            return "<div id=\"\(id)\">\(memoryMain())</div>"
        case .insights:
            return "<div id=\"\(id)\">\(insightsMain())</div>"
        case .settings:
            return "<div id=\"\(id)\">\(settingsMain())</div>"
        case .logs:
            return "<div id=\"\(id)\">\(logsMain())</div>"
        case .tasks:
            return "<div id=\"\(id)\">\(tasksMain())</div>"
        case .todos:
            return "<div id=\"\(id)\">\(todosPanelHTML())</div>"
        }
    }

    // MARK: Chat main

    /// The chat header (title + meta + regenerate/delete) as its own node, so a turn
    /// boundary can refresh it without replacing the whole chat region.
    func chatHeaderHTML() -> String {
        let session = activeSession()
        let configName = configName(for: activeSessionID)
        let title = session.map { trunc(sessionTitle($0), 60) } ?? "Chat"
        let count = session.map { $0.messages.isEmpty ? $0.messageCount : $0.messages.count } ?? 0
        let model = settings.modelConfig(named: configName)?.model ?? configName
        let meta = "\(esc(model)) • \(count) messages"
        let delLabel = pendingDelete ? "Confirm?" : WebUIIcon(.x, size: .small).render()
        let delClass = pendingDelete ? "sess-confirm" : "icon-mini danger"
        let regenBtn = """
        <button type="button" id="regen-btn" class="icon-mini" title="Regenerate last reply">\(WebUIIcon(.refreshCw, size: .small).render())</button>
        """
        return """
        <header class="chat-header" id="chat-header">
          <div>
            <div class="chat-title">\(esc(title))</div>
            <div class="chat-meta">\(meta)</div>
          </div>
          <div class="row-actions-main" style="margin:0" data-component-id="regen" data-event="click">
            \(regenBtn)
            \(btn("chat-del", "chat-del", delClass, delLabel, " title=\"Delete chat\""))
          </div>
        </header>
        """
    }

    func chatMain() -> String {
        guard activeSessionID != nil else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank">
                <div class="blank-ico">\(WebUIIcon(.messageSquare, size: .extraLarge).render())</div>
                <div class="blank-title">Welcome to ARC Agent</div>
                <div class="blank-sub">Pick a conversation on the left, or start a new one.</div>
                \(btn("blank-chat-new", "blank-chat-new", "primary-btn blank-cta", WebUIIcon(.plus, size: .small).render() + "<span>New chat</span>"))
              </div>
            </div>
            """
        }
        let session = activeSession()

        let header = chatHeaderHTML()
        let follow = forceScrollBottom ? " data-follow=\"bottom\"" : ""
        forceScrollBottom = false
        let scrollBtn = "<button type=\"button\" id=\"scroll-to-bottom\" class=\"scroll-to-bottom-btn\" data-component-id=\"scroll-to-bottom\" title=\"Jump to latest\" aria-label=\"Jump to latest\" hidden>&#8595;</button>"
        // The jump button anchors to its own wrapping container so it sits
        // just above the composer (never overlapping it), at the bottom-right
        // of the scroll viewport.
        let scroll = """
        <div class="chat-scroll-wrap">
          <div class="chat-scroll" id="chat-scroll" data-scroll-key="chat"\(follow)>
            <div class="chat-inner" id="chat-inner">
              \(messagesHTML(session?.messages ?? []))
            </div>
          </div>
          \(scrollBtn)
          \(outlineToggleHTML)
          \(outlinePanelHTML)
        </div>
        """
        let composer = composerHTML()
        return header + scroll + composer
    }

    /// Floating "Conversation outline" button (reference #2124 parity); hidden
    /// entirely when the appearance setting is off.
    var outlineToggleHTML: String {
        guard settings.showConversationOutline else { return "" }
        return "<button type=\"button\" id=\"outline-toggle\" class=\"outline-toggle-btn\" title=\"Conversation outline\" aria-label=\"Toggle conversation outline\">&#9776;</button>"
    }

    /// The outline panel itself (server-rendered shell; the JS fills entries
    /// from the rendered user message anchors and handles jumps).
    var outlinePanelHTML: String {
        guard settings.showConversationOutline else { return "" }
        return """
        <div id="outline-panel" role="navigation" aria-label="Conversation outline" hidden>
          <div class="outline-header">
            <span>Outline</span>
            <button type="button" id="outline-close" class="outline-close-btn" title="Close outline" aria-label="Close outline">&#215;</button>
          </div>
          <div id="outline-entries" class="outline-entries"></div>
        </div>
        """
    }

    func messagesHTML(_ messages: [Message]) -> String {
        var html: [String] = []
        var i = 0
        let mode = settings.activityDisplay
        while i < messages.count {
            if messages[i].role == .user {
                html.append(messageHTML(messages[i], rawIdx: i))
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
                html.append(block)
            } else {
                html.append(contentsOf: legacySegmentHTML(seg, mode: mode))
            }
            i = j
        }
        // Live turn + steer bubble belong to their owning session only.
        if let live = activeTurns[activeSessionID ?? ""] {
            // A pending steer renders as a arc-style steer indicator: a
            // transient italic banner with the uppercase STEER badge, below
            // the messages (never persisted as a message).
            if let steer = live.steerText, !steer.isEmpty {
                html.append("""
                <div class="steer-indicator">
                  <span class="steer-badge">Steer</span>
                  <span class="steer-body">\(esc(steer))</span>
                </div>
                """)
            }
            html.append(liveMessageHTML(live))
        }
        if html.isEmpty {
            html.append("""
            <div class="blank">
              <div class="blank-ico">\(WebUIIcon(.messageSquare, size: .extraLarge).render())</div>
              <div class="blank-title">This chat is empty</div>
              <div class="blank-sub">Say hello below — or type / for the command list.</div>
              <button type="button" class="ghost-btn blank-cta" data-focus-composer>\(WebUIIcon(.edit, size: .small).render())<span>Start typing</span></button>
            </div>
            """)
        }
        return html.joined()
    }

    /// The role header for an assistant reply: sparkle icon + "ARC Agent" on
    /// the left; the grouped meta row carries the tokens-per-second chip, the
    /// token usage and the produced-at time on the right (arc parity).
    func assistantRoleHeaderHTML(_ m: Message) -> String {
        let tp = m.tps ?? 0
        let tpsChip = settings.showTps && tp > 0
            ? "<span class=\"msg-tps-inline\" title=\"Tokens per second\">\(esc(fmtTps(tp)))</span>" : ""
        let usage = usageInlineHTML(m)
        let ts = fmtMessageTime(m.createdAt)
        let timeSpan = ts.isEmpty ? "" : "<span class=\"msg-time\">\(esc(ts))</span>"
        let right = usage.isEmpty && timeSpan.isEmpty
            ? "" : "<span class=\"mm-right\">\(usage)\(timeSpan)</span>"
        return "<div class=\"msg-meta\"><span class=\"mm-left\"><span class=\"role-icon assistant\">\(WebUIIcon(.star, size: .small).render())</span> ARC Agent\(tpsChip)</span><span class=\"mm-spacer\"></span>\(right)</div>"
    }

    /// The body (markdown + tool cards) of an assistant reply.
    func assistantBodyHTML(_ m: Message) -> String {
        let content = m.content ?? ""
        let chips = toolChipsHTML(m.toolCalls)
        if content.isEmpty { return chips }
        return "<div class=\"msg-body\">\(mdBox(content))</div>" + chips
    }

    /// arc parity: input/output token usage, rendered inside the meta row.
    func usageInlineHTML(_ m: Message) -> String {
        guard settings.showTokenUsage, let u = m.usage else { return "" }
        return "<span class=\"msg-usage-inline\">\(fmtTokens(u.promptTokens)) in · \(fmtTokens(u.completionTokens)) out</span>"
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

    /// A collapsible reasoning row (icon + label + caret), shared by every
    /// activity display mode. The key keeps its open state across re-renders.
    func thinkingRowHTML(_ text: String, key: String, innerID: String? = nil) -> String {
        let inner = innerID.map { "<span id=\"\($0)\">" + esc(text) + "</span>" } ?? esc(text)
        return "<details class=\"thinking-row\"" + webuiKeyAttr(key) + "><summary>"
            + WebUIIcon(.edit, size: .small).render()
            + "<span class=\"tw-label\">Thinking</span><span class=\"tw-spacer\"></span>"
            + "<span class=\"tw-caret\">" + WebUIIcon(.chevronRight, size: .small).render() + "</span>"
            + "</summary><div class=\"tc-detail\">" + inner + "</div></details>"
    }

    /// arc-parity turn dropdown. Wraps a completed turn's supporting
    /// activity behind one `Processed Xm Ys` summary; only the final reply
    /// stays visible until the user opens it. `transparent_stream` renders the
    /// same block pre-opened (full cards visible). Returns nil for modes that
    /// don't use the block, for trunks with no activity, and for trunks with
    /// no final reply (stop/error edges) — callers fall back to the legacy
    /// per-piece rendering.
    func turnBlockHTML(_ seg: [Message], mode: String, turnIndex: Int) -> String? {
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

        var rows: [String] = []
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
                var detail: [String] = []
                if let interim = m.content, !interim.isEmpty {
                    detail.append("<div class=\"msg-body interim\">" + mdBox(interim) + "</div>")
                }
                detail.append(toolChipsHTML(calls, results: pair.1))
                rows.append("<details class=\"worklog-summary\" id=\"\(target)\" data-webui-key=\"\(target)\"><summary>" + WebUIIcon(.tool, size: .small).render()
                    + "<span>" + esc(summary) + "</span><span class=\"tw-spacer\"></span>"
                    + "<button class=\"tw-copy\" type=\"button\" data-copy-target=\"\(target)\" title=\"Copy this activity\">" + WebUIIcon(.copy, size: .small).render() + "</button>"
                    + "<span class=\"tw-caret\">" + WebUIIcon(.chevronRight, size: .small).render() + "</span></summary><div class=\"wl-detail\">" + detail.joined() + "</div></details>")
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
        let terminalCard = finalMsg.terminalReason.map { terminalCardHTML(for: $0) } ?? ""
        let worklogKey = "tw-\(turnIndex)-\(String(format: "%.3f", finalMsg.createdAt?.timeIntervalSince1970 ?? 0))"
        return """
        <div class="assistant-turn" id="turn-\(turnIndex)" data-turn-duration="\(String(format: "%.0f", finalMsg.turnDuration ?? 0))">
          \(assistantRoleHeaderHTML(finalMsg))
          <details class="turn-worklog" data-tw-session="\(esc(activeSessionID ?? ""))" data-webui-key="\(worklogKey)">
            <summary>
              <span class="tw-dot"></span>
              <span class="tw-label">\(esc(label))</span>
              <span class="tw-spacer"></span>
              <span class="tw-caret">\(WebUIIcon(.chevronRight, size: .small).render())</span>
            </summary>
            <div class="wl-detail tw-body">
              \(rows.joined())
            </div>
          </details>
          <div class="msg assistant">
            <div style="max-width:100%;width:100%">
              \(assistantBodyHTML(finalMsg))
              \(terminalCard)
              \(msgFootHTML(finalMsg))
            </div>
          </div>
        </div>
        """
    }

    /// Legacy per-piece rendering for a completed assistant segment (used when
    /// `turnBlockHTML` declines — e.g. stop/error trunks, hide mode).
    func legacySegmentHTML(_ seg: [Message], mode: String) -> [String] {
        var out: [String] = []
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

    /// Renders one assistant turn's supporting activity (reasoning, interim
    /// text, tool calls + results) according to the persisted display mode
    /// (compact_worklog | transparent_stream | hide_all_activity).
    func activityGroupHTML(_ m: Message, calls: [ToolCall], results: [String: String], mode: String) -> String {
        let mk = msgWebuiKey(m)
        switch mode {
        case "hide_all_activity":
            // Final answer only: drop the whole execution trace.
            return ""
        case "transparent_stream":
            var rows: [String] = []
            if let r = m.reasoning, !r.isEmpty {
                rows.append(thinkingRowHTML(r, key: mk.isEmpty ? "" : "think-r\(mk)"))
            }
            if let interim = m.content, !interim.isEmpty {
                rows.append("<div class=\"msg-body interim\">" + mdBox(interim) + "</div>")
            }
            for c in calls {
                rows.append(toolCardHTML(c, result: results[c.id]))
            }
            return rows.joined()
        default:
            // compact_worklog: one quiet, collapsible summary per turn.
            let names = calls.map { $0.function.name }
            let summary = "Ran " + String(calls.count) + " tool call" + (calls.count == 1 ? "" : "s") + " · " + names.joined(separator: ", ")
            var detail: [String] = []
            if let r = m.reasoning, !r.isEmpty {
                detail.append("<div class=\"tc-detail thinking-detail\">" + esc(r) + "</div>")
            }
            if let interim = m.content, !interim.isEmpty {
                detail.append("<div class=\"msg-body interim\">" + mdBox(interim) + "</div>")
            }
            detail.append(toolChipsHTML(calls, results: results))
            return "<details class=\"worklog-summary\"" + webuiKeyAttr(mk.isEmpty ? "" : "ws-" + mk) + "><summary>" + WebUIIcon(.tool, size: .small).render() + "<span>" + esc(summary) + "</span><span class=\"tw-spacer\"></span><span class=\"tw-caret\">" + WebUIIcon(.chevronRight, size: .small).render() + "</span></summary><div class=\"wl-detail\">" + detail.joined() + "</div></details>"
        }
    }

    /// One tool call as a compact card: tool icon + name + one-line argument
    /// summary; expands to the full arguments JSON and, when known, the result.
    /// The card carries a stable `data-webui-key` so the engine restores its
    /// open state across fragment re-renders with shifting row indices.
    func toolCardHTML(_ c: ToolCall, result: String?) -> String {
        let args = c.function.arguments
        var body = "<div class=\"tc-label\">Arguments</div><pre class=\"tc-block\">" + esc(args) + "</pre>"
        if let result, !result.isEmpty {
            body += "<div class=\"tc-label\">Result</div><pre class=\"tc-block\">" + esc(result) + "</pre>"
        }
        return "<details class=\"tool-card\" data-webui-key=\"tc-\(esc(c.id))\"><summary>"
            + WebUIIcon(.tool, size: .small).render()
            + "<span class=\"tc-name\">" + esc(c.function.name) + "</span>"
            + "<span class=\"tc-arg\">" + toolArgSummary(args) + "</span>"
            + "<span class=\"tw-spacer\"></span>"
            + "<button class=\"tc-copy\" type=\"button\" data-copy=\"" + esc(args) + "\" title=\"Copy arguments\">" + WebUIIcon(.copy, size: .small).render() + "</button>"
            + "<span class=\"tw-caret\">" + WebUIIcon(.chevronRight, size: .small).render() + "</span>"
            + "</summary><div class=\"tc-detail\">" + body + "</div></details>"
    }

    func messageHTML(_ m: Message, rawIdx: Int = -1) -> String {
        switch m.role {
        case .user:
            // Slash-command rewrites (skill invocation scaffolding) keep the
            // typed line as the display text; the model sees `content`.
            let content = m.displayText ?? m.content ?? ""
            let anchor = rawIdx >= 0 ? " id=\"msg-user-\(rawIdx)\"" : ""
            return """
            <div class="msg user"\(anchor)>
              <div class="msg-body user-bubble">\(mdBox(content))</div>
            </div>
            """
        case .assistant:
            // Terminal-state status card (e.g. tool iteration limit reached,
            // turn stopped, model connection lost) under the reply that ended
            // the turn.
            let terminalCard = m.terminalReason.map { terminalCardHTML(for: $0) } ?? ""
            let anchor = rawIdx >= 0 ? " id=\"msg-\(rawIdx)\"" : ""
            return """
            <div class="msg assistant"\(anchor)>
              <div style="max-width:100%;width:100%">
                \(assistantRoleHeaderHTML(m))
                \(assistantBodyHTML(m))
                \(terminalCard)
                \(msgFootHTML(m))
              </div>
            </div>
            """
        case .tool:
            // Tool results render as the same expandable card family as calls:
            // icon + name + a one-line preview, expanding to the full output.
            let content = m.content ?? ""
            let preview = esc(trunc(content.replacingOccurrences(of: "\n", with: " "), 96))
            let resultKey = m.toolCallID.map { "tr-\($0)" }
                ?? m.createdAt.map { "tr-\(Int($0.timeIntervalSince1970 * 1000))" } ?? ""
            let anchor = rawIdx >= 0 ? " id=\"msg-\(rawIdx)\"" : ""
            let card = "<details class=\"tool-card\"" + webuiKeyAttr(resultKey) + "><summary>"
                + WebUIIcon(.tool, size: .small).render()
                + "<span class=\"tc-name\">" + esc(m.name ?? "tool") + "</span>"
                + "<span class=\"tc-arg\">" + preview + "</span>"
                + "<span class=\"tw-spacer\"></span>"
                + "<span class=\"tw-caret\">" + WebUIIcon(.chevronRight, size: .small).render() + "</span>"
                + "</summary><div class=\"tc-detail\"><div class=\"tc-label\">Result</div><pre class=\"tc-block\">" + esc(content) + "</pre></div></details>"
            return """
            <div class="msg assistant"\(anchor)>
              <div style="width:100%">
                \(card)
              </div>
            </div>
            """
        case .system:
            return ""
        }
    }

    /// Arc-parity terminal-state card: rendered under the reply that ended a
    /// turn abnormally. Covers the tool-iteration limit (the classic case)
    /// and interrupted turns — user stop or model connection loss — so the
    /// UI always explains WHY the turn ended the way it did.
    func terminalCardHTML(for reason: String) -> String {
        switch reason {
        case "user_stopped":
            return interruptionCardHTML(
                icon: .square, title: "Turn stopped",
                sub: "Stopped by the user before the reply finished.",
                state: "Stopped by user", next: "Start a new turn to continue.")
        case "disconnected":
            return interruptionCardHTML(
                icon: .alertTriangle, title: "Model connection lost",
                sub: "The connection to the model was lost, so the turn was interrupted.",
                state: "Disconnected", next: "Start a new turn to continue.")
        default:
            return limitCardHTML()
        }
    }

    /// The tool-iteration-limit status card (shown under the final reply when
    /// the tool-iteration budget was exhausted).
    func limitCardHTML() -> String {
        return """
        <div class="limit-card">
          <div class="limit-head">
            <span class="limit-ico">\(WebUIIcon(.zap, size: .small).render())</span>
            <span class="limit-title">Tool iteration limit reached</span>
          </div>
          <div class="limit-sub">Stopped because the tool iteration limit was reached.</div>
          <div class="limit-rows">
            <div class="limit-row"><span class="limit-k">State</span><span class="limit-v">Limit reached</span></div>
            <div class="limit-row"><span class="limit-k">Next step</span><span class="limit-v">Start a new turn to continue.</span></div>
          </div>
        </div>
        """
    }

    /// Shared shell for interruption status cards (same look as the limit
    /// card, distinct icon/colors per terminal reason).
    func interruptionCardHTML(icon: IconName, title: String, sub: String, state: String, next: String) -> String {
        return """
        <div class="limit-card">
          <div class="limit-head">
            <span class="limit-ico">\(WebUIIcon(icon, size: .small).render())</span>
            <span class="limit-title">\(esc(title))</span>
          </div>
          <div class="limit-sub">\(esc(sub))</div>
          <div class="limit-rows">
            <div class="limit-row"><span class="limit-k">State</span><span class="limit-v">\(esc(state))</span></div>
            <div class="limit-row"><span class="limit-k">Next step</span><span class="limit-v">\(esc(next))</span></div>
          </div>
        </div>
        """
    }

    /// Tool calls as compact cards (icon + name + argument summary, expanding
    /// to the full JSON and — when paired — the result). `results` pairs a
    /// call with the tool message carrying its output.
    func toolChipsHTML(_ calls: [ToolCall]?, results: [String: String] = [:]) -> String {
        guard let calls, !calls.isEmpty else { return "" }
        let cards = calls.map { toolCardHTML($0, result: results[$0.id]) }
        return "<div class=\"tool-pills\">\(cards.joined())</div>"
    }

    func liveMessageHTML(_ live: LiveTurn) -> String {
        let mode = settings.activityDisplay
        let streamText = esc(live.assistantText).replacingOccurrences(of: "\n", with: "<br>")
        let cursor = live.status == "running" ? "<span class=\"stream-cursor\"></span>" : ""
        let thinkingRow = mode != "hide_all_activity" && !live.thinking.isEmpty
            ? thinkingRowHTML(live.thinking, key: "live-think", innerID: "live-turn-thinking")
            : ""
        let chips = mode == "transparent_stream" && !live.toolChips.isEmpty
            ? "<div class=\"tool-pills\">" + live.toolChips.joined() + "</div>"
            : ""
        let status: String
        switch live.status {
        case "tool":
            let name = live.toolName.map { " " + $0 } ?? ""
            let started = live.toolStartedAt.map { "<span class=\"msg-elapsed\" data-elapsed data-started=\"\(Int($0.timeIntervalSince1970 * 1000))\">\(fmtElapsed($0))</span>" } ?? ""
            status = mode == "hide_all_activity" ? ""
                : "<div class=\"live-status\"><span>" + WebUIIcon(.tool, size: .small).render() + " Running" + esc(name) + "…</span>" + started + "</div>"
        case "error":
            status = "<div class=\"live-status\" style=\"color:var(--danger)\"><span>" + WebUIIcon(.alertTriangle, size: .small).render() + " " + esc(live.error ?? "Turn failed") + "</span></div>"
        case "approval":
            status = "<div class=\"live-status\"><span>" + WebUIIcon(.alertTriangle, size: .small).render() + " Waiting for your approval…</span></div>"
        case "done":
            status = ""
        default:
            status = mode == "hide_all_activity" ? ""
                : "<div class=\"live-status\"><span>" + WebUIIcon(.edit, size: .small).render() + " Responding…</span></div>"
        }
        let body = "<div class=\"msg-body\" id=\"live-turn-body\" style=\"white-space:pre-wrap\"><span id=\"live-turn-text\">" + streamText + "</span>" + cursor + "</div>"
        // arc parity: live tokens-per-second chip in the streaming header.
        let liveTps = live.tps ?? 0
        let tpsChip = settings.showTps && liveTps > 0
            ? "<span class=\"msg-tps-inline\" title=\"Tokens per second\">\(esc(fmtTps(liveTps)))</span>" : ""
        let elapsedSpan = "<span class=\"msg-elapsed\" data-elapsed data-started=\"\(Int(live.startedAt.timeIntervalSince1970 * 1000))\">\(fmtElapsed(live.startedAt))</span>"
        // the status line sits first: everything that grows below it (reasoning,
        // streamed text, tool pills) then reflows behind it, so nothing above
        // the growth ever moves (CLS: the status line was being pushed down
        // per token).
        return """
        <div class="msg assistant" id="live-turn" data-session="\(esc(live.sessionID))">
          <div style="width:100%">
            <div class="msg-meta"><span class="mm-left">ARC Agent\(tpsChip)</span><span class="mm-spacer"></span><span class="mm-right">\(elapsedSpan)</span></div>
            \(status)
            \(thinkingRow)
            \(body)
            \(chips)
          </div>
        </div>
        """
    }

    // MARK: Composer flyout (arc parity: approval + clarification cards)

    /// The arc-style flyout cards attached to the composer (approval /
    /// clarification / yolo pill). Rendered above the composer input. The
    /// session ownership check keeps prompts from leaking across chats.
    func composerFlyoutHTML() -> String {
        let sid = activeSessionID ?? ""
        if let pa = pendingApproval, pa.sessionID == sid {
            return approvalCardHTML(command: pa.command, description: pa.description)
        }
        if let pc = pendingClarify, pc.sessionID == sid {
            return clarifyCardHTML(pc)
        }
        if isYolo(sid) {
            return yoloPillHTML()
        }
        return ""
    }

    /// arc-style approval card: attached to the composer, orange header,
    /// command code block, Allow once / session / always / deny + skip-all.
    func approvalCardHTML(command: String, description: String) -> String {
        let desc = description.isEmpty ? "" : "<div class=\"approval-desc\">\(esc(description))</div>"
        return """
        <div class="approval-card visible">
          <div class="approval-inner">
            <div class="approval-head">
              <span class="approval-ico">\(WebUIIcon(.alertTriangle, size: .small).render())</span><span class="approval-title">Approval required</span>
              <button type="button" class="approval-collapse" id="approval-collapse" title="Collapse">\(WebUIIcon(.chevronDown, size: .small).render())</button>
              <button type="button" id="approval-dismiss" data-component-id="approval-dismiss" data-event="click" class="approval-dismiss" title="Dismiss">\(WebUIIcon(.x, size: .small).render())</button>
            </div>
            \(desc)
            <div class="approval-cmd"><code>\(esc(command))</code></div>
            <div class="approval-btns">
              <button type="button" id="approval-once" data-component-id="approval-once" data-event="click" class="approval-btn once">\(WebUIIcon(.check, size: .small).render())<span class="approval-btn-label">Allow once</span></button>
              <button type="button" id="approval-session" data-component-id="approval-session" data-event="click" class="approval-btn session">\(WebUIIcon(.lock, size: .small).render())<span class="approval-btn-label">Allow session</span></button>
              <button type="button" id="approval-always" data-component-id="approval-always" data-event="click" class="approval-btn always">\(WebUIIcon(.star, size: .small).render())<span class="approval-btn-label">Always allow</span></button>
              <button type="button" id="approval-deny" data-component-id="approval-deny" data-event="click" class="approval-btn deny">\(WebUIIcon(.x, size: .small).render())<span class="approval-btn-label">Deny</span></button>
            </div>
            <div class="approval-yolo-row">
              <button type="button" id="approval-yolo" data-component-id="approval-yolo" data-event="click" class="approval-btn yolo">\(WebUIIcon(.zap, size: .small).render())<span class="approval-btn-label">Skip all this session</span></button>
            </div>
          </div>
        </div>
        """
    }

    /// arc-style clarification card: question, numbered choices (up to 4),
    /// free-form response row and a 120 s countdown, attached to the composer.
    func clarifyCardHTML(_ pc: PendingClarify) -> String {
        let expiryMs = Int(pc.expiresAt.timeIntervalSince1970 * 1000)
        let remaining = max(1, Int(pc.expiresAt.timeIntervalSinceNow.rounded(.up)))
        let choiceRows = pc.choices.enumerated().map { i, c in
            """
            <button type="button" id="clarify-choice-\(i)" class="clarify-choice">
              <span class="clarify-choice-badge">\(i + 1)</span><span class="clarify-choice-text">\(esc(c))</span>
            </button>
            """
        }.joined()
        let choicesBlock = choiceRows.isEmpty ? "" : "<div class=\"clarify-choices\" data-component-id=\"clarify-choice\" data-event=\"click\">\(choiceRows)</div>"
        return """
        <div class="clarify-card visible">
          <div class="clarify-inner">
            <div class="clarify-head">
              <span class="clarify-ico">\(WebUIIcon(.badgeQuestionMark, size: .small).render())</span><span class="clarify-title">Clarification needed</span>
              <span class="clarify-countdown" id="clarify-countdown" data-expires="\(expiryMs)">\(remaining)s</span>
              <button type="button" class="clarify-collapse" id="clarify-collapse" title="Collapse">\(WebUIIcon(.chevronDown, size: .small).render())</button>
            </div>
            <div class="clarify-question">\(esc(pc.question))</div>
            \(choicesBlock)
            <div class="clarify-response">
              <button type="button" id="clarify-other" class="clarify-pill pill-other" title="Type your own answer">Other</button>
              <form id="clarify-form" data-component-id="clarify-form" data-event="submit" class="clarify-free">
                <input id="clarify-input" name="clarify-input" data-component-id="clarify-input" type="text" placeholder="Type your response..." autocomplete="off">
                <button type="submit" id="clarify-submit" class="clarify-submit">Send</button>
              </form>
            </div>
            <div class="clarify-hint">Pick a choice, or type your own answer below.</div>
          </div>
        </div>
        """
    }

    /// Session-level "approvals skipped" pill (reference yolo indicator) with a
    /// restore control.
    func yoloPillHTML() -> String {
        """
        <div class="yolo-pill">
          <span class="yolo-ico">\(WebUIIcon(.zap, size: .small).render())</span>
          <span class="yolo-text">Approvals skipped for this session</span>
          <button type="button" id="yolo-off" data-component-id="yolo-off" data-event="click" class="yolo-off">Restore</button>
        </div>
        """
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

    /// Hover footer for completed assistant responses: copy only — the
    /// produced-at time now lives in the message meta row.
    func msgFootHTML(_ m: Message) -> String {
        return """
        <div class="msg-foot">
          <span class="msg-actions">
            <button type="button" class="msg-copy-btn msg-action-btn" data-copy="\(esc(m.content ?? ""))" title="Copy response">\(WebUIIcon(.copy, size: .small).render())</button>
          </span>
        </div>
        """
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

    /// Composer ring + hover tooltip, mirroring the reference client's ctx indicator.
    func ctxIndicatorHTML(_ s: Session) -> String {
        guard !s.messages.isEmpty else { return "" }
        let snap = ctxSnapshot(for: s)
        let pct = snap.contextLength > 0 ? min(100, Int((Double(snap.usedTokens) / Double(snap.contextLength) * 100).rounded())) : 0
        let circ = 61.261056745
        let offset = circ * (1 - Double(pct) / 100)
        let level = pct > 75 ? " ctx-high" : (pct > 50 ? " ctx-mid" : "")
        let thrPct = snap.contextLength > 0 ? Int((Double(snap.threshold) / Double(snap.contextLength) * 100).rounded()) : 0
        var cacheLine = ""
        if let hit = snap.cacheHitPercent, let read = snap.cacheRead, let write = snap.cacheWrite {
            cacheLine = "<div class=\"ctx-tooltip-line\">Cache: \(hit)% hit (\(fmtTokens(read)) read / \(fmtTokens(write)) write)</div>"
        }
        return """
        <div class="ctx-indicator-wrap">
          <button type="button" class="ctx-indicator\(level)" title="Context window usage" aria-label="Context window usage">
            <span class="ctx-ring">
              <svg class="ctx-ring-svg" viewBox="0 0 24 24" aria-hidden="true">
                <circle class="ctx-ring-track" cx="12" cy="12" r="9.75"></circle>
                <circle class="ctx-ring-value" cx="12" cy="12" r="9.75" style="stroke-dasharray:\(circ);stroke-dashoffset:\(offset)"></circle>
              </svg>
              <span class="ctx-ring-center">\(pct)</span>
            </span>
          </button>
          <div class="ctx-tooltip" role="tooltip">
            <div class="ctx-tooltip-title">Context window</div>
            <div class="ctx-tooltip-line">Context window: \(pct)% used (\(100 - pct)% left)</div>
            <div class="ctx-tooltip-line">Context window: \(fmtTokens(snap.usedTokens)) / \(fmtTokens(snap.contextLength)) tokens used</div>
            <div class="ctx-tooltip-line">Auto-compress at \(fmtTokens(snap.threshold)) (\(thrPct)%)</div>
            \(cacheLine)
          </div>
        </div>
        """
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
    func selectionChipsHTML() -> String {
        guard !pendingContexts.isEmpty else { return "" }
        var cards = ""
        for block in pendingContexts {
            let preview = AppState.contextPreview(block.text)
            cards += #"<article class="selection-context-card" data-selection-id="\#(esc(block.id))">"#
            cards += #"<div class="selection-context-accent" aria-hidden="true"></div>"#
            cards += "<div class=\"selection-context-body\">"
            cards += "<div class=\"selection-context-header\">"
            cards += #"<span class="selection-context-name">\#(esc(block.name))</span>"#
            cards += #"<button type="button" id="\#(esc(block.id))" class="selection-context-remove" title="Remove context block">&#x2715;</button>"#
            cards += "</div>"
            cards += #"<blockquote class="selection-context-quote">\#(esc(preview))</blockquote>"#
            cards += "</div></article>"
        }
        return #"<div id="composer-selection-chips" class="selection-chips-wrap" data-component-id="selection-context-del" data-event="click">\#(cards)</div>"#
    }

    func composerHTML() -> String {
        let running = activeTurns[activeSessionID ?? ""] != nil
        let sid = activeSessionID ?? ""
        let draft = settings.composerDrafts[sid] ?? ""

        let attachmentsHTML: String = {
            var chips = ""
            for (i, path) in attachments.enumerated() {
                let x = btn("att-del-\(i)", "", "chip-x", WebUIIcon(.x, size: .small).render())
                chips += "<span class=\"chip\">@\(esc(trunc(path, 50)))\(x)</span>"
            }
            return chips
        }()

        let isBooked = activeSessionID.map { isBookmarked($0) } ?? false
        let bookLabel = isBooked ? WebUIIcon(.star, size: .small).render() : WebUIIcon(.star, size: .small).render()

        // arc-parity composer dropdowns (workspace / profile / model /
        // thinking) — custom panels rendered by the server, replacing the
        // native <select> elements.
        let selectors = composerSelectorsHTML()

        // File popover
        let filePopVisible = filePopOpen ? "" : " hidden"
        let recents = settings.recentFiles.prefix(6).map { r in
            let er = enc(r)
            return "<button type=\"button\" id=\"fr-\(er)\" class=\"fp-recent\">@\(esc(trunc(r, 60)))</button>"
        }.joined()

        let filePop = """
        <div id="file-pop" class="file-pop\(filePopVisible)" data-component-id="file-recents" data-event="click">
          <div class="fp-row">
            <input id="file-path-input" data-component-id="file-path-input" type="text" placeholder="/absolute/path/to/file" value="\(esc(formValues["file-path-input"] ?? ""))">
            \(btn("file-attach", "file-attach", "primary-btn", "Attach"))
          </div>
          <div class="fp-recents">Recent</div>
          \(recents)
        </div>
        """

        // While a turn runs, the send control becomes a red stop button.
        let sendButton: String
        if running {
            sendButton = #"<button type="button" id="cb-send" data-component-id="stop-turn" class="send-btn stop" title="Stop">"# + WebUIIcon(.square, size: .medium).render() + #"</button>"#
        } else {
            sendButton = #"<button type="submit" id="cb-send" data-component-id="cb-send" class="send-btn" title="Send">"# + WebUIIcon(.arrowUp, size: .medium).render() + #"</button>"#
        }

        let selOpen = wsSelectOpen || profileSelectOpen || modelSelectOpen || thinkSelectOpen
        return """
        <div class="composer-wrap" id="composer-wrap">
          <div id="composer-flyout">\(composerFlyoutHTML())</div>
          <div id="cmd-dropdown" class="cmd-dropdown" aria-label="Slash commands"></div>
          \(selectionChipsHTML())
          <form id="composer-form" data-component-id="composer-form" class="composer-bar\(selOpen ? " sel-open" : "")">
            <div class="attach-chips" id="attach-chips" data-component-id="att-chips" data-event="click">\(attachmentsHTML)</div>
            <textarea id="composer-input" name="composer-input" data-component-id="composer-input" data-session="\(esc(sid))" data-prevent-enter="send" placeholder="\(running ? "Steer the current response…" : "Message ARC…")" rows="1" style="min-height:24px">\(esc(draft))</textarea>
            <div class="composer-toolbar">
              \(btn("cb-file", "cb-file", "tool-btn" + (filePopOpen ? " on" : ""), WebUIIcon(.paperclip, size: .medium).render(), " title=\"Attach a file\""))
              \(btn("cb-bookmark", "cb-bookmark", "tool-btn" + (isBooked ? " on" : ""), bookLabel, " title=\"Bookmark this chat\""))
              \(selectors)
              <span class="spacer"></span>
              \(activeSession().map { ctxIndicatorHTML($0) } ?? "")
              \(sendButton)
            </div>
          </form>
          \(filePop)
          <div id="slash-data" hidden>\(esc(slashDataJSON()))</div>
        </div>
        """
    }

    // MARK: Composer dropdown selectors (arc parity)

    /// Renders the four composer dropdown widgets (workspace, profile,
    /// model, thinking) as trigger buttons with server-rendered popovers,
    /// matching the arc agent webui look.
    func composerSelectorsHTML() -> String {
        let ws = (workspaceName(for: activeSessionID) ?? "")
        let profile = (profileName(for: activeSessionID) ?? "")
        let config = (configName(for: activeSessionID) ?? "")
        let model = settings.modelConfig(named: config)?.model ?? config
        let think = (thinkingLevel(for: activeSessionID) ?? "")

        let wsTrigger = ddTrigger(id: "cb-ws-toggle", icon: WebUIIcon(.folder, size: .small).render(),
                                  label: ws.isEmpty ? "Workspace" : ws, title: "Workspace")
        let ppTrigger = ddTrigger(id: "cb-profile-toggle", icon: WebUIIcon(.user, size: .small).render(),
                                  label: profile.isEmpty ? "Profile" : profile, title: "Profile")
        let mdTrigger = ddTrigger(id: "cb-model-toggle", icon: WebUIIcon(.box, size: .small).render(),
                                  label: model.isEmpty ? "Model" : model, title: "Model")
        let thTrigger = ddTrigger(id: "cb-think-toggle", icon: WebUIIcon(.circleGauge, size: .small).render(),
                                  label: think.isEmpty ? "Off" : think.capitalized, title: "Thinking")

        return wsDropdown(trigger: wsTrigger)
            + ppDropdown(trigger: ppTrigger)
            + mdDropdown(trigger: mdTrigger)
            + thDropdown(trigger: thTrigger)
    }

    private func ddTrigger(id: String, icon: String, label: String, title: String) -> String {
        // the full label rides the DOM — the chip's CSS ellipsis handles
        // overflow and `title` carries the whole name, so a clipped chip stays
        // hover-readable (the old server-side truncation lost the tail of the
        // name permanently, mid-word).
        let tip = label.isEmpty ? title : "\(title) — \(label)"
        return """
        <button type="button" id="\(id)" data-component-id="\(id)" class="dd-trigger" title="\(esc(tip))">
          \(icon)<span class="dd-trigger-label">\(esc(label))</span>\(WebUIIcon(.chevronDown, size: .small).render())
        </button>
        """
    }

    /// one dropdown row. the row carries only its id: the wire dispatches on
    /// `targetId`, and the engine reports the nearest id *inside* the boundary —
    /// so the boundary lives on the popover (`dd-pop`), never on the row.
    private func ddRow(id: String, body: String, extraClass: String = "") -> String {
        let cls = extraClass.isEmpty ? "dd-row" : "dd-row \(extraClass)"
        return """
        <button type="button" id="\(id)" class="\(cls)">\(body)</button>
        """
    }

    /// Workspace dropdown: search + list + (Choose path | Manage spaces).
    func wsDropdown(trigger: String) -> String {
        let vis = wsSelectOpen ? "" : " hidden"
        let q = wsSelectQuery.lowercased()
        var rows: [String] = []
        for ws in settings.workspaces {
            if !q.isEmpty && !ws.name.lowercased().contains(q) && !ws.path.lowercased().contains(q) { continue }
            let encWS = enc(ws.name)
            rows.append(ddRow(id: "ws-pick-\(encWS)", body: """
            <span class="dd-row-title">\(esc(ws.name))</span>
            <span class="dd-row-sub">\(esc(trunc(ws.path, 58)))</span>
            """))
        }
        let empty = rows.isEmpty
            ? "<div class=\"dd-empty\">No workspaces match “\(esc(wsSelectQuery))”</div>" : ""
        return """
        <div class="dd">
          \(trigger)
          <div class="dd-pop dd-pop-ws\(vis)" data-component-id="ws-pick" data-event="click">
            <div class="dd-search">
              <input id="ws-search-input" data-component-id="ws-search-input" data-event="input" data-no-restore type="text" placeholder="Search workspaces…" spellcheck="false" autocomplete="off" value="\(esc(wsSelectQuery))">
              \(wsSelectQuery.isEmpty ? "" : btn("ws-search-clear", "ws-search-clear", "dd-clear", WebUIIcon(.x, size: .small).render()))
            </div>
            <div class="dd-list">\(rows.joined())\(empty)</div>
            <div class="dd-foot">
              <button type="button" id="ws-choose-path" data-component-id="ws-choose-path" class="dd-foot-row">
                <span class="dd-foot-ico">\(WebUIIcon(.folderPlus, size: .small).render())</span>
                <span class="dd-foot-txt"><span class="dd-row-title">Choose workspace path</span><span class="dd-row-sub">Add a validated path and switch this conversation</span></span>
              </button>
              <button type="button" id="ws-manage" data-component-id="ws-manage" class="dd-foot-row">
                <span class="dd-foot-ico">\(WebUIIcon(.settings, size: .small).render())</span>
                <span class="dd-foot-txt"><span class="dd-row-title">Manage workspaces</span><span class="dd-row-sub">Open the Spaces panel</span></span>
              </button>
            </div>
          </div>
        </div>
        """
    }

    /// Profile dropdown: per-profile cards (dot, name + check, model · skills)
    /// plus a Manage profiles footer.
    func ppDropdown(trigger: String) -> String {
        let vis = profileSelectOpen ? "" : " hidden"
        let activeProfileName = profileName(for: activeSessionID) ?? ""
        let total = skills.count
        var rows: [String] = []
        for p in profiles {
            let on = !activeProfileName.isEmpty && p.name == activeProfileName
            let check = on ? " " + WebUIIcon(.check, size: .small).render() : ""
            let model = p.model ?? settings.modelConfig(named: settings.activeConfig)?.model ?? "inherit"
            // Skills are active by default; the runtime gates on
            // settings.disabledSkills (see Actions.swift), not profileSkills.
            let onCount = enabledSkillCount(for: p.name)
            let titleSuffix = p.title.isEmpty || p.title == p.name ? "" : " (\(esc(p.title)))"
            rows.append(ddRow(id: "pp-\(enc(p.name))", body: """
            <span class="dd-dot\(on ? " on" : "")"></span>
            <span class="dd-profile-main">
              <span class="dd-row-title">\(esc(p.name))\(titleSuffix)\(check)</span>
              <span class="dd-row-sub">\(esc(model)) · \(onCount) / \(total)</span>
              <span class="dd-row-sub">skills</span>
            </span>
            """, extraClass: "dd-profile-row"))
        }
        return """
        <div class="dd">
          \(trigger)
          <div class="dd-pop dd-pop-profile\(vis)" data-component-id="profile-pick" data-event="click">
            <div class="dd-list dd-list-profile">\(rows.joined())</div>
            <div class="dd-foot">
              <button type="button" id="pp-manage" data-component-id="pp-manage" class="dd-foot-row">
                <span class="dd-foot-ico">\(WebUIIcon(.settings, size: .small).render())</span>
                <span class="dd-foot-txt"><span class="dd-row-title">Manage profiles</span></span>
              </button>
            </div>
          </div>
        </div>
        """
    }

    /// Model dropdown: scope note + search + CONFIGURED list with badges.
    func mdDropdown(trigger: String) -> String {
        let vis = modelSelectOpen ? "" : " hidden"
        let active = configName(for: activeSessionID)
        let q = modelSelectQuery.lowercased()
        var rows: [String] = []
        for c in settings.modelConfigs {
            if !q.isEmpty && !c.name.lowercased().contains(q) && !c.model.lowercased().contains(q) { continue }
            let sel = c.name == active
            let selBadge = sel ? "<span class=\"dd-badge sel\">SELECTED</span>" : ""
            rows.append(ddRow(id: "mc-\(enc(c.name))", body: """
            <span class="dd-model-main">
              <span class="dd-row-title">\(esc(c.model))</span>
              <span class="dd-badges"><span class="dd-badge">\(esc(c.name.uppercased())) (CUSTOM)</span>\(selBadge)</span>
            </span>
            """))
        }
        let empty = rows.isEmpty
            ? "<div class=\"dd-empty\">No models match “\(esc(modelSelectQuery))”</div>" : ""
        return """
        <div class="dd">
          \(trigger)
          <div class="dd-pop dd-pop-model\(vis)" data-component-id="model-pick" data-event="click">
            <div class="dd-note">Applies to this conversation from your next message.</div>
            <div class="dd-search">
              <input id="model-search-input" data-component-id="model-search-input" data-event="input" data-no-restore type="text" placeholder="Search models…" spellcheck="false" autocomplete="off" value="\(esc(modelSelectQuery))">
              \(modelSelectQuery.isEmpty ? "" : btn("model-search-clear", "model-search-clear", "dd-clear", WebUIIcon(.x, size: .small).render()))
            </div>
            <div class="dd-section">CONFIGURED</div>
            <div class="dd-list">\(rows.joined())\(empty)</div>
          </div>
        </div>
        """
    }

    /// Thinking-level dropdown (arc-style pill trigger + level list).
    func thDropdown(trigger: String) -> String {
        let vis = thinkSelectOpen ? "" : " hidden"
        let current = thinkingLevel(for: activeSessionID)
        var rows: [String] = []
        for lv in ["off", "low", "medium", "high", "max"] {
            let on = lv == current
            let check = on ? " " + WebUIIcon(.check, size: .small).render() : ""
            rows.append(ddRow(id: "tp-\(lv)", body: """
            <span class="dd-row-title">\(lv.capitalized)\(check)</span>
            """))
        }
        return """
        <div class="dd">
          \(trigger)
          <div class="dd-pop dd-pop-think\(vis)" data-component-id="think-pick" data-event="click">
            <div class="dd-list">\(rows.joined())</div>
          </div>
        </div>
        """
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
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.star, size: .extraLarge).render())</div><div>Select a skill to see its description.</div></div>
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
                \(btn("sk-edit", "skill-edit", "icon-mini", WebUIIcon(.edit, size: .small).render(), " title=\"Edit skill\""))
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
        let form = """
        <form id="skill-create-form" data-component-id="skill-create-form" class="detail-card" style="max-width:720px">
          <h1 class="detail-title">New skill</h1>
          <div class="detail-sub">A skill is a SKILL.md file with YAML frontmatter (name, description) found under the skills directory.</div>
          <div class="form-grid">
            <div><label for="skill-name-input">Name</label><input id="skill-name-input" name="skill-name-input" data-component-id="skill-name-input" data-event="input" placeholder="my-skill"></div>
            <div><label for="skill-cat-input">Category</label><input id="skill-cat-input" name="skill-cat-input" data-component-id="skill-cat-input" data-event="input" placeholder="e.g. devops"></div>
            <div><label for="skill-desc-input">Description</label><input id="skill-desc-input" name="skill-desc-input" data-component-id="skill-desc-input" data-event="input" placeholder="Short description"></div>
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
        guard let name = selectedProfile,
              let p = profiles.first(where: { $0.name == name })
        else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.user, size: .extraLarge).render())</div><div>Select a profile to see its details.</div></div>
            </div>
            """
        }
        let card = profileCardHTML(p)
        let set = p.enabledToolsets ?? []
        let toolsetsNote = set.isEmpty ? "all (not overridden)" : set.joined(separator: ", ")
        let encName = enc(p.name)
        let isDefault = p.name == "default"
        let headIcons = btn("pr-edit-\(encName)", "", "icon-mini", WebUIIcon(.edit, size: .medium).render(), " title=\"Edit profile\"")
            + btn("pr-sel-\(encName)", "", "icon-mini", WebUIIcon(.check, size: .medium).render(), " title=\"Select profile for this chat\"")
            + (isDefault ? "" : btn("pr-del-\(encName)", "", "icon-mini danger", WebUIIcon(.trash, size: .medium).render(), " title=\"Delete profile\""))
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
            </div>
          </div>
        </div>
        """
    }

    func profileKV(_ p: Profile) -> String {
        var rows = ""
        rows += "<div class=\"kv\"><span class=\"k\">Name</span><span class=\"v\">\(esc(p.name))</span></div>"
        rows += "<div class=\"kv\"><span class=\"k\">Model</span><span class=\"v\">\(esc(p.model ?? "inherit"))</span></div>"
        rows += "<div class=\"kv\"><span class=\"k\">Provider</span><span class=\"v\">\(esc(p.provider ?? "inherit"))</span></div>"
        if let b = p.baseURL { rows += "<div class=\"kv\"><span class=\"k\">Base URL</span><span class=\"v\">\(esc(b))</span></div>" }
        return rows
    }

    /// Per-profile context parameters summary (kv rows; "inherit" when unset).
    func profileContextHTML(_ p: Profile) -> String {
        guard let ctx = p.context, !ctx.isEmpty else {
            return "<div class=\"kv\"><span class=\"k\">Context</span><span class=\"v\">inherit (no overrides)</span></div>"
        }
        var rows = ""
        rows += "<div class=\"kv\"><span class=\"k\">Context window</span><span class=\"v\">\(ctx.contextLength.map { "\($0) tokens" } ?? "inherit")</span></div>"
        rows += "<div class=\"kv\"><span class=\"k\">Max output</span><span class=\"v\">\(ctx.maxOutputTokens.map { "\($0) tokens" } ?? "inherit")</span></div>"
        rows += "<div class=\"kv\"><span class=\"k\">Reasoning effort</span><span class=\"v\">\(esc(ctx.reasoningEffort ?? "inherit"))</span></div>"
        rows += "<div class=\"kv\"><span class=\"k\">Temperature</span><span class=\"v\">\(ctx.temperature.map { String($0) } ?? "inherit")</span></div>"
        rows += "<div class=\"kv\"><span class=\"k\">Top P</span><span class=\"v\">\(ctx.topP.map { String($0) } ?? "inherit")</span></div>"
        rows += "<div class=\"kv\"><span class=\"k\">Compress at</span><span class=\"v\">\(ctx.compressionBudget.map { "\($0) tokens" } ?? "inherit")</span></div>"
        return rows
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
    /// badges (ACTIVE / (default) / Gateway running / code-block model).
    func profileCardHTML(_ p: Profile) -> String {
        let activeProfile = profileName(for: activeSessionID) ?? ""
        let isActive = !activeProfile.isEmpty && activeProfile == p.name
        let isDefault = p.name == "default"
        let skillCount = enabledSkillCount(for: p.name)
        let modelName = p.model ?? settings.modelConfig(named: settings.activeConfig)?.model ?? "inherit"
        let providerName = p.provider ?? "custom"
        let keyCount = settings.modelConfigs.filter { !$0.apiKey.isEmpty }.count
        let keyLabel = keyCount > 0 ? "\(keyCount) \(keyCount == 1 ? "key" : "keys") configured" : "None"
        let statusBadges = (isActive ? "<span class=\"pl-badge badge-active\">ACTIVE</span>" : "<span class=\"pl-badge badge-inactive\">INACTIVE</span>")
            + (isDefault ? " <span class=\"pl-badge badge-default\">(default)</span>" : "")
        let gateway = gatewayRunning
            ? "<span class=\"pl-badge badge-green\"><span class=\"pl-dot\"></span>Gateway running</span>"
            : "<span class=\"pl-badge badge-red\">Gateway stopped</span>"
        return """
        <div class="pl-card">
          <div class="pl-eyebrow">PROFILE</div>
          <div class="pl-row"><span class="pl-k">Status</span><span class="pl-v">\(statusBadges)</span></div>
          <div class="pl-row"><span class="pl-k">Gateway</span><span class="pl-v">\(gateway)</span></div>
          <div class="pl-row"><span class="pl-k">Model</span><span class="pl-v"><code class="pl-code">\(esc(modelName))</code></span></div>
          <div class="pl-row"><span class="pl-k">Provider</span><span class="pl-v">\(esc(providerName))</span></div>
          <div class="pl-row"><span class="pl-k">API key</span><span class="pl-v">\(esc(keyLabel))</span></div>
          <div class="pl-row"><span class="pl-k">Skills</span><span class="pl-v">\(skillCount) / \(skills.count) skills</span></div>
        </div>
        """
    }

    // MARK: Tools main

    func toolsMain() -> String {
        guard let name = selectedTool,
              let tool = registry.lookup(name: name)
        else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.tool, size: .extraLarge).render())</div><div>Select a tool to see its definition and parameters.</div></div>
            </div>
            """
        }
        let params = schemaHTML(tool.schema)
        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
            <div class="detail-card">
              <h1 class="detail-title">\(toolEmojiIcon(tool.emoji)) \(esc(tool.name))</h1>
              <div class="detail-sub">\(esc(tool.toolset)) toolset</div>
              <div class="kv"><span class="k">Description</span><span class="v">\(esc(tool.description))</span></div>
              <div class="kv"><span class="k">Toolset</span><span class="v">\(esc(tool.toolset))</span></div>
              <div class="kv"><span class="k">Requires env</span><span class="v">\(tool.requiresEnv.isEmpty ? "none" : esc(tool.requiresEnv.joined(separator: ", ")))</span></div>
              <h3 style="margin:16px 0 6px">Parameters</h3>
              \(params)
            </div>
          </div>
        </div>
        """
    }

    func pluginSettingsHTML() -> String {
        let names = pluginManifests.keys.sorted()
        guard !names.isEmpty else {
            return """
            <div class="set-row" style="flex-direction:column;align-items:stretch;gap:6px">
              <div class="set-label">No tool plugins found.</div>
              <div class="set-hint">Drop a directory with a <code>manifest.json</code> into <code>~/.arc/plugins/&lt;name&gt;/</code> and press Rescan. Each tool is an executable (or interpreter + script pair, e.g. <code>python3</code> + <code>tool.py</code>) that reads <code>{"tool": name, "args": {...}}</code> on stdin and writes <code>{"result": "..."}</code> on stdout. See <code>docs/plugin-tools.md</code> in the arc-agent repository for the full contract and examples.</div>
            </div>
            """
        }
        let allow = arcConfig.plugins.enabled
        let cards = names.map { name -> String in
            let m = pluginManifests[name]
            let on = allow?.contains(name) ?? true
            let tools = (m?.tools ?? []).map { $0.name }
            let toolChips = tools.map { "<span class='mc-badge' style='margin-right:4px'>\(esc($0))</span>" }.joined()
            return """
            <div class="set-row" style="flex-direction:column;align-items:stretch;gap:4px">
              <div style="display:flex;align-items:center;justify-content:space-between">
                <div class="set-label">\(esc(name)) <small>v\(esc(m?.version ?? "0.0.0"))</small></div>
                <label class="switch">
                  <input type="checkbox" id="plgl-\(enc(name))" value="plgl-\(enc(name))" data-component-id="plugin-toggle" data-event="change" data-no-restore \(on ? "checked" : "")>
                  <span class="track"></span><span class="knob"></span>
                </label>
              </div>
              <div class="set-hint">\(esc(m?.description ?? ""))</div>
              <div class="set-hint">\(tools.isEmpty ? "No tools" : "Tools: " + toolChips)</div>
            </div>
            """
        }.joined()
        return cards + """
        <div class="set-row">
          <div class="set-label">Rescan<small>Re-read <code>~/.arc/plugins</code> after adding or editing a plugin.</small></div>
          <button type="button" id="plugin-rescan" data-component-id="plugin-rescan" data-event="click" class="btn">Rescan plugins</button>
        </div>
        """
    }

    func schemaHTML(_ schema: JSONSchema) -> String {
        var rows: [String] = []
        switch schema {
        case .object(let desc, let properties, let required):
            if let d = desc { rows.append("<div class=\"kv\"><span class=\"k\">Object</span><span class=\"v\">\(esc(d))</span></div>") }
            let req = Set(required ?? [])
            for (key, prop) in properties.sorted(by: { $0.key < $1.key }) {
                let typeLabel = schemaTypeLabel(prop)
                let r = req.contains(key) ? " <span class='mc-badge' style='margin-left:6px'>required</span>" : ""
                let detail = schemaOneLine(prop)
                rows.append("<div class=\"kv\"><span class=\"k\">\(esc(key))<small style=\"color:var(--muted)\"> (\(esc(typeLabel)))</small></span><span class=\"v\">\(esc(detail))\(r)</span></div>")
            }
        case .array(let desc, let items):
            rows.append("<div class=\"kv\"><span class=\"k\">Array of</span><span class=\"v\">\(esc(schemaTypeLabel(items))) — \(esc(desc ?? ""))</span></div>")
        default:
            rows.append("<div class=\"kv\"><span class=\"k\">Type</span><span class=\"v\">\(esc(schemaTypeLabel(schema)))</span></div>")
            if let d = schemaDescription(schema) { rows.append("<div class=\"kv\"><span class=\"k\">Description</span><span class=\"v\">\(esc(d))</span></div>") }
        }
        return rows.joined()
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

    func workspacesMain() -> String {
        if createWorkspace {
            let form = """
            <form id="ws-create-form" data-component-id="ws-create-form" class="detail-card" style="max-width:560px">
              <h1 class="detail-title">New workspace</h1>
              <div class="detail-sub">A workspace points at any folder on this computer. The folder path is required and follows Unix path rules; the name is an optional label — leave it blank and it is derived from the folder. Sessions keep their own workspace per chat; you pick it in the chat composer.</div>
              <div class="form-grid">
                <div>
                  <label for="ws-path-input">Folder path</label>
                  <input id="ws-path-input" name="ws-path-input" data-component-id="ws-path-input" type="text" placeholder="/Users/you/research or ~/research" autofocus value="\(esc(formValues["ws-path-input"] ?? ""))">
                  <small style="color:var(--muted);font-size:0.75em">Required. An absolute path; ~ means your home folder.</small>
                </div>
                <div>
                  <label for="ws-name-input">Name (optional)</label>
                  <input id="ws-name-input" name="ws-name-input" data-component-id="ws-name-input" type="text" placeholder="derived from the folder name" value="\(esc(formValues["ws-name-input"] ?? ""))">
                  <small style="color:var(--muted);font-size:0.75em">A label for the switcher — any text except '/'.</small>
                </div>
              </div>
              <div class="row-actions-main">
                <button type="submit" class="primary-btn">Create</button>
                \(btn("ws-cancel", "ws-cancel", "ghost-btn", "Cancel"))
              </div>
            </form>
            """
            return """
            <div class="main-view">
              <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">\(form)</div>
            </div>
            """
        }
        let ws = settings.activeWorkspace
        let path = workspacePath(for: nil)
        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
            <div class="detail-card">
              <h1 class="detail-title">\(WebUIIcon(.grid, size: .large).render()) Workspaces</h1>
              <div class="detail-sub">Workspaces are folders on this computer. Each chat keeps its own workspace, chosen in the chat composer.</div>
              <div class="kv"><span class="k">Default</span><span class="v">\(esc(ws))</span></div>
              <div class="kv"><span class="k">Folder</span><span class="v">\(esc(path))</span></div>
              <div class="kv"><span class="k">Sessions</span><span class="v">\(sessions.count)</span></div>
              <div class="kv"><span class="k">Note</span><span class="v">All chats share one session list; switching a chat's workspace changes its working folder, not the conversation list.</span></div>
            </div>
          </div>
        </div>
        """
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
    func agentLimitsSection() -> String {
        let rawMax: Int? = arcConfig.agent.max_turns ?? arcConfig.max_turns
        let maxUnlimited = (rawMax ?? 1) <= 0
        let effMax = arcConfig.effectiveMaxTurns()
        let maxValue = effMax == Int.max ? 90 : effMax
        let rawLoop: Int? = arcConfig.guardrails.toolLoopCap
        let loopUnlimited = (rawLoop ?? 1) <= 0
        let effLoop = arcConfig.effectiveToolLoopCap()
        let loopValue = effLoop == Int.max ? 25 : effLoop
        func sw(_ id: String, _ on: Bool) -> String {
            "<label class=\"switch\"><input type=\"checkbox\" id=\"\(id)\" data-no-restore \(on ? "checked" : "")><span class=\"track\"></span><span class=\"knob\"></span></label>"
        }
        let numStyle = "width:96px;padding:8px;background:var(--code-bg);color:var(--text);border:1px solid var(--border);border-radius:6px;font-size:13px"
        return """
        <section class="set-section" id="agent-limits">
          <h2>Agent limits</h2>
          <div class="detail-card">
            <div class="set-row">
              <div class="set-label">Tool iteration limit<small>Tool-calling iterations allowed per turn before the agent is asked to wrap up (reference max_turns, default 90).</small></div>
              <div id="al-max-turns-wrap" data-component-id="al-max-turns" data-event="change">
                <input type="number" id="al-max-turns" min="1" step="1" value="\(maxValue)" \(maxUnlimited ? "disabled" : "") style="\(numStyle)">
              </div>
            </div>
            <div class="set-row">
              <div class="set-label">Unlimited tool iterations<small>No iteration cap: the turn keeps running until the agent finishes the prompt on its own.</small></div>
              <div id="al-max-turns-unl-wrap" data-component-id="al-max-turns-unlimited" data-event="change">
                \(sw("al-max-turns-unlimited", maxUnlimited))
              </div>
            </div>
            <div class="set-row" style="margin-top:14px">
              <div class="set-label">Per-tool call cap<small>How many times one tool may run per turn before a synthetic "N calls (cap N)" reply (default 25).</small></div>
              <div id="al-tool-cap-wrap" data-component-id="al-tool-cap" data-event="change">
                <input type="number" id="al-tool-cap" min="1" step="1" value="\(loopValue)" \(loopUnlimited ? "disabled" : "") style="\(numStyle)">
              </div>
            </div>
            <div class="set-row">
              <div class="set-label">Unlimited per-tool calls<small>No synthetic call cap for any tool in a turn.</small></div>
              <div id="al-tool-cap-unl-wrap" data-component-id="al-tool-cap-unlimited" data-event="change">
                \(sw("al-tool-cap-unlimited", loopUnlimited))
              </div>
            </div>
          </div>
        </section>
        """
    }

    func agentPowersSection() -> String {
        let powers = arcConfig.agentPowers
        func sw(_ id: String, _ on: Bool) -> String {
            "<label class=\"switch\"><input type=\"checkbox\" id=\"\(id)\" data-component-id=\"\(id)\" data-event=\"change\" data-no-restore \(on ? "checked" : "")><span class=\"track\"></span><span class=\"knob\"></span></label>"
        }
        /// Plain switch for per-item rows: NO data-component-id on the input,
        /// so the runtime resolves the component to the container div below
        /// (whose wire dispatches on `targetId`). With an id on the input the
        /// client would address the checkbox directly and the container wire
        /// would never fire.
        func swPlain(_ id: String, _ on: Bool) -> String {
            "<label class=\"switch\"><input type=\"checkbox\" id=\"\(id)\" value=\"\(id)\" data-no-restore \(on ? "checked" : "")><span class=\"track\"></span><span class=\"knob\"></span></label>"
        }
        let lockedNames = Set(powers.lockedSkills)
        var skillRows = ""
        for sk in skills {
            let locked = lockedNames.contains(sk.name)
            skillRows += "<div class=\"set-row\"><div class=\"set-label\">\(esc(sk.name))<small>Locked: skill_edit refuses this skill.</small></div>" + swPlain("ap-skill-lock-\(sk.name)", locked) + "</div>"
        }
        if skills.isEmpty {
            skillRows = "<div class=\"empty-hint\">No skills discovered yet.</div>"
        }
        skillRows = "<div id=\"ap-skill-locks\" data-component-id=\"ap-skill-locks\" data-event=\"change\" class=\"ap-skills-scroll\">" + skillRows + "</div>"
        let profileFiles: [(String, String, String)] = [
            ("memory", "MEMORY.md", "the agent's persistent notes (memory tool, profile_edit)"),
            ("user", "USER.md", "the user profile"),
            ("soul", "SOUL.md", "the profile persona/prompt"),
            ("agents", "AGENTS.md", "workspace project instructions"),
        ]
        var profileRows = ""
        for (key, label, detail) in profileFiles {
            let locked = powers.lockedProfileFiles.contains(key)
            profileRows += "<div class=\"set-row\"><div class=\"set-label\">\(label)<small>\(detail).</small></div>" + swPlain("ap-profilefile-lock-\(key)", locked) + "</div>"
        }
        profileRows = "<div id=\"ap-profilefile-locks\" data-component-id=\"ap-profilefile-locks\" data-event=\"change\">" + profileRows + "</div>"
        return """
        <section class="set-section" id="agent-powers">
          <h2>Agent powers</h2>
          <div class="detail-card">
            <h3 style="margin:0 0 6px">Skills</h3>
            <div class="set-row">
              <div class="set-label">Agent can create/edit skills<small>When off, skill_creation and skill_edit refuse, and write_file/terminal refuse writes under the skills directory. Skills become readable-only.</small></div>
              \(sw("ap-skills-global", powers.skillsManage))
            </div>
            <div class="detail-sub" style="margin:10px 0 4px">Locked skills<small>Individually locked skills cannot be edited (skill_edit refuses them).</small></div>
            \(skillRows)
          </div>
          <div class="detail-card" style="margin-top:12px">
            <h3 style="margin:0 0 6px">Profile (MEMORY / USER / SOUL / AGENTS)</h3>
            <div class="set-row">
              <div class="set-label">Agent can edit the profile<small>When off, profile_edit and the memory tool refuse writes to MEMORY/USER/SOUL/AGENTS, and write_file/terminal refuse those files.</small></div>
              \(sw("ap-profile-global", powers.profileEdit))
            </div>
            <div class="detail-sub" style="margin:10px 0 4px">Locked profile files<small>These cannot be edited by the agent while locked.</small></div>
            \(profileRows)
          </div>
        </section>
        """
    }


    /// Settings → Storage: medium picker (staged, not connected until
    /// "Save and Connect"), saved Tessera connections CRUD, and the active
    /// medium label. Mirrors the composer-dropdown component shapes (one wire
    /// on the popover container, rows carry only ids).
    func storageSettingsHTML() -> String {
        func storageMediumLabel(_ medium: String) -> String {
            if medium == "file" { return "Local file storage" }
            if medium == "config" { return "Default (config.json)" }
            return settings.storageConnections.first(where: { $0.id == medium })?.name ?? "Unknown storage"
        }
        func storagePickedLabel(_ medium: String) -> String {
            if medium == "file" { return "Local file storage" }
            if medium == "config" { return "Default (config.json)" }
            return settings.storageConnections.first(where: { $0.id == medium })?.name ?? "Unknown storage"
        }
        func storageRowBadges(active: Bool, staged: Bool) -> String {
            var b = ""
            if active { b += "<span class=\"dd-badge sel\">ACTIVE</span>" }
            if staged { b += "<span class=\"dd-badge\">SELECTED</span>" }
            return b
        }
        // The effective medium = what the RUNTIME is actually using. A hosted
        // daemon always boots config.json's tessera (or file), so while the
        // AppState is attached to the daemon's pair the truth is "config",
        // NOT the persisted picker choice (which may be stale after the user
        // saved a connection the daemon never applied). Once the picker has
        // actually connected (attach detached), the choice is the truth.
        let effectiveFile = runtimeBackend == "file"
        let effectiveMedium = effectiveFile ? "file" : (attachedStorage != nil ? "config" : settings.activeStorage)
        let storagePickVis = storagePickOpen ? "" : " hidden"
        var storagePickRows: [String] = []
        storagePickRows.append(ddRow(id: "storage-pick-file", body: """
        <span class="dd-row-title">Local file storage <span class="dd-badges">\(storageRowBadges(active: effectiveFile, staged: stagedStorage == "file"))</span></span>
        <span class="dd-row-sub">~/.arc/sessions + memories — always available, needs no relay</span>
        """))
        storagePickRows.append(ddRow(id: "storage-pick-config", body: """
        <span class="dd-row-title">Default (config.json) <span class="dd-badges">\(storageRowBadges(active: !effectiveFile && effectiveMedium == "config", staged: stagedStorage == "config"))</span></span>
        <span class="dd-row-sub">Tessera from the tessera block of ~/.arc/config.json</span>
        """))
        for conn in settings.storageConnections {
            storagePickRows.append(ddRow(id: "storage-pick-conn-\(enc(conn.id))", body: """
            <span class="dd-row-title">\(esc(conn.name)) <span class="dd-badges">\(storageRowBadges(active: !effectiveFile && effectiveMedium == conn.id, staged: stagedStorage == conn.id))</span></span>
            <span class="dd-row-sub">\(esc(conn.endpointLabel)) — app \(conn.application)\(incompleteNote(conn))</span>
            """))
        }
        let storagePickerHTML = """
        <div class="dd dd-settings">
          \(ddTrigger(id: "storage-pick-toggle", icon: WebUIIcon(.database, size: .small).render(), label: storageMediumLabel(effectiveMedium), title: "Storage medium in use"))
          <div class="dd-pop dd-pop-down\(storagePickVis)" data-component-id="storage-pick" data-event="click">
            <div class="dd-note">Pick a medium, then press <strong>Save and Connect</strong> to switch.</div>
            <div class="dd-list">\(storagePickRows.joined())</div>
          </div>
        </div>
        """
        let storageCanConnect = stagedStorage != nil && stagedStorage != effectiveMedium
        let storageStagedNote: String
        if let st = stagedStorage {
            storageStagedNote = "<div class=\"set-hint\" style=\"margin:2px 0 0 0\">Selected: <strong>\(esc(storagePickedLabel(st)))</strong> — not connected yet. Press <strong>Save and Connect</strong>.</div>"
        } else {
            storageStagedNote = ""
        }
        let storageConnRows = settings.storageConnections.map { conn -> String in
            let encID = enc(conn.id)
            let activeBadge = !effectiveFile && effectiveMedium == conn.id ? "<span class=\"mc-badge\">connected</span>" : ""
            let stagedBadge = stagedStorage == conn.id ? "<span class=\"mc-badge\">selected</span>" : ""
            return """
            <div class="mc-row">
              <span class="mc-name">\(esc(conn.name)) \(activeBadge)\(stagedBadge)</span>
              <span class="mc-model">\(esc(conn.endpointLabel)) · app \(conn.application)\(incompleteNote(conn))</span>
              <div style="display:flex;gap:6px;align-items:center;flex-shrink:0">
                <div data-component-id="storage-edit" data-event="click">\(btn("storage-edit-\(encID)", "", "ghost-btn", "Edit", " style=\"padding:4px 10px;font-size:0.8em\""))</div>
                <div data-component-id="storage-del" data-event="click">\(btn("storage-del-\(encID)", "", "danger-btn", "Remove", " style=\"padding:4px 10px;font-size:0.8em\""))</div>
              </div>
            </div>
            """
        }.joined()
        let storageConnList = storageConnRows.isEmpty
            ? "<div class=\"empty-hint\">No tessera storages configured.</div>" : storageConnRows
        func incompleteNote(_ conn: TesseraStorageConnection) -> String {
            if let note = conn.completenessNote {
                return " — <span class=\"set-warn\">\(esc(note))</span>"
            }
            return ""
        }
        let se = storageEdit
        let storageConnForm = """
        <form id="storage-conn-form" data-component-id="storage-conn-form" class="form-grid" style="margin-top:14px;border-top:1px dashed var(--border);padding-top:14px">
          <input type="hidden" id="storage-edit-id" name="storage-edit-id" data-component-id="storage-edit-id" value="\(esc(se?.id ?? ""))">
          <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px">
            <div><label for="sc-name">Name</label><input id="sc-name" name="sc-name" data-component-id="sc-name" placeholder="Home relay" value="\(esc(se?.name ?? ""))"></div>
            <div><label for="sc-ip">Server IP / host</label><input id="sc-ip" name="sc-ip" data-component-id="sc-ip" placeholder="10.0.0.1" value="\(esc(se?.serverIP ?? ""))"></div>
            <div><label for="sc-port">Port</label><input id="sc-port" name="sc-port" data-component-id="sc-port" type="number" min="1" max="65535" placeholder="51820" value="\(se.map { String($0.serverPort) } ?? "")"></div>
          </div>
          <div><label for="sc-app">Application id</label><input id="sc-app" name="sc-app" data-component-id="sc-app" type="number" min="0" max="65535" placeholder="1" value="\(se.map { String($0.application) } ?? "")"></div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
            <div><label for="sc-pub">Server public key</label><input id="sc-pub" name="sc-pub" data-component-id="sc-pub" placeholder="base64 (32 bytes)" value="\(esc(se?.serverPublicKey ?? ""))"></div>
            <div><label for="sc-priv">Client private key</label><input id="sc-priv" name="sc-priv" data-component-id="sc-priv" type="password" placeholder="base64 (32 bytes)" value="\(esc(se?.myPrivateKey ?? ""))"></div>
          </div>
          <div class="row-actions-main" style="margin:0">
            <button type="submit" class="primary-btn">\(se == nil ? "Add storage" : "Update storage")</button>
            \(se == nil ? "" : btn("storage-cancel-edit", "storage-cancel-edit", "ghost-btn", "Cancel", " style=\"padding:4px 10px;font-size:0.8em\""))
          </div>
        </form>
        """

        return """
        <section class="set-section" id="storage">
          <h2>Storage</h2>
          <div class="detail-card">
            <h3 style="margin:0 0 6px">Storage medium</h3>
            <div class="detail-sub" style="margin-bottom:10px">Where sessions, memory and profiles are saved. Picking a medium only stages it — press <strong>Save and Connect</strong> to actually switch.</div>
            <div class="set-row" style="flex-direction:column;align-items:stretch;gap:8px">
              <div class="set-label">Connected storage<small>\(esc(storageDescription())).</small></div>
              <div style="display:flex;gap:10px;align-items:flex-start;flex-wrap:wrap">
                \(storagePickerHTML)
                <button type="button" id="storage-connect" data-component-id="storage-connect" class="primary-btn"\(storageCanConnect ? "" : " disabled")>Save and Connect</button>
              </div>
              \(storageStagedNote)
            </div>
          </div>
          <div class="detail-card" style="margin-top:12px">
            <h3 style="margin:0 0 6px">Tessera storages</h3>
            <div class="detail-sub" style="margin-bottom:10px">Connections to different Tessera relays (signed NOSTR event stores). A connection must be complete (IP, port, public key, client private key) before it can be picked and connected to.</div>
            \(storageConnList)
            \(storageConnForm)
          </div>
          <div class="detail-card" style="margin-top:12px">
            <div class="set-row">
              <div class="set-label">Mixture of Agents<small>Fan out reference-model advice before the main call. Reference models come from the <code>moa</code> block of ~/.arc/config.json; without them this does nothing.</small></div>
              <label class="switch">
                <input type="checkbox" id="set-moa" data-component-id="set-moa" data-event="change" data-no-restore \(settings.moaEnabled ? "checked" : "")>
                <span class="track"></span><span class="knob"></span>
              </label>
            </div>
          </div>
        </section>
        """
    }

    func settingsMain() -> String {
        // Appearance
        let themeDefs: [(key: String, label: String, icon: IconName, preview: String)] = [
            ("light", "Light", .sun,
             "background:#FFFFFF;border:1px solid rgba(0,0,0,0.14)"),
            ("dark", "Dark", .moon,
             "background:#0D1117;border:1px solid rgba(255,255,255,0.10)"),
            ("system", "System", .monitor,
             "background:linear-gradient(100deg,#FFFFFF 0%,#8B8B93 52%,#15151A 100%);border:1px solid rgba(0,0,0,0.12)"),
        ]
        let themeCards = themeDefs.map { t in
            let active = settings.theme == t.key ? " active" : ""
            return "<button type=\"button\" id=\"thm-\(t.key)\" data-theme-choice=\"\(t.key)\" class=\"theme-pick-btn\(active)\" title=\"\(t.label)\"><span class=\"thm-preview\" style=\"\(t.preview)\"><span class=\"thm-ic\">\(WebUIIcon(t.icon, size: .medium).render())</span></span><span class=\"thm-label\">\(t.label)</span></button>"
        }.joined()
        let sizeCards = ThemeSize.allCases.map { s in
            let active = settings.textSize == s.rawValue ? " active" : ""
            return "<button type=\"button\" id=\"fsz-\(s.rawValue)\" class=\"font-size-pick-btn\(active)\" title=\"\(s.label)\"><span class=\"fsz-preview\" style=\"font-size:\(s.previewPx)\">Aa</span><span class=\"fsz-label\">\(s.label)</span></button>"
        }.joined()
        // the scheme grid renders from the catalog: identity — id, label, swatch — comes from
        // the providers themselves, so the picker cannot list a scheme the sheet does not
        // carry, and adding one is a single declaration. `swatch[0]` is the accent (the
        // tile's border), the rest are the preview dots.
        let swatches = ArcThemeCatalog.entries.map { entry in
            let active = settings.colorScheme == entry.id ? " active" : ""
            let accent = entry.swatch.first ?? ""
            let dots = entry.swatch.dropFirst().map { d in
                "<span class=\"scheme-dot\" style=\"background:\(d)\"></span>"
            }.joined()
            return """
            <button type="button" id="scheme-\(enc(entry.id))" data-scheme-choice="\(esc(entry.id))" class="scheme-tile\(active)" title="\(esc(entry.label))" style="--sw-accent:\(accent)">
              <span class="scheme-dots">\(dots)</span>
              <span class="scheme-name">\(esc(entry.label))</span>
            </button>
            """
        }.joined()

        // Activity display (segmented choice; mirrors arc agent webui).
        let actOpts = [
            ("compact_worklog", "Compact Worklog"),
            ("transparent_stream", "Transparent Stream"),
            ("hide_all_activity", "Final answer only"),
        ].map { mode, label in
            let active = settings.activityDisplay == mode ? " active" : ""
            return "<button type=\"button\" id=\"actdisp-\(mode)\" class=\"bubble-opt\(active)\">\(label)</button>"
        }.joined()

        // Sidebar tabs (arc-style chips; Chat + Settings are always visible)
        let tabDefs: [(key: String, label: String)] = [
            ("skills", "Skills"), ("profiles", "Profiles"), ("tools", "Tools"),
            ("workspaces", "Workspace"), ("github", "GitHub"), ("kanban", "Kanban"), ("memory", "Memory"),
            ("insights", "Insights"), ("logs", "Logs"), ("tasks", "Tasks"), ("todos", "Todos"),
        ]
        // Chips follow the canonical sidebar order; state = hidden set.
        let chipKeys = settings.sidebarTabs.filter { key in tabDefs.contains { $0.key == key } }
            + tabDefs.map(\.key).filter { key in !settings.sidebarTabs.contains(key) }
        let tabChips = chipKeys.map { key -> String in
            let label = tabDefs.first { $0.key == key }?.label ?? key
            let on = !settings.hiddenSidebarTabs.contains(key)
            return """
            <label class="side-tab-chip\(on ? " on" : "")">
              <input type="checkbox" id="st-\(enc(key))" value="st-\(enc(key))" data-component-id="side-tab-chips" data-event="change" data-no-restore \(on ? "checked" : "")>
              <span>\(label)</span>
            </label>
            """
        }.joined()

        // Model config CRUD
        let mcRows = settings.modelConfigs.map { c -> String in
            let badge = c.name == settings.activeConfig ? "<span class=\"mc-badge\">active</span>" : ""
            let encName = enc(c.name)
            return """
            <div class="mc-row">
              <span class="mc-name">\(esc(c.name)) \(badge)</span>
              <span class="mc-model">\(esc(c.model))</span>
              <div class="row-actions-main" style="margin:0">
                \(btn("mc-use-\(encName)", "", "ghost-btn", "Use", " style=\"padding:4px 10px;font-size:0.8em\""))
                \(btn("mc-del-\(encName)", "", "danger-btn", "Remove", " style=\"padding:4px 10px;font-size:0.8em\""))
              </div>
            </div>
            """
        }.joined()

        let thinkOpts = ["off", "low", "medium", "high", "max"].map { lv in
            let sel = settings.thinkingLevel == lv ? " selected" : ""
            return "<option value=\"\(lv)\"\(sel)>\(lv.capitalized)</option>"
        }.joined()


        // Auxiliary models (reference auxiliary.<task>, edited into ~/.arc/config.json)
        let auxRows = AuxiliaryTask.allCases.map { task -> String in
            let ov = arcConfig.auxiliary.override(for: task)
            let has = ov?.isSet == true
            if auxEditingTask == task.key {
                let pv = ov?.provider ?? ""
                let mv = ov?.model ?? ""
                let bv = ov?.baseURL ?? ""
                let kv = ov?.apiKey ?? ""
                return """
                <div class="aux-editing">
                  <form id="aux-form-\(task.key)" data-component-id="aux-form">
                    <div class="aux-fields">
                      <label class="aux-field">Provider<input type="hidden" name="aux-task" value="\(task.key)"><input name="aux-provider" id="aux-provider-\(task.key)" value="\(esc(pv))" placeholder="auto"></label>
                      <label class="aux-field">Model<input name="aux-model" id="aux-model-\(task.key)" value="\(esc(mv))" placeholder="(main model)"></label>
                      <label class="aux-field">Base URL<input name="aux-base-url" id="aux-base-url-\(task.key)" value="\(esc(bv))" placeholder="(main base URL)"></label>
                      <label class="aux-field">API key<input name="aux-api-key" id="aux-api-key-\(task.key)" type="password" value="\(esc(kv))" placeholder="(main API key)"></label>
                    </div>
                    <div class="aux-actions" data-component-id="aux-edit" data-event="click">
                      <button type="submit" class="primary-btn">Save</button>
                      \(btn("aux-cancel-\(task.key)", "", "ghost-btn", "Cancel"))
                    </div>
                  </form>
                </div>
                """
            }
            let summary: String
            if let ov, has {
                if !ov.model.isEmpty {
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
            return """
            <div class="set-row">
              <div class="set-label">\(esc(task.displayName))<small>\(esc(task.detail)). Currently: \(esc(summary)).</small></div>
              <div class="aux-right" data-component-id="aux-edit" data-event="click">
                \(btn("aux-edit-\(task.key)", "", "ghost-btn", has ? "Edit" : "Configure"))
                \(has ? btn("aux-reset-\(task.key)", "", "ghost-btn", "Reset") : "")
              </div>
            </div>
            """
        }.joined()

        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll settings-wrap" data-scroll-key="main-scroll">
            <section class="set-section" id="appearance">
              <h2>Appearance</h2>
              <div class="detail-card">
                <div class="set-row" style="flex-direction:column;align-items:stretch;gap:6px">
                  <div class="set-label">Theme<small>Light, dark, or follow the system.</small></div>
                  <div class="thm-grid" data-component-id="theme-pick" data-event="click">\(themeCards)</div>
                </div>
                <div class="set-row" style="flex-direction:column;align-items:stretch;gap:6px">
                  <div class="set-label">Text size<small>Chat content, session names, workspace files, and memory text.</small></div>
                  <div class="fsz-grid" data-component-id="font-size-pick" data-event="click">\(sizeCards)</div>
                </div>
                <div class="set-row" style="flex-direction:column;align-items:stretch;gap:6px">
                  <div class="set-label">Color scheme<small>Full palette for the interface.</small></div>
                  <div class="scheme-grid" data-component-id="scheme-pick" data-event="click">\(swatches)</div>
                </div>
                  <div class="set-row">
                    <div class="set-label">Show conversation outline<small>Adds a floating button to the chat view that lists your sent messages; clicking one jumps to it.</small></div>
                    <label class="switch">
                      <input type="checkbox" id="set-showoutline" data-component-id="set-showoutline" data-event="change" data-no-restore \(settings.showConversationOutline ? "checked" : "")>
                      <span class="track"></span><span class="knob"></span>
                    </label>
                  </div>
                  <div class="set-row">
                    <div class="set-label">Activity display<small>How thinking and tool activity appear in chats.</small></div>
                    <div class="bubble-opts" data-component-id="activity-display" data-event="click">\(actOpts)</div>
                  </div>
                  <div class="set-row" style="flex-direction:column;align-items:stretch;gap:8px">
                    <div class="set-label">Sidebar tabs</div>
                    <div class="side-tab-chips">\(tabChips)</div>
                    <input type="hidden" id="sidebar-tab-order" data-component-id="sidebar-tab-order" data-event="change" value="\(esc(settings.sidebarTabs.joined(separator: ",")))">
                    <div class="set-hint">Choose which tabs appear in the sidebar and rail. Drag chips to reorder them. Chat and Settings are always visible.</div>
                  </div>

              </div>
            </section>

            <section class="set-section" id="preferences">
              <h2>Preferences</h2>
              <div class="detail-card" style="margin-bottom:12px">
                <div class="set-row">
                  <div class="set-label">Default thinking level<small>Applied to new chats; per-chat override in the composer.</small></div>
                  <select id="set-think" data-component-id="set-think" data-event="change">\(thinkOpts)</select>
                </div>
              </div>
              <div class="detail-card" style="margin-top:12px">
                <h3 style="margin:0 0 6px">Chat</h3>
                <div class="set-row">
                  <div class="set-label">Show token usage<small>Displays input/output token count below each assistant reply. Also toggled with <code>/usage</code>.</small></div>
                  <label class="switch">
                    <input type="checkbox" id="set-showtokens" data-component-id="set-showtokens" data-event="change" data-no-restore \(settings.showTokenUsage ? "checked" : "")>
                    <span class="track"></span><span class="knob"></span>
                  </label>
                </div>
                <div class="set-row">
                  <div class="set-label">Show token speed (TPS)<small>Displays tokens per second in assistant message headers while streaming and after a response completes. Off by default.</small></div>
                  <label class="switch">
                    <input type="checkbox" id="set-showtps" data-component-id="set-showtps" data-event="change" data-no-restore \(settings.showTps ? "checked" : "")>
                    <span class="track"></span><span class="knob"></span>
                  </label>
                </div>
                <div class="set-row">
                  <div class="set-label">Pinned conversations limit<small>Maximum number of active conversations that can be pinned in the sidebar. Default is 3.</small></div>
                  <input type="number" id="set-pinlimit" data-component-id="set-pinlimit" data-event="change" min="1" max="99" step="1" value="\(settings.pinnedSessionsLimit)" style="width:96px;padding:8px;background:var(--code-bg);color:var(--text);border:1px solid var(--border);border-radius:6px;font-size:13px">
                </div>
              </div>
              <div class="detail-card">
                <h3 style="margin:0 0 6px">Model configurations</h3>
                <div class="detail-sub" style="margin-bottom:10px">Add or remove the model configurations available in every chat's config selector.</div>
                <div data-component-id="modelcfg-list" data-event="click">\(mcRows.isEmpty ? "<div class=\"empty-hint\">No model configurations.</div>" : mcRows)</div>
                <form id="modelcfg-add-form" data-component-id="modelcfg-add-form" class="form-grid" style="margin-top:14px;border-top:1px dashed var(--border);padding-top:14px">
                  <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px">
                    <div><label for="mc-name">Name</label><input id="mc-name" name="mc-name" data-component-id="mc-name" placeholder="deepseek-v4-flash"></div>
                    <div><label for="mc-model">Model</label><input id="mc-model" name="mc-model" data-component-id="mc-model" placeholder="deepseek-v4-flash"></div>
                    <div><label for="mc-provider">Provider</label><input id="mc-provider" name="mc-provider" data-component-id="mc-provider" placeholder="custom"></div>
                  </div>
                  <div><label for="mc-baseurl">Base URL</label><input id="mc-baseurl" name="mc-baseurl" data-component-id="mc-baseurl" placeholder="https://api.openai.com/v1"></div>
                  <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
                    <div><label for="mc-apikey">API key (optional)</label><input id="mc-apikey" name="mc-apikey" data-component-id="mc-apikey" type="password" placeholder="sk-…"></div>
                    <div><label for="mc-ctx">Context length (optional)</label><input id="mc-ctx" name="mc-ctx" data-component-id="mc-ctx" type="text" placeholder="128000"></div>
                    <div><label for="mc-maxtok">Max output tokens (optional)</label><input id="mc-maxtok" name="mc-maxtok" data-component-id="mc-maxtok" type="text" placeholder="32768"></div>
                  </div>
                  <div class="row-actions-main" style="margin:0">
                    <button type="submit" class="primary-btn">Add configuration</button>
                  </div>
                </form>
              </div>

              <div class="detail-card" style="margin-top:12px">
                <h3 style="margin:0 0 6px">Auxiliary models</h3>
                <div class="detail-sub" style="margin-bottom:10px">Auxiliary tasks (vision, compression, approval, titles, …) use a dedicated model from the <code>auxiliary</code> block of ~/.arc/config.json. Empty overrides fall back to the chat's main model.</div>
                \(auxRows)
              </div>
            </section>

            <section class="set-section" id="assistance">
              <h2>Assistance &amp; approvals</h2>
              <div class="detail-card">
                <div class="set-row">
                  <div class="set-label">Smart approval<small>Flagged commands are assessed by the <code>approval</code> auxiliary model (reference smart mode): low risk auto-approves, high risk is denied, uncertainty still prompts. Off = classic prompt for every flagged command. <code>approvals: off</code> in ~/.arc/config.json always wins.</small></div>
                  <label class="switch">
                    <input type="checkbox" id="set-smart-approval" data-component-id="set-smart-approval" data-event="change" data-no-restore \(settings.smartApproval ? "checked" : "")>
                    <span class="track"></span><span class="knob"></span>
                  </label>
                </div>
                <div class="set-row">
                  <div class="set-label">Smart pick-a-path<small>When a pick-a-path question times out (120 s), the <code>clarify</code> auxiliary model chooses the best offered answer instead of the agent's unguided judgement.</small></div>
                  <label class="switch">
                    <input type="checkbox" id="set-smart-pickapath" data-component-id="set-smart-pickapath" data-event="change" data-no-restore \(settings.smartPickAPath ? "checked" : "")>
                    <span class="track"></span><span class="knob"></span>
                  </label>
                </div>
              </div>
            </section>

            \(agentLimitsSection())

            \(agentPowersSection())

            \(storageSettingsHTML())

            <section class="set-section" id="tool-plugins">
              <h2>Tool plugins</h2>
              <div class="detail-card">
                <div class="set-row" style="flex-direction:column;align-items:stretch;gap:6px">
                  <div class="set-label">Integrate tools<small>Tools written as Python scripts or Swift executables, discovered from <code>~/.arc/plugins/</code> (arc plugin parity). Enablement is stored in the <code>plugins.enabled</code> allow-list of <code>~/.arc/config.json</code>.</small></div>
                </div>
                \(pluginSettingsHTML())
              </div>
            </section>

            <section class="set-section" id="about">
              <h2>About</h2>
              <div class="detail-card">
                <div class="kv"><span class="k">Version</span><span class="v">\(esc(ArcAgentCore.version)) (webui \(esc(WebUIVersion.version)))</span></div>
                <div class="kv"><span class="k">Workspace</span><span class="v">\(esc(workspaceName(for: activeSessionID))) — \(esc(workspacePath(for: activeSessionID)))</span></div>
                <div class="kv"><span class="k">Sessions</span><span class="v">\(sessions.count)</span></div>
                <div class="kv"><span class="k">Skills</span><span class="v">\(skills.count)</span></div>
                <div class="kv"><span class="k">Tools</span><span class="v">\(registry.allTools.count)</span></div>
                <div class="kv"><span class="k">Profiles</span><span class="v">\(profiles.count)</span></div>
              </div>
            </section>
          </div>
        </div>
        """
    }
}

extension AppState {
    // MARK: Kanban

    func kanbanPanel() -> String {
        let newBtn = btn("kb-addcol", "kb-addcol", "plus-btn", addingColumn ? WebUIIcon(.x, size: .small).render() : WebUIIcon(.plus, size: .small).render(), " title=\"" + (addingColumn ? "Cancel" : "Add column") + "\"")
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
            let confirm = confirmColumn == col.id ? " Confirm?" : WebUIIcon(.x, size: .small).render()
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
              <div class="blank"><div class="big">\(WebUIIcon(.columns, size: .extraLarge).render())</div><div>No columns yet — add one in the panel.</div></div>
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
            add = """
            <form id="kb-addcard-form" data-component-id="kb-addcard-form" class="kb-addcard-form">
              <input id="kb-addcard-name" name="kb-addcard-name" data-component-id="kb-addcard-name" type="text" placeholder="Card title" autofocus>
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
              \(btn("kb-rencol-\(cid)", "", "icon-mini", WebUIIcon(.edit, size: .small).render(), " title=\"Rename column\" data-colid=\"\(col.id)\""))
              \(btn("kb-bdel-\(cid)", "", confirmColumn == col.id ? "icon-mini danger sess-confirm" : "icon-mini danger", confirmColumn == col.id ? "Confirm?" : WebUIIcon(.x, size: .small).render(), " title=\"Delete column\""))
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
        let left = idx > 0 ? btn("kb-movel-\(encc)", "", "icon-mini", WebUIIcon(.chevronLeft, size: .small).render(), " title=\"Move left\"") : ""
        let right = idx < settings.kanbanColumns.count - 1 ? btn("kb-mover-\(encc)", "", "icon-mini", WebUIIcon(.chevronRight, size: .small).render(), " title=\"Move right\"") : ""
        return """
        <div class="kb-card">
          <div class="kb-card-title" data-cardid="\(card.id)">\(esc(trunc(card.title, 70)))</div>
          <div class="kb-card-actions">
            \(btn("kb-edit-\(encc)", "", "icon-mini", WebUIIcon(.edit, size: .small).render(), " title=\"Edit title\" data-cardid=\"\(card.id)\""))
            \(left)\(right)
            \(btn("kb-del-\(encc)", "", "icon-mini danger", WebUIIcon(.x, size: .small).render(), " title=\"Delete card\""))
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
            ("memory", "My Notes", "MEMORY.md", WebUIIcon(.fileText, size: .large).render()),
            ("user", "User Profile", "USER.md", WebUIIcon(.user, size: .large).render()),
            ("soul", "Agent Soul", "SOUL.md", WebUIIcon(.star, size: .large).render()),
            ("context", "Project Context", "AGENTS.md", WebUIIcon(.folder, size: .large).render()),
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
              <div class="blank"><div class="big">\(WebUIIcon(.database, size: .extraLarge).render())</div><div>Select a document from the panel.</div></div>
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
            ? "<div class=\"empty-hint\">\(esc(sub)) is empty. Press " + WebUIIcon(.edit, size: .small).render() + " to start writing.</div>"
            : mdBox(memoryContent)
        return """
        <div class="main-view"><div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
          <div class="detail-card">
            <div class="mem-head">
              <div><h1 class="detail-title" style="margin:0">\(title)</h1><div class="detail-sub">\(esc(sub)) — \(esc(meta.note))</div></div>
              \(btn("mem-edit", "mem-edit", "icon-mini", WebUIIcon(.edit, size: .small).render(), " title=\"Edit \(esc(sub))\""))
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
          \(btn("log-clear", "log-clear", "icon-mini", WebUIIcon(.trash, size: .small).render(), " title=\"Clear logs\""))
        </div>
        """
        let chips = ["all", "info", "warn", "error"].map { lvl -> String in
            let label = lvl == "all" ? "All" : (lvl == "info" ? "Info" : (lvl == "warn" ? "Warn" : "Error"))
            let active = logFilter == lvl ? " active" : ""
            return "<button type=\"button\" id=\"log-filter-\(lvl)\" class=\"chip-btn\(active)\">\(label)</button>"
        }.joined()
        return """
        \(head)
        <div class="panel-body">
          <div class="log-stats">
            <span class="log-stat"><span class="dot dot-info"></span>\(info)</span>
            <span class="log-stat"><span class="dot dot-warn"></span>\(warn)</span>
            <span class="log-stat"><span class="dot dot-err"></span>\(err)</span>
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
    /// Only rendered while the panel is closed — the panel is dismissed via
    /// its own ✕, so the arrow disappears once the panel is open.
    func workspaceDockHTML() -> String {
        guard !workspaceOpen else { return "<div id=\"ws-dock\"></div>" }
        return """
        <div id="ws-dock" data-component-id="workspace" data-event="click">
          <button type="button" id="w-dock" class="ws-dock-btn" title="Open workspace">\(WebUIIcon(.chevronLeft, size: .medium).render())</button>
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
            <button type="button" id="w-hidden" class="\(showHiddenFiles ? "menu-sel" : "")">\(showHiddenFiles ? "<span class=\"chk\">" + WebUIIcon(.checkSquare, size: .small).render() + "</span>" : "<span class=\"chk\">" + WebUIIcon(.square, size: .small).render() + "</span>") Show hidden files</button>
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
              \(btn("w-new", "", "icon-mini", WebUIIcon(.plus, size: .small).render(), " title=\"New file\""))
              \(btn("w-newfolder", "", "icon-mini", WebUIIcon(.folder, size: .small).render(), " title=\"New folder\""))
              \(btn("w-upload", "", "icon-mini", WebUIIcon(.upload, size: .small).render(), " title=\"Upload files or drop them here\""))
              \(wsMenu)
              \(btn("w-close", "", "icon-mini", WebUIIcon(.x, size: .small).render(), " title=\"Close workspace\""))
            </div>
          </div>
          \(create)
          <div class="ws-body" id="ws-tree" data-component-id="workspace" data-event="click" data-root="\(esc(panelWorkspacePath()))">
            <div class="ws-path" title="\(esc(panelWorkspacePath()))">\(esc(panelWorkspacePath()))</div>
            \(workspaceTreeHTML())
          </div>
        </div>
        """
    }

    func workspaceTreeHTML() -> String {
        let root = URL(fileURLWithPath: panelWorkspacePath())
        let fm = FileManager.default
        var lines: [String] = []
        var count = 0
        func walk(_ dir: URL, rel: String, depth: Int) {
            guard depth <= 8, count < 600 else { return }
            let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            var entries = all
            if !showHiddenFiles {
                entries = entries.filter { !$0.lastPathComponent.hasPrefix(".") }
            }
            entries.sort { a, b in
                let ada = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let adb = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if ada != adb { return ada }
                return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
            }
            let pad = 12 + depth * 15
            for entry in entries {
                let name = entry.lastPathComponent
                let relPath = rel.isEmpty ? name : rel + "/" + name
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let encPath = enc(relPath)
                count += 1
                if count > 600 { return }
                if isDir {
                    let expanded = expandedPaths.contains(relPath)
                    let caret = expanded ? WebUIIcon(.chevronDown, size: .small).render() : WebUIIcon(.chevronRight, size: .small).render()
                    lines.append("<button type=\"button\" id=\"w-toggle-\(encPath)\" class=\"ws-row\" style=\"padding-left:\(pad)px\" title=\"\(esc(relPath))\"><span class=\"ws-caret\">\(caret)</span><span class=\"ws-ic\">\(WebUIIcon(.folder, size: .small).render())</span><span class=\"ws-name\">\(esc(name))</span></button>")
                    if expanded { walk(entry, rel: relPath, depth: depth + 1) }
                } else {
                    lines.append("<button type=\"button\" id=\"w-file-\(encPath)\" class=\"ws-row\" style=\"padding-left:\(pad + 4)px\" title=\"\(esc(relPath))\"><span class=\"ws-ic\">\(wsFileIcon(name))</span><span class=\"ws-name\">\(esc(name))</span></button>")
                }
            }
        }
        walk(root, rel: "", depth: 0)
        if lines.isEmpty {
            lines.append("<div class=\"empty-hint\">This workspace is empty.</div>")
        }
        return lines.joined()
    }

    func wsFileIcon(_ name: String) -> String {
        return WebUIIcon(.file, size: .small).render()
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

// MARK: - GitHub page

extension AppState {

    /// Left panel: repository summary + commit list (newest first). Unpushed
    /// commits carry the theme-accent badge; the selected commit is active.
    func githubPanel() -> String {
        let refreshBtn = btn("gh-refresh", "gh-refresh", "icon-btn",
                             WebUIIcon(.refreshCw, size: .medium).render(), " title=\"Refresh repository\" data-tip=\"Refresh\"")
        let head = """
        <div class="panel-head">
          <span class="panel-title">GitHub</span>
          <div class="panel-actions">\(refreshBtn)</div>
        </div>
        """
        let body: String
        switch githubPage {
        case .idle, .loading:
            body = "<div class=\"empty-hint\">Loading repository…</div>"
        case .notARepo(let path):
            body = """
            <div class="gh-notice">
              <div class="gh-notice-title">Not a git project</div>
              <div class="gh-notice-body">The workspace <code>\(esc(path))</code> is not a git repository, so there is nothing to show. Open a chat whose workspace is a git project, or change the default workspace under Settings → Workspaces.</div>
            </div>
            """
        case .error(let msg):
            body = "<div class=\"empty-hint\">\(esc(msg))</div>"
        case .repo(let path, let branch, let remote):
            var meta: [String] = []
            if let branch { meta.append("branch <b>\(esc(branch))</b>") }
            if let remote { meta.append("<span class=\"gh-remote\">\(esc(remote))</span>") }
            let unpushedCount = githubCommits.filter(\.unpushed).count
            var sub = "\(esc(path)) · \(githubCommits.count) commits"
            if unpushedCount > 0 {
                sub += " · <span class=\"gh-unpushed\">\(unpushedCount) unpushed</span>"
            }
            let summary = """
            <div class="gh-summary">
              <div class="gh-summary-meta">\(meta.joined(separator: " · "))</div>
              <div class="gh-summary-sub">\(sub)</div>
            </div>
            """
            let rows = githubCommits.map { githubCommitRow($0) }.joined()
            if githubCommits.isEmpty {
                body = summary + "<div class=\"empty-hint\">No commits found.</div>"
            } else {
                body = summary + "<div class=\"gh-list\" data-component-id=\"gh-commit\" data-event=\"click\">\(rows)</div>"
            }
        }
        return head + "<div class=\"panel-body gh-panel-body\" id=\"gh-list-body\">\(body)</div>"
    }

    /// Standard panel-body padding + spacing so the GitHub page sizes like
    /// the Workspaces/Todos sections (width comes from `#panel`/`--panel-w`).

    private func githubCommitRow(_ c: GitHubCommit) -> String {
        let active = c.sha == githubSelectedSHA ? " active" : ""
        let unpushed = c.unpushed ? "<span class=\"gh-unpushed-badge\">↑ unpushed</span>" : ""
        let refs = c.refs.isEmpty
            ? ""
            : "<span class=\"gh-refs\">\(esc(trunc(c.refs, 40)))</span>"
        let date = ghShortDate(c.dateISO)
        return """
        <button type="button" id="gh-commit-\(c.sha)" class="gh-commit\(active)">
          <span class="gh-commit-row">
            <span class="gh-sha">\(esc(c.short))</span>
            <span class="gh-commit-subject">\(esc(trunc(c.subject, 56)))</span>
          </span>
          <span class="gh-commit-meta">\(esc(c.author)) · \(date)\(unpushed)</span>
          \(refs.isEmpty ? "" : "<span class=\"gh-commit-refs\">\(refs)</span>")
        </button>
        """
    }

    /// Main pane: the selected commit's message + file changes.
    func githubMain() -> String {
        guard let sha = githubSelectedSHA else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.gitBranch, size: .extraLarge).render())</div><div>Select a commit on the left to see its message and files.</div></div>
            </div>
            """
        }
        guard let detail = githubDetail else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div>Loading commit \(esc(sha))…</div></div>
            </div>
            """
        }
        let filesHTML = detail.files.map { f -> String in
            let plus = f.insertions > 0 ? "<span class=\"gh-num-add\">+\(f.insertions)</span>" : ""
            let minus = f.deletions > 0 ? "<span class=\"gh-num-del\">−\(f.deletions)</span>" : ""
            return """
            <div class="gh-file">
              <span class="gh-status \(f.statusClass)">\(esc(f.statusLabel))</span>
              <span class="gh-file-path">\(esc(f.path))</span>
              <span class="gh-nums">\(plus)\(minus)</span>
            </div>
            """
        }.joined()
        let bodyHTML = detail.body.isEmpty
            ? ""
            : "<div class=\"gh-body\">\(esc(detail.body))</div>"
        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
            <div class="detail-card gh-detail">
              <div class="gh-detail-subject">\(esc(detail.subject))</div>
              <div class="gh-detail-meta">
                <span class="gh-sha">\(esc(detail.sha))</span> · \(esc(detail.author)) · \(ghShortDate(detail.dateISO))
              </div>
              \(bodyHTML)
              <div class="gh-files-head">Files changed <span class="gh-files-count">\(detail.files.count)</span></div>
              <div class="gh-files">\(filesHTML.isEmpty ? "<div class=\"empty-hint\">No file changes (merge or empty commit).</div>" : filesHTML)</div>
            </div>
          </div>
        </div>
        """
    }

    /// Compact display date for a git ISO-8601 timestamp (%aI).
    private func ghShortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let date = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d, HH:mm"
        return out.string(from: date)
    }
}

/// Map a harness tool emoji to its colorless line-drawing equivalent.
/// Unknown or nil emoji render nothing (or a generic file glyph for a
/// non-nil unknown), so no colored emoji ever reaches the UI.
func toolEmojiIcon(_ emoji: String?) -> String {
    guard let e = emoji, !e.isEmpty else { return "" }
    switch e {
    case "📋": return WebUIIcon(.fileText, size: .small).render()
    case "🔍": return WebUIIcon(.search, size: .small).render()
    case "💬": return WebUIIcon(.messageSquare, size: .small).render()
    case "➕": return WebUIIcon(.plus, size: .small).render()
    case "🗑️", "🗑": return WebUIIcon(.trash, size: .small).render()
    case "👥": return WebUIIcon(.user, size: .small).render()
    case "📄": return WebUIIcon(.file, size: .small).render()
    case "🌐": return WebUIIcon(.globe, size: .small).render()
    case "🔄": return WebUIIcon(.refreshCw, size: .small).render()
    case "💻": return WebUIIcon(.terminal, size: .small).render()
    case "🧠": return WebUIIcon(.database, size: .small).render()
    case "✏️", "✏": return WebUIIcon(.edit, size: .small).render()
    case "🎯": return WebUIIcon(.target, size: .small).render()
    case "⏹️", "⏹": return WebUIIcon(.stopCircle, size: .small).render()
    case "📚", "📖": return WebUIIcon(.book, size: .small).render()
    case "✅": return WebUIIcon(.check, size: .small).render()
    case "🚫": return WebUIIcon(.x, size: .small).render()
    default: return WebUIIcon(.file, size: .small).render()
    }
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
