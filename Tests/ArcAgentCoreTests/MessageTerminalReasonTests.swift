import Foundation
import Testing
@testable import ArcAgentCore

/// `Message.terminalReason` — Hermes `_terminal_reason` parity for
/// terminal-state status cards (e.g. "max_iterations").
@Suite("Message terminal reason")
struct MessageTerminalReasonTests {

    @Test("Round-trips through Codable")
    func roundTrip() throws {
        let msg = Message(
            role: .assistant,
            content: "Summary text",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            terminalReason: "max_iterations"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded.terminalReason == "max_iterations")
        #expect(decoded.content == "Summary text")
        #expect(decoded.role == .assistant)
    }

    @Test("Legacy payload without the field decodes as nil")
    func legacyDecode() throws {
        // Shape of a pre-terminalReason stored message (no new key).
        let json = """
        {"role":"assistant","content":"old reply"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Message.self, from: json)
        #expect(decoded.terminalReason == nil)
        #expect(decoded.content == "old reply")
    }

    @Test("Normal replies carry no terminal reason")
    func normalNil() {
        let msg = Message(role: .assistant, content: "hi")
        #expect(msg.terminalReason == nil)
    }
}
