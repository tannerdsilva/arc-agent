import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import Testing
import WebUI
import WebUICore
import WebUIServer

@testable import ArcWebUI

// MARK: - the two populations, on one page
//
// no-webui 2.8.0 gives the router two scopes instead of one: the HOST table
// (`register(_:for:)`, the shape `Controller.wireAll` uses at boot, sealed once
// the server starts) and one render session per page (`controlAttributes`,
// which registers while the render pass runs). Dispatch resolves the session
// first and the host table second (§22.1/D1). Publishing
// `RuntimeConfig.renderToken` is what makes a real page reach BOTH: every frame
// the engine sends carries the token, so the server routes it to that render's
// session, and any id the render did not wire still answers from the host table.
//
// This suite is the consumer half of the framework's §22.1 gate. It drives a
// real `WebUIServer` over a real websocket — the page route, the render context,
// the token mint, the session index and the wire framing are all in the check —
// rather than calling `router.dispatch` as a function.

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
    private var closed = false

    func push(_ text: String) { frames.append(text) }
    func close() { closed = true }
    func all() -> [String] { frames }

    func first(containing needle: String, within timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let hit = frames.first(where: { $0.contains(needle) }) { return hit }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct DispatchSocket: Sendable {
    let inbox: FrameInbox
    let write: @Sendable (String) async throws -> Void

    func send(_ json: String, within timeout: Duration = .seconds(5)) async throws {
        try await withDeadline(timeout) { try await write(json) }
    }

    /// send one frame, then wait for the reply naming `needle`. The send and the
    /// read each carry the deadline, so a server that answers nothing fails here.
    func reply(
        to json: String,
        containing needle: String,
        within timeout: Duration = .seconds(5)
    ) async throws -> String {
        try await send(json, within: timeout)
        guard let frame = await inbox.first(containing: needle, within: timeout) else {
            let seen = await inbox.all()
            throw HarnessError.noReply(needle: needle, seen: seen)
        }
        return frame
    }
}

private enum HarnessError: Error, CustomStringConvertible {
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

private enum ClientUpgrade: Sendable {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case notUpgraded
}

/// open one upgraded connection, hand it to `body`, and close the group after.
private func withSocket<T: Sendable>(
    port: Int,
    _ body: @escaping @Sendable (DispatchSocket) async throws -> T
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
        throw HarnessError.upgradeRefused
    }

    do {
        let value = try await channel.executeThenClose { inbound, outbound in
            let inbox = FrameInbox()
            let pump = Task {
                do {
                    for try await frame in inbound {
                        guard frame.opcode == .text else { continue }
                        let buffer = frame.unmaskedData
                        guard let text = buffer.getString(
                            at: buffer.readerIndex,
                            length: buffer.readableBytes
                        ) else { continue }
                        await inbox.push(text)
                    }
                    await inbox.close()
                } catch {
                    await inbox.close()
                }
            }
            defer { pump.cancel() }
            let socket = DispatchSocket(inbox: inbox) { text in
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

// MARK: - server harness

private struct MixedPageServer: Sendable {
    let port: Int
    let router: EventRouter
    let server: WebUIServer
    let run: Task<Void, Error>

    func page() async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "GET / answered \(status)")
        return String(decoding: data, as: UTF8.self)
    }

    /// the token the page itself publishes in `webui-config` — the value the
    /// engine echoes on every frame, read the way the engine reads it.
    func pageToken() async throws -> String {
        let page = try await page()
        guard let meta = Self.webuiMeta(inPage: page),
              let token = meta["renderToken"] as? String,
              !token.isEmpty
        else {
            throw HarnessError.noReply(needle: "webui-config renderToken", seen: [page])
        }
        return token
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

private enum Population {
    /// the id both populations register: the collision the precedence rule is
    /// about.
    static let mixed = "probe"
    /// an id only the host table carries — the legacy door's control.
    static let hostOnly = "legacy"
    static let sessionFragment = "session-answered"
    static let hostFragment = "host-answered"
}

/// boot a real server whose one page carries both populations, run `body`, and
/// always stop the listener.
///
/// - Parameters:
///   - requireRenderToken: the framework's strict door. arc runs with it OFF
///     (`HostConfigTests` pins that), so the default here is arc's config; the
///     stale-token test turns it on to observe the refusal.
private func withMixedPageServer(
    requireRenderToken: Bool = false,
    _ body: @escaping @Sendable (MixedPageServer) async throws -> Void
) async throws {
    let tokens = UploadTokenStore()

    var config = WebUIHost.serverConfig(host: "127.0.0.1", port: 0)
    config.requireRenderToken = requireRenderToken
    let serverConfig = config

    let eventRouter = EventRouter()
    // the HOST population: `register(_:for:)` with no session — the exact shape
    // `Controller.wireAll` uses for arc's boot-wired controls.
    let hostRegistered = eventRouter.register(
        { [mixed = Population.mixed] _ in
            [FragmentUpdate(id: Population.hostFragment, html: "host:\(mixed)", transition: false)]
        },
        for: ComponentID(Population.mixed)
    )
    #expect(hostRegistered, "the host registration must land before the seal")

    let hostOnlyRegistered = eventRouter.register(
        { _ in
            [FragmentUpdate(id: Population.hostFragment, html: "host:\(Population.hostOnly)", transition: false)]
        },
        for: ComponentID(Population.hostOnly)
    )
    #expect(hostOnlyRegistered, "the host-only registration must land before the seal")

    let pageRouter = Router {
        WorkspaceUpload.pageRoute("/", tokens: tokens) { _, token in
            // the SESSION population: this call is `controlAttributes`, the same
            // entry point arc's Views use through `ArcButton.extraAttributes`.
            // It is executed here, inside the render context the server
            // establishes for this response, so it registers into THIS render's
            // session — the one the minted token names.
            let wiring = controlAttributes(id: Population.mixed, event: .click) { _ in
                [FragmentUpdate(
                    id: Population.sessionFragment,
                    html: "session:\(token)",
                    transition: false
                )]
            }
            let markup = """
                <div id="app"><button id="probe"\(wiring)>probe</button>\
                <button id="legacy" data-component-id="legacy" data-event="click">legacy</button></div>
                """
            return AppShell.makeDocument(
                sheetURL: "/ui/style.css",
                overlayURL: "/ui/init.js",
                renderToken: token,
                maxFrameBytes: serverConfig.maxFrameSize
            )(
                UnsafeMarkup.trusted(markup),
                "data-scheme=\"poseidon\" data-theme=\"dark\""
            )
        }
    }

    var harness: MixedPageServer?
    for _ in 0..<8 {
        let port = Int.random(in: 20000..<40000)
        var attempt = serverConfig
        attempt.port = port
        let server = WebUIServer(
            router: pageRouter,
            eventRouter: eventRouter,
            config: attempt,
            logger: Logger(label: "arc.test.two-population")
        )
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
            harness = MixedPageServer(port: port, router: eventRouter, server: server, run: run)
            break
        }
        await server.stop()
        run.cancel()
    }
    guard let harness else { throw HarnessError.couldNotBind }

    do {
        try await body(harness)
    } catch {
        await harness.stop()
        throw error
    }
    await harness.stop()
}

private func event(_ component: String, token: String?) -> String {
    var json = """
        {"type":"event","component":"\(component)","event":"click","data":{}}
        """
    if let token, !token.isEmpty {
        json = """
            {"type":"event","component":"\(component)","event":"click","data":{},"token":"\(token)"}
            """
    }
    return json
}

// MARK: - the seal's log sink

/// captures what the router writes, so the seal's refusal can be asserted as
/// text rather than described. `Logger(label:factory:)` keeps this handler
/// local: no global `LoggingSystem.bootstrap` is touched.
private final class LogSink: LogHandler, @unchecked Sendable {
    private let lines = Mutex<[String]>([])

    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        lines.withLock { $0.append("\(event.level): \(event.message)") }
    }

    var messages: [String] { lines.withLock { $0 } }
}

// MARK: - tests

extension ArcWebUITestRoot {

    @Suite("two-population dispatch", .serialized)
    struct TwoPopulationDispatchTests {

        /// §22.1's precedence rule, on the page that makes it matter: one page,
        /// one id registered by both populations. The token-bound frame routes
        /// to the render's session, that session's registration answers, and the
        /// host handler — which is registered for the same id — must not fire.
        ///
        /// The host registration is proven live in the same test by sending the
        /// same id with no token: that frame takes the legacy `.default` door,
        /// where no session handler exists, and the host table answers. Without
        /// that half, "the host did not fire" could pass because it never landed.
        @Test("the session shadows the host for a colliding id, and the host still answers the legacy door")
        func sessionWinsForACollidingID() async throws {
            try await withMixedPageServer { harness in
                let token = try await harness.pageToken()

                // the page's render really did register into the token's session
                #expect(
                    harness.router.handlerCount(in: RenderSessionID(token)) >= 1,
                    "the render pass registered nothing in session '\(token)'"
                )
                #expect(harness.router.hostHandlerCount == 2, "both host registrations must be in the host table")
                #expect(harness.router.hostRegistrationsSealed, "the server seals the host table at start()")

                try await withSocket(port: harness.port) { socket in
                    let bound = try await socket.reply(
                        to: event(Population.mixed, token: token),
                        containing: Population.sessionFragment
                    )
                    #expect(
                        bound.contains("session:\(token)"),
                        "the session handler answers with its own session: \(bound)"
                    )
                    #expect(
                        !bound.contains(Population.hostFragment),
                        "the host handler fired for an id the session already answers: \(bound)"
                    )

                    let legacy = try await socket.reply(
                        to: event(Population.mixed, token: nil),
                        containing: Population.hostFragment
                    )
                    #expect(
                        legacy.contains("host:\(Population.mixed)"),
                        "a tokenless frame must still reach the host table through .default: \(legacy)"
                    )
                    #expect(
                        !legacy.contains(Population.sessionFragment),
                        "a tokenless frame resolved into a render session: \(legacy)"
                    )
                }
            }
        }

        /// Two page loads mint two tokens and two sessions. The same id, wired at
        /// render time in both, must answer from the session its frame names —
        /// never from the other page's.
        @Test("two sessions with the same render-time id each answer their own")
        func twoSessionsKeepTheirOwnHandlers() async throws {
            try await withMixedPageServer { harness in
                let first = try await harness.pageToken()
                let second = try await harness.pageToken()
                #expect(first != second, "two renders minted the same token: the second session overwrote the first")

                try await withSocket(port: harness.port) { one in
                    try await withSocket(port: harness.port) { two in
                        let oneReply = try await one.reply(
                            to: event(Population.mixed, token: first),
                            containing: Population.sessionFragment
                        )
                        #expect(oneReply.contains("session:\(first)"), "session one answered \(oneReply)")
                        #expect(!oneReply.contains("session:\(second)"), "session one reached session two's handler: \(oneReply)")

                        let twoReply = try await two.reply(
                            to: event(Population.mixed, token: second),
                            containing: Population.sessionFragment
                        )
                        #expect(twoReply.contains("session:\(second)"), "session two answered \(twoReply)")
                        #expect(!twoReply.contains("session:\(first)"), "session two reached session one's handler: \(twoReply)")
                    }
                }
            }
        }

        /// A token this host never minted is refused, not routed: the framework's
        /// strict door answers a `token` error frame. arc leaves the door tolerant
        /// by default (`HostConfigTests` pins `requireRenderToken == false`), which
        /// is why the refusal is asserted against a server that turns it on.
        @Test("a stale or unknown token is refused with a token error")
        func staleTokenIsRefused() async throws {
            try await withMixedPageServer(requireRenderToken: true) { harness in
                try await withSocket(port: harness.port) { socket in
                    let reply = try await socket.reply(
                        to: event(Population.mixed, token: "never-minted-by-this-host"),
                        containing: "\"code\":\"token\""
                    )
                    #expect(
                        reply.contains("unknown or missing render token"),
                        "the refusal must name the token: \(reply)"
                    )
                    #expect(
                        !reply.contains(Population.hostFragment),
                        "a stale token fell through to the host table: \(reply)"
                    )
                }
            }
        }

        /// The seal's shape: after `sealHostRegistrations()` a host registration
        /// is REFUSED — `register` answers `false`, the table does not grow, and
        /// the refusal is logged at `.error` naming the id — never dropped
        /// silently. A session registration is unaffected: a render pass keeps
        /// registering its own controls for as long as the server runs.
        @Test("a host registration after the seal is refused with an error diagnostic")
        func lateHostRegistrationIsRefused() async {
            let sink = LogSink()
            let router = EventRouter(logger: Logger(label: "arc.test.seal", factory: { _ in sink }))
            let first = router.register(
                { _ in [FragmentUpdate(id: "early", html: "early", transition: false)] },
                for: ComponentID("sealed-early")
            )
            #expect(first, "the pre-seal registration must land")

            router.sealHostRegistrations()
            #expect(router.hostRegistrationsSealed)
            #expect(router.hostHandlerCount == 1)

            let late = router.register(
                { _ in [FragmentUpdate(id: "late", html: "late", transition: false)] },
                for: ComponentID("sealed-late")
            )
            #expect(late == false, "a host registration after the seal must be refused")
            #expect(router.hostHandlerCount == 1, "a refused registration grew the host table")

            let logged = sink.messages.filter { $0.contains("host registrations are sealed") }
            #expect(!logged.isEmpty, "the refusal was silent: \(sink.messages)")
            #expect(
                logged.contains { $0.contains("sealed-late") && $0.contains("error") },
                "the diagnostic must be an .error naming the refused id: \(logged)"
            )

            // the refused id answers nothing — no half-landed handler.
            let refused = await router.dispatch(
                EventData(component: ComponentID("sealed-late"), event: "click", data: [:])
            )
            #expect(refused.fragments.isEmpty, "a refused registration is still dispatching")

            // the seal is a host-table fact only: a render pass keeps registering.
            let session = RenderSessionID("post-seal-render")
            router.begin(session)
            router.register({ _ in [] }, for: ComponentID("sealed-late"), in: session)
            #expect(router.handlerCount(in: session) == 1, "the seal closed the session door too")

            // and re-sealing is idempotent: the server calls it again at start().
            router.sealHostRegistrations()
            #expect(sink.messages.filter { $0.contains("host registrations are sealed") }.count == logged.count,
                    "a second seal logged a second refusal")
        }
    }
}
