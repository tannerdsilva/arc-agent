import Foundation

/// Per-model parameters as stored in a web UI model configuration preset.
///
/// The model configuration is the single home for model parameters — window
/// size, generation budget, sampling, reasoning effort, compression budget.
/// Profiles point *at* models; they do not carry parameters. This is the
/// daemon-side reader for that store: a tolerant decoder over
/// `<webUI>/settings.json` → `modelConfigs`, because the daemon target cannot
/// depend on the web UI target (the dependency runs the other way).
public struct PerModelParameters: Sendable, Equatable {
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var reasoningEffort: String?
    public var compressionBudget: Int?

    public init(
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        reasoningEffort: String? = nil,
        compressionBudget: Int? = nil
    ) {
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.reasoningEffort = reasoningEffort
        self.compressionBudget = compressionBudget
    }
}

public enum ModelParameterStore {

    /// The persisted web UI model configurations: `<webUI>/settings.json`.
    ///
    /// Mirrors the fields `ModelConfigPreset` carries; every field optional so
    /// older stores decode. Extra/unknown keys are ignored.
    struct PresetDTO: Codable {
        var model: String?
        var contextLength: Int?
        var maxOutputTokens: Int?
        var temperature: Double?
        var topP: Double?
        var reasoningEffort: String?
        var compressionBudget: Int?
    }

    private struct SettingsDTO: Codable {
        var modelConfigs: [PresetDTO]?
    }

    /// Load every stored model configuration (nil when the store is absent
    /// or undecodable — hosted sessions then fall back to global config).
    static func allPresets(settingsURL: URL? = nil) -> [PresetDTO] {
        let url = settingsURL ?? ArcHome.webUISettings
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(SettingsDTO.self, from: data),
              let configs = settings.modelConfigs else { return [] }
        return configs
    }

    /// The parameters configured for `model`, or nil when no stored
    /// configuration names it.
    ///
    /// All stored configurations whose `model` matches are merged newest-wins
    /// in store order (later entries refine earlier ones), so a user may keep
    /// several named configurations for the same model without the daemon
    /// picking an arbitrary winner for the *parameters*.
    public static func parameters(forModel model: String) -> PerModelParameters? {
        parameters(forModel: model, settingsURL: ArcHome.webUISettings)
    }

    /// Injectable-URL variant for tests.
    static func parameters(forModel model: String, settingsURL: URL) -> PerModelParameters? {
        let matches = allPresets(settingsURL: settingsURL).filter { $0.model == model }
        guard !matches.isEmpty else { return nil }
        var merged = PerModelParameters()
        for p in matches {
            if let v = p.contextLength { merged.contextLength = v }
            if let v = p.maxOutputTokens { merged.maxOutputTokens = v }
            if let v = p.temperature { merged.temperature = v }
            if let v = p.topP { merged.topP = v }
            if let v = p.reasoningEffort { merged.reasoningEffort = v }
            if let v = p.compressionBudget { merged.compressionBudget = v }
        }
        return merged
    }
}
