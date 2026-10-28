import Foundation
import Testing
@testable import ArcAgentCore

/// Task 5 — a single-flight per-session turn lease so only one agent generates
/// a response for a shared session at a time.
@Suite("Turn lease")
struct TurnLeaseTests {

    @Test("a free session can be acquired; a held session cannot")
    func acquireAndHold() async {
        let reg = TurnLeaseRegistry()
        #expect(await reg.acquire(sessionID: "s1") == true)
        #expect(await reg.isHeld(sessionID: "s1"))
        #expect(await reg.acquire(sessionID: "s1") == false)
        // Other sessions are independent.
        #expect(await reg.acquire(sessionID: "s2") == true)
    }

    @Test("release frees the session for the next turn")
    func releaseReacquires() async {
        let reg = TurnLeaseRegistry()
        #expect(await reg.acquire(sessionID: "s1"))
        await reg.release(sessionID: "s1")
        #expect(!(await reg.isHeld(sessionID: "s1")))
        #expect(await reg.acquire(sessionID: "s1"))
    }

    @Test("a lease expires after its TTL")
    func ttlExpiry() async throws {
        let reg = TurnLeaseRegistry()
        #expect(await reg.acquire(sessionID: "s1", ttl: 0.02))
        #expect(await reg.isHeld(sessionID: "s1"))
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(!(await reg.isHeld(sessionID: "s1")))
        #expect(await reg.acquire(sessionID: "s1"))
    }

    @Test("liveCount tracks held leases")
    func liveCount() async {
        let reg = TurnLeaseRegistry()
        _ = await reg.acquire(sessionID: "a")
        _ = await reg.acquire(sessionID: "b")
        #expect(await reg.liveCount == 2)
        await reg.release(sessionID: "a")
        #expect(await reg.liveCount == 1)
    }
}
