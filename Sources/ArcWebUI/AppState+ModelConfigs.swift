import Foundation

// MARK: - Editing a model configuration in place (Settings → Model configurations)
//
// A model configuration is one provider endpoint: name, model, provider, base
// URL, key, context length, output budget. Before this file the web UI could
// only add and remove one, so rotating a key or fixing a typo'd endpoint meant
// deleting the record — which dropped every chat pin and auxiliary route that
// named it — and typing it again.
//
// The rules the edit path holds:
// - the record is replaced at its own index, so list order and identity survive
//   an edit that keeps the name;
// - a rename repoints every pin that named the old name (`activeConfig`, the
//   per-chat picks, the legacy auxiliary map), the same set the boot reconciler
//   repoints when it renames the managed preset;
// - a blank key field keeps the stored secret, a typed key replaces it, and the
//   secret is never rendered back into the form;
// - the managed preset (the one `config.json` owns) writes through to the main
//   model block, because a settings-only edit would be reverted on the next
//   boot by `ConfigModelReconciler`.

/// One edit submission. `apiKey` is kept verbatim (a secret is never
/// re-spelled); every other field is trimmed at the boundary that reads it.
struct ModelConfigDraft: Sendable, Equatable {
    var name: String
    var model: String
    var provider: String
    var baseURL: String
    var apiKey: String
    var clearAPIKey: Bool
    var contextLength: Int?
    var maxOutputTokens: Int?
}

/// Why an in-place edit was refused. The controller turns one into a toast;
/// the form stays open with the submitted text.
enum ModelConfigEditError: Error, Equatable {
    case notFound
    case emptyName
    case emptyModel
    case emptyBaseURL
    case invalidBaseURL
    case duplicateName(String)
    case configWriteFailed

    var message: String {
        switch self {
        case .notFound:
            return "That model configuration no longer exists."
        case .emptyName:
            return "A name is required."
        case .emptyModel:
            return "A model is required."
        case .emptyBaseURL:
            return "A base URL is required."
        case .invalidBaseURL:
            return "Base URL is not a valid URL."
        case .duplicateName(let name):
            return "A configuration named '\(name)' already exists."
        case .configWriteFailed:
            return "The main configuration could not be saved — see the toast for the reason."
        }
    }
}

extension AppState {

    // MARK: form lifecycle

    /// Open the edit form pre-filled from `name`. The key field starts empty:
    /// the stored secret stays in the actor and only a placeholder describes it.
    func openModelConfigEdit(_ name: String) {
        guard let preset = settings.modelConfigs.first(where: { $0.name == name }) else { return }
        editingModelConfig = name
        stagedModelConfigAPIKey = nil
        formValues["mce-name"] = preset.name
        formValues["mce-model"] = preset.model
        formValues["mce-provider"] = preset.provider
        formValues["mce-baseurl"] = preset.baseURL
        formValues["mce-apikey"] = nil
        formValues["mce-clear-key"] = nil
        formValues["mce-ctx"] = preset.contextLength.map(String.init) ?? ""
        formValues["mce-maxtok"] = preset.maxOutputTokens.map(String.init) ?? ""
    }

    /// Close the edit form and drop its draft (a staged key included).
    func closeModelConfigEdit() {
        editingModelConfig = nil
        stagedModelConfigAPIKey = nil
        clearModelConfigForm()
    }

    /// Drop the edit form's draft values. The add form never reads these, so a
    /// stale draft cannot leak into a new configuration.
    func clearModelConfigForm() {
        formValues["mce-name"] = nil
        formValues["mce-model"] = nil
        formValues["mce-provider"] = nil
        formValues["mce-baseurl"] = nil
        formValues["mce-apikey"] = nil
        formValues["mce-clear-key"] = nil
        formValues["mce-ctx"] = nil
        formValues["mce-maxtok"] = nil
    }

    // MARK: save

    /// Replace the configuration named `originalName` with `draft`, in place.
    ///
    /// Returns nil on success (the form is closed and settings persisted), or
    /// the reason nothing changed. A failed validation leaves the draft — and
    /// any staged key — untouched so the form can render it back.
    @discardableResult
    func saveModelConfigEdit(originalName: String, draft: ModelConfigDraft) async -> ModelConfigEditError? {
        guard let index = settings.modelConfigs.firstIndex(where: { $0.name == originalName }) else {
            return .notFound
        }
        let existing = settings.modelConfigs[index]
        let managed = ConfigModelReconciler.manages(existing)

        // keep the clear intent across a refused save, so the re-rendered form
        // still shows what the user asked for.
        formValues["mce-clear-key"] = draft.clearAPIKey ? "1" : nil

        // stage a typed key BEFORE validation: a refused save must not lose a
        // secret the user just typed. it is never rendered — `modelConfigForm`
        // only describes it.
        if draft.clearAPIKey {
            stagedModelConfigAPIKey = nil
        } else if !draft.apiKey.isEmpty {
            stagedModelConfigAPIKey = draft.apiKey
        }

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = draft.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard managed || !name.isEmpty else { return .emptyName }
        guard !model.isEmpty else { return .emptyModel }
        guard !baseURL.isEmpty else { return .emptyBaseURL }
        guard Self.isEndpointURL(baseURL) else { return .invalidBaseURL }

        // the managed preset's name follows its model (the reconciler enforces
        // that on every boot), so a managed edit derives the name instead of
        // accepting one that would be overwritten.
        let finalName = managed ? model : name
        if settings.modelConfigs.contains(where: { $0.name == finalName && $0.name != originalName }) {
            return .duplicateName(finalName)
        }

        // resolve the key: clear wins, then a key staged above, then the secret
        // already stored on the record.
        let key: String
        if draft.clearAPIKey {
            key = ""
        } else if let staged = stagedModelConfigAPIKey {
            key = staged
        } else {
            key = existing.apiKey
        }

        let finalProvider = provider.isEmpty ? "custom" : provider

        // the managed preset IS `config.json`'s model block in the UI: persist
        // through the configuration store first, so a failed write changes
        // nothing and the next boot reconciles to the same values.
        if managed {
            let written = await updateConfig { config in
                config.model.defaultModel = model
                config.model.provider = finalProvider
                config.model.baseURL = baseURL
                config.model.contextLength = draft.contextLength
                config.model.maxOutputTokens = draft.maxOutputTokens
            }
            guard written else { return .configWriteFailed }
        }

        var preset = existing
        preset.name = finalName
        preset.model = model
        preset.provider = finalProvider
        preset.baseURL = baseURL
        preset.apiKey = key
        preset.contextLength = draft.contextLength
        preset.maxOutputTokens = draft.maxOutputTokens
        preset.source = managed ? ConfigModelReconciler.managedSource : "ui"
        settings.modelConfigs[index] = preset

        if finalName != originalName {
            repointModelConfigPins(from: originalName, to: finalName)
        }

        saveSettings()
        editingModelConfig = nil
        stagedModelConfigAPIKey = nil
        clearModelConfigForm()
        return nil
    }

    // MARK: helpers

    /// A provider endpoint must carry an http(s) scheme and a host.
    /// `URL(string:)` alone accepts a scheme-only string and any scheme at all
    /// (`ftp://host/v1`), which is how a typo could be stored and then fail at
    /// request time instead of at the form.
    static func isEndpointURL(_ text: String) -> Bool {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              let host = url.host, !host.isEmpty
        else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Repoint every reference to a renamed configuration — the same pin set the
    /// boot reconciler repoints when the managed preset follows its model.
    private func repointModelConfigPins(from old: String, to new: String) {
        if settings.activeConfig == old { settings.activeConfig = new }
        for session in settings.sessionConfig.filter({ $0.value == old }).map(\.key) {
            settings.sessionConfig[session] = new
        }
        for task in settings.auxiliaryModels.filter({ $0.value == old }).map(\.key) {
            settings.auxiliaryModels[task] = new
        }
    }
}
