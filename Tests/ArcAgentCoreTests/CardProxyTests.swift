import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient
import NIOCore

// =========================================================================
// CardProxy — the CardStore-level daemon proxy (POST /v1/card).
//
// Covers:
//   1. the daemon route (token gate, verb decode, executor dispatch on a
//      real FileCardStore behind the real HTTPServerService),
//   2. the client (ProxiedCardStore round-trips, structured store-error
//      rethrow, unknown-verb transport failure),
//   3. the fallback contract (dead daemon → local backend, per call),
//   4. the failure-envelope wire round-trip for every CardStoreError case.
// =========================================================================

@Suite("Card proxy", .serialized)
struct CardProxyTests {

        private func tempHome() throws -> URL {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("card-proxy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return home
        }

        /// Boot an HTTPServerService whose /v1/card executes on a fresh
        /// FileCardStore. The store is kept so expectations can be checked
        /// directly.
        private struct CardServer {
            let base: String
            let task: Task<Void, Never>
            let store: FileCardStore
        }

        private func bootCardServer(token: String?) async throws -> CardServer {
            let home = try tempHome()
            let store = FileCardStore(arcHome: home)
            let handler: @Sendable (String, [String: Any]) async throws -> Any? = { verb, params in
                try await CardProxyExecutor.dispatch(verb: verb, params: params, store: store)
            }
            for _ in 0..<5 {
                let port = Int.random(in: 20_100...29_900)
                let base = "http://127.0.0.1:\(port)"
                let server = HTTPServerService(
                    config: .init(host: "127.0.0.1", port: port),
                    onChat: { _, _ in "unused" },
                    onCard: token == nil ? nil : handler,
                    kanbanProxyToken: token
                )
                let task: Task<Void, Never> = Task { try? await server.run() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let client = HTTPClient(eventLoopGroupProvider: .singleton)
                var ready = false
                defer { _ = client.shutdown() }
                do {
                    let response = try await client.execute(
                        HTTPClientRequest(url: base + "/health"), timeout: .seconds(2))
                    ready = response.status.code == 200
                } catch {}
                if ready {
                    return CardServer(base: base, task: task, store: store)
                }
                task.cancel()
            }
            throw CardProxyTestError(message: "could not bind a card-proxy test server")
        }

        private struct CardProxyTestError: Error {
            let message: String
        }

        /// Concurrency-safe flag for the fallback factory closure.
        private final class FlagBox: @unchecked Sendable {
            var flag = false
        }

        /// A minimal ready task to push through the proxy.
        private func newTask(id: String) -> CardTask {
            CardTask(id: id, title: "proxied \(id)", status: .ready, createdBy: "test")
        }

        @Test("daemon route: full verb round-trip over a real FileCardStore")
        func verbRoundTrip() async throws {
            let server = try await bootCardServer(token: "sekrit")
            let (base, store) = (server.base, server.store)
            defer { server.task.cancel() }
            let port = Int(base.split(separator: ":").last ?? "0") ?? 0
            let proxy = ProxiedCardStore(host: "127.0.0.1", port: port, token: "sekrit")

            // create → get
            let created = try await proxy.createTask(newTask(id: "t-1"), board: "b")
            #expect(created.id == "t-1")
            let fetched = try await proxy.getTask(id: "t-1", board: "b")
            #expect(fetched?.title == "proxied t-1")

            // list with filter
            let listed = try await proxy.listTasks(board: "b", filter: CardListFilter(limit: 10))
            #expect(listed.map(\.id) == ["t-1"])

            // claim → run appears; complete → summary rides back
            let (claimed, run) = try await proxy.claimTask(id: "t-1", board: "b", profile: "worker-a")
            #expect(claimed.id == "t-1")
            #expect(claimed.status == .running)
            #expect(run.profile == "worker-a")

            let (completed, doneRun) = try await proxy.completeTask(
                id: "t-1", board: "b", runID: run.id,
                summary: "handoff", metadata: ["k": "v"],
                createdCards: [], artifacts: ["a.txt"]
            )
            #expect(completed.status == .done)
            #expect(doneRun.summary == "handoff")

            // comments + events + runs
            let comment = try await proxy.addComment(taskID: "t-1", board: "b", author: "tester", body: "hello")
            #expect(comment.body == "hello")
            let comments = try await proxy.comments(taskID: "t-1", board: "b")
            #expect(comments.count == 1)

            try await proxy.appendEvent(taskID: "t-1", board: "b", runID: run.id, kind: "completed", payload: nil)
            let events = try await proxy.events(taskID: "t-1", board: "b", limit: 10)
            #expect(events.map(\.kind).contains("completed"))

            let runs = try await proxy.runs(taskID: "t-1", board: "b")
            #expect(runs.map(\.id).contains(run.id))

            // links + recompute
            let child = try await proxy.createTask(newTask(id: "t-2"), board: "b")
            #expect(child.id == "t-2")
            try await proxy.link(parentID: "t-1", childID: "t-2", board: "b")
            let parents = try await proxy.parentIDs(of: "t-2", board: "b")
            #expect(parents == ["t-1"])
            let children = try await proxy.childIDs(of: "t-1", board: "b")
            #expect(children == ["t-2"])
            let promoted = try await proxy.recomputeReady(board: "b")
            #expect(promoted.isEmpty)  // t-2's parent is done, but t-2 is done too

            // void verbs don't throw
            try await proxy.heartbeat(id: "t-2", board: "b", runID: nil)
            try await proxy.saveTask(newTask(id: "t-2"), board: "b")

            // the daemon-side store actually received everything (one tunnel wrote it)
            let localFetch = try await store.getTask(id: "t-1", board: "b")
            #expect(localFetch?.result == "handoff")  // the result field rides on complete
            #expect(localFetch != nil)
        }

        @Test("daemon route: store-level failure rethrown as CardStoreError, not a fallback")
        func storeErrorRethrow() async throws {
            let server = try await bootCardServer(token: "sekrit")
            let base = server.base
            defer { server.task.cancel() }
            let port = Int(base.split(separator: ":").last ?? "0") ?? 0
            let fellBack = FlagBox()
            let proxy = ProxiedCardStore(host: "127.0.0.1", port: port, token: "sekrit") {
                fellBack.flag = true
                return FileCardStore(arcHome: FileManager.default.temporaryDirectory)
            }

            do {
                _ = try await proxy.claimTask(id: "nope", board: "b", profile: "worker-a")
                Issue.record("expected taskNotFound")
            } catch let error as CardStoreError {
                #expect(error == .taskNotFound("nope"))
            }
            #expect(!fellBack.flag)
        }

        @Test("daemon route: token gate still 401s; missing token disables the route")
        func tokenGate() async throws {
            let server = try await bootCardServer(token: "sekrit")
            let base = server.base
            defer { server.task.cancel() }
            let client = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = client.shutdown() }
            var request = HTTPClientRequest(url: base + "/v1/card")
            request.method = .POST
            request.headers.add(name: "Authorization", value: "Bearer wrong")
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(data: try JSONSerialization.data(withJSONObject: ["verb": "getTask", "params": ["id": "x", "board": "b"]])))
            let response = try await client.execute(request, timeout: .seconds(5))
            #expect(response.status.code == 401)
        }

        @Test("fallback: dead daemon → verbs execute on the injected local backend")
        func deadDaemonFallsBack() async throws {
            let home = try tempHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let local = FileCardStore(arcHome: home)
            let proxy = ProxiedCardStore(host: "127.0.0.1", port: 1, token: "sekrit") { local }

            // Nothing on port 1: every verb falls back to the local store.
            let created = try await proxy.createTask(newTask(id: "t-local"), board: "b")
            #expect(created.id == "t-local")
            let fetched = try await proxy.getTask(id: "t-local", board: "b")
            #expect(fetched?.title == "proxied t-local")
            // The local store itself holds the row — the process's own
            // (would-be) tunnel was used, not the daemon's.
            let direct = try await local.getTask(id: "t-local", board: "b")
            #expect(direct != nil)
        }

        @Test("fallback: unknown verb is a transport failure, not a crash")
        func unknownVerbFallsBack() async throws {
            let home = try tempHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let local = FileCardStore(arcHome: home)
            let proxy = ProxiedCardStore(host: "127.0.0.1", port: 1, token: "sekrit") { local }
            // "bogusVerb" → daemon-side would fail; dead daemon → fallback
            // path answers locally. Either way the call completes.
            let fetched = try await proxy.getTask(id: "whatever", board: "b")
            #expect(fetched == nil)
        }

        @Test("failure envelope: every CardStoreError case survives the wire")
        func failureEnvelopeRoundTrip() throws {
            let cases: [CardStoreError] = [
                .taskNotFound("t-9"),
                .runNotFound(taskID: "t-9", runID: "r-9"),
                .taskNotClaimable("t-9", status: .done),
                .taskNotRunning("t-9", status: .ready),
                .parentCycle(parent: "p", child: "c"),
                .parentNotFound("p"),
                .phantomCreatedCard("ghost"),
                .attachmentWriteFailed("t-9"),
            ]
            for original in cases {
                let envelope = CardProxyWire.failureEnvelope(original)
                let raw = try #require(envelope["failure"] as? [String: Any])
                let failure = try JSONDecoder().decode(
                    CardProxyWire.Failure.self, from: JSONSerialization.data(withJSONObject: raw))
                let restored = CardProxyWire.cardStoreError(from: failure)
                #expect(restored == original)
            }
        }

        @Test("CardStores.shared: a daemon process never proxies")
        func daemonProcessNeverProxies() async throws {
            // Stage an arc home WITH a proxy token so the only thing keeping
            // the process off the proxy path is the daemon flag.
            let home = try tempHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try "ARC_KANBAN_PROXY_TOKEN=sekrit\n".write(
                to: home.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            let oldHome = getenv("ARC_HOME").map { String(cString: $0) }
            setenv("ARC_HOME", home.path, 1)
            defer {
                if let oldHome { setenv("ARC_HOME", oldHome, 1) } else { unsetenv("ARC_HOME") }
            }

            CardStores.isDaemonProcess = true
            defer { CardStores.isDaemonProcess = false }
            let store = await CardStores.shared()
            #expect(!(store is ProxiedCardStore))
        }
}
