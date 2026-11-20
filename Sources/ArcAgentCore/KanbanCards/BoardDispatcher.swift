import AsyncHTTPClient
import Foundation
import Logging
import ServiceLifecycle

// ==========================================================================
// BoardDispatcher — the aux-model board loop (Hermes-parity structure,
// aux-model brain).
//
// Like the reference agent's gateway-embedded kanban dispatcher, this is a
// lifecycle `Service` that ticks on an interval and dispatches ready work.
// The difference (deliberate): the per-tick decisions are made by the
// auxiliary `board_dispatcher` model, which sees the whole board — every
// card in every column, run summaries, block reasons — and acts *only
// through the `kanban` tool*:
//
//   1. Dispatch — `action: run` claims and spawns a worker for ready cards.
//   2. Follow-up — after reading completed cards' handoff summaries, it may
//      `action: create` new cards on the board to continue a goal.
//   3. Cleanup — fully complete cards with no further use are
//      `action: archive`d off the columns into the Completed tab.
//
// The dispatcher never edits board state directly: every mutation rides
// the same tool surface the agent and workers use, so the web UI's
// read-only view and the store's event log stay authoritative.
// ==========================================================================

/// One tick's outcome, for logging and tests.
public struct BoardDispatchOutcome: Sendable, Equatable {
    public var board: String
    public var toolCalls: Int
    public var report: String
}

/// The aux-model board dispatcher. Long-lived → a `Service` (Second Law).
public final class BoardDispatcherService: Service, Sendable {

    public let config: BoardDispatcherConfig
    private let store: any CardStore
    private let logger: Logger
    /// Builds the tick's aux client from the HTTP stack the service owns.
    /// nil return → tick skipped (no aux model configured).
    private let makeClient: @Sendable (HTTPClient) async throws -> (any LLMClient)?
    /// In-process worker runner handed to the kanban tool's `run` action
    /// (the daemon's one-shot path — no new tunnel, ever).
    private let runner: @Sendable (String) async throws -> String
    /// Creates the HTTP stack. The service owns its full lifetime: created
    /// on run() entry, shut down on run() exit — never leaked, never
    /// detached, and never created if the service never runs.
    private let makeHTTP: @Sendable () -> HTTPClient
    /// False in tests: the injected mock client needs no HTTP stack.
    private let ownsHTTP: Bool

    public init(
        config: BoardDispatcherConfig,
        store: any CardStore,
        makeClient: @escaping @Sendable (HTTPClient) async throws -> (any LLMClient)?,
        runner: @escaping @Sendable (String) async throws -> String,
        makeHTTP: @escaping @Sendable () -> HTTPClient = { HTTPClient(eventLoopGroupProvider: .singleton) },
        ownsHTTP: Bool = true,
        logger: Logger
    ) {
        self.config = config
        self.store = store
        self.makeClient = makeClient
        self.runner = runner
        self.makeHTTP = makeHTTP
        self.ownsHTTP = ownsHTTP
        self.logger = logger
    }

    public func run() async throws {
        let http = ownsHTTP ? makeHTTP() : HTTPClient(eventLoopGroupProvider: .singleton)
        // The service created it; the service shuts it down — awaited inline
        // on EVERY exit path below (never deferred into an unstructured task).
        logger.info("board dispatcher started (interval \(config.intervalSeconds)s, boards watched each tick)")
        while !Task.isCancelled {
            do {
                let client = try await makeClient(http)
                if let client {
                    let outcomes = try await tick(client: client)
                    for outcome in outcomes where !outcome.report.isEmpty {
                        logger.info("board \(outcome.board): \(outcome.report)")
                    }
                } else {
                    logger.info("board dispatcher: no aux model configured — tick skipped")
                }
            } catch is CancellationError {
                break
            } catch {
                // A failed tick must never kill the service — the next
                // interval retries (transient relay/model errors are the
                // expected case, and the loop is the recovery).
                logger.warning("board dispatcher tick failed: \(error.localizedDescription)")
            }
            do { try await Task.sleep(for: .seconds(config.intervalSeconds)) }
            catch { break } // cancelled mid-sleep → exit the loop, shutdown below
        }
        try? await http.shutdown()
    }

    /// One pass over every registered board. Public for tests.
    public func tick(client: any LLMClient) async throws -> [BoardDispatchOutcome] {
        let boards = try await store.listBoards().filter { $0.id != CardBoard.standaloneID }
        var outcomes: [BoardDispatchOutcome] = []
        for board in boards {
            let digest = try await Self.boardDigest(store: store, board: board.id)
            let outcome = try await Self.dispatchBoard(
                board: board.id, digest: digest,
                client: client, store: store, runner: runner,
                maxIterations: config.maxIterations)
            outcomes.append(outcome)
        }
        return outcomes
    }

    // MARK: Prompting

    static func systemPrompt() -> String {
        """
        You are the kanban board dispatcher. You manage boards through the `kanban` tool ONLY — it is your single capability. The board has one lane and five fixed columns: Todo, Ready, Running, Blocked, Finished.

        Your three duties, in priority order:
        1. DISPATCH. Cards in the Ready column are dispatchable: dispatch each with action "run" (pass task_id and board). A card sitting in Todo with no blockers that should run now: move it to Ready first (action "move", task_id, column "Ready"), then run it. Running/Blocked/Finished cards are already in flight or settled — leave them.
        2. CONTINUE GOALS. Read cards that just reached Finished (their run summaries carry the handoff). If a card's overall goal is not fully achieved, create follow-up cards on the same board with action "create" — title, body (the remaining work), board, and priority. Keep the set minimal; do not duplicate existing cards. Pass "created_cards" ids only from worker completions, never invent ids.
        3. CLEAN UP. A card that is fully complete with no remaining purpose (nothing it gates, no pending follow-up) should be archived: action "archive", task_id. Archived cards move to the Completed tab and leave the columns. Do not archive a card whose summary implies more work is coming, and do not archive anything created this tick.

        Constraints:
        - Act only when warranted; an empty tick is a valid outcome. Never fabricate tool arguments; never touch cards on other boards.
        - When you are done, reply with a one-paragraph report of what you did and why (or "no action").
        """
    }

    /// The board state the aux model sees: every card with its column,
    /// status, priority, assignee, and the latest run handoff.
    static func boardDigest(store: any CardStore, board: String) async throws -> String {
        let tasks = try await store.listTasks(board: board, filter: CardListFilter(includeArchived: false, limit: 200))
        var lines: [String] = []
        lines.append("Board '\(board)' — columns: Todo, Ready, Running, Blocked, Finished. \(tasks.count) card\(tasks.count == 1 ? "" : "s") on the board.")
        for column in CardColumn.allCases {
            let inColumn = tasks.filter { CardColumn(status: $0.status) == column }
            guard !inColumn.isEmpty else { continue }
            lines.append("")
            lines.append("[\(column.displayName)]")
            for task in inColumn {
                var line = "  • \(task.id.prefix(8)) \(task.title) (status \(task.status.rawValue), priority \(task.priority)"
                if let a = task.assignee { line += ", assignee \(a)" }
                if task.consecutiveFailures > 0 { line += ", \(task.consecutiveFailures) consecutive failures" }
                line += ")"
                lines.append(line)
                if let body = task.body, !body.isEmpty {
                    lines.append("    body: \(CardRules.cap(body, 600))")
                }
                let runs = (try? await store.runs(taskID: task.id, board: board)) ?? []
                if let last = runs.last {
                    if let summary = last.summary { lines.append("    last run #\(last.attempt) (\(last.outcome?.rawValue ?? "open")): \(CardRules.cap(summary, 500))") }
                    else { lines.append("    last run #\(last.attempt) (\(last.outcome?.rawValue ?? "open"))") }
                }
            }
        }
        if lines.count == 1 { lines.append("The board is empty.") }
        return lines.joined(separator: "\n")
    }

    /// Run the aux-model tool loop for one board until it reports done.
    static func dispatchBoard(
        board: String, digest: String, client: any LLMClient,
        store: any CardStore, runner: @escaping @Sendable (String) async throws -> String,
        maxIterations: Int
    ) async throws -> BoardDispatchOutcome {
        // A dedicated tool entry: no worker env, board pinned by the model's
        // explicit `board` argument, dispatch wired to the in-process runner.
        let dispatchDep = ToolDependency<@Sendable (String) async throws -> String>()
        dispatchDep.set(runner)
        let box = KanbanTool.StoreBox(storeOverride: store, envOverride: [:], dispatch: dispatchDep)
        let entry = KanbanTool.entry(storeOverride: store, envOverride: [:], dispatch: dispatchDep)
        let tools = [ToolSchemaRenderer.schema(for: entry)]

        var messages: [Message] = [
            Message(role: .system, content: systemPrompt()),
            Message(role: .user, content: digest),
        ]
        var calls = 0
        var report = ""
        for _ in 0..<maxIterations {
            let response = try await client.complete(messages: messages, tools: tools)
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                messages.append(Message(
                    role: .assistant, content: response.content,
                    toolCalls: toolCalls, reasoning: response.reasoning,
                    apiContent: response.content))
                for call in toolCalls {
                    calls += 1
                    let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]
                    let output = (try? await KanbanTool.handle(args: args, box: box)) ?? "Error: malformed arguments"
                    messages.append(Message(
                        role: .tool, content: output,
                        name: call.function.name, toolCallID: call.id,
                        apiContent: output))
                }
                continue
            }
            report = (response.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return BoardDispatchOutcome(board: board, toolCalls: calls, report: report)
    }
}
