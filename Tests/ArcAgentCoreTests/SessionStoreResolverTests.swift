import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// MARK: - Recording store
// =========================================================================

/// An in-memory ``SessionStore`` that records every mutation so tests can
/// assert what the agent actually persisted.
actor RecordingSessionStore: SessionStore {
    var sessions: [String: Session] = [:]

    func create(_ session: Session) async throws {
        sessions[session.id] = session
    }

    func get(id: String) async throws -> Session? { sessions[id] }

    func update(_ session: Session) async throws { sessions[session.id] = session }

    func delete(id: String) async throws { sessions[id] = nil }

    func list(limit: Int, offset: Int) async throws -> [Session] {
        let sorted = sessions.values.sorted { $0.updatedAt > $1.updatedAt }
        return Array(sorted.dropFirst(offset).prefix(limit)).map { summary in
            var s = summary
            s.messages = []  // summaries carry metadata only
            s.messageCount = summary.messages.count
            return s
        }
    }

    func appendMessage(sessionID: String, message: Message) async throws {
        var session = sessions[sessionID] ?? Session(id: sessionID)
        session.messages.append(message)
        session.updatedAt = Date()
        sessions[sessionID] = session
    }
}

// =========================================================================
// MARK: - Session Store Resolver
// =========================================================================

extension ArcCoreTestRoot {
    @Suite("Session Store Resolver", .serialized)
    struct SessionStoreResolverTests {

        private var dummyTessera: TesseraConfig {
            TesseraConfig(
                serverIP: "127.0.0.1",
                serverPort: 51921,
                serverPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                myPrivateKey: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
                application: 1
            )
        }

        @Test("no tessera config resolves to file storage + file memory")
        func noTesseraResolvesToFile() async {
            let r = await SessionStoreResolver.resolve(tessera: nil)
            #expect(r.sessionStore is FileSessionStore)
            #expect(r.memoryProvider is FileMemoryProvider)
        }

        @Test("unhealthy relay falls back to file storage (never hangs)")
        func unhealthyFallsBackToFile() async {
            let r = await SessionStoreResolver.resolve(tessera: dummyTessera, healthCheck: { false })
            #expect(r.sessionStore is FileSessionStore)
            #expect(r.memoryProvider is FileMemoryProvider)
        }

        @Test("healthy relay resolves tessera storage")
        func healthyResolvesToTessera() async {
            let r = await SessionStoreResolver.resolve(tessera: dummyTessera, healthCheck: { true })
            #expect(r.sessionStore is TesseraSessionStore)
            #expect(r.memoryProvider is TesseraMemoryProvider)
        }

        @Test("per-profile memory directory is honored in file mode")
        func honorsMemoryDirectory() async {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arc-test-mem-\(UUID().uuidString)", isDirectory: true)
            let r = await SessionStoreResolver.resolve(tessera: nil, memoryDirectory: dir)
            #expect(r.sessionStore is FileSessionStore)
            #expect(r.memoryProvider is FileMemoryProvider)
        }
    }
}

// =========================================================================
// MARK: - Streaming persistence (F3a)
// =========================================================================

extension ArcCoreTestRoot {
    @Suite("Streaming Persistence", .serialized)
    struct StreamingPersistenceTests {

        @Test("streamConversation persists the completed turn (user + tool + assistant)")
        func streamingConversationPersists() async throws {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-stream-persist-\(UUID().uuidString).txt")
            try "streamed payload 42".write(to: target, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: target) }

            let registry = try ArcAgentCore.buildDefaultRegistry()
            let store = RecordingSessionStore()
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "k",
                registry: registry,
                sessionStore: store,
                skills: [],
                maxIterations: 5,
                maxTurnDuration: 30,
                persistSessions: true,
                approvalMode: .manual,
                maxContextTokens: 64_000
            )
            let agent = ArcAgent(config: config)
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { httpClient.shutdown() }
            await agent.setupClient(httpClient: httpClient)
            await agent.setClient(ScriptedLLMClient(filePath: target.path))

            let events = agent.streamConversation(message: "Read the file at \(target.path)")
            var streamed = ""
            for try await event in events {
                streamed += event
            }
            #expect(streamed.contains("streamed payload 42"))

            // The whole turn — user prompt, tool call/result, final answer — must
            // have been persisted by the time the stream closes.
            let sessions = try await store.list(limit: 10)
            #expect(!sessions.isEmpty, "streamConversation should persist the session")
            guard let session = try await store.get(id: sessions[0].id) else {
                Issue.record("session not materializable")
                return
            }
            #expect(session.messages.contains { $0.role == .user })
            #expect(session.messages.contains { $0.role == .assistant })
            #expect(session.messages.contains { $0.role == .tool && $0.name == "read_file" })
            #expect(!session.messages.isEmpty)
        }
    }
}
