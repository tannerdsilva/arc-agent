import Testing
import Foundation
import ArcAgentCore
@testable import ArcWebUI

/// The settings document behind the shared store.
///
/// `settings.json` used to be read with `try?` and written with `try?`: a file
/// that failed to decode silently became compiled defaults, and the next toggle
/// wrote those defaults over ~100 KB of the user's state. These are the same
/// guarantees `ConfigurationStore` already proves for `config.json`.
extension ArcWebUITestRoot {
    @Suite("settings store", .serialized)
    struct SettingsStoreTests {

        /// A fresh settings URL under a unique scratch directory. The file is
        /// not created: a missing document is its own case.
        private func scratch() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-settings-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("settings.json")
        }

        private func store(at url: URL) -> SettingsStore {
            SettingsStore(url: url, environment: [:], resolve: { document, _ in document })
        }

        @Test("a corrupt settings file is refused, never replaced by defaults")
        func corruptSettingsRefused() async throws {
            let url = try scratch()
            try Data("{ not json".utf8).write(to: url)
            let store = store(at: url)

            #expect(await store.failure() != nil)
            await #expect(throws: ConfigError.self) {
                _ = try await store.mutate { $0.theme = "dark" }
            }
            let untouched = try String(contentsOf: url, encoding: .utf8)
            #expect(untouched == "{ not json")
        }

        @Test("a missing settings file is defaults, not a failure")
        func missingSettingsYieldsDefaults() async throws {
            let url = try scratch()
            let store = store(at: url)

            #expect(await store.failure() == nil)
            let snapshot = await store.snapshot()
            #expect(snapshot.declared == AppSettings())
            #expect(snapshot.resolved == AppSettings())
            #expect(snapshot.url == url)
            // reading a missing document never creates it.
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        @Test("a settings write keeps one generation of backup")
        func writeKeepsBackup() async throws {
            let url = try scratch()
            let store = store(at: url)
            _ = try await store.mutate { $0.theme = "dark" }
            _ = try await store.mutate { $0.theme = "light" }

            let backup = url.appendingPathExtension("bak")
            let restored = try SettingsStore.read(backup)
            #expect(restored.theme == "dark")
        }

        @Test("a render fixture owns no settings file")
        func fixtureOwnsNoSettingsFile() async throws {
            let realURL = ArcHome.webUISettings
            let before = try? FileManager.default
                .attributesOfItem(atPath: realURL.path)[.modificationDate] as? Date

            let app = AppState(renderFixture: .init())
            #expect(await app.settingsStore == nil)

            // saving from a fixture is a no-op: it must never touch (or
            // create) the operator's real settings file.
            await app.saveSettings()

            let after = try? FileManager.default
                .attributesOfItem(atPath: realURL.path)[.modificationDate] as? Date
            #expect(before == after)
        }

        @Test("a boot-failure toast outlives the TTL, a normal one does not")
        func persistentToastSurvivesExpiry() async throws {
            // regression: the corrupt-settings warning was an ordinary error
            // toast, so it expired after 10s and anyone who opened the
            // dashboard later saw a silently reset UI.
            let app = AppState(renderFixture: .init())
            let persistent = await app.surfaceToast(
                "settings.json could not be read", kind: "error", persistent: true)
            _ = await app.surfaceToast("transient error", kind: "error")

            _ = await app.expireToasts(now: Date().addingTimeInterval(3600))

            let remaining = await app.toasts.map(\.text)
            #expect(remaining == [persistent.text])
        }
    }
}
