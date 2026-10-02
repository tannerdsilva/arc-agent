import ArcAgentCore

/// `~/.arc/config.json`'s `model` block is the UI's default model: exactly ONE
/// preset is "managed" — refreshed from the resolved config on every boot,
/// renamed to follow the model so the label cannot lie, with every pin that
/// referenced it repointed.
///
/// Presets the user creates in the picker (`source == "ui"`) are untouched,
/// and the managed preset is activated only when nothing valid is selected —
/// so an explicit pick survives config edits until the user chooses another.
enum ConfigModelReconciler {

    /// The provenance marker for the config-owned preset.
    static let managedSource = "config.json"

    /// The snapshot of `loadConfig()`'s model block (+ the env API key) that
    /// the reconciler applies.
    struct Resolved: Equatable {
        var model: String
        var provider: String
        var baseURL: String
        var apiKey: String
        var contextLength: Int?
        var maxOutputTokens: Int?

        init(arc: ArcConfig, apiKey: String = "") {
            self.model = arc.model.defaultModel
            self.provider = arc.model.provider
            self.baseURL = arc.model.baseURL ?? "https://api.openai.com/v1"
            self.apiKey = apiKey
            self.contextLength = arc.model.contextLength
            self.maxOutputTokens = arc.model.maxOutputTokens
        }
    }

    /// Reconcile the managed preset. Returns true when `settings` changed and
    /// should be persisted.
    @discardableResult
    static func reconcile(_ s: inout AppSettings, resolved: Resolved) -> Bool {
        var changed = false

        // locate — or adopt the legacy one-shot seed, or create.
        let managedIndex: Int
        if let i = s.modelConfigs.firstIndex(where: { $0.source == managedSource }) {
            managedIndex = i
        } else if let i = s.modelConfigs.firstIndex(where: { $0.source == nil && $0.name == $0.model }) {
            // the legacy seed named the preset by its model; adopt it so the
            // pins accumulated against it (sessionConfig entries) keep
            // resolving across the rename.
            s.modelConfigs[i].source = managedSource
            managedIndex = i
            changed = true
        } else {
            let name = Self.name(for: resolved)
            s.modelConfigs.append(ModelConfigPreset(
                name: name,
                model: name,
                provider: resolved.provider,
                baseURL: resolved.baseURL,
                apiKey: resolved.apiKey,
                contextLength: resolved.contextLength,
                maxOutputTokens: resolved.maxOutputTokens,
                source: managedSource
            ))
            managedIndex = s.modelConfigs.count - 1
            changed = true
        }

        // refresh its fields; the name follows the model.
        let oldName = s.modelConfigs[managedIndex].name
        let name = Self.name(for: resolved)
        var preset = s.modelConfigs[managedIndex]
        preset.name = name
        preset.model = name
        preset.provider = resolved.provider
        preset.baseURL = resolved.baseURL
        if !resolved.apiKey.isEmpty { preset.apiKey = resolved.apiKey }
        preset.contextLength = resolved.contextLength
        preset.maxOutputTokens = resolved.maxOutputTokens
        if preset != s.modelConfigs[managedIndex] {
            s.modelConfigs[managedIndex] = preset
            changed = true
        }

        // repoint every pin that named the old preset.
        if oldName != name {
            if s.activeConfig == oldName { s.activeConfig = name }
            for key in s.sessionConfig.keys where s.sessionConfig[key] == oldName {
                s.sessionConfig[key] = name
            }
        }

        // the managed preset is the DEFAULT: activate it only when nothing
        // valid is selected — an explicit pick survives config edits.
        if s.activeConfig.isEmpty || !s.modelConfigs.contains(where: { $0.name == s.activeConfig }) {
            if s.activeConfig != name {
                s.activeConfig = name
                changed = true
            }
        }
        return changed
    }

    private static func name(for resolved: Resolved) -> String {
        resolved.model.isEmpty ? "default" : resolved.model
    }
}