import Foundation
import Logging

/// The top-level configuration for ARC Agent.
///
/// Config is resolved in order of priority:
/// 1. CLI flags (highest)
/// 2. Environment variables
/// 3. `config.json` on disk
/// 4. Compiled-in defaults (lowest)
///
/// ## File Layout
/// ```
/// ~/.arc/
/// ├── config.json       # All non-secret settings
/// └── .env              # Secrets only (API keys, tokens)
/// ```
///
/// ## Design
///
/// This is a concrete `Codable` struct — no protocol needed. The config
/// format is stable and has no polymorphic behavior to abstract.
///
/// ## Partial Configs
///
/// Every section and field decodes **optionally against its default**, so a
/// config file that omits sections (e.g. only `model`/`agent`/`security`)
/// merges over the compiled-in defaults instead of failing to decode. This
/// matters because `saveConfig` writes the full shape, but hand-edited or
/// older config files often contain only a subset — and a decode failure
/// here would silently discard the *entire* file.
public struct ArcConfig: Codable, Sendable, Equatable {

    // MARK: - Model

    /// Model and provider configuration.
    public var model: ModelConfig

    /// Agent behavior configuration.
    public var agent: AgentConfig

    /// Terminal tool configuration.
    public var terminal: TerminalConfig

    /// Delegation system configuration.
    public var delegation: DelegationConfig

    /// Memory system configuration.
    public var memory: MemoryConfig

    /// Security/approval configuration.
    public var security: SecurityConfig

    /// Tessera storage configuration. When set, sessions, memory, and the
    /// profile index are persisted as signed NOSTR events to a Tessera
    /// server instead of local files.
    public var tessera: TesseraConfig?

    /// Hermes-parity auxiliary-model overrides (`auxiliary.<task>`), routing
    /// secondary tasks (vision, web extract, compression, approval, titles, …)
    /// to dedicated model configurations. Tasks without an override use the
    /// main model.
    public var auxiliary: AuxiliaryModelSet

    // MARK: - Init

    public init(
        model: ModelConfig = ModelConfig(),
        agent: AgentConfig = AgentConfig(),
        terminal: TerminalConfig = TerminalConfig(),
        delegation: DelegationConfig = DelegationConfig(),
        memory: MemoryConfig = MemoryConfig(),
        security: SecurityConfig = SecurityConfig(),
        tessera: TesseraConfig? = nil,
        auxiliary: AuxiliaryModelSet = AuxiliaryModelSet()
    ) {
        self.model = model
        self.agent = agent
        self.terminal = terminal
        self.delegation = delegation
        self.memory = memory
        self.security = security
        self.tessera = tessera
        self.auxiliary = auxiliary
    }

    /// Decode each section independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(ModelConfig.self, forKey: .model) ?? ModelConfig()
        self.agent = try container.decodeIfPresent(AgentConfig.self, forKey: .agent) ?? AgentConfig()
        self.terminal = try container.decodeIfPresent(TerminalConfig.self, forKey: .terminal) ?? TerminalConfig()
        self.delegation = try container.decodeIfPresent(DelegationConfig.self, forKey: .delegation) ?? DelegationConfig()
        self.memory = try container.decodeIfPresent(MemoryConfig.self, forKey: .memory) ?? MemoryConfig()
        self.security = try container.decodeIfPresent(SecurityConfig.self, forKey: .security) ?? SecurityConfig()
        self.tessera = try container.decodeIfPresent(TesseraConfig.self, forKey: .tessera)
        self.auxiliary = try container.decodeIfPresent(AuxiliaryModelSet.self, forKey: .auxiliary) ?? AuxiliaryModelSet()
    }
}

// MARK: - Sub-Configs

/// Model and provider configuration.
public struct ModelConfig: Codable, Sendable, Equatable {
    /// Default model to use.
    public var defaultModel: String
    /// Default provider name.
    public var provider: String
    /// Base URL override.
    public var baseURL: String?
    /// Context length for the default model.
    public var contextLength: Int?

    public init(
        defaultModel: String = "gpt-4o",
        provider: String = "openai",
        baseURL: String? = nil,
        contextLength: Int? = nil
    ) {
        self.defaultModel = defaultModel
        self.provider = provider
        self.baseURL = baseURL
        self.contextLength = contextLength
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ModelConfig().defaultModel
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ModelConfig().provider
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
    }
}

/// Agent behavior configuration.
public struct AgentConfig: Codable, Sendable, Equatable {
    /// Maximum iterations per conversation.
    public var maxIterations: Int
    /// Whether to persist sessions.
    public var persistSessions: Bool
    /// Whether to load skills on startup.
    public var loadSkills: Bool

    public init(
        maxIterations: Int = 25,
        persistSessions: Bool = true,
        loadSkills: Bool = true
    ) {
        self.maxIterations = maxIterations
        self.persistSessions = persistSessions
        self.loadSkills = loadSkills
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? AgentConfig().maxIterations
        self.persistSessions = try container.decodeIfPresent(Bool.self, forKey: .persistSessions) ?? AgentConfig().persistSessions
        self.loadSkills = try container.decodeIfPresent(Bool.self, forKey: .loadSkills) ?? AgentConfig().loadSkills
    }
}

/// Terminal tool configuration.
public struct TerminalConfig: Codable, Sendable, Equatable {
    /// Default timeout in seconds.
    public var defaultTimeout: Int
    /// Whether to allow background processes.
    public var allowBackground: Bool

    public init(defaultTimeout: Int = 180, allowBackground: Bool = true) {
        self.defaultTimeout = defaultTimeout
        self.allowBackground = allowBackground
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultTimeout = try container.decodeIfPresent(Int.self, forKey: .defaultTimeout) ?? TerminalConfig().defaultTimeout
        self.allowBackground = try container.decodeIfPresent(Bool.self, forKey: .allowBackground) ?? TerminalConfig().allowBackground
    }
}

/// Delegation system configuration.
public struct DelegationConfig: Codable, Sendable, Equatable {
    /// Maximum concurrent child agents.
    public var maxConcurrentChildren: Int
    /// Maximum spawn depth.
    public var maxSpawnDepth: Int

    public init(maxConcurrentChildren: Int = 12, maxSpawnDepth: Int = 3) {
        self.maxConcurrentChildren = maxConcurrentChildren
        self.maxSpawnDepth = maxSpawnDepth
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxConcurrentChildren = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentChildren) ?? DelegationConfig().maxConcurrentChildren
        self.maxSpawnDepth = try container.decodeIfPresent(Int.self, forKey: .maxSpawnDepth) ?? DelegationConfig().maxSpawnDepth
    }
}

/// Memory system configuration.
public struct MemoryConfig: Codable, Sendable, Equatable {
    /// Whether memory is enabled.
    public var enabled: Bool
    /// Maximum memory size in characters.
    public var maxSize: Int

    public init(enabled: Bool = true, maxSize: Int = 2200) {
        self.enabled = enabled
        self.maxSize = maxSize
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? MemoryConfig().enabled
        self.maxSize = try container.decodeIfPresent(Int.self, forKey: .maxSize) ?? MemoryConfig().maxSize
    }
}

/// Security/approval configuration.
public struct SecurityConfig: Codable, Sendable, Equatable {
    /// The approval mode.
    public var approvalMode: String
    /// Whether YOLO mode is enabled (frozen at start).
    public var yoloMode: Bool

    public init(approvalMode: String = "manual", yoloMode: Bool = false) {
        self.approvalMode = approvalMode
        self.yoloMode = yoloMode
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.approvalMode = try container.decodeIfPresent(String.self, forKey: .approvalMode) ?? SecurityConfig().approvalMode
        self.yoloMode = try container.decodeIfPresent(Bool.self, forKey: .yoloMode) ?? SecurityConfig().yoloMode
    }
}

// MARK: - Loading

/// Errors that can occur during config loading.
public enum ConfigError: Error, Sendable, CustomStringConvertible {
    case notFound(String)
    case parseError(String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "Config file not found: \(path)"
        case .parseError(let message): return "Failed to parse config: \(message)"
        case .invalidValue(let message): return "Invalid config value: \(message)"
        }
    }
}

/// Load configuration from disk, merging with environment variables.
///
/// Resolution order:
/// 1. Start with compiled-in defaults
/// 2. Overlay values from `configURL` (if it exists)
/// 3. Overlay values from environment variables
///
/// - Parameter configURL: The config file URL. Defaults to `~/.arc/config.json`.
/// - Returns: The resolved configuration.
public func loadConfig(from configURL: URL? = nil) -> ArcConfig {
    var config = ArcConfig()

    // Determine the config file URL
    let resolvedURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/config.json")

    if FileManager.default.fileExists(atPath: resolvedURL.path) {
        do {
            let data = try Data(contentsOf: resolvedURL)
            let decoded = try JSONDecoder().decode(ArcConfig.self, from: data)
            config = decoded
        } catch {
            // Fall back to defaults on parse error. This must be visible:
            // a silent discard here means the user's model/provider/baseURL
            // choices are ignored and the agent dials a default endpoint
            // with no key — a 401 on every turn with no clue why.
            Logger(label: "com.arc-agent.config").error(
                "Failed to parse \(resolvedURL.path); using default configuration: \(error)"
            )
        }
    }

    // Environment variable overrides
    if let model = ProcessInfo.processInfo.environment["ARC_MODEL"] {
        config.model.defaultModel = model
    }
    if let provider = ProcessInfo.processInfo.environment["ARC_PROVIDER"] {
        config.model.provider = provider
    }
    if let baseURL = ProcessInfo.processInfo.environment["ARC_BASE_URL"] {
        config.model.baseURL = baseURL
    }
    if let approvalMode = ProcessInfo.processInfo.environment["ARC_APPROVAL_MODE"] {
        config.security.approvalMode = approvalMode
    }
    if ProcessInfo.processInfo.environment["ARC_YOLO"] != nil {
        config.security.yoloMode = true
    }

    // Tessera storage overrides. Any ARC_TESSERA_* variable activates the
    // tessera backend; unset fields keep whatever config.json declared.
    let tesseraIP = ProcessInfo.processInfo.environment["ARC_TESSERA_SERVER_IP"]
    let tesseraPort = ProcessInfo.processInfo.environment["ARC_TESSERA_SERVER_PORT"]
    let tesseraServerPub = ProcessInfo.processInfo.environment["ARC_TESSERA_SERVER_PUBLIC_KEY"]
    let tesseraClientPriv = ProcessInfo.processInfo.environment["ARC_TESSERA_PRIVATE_KEY"]
    if tesseraIP != nil || tesseraPort != nil || tesseraServerPub != nil || tesseraClientPriv != nil {
        var t = config.tessera ?? TesseraConfig(
            serverIP: "127.0.0.1", serverPort: 51820,
            serverPublicKey: "", myPrivateKey: "", application: 1
        )
        if let tesseraIP { t.serverIP = tesseraIP }
        if let tesseraPort, let p = Int(tesseraPort) { t.serverPort = p }
        if let tesseraServerPub { t.serverPublicKey = tesseraServerPub }
        if let tesseraClientPriv { t.myPrivateKey = tesseraClientPriv }
        if let app = ProcessInfo.processInfo.environment["ARC_TESSERA_APPLICATION"], let a = UInt16(app) {
            t.application = a
        }
        config.tessera = t
    }

    return config
}

/// Save configuration to disk.
///
/// - Parameters:
///   - config: The configuration to save.
///   - configURL: The config file URL. Defaults to `~/.arc/config.json`.
/// - Throws: If the file cannot be written.
public func saveConfig(_ config: ArcConfig, to configURL: URL? = nil) throws {
    let resolvedURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/config.json")
    let configDir = resolvedURL.deletingLastPathComponent()

    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(config)
    try data.write(to: resolvedURL, options: .atomic)
}
