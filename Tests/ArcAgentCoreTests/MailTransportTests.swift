import Testing
@testable import ArcAgentCore
import Foundation
import NIO
import NIOCore

// =========================================================================
// MARK: - Mail Transport Tests (loopback, no external network)
// =========================================================================

@Suite("Mail transport")
struct MailTransportTests {

    // MARK: LineCodec literal handling

    @Test("LineCodec emits lines and captures IMAP literals")
    func lineCodecLiterals() throws {
        let channel = EmbeddedChannel()
        let codec = LineCodec()
        var lines: [String] = []
        var literals: [Data] = []
        codec.onLine = { lines.append($0) }
        codec.onLiteral = { literals.append($0) }
        try channel.pipeline.syncOperations.addHandler(codec)

        // Marker line: "* 1 FETCH (BODY[] {11}" then 11 literal bytes then close.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("* 1 FETCH (BODY[] {11}\r\n")
        try channel.writeInbound(buffer)

        var literal = channel.allocator.buffer(capacity: 16)
        literal.writeString("hello world")
        try channel.writeInbound(literal)

        var tail = channel.allocator.buffer(capacity: 8)
        tail.writeString(")\r\nA1 OK done\r\n")
        try channel.writeInbound(tail)

        #expect(lines.count == 3)
        #expect(lines[0] == "* 1 FETCH (BODY[] {11}")
        #expect(lines[1] == ")")
        #expect(lines[2] == "A1 OK done")
        #expect(literals.count == 1)
        #expect(String(data: literals[0], encoding: .utf8) == "hello world")
        try channel.finish()
    }

    @Test("TLS connect to a non-TLS server fails cleanly instead of crashing")
    func tlsToPlainServerFailsCleanly() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                // Accept nothing: close immediately so the TLS client sees an
                // EOF/error during the handshake.
                channel.close(promise: nil)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { try? server.close().wait() }
        guard let port = server.localAddress?.port else {
            Issue.record("loopback server did not bind a port")
            return
        }
        let sender = SMTPSender(
            host: "127.0.0.1", port: port,
            username: "u", password: "p",
            useTLS: true,
            eventLoopGroup: group
        )
        // A TLS client against a server that immediately closes must surface
        // as a thrown error — never a `try!` process crash. (Suite timeout is
        // bounded by the sender's 15s exchange deadline in the worst case.)
        var threw = false
        do {
            try await sender.connect()
        } catch {
            threw = true // graceful failure path (TLS/IO/timeout error)
        }
        #expect(threw, "TLS connect to a closed server must throw, not crash")
    }

}
