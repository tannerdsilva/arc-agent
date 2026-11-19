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

    /// How this dispatcher reads its surface. A slot is read per call, so a tool
    /// admitted after construction is served; a fixed array is for carriers whose
    /// surface genuinely cannot change (a compiled-in registry, a test fixture).
    private let catalog: @Sendable () -> [any AgentTool]

    public init(entries: [any AgentTool]) {
        self.catalog = { entries }
    }

    /// Serves whatever a late-bound slot currently holds.
    ///
    /// The slot, not the registry: `MutableToolRegistry` is a value, so a
    /// dispatcher handed a registry can only ever serve the copy it was built
    /// with. The owner re-points the slot when the surface changes.
    public init(surface: ToolDependency<any ToolCatalogReader>) {
        self.catalog = { surface.get()?.allTools.map { $0.tool } ?? [] }
    }

    // MARK: - MCPToolDispatcher

    public func toolCatalog(for callerAccessLevel: AccessLevel) -> [MCPToolDescriptor] {
        let entries = catalog()
        return entries.compactMap { entry in
            guard callerAccessLevel >= Self.access(for: entry) else { return nil }
            return MCPToolDescriptor(
                name: entry.name,
                description: entry.description,
                parameters: Self.parameters(from: entry.schema)
            )
        }
    }

    public func requiredAccess(named name: String) -> AccessLevel? {
        let entries = catalog()
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return Self.access(for: entry)
    }

    public func callTool(
        named name: String,
        arguments: [String: Any],
        context: MCPContext
    ) async throws -> MCPToolResult? {
        let entries = catalog()
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        // `context.arguments`, never the raw `arguments` parameter: a raw
        // `[String: Any]` sent into the `@Sendable` handler is a region-isolation
        // error under Swift 6 (`sending 'arguments' risks causing data races`).
        return .text(try await entry.handler(context.arguments))
    }

    // MARK: - Access policy

    /// The access a tool requires: its own placement, then its toolset's tier.
    ///
    /// Placement is consulted first because it is the narrower declaration — a
    /// tool that holds state it cannot release is served to this process only,
    /// whatever its toolset's tier would admit.
    static func access(for entry: any AgentTool) -> AccessLevel {
        if entry.placement == .inProcessOnly { return .root }
        return access(for: entry.toolset)
    }

    /// The level a toolset's tools carry, straight off the type.
    ///
    /// The caller's level is set by the carrier, not by arc: the in-process
    /// client and a stdio caller arrive as `.root`, a loopback TCP caller as
    /// `.admin`, and any other address as `.public` — arc's own resolver, since
    /// swift-mcp's `TCPTransport.defaultAccessResolver` never matches NIO's
    /// address description.
    ///
    /// - `.inProcessOnly` → `.root`: filesystem writes, shell, code execution,
    ///   desktop and browser control, and every foreign namespace a plugin
    ///   claims. Local process only; none of it is reachable over a socket.
    /// - `.loopback` → `.admin`: reachable from this machine, never from a
    ///   non-loopback address.
    /// - `.network` → `.public`: deliberately nothing uses this today. A
    ///   toolset that opts in is one arc means to expose to the network, and
    ///   that decision now lives on the type instead of in this function.
    ///
    /// An unknown toolset is `.root` rather than "no such tool" on purpose:
    /// `requiredAccess(named:)` returning nil is the framework's unknown-tool
    /// signal (`-32602`), so nil would also hide an internal tool from arc's own
    /// in-process carrier. Fail-closed here means **denied to carriers, not
    /// denied to the agent.**
    static func access(for toolset: Toolset) -> AccessLevel {
        switch toolset.reach {
        case .inProcessOnly: return .root
        case .loopback:      return .admin
        case .network:       return .public
        }
    }

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