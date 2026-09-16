import ArcAgentCore
import Foundation
import WebUI

// MARK: - AppState: UI actions (controller-facing)

extension AppState {

    // MARK: Navigation + mode flags

    func switchView(_ v: ViewID) {
        activeView = v
        createSkill = false
        skillEdit = false
        createProfile = false
        createWorkspace = false
        pendingDelete = false
        filePopOpen = false
        confirmDeleteID = nil
    }

    func setLogFilter(_ f: String) {
        logFilter = f
    }

    func isLogsView() -> Bool {
        activeView == .logs
    }

    /// Chat-region fragments (panel + main + toasts).
    /// Append a message to a session by index and persist it (used for
    /// local slash-command echoes).
    func appendToSession(idx: Int, message: Message) async {
        guard sessions.indices.contains(idx) else { return }
        sessions[idx].messages.append(message)
        sessionVersion += 1
        if let store {
            await persistMessage(message, sessionID: sessions[idx].id, store: store)
        }
    }

    func chatFragments() async -> [FragmentUpdate] {
        await refreshFragments()
    }

    /// Panel-only fragment (used by filter search + skill panels).
    func skillPanelFragment() async -> [FragmentUpdate] {
        [FragmentUpdate(id: "panel", html: panelHTML())]
    }

    func setCreateSkill(_ on: Bool) {
        createSkill = on
        if on { selectedSkill = nil }
    }

    func setCreateProfile(_ on: Bool) {
        createProfile = on
        if on { selectedProfile = nil }
    }

    func setCreateWorkspace(_ on: Bool) {
        createWorkspace = on
    }

    func setActiveSession(_ id: String) async {
        activeSessionID = id
        pendingDelete = false
        filePopOpen = false
        attachments = []
        forceScrollBottom = true
        // Follow the chat's own workspace (right panel + composer selector).
        if let id = activeSessionID {
            selectedWorkspace = settings.sessionWorkspaces[id] ?? settings.activeWorkspace
            // Lazy design: fetch this chat's messages on open (and evict
            // least-recently-opened bodies beyond the cache cap).
            await ensureSessionMessages(id)
        }
        evictOverloadedCache()
    }

    func clearPendingDelete() {
        pendingDelete = false
    }

    /// Mark the next chat-scroll render with `data-follow="bottom"` so a
    /// full page load always opens the active conversation at the bottom.
    func armScrollToBottom() {
        forceScrollBottom = true
    }

    /// Open a shared conversation link (`?s=<id>`): select the session (also
    /// revealing it in the panel when archived) and scroll the chat to bottom.
    func openDeepLink(_ id: String) async {
        await reloadSessions(selecting: id)
        guard activeSessionID == id else { return }
        await setActiveSession(id)
        if isArchived(id) {
            setShowArchived(true)
        }
    }

    // MARK: Toasts

    @discardableResult
    func hint(_ text: String, kind: String = "info") -> Toast {
        toast(text, kind: kind)
    }

    // MARK: Form values

    func storeFormValue(_ key: String, _ value: String) {
        formValues[key] = value
    }

    /// Per-chat composer draft (Hermes parity). Persisted with a 1.5 s
    /// debounce so keystrokes don't hammer the settings file.
    func storeComposerDraft(_ text: String, sessionID: String) {
        settings.composerDrafts[sessionID] = text
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self.saveSettings()
        }
    }

    func readFormValue(_ key: String) -> String {
        formValues[key] ?? ""
    }

    // MARK: Chat composer

    func toggleFilePop() {
        filePopOpen.toggle()
    }

    // MARK: Composer dropdowns (Hermes parity)

    /// Close every composer dropdown (openers close their siblings) and
    /// reset the live-search filters so the next open is fresh.
    func closeComposerSelectors() {
        wsSelectOpen = false
        profileSelectOpen = false
        modelSelectOpen = false
        thinkSelectOpen = false
        wsSelectQuery = ""
        modelSelectQuery = ""
    }

    /// Toggle a composer dropdown: re-clicking an open trigger closes it.
    func toggleWSSelect() {
        let wasOpen = wsSelectOpen
        closeComposerSelectors()
        if !wasOpen { wsSelectOpen = true }
    }

    func toggleProfileSelect() {
        let wasOpen = profileSelectOpen
        closeComposerSelectors()
        if !wasOpen { profileSelectOpen = true }
    }

    func toggleModelSelect() {
        let wasOpen = modelSelectOpen
        closeComposerSelectors()
        if !wasOpen { modelSelectOpen = true }
    }

    func toggleThinkSelect() {
        let wasOpen = thinkSelectOpen
        closeComposerSelectors()
        if !wasOpen { thinkSelectOpen = true }
    }

    func setWSSelectQuery(_ q: String) {
        wsSelectQuery = q
    }

    func setModelSelectQuery(_ q: String) {
        modelSelectQuery = q
    }

    /// Mark the HTTP/WS server as bound (shown in the profile card).
    func markGatewayUp() {
        gatewayRunning = true
    }

    func addAttachment(_ path: String) {
        guard !attachments.contains(path) else { return }
        attachments.append(path)
        settings.recentFiles.removeAll { $0 == path }
        settings.recentFiles.insert(path, at: 0)
        if settings.recentFiles.count > 10 { settings.recentFiles = Array(settings.recentFiles.prefix(10)) }
        saveSettings()
        filePopOpen = false
        formValues["file-path-input"] = ""
    }

    func removeAttachment(_ index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    func toggleBookmarkActive() {
        guard let id = activeSessionID else { return }
        toggleBookmark(id)
    }

    func toggleBookmark(_ id: String) {
        if settings.bookmarkedSessions.contains(id) {
            settings.bookmarkedSessions.removeAll { $0 == id }
        } else {
            // Hermes parity: cap the number of pinned conversations. Count
            // only non-archived pins; reaching the limit blocks the pin next.
            let limit = max(1, settings.pinnedSessionsLimit)
            let pinnedCount = settings.bookmarkedSessions.filter { !settings.archivedSessions.contains($0) }.count
            if pinnedCount >= limit {
                hint("Only \(limit) conversations can be pinned. Unpin one before pinning another.", kind: "error")
                return
            }
            settings.bookmarkedSessions.append(id)
        }
        saveSettings()
    }

    // MARK: Chat preferences (Hermes parity)

    /// Toggle input/output token usage below assistant replies (/usage command).
    func toggleShowTokenUsage() {
        settings.showTokenUsage.toggle()
        saveSettings()
    }

    func setShowTokenUsage(_ on: Bool) {
        guard settings.showTokenUsage != on else { return }
        settings.showTokenUsage = on
        saveSettings()
    }

    func setShowTps(_ on: Bool) {
        guard settings.showTps != on else { return }
        settings.showTps = on
        saveSettings()
    }

    func setPinnedSessionsLimit(_ n: Int) {
        let clamped = min(max(n, 1), 99)
        guard settings.pinnedSessionsLimit != clamped else { return }
        settings.pinnedSessionsLimit = clamped
        saveSettings()
    }

    func setChatProfile(_ name: String) {
        guard let id = activeSessionID else { return }
        if name.isEmpty { settings.sessionProfile.removeValue(forKey: id) }
        else { settings.sessionProfile[id] = name }
        saveSettings()
    }

    func setChatConfig(_ name: String) {
        guard let id = activeSessionID else { return }
        if name.isEmpty { settings.sessionConfig.removeValue(forKey: id) }
        else { settings.sessionConfig[id] = name }
        saveSettings()
    }

    func setChatThinking(_ level: String) {
        guard let id = activeSessionID else { return }
        if level.isEmpty { settings.sessionThinking.removeValue(forKey: id) }
        else { settings.sessionThinking[id] = level }
        saveSettings()
    }

    // MARK: Session deletion (centered confirmation modal)

    func requestDeleteSession(_ id: String) {
        confirmDeleteID = id
    }

    func cancelDelete() {
        confirmDeleteID = nil
    }

    func confirmDeleteSession(_ id: String?) async {
        guard let store, let id else { return }
        confirmDeleteID = nil
        do {
            try await store.delete(id: id)
        } catch {
            LogCollector.shared.append(level: .error, text: "[store] failed to delete session \(String(id.prefix(8))): \(error)")
        }
        settings.sessionWorkspaces.removeValue(forKey: id)
        settings.sessionCategories.removeValue(forKey: id)
        settings.sessionProfile.removeValue(forKey: id)
        settings.bookmarkedSessions.removeAll { $0 == id }
        settings.todos.removeValue(forKey: id)
        settings.composerDrafts.removeValue(forKey: id)
        saveSettings()
        await reloadSessions()
        if activeSessionID == nil,
           let newest = sessions.max(by: { $0.updatedAt < $1.updatedAt }) {
            await setActiveSession(newest.id)
        }
        _ = hint("Chat deleted.")
    }

    // MARK: Rename / archive / duplicate

    func renameSession(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.sessionTitles.removeValue(forKey: id)
        } else {
            settings.sessionTitles[id] = trimmed
        }
        saveSettings()
    }

    func setShowArchived(_ on: Bool) {
        showArchived = on
        confirmDeleteID = nil
    }

    func toggleArchive(_ id: String) {
        if settings.archivedSessions.contains(id) {
            settings.archivedSessions.removeAll { $0 == id }
            // Unarchiving while in the archived-only view: exit it so the
            // conversation reappears in the normal list immediately.
            if showArchived { showArchived = false }
        } else {
            settings.archivedSessions.append(id)
        }
        saveSettings()
    }

    func duplicateSession(_ id: String) async {
        guard let store else { return }
        await ensureSessionMessages(id)
        guard let src = sessions.first(where: { $0.id == id }) else { return }
        let copy = Session(
            id: UUID().uuidString,
            createdAt: Date(),
            updatedAt: Date(),
            model: src.model,
            provider: src.provider,
            messages: src.messages
        )
        try? await store.create(copy)
        if let ws = settings.sessionWorkspaces[id] {
            settings.sessionWorkspaces[copy.id] = ws
        }
        saveSettings()
        await reloadSessions(selecting: copy.id)
        await setActiveSession(copy.id)
        _ = hint("Duplicated '\(sessionTitle(src))'.")
    }

    // MARK: Chat filtering + categories

    func setChatFilter(_ text: String) {
        chatFilter = text
    }

    func setActiveCategory(_ id: String) {
        activeCategory = id
    }

    func setAddingCategory(_ on: Bool) {
        addingCategory = on
    }

    // MARK: Category context menu (right-click)

    func categoryExists(_ id: String) -> Bool {
        settings.chatCategories.contains { $0.id == id }
    }

    func openCategoryMenu(id: String, x: Int, y: Int) {
        categoryMenu = CategoryMenu(categoryID: id, x: x, y: y)
        categoryMenuRename = false
    }

    func closeCategoryMenu() {
        categoryMenu = nil
        categoryMenuRename = false
    }

    func setCategoryMenuRename(_ on: Bool) {
        categoryMenuRename = on
    }

    func menuCategoryID() -> String? {
        categoryMenu?.categoryID
    }

    func renameCategory(_ id: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            _ = hint("Category needs a name.", kind: "error")
            return
        }
        if let i = settings.chatCategories.firstIndex(where: { $0.id == id }) {
            settings.chatCategories[i].name = name
            saveSettings()
        }
    }

    func setCategoryColor(_ id: String, color: String) {
        guard !color.isEmpty else { return }
        if let i = settings.chatCategories.firstIndex(where: { $0.id == id }) {
            settings.chatCategories[i].color = color
            saveSettings()
        }
    }

    /// Add a category (name + hex color). Duplicate names are rejected.
    func addCategory(name raw: String, color: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            _ = hint("Category needs a name.", kind: "error")
            return
        }
        guard !settings.chatCategories.contains(where: { $0.name == name }) else {
            _ = hint("Category '\(name)' already exists.", kind: "error")
            return
        }
        guard !color.isEmpty else {
            _ = hint("Choose a color for the category.", kind: "error")
            return
        }
        settings.chatCategories.append(ChatCategory(id: UUID().uuidString, name: name, color: color))
        saveSettings()
    }

    /// Remove a category and unassign every chat in it.
    func deleteCategory(_ id: String) {
        settings.chatCategories.removeAll { $0.id == id }
        settings.sessionCategories = settings.sessionCategories.filter { $0.value != id }
        if activeCategory == id { activeCategory = "all" }
        if categoryMenu?.categoryID == id { closeCategoryMenu() }
        saveSettings()
    }

    /// Assign (or clear, when nil) the category for a conversation.
    func setChatCategory(_ sessionID: String, to categoryID: String?) {
        if let cid = categoryID {
            settings.sessionCategories[sessionID] = cid
        } else {
            settings.sessionCategories.removeValue(forKey: sessionID)
        }
        saveSettings()
    }

    // MARK: Kanban

    func setAddingColumn(_ on: Bool) { addingColumn = on }

    func addKanbanColumn(name raw: String, color: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            _ = hint("Column needs a name.", kind: "error")
            return
        }
        guard !color.isEmpty else {
            _ = hint("Choose a color for the column.", kind: "error")
            return
        }
        settings.kanbanColumns.append(KBColumn(id: UUID().uuidString, name: name, color: color))
        saveSettings()
    }

    func setConfirmColumn(_ id: String?) { confirmColumn = id }

    func deleteKanbanColumn(_ id: String) {
        settings.kanbanColumns.removeAll { $0.id == id }
        settings.kanbanCards.removeAll { $0.columnID == id }
        if addingCardColumnID == id { addingCardColumnID = nil }
        confirmColumn = nil
        saveSettings()
    }

    func renameKanbanColumn(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = settings.kanbanColumns.firstIndex(where: { $0.id == id }) else { return }
        settings.kanbanColumns[i].name = n
        saveSettings()
    }

    func setAddingCard(_ columnID: String?) { addingCardColumnID = columnID }

    func addKanbanCard(_ title: String, in columnID: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            _ = hint("Card needs a title.", kind: "error")
            return
        }
        settings.kanbanCards.append(KBCard(id: UUID().uuidString, columnID: columnID, title: t))
        addingCardColumnID = nil
        saveSettings()
    }

    func renameKanbanCard(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = settings.kanbanCards.firstIndex(where: { $0.id == id }) else { return }
        settings.kanbanCards[i].title = t
        saveSettings()
    }

    func deleteKanbanCard(_ id: String) {
        settings.kanbanCards.removeAll { $0.id == id }
        saveSettings()
    }

    func moveKanbanCard(_ id: String, by delta: Int) {
        guard let i = settings.kanbanCards.firstIndex(where: { $0.id == id }),
              let fi = settings.kanbanColumns.firstIndex(where: { $0.id == settings.kanbanCards[i].columnID }) else { return }
        let ti = fi + delta
        guard ti >= 0, ti < settings.kanbanColumns.count else { return }
        settings.kanbanCards[i].columnID = settings.kanbanColumns[ti].id
        saveSettings()
    }

    // MARK: Memory panel

    func openMemoryDoc(_ key: String) {
        memoryEdit = false
        memoryDoc = key
        memoryContent = key == "context" ? "" : loadMemoryText(key)
    }

    func startMemoryEdit() { memoryEdit = true }

    func cancelMemoryEdit() { memoryEdit = false }

    func saveMemoryDoc(_ key: String, content: String) {
        guard key != "context" else { return }
        let ok = writeMemoryText(key, content: content)
        memoryContent = content
        memoryEdit = false
        _ = hint(ok ? "Saved \(memoryFileURL(key)?.lastPathComponent ?? "file")." : "Could not write \(memoryFileURL(key)?.lastPathComponent ?? "file").", kind: ok ? "" : "error")
    }

    func loadMemoryText(_ key: String) -> String {
        guard let url = memoryFileURL(key), let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    @discardableResult
    func writeMemoryText(_ key: String, content: String) -> Bool {
        guard let url = memoryFileURL(key) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: Workspace panel

    func toggleWorkspace() {
        workspaceOpen.toggle()
        wsNewMode = ""
        // One-shot slide-in for the open transition (consumed by the render).
        if workspaceOpen { wsEnterAnim = true }
    }

    func closeWorkspace() {
        workspaceOpen = false
        wsNewMode = ""
    }

    func setWsNewMode(_ mode: String) { wsNewMode = mode }

    func toggleShowHiddenFiles() { showHiddenFiles.toggle() }

    func togglePath(_ rel: String) {
        if expandedPaths.contains(rel) { expandedPaths.remove(rel) } else { expandedPaths.insert(rel) }
    }

    func createWorkspaceEntry(name raw: String, kind: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            _ = hint("Enter a plain name (no '/').", kind: "error")
            return
        }
        let url = workspaceRootURL().appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = hint("'\(name)' already exists.", kind: "error")
            return
        }
        do {
            if kind == "folder" {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data("".utf8).write(to: url)
            }
            wsNewMode = ""
            _ = hint("Created '\(name)'.")
        } catch {
            _ = hint("Could not create '\(name)': \(error.localizedDescription)", kind: "error")
        }
    }

    /// Write an uploaded file (base64 payload) into the workspace at relPath.
    func uploadWorkspaceFile(name: String, relPath: String, b64: String) {
        guard !relPath.components(separatedBy: "/").contains("..") else {
            _ = hint("Upload rejected: invalid path.", kind: "error")
            return
        }
        guard let data = Data(base64Encoded: b64) else {
            _ = hint("Upload failed: could not decode \(name).", kind: "error")
            return
        }
        let dest = workspaceRootURL().appendingPathComponent(relPath)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
            _ = hint("Uploaded \(dest.lastPathComponent).")
        } catch {
            _ = hint("Upload failed for \(name): \(error.localizedDescription)", kind: "error")
        }
    }

    // MARK: Skills

    func setSkillFilter(_ text: String) {
        skillFilter = text
    }

    func selectSkill(_ name: String) {
        selectedSkill = name
        createSkill = false
        skillEdit = false
    }

    /// Body of a SKILL.md (content minus the leading YAML frontmatter block).
    func skillBody(_ full: String) -> String {
        guard full.hasPrefix("---") else { return full }
        var rest = String(full.dropFirst(3))
        if rest.hasPrefix("\n") { rest.removeFirst() }
        if let end = rest.range(of: "\n---") {
            return String(rest[end.upperBound...]).trimmingCharacters(in: .newlines)
        }
        return full
    }

    /// Open the edit form for the selected skill, prefilling the form values
    /// from the skill's current state. `content` here is the FULL SKILL.md
    /// (frontmatter + body), so the textarea gets just the body.
    func startSkillEdit() {
        guard let s = skill(named: selectedSkill ?? "") else { return }
        for (k, v) in [("sk-edit-name-input", s.name),
                       ("sk-edit-cat-input", s.category ?? ""),
                       ("sk-edit-desc-input", s.description),
                       ("sk-edit-content-input", skillBody(s.content))] {
            storeFormValue(k, v)
        }
        skillEdit = true
    }

    func cancelSkillEdit() {
        skillEdit = false
        for k in ["sk-edit-name-input", "sk-edit-cat-input", "sk-edit-desc-input", "sk-edit-content-input"] {
            storeFormValue(k, "")
        }
    }

    func toggleSkill(_ name: String, enable: Bool? = nil) {
        // Skill toggles edit the profile bound to the ACTIVE chat when there
        // is one (per-profile unique skill sets); otherwise they edit the
        // global list, which profiles inherit until overridden.
        let context = activeSkillContext()
        if context.isEmpty {
            let shouldEnable = enable ?? !settings.disabledSkills.contains(name)
            if shouldEnable {
                settings.disabledSkills.removeAll { $0 == name }
            } else if !settings.disabledSkills.contains(name) {
                settings.disabledSkills.append(name)
            }
        } else {
            var disabled = settings.profileSkills[context] ?? settings.disabledSkills
            let shouldEnable = enable ?? !disabled.contains(name)
            if shouldEnable {
                disabled.removeAll { $0 == name }
            } else if !disabled.contains(name) {
                disabled.append(name)
            }
            settings.profileSkills[context] = disabled
        }
        saveSettings()
    }

    // MARK: Sidebar tabs

    func setSidebarTab(_ key: String, visible: Bool) {
        guard let v = ViewID(rawValue: key), v != .chat, v != .settings else { return }
        if visible {
            settings.hiddenSidebarTabs.removeAll { $0 == key }
            // Re-insert at its canonical slot if it ever left the list, so the
            // rail order never changes from toggling.
            if !settings.sidebarTabs.contains(key) {
                settings.sidebarTabs = AppSettings.normalizedSidebarOrder(settings.sidebarTabs + [key])
            }
        } else {
            if !settings.hiddenSidebarTabs.contains(key) {
                settings.hiddenSidebarTabs.append(key)
            }
            // Never strand the user on a view they just hid.
            if activeView == v { activeView = .chat }
        }
        saveSettings()
    }

    func setSidebarTabOrder(_ keys: [String]) {
        let valid = keys.filter { k in
            guard let v = ViewID(rawValue: k) else { return false }
            return v != .chat && v != .settings
        }
        settings.sidebarTabs = valid
        // Drop any hidden keys that no longer exist in the canonical order.
        settings.hiddenSidebarTabs = settings.hiddenSidebarTabs.filter { settings.sidebarTabs.contains($0) }
        saveSettings()
    }

    /// The profile bound to the active chat, if any. Empty = global context.
    func activeSkillContext() -> String {
        profileName(for: activeSessionID) ?? ""
    }

    /// Disabled skills in effect for a profile: the profile's own override, or
    /// the global list when the profile has none (inheritance).
    func disabledSkills(for profile: String) -> [String] {
        guard !profile.isEmpty else { return settings.disabledSkills }
        return settings.profileSkills[profile] ?? settings.disabledSkills
    }

    /// Disabled skills shown in the skill list for the current context.
    func skillContextDisabled() -> [String] {
        disabledSkills(for: activeSkillContext())
    }

    /// Enabled-skill count for a profile (used in dropdown rows + cards).
    func enabledSkillCount(for profile: String) -> Int {
        let dis = Set(disabledSkills(for: profile))
        return skills.filter { !dis.contains($0.name) }.count
    }

    func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    func reloadSkills() {
        skills = discoverSkills()
        skillVersion += 1
    }

    func skillsDir() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/skills")
    }

    // MARK: Profiles

    func selectProfile(_ name: String) {
        selectedProfile = name
        createProfile = false
        editingProfile = nil
    }

    /// Enter profile edit mode (the create form, pre-filled).
    func setEditingProfile(_ name: String?) {
        editingProfile = name
        createProfile = false
    }

    func reloadProfiles() async {
        let pm = ProfileManager()
        profiles = (try? await pm.list()) ?? []
    }

    /// The context overrides of the profile bound to a chat, if any.
    func profileContext(for sessionID: String?) -> ProfileContextConfig? {
        guard let pname = profileName(for: sessionID),
              let p = profiles.first(where: { $0.name == pname }),
              let ctx = p.context, !ctx.isEmpty
        else { return nil }
        return ctx
    }

    /// Effective auto-compress threshold for a chat: the bound profile's
    /// compression budget, else the ARC_COMPRESSION_BUDGET env, else 32k.
    func compressionBudget(for sessionID: String?) -> Int {
        if let b = profileContext(for: sessionID)?.compressionBudget, b > 0 { return b }
        return Int(ProcessInfo.processInfo.environment["ARC_COMPRESSION_BUDGET"] ?? "") ?? 32_000
    }

    /// Parse an optional Int from a form value (empty string → nil).
    static func optInt(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Int(t)
    }

    /// Parse an optional Double from a form value (empty string → nil).
    static func optDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Double(t)
    }

    func toggleProfileSkill(profile p: String, skill s: String, on: Bool) {
        // Per-profile DISABLED override (seeded from the global list on the
        // first edit so the profile starts inheriting and then diverges).
        var disabled = settings.profileSkills[p] ?? settings.disabledSkills
        if on {
            disabled.removeAll { $0 == s }
        } else if !disabled.contains(s) {
            disabled.append(s)
        }
        settings.profileSkills[p] = disabled
        saveSettings()
    }

    func requestProfileDelete(_ name: String) {
        confirmProfileDelete = name
    }

    func cancelProfileDelete() {
        confirmProfileDelete = nil
    }

    /// Drop every reference to a deleted profile (session bindings, skills
    /// override, detail selection).
    func removeProfileRefs(_ name: String) {
        for (k, v) in settings.sessionProfile where v == name {
            settings.sessionProfile.removeValue(forKey: k)
        }
        settings.profileSkills.removeValue(forKey: name)
        if selectedProfile == name { selectedProfile = nil }
        saveSettings()
    }

    // MARK: Tools

    func selectTool(_ name: String) {
        selectedTool = name
    }

    func setToolset(_ name: String, enabled: Bool) {
        if enabled {
            settings.disabledToolsets.removeAll { $0 == name }
        } else if !settings.disabledToolsets.contains(name) {
            settings.disabledToolsets.append(name)
        }
        saveSettings()
    }

    // MARK: Workspaces

    func workspaceNames() -> [String] {
        settings.workspaces.map(\.name)
    }

    func workspaceEntry(named name: String) -> WorkspaceEntry? {
        settings.workspaces.first { $0.name == name }
    }

    /// The workspace name for a chat: its own selection if set, else the
    /// global default (`activeWorkspace`). Nil session id → global default.
    func workspaceName(for sessionID: String?) -> String {
        if let id = sessionID, let w = settings.sessionWorkspaces[id], !w.isEmpty {
            return w
        }
        return settings.activeWorkspace
    }

    /// Absolute path of the folder a chat's workspace points at; falls back
    /// to the global default workspace's path.
    func workspacePath(for sessionID: String?) -> String {
        let name = workspaceName(for: sessionID)
        let path = workspaceEntry(named: name)?.path ?? WorkspaceEntry.defaultPath(for: name)
        // Hermes parity: the default workspace is created on first use
        // (`~/workspace` et al.) — best effort, like Hermes' resolve step.
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func activeWorkspaceName() -> String {
        settings.activeWorkspace
    }

    func setWorkspaces(_ list: [WorkspaceEntry], active: String) {
        settings.workspaces = list
        settings.activeWorkspace = active
        saveSettings()
    }

    func workspaceEntries() -> [WorkspaceEntry] {
        settings.workspaces
    }

    /// Set the global default workspace (applies to chats without their own).
    func setWorkspace(active name: String) {
        settings.activeWorkspace = name
        selectedWorkspace = name
        saveSettings()
    }

    /// Set (or clear, when empty) the workspace for the active chat only.
    func setChatWorkspace(_ name: String) {
        guard let id = activeSessionID else { return }
        if name.isEmpty || settings.workspaces.allSatisfy({ $0.name != name }) {
            settings.sessionWorkspaces.removeValue(forKey: id)
            selectedWorkspace = settings.activeWorkspace
        } else {
            settings.sessionWorkspaces[id] = name
            selectedWorkspace = name
        }
        saveSettings()
    }

    func removeWorkspace(_ name: String) {
        settings.workspaces.removeAll { $0.name == name }
        if settings.activeWorkspace == name { settings.activeWorkspace = "main" }
        settings.sessionWorkspaces = settings.sessionWorkspaces.filter { $0.value != name }
        saveSettings()
    }

    func rebuildAndReload() async {
        runtimeKey = nil
        store = nil
        memory = nil
        await reloadAll()
    }

    // MARK: Settings

    // MARK: Steering

    /// True while a turn is streaming / running tool calls in THAT session.
    func isTurnActive(sessionID: String) -> Bool {
        activeTurns[sessionID] != nil
    }

    /// Deliver mid-run user guidance (Hermes /steer) to the turn in the SAME
    /// session only. A message typed in a different chat must never steer
    /// another chat's run — it starts its own turn instead.
    func submitSteer(_ text: String, sessionID: String) {
        guard activeTurns[sessionID] != nil else { return }
        let existing = activeTurns[sessionID]?.steerText
        activeTurns[sessionID]?.steerText = existing.map { $0 + "\n" + text } ?? text
    }

    func setTheme(_ theme: String) {
        settings.theme = theme
        saveSettings()
    }

    func setTextSize(_ size: String) {
        settings.textSize = size
        saveSettings()
    }

    func setAccent(_ hex: String) {
        settings.accent = hex
        saveSettings()
    }

    func setColorScheme(_ name: String) {
        settings.colorScheme = name
        saveSettings()
    }

    func setActivityDisplay(_ mode: String) {
        settings.activityDisplay = mode
        saveSettings()
    }

    func setDefaultThinking(_ level: String) {
        settings.thinkingLevel = level
        saveSettings()
    }

    func setTesseraOff(_ off: Bool) {
        settings.tesseraOff = off
        saveSettings()
    }

    func setMoaEnabled(_ on: Bool) {
        settings.moaEnabled = on
        saveSettings()
    }

    func addModelConfig(_ preset: ModelConfigPreset) {
        if let i = settings.modelConfigs.firstIndex(where: { $0.name == preset.name }) {
            settings.modelConfigs[i] = preset
        } else {
            settings.modelConfigs.append(preset)
        }
        if settings.activeConfig.isEmpty { settings.activeConfig = preset.name }
        saveSettings()
    }

    func useModelConfig(_ name: String) {
        guard settings.modelConfigs.contains(where: { $0.name == name }) else { return }
        settings.activeConfig = name
        saveSettings()
    }

    func removeModelConfig(_ name: String) {
        settings.modelConfigs.removeAll { $0.name == name }
        if settings.activeConfig == name {
            settings.activeConfig = settings.modelConfigs.first?.name ?? ""
        }
        saveSettings()
    }

    // MARK: Store accessor

    func storeRef() -> (any SessionStore)? {
        store
    }

    // MARK: Boot

    @discardableResult
    func crumb(_ s: String) -> String {
        FileHandle.standardError.write(Data("CRUMB \(s)\n".utf8))
        return s
    }

    /// Construct the runtime and load data. Safe to call repeatedly.
    func boot() async {
        await ensureRuntime()
        crumb("boot: runtime built, backend=\(runtimeBackend)")
        await reloadAll()
        crumb("boot: reloadAll done")
    }

    /// Force file storage for THIS process only (does not persist), used by
    /// the `--tessera-off` CLI flag so a flag pass doesn't rewrite the stored
    /// default, and by the boot-time timeout so a transient Tessera outage
    /// never permanently overrides the user's tessera-on setting. A later
    /// boot with the relay reachable retries Tessera automatically.
    func overrideTesseraOff(_ off: Bool) {
        settings.tesseraOff = off
    }

    /// Boot-time storage fallback: in-memory only, never persisted. The disk
    /// flag (`settings.tesseraOff`) is the user's preference and must survive
    /// an outage unscathed — otherwise one dead relay permanently disables
    /// Tessera in settings.json (observed live Sep 2026).
    func forceTesseraOff() {
        runtimeTesseraOff = true
    }

    func sessionCount() -> Int {
        sessions.count
    }

    func skillCount() -> Int {
        skills.count
    }

    func profileCount() -> Int {
        profiles.count
    }

    func toolCount() -> Int {
        registry.allTools.count
    }

    func activeSessionIDValue() -> String? {
        activeSessionID
    }

    func newestSessionID() -> String? {
        sessions.sorted { $0.updatedAt > $1.updatedAt }.first?.id
    }

    // MARK: Live workspace panel

    /// True while the right-hand workspace panel is open (live-scan gate).
    func isWorkspaceOpen() -> Bool { workspaceOpen }

    /// Re-scan the visible workspace tree. Returns true only when the listing
    /// actually changed since the last scan (the fresh HTML is cached either
    /// way; the first scan only warms the cache to avoid a redundant push).
    func scanWorkspaceTree() async -> Bool {
        let fresh = workspaceTreeHTML()
        guard !cachedWSTreeHTML.isEmpty else {
            cachedWSTreeHTML = fresh
            return false
        }
        guard fresh != cachedWSTreeHTML else { return false }
        cachedWSTreeHTML = fresh
        return true
    }

    /// Fragment for the live-updated tree, mirroring the original render so
    /// the whole ws-tree element (with its data-root) is replaced wholesale.
    func liveWorkspaceFragments() async -> [FragmentUpdate] {
        let path = esc(panelWorkspacePath())
        return [
            FragmentUpdate(
                id: "ws-tree",
                html: "<div class=\"ws-body\" id=\"ws-tree\" data-root=\"\(path)\">\n" +
                      "  <div class=\"ws-path\" title=\"\(path)\">\(path)</div>\n" +
                      "  \(cachedWSTreeHTML)\n" +
                      "</div>"
            ),
        ]
    }

    // MARK: Auxiliary models

    /// Which auxiliary task's editor is open (nil = all collapsed).
    func setAuxEditing(_ key: String?) {
        auxEditingTask = key
    }

    /// Persist one auxiliary task's override to `~/.arc/config.json`
    /// (Hermes `auxiliary.<task>` shape). All-empty fields (or a bare "auto"
    /// provider) remove the override and route the task back to the main model.
    func setAuxOverride(
        task: AuxiliaryTask,
        provider: String,
        model: String,
        baseURL: String,
        apiKey: String
    ) {
        let p = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var cfg = arcConfig
        if m.isEmpty && b.isEmpty && k.isEmpty && (p.isEmpty || p == "auto") {
            cfg.auxiliary.byTask.removeValue(forKey: task)
        } else {
            cfg.auxiliary.byTask[task] = AuxiliaryOverride(provider: p, model: m, baseURL: b, apiKey: k)
        }
        do {
            try saveConfig(cfg)
            arcConfig = cfg
            _ = hint("Auxiliary model “\(task.displayName)” saved to ~/.arc/config.json.")
        } catch {
            _ = hint("Could not save ~/.arc/config.json: \(error.localizedDescription)", kind: "error")
        }
    }

    /// Remove an auxiliary task's override (route back to the main model).
    func clearAuxOverride(task: AuxiliaryTask) {
        var cfg = arcConfig
        cfg.auxiliary.byTask.removeValue(forKey: task)
        do {
            try saveConfig(cfg)
            arcConfig = cfg
            _ = hint("Auxiliary model “\(task.displayName)” reset to the main model.")
        } catch {
            _ = hint("Could not save ~/.arc/config.json: \(error.localizedDescription)", kind: "error")
        }
    }

    /// Best-effort chat-title generation via the title_gen auxiliary model.
    /// Only fires when a title_gen assignment exists and the chat has no
    /// custom title yet; the default stays the first-message auto title.
    /// Stores the title and pushes a lightweight topbar+panel refresh so the
    /// streaming chat area is left untouched.
    func maybeGenerateTitle(
        sessionID: String,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) async {
        guard !isTitleGenRunning else { return }
        isTitleGenRunning = true
        defer { isTitleGenRunning = false }
        guard settings.sessionTitles[sessionID] == nil,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        await ensureSessionMessages(sessionID)
        guard let content = session.messages.first(where: { $0.role == .user })?.content,
              !content.isEmpty,
              let client = makeAuxClient(for: .titleGeneration, sessionID: sessionID)
        else { return }
        let prompt = "Return ONLY a short chat title (max 8 words, plain text, no quotes, no period) for a conversation that opens with: \(trunc(content, 240))"
        do {
            let reply = try await client.complete(
                messages: [Message(role: .user, content: prompt, createdAt: Date())],
                tools: nil,
                reasoningEffort: nil
            )
            if let u = reply.usage {
                recordTokensBurned(u.totalTokens > 0 ? u.totalTokens : u.promptTokens + u.completionTokens)
            }
            guard let t = reply.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return }
            let title = String(t.prefix(44))
            guard title != sessionTitle(session) else { return }
            settings.sessionTitles[sessionID] = title
            saveSettings()
            await pusher([
                FragmentUpdate(id: "topbar", html: topbarHTML()),
                FragmentUpdate(id: "panel", html: panelHTML()),
            ])
        } catch {
            // Best-effort: a failed title call leaves the auto title in place.
        }
    }
}