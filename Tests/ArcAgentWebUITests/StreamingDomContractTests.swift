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
// renderer's source — it is what crosses the push door while a turn runs:
//
//   - the token writer owns those two nodes with `.text` ops. An html replace
//     re-mounts the node, and the writer's next delta lands in a node it no
//     longer owns (its baseline says "already sent"), so the text silently stops
//     growing.
//   - a structural frame has to name a node the client holds, and carry bytes a
//     render produced. An id that resolves nowhere is a dropped update that logs
//     once and then disappears.
//   - a token-only stretch of a turn ships no structural frame at all: the two
//     spans are excluded from the diff, so the render is byte-identical and the
//     door has nothing to say.
//
// These used to be source greps ("does Actions.swift contain
// `FragmentUpdate.text(id: "live-turn-text"`?"), which go green with the feature
// inert and red on any refactor that keeps the behaviour. They are now
// measurements of a scripted turn's real batches, pushed through a real
// `PushEdge` — the measured wire for the script below is
//
//   batch 0  renders=1  8 structural frames: s-open-…, s-menu-…, chat-header,
//                       chat-scroll, chat-inner, composer-form, composer-input,
//                       cb-send  (the turn-start boundary)
//   batch 1  renders=2  live-turn[replace]            (the live turn mounts)
//   batch 2  renders=3  live-turn-text[text]          (a token batch)
//   batch 3  renders=3  live-turn-thinking[text]      (a token batch)
//   batch 4  renders=5  app[replace]                  (the finalize: the live
//                       turn's removal is the one diff shape the differ cannot
//                       express as a region, so it escalates to the root)
// ===========================================================================

/// the scripted provider: streaming-only (a non-streaming call is a harness
/// error, not a fallback), one step at a time, with the pause a step can carry so
/// the turn's 90 ms push coalescer flushes a token batch on its own.
private struct StreamingScriptedClient: LLMClient {

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

        private struct Rig {
            let app: AppState
            let edge: PushEdge
            let wire: PushRecorder
            /// the page the client holds when the turn starts.
            let seed: String
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
            f.settings.disabledToolsets = []
            f.sessions = [session()]
            f.activeSessionID = Self.sessionID
            f.activeTabID = "chat"
            if let liveTurn {
                f.activeTurns = [Self.sessionID: liveTurn]
            }
            return f
        }

        /// a rig whose door renders the app it describes — the real shell, not a
        /// synthetic page — and records both sides, in order.
        private func makeRig(_ app: AppState) async -> Rig {
            let wire = PushRecorder()
            let edge = PushEdge(
                differ: PageDiffer(policy: PushEdge.livePolicy),
                render: {
                    let markup = await app.appShell().markup.html
                    await wire.noteRender(markup)
                    return markup
                },
                broadcast: wire.push
            )
            let seed = await app.appShell().markup.html
            edge.seed(seed)
            return Rig(app: app, edge: edge, wire: wire, seed: seed)
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

        /// whether `markup` carries `id` as an id attribute.
        private func markup(_ markup: String, carriesID id: String) -> Bool {
            markup.contains("id=\"\(id)\"")
        }

        /// the real shell with a live turn on screen, streaming `text` /
        /// `thinking`. Every clock field is fixed, so two calls differ only in the
        /// bytes they are told to differ in.
        private func livePage(workspace: URL, text: String, thinking: String) async -> String {
            var live = LiveTurn(sessionID: Self.sessionID, userText: "hello", attachments: [])
            live.assistantText = text
            live.thinking = thinking
            live.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let app = AppState(renderFixture: makeFixture(workspace: workspace, liveTurn: live))
            return await app.appShell().markup.html
        }

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
            let structural = log.filter(\.isStructural)
            let deltas = log.filter(\.isDeltaOnly)
            // floor: a turn that pushed nothing would satisfy every assertion below
            // while proving nothing about the streaming path.
            #expect(structural.count >= 2,
                    "the turn must push structure too — got \(structural.count) structural batches")
            #expect(!deltas.isEmpty, "the turn must push at least one token batch — got none")

            // 1. an html replace of either span would re-mount the node and strand
            //    the writer's next delta. no structural frame may name them.
            let structuralTargets = structural.flatMap(\.updates).map(\.id)
            let replacedSpans = structuralTargets.filter { Self.tokenSpans.contains($0) }
            #expect(replacedSpans.isEmpty,
                    "a structural frame re-mounted a token-owned span: \(replacedSpans) in \(structuralTargets)")

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

            // 3. a token batch is deltas only: a structural frame riding along would
            //    re-mount the parent the delta is about to be written into.
            for batch in log where batch.updates.contains(where: { Self.tokenSpans.contains($0.id) }) {
                #expect(batch.isDeltaOnly,
                        "a batch carrying a token write also carried structure: \(batch)")
            }
        }

        @Test("every structural frame addresses a node the page holds")
        func structuralFramesResolve() async {
            let app = AppState(renderFixture: makeFixture(workspace: makeWorkspace()))
            let rig = await makeRig(app)
            let finished = await runScriptedTurn(app, edge: rig.edge)
            #expect(finished, "the scripted turn must reach its end")

            let log = await rig.wire.log
            var examined = 0
            for batch in log where batch.isStructural {
                // the page the client holds once this batch lands: the door just
                // rendered it, and the door's frames are regions of that render.
                let held = batch.render ?? rig.seed
                for frame in batch.updates {
                    examined += 1
                    #expect(markup(held, carriesID: frame.id),
                            "frame #\(frame.id) resolves nowhere in the page the client holds — a dropped update")
                    #expect(!frame.html.isEmpty, "frame #\(frame.id) carries no bytes")
                    #expect(held.contains(frame.html),
                            "frame #\(frame.id) carries bytes the render did not produce — a producer's html, not the door's")
                }
            }
            // floor: the scan must have seen the turn's frames.
            #expect(examined >= 8, "the scan examined \(examined) structural frames — it is not reaching the wire")
        }

        @Test("a token-only change ships no structural frame")
        func tokenOnlyChangeShipsNoStructuralFrame() async {
            // The page the client holds, rendered from a live turn. The changed
            // page is derived from THIS render rather than from a second
            // `appShell()`: the shell also renders the process's shared log
            // buffer, which other suites write to in parallel, so two renders can
            // differ in the log dock and the pair would then be testing that
            // instead of the spans.
            let base = await livePage(workspace: makeWorkspace(), text: "tok-a", thinking: "thi-a")
            let cases: [(span: String, prior: String, next: String)] = [
                ("live-turn-text", "tok-a", "tok-b"),
                ("live-turn-thinking", "thi-a", "thi-b"),
            ]

            for testCase in cases {
                // the span's own bytes, rewritten — exactly what a token delta
                // changes in the render (`Span { Text(…) }.id(…)`).
                let from = ">\(testCase.prior)</span>"
                let to = ">\(testCase.next)</span>"
                #expect(base.contains(from),
                        "#\(testCase.span): the render must carry the span's token text, or the pair is synthetic")
                let page = base.replacingOccurrences(of: from, with: to)
                #expect(page != base, "#\(testCase.span): the pair must actually differ")

                // the door: a producer asking it to look during a token-only
                // stretch must find nothing to ship.
                let wire = PushRecorder()
                let edge = PushEdge(
                    differ: PageDiffer(policy: PushEdge.livePolicy),
                    render: { page },
                    broadcast: wire.push
                )
                edge.seed(base)
                await edge.push([])
                let ids = await wire.batches.map { $0.map(\.id) }
                #expect(ids.isEmpty,
                        "#\(testCase.span): a token-only change shipped \(ids) — the span leaked into the diff")
            }
        }
    }
}
