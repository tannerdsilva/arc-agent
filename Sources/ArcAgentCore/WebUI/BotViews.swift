import Foundation

// MARK: - Bots Page

/// The main bots page that includes the Bots pane, chat area, and Routines pane.
public struct BotsPage: View {
    /// The list of profiles to display.
    public let profiles: [ProfileData]
    /// Currently selected bot name.
    public let selectedBot: String
    /// Welcome message for the chat area.
    public let welcomeMessage: String

    public init(
        profiles: [ProfileData] = [],
        selectedBot: String = "default",
        welcomeMessage: String = "Select a bot to start chatting."
    ) {
        self.profiles = profiles
        self.selectedBot = selectedBot
        self.welcomeMessage = welcomeMessage
    }

    public func render() -> String {
        let selectedProfile = profiles.first { $0.name == selectedBot }

        return """
        <div class="hstack" style="height: 100vh;">
          \(BotsPane(profiles: profiles, selectedBot: selectedBot).render())
          <div class="vstack" style="flex: 1; min-width: 0;">
            \(selectedProfile.map { BotChatHeader(profile: $0).render() } ?? "")
            \(ChatPage(welcomeMessage: welcomeMessage).render())
          </div>
          \(RoutinesPane(profiles: profiles, selectedBot: selectedBot).render())
        </div>
        """
    }
}

// MARK: - Profile Data

/// Serializable profile data for the web UI.
public struct ProfileData: Sendable, Codable {
    public let name: String
    public let title: String
    public let description: String
    public let avatarShape: String
    public let avatarColor: String
    public let avatarImage: String?
    public let lastActive: Double
    public let lastPreview: String
    public let isActive: Bool
    public let isPinned: Bool
    public let group: String?
    public let hasUnread: Bool

    public init(
        name: String,
        title: String = "",
        description: String = "",
        avatarShape: String = "circle",
        avatarColor: String = "#8b5cf6",
        avatarImage: String? = nil,
        lastActive: Double = 0,
        lastPreview: String = "",
        isActive: Bool = false,
        isPinned: Bool = false,
        group: String? = nil,
        hasUnread: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.avatarShape = avatarShape
        self.avatarColor = avatarColor
        self.avatarImage = avatarImage
        self.lastActive = lastActive
        self.lastPreview = lastPreview
        self.isActive = isActive
        self.isPinned = isPinned
        self.group = group
        self.hasUnread = hasUnread
    }

    public var displayName: String { title.isEmpty ? name : title }
    public var handle: String { name.lowercased() }
}

// MARK: - Bots Pane

/// The left-side bot roster panel.
public struct BotsPane: View {
    public let profiles: [ProfileData]
    public let selectedBot: String

    public init(profiles: [ProfileData], selectedBot: String) {
        self.profiles = profiles
        self.selectedBot = selectedBot
    }

    public func render() -> String {
        let activeBots = profiles.filter { $0.isActive }
        let grouped = groupProfiles(profiles)

        return """
        <div class="bots-pane" style="width: 260px;">
          <div class="bots-header">
            <h2>Bots</h2>
            <div class="hstack" style="gap: 4px;">
              <button class="btn-icon" onclick="openNewAgentDialog()" title="New Agent">+</button>
            </div>
          </div>
          \(activeBots.isEmpty ? "" : ActiveNowStrip(bots: activeBots).render())
          <input class="bot-search" id="bot-search" type="text" placeholder="Search bots..." oninput="filterBots(this.value)">
          <div class="bot-roster" id="bot-roster">
            \(renderGroups(grouped))
          </div>
        </div>
        """
    }

    private func renderGroups(_ groups: [(String, [ProfileData])]) -> String {
        groups.map { groupName, bots in
            let isUngrouped = groupName == "__ungrouped__"
            var html = ""

            if !isUngrouped {
                html += """
                <div class="group-header">
                  <span>\(htmlEscape(groupName))</span>
                  <div class="group-separator"></div>
                  \(bots.count >= 2 && bots.count <= 6 ? "<button class=\"btn-icon\" onclick=\"openGroupChat('\(htmlEscape(groupName))')\" title=\"Open group chat\">💬</button>" : "")
                </div>
                """
            }

            for bot in bots {
                html += BotRow(profile: bot, isSelected: bot.name == selectedBot).render()
            }

            return html
        }.joined()
    }

    private func groupProfiles(_ profiles: [ProfileData]) -> [(String, [ProfileData])] {
        var grouped: [String: [ProfileData]] = [:]
        var ungrouped: [ProfileData] = []

        // Pinned first, then by recency
        let sorted = profiles.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.lastActive > b.lastActive
        }

        for bot in sorted {
            if let group = bot.group, !group.isEmpty {
                grouped[group, default: []].append(bot)
            } else {
                ungrouped.append(bot)
            }
        }

        var result: [(String, [ProfileData])] = []
        if !ungrouped.isEmpty {
            result.append(("__ungrouped__", ungrouped))
        }
        for (name, bots) in grouped.sorted(by: { $0.key < $1.key }) {
            result.append((name, bots))
        }
        return result
    }
}

// MARK: - Bot Row

/// A single row in the bot roster.
public struct BotRow: View {
    public let profile: ProfileData
    public let isSelected: Bool

    public init(profile: ProfileData, isSelected: Bool = false) {
        self.profile = profile
        self.isSelected = isSelected
    }

    public func render() -> String {
        let activeClass = isSelected ? " active" : ""
        let unreadHtml = profile.hasUnread ? "<span class=\"unread-badge\">●</span>" : ""
        let activeDot = profile.isActive ? "<span class=\"active-dot\"></span>" : ""

        return """
        <div class="bot-row\(activeClass)" onclick="selectBot('\(htmlEscape(profile.name))')" data-bot="\(htmlEscape(profile.name))">
          \(BotAvatar(profile: profile).render())
          <div class="bot-info">
            <div class="bot-name">\(htmlEscape(profile.displayName)) \(activeDot)</div>
            <div class="bot-preview">\(htmlEscape(String(profile.lastPreview.prefix(60))))</div>
          </div>
          \(unreadHtml)
        </div>
        """
    }
}

// MARK: - Bot Avatar

/// An avatar for a bot in the roster.
public struct BotAvatar: View {
    public let profile: ProfileData
    public let size: Int

    public init(profile: ProfileData, size: Int = 32) {
        self.profile = profile
        self.size = size
    }

    public func render() -> String {
        if let image = profile.avatarImage, !image.isEmpty {
            return """
            <div class="bot-avatar" style="width: \(size)px; height: \(size)px;">
              <img src="\(htmlEscape(image))" alt="">
            </div>
            """
        }

        let shape = profile.avatarShape
        let color = profile.avatarColor
        let s = size

        return """
        <div class="bot-avatar" style="width: \(s)px; height: \(s)px;">
          <svg class="avatar-svg" viewBox="0 0 40 40" width="\(s)" height="\(s)">
            \(shapePath(shape: shape, color: color))
            \(eyeShape(cx: 15.4, cy: 17.2, rx: 2.2, ry: 2.3, fill: eyeFill(color: color))
            + eyeShape(cx: 24.6, cy: 17.2, rx: 2.2, ry: 2.3, fill: eyeFill(color: color)))
          </svg>
        </div>
        """
    }

    private func shapePath(shape: String, color: String) -> String {
        switch shape {
        case "squircle":
            return "<rect x=\"3\" y=\"3\" width=\"34\" height=\"34\" rx=\"11\" fill=\"\(color)\"/>"
        case "pill":
            return "<rect x=\"2\" y=\"7\" width=\"36\" height=\"26\" rx=\"13\" fill=\"\(color)\"/>"
        case "triangle":
            return "<path d=\"M20 5.5 L36 33.5 L4 33.5 Z\" fill=\"\(color)\" stroke=\"\(color)\" stroke-width=\"7\" stroke-linejoin=\"round\"/>"
        case "hexagon":
            return "<path d=\"M20 3.5 L34.5 11.75 L34.5 28.25 L20 36.5 L5.5 28.25 L5.5 11.75 Z\" fill=\"\(color)\" stroke=\"\(color)\" stroke-width=\"7\" stroke-linejoin=\"round\"/>"
        case "cloud":
            return "<path d=\"M11 32 a7.5 7.5 0 0 1 -1 -14.9 A9.5 9.5 0 0 1 29 12.5 A7 7 0 0 1 30 32 Z\" fill=\"\(color)\"/>"
        case "drop":
            return "<path d=\"M20 3 C20 3 6 20 6 27 a14 13.5 0 0 0 28 0 C34 20 20 3 20 3 Z\" fill=\"\(color)\"/>"
        case "blob":
            return "<path d=\"\(blobPath())\" fill=\"\(color)\"/>"
        default: // circle
            return "<circle cx=\"20\" cy=\"20\" r=\"17.5\" fill=\"\(color)\"/>"
        }
    }

    private func eyeShape(cx: Double, cy: Double, rx: Double, ry: Double, fill: String) -> String {
        "<ellipse cx=\"\(cx)\" cy=\"\(cy)\" rx=\"\(rx)\" ry=\"\(ry)\" fill=\"\(fill)\"/>" +
        "<circle cx=\"\(cx - 0.6)\" cy=\"\(cy - 0.7)\" r=\"0.65\" fill=\"rgba(255,255,255,0.85)\"/>"
    }

    private func eyeFill(color: String) -> String {
        // Perceptual luminance check
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let rgb = Int(hex, radix: 16) else {
            return "rgba(0,0,0,0.85)"
        }
        let r = Double((rgb >> 16) & 0xFF)
        let g = Double((rgb >> 8) & 0xFF)
        let b = Double(rgb & 0xFF)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < 110 ? "rgba(232,220,195,0.95)" : "rgba(0,0,0,0.85)"
    }

    private func blobPath() -> String {
        // A simple organic blob shape
        let pts: [(Double, Double)] = [
            (20, 3), (30, 6), (35, 14), (36, 22), (32, 30),
            (26, 36), (14, 36), (8, 30), (4, 22), (5, 14)
        ]
        let d = pts.enumerated().map { i, pt in
            i == 0 ? "M\(pt.0) \(pt.1)" : "L\(pt.0) \(pt.1)"
        }.joined(separator: " ")
        return d + " Z"
    }
}

// MARK: - Active Now Strip

/// The "active now" presence strip above the roster.
public struct ActiveNowStrip: View {
    public let bots: [ProfileData]

    public init(bots: [ProfileData]) {
        self.bots = bots
    }

    public func render() -> String {
        guard !bots.isEmpty else { return "" }

        let chips = bots.map { bot in
            """
            <span class="active-now-chip" onclick="selectBot('\(htmlEscape(bot.name))')">
              <span class="active-dot"></span>
              \(htmlEscape(bot.displayName))
            </span>
            """
        }.joined()

        return """
        <div class="active-now-strip">
          \(chips)
        </div>
        """
    }
}

// MARK: - Bot Chat Header

/// The header shown when chatting with a specific bot.
public struct BotChatHeader: View {
    public let profile: ProfileData

    public init(profile: ProfileData) {
        self.profile = profile
    }

    public func render() -> String {
        """
        <div class="bot-chat-header">
          \(BotAvatar(profile: profile, size: 28).render())
          <div>
            <div class="bot-name">\(htmlEscape(profile.displayName))</div>
            <div class="bot-handle">@\(htmlEscape(profile.handle))</div>
          </div>
          <div class="spacer"></div>
          <span style="font-size: 11px; color: var(--text-muted);">\(htmlEscape(profile.description))</span>
        </div>
        """
    }
}

// MARK: - Routines Pane

/// The right-side routines/cronjobs tile.
public struct RoutinesPane: View {
    public let profiles: [ProfileData]
    public let selectedBot: String

    public init(profiles: [ProfileData], selectedBot: String) {
        self.profiles = profiles
        self.selectedBot = selectedBot
    }

    public func render() -> String {
        let selected = profiles.first { $0.name == selectedBot }

        return """
        <div class="routines-pane" style="width: 250px;">
          <div class="routines-header">
            <div class="hstack" style="gap: 6px; align-items: center;">
              \(selected.map { BotAvatar(profile: $0, size: 18).render() } ?? "")
              <h3>Cronjobs</h3>
            </div>
            <button class="btn-icon" onclick="openNewRoutineDialog()" title="New Cronjob">+</button>
          </div>
          <div class="routines-list">
            <div class="empty-state">
              <div class="icon">📅</div>
              <div>Cronjobs are recurring tasks this agent runs on a schedule.</div>
              <button class="btn-secondary" onclick="openNewRoutineDialog()">Create Cronjob</button>
            </div>
          </div>
        </div>
        """
    }
}

// MARK: - New Agent Dialog

/// The "New Agent" creation dialog.
public struct NewAgentDialog: View {
    public let isOpen: Bool

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    public func render() -> String {
        guard isOpen else { return "" }

        return """
        <div class="dialog-overlay" onclick="closeNewAgentDialog()">
          <div class="dialog-content" onclick="event.stopPropagation()">
            <div class="dialog-title">New Agent</div>
            <form onsubmit="createAgent(event)">
              <label class="form-label">Name</label>
              <input class="form-input" id="agent-name" type="text" placeholder="e.g. researcher" required pattern="[a-z0-9][a-z0-9_-]{1,63}">

              <label class="form-label">Title</label>
              <input class="form-input" id="agent-title" type="text" placeholder="e.g. Research Analyst">

              <label class="form-label">Description</label>
              <textarea class="form-textarea" id="agent-desc" placeholder="What does this agent do?"></textarea>

              <details style="margin-bottom: 12px;">
                <summary style="font-size: 12px; color: var(--text-secondary); cursor: pointer;">Advanced</summary>
                <div style="margin-top: 8px;">
                  <label class="form-label">Clone from</label>
                  <input class="form-input" id="agent-clone" type="text" placeholder="Existing profile name (optional)">

                  <label class="form-label">Model override</label>
                  <input class="form-input" id="agent-model" type="text" placeholder="e.g. gpt-4o (optional)">

                  <label class="form-label">Provider override</label>
                  <input class="form-input" id="agent-provider" type="text" placeholder="e.g. openai (optional)">

                  <label class="form-label">Group</label>
                  <input class="form-input" id="agent-group" type="text" placeholder="Group name (optional)">
                </div>
              </details>

              <div class="form-actions">
                <button type="button" class="btn-secondary" onclick="closeNewAgentDialog()">Cancel</button>
                <button type="submit" class="btn-primary">Create Agent</button>
              </div>
            </form>
          </div>
        </div>
        """
    }
}

// MARK: - HTML Helpers (htmlEscape is defined in Utilities.swift)
