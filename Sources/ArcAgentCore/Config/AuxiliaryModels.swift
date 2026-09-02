import Foundation

/// Hermes-parity auxiliary tasks: secondary agent duties that can be routed
/// to a dedicated model configuration (Hermes `auxiliary.<task>` block).
///
/// Each task names a distinct subsystem so the same harness can keep a cheap
/// default model for the main loop and send heavier or specialized work
/// (vision, extraction, approval, titles, …) to a purpose-picked model.
public enum AuxiliaryTask: String, Codable, CaseIterable, Sendable, Identifiable, Equatable {
    case vision
    case webExtract = "web_extract"
    case compression
    case approval
    case mcp
    case titleGeneration = "title_gen"
    case skillsHub = "skills_hub"
    case curator
    case kanbanDecomposer = "kanban_decomposer"
    case profileDescriber = "profile_describer"
    case triage

    public var id: String { rawValue }

    /// Canonical config key (`auxiliary.<key>`), mirroring Hermes naming.
    public var key: String { rawValue }

    /// Human-readable label for UIs.
    public var displayName: String {
        switch self {
        case .vision: return "Vision"
        case .webExtract: return "Web extract"
        case .compression: return "Compression"
        case .approval: return "Approval"
        case .mcp: return "MCP"
        case .titleGeneration: return "Title generation"
        case .skillsHub: return "Skills hub"
        case .curator: return "Curator"
        case .kanbanDecomposer: return "Kanban decomposer"
        case .profileDescriber: return "Profile describer"
        case .triage: return "Triage specifier"
        }
    }

    /// One-line description of the task.
    public var detail: String {
        switch self {
        case .vision: return "Image and screenshot analysis"
        case .webExtract: return "Web page summarization"
        case .compression: return "Context summarization"
        case .approval: return "Smart command approval"
        case .mcp: return "MCP tool reasoning"
        case .titleGeneration: return "Session titles"
        case .skillsHub: return "Skills search and install"
        case .curator: return "Skill-usage review pass"
        case .kanbanDecomposer: return "Task decomposition"
        case .profileDescriber: return "Profile summaries"
        case .triage: return "Issue and task triage specs"
        }
    }
}

/// An optional per-task model override (value of `auxiliary.<task>`).
///
/// Empty fields mean "inherit the main model configuration"; a task with no
/// override at all resolves to the main model.
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

    /// Tolerant decode: any absent field defaults to "" (inherit main).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
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
    /// everything else inherits from the main model (Hermes behavior).
    public func resolved(for task: AuxiliaryTask, over main: ModelConfig, apiKey: String = "") -> AuxResolvedModel {
        let o = byTask[task]
        let model = (o?.model.isEmpty == false ? o!.model : nil) ?? main.defaultModel
        let provider = (o?.provider.isEmpty == false ? o!.provider : nil) ?? main.provider
        let baseURL = (o?.baseURL.isEmpty == false ? o!.baseURL : nil) ?? main.baseURL
        let key = (o?.apiKey.isEmpty == false ? o!.apiKey : nil) ?? apiKey
        return AuxResolvedModel(model: model, provider: provider, baseURL: baseURL, apiKey: key)
    }

    /// Tolerant decode: missing block/tasks/fields all fall back to defaults.
    /// The block is a flat map of task-key → override (Hermes shape), e.g.
    /// `{"vision": {"model": "…"}, "title_gen": {"provider": "…"}}`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var map: [AuxiliaryTask: AuxiliaryOverride] = [:]
        for key in container.allKeys {
            if let task = AuxiliaryTask(rawValue: key.stringValue),
               let ov = try? container.decode(AuxiliaryOverride.self, forKey: key) {
                map[task] = ov
            }
        }
        self.byTask = map
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (task, override) in byTask {
            try container.encode(override, forKey: AnyCodingKey(task.key))
        }
    }
}

/// A catch-all `CodingKey` allowing the auxiliary block's keys to be the
/// arbitrary task names (vision, web_extract, title_gen, …).
struct AnyCodingKey: CodingKey, Equatable, Sendable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
