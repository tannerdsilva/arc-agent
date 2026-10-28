import Foundation

/// The core library for ARC Agent.
///
/// This module contains the agent loop, tool registry, provider profiles,
/// session management, and all other subsystems described in VISION.md.
///
/// For now, it exposes the tool registry and built-in tools. Each subsystem
/// will be fleshed out incrementally as we validate the architecture through
/// prototypes.
public enum ArcAgentCore {

    /// The current library version.
    public static let version = "0.1.0"

    /// Build a ``CompileTimeToolRegistry`` pre-loaded with the built-in tools,
    /// scoped to `context`.
    ///
    /// This is the only entry point: a tool surface cannot be built without
    /// saying *whose* surface it is. The scope-bearing tools capture the
    /// values they are given here — `memory` its provider, `profile_edit` its
    /// documents and roster, the roster tools their store — so no tool body
    /// looks a process-global up at call time (GROUNDZERO slice 4).
    ///
    /// - Parameters:
    ///   - context: the calling identity — profile, session, workspace, grant.
    ///   - profiles: the roster the profile tools read and write.
    ///   - memory: this caller's memory provider. It must address the same
    ///     profile directory as `context.profile` or `memory` and
    ///     `profile_edit` would address two documents again.
    ///   - sessions: the session store `session_search` reads. Wired here
    ///     rather than in the agent so a registry built for a caller with no
    ///     `ArcAgent` (the CLI's `arc local` bridge, the daemon's MCP server)
    ///     still searches the right store. Slice 6 replaces this ambient
    ///     assignment with a constructor parameter.
    ///   - messaging: the inter-agent messaging service. When `nil` the
    ///     `send_bot_message` tool is **not registered**: a surface with no
    ///     delivery path does not advertise one (the CLI carries neither).
    ///   - groupChats: the group-chat room manager. `nil` likewise omits
    ///     `send_group_chat`. The daemon supplies both.
    ///   - kanban: the board the `kanban_*` tools act on. `nil` keeps the tools
    ///     in the surface (they are part of the compiled list) but they report
    ///     that no board is available.
    ///   - delivery: the platform delivery path `send_message` acts through.
    ///     `nil` leaves the tool explaining that no delivery manager is wired.
    ///   - dependencies: the per-agent slots the tools capture. Pass the bundle
    ///     you want ``ArcAgent`` to fill when you build the surface for an
    ///     agent; the default is a fresh bundle, which the registry carries so
    ///     the agent can adopt it.
    /// - Returns: A configured ``CompileTimeToolRegistry``.
    /// - Throws: If a built-in tool fails to register (should not happen in
    ///   normal operation since built-in tool names are unique by construction).
    public static func buildRegistry(
        context: ToolContext,
        profiles: any ProfileStore,
        memory: any MemoryProvider,
        sessions: any SessionStore,
        messaging: (any BotMessageDelivering)? = nil,
        groupChats: GroupChatManager? = nil,
        kanban: (any KanbanBoard)? = nil,
        delivery: DeliveryManager? = nil,
        dependencies: ToolDependencies = ToolDependencies()
    ) throws -> CompileTimeToolRegistry {
        var registry = CompileTimeToolRegistry(toolDependencies: dependencies)

        // Resources the caller already owns: bound before the tools are
        // registered so a handler can never run against an empty slot the
        // builder could have filled (GROUNDZERO slice 6). A `nil` here means
        // "this caller owns none", never "clear what the bundle already had" —
        // a caller that pre-filled the slot (a test's fixture board, the
        // daemon's delivery manager) keeps it.
        dependencies.sessionStore.set(sessions)
        if let kanban { dependencies.kanbanBoard.set(kanban) }
        if let delivery { dependencies.sendMessageDelivery.set(delivery) }
        try registry.register(ReadFileTool.entry)
        try registry.register(WriteFileTool.entry)
        try registry.register(TerminalTool.entry)
        try registry.register(ProcessTool.entry)
        try registry.register(ProcessWatchTool.entry)
        try registry.register(WebSearchTool.entry)
        try registry.register(WebExtractTool.entry)
        try registry.register(MemoryTool.entry(context: context, memory: memory))
        try registry.register(SessionSearchTool.entry(store: dependencies.sessionStore))
        try registry.register(TodoTool.entry(store: dependencies.todoStore))
        try registry.register(SkillViewTool.entry)
        try registry.register(SkillManageTool.entry)
        try registry.register(SkillsListTool.entry)
        try registry.register(ProfileEditTool.entry(
            context: context,
            documents: documents(for: context),
            profiles: profiles
        ))
        try registry.register(ClarifyTool.entry)
        try registry.register(PatchTool.entry)
        try registry.register(SearchFilesTool.entry)
        try registry.register(ExecuteCodeTool.entry(
            grant: context.grant, timeout: dependencies.executeCodeTimeout))
        try registry.register(DelegateTaskTool.entry(manager: dependencies.delegationManager))
        try registry.register(ProjectListTool.entry)
        try registry.register(ProjectCreateTool.entry)
        try registry.register(ProjectSwitchTool.entry)
        try registry.register(ToolSearchTool.entry(registry: dependencies.toolSearchRegistry))
        try registry.register(SendMessageTool.entry(
            delivery: dependencies.sendMessageDelivery,
            homeChatResolver: dependencies.homeChatResolver))
        try registry.register(ListChildrenTool.entry(manager: dependencies.delegationManager))
        try registry.register(SteerChildTool.entry(manager: dependencies.delegationManager))
        try registry.register(StopChildTool.entry(manager: dependencies.delegationManager))
        try registry.register(KanbanTools.create(board: dependencies.kanbanBoard))
        try registry.register(KanbanTools.list(board: dependencies.kanbanBoard))
        try registry.register(KanbanTools.show(board: dependencies.kanbanBoard))
        try registry.register(KanbanTools.complete(board: dependencies.kanbanBoard))
        try registry.register(KanbanTools.block(board: dependencies.kanbanBoard))

        // Profile/bot mode tools. Service-scoped: they act on the roster, not
        // on the calling profile's documents.
        try registry.register(ListProfilesTool.entry(profiles: profiles))
        try registry.register(GetProfileTool.entry(profiles: profiles))
        try registry.register(CreateProfileTool.entry(profiles: profiles))
        try registry.register(DeleteProfileTool.entry(context: context, profiles: profiles))

        // Messaging tools exist only where the delivery path does: absent
        // services mean absent tools, not tools that fail at call time.
        if let messaging {
            try registry.register(SendBotMessageTool.entry(
                context: context, profiles: profiles, messaging: messaging))
        }
        if let groupChats {
            try registry.register(SendGroupChatTool.entry(
                context: context, profiles: profiles, groupChats: groupChats))
        }

        // Browser tools (CDP provider — no Playwright/Node required)
        try registry.register(BrowserTools.navigate)
        try registry.register(BrowserTools.snapshot)
        try registry.register(BrowserTools.click)
        try registry.register(BrowserTools.type)
        try registry.register(BrowserTools.press)
        try registry.register(BrowserTools.scroll)
        try registry.register(BrowserTools.back)
        try registry.register(BrowserTools.console)
        try registry.register(BrowserTools.getImages)
        try registry.register(BrowserTools.vision)
        try registry.register(BrowserTools.dialog)
        try registry.register(BrowserTools.cdp)
        try registry.register(BrowserTools.connect)
        try registry.register(BrowserTools.close)
        try registry.register(ComputerUseTool.entry)
        try registry.register(MCPClientTool.entry)
        Task { await BrowserRegistry.shared.register(CDPBrowserProvider()) }

        // `tool_search` sees the surface it lives on; the agent re-points this
        // at its own registry (which may carry plugin tools) when it adopts the
        // bundle.
        dependencies.toolSearchRegistry.set(registry)

        return registry
    }

    // MARK: - Scope

    /// The documents `context` owns: `MEMORY.md` / `USER.md` under the profile
    /// directory, bound to the calling grant.
    ///
    /// One root, chosen from the profile name — never from caller input after
    /// construction. `ProfileManager.memoryURL(for:)` is the same directory the
    /// CLI already hands `FileMemoryProvider`, which is what makes the `memory`
    /// tool and `profile_edit` address one document.
    public static func documents(for context: ToolContext) -> ProfileDocuments {
        let root = ProfileManager.memoryURL(for: context.profile.rawValue)
            ?? URL(fileURLWithPath: ProfileManager.profilesDir)
                .appendingPathComponent(context.profile.rawValue, isDirectory: true)
        return ProfileDocuments(root: root, grant: context.grant)
    }
}
