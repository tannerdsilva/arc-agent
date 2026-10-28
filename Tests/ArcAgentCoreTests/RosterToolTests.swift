import Testing
@testable import ArcAgentCore
import Foundation

// MARK: - Roster tools (GROUNDZERO slice 5)
//
// Four defects live here, and each test is the monitor for one:
//
// - `create_profile` applied `model` / `provider` / `group` / `description`
//   only inside its `title` branch, then wrote the record twice.
// - `clone_from` naming a profile the roster did not hold created an
//   un-cloned profile and said nothing.
// - `delete_profile` had no confirmation and would happily delete the profile
//   the caller was running as.
// - `send_bot_message` and `send_group_chat` returned "Message sent…" without
//   delivering anything.
extension ArcCoreTestRoot {

    @Suite("Roster tools")
    struct RosterToolTests {

        // MARK: - Fixtures

        /// Run `body` against an isolated profile root. `create_profile`
        /// writes the profile's directory through `ProfileManager.profilesDir`,
        /// so that seam is the one the fixture moves.
        private func withProfileRoot(_ body: () async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-roster-tools-\(UUID().uuidString)", isDirectory: true)
            ProfileManager.testProfilesRoot = root.path
            defer {
                ProfileManager.testProfilesRoot = nil
                try? FileManager.default.removeItem(at: root)
            }
            try await body()
        }

        private func name(_ rawValue: String) -> ProfileName {
            guard let name = ProfileName(rawValue) else {
                preconditionFailure("'\(rawValue)' is not a valid profile name")
            }
            return name
        }

        // MARK: - create_profile

        /// The pinned RED: every optional is applied on its own, so a model
        /// with no title is still a model. One `put`, not two.
        @Test("create_profile applies every option without a title, in one write")
        func createAppliesEveryOptionInOneWrite() async throws {
            try await withProfileRoot {
                let store = InMemoryProfileStore()
                _ = try await CreateProfileTool.entry(profiles: store).handler([
                    "name": "model-only",
                    "model": "some-model",
                    "provider": "some-provider",
                    "group": "research",
                    "description": "does research",
                ])

                let created = try await store.get(name("model-only"))
                #expect(created?.model == "some-model")
                #expect(created?.provider == "some-provider")
                #expect(created?.group == "research")
                #expect(created?.description == "does research")
                // No title was passed, and none was invented.
                #expect(created?.title == "")

                let writes = await store.putCount
                #expect(writes == 1)
            }
        }

        /// A clone that names a profile the roster does not hold is a caller
        /// mistake: refuse it instead of creating a silently un-cloned profile.
        /// A clone that names a real profile still copies its config, and an
        /// explicit option still wins over the cloned value.
        @Test("create_profile refuses a missing clone_from and still clones a real one")
        func createRefusesMissingCloneSource() async throws {
            try await withProfileRoot {
                let store = InMemoryProfileStore([Profile(name: "alice", title: "Alice")])
                let tool = CreateProfileTool.entry(profiles: store)

                await #expect(throws: ProfileError.self) {
                    _ = try await tool.handler([
                        "name": "ghost-clone",
                        "clone_from": "nobody-here",
                    ])
                }
                let ghost = try await store.get(name("ghost-clone"))
                #expect(ghost == nil)
                let writesAfterRefusal = await store.putCount
                #expect(writesAfterRefusal == 0)

                _ = try await tool.handler([
                    "name": "alice-clone",
                    "clone_from": "alice",
                    "model": "override-model",
                ])
                let clone = try await store.get(name("alice-clone"))
                #expect(clone?.title == "Alice")
                #expect(clone?.model == "override-model")
            }
        }

        // MARK: - delete_profile

        /// The caller's own profile is the one identity it cannot destroy.
        @Test("delete_profile refuses the profile the caller is running as")
        func deleteRefusesOwnProfile() async throws {
            try await withProfileRoot {
                let store = InMemoryProfileStore([
                    Profile(name: "alice"), Profile(name: "bob"),
                ])
                let tool = DeleteProfileTool.entry(
                    context: ArcAgentCore.testContext(profile: name("alice")),
                    profiles: store
                )

                let out = try await tool.handler(["name": "alice", "confirm": true])
                #expect(out.contains("Refusing"))
                #expect(out.contains("running as"))

                let stillThere = try await store.get(name("alice"))
                #expect(stillThere != nil)
                let deletes = await store.deleteCount
                #expect(deletes == 0)
            }
        }

        /// Without `confirm: true` nothing is deleted — not on a missing field,
        /// not on `false`. With it, the delete happens.
        @Test("delete_profile deletes nothing without confirm: true")
        func deleteRequiresConfirm() async throws {
            try await withProfileRoot {
                let store = InMemoryProfileStore([
                    Profile(name: "alice"), Profile(name: "bob"),
                ])
                let tool = DeleteProfileTool.entry(
                    context: ArcAgentCore.testContext(profile: name("alice")),
                    profiles: store
                )

                let missing = try await tool.handler(["name": "bob"])
                #expect(missing.contains("confirm: true"))
                let refusedFalse = try await tool.handler(["name": "bob", "confirm": false])
                #expect(refusedFalse.contains("confirm: true"))

                let bob = try await store.get(name("bob"))
                #expect(bob != nil)
                let deletesBefore = await store.deleteCount
                #expect(deletesBefore == 0)

                let deleted = try await tool.handler(["name": "bob", "confirm": true])
                #expect(deleted.contains("deleted"))
                let gone = try await store.get(name("bob"))
                #expect(gone == nil)
                let deletesAfter = await store.deleteCount
                #expect(deletesAfter == 1)
            }
        }

        // MARK: - Messaging

        /// The peer's reply comes back through the tool, the message reaches
        /// the delivery seam with the caller's identity, and a peer that never
        /// answers inside the bound produces a timeout sentence instead of a
        /// hang or a throw.
        @Test("send_bot_message returns the peer's reply, and times out cleanly")
        func sendBotMessageDeliversAndReturnsReply() async throws {
            try await withProfileRoot {
                let store = InMemoryProfileStore([
                    Profile(name: "alice"), Profile(name: "bob", title: "Bob"),
                ])
                let sent = SentLog()
                let tool = SendBotMessageTool.entry(
                    context: ArcAgentCore.testContext(profile: name("alice")),
                    profiles: store,
                    messaging: CannedReplyMessaging(reply: "on it", sent: sent)
                )

                let reply = try await tool.handler(["target": "bob", "message": "ping"])
                #expect(reply == "Reply from 'bob': on it")

                // The delivery actually happened, addressed from the caller.
                let delivered = await sent.messages
                #expect(delivered.count == 1)
                #expect(delivered.first?.from == "alice")
                #expect(delivered.first?.to == "bob")
                #expect(delivered.first?.body == "ping")
                // The display name comes from the roster, not the slug.
                #expect(delivered.first?.fromDisplay == "alice")

                // A silent peer: bounded wait, clear answer, no throw.
                let silent = SendBotMessageTool.entry(
                    context: ArcAgentCore.testContext(profile: name("alice")),
                    profiles: store,
                    messaging: LateReplyMessaging(delay: .seconds(1)),
                    replyTimeout: .milliseconds(50)
                )
                let timedOut = try await silent.handler(["target": "bob", "message": "anyone there?"])
                #expect(timedOut.contains("Timed out after 50ms"))
                #expect(timedOut.contains("'bob'"))
            }
        }

        /// The message lands in the room's log, addressed to the room the
        /// roster's group assignment defines. A group with no room and no
        /// members is refused rather than "delivered" where nobody reads it.
        @Test("send_group_chat posts into the room's log")
        func sendGroupChatPostsIntoRoom() async throws {
            try await withProfileRoot {
                var alice = Profile(name: "alice")
                alice.group = "research"
                var bob = Profile(name: "bob")
                bob.group = "research"
                let store = InMemoryProfileStore([alice, bob])
                let rooms = GroupChatManager(profileManager: ProfileManager())
                let tool = SendGroupChatTool.entry(
                    context: ArcAgentCore.testContext(profile: name("alice")),
                    profiles: store,
                    groupChats: rooms
                )

                let out = try await tool.handler(["group": "research", "message": "status?"])
                #expect(out.contains("group chat 'research'"))
                #expect(out.contains("2 members"))

                let room = await rooms.get(name: "research")
                #expect(room != nil)
                let log = await room?.roomLog ?? []
                #expect(log.contains { $0.text == "status?" && $0.from.isUser })

                let refused = try await tool.handler(["group": "ghost", "message": "hi"])
                #expect(refused.contains("No group chat 'ghost'"))
            }
        }
    }
}
