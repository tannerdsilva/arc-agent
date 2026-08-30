import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient
import NIOCore

// =========================================================================
// MARK: - Gateway HTTP Server (primary entry point)

@Suite("Gateway HTTP")
struct GatewayHTTPTests {

    /// Boot the real ``HTTPServerService`` on an ephemeral port and probe
    /// the primary entry points: health, web UI, and the chat API. This is
    /// the "every message flows through them" test for the HTTP layer.
    @Test("health, UI, and chat routes answer over real HTTP")
    func httpRoutesAnswer() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.shutdown() }

        let port = 18091
        let base = "http://127.0.0.1:\(port)"

        let server = HTTPServerService(
            config: .init(host: "127.0.0.1", port: port),
            onChat: { sessionID, message in
                "echo:\(sessionID):\(message)"
            },
            onUI: { mode in
                "<h1>ui-\(mode)</h1>"
            }
        )

        let task = Task { try? await server.run() }
        defer { task.cancel() }

        // Give the server its startup window before probing. A probe toward
        // a still-starting Hummingbird can burn its full timeout, so don't
        // tight-loop with short timeouts.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        var ready = false
        for _ in 0..<5 {
            do {
                let response = try await httpClient.execute(
                    HTTPClientRequest(url: base + "/health"),
                    timeout: .seconds(4)
                )
                if response.status.code == 200 {
                    ready = true
                    break
                }
            } catch {
                // not up yet
            }
        }
        #expect(ready, "gateway HTTP server did not become ready on port \(port)")

        // GET /health
        let health = try await httpClient.execute(
            HTTPClientRequest(url: base + "/health"),
            timeout: .seconds(2)
        )
        #expect(health.status.code == 200)

        // GET /ui — the web UI router, with the stub onUI closure
        let ui = try await httpClient.execute(
            HTTPClientRequest(url: base + "/ui"),
            timeout: .seconds(2)
        )
        let uiBody = try await ui.body.collect(upTo: 1_000_000)
        #expect(ui.status.code == 200)
        #expect(String(data: Data(buffer: uiBody), encoding: .utf8)?.contains("ui-chat") == true)

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
