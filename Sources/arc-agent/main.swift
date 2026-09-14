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

            Current phase: vascular hardening — the core plumbing is built and
            the test suite is green; work is focused on making the internal
            data flow reliable, observable, and resilient. See VISION.md for
            the full architecture.
            """,
        subcommands: [
            Chat.self,
            Serve.self,
            Setup.self,
            Tools.self,
            Profile.self,
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

    @Option(name: .long, help: "Resume a persisted session by ID.")
    var session: String?

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

        let registry = try await MutableToolRegistry.make(enabledPlugins: pluginAllowList())

        // Storage: with a `tessera` configuration, sessions and memory are
        // persisted to the Tessera server as signed NOSTR events. If the
        // relay is unreachable (bounded handshake), fall back to file
        // storage so the agent never hangs or crashes on storage.
        let sessionStore: any SessionStore
        let memoryProvider: (any MemoryProvider)?
        if let tessera = arcConfig.tessera {
            await TesseraConnection.shared.configure(tessera)
            if await TesseraConnection.shared.healthCheck() {
                sessionStore = TesseraSessionStore()
                memoryProvider = TesseraMemoryProvider()
            } else {
                Logger(label: "arc-agent").warning(
                    "Tessera relay unreachable (handshake timed out); falling back to file storage for this run"
                )
                sessionStore = FileSessionStore()
                memoryProvider = FileMemoryProvider()
            }
        } else {
            sessionStore = FileSessionStore()
            memoryProvider = FileMemoryProvider()
        }

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
            sessionStore: sessionStore,
            memoryProvider: memoryProvider,
            skills: skills,
            maxIterations: arcConfig.agent.maxIterations,
            persistSessions: arcConfig.agent.persistSessions,
            approvalMode: approvalMode,
            query: query,
            sessionID: session,
            contextLength: arcConfig.model.contextLength,
            moa: arcConfig.moa,
            reasoningEffort: arcConfig.agent.reasoningEffort,
            maxOutputTokens: arcConfig.model.maxOutputTokens
        )

        let agent = ArcAgent(config: agentConfig)

        if let query {
            // Single-query mode: stream the reply like Hermes — visible
            // tokens and tool activity instead of a silent wait.
            do {
                for try await chunk in agent.streamConversation(message: query) {
                    print(chunk, terminator: "")
                    // fflush is safe on TTYs and pipes; synchronizeFile would
                    // raise NSFileHandleOperationException on a pipe.
                    fflush(stdout)
                }
            } catch {
                print("\nError: \(error.localizedDescription)")
            }
            await agent.shutdownHTTPClient()
            // Tear the Tessera tunnel down before process exit so the
            // dependency's client is never deinitialized half-open (that
            // trap killed the CLI whenever the relay wedged).
            await TesseraConnection.shared.shutdown()
        } else {
            // Interactive mode: wrap in ServiceGroup for lifecycle management
            let serviceGroup = ServiceGroup(
                configuration: .init(
                    services: [agent],
                    logger: Logger(label: "arc-agent")
                )
            )
            try await serviceGroup.run()
            await TesseraConnection.shared.shutdown()
        }
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

        // Tessera storage for the gateway: sessions, memory, and the profile
        // index all flow through the shared connection.
        if let tessera = arcConfig.tessera {
            await TesseraConnection.shared.configure(tessera)
        }

        let agentConfig = SessionRegistry.AgentConfig(
            model: arcConfig.model.defaultModel,
            provider: arcConfig.model.provider,
            baseURL: arcConfig.model.baseURL ?? "https://api.openai.com/v1",
            apiKey: ProcessInfo.processInfo.environment["ARC_API_KEY"] ?? "",
            tessera: arcConfig.tessera,
            persistSessions: arcConfig.agent.persistSessions
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
        let registry = try await MutableToolRegistry.make(enabledPlugins: pluginAllowList())
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
        print("Phase: vascular hardening")
    }
}

// MARK: - Profile

struct Profile: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Manage agent profiles (bots).",
        subcommands: [
            ProfileList.self,
            ProfileCreate.self,
            ProfileDelete.self,
            ProfileShow.self,
        ]
    )
}

struct ProfileList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all profiles."
    )

    func run() async throws {
        let manager = ProfileManager()
        let profiles = try await manager.list()

        print("⚡ ARC Agent — Profiles")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for p in profiles {
            let avatar = p.avatar.map { "\($0.shape) \($0.color)" } ?? "default"
            let group = p.group.map { " [\($0)]" } ?? ""
            print("  \(p.name)\(group)")
            print("     Title: \(p.title.isEmpty ? "(none)" : p.title)")
            print("     Model: \(p.model ?? "(default)")")
            print("     Avatar: \(avatar)")
            print("")
        }
        print("Total: \(profiles.count) profile(s)")
    }
}

struct ProfileCreate: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new profile."
    )

    @Argument(help: "Profile name (lowercase, alphanumeric, hyphens).")
    var name: String

    @Option(name: .long, help: "Display title.")
    var title: String = ""

    @Option(name: .long, help: "Description.")
    var description: String = ""

    @Option(name: .long, help: "Clone from an existing profile.")
    var cloneFrom: String?

    @Option(name: .long, help: "Context window size in tokens (Hermes context_length).")
    var contextLength: Int?

    @Option(name: .long, help: "Max output tokens.")
    var maxOutputTokens: Int?

    @Option(name: .long, help: "Reasoning effort (minimal/low/medium/high/max).")
    var reasoningEffort: String?

    @Option(name: .long, help: "Sampling temperature (0.0-2.0).")
    var temperature: Double?

    @Option(name: .long, help: "Nucleus sampling threshold (0.0-1.0).")
    var topP: Double?

    @Option(name: .long, help: "Auto-compress threshold in tokens.")
    var compressionBudget: Int?

    @Option(name: .long, help: "Model override.")
    var model: String?

    @Option(name: .long, help: "Provider override.")
    var provider: String?

    @Option(name: .long, help: "Group name.")
    var group: String?

    func run() async throws {
        let manager = ProfileManager()
        var profile = try await manager.create(name: name, cloneFrom: cloneFrom)
        profile.title = title
        profile.description = description
        profile.model = model
        profile.provider = provider
        profile.group = group
        let ctx = ProfileContextConfig(
            contextLength: contextLength,
            maxOutputTokens: maxOutputTokens,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            topP: topP,
            compressionBudget: compressionBudget
        )
        profile.context = ctx.isEmpty ? nil : ctx
        try await manager.update(profile)
        print("✅ Profile '\(name)' created.")
    }
}

struct ProfileDelete: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a profile."
    )

    @Argument(help: "Profile name to delete.")
    var name: String

    func run() async throws {
        let manager = ProfileManager()
        try await manager.delete(name: name)
        print("✅ Profile '\(name)' deleted.")
    }
}

struct ProfileShow: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show profile details."
    )

    @Argument(help: "Profile name.")
    var name: String

    func run() async throws {
        let manager = ProfileManager()
        guard let profile = try await manager.get(name: name) else {
            print("Error: Profile '\(name)' not found.")
            return
        }

        print("⚡ Profile: \(profile.name)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Title:       \(profile.title.isEmpty ? "(none)" : profile.title)")
        print("  Description: \(profile.description.isEmpty ? "(none)" : profile.description)")
        print("  Model:       \(profile.model ?? "(default)")")
        print("  Provider:    \(profile.provider ?? "(default)")")
        print("  Base URL:    \(profile.baseURL ?? "(default)")")
        print("  Group:       \(profile.group ?? "(none)")")
        print("  Pinned:      \(profile.isPinned)")
        print("  Created:     \(profile.createdAt)")
        print("  Updated:     \(profile.updatedAt)")
        if let context = profile.context, !context.isEmpty {
            print("  Context window: \(context.contextLength.map { String($0) } ?? "(default)") tokens")
            print("  Max output:     \(context.maxOutputTokens.map { String($0) } ?? "(default)") tokens")
            print("  Reasoning:      \(context.reasoningEffort ?? "(default)")")
            print("  Temperature:    \(context.temperature.map { String($0) } ?? "(default)")")
            print("  Top P:          \(context.topP.map { String($0) } ?? "(default)")")
            print("  Compress at:    \(context.compressionBudget.map { String($0) } ?? "(default)") tokens")
        }
        if let avatar = profile.avatar {
            print("  Avatar:      \(avatar.shape) \(avatar.color)")
        }
        if let soul = profile.soulMD {
            let preview = soul.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines)
            print("  SOUL.md:     \(preview)...")
        }
    }
}
