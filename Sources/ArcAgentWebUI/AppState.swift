import ArcAgentCore
import AsyncHTTPClient
import Foundation

// MARK: - Enums & value types

enum ViewID: String, CaseIterable {
    case chat = "chat"
    case skills = "skills"
    case profiles = "profiles"
    case tools = "tools"
    case workspaces = "workspaces"
    case kanban = "kanban"
    case memory = "memory"
    case insights = "insights"
    case logs = "logs"
    case tasks = "tasks"
    case todos = "todos"
    case settings = "settings"

    var title: String {
        switch self {
        case .chat: return "Chats"
        case .skills: return "Skills"
        case .profiles: return "Profiles"
        case .tools: return "Tools"
        case .workspaces: return "Workspaces"
        case .kanban: return "Kanban"
        case .memory: return "Personal Memory"
        case .insights: return "Insights"
        case .logs: return "Logs"
        case .tasks: return "Scheduled Tasks"
        case .todos: return "Todos"
        case .settings: return "Settings"
        }
    }

    /// Short label for the hover tooltip pill shown to the right of the icon.
    var tip: String {
        switch self {
        case .chat: return "Chat"
        case .skills: return "Skills"
        case .profiles: return "Profiles"
        case .tools: return "Tools"
        case .workspaces: return "Workspace"
        case .kanban: return "Kanban"
        case .memory: return "Memory"
        case .insights: return "Insights"
        case .logs: return "Logs"
        case .tasks: return "Tasks"
        case .todos: return "Todos"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chat: return svgIcon("chat", 19)
        case .skills: return svgIcon("sparkle", 19)
        case .profiles: return svgIcon("person", 19)
        case .tools: return svgIcon("tools", 19)
        case .workspaces: return svgIcon("workspaces", 19)
        case .kanban: return svgIcon("kanban", 19)
        case .memory: return svgIcon("memory", 19)
        case .insights: return svgIcon("chart", 19)
        case .logs: return svgIcon("log", 19)
        case .tasks: return svgIcon("clock", 19)
        case .todos: return svgIcon("check", 19)
        case .settings: return svgIcon("settings", 19)
        }
    }
}

/// A user-created chat category (name + dot color), mirroring the Hermes chat
/// left panel: chips above the session list, and a matching color dot on each
/// conversation row next to its "⋮" menu.
struct ChatCategory: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var color: String
}

/// An open right-click menu on a category chip (position is viewport-relative).
struct CategoryMenu: Equatable {
    var categoryID: String
    var x: Int
    var y: Int
}

/// Kanban board column (name + accent color).
struct KBColumn: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var color: String
}

/// Kanban board card.
struct KBCard: Codable, Equatable, Identifiable {
    var id: String
    var columnID: String
    var title: String
    var note: String = ""
}

/// A user-managed model configuration preset (shown in the chat config selector).
struct ModelConfigPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var model: String
    var provider: String
    var baseURL: String
    var apiKey: String
    var contextLength: Int?
    var maxOutputTokens: Int?
    var temperature: Double?
    var topP: Double?

    init(
        name: String,
        model: String,
        provider: String = "custom",
        baseURL: String,
        apiKey: String = "",
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.name = name
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
    }

    /// A copy with the bound profile's context overrides applied (nil fields
    /// keep this config's values). Used when a chat is bound to a profile
    /// that sets per-profile context parameters.
    func applying(_ ctx: ProfileContextConfig) -> ModelConfigPreset {
        var copy = self
        if let v = ctx.contextLength { copy.contextLength = v }
        if let v = ctx.maxOutputTokens { copy.maxOutputTokens = v }
        if let v = ctx.temperature { copy.temperature = v }
        if let v = ctx.topP { copy.topP = v }
        return copy
    }
}

/// A named workspace bound to an arbitrary folder on disk. Older settings
/// stored workspaces as plain name strings (data dir `~/.arc/workspaces/<name>`);
/// decoding accepts both the legacy string form and the current {name,path} form.
struct WorkspaceEntry: Codable, Equatable {
    var name: String
    /// Absolute path to the folder this workspace points at.
    var path: String

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let legacy = try? single.decode(String.self) {
            self.name = legacy
            self.path = Self.defaultPath(for: legacy)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        let p = try c.decodeIfPresent(String.self, forKey: .path)
        self.path = p?.isEmpty == false ? p! : Self.defaultPath(for: self.name)
    }

    /// The legacy default data directory for a named workspace.
    ///
    /// Hermes parity: the default ("main") workspace is `~/workspace`
    /// (e.g. `/Users/<me>/workspace`) — home folder + `/workspace`, matching
    /// Hermes' default workspace discovery. Side workspaces live under
    /// `~/.arc/workspaces/<name>`.
    static func defaultPath(for name: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if name == "main" {
            return home.appendingPathComponent("workspace").path
        }
        return home.appendingPathComponent(".arc/workspaces/\(name)").path
    }
}

/// Persisted UI + app settings (stored at ~/.arc-agent-webui/settings.json).
struct AppSettings: Codable, Equatable {
    var theme: String = "light"
    var textSize: String = "md"
    var accent: String = "#B8860B"
    var colorScheme: String = "cappuccino"
    var thinkingLevel: String = "medium"
    /// How supporting activity (thinking, tool calls) is shown in chats.
    /// Mirrors Hermes: compact_worklog | transparent_stream | hide_all_activity.
    var activityDisplay: String = "compact_worklog"

    var modelConfigs: [ModelConfigPreset] = []
    var activeConfig: String = ""
    /// Auxiliary-model routing: task key → model-config name ("" = main model).
    var auxiliaryModels: [String: String] = [:]

    var disabledToolsets: [String] = []
    var disabledSkills: [String] = []
    var bookmarkedSessions: [String] = []

    var workspaces: [WorkspaceEntry] = [
        WorkspaceEntry(name: "main", path: WorkspaceEntry.defaultPath(for: "main"))
    ]
    var activeWorkspace: String = "main"
    /// Per-chat workspace selection (session id → workspace name). Chats
    /// without an entry fall back to `activeWorkspace`.
    var sessionWorkspaces: [String: String] = [:]
    var tesseraOff: Bool = false
    /// Mixture-of-Agents advisory passes, when reference models are configured.
    var moaEnabled: Bool = false

    var recentFiles: [String] = []

    /// Per-chat selections (keyed by session id).
    var sessionConfig: [String: String] = [:]
    var sessionProfile: [String: String] = [:]
    var sessionThinking: [String: String] = [:]
    /// Custom display names (keyed by session id); empty = auto title.
    var sessionTitles: [String: String] = [:]
    /// Durable per-session context-compression summaries (Hermes parity). The
    /// stored transcript stays intact; compression applies at request time.
    var sessionCompressions: [String: String] = [:]
    /// Per-chat Hermes-parity todo list (keyed by session id; the "" key is
    /// a legacy bucket that is migrated into the active chat on first view).
    var todos: [String: [TodoItem]] = [:]
    /// Run queue: todo tasks (from any chat) in the order the user chose.
    var queuePlan: [QueueEntry] = []
    /// Hermes-parity scheduled tasks (cron jobs).
    var scheduledJobs: [CronJob] = []
    /// Archived chats are hidden from the default list but restorable.
    var archivedSessions: [String] = []

    /// User-created chat categories and per-chat assignment (session id → category id).
    var chatCategories: [ChatCategory] = []
    var sessionCategories: [String: String] = [:]

    /// Kanban board state.
    var kanbanColumns: [KBColumn] = []
    var kanbanCards: [KBCard] = []

    /// Filesystem root for the right-hand workspace panel (default: launch dir).
    /// Legacy single-workspace path (superseded by `workspaces`); kept for
    /// settings-file compatibility. Default: `~/workspace` (Hermes parity).
    var workspaceRoot: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("workspace").path

    /// Per-profile enabled skills (profile name -> list of skill names).
    var profileSkills: [String: [String]] = [:]
    /// Per-chat composer drafts keyed by session id (Hermes parity: each chat
    /// keeps the text you typed but didn't send).
    var composerDrafts: [String: String] = [:]
    /// Daily-token graph range for the Insights view (7/30/90/365).
    var insightsRangeDays: Int = 30

    /// Show input/output token usage below each assistant reply (Hermes:
    /// show_token_usage; also toggled with /usage).
    var showTokenUsage: Bool = false
    /// Show tokens-per-second in assistant message headers while streaming
    /// and after a response completes (Hermes: show_tps). Off by default.
    var showTps: Bool = false
    /// Maximum active conversations that can be pinned in the sidebar
    /// (Hermes: pinned_sessions_limit). Default 3.
    var pinnedSessionsLimit: Int = 3
    /// Canonical order of every rail tab (view keys; chat + settings are
    /// always visible and are never listed here). This list never loses
    /// entries: a hidden tab keeps its slot, so re-enabling restores its
    /// original position.
    var sidebarTabs: [String] = AppSettings.defaultSidebarTabs
    /// Tabs currently hidden from the rail (subset of sidebarTabs).
    var hiddenSidebarTabs: [String] = []
    /// Sessions where approvals are skipped (Hermes "/api/session/yolo" parity):
    /// the user tapped "Skip all this session" in an approval card.
    var yoloSessions: [String] = []
    static let defaultSidebarTabs = ["skills", "profiles", "tools", "workspaces", "kanban", "memory", "insights", "logs", "tasks", "todos"]
    static var defaultSidebarTabsKeys: [String] { defaultSidebarTabs }
    /// Rebuild a canonical sidebar list from a possibly-partial stored list:
    /// present keys keep their relative order; keys missing from the stored
    /// list are re-inserted at their default position.
    static func normalizedSidebarOrder(_ stored: [String]) -> [String] {
        var order = stored
        for key in defaultSidebarTabs where !order.contains(key) {
            var inserted = false
            for (i, k) in order.enumerated() {
                if let di = defaultSidebarTabs.firstIndex(of: k),
                   di > (defaultSidebarTabs.firstIndex(of: key) ?? -1) {
                    order.insert(key, at: i)
                    inserted = true
                    break
                }
            }
            if !inserted { order.append(key) }
        }
        return order
    }

    enum CodingKeys: String, CodingKey {
        case theme, textSize, accent, colorScheme, thinkingLevel, activityDisplay
        case modelConfigs, activeConfig
        case auxiliaryModels
        case disabledToolsets, disabledSkills, bookmarkedSessions
        case workspaces, activeWorkspace, sessionWorkspaces, tesseraOff, moaEnabled
        case recentFiles
        case sessionConfig, sessionProfile, sessionThinking, sessionTitles, sessionCompressions, archivedSessions
        case chatCategories, sessionCategories
        case kanbanColumns, kanbanCards
        case todos, scheduledJobs
        case queuePlan
        case workspaceRoot
        case profileSkills
        case composerDrafts
        case insightsRangeDays
        case showTokenUsage, showTps, pinnedSessionsLimit
        case sidebarTabs, hiddenSidebarTabs, yoloSessions
    }

    /// Tolerant decode: any missing (or mistyped) key falls back to the field's
    /// default, so adding a new settings key never wipes the stored settings.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "light"
        textSize = try c.decodeIfPresent(String.self, forKey: .textSize) ?? "md"
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? "#B8860B"
        colorScheme = try c.decodeIfPresent(String.self, forKey: .colorScheme) ?? "default"
        // Scheme migration: the old gold scheme id was renamed to Hermes' "default".
        if colorScheme == "cappuccino" { colorScheme = "default" }
        thinkingLevel = try c.decodeIfPresent(String.self, forKey: .thinkingLevel) ?? "medium"
        activityDisplay = try c.decodeIfPresent(String.self, forKey: .activityDisplay) ?? "compact_worklog"
        modelConfigs = try c.decodeIfPresent([ModelConfigPreset].self, forKey: .modelConfigs) ?? []
        activeConfig = try c.decodeIfPresent(String.self, forKey: .activeConfig) ?? ""
        auxiliaryModels = try c.decodeIfPresent([String: String].self, forKey: .auxiliaryModels) ?? [:]
        disabledToolsets = try c.decodeIfPresent([String].self, forKey: .disabledToolsets) ?? []
        disabledSkills = try c.decodeIfPresent([String].self, forKey: .disabledSkills) ?? []
        bookmarkedSessions = try c.decodeIfPresent([String].self, forKey: .bookmarkedSessions) ?? []
        workspaces = try c.decodeIfPresent([WorkspaceEntry].self, forKey: .workspaces) ?? [
            WorkspaceEntry(name: "main", path: WorkspaceEntry.defaultPath(for: "main"))
        ]
        activeWorkspace = try c.decodeIfPresent(String.self, forKey: .activeWorkspace) ?? "main"
        sessionWorkspaces = try c.decodeIfPresent([String: String].self, forKey: .sessionWorkspaces) ?? [:]
        tesseraOff = try c.decodeIfPresent(Bool.self, forKey: .tesseraOff) ?? false
        moaEnabled = try c.decodeIfPresent(Bool.self, forKey: .moaEnabled) ?? false
        recentFiles = try c.decodeIfPresent([String].self, forKey: .recentFiles) ?? []
        sessionConfig = try c.decodeIfPresent([String: String].self, forKey: .sessionConfig) ?? [:]
        sessionProfile = try c.decodeIfPresent([String: String].self, forKey: .sessionProfile) ?? [:]
        sessionThinking = try c.decodeIfPresent([String: String].self, forKey: .sessionThinking) ?? [:]
        sessionTitles = try c.decodeIfPresent([String: String].self, forKey: .sessionTitles) ?? [:]
        sessionCompressions = try c.decodeIfPresent([String: String].self, forKey: .sessionCompressions) ?? [:]
        archivedSessions = try c.decodeIfPresent([String].self, forKey: .archivedSessions) ?? []
        chatCategories = try c.decodeIfPresent([ChatCategory].self, forKey: .chatCategories) ?? []
        sessionCategories = try c.decodeIfPresent([String: String].self, forKey: .sessionCategories) ?? [:]
        if let m = try? c.decodeIfPresent([String: [TodoItem]].self, forKey: .todos) {
            todos = m
        } else if let legacy = try? c.decodeIfPresent([TodoItem].self, forKey: .todos) {
            // Pre-per-chat shape: park under the legacy bucket until the
            // active chat is known, then migrate on first view.
            todos = ["": legacy]
        } else {
            todos = [:]
        }
        queuePlan = try c.decodeIfPresent([QueueEntry].self, forKey: .queuePlan) ?? []
        scheduledJobs = try c.decodeIfPresent([CronJob].self, forKey: .scheduledJobs) ?? []
        kanbanColumns = try c.decodeIfPresent([KBColumn].self, forKey: .kanbanColumns) ?? []
        kanbanCards = try c.decodeIfPresent([KBCard].self, forKey: .kanbanCards) ?? []
        workspaceRoot = try c.decodeIfPresent(String.self, forKey: .workspaceRoot) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workspace").path
        profileSkills = try c.decodeIfPresent([String: [String]].self, forKey: .profileSkills) ?? [:]
        composerDrafts = try c.decodeIfPresent([String: String].self, forKey: .composerDrafts) ?? [:]
        insightsRangeDays = try c.decodeIfPresent(Int.self, forKey: .insightsRangeDays) ?? 30
        showTokenUsage = try c.decodeIfPresent(Bool.self, forKey: .showTokenUsage) ?? false
        showTps = try c.decodeIfPresent(Bool.self, forKey: .showTps) ?? false
        pinnedSessionsLimit = try c.decodeIfPresent(Int.self, forKey: .pinnedSessionsLimit) ?? 3
        sidebarTabs = try c.decodeIfPresent([String].self, forKey: .sidebarTabs) ?? AppSettings.defaultSidebarTabs
        hiddenSidebarTabs = try c.decodeIfPresent([String].self, forKey: .hiddenSidebarTabs) ?? []
        yoloSessions = try c.decodeIfPresent([String].self, forKey: .yoloSessions) ?? []
        // Migration from the older "visible-only" sidebarTabs format: keys that
        // were missing from the stored list were hidden by the user; rebuild the
        // canonical full order from what was stored (relative order preserved,
        // missing keys restored at their default slots).
        if hiddenSidebarTabs.isEmpty && sidebarTabs.count < AppSettings.defaultSidebarTabs.count {
            hiddenSidebarTabs = AppSettings.defaultSidebarTabs.filter { !sidebarTabs.contains($0) }
            sidebarTabs = AppSettings.normalizedSidebarOrder(sidebarTabs)
        } else {
            sidebarTabs = AppSettings.normalizedSidebarOrder(sidebarTabs)
        }
        hiddenSidebarTabs = hiddenSidebarTabs.filter { sidebarTabs.contains($0) }
    }

    func modelConfig(named name: String) -> ModelConfigPreset? {
        modelConfigs.first { $0.name == name }
    }
}

struct LiveTurn {
    var sessionID: String
    var userText: String
    var attachments: [String]
    var assistantText: String = ""
    /// Accumulated reasoning/thinking text streamed by the model.
    var thinking: String = ""
    var toolChips: [String] = []
    var status: String = "running"   // running | tool | done | error
    var error: String? = nil
    var startedAt = Date()
    /// Set by the Stop button; the turn's stream/tool loops poll it.
    var stopped = false
    var turnToken = 0
    /// Live tokens-per-second estimate for the streaming reply (showTps).
    var tps: Double? = nil
    /// Pending mid-run user guidance (Hermes /steer). Injected into the last
    /// tool result at the next tool boundary; drained as the next turn if the
    /// run ends before consuming it (leftover steer).
    var steerText: String? = nil
}

/// A pending user-approval request (Hermes-style permission card in the chat).
/// A named context block attached to the composer (Hermes webui parity:
/// `_pendingSelections`, rendered as "Context N" chips above the input).
struct PendingContext: Codable, Equatable, Sendable {
    let id: String
    var name: String
    let text: String
}

struct PendingApproval {
    let command: String
    let description: String
    let sessionID: String
    let continuation: AsyncStream<Bool>.Continuation
}

/// Hermes-parity clarification request: the agent's `clarify` tool is waiting
/// for an answer. Choices are up to 4 (numbered); the user may also type a
/// free-form answer. Expires after 120 s — on timeout the turn continues with
/// a best-judgement notice (same effect as Hermes' smart-approval fallback).
struct PendingClarify {
    let question: String
    let choices: [String]
    let sessionID: String
    let continuation: AsyncStream<String>.Continuation
    let expiresAt: Date
}

/// How the user answered a pending approval (Hermes parity: once / session /
/// always / deny).
enum ApprovalChoice {
    case once, session, always, deny
}

/// Hermes-parity: the preset answer used when the user picks "Other" and
/// submits free-form text.

struct Toast: Identifiable {
    let id: Int
    let text: String
    let kind: String   // info | success | error
}

// MARK: - AppState

/// The single source of truth for the web UI. All mutable state is guarded by
/// this actor (First Law). Views are built from snapshots taken via async
/// accessors so renderers stay pure and synchronous.
actor AppState {

    // MARK: State

    var settings = AppSettings()
    var activeView: ViewID = .chat

    /// Logs view: active severity filter ("all" | "info" | "warn" | "error").
    var logFilter = "all"

    var sessions: [Session] = []

    // MARK: Lazy message loading (scalable design)

    /// Chat IDs whose message bodies are currently materialized, oldest-open
    /// first. `sessions` entries outside this set carry metadata only.
    var loadedSessionOrder: [String] = []

    /// Bound on how many chats keep their messages in memory. Eviction is
    /// least-recently-opened and never touches the active chat, so memory
    /// stays constant no matter how large the history grows.
    static let sessionMessageCacheCap = 32

    /// Materialize a session's messages (fetching from the store if they were
    /// never loaded or were evicted from the LRU cache). No-op when the
    /// session is already loaded or the store is unavailable.
    func ensureSessionMessages(_ id: String) async {
        guard let store else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        if !sessions[idx].messages.isEmpty {
            touchSessionLoaded(id)
            return
        }
        if !loadedSessionOrder.contains(id) {
            guard let full = try? await store.get(id: id) else { return }
            guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[i].messages = full.messages
            sessions[i].messageCount = full.messages.count
            sessions[i].title = full.title
            touchSessionLoaded(id)
        }
        evictOverloadedCache()
    }

    func touchSessionLoaded(_ id: String) {
        loadedSessionOrder.removeAll { $0 == id }
        loadedSessionOrder.append(id)
    }

    /// Drop the least-recently-opened chat bodies beyond the cache cap, never
    /// the active chat (its count stays in `messageCount` for the sidebar).
    func evictOverloadedCache() {
        while loadedSessionOrder.count > Self.sessionMessageCacheCap {
            guard let victim = loadedSessionOrder.first else { break }
            if victim == activeSessionID {
                loadedSessionOrder.removeFirst()
                loadedSessionOrder.append(victim)
                continue
            }
            loadedSessionOrder.removeFirst()
            if let idx = sessions.firstIndex(where: { $0.id == victim }) {
                // Capture the live count before dropping bodies so sidebar
                // counts stay correct after eviction.
                sessions[idx].messageCount = sessions[idx].messages.count
                sessions[idx].messages = []
            }
        }
    }
    var activeSessionID: String?
    var sessionVersion = 0

    var skills: [Skill] = []
    var selectedSkill: String?
    var skillFilter = ""
    var skillVersion = 0

    var profiles: [Profile] = []
    var selectedProfile: String?

    var toolsets: [(name: String, tools: [ToolEntry])] = []
    var selectedTool: String?

    var selectedWorkspace: String?

    var formValues: [String: String] = [:]
    /// Debounced settings save for composer drafts (cancelled + rescheduled on
    /// each keystroke; writes at most once per ~1.5 s while typing).
    var draftSaveTask: Task<Void, Never>?
    var attachments: [String] = []
    /// Context blocks attached to the composer via "Reply with selection"
    /// (Hermes `_pendingSelections`). In-memory only (not persisted).
    var pendingContexts: [PendingContext] = []
    private var contextCounter = 0

    /// Attach a context block; returns the new block (id "ctx-N", name
    /// "Context N").
    func addPendingContext(_ text: String) -> PendingContext {
        contextCounter += 1
        // Hermes parity: chip names are positional ("Context 1", "Context 2",
        // ...) at add time, not monotonic.
        let block = PendingContext(id: "ctx-\(contextCounter)",
                                   name: "Context \(pendingContexts.count + 1)",
                                   text: text)
        pendingContexts.append(block)
        return block
    }

    /// Remove a context block by id; resets the counter when empty.
    func removePendingContext(_ id: String) {
        pendingContexts.removeAll { $0.id == id }
        if pendingContexts.isEmpty { contextCounter = 0 }
    }

    /// Drop all pending context blocks.
    func clearPendingContexts() {
        pendingContexts = []
        contextCounter = 0
    }

    /// Truncated preview (Hermes `_selectedContextPreview`: 360 chars + …).
    static func contextPreview(_ text: String, limit: Int = 360) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let collapsed = normalized.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }
        return collapsed.count > limit ? String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : collapsed
    }

    /// Markdown for one context block (Hermes `_composerTextWithPendingSelections`):
    /// `**Context N:**` + blockquote lines. Long content is truncated (…)
    /// so it never overtakes the sent message (user requirement).
    static func contextBlockMarkdown(_ block: PendingContext, contentLimit: Int = 600) -> String {
        var text = block.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.count > contentLimit {
            text = String(text.prefix(contentLimit)).trimmingCharacters(in: .whitespaces) + "…"
        }
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n")
        return "**\(block.name):**\n\(quoted)"
    }

    /// Final composer text with pending contexts inlined (Hermes
    /// `_composerTextWithPendingSelections`).
    func composeWithPendingContexts(_ raw: String) -> String {
        guard !pendingContexts.isEmpty else { return raw }
        let blocks = pendingContexts
            .map { Self.contextBlockMarkdown($0) }
            .joined(separator: "\n\n")
        let current = raw.trimmingCharacters(in: .whitespaces)
        if current.isEmpty { return blocks }
        return current + "\n\n" + blocks
    }


    /// UI mode flags
    var pendingDelete = false
    var filePopOpen = false

    /// Composer dropdown state (Hermes-parity custom selectors: workspace,
    /// profile, model, thinking). UI-only — never persisted.
    var wsSelectOpen = false
    var wsSelectQuery = ""
    var profileSelectOpen = false
    var modelSelectOpen = false
    var modelSelectQuery = ""
    var thinkSelectOpen = false
    /// True once the app's HTTP/WS server is bound (surfaced in the profile card).
    var gatewayRunning = false
    var createSkill = false
    var createProfile = false
    /// Profile currently being edited (nil = not editing). The create form
    /// doubles as the edit form; when set, it renders pre-filled.
    var editingProfile: String?
    var createWorkspace = false
    /// Left-panel chat list: show archived chats instead of the active ones.
    var showArchived = false
    /// Session awaiting delete confirmation (centered modal).
    var confirmDeleteID: String?
    /// Name of the profile pending deletion (confirmation modal).
    var confirmProfileDelete: String?
    /// Next chat-scroll render should force the view to the bottom (chat open).
    var forceScrollBottom = true

    /// Chat list filtering (phase: categories).
    var chatFilter = ""
    var activeCategory = "all"      // "all" | "unassigned" | category id
    var addingCategory = false
    /// Open right-click category menu (nil = none); rename flips the menu's
    /// top row into an inline editor.
    var categoryMenu: CategoryMenu? = nil
    var categoryMenuRename = false

    /// Right-hand workspace panel.
    var workspaceOpen = false
    /// Last rendered workspace-tree rows; the live scanner only pushes a
    /// fragment when the listing actually changes.
    var cachedWSTreeHTML = ""
    var wsNewMode = ""              // "" | "file" | "folder" (inline create)
    var wsNewDraft: String? = nil
    var showHiddenFiles = false
    var expandedPaths: Set<String> = []
    /// One-shot flag: set when toggling the panel OPEN so the next render
    /// attaches the slide-in animation class; consumed by workspacePanelHTML.
    var wsEnterAnim = false

    /// Personal memory panel (phase: memory).
    var memoryDoc: String? = nil    // "memory" | "user" | "soul" | "context"
    var memoryEdit = false
    var skillEdit = false
    var memoryContent = ""

    /// Kanban UI mode (phase: kanban).
    var addingColumn = false
    var addingCardColumnID: String? = nil
    var confirmColumn: String? = nil

    /// Shared palette for category / kanban column colors.
    static let palette: [String] = [
        "#E5484D", "#E1914B", "#D9A441", "#5BB98C",
        "#2F9EB7", "#4F6FDD", "#9D5CD0", "#C25A8A", "#8A8271"
    ]

    /// Active turns keyed by sessionID — different chats may run concurrently.
    /// Steering and Stop are scoped to the turn's own session.
    var activeTurns: [String: LiveTurn] = [:]
    /// Hermes-style approval gate for the webui tool loop: the terminal tool
    /// is checked against ApprovalManager, and dangerous commands pause the
    /// turn on a permission card until the user approves or denies.
    var approvalManager: ApprovalManager?
    /// Hermes-parity: the notice returned to the agent when a clarify request
    /// times out (the user did not answer within 120 s). The agent then
    /// proceeds on its own judgment — the "smart mode" fallback.
    static let clarifyTimeoutText = "The user did not provide a response within the time limit. Use your best judgement to make the choice and proceed."
    /// Pending user clarification (agent's `clarify` tool waiting for an answer).
    var pendingClarify: PendingClarify?
    /// Timer task that fires `finishClarifyTimeout` when the 120 s deadline passes.
    var clarifyTimerTask: Task<Void, Never>?

    // MARK: Run queue (Todos panel tab state)
    var todosTab: TodosTab = .tasks
    var queuePickerOpen = false
    var queueCandidates: Set<String> = []
    var queueLinksOpen: String?
    var queueLinkSel: Set<String> = []
    var queueRunActive = false
    var queueStatuses: [String: String] = [:]
    /// The currently awaiting user approval (rendered as a card in chat).
    var pendingApproval: PendingApproval?
    /// Owned task handle for the scheduled-jobs engine (cancelled at stop).
    var cronTask: Task<Void, Never>?
    /// Guards fire-and-forget title generation so only one runs at a time.
    var isTitleGenRunning = false
    /// The `~/.arc/config.json` as loaded from disk (no env overrides), the
    /// canonical home of the `auxiliary` block edited from Preferences.
    var arcConfig: ArcConfig = ArcConfig()
    /// Which auxiliary task is currently being edited in Preferences.
    var auxEditingTask: String? = nil
    /// Durable insights analytics (skill usage, daily token burn).
    var insights: InsightsData = InsightsData()
    /// Daily-token graph range selected in the Insights panel (7/30/90/365).
    var insightsRangeDays = 30
    var toasts: [Toast] = []
    private var toastSeq = 0

    var registry: MutableToolRegistry

    /// Discovered tool plugins (`~/.arc/plugins/<name>/manifest.json`),
    /// refreshed by ``refreshPlugins()`` — the Settings → Tool plugins view
    /// data source (Hermes plugin metadata parity).
    var pluginManifests: [String: PluginManifest] = [:]

    // MARK: Runtime pieces (rebuilt when workspace / tessera mode changes)

    var httpClient: HTTPClient?
    var store: (any SessionStore)?
    /// The storage backend this process actually constructed: "tessera" or
    /// "file". Honest label vs `settings.tesseraOff` because the boot-time
    /// fallback can differ from the persisted setting within a process.
    var runtimeBackend: String = "file"
    var memory: (any MemoryProvider)?
    var runtimeKey: String?
    /// In-memory storage fallback flag (never persisted): set by
    /// ``forceTesseraOff()`` when the boot-time Tessera probe times out.
    /// Kept separate from `settings.tesseraOff` so a relay outage can never
    /// permanently flip the user's persisted preference.
    var runtimeTesseraOff = false

    // MARK: Init

    init() throws {
        self.registry = MutableToolRegistry(builtIn: try ArcAgentCore.buildDefaultRegistry())
        let grouped = Dictionary(grouping: self.registry.allTools, by: { $0.toolset })
        self.toolsets = grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
        self.settings = Self.loadSettings()
        let rawConfig = Self.rawArcConfig()
        self.arcConfig = rawConfig
        self.insights = Self.loadInsights()
        self.insightsRangeDays = self.settings.insightsRangeDays
        let resolvedConfig = loadConfig()
        self.settings = AppState.seedConfigs(from: resolvedConfig, into: self.settings)
        self.settings = AppState.seedKanban(into: self.settings)
        if Self.migrateLegacyAuxModels(into: &self.settings, arc: &self.arcConfig) {
            saveSettings()
        }
        if Self.migrateWorkspaceDefaults(into: &self.settings) {
            saveSettings()
        }
        self.selectedWorkspace = self.settings.activeWorkspace
        Task { await self.refreshPlugins() }
    }

    /// Rescan `~/.arc/plugins/` and rebuild the runtime registry with built-in
    /// + enabled plugin tools (Hermes agent-init plugin bundling parity).
    func refreshPlugins() async {
        try? await PluginRegistry.shared.loadAll()
        self.pluginManifests = await PluginRegistry.shared.plugins()
        let allow = self.arcConfig.plugins.enabled.map { Set($0) }
        if let made = try? await MutableToolRegistry.make(enabledPlugins: allow) {
            self.registry = made
        }
        let grouped = Dictionary(grouping: self.registry.allTools, by: { $0.toolset })
        self.toolsets = grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    /// Enable/disable a tool plugin (Hermes `plugins.enabled` parity). Writes
    /// `~/.arc/config.json` so the CLI/gateway honor the same allow-list.
    func setPluginEnabled(_ name: String, enabled: Bool) {
        var raw = Self.rawArcConfig()
        var list = raw.plugins.enabled ?? self.pluginManifests.keys.sorted()
        if enabled {
            if !list.contains(name) { list.append(name) }
        } else {
            list.removeAll { $0 == name }
        }
        raw.plugins.enabled = list
        self.arcConfig = raw
        try? saveConfig(raw)
        Task { await self.refreshPlugins() }
    }

    /// Persist an "Always allow" command into `~/.arc/config.json` so the CLI
    /// and gateway honor the same allowlist (Hermes approval patterns parity).
    func persistAlwaysAllowed(_ command: String) async {
        var raw = Self.rawArcConfig()
        var list = raw.security.alwaysAllowedCommands
        guard !list.contains(command) else { return }
        list.append(command)
        raw.security.alwaysAllowedCommands = list
        self.arcConfig = raw
        try? saveConfig(raw)
    }

    /// The raw `~/.arc/config.json` (no environment overrides applied) — the
    /// file the aux editor reads and writes so env vars never get baked in.
    static func rawArcConfig() -> ArcConfig {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/config.json")
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(ArcConfig.self, from: data) {
            return cfg
        }
        return ArcConfig()
    }

    /// Hermes parity: migrate the legacy default workspace (home folder) to
    /// `~/workspace`. Returns true when the persisted "main" entry was
    /// repointed (or restored to the new default path).
    static func migrateWorkspaceDefaults(into settings: inout AppSettings) -> Bool {
        let newMain = WorkspaceEntry.defaultPath(for: "main")
        guard let i = settings.workspaces.firstIndex(where: { $0.name == "main" }),
              settings.workspaces[i].path != newMain
        else { return false }
        let oldDefaultHome = FileManager.default.homeDirectoryForCurrentUser.path
        guard settings.workspaces[i].path == oldDefaultHome ||
              settings.workspaces[i].path.isEmpty
        else { return false }
        settings.workspaces[i].path = newMain
        return true
    }

    /// One-time migration: the earlier Preferences stored per-task preset
    /// names in settings.json; move them into `auxiliary.<task>` overrides in
    /// ~/.arc/config.json and clear the legacy store.
    static func migrateLegacyAuxModels(into settings: inout AppSettings, arc: inout ArcConfig) -> Bool {
        guard !settings.auxiliaryModels.isEmpty else { return false }
        let presets = settings.modelConfigs
        var changed = false
        for (key, name) in settings.auxiliaryModels where !name.isEmpty {
            if let task = AuxiliaryTask(configKey: key),
               let preset = presets.first(where: { $0.name == name }) {
                arc.auxiliary.byTask[task] = AuxiliaryOverride(
                    provider: preset.provider,
                    model: preset.model,
                    baseURL: preset.baseURL,
                    apiKey: preset.apiKey
                )
                changed = true
            }
        }
        settings.auxiliaryModels = [:]
        if changed {
            try? saveConfig(arc)
        }
        return true
    }

    /// Seed the default kanban columns on first run (no stored board yet).
    static func seedKanban(into s: AppSettings) -> AppSettings {
        var s = s
        guard s.kanbanColumns.isEmpty else { return s }
        let palette = ["#5BB98C", "#2F9EB7", "#E1914B", "#9D5CD0"]
        let names = ["Backlog", "In progress", "Done"]
        s.kanbanColumns = names.enumerated().map { i, name in
            KBColumn(id: UUID().uuidString, name: name, color: palette[i % palette.count])
        }
        return s
    }

    /// Seed model configs from ~/.arc/config.json on first run.
    static func seedConfigs(from arc: ArcConfig, into s: AppSettings) -> AppSettings {
        var s = s
        guard s.modelConfigs.isEmpty else { return s }
        let model = arc.model.defaultModel
        let baseURL = arc.model.baseURL ?? "https://api.openai.com/v1"
        let key = ProcessInfo.processInfo.environment["ARC_API_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""
        let preset = ModelConfigPreset(
            name: model.isEmpty ? "default" : model,
            model: model.isEmpty ? "gpt-4o" : model,
            provider: arc.model.provider,
            baseURL: baseURL,
            apiKey: key,
            contextLength: arc.model.contextLength,
            maxOutputTokens: arc.model.maxOutputTokens
        )
        s.modelConfigs = [preset]
        s.activeConfig = preset.name
        return s
    }

    // MARK: Settings persistence

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc-agent-webui/settings.json")
    }

    static func loadSettings() -> AppSettings {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            FileHandle.standardError.write("ws-settings-decode-error: \(error)\n".data(using: .utf8)!)
            return AppSettings()
        }
    }

    func saveSettings() {
        let url = Self.settingsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func tapSetting<T>(_ mutate: (inout AppSettings) -> T) -> T {
        let r = mutate(&settings)
        saveSettings()
        return r
    }

    // MARK: Toasts

    func toast(_ text: String, kind: String = "info") -> Toast {
        toastSeq += 1
        let t = Toast(id: toastSeq, text: text, kind: kind)
        // Only errors are surfaced as toasts (user preference): routine
        // confirmations are quiet, errors appear as a red bubble at the top.
        guard kind == "error" else { return t }
        toasts.append(t)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        return t
    }

    func dismissToast(id: Int) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: Runtime construction

    /// (Re)build the store + memory provider when the storage mode changes.
    /// Workspaces are per-chat working directories and no longer isolate the
    /// session store — all chats share one session pool.
    func ensureRuntime() async {
        let key = "\(settings.tesseraOff)-\(runtimeTesseraOff)"
        if runtimeKey == key, store != nil { return }
        runtimeKey = key
        let tesseraOff = settings.tesseraOff || runtimeTesseraOff

        if httpClient == nil {
            httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        }

        // Approval gate (Hermes smart approval): mode follows ~/.arc/config.json
        // (off | manual | smart). In smart mode the `approval` auxiliary model
        // classifies risk when configured; the built-in regex detector stands
        // in otherwise.
        if approvalManager == nil {
            let mode: ApprovalMode
            switch loadConfig().security.approvalMode {
            case "off": mode = .off
            case "smart": mode = .smart
            default: mode = .manual
            }
            let manager = ApprovalManager(
                mode: mode,
                alwaysAllowedCommands: loadConfig().security.alwaysAllowedCommands
            )
            await manager.setAlwaysAllowSink { [weak self] command in
                await self?.persistAlwaysAllowed(command)
            }
            if mode == .smart, arcConfig.auxiliary.override(for: .approval)?.isSet == true {
                await manager.setClassifier { [weak self] command in
                    guard let self else { return nil }
                    return await self.classifyApprovalRisk(command)
                }
            }
            approvalManager = manager
        }

        if tesseraOff || loadConfig().tessera == nil {
            runtimeBackend = "file"
            store = FileSessionStore()
            memory = FileMemoryProvider()
        } else {
            runtimeBackend = "tessera"
            await TesseraConnection.shared.configure(loadConfig().tessera!)
            store = TesseraSessionStore()
            memory = TesseraMemoryProvider()
        }
    }

    /// Human-readable description of the storage backend actually in use,
    /// including the Tessera endpoint when connected.
    func storageDescription() -> String {
        if runtimeBackend == "tessera", let t = loadConfig().tessera {
            return "Tessera @ \(t.serverIP):\(t.serverPort) (signed NOSTR events)"
        }
        return "File storage"
    }

    /// Build an OpenAI-compatible client for the given config preset,
    /// reusing the process-wide HTTP client.
    func makeClient(for preset: ModelConfigPreset) -> OpenAICompatibleClient? {
        guard let hc = httpClient,
              let url = URL(string: preset.baseURL)
        else { return nil }
        return OpenAICompatibleClient(
            baseURL: url,
            apiKey: preset.apiKey,
            model: preset.model,
            httpClient: hc,
            defaultParameters: RequestParameters(temperature: preset.temperature, maxTokens: preset.maxOutputTokens, topP: preset.topP)
        )
    }

    /// Resolve the client for an auxiliary task from the `auxiliary` block of
    /// ~/.arc/config.json (edited in Preferences), falling back to the chat's
    /// (or active) main config. Mirrors Hermes `auxiliary.<task>` routing.
    func makeAuxClient(for task: AuxiliaryTask, sessionID: String?) -> OpenAICompatibleClient? {
        guard let hc = httpClient else { return nil }
        let preset = settings.modelConfig(named: configName(for: sessionID))
        let main = ModelConfig(
            defaultModel: preset?.model ?? "gpt-4o",
            provider: preset?.provider ?? "custom",
            baseURL: preset?.baseURL
        )
        let router = AuxiliaryModelRouter(
            set: arcConfig.auxiliary,
            main: main,
            mainAPIKey: preset?.apiKey ?? ""
        )
        return router.makeClient(task: task, httpClient: hc)
    }

    // MARK: Approval gating (Hermes smart command approval)

    /// Smart-approval risk classification via the `approval` auxiliary model.
    /// Mirror of the harness `ArcAgent.classifyApprovalRisk`; returns nil when
    /// the client is unavailable or the call fails, letting the regex
    /// detector stand in.
    func classifyApprovalRisk(_ command: String) async -> DangerLevel? {
        guard let hc = httpClient,
              let client = makeAuxClient(for: .approval, sessionID: nil) else { return nil }
        let prompt = """
        You classify shell commands for an autonomous coding agent. Reply with exactly one word from: safe, suspicious, dangerous, critical. Consider destructive or exfiltrating operations (rm -rf, mkfs, dd, diskutil erase, curl | sh) critical or dangerous.

        Command: \(command)
        """
        do {
            let resp = try await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil,
                reasoningEffort: nil
            )
            let low = (resp.content ?? "").lowercased()
            if low.contains("critical") { return .critical }
            if low.contains("danger") { return .dangerous }
            if low.contains("suspicious") { return .suspicious }
            return .safe
        } catch {
            return nil
        }
    }

    /// Resolve the pending approval (Approve / Deny button on the permission
    /// card). Yields the decision into the waiting turn.
    func resolveApproval(_ choice: ApprovalChoice) async {
        guard let pa = pendingApproval else { return }
        pendingApproval = nil
        let granted: Bool
        switch choice {
        case .once:
            granted = true
        case .session:
            // Hermes "Allow session": pre-approve the rest of the session.
            await approvalManager?.preApproveSession(pa.sessionID)
            granted = true
        case .always:
            // Hermes "Always allow": persist the command to the allowlist.
            await approvalManager?.alwaysAllow(command: pa.command)
            granted = true
        case .deny:
            granted = false
        }
        pa.continuation.yield(granted)
        pa.continuation.finish()
    }

    // MARK: Clarification (Hermes parity)

    /// Resolve a pending clarification with the user's answer.
    func respondClarify(_ answer: String) async {
        guard let pc = pendingClarify else { return }
        pendingClarify = nil
        clarifyTimerTask?.cancel()
        clarifyTimerTask = nil
        pc.continuation.yield(answer)
        pc.continuation.finish()
    }

    /// Timeout path for a clarification: the user did not answer in time.
    /// The turn continues with a best-judgement notice (Hermes smart-mode
    /// fallback for clarify timeouts).
    func finishClarifyTimeout(sessionID: String, expiresAt: Date) async {
        guard let pc = pendingClarify, pc.sessionID == sessionID, pc.expiresAt == expiresAt else { return }
        pendingClarify = nil
        clarifyTimerTask = nil
        pc.continuation.yield(Self.clarifyTimeoutText)
        pc.continuation.finish()
    }

    // MARK: Approval skip-all (Hermes "/api/session/yolo" parity)

    /// Whether approvals are skipped for the given session ("Skip all this
    /// session" was tapped). Critical commands still require approval.
    func isYolo(_ sessionID: String) -> Bool {
        settings.yoloSessions.contains(sessionID)
    }

    /// Enable/disable skip-all-approvals for a session. Persisted per session.
    func setYolo(_ sessionID: String, _ on: Bool) {
        var list = settings.yoloSessions
        list.removeAll { $0 == sessionID }
        if on { list.append(sessionID) }
        settings.yoloSessions = list
        saveSettings()
    }

    // MARK: Data loading

    /// Reload sessions, skills and profiles from the backing stores.
    func reloadAll() async {
        await ensureRuntime()
        if let store {
            crumb("reloadAll: listing sessions (\(runtimeBackend))")
            sessions = (try? await store.list(limit: 500)) ?? []
            crumb("reloadAll: sessions listed (\(sessions.count))")
        }
        sessionVersion += 1

        skills = discoverSkills()
        skillVersion += 1

        let pm = ProfileManager()
        profiles = (try? await pm.list()) ?? []
    }

    // MARK: Per-chat selections

    func configName(for sessionID: String?) -> String {
        if let sid = sessionID, let c = settings.sessionConfig[sid], !c.isEmpty { return c }
        return settings.activeConfig
    }

    func profileName(for sessionID: String?) -> String? {
        if let sid = sessionID, let p = settings.sessionProfile[sid], !p.isEmpty { return p }
        return nil
    }

    func thinkingLevel(for sessionID: String?) -> String {
        if let sid = sessionID, let t = settings.sessionThinking[sid], !t.isEmpty { return t }
        return settings.thinkingLevel
    }

    // MARK: Session helpers

    func activeSession() -> Session? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    func sessionTitle(_ s: Session) -> String {
        if let custom = settings.sessionTitles[s.id],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        if let first = s.messages.first(where: { $0.role == .user }),
           let c = first.content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trunc(c, 44)
        }
        // Unloaded summaries carry the title hint (first user message) in
        // `title`; fall back to "New chat" only when neither exists.
        if let t = s.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trunc(t, 44)
        }
        return "New chat"
    }

    func isArchived(_ id: String) -> Bool {
        settings.archivedSessions.contains(id)
    }

    func isBookmarked(_ sessionID: String) -> Bool {
        settings.bookmarkedSessions.contains(sessionID)
    }

    // MARK: Chat categories

    /// The (still-existing) category id a session belongs to, if any.
    func categoryID(for sessionID: String) -> String? {
        guard let cid = settings.sessionCategories[sessionID],
              settings.chatCategories.contains(where: { $0.id == cid }) else { return nil }
        return cid
    }

    func categoryColor(for categoryID: String?) -> String {
        guard let cid = categoryID,
              let cat = settings.chatCategories.first(where: { $0.id == cid }) else { return "" }
        return cat.color
    }

    func categoryName(for categoryID: String?) -> String {
        guard let cid = categoryID,
              let cat = settings.chatCategories.first(where: { $0.id == cid }) else { return "" }
        return cat.name
    }
}
