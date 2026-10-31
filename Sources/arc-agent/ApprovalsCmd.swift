import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Approvals

/// `arc approvals` — approval posture helpers (reference `reference approvals`
/// CLI surface).
struct ApprovalsCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "approvals",
        abstract: "Inspect and tune the approval flow.",
        subcommands: [ApprovalsSuggest.self]
    )
}

/// `arc approvals suggest` — mine session history for commands the user has
/// repeatedly approved and propose `security.alwaysAllowedCommands` entries.
/// Nothing is written unless `--apply` is passed.
struct ApprovalsSuggest: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: "Suggest always-allow commands from your session history."
    )

    @Flag(help: "Write the proposed commands into ~/.arc/config.json security.alwaysAllowedCommands.")
    var apply: Bool = false

    @Option(name: .shortAndLong, help: "Minimum number of observed approvals for a proposal.")
    var min: Int = 3

    @Option(name: .shortAndLong, help: "Maximum recent sessions to scan.")
    var sessions: Int = 60

    func run() async throws {
        let store = FileSessionStore()
        let summaries = try await store.list(limit: sessions)

        var materialized: [Session] = []
        for summary in summaries {
            if let session = try await store.get(id: summary.id) {
                materialized.append(session)
            }
        }

        let configStore = ConfigurationStore(url: ArcHome.config)
        // A file this process cannot read makes `--apply` pointless: fail with
        // the parse error instead of analysing against compiled defaults.
        if apply, let failure = await configStore.failure() { throw failure }
        let config = await configStore.declared()
        let alwaysAllowed = Set(
            config.security.alwaysAllowedCommands.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
        let proposals = await ApprovalSuggester.analyze(
            sessions: materialized,
            minFrequency: max(1, min),
            alwaysAllowed: alwaysAllowed
        )

        print("Scanned \(materialized.count) session(s).")
        print("")
        print(ApprovalSuggester.render(proposals))

        guard apply, !proposals.isEmpty else { return }

        // read-modify-write inside the store: the append sees the file as it is
        // now, and a file the store cannot decode is refused, not replaced.
        let commands = proposals.map { $0.command }
        let snapshot = try await configStore.mutate { config in
            var list = config.security.alwaysAllowedCommands
            for command in commands where !list.contains(command) {
                list.append(command)
            }
            if list != config.security.alwaysAllowedCommands {
                config.security.alwaysAllowedCommands = list
            }
        }
        let added = snapshot.declared.security.alwaysAllowedCommands.count
            - config.security.alwaysAllowedCommands.count
        print("Applied \(added) command(s) to security.alwaysAllowedCommands in ~/.arc/config.json.")
    }
}
