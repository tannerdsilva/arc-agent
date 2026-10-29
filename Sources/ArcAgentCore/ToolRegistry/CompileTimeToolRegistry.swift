import ArcToolKit

/// A compile-time tool registry that stores tools in a dictionary.
///
/// ``CompileTimeToolRegistry`` is the primary ``ToolRegistry`` implementation
/// for built-in tools. Tools are registered at module initialization time via
/// static extensions or an explicit registration call during agent setup.
///
/// Every tool admitted here is stamped ``ToolOrigin/builtin``: this registry is
/// the compiled-in tier, and the one-argument ``register(_:)`` the built-in
/// declarations use supplies that origin without naming it.
///
/// ## Thread Safety
///
/// This type is a value type (struct). Mutation requires `var` access, which
/// means it must be used from a single owner or behind an actor. The agent
/// loop holds the registry on its actor, serializing all access.
///
/// ## Usage
///
/// ```swift
/// var registry = CompileTimeToolRegistry()
/// try registry.register(readFileEntry)
/// try registry.register(writeFileEntry)
///
/// let schemas = registry.buildToolSchemas(enabled: ["file"], disabled: [])
/// ```
public struct CompileTimeToolRegistry: ToolRegistry {

    /// The internal storage, keyed by tool name. Each value carries the origin
    /// its admission assigned.
    private var tools: [String: RegisteredTool] = [:]

    /// The per-agent dependency slots the tools in this registry were built
    /// with (GROUNDZERO slice 6).
    ///
    /// Carried on the registry rather than passed alongside it so ``ArcAgent``
    /// can adopt exactly the slots its tools captured — `todo`'s store and the
    /// agent's store cannot drift apart. A registry built without naming slots
    /// gets a fresh, empty bundle: one surface, one bundle.
    public let toolDependencies: ToolDependencies

    /// Create an empty registry.
    ///
    /// - Parameter toolDependencies: the slots the tools registered here were
    ///   built with. The default is a fresh bundle, which is what a registry
    ///   assembled by hand (tests, fixtures) wants.
    public init(toolDependencies: ToolDependencies = ToolDependencies()) {
        self.toolDependencies = toolDependencies
    }

    // MARK: - ToolRegistry

    /// Register a tool with an explicit origin.
    ///
    /// - Throws: ``ToolRegistryError/duplicateName`` if a tool named
    ///   `tool.name` is already registered.
    public mutating func register(_ tool: any AgentTool, origin: ToolOrigin) throws {
        guard tools[tool.name] == nil else {
            throw ToolRegistryError.duplicateName(tool.name)
        }
        tools[tool.name] = RegisteredTool(tool: tool, origin: origin)
    }

    /// Register a compiled-in tool.
    ///
    /// Convenience for the built-in declarations: this registry is the
    /// compiled-in tier, so the origin is ``ToolOrigin/builtin`` by
    /// construction and the call sites do not name it.
    ///
    /// - Throws: ``ToolRegistryError/duplicateName`` if a tool named
    ///   `tool.name` is already registered.
    public mutating func register(_ tool: any AgentTool) throws {
        try register(tool, origin: .builtin)
    }

    /// Look up a tool by name, with its origin.
    public func lookup(name: String) -> RegisteredTool? {
        tools[name]
    }

    /// All registered tools, with their origins, in name order.
    public var allTools: [RegisteredTool] {
        // Dictionary values are not ordered, but for deterministic schema
        // output we sort by name.
        tools.values.sorted { $0.name < $1.name }
    }

    /// A copy with `replacements` taking the place of the built-ins that share
    /// their name (an unknown name is added).
    ///
    /// A built-in captures its dependencies at construction — a memory
    /// provider, a profile's documents — and ``register(_:origin:)`` refuses a
    /// duplicate name, so a caller that must address a *different* per-call
    /// scope cannot re-point one in place. It builds the copy it needs
    /// instead: the web UI's turns run for a session that is not necessarily
    /// the active chat, and `memory` / `profile_edit` must address the turn's
    /// profile rather than whichever chat was active when the surface was last
    /// rebuilt (GROUNDZERO2 slice 4).
    ///
    /// Replacements are admitted at the compiled-in tier (``ToolOrigin/builtin``),
    /// which is the tier they replace.
    public func replacing(_ replacements: [any AgentTool]) -> CompileTimeToolRegistry {
        var copy = self
        for tool in replacements {
            copy.tools[tool.name] = RegisteredTool(tool: tool, origin: .builtin)
        }
        return copy
    }
}
