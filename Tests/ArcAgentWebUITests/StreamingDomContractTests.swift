import Foundation
import Testing
@testable import ArcAgentCore
@testable import ArcWebUI
import WebUICore
import WebUIState

// ===========================================================================
// MARK: - the streaming DOM contract, at the wire
//
// The live turn streams into two stable spans (`#live-turn-text`,
// `#live-turn-thinking`). What keeps a stream alive is not a spelling in the
// renderer's source — it is what crosses the producer door while a turn runs:
//
//   - the token writer owns those two nodes with `.text` ops. An html replace
//     re-mounts the node, and the writer's next delta lands in a node it no
//     longer owns (its baseline says "already sent"), so the text silently stops
//     growing.
//   - a structural frame has to name a node the client holds, and carry bytes a
//     render produced. An id that resolves nowhere is a dropped update that logs
//     once and then disappears.
//   - a token-only stretch of a turn ships no structural frame at all: the two
//     spans are excluded from the refresh policy, so a re-render is
//     byte-identical and the server has nothing to send.
//
// These used to be source greps ("does Actions.swift contain
// `FragmentUpdate.text(id: "live-turn-text"`?"), which go green with the feature
// inert and red on any refactor that keeps the behaviour. They are now
// measurements of a scripted turn's real batches, pushed through a real
// `PushEdge`.
//
// Since A10b the door no longer derives frames: a structural batch is a refresh
// of every page this host served (`PushEdge.refresh`), and the broadcast carries
// deltas only. The shape a scripted turn leaves on the door is therefore
//
//   refresh                    (turn start: the composer swaps send ⇄ stop)
//   refresh                    (the live turn mounts)
//   delta   live-turn-text[text]          (a token batch)
//   delta   live-turn-thinking[text]      (a token batch)
//   refresh                    (the finalize: the live turn goes away)
//
// No broadcast in that sequence carries a structural update — that is the
// property this suite owns, and it is what makes re-mounting a token span
// impossible rather than merely avoided. What each refresh *ships* is the
// server's decision, and `ProducerRefreshWireTests` asks it over a real socket.
// ===========================================================================

/// the scripted provider: streaming-only (a non-streaming call is a harness
/// error, not a fallback), one step at a time, with the pause a step can carry so
/// the turn's 90 ms push coalescer flushes a token batch on its own.
///
/// Shared by the streaming DOM contract suite and the live-turn wire suite
/// (`LiveTurnWireTests`): one scripted provider, not two, because the two suites
/// must not disagree about what a provider emits.
struct StreamingScriptedClient: LLMClient {

    struct Step: Sendable {
        var reasoning: String? = nil
        var text: String? = nil
        var pauseMilliseconds: Int = 0
    }

    var steps: [Step] = []
    var usage: Usage? = nil

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        throw LLMError.apiError(statusCode: 500, message: "scripted client is streaming-only")
    }

    func complete(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String?
    ) async throws -> LLMResponse {
        try await complete(messages: messages, tools: tools)
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        stream(messages: messages, tools: tools, reasoningEffort: nil)
    }

    func stream(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        let steps = self.steps
        let usage = self.usage
        return AsyncThrowingStream { continuation in
            Task {
                for step in steps {
                    if step.pauseMilliseconds > 0 {
                        try? await Task.sleep(for: .milliseconds(step.pauseMilliseconds))
                    }
                    if let reasoning = step.reasoning {
                        continuation.yield(LLMDelta(content: nil, reasoning: reasoning))
                    }
                    if let text = step.text {
                        continuation.yield(LLMDelta(content: text))
                    }
                }
                if let usage {
                    continuation.yield(LLMDelta(content: nil, usage: usage))
                }
                continuation.yield(LLMDelta(content: nil, finishReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private extension AppState {
    /// bind the scripted provider — the one var the production init fills from
    /// the live config. No store is bound: this suite is about the wire, and the
    /// golden suite already owns persistence.
    func useScriptedClient(_ client: any LLMClient) {
        turnClientOverride = client
    }
}

/// run a turn to its end, but never wait forever: a turn that awaits a decision
/// nobody will make must fail here instead of hanging the suite.
private func awaitTurn(_ turn: Task<Void, Never>, timeout: TimeInterval = 30) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await turn.value; return true }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        if !finished { turn.cancel() }
        return finished
    }
}

extension ArcWebUITestRoot {
    @Suite("Streaming DOM contract", .serialized)
    struct StreamingDomContractTests {

        /// the two nodes the token writer owns: `FragmentUpdate.text` writes into
        /// them, and nothing else may re-mount them while a turn streams.
        private static let tokenSpans: Set<String> = ["live-turn-text", "live-turn-thinking"]

        private static let preset = ModelConfigPreset(
            name: "b5-stream",
            model: "stream-model-1",
            baseURL: "http://127.0.0.1:9/v1",
            contextLength: 8_000,
            maxOutputTokens: 512
        )

        private static let sessionID = "s-b5-stream"

        // MARK: harness

        /// how many times the door asked the server to re-render the served
        /// pages. A refresh is the whole of a structural batch now, so this is
        /// the turn's structural boundary count.
        private actor RefreshTally {
            private(set) var count = 0
            func note() { count += 1 }
        }

        private struct Rig {
            let app: AppState
            let edge: PushEdge
            /// the broadcasts the door made — deltas only, by contract.
            let wire: PushRecorder
            let tally: RefreshTally
        }

        private func session() -> Session {
            Session(id: Self.sessionID,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    title: "Streaming",
                    messageCount: 1,
                    messages: [Message(role: .user, content: "earlier")])
        }

        /// a fresh workspace directory. The SAME path is handed to every state a
        /// render pair is taken from, because the workspace tree renders the path
        /// — two different temp dirs would differ outside the spans and make a
        /// token-only pair mean nothing.
        private func makeWorkspace() -> URL {
            let workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-b5-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            return workspace
        }

        /// a state whose chat view is showing, whose registry is empty (the script
        /// calls no tools), and whose model config is the stub preset.
        private func makeFixture(workspace: URL, liveTurn: LiveTurn? = nil) -> AppState.RenderFixture {
            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [Self.preset]
            f.settings.activeConfig = Self.preset.name
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspace.path)]
            f.settings.activeWorkspace = "main"
            f.arcConfig.tools.disabledToolsets = []
            f.sessions = [session()]
            f.activeSessionID = Self.sessionID
            f.activeTabID = "chat"
            if let liveTurn {
                f.activeTurns = [Self.sessionID: liveTurn]
            }
            return f
        }

        /// a rig whose door asks a counter to refresh — the server is not in this
        /// suite — and records every broadcast.
        private func makeRig(_ app: AppState) async -> Rig {
            let wire = PushRecorder()
            let tally = RefreshTally()
            let edge = PushEdge(
                refresh: { await tally.note() },
                broadcast: wire.push
            )
            return Rig(app: app, edge: edge, wire: wire, tally: tally)
        }

        /// reasoning, then two text chunks and one more reasoning delta, each far
        /// enough apart that the turn's 90 ms coalescer flushes them on their own.
        /// The second reasoning step is what makes the THINKING span a `.text`
        /// write too: the first one arrives with the status change, so it rides
        /// the structural batch.
        private let script: [StreamingScriptedClient.Step] = [
            .init(reasoning: "considering the request"),
            .init(text: "Work", pauseMilliseconds: 150),
            .init(text: "ing on it.", pauseMilliseconds: 150),
            .init(reasoning: " further", pauseMilliseconds: 160),
        ]

        /// drive one scripted turn to its end through `runTurn`, with the door as
        /// the turn's pusher.
        private func runScriptedTurn(_ app: AppState, edge: PushEdge) async -> Bool {
            await app.useScriptedClient(StreamingScriptedClient(
                steps: script,
                usage: Usage(promptTokens: 120, completionTokens: 40, totalTokens: 160)
            ))
            let turn = Task {
                await app.runTurn(
                    userText: "hello",
                    pusher: { await edge.push($0) },
                    sessionID: Self.sessionID,
                    selectAfter: false
                )
            }
            return await awaitTurn(turn)
        }

        // Two helpers stood here and died with the host-side differ (A10b):
        // `markup(_:carriesID:)` and `livePage(workspace:text:thinking:)`
        // existed to check a frame against the render the DOOR had made. The
        // door derives no frames now, and `ProducerRefreshWireTests` asks a real
        // server for the bytes it ships.

        // MARK: - addressability (the ids the streaming push addresses)

        @Test("the live turn and its body are addressable")
        func liveTurnIsAddressable() async {
            // the live turn is typed now: pin the RENDERED node ids, which are
            // exactly what the streaming text ops target.
            let live = await RenderedMarkup.liveTurn()
            #expect(live.contains("id=\"live-turn\""), "liveMessageHTML must carry id=\"live-turn\"")
            #expect(live.contains("id=\"live-turn-body\""), "the live body must carry id=\"live-turn-body\"")
            #expect(live.contains("id=\"live-turn-text\""),
                    "the streaming text must sit in a stable span (id=\"live-turn-text\") for text-op writes")
            #expect(live.contains("id=\"live-turn-thinking\""),
                    "the reasoning span must be in the render, not materialize later")
        }

        @Test("committed turns and messages are addressable")
        func committedUnitsAreAddressable() async {
            let block = await RenderedMarkup.turnBlock()
            #expect(block.contains("id=\"turn-1\""), "turnBlockHTML must carry id=\"turn-<turnIndex>\"")
            // the messages are typed now: prove the addresses on RENDERED rows.
            // the streaming push targets these ids, so a missing one is a
            // silently dropped update, not a cosmetic difference.
            let rendered = await RenderedMarkup.addressedMessages()
            #expect(rendered.contains("id=\"msg-user-0\""),
                    "user messages must be addressable as id=\"msg-user-<rawIdx>\"")
            #expect(rendered.contains("id=\"msg-1\""),
                    "assistant and tool messages must carry id=\"msg-<rawIdx>\"")
            #expect(!rendered.contains("id=\"\""), "an address attribute must never render empty")
        }

        @Test("tool progress is a name plus a client-ticked clock")
        func toolProgressIsNamedAndTimed() async {
            // the mapper is a pure function of the event, so the status line's two
            // fields are pinned without a socket and without reading its source.
            var live = LiveTurn(sessionID: Self.sessionID, userText: "hi", attachments: [])
            live.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let mapped = TurnLiveState.apply(
                .toolCallStarted(id: "call-1", name: "read_file", arguments: "{}"),
                to: live
            )
            #expect(mapped.toolName == "read_file", "the mapper must stamp the running tool's name")
            #expect(mapped.toolStartedAt != nil,
                    "the mapper must stamp when the tool started, for the client-ticked clock")
            // and the render carries both: the name a reader sees, the clock the
            // client ticks.
            let rendered = await RenderedMarkup.liveTurn()
            #expect(rendered.contains("read_file"), "the tool status line must render the tool name")
            #expect(rendered.contains("data-elapsed") && rendered.contains("data-started="),
                    "the tool clock must reuse the client-ticked elapsed span")
        }

        // MARK: - the wire contract
        @Test("a token write into the streaming spans is a text op, never a replace")
        func tokenWritesAreTextOps() async {
            let app = AppState(renderFixture: makeFixture(workspace: makeWorkspace()))
            let rig = await makeRig(app)
            let finished = await runScriptedTurn(app, edge: rig.edge)
            #expect(finished, "the scripted turn must reach its end")

            let log = await rig.wire.log
            let deltas = log.filter(\.isDeltaOnly)
            // floor: a turn that pushed nothing would satisfy every assertion below
            // while proving nothing about the streaming path.
            #expect(!deltas.isEmpty, "the turn must push at least one token batch — got none")

            // 1. no broadcast may carry structure at all. a structural frame would
            //    re-mount the node the delta is about to be written into, and the
            //    writer's next delta would land in a node it no longer owns.
            let structural = log.filter(\.isStructural)
            #expect(structural.isEmpty,
                    "the door broadcast \(structural.map(\.ids)) — a structural batch is a refresh, never a frame")

            // 2. every write that reaches a span is a `.text` op carrying no html —
            //    the characterData write the token writer owns.
            let spanWrites = log.flatMap(\.updates).filter { Self.tokenSpans.contains($0.id) }
            #expect(!spanWrites.isEmpty,
                    "the turn never wrote a token span: the streaming contract is unexercised")
            for update in spanWrites {
                #expect(update.op == .text,
                        "#\(update.id) was written with op \(String(describing: update.op)) — only .text keeps the node")
                #expect(update.html.isEmpty,
                        "#\(update.id) carried \(update.html.count) bytes of html with a text op")
                #expect(update.text?.isEmpty == false, "#\(update.id) was written with an empty payload")
                #expect(update.transition == false,
                        "#\(update.id) did not opt out of the view transition — a token-rate write must not animate")
            }

            // 3. a batch carrying a token write is deltas only. true by
            //    construction now — structure never reaches the broadcast — and
            //    kept as the wire-level statement a future producer would break by
            //    broadcasting its own structure.
            for batch in log where batch.updates.contains(where: { Self.tokenSpans.contains($0.id) }) {
                #expect(batch.isDeltaOnly,
                        "a batch carrying a token write also carried structure: \(batch)")
            }
        }

        @Test("a turn's structural boundaries are refreshes, and its token batches are deltas")
        func boundariesAreRefreshesAndTokensAreDeltas() async {
            // the door's partition, measured on a real turn: every structural
            // boundary asks the server to re-render the served pages, and every
            // broadcast the turn makes is a delta batch.
            let app = AppState(renderFixture: makeFixture(workspace: makeWorkspace()))
            let rig = await makeRig(app)
            let finished = await runScriptedTurn(app, edge: rig.edge)
            #expect(finished, "the scripted turn must reach its end")

            let refreshes = await rig.tally.count
            let log = await rig.wire.log
            // floor: the turn has at least the live-turn mount and the finalize
            // boundary. A door that swallowed them would leave the page stale with
            // every assertion in the suite still green.
            #expect(refreshes >= 2,
                    "the turn asked for \(refreshes) refreshes — the door never reached the server")
            #expect(!log.isEmpty, "the turn broadcast no deltas at all")
            // bound first: `allSatisfy` takes a throwing closure, and the
            // `#expect` macro will not carry an unmarked `try` into its expansion.
            let allDeltas = log.allSatisfy(\.isDeltaOnly)
            #expect(allDeltas, "a broadcast batch carried structure: \(log.map(\.ids))")
        }
    }
}
