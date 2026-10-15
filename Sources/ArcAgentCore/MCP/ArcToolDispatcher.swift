import Foundation
import MCP

/// Serves an ARC tool surface as MCP, with no per-tool registration.
///
/// One dispatch surface sits behind every MCP carrier arc uses: swift-mcp's
/// network-free `LocalClientTransport` (arc's own agent calling arc's own
/// tools), the outward `MCPServer`, and any carrier added later. The catalog,
/// the access gate and the wire schemas all derive from the same
/// `[any AgentTool]` array the registry holds, so the served surface cannot
/// drift from the registered one.
///
/// Hand-written rather than macro-generated (`@MCPApplication`) on purpose:
/// arc's tool declarations are `ToolEntry` values, and a generated pack would be
/// a second declaration of the same tools. A hand-written dispatcher is a
/// supported shape in swift-mcp — only `toolCatalog(for:)` is macro-shaped.
///
/// See `.hermes/plans/2026-10-14_163703-mcp-pack-and-carriers.md`.
public struct ArcToolDispatcher: MCPToolDispatcher {

    /// The tools served, as the registry holds them.
    private let entries: [any AgentTool]

    /// Serves an explicit tool array.
    public init(entries: [any AgentTool]) {
        self.entries = entries
    }

    /// Serves every tool a registry holds.
    public init(registry: some ToolRegistry) {
        self.entries = registry.allTools
    }

    // MARK: - MCPToolDispatcher

    public func toolCatalog(for callerAccessLevel: AccessLevel) -> [MCPToolDescriptor] {
        entries.compactMap { entry in
            guard callerAccessLevel >= Self.access(for: entry.toolset) else { return nil }
            return MCPToolDescriptor(
                name: entry.name,
                description: entry.description,
                parameters: Self.parameters(from: entry.schema)
            )
        }
    }

    public func requiredAccess(named name: String) -> AccessLevel? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return Self.access(for: entry.toolset)
    }

    public func callTool(
        named name: String,
        arguments: [String: Any],
        context: MCPContext
    ) async throws -> MCPToolResult? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        // `context.arguments`, never the raw `arguments` parameter: a raw
        // `[String: Any]` sent into the `@Sendable` handler is a region-isolation
        // error under Swift 6 (`sending 'arguments' risks causing data races`).
        return .text(try await entry.handler(context.arguments))
    }

    // MARK: - Access policy

    /// The level a toolset requires. Deny by default, in two tiers.
    ///
    /// The caller's level is set by the carrier, not by arc: the in-process
    /// client and a stdio caller arrive as `.root`, a loopback TCP caller as
    /// `.admin`, and any other address as `.public` — swift-mcp's
    /// `TCPTransport.defaultAccessResolver`.
    ///
    /// - `.root` — filesystem writes, shell, code execution, desktop and browser
    ///   control. Local process only. These must never be reachable over a
    ///   socket, and none are listed below.
    /// - `.admin` — everything else: informational and organisational toolsets.
    ///   Reachable from loopback, never from a non-loopback address.
    /// - `.public` — deliberately nothing. No arc toolset is exposed to an
    ///   unauthenticated network caller. `MCPToolConfiguration` defaults
    ///   `requiredAccess` to `.public`, which is what made every registered tool
    ///   reachable over TCP before this gate existed.
    static func access(for toolset: String) -> AccessLevel {
        localOnlyToolsets.contains(toolset) ? .root : .admin
    }

    /// Toolsets requiring the local process: arbitrary filesystem, shell,
    /// code-execution and desktop control.
    static let localOnlyToolsets: Set<String> = [
        "file",
        "terminal",
        "code_execution",
        "computer_use",
        "browser",
    ]

    // MARK: - Caller resolution

    /// Maps a TCP caller's source address to an access level.
    ///
    /// swift-mcp's `TCPTransport` passes `channel.remoteAddress?.description`, and
    /// `TCPTransport.defaultAccessResolver` tests colon-anchored prefixes
    /// (`"[IPv4]127.0.0.1:"`) that NIO's description does not start with — NIO
    /// renders a host/address pair (`"[IPv4]127.0.0.1/127.0.0.1:54321"`). Measured:
    /// with the default resolver every loopback caller arrived as `.public` and
    /// was advertised zero tools. Arc therefore supplies its own resolver and owns
    /// this policy: loopback is `.admin`, every other address `.public`.
    static func callerAccess(for address: String) -> AccessLevel {
        isLoopback(address) ? .admin : .public
    }

    /// Whether a peer address is the local machine.
    ///
    /// Compares the host portion exactly rather than substring-matching, so a
    /// remote address that merely contains `::1` (`2001:db8::1`) is not promoted.
    static func isLoopback(_ address: String) -> Bool {
        switch host(of: address) {
        case "127.0.0.1", "::1", "::ffff:127.0.0.1":
            return true
        default:
            return false
        }
    }

    /// Extracts the host from a peer address string.
    ///
    /// Handles the NIO shape (`[IPv4]127.0.0.1/127.0.0.1:54321` → `127.0.0.1`,
    /// `[IPv6]::1/::1:54321` → `::1`) and falls back to stripping a trailing port
    /// for unbracketed spellings.
    private static func host(of address: String) -> String {
        var text = address
        if let close = text.lastIndex(of: "]") {
            text = String(text[text.index(after: close)...])
        }
        if let slash = text.firstIndex(of: "/") {
            return String(text[text.startIndex..<slash])
        }
        if let colon = text.lastIndex(of: ":") {
            return String(text[text.startIndex..<colon])
        }
        return text
    }

    // MARK: - JSONSchema -> MCP parameter metadata

    /// Translates arc's hand-written schema into the metadata the framework
    /// renders as the wire `inputSchema`.
    static func parameters(from schema: JSONSchema) -> [MCPParameterInfo] {
        guard case .object(_, let properties, let required) = schema else { return [] }
        let requiredSet = Set(required ?? [])
        return properties.keys.sorted().map { key in
            let property = properties[key]!
            return MCPParameterInfo(
                name: key,
                description: describe(property),
                required: requiredSet.contains(key),
                kind: kind(property, required: requiredSet.contains(key)),
                typeName: typeName(property),
                hasDefault: hasDefault(property)
            )
        }
    }

    private static func describe(_ schema: JSONSchema) -> String? {
        switch schema {
        case .string(let d, _), .integer(let d, _), .number(let d, _),
             .boolean(let d, _), .enum(let d, _):
            return d
        case .object(let d, _, _):
            return d
        case .array(let d, _):
            return d
        }
    }

    private static func typeName(_ schema: JSONSchema) -> String {
        switch schema {
        case .string: return "String"
        case .integer: return "Int"
        case .number: return "Double"
        case .boolean: return "Bool"
        case .array: return "[Any]"
        case .object: return "[String: Any]"
        case .enum: return "String"
        }
    }

    private static func hasDefault(_ schema: JSONSchema) -> Bool {
        // Split rather than combined patterns: the associated default types
        // differ per case, so a shared binding does not compile.
        switch schema {
        case .string(_, let d): return d != nil
        case .integer(_, let d): return d != nil
        case .number(_, let d): return d != nil
        case .boolean(_, let d): return d != nil
        default: return false
        }
    }

    private static func kind(_ schema: JSONSchema, required: Bool) -> MCPParamKind {
        if case .boolean = schema, !required { return .flag }
        return required ? .argument : .option
    }
}