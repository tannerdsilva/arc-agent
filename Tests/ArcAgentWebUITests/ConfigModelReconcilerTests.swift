import Foundation
import Testing

import ArcAgentCore
@testable import ArcWebUI

/// `~/.arc/config.json`'s `model` block drives the UI's default model — the
/// divergence class behind the 2026-10-01 "I edited config.json and the web UI
/// never picked it up" report. The reconciler is pure so the matrix is pinned
/// without touching the real config or settings files.
@Suite("Config model reconcile")
struct ConfigModelReconcilerTests {

    private func arc(model: String, provider: String = "sglang", baseURL: String = "http://new:1/v1") -> ArcConfig {
        var c = ArcConfig()
        c.model.defaultModel = model
        c.model.provider = provider
        c.model.baseURL = baseURL
        return c
    }

    @Test("the legacy seed is adopted, refreshed and renamed; pins follow")
    func adoptsLegacySeed() {
        var s = AppSettings()
        s.modelConfigs = [
            ModelConfigPreset(name: "old-model", model: "old-model", provider: "sglang", baseURL: "http://old:1/v1")
        ]
        s.activeConfig = "old-model"
        s.sessionConfig = ["s1": "old-model", "s2": "other"]

        let changed = ConfigModelReconciler.reconcile(&s, resolved: .init(arc: arc(model: "new-model")))

        #expect(changed)
        #expect(s.modelConfigs.count == 1)
        #expect(s.modelConfigs[0].name == "new-model")
        #expect(s.modelConfigs[0].model == "new-model")
        #expect(s.modelConfigs[0].baseURL == "http://new:1/v1")
        #expect(s.modelConfigs[0].source == "config.json")
        #expect(s.activeConfig == "new-model")
        #expect(s.sessionConfig["s1"] == "new-model", "a pinned session follows the rename")
        #expect(s.sessionConfig["s2"] == "other", "unrelated pins are untouched")
    }

    @Test("a user's explicit pick survives; the managed preset is created alongside")
    func userPickSurvives() {
        var s = AppSettings()
        s.modelConfigs = [
            ModelConfigPreset(name: "my-ollama", model: "qwen", provider: "ollama",
                              baseURL: "http://localhost:11434/v1", source: "ui")
        ]
        s.activeConfig = "my-ollama"

        ConfigModelReconciler.reconcile(&s, resolved: .init(arc: arc(model: "managed-model")))

        #expect(s.modelConfigs.count == 2)
        #expect(s.activeConfig == "my-ollama", "the user's pick stays active")
        #expect(s.modelConfigs.contains { $0.source == "config.json" && $0.model == "managed-model" })
    }

    @Test("a second boot with the same config is a no-op")
    func idempotent() {
        var s = AppSettings()
        s.modelConfigs = [
            ModelConfigPreset(name: "old", model: "old", provider: "sglang", baseURL: "http://o/v1")
        ]
        s.activeConfig = "old"
        let resolved = ConfigModelReconciler.Resolved(arc: arc(model: "same-model"))

        #expect(ConfigModelReconciler.reconcile(&s, resolved: resolved))
        #expect(!ConfigModelReconciler.reconcile(&s, resolved: resolved), "second reconcile must be a no-op")
        #expect(s.modelConfigs.count == 1)
    }

    @Test("an empty store gets the managed preset, active")
    func emptyStore() {
        var s = AppSettings()
        ConfigModelReconciler.reconcile(&s, resolved: .init(arc: arc(model: "only-model")))

        #expect(s.modelConfigs.count == 1)
        #expect(s.modelConfigs[0].source == "config.json")
        #expect(s.activeConfig == "only-model")
    }

    @Test("a dangling active selection falls to the managed preset")
    func danglingActive() {
        var s = AppSettings()
        s.modelConfigs = [
            ModelConfigPreset(name: "gone" + "-preset", model: "m", provider: "p", baseURL: "http://g/v1", source: "ui")
        ]
        s.activeConfig = "does-not-exist"

        ConfigModelReconciler.reconcile(&s, resolved: .init(arc: arc(model: "fallback-model")))

        #expect(s.activeConfig == "fallback-model")
    }

    @Test("the managed key is refreshed when the env provides one")
    func apiKeyRefresh() {
        var s = AppSettings()
        s.modelConfigs = [
            ModelConfigPreset(name: "old", model: "old", provider: "sglang", baseURL: "http://o/v1")
        ]
        ConfigModelReconciler.reconcile(
            &s,
            resolved: .init(arc: arc(model: "keyed-model"), apiKey: "sk-env")
        )
        #expect(s.modelConfigs[0].apiKey == "sk-env")
    }
}