import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient
import NIOCore

// =========================================================================
// MARK: - Gateway HTTP Server (primary entry point)

@Suite("Gateway HTTP")
struct GatewayHTTPTests {

    /// Boot the real ``HTTPServerService`` and probe the REST entry points:
    /// health and the chat API. This is the "every message flows through them"
    /// test for the HTTP layer. The web UI is served by `WebUIHost`, a sibling
    /// service in the daemon, not here.
    ///
    /// Binds a random high port per attempt and retries a bounded number of
    /// times: a fixed port is red whenever a live `arc serve` (or a parallel
    /// run) holds it — the suite went red while a daemon occupied 18091.
    @Test("health and chat routes answer over real HTTP")
    func httpRoutesAnswer() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown() }

        var serverTask: Task<Void, Never>?
        defer { serverTask?.cancel() }

        var readyBase: String?
        var lastPort = 0
        for _ in 0..<3 {
            let port = Int.random(in: 20_100...29_900)
            lastPort = port
            let base = "http://127.0.0.1:\(port)"

            let server = HTTPServerService(
                config: .init(host: "127.0.0.1", port: port),
                onChat: { sessionID, message in
                    "echo:\(sessionID):\(message)"
                }
            )
            serverTask = Task { try? await server.run() }

            // Give the server its startup window before probing. A probe toward
            // a still-starting Hummingbird can burn its full timeout, so don't
            // tight-loop with short timeouts.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var ready = false
            for _ in 0..<5 {
                do {
                    let response = try await httpClient.execute(
                        HTTPClientRequest(url: base + "/health"),
                        timeout: .seconds(2)
                    )
                    if response.status.code == 200 {
                        ready = true
                        break
                    }
                } catch {
                    // not up yet (or the port was taken before bind)
                }
            }
            if ready {
                readyBase = base
                break
            }
            // Port collision: stop this attempt before trying the next draw.
            serverTask?.cancel()
            serverTask = nil
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let base = try #require(readyBase, "gateway HTTP server did not become ready on any tried port (last \(lastPort))")

        // GET /health
        let health = try await httpClient.execute(
            HTTPClientRequest(url: base + "/health"),
            timeout: .seconds(2)
        )
        #expect(health.status.code == 200)

        // POST /v1/chat — the chokepoint through which every message flows
        var chatRequest = HTTPClientRequest(url: base + "/v1/chat")
        chatRequest.method = .POST
        chatRequest.headers.add(name: "Content-Type", value: "application/json")
        chatRequest.body = .bytes(ByteBuffer(string: #"{"session_id":"s1","message":"hello"}"#))

        let chat = try await httpClient.execute(chatRequest, timeout: .seconds(2))
        let chatBody = try await chat.body.collect(upTo: 1_000_000)
        #expect(chat.status.code == 200)

        let json = try JSONSerialization.jsonObject(with: Data(buffer: chatBody)) as? [String: Any]
        #expect(json?["response"] as? String == "echo:s1:hello",
            "expected the onChat response to flow through /v1/chat, got: \(String(data: Data(buffer: chatBody), encoding: .utf8) ?? "?")")
    }
}
