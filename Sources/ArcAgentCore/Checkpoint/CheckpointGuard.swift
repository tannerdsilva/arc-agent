import Foundation

// MARK: - Checkpoints & rollback (reference `tools/checkpoint_manager.py`)

/// Automatic checkpoint guard.
///
/// Mirrors the Hermes v2 contract: opt-in (`checkpoints.enabled`), snapshots
/// are taken automatically **before** file mutations (`write_file`, `patch`,
/// destructive terminal commands), at most **one per directory per turn**,
/// and all failure modes are non-fatal (the tool proceeds regardless).
///
/// Turn scoping is driven by ``beginTurn()``, which ``ArcAgent`` invokes at
/// each turn boundary (`resetTurnState`).
public actor CheckpointGuard {

    public static let shared = CheckpointGuard()

    /// Test/CLI override. nil = resolve from `~/.arc/config.json` each call.
    private var enabledOverride: Bool?

    /// Monotonic turn counter; incremented at each agent turn boundary.
    private var epoch = 0

    /// Project roots already snapshotted in the current epoch — the
    /// "at most one checkpoint per directory per turn" rule.
    private var snappedThisEpoch: Set<String> = []

    // MARK: - Lifecycle

    public func beginTurn() {
        epoch += 1
        snappedThisEpoch.removeAll()
    }

    /// Force the enabled state (tests / CLI `--checkpoints`).
    public func setEnabled(_ value: Bool) {
        enabledOverride = value
    }

    /// Resolve the effective enabled state.
    public func isEnabled() -> Bool {
        if let override = enabledOverride { return override }
        return loadConfig().checkpoints?.enabled ?? false
    }

    // MARK: - Ensure

    /// Snapshot `directory` (its resolved project root) if — and only if —
    /// checkpoints are enabled, the root is in scope, and this directory has
    /// not already been snapshotted this turn. Returns the checkpoint, or nil
    /// when skipped or when there was nothing to snapshot (clean tree).
    ///
    /// All storage failures are swallowed: checkpoints must never break the
    /// tool that triggered them.
    @discardableResult
    public func ensure(directory: String, label: String) async -> Checkpoint? {
        guard isEnabled() else { return nil }
        guard let root = await CheckpointMaker.projectRoot(for: directory) else { return nil }
        guard Self.scopeOK(root) else { return nil }
        guard !snappedThisEpoch.contains(root) else { return nil }
        snappedThisEpoch.insert(root)

        let name = "checkpoint-\(epoch)-" + Self.slug(label)
        guard let checkpoint = await CheckpointMaker.snapshot(directory: root, name: name, message: label) else {
            return nil // no repo / no changes — non-fatal
        }
        do {
            let store = try CheckpointStore()
            await store.add(checkpoint, projectPath: root)
            try await store.save()
            await pruneToCap(root: root, store: store)
        } catch {
            // Non-fatal by design (reference: all checkpoint errors are debug-logged).
        }
        return checkpoint
    }

    /// Enforce `checkpoints.max_snapshots` (default 20) by dropping the oldest
    /// entries of a project from the registry. Loose git objects are reclaimed
    /// by `git gc` on the real store; arc keeps registry metadata only.
    private func pruneToCap(root: String, store: CheckpointStore) async {
        let cap = loadConfig().checkpoints?.maxSnapshots ?? 20
        guard cap > 0 else { return }
        let list = await store.list(projectPath: root)
        for checkpoint in list.dropFirst(cap) {
            await store.remove(name: checkpoint.name, projectPath: root)
        }
        try? await store.save()
    }

    // MARK: - Scope & detection

    /// Skip overly broad directories (root `/` and home) — reference guard.
    public static func scopeOK(_ root: String) -> Bool {
        let standardized = URL(fileURLWithPath: root).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return standardized != "/" && standardized != home
    }

    /// Reference destructive-command set (`checkpoints-and-rollback.md`):
    /// `rm`, `rmdir`, `cp`, `install`, `mv`, `sed -i`, `truncate`, `dd`,
    /// `shred`, output redirects (`>`), and `git reset`/`clean`/`checkout`.
    public static func isDestructive(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }

        // Skip env prefixes (FOO=bar cmd ...) and sudo/env/nohup wrappers.
        var words = trimmed.split(separator: " ").map(String.init)
        while let first = words.first, first.contains("=") || ["sudo", "env", "nohup"].contains(first) {
            words.removeFirst()
        }
        guard let argv0 = words.first else { return false }
        let bin = URL(fileURLWithPath: argv0).lastPathComponent

        let mutators: Set<String> = ["rm", "rmdir", "mv", "cp", "dd", "shred", "truncate", "install"]
        if mutators.contains(bin) { return true }

        if bin == "sed" {
            return words.dropFirst().contains { $0.hasPrefix("-i") || $0.hasPrefix("--in-place") }
                || trimmed.contains(" -i ") || trimmed.hasSuffix(" -i")
        }
        if bin == "git" {
            guard let sub = words.dropFirst().first else { return false }
            return ["reset", "clean", "checkout"].contains(sub)
        }
        // Output redirects in plain shell commands (overwrite/append — the
        // reference counts `>` as destructive, even after `echo`).
        if trimmed.contains(">") {
            return true
        }
        return false
    }

    private static func slug(_ s: String) -> String {
        let alnum = s.lowercased().map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "-" }
        let joined = String(alnum)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let slugged = joined.replacingOccurrences(of: " ", with: "-")
        return String(slugged.prefix(40))
    }
}

// MARK: - Rollback listing (reference `/rollback` output)

public enum RollbackFormatter {

    /// `📸 Checkpoints for <root>:` + numbered list with change stats.
    public static func listText(_ checkpoints: [Checkpoint], root: String) async -> String {
        guard !checkpoints.isEmpty else {
            return "No checkpoints for \(root)."
        }
        var lines = ["📸 Checkpoints for \(root):", ""]
        for (index, cp) in checkpoints.enumerated() {
            let when = CheckpointDateFormatter.format(cp.createdAt)
            let stats = await CheckpointMaker.stats(commit: cp.commit, directory: root)
            lines.append("  \(index + 1). \(cp.commit.prefix(7))  \(when)  \(cp.message ?? cp.name)\(stats.isEmpty ? "" : "  (\(stats))")")
        }
        lines.append("")
        lines.append("  /rollback <N>             restore to checkpoint N")
        lines.append("  /rollback diff <N>        preview changes since checkpoint N")
        lines.append("  /rollback <N> <file>      restore a single file from checkpoint N")
        return lines.joined(separator: "\n")
    }
}

enum CheckpointDateFormatter {
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
