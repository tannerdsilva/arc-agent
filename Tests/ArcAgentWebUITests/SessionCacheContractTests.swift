import Foundation
import Testing

@testable import ArcWebUI

/// Regression guard for the storage-switch blank-chat bug.
///
/// When the `sessions` array is replaced with fresh metadata-only summaries
/// (storage switch via `reloadAll` / `reloadAllBounded`), the LRU that tracks
/// materialized chats must be invalidated — and `ensureSessionMessages` must
/// also self-heal a stale LRU entry (id listed but no bodies) by refetching.
/// Otherwise a chat that was loaded before the switch stays blank after it
/// until a new turn force-reloads it.
@Suite("Session cache LRU contracts")
struct SessionCacheContractTests {

    private static let sourcesRoot = "Sources/ArcWebUI"

    private static func source(_ name: String) -> String {
        (try? String(contentsOfFile: "\(sourcesRoot)/\(name)", encoding: .utf8)) ?? ""
    }

    /// The body of the first `func <name>` up to the next top-level `func`.
    private static func body(of name: String, in text: String) -> String {
        guard let start = text.range(of: "func \(name)") else { return "" }
        guard let end = text.range(of: "\n    func ", range: start.upperBound..<text.endIndex) else {
            return String(text[start.lowerBound...])
        }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    @Test("ensureSessionMessages refetches a session in the LRU that carries no bodies")
    func staleLRURefetches() {
        let text = Self.source("AppState.swift")
        let ensure = Self.body(of: "ensureSessionMessages(_ id: String)", in: text)
        #expect(!ensure.isEmpty)
        // Bodies (current truth) are authoritative over LRU membership: an
        // empty body must not be skipped just because the id is still listed.
        #expect(ensure.contains("if !sessions[idx].messages.isEmpty"))
        #expect(ensure.contains("if loadedSessionOrder.contains(id)"))
        #expect(ensure.contains("loadedSessionOrder.removeAll { $0 == id }"))
        #expect(ensure.contains("store.get(id: id)"))
        let staleCheck = ensure.range(of: "loadedSessionOrder.contains(id)")
        let fetch = ensure.range(of: "store.get(id: id)")
        if let staleCheck, let fetch {
            #expect(staleCheck.lowerBound < fetch.lowerBound)
        } else {
            Issue.record("LRU stale-check and store.get both must be present")
        }
    }

    @Test("reloadAll invalidates the lazy cache when it replaces the sessions array")
    func reloadAllInvalidates() {
        let text = Self.source("AppState.swift")
        let reload = Self.body(of: "reloadAll() async", in: text)
        #expect(reload.contains("sessions = try await store.list(limit: 500)"))
        #expect(reload.contains("loadedSessionOrder.removeAll()"))
        // The active chat is re-materialized so an open chat never sits blank
        // after a storage switch.
        #expect(reload.contains("await ensureSessionMessages(keep)"))
    }

    @Test("reloadAllBounded invalidates the lazy cache when it replaces the sessions array")
    func reloadBoundedInvalidates() {
        let text = Self.source("AppState+Actions.swift")
        let reload = Self.body(of: "reloadAllBounded(seconds: UInt64 = 10)", in: text)
        #expect(reload.contains("sessions = list"))
        #expect(reload.contains("loadedSessionOrder.removeAll()"))
    }
}
