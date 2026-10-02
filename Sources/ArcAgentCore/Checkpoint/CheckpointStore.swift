import Foundation
import SwiftSlash

// MARK: - Checkpoints & rollback (reference `tools/checkpoint_manager.py`, `reference checkpoints`)

/// One snapshot of a project's working tree (a git commit + metadata).
public struct Checkpoint: Codable, Sendable, Equatable {
    public let name: String
    public let commit: String
    public let createdAt: Date
    public let message: String?
    public let projectPath: String

    public init(name: String, commit: String, createdAt: Date, message: String?, projectPath: String) {
        self.name = name
        self.commit = commit
        self.createdAt = createdAt
        self.message = message
        self.projectPath = projectPath
    }
}

/// Registry of checkpoints (metadata JSON), keyed per project directory.
/// Snapshots are git commits of the working tree (`git stash create`).
public actor CheckpointStore {

    public nonisolated(unsafe) static var storageURL: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/checkpoints")
        return base.appendingPathComponent("registry.json")
    }()

    public static func setStorageURL(_ url: URL) { storageURL = url }

    private var entries: [String: [Checkpoint]] = [:]

    public init() throws {
        let data = try? Data(contentsOf: Self.storageURL)
        if let data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([String: [Checkpoint]].self, from: data) {
                entries = decoded
            }
        }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(
            at: Self.storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: Self.storageURL)
    }

    public func list(projectPath: String) -> [Checkpoint] {
        entries[Self.keyFor(projectPath)] ?? []
    }

    public func add(_ checkpoint: Checkpoint, projectPath: String) {
        let key = Self.keyFor(projectPath)
        var list = entries[key] ?? []
        list.insert(checkpoint, at: 0)
        entries[key] = list
    }

    public func remove(name: String, projectPath: String) -> Bool {
        let key = Self.keyFor(projectPath)
        guard let list = entries[key] else { return false }
        let filtered = list.filter { $0.name != name }
        entries[key] = filtered
        return filtered.count != list.count
    }

    public func clear(projectPath: String?) {
        if let projectPath {
            entries.removeValue(forKey: Self.keyFor(projectPath))
        } else {
            entries = [:]
        }
    }

    /// Prune entries older than `retentionDays`; returns removed count.
    public func prune(retentionDays: Int) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        var removed = 0
        for (key, list) in entries {
            let kept = list.filter { $0.createdAt >= cutoff }
            removed += list.count - kept.count
            entries[key] = kept
        }
        return removed
    }

    public func find(name: String, projectPath: String) -> Checkpoint? {
        entries[Self.keyFor(projectPath)]?.first { $0.name == name }
    }

    public func projectKeys() -> [String] { Array(entries.keys) }

    static func keyFor(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Creates checkpoints by shelling out to git (byte-exact, bounded).
public enum CheckpointMaker {

    /// Snapshot a working directory. Returns nil when git fails (e.g. no repo).
    public static func snapshot(directory: String, name: String, message: String?) async -> Checkpoint? {
        guard let commit = await stashCreate(directory: directory) else { return nil }
        return Checkpoint(
            name: name,
            commit: commit,
            createdAt: Date(),
            message: message,
            projectPath: URL(fileURLWithPath: directory).standardizedFileURL.path
        )
    }

    /// `git stash create` — commits the working tree without touching it.
    /// Returns the commit hash, or nil.
    static func stashCreate(directory: String) async -> String? {
        let outcome = await git(["stash", "create"], directory: directory)
        guard outcome.0 == 0 else { return nil }
        let hash = outcome.1.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// Roll the working directory back to a checkpoint's commit.
    /// Returns (success, message).
    public static func restore(checkpoint: Checkpoint, directory: String) async -> (Bool, String) {
        let outcome = await git(["restore", "--source=\(checkpoint.commit)", "--worktree", "--", "."], directory: directory)
        if outcome.0 == 0 {
            return (true, "restored \(checkpoint.name) (\(checkpoint.commit.prefix(8)))")
        }
        return (false, outcome.1)
    }

    /// `git diff --stat` between worktree and the checkpoint commit.
    public static func diffStat(checkpoint: Checkpoint, directory: String) async -> String {
        let outcome = await git(["diff", "--stat", checkpoint.commit], directory: directory)
        return outcome.0 == 0 ? outcome.1 : outcome.1
    }

    /// Resolve a reasonable project root for `path`: the enclosing git
    /// repository top-level when available, otherwise the directory itself.
    static func projectRoot(for path: String) async -> String? {
        let dir = URL(fileURLWithPath: path).standardizedFileURL.path
        let outcome = await git(["rev-parse", "--show-toplevel"], directory: dir)
        if outcome.0 == 0 {
            let root = outcome.1.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = root.split(separator: "\n").first.map(String.init) ?? root
            if !firstLine.isEmpty { return firstLine }
        }
        return dir
    }

    /// `git show --stat` summary (commit vs its parent) — the change stats
    /// shown by `/rollback`. Returns "" when unavailable.
    public static func stats(commit: String, directory: String) async -> String {
        let outcome = await git(["show", "--stat", "--format=", commit], directory: directory)
        guard outcome.0 == 0 else { return "" }
        // Parse the last line: " 1 file changed, 1 insertion(+), 1 deletion(-)"
        let lastLine = outcome.1.split(separator: "\n").last.map(String.init) ?? ""
        return lastLine.trimmingCharacters(in: .whitespaces)
    }

    /// Roll a single tracked file in the working directory back to the
    /// checkpoint's commit. Returns (success, message).
    public static func restoreFile(checkpoint: Checkpoint, directory: String, file: String) async -> (Bool, String) {
        let outcome = await git(
            ["restore", "--source=\(checkpoint.commit)", "--worktree", "--", file],
            directory: directory
        )
        if outcome.0 == 0 {
            return (true, "restored \(file) from \(checkpoint.name) (\(checkpoint.commit.prefix(8)))")
        }
        return (false, outcome.1)
    }

    static func git(_ args: [String], directory: String) async -> (Int32, String) {
        var command = Command(absolutePath: Path("/usr/bin/git"), arguments: args)
        command.inheritCurrentEnvironment()
        command.workingDirectory = Path(directory)
        do {
            let outcome = try await SubprocessRunner.runBytes(command, timeout: 30)
            let out = String(data: outcome.stdout, encoding: .utf8) ?? ""
            let err = String(data: outcome.stderr, encoding: .utf8) ?? ""
            return (outcome.exitCodeValue, err.isEmpty ? out : out + "\n" + err)
        } catch {
            return (-1, "git error: \(error)")
        }
    }
}
