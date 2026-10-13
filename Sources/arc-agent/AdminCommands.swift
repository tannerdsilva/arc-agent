import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Sessions

/// `arc sessions` — inspect the session store (reference `reference sessions`
/// CLI surface, subset: list / show / delete).

struct SessionsCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Inspect persisted sessions.",
        subcommands: [SessionsList.self, SessionsShow.self, SessionsDelete.self,
                      SessionsExport.self, SessionsPrune.self, SessionsRename.self]
    )
}

struct SessionsList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all sessions (summaries)."
    )

    @Option(name: .shortAndLong, help: "Maximum sessions to show.")
    var limit: Int = 20

    @Option(name: .long, help: "Filter by source platform (cli, telegram, …).")
    var source: String?

    @Option(name: .long, help: "Filter by workspace key subtarget (path or basename).")
    var workspace: String?

    func run() async throws {
        let store = FileSessionStore()
        let sessions = try await store.list(limit: limit)
        let filtered = sessions.filter { s in
            if let source, s.source != source { return false }
            if let needle = workspace, let key = s.workspaceKey {
                let keyURL = URL(fileURLWithPath: key)
                let base = keyURL.lastPathComponent
                if !key.contains(needle) && base != needle { return false }
            }
            return true
        }
        if filtered.isEmpty {
            print("No persisted sessions.")
            return
        }
        print("⚡ ARC Agent — Sessions")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for s in filtered {
            let title = s.title ?? "—"
            let date = ISO8601DateFormatter().string(from: s.updatedAt)
            print("  \(s.id)")
            print("     \(title) — \(s.messageCount) messages — \(s.model) [\(date)]")
        }
        print("Total: \(filtered.count) session(s)")
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
            print("  \(j.id.prefix(8)) — \(j.schedule) — \(j.name)")
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
        print("  Context length: \(String(describing: config.model.contextLength))")
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

// MARK: - Sessions export (reference `hermes sessions export`)

struct SessionsExport: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export sessions (jsonl default, or trace; --redact scrubs secrets)."
    )

    @Argument(help: "Output file path (or `-` for stdout).")
    var output: String

    @Option(name: .long, help: "Export format: jsonl (default) or trace.")
    var format: String = "jsonl"

    @Option(name: .long, help: "Export a single session by ID.")
    var sessionID: String?

    @Flag(name: .long, help: "Scrub API keys/tokens/credentials from the export.")
    var redact = false

    func run() async throws {
        let store = FileSessionStore()
        let sessions: [Session]
        if let id = sessionID {
            guard let s = try await store.get(id: id) else {
                throw ValidationError("Session \(id) not found.")
            }
            sessions = [s]
        } else {
            // Materialize full histories (list returns summaries).
            var full: [Session] = []
            for summary in try await store.list(limit: 5000) {
                if let s = try await store.get(id: summary.id) { full.append(s) }
            }
            sessions = full
        }
        var bytes = Data()
        for session in sessions {
            switch format {
            case "trace":
                bytes.append(try SessionExporter.traceRecord(session: redact ? redacted(session) : session))
            default:
                bytes.append(try SessionExporter.jsonlRecord(session: session, redacted: redact))
            }
        }
        if output == "-" {
            FileHandle.standardOutput.write(bytes)
        } else {
            try bytes.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("Exported \(sessions.count) session(s) to \(output)")
        }
    }

    private func redacted(_ session: Session) -> Session {
        var s = session
        s.systemPrompt = s.systemPrompt.map(SessionExporter.redact)
        s.messages = s.messages.map { m in
            Message(role: m.role, content: m.content.map(SessionExporter.redact), name: m.name,
                    toolCalls: m.toolCalls, toolCallID: m.toolCallID, reasoning: m.reasoning,
                    terminalReason: m.terminalReason)
        }
        return s
    }
}

// MARK: - Sessions prune (reference `hermes sessions prune`)

struct SessionsPrune: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Delete ended sessions inactive for N days (default 90)."
    )

    @Option(name: .long, help: "Minimum inactive days (default 90).")
    var olderThan: Int?

    @Option(name: .long, help: "Only prune sessions from this source platform.")
    var source: String?

    @Flag(name: .long, help: "Skip confirmation.")
    var yes = false

    func run() async throws {
        let store = FileSessionStore()
        let all = try await store.list(limit: 5000)
        let filter = SessionPruneFilter(olderThanDays: olderThan, source: source)
        let doomed = all.filter { filter.matches($0, now: Date()) }
        if doomed.isEmpty {
            print("Nothing to prune.")
            return
        }
        print("Will delete \(doomed.count) ended session(s):")
        for s in doomed.prefix(20) {
            print("  \(s.id) — \(s.title ?? "(untitled)")")
        }
        guard yes else {
            print("Run with --yes to confirm.")
            return
        }
        for s in doomed {
            try await store.delete(id: s.id)
        }
        print("Deleted \(doomed.count) session(s).")
    }
}

// MARK: - Sessions rename (reference `hermes sessions rename`)

struct SessionsRename: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a session (title rules: unique, max 100 chars, sanitized)."
    )

    @Argument(help: "Session ID.")
    var id: String

    @Argument(help: "New title.")
    var newTitle: String

    func run() async throws {
        let store = FileSessionStore()
        guard var session = try await store.get(id: id) else {
            throw ValidationError("Session \(id) not found.")
        }
        session.title = SessionTitle.sanitized(newTitle)
        try await store.update(session)
        print("Renamed to: \(session.title ?? "")")
    }
}
