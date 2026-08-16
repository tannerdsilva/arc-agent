import ArgumentParser
import ArcAgentCore
import Foundation
import Logging
import ServiceLifecycle

@main
struct Arc: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "arc",
        abstract: "A Swift-native AI agent harness.",
        discussion: """
            ARC Agent is a precompiled, Swift-native AI agent harness —
            deterministic, predictable, and efficient.

            This is an early-stage project. Most commands are not yet
            implemented. See VISION.md for the full architecture.
            """,
        subcommands: [
            Chat.self,
            Tools.self,
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

    @Option(name: .shortAndLong, help: "API base URL.")
    var baseURL: String?

    @Option(name: .shortAndLong, help: "API key.")
    var apiKey: String?

    func run() async throws {
        let resolvedModel = model ?? ProcessInfo.processInfo.environment["ARC_MODEL"] ?? "gpt-4o"
        let resolvedBaseURL = baseURL
            ?? ProcessInfo.processInfo.environment["ARC_BASE_URL"]
            ?? "https://api.openai.com/v1"
        let resolvedApiKey = apiKey
            ?? ProcessInfo.processInfo.environment["ARC_API_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""

        guard !resolvedApiKey.isEmpty else {
            print("Error: No API key found. Set ARC_API_KEY or OPENAI_API_KEY, or pass --api-key.")
            return
        }

        guard let url = URL(string: resolvedBaseURL) else {
            print("Error: Invalid base URL '\(resolvedBaseURL)'.")
            return
        }

        let registry = try ArcAgentCore.buildDefaultRegistry()

        let config = ArcAgent.Configuration(
            model: resolvedModel,
            baseURL: url,
            apiKey: resolvedApiKey,
            registry: registry,
            query: query
        )

        let agent = ArcAgent(config: config)

        if query != nil {
            print("⚡ ARC Agent — \(resolvedModel)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }

        // The ServiceGroup manages the agent's lifecycle — the HTTP client
        // is created in ArcAgent.run() and shut down when the group exits.
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [agent],
                logger: Logger(label: "arc-agent")
            )
        )
        try await serviceGroup.run()
    }
}

struct Tools: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "List registered tools and their schemas."
    )

    func run() async throws {
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let tools = registry.allTools

        print("⚡ ARC Agent — Registered Tools")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for tool in tools {
            let emoji = tool.emoji ?? "🔧"
            print("\(emoji) \(tool.name) [\(tool.toolset)]")
            print("   \(tool.description)")
            print("")
        }
        print("Total: \(tools.count) tool(s)")
    }
}

struct Version: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the version."
    )

    func run() async throws {
        print("arc-agent \(ArcAgentCore.version)")
        print("Phase: phase 1 — core agent")
    }
}
