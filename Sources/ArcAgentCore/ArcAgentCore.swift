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

    /// Build a ``CompileTimeToolRegistry`` pre-loaded with the built-in tools.
    ///
    /// This is the primary entry point for creating a tool registry with all
    /// compiled-in tools. Additional tools can be registered after creation.
    ///
    /// - Returns: A configured ``CompileTimeToolRegistry``.
    /// - Throws: If a built-in tool fails to register (should not happen in
    ///   normal operation since built-in tool names are unique by construction).
    public static func buildDefaultRegistry() throws -> CompileTimeToolRegistry {
        var registry = CompileTimeToolRegistry()
        try registry.register(ReadFileTool.entry)
        try registry.register(WriteFileTool.entry)
        try registry.register(TerminalTool.entry)
        try registry.register(WebSearchTool.entry)
        try registry.register(WebExtractTool.entry)
        try registry.register(MemoryTool.entry)
        try registry.register(SessionSearchTool.entry)
        try registry.register(SkillViewTool.entry)
        try registry.register(ClarifyTool.entry)
        try registry.register(DelegateTaskTool.entry)
        try registry.register(ListChildrenTool.entry)
        try registry.register(SteerChildTool.entry)
        try registry.register(StopChildTool.entry)
        try registry.register(KanbanTools.create)
        try registry.register(KanbanTools.list)
        try registry.register(KanbanTools.show)
        try registry.register(KanbanTools.complete)
        try registry.register(KanbanTools.block)

        // Profile/bot mode tools
        try registry.register(ListProfilesTool.entry)
        try registry.register(GetProfileTool.entry)
        try registry.register(SendBotMessageTool.entry)
        try registry.register(CreateProfileTool.entry)
        try registry.register(DeleteProfileTool.entry)
        try registry.register(SendGroupChatTool.entry)

        // Media / integration tools (Hermes image_gen, tts, transcription,
        // video, outbound webhooks, code_execution, shell hooks)
        try registry.register(MediaTools.imageGenerate)
        try registry.register(MediaTools.tts)
        try registry.register(MediaTools.transcription)
        try registry.register(MediaTools.videoGenerate)
        try registry.register(WebhookTools.notify)
        try registry.register(CodeExecutionTool.entry)

        // Browser tools (CDP provider — no Playwright/Node required)
        try registry.register(BrowserTools.navigate)
        try registry.register(BrowserTools.snapshot)
        try registry.register(BrowserTools.click)
        try registry.register(BrowserTools.type)
        try registry.register(BrowserTools.press)
        try registry.register(BrowserTools.scroll)
        try registry.register(BrowserTools.back)
        Task { await BrowserRegistry.shared.register(CDPBrowserProvider()) }

        return registry
    }
}
