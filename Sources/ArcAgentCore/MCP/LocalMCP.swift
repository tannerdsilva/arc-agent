import Foundation
import MCP

/// An in-process MCP client over the framework's network-free carrier.
///
/// arc's own tool surface, reached the way a peer's would be: through
/// ``MCPClient`` over ``LocalClientTransport``, with no process, pipe or socket.
/// The caller is the local process, so every tool is visible and reachable at
/// ``AccessLevel/root``.
///
/// One bridge serves two purposes — the introspection harness behind
/// `arc mcp local`, and the seam a future tool source (a pack, a subprocess
/// server) plugs into without a second mechanism.
public actor LocalMCPBridge {

    /// The client this bridge owns.
    ///
    /// Exposed for typed callers that build an argument dictionary in their own
    /// scope. Swift 6 forbids forwarding a non-Sendable `[String: Any]` into the
    /// actor as a parameter (even a `sending` one) — the value must be created at
    /// the call site, which is why ``call(_:argumentsJSON:)`` decodes locally.
    public let client: MCPClient

    /// Bridges an explicit dispatcher.
    public init(
        dispatcher: ArcToolDispatcher,
        serverName: String = "arc",
        serverVersion: String = ArcAgentCore.version
    ) {
        self.client = MCPClient(
            transport: LocalClientTransport(
                dispatcher: dispatcher,
                configuration: .init(serverName: serverName, serverVersion: serverVersion)
            )
        )
    }

    /// Bridges every tool a registry holds.
    public init(
        registry: some ToolRegistry,
        serverName: String = "arc",
        serverVersion: String = ArcAgentCore.version
    ) {
        self.init(
            dispatcher: ArcToolDispatcher(registry: registry),
            serverName: serverName,
            serverVersion: serverVersion
        )
    }

    /// Connects on first use.
    ///
    /// `MCPClient.connect()` guards on `state == .idle`, so it must not be
    /// called twice; the bridge owns that decision rather than each caller.
    private func ready() async throws {
        if await client.currentState() == .idle {
            try await client.connect()
        }
    }

    /// The tool catalog as the in-process caller sees it.
    public func tools() async throws -> [RemoteToolDescriptor] {
        try await ready()
        return try await client.listTools()
    }

    /// Invokes a tool by name from a JSON argument object.
    ///
    /// Throws an `MCP remote error` for a name the dispatcher does not serve
    /// (`-32602`), not an error-valued result.
    public func call(_ name: String, argumentsJSON: String = "{}") async throws -> MCPToolResult {
        try await ready()
        // Decoded here, in the calling scope: see `client` on why this cannot be
        // a `[String: Any]` parameter.
        let arguments = try Self.decode(argumentsJSON)
        return try await client.callTool(name, arguments: arguments)
    }

    /// Decodes a JSON object of arguments.
    private static func decode(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LocalMCPError.argumentsNotAnObject(text)
        }
        return object
    }

    /// Closes the session. Safe to call more than once.
    public func close() async {
        await client.close()
    }
}

public extension MCPToolResult {

    /// The concatenated text blocks, which is what every arc tool returns.
    var text: String {
        content.compactMap { block in
            if case .text(let value) = block { return value }
            return nil
        }.joined()
    }
}

/// Errors raised by the in-process bridge before anything reaches the wire.
public enum LocalMCPError: Error, CustomStringConvertible {

    /// The argument payload was not a JSON object.
    case argumentsNotAnObject(String)

    public var description: String {
        switch self {
        case .argumentsNotAnObject(let text):
            return "arguments must be a JSON object, got: \(text)"
        }
    }
}