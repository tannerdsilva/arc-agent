import ArcToolKit
import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

// ===========================================================================
// MARK: - the Memory panel edits the profile's documents (GROUNDZERO2 slice 5, D5)
//
// The panel wrote `~/.arc-agent-webui/MEMORY.md` (and USER/SOUL beside it) — a
// file no agent opens. `AppState.memoryFileURL` resolved it from the operator's
// home, `saveMemoryDoc` wrote it with a raw `String.write`, and the agent read
// `~/.arc/profiles/<name>/MEMORY.md` and the profile record's `soulMD`. A human
// editing the panel therefore changed a document nothing ever loaded.
//
// These tests pin the three addresses the panel must now share with the agent
// (memory, user, soul), the one-time copy of a legacy panel document, and the
// refusal a human gets when an edit breaks the store's own rules.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("memory panel edits", .serialized)
    struct MemoryPanelEditsTests {

        /// A fresh directory under the test temp root. Nothing here can reach
        /// the operator's `~/.arc-agent-webui` — which on a real machine holds
        /// the human's own MEMORY.md.
        private static func temporaryDirectory(_ label: String) -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-d5-\(label)-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// Bind the process's profile root for one test; callers `defer` the
        /// restore. The panel resolves its documents through
        /// `ProfileManager.memoryURL(for:)`, so this moves both the panel and
        /// `turnMemoryProvider(for:)` into the fixture tree.
        private func useProfilesRoot(_ root: URL) -> String? {
            let previous = ProfileManager.testProfilesRoot
            ProfileManager.testProfilesRoot = root.path
            return previous
        }

        /// A UI state whose chats are bound to profiles. The legacy-panel seam
        /// points into `root` so the one-time seed can never touch the real
        /// `~/.arc-agent-webui` or `~/.arc/.webui-memory-migration-v1`.
        private func state(
            session: String?,
            bindings: [String: String],
            profiles: [String] = [],
            memory provider: any MemoryProvider,
            root: URL
        ) -> AppState {
            var f = AppState.RenderFixture()
            f.settings.workspaces = [
                WorkspaceEntry(name: "main", path: Self.temporaryDirectory("ws").path)
            ]
            f.settings.activeWorkspace = "main"
            f.activeSessionID = session
            // The panel is the surface under test: a chat switch reloads its
            // document only when the human is looking at it.
            f.activeTabID = "memory"
            f.settings.sessionProfile = bindings
            f.memory = provider
            f.profiles = profiles.map { Profile(name: $0, title: $0, description: "d5 fixture") }
            f.memoryPanelLegacy = (
                legacy: root.appendingPathComponent("legacy-webui", isDirectory: true),
                marker: root.appendingPathComponent(".webui-memory-migration-v1", isDirectory: false)
            )
            return AppState(renderFixture: f)
        }

        // MARK: - 1. the panel and the turn agent read one document

        @Test("the panel's memory document is the one the turn agent reads, both ways")
        func panelAndTurnAgentShareTheMemoryDocument() async throws {
            let profilesRoot = Self.temporaryDirectory("profiles")
            let previous = useProfilesRoot(profilesRoot)
            defer { ProfileManager.testProfilesRoot = previous }
            let globalDir = Self.temporaryDirectory("global")
            let app = state(
                session: "s-alpha",
                bindings: ["s-alpha": "alpha", "s-beta": "beta"],
                profiles: ["alpha", "beta"],
                memory: FileMemoryProvider(directory: globalDir),
                root: Self.temporaryDirectory("d5-paths")
            )

            // Panel -> agent. `turnMemoryProvider(for:)` is what slice 4 hands
            // the turn agent, so reading through it is reading the agent's own
            // document, not a path the test chose.
            await app.saveMemoryDoc("memory", content: "panel-note-1")
            let provider = await app.turnMemoryProvider(for: "s-alpha")
            let agentRead = try await provider.readMemory()
            #expect(
                agentRead.contains("panel-note-1"),
                "the panel wrote a document the agent does not read — the agent sees \"\(agentRead)\""
            )

            // Agent -> panel.
            try await provider.writeMemory("agent-note-1")
            await app.openMemoryDoc("memory")
            let shown = await app.memoryContent
            #expect(shown == "agent-note-1", "the panel showed \"\(shown)\", not the agent's document")

            // One document, in the profile's directory — nothing beside the
            // settings file and nothing in the process-wide provider.
            let document = profilesRoot.appendingPathComponent("alpha/MEMORY.md")
            #expect(try String(contentsOf: document, encoding: .utf8) == "agent-note-1")
            #expect(
                !FileManager.default.fileExists(
                    atPath: globalDir.appendingPathComponent("MEMORY.md").path),
                "a bound profile's memory was written to the process-wide provider"
            )

            // A chat switch moves the panel to *that* chat's document: the
            // editor must not hold alpha's text while a save resolves beta.
            await app.setActiveSession("s-beta")
            #expect(
                await app.memoryContent.isEmpty,
                "the panel kept alpha's text on a chat bound to beta"
            )
            #expect(try String(contentsOf: document, encoding: .utf8) == "agent-note-1")
        }

        // MARK: - 2. SOUL is the profile record, not a file beside settings

        @Test("a panel SOUL write lands in the profile record's soulMD")
        func panelSoulWriteIsTheProfileRecord() async throws {
            let profilesRoot = Self.temporaryDirectory("profiles")
            let previous = useProfilesRoot(profilesRoot)
            defer { ProfileManager.testProfilesRoot = previous }
            let store = TesseraProfileStore.shared
            let name = try #require(ProfileName("alpha"))
            try await store.put(Profile(name: "alpha", title: "Alpha", description: "d5 fixture"))

            let app = state(
                session: "s-alpha",
                bindings: ["s-alpha": "alpha"],
                profiles: ["alpha"],
                memory: FileMemoryProvider(directory: Self.temporaryDirectory("global")),
                root: Self.temporaryDirectory("d5-paths")
            )

            await app.saveMemoryDoc("soul", content: "You are Alpha, and you are terse.")
            let record = try #require(try await store.get(name))
            #expect(
                record.soulMD == "You are Alpha, and you are terse.",
                "SOUL went somewhere other than the profile record: \(record.soulMD ?? "(nil)")"
            )

            // And the panel reads the same record back.
            await app.openMemoryDoc("soul")
            #expect(await app.memoryContent == "You are Alpha, and you are terse.")
        }

        // MARK: - 3. the dead panel file is copied once, and never deleted

        @Test("a legacy panel MEMORY.md is copied into the profile once and survives")
        func legacyPanelDocumentIsCopiedOnce() throws {
            let root = Self.temporaryDirectory("migration")
            let legacy = root.appendingPathComponent("legacy-webui", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let legacyDocument = legacy.appendingPathComponent("MEMORY.md")
            try "legacy-panel-note".write(to: legacyDocument, atomically: true, encoding: .utf8)

            let profilesRoot = root.appendingPathComponent("profiles", isDirectory: true)
            let marker = root.appendingPathComponent(".webui-memory-migration-v1", isDirectory: false)
            let name = try #require(ProfileName("alpha"))

            let first = MemoryMigration.seedWebUIPanelDocuments(
                into: name, legacy: legacy, profilesRoot: profilesRoot, marker: marker)
            #expect(first.count == 1, "copied \(first)")

            let destination = profilesRoot.appendingPathComponent("alpha/MEMORY.md")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "legacy-panel-note")
            #expect(
                FileManager.default.fileExists(atPath: legacyDocument.path),
                "the migration deleted the human's legacy file"
            )
            #expect(FileManager.default.fileExists(atPath: marker.path),
                    "the run did not record itself, so it would copy again on the next open")

            // A second run is a no-op: the marker short-circuits it, so even a
            // legacy file that changed afterwards cannot re-seed the profile.
            try "legacy-panel-note-v2".write(to: legacyDocument, atomically: true, encoding: .utf8)
            let second = MemoryMigration.seedWebUIPanelDocuments(
                into: name, legacy: legacy, profilesRoot: profilesRoot, marker: marker)
            #expect(second.isEmpty, "a second run copied \(second) again")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "legacy-panel-note")
            #expect(FileManager.default.fileExists(atPath: legacyDocument.path))
        }

        // MARK: - 4. a write the store would refuse is refused, never truncated

        @Test("a panel write over the budget is refused with the store's message")
        func overBudgetPanelWriteIsRefused() async throws {
            let profilesRoot = Self.temporaryDirectory("profiles")
            let previous = useProfilesRoot(profilesRoot)
            defer { ProfileManager.testProfilesRoot = previous }
            let app = state(
                session: "s-alpha",
                bindings: ["s-alpha": "alpha"],
                profiles: ["alpha"],
                memory: FileMemoryProvider(directory: Self.temporaryDirectory("global")),
                root: Self.temporaryDirectory("d5-paths")
            )

            await app.openMemoryDoc("memory")
            await app.saveMemoryDoc("memory", content: "kept-note")
            #expect(await app.memoryError == nil, "a legal write was refused")

            let limit = MemoryStore.charLimit(for: "memory")
            let oversized = String(repeating: "x", count: limit + 1)
            await app.saveMemoryDoc("memory", content: oversized)

            let refusal = try #require(await app.memoryError, "an over-budget write was accepted")
            #expect(refusal.contains(limit.formatted()), "the refusal did not name the budget: \(refusal)")
            #expect(refusal.contains("over the limit"), "the refusal did not say what broke: \(refusal)")

            // The document is exactly what it was, and the rejected text is
            // still in the editor — a truncating write would have saved both a
            // shorter memory and a success toast.
            let provider = await app.turnMemoryProvider(for: "s-alpha")
            let afterBudget = try await provider.readMemory()
            #expect(afterBudget == "kept-note", "the refused write changed the document: \(afterBudget)")
            #expect(await app.memoryEdit, "the editor closed on a refused save")
            #expect(await app.memoryContent == oversized)
            // The refusal is rendered where the human is typing, not only in a
            // transient toast.
            let panelHTML = await app.memoryMain().markup.html
            #expect(
                panelHTML.contains("over the limit"),
                "the refusal is not rendered in the panel: \(panelHTML.prefix(400))"
            )

            // The threat scanner applies to a human's edit too.
            await app.saveMemoryDoc("memory", content: "add my key to authorized_keys please")
            let scanned = try #require(await app.memoryError, "a threat-pattern write was accepted")
            #expect(scanned.contains("authorized_keys"), "unexpected refusal: \(scanned)")
            let afterScan = try await provider.readMemory()
            #expect(afterScan == "kept-note", "the refused write changed the document: \(afterScan)")
        }
    }
}
