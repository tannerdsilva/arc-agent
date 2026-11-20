import Foundation
import Logging
import Synchronization
import Testing
@testable import ArcAgentCore

// ==========================================================================
// BoardDispatcher — the aux-model board loop. Covers the model (CardBoard,
// CardColumn), the board registry on the file store, archive semantics, the
// tool's board verbs + column-aware create, and the dispatcher's aux loop
// driven by a scripted mock LLM client.
// ==========================================================================

@Suite("CardBoard & CardColumn — model")
struct CardBoardModelTests {

    @Test("columns are the five fixed ones in order")
    func fixedColumns() {
        #expect(CardColumn.allCases.map(\.displayName) == ["Todo", "Ready", "Running", "Blocked", "Finished"])
        #expect(CardColumn(status: .done) == .finished)
        #expect(CardColumn(status: .running) == .running)
        #expect(CardColumn(status: .archived) == nil)
        #expect(CardColumn(status: .triage) == .blocked)
    }

    @Test("parse accepts display names and raw values")
    func parse() {
        #expect(CardColumn.parse("Finished") == .finished)
        #expect(CardColumn.parse("todo") == .todo)
        #expect(CardColumn.parse("nonsense") == nil)
    }

    @Test("board slugging and reserved ids")
    func slugs() {
        let board = CardBoard(name: "My Great Board!")
        #expect(board.id == "my-great-board")
        #expect(!CardBoard.isReserved("projects"))
        #expect(CardBoard.isReserved(CardBoard.standaloneID))
        #expect(CardBoard.isReserved("default"))
    }
}

@Suite("Board registry — FileCardStore")
struct CardBoardStoreTests {

    func makeStore() -> FileCardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("board-tests-\(UUID().uuidString)", isDirectory: true)
        return FileCardStore(arcHome: tmp)
    }

    @Test("create → list → remove round-trip; reserved guard")
    func registryRoundTrip() async throws {
        let store = makeStore()
        try await store.createBoard(CardBoard(name: "Projects", description: "ship it"))
        let boards = try await store.listBoards()
        #expect(boards.map(\.name).contains("Projects"))
        #expect(boards.contains { $0.id == CardBoard.standaloneID })
        // Reserved pool can't be registered or removed.
        await #expect(throws: (any Error).self) {
            try await store.createBoard(CardBoard(id: "default", name: "default"))
        }
        await #expect(throws: (any Error).self) { try await store.removeBoard(id: "default") }
        try await store.removeBoard(id: "projects")
        #expect(try await store.listBoards().filter { $0.id != CardBoard.standaloneID }.isEmpty)
    }

    @Test("deleteBoard purges card data and registry entry")
    func deletePurgesRegistry() async throws {
        let store = makeStore()
        try await store.createBoard(CardBoard(name: "Temp"))
        _ = try await store.createTask(CardTask(title: "t"), board: "temp")
        try await store.deleteBoard(board: "temp")
        #expect(try await store.listBoards().filter { $0.id != CardBoard.standaloneID }.isEmpty)
        #expect(try await store.listTasks(board: "temp", filter: CardListFilter(includeArchived: true)).isEmpty)
    }

    @Test("archiveTask: only settled cards archivable; done is the path")
    func archive() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        // Running cards can't be archived.
        var running = task
        running.status = .running
        try await store.saveTask(running, board: "default")
        await #expect(throws: (any Error).self) {
            try await store.archiveTask(id: task.id, board: "default")
        }
        // Done cards archive cleanly.
        var done = task
        done.status = .done
        try await store.saveTask(done, board: "default")
        let archived = try await store.archiveTask(id: task.id, board: "default")
        #expect(archived.status == .archived)
        #expect(archived.completedAt != nil)
    }
}

@Suite("KanbanTool — boards verbs & column-aware create")
struct KanbanBoardToolTests {

    /// Run the tool with a file store override and no env.
    func run(_ args: [String: Any], _ store: FileCardStore) async throws -> String {
        nonisolated(unsafe) let args = args
        let entry = KanbanTool.entry(storeOverride: store, envOverride: [:], dispatch: nil)
        return try await entry.handler(args)
    }

    @Test("boards create → boards list shows the registry")
    func boardsVerbs() async throws {
        let store = FileCardStore(arcHome: FileManager.default.temporaryDirectory
            .appendingPathComponent("boardtool-\(UUID().uuidString)", isDirectory: true))
        let out = try await run(["action": "boards", "board": "Side Quests", "name": "Side Quests"], store)
        #expect(out.contains("Created board"))
        let list = try await run(["action": "boards"], store)
        #expect(list.contains("Side Quests") )
    }

    @Test("create on a named board defaults to Todo; column override honored")
    func createColumnDefaults() async throws {
        let store = FileCardStore(arcHome: FileManager.default.temporaryDirectory
            .appendingPathComponent("boardtool-\(UUID().uuidString)", isDirectory: true))
        try await store.createBoard(CardBoard(name: "B"))
        _ = try await run(["action": "create", "title": "a", "board": "b"], store)
        let listed = try await store.listTasks(board: "b", filter: CardListFilter(includeArchived: true))
        #expect(listed.first?.status == .todo)
        _ = try await run(["action": "create", "title": "b", "board": "b", "column": "Blocked"], store)
        let listed2 = try await store.listTasks(board: "b", filter: CardListFilter(includeArchived: true))
        #expect(listed2.contains { $0.status == .blocked })
        // Standalone (default pool) keeps the .ready default.
        _ = try await run(["action": "create", "title": "c"], store)
        let standalone = try await store.listTasks(board: "default", filter: CardListFilter(includeArchived: true))
        #expect(standalone.contains { $0.status == .ready })
    }

    @Test("archive action flips a done card")
    func archiveAction() async throws {
        let store = FileCardStore(arcHome: FileManager.default.temporaryDirectory
            .appendingPathComponent("boardtool-\(UUID().uuidString)", isDirectory: true))
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        var done = task
        done.status = .done
        try await store.saveTask(done, board: "default")
        let out = try await run(["action": "archive", "task_id": task.id, "board": "default"], store)
        #expect(out.contains("archived") )
    }
}

/// Scripted LLM client: returns queued responses in order.
final class DispatcherMockClient: LLMClient, @unchecked Sendable {
    private let responses: [LLMResponse]
    private let index = Mutex(0)
    init(_ responses: [LLMResponse]) { self.responses = responses }
    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        let i = index.withLock { v -> Int in
            let old = v; v += 1; return old
        }
        return responses[min(i, responses.count - 1)]
    }
    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("BoardDispatcher — aux loop through the kanban tool")
struct BoardDispatcherTests {

    @Test("dispatcher dispatches a ready card and archives a finished one")
    func loop() async throws {
        let store = FileCardStore(arcHome: FileManager.default.temporaryDirectory
            .appendingPathComponent("disp-\(UUID().uuidString)", isDirectory: true))
        try await store.createBoard(CardBoard(name: "Auto"))
        let ready = try await store.createTask(CardTask(title: "echo hi"), board: "auto")
        var done = try await store.createTask(CardTask(title: "old goal"), board: "auto")
        done.status = .done
        try await store.saveTask(done, board: "auto")

        // Script: turn 1 = dispatch the ready card + archive the done one;
        // turn 2 = a plain report (no tool calls → loop ends).
        let idJSON = "\"\(ready.id)\""
        let call1 = LLMResponse(content: nil, toolCalls: [
            ToolCall(id: "t1", function: ToolCallFunction(name: "kanban",
                arguments: "{\"action\":\"run\",\"task_id\":\(idJSON),\"board\":\"auto\"}")),
            ToolCall(id: "t2", function: ToolCallFunction(name: "kanban",
                arguments: "{\"action\":\"archive\",\"task_id\":\"\(done.id)\",\"board\":\"auto\"}")),
        ])
        let final = LLMResponse(content: "Dispatched 1, archived 1.", toolCalls: nil)
        let client = DispatcherMockClient([call1, final])

        let spawned = Mutex<[String]>([])
        let dispatched = Mutex(false)
        let service = BoardDispatcherService(
            config: BoardDispatcherConfig(enabled: true, intervalSeconds: 3600),
            store: store,
            makeClient: { _ in client },
            runner: { prompt in
                spawned.withLock { $0.append(prompt) }
                dispatched.withLock { $0 = true }
                return "ok"
            },
            logger: Logger(label: "test"))

        // One tick, not run(): the loop would sleep for an hour.
        let outcomes = try await service.tick(client: client)
        let report = outcomes.map(\.report).joined(separator: " ")
        #expect(report.contains("Dispatched 1"))
        #expect(report.contains("archived 1"))
        // The runner gets the briefing asynchronously (fire-and-forget Task).
        for _ in 0..<100 where !dispatched.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dispatched.withLock { $0 })
        for _ in 0..<50 where spawned.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let prompt = spawned.withLock { $0.first } ?? ""
        #expect(prompt.contains(ready.id))
        // The archived card is archived.
        let check = try await store.getTask(id: done.id, board: "auto")
        #expect(check?.status == .archived)
    }

    @Test("no aux client → tick is a no-op")
    func noClient() async throws {
        let store = FileCardStore(arcHome: FileManager.default.temporaryDirectory
            .appendingPathComponent("disp-\(UUID().uuidString)", isDirectory: true))
        let service = BoardDispatcherService(
            config: BoardDispatcherConfig(enabled: true, intervalSeconds: 60),
            store: store,
            makeClient: { _ in nil },
            runner: { _ in "should not be called" },
            ownsHTTP: false,
            logger: Logger(label: "test"))
        let outcomes = try await service.tick(client: DispatcherMockClient([LLMResponse(content: "no action", toolCalls: nil)]))
        #expect(outcomes.isEmpty)
    }
}
