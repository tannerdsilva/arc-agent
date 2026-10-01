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

    /// Command-line overrides; `nil` keeps the config file's value.
    public struct Overrides: Sendable {
        public var host: String?
        public var port: Int?
        public var telegramToken: String?

        public init(host: String? = nil, port: Int? = nil, telegramToken: String? = nil) {
            self.host = host
            self.port = port
            self.telegramToken = telegramToken
        }
    }

    /// The REST API surface; `nil` when disabled by config.
    public var api: Surface?

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
        return DaemonPlan(api: api, telegramToken: overrides.telegramToken)
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