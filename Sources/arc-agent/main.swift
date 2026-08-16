import ArgumentParser
import ArcAgentCore

@main
struct Arc: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "arc",
        abstract: "A Swift-native AI agent harness.",
        discussion:
            """
            ARC Agent is a precompiled, Swift-native AI agent harness —
            deterministic, predictable, and efficient.

            This is an early-stage project. Most commands are not yet
            implemented. See VISION.md for the full architecture.
            """,
        subcommands: [
            Chat.self,
            Version.self,
        ]
    )
}

// MARK: - Subcommands

struct Chat: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Start an interactive conversation."
    )

    @Option(name: .shortAndLong, help: "Single query, non-interactive.")
    var query: String?

    @Option(name: .shortAndLong, help: "Model to use.")
    var model: String?

    func run() async throws {
        print("⚡ ARC Agent — chat mode")
        print("   This is a prototype. The agent loop is not yet wired.")
        if let q = query {
            print("   Query: \(q)")
        }
        if let m = model {
            print("   Model: \(m)")
        }
    }
}

struct Version: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the version."
    )

    func run() async throws {
        print("arc-agent 0.0.0")
        print("Phase: blue sky")
    }
}
