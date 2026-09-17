import Foundation

// MARK: - Profile-based inbound routing
//
// Faithful port of Hermes `gateway/profile_routing.py` (docs/profile-routing.md):
// a single gateway routes per-platform / guild / channel / thread inbound
// messages to a dedicated profile, each with its own model, tools, memory, and
// persona. Matching is conjunctive (every declared discriminator must hold),
// `chat_id` matches hierarchically (a route keyed on a channel also matches
// threads whose parent is that channel), and specificity decides between
// multiple matches: thread 8 > chat 4 > guild 2 > platform-only 0.
//
// Wired into ``GatewayService``: when `multiplexProfiles` is off the routes are
// ignored entirely (Hermes parity — behavior is byte-identical to the
// single-profile gateway).

/// One routing rule mapping a platform scope to a profile.
public struct ProfileRoute: Codable, Sendable, Equatable, Hashable {
    /// Human-readable route name (config bookkeeping only).
    public var name: String
    /// Platform identifier ("telegram", "discord", "slack", "api", ...).
    public var platform: String
    /// Target profile name; must exist in ``ProfileManager``.
    public var profile: String
    /// Guild/server discriminator.
    public var guildID: String?
    /// Channel/chat discriminator (matches a thread via its parent channel too).
    public var chatID: String?
    /// Exact thread/topic discriminator.
    public var threadID: String?
    /// Disabled routes never match (kept for config round-tripping).
    public var enabled: Bool

    public init(
        name: String,
        platform: String,
        profile: String,
        guildID: String? = nil,
        chatID: String? = nil,
        threadID: String? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.platform = platform
        self.profile = profile
        self.guildID = guildID
        self.chatID = chatID
        self.threadID = threadID
        self.enabled = enabled
    }

    /// Higher = more specific match (Hermes tables: thread 8, chat 4, guild 2,
    /// platform-only 0).
    public var specificity: Int {
        (guildID != nil ? 2 : 0) + (chatID != nil ? 4 : 0) + (threadID != nil ? 8 : 0)
    }

    /// All declared discriminators are matched conjunctively (AND). `chatID`
    /// supports hierarchical matching: a direct channel match
    /// (`chatID == route.chatID`) or a thread/post whose parent channel is the
    /// route's chat (`parentChatID == route.chatID`). A route declaring both
    /// `guildID` and `chatID` requires both to hold — a channel match alone
    /// does not satisfy a guild constraint (intentional and tested in Hermes).
    public func matches(
        platform sourcePlatform: String,
        guildID sourceGuildID: String? = nil,
        chatID sourceChatID: String? = nil,
        threadID sourceThreadID: String? = nil,
        parentChatID sourceParentChatID: String? = nil
    ) -> Bool {
        guard enabled else { return false }
        guard self.platform == sourcePlatform else { return false }
        if let t = threadID, t != sourceThreadID { return false }
        if let c = chatID, c != sourceChatID, c != sourceParentChatID { return false }
        if let g = guildID, g != sourceGuildID { return false }
        return true
    }
}

/// Gateway-side routing config (`~/.arc/config.json` → `profile_routing`).
public struct ProfileRoutingConfig: Codable, Sendable, Equatable {
    /// Route table. Only honored when `multiplexProfiles` is true.
    public var routes: [ProfileRoute]
    /// `gateway.multiplex_profiles` — with this off, routes are ignored.
    public var multiplexProfiles: Bool

    public init(routes: [ProfileRoute] = [], multiplexProfiles: Bool = false) {
        self.routes = routes
        self.multiplexProfiles = multiplexProfiles
    }

    /// Routes sorted most-specific-first, exactly like Hermes'
    /// `parse_profile_routes` so the first-match walk is deterministic.
    public var sortedRoutes: [ProfileRoute] {
        routes.sorted { lhs, rhs in
            if lhs.specificity != rhs.specificity {
                return lhs.specificity > rhs.specificity
            }
            return false // stable: keep declaration order among ties
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.routes = try container.decodeIfPresent([ProfileRoute].self, forKey: .routes) ?? []
        self.multiplexProfiles = try container.decodeIfPresent(Bool.self, forKey: .multiplexProfiles) ?? false
    }
}

public enum ProfileRouteResolver {

    /// Best-matching route for a source, or nil when no route matches.
    /// Hermes `match_profile_route` returns the FIRST match over the sorted
    /// (most-specific-first) list; the same result here: highest specificity,
    /// ties broken by declaration order.
    public static func resolve(
        _ routes: [ProfileRoute],
        platform: String,
        guildID: String? = nil,
        chatID: String? = nil,
        threadID: String? = nil,
        parentChatID: String? = nil
    ) -> ProfileRoute? {
        // Hermes `parse_profile_routes` sorts most-specific-first and
        // `match_profile_route` returns the first match. Same net result here:
        // iterate highest specificity first, declaration order among ties.
        let ordered = routes.sorted { lhs, rhs in
            if lhs.specificity != rhs.specificity {
                return lhs.specificity > rhs.specificity
            }
            return false // stable
        }
        for route in ordered where route.matches(
            platform: platform,
            guildID: guildID,
            chatID: chatID,
            threadID: threadID,
            parentChatID: parentChatID
        ) {
            return route
        }
        return nil
    }

    /// The profile an inbound message should run under, or nil for the
    /// default. With `multiplexProfiles` off the route table is ignored
    /// entirely (Hermes parity).
    public static func profile(
        for chat: ChatTarget,
        routes: [ProfileRoute],
        multiplexProfiles: Bool
    ) -> String? {
        guard multiplexProfiles, !routes.isEmpty else { return nil }
        return resolve(
            routes,
            platform: chat.platform,
            guildID: chat.guildID,
            chatID: chat.chatID,
            threadID: chat.threadID,
            parentChatID: chat.parentChatID
        )?.profile
    }
}
