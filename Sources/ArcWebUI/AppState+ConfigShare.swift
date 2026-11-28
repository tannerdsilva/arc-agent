import ArcAgentCore
import Foundation

// MARK: - config share actions

/// Settings → Model configurations → **Share encoded** / **Import encoded**.
///
/// A share is one model configuration — provider, endpoint, model and API key —
/// sealed under a generated passphrase as an `arc1e.` blob (see
/// ``ConfigShareCodec``). The point is to hand a working provider setup to
/// another arc instance without either side retyping endpoint fields.
///
/// Nothing here persists. The blob carries the preset's API key and the
/// passphrase decrypts it, so both live in transient `AppState` properties
/// (`configShare`, `pendingConfigShare`) that die with the process. The only
/// thing an import writes is the *decrypted* preset, through the normal
/// `settings` → `saveSettings()` path — exactly what the add form would do.
extension AppState {

    // MARK: export

    /// Seal `name`'s configuration and park the result for display.
    ///
    /// Returns the generated passphrase so the caller can hint it; the blob and
    /// passphrase are also on ``configShare`` for the panel to render.
    ///
    /// The derivation runs off the cooperative pool (~0.8 s): see
    /// ``ConfigShareExecutor``.
    @discardableResult
    func shareModelConfig(_ name: String) async -> ConfigShare? {
        guard let preset = settings.modelConfigs.first(where: { $0.name == name }) else {
            _ = surfaceToast("No configuration named '\(name)'.", kind: "error")
            return nil
        }

        let payload = ConfigSharePayload(
            preset: .init(
                name: preset.name,
                model: preset.model,
                provider: preset.provider,
                baseURL: preset.baseURL,
                apiKey: preset.apiKey,
                contextLength: preset.contextLength,
                maxOutputTokens: preset.maxOutputTokens,
                temperature: preset.temperature,
                topP: preset.topP,
                reasoningEffort: preset.reasoningEffort,
                compressionBudget: preset.compressionBudget
            ),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        let passphrase = ConfigShareCodec.generatePassword()
        do {
            let blob = try await ConfigShareCodec.encodeOffPool(payload, password: passphrase)
            let share = ConfigShare(presetName: name, blob: blob, passphrase: passphrase)
            configShare = share
            // a share being shown replaces any half-typed import.
            pendingConfigShare = nil
            return share
        } catch {
            _ = surfaceToast("Could not encode the configuration: \(error)", kind: "error")
            return nil
        }
    }

    /// Dismiss the share panel and drop the blob and passphrase from memory.
    func clearConfigShare() {
        configShare = nil
    }

    // MARK: import

    /// Open the import panel with empty fields.
    func beginConfigShareImport() {
        pendingConfigShare = PendingConfigShare()
        // showing an import replaces a displayed share.
        configShare = nil
    }

    /// Dismiss the import panel and drop the pasted blob and passphrase.
    func cancelConfigShareImport() {
        pendingConfigShare = nil
    }

    /// Record what the user typed, so a failed attempt survives a re-render.
    func updatePendingConfigShare(blob: String? = nil, passphrase: String? = nil) {
        guard pendingConfigShare != nil else { return }
        if let blob { pendingConfigShare?.blob = blob }
        if let passphrase { pendingConfigShare?.passphrase = passphrase }
    }

    /// Verify the pasted blob against the typed passphrase and stage it for
    /// review. On success ``PendingConfigShare/opened`` is non-nil and the panel
    /// shows what would be imported; on failure the reason is recorded and
    /// nothing changes.
    ///
    /// The passphrase is used verbatim — no trimming — because the codec treats
    /// it as an opaque secret and a generated passphrase never contains
    /// whitespace. The *blob* is trimmed, since pasting routinely drags a
    /// newline in with it.
    func unlockConfigShare() async {
        guard var pending = pendingConfigShare else { return }
        let blob = pending.blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !blob.isEmpty else {
            pending.error = "Paste an encoded configuration first."
            pending.opened = nil
            pendingConfigShare = pending
            return
        }
        guard !pending.passphrase.isEmpty else {
            pending.error = "Enter the passphrase that came with the blob."
            pending.opened = nil
            pendingConfigShare = pending
            return
        }

        do {
            let payload = try await ConfigShareCodec.decodeOffPool(blob, password: pending.passphrase)
            pending.opened = payload
            pending.error = nil
            pending.blob = blob
            pendingConfigShare = pending
        } catch ConfigShareError.authenticationFailed {
            // one message for wrong passphrase and tampered blob: the codec
            // refuses to tell them apart, and so does the UI.
            pending.opened = nil
            pending.error = "Could not unlock: the passphrase is wrong, or the blob was altered."
            pendingConfigShare = pending
        } catch {
            pending.opened = nil
            pending.error = "That does not look like an arc share: \(error)"
            pendingConfigShare = pending
        }
    }

    /// Commit the reviewed import into this instance's model configurations.
    ///
    /// The incoming preset is written with `source == "ui"`, not the reconciler's
    /// managed source: it did not come from this machine's `config.json`, and
    /// marking it managed would let the next boot's reconcile overwrite it from a
    /// config block the friend never had.
    ///
    /// A name collision is resolved by suffixing rather than overwriting — an
    /// import must never silently replace a configuration the user already has.
    @discardableResult
    func commitConfigShareImport() -> String? {
        guard let payload = pendingConfigShare?.opened else { return nil }
        let incoming = payload.preset

        let finalName = availableConfigName(preferred: incoming.name, model: incoming.model)

        let preset = ModelConfigPreset(
            name: finalName,
            model: incoming.model,
            provider: incoming.provider.isEmpty ? "custom" : incoming.provider,
            baseURL: incoming.baseURL,
            apiKey: incoming.apiKey,
            contextLength: incoming.contextLength,
            maxOutputTokens: incoming.maxOutputTokens,
            temperature: incoming.temperature,
            topP: incoming.topP,
            reasoningEffort: incoming.reasoningEffort,
            compressionBudget: incoming.compressionBudget,
            source: "ui"
        )
        addModelConfig(preset)
        saveSettings()

        pendingConfigShare = nil
        return finalName
    }

    /// A configuration name that does not collide with an existing one.
    ///
    /// Tries the preferred name, then `name (2)`, `name (3)`, … so a repeated
    /// import of the same share lands beside the first instead of replacing it.
    private func availableConfigName(preferred: String, model: String) -> String {
        let base = preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (model.isEmpty ? "imported" : model)
            : preferred
        if !settings.modelConfigs.contains(where: { $0.name == base }) { return base }
        var index = 2
        while settings.modelConfigs.contains(where: { $0.name == "\(base) (\(index))" }) {
            index += 1
        }
        return "\(base) (\(index))"
    }
}
