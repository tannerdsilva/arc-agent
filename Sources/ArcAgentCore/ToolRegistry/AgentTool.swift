import Foundation

// MARK: - Tool Protocol (Protocols First)

/// A tool executable by the agent.
///
/// ``AgentTool`` is the single protocol every kind of tool conforms to:
/// built-in tools (``ToolEntry``), executable plugin tools loaded from
/// `~/.arc/plugins/<name>/` (``PluginTool``), and any future tool kind
/// (MCP-backed, host-bridge, etc.). The registry — ``ToolRegistry`` — stores
/// heterogeneous tools behind this protocol, so the agent loop, schema
/// builder, and disclosure machinery never need to know *which* kind of tool
/// they are dispatching to.
///
/// ## Design (Protocols First)
///
/// This is the first step in the three-step design ordering:
/// 1. **Protocol** — ``AgentTool`` (this protocol)
/// 2. **Concrete types** — ``ToolEntry`` (built-in), ``PluginTool`` (executable
///    plugin) — both conform directly; no funky boxing or closure wrapping
///    needed to make a plugin tool look like a built-in.
/// 3. **Macros** — a `#tool` macro may eventually generate
///    ``AgentTool`` conformance for declaration-site tools.
///
/// ## Concurrency
///
/// ``AgentTool`` is ``Sendable``. A conforming tool is immutable metadata
/// plus a ``ToolHandler`` closure (itself ``Sendable``), so one instance can
/// be registered once and executed concurrently by the agent loop.
public protocol AgentTool: Sendable {

    /// The unique name of this tool (e.g. `"read_file"`).
    ///
    /// This is the identifier the LLM sends back in a `tool_calls` payload.
    /// Names should be `snake_case` and unique within a registry.
    var name: String { get }

    /// The toolset this tool belongs to (e.g. `"file"`, `"web"`, `"terminal"`).
    ///
    /// Toolsets are the grouping mechanism for enabling/disabling categories
    /// of tools at the agent level.
    var toolset: String { get }

    /// A human-readable description of what this tool does.
    ///
    /// Passed to the LLM as part of the function-calling schema. Good
    /// descriptions dramatically improve the model's ability to choose the
    /// right tool.
    var description: String { get }

    /// The JSON Schema describing this tool's parameters.
    ///
    /// Conforms to the OpenAI function-calling subset of JSON Schema.
    var schema: JSONSchema { get }

    /// The closure that executes this tool.
    ///
    /// Receives the parsed arguments dictionary (keys match the schema
    /// property names) and returns a string result that is fed back to the
    /// LLM as a tool response message.
    var handler: ToolHandler { get }

    /// An optional closure that checks whether this tool's requirements are
    /// met (e.g. a binary is installed, an environment variable is set).
    ///
    /// Return `true` if the tool is available, `false` otherwise. A `nil`
    /// check means "always available (no runtime dependencies)". The default
    /// is `nil`.
    var checkFn: ToolRequirementCheck? { get }

    /// Environment variable names this tool requires at runtime.
    ///
    /// The credential pool checks these when resolving credentials. Tools
    /// with missing required env vars are filtered out of the schema array
    /// sent to the LLM. The default is empty.
    var requiresEnv: [String] { get }

    /// An optional emoji for display purposes (e.g. `"📄"` for file tools).
    /// The default is `nil`.
    var emoji: String? { get }
}

// MARK: - Default requirements

extension AgentTool {

    /// Default: no availability check — the tool is always available.
    public var checkFn: ToolRequirementCheck? { nil }

    /// Default: no required environment variables.
    public var requiresEnv: [String] { [] }

    /// Default: no emoji.
    public var emoji: String? { nil }
}
