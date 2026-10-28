import Foundation
import Testing
@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// The grant and the documents type carry authority as values, so most of
    /// these never read the process-global gate. They nest under
    /// `ArcCoreTestRoot` anyway: `refusalSentencesUnchanged` cross-checks the
    /// live static, which the serialized tree already owns.
    @Suite("Tool grant")
    struct ToolGrantTests {

        private func grant(
            _ access: DocumentAccess,
            profile: String = "default"
        ) -> ToolGrant {
            ToolGrant(
                profile: ProfileName(profile)!,
                documentAccess: access,
                mayManageSkills: false
            )
        }

        /// Convenience for the common "these documents are open, the rest are
        /// individually locked" shape.
        private func grant(
            _ editable: Set<ProfileFile>,
            profile: String = "default"
        ) -> ToolGrant {
            grant(.only(editable), profile: profile)
        }

        private func tempDirectory(_ label: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tool-grant-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // MARK: - Sentences

        /// The refusal text is operator-facing copy quoted by Settings and by
        /// these tests. It must not be reworded by the move onto a value, and
        /// the two ways a surface can be closed — the global switch off, or
        /// all four documents individually locked — must not share a sentence
        /// (GROUNDZERO defect D1).
        @Test("refusal sentences are unchanged")
        func refusalSentencesUnchanged() {
            let globalLocked = "Refused: profile editing is locked in Settings (Agent powers → Profile). "
                + "The agent cannot modify MEMORY/USER/SOUL/AGENTS while 'Agent can edit profile' is off."
            let memoryLocked = "Refused: MEMORY is locked in Settings (Agent powers → Profile). "
                + "Unlock it there before editing."
            let soulLocked = "Refused: SOUL is locked in Settings (Agent powers → Profile). "
                + "Unlock it there before editing."

            // The global switch: one sentence for the whole surface.
            for file in ProfileFile.allCases {
                #expect(grant(.none).refusal(for: file) == globalLocked)
            }
            // Individually locked: the document's own sentence...
            #expect(grant([.user, .soul, .agents]).refusal(for: .memory) == memoryLocked)
            #expect(grant([.memory, .user, .agents]).refusal(for: .soul) == soulLocked)
            // ...including when every document is locked — D1: this used to
            // arrive as an empty set and answer with the global sentence.
            for file in ProfileFile.allCases {
                let sentence = grant(.only([])).refusal(for: file)
                #expect(sentence == "Refused: \(file.displayName) is locked in Settings "
                    + "(Agent powers → Profile). Unlock it there before editing.")
                #expect(sentence != globalLocked, "only([]) must not speak for the global switch")
            }
            // Unlocked is silent, for every document.
            for file in ProfileFile.allCases {
                #expect(grant(.all).refusal(for: file) == nil)
                #expect(grant(Set(ProfileFile.allCases)).refusal(for: file) == nil)
            }
            // The path-shaped entry point resolves the right document.
            #expect(grant([.user]).refusal(forPath: "/tmp/proj/MEMORY.md") == memoryLocked)
            #expect(grant([.user]).refusal(forPath: "/tmp/proj/notes.md") == nil)
            #expect(grant(.none).refusal(forPath: "/tmp/proj/AGENTS.md") == globalLocked)

            // And the bridge maps the gate's two locks onto the two states, so
            // the sentences above are the ones an operator actually sees.
            defer { AgentPowers.configure(AgentPowersConfig()) }
            let configurations: [(AgentPowersConfig, DocumentAccess)] = [
                (AgentPowersConfig(), .all),
                (AgentPowersConfig(profileEdit: false), .none),
                (AgentPowersConfig(profileEdit: true, lockedProfileFiles: ["memory", "agents"]),
                 .only([.user, .soul])),
            ]
            for (config, expected) in configurations {
                AgentPowers.configure(config)
                #expect(AgentPowers.grant(profile: .default).documentAccess == expected)
            }

            // All four locked individually is `only([])`, not `.none` — the D1
            // distinction must survive the trip through the gate.
            AgentPowers.configure(AgentPowersConfig(
                profileEdit: true, lockedProfileFiles: ["memory", "user", "soul", "agents"]))
            let allLocked = AgentPowers.grant(profile: .default)
            #expect(allLocked.documentAccess == .only([]))
            #expect(allLocked.refusal(for: .memory) == memoryLocked)
        }

        // MARK: - One root

        /// A document set carries exactly one root and cannot be re-pointed:
        /// two values built over two roots write to two places, and neither can
        /// see the other's document.
        @Test("documents bind to one root")
        func documentsBindToOneRoot() throws {
            let first = try tempDirectory("a")
            let second = try tempDirectory("b")
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }

            let boundGrant = grant(Set(ProfileFile.allCases))
            let documentsA = ProfileDocuments(root: first, grant: boundGrant)
            let documentsB = ProfileDocuments(root: second, grant: boundGrant)

            try documentsA.write(.memory, "alpha")
            try documentsB.write(.memory, "beta")

            let memoryA = first.appendingPathComponent("MEMORY.md")
            let memoryB = second.appendingPathComponent("MEMORY.md")
            #expect(try String(contentsOf: memoryA, encoding: .utf8) == "alpha")
            #expect(try String(contentsOf: memoryB, encoding: .utf8) == "beta")
            #expect(try documentsA.read(.memory) == "alpha")
            #expect(try documentsB.read(.memory) == "beta")

            // The same value keeps writing to its own root across writes.
            try documentsA.write(.user, "alice")
            #expect(try String(contentsOf: first.appendingPathComponent("USER.md"), encoding: .utf8) == "alice")
            #expect(!FileManager.default.fileExists(
                atPath: second.appendingPathComponent("USER.md").path))

            // Membership is root-scoped, and a missing document reads empty
            // rather than borrowing the other root's content.
            #expect(documentsA.contains(path: documentsA.path(for: .memory)))
            #expect(!documentsA.contains(path: documentsB.path(for: .memory)))
            #expect(!documentsA.contains(path: first.appendingPathComponent("notes.md").path))
            #expect(documentsA.file(at: documentsA.path(for: .soul)) == .soul)
            #expect(try documentsA.read(.soul).isEmpty)

            // The grant is enforced by the value itself, not only by the tool.
            let locked = ProfileDocuments(root: first, grant: grant([.user]))
            #expect(throws: ProfileDocuments.Failure.self) {
                try locked.write(.memory, "gamma")
            }
            #expect(try documentsA.read(.memory) == "alpha")

            // A grant cannot be built for a name the validator rejects, so a
            // document set can never be bound to an impossible profile.
            #expect(ProfileName("Not A Name") == nil)
            #expect(ProfileName("x") == nil)
            #expect(ProfileName("default") == .default)
        }

        // MARK: - Patch

        /// A grant that excludes a document stops `patch` in both modes: the
        /// replace target and every `*** Update File:` / `*** Add File:`
        /// target inside a V4A body.
        @Test("patch refuses a path the grant excludes")
        func patchRefusesWhenTheGrantExcludesThePath() async throws {
            let directory = try tempDirectory("patch")
            defer { try? FileManager.default.removeItem(at: directory) }
            let document = directory.appendingPathComponent("MEMORY.md")
            try "alpha".write(to: document, atomically: true, encoding: .utf8)

            let locked = grant([.user])

            let replace = try await PatchTool.entry(grant: locked).handler([
                "path": document.path, "old_string": "alpha", "new_string": "beta",
            ])
            #expect(replace.contains("Refused:"))
            #expect(replace.contains("MEMORY"))
            #expect(try String(contentsOf: document, encoding: .utf8) == "alpha")

            let v4a = """
            *** Begin Patch
            *** Update File: \(document.path)
            @@
            -alpha
            +beta
            *** End Patch
            """
            let patched = try await PatchTool.entry(grant: locked).handler([
                "mode": "patch", "patch": v4a,
            ])
            #expect(patched.contains("Refused:"))
            #expect(try String(contentsOf: document, encoding: .utf8) == "alpha")

            let addedPath = directory.appendingPathComponent("SOUL.md")
            let added = """
            *** Begin Patch
            *** Add File: \(addedPath.path)
            +persona
            *** End Patch
            """
            let addedOut = try await PatchTool.entry(grant: locked).handler([
                "mode": "patch", "patch": added,
            ])
            #expect(addedOut.contains("Refused:"))
            #expect(!FileManager.default.fileExists(atPath: addedPath.path))

            // A path outside the grant's authority is not its business.
            let note = directory.appendingPathComponent("notes.md")
            try "alpha".write(to: note, atomically: true, encoding: .utf8)
            let allowed = try await PatchTool.entry(grant: locked).handler([
                "path": note.path, "old_string": "alpha", "new_string": "beta",
            ])
            #expect(!allowed.contains("Refused:"))
            #expect(try String(contentsOf: note, encoding: .utf8).contains("beta"))

            // And a grant that includes the document lets the same edit through.
            let open = grant(Set(ProfileFile.allCases))
            let applied = try await PatchTool.entry(grant: open).handler([
                "path": document.path, "old_string": "alpha", "new_string": "beta",
            ])
            #expect(applied.contains("Successfully applied patch"))
            #expect(try String(contentsOf: document, encoding: .utf8).contains("beta"))
        }
    }
}
