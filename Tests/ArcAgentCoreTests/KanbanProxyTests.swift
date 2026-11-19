import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient
import NIOCore

// =========================================================================
// KanbanProxy — the worker→daemon card-write proxy.
//
// Covers three layers:
//   1. the daemon route (`POST /v1/kanban` over the real HTTPServerService:
//      token gate, payload decode, handler execution),
//   2. the client (`KanbanProxy.resolve` against a temp arc home,
//      `forward` round-trip and failure→nil),
//   3. the tool seam (`KanbanTool.handle` proxies in worker sessions and
//      falls back to the local store when the daemon is unreachable).
// =========================================================================

extension ArcCoreTestRoot {
    @Suite("Kanban proxy", .serialized)
    struct KanbanProxyTests {

        /// Spawn a proxy-capable HTTPServerService on a fixed port.
        private func spawnProxyServer(
            port: Int,
            token: String?,
            handler: @escaping @Sendable ([String: Any], [String: String]) async throws -> String
        ) -> Task<Void, Never> {
            let server = HTTPServerService(
                config: .init(host: "127.0.0.1", port: port),
                onChat: { _, _ in "unused" },
                onKanban: token == nil ? nil : handler,
                kanbanProxyToken: token
            )
            return Task { try? await server.run() }
        }

        /// True when /health answers on base.
        private func probeReady(_ base: String) async -> Bool {
            let client = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = client.shutdown() }
            do {
                let response = try await client.execute(
                    HTTPClientRequest(url: base + "/health"), timeout: .seconds(2))
                return response.status.code == 200
            } catch { return false }
        }

        /// Boot on a random high port, retrying on collisions. Caller cancels
        /// the returned task.
        private func bootProxyServer(
            token: String?,
            handler: @escaping @Sendable ([String: Any], [String: String]) async throws -> String
        ) async -> (String, Task<Void, Never>) {
            for _ in 0..<5 {
                let port = Int.random(in: 20_100...29_900)
                let base = "http://127.0.0.1:\(port)"
                let task = spawnProxyServer(port: port, token: token, handler: handler)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await probeReady(base) { return (base, task) }
                task.cancel()
            }
            fatalError("could not bind a proxy test server")
        }

        private func post(
            _ url: String,
            token: String?,
            body: [String: Any]
        ) async -> HTTPClientResponse {
            let client = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = client.shutdown() }
            var request = HTTPClientRequest(url: url)
            request.method = .POST
            if let token { request.headers.add(name: "Authorization", value: "Bearer \(token)") }
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(data: try! JSONSerialization.data(withJSONObject: body)))
            return try! await client.execute(request, timeout: .seconds(5))
        }

        @Test("proxy route: token gate, decode, handler execution")
        func proxyRouteRoundTrip() async throws {
            let (base, task) = await bootProxyServer(token: "sekrit") { (args: [String: Any], env: [String: String]) async throws -> String in
                "did:\(args["action"] as? String ?? "?"):\(env["ARC_KANBAN_TASK_ID"] ?? "-")"
            }
            defer { task.cancel() }

            // No token → 401.
            var response = await post(base + "/v1/kanban", token: nil, body: ["args": ["action": "list"]])
            #expect(response.status.code == 401)

            // Wrong token → 401.
            response = await post(base + "/v1/kanban", token: "wrong", body: ["args": ["action": "list"]])
            #expect(response.status.code == 401)

            // Missing args → 400.
            response = await post(base + "/v1/kanban", token: "sekrit", body: ["nope": 1])
            #expect(response.status.code == 400)

            // Happy path: handler runs with args + env.
            response = await post(
                base + "/v1/kanban", token: "sekrit",
                body: ["args": ["action": "list"], "env": ["ARC_KANBAN_TASK_ID": "t-1"]]
            )
            #expect(response.status.code == 200)
            let data = try await response.body.collect(upTo: 64 * 1024)
            let decoded = try #require(JSONSerialization.jsonObject(with: Data(buffer: data)) as? [String: Any])
            #expect(decoded["output"] as? String == "did:list:t-1")
        }

        @Test("proxy route absent without token/handler config")
        func proxyRouteAbsentWithoutConfig() async throws {
            let client = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = client.shutdown() }
            var serverTask: Task<Void, Never>?
            defer { serverTask?.cancel() }
            var bound: String?
            for _ in 0..<3 {
                let port = Int.random(in: 20_100...29_900)
                let base = "http://127.0.0.1:\(port)"
                let server = HTTPServerService(
                    config: .init(host: "127.0.0.1", port: port),
                    onChat: { _, _ in "unused" }
                )
                serverTask = Task { try? await server.run() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do {
                    let response = try await client.execute(
                        HTTPClientRequest(url: base + "/health"), timeout: .seconds(2))
                    if response.status.code == 200 { bound = base; break }
                } catch {}
                serverTask?.cancel()
                serverTask = nil
            }
            let base = try #require(bound, "server did not bind")
            let response = await post(base + "/v1/kanban", token: "x", body: ["args": ["action": "list"]])
            // No route registered → router 404/405, not 200.
            #expect(response.status.code != 200)
        }

        @Test("resolve reads daemon.json api block, env overrides, .env token")
        func resolveFromArcHome() throws {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("kanban-proxy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }

            // No token yet → nil.
            #expect(KanbanProxy.resolve(arcHome: home, environment: [:]) == nil)

            try "ARC_KANBAN_PROXY_TOKEN=tok\n".write(to: home.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            try #"{"api": {"enabled": false, "port": 9999}}"#.write(to: home.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)
            // api disabled → nil even with token.
            #expect(KanbanProxy.resolve(arcHome: home, environment: [:]) == nil)

            try #"{"api": {"enabled": true, "host": "127.0.0.1", "port": 9123}}"#
                .write(to: home.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)
            let proxy = try #require(KanbanProxy.resolve(arcHome: home, environment: [:]))
            #expect(proxy.port == 9123)
            #expect(proxy.token == "tok")

            // Env override wins over daemon.json.
            let overridden = try #require(KanbanProxy.resolve(arcHome: home, environment: ["API_PORT": "9999"]))
            #expect(overridden.port == 9999)
        }

        @Test("forward round-trips and returns nil on transport failure")
        func forwardRoundTripAndFallback() async throws {
            let (base, task) = await bootProxyServer(token: "sekrit") { (args: [String: Any], _: [String: String]) async throws -> String in
                "ok:\(args["action"] as? String ?? "?")"
            }
            defer { task.cancel() }

            let port = Int(base.split(separator: ":").last ?? "0") ?? 0
            let proxy = KanbanProxy(host: "127.0.0.1", port: port, token: "sekrit")
            let output = await proxy.forward(args: ["action": "list"], env: [:])
            #expect(output == "ok:list")

            // Dead endpoint → nil (fallback signal), not a throw.
            let dead = KanbanProxy(host: "127.0.0.1", port: 1, token: "sekrit")
            #expect(await dead.forward(args: ["action": "list"], env: [:]) == nil)
        }

        @Test("tool handle: worker sessions proxy; failures fall back to local store")
        func toolHandleProxyAndFallback() async throws {
            let (base, task) = await bootProxyServer(token: "sekrit") { (args: [String: Any], _: [String: String]) async throws -> String in
                // Simulate the daemon executing with its own store.
                "proxied:\(args["action"] as? String ?? "?")"
            }
            defer { task.cancel() }

            let port = Int(base.split(separator: ":").last ?? "0") ?? 0

            // Point resolve() at the test server by hand: the tool seam goes
            // through KanbanProxy.resolve(), which reads the arc home —
            // so stage a temp home instead of touching the real one.
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("kanban-proxy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            try "ARC_KANBAN_PROXY_TOKEN=sekrit\n".write(
                to: home.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            // The tool seam calls resolve() with the process env; the only
            // injectable knob is ARC_HOME — set it, run, restore.
            let oldHome = getenv("ARC_HOME").map { String(cString: $0) }
            setenv("ARC_HOME", home.path, 1)
            defer {
                if let oldHome { setenv("ARC_HOME", oldHome, 1) } else { unsetenv("ARC_HOME") }
            }
            // daemon.json must point at the test server.
            try #"{"api": {"enabled": true, "port": \#(port)}}"#
                .write(to: home.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)

            let workerEnv = [CardWorker.taskIDKey: "t-1", CardWorker.runIDKey: "r-1"]
            let output = try await KanbanTool.handle(
                args: ["action": "list"],
                box: .init(envOverride: workerEnv)
            )
            #expect(output == "proxied:list")

            // Non-worker env (no task id) never proxies, even with the daemon up.
            let orchestratorOutput = try await KanbanTool.handle(
                args: ["action": "list"],
                box: .init(envOverride: [:])
            )
            #expect(orchestratorOutput != "proxied:list")

            // Daemon down → local fallback (file store answers, no crash).
            try #"{"api": {"enabled": true, "port": 1}}"#
                .write(to: home.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)
            let fallback = try await KanbanTool.handle(
                args: ["action": "list"],
                box: .init(envOverride: workerEnv)
            )
            #expect(!fallback.contains("proxied:"))
        }
    }
}
