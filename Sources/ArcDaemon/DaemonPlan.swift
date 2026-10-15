import ArcAgentCore

/// The resolved long-lived surfaces a daemon run composes.
///
/// Pure data: ``resolve(config:overrides:)`` is a pure function over the loaded
/// daemon config plus the command-line overrides, so the composition matrix is
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
    public static func resolve(config: DaemonConfig, overrides: Overrides) -> DaemonPlan {
        var api: Surface?
        if config.api.enabled {
            api = Surface(
                host: overrides.host ?? config.api.host,
                port: overrides.port ?? config.api.port
            )
        }
        var webui: Surface?
        if overrides.webuiEnabled ?? config.webui.enabled {
            webui = Surface(host: config.webui.host, port: config.webui.port)
        }
        var mcpServer: Surface?
        if config.mcpServer.enabled {
            mcpServer = Surface(host: config.mcpServer.host, port: config.mcpServer.port)
        }
        var kanban: KanbanLoop?
        if config.kanban.dispatcherEnabled {
            kanban = KanbanLoop(pollSeconds: config.kanban.pollSeconds)
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

    /// Fill a command-line token into the daemon config that carries none —
    /// the `--telegram-token` flag used to be dropped whenever `daemon.json`
    /// existed at all (the config path shadowed the legacy flag path).
    public func configWithFilledToken(_ config: DaemonConfig) -> DaemonConfig {
        guard let token = telegramToken, !token.isEmpty, config.telegram.botToken.isEmpty else {
            return config
        }
        var config = config
        config.telegram.botToken = token
        config.telegram.enabled = true
        return config
    }
}