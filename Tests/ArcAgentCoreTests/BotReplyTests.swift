import ArcToolKit
import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - Correlated bot replies (D17)
//
// `send_bot_message` used to deliver a message and return the instant the
// delivery call returned, so every call answered "Message delivered …; no
// reply came back." — even when the peer had answered, and even when the peer
// had never existed as a session.
//
// These tests are the monitors for the path that replaced it:
//
// 1. a peer's turn comes back as the reply to the message that asked;
// 2. two concurrent senders to the SAME peer each keep their own answer, even
//    when the answers arrive out of send order (that is the correlation
//    assertion — a shared stream cannot pass it);
// 3. a peer that never answers costs the caller one bound, leaves no waiter
//    registered, and does not hang the suite.
//
// `SessionHandle.responses` is deliberately not involved: it is a
// single-consumer stream the session host already reads from two loops.
// =========================================================================

extension ArcCoreTestRoot {

    @Suite("Bot reply correlation", .serialized)
    struct BotReplyTests {

        // MARK: - Fixtures

        /// The session layer, in memory.
        ///
        /// Delivery is the one half a test cannot run for real: a real
        /// ``SessionAgent`` builds its model client inside `run()`, so a
        /// delivered message would reach a live provider. The peer below is that
        /// stub — one mailbox and one turn per profile.
        ///
        /// The *reply* half is production code all the way down: a peer's turn
        /// publishes through ``SessionRegistry/publishReply(id:text:)`` into the
        /// real ``BotReplyBus``, and the service awaits through
        /// ``SessionRegistry/registerReplyWaiter(id:)``.
        actor InMemoryPeerSessions: BotPeerSessions {

            /// The reply channel under test; only its waiter API is used.
            private let registry: SessionRegistry

            /// What a peer's turn answers, or nil when the turn produces nothing
            /// (the peer stays silent).
            private let turn: @Sendable (IncomingMessage) -> String?

            /// How long a peer "thinks" before answering — the knob that lets a
            /// test reorder two answers.
            private let thinkTime: @Sendable (IncomingMessage) -> Duration

            /// One inbox per profile, created on first delivery.
            private var mailboxes: [String: AsyncStream<IncomingMessage>.Continuation] = [:]

            init(
                registry: SessionRegistry,
                thinkTime: @escaping @Sendable (IncomingMessage) -> Duration = { _ in .zero },
                turn: @escaping @Sendable (IncomingMessage) -> String?
            ) {
                self.registry = registry
                self.thinkTime = thinkTime
                self.turn = turn
            }

            // MARK: BotPeerSessions

            func registerReplyWaiter(id: String) async -> AsyncStream<String> {
                await registry.registerReplyWaiter(id: id)
            }

            func cancelReplyWaiter(id: String) async {
                await registry.cancelReplyWaiter(id: id)
            }

            func deliver(_ incoming: IncomingMessage, profile: String) async {
                let mailbox: AsyncStream<IncomingMessage>.Continuation
                if let existing = mailboxes[profile] {
                    mailbox = existing
                } else {
                    let (stream, continuation) = AsyncStream<IncomingMessage>.makeStream()
                    mailboxes[profile] = continuation
                    mailbox = continuation
                    startTurns(for: profile, reading: stream)
                }
                mailbox.yield(incoming)
            }

            /// The ids a caller is still waiting on. Empty after a timeout.
            func waitingIDs() async -> [String] {
                await registry.waitingReplyIDs()
            }

            // MARK: Turns

            /// One turn task per message.
            ///
            /// A sequential peer would answer in send order, which hides a
            /// shared-channel bug behind the ordering it produced. Concurrent
            /// turns let the scripted think times actually reorder the answers,
            /// so each sender can only get its own reply if the reply carried
            /// the id of the message that asked.
            private func startTurns(
                for profile: String,
                reading stream: AsyncStream<IncomingMessage>
            ) {
                let turn = self.turn
                let thinkTime = self.thinkTime
                let registry = self.registry
                Task {
                    for await message in stream {
                        Task {
                            let delay = thinkTime(message)
                            if delay > .zero { try? await Task.sleep(for: delay) }
                            guard let text = turn(message) else { return }
                            await registry.publishReply(id: message.id, text: text)
                        }
                    }
                }
            }
        }

        /// The whole `send_bot_message` stack over an isolated profile root.
        private struct Stack {
            let registry: SessionRegistry
            let peers: InMemoryPeerSessions
            let service: BotMessagingService
            let tool: ToolEntry
            let sender: String
            let recipient: String
        }

        // MARK: - Setup

        /// Build the stack over a throwaway profile root.
        ///
        /// Profile names carry a per-run suffix so that, if another suite moves
        /// the shared `testProfilesRoot` seam underneath this one, the canonical
        /// chat file still lands in a throwaway directory rather than a real
        /// profile's.
        private func withStack(
            replyTimeout: Duration = .seconds(5),
            thinkTime: @escaping @Sendable (IncomingMessage) -> Duration = { _ in .zero },
            turn: @escaping @Sendable (IncomingMessage) -> String?,
            _ body: (Stack) async throws -> Void
        ) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-bot-reply-\(UUID().uuidString)", isDirectory: true)
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let sender = "alice-\(suffix)"
            let recipient = "bob-\(suffix)"
            // `getOrCreateCanonicalChat` writes `canonical_chat.txt` inside the
            // recipient's profile directory, so that directory must exist.
            for profile in [sender, recipient] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(profile, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            let previousRoot = ProfileManager.testProfilesRoot
            ProfileManager.testProfilesRoot = root.path
            defer {
                ProfileManager.testProfilesRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            // One roster for both halves: the tool looks the target up, and the
            // service validates sender and recipient on the same store.
            let store = InMemoryProfileStore([
                Profile(name: sender), Profile(name: recipient),
            ])
            let pm = ProfileManager(store: store)
            let registry = SessionRegistry(
                agentConfig: SessionRegistry.AgentConfig(
                    model: "gpt-4o",
                    provider: "openai",
                    baseURL: "https://api.openai.com/v1",
                    apiKey: "test-key"
                ),
                deliveryManager: DeliveryManager(),
                profileManager: pm
            )
            let peers = InMemoryPeerSessions(registry: registry, thinkTime: thinkTime, turn: turn)
            let service = BotMessagingService(profileManager: pm, peers: peers)
            let tool = SendBotMessageTool.entry(
                context: ArcAgentCore.testContext(profile: name(sender)),
                profiles: store,
                messaging: service,
                replyTimeout: replyTimeout
            )
            try await body(Stack(
                registry: registry,
                peers: peers,
                service: service,
                tool: tool,
                sender: sender,
                recipient: recipient
            ))
        }

        private func name(_ rawValue: String) -> ProfileName {
            guard let name = ProfileName(rawValue) else {
                preconditionFailure("'\(rawValue)' is not a valid profile name")
            }
            return name
        }

        // MARK: - The reply reaches the asker

        /// The peer's turn text is what the tool returns. Before the reply path,
        /// this call answered with the "no reply came back" sentence instead.
        @Test("a bot's turn comes back as the reply to the message that asked")
        func replyIsCorrelatedToTheAskingMessage() async throws {
            try await withStack(turn: { "bob saw: \($0.text)" }) { stack in
                let out = try await stack.tool.handler([
                    "target": stack.recipient,
                    "message": "ping",
                ])
                #expect(out == "Reply from '\(stack.recipient)': bob saw: Message from \(stack.sender) (@\(stack.sender)): ping")
            }
        }

        // MARK: - Correlation, not a shared stream

        /// Two senders, one peer, answers that arrive out of send order: the
        /// slow question's answer lands last, so a single shared reply channel
        /// would hand both senders the fast one.
        @Test("two concurrent senders to one peer each get their own reply")
        func concurrentSendersKeepTheirOwnReplies() async throws {
            try await withStack(
                thinkTime: { $0.text.contains("slow") ? .milliseconds(250) : .zero },
                turn: { "bob saw: \($0.text)" }
            ) { stack in
                async let slow = stack.tool.handler([
                    "target": stack.recipient,
                    "message": "slow question",
                ])
                async let fast = stack.tool.handler([
                    "target": stack.recipient,
                    "message": "fast question",
                ])
                let (slowOut, fastOut) = try await (slow, fast)

                #expect(slowOut == "Reply from '\(stack.recipient)': bob saw: Message from \(stack.sender) (@\(stack.sender)): slow question")
                #expect(fastOut == "Reply from '\(stack.recipient)': bob saw: Message from \(stack.sender) (@\(stack.sender)): fast question")
            }
        }

        // MARK: - A silent peer is bounded

        /// A peer that never answers returns the honest timeout sentence, costs
        /// the caller one bound, and leaves no waiter behind.
        @Test("a silent peer times out without hanging or leaking a waiter")
        func silentPeerTimesOut() async throws {
            try await withStack(replyTimeout: .milliseconds(50), turn: { _ in nil }) { stack in
                let started = ContinuousClock.now
                let out = try await stack.tool.handler([
                    "target": stack.recipient,
                    "message": "anyone there?",
                ])
                let elapsed = started.duration(to: .now)

                #expect(out.contains("Timed out after 50ms"))
                #expect(out.contains("'\(stack.recipient)'"))
                #expect(elapsed < .seconds(5), "a silent peer must not hold the turn open")

                // The waiter is gone: a timed-out question is not a leak.
                var waiting = await stack.peers.waitingIDs()
                for _ in 0..<40 where !waiting.isEmpty {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waiting = await stack.peers.waitingIDs()
                }
                #expect(waiting.isEmpty, "a timed-out question must not leave a waiter registered")
            }
        }

        // MARK: - The bus drops what nobody asked for

        /// A turn nobody is waiting on (a human-facing session) publishes into
        /// nothing instead of buffering, and a waited-on id is delivered once
        /// and then forgotten.
        @Test("a reply with no waiter is dropped; a waited-on reply is delivered once")
        func busDropsUnwaitedReplies() async {
            let bus = BotReplyBus()

            #expect(await bus.publish(id: "nobody-asked", text: "hi") == false)
            #expect(await bus.waitingIDs.isEmpty)

            let stream = await bus.register(id: "q1")
            #expect(await bus.waitingIDs == ["q1"])
            #expect(await bus.publish(id: "q1", text: "answer") == true)

            var reply: String?
            for await value in stream { reply = value }
            #expect(reply == "answer")
            #expect(await bus.waitingIDs.isEmpty, "a delivered waiter must be removed")
        }
    }
}
