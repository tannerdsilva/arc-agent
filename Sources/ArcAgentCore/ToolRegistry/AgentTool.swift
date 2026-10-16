import Foundation

// MARK: - Placement (Protocols First)

/// Where a tool's capability may be exercised.
///
/// Declared by the *tool*, because that is where the contract is enforced:
/// ``ArcToolDispatcher`` reads it when it decides what a caller may see, so one
/// tool can be held below its toolset's tier without inventing a toolset for it.
public enum ToolPlacement: Sendable {

    /// Reachable by any carrier the tool's access tier admits.
    case anyCarrier

    /// Exercised only in this address space.
    ///
    /// For a tool whose state cannot leave the process — an encryption key, an
    /// unlocked store, a live connection. Maps to `.root` whatever the toolset's
    /// tier says, so no socket caller (loopback included) reaches it, while the
    /// agent and the in-process carrier still do.
    case inProcessOnly
}

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

    /// Where this tool's capability may be exercised.
    ///
    /// The default is ``ToolPlacement/anyCarrier``. A tool that captures state
    /// which cannot leave the process declares ``ToolPlacement/inProcessOnly``,
    /// and ``ArcToolDispatcher`` then serves it to `.root` callers only — the
    /// agent and the in-process carrier — whatever its toolset's tier says.
    var placement: ToolPlacement { get }

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

    /// Default: reachable wherever its toolset's tier admits it.
    public var placement: ToolPlacement { .anyCarrier }

    /// Default: no emoji.
    public var emoji: String? { nil }
}