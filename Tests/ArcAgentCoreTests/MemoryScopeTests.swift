import ArcToolKit
import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Memory and profile scope
//
// GROUNDZERO slice 4. The `memory` tool and `profile_edit` used to find their
// subject through process-global statics (`MemoryTool.provider`,
// `AgentPowers.memoriesDirectory`), so two profiles in one process addressed
// one file and a second agent's start could re-point the first agent's memory.
// These tests pin the replacement: scope is a value handed to the tool, and two
// scopes write two files.
//
// Nothing here reads `AgentPowers`' live gate: every tool is built with an
// explicit grant, so the suite is about addressing, not authority.

extension ArcCoreTestRoot {
    @Suite("Memory and profile scope", .serialized)
    struct MemoryScopeTests {

        // MARK: Fixtures

        /// A profile directory that looks like `~/.arc/profiles/<name>`.
        private struct ProfileHome {
            let name: ProfileName
            let root: URL

            init(_ name: String, label: String) throws {
                self.name = ProfileName(name)!
                self.root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gz-scope-\(label)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            }

            var documents: ProfileDocuments {
                ProfileDocuments(root: root, grant: grant(.all))
            }

            var memoryFile: URL { root.appendingPathComponent("MEMORY.md") }
            var userFile: URL { root.appendingPathComponent("USER.md") }

            func grant(_ access: DocumentAccess) -> ToolGrant {
                ToolGrant(profile: name, documentAccess: access)
            }

            func context(workspace: URL) -> ToolContext {
                ToolContext(
                    profile: name,
                    sessionID: "session-\(name.rawValue)",
                    workspace: workspace.path,
                    grant: grant(.all)
                )
            }

            /// The memory tool as `buildRegistry(context:memory:)` would build
            /// it: this profile's context and this profile's provider root.
            func memoryTool(workspace: URL? = nil) -> ToolEntry {
                MemoryTool.entry(
                    context: context(workspace: workspace ?? root),
                    memory: FileMemoryProvider(directory: root)
                )
            }

            func profileEdit(
                workspace: URL? = nil,
                profiles: any ProfileStore,
                access: DocumentAccess = .all
            ) -> ToolEntry {
                let grant = grant(access)
                return ProfileEditTool.entry(
                    context: ToolContext(
                        profile: name,
                        sessionID: "session-\(name.rawValue)",
                        workspace: (workspace ?? root).path,
                        grant: grant
                    ),
                    documents: ProfileDocuments(root: root, grant: grant),
                    profiles: profiles
                )
            }

            func remove() { try? FileManager.default.removeItem(at: root) }
        }

        private func tempDirectory(_ label: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gz-workspace-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // MARK: - Two profiles, two documents

        /// The core claim: scope is the profile, so two agents writing one
        /// logical document write two files.
        @Test("two profiles write different files")
        func twoProfilesWriteDifferentFiles() async throws {
            let alpha = try ProfileHome("alpha", label: "alpha")
            let beta = try ProfileHome("beta", label: "beta")
            defer { alpha.remove(); beta.remove() }

            let alphaOut = try await alpha.memoryTool().handler([
                "target": "memory", "action": "add", "content": "alpha-only fact",
            ])
            let betaOut = try await beta.memoryTool().handler([
                "target": "memory", "action": "add", "content": "beta-only fact",
            ])
            #expect(!alphaOut.contains("Error"))
            #expect(!betaOut.contains("Error"))

            let alphaMemory = try String(contentsOf: alpha.memoryFile, encoding: .utf8)
            let betaMemory = try String(contentsOf: beta.memoryFile, encoding: .utf8)
            #expect(alphaMemory.contains("alpha-only fact"))
            #expect(!alphaMemory.contains("beta-only fact"))
            #expect(betaMemory.contains("beta-only fact"))
            #expect(!betaMemory.contains("alpha-only fact"))

            // And each `profile_edit` sees only its own profile's document.
            let store: any ProfileStore = InMemoryProfileStore()
            let alphaRead = try await alpha.profileEdit(profiles: store)
                .handler(["file": "memory", "action": "read"])
            let betaRead = try await beta.profileEdit(profiles: store)
                .handler(["file": "memory", "action": "read"])
            #expect(alphaRead.contains("alpha-only fact"))
            #expect(!alphaRead.contains("beta-only fact"))
            #expect(betaRead.contains("beta-only fact"))
            #expect(!betaRead.contains("alpha-only fact"))
        }

        // MARK: - Reads come from the captured provider

        /// The provider is captured, not looked up: the tool reads the entries
        /// of the provider it was built with. `replace` needs an existing entry,
        /// so it fails on a provider that does not hold it and succeeds on the
        /// one that does — from the same call arguments.
        @Test("memory reads the scoped provider")
        func memoryReadsTheScopedProvider() async throws {
            let alpha = try ProfileHome("alpha", label: "read-alpha")
            let beta = try ProfileHome("beta", label: "read-beta")
            defer { alpha.remove(); beta.remove() }

            _ = try await alpha.memoryTool().handler([
                "target": "memory", "action": "add", "content": "shared needle",
            ])

            let hit = try await alpha.memoryTool().handler([
                "target": "memory", "action": "replace",
                "old_text": "shared needle", "content": "rewritten needle",
            ])
            #expect(hit.contains("Entry replaced"))
            let rewritten = try String(contentsOf: alpha.memoryFile, encoding: .utf8)
            #expect(rewritten.contains("rewritten needle"))

            // Same tool shape, different provider: nothing to replace, and the
            // scoped file is untouched.
            let miss = try await beta.memoryTool().handler([
                "target": "memory", "action": "replace",
                "old_text": "shared needle", "content": "wrong file",
            ])
            #expect(miss.contains("No entry matched"))
            #expect(!FileManager.default.fileExists(atPath: beta.memoryFile.path))
        }

        // MARK: - profile_edit's defaults

        /// `file=soul` with no `profile` argument addresses the *calling*
        /// profile. It used to default to `"default"`, so every agent's SOUL
        /// edit landed on the default bot's persona.
        @Test("profile_edit soul defaults to the calling profile")
        func profileEditSoulDefaultsToCallingProfile() async throws {
            let beta = try ProfileHome("beta", label: "soul")
            defer { beta.remove() }

            let store = InMemoryProfileStore([
                Profile(name: "default", title: "Default", description: "the default bot",
                        soulMD: "default persona"),
                Profile(name: "beta", title: "Beta", description: "beta bot",
                        soulMD: "beta persona"),
            ])

            // Read: the caller's persona, not the default one.
            let read = try await beta.profileEdit(profiles: store)
                .handler(["file": "soul", "action": "read"])
            #expect(read == "beta persona")

            // Write: lands on beta, and default is untouched.
            let write = try await beta.profileEdit(profiles: store)
                .handler(["file": "soul", "action": "write", "content": "beta persona v2"])
            #expect(write.contains("Updated SOUL for profile 'beta'"))

            let betaRecord = try await store.get(beta.name)
            let defaultRecord = try await store.get(.default)
            #expect(betaRecord?.soulMD == "beta persona v2")
            #expect(defaultRecord?.soulMD == "default persona")

            // An explicit `profile` argument still wins.
            let explicit = try await beta.profileEdit(profiles: store)
                .handler(["file": "soul", "action": "read", "profile": "default"])
            #expect(explicit == "default persona")
        }

        // MARK: - One document

        /// The write side of the addressing split: what `memory` writes,
        /// `profile_edit` reads — same profile, same file.
        @Test("memory writes the calling profile's documents")
        func memoryWritesTheCallingProfilesDocuments() async throws {
            let alpha = try ProfileHome("alpha", label: "one-doc")
            defer { alpha.remove() }
            let store: any ProfileStore = InMemoryProfileStore()

            _ = try await alpha.memoryTool().handler([
                "target": "memory", "action": "add", "content": "one-document probe",
            ])
            let read = try await alpha.profileEdit(profiles: store)
                .handler(["file": "memory", "action": "read"])
            #expect(read.contains("one-document probe"))

            // USER.md is the same story, and it is a different file.
            _ = try await alpha.memoryTool().handler([
                "target": "user", "action": "add", "content": "prefers terse answers",
            ])
            let userRead = try await alpha.profileEdit(profiles: store)
                .handler(["file": "user", "action": "read"])
            #expect(userRead.contains("prefers terse answers"))
            let memoryText = try String(contentsOf: alpha.memoryFile, encoding: .utf8)
            #expect(!memoryText.contains("prefers terse answers"))

            // A profile_edit write is visible to the provider: the round trip
            // closes in both directions.
            _ = try await alpha.profileEdit(profiles: store)
                .handler(["file": "memory", "action": "write", "content": "from profile_edit"])
            let providerSaw = try await FileMemoryProvider(directory: alpha.root).readMemory()
            #expect(providerSaw.contains("from profile_edit"))
        }
    }
}
