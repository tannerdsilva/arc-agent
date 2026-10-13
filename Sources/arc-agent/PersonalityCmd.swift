import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Personality CLI (reference `/personality`, `features/personality.md`)

/// `arc personality` — set, list, or clear named personality overlays.
struct PersonalityCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "personality",
        abstract: "Set, list, or clear named personality overlays.",
        subcommands: [PersonalityList.self, PersonalitySet.self, PersonalityClear.self]
    )
}

struct PersonalityList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Show available personalities and the active one."
    )

    func run() throws {
        let config = loadConfig()
        let overlays = config.agent.personalities
        print("Available personalities:")
        if overlays.isEmpty {
            print("  (none configured — add an `agent.personalities` block to config.json)")
        }
        for (name, overlay) in overlays.sorted(by: { $0.key < $1.key }) {
            print("  \(name)<12) - \(overlay.preview())")
        }
        let active = config.agent.systemPrompt
        print()
        print(active.isEmpty
            ? "Active personality: none (base agent behavior)"
            : "Active personality: \(String(active.prefix(60)))\(active.count > 60 ? "…" : "")")
    }
}

struct PersonalitySet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Activate a named personality (saved to config). Use `none` to clear."
    )

    @Argument(help: "Personality name from config's agent.personalities, or 'none'.")
    var name: String

    func run() async throws {
        var config = loadConfig()
        let normalized = name.lowercased()
        if ["none", "default", "neutral"].contains(normalized) {
            config.agent.systemPrompt = ""
            try saveConfig(config)
            print("(^_^)b Personality cleared (saved to config).")
            print("  No personality overlay — using base agent behavior.")
            return
        }
        guard let overlay = config.agent.personalities[normalized] ?? config.agent.personalities[name] else {
            let available = config.agent.personalities.keys.sorted().joined(separator: ", ")
            print("(._.) Unknown personality: \(name)")
            print("  Available: none\(available.isEmpty ? "" : ", \(available)")")
            return
        }
        config.agent.systemPrompt = overlay.resolve()
        try saveConfig(config)
        let preview = overlay.resolve()
        print("(^_^)b Personality set to '\(name)' (saved to config).")
        print("  \"\(String(preview.prefix(60)))\(preview.count > 60 ? "…" : "")\"")
    }
}

struct PersonalityClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Clear the active personality overlay."
    )

    func run() async throws {
        var config = loadConfig()
        config.agent.systemPrompt = ""
        try saveConfig(config)
        print("(^_^)b Personality cleared (saved to config).")
    }
}
