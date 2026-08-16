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
            Serve.self,
            Setup.self,
            Tools.self,
            Version.self,
        ]
    )
}

// MARK: - Chat

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

    @Flag(name: .shortAndLong, help: "Enable YOLO mode (no approval prompts).")
    var yolo: Bool = false

    func run() async throws {
        let arcConfig = loadConfig()

        let resolvedModel = model ?? ProcessInfo.processInfo.environment["ARC_MODEL"]
            ?? arcConfig.model.defaultModel
        let resolvedBaseURL = baseURL
            ?? ProcessInfo.processInfo.environment["ARC_BASE_URL"]
            ?? arcConfig.model.baseURL
            ?? "https://api.openai.com/v1"
        let resolvedApiKey = apiKey
            ?? ProcessInfo.processInfo.environment["ARC_API_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""

        guard !resolvedApiKey.isEmpty else {
            print("Error: No API key found. Set ARC_API_KEY or OPENAI_API_KEY, or pass --api-key.")
            print("       Run `arc setup` to configure your API key.")
            return
        }

        guard let url = URL(string: resolvedBaseURL) else {
            print("Error: Invalid base URL '\(resolvedBaseURL)'.")
            return
        }

        let registry = try ArcAgentCore.buildDefaultRegistry()

        // Discover skills if enabled
        let skills: [Skill] = arcConfig.agent.loadSkills ? discoverSkills() : []

        // Resolve approval mode
        let approvalMode: ApprovalMode = yolo ? .off
            : ApprovalMode(rawValue: arcConfig.security.approvalMode) ?? .manual

        let agentConfig = ArcAgent.Configuration(
            model: resolvedModel,
            provider: arcConfig.model.provider,
            baseURL: url,
            apiKey: resolvedApiKey,
            registry: registry,
            skills: skills,
            maxIterations: arcConfig.agent.maxIterations,
            persistSessions: arcConfig.agent.persistSessions,
            approvalMode: approvalMode,
            query: query
        )

        let agent = ArcAgent(config: agentConfig)

        if query != nil {
            print("⚡ ARC Agent — \(resolvedModel)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }

        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [agent],
                logger: Logger(label: "arc-agent")
            )
        )
        try await serviceGroup.run()
    }
}

// MARK: - Serve

struct Serve: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the gateway server daemon."
    )

    @Option(name: .shortAndLong, help: "HTTP server host.")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "HTTP server port.")
    var port: Int = 8080

    @Option(name: .long, help: "Telegram bot token.")
    var telegramToken: String?

    func run() async throws {
        let arcConfig = loadConfig()
        let logger = Logger(label: "arc-agent.gateway")

        let agentConfig = SessionRegistry.AgentConfig(
            model: arcConfig.model.defaultModel,
            provider: arcConfig.model.provider,
            baseURL: arcConfig.model.baseURL ?? "https://api.openai.com/v1",
            apiKey: ProcessInfo.processInfo.environment["ARC_API_KEY"] ?? ""
        )

        let gateway = GatewayService(
            host: host,
            port: port,
            telegramToken: telegramToken ?? ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"],
            agentConfig: agentConfig
        )

        print("⚡ ARC Agent Gateway")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("HTTP server: http://\(host):\(port)")
        if telegramToken != nil || ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] != nil {
            print("Telegram: enabled")
        }
        print("")

        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [gateway],
                logger: logger
            )
        )

        try await serviceGroup.run()
    }
}

// MARK: - Setup

struct Setup: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Configure ARC Agent for first use."
    )

    func run() async throws {
        print("⚡ ARC Agent Setup")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")

        var config = ArcConfig()

        // Provider
        print("Available providers:")
        for provider in BundledProviders.unique {
            print("  \(provider.name) — \(provider.description)")
        }
        print("")
        print("Enter provider name [\(config.model.provider)]: ", terminator: "")
        if let input = readLine(), !input.isEmpty {
            config.model.provider = input
        }

        // Model
        print("Enter default model [\(config.model.defaultModel)]: ", terminator: "")
        if let input = readLine(), !input.isEmpty {
            config.model.defaultModel = input
        }

        // Base URL
        if let profile = BundledProviders.resolve(config.model.provider) {
            print("Base URL: \(profile.baseURL.absoluteString)")
        } else {
            print("Enter base URL [\(config.model.baseURL ?? "https://api.openai.com/v1")]: ", terminator: "")
            if let input = readLine(), !input.isEmpty {
                config.model.baseURL = input
            }
        }

        // Approval mode
        print("")
        print("Approval mode (manual / smart / off) [\(config.security.approvalMode)]: ", terminator: "")
        if let input = readLine(), !input.isEmpty {
            config.security.approvalMode = input
        }

        // Save config
        try saveConfig(config)
        print("")
        print("✅ Configuration saved to ~/.arc/config.json")
        print("")
        print("Next steps:")
        print("  1. Set your API key: export ARC_API_KEY=sk-...")
        print("     Or add it to ~/.arc/.env")
        print("  2. Run: arc chat -q \"hello world\"")
    }
}

// MARK: - Tools

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

// MARK: - Version

struct Version: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the version."
    )

    func run() async throws {
        print("arc-agent \(ArcAgentCore.version)")
        print("Phase: phase 2 — production readiness")
    }
}
