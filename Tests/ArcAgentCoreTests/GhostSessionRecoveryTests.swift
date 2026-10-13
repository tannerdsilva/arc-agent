import Foundation
import Testing

@testable import ArcAgentCore

/// The ghost-session contract.
///
/// A session the UI still renders from memory while its store file is gone is
/// the silent-data-loss case observed live: every `appendMessage` throws
/// ``SessionError/notFound``, the message never lands, and nothing heals the
/// entry. These tests pin the store semantics the recovery path relies on:
/// the file requirement, the visibility gap in `list`, and that a `create`
/// upsert re-materializes the full transcript so later appends land.
@Suite("Ghost session recovery")
struct GhostSessionRecoveryTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-ghost-\(UUID().uuidString)")
    }

    private func fileURL(_ dir: URL, _ id: String) -> URL {
        dir.appendingPathComponent("\(id).json")
    }

    @Test("appendMessage throws notFound once the session file is gone")
    func appendRequiresFile() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSessionStore(directory: dir)
        let sid = "ghost-append"
        try await store.create(Session(id: sid))
        try await store.appendMessage(sessionID: sid, message: Message(role: .user, content: "before"))

        try FileManager.default.removeItem(at: fileURL(dir, sid))

        await #expect(throws: SessionError.self) {
            try await store.appendMessage(sessionID: sid, message: Message(role: .user, content: "after"))
        }
    }

    @Test("a missing file drops the session from list() — the sidebar gap")
    func listOmitsMissingFile() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSessionStore(directory: dir)
        try await store.create(Session(id: "kept"))
        try await store.create(Session(id: "gone"))

        try FileManager.default.removeItem(at: fileURL(dir, "gone"))

        let listed = try await store.list(limit: 10).map(\.id)
        #expect(listed == ["kept"])
    }

    @Test("re-creating from the in-memory snapshot restores the transcript and later appends land")
    func healThenAppend() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSessionStore(directory: dir)
        let sid = "ghost-heal"
        let first = Message(role: .user, content: "one")
        let reply = Message(role: .assistant, content: "two")
        try await store.create(Session(id: sid, messages: [first, reply]))

        try FileManager.default.removeItem(at: fileURL(dir, sid))

        // the recovery path: rebuild the entry from the transcript the UI holds
        try await store.create(Session(id: sid, title: "Recovered chat", messages: [first, reply]))
        try await store.appendMessage(sessionID: sid, message: Message(role: .user, content: "three"))

        let restored = try await store.get(id: sid)
        #expect(restored?.messages.map(\.content) == ["one", "two", "three"])
        #expect(restored?.title == "Recovered chat")
    }
}