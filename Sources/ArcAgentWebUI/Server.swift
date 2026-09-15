import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import WebUI

// MARK: - Shim handler (HTTPByteBuffer → HTTPServerResponsePart)

final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = Self.unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

enum UpgradeResult: Sendable {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

// MARK: - WebServer

final class WebServer {

    let logger: Logger
    let router: EventRouter
    let hub: ClientHub
    /// The page rendered at boot; served only if live rendering fails.
    let bootPage: String
    /// Renders the shell from the CURRENT actor state, so a refresh never
    /// shows stale boot-time markup (e.g. sessions created or deleted after
    /// boot). Receives a decoded `?s=` deep-link session id (nil when absent).
    let pageProvider: @Sendable (String?) async -> String

    /// Patched no-webui runtime (Enter-to-send + passive event filtering).
    let runtimeJS: String
    /// Boot script that connects the runtime to `/ws`.
    let initJS: String
    /// Full UI stylesheet.
    let styleCSS: String

    init(
        logger: Logger,
        router: EventRouter,
        hub: ClientHub,
        bootPage: String,
        pageProvider: @Sendable @escaping (String?) async -> String,
        runtimeJS: String,
        initJS: String,
        styleCSS: String
    ) {
        self.logger = logger
        self.router = router
        self.hub = hub
        self.bootPage = bootPage
        self.pageProvider = pageProvider
        self.runtimeJS = runtimeJS
        self.initJS = initJS
        self.styleCSS = styleCSS
    }

    // MARK: Bootstrap

    func serve(host: String, port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await bootstrap.bind(
            host: host, port: port
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                    shouldUpgrade: { channel, head in
                        let ok = head.method == .GET && head.uri == "/ws"
                        return channel.eventLoop.makeSucceededFuture(ok ? HTTPHeaders() : nil)
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            let ws = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                wrappingChannelSynchronously: channel)
                            return UpgradeResult.websocket(ws)
                        }
                    }
                )
                let config = NIOTypedHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
                            let http = try NIOAsyncChannel<
                                HTTPServerRequestPart,
                                HTTPPart<HTTPResponseHead, ByteBuffer>
                            >(wrappingChannelSynchronously: channel)
                            return UpgradeResult.http(http)
                        }
                    }
                )
                let pipelineConfig = NIOUpgradableHTTPServerPipelineConfiguration(
                    upgradeConfiguration: config)
                let negotiation = try channel.pipeline.syncOperations
                    .configureUpgradableHTTPServerPipeline(configuration: pipelineConfig)
                return negotiation
            }
        }

        logger.info("arc-agent webui on http://\(host):\(port)")

        try await withThrowingDiscardingTaskGroup { group in
            try await channel.executeThenClose { inbound in
                for try await negotiationFuture in inbound {
                    group.addTask {
                        await self.handle(negotiationFuture)
                    }
                }
            }
        }
        try await group.shutdownGracefully()
    }

    private func handle(_ negotiationFuture: EventLoopFuture<UpgradeResult>) async {
        do {
            switch try await negotiationFuture.get() {
            case .websocket(let ws):
                try await handleWebsocket(ws)
            case .http(let http):
                try await handleHTTP(http)
            }
        } catch {
            // connection error; ignore
        }
    }

    // MARK: WebSocket

    private func handleWebsocket(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async throws {
        let clientID = await hub.nextID()
        try await channel.executeThenClose { inbound, outbound in
            await hub.register(clientID, outbound)
            do {
                for try await frame in inbound {
                    switch frame.opcode {
                    case .text:
                        let payload = String(buffer: frame.unmaskedData)
                        await self.dispatch(eventText: payload, clientID: clientID, outbound: outbound)
                    case .ping:
                        let buf = ByteBuffer()
                        let pong = WebSocketFrame(fin: true, opcode: .pong, data: buf)
                        try await outbound.write(pong)
                    case .connectionClose:
                        var data = frame.unmaskedData
                        let code = data.readSlice(length: 2) ?? ByteBuffer()
                        let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: code)
                        try await outbound.write(close)
                        return
                    default:
                        break
                    }
                }
            } catch {
                // socket closed
            }
            await hub.unregister(clientID)
        }
    }

    private func dispatch(
        eventText payload: String,
        clientID: Int,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async {
        guard let data = payload.data(using: .utf8) else { return }
        do {
            let msg = try JSONDecoder().decode(WSIncoming.self, from: data)
            switch msg {
            case .event(let component, let event, let data):
                let eventData = EventData(component: ComponentID(component), event: event, data: data)
                let updates = await TaskEnv.$clientID.withValue(clientID) {
                    await self.router.handle(eventData)
                }
                guard !updates.isEmpty else { return }
                let out = WSOutgoing.update(fragments: updates)
                try await writeJSON(out, outbound: outbound)
            case .ping:
                try await writeJSON(WSOutgoing.pong, outbound: outbound)
            case .navigate:
                break
            }
        } catch {
            let err = WSOutgoing.error(code: "decode", message: "bad event: \(error)")
            try? await writeJSON(err, outbound: outbound)
        }
    }

    private func writeJSON(
        _ msg: WSOutgoing,
        outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async throws {
        let data = try JSONEncoder().encode(msg)
        var buf = ByteBuffer()
        buf.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        try await outbound.write(frame)
    }

    // MARK: HTTP

    private func handleHTTP(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        try await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .head(let head) = part else { continue }
                guard head.method == .GET else {
                    try await self.respond405(outbound: outbound)
                    return
                }
                // Strip the query string — browsers cache-bust with ?v=….
                let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
                // Vendored KaTeX fonts are binary; serve them before the text
                // tuple path below.
                if path.hasPrefix("/ui/vendor/katex/fonts/") {
                    let name = String(path.dropFirst("/ui/vendor/katex/fonts/".count))
                    if let b64 = KaTeXAssets.fontsBase64[name], let data = Data(base64Encoded: b64) {
                        try await self.respondData(outbound: outbound, body: data, contentType: "font/woff2")
                    } else {
                        try await self.respond404(outbound: outbound)
                    }
                    return
                }
                let (text, contentType): (String, String)
                switch path {
                case "/__assets/css":
                    // no-webui assets (kept for compatibility; the app uses /ui/*)
                    text = WebUIAssets.css; contentType = "text/css; charset=utf-8"
                case "/__assets/js":
                    text = WebUIAssets.js; contentType = "text/javascript; charset=utf-8"
                case "/ui/style.css":
                    text = self.styleCSS; contentType = "text/css; charset=utf-8"
                case "/ui/runtime.js":
                    text = self.runtimeJS; contentType = "text/javascript; charset=utf-8"
                case "/ui/init.js":
                    text = self.initJS; contentType = "text/javascript; charset=utf-8"
                case "/ui/vendor/katex/katex.min.js":
                    text = KaTeXAssets.js; contentType = "text/javascript; charset=utf-8"
                case "/ui/vendor/katex/katex.min.css":
                    text = KaTeXAssets.css; contentType = "text/css; charset=utf-8"
                case "/", "/index.html":
                    // ?s=<id> opens that conversation directly (copy-link flow).
                    var deepLink: String?
                    if let query = head.uri.split(separator: "?").dropFirst().first {
                        for param in query.split(separator: "&") {
                            let kv = param.split(separator: "=", maxSplits: 1).map(String.init)
                            if kv.count == 2, kv[0] == "s" {
                                deepLink = kv[1].removingPercentEncoding
                            }
                        }
                    }
                    text = (try? await self.pageProvider(deepLink)) ?? self.bootPage
                    contentType = "text/html; charset=utf-8"
                default:
                    try await self.respond404(outbound: outbound)
                    return
                }
                try await self.respond(outbound: outbound, body: text, contentType: contentType)
            }
        }
    }

    private func respond(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>,
        body: String,
        contentType: String
    ) async throws {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.replaceOrAdd(name: "Content-Type", value: contentType)
        head.headers.replaceOrAdd(name: "Content-Length", value: "\(body.utf8.count)")
        head.headers.replaceOrAdd(name: "Connection", value: "close")
        head.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        var buf = ByteBuffer()
        buf.writeString(body)
        // Write head/body/end atomically, then give the flush time to land
        // before the channel closes (prevents tail truncation on large pages).
        try await outbound.write(contentsOf: [.head(head), .body(buf), .end(nil)])
        try await outbound.finish()
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func respondData(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>,
        body: Data,
        contentType: String
    ) async throws {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.replaceOrAdd(name: "Content-Type", value: contentType)
        head.headers.replaceOrAdd(name: "Content-Length", value: "\(body.count)")
        head.headers.replaceOrAdd(name: "Connection", value: "close")
        head.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        var buf = ByteBuffer()
        buf.writeBytes(body)
        try await outbound.write(contentsOf: [.head(head), .body(buf), .end(nil)])
        try await outbound.finish()
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func respond404(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var head = HTTPResponseHead(version: .http1_1, status: .notFound)
        head.headers.replaceOrAdd(name: "Content-Length", value: "9")
        head.headers.replaceOrAdd(name: "Connection", value: "close")
        var buf = ByteBuffer()
        buf.writeString("not found")
        try await outbound.write(contentsOf: [.head(head), .body(buf), .end(nil)])
        try await outbound.finish()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func respond405(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var head = HTTPResponseHead(version: .http1_1, status: .methodNotAllowed)
        head.headers.replaceOrAdd(name: "Content-Length", value: "0")
        head.headers.replaceOrAdd(name: "Connection", value: "close")
        try await outbound.write(contentsOf: [.head(head), .end(nil)])
        try await outbound.finish()
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
