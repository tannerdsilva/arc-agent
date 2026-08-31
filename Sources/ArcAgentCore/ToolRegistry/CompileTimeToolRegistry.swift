/// A compile-time tool registry that stores tools in a dictionary.
///
/// ``CompileTimeToolRegistry`` is the primary ``ToolRegistry`` implementation
/// for built-in tools. Tools are registered at module initialization time via
/// static extensions or an explicit registration call during agent setup.
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

    /// The internal storage, keyed by tool name.
    private var tools: [String: ToolEntry] = [:]

    /// Create an empty registry.
    public init() {}

    // MARK: - ToolRegistry

    /// Register a tool.
    ///
    /// - Throws: ``ToolRegistryError.duplicateName`` if a tool named
    ///   `tool.name` is already registered.
    public mutating func register(_ tool: ToolEntry) throws {
        guard tools[tool.name] == nil else {
            throw ToolRegistryError.duplicateName(tool.name)
        }
        tools[tool.name] = tool
    }

    /// Look up a tool by name.
    public func lookup(name: String) -> ToolEntry? {
        tools[name]
    }

    /// All registered tools, in registration order.
    public var allTools: [ToolEntry] {
        // Dictionary values are not ordered, but for deterministic schema
        // output we sort by name.
        tools.values.sorted { $0.name < $1.name }
    }
}
