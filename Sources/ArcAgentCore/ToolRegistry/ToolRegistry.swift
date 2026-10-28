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
public protocol ToolRegistry: Sendable {

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
    /// The order is insertion order — tools registered first appear first.
    var allTools: [RegisteredTool] { get }

    /// Build the OpenAI-compatible function-calling schema array.
    ///
    /// This method filters tools by the enabled/disabled toolsets, runs
    /// availability checks, and maps each surviving tool to the OpenAI
    /// function-calling schema format.
    ///
    /// - Parameters:
    ///   - enabled: The set of enabled toolset names. If empty, all toolsets
    ///     are enabled.
    ///   - disabled: The set of disabled toolset names. Takes precedence over
    ///     `enabled`.
    /// - Returns: An array of OpenAI-compatible function-calling schemas.
    func buildToolSchemas(
        enabled: Set<String>,
        disabled: Set<String>
    ) -> [[String: Any]]
}

// MARK: - Default Implementation

extension ToolRegistry {

    /// Default implementation of ``buildToolSchemas(enabled:disabled:)``.
    ///
    /// 1. Resolves enabled toolsets to tool names (or uses all tools if
    ///    `enabled` is empty).
    /// 2. Subtracts disabled toolsets.
    /// 3. Runs `checkFn` for each tool and filters out unavailable ones.
    /// 4. Maps each surviving tool to the OpenAI function-calling format.
    public func buildToolSchemas(
        enabled: Set<String>,
        disabled: Set<String>
    ) -> [[String: Any]] {
        let tools = allTools.filter { tool in
            // If disabled, exclude
            guard !disabled.contains(tool.toolset) else { return false }

            // If enabled is non-empty, toolset must be in it
            if !enabled.isEmpty {
                guard enabled.contains(tool.toolset) else { return false }
            }

            // Run availability check
            if let check = tool.checkFn {
                guard check() else { return false }
            }

            return true
        }

        return tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.schema.asDictionary(),
                ] as [String: Any],
            ] as [String: Any]
        }
    }
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
