import ArcAgentCore
import Foundation
import Testing
import WebUICore
@testable import ArcWebUI

// ===========================================================================
// MARK: - sharing a model configuration as an encrypted blob
//
// "Share encoded" seals one configuration — including its API key — under a
// generated 10-character passphrase and shows the blob. "Import encoded" takes
// a blob and a passphrase, verifies them, and adds the configuration.
//
// The tests below pin the properties that matter beyond the codec's own suite:
// that the blob and passphrase are *never* persisted (the blob is a credential
// and the passphrase decrypts it), that an import cannot clobber an existing
// configuration, and that an imported record is UI-owned rather than managed
// (a managed record would be overwritten by the next boot's reconcile from a
// config block the sending machine had and this one does not).
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("config share", .serialized)
    struct ConfigShareTests {

        private static func state() -> AppState {
            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [
                ModelConfigPreset(
                    name: "shared", model: "deepseek-v4-flash", provider: "silva-quad",
                    baseURL: "https://api.example.com/v1", apiKey: "sk-live-abcdef0123456789",
                    contextLength: 128_000, maxOutputTokens: 8192,
                    temperature: 0.7, topP: 0.95, reasoningEffort: "medium",
                    compressionBudget: 32_000, source: "ui"),
            ]
            f.settings.activeConfig = "shared"
            return AppState(renderFixture: f)
        }

        // MARK: export

        @Test("sharing yields a prefixed blob and a 10-character passphrase")
        func shareProducesBlobAndPassphrase() async {
            let app = Self.state()
            let share = await app.shareModelConfig("shared")
            #expect(share != nil)
            #expect(share?.blob.hasPrefix("arc1e.") == true)
            #expect(share?.passphrase.count == 10)
            #expect(share?.presetName == "shared")
            // the reveal state is what the panel renders.
            #expect(await app.configShare == share)
        }

        @Test("sharing an unknown configuration reports and shows nothing")
        func shareUnknown() async {
            let app = Self.state()
            let share = await app.shareModelConfig("nope")
            #expect(share == nil)
            #expect(await app.configShare == nil)
        }

        @Test("the blob and passphrase are not written into the settings document")
        func shareIsNotPersisted() async {
            let app = Self.state()
            let share = await app.shareModelConfig("shared")
            #expect(share != nil)

            // AppSettings is what SettingsStore serializes. Neither secret may
            // appear anywhere in its encoded form — this is the invariant that
            // keeps a credential and its key out of settings.json.
            let encoded = (try? JSONEncoder().encode(await app.settings))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let blob = share?.blob {
                #expect(!encoded.contains(blob), "the blob must never reach the settings document")
            }
            if let pass = share?.passphrase {
                #expect(!encoded.contains(pass), "the passphrase must never reach the settings document")
            }
        }

        @Test("clearing the share drops the blob and passphrase")
        func clearDropsSecrets() async {
            let app = Self.state()
            _ = await app.shareModelConfig("shared")
            #expect(await app.configShare != nil)
            await app.clearConfigShare()
            #expect(await app.configShare == nil)
        }

        // MARK: import

        @Test("a share round-trips into another instance as a UI-owned record")
        func importRoundTrip() async {
            let source = Self.state()
            guard let share = await source.shareModelConfig("shared") else {
                Issue.record("share failed")
                return
            }

            let target = Self.state()
            await target.beginConfigShareImport()
            await target.updatePendingConfigShare(blob: share.blob, passphrase: share.passphrase)
            await target.unlockConfigShare()

            let opened = await target.pendingConfigShare?.opened
            #expect(opened != nil, "a correct passphrase must unlock the blob")
            #expect(await target.pendingConfigShare?.error == nil)

            let name = await target.commitConfigShareImport()
            #expect(name != nil)
            let imported = await target.settings.modelConfigs.first(where: { $0.name == name })
            #expect(imported != nil)
            // every field travels, including the key.
            #expect(imported?.apiKey == "sk-live-abcdef0123456789")
            #expect(imported?.baseURL == "https://api.example.com/v1")
            #expect(imported?.contextLength == 128_000)
            #expect(imported?.compressionBudget == 32_000)
            #expect(imported?.reasoningEffort == "medium")
            // provenance: a friend's record is not this machine's config.json.
            #expect(imported?.source == "ui")
            // the panel closes and the pasted secret goes with it.
            #expect(await target.pendingConfigShare == nil)
        }

        @Test("a wrong passphrase reports one message and unlocks nothing")
        func wrongPassphrase() async {
            let source = Self.state()
            guard let share = await source.shareModelConfig("shared") else {
                Issue.record("share failed"); return
            }
            let target = Self.state()
            await target.beginConfigShareImport()
            await target.updatePendingConfigShare(blob: share.blob, passphrase: "wrongwrong")
            await target.unlockConfigShare()

            #expect(await target.pendingConfigShare?.opened == nil)
            let error = await target.pendingConfigShare?.error ?? ""
            // one message for wrong-passphrase and tampered-blob alike.
            #expect(error.contains("passphrase is wrong"))
            // the pasted values survive so the user can correct the passphrase.
            #expect(await target.pendingConfigShare?.blob == share.blob)
            #expect(await target.pendingConfigShare?.passphrase == "wrongwrong")
        }

        @Test("an import cannot clobber an existing configuration of the same name")
        func importCollisionIsSuffixed() async {
            let source = Self.state()
            guard let share = await source.shareModelConfig("shared") else {
                Issue.record("share failed"); return
            }
            // the target already has a "shared" record with a different key.
            let target = Self.state()
            await target.beginConfigShareImport()
            await target.updatePendingConfigShare(blob: share.blob, passphrase: share.passphrase)
            await target.unlockConfigShare()
            let name = await target.commitConfigShareImport()

            #expect(name == "shared (2)")
            let configs = await target.settings.modelConfigs
            #expect(configs.count == 2)
            // the original is untouched.
            #expect(configs.first(where: { $0.name == "shared" })?.apiKey == "sk-live-abcdef0123456789")
            #expect(configs.first(where: { $0.name == "shared (2)" }) != nil)
        }

        @Test("repeated imports keep numbering rather than replacing")
        func repeatedImportsNumber() async {
            let source = Self.state()
            guard let share = await source.shareModelConfig("shared") else {
                Issue.record("share failed"); return
            }
            let target = Self.state()
            for _ in 0..<2 {
                await target.beginConfigShareImport()
                await target.updatePendingConfigShare(blob: share.blob, passphrase: share.passphrase)
                await target.unlockConfigShare()
                _ = await target.commitConfigShareImport()
            }
            let names = await target.settings.modelConfigs.map(\.name)
            #expect(names == ["shared", "shared (2)", "shared (3)"])
        }

        @Test("unlocking without a blob or passphrase reports instead of deriving")
        func unlockRequiresInput() async {
            let app = Self.state()
            await app.beginConfigShareImport()
            await app.unlockConfigShare()
            #expect(await app.pendingConfigShare?.error?.contains("Paste an encoded") == true)

            await app.updatePendingConfigShare(blob: "arc1e.abc", passphrase: "")
            await app.unlockConfigShare()
            #expect(await app.pendingConfigShare?.error?.contains("passphrase") == true)
        }

        @Test("cancelling an import drops the pasted secret")
        func cancelDropsPastedSecret() async {
            let source = Self.state()
            guard let share = await source.shareModelConfig("shared") else {
                Issue.record("share failed"); return
            }
            let target = Self.state()
            await target.beginConfigShareImport()
            await target.updatePendingConfigShare(blob: share.blob, passphrase: share.passphrase)
            await target.cancelConfigShareImport()
            #expect(await target.pendingConfigShare == nil)
        }
    }
}
