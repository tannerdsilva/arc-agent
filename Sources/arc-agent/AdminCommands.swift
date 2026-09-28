import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Sessions

/// `arc sessions` — inspect the session store (Hermes `hermes sessions`
/// CLI surface, subset: list / show / delete).

struct SessionsCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Inspect persisted sessions.",
        subcommands: [SessionsList.self, SessionsShow.self, SessionsDelete.self]
    )
}

struct SessionsList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all sessions (summaries)."
    )

    @Option(name: .shortAndLong, help: "Maximum sessions to show.")
    var limit: Int = 20

    func run() async throws {
        let store = FileSessionStore()
        let sessions = try await store.list(limit: limit)
        if sessions.isEmpty {
            print("No persisted sessions.")
            return
        }
        print("⚡ ARC Agent — Sessions")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for s in sessions {
            let title = s.title ?? "(untitled)"
            let date = ISO8601DateFormatter().string(from: s.updatedAt)
            print("  \(s.id)")
            print("     \(title) — \(s.messageCount) messages — \(s.model) [\(date)]")
        }
        print("Total: \(sessions.count) session(s)")
    }
}

struct SessionsShow: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one session (materializes messages)."
    )

    @Argument(help: "Session ID.")
    var id: String

    func run() async throws {
        let store = FileSessionStore()
        guard let session = try await store.get(id: id) else {
            print("Error: Session '\(id)' not found.")
            return
        }
        print("⚡ Session: \(session.id)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Title:    \(session.title ?? "(untitled)")")
        print("  Model:    \(session.model)")
        print("  Created:  \(session.createdAt)")
        print("  Updated:  \(session.updatedAt)")
        print("")
        for message in session.messages {
            let prefix: String
            switch message.role {
            case .user: prefix = "🧑 user"
            case .assistant: prefix = "🤖 assistant"
            case .system: prefix = "⚙️ system"
            case .tool: prefix = "🔧 tool"
            }
            let body = (message.content ?? "").prefix(400)
            print("── \(prefix)")
            print(body)
            print("")
        }
    }
}

struct SessionsDelete: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a session."
    )

    @Argument(help: "Session ID.")
    var id: String

    func run() async throws {
        let store = FileSessionStore()
        try await store.delete(id: id)
        print("✅ Session '\(id)' deleted.")
    }
}

// MARK: - Memory

/// `arc memory` — inspect the (active profile's) memory store.

struct MemoryCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Inspect the memory store.",
        subcommands: [MemoryShow.self, MemoryList.self]
    )
}

struct MemoryShow: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the memory block (the agent's memory context)."
    )

    func run() async throws {
        let provider = FileMemoryProvider()
        let content = try await provider.readMemory()
        print("⚡ ARC Agent — Memory")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print(content.isEmpty ? "(empty)" : content)
    }
}

struct MemoryList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List individual memory entries."
    )

    func run() async throws {
        let store = MemoryStore(provider: FileMemoryProvider())
        let entries = try await store.entries("memory")
        let userEntries = try await store.entries("user")
        print("⚡ ARC Agent — Memory entries")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("memory:")
        for line in entries where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            print("  § \(line)")
        }
        print("user:")
        for line in userEntries where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            print("  § \(line)")
        }
    }
}

// MARK: - Skills

/// `arc skills` — list discovered skills.

struct SkillsCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "skills",
        abstract: "Inspect the skills directory.",
        subcommands: [
            SkillsList.self, SkillsAudit.self, SkillsUsage.self,
            SkillsProvenance.self, SkillsSync.self,
        ]
    )
}

struct SkillsList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List discovered skills."
    )

    @Option(name: .long, help: "Skills directory (default: ~/.arc/skills).")
    var directory: String?

    func run() async throws {
        let dir = directory.map { URL(fileURLWithPath: $0) }
        let skills = discoverSkills(in: dir)
        if skills.isEmpty {
            print("No skills discovered.")
            return
        }
        print("⚡ ARC Agent — Skills")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for s in skills {
            let category = s.category ?? "(general)"
            let tags = s.tags.isEmpty ? "" : " — tags: \(s.tags.joined(separator: ", "))"
            print("  \(s.name) [\(category)]\(tags)")
            print("     \(s.description.prefix(140))")
        }
        print("Total: \(skills.count) skill(s)")
    }
}

// MARK: - Kanban

/// `arc kanban` — inspect the kanban board.

struct KanbanCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "kanban",
        abstract: "Inspect the kanban board.",
        subcommands: [KanbanList.self]
    )
}

struct KanbanList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List kanban tasks."
    )

    @Option(name: .long, help: "Filter by status.")
    var status: String?

    @Option(name: .long, help: "Maximum tasks.")
    var limit: Int = 50

    func run() async throws {
        let board = FileKanbanBoard()
        let statusFilter = status.flatMap { TaskStatus(rawValue: $0) }
        let tasks = try await board.list(status: statusFilter, limit: limit)
        if tasks.isEmpty {
            print("No kanban tasks.")
            return
        }
        print("⚡ ARC Agent — Kanban")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for t in tasks {
            print("  [\(t.status)] P\(t.priority) \(t.title) — \(t.id.prefix(8))")
        }
        print("Total: \(tasks.count) task(s)")
    }
}

// MARK: - Cron

/// `arc cron` — inspect cron jobs.

struct CronCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "cron",
        abstract: "Inspect cron jobs.",
        subcommands: [CronList.self]
    )
}

struct CronList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all cron jobs."
    )

    func run() async throws {
        let store = FileCronStore()
        let jobs = try await store.listAll()
        if jobs.isEmpty {
            print("No cron jobs.")
            return
        }
        print("⚡ ARC Agent — Cron jobs")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for j in jobs {
            print("  \(j.id.prefix(8)) — \(j.schedule) — \(j.name ?? "(unnamed)")")
            print("     \(String(describing: j.prompt.prefix(140)))")
        }
        print("Total: \(jobs.count) job(s)")
    }
}

// MARK: - Config

/// `arc config` — inspect configuration.

struct ConfigCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect configuration.",
        subcommands: [ConfigShow.self]
    )
}

struct ConfigShow: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the resolved configuration."
    )

    func run() async throws {
        let config = loadConfig()
        print("⚡ ARC Agent — Configuration")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Path:  ~/.arc/config.json")
        print("  Model: \(config.model.defaultModel) (\(config.model.provider))")
        print("  Context length: \(config.model.contextLength)")
        print("  Approval mode:  \(config.security.approvalMode)")
        print("  Max turns:      \(config.max_turns ?? 0)")
        print("  Web search:     \(config.web.effectiveSearchBackend ?? "(auto)" )")
        print("  MCP servers:    \(config.mcpServers.isEmpty ? "(none)" : config.mcpServers.keys.joined(separator: ", "))")
        print("  Tessera:        \(config.tessera != nil ? "configured" : "(none)")")
    }
}

// MARK: - MCP

/// `arc mcp` — inspect configured MCP servers.

struct McpCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Inspect configured MCP servers.",
        subcommands: [McpList.self]
    )
}

struct McpList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List configured MCP servers."
    )

    func run() async throws {
        let config = loadConfig()
        if config.mcpServers.isEmpty {
            print("No MCP servers configured.")
            return
        }
        print("⚡ ARC Agent — MCP servers")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for (name, server) in config.mcpServers {
            print("  \(name): \(server.command) \(server.args.joined(separator: " "))")
        }
    }
}
