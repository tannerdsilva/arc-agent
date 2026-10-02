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

    /// Build a ``CompileTimeToolRegistry`` pre-loaded with the default tool
    /// set: file IO and shell only.
    ///
    /// This is the primary entry point for creating a tool registry with the
    /// built-in basic tools. Every other tool family compiled into the
    /// library — skills, memory, kanban, delegation, browser, web, project,
    /// profile, MCP — is deliberately NOT registered here; hosts opt in by
    /// registering the entries they want on top of this registry.
    ///
    /// - Returns: A configured ``CompileTimeToolRegistry``.
    /// - Throws: If a built-in tool fails to register (should not happen in
    ///   normal operation since built-in tool names are unique by construction).
    public static func buildDefaultRegistry() throws -> CompileTimeToolRegistry {
        var registry = CompileTimeToolRegistry()
        // file IO
        try registry.register(ReadFileTool.entry)
        try registry.register(WriteFileTool.entry)
        try registry.register(PatchTool.entry)
        try registry.register(SearchFilesTool.entry)
        // shell
        try registry.register(TerminalTool.entry)
        try registry.register(ProcessTool.entry)
        return registry
    }
}
