import ArcAgentCore
import Foundation
import Testing

// MARK: - Session list pagination (reference: bounded sidebar window)

/// Regression suite for `SessionStore.list(limit:offset:)`: the limit is a
/// hard store-level bound (never more than `limit` summaries returned) and
/// `offset` pages past the newest sessions. Both the webui sidebar window and
/// the "Load more conversations" step depend on these semantics.
@Suite("Session list pagination")
struct SessionPaginationTests {

    private func makeStore() -> (FileSessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-session-pagination-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (FileSessionStore(directory: dir), dir)
    }

    @Test("list limit is a hard store-level bound and offset pages")
    func listLimitAndOffset() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 1...4 {
            let s = Session(
                id: "p\(i)",
                createdAt: Date(timeIntervalSince1970: 1_000_000 + Double(i)),
                updatedAt: Date(timeIntervalSince1970: 1_000_000 + Double(i)),
                messages: [Message(role: .user, content: "msg \(i)")]
            )
            try await store.create(s)
            // Distinct file mtimes so the newest-first ordering is deterministic.
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Newest first, bounded by limit.
        let page1 = try await store.list(limit: 2, offset: 0)
        #expect(page1.map(\.id) == ["p4", "p3"], "returns the newest N")
        #expect(page1.allSatisfy { $0.messages.isEmpty }, "summaries only, no bodies")

        // Second page.
        let page2 = try await store.list(limit: 2, offset: 2)
        #expect(page2.map(\.id) == ["p2", "p1"])

        // Mid-page offset.
        let mid = try await store.list(limit: 1, offset: 1)
        #expect(mid.map(\.id) == ["p3"])

        // Bounds: zero limit, offset exactly at the end, offset past the end.
        #expect(try await store.list(limit: 0, offset: 0).isEmpty)
        #expect(try await store.list(limit: 10, offset: 4).isEmpty)
        #expect(try await store.list(limit: 10, offset: 100).isEmpty)

        // Negative offset clamps to the first page.
        let clamped = try await store.list(limit: 2, offset: -5)
        #expect(clamped.map(\.id) == ["p4", "p3"])

        // Convenience (offset 0) remains available for existing callers.
        let legacy = try await store.list(limit: 3)
        #expect(legacy.map(\.id) == ["p4", "p3", "p2"])
    }
}
