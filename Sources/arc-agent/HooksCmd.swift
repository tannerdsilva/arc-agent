import ArgumentParser
import Foundation
import ArcAgentCore

// MARK: - Hooks (reference `hermes hooks list`)

/// List configured event hooks (file-backed gateway hooks + outbound targets).
struct HooksCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "List event hooks and outbound webhook targets (reference `hermes hooks list`)."
    )

    /// Accepts `arc hooks list` (reference) and bare `arc hooks`.
    @Argument(help: "Subcommand (accepts `list`); bare invocation lists hooks.")
    var subcommand: String? = nil

    func run() async throws {
        if let subcommand, subcommand != "list" {
            throw ValidationError("Unknown hooks subcommand '\(subcommand)' (expected: list).")
        }
        let config = loadConfig()

        print("📡 Event Hooks summary")
        print(String(repeating: "=", count: 70))

        // File-backed gateway hooks.
        await HookBus.shared.loadFileHooks()
        let fileHooks = await HookBus.shared.fileHookSummaries()
        print("\nGateway hooks (file-backed, `~/.arc/hooks/<name>/HOOK.yaml`):")
        if fileHooks.isEmpty {
            print("  (none)")
        } else {
            for hook in fileHooks {
                print("  - \(hook.name): \(hook.events.joined(separator: ", "))\(hook.description.isEmpty ? "" : " — \(hook.description)")")
            }
        }

        // Outbound targets.
        print("\nOutbound webhooks (`hooks.outbound` in config):")
        if config.hooks.outbound.isEmpty {
            print("  (none)")
        } else {
            for target in config.hooks.outbound {
                let signed = target.resolvedSecret()?.isEmpty == false
                print("  - \(target.name ?? target.url)  \(target.events.joined(separator: ", "))  \(signed ? "[signed]" : "[UNSIGNED]")")
                if let matcher = target.matcher, !matcher.isEmpty {
                    print("      matcher: \(matcher)")
                }
            }
        }

        print("\nPlugin hooks are registered programmatically (see HookBus.register).")
    }
}
