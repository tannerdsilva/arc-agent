import Foundation
import NIOCore
import NIO
import NIOPosix

/// Loopback TCP JSONL RPC server backing `execute_code`.
///
/// One connection per tool call: client sends a single JSON line
/// `{"tool": "...", "args": {...}, "token": "..."}`; the server dispatches it
/// through the host tool executor and replies with one JSON line
/// `{"result": "..."}` or `{"error": "..."}`, then closes.
final class ToolRPCServer: @unchecked Sendable {

    let channel: Channel
    private let group: EventLoopGroup

    private init(channel: Channel, group: EventLoopGroup) {
        self.channel = channel
        self.group = group
    }

    static func start(
        host: @escaping @Sendable (String, [String: Any]) async throws -> String,
        limiter: ExecuteCodeTool.RunLimiter, token: String
    ) async throws -> (server: ToolRPCServer, port: Int) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    RPCRequestHandler(host: host, limiter: limiter, token: token))
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else {
            try? await group.shutdownGracefully()
            throw ToolError.execution("Could not bind execute_code RPC socket")
        }
        return (ToolRPCServer(channel: channel, group: group), port)
    }

    func shutdown() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

/// One request per connection: read until newline, dispatch, respond, close.
final class RPCRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let host: @Sendable (String, [String: Any]) async throws -> String
    private let limiter: ExecuteCodeTool.RunLimiter
    private let token: String
    private var buffer = ByteBuffer()
    private var responded = false

    init(
        host: @escaping @Sendable (String, [String: Any]) async throws -> String,
        limiter: ExecuteCodeTool.RunLimiter, token: String
    ) {
        self.host = host
        self.limiter = limiter
        self.token = token
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        guard let newlineIdx = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            // wait for the rest of the line
            return
        }
        let lineLength = buffer.readableBytesView.distance(
            from: buffer.readerIndex, to: newlineIdx)
        guard var line = buffer.readSlice(length: lineLength) else { return }
        _ = line.moveReaderIndex(forwardBy: 0)
        guard let jsonText = line.readString(length: lineLength) else {
            respondError(context: context, message: "invalid request encoding")
            return
        }
        _ = newlineIdx

        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool"] as? String,
              !tool.isEmpty else {
            respondError(context: context, message: "missing or invalid 'tool' field")
            return
        }
        if let sentToken = obj["token"] as? String, sentToken != token {
            respondError(context: context, message: "invalid RPC token")
            return
        }
        let args = obj["args"] as? [String: Any] ?? [:]

        let future: EventLoopFuture<String> = context.eventLoop.makeFutureWithTask {
            try await self.limiter.run {
                try await self.host(tool, args)
            }
        }
        future.whenComplete { result in
            switch result {
            case .success(let text):
                var out = context.channel.allocator.buffer(capacity: text.count + 32)
                let payload = "{\"result\":\(Self.jsonEscape(text))}\n"
                out.writeString(payload)
                context.writeAndFlush(NIOAny(out), promise: nil)
                context.close(promise: nil)
            case .failure(let error):
                self.respondError(context: context, message: String(describing: error))
            }
        }
    }

    private func respondError(context: ChannelHandlerContext, message: String) {
        guard !responded else { return }
        responded = true
        var out = context.channel.allocator.buffer(capacity: message.count + 32)
        out.writeString("{\"error\":\(Self.jsonEscape(message))}\n")
        context.writeAndFlush(NIOAny(out), promise: nil)
        context.close(promise: nil)
    }

    /// JSON string escaping for arbitrary tool result text.
    static func jsonEscape(_ text: String) -> String {
        var escaped = ""
        for ch in text {
            switch ch {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.append(ch)
                }
            }
        }
        return "\"\(escaped)\""
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // no-op: responses are dispatched per request
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
