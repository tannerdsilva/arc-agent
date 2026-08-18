import Testing
@testable import ArcAgentCore
import Foundation
import ServiceLifecycle

// =========================================================================
// MARK: - Delivery Manager Tests
//
// These test the hardening of `DeliveryManager.send` for **local**
// (request/response) platforms — `api` (HTTP) and `webui` (WebSocket).
//
// Regression: before the fix, a web/API chat turn would reach
// `deliveryManager.send(message:to:)` with platform "api"/"webui" and no
// adapter registered for it, throwing `unknownPlatform`. That throw was
// caught upstream by `SessionAgent`, which **removed the session and shut
// down its HTTP client** — so every web turn wiped conversation context.
//
// The fix: `api`/`webui` are local platforms whose answer already travels
// over the caller's own response channel (the HTTP body / WS frame). They
// must never be treated as "unknown" or routed to a push adapter.
// =========================================================================

/// A minimal push adapter used to prove that *real* platforms still route
/// through the adapter and that *unregistered* push platforms still throw.
final class StubAdapter: PlatformAdapter, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _sentCount = 0

    init(name: String) { self.name = name }

    var sentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sentCount
    }

    private func record() {
        lock.lock()
        defer { lock.unlock() }
        _sentCount += 1
    }

    func send(message: OutgoingMessage, to target: ChatTarget) async throws {
        record()
    }

    var incomingMessages: AsyncStream<IncomingMessage> {
        AsyncStream { $0.finish() }
    }

    func run() async throws {
        // No lifecycle work for the stub.
    }
}

// MARK: - Local platform handling (the regression)

@Test("send to 'api' platform does not throw when no adapter is registered")
func sendApiLocalNoThrow() async {
    let dm = DeliveryManager()
    let target = ChatTarget(platform: "api", chatID: "s1")
    let msg = OutgoingMessage(text: "hello from api")
    // Must NOT throw. Before the fix this threw `.unknownPlatform("api")`.
    await #expect(throws: Never.self) {
        try await dm.send(message: msg, to: target)
    }
}

@Test("send to 'webui' platform does not throw when no adapter is registered")
func sendWebUILocalNoThrow() async {
    let dm = DeliveryManager()
    let target = ChatTarget(platform: "webui", chatID: "s2")
    let msg = OutgoingMessage(text: "hello from webui")
    // Must NOT throw. Before the fix this threw `.unknownPlatform("webui")`.
    await #expect(throws: Never.self) {
        try await dm.send(message: msg, to: target)
    }
}

// MARK: - Push platforms still behave correctly

@Test("registered push platform still routes through its adapter")
func registeredPushRoutes() async {
    let dm = DeliveryManager()
    let stub = StubAdapter(name: "telegram")
    await dm.register(adapter: stub)
    let target = ChatTarget(platform: "telegram", chatID: "chat-99")
    let msg = OutgoingMessage(text: "ping")
    try? await dm.send(message: msg, to: target)
    #expect(stub.sentCount == 1)
}

@Test("unregistered push platform still throws unknownPlatform")
func unregisteredPushThrows() async {
    let dm = DeliveryManager()
    let stub = StubAdapter(name: "telegram")
    await dm.register(adapter: stub)
    // "discord" is NOT registered and is NOT a local platform.
    let target = ChatTarget(platform: "discord", chatID: "chan-1")
    let msg = OutgoingMessage(text: "should fail")
    do {
        try await dm.send(message: msg, to: target)
        // If it did NOT throw, the test fails.
        #expect(Bool(false), "expected unknownPlatform to be thrown for unregistered push platform")
    } catch let error as GatewayError {
        switch error {
        case .unknownPlatform(let p):
            #expect(p == "discord")
        default:
            #expect(Bool(false), "expected .unknownPlatform, got \(error)")
        }
    } catch {
        #expect(Bool(false), "expected GatewayError, got \(error)")
    }
}
