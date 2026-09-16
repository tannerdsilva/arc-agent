import Foundation
import Testing
@testable import ArcAgentCore

@Suite("Message displayText (slash-command rewrite bites)")
struct MessageDisplayTextTests {
    @Test("displayText round-trips through Codable")
    func displayTextRoundTrip() throws {
        let msg = Message(role: .user, content: "long [IMPORTANT]...", createdAt: Date(),
                          displayText: "/skill-name run it")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded.displayText == "/skill-name run it")
        #expect(decoded.content == "long [IMPORTANT]...")
    }

    @Test("legacy events without displayText decode to nil")
    func legacyDecodesNil() throws {
        // Shape of a pre-displayText stored message (no new key).
        let json = "{\"role\":\"user\",\"content\":\"hello\"}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Message.self, from: json)
        #expect(decoded.displayText == nil)
        #expect(decoded.content == "hello")
    }
}
