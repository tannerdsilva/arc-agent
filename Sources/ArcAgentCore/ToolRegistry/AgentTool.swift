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

// MARK: - Availability (one value)

/// What must be true for a tool to be advertised.
///
/// One value replaced two members. A synchronous availability closure was
/// declared by the protocol and implemented by nobody, so it could not express
/// the asynchronous checks its own doc comment promised; the environment list
/// beside it was declared by six built-ins and consulted by nothing, which made
/// every one of those declarations ceremony. Availability is now a decision a
/// tool *declares*, and the schema renderer and the web UI's tool panel both
/// evaluate it.
public enum ToolAvailability: Sendable, Hashable {

    /// Advertised whenever its toolset is enabled.
    case always

    /// Advertised only when every named variable is present and non-empty.
    ///
    /// Empty and unset are both unmet: an empty credential is not a
    /// credential.
    case requiresEnv([String])
}

extension ToolAvailability {

    /// The variables this availability names, in declaration order.
    ///
    /// Empty for ``always``. The web UI's "Requires env" row renders this so
    /// the listing stays one line rather than a `switch` in a view builder.
    public var requiredEnvNames: [String] {
        switch self {
        case .always:
            return []
        case .requiresEnv(let names):
            return names
        }
    }

    /// `nil` when the tool may be advertised; otherwise a reason naming the
    /// missing variables.
    ///
    /// - Parameter env: The environment to test against. A caller renders once
    ///   and hands the same dictionary to every tool in that render, so one
    ///   process-environment read serves the whole surface.
    public func unavailableReason(env: [String: String]) -> String? {
        switch self {
        case .always:
            return nil
        case .requiresEnv(let names):
            let missing = names.filter { name in
                guard let value = env[name] else { return true }
                return value.isEmpty
            }
            guard missing.isEmpty == false else { return nil }
            return "missing required environment: \(missing.joined(separator: ", "))"
        }
    }
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

    /// The toolset this tool belongs to (e.g. `.file`, `.web`, `.terminal`).
    ///
    /// Toolsets are the grouping mechanism for enabling/disabling categories
    /// of tools at the agent level — and, since T3a, the carrier of the two
    /// decisions that used to live in four separate string tables: who may
    /// reach the tools (``Toolset/Reach``) and whether they render eagerly or
    /// defer behind the `tool_search` bridge (``Toolset/Disclosure``).
    ///
    /// A site that only needs the spelling reads ``toolsetName``; a site that
    /// decides something takes the type.
    var toolset: Toolset { get }

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

    /// What must be true for this tool to be advertised.
    ///
    /// The default is ``ToolAvailability/always``. This one value replaces the
    /// two members that used to sit here: a synchronous closure with zero
    /// implementations, which could not express the async work its own doc
    /// comment described, and an environment list that was inert on every
    /// built-in — no schema path ever consulted it.
    var availability: ToolAvailability { get }

    /// Whether this tool may run concurrently with siblings in one batch.
    ///
    /// Default `false` — the conservative polarity, and the one that keeps a
    /// side-effecting tool serialised until someone says otherwise. The
    /// planner in ``ArcAgent`` asks the tool through the live surface rather
    /// than reading a name table that could drift from the declarations.
    var parallelSafe: Bool { get }

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

    /// Display / config / wire spelling. Every site that only **reads** a name
    /// keeps compiling; every site that **decides** something now needs the type.
    public var toolsetName: String { toolset.name }

    /// Default: advertised whenever its toolset is enabled.
    public var availability: ToolAvailability { .always }

    /// Convenience over ``ToolAvailability/unavailableReason(env:)`` — the
    /// question a renderer asks each tool once per render.
    public func unavailableReason(env: [String: String]) -> String? {
        availability.unavailableReason(env: env)
    }

    /// Default: serialised. Side effects stay ordered until a tool says its
    /// reads are independent of its siblings.
    public var parallelSafe: Bool { false }

    /// Default: reachable wherever its toolset's tier admits it.
    public var placement: ToolPlacement { .anyCarrier }

    /// Default: no emoji.
    public var emoji: String? { nil }
}