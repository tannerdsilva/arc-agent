import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Profile-based inbound routing (docs/profile-routing.md) parity tests

@Suite("Profile routing")
struct ProfileRoutingTests {

    private func route(
        _ name: String = "r",
        platform: String = "discord",
        guildID: String? = nil,
        chatID: String? = nil,
        threadID: String? = nil,
        profile: String = "p",
        enabled: Bool = true
    ) -> ProfileRoute {
        ProfileRoute(
            name: name, platform: platform, profile: profile,
            guildID: guildID, chatID: chatID, threadID: threadID, enabled: enabled
        )
    }

    @Test("specificity weights: thread 8, chat 4, guild 2, platform-only 0")
    func specificity() {
        #expect(route(threadID: "t").specificity == 8)
        #expect(route(chatID: "c").specificity == 4)
        #expect(route(guildID: "g").specificity == 2)
        #expect(route().specificity == 0)
        #expect(route(chatID: "c", threadID: "t").specificity == 12)
    }

    @Test("all declared discriminators match conjunctively (AND)")
    func conjunctive() {
        let r = route(guildID: "g1", chatID: "c1")
        // Chat match alone does not satisfy a guild constraint.
        #expect(!r.matches(platform: "discord", chatID: "c1"))
        #expect(!r.matches(platform: "discord", guildID: "g1"))
        #expect(r.matches(platform: "discord", guildID: "g1", chatID: "c1"))
        // Platform must match exactly.
        #expect(!r.matches(platform: "telegram", guildID: "g1", chatID: "c1"))
    }

    @Test("chat_id matches hierarchically: thread whose parent is the channel")
    func hierarchicalParent() {
        let channel = route(chatID: "channel-1")
        #expect(channel.matches(platform: "discord", chatID: "channel-1"))
        // Message in a thread whose parent is the channel.
        #expect(channel.matches(platform: "discord", chatID: "thread-9", parentChatID: "channel-1"))
        // Unrelated parent does not match.
        #expect(!channel.matches(platform: "discord", chatID: "thread-9", parentChatID: "other"))
    }

    @Test("disabled routes never match")
    func disabledRoute() {
        let r = route(chatID: "c", enabled: false)
        #expect(!r.matches(platform: "discord", chatID: "c"))
    }

    @Test("thread route beats channel route beats guild route")
    func mostSpecificWins() {
        let routes = [
            route("guild", guildID: "g1", profile: "guild-profile"),
            route("channel", guildID: "g1", chatID: "c1", profile: "channel-profile"),
            route("thread", guildID: "g1", chatID: "c1", threadID: "t1", profile: "thread-profile"),
        ]
        let resolved = ProfileRouteResolver.resolve(
            routes, platform: "discord",
            guildID: "g1", chatID: "c1", threadID: "t1"
        )
        #expect(resolved?.name == "thread")
        let channelHit = ProfileRouteResolver.resolve(
            routes, platform: "discord",
            guildID: "g1", chatID: "c1"
        )
        #expect(channelHit?.name == "channel")
        let guildHit = ProfileRouteResolver.resolve(
            routes, platform: "discord", guildID: "g1"
        )
        #expect(guildHit?.name == "guild")
    }

    @Test("ties resolve to the first declared route (declaration order)")
    func tieBreaks() {
        let routes = [
            route("first", chatID: "c", profile: "a"),
            route("second", chatID: "c", profile: "b"),
        ]
        let resolved = ProfileRouteResolver.resolve(routes, platform: "discord", chatID: "c")
        #expect(resolved?.name == "first")
    }

    @Test("no match returns nil")
    func noMatch() {
        let routes = [route(chatID: "c")]
        #expect(ProfileRouteResolver.resolve(routes, platform: "discord", chatID: "other") == nil)
        #expect(ProfileRouteResolver.resolve(routes, platform: "telegram", chatID: "c") == nil)
        #expect(ProfileRouteResolver.resolve([], platform: "discord", chatID: "c") == nil)
    }

    @Test("routes are ignored entirely when multiplexing is off")
    func multiplexGate() {
        let routes = [route(chatID: "c", profile: "routed")]
        let chat = ChatTarget(platform: "discord", chatID: "c")
        let profile = ProfileRouteResolver.profile(for: chat, routes: routes, multiplexProfiles: false)
        #expect(profile == nil)
        let on = ProfileRouteResolver.profile(for: chat, routes: routes, multiplexProfiles: true)
        #expect(on == "routed")
    }

    @Test("source carries guild/parent for thread routing through ChatTarget")
    func chatTargetCarries() {
        let chat = ChatTarget(
            platform: "discord", chatID: "thread-7",
            threadID: "thread-7", guildID: "g1", parentChatID: "channel-3"
        )
        let routes = [route(chatID: "channel-3", profile: "chan-profile")]
        #expect(ProfileRouteResolver.profile(for: chat, routes: routes, multiplexProfiles: true) == "chan-profile")
    }

    @Test("config round-trips routes and the multiplex gate")
    func configRoundTrip() throws {
        let config = ProfileRoutingConfig(
            routes: [
                route("tg-work", platform: "telegram", chatID: "42", profile: "work"),
                route("guild", guildID: "g9", profile: "server"),
            ],
            multiplexProfiles: true
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProfileRoutingConfig.self, from: data)
        #expect(decoded.multiplexProfiles)
        #expect(decoded.routes.count == 2)
        #expect(decoded.routes[0].profile == "work")
        #expect(decoded.sortedRoutes[0].name == "tg-work") // thread-less, chat route outranks guild
    }

    @Test("old configs without the profileRouting block decode to defaults")
    func oldConfigDecodes() throws {
        let json = #"{"model":{"defaultModel":"x","provider":"y"}}"#
        let config = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
        #expect(config.profileRouting.routes.isEmpty)
        #expect(!config.profileRouting.multiplexProfiles)
    }
}
