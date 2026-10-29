import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - Group-room member turns (D18) and late arrivals (D20)
//
// A room's log used to hold exactly one line: the user's. `executeMemberTurn`
// returned `nil` unconditionally ("the full session routing integration
// requires the daemon to be running"), so every member turn was a silent pass
// and a room could never answer. `GroupChatManager.setMessagingService` stored
// the service for rooms created *afterwards* only, and `getOrCreate` fixed
// membership at creation, so a profile assigned to the group later never joined.
//
// These four tests are the monitors for the repaired path:
//
// 1. a user message produces at least one member entry in the log;
// 2. a member that answers `(pass)` adds nothing — but was genuinely asked
//    (the silence is a decision, not a missing turn);
// 3. a profile assigned to the group after the room existed joins on the next
//    round and speaks;
// 4. a room created *before* `setMessagingService` receives the service.
//
// The reply half is production code all the way down: the room calls
// `BotMessagingService.ask`, which registers a waiter on the real
// ``BotReplyBus`` via ``SessionRegistry``, and the peer stub publishes into the
// same bus. Only delivery is stubbed — a real ``SessionAgent`` builds its model
// client inside `run()`, so delivering there would reach a live provider.
// =========================================================================

extension ArcCoreTestRoot {

    @Suite("Group room turns", .serialized)
    struct GroupRoomTurnTests {

        // MARK: - Fixtures

        /// The session layer, in memory: one mailbox and one turn per profile.
        ///
        /// Every delivery is recorded, so a test can prove the room actually
        /// asked the member (and with which sender id) rather than inferring it
        /// from a reply that a stub could have produced for another reason.
        actor RoomPeerSessions: BotPeerSessions {

            /// The reply channel under test; only its waiter API is used.
            private let registry: SessionRegistry

            /// What a peer's turn answers, or `nil` for a peer that never
            /// answers at all.
            private let turn: @Sendable (IncomingMessage) -> String?

            /// One inbox per profile, created on first delivery.
            private var mailboxes: [String: AsyncStream<IncomingMessage>.Continuation] = [:]

            /// Every message the room delivered, in order.
            private(set) var deliveries: [(profile: String, message: IncomingMessage)] = []

            init(
                registry: SessionRegistry,
                turn: @escaping @Sendable (IncomingMessage) -> String?
            ) {
                self.registry = registry
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
                deliveries.append((profile: profile, message: incoming))

                let mailbox: AsyncStream<IncomingMessage>.Continuation
                if let existing = mailboxes[profile] {
                    mailbox = existing
                } else {
                    let (stream, continuation) = AsyncStream<IncomingMessage>.makeStream()
                    mailboxes[profile] = continuation
                    mailbox = continuation
                    startTurns(reading: stream)
                }
                mailbox.yield(incoming)
            }

            // MARK: Introspection

            /// A copy of the delivery record (an actor's tuple array is not
            /// sendable as-is through an `await` boundary).
            func delivered() -> [Delivered] {
                deliveries.map { Delivered(profile: $0.profile, id: $0.message.id,
                                           text: $0.message.text, senderID: $0.message.senderID) }
            }

            /// The ids a caller is still waiting on. Empty when nothing leaked.
            func waitingIDs() async -> [String] {
                await registry.waitingReplyIDs()
            }

            struct Delivered: Sendable {
                let profile: String
                let id: String
                let text: String
                let senderID: String
            }

            // MARK: Turns

            /// One turn task per message, so a peer that answers immediately
            /// cannot block the room's next delivery.
            private func startTurns(reading stream: AsyncStream<IncomingMessage>) {
                let turn = self.turn
                let registry = self.registry
                Task {
                    for await message in stream {
                        guard let text = turn(message) else { continue }
                        await registry.publishReply(id: message.id, text: text)
                    }
                }
            }
        }

        /// A room, its roster, and the stub session layer behind it.
        private struct RoomStack {
            let store: InMemoryProfileStore
            let service: BotMessagingService
            let peers: RoomPeerSessions
            let manager: GroupChatManager
        }

        /// Build a room stack over an in-memory roster.
        ///
        /// - Parameters:
        ///   - seeded: the roster at creation time (each profile's `group`
        ///     decides whether it belongs to the room).
        ///   - members: the room's initial membership.
        ///   - wireService: `false` leaves the manager (and therefore the room)
        ///     without a messaging service, which is the state a room exists in
        ///     before the host wires one.
        ///   - turn: what a member answers when asked.
        private func withRoom(
            room: String = "research",
            seeded: [Profile],
            members: [String],
            wireService: Bool = true,
            turn: @escaping @Sendable (IncomingMessage) -> String?,
            _ body: (RoomStack) async throws -> Void
        ) async throws {
            let store = InMemoryProfileStore(seeded)
            let profileManager = ProfileManager(store: store)
            let registry = SessionRegistry(
                agentConfig: SessionRegistry.AgentConfig(
                    model: "gpt-4o",
                    provider: "openai",
                    baseURL: "https://api.openai.com/v1",
                    apiKey: "unused-by-the-stub"
                ),
                deliveryManager: DeliveryManager(),
                profileManager: profileManager
            )
            let peers = RoomPeerSessions(registry: registry, turn: turn)
            let service = BotMessagingService(profileManager: profileManager, peers: peers)
            let manager = GroupChatManager(profileManager: profileManager)

            if wireService {
                await manager.setMessagingService(service)
            }
            _ = await manager.getOrCreate(
                name: room,
                members: members.map { GroupChatRoom.Member(name: $0) }
            )

            try await body(RoomStack(
                store: store,
                service: service,
                peers: peers,
                manager: manager
            ))
        }

        private func member(named: String, in group: String) -> Profile {
            var profile = Profile(name: named)
            profile.group = group
            return profile
        }

        // MARK: - D18: a member actually speaks

        /// Before the fix the log held only the user's line: `executeMemberTurn`
        /// returned `nil` for everyone, unconditionally.
        @Test("one user message produces a member entry in the log")
        func userMessageProducesMemberEntry() async throws {
            try await withRoom(
                seeded: [member(named: "alice", in: "research"), member(named: "bob", in: "research")],
                members: ["alice", "bob"],
                turn: { _ in "alice and bob both answer" }
            ) { stack in
                guard let room = await stack.manager.get(name: "research") else {
                    Issue.record("the room was not created")
                    return
                }
                await room.sendUserMessage("status?")

                let log = await room.roomLog
                #expect(log.first?.from.isUser == true, "the user's line comes first")
                let memberEntries = log.filter { !$0.from.isUser }
                #expect(!memberEntries.isEmpty, "a room with two answering members must log a member entry")
                #expect(memberEntries.allSatisfy { $0.text == "alice and bob both answer" })

                // Both members were asked, and the room's own identity — not a
                // profile — is the sender of the turn prompt.
                let delivered = await stack.peers.delivered()
                #expect(Set(delivered.map(\.profile)) == ["alice", "bob"])
                #expect(delivered.allSatisfy { $0.senderID == "group:research" })
                #expect(await stack.peers.waitingIDs().isEmpty, "an answered question leaves no waiter behind")
            }
        }

        // MARK: - (pass) stays silent

        /// `(pass)` means "nothing to add". The member must still have been
        /// asked — a room that never calls its members would pass this by
        /// accident otherwise.
        @Test("a member that answers (pass) adds nothing to the log")
        func passAddsNothing() async throws {
            try await withRoom(
                seeded: [member(named: "alice", in: "research"), member(named: "bob", in: "research")],
                members: ["alice", "bob"],
                turn: { _ in "(pass)" }
            ) { stack in
                guard let room = await stack.manager.get(name: "research") else {
                    Issue.record("the room was not created")
                    return
                }
                await room.sendUserMessage("anyone?")

                let log = await room.roomLog
                #expect(log.count == 1, "a full round of passes settles the room")
                #expect(log.allSatisfy { $0.from.isUser })

                let delivered = await stack.peers.delivered()
                #expect(!delivered.isEmpty, "the member was asked and chose to pass")
                #expect(await stack.peers.waitingIDs().isEmpty, "a pass leaves no waiter behind")
            }
        }

        // MARK: - D20: a late arrival joins

        /// A profile assigned to the group *after* the room was created joins on
        /// the next round. `getOrCreate` fixed membership at creation, so carol
        /// was invisible to the room forever.
        @Test("a profile assigned to the group after creation joins the next round")
        func lateAssignmentJoins() async throws {
            try await withRoom(
                seeded: [member(named: "alice", in: "research")],
                members: ["alice"],
                turn: { _ in "carol is here too" }
            ) { stack in
                guard let room = await stack.manager.get(name: "research") else {
                    Issue.record("the room was not created")
                    return
                }
                let before = await room.members.map(\.name)
                #expect(before == ["alice"])

                // Assigned in the roster, not in the room.
                try await stack.store.put(member(named: "carol", in: "research"))

                await room.sendUserMessage("hello room")

                let after = await room.members.map(\.name)
                #expect(after.contains("carol"), "a profile assigned to the group must join the room")
                #expect(after.contains("alice"), "an existing member is never dropped")

                let delivered = await stack.peers.delivered()
                #expect(delivered.contains { $0.profile == "carol" }, "carol must get a turn, not just a seat")

                let log = await room.roomLog
                #expect(log.contains { $0.from == .member(name: "carol") })
            }
        }

        // MARK: - The service reaches rooms that already exist

        /// `setMessagingService` stored the service for future rooms only, so a
        /// room created before the host wired the service stayed mute for the
        /// life of the process.
        @Test("a room created before setMessagingService still receives it")
        func servicePropagatesToExistingRooms() async throws {
            try await withRoom(
                seeded: [member(named: "alice", in: "research"), member(named: "bob", in: "research")],
                members: ["alice", "bob"],
                wireService: false,
                turn: { _ in "wired after the room existed" }
            ) { stack in
                guard let room = await stack.manager.get(name: "research") else {
                    Issue.record("the room was not created")
                    return
                }

                await stack.manager.setMessagingService(stack.service)

                await room.sendUserMessage("anyone there?")

                let log = await room.roomLog
                #expect(log.contains { $0.text == "wired after the room existed" })
            }
        }
    }
}
