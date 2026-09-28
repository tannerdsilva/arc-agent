import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Checkpoints CLI (Hermes `hermes checkpoints`)

/// `arc checkpoints` — git-backed workspace snapshots with rollback.
struct CheckpointsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkpoints",
        abstract: "Snapshot and roll back project working trees (git-backed).",
        subcommands: [
            CheckpointsStatus.self, CheckpointsSnapshot.self, CheckpointsList.self,
            CheckpointsRestore.self, CheckpointsPrune.self, CheckpointsClear.self,
        ]
    )
}

func checkpointStore() throws -> CheckpointStore { try CheckpointStore() }

struct CheckpointsStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show checkpoint health (default).")
    @Option() var limit: Int = 20
    func run() async throws {
        let store = try checkpointStore()
        var total = 0
        for key in await store.projectKeys().sorted() {
            let list = await store.list(projectPath: key)
            total += list.count
            print("\(key): \(list.count) checkpoint(s) — newest: \(list.first?.createdAt.description ?? "-")")
        }
        print("Total checkpoints: \(total) at \(CheckpointStore.storageURL.deletingLastPathComponent().path)")
    }
}

struct CheckpointsSnapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Snapshot the working tree.")
    @Option(name: [.long, .short], help: "Directory (default: current).")
    var directory: String?
    @Option(name: .long, help: "Snapshot name (default: checkpoint-<timestamp>).")
    var name: String?
    @Option(name: .long, help: "Message.")
    var message: String?
    func run() async throws {
        let dir = directory ?? FileManager.default.currentDirectoryPath
        let label = name ?? "checkpoint-\(Int(Date().timeIntervalSince1970))"
        guard let checkpoint = await CheckpointMaker.snapshot(directory: dir, name: label, message: message) else {
            print("Error: no git repo / snapshot failed in \(dir). Checkpoints require a git working tree.")
            return
        }
        let store = try checkpointStore()
        await store.add(checkpoint, projectPath: dir)
        try await store.save()
        print("✔ Checkpoint \(label) — \(checkpoint.commit.prefix(8)) (\(dir))")
    }
}

struct CheckpointsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List checkpoints for a project.")
    @Option(name: [.long, .short], help: "Directory (default: current).")
    var directory: String?
    @Option() var limit: Int = 20
    func run() async throws {
        let dir = URL(fileURLWithPath: directory ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let store = try checkpointStore()
        let list = await store.list(projectPath: dir)
        if list.isEmpty { print("No checkpoints for \(dir)."); return }
        for c in list.prefix(limit) {
            let when = c.createdAt.formatted(date: .abbreviated, time: .shortened)
            print("\(c.name)  \(c.commit.prefix(8))  \(when)  \(c.message ?? "")")
        }
    }
}

struct CheckpointsRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Roll the working tree back to a checkpoint.")
    @Argument var name: String
    @Option(name: [.long, .short], help: "Directory (default: current).")
    var directory: String?
    func run() async throws {
        let dir = URL(fileURLWithPath: directory ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let store = try checkpointStore()
        guard let checkpoint = await store.find(name: name, projectPath: dir) else {
            print("Checkpoint '\(name)' not found for \(dir)."); return
        }
        let (ok, message) = await CheckpointMaker.restore(checkpoint: checkpoint, directory: dir)
        print(ok ? "✔ \(message)" : "✘ restore failed: \(message)")
        let stat = await CheckpointMaker.diffStat(checkpoint: checkpoint, directory: dir)
        if !stat.isEmpty { print(stat) }
    }
}

struct CheckpointsPrune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Delete checkpoints older than the retention window.")
    @Option() var retentionDays: Int = 7
    @Flag(help: "Skip confirmation.")
    var force: Bool = false
    func run() async throws {
        if !force {
            print("Pruning checkpoints older than \(retentionDays) days. Continue? [y/N]", terminator: " ")
            guard let line = readLine(), ["y", "Y", "yes"].contains(line) else {
                print("aborted"); return
            }
        }
        let store = try checkpointStore()
        let removed = await store.prune(retentionDays: retentionDays)
        try await store.save()
        print("Removed \(removed) checkpoint(s).")
    }
}

struct CheckpointsClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Delete all checkpoints (optionally one project).")
    @Option(name: [.long, .short], help: "Directory (default: all projects).")
    var directory: String?
    @Flag(help: "Skip confirmation.")
    var force: Bool = false
    func run() async throws {
        if !force {
            print("Delete ALL checkpoints? [y/N]", terminator: " ")
            guard let line = readLine(), ["y", "Y", "yes"].contains(line) else {
                print("aborted"); return
            }
        }
        let store = try checkpointStore()
        await store.clear(projectPath: directory.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        try await store.save()
        print("Checkpoints cleared.")
    }
}
