import Foundation
import MCP

/// A source of tools for the agent surface.
///
/// ``ArcToolDispatcher`` projects arc's registry *outward* onto MCP carriers.
/// ``ToolSource`` is the inverse: it projects a pack reached *through* a carrier
/// into tools the agent loop can call. Together they close the loop —
/// pack → carrier → source → registry → dispatcher → outward — with the access
/// roster deciding whether the last leg is legal.
///
/// A tool minted here is an ordinary ``AgentTool``: the loop, the schema builder
/// and the disclosure machinery cannot tell it from a built-in, which is the
/// point. Placement is a property of the source's *carrier*, never of the tool:
/// a source built over ``LocalMCPBridge`` reaches tools that exist only in this
/// address space, so a pack that captures state (a key, an unlocked store, a live
/// connection) has no out-of-process form to be re-placed onto.
public protocol ToolSource: Sendable {

    /// The source's name, for logging and duplicate-name diagnostics.
    var name: String { get }

    /// The tools this source contributes, in catalog order.
    func tools() async throws -> [any AgentTool]
}

/// The registry itself as a source, so surface assembly is uniform.
///
/// A source must not contribute a name the registry it is assembled into already
/// holds: ``MutableToolRegistry/register(_:)`` refuses the duplicate rather than
/// letting two tools share one name on the model surface.
public struct RegistryToolSource: ToolSource {

    public let name = "registry"
    private let registry: any ToolRegistry

    public init(registry: any ToolRegistry) {
        self.registry = registry
    }

    public func tools() async throws -> [any AgentTool] {
        registry.allTools
    }
}

/// Tools from a pack reached over the in-process carrier — the internal-tool rung.
///
/// The pack's dispatcher may capture state that must not leave the process, and
/// this carrier has no process, pipe or socket to leak it through. The pack
/// declares the toolset its tools belong to; the access roster decides what that
/// toolset is reachable from.
public struct LocalPackToolSource: ToolSource {

    public let name: String

    /// The toolset every tool this pack serves belongs to.
    public let toolset: String

    /// The carrier this source reaches its pack through.
    ///
    /// Public so its owner can close it (``LocalMCPBridge/close()``) — the source
    /// never owns a session's lifecycle.
    public let bridge: LocalMCPBridge

    public init(name: String = "local", toolset: String, bridge: LocalMCPBridge) {
        self.name = name
        self.toolset = toolset
        self.bridge = bridge
    }

    /// Reaches an explicit dispatcher over the in-process carrier.
    public init(name: String = "local", toolset: String, dispatcher: ArcToolDispatcher) {
        self.init(name: name, toolset: toolset, bridge: LocalMCPBridge(dispatcher: dispatcher))
    }

    public func tools() async throws -> [any AgentTool] {
        try await bridge.tools().map { descriptor in
            PackToolEntry(
                name: descriptor.name,
                toolset: toolset,
                description: descriptor.description ?? "",
                schema: Self.schema(from: descriptor.inputSchema),
                bridge: bridge
            )
        }
    }

    /// The wire `inputSchema` rendered as arc's schema.
    ///
    /// A descriptor carrying no `type` has no parameters to advertise, and the
    /// empty object is the honest translation — ``JSONSchema/init?(fromOpenAI:)``
    /// returns nil rather than inventing a shape.
    static func schema(from inputSchema: [String: AnyCodable]) -> JSONSchema {
        JSONSchema(fromOpenAI: inputSchema.mapValues { $0.value })
            ?? .object(properties: [:])
    }
}

/// A tool a ``ToolSource`` minted from a pack.
///
/// Structurally the same shape as ``ToolEntry`` — metadata plus a handler — so
/// the conformance is a plain structural match. The handler bridges into the
/// pack's carrier, encoding its arguments as the JSON object the wire carries:
/// the same cost ``MCPClientTool`` pays for a foreign server, paid here for an
/// in-process one.
struct PackToolEntry: AgentTool {

    let name: String
    let toolset: String
    let description: String
    let schema: JSONSchema
    let handler: ToolHandler

    init(
        name: String,
        toolset: String,
        description: String,
        schema: JSONSchema,
        bridge: LocalMCPBridge
    ) {
        self.name = name
        self.toolset = toolset
        self.description = description
        self.schema = schema
        self.handler = { arguments in
            // Encoded here, in the calling scope: a non-Sendable `[String: Any]`
            // cannot be forwarded into the bridge actor as a parameter, which is
            // exactly why `LocalMCPBridge.call` takes a JSON string. Serialization
            // failures throw rather than degrading to an empty object, so a tool
            // call never silently loses its arguments.
            let data = try JSONSerialization.data(withJSONObject: arguments)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            // `flattenedText`, not `text`: the framework folds a failed invocation
            // into an `isError` result rather than a throw, and its flat rendering
            // prefixes `Error: ` so a failure is not presented as success text to
            // the model. (`MCPClientManager.text(of:)` drops that signal — see the
            // phase-5 notes; the minted path keeps it.)
            return try await bridge.call(name, argumentsJSON: text).flattenedText
        }
    }
}