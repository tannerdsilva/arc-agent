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

}
