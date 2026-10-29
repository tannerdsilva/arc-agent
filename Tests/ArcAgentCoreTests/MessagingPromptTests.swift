import Foundation
import Testing
@testable import ArcAgentCore

/// GROUNDZERO slice 6 — the agent-to-agent protocol reaches the sessions that
/// can actually use it, and nowhere else.
///
/// The daemon injects a profile's SOUL as a system message. This suite pins the
/// composition: the messaging section rides along **only** when the session's
/// surface carries `send_bot_message`, and a SOUL that already documents the
/// protocol is not given it twice.
@Suite("Messaging prompt")
struct MessagingPromptTests {

    // MARK: - Fixtures

    /// The daemon's session surface, with and without the messaging services.
    ///
    /// Both come from the same `buildRegistry` call the daemon makes, so the
    /// presence of `send_bot_message` is decided by the production
    /// register-when-available rule (D21), not by this test.
    static func surface(withMessaging: Bool) throws -> MutableToolRegistry {
        let builtIn = try ArcAgentCore.buildRegistry(
            context: ArcAgentCore.testContext(),
            profiles: TesseraProfileStore.shared,
            memory: FileMemoryProvider(),
            sessions: FileSessionStore(),
            messaging: withMessaging ? CannedReplyMessaging(reply: "ack") : nil,
            groupChats: nil
        )
        return MutableToolRegistry(builtIn: builtIn)
    }

    static let bot = Profile(name: "scout", title: "Research Analyst")
    static let peer = Profile(name: "quill", title: "Technical Writer")

    /// The daemon file, for the one wiring assertion a prompt test cannot make
    /// behaviourally (running a real turn needs a model).
    static var daemonSource: String {
        (try? String(contentsOfFile: "Sources/ArcAgentCore/Daemon/SessionAgent.swift", encoding: .utf8)) ?? ""
    }

    // MARK: - Tests

    @Test("a session whose surface carries send_bot_message is told the protocol")
    func messagingSurfaceGetsProtocol() throws {
        let registry = try Self.surface(withMessaging: true)
        #expect(registry.lookup(name: "send_bot_message") != nil)

        let message = try #require(sessionSystemMessage(
            soul: "You are Scout.",
            registry: registry,
            profile: Self.bot,
            roster: [Self.bot, Self.peer]
        ))

        #expect(message.contains("## Messaging other agents"))
        // The teammate list names the OTHER agent, never the speaker.
        #expect(message.contains("`quill` — Technical Writer"))
        #expect(!message.contains("`scout`"))
        // The SOUL is preserved, leads, and is separated from the section by
        // exactly one blank line.
        #expect(message.hasPrefix("You are Scout.\n\n## Messaging other agents"))

        // And the daemon session is what injects it.
        #expect(Self.daemonSource.contains("sessionSystemMessage("))
    }

    @Test("a session whose surface does not carry it is not told about it")
    func plainSurfaceGetsNoProtocol() throws {
        let registry = try Self.surface(withMessaging: false)
        #expect(registry.lookup(name: "send_bot_message") == nil)

        let message = sessionSystemMessage(
            soul: "You are Scout.",
            registry: registry,
            profile: Self.bot,
            roster: [Self.bot, Self.peer]
        )

        // A CLI-shaped surface keeps its SOUL and learns nothing about a tool
        // it does not have.
        #expect(message == "You are Scout.")

        // With no SOUL either, there is nothing to inject at all.
        #expect(sessionSystemMessage(
            soul: nil,
            registry: registry,
            profile: Self.bot,
            roster: [Self.bot, Self.peer]
        ) == nil)
    }

    @Test("a SOUL that already documents the protocol is not given it twice")
    func soulWithProtocolIsNotDuplicated() throws {
        let registry = try Self.surface(withMessaging: true)
        let heading = "## Messaging other agents"
        let soul = "# Scout" + "\n\n" + heading + "\n\nAsk Quill; she writes the docs.\n"

        let message = try #require(sessionSystemMessage(
            soul: soul,
            registry: registry,
            profile: Self.bot,
            roster: [Self.bot, Self.peer]
        ))

        #expect(message.components(separatedBy: heading).count - 1 == 1)
        #expect(message.hasPrefix("# Scout"))
        #expect(message.contains("Ask Quill; she writes the docs."))
    }
}
