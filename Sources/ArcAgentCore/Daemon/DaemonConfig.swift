import Foundation

/// The daemon's surface configuration (arc parity).
///
/// Loaded from `<home>/daemon.json` with environment-variable overrides
/// (reference convention: settings in the config file, secrets in env).
/// Example:
///
/// ```json
/// {
///   "telegram": {
///     "enabled": true,
///     "bot_token": "",
///     "allowed_users": "123,456",
///     "allow_all_users": false,
///     "home_channel": "123456",
///     "typing_indicator": true,
///     "reply_to_mode": "first",
///     "require_mention": false
///   },
///   "email": {
///     "enabled": true,
///     "address": "agent@example.com",
///     "password": "",
///     "imap_host": "imap.example.com",
///     "imap_port": 993,
///     "smtp_host": "smtp.example.com",
///     "smtp_port": 465,
///     "poll_interval_seconds": 60,
///     "allowed_users": ""
///   },
///   "slack": {
///     "enabled": true,
///     "bot_token": "",
///     "app_token": "",
///     "allowed_users": "",
///     "allow_all_users": false,
///     "home_channel": "",
///     "typing_indicator": false,
///     "reply_to_mode": "first",
///     "require_mention": true
///   }
/// }
/// ```
public struct DaemonConfig: Sendable {
    public var telegram: TelegramConfig
    public var email: EmailConfig
    public var slack: SlackConfig
    /// The daemon's REST API surface (`POST /v1/chat`, `GET /health`).
    public var api: APIConfig
    /// The daemon's Web UI surface (no-webui + ArcWebUI).
    public var webui: WebUIConfig

    /// The daemon's MCP server surface (swift-mcp, TCP).
    public var mcpServer: MCPServerSurfaceConfig
    /// The kanban dispatcher loop (core file board).
    public var kanban: KanbanConfig

    public init(
        telegram: TelegramConfig = TelegramConfig(),
        email: EmailConfig = EmailConfig(),
        slack: SlackConfig = SlackConfig(),
        api: APIConfig = APIConfig(),
        webui: WebUIConfig = WebUIConfig(),
        mcpServer: MCPServerSurfaceConfig = MCPServerSurfaceConfig(),
        kanban: KanbanConfig = KanbanConfig()
    ) {
        self.telegram = telegram
        self.email = email
        self.slack = slack
        self.api = api
        self.webui = webui
        self.mcpServer = mcpServer
        self.kanban = kanban
    }

    /// Load config from `<home>/daemon.json`, applying env overrides.
    ///
    /// - Parameters:
    ///   - home: The daemon home directory (defaults to `~/.arc`).
    ///   - environment: Process environment (injectable for tests).
    public static func load(
        home: URL = Self.defaultHome(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DaemonConfig {
        var config = DaemonConfig()
        let jsonURL = home.appendingPathComponent("daemon.json")
        if let data = try? Data(contentsOf: jsonURL),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            config.telegram = TelegramConfig(dict: root["telegram"] as? [String: Any], env: environment)
            config.email = EmailConfig(dict: root["email"] as? [String: Any], env: environment)
            config.slack = SlackConfig(dict: root["slack"] as? [String: Any], env: environment)
            config.api = APIConfig(dict: root["api"] as? [String: Any], env: environment)
            config.webui = WebUIConfig(dict: root["webui"] as? [String: Any], env: environment)
            config.mcpServer = MCPServerSurfaceConfig(dict: root["mcp_server"] as? [String: Any], env: environment)
            config.kanban = KanbanConfig(dict: root["kanban"] as? [String: Any], env: environment)
        } else {
            // No file: still honor env-only configuration.
            config.telegram = TelegramConfig(dict: nil, env: environment)
            config.email = EmailConfig(dict: nil, env: environment)
            config.slack = SlackConfig(dict: nil, env: environment)
            config.api = APIConfig(dict: nil, env: environment)
            config.webui = WebUIConfig(dict: nil, env: environment)
            config.mcpServer = MCPServerSurfaceConfig(dict: nil, env: environment)
            config.kanban = KanbanConfig(dict: nil, env: environment)
        }
        return config
    }

    // MARK: - Surface readiness

    /// True when the telegram block is enabled and carries a bot token —
    /// i.e. a ``TelegramAdapter`` will be constructed.
    public var telegramAdapterReady: Bool {
        telegram.enabled && !telegram.botToken.isEmpty
    }

    /// True when the email block is enabled and carries an address and
    /// password — i.e. an ``EmailAdapter`` will be constructed.
    public var emailAdapterReady: Bool {
        email.enabled && !email.address.isEmpty && !email.password.isEmpty
    }

    /// True when the slack block is enabled and carries both tokens — i.e.
    /// a ``SlackAdapter`` will be constructed.
    public var slackAdapterReady: Bool {
        slack.enabled && !slack.botToken.isEmpty && !slack.appToken.isEmpty
    }

    /// Any platform adapter ready to run. `ArcDaemon` composes the
    /// ``SessionHost`` when this or the API surface is enabled.
    public var anyPlatformAdapterReady: Bool {
        telegramAdapterReady || emailAdapterReady || slackAdapterReady
    }

    public static func defaultHome() -> URL {
        // One home for everything the daemon reads: `~/.arc` (or `$ARC_HOME`).
        // The web UI's `.arc-agent-webui` directory remains UI state only.
        ArcHome.root
    }
}

public struct TelegramConfig: Sendable {
    public var enabled: Bool
    public var botToken: String
    public var allowedUsers: Set<String>
    public var allowAllUsers: Bool
    public var homeChannel: String?
    public var typingIndicator: Bool
    public var replyToMode: String
    public var requireMention: Bool
    public var pollIntervalSeconds: Int

    public init(
        enabled: Bool = false,
        botToken: String = "",
        allowedUsers: Set<String> = [],
        allowAllUsers: Bool = false,
        homeChannel: String? = nil,
        typingIndicator: Bool = true,
        replyToMode: String = "first",
        requireMention: Bool = false,
        pollIntervalSeconds: Int = 1
    ) {
        self.enabled = enabled
        self.botToken = botToken
        self.allowedUsers = allowedUsers
        self.allowAllUsers = allowAllUsers
        self.homeChannel = homeChannel
        self.typingIndicator = typingIndicator
        self.replyToMode = replyToMode
        self.requireMention = requireMention
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    init(dict: [String: Any]?, env: [String: String]) {
        let d = dict ?? [:]
        // Env always wins over the JSON file (reference convention).
        self.botToken = env["TELEGRAM_BOT_TOKEN"]
            ?? (d["bot_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ""
        self.enabled = (d["enabled"] as? Bool ?? false) || !self.botToken.isEmpty
        self.allowedUsers = AuthzPolicy.parseIds(env["TELEGRAM_ALLOWED_USERS"] ?? (d["allowed_users"] as? String))
        self.allowAllUsers = Self.truthy(env["TELEGRAM_ALLOW_ALL_USERS"] ?? d["allow_all_users"])
        self.homeChannel = env["TELEGRAM_HOME_CHANNEL"] ?? (d["home_channel"] as? String)
        self.typingIndicator = d["typing_indicator"] as? Bool ?? true
        self.replyToMode = d["reply_to_mode"] as? String ?? "first"
        self.requireMention = Self.truthy(d["require_mention"])
        self.pollIntervalSeconds = d["poll_interval_seconds"] as? Int ?? 1
    }

    private static func truthy(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let s as String where !s.isEmpty:
            return ["1", "true", "yes", "on"].contains(s.lowercased())
        default: return false
        }
    }
}

public struct EmailConfig: Sendable {
    public var enabled: Bool
    public var address: String
    public var password: String
    public var imapHost: String
    public var imapPort: Int
    public var imapUseTLS: Bool
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpUseTLS: Bool
    public var allowedUsers: Set<String>
    public var allowAllUsers: Bool
    public var pollIntervalSeconds: Int

    public init(
        enabled: Bool = false,
        address: String = "",
        password: String = "",
        imapHost: String = "",
        imapPort: Int = 993,
        imapUseTLS: Bool = true,
        smtpHost: String = "",
        smtpPort: Int = 465,
        smtpUseTLS: Bool = true,
        allowedUsers: Set<String> = [],
        allowAllUsers: Bool = false,
        pollIntervalSeconds: Int = 60
    ) {
        self.enabled = enabled
        self.address = address
        self.password = password
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUseTLS = imapUseTLS
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUseTLS = smtpUseTLS
        self.allowedUsers = allowedUsers
        self.allowAllUsers = allowAllUsers
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    init(dict: [String: Any]?, env: [String: String]) {
        let d = dict ?? [:]
        // Env always wins over the JSON file (reference convention).
        self.address = env["EMAIL_ADDRESS"] ?? (d["address"] as? String) ?? ""
        self.password = env["EMAIL_PASSWORD"] ?? (d["password"] as? String) ?? ""
        self.imapHost = env["EMAIL_IMAP_HOST"] ?? (d["imap_host"] as? String) ?? ""
        self.imapPort = Int(env["EMAIL_IMAP_PORT"] ?? "") ?? (d["imap_port"] as? Int) ?? 993
        self.imapUseTLS = d["imap_use_tls"] as? Bool ?? true
        self.smtpHost = env["EMAIL_SMTP_HOST"] ?? (d["smtp_host"] as? String) ?? ""
        self.smtpPort = Int(env["EMAIL_SMTP_PORT"] ?? "") ?? (d["smtp_port"] as? Int) ?? 465
        self.smtpUseTLS = d["smtp_use_tls"] as? Bool ?? true
        self.allowedUsers = AuthzPolicy.parseIds(env["EMAIL_ALLOWED_USERS"] ?? (d["allowed_users"] as? String))
        self.allowAllUsers = Self.truthy(env["EMAIL_ALLOW_ALL_USERS"] ?? d["allow_all_users"])
        self.enabled = (d["enabled"] as? Bool ?? false) || (!self.address.isEmpty && !self.password.isEmpty)
        self.pollIntervalSeconds = d["poll_interval_seconds"] as? Int ?? 60
    }
    private static func truthy(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let s as String where !s.isEmpty:
            return ["1", "true", "yes", "on"].contains(s.lowercased())
        default: return false
        }
    }
}

public struct SlackConfig: Sendable {
    public var enabled: Bool
    public var botToken: String
    public var appToken: String
    public var allowedUsers: Set<String>
    public var allowAllUsers: Bool
    public var homeChannel: String?
    public var typingIndicator: Bool
    public var replyToMode: String
    public var requireMention: Bool

    public init(
        enabled: Bool = false,
        botToken: String = "",
        appToken: String = "",
        allowedUsers: Set<String> = [],
        allowAllUsers: Bool = false,
        homeChannel: String? = nil,
        typingIndicator: Bool = false,
        replyToMode: String = "first",
        requireMention: Bool = true
    ) {
        self.enabled = enabled
        self.botToken = botToken
        self.appToken = appToken
        self.allowedUsers = allowedUsers
        self.allowAllUsers = allowAllUsers
        self.homeChannel = homeChannel
        self.typingIndicator = typingIndicator
        self.replyToMode = replyToMode
        self.requireMention = requireMention
    }

    init(dict: [String: Any]?, env: [String: String]) {
        let d = dict ?? [:]
        // Env always wins over the JSON file (reference convention).
        self.botToken = env["SLACK_BOT_TOKEN"]
            ?? (d["bot_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ""
        self.appToken = env["SLACK_APP_TOKEN"]
            ?? (d["app_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ""
        self.enabled = (d["enabled"] as? Bool ?? false)
            || (!self.botToken.isEmpty && !self.appToken.isEmpty)
        self.allowedUsers = AuthzPolicy.parseIds(env["SLACK_ALLOWED_USERS"] ?? (d["allowed_users"] as? String))
        self.allowAllUsers = Self.truthy(env["SLACK_ALLOW_ALL_USERS"] ?? d["allow_all_users"])
        self.homeChannel = env["SLACK_HOME_CHANNEL"] ?? (d["home_channel"] as? String)
        self.typingIndicator = d["typing_indicator"] as? Bool ?? false
        self.replyToMode = d["reply_to_mode"] as? String ?? "first"
        self.requireMention = d["require_mention"] as? Bool ?? true
    }
    private static func truthy(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let s as String where !s.isEmpty:
            return ["1", "true", "yes", "on"].contains(s.lowercased())
        default: return false
        }
    }
}

/// The daemon's REST API surface (`POST /v1/chat`, `GET /health`).
///
/// Config lives in `daemon.json` under the `api` key; environment overrides:
/// `API_ENABLED`, `API_HOST`, `API_PORT`. The surface is enabled by default and
/// binds loopback; disabling it removes the HTTP service from the daemon's tree
/// entirely (nothing is listened on).
public struct APIConfig: Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool = true, host: String = "127.0.0.1", port: Int = 8080) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    init(dict: [String: Any]?, env: [String: String]) {
        let d = dict ?? [:]
        // env always wins over the JSON file (reference convention).
        self.host = env["API_HOST"] ?? (d["host"] as? String) ?? "127.0.0.1"
        self.port = Int(env["API_PORT"] ?? "") ?? (d["port"] as? Int) ?? 8080
        if let raw = env["API_ENABLED"] {
            self.enabled = Self.truthy(raw)
        } else {
            self.enabled = d["enabled"] as? Bool ?? true
        }
    }

    private static func truthy(_ v: String) -> Bool {
        ["1", "true", "yes", "on"].contains(v.lowercased())
    }
}

/// The daemon's Web UI surface (no-webui's `WebUIServer` + `ArcWebUI`).
///
/// Config lives in `daemon.json` under the `webui` key; environment overrides:
/// `WEBUI_ENABLED`, `WEBUI_HOST`, `WEBUI_PORT`, and `--webui/--no-webui` on
/// `arc serve` overrides both. Enabled by default on loopback:8890 — the
/// daemon is the only UI host (the standalone `arc-agent-webui` binary was
/// retired in the daemon consolidation).
public struct WebUIConfig: Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool = true, host: String = "127.0.0.1", port: Int = 8890) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    init(dict: [String: Any]?, env: [String: String]) {
        let d = dict ?? [:]
        // env always wins over the JSON file (reference convention).
        self.host = env["WEBUI_HOST"] ?? (d["host"] as? String) ?? "127.0.0.1"
        self.port = Int(env["WEBUI_PORT"] ?? "") ?? (d["port"] as? Int) ?? 8890
        if let raw = env["WEBUI_ENABLED"] {
            self.enabled = Self.truthy(raw)
        } else {
            self.enabled = d["enabled"] as? Bool ?? true
        }
    }

    private static func truthy(_ v: String) -> Bool {
        ["1", "true", "yes", "on"].contains(v.lowercased())
    }
}

/// The daemon's MCP server surface (swift-mcp over TCP).
///
/// Config: `daemon.json` → `mcp_server {enabled, host, port}`; env
/// `MCP_SERVER_ENABLED/HOST/PORT`. **Disabled by default.** When enabled it
/// exposes every **built-in** tool (the `CompileTimeToolRegistry` — plugin
/// tools are not exposed) to any MCP client that can reach the bind address.
/// There is **no auth**: the bind host is the security boundary, so leave it
/// on loopback unless you mean it. stdio transport is meaningless in a daemon;
/// TCP only.
public struct MCPServerSurfaceConfig: Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool = false, host: String = "127.0.0.1", port: Int = 8081) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    init(dict: [String: Any]?, env: [String: String]) {
        let d = dict ?? [:]
        // env always wins over the JSON file (reference convention).
        self.host = env["MCP_SERVER_HOST"] ?? (d["host"] as? String) ?? "127.0.0.1"
        self.port = Int(env["MCP_SERVER_PORT"] ?? "") ?? (d["port"] as? Int) ?? 8081
        if let raw = env["MCP_SERVER_ENABLED"] {
            self.enabled = Self.truthy(raw)
        } else {
            self.enabled = d["enabled"] as? Bool ?? false
        }
    }

    private static func truthy(_ v: String) -> Bool {
        ["1", "true", "yes", "on"].contains(v.lowercased())
    }
}

/// The kanban dispatcher loop.
///
/// Config: `daemon.json` → `kanban {dispatcher_enabled, poll_seconds}`; env
/// `KANBAN_DISPATCHER_ENABLED`, `KANBAN_POLL_SECONDS`. **Disabled by default,
/// and here is why you should leave it that way until it grows up:**
/// `KanbanDispatcher.run()` is a stub — it marks every `ready` task `running`,
/// sleeps one second, marks it `done`, and never runs anything. It also polls
/// the **core** board (`~/.arc/kanban/`, `FileKanbanBoard`), not the web UI's
/// kanban panel (which lives in `~/.arc-agent-webui/settings.json`) — the two
/// are separate stores today. Enabling the gate is for exercising the dispatch
/// loop only; it mutates the core board.
public struct KanbanConfig: Sendable {
    public var dispatcherEnabled: Bool
    public var pollSeconds: Int

    public init(dispatcherEnabled: Bool = false, pollSeconds: Int = 5) {
        self.dispatcherEnabled = dispatcherEnabled
        self.pollSeconds = pollSeconds
    }

    init(dict: [String: Any]?, env: [String: String]) {
        let d = dict ?? [:]
        // env always wins over the JSON file (reference convention).
        self.pollSeconds = Int(env["KANBAN_POLL_SECONDS"] ?? "")
            ?? (d["poll_seconds"] as? Int)
            ?? 5
        if let raw = env["KANBAN_DISPATCHER_ENABLED"] {
            self.dispatcherEnabled = Self.truthy(raw)
        } else {
            self.dispatcherEnabled = d["dispatcher_enabled"] as? Bool ?? false
        }
    }

    private static func truthy(_ v: String) -> Bool {
        ["1", "true", "yes", "on"].contains(v.lowercased())
    }
}
