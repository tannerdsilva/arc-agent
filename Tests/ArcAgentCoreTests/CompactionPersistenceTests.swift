import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient
import Synchronization

// =========================================================================
// MARK: - Compaction persistence
// =========================================================================

/// A compression pass rewrites the in-memory transcript. The append watermark
/// (`persistedMessageCount`) is positional, so it no longer describes a stored
/// prefix afterwards — the store must be rewritten with it, or every later
/// append silently does nothing.
extension ArcCoreTestRoot {
    @Suite("Compaction persistence", .serialized)
    struct CompactionPersistenceTests {

        private func tempStore() -> FileSessionStore {
            FileSessionStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("arc-compaction-persist-\(UUID().uuidString)")
            )
        }

        private func filler(_ tag: String, chars: Int) -> String {
            let unit = "alpha beta gamma delta epsilon zeta eta theta iota kappa. "
            var s = "\(tag) "
            while s.count < chars { s += unit }
            return String(s.prefix(chars))
        }

        private func seedHistory(exchanges: Int, charsEach: Int) -> [Message] {
            var seed: [Message] = []
            for i in 0..<exchanges {
                seed.append(Message(role: .user, content: filler("q\(i)", chars: charsEach)))
                seed.append(Message(role: .assistant, content: filler("a\(i)", chars: charsEach)))
            }
            return seed
        }

        private func makeAgent(
            store: any SessionStore,
            sessionID: String,
            registry: CompileTimeToolRegistry,
            httpClient: HTTPClient,
            client: any LLMClient
        ) async -> ArcAgent {
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: String(),
                registry: registry,
                sessionStore: store,
                skills: [],
                maxIterations: 6,
                maxTurnDuration: 30,
                persistSessions: true,
                approvalMode: .off,
                query: nil,
                maxContextTokens: 32_000,
                sessionID: sessionID,
                compressionBudget: 32_000,
                injectProjectContext: false,
                autoCompression: true
            )
            let agent = ArcAgent(config: config)
            await agent.setupClient(httpClient: httpClient)
            await agent.setClient(client)
            return agent
        }

        private func toolCallingClient() -> EventScriptClient {
            let call = ToolCallDelta(
                index: 0,
                id: "call_1",
                name: "read_file",
                arguments: #"{"path":"arc-does-not-exist.txt"}"#
            )
            return EventScriptClient(
                first: .init(toolCalls: [call]),
                final: .init(chunks: ["done"])
            )
        }

        @Test("compression does not stop later messages from persisting")
        func compactionKeepsPersisting() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let store = tempStore()
            let sid = "compaction-persist"
            try await store.create(Session(
                id: sid,
                model: "test-model",
                provider: "openai",
                messages: seedHistory(exchanges: 60, charsEach: 1_600),
                source: "daemon",
                workspaceKey: "/tmp/arc-workspace"
            ))

            let agent = await makeAgent(
                store: store, sessionID: sid,
                registry: try ArcAgentCore.testRegistry(),
                httpClient: httpClient, client: toolCallingClient()
            )
            for try await _ in agent.streamTurn(message: "hello") {}

            let stored = try #require(try await store.get(id: sid))
            // the compression summary landed...
            #expect(stored.messages.contains { ($0.content ?? "").hasPrefix(ArcAgent.compressionSummaryPrefix) },
                "the compressed transcript was never written to the store")
            // ...and the turn's final answer landed after it
            #expect(stored.messages.contains { $0.role == .assistant && $0.content == "done" },
                "messages produced after the compression were not persisted")
            // the rewrite preserved session metadata
            #expect(stored.source == "daemon")
            #expect(stored.workspaceKey == "/tmp/arc-workspace")
        }

        @Test("a failed rewrite retries before later appends")
        func failedRewriteRetriesOnNextPersist() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let inner = tempStore()
            let store = FailingUpdateStore(inner: inner, failures: 2)
            let sid = "compaction-retry"
            try await store.create(Session(
                id: sid,
                model: "test-model",
                provider: "openai",
                messages: seedHistory(exchanges: 60, charsEach: 1_600)
            ))

            let client = toolCallingClient()
            let agent = await makeAgent(
                store: store, sessionID: sid,
                registry: try ArcAgentCore.testRegistry(),
                httpClient: httpClient, client: client
            )
            // turn 1: compression fires; the store rewrite fails once
            for try await _ in agent.streamTurn(message: "first") {}
            // turn 2: the pending rewrite is retried before anything appends
            for try await _ in agent.streamTurn(message: "second") {}

            let stored = try #require(try await inner.get(id: sid))
            #expect(stored.messages.contains { ($0.content ?? "").hasPrefix(ArcAgent.compressionSummaryPrefix) },
                "the retried rewrite never landed")
            // Both turns' work is present exactly once — the retry rewrote,
            // it did not append against a stale watermark.
            #expect(stored.messages.filter { $0.role == .user && $0.content == "first" }.count == 1)
            #expect(stored.messages.filter { $0.role == .user && $0.content == "second" }.count == 1)
            #expect(stored.messages.filter { $0.role == .assistant && $0.content == "done" }.count == 2,
                "the turns after the failed rewrite were lost or duplicated")
        }
    }
}

/// A session store whose `update` path fails a fixed number of times.
///
/// The failures stand in for a relay/disk error during the post-compression
/// rewrite; once spent, everything delegates to the file store.
final class FailingUpdateStore: SessionStore, @unchecked Sendable {
    private let inner: FileSessionStore
    private let remaining: Mutex<Int>

    init(inner: FileSessionStore, failures: Int) {
        self.inner = inner
        self.remaining = Mutex(failures)
    }

    func create(_ session: Session) async throws {
        try await inner.create(session)
    }

    func get(id: String) async throws -> Session? {
        try await inner.get(id: id)
    }

    func update(_ session: Session) async throws {
        let shouldFail = remaining.withLock { count -> Bool in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        if shouldFail { throw SessionError.storageError("injected update failure") }
        try await inner.update(session)
    }

    func delete(id: String) async throws {
        try await inner.delete(id: id)
    }

    func list(limit: Int, offset: Int) async throws -> [Session] {
        try await inner.list(limit: limit, offset: offset)
    }

    func appendMessage(sessionID: String, message: Message) async throws {
        try await inner.appendMessage(sessionID: sessionID, message: message)
    }
}
