import Foundation
import Testing
import WebUI
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The settings page says which policy the environment is supplying.
    ///
    /// A settings control writes the configuration file, so when an environment
    /// variable outranks the file the control looks broken: the value snaps back
    /// on the next resolve and nothing on screen explains why. One line at the
    /// top of Settings names the overridden policy in the user's words — "the
    /// main model", never `model.defaultModel` or a file path.
    ///
    /// The seam is `AppState(renderFixture:)` plus a **scratch** configuration
    /// store with an injected environment, then `refreshConfig()` — the same
    /// reload path the app uses when the file changes under it.
    @Suite("settings environment overrides", .serialized)
    struct SettingsEnvironmentOverrideTests {

        /// A scratch `config.json` holding `json`, in a fresh directory so the
        /// store's `.env` sibling is absent (or exactly what a test writes).
        private static func scratchConfig(_ json: String) throws -> (url: URL, dir: URL) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-env-override-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            try json.write(to: url, atomically: true, encoding: .utf8)
            return (url, dir)
        }

        private func app(url: URL, environment: [String: String]) -> AppState {
            var fixture = AppState.RenderFixture()
            fixture.settings.theme = "light"
            return AppState(
                renderFixture: fixture,
                configurationStore: ConfigurationStore(url: url, environment: environment))
        }

        // MARK: - the line itself

        @Test("an environment model is named at the top of Settings")
        func environmentModelIsNamed() async throws {
            let (url, dir) = try Self.scratchConfig(#"{"model":{"defaultModel":"file-model"}}"#)
            defer { try? FileManager.default.removeItem(at: dir) }
            let app = app(url: url, environment: ["ARC_MODEL": "env-model"])
            await app.refreshConfig()
            let html = await app.settingsMain().markup.html
            #expect(html.contains(
                "Set by the environment — change the environment to change these: the main model."),
                "the note names the setting in domain words")
        }

        @Test("no environment override means no note")
        func noNoteWithoutOverrides() async throws {
            let (url, dir) = try Self.scratchConfig(#"{"model":{"defaultModel":"file-model"}}"#)
            defer { try? FileManager.default.removeItem(at: dir) }
            let app = app(url: url, environment: [:])
            await app.refreshConfig()
            let html = await app.settingsMain().markup.html
            #expect(!html.contains("Set by the environment"),
                    "nothing is overridden, so nothing is claimed")
        }

        @Test("every overridden policy is named in one sentence")
        func namesEveryOverride() async throws {
            let (url, dir) = try Self.scratchConfig(
                #"{"model":{"defaultModel":"file-model","provider":"openai"},"security":{"approvalMode":"manual"}}"#)
            defer { try? FileManager.default.removeItem(at: dir) }
            let app = app(url: url, environment: [
                "ARC_MODEL": "env-model",
                "ARC_PROVIDER": "anthropic",
                "ARC_APPROVAL_MODE": "off",
            ])
            await app.refreshConfig()
            let html = await app.settingsMain().markup.html
            #expect(html.contains(
                "Set by the environment — change the environment to change these: the main model, the model provider and the approval mode."))
        }

        // MARK: - what counts as an override

        @Test("an environment Tessera relay is an override, a stored key is not")
        func tesseraConnectionOnly() async throws {
            let declared = ArcConfig()
            var relay = ArcConfig()
            relay.tessera = TesseraConfig(
                serverIP: "10.0.0.5", serverPort: 51921,
                serverPublicKey: "npub1example", myPrivateKey: "", application: 7)
            #expect(AppState.environmentOverrideNames(declared: declared, resolved: relay)
                == ["the Tessera connection"])

            // the private key round-trips through `.env` on every saved
            // connection: a key alone must not be reported as an override.
            var keyOnly = ArcConfig()
            keyOnly.tessera = TesseraConfig(
                serverIP: relay.tessera!.serverIP, serverPort: relay.tessera!.serverPort,
                serverPublicKey: relay.tessera!.serverPublicKey,
                myPrivateKey: "nsec1exampleprivatekey", application: relay.tessera!.application)
            #expect(AppState.environmentOverrideNames(declared: relay, resolved: keyOnly).isEmpty,
                    "a stored client key is persisted state, not an environment override")
        }

        @Test("an unknown approval spelling that runs as manual is not an override")
        func approvalComparedAfterParsing() {
            var declared = ArcConfig()
            declared.security.approvalMode = ""
            var resolved = ArcConfig()
            resolved.security.approvalMode = "manual"
            #expect(AppState.environmentOverrideNames(declared: declared, resolved: resolved).isEmpty)
        }

        @Test("a stored .env client key is not reported as an environment override")
        func dotEnvKeyIsNotAnOverride() async throws {
            let json = #"""
                {"tessera":{"serverIP":"10.0.0.5","serverPort":51921,"serverPublicKey":"npub1example","myPrivateKey":"","application":7}}
                """#
            let (url, dir) = try Self.scratchConfig(json)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "ARC_TESSERA_PRIVATE_KEY=nsec1exampleprivatekey\n"
                .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            let app = app(url: url, environment: [:])
            await app.refreshConfig()
            let html = await app.settingsMain().markup.html
            #expect(!html.contains("Set by the environment"),
                    "a key saved by the UI lives in .env; it is not an override")
        }
    }
}
