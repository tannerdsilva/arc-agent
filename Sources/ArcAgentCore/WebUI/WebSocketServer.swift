import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOWebSocket
import NIOHTTP1
import ServiceLifecycle

/// A standalone WebSocket server for the ARC Agent web UI.
///
/// Runs on a separate port from the HTTP server. The JavaScript runtime
/// connects to this server for real-time communication.
///
/// Uses NIOWebSocket directly — no Hummingbird pipeline integration needed.
///
/// ## Concurrency
///
/// This is a ``Service`` managed by the gateway's ``ServiceGroup``.
/// It runs on a single event loop group and accepts WebSocket connections.
public struct WebSocketServerService: Service {
    private let host: String
    private let port: Int
        private let logger = Logger(label: "com.arc-agent.websocket-server")
    private let handlerFactory: @Sendable (String) -> WebSocketHandler

    /// Create a WebSocket server service.
    /// - Parameters:
    ///   - host: Host to bind to.
    ///   - port: Port to listen on.
    ///   - handlerFactory: Factory that creates a ``WebSocketHandler`` for each connection.
    public init(
        host: String = "127.0.0.1",
        port: Int,
        handlerFactory: @escaping @Sendable (String) -> WebSocketHandler
    ) {
        self.host = host
        self.port = port
        self.handlerFactory = handlerFactory
    }

    public func run() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { eventLoopGroup.shutdownGracefully { _ in } }

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                channel.eventLoop.makeSucceededFuture([:])
            },
            upgradePipelineHandler: { channel, head in
                let sessionID = UUID().uuidString
                let handler = self.handlerFactory(sessionID)

                return channel.pipeline.addHandler(WebSocketFrameHandler(handler: handler)).flatMap {
                    Task { await handler.setChannel(channel) }
                    return channel.eventLoop.makeSucceededFuture(Void())
                }
            }
        )

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrade: NIOHTTPServerUpgradeSendableConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: upgrade
                )
            }

        let channel = try await bootstrap.bind(host: self.host, port: self.port).get()
        logger.info("Listening on ws://\(self.host):\(self.port)")

        // Wait for the channel to close (service lifecycle handles cancellation)
        try await channel.closeFuture.get()
    }
}

// MARK: - WebSocket Frame Handler

/// Handles WebSocket frames after the upgrade is complete.
final class WebSocketFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let handler: WebSocketHandler

    init(handler: WebSocketHandler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            // Use unmaskedData to get the client's original text
            var data = frame.unmaskedData
            guard let text = data.readString(length: data.readableBytes) else { return }
            // Echo back with proper JSON encoding
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            let echo = "{\"type\":\"message\",\"html\":\"<p>\(escaped)</p>\"}"
            var out = context.channel.allocator.buffer(string: echo)
            let outFrame = WebSocketFrame(fin: true, opcode: .text, data: out)
            context.writeAndFlush(wrapOutboundOut(outFrame), promise: nil)

        case .connectionClose:
            Task { [handler] in
                try? await handler.updateStatus(connected: false)
            }
            _ = context.close()

        case .ping:
            var buffer = context.channel.allocator.buffer(capacity: 0)
            let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: buffer)
            context.writeAndFlush(wrapOutboundOut(pongFrame), promise: nil)

        case .pong:
            break

        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task { [handler] in
            try? await handler.updateStatus(connected: false)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
