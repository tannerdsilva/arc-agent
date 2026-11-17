import ArcToolKit

/// The read side of a tool surface: what a consumer that only *advertises* or
/// *looks up* tools needs.
///
/// `tool_search` and the MCP dispatcher hold this, so neither can reach
/// `register` — mutating a copy would be a lie either way. A reader that wants
/// to *search* the live catalog reads whatever the ``ToolDependency`` slot
/// currently names; whoever produced the newest surface fills it.
public protocol ToolCatalogReader: Sendable {

    /// Look up a tool by name.
    ///
    /// - Parameter name: The tool's unique name.
    /// - Returns: The tool and its origin, or `nil` if no tool with that name
    ///   is registered.
    func lookup(name: String) -> RegisteredTool?

    /// All registered tools, each with its origin.
    ///
    /// The order is **name order**, and that is a contract rather than a
    /// convenience: this array is rendered into the prompt prefix, so a
    /// registry whose order is stable across processes is what lets the
    /// provider's prompt cache hit.
    var allTools: [RegisteredTool] { get }
}

/// A registry that manages tool discovery, registration, and lookup.
///
/// ``ToolRegistry`` is the narrow waist of the ARC Agent tool system. Every tool
/// — whether compiled into the binary or loaded from a plugin — is registered
/// through this interface. The agent loop queries the registry to build the
/// schema array sent to the LLM and to dispatch tool calls to the correct
/// handler.
///
/// ## Concurrency
///
/// ``ToolRegistry`` is ``Sendable``. Implementations must ensure that
/// ``lookup(name:)`` and ``allTools`` are safe to call from any task
/// concurrently with registration.
///
/// ## Provenance
///
/// Registration carries a ``ToolOrigin`` and lookup returns a
/// ``RegisteredTool`` — the tool *and* the origin its registry assigned. A name
/// therefore has exactly one owner, and that owner always has an origin:
/// provenance cannot be dropped on the floor because ``lookup(name:)`` cannot
/// return a bare tool.
///
/// ## Design (Protocols First)
///
/// This protocol is the first step in the three-step design ordering:
/// 1. **Protocol** — ``ToolRegistry`` (this protocol)
/// 2. **Concrete types** — ``CompileTimeToolRegistry``, ``PluginToolRegistry``
/// 3. **Macros** — A `#tool` macro may eventually generate registration calls
///
/// See ``CompileTimeToolRegistry`` for the built-in implementation.
public protocol ToolRegistry: Sendable, ToolCatalogReader {

    /// Register a tool with the registry.
    ///
    /// - Parameters:
    ///   - tool: The tool entry to register (built-in or plugin — anything
    ///     conforming to ``AgentTool``).
    ///   - origin: Where the tool came from, assigned by the admitting
    ///     registry — never declared by the tool.
    /// - Throws: ``ToolRegistryError/duplicateName`` if a tool with the same
    ///   name is already registered.
    mutating func register(_ tool: any AgentTool, origin: ToolOrigin) throws

    /// Look up a tool by name.
    ///
    /// - Parameter name: The tool's unique name.
    /// - Returns: The tool and its origin, or `nil` if no tool with that name
    ///   is registered.
    /// - Note: Provenance survives the lookup; a caller that only needs to
    ///   dispatch reads ``RegisteredTool/tool``.
    func lookup(name: String) -> RegisteredTool?

    /// All registered tools, each with its origin.
    ///
    /// The order is **name order**, and that is a contract rather than a
    /// convenience: this array is rendered into the prompt prefix, so a
    /// registry whose order is stable across processes is what lets the
    /// provider's prompt cache hit. Both implementations sort — a runtime tier
    /// that arrives in dictionary iteration order would otherwise reorder the
    /// prefix on every launch.
    var allTools: [RegisteredTool] { get }

    /// A monotonically increasing identity for this surface's contents.
    ///
    /// a value registry is re-pointed rather than mutated in place, so a cache
    /// cannot watch it — it compares this number. an immutable registry answers
    /// `0` forever; an admitting registry bumps on every accepted mutation.
    var revision: Int { get }
}

// MARK: - Errors

/// Errors that can occur during tool registry operations.
public enum ToolRegistryError: Error, Sendable, CustomStringConvertible {
    /// A tool with the same name is already registered.
    case duplicateName(String)

    public var description: String {
        switch self {
        case .duplicateName(let name):
            return "A tool named '\(name)' is already registered."
        }
    }
}
