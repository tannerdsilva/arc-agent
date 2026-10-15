import Foundation
import MCP
import ServiceLifecycle

/// Registry of MCP server sessions (reference `mcp_servers` config).
///
/// Sessions are swift-mcp `MCPClient` actors over `SubprocessClientTransport`:
/// the framework owns the spawn, the newline-delimited framing, the handshake,
/// the per-request deadlines and the shutdown ladder, so this actor owns only
/// config→session identity.
public actor MCPClientManager {
    public static let shared = MCPClientManager()

    private var configs: [String: MCPServerConfig] = [:]
    private var clients: [String: MCPClient] = [:]

    public init() {}

    /// Point the registry at a new `mcp_servers` block (called at agent start
    /// and after any config edit).
    ///
    /// A session is bound to the config it was spawned with, so a server whose
    /// config changed is closed and dropped — otherwise an edit (a new command,
    /// a corrected arg) would silently keep calling the old process. Servers
    /// whose config is unchanged keep their warm session, and removed servers
    /// are closed.
    public func configure(_ servers: [String: MCPServerConfig]) async {
        let stale = clients.keys.filter { configs[$0] != servers[$0] }
        for name in stale {
            await clients[name]?.close()
            clients.removeValue(forKey: name)
        }
        configs = servers
    }

    /// Configured server names, sorted.
    public func configuredNames() -> [String] {
        Array(configs.keys).sorted()
    }

    /// A connected session for `name`, spawning it and running the handshake on
    /// first use.
    ///
    /// A session that is no longer `.ready` is closed and replaced rather than
    /// resurrected: the framework keeps no respawn watchdog, so replacement on
    /// next use is the recovery path. A spawn that throws is not cached, so the
    /// call after it retries.
    public func client(named name: String) async throws -> MCPClient {
        guard let config = configs[name] else {
            throw MCPClientError.rpc(
                "unknown MCP server '\(name)' (configured: \(configuredNames().joined(separator: ", ")))"
            )
        }
        if let existing = clients[name] {
            if await existing.currentState() == .ready { return existing }
            await existing.close()
            clients[name] = nil
        }

        var configuration = MCPClient.ClientConfiguration()
        configuration.callTimeout = .seconds(config.timeout)
        configuration.negotiationTimeout = .seconds(config.connectTimeout)
        configuration.clientName = "arc-agent"
        configuration.clientVersion = ArcAgentCore.version

        let client = MCPClient(
            transport: SubprocessClientTransport(configuration: Self.spawn(name: name, config: config)),
            configuration: configuration
        )
        try await client.connect()
        clients[name] = client
        return client
    }

    /// The tools `name` exposes, as its `tools/list` catalog.
    public func tools(named name: String) async throws -> [RemoteToolDescriptor] {
        try await client(named: name).listTools()
    }

    /// Call a tool on `name` and return its text content.
    ///
    /// Arguments arrive as JSON: a `[String: Any]` cannot be forwarded into the
    /// client actor as a parameter under Swift 6 region isolation, so the
    /// decode happens in this scope.
    public func call(
        named name: String,
        tool: String,
        argumentsJSON: String = "{}"
    ) async throws -> String {
        let client = try await client(named: name)
        let arguments = try Self.decode(argumentsJSON)
        return Self.text(of: try await client.callTool(tool, arguments: arguments))
    }

    /// Close every session. Children also see stdin EOF, which is the
    /// framework's portable shutdown signal.
    public func shutdown() async {
        for (_, client) in clients { await client.close() }
        clients.removeAll()
    }

    // MARK: - Config → transport

    /// Projects an `MCPServerConfig` onto a spawn configuration.
    ///
    /// The child is spawned with **exactly** the sanitized environment
    /// (`inheritParentEnvironment: false`): a subprocess shares the host uid, so
    /// inheriting the parent environment would hand every agent credential to an
    /// external server.
    private static func spawn(
        name: String,
        config: MCPServerConfig
    ) -> SubprocessClientTransport.Configuration {
        var configuration = SubprocessClientTransport.Configuration(
            executable: config.command,
            arguments: config.args,
            environment: MCPServerConfig.sanitizedEnvironment(config.env),
            inheritParentEnvironment: false
        )
        configuration.callerIdentity = "arc:\(name)"
        return configuration
    }

    // MARK: - Result shaping

    private static func decode(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MCPClientError.rpc("arguments must be a JSON object, got: \(text)")
        }
        return object
    }

    private static func text(of result: MCPToolResult) -> String {
        let text = result.content.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined(separator: "\n")
        if text.isEmpty, result.isError { return "(tool returned an error)" }
        return text.isEmpty ? "(empty result)" : text
    }
}

/// Owns the configured MCP sessions for the process lifetime.
///
/// Sessions spawn lazily on first use; this service exists so the daemon's
/// `ServiceGroup` owns their teardown — closing a session is what gives a child
/// a clean stdin EOF instead of a signal. Cleanup lives in `run()` rather than a
/// caller's `defer`, per the Second Law.
public struct MCPClientsService: Service {

    private let manager: MCPClientManager

    public init(manager: MCPClientManager = .shared) {
        self.manager = manager
    }

    public func run() async throws {
        // Nothing to do until shutdown: sessions are created on demand.
        do {
            try await gracefulShutdown()
        } catch is CancellationError {
            // expected: cancelled directly rather than by group shutdown
        }
        await manager.shutdown()
    }
}