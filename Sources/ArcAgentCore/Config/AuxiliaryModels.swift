import AsyncHTTPClient
import Foundation

/// Hermes-parity auxiliary tasks: secondary agent duties that can be routed
/// to a dedicated model configuration (Hermes `auxiliary.<task>` block).
///
/// Task keys match Hermes exactly (`auxiliary.title_generation`, …) so the
/// same `~/.arc/config.json` drives both agents. Legacy arc-agent names
/// (`title_gen`, `triage`) are accepted on decode.
public enum AuxiliaryTask: String, Codable, CaseIterable, Sendable, Identifiable, Equatable {
    case vision
    case compression
    case webExtract = "web_extract"
    case approval
    case mcp
    case titleGeneration = "title_generation"
    case memoryQueryRewrite = "memory_query_rewrite"
    case ttsAudioTags = "tts_audio_tags"
    case skillsHub = "skills_hub"
    case triageSpecifier = "triage_specifier"
    case kanbanDecomposer = "kanban_decomposer"
    case profileDescriber = "profile_describer"
    case curator

    public var id: String { rawValue }

    /// Canonical config key (`auxiliary.<key>`), mirroring Hermes naming.
    public var key: String { rawValue }

    /// Tolerant lookup: legacy arc-agent keys (`title_gen`, `triage`) map to
    /// their Hermes-canonical counterparts so old configs keep working.
    public init?(configKey key: String) {
        switch key {
        case "title_gen": self = .titleGeneration
        case "triage": self = .triageSpecifier
        default: self.init(rawValue: key)
        }
    }

    /// Human-readable label for UIs (Hermes display names).
    public var displayName: String {
        switch self {
        case .vision: return "Vision"
        case .compression: return "Compression"
        case .webExtract: return "Web extract"
        case .approval: return "Approval"
        case .mcp: return "MCP"
        case .titleGeneration: return "Title generation"
        case .memoryQueryRewrite: return "Memory query rewrite"
        case .ttsAudioTags: return "TTS audio tags"
        case .skillsHub: return "Skills hub"
        case .triageSpecifier: return "Triage specifier"
        case .kanbanDecomposer: return "Kanban decomposer"
        case .profileDescriber: return "Profile describer"
        case .curator: return "Curator"
        }
    }

    /// One-line description of the task (Hermes descriptions).
    public var detail: String {
        switch self {
        case .vision: return "Image and screenshot analysis"
        case .compression: return "Context summarization"
        case .webExtract: return "Web page summarization"
        case .approval: return "Smart command approval"
        case .mcp: return "MCP tool reasoning"
        case .titleGeneration: return "Session titles"
        case .memoryQueryRewrite: return "Memory retrieval queries"
        case .ttsAudioTags: return "Gemini TTS tag insertion"
        case .skillsHub: return "Skills search and install"
        case .triageSpecifier: return "Issue and task triage specs"
        case .kanbanDecomposer: return "Task decomposition"
        case .profileDescriber: return "Profile summaries"
        case .curator: return "Skill-usage review pass"
        }
    }
}

/// An optional per-task model override (value of `auxiliary.<task>`).
///
/// Fields match Hermes (`provider`, `model`, `base_url`, `api_key`). Empty
/// fields mean "inherit the main model configuration"; a task with no override
/// at all resolves to the main model. A `provider` of `"auto"` (Hermes
/// default) also means inherit the main provider.
public struct AuxiliaryOverride: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var baseURL: String
    public var apiKey: String

    public init(
        provider: String = "",
        model: String = "",
        baseURL: String = "",
        apiKey: String = ""
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// True when at least one field is set, i.e. this override would route
    /// the task away from the main model.
    public var isSet: Bool {
        !provider.isEmpty || !model.isEmpty || !baseURL.isEmpty || !apiKey.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model
        case baseURL = "base_url"
        case apiKey = "api_key"
    }

    /// Tolerant decode: any absent field defaults to "" (inherit main), and
    /// the legacy camelCase spellings (`baseURL`/`apiKey`) are accepted too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FlexibleCodingKey.self)
        func take(_ keys: String...) -> String {
            for k in keys {
                if let v = try? c.decodeIfPresent(String.self, forKey: FlexibleCodingKey(k)),
                   !v.isEmpty { return v }
            }
            return ""
        }
        self.provider = take("provider")
        self.model = take("model")
        self.baseURL = take("base_url", "baseURL")
        self.apiKey = take("api_key", "apiKey")
    }
}

/// The concrete resolved endpoint for an auxiliary task after merging an
/// override with the main model configuration.
public struct AuxResolvedModel: Equatable, Sendable {
    public let model: String
    public let provider: String
    public let baseURL: String?
    public let apiKey: String

    public init(model: String, provider: String, baseURL: String?, apiKey: String) {
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

/// The full auxiliary-model block: task → override, with a tolerant decoder
/// so config files that only carry some tasks never fail wholesale.
public struct AuxiliaryModelSet: Codable, Equatable, Sendable {
    public var byTask: [AuxiliaryTask: AuxiliaryOverride]

    public init(byTask: [AuxiliaryTask: AuxiliaryOverride] = [:]) {
        self.byTask = byTask
    }

    public func override(for task: AuxiliaryTask) -> AuxiliaryOverride? {
        byTask[task]
    }

    /// Merge over the main model config: override fields win when non-empty,
    /// everything else inherits from the main model (Hermes behavior). A
    /// provider of `"auto"` is treated like "inherit the main provider".
    public func resolved(for task: AuxiliaryTask, over main: ModelConfig, apiKey: String = "") -> AuxResolvedModel {
        let o = byTask[task]
        let model = (o?.model.isEmpty == false ? o!.model : nil) ?? main.defaultModel
        let ov = o?.provider ?? ""
        let provider = (ov.isEmpty || ov == "auto" ? main.provider : ov)
        let baseURL = (o?.baseURL.isEmpty == false ? o!.baseURL : nil) ?? main.baseURL
        let key = (o?.apiKey.isEmpty == false ? o!.apiKey : nil) ?? apiKey
        return AuxResolvedModel(model: model, provider: provider, baseURL: baseURL, apiKey: key)
    }

    /// Tolerant decode: missing block/tasks/fields all fall back to defaults.
    /// The block is a flat map of task-key → override (Hermes shape), e.g.
    /// `{"vision": {"model": "…"}, "title_generation": {"provider": "…"}}`.
    /// Legacy keys (`title_gen`, `triage`) are mapped to their canonical task.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        var map: [AuxiliaryTask: AuxiliaryOverride] = [:]
        for key in container.allKeys {
            if let task = AuxiliaryTask(configKey: key.stringValue),
               let ov = try? container.decode(AuxiliaryOverride.self, forKey: key) {
                map[task] = ov
            }
        }
        self.byTask = map
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlexibleCodingKey.self)
        for (task, override) in byTask {
            try container.encode(override, forKey: FlexibleCodingKey(task.key))
        }
    }
}

/// Resolves and builds LLM clients for auxiliary tasks, mirroring Hermes
/// `auxiliary.<task>` routing. Consumers ask for a task; if an override is
/// configured the client targets the override endpoint, otherwise the client
/// targets the main model endpoint.
public struct AuxiliaryModelRouter: Sendable {
    public let set: AuxiliaryModelSet
    /// The main model config the aux endpoints inherit from.
    public let main: ModelConfig
    /// The main model's API key (used when an override has no key of its own).
    public let mainAPIKey: String

    public init(set: AuxiliaryModelSet, main: ModelConfig, mainAPIKey: String) {
        self.set = set
        self.main = main
        self.mainAPIKey = mainAPIKey
    }

    /// True when the task carries an explicit override (any field set).
    public func hasOverride(_ task: AuxiliaryTask) -> Bool {
        set.override(for: task)?.isSet == true
    }

    /// The resolved endpoint parameters for a task.
    public func resolved(_ task: AuxiliaryTask) -> AuxResolvedModel {
        set.resolved(for: task, over: main, apiKey: mainAPIKey)
    }

    /// Build a client for an auxiliary task. When the task has no override the
    /// returned client points at the main model endpoint; returns nil only if
    /// no usable base URL can be formed.
    public func makeClient(task: AuxiliaryTask, httpClient: HTTPClient) -> OpenAICompatibleClient? {
        let r = resolved(task)
        let base = r.baseURL.isEmptyOrNil ? "https://api.openai.com/v1" : r.baseURL!
        guard let url = URL(string: base) else { return nil }
        return OpenAICompatibleClient(
            baseURL: url,
            apiKey: r.apiKey,
            model: r.model,
            httpClient: httpClient
        )
    }
}

extension Optional where Wrapped == String {
    fileprivate var isEmptyOrNil: Bool {
        switch self {
        case .none: return true
        case .some(let s): return s.isEmpty
        }
    }
}

/// A catch-all `CodingKey` allowing the auxiliary block's keys to be the
/// arbitrary task names (vision, web_extract, title_generation, …).
struct FlexibleCodingKey: CodingKey, Equatable, Sendable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
