import ArcToolKit
import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

// ===========================================================================
// MARK: - a turn's memory document belongs to its profile (GROUNDZERO2 slice 4, D13)
//
// The UI handed every turn the process-wide memory provider resolved once at
// boot, while `profile_edit` — scoped by `ToolContext` — addressed
// `~/.arc/profiles/<name>`: a `memory` write landed in `~/.arc/memories` and
// the profile's own `MEMORY.md` stayed empty, so the two tools a human watches
// disagreed. These tests pin the one-document property through the surface the
// turn actually dispatches through (`Configuration.registry`): for one bound
// profile, for two profiles in one process, and for the Tessera provider that
// must keep its process-wide scope.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("memory panel scope", .serialized)
    struct MemoryPanelScopeTests {

        /// No network, no sampling knobs to observe: these tests are about
        /// which document a turn addresses, not which model it asks.
        private static let preset = ModelConfigPreset(
            name: "d13-stub",
            model: "stub-model-1",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            apiKey: "stub-key"
        )

        /// A fresh directory under the test temp root. `FileManager`'s
        /// temporary directory is per-process, so nothing here can reach the
        /// operator's `~/.arc`.
        private static func temporaryDirectory(_ label: String) -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-d13-\(label)-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// Bind the process's profile root for one test, returning the root the
        /// profile directories live under. Callers `defer` the restore.
        private func useProfilesRoot(_ root: URL) -> String? {
            let previous = ProfileManager.testProfilesRoot
            ProfileManager.testProfilesRoot = root.path
            return previous
        }

        /// A UI state whose chats are bound to profiles, with the process-wide
        /// memory provider rooted in a temp directory — never the real
        /// `~/.arc/memories`, which a RED run would otherwise write.
        private func state(
            bindings: [String: String],
            profiles: [String] = [],
            memory provider: any MemoryProvider
        ) -> AppState {
            var f = AppState.RenderFixture()
            f.settings.workspaces = [
                WorkspaceEntry(name: "main", path: Self.temporaryDirectory("ws").path)
            ]
            f.settings.activeWorkspace = "main"
            f.settings.sessionProfile = bindings
            f.memory = provider
            f.profiles = profiles.map { Profile(name: $0, title: $0, description: "d13 fixture") }
            return AppState(renderFixture: f)
        }

        // MARK: - one profile: the write is the read

        @Test("a turn agent's memory write is the document profile_edit reads")
        func turnAgentMemoryIsTheProfileDocument() async throws {
            let profilesRoot = Self.temporaryDirectory("profiles")
            let previous = useProfilesRoot(profilesRoot)
            defer { ProfileManager.testProfilesRoot = previous }
            let globalDir = Self.temporaryDirectory("global")
            let app = state(
                bindings: ["s-alpha": "alpha"],
                profiles: ["alpha"],
                memory: FileMemoryProvider(directory: globalDir)
            )

            let (_, config) = await app.makeTurnAgent(
                preset: Self.preset,
                profileContext: nil,
                thinking: "off",
                headless: false,
                sessionID: "s-alpha"
            )

            // 1. The turn's provider is rooted at the session's profile — the
            //    same directory `ProfileDocuments` writes — not the process's.
            let provider = try #require(config.memoryProvider as? FileMemoryProvider)
            let profileDir = profilesRoot.appendingPathComponent("alpha", isDirectory: true)
            #expect(
                provider.directory.standardizedFileURL.path == profileDir.standardizedFileURL.path,
                "the turn was handed \(provider.directory.path), not the profile's directory"
            )

            // 2. The surface the turn dispatches through addresses one
            //    document from both tools: the `memory` write is visible to
            //    `profile_edit`'s read. (`memory` has no read action — reads
            //    are prompt injection — so the read comes from the other tool.)
            let memory = try #require(
                config.registry.lookup(name: "memory"),
                "the turn's surface must carry the memory tool"
            )
            let write = try await memory.handler([
                "target": "memory", "action": "add", "content": "d13-profile-probe",
            ])
            #expect(!write.hasPrefix("Error"), "\(write)")

            let edit = try #require(config.registry.lookup(name: "profile_edit"))
            let read = try await edit.handler(["file": "memory", "action": "read"])
            #expect(read.contains("d13-profile-probe"), "\(read)")

            // 3. Nothing landed in the process-wide directory.
            #expect(
                !FileManager.default.fileExists(
                    atPath: globalDir.appendingPathComponent("MEMORY.md").path),
                "a bound profile's memory was written to the process-wide provider"
            )

            // 4. And it is on disk where the profile's documents live.
            let document = profileDir.appendingPathComponent("MEMORY.md")
            let onDisk = try String(contentsOf: document, encoding: .utf8)
            #expect(onDisk.contains("d13-profile-probe"))
        }

        // MARK: - two profiles: no bleed

        @Test("two chats bound to different profiles do not share a memory document")
        func twoProfilesKeepSeparateDocuments() async throws {
            let profilesRoot = Self.temporaryDirectory("profiles")
            let previous = useProfilesRoot(profilesRoot)
            defer { ProfileManager.testProfilesRoot = previous }
            let app = state(
                bindings: ["s-alpha": "alpha", "s-beta": "beta"],
                profiles: ["alpha", "beta"],
                memory: FileMemoryProvider(directory: Self.temporaryDirectory("global"))
            )

            let (_, alpha) = await app.makeTurnAgent(
                preset: Self.preset, profileContext: nil, thinking: "off",
                headless: false, sessionID: "s-alpha"
            )
            let (_, beta) = await app.makeTurnAgent(
                preset: Self.preset, profileContext: nil, thinking: "off",
                headless: false, sessionID: "s-beta"
            )

            let alphaMemory = try #require(alpha.registry.lookup(name: "memory"))
            let betaMemory = try #require(beta.registry.lookup(name: "memory"))
            _ = try await alphaMemory.handler([
                "target": "memory", "action": "add", "content": "alpha-note",
            ])
            _ = try await betaMemory.handler([
                "target": "memory", "action": "add", "content": "beta-note",
            ])

            let alphaRead = try await #require(alpha.registry.lookup(name: "profile_edit"))
                .handler(["file": "memory", "action": "read"])
            let betaRead = try await #require(beta.registry.lookup(name: "profile_edit"))
                .handler(["file": "memory", "action": "read"])

            #expect(alphaRead.contains("alpha-note"), "\(alphaRead)")
            #expect(!alphaRead.contains("beta-note"), "alpha's document leaked beta's note")
            #expect(betaRead.contains("beta-note"), "\(betaRead)")
            #expect(!betaRead.contains("alpha-note"), "beta's document leaked alpha's note")

            // The two documents on disk are two documents.
            let alphaDoc = profilesRoot.appendingPathComponent("alpha/MEMORY.md")
            let betaDoc = profilesRoot.appendingPathComponent("beta/MEMORY.md")
            #expect(try String(contentsOf: alphaDoc, encoding: .utf8).contains("alpha-note"))
            #expect(try String(contentsOf: betaDoc, encoding: .utf8).contains("beta-note"))
        }

        // MARK: - Tessera keeps its process-wide scope

        @Test("a Tessera turn keeps the process-wide provider")
        func tesseraMemoryStaysProcessWide() async throws {
            let profilesRoot = Self.temporaryDirectory("profiles")
            let previous = useProfilesRoot(profilesRoot)
            defer { ProfileManager.testProfilesRoot = previous }
            let tessera = TesseraMemoryProvider()
            let app = state(bindings: ["s-alpha": "alpha"], profiles: ["alpha"], memory: tessera)

            let (_, config) = await app.makeTurnAgent(
                preset: Self.preset, profileContext: nil, thinking: "off",
                headless: false, sessionID: "s-alpha"
            )

            // Tessera memory has no profile dimension (one tunnel, one key
            // set): the provider the runtime built must reach the turn, not a
            // per-profile file store invented for it.
            #expect(config.memoryProvider is TesseraMemoryProvider)
            #expect(config.registry.lookup(name: "memory") != nil)

            // No profile document was fabricated for it either.
            #expect(
                !FileManager.default.fileExists(
                    atPath: profilesRoot.appendingPathComponent("alpha/MEMORY.md").path)
            )
        }
    }
}
