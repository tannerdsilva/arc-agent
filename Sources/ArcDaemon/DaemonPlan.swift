import ArcAgentCore

/// The resolved long-lived surfaces a daemon run composes.
///
/// Pure data: ``resolve(gateway:overrides:)`` is a pure function over the loaded
/// gateway config plus the command-line overrides, so the composition matrix is
/// unit-testable without binding a socket.
public struct DaemonPlan: Sendable, Equatable {

    /// A bound network surface (host + port).
    public struct Surface: Sendable, Equatable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    /// A background loop with no address of its own: present means enabled.
    public struct KanbanLoop: Sendable, Equatable {
        public var pollSeconds: Int

        public init(pollSeconds: Int) {
            self.pollSeconds = pollSeconds
        }
    }

    /// Command-line overrides; `nil` keeps the config file's value.
    public struct Overrides: Sendable {
        public var host: String?
        public var port: Int?
        public var telegramToken: String?
        /// `--webui` / `--no-webui` (tri-state: nil keeps the config's value).
        public var webuiEnabled: Bool?
        /// `--tessera-off`: skip the Tessera probe and use file storage.
        public var tesseraOff: Bool

        public init(
            host: String? = nil,
            port: Int? = nil,
            telegramToken: String? = nil,
            webuiEnabled: Bool? = nil,
            tesseraOff: Bool = false
        ) {
            self.host = host
            self.port = port
            self.telegramToken = telegramToken
            self.webuiEnabled = webuiEnabled
            self.tesseraOff = tesseraOff
        }
    }

    /// The REST API surface; `nil` when disabled by config.
    public var api: Surface?

    /// The Web UI surface; `nil` when disabled by config.
    public var webui: Surface?

    /// The MCP server surface; `nil` when disabled by config.
    public var mcpServer: Surface?

    /// The kanban dispatcher; `nil` when disabled by config.
    public var kanban: KanbanLoop?

    /// Skip the Tessera probe and use file storage for this process.
    public var tesseraOff: Bool

    /// A telegram bot token supplied on the command line; `nil` when absent.
    public var telegramToken: String?

    /// Resolve the plan: config first, command-line overrides on top. The
    /// surface set is the whole truth — a disabled surface is absent here and
    /// never composed.
    public static func resolve(gateway: GatewayConfig, overrides: Overrides) -> DaemonPlan {
        var api: Surface?
        if gateway.api.enabled {
            api = Surface(
                host: overrides.host ?? gateway.api.host,
                port: overrides.port ?? gateway.api.port
            )
        }
        var webui: Surface?
        if overrides.webuiEnabled ?? gateway.webui.enabled {
            webui = Surface(host: gateway.webui.host, port: gateway.webui.port)
        }
        var mcpServer: Surface?
        if gateway.mcpServer.enabled {
            mcpServer = Surface(host: gateway.mcpServer.host, port: gateway.mcpServer.port)
        }
        var kanban: KanbanLoop?
        if gateway.kanban.dispatcherEnabled {
            kanban = KanbanLoop(pollSeconds: gateway.kanban.pollSeconds)
        }
        return DaemonPlan(
            api: api,
            webui: webui,
            mcpServer: mcpServer,
            kanban: kanban,
            tesseraOff: overrides.tesseraOff,
            telegramToken: overrides.telegramToken
        )
    }

    /// Fill a command-line token into a gateway config that carries none — the
    /// `--telegram-token` flag used to be dropped whenever `gateway.json`
    /// existed at all (the config path shadowed the legacy flag path).
    public func gatewayWithFilledToken(_ gateway: GatewayConfig) -> GatewayConfig {
        guard let token = telegramToken, !token.isEmpty, gateway.telegram.botToken.isEmpty else {
            return gateway
        }
        var gateway = gateway
        gateway.telegram.botToken = token
        gateway.telegram.enabled = true
        return gateway
    }
}