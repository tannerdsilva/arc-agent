import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
import WebUI
import WebUICore
import WebUIServer

@testable import ArcAgentCore
@testable import ArcWebUI

// MARK: - the producer refresh, on a real server and a real socket
//
// `PushDiffTests` proves the DOOR's decision — a structural batch asks for one
// refresh and forwards no html, a delta is broadcast verbatim, and the refresh
// comes first. That suite replaces both of the door's sinks with counters, so it
// cannot say what the refresh actually ships. This one asks the component that
// answers in production: a real `WebUIServer`, the host's own `serverConfig`
// (so `AppShell.refreshPolicy` is the policy in the check), a real page route,
// and a real websocket.
//
// The page is deliberately shaped like arc's shell: `#app` is the root, `#stage`
// and `#toasts` are tracked regions inside it, `#live-turn-text` is a
// token-owned span inside an untracked-but-addressable parent, and a `<p>` with
// no id sits outside every region — the residue a page patch exists for.
//
// What this suite owns, one test each:
//
//   1. a producer refresh reaches the served session's socket and no other
//      (§22.2/D1: the fan-out is session-scoped);
//   2. structure ships BEFORE the deltas of the same push — the ordering the
//      retired `PageDiffer` used to guarantee locally;
//   3. a refresh that reproduces the page sends nothing at all;
//   4. a change no region covers answers the page region (`#webui-page`), the
//      patch `WebUIServer.diffFrame` builds itself;
//   5. a token-owned span's bytes make no frame — `refreshPolicy.excluded`, the
//      value that must survive the move out of `PushEdge`;
//   6. an appeared child ships its region WITH the container, never inner-only
//      (an empty replacement deletes the node for the session).

// MARK: - wire client

/// The one thing a bounded socket test must never do is await without a
/// deadline: an unbounded read on a frame that never comes wedges the whole
/// test target, not just this test. Every await below crosses `withDeadline`.
private struct SocketTimeout: Error {}

private func withDeadline<T: Sendable>(
    _ timeout: Duration,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SocketTimeout()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw SocketTimeout() }
        return first
    }
}

/// the text frames one connection received, appended by its read pump and read
/// by the test. `first(containing:within:)` polls to a deadline and answers nil
/// rather than suspending on a continuation that may never resume.
private actor FrameInbox {
    private var frames: [String] = []

    func push(_ text: String) { frames.append(text) }
    func all() -> [String] { frames }
    func count() -> Int { frames.count }

    func first(containing needle: String, within timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let hit = frames.first(where: { $0.contains(needle) }) { return hit }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct ProducerSocket: Sendable {
    let inbox: FrameInbox
    let write: @Sendable (String) async throws -> Void

    func send(_ json: String, within timeout: Duration = .seconds(5)) async throws {
        try await withDeadline(timeout) { try await write(json) }
    }

    /// send one frame, then wait for the reply containing `needle`.
    func reply(
        to json: String,
        containing needle: String,
        within timeout: Duration = .seconds(5)
    ) async throws -> String {
        try await send(json, within: timeout)
        guard let frame = await inbox.first(containing: needle, within: timeout) else {
            throw ProducerHarnessError.noReply(needle: needle, seen: await inbox.all())
        }
        return frame
    }

    /// bind this connection to `token`'s render session — the ping is the
    /// cheapest frame the server answers, and it is what the engine sends.
    func bind(to token: String) async throws {
        _ = try await reply(to: pingFrame(token), containing: "\"pong\"")
    }
}

private enum ProducerHarnessError: Error, CustomStringConvertible {
    case couldNotBind
    case upgradeRefused
    case noReply(needle: String, seen: [String])

    var description: String {
        switch self {
        case .couldNotBind:
            return "no free port answered on loopback"
        case .upgradeRefused:
            return "the server refused the websocket upgrade"
        case .noReply(let needle, let seen):
            return "no frame containing '\(needle)' within the deadline; saw \(seen)"
        }
    }
}

private func pingFrame(_ token: String) -> String {
    "{\"type\":\"ping\",\"token\":\"\(token)\"}"
}

private enum ClientUpgrade: Sendable {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case notUpgraded
}

/// open one upgraded connection, hand it to `body`, and close the group after.
private func withSocket<T: Sendable>(
    port: Int,
    _ body: @escaping @Sendable (ProducerSocket) async throws -> T
) async throws -> T {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upgrade: ClientUpgrade
    do {
        upgrade = try await withDeadline(.seconds(10)) { () -> ClientUpgrade in
            let future: EventLoopFuture<ClientUpgrade> = try await ClientBootstrap(group: group)
                .connect(host: "127.0.0.1", port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let upgrader = NIOTypedWebSocketClientUpgrader<ClientUpgrade>(
                            upgradePipelineHandler: { channel, _ in
                                channel.eventLoop.makeCompletedFuture {
                                    .websocket(
                                        try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                            wrappingChannelSynchronously: channel
                                        )
                                    )
                                }
                            }
                        )
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
                        headers.add(name: "Content-Length", value: "0")
                        let head = HTTPRequestHead(
                            version: .http1_1,
                            method: .GET,
                            uri: "/ws",
                            headers: headers
                        )
                        let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                            upgradeRequestHead: head,
                            upgraders: [upgrader],
                            notUpgradingCompletionHandler: { channel in
                                channel.eventLoop.makeCompletedFuture { ClientUpgrade.notUpgraded }
                            }
                        )
                        return try channel.pipeline.syncOperations
                            .configureUpgradableHTTPClientPipeline(
                                configuration: .init(upgradeConfiguration: configuration)
                            )
                    }
                }
            return try await future.get()
        }
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }

    guard case .websocket(let channel) = upgrade else {
        try? await group.shutdownGracefully()
        throw ProducerHarnessError.upgradeRefused
    }

    do {
        let value = try await channel.executeThenClose { inbound, outbound in
            let inbox = FrameInbox()
            let pump = Task {
                for try await frame in inbound {
                    guard frame.opcode == .text else { continue }
                    let buffer = frame.unmaskedData
                    guard let text = buffer.getString(
                        at: buffer.readerIndex,
                        length: buffer.readableBytes
                    ) else { continue }
                    await inbox.push(text)
                }
            }
            defer { pump.cancel() }
            let socket = ProducerSocket(inbox: inbox) { text in
                try await outbound.write(
                    WebSocketFrame(
                        fin: true,
                        opcode: .text,
                        maskKey: WebSocketMaskingKey.random(),
                        data: ByteBuffer(string: text)
                    )
                )
            }
            return try await body(socket)
        }
        try? await group.shutdownGracefully()
        return value
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

// MARK: - the page the server serves

/// The state the page reads. Every field is a region (or, for `tail`, the
/// residue), so a test moves exactly one thing and the diff has exactly one
/// honest answer.
private actor ProducerPage {
    private var stage = "a"
    private var toasts = ""
    private var tokenText = "tok-a"
    private var tail = ""

    func setStage(_ value: String) { stage = value }
    func setToasts(_ value: String) { toasts = value }
    func setTokenText(_ value: String) { tokenText = value }
    func setTail(_ value: String) { tail = value }

    /// `#app` is the root region; `#stage` / `#toasts` are tracked regions inside
    /// it; `#live-turn-text` is the token-owned span inside an addressable parent
    /// (`#live-turn`), whose own hash must not move when only the span does;
    /// `<p>` carries no id, so it is outside every region — the residue.
    func markup() -> String {
        "<div id=\"app\">"
            + "<div id=\"live-turn\"><span id=\"live-turn-text\">\(tokenText)</span></div>"
            + "<div id=\"stage\">\(stage)</div>"
            + "<div id=\"toasts\">\(toasts)</div>"
            + "</div><p>\(tail)</p>"
    }
}

// MARK: - server harness

private struct ProducerServer: Sendable {
    let port: Int
    let server: WebUIServer
    let run: Task<Void, Error>
    let page: ProducerPage
    let tokens: UploadTokenStore

    func pageHTML() async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "GET / answered \(status)")
        return String(decoding: data, as: UTF8.self)
    }

    /// the token the page publishes — the value the engine echoes, read the way
    /// the engine reads it.
    func pageToken() async throws -> String {
        let page = try await pageHTML()
        guard let meta = Self.webuiMeta(inPage: page),
              let token = meta["renderToken"] as? String,
              !token.isEmpty
        else {
            throw ProducerHarnessError.noReply(needle: "webui-config renderToken", seen: [page])
        }
        return token
    }

    /// re-render the page the session was served, and ship what moved.
    func refresh(_ token: String) async {
        await server.refresh(session: RenderSessionID(token))
    }

    static func webuiMeta(inPage page: String) -> [String: Any]? {
        guard let name = page.range(of: "name=\"webui-config\"") else { return nil }
        let rest = page[name.upperBound...]
        guard let open = rest.range(of: "content=\"") else { return nil }
        let tail = rest[open.upperBound...]
        guard let close = tail.range(of: "\">") else { return nil }
        let json = String(tail[..<close.lowerBound])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    func stop() async {
        await server.stop()
        run.cancel()
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            do {
                _ = try await URLSession(configuration: .ephemeral).data(from: url)
                try? await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
        }
    }
}

/// boot a real server carrying the producer page, run `body`, and always stop
/// the listener.
///
/// The config is `WebUIHost.serverConfig` — the one arc runs — so the policy in
/// the check is the policy production re-renders under, not a literal this
/// harness would keep passing after the real one moved.
private func withProducerServer(
    serving markup: (@Sendable () async -> UnsafeMarkup)? = nil,
    _ body: @escaping @Sendable (ProducerServer) async throws -> Void
) async throws {
    let tokens = UploadTokenStore()
    let page = ProducerPage()
    let servedPage = markup

    var harness: ProducerServer?
    for _ in 0..<8 {
        let port = Int.random(in: 20000..<40000)
        var config = WebUIHost.serverConfig(host: "127.0.0.1", port: port)
        config.port = port
        // the closure below takes a value, not the mutable var it was built from.
        let serverConfig = config
        let pageRouter = Router {
            WorkspaceUpload.pageRoute("/", tokens: tokens) { _, token, _ in
                // `servedPage` is the production page when a caller that owns a
                // real `AppState` passes one (the live-turn suite), and this
                // file's one-region-at-a-time page otherwise. The theme attrs
                // are outside the diff root (`<body>`), so a caller's own theme
                // cannot change what a refresh ships.
                let rendered: UnsafeMarkup
                if let servedPage {
                    rendered = await servedPage()
                } else {
                    rendered = UnsafeMarkup.trusted(await page.markup())
                }
                return AppShell.makeDocument(
                    sheetURL: "/ui/style.css",
                    renderToken: token,
                    maxFrameBytes: serverConfig.maxFrameSize
                )(
                    rendered,
                    "data-scheme=\"poseidon\" data-theme=\"dark\""
                )
            }
        }
        let server = WebUIServer(router: pageRouter, config: config)
        let run = Task { try await server.start() }
        let deadline = Date().addingTimeInterval(3)
        var serving = false
        while Date() < deadline {
            if (try? await URLSession(configuration: .ephemeral)
                .data(from: URL(string: "http://127.0.0.1:\(port)/")!)) != nil {
                serving = true
                break
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if serving {
            harness = ProducerServer(port: port, server: server, run: run, page: page, tokens: tokens)
            break
        }
        await server.stop()
        run.cancel()
    }
    guard let harness else { throw ProducerHarnessError.couldNotBind }

    do {
        try await body(harness)
    } catch {
        await harness.stop()
        throw error
    }
    await harness.stop()
}

/// one fragment as it crossed the wire: a `.replace` carries `html`, a `.text`
/// carries `text` — the door's two halves are told apart by `op`, never by
/// guessing from the html.
private struct WireFragment: Sendable {
    let id: String
    let html: String
    let op: String?
    let text: String?
}

/// the fragments an `update` frame carries, read from the wire's own json. An
/// `op` is absent for `.replace` (the framework's encoding), so `nil` and
/// `"replace"` are the same op here.
private func wireFragments(inFrame frame: String) -> [WireFragment] {
    guard let data = frame.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = object["fragments"] as? [[String: Any]]
    else { return [] }
    return list.map { item in
        WireFragment(
            id: item["id"] as? String ?? "",
            html: item["html"] as? String ?? "",
            op: item["op"] as? String,
            text: item["text"] as? String
        )
    }
}

/// the id + html pairs a frame carries (the shape the producer tests assert on).
private func fragments(inFrame frame: String) -> [(id: String, html: String)] {
    wireFragments(inFrame: frame).map { ($0.id, $0.html) }
}

/// the `.text` writes into `span`, in the order the socket received them.
private func textWrites(in frames: [String], span: String) -> [(frame: Int, text: String)] {
    var writes: [(frame: Int, text: String)] = []
    for (index, frame) in frames.enumerated() {
        for fragment in wireFragments(inFrame: frame)
        where fragment.id == span && fragment.op == "text" {
            if let text = fragment.text { writes.append((index, text)) }
        }
    }
    return writes
}

/// the first frame that shipped `span` as html — the structural replace that
/// mounted the node a token writer then owns.
private func mountFrame(of span: String, in frames: [String]) -> Int? {
    frames.firstIndex { frame in
        wireFragments(inFrame: frame).contains { fragment in
            (fragment.op == nil || fragment.op == "replace")
                && fragment.html.contains("id=\"\(span)\"")
        }
    }
}

/// a compact, readable digest of what crossed the wire: fragment ids, ops and
/// payload sizes rather than the bytes (a page-region patch is the whole shell).
private func frameDigest(_ frames: [String]) -> String {
    frames.enumerated().map { index, frame in
        let parts = wireFragments(inFrame: frame).map { fragment -> String in
            if fragment.op == "text" {
                return "\(fragment.id)[text \(fragment.text?.count ?? 0)B]"
            }
            return "\(fragment.id)[\(fragment.op ?? "replace") \(fragment.html.count)B]"
        }
        return "#\(index) \(parts.joined(separator: ","))"
    }.joined(separator: " | ")
}

// MARK: - tests

extension ArcWebUITestRoot {

    @Suite("producer refresh wire", .serialized)
    struct ProducerRefreshWireTests {

        @Test("a producer refresh reaches the served session's socket and no other")
        func refreshIsSessionScoped() async throws {
            try await withProducerServer { harness in
                let first = try await harness.pageToken()
                let second = try await harness.pageToken()
                #expect(first != second, "two page loads minted the same token")

                try await withSocket(port: harness.port) { one in
                    try await withSocket(port: harness.port) { two in
                        // both sockets speak for a page: without the bind, the
                        // negative below could pass because neither was attached.
                        try await one.bind(to: first)
                        try await two.bind(to: second)

                        await harness.page.setStage("b")
                        await harness.refresh(first)

                        let moved = await one.inbox.first(containing: "stage", within: .seconds(5))
                        #expect(moved != nil, "the refresh never reached the session's own socket")
                        #expect(fragments(inFrame: moved ?? "").map(\.id) == ["stage"],
                                "the refresh shipped \(fragments(inFrame: moved ?? "").map(\.id))")

                        let leaked = await two.inbox.first(containing: "stage", within: .milliseconds(400))
                        #expect(leaked == nil,
                                "a refresh fanned out to another session's page: \(leaked ?? "")")
                    }
                }
            }
        }

        @Test("structure ships before the deltas of the same push")
        func structureShipsBeforeDeltas() async throws {
            try await withProducerServer { harness in
                let token = try await harness.pageToken()
                let server = harness.server
                let session = RenderSessionID(token)

                try await withSocket(port: harness.port) { socket in
                    try await socket.bind(to: token)

                    // the door wired the way the host wires it: one refresh of the
                    // served page, then the deltas verbatim.
                    let edge = PushEdge(
                        refresh: { await server.refresh(session: session) },
                        broadcast: { await server.broadcast($0) }
                    )
                    await harness.page.setStage("b")
                    await edge.push([
                        // the producer's html is stale by construction.
                        FragmentUpdate(id: "stage", html: "<div id=\"stage\">PRODUCER</div>"),
                        FragmentUpdate.text(id: "live-turn-text", value: "tok-b", transition: false),
                    ])

                    // wait for the LAST frame of the push, so the order below is
                    // about frames that all arrived rather than about timing.
                    let delta = await socket.inbox.first(containing: "live-turn-text", within: .seconds(5))
                    #expect(delta != nil, "the delta never reached the socket")

                    let frames = (await socket.inbox.all()).filter { !$0.contains("\"pong\"") }
                    let structural = frames.firstIndex { $0.contains("stage") }
                    let deltas = frames.firstIndex { $0.contains("live-turn-text") }
                    #expect(structural != nil, "the structural frame never reached the socket: \(frames)")
                    #expect(structural == 0, "the structure was not the first frame: \(frames)")
                    if let structural, let deltas {
                        #expect(structural < deltas,
                                "the delta beat the structure that may have re-mounted its node: \(frames)")
                    }

                    // and what shipped is the render's bytes, never the producer's.
                    let wire = frames.joined()
                    #expect(!wire.contains("PRODUCER"), "the producer's html crossed the wire: \(wire)")
                    if let structural {
                        let parts = fragments(inFrame: frames[structural])
                        #expect(parts.first?.html == "<div id=\"stage\">b</div>",
                                "the frame must carry the re-render's region: \(parts)")
                    }
                }
            }
        }

        @Test("a refresh that reproduces the page sends nothing")
        func aSecondRefreshWithNoByteChangeShipsNothing() async throws {
            try await withProducerServer { harness in
                let token = try await harness.pageToken()
                try await withSocket(port: harness.port) { socket in
                    try await socket.bind(to: token)

                    await harness.page.setStage("b")
                    await harness.refresh(token)
                    let moved = await socket.inbox.first(containing: "stage", within: .seconds(5))
                    #expect(moved != nil, "the first refresh shipped nothing")

                    // the same page again: the server's baseline already holds it,
                    // so there is no frame — and a page that received one would
                    // re-mount a region for no reason on every idle boundary.
                    let before = await socket.inbox.count()
                    await harness.refresh(token)
                    try await Task.sleep(for: .milliseconds(400))
                    let after = await socket.inbox.count()
                    #expect(after == before, "an unchanged refresh sent \(after - before) frame(s)")
                }
            }
        }

        @Test("a change outside every child region answers the page region")
        func aChangeOutsideEveryChildRegionAnswersThePageRegion() async throws {
            try await withProducerServer { harness in
                let token = try await harness.pageToken()
                try await withSocket(port: harness.port) { socket in
                    try await socket.bind(to: token)

                    // `<p>` carries no id, so no CHILD region covers its bytes.
                    // The only element whose own bytes moved is the page region
                    // itself, and its replacement is the patch shape that can
                    // carry them.
                    await harness.page.setTail("tail-1")
                    await harness.refresh(token)

                    let frame = await socket.inbox.first(containing: "webui-page", within: .seconds(5))
                    #expect(frame != nil, "a change outside every child region shipped nothing: the page is stale")
                    let parts = fragments(inFrame: frame ?? "")
                    #expect(parts.map(\.id) == [AppShell.pageRegionID],
                            "a change outside every region must answer \(AppShell.pageRegionID), got \(parts.map(\.id))")
                    #expect(parts.first?.html.contains("tail-1") == true,
                            "the page patch must carry the bytes that moved")
                }
            }
        }

        @Test("a removal the diff cannot express answers the page region")
        func aRemovalTheDiffCannotExpressAnswersThePageRegion() async throws {
            try await withProducerServer { harness in
                // the toast is there when the page is served, so the baseline
                // holds `#t-1` as a tracked region.
                await harness.page.setToasts("<button id=\"t-1\">x</button>")
                let token = try await harness.pageToken()

                try await withSocket(port: harness.port) { socket in
                    try await socket.bind(to: token)

                    // the wire has no remove op and a baseline keeps hashes, not
                    // offsets, so a vanished region has no patch shape at all:
                    // it escalates to the page region — the frame
                    // `WebUIServer.diffFrame` builds itself.
                    await harness.page.setToasts("")
                    await harness.refresh(token)

                    let frame = await socket.inbox.first(containing: "webui-page", within: .seconds(5))
                    #expect(frame != nil, "a removed region shipped nothing: the stale toast stays on screen")
                    let parts = fragments(inFrame: frame ?? "")
                    #expect(parts.map(\.id) == [AppShell.pageRegionID],
                            "a removal must answer \(AppShell.pageRegionID), got \(parts.map(\.id))")
                    #expect(parts.first?.html.contains("t-1") != true,
                            "the dismissed control must not be repeated back to the client")
                }
            }
        }

        @Test("a token-owned span's bytes make no frame")
        func tokenSpanBytesMakeNoFrame() async throws {
            try await withProducerServer { harness in
                let token = try await harness.pageToken()
                try await withSocket(port: harness.port) { socket in
                    try await socket.bind(to: token)

                    // the span is written by `FragmentUpdate.text` on every token.
                    // If its bytes reached the diff, `#live-turn`'s own hash would
                    // move and every token would ship a structural frame that
                    // re-mounts the node the writer owns.
                    let before = await socket.inbox.count()
                    await harness.page.setTokenText("tok-b")
                    await harness.refresh(token)
                    try await Task.sleep(for: .milliseconds(400))
                    let after = await socket.inbox.count()
                    #expect(after == before,
                            "the token-owned span's bytes shipped \(after - before) frame(s): refreshPolicy.excluded is not in force")
                }
            }
        }

        @Test("an appeared child ships its region with the container")
        func anAppearedChildCarriesTheContainer() async throws {
            try await withProducerServer { harness in
                let token = try await harness.pageToken()
                try await withSocket(port: harness.port) { socket in
                    try await socket.bind(to: token)

                    // the engine's `replaceElement` removes a node whose
                    // replacement is empty, so an inner-only frame would delete
                    // `#toasts` for the rest of the session and swallow every
                    // later toast.
                    await harness.page.setToasts("<button id=\"t-1\">x</button>")
                    await harness.refresh(token)

                    let frame = await socket.inbox.first(containing: "toasts", within: .seconds(5))
                    #expect(frame != nil, "a toast appearing shipped nothing")
                    let parts = fragments(inFrame: frame ?? "")
                    #expect(parts.map(\.id) == ["toasts"], "the appeared child escalated to \(parts.map(\.id))")
                    #expect(parts.first?.html.contains("id=\"toasts\"") == true,
                            "an inner-only frame deletes the node for the session: \(parts)")
                    #expect(parts.first?.html.contains("t-1") == true,
                            "the frame must carry the new toast")
                }
            }
        }
    }
}

// MARK: - the live turn, driven by a real turn, on a real server
//
// `StreamingDomContractTests` proves the turn's batches against a recorder — a
// refresh is a structural boundary, a token write rides the broadcast — but it
// never asks a server, so it cannot say the frame that MOUNTS `#live-turn-text`
// reached a socket before the frame that writes into it. The suite above proves
// the producer door over a real socket, but its page is moved by hand: no test
// drove a real turn.
//
// This suite does. A real `AppState` and its real render (`appShell()`), the
// host's own `serverConfig`, the host's own `PushEdge` wiring, a real websocket,
// and a scripted `LLMClient` standing where a provider would be
// (`turnClientOverride`). The turn loop is production's — same coalescer, same
// boundaries, same finalize.
//
// What it pins, from the frames alone:
//
//   1. the structural replace that ships `#live-turn-text` arrives BEFORE the
//      first `.text` write into it (a delta that beats its container is an
//      "Element not found" the client logs and drops);
//   2. both token writes arrive, in order, as the cumulative snapshots a
//      `.text` op means.
//
// Why three scripted chunks for two wire writes: the first text delta always
// takes the live turn's STRUCTURAL branch — `lastPush` starts at `distantPast`,
// so its throttle fires, and `liveStructureSignature` has flipped (the live turn
// had no assistant text at the turn-start boundary). That batch is a refresh, not
// a text op. The refresh itself ships nothing for the text: the span is
// `refreshPolicy.excluded`, so its bytes never move an ancestor's hash
// (`tokenSpanBytesMakeNoFrame` owns that measurement). The first wire write is
// therefore the second chunk, and every later chunk is a `.text` op carrying the
// whole accumulated text.

private extension AppState {
    /// bind the scripted provider — the turn agent's one provider seam
    /// (`turnClientOverride`). No store is bound: this suite is about the wire.
    func useTurnClient(_ client: any LLMClient) {
        turnClientOverride = client
    }
}

extension ArcWebUITestRoot {

    @Suite("live turn wire", .serialized)
    struct LiveTurnWireTests {

        private static let preset = ModelConfigPreset(
            name: "d63-live-turn",
            model: "scripted-turn-1",
            baseURL: "http://127.0.0.1:9/v1",
            contextLength: 8_000,
            maxOutputTokens: 512
        )

        private static let sessionID = "s-d63-live-turn"

        /// the span the token writer owns, and the node a delta targets.
        private static let span = "live-turn-text"

        /// a fresh workspace directory: the turn agent renders the workspace
        /// path, and two tests must not share one.
        private func makeWorkspace() -> URL {
            let workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-d63-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            return workspace
        }

        /// a state whose chat view is showing, whose registry is empty (the
        /// script calls no tools), and whose model config is the stub preset —
        /// the same fixture `StreamingDomContractTests` renders from.
        private func makeApp(workspace: URL) -> AppState {
            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [Self.preset]
            f.settings.activeConfig = Self.preset.name
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspace.path)]
            f.settings.activeWorkspace = "main"
            f.arcConfig.tools.disabledToolsets = []
            f.sessions = [Session(
                id: Self.sessionID,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                title: "Live turn",
                messageCount: 1,
                messages: [Message(role: .user, content: "earlier")]
            )]
            f.activeSessionID = Self.sessionID
            f.activeTabID = "chat"
            return AppState(renderFixture: f)
        }

        @Test("a real turn mounts the streaming span before it writes into it")
        func aRealTurnShipsStructureBeforeItsFirstDelta() async throws {
            let app = makeApp(workspace: makeWorkspace())
            await app.useTurnClient(StreamingScriptedClient(steps: [
                .init(text: "Hello", pauseMilliseconds: 150),
                .init(text: " there", pauseMilliseconds: 150),
                .init(text: ", world", pauseMilliseconds: 150),
            ]))

            // the server serves the PRODUCTION page: the route renders
            // `appShell()` under the host's own config, so a refresh diffs the
            // real shell against the baseline it recorded when it served it.
            try await withProducerServer(serving: { await app.appShell().markup }) { harness in
                let token = try await harness.pageToken()

                try await withSocket(port: harness.port) { socket in
                    try await socket.bind(to: token)

                    // the host's door, verbatim (`WebUIHost.run`): a structural
                    // batch refreshes every page the route served; a delta is
                    // broadcast as it stands.
                    let tokens = harness.tokens
                    let server = harness.server
                    let edge = PushEdge(
                        refresh: {
                            for served in await tokens.snapshot() {
                                await server.refresh(session: RenderSessionID(served))
                            }
                        },
                        broadcast: { await server.broadcast($0) }
                    )

                    let turn = Task {
                        await app.runTurn(
                            userText: "hello",
                            pusher: { await edge.push($0) },
                            sessionID: Self.sessionID,
                            selectAfter: false
                        )
                    }
                    defer { turn.cancel() }
                    // the turn must END: a turn awaiting a provider that never
                    // answers is a failure here, not a hung executable.
                    try await withDeadline(.seconds(30)) { await turn.value }

                    // the turn awaited both pushes, but the socket's read pump
                    // still has to deliver them; poll to a deadline rather than
                    // sleep on principle.
                    var frames: [String] = []
                    let deadline = ContinuousClock.now + .seconds(5)
                    repeat {
                        frames = (await socket.inbox.all()).filter { !$0.contains("\"pong\"") }
                        if textWrites(in: frames, span: Self.span).count >= 2 { break }
                        try await Task.sleep(for: .milliseconds(20))
                    } while ContinuousClock.now < deadline

                    let writes = textWrites(in: frames, span: Self.span)
                    let mount = mountFrame(of: Self.span, in: frames)

                    // floor first: an ordering check over indices it never found
                    // passes vacuously, and so does a turn that shipped nothing.
                    #expect(!frames.isEmpty, "the turn put no frame on the socket")
                    #expect(mount != nil,
                            "no structural frame shipped #\(Self.span) — nothing mounted the span the deltas write into. frames: \(frameDigest(frames))")
                    #expect(writes.count >= 2,
                            "the turn made \(writes.count) token write(s) into #\(Self.span), expected 2. frames: \(frameDigest(frames))")

                    // 1. the mount precedes the first write.
                    if let mount, let first = writes.first {
                        #expect(mount < first.frame,
                                "the token write reached the socket before the structural frame that mounts its span: mount #\(mount), first write #\(first.frame). frames: \(frameDigest(frames))")
                    }

                    // 2. both writes arrive, in order, as cumulative snapshots.
                    #expect(writes.map(\.text) == ["Hello there", "Hello there, world"],
                            "the span's writes arrived as \(writes.map(\.text)). frames: \(frameDigest(frames))")
                }
            }
        }
    }
}
