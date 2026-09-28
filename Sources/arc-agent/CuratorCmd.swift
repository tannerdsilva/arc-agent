import ArgumentParser
import ArcAgentCore
import Foundation

/// `arc curator` — skill-library hygiene (Hermes `curator.py`).
///
/// Computes automatic transitions (review-worthy after 30 days unused,
/// archive after 90), respects the skill edit locks in `agent_powers`
/// (`lockedSkills` are never touched; `skillsManage: false` forces
/// report-only), and takes a full backup before any archive move.
struct CuratorCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "curator",
        abstract: "Run skill-library hygiene: review/archive unused skills.",
        discussion: """
            Dry-run by default. With --apply, skills are archived (moved out \
            of the skills index) after a full backup. Skill edit locks from \
            agent_powers (lockedSkills / skillsManage) are always honored.
            """
    )

    @Flag(name: .shortAndLong, help: "Apply archive transitions (default: dry-run).")
    var apply = false

    @Flag(name: .long, help: "Ignore the 7-day interval gate and run now.")
    var force = false

    @Flag(name: .long, help: "Restore the newest backup into the skills directory.")
    var rollback = false

    func run() async throws {
        let config = loadConfig()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let skillsDir = home.appendingPathComponent(".arc/skills")
        let curatorDir = home.appendingPathComponent(".arc/curator")
        let backupsDir = curatorDir.appendingPathComponent("backups")
        let archiveDir = curatorDir.appendingPathComponent("archive")
        let stateURL = curatorDir.appendingPathComponent("state.json")
        let cronURL = home.appendingPathComponent(".arc/cron-jobs.json")

        // ── Skill edit locks (agent_powers) ─────────────────────────────
        let lockedNames = Set(config.agentPowers.lockedSkills)
        let skillsLocked = !config.agentPowers.skillsManage

        if rollback {
            let backups = try CuratorBackupStore.list(directory: backupsDir)
            guard let newest = backups.first else {
                print("No backups to restore.")
                return
            }
            try CuratorBackupStore.rollback(
                backupID: newest.id, backupsDir: backupsDir, skillsDir: skillsDir)
            print("Restored backup \(newest.id) (\(newest.files.count) files).")
            return
        }

        var state = CuratorState.load(from: stateURL)
        let (due, reason) = Curator.isDue(state: state)
        if !due, !force {
            print("Curator not due (\(reason ?? "unknown")). Use --force to run anyway.")
            return
        }

        // ── Discover skills + last-modified times ───────────────────────
        let discovered = discoverSkills()
        let inputs = discovered.map { skill -> CuratorInput in
            let (url, mtime) = skillFileLocator(name: skill.name, skillsDir: skillsDir)
            _ = url
            return CuratorInput(name: skill.name, lastModified: mtime)
        }

        let cronReferenced = Curator.cronReferencedSkills(from: cronURL)
        let transitions = Curator.transitions(
            skills: inputs,
            cronReferenced: cronReferenced
        ).filter { !lockedNames.contains($0.skill) }

        if transitions.isEmpty {
            print("Skill library is clean — no transitions due.")
        } else {
            for transition in transitions {
                print("\(transition.kind.rawValue.uppercased()): \(transition.skill) — \(transition.reason)")
            }
        }

        // ── Apply (only when allowed by locks) ──────────────────────────
        let archives = transitions.filter { $0.kind == .archive }
        if !archives.isEmpty {
            if skillsLocked {
                print("Skill editing is locked (agent_powers.skills_manage=false) — report only.")
            } else if apply {
                let backup = try CuratorBackupStore.create(skillsDir: skillsDir, backupsDir: backupsDir)
                print("Backup: \(backup.id) (\(backup.files.count) files) → \(backupsDir.path)")
                try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
                for transition in archives {
                    let source = skillsDir.appendingPathComponent(transition.skill)
                    let destination = archiveDir.appendingPathComponent(
                        "\(transition.skill)-\(backup.id)")
                    if fm.fileExists(atPath: source.path) {
                        try fm.moveItem(at: source, to: destination)
                        print("Archived \(transition.skill) → \(destination.path)")
                    } else {
                        print("Skip \(transition.skill): not found at \(source.path)")
                    }
                }
            } else {
                print("Dry-run: pass --apply to archive \(archives.count) skill(s) (backup + move).")
            }
        }

        state.lastRunAt = Date()
        state.consecutiveRuns = transitions.isEmpty ? 0 : state.consecutiveRuns + 1
        try state.save(to: stateURL)
    }

    /// Best-effort locator for a skill's SKILL.md so its mtime can seed the
    /// idle signal. Recursive: skills may sit in category subdirectories
    /// (`<dir>/<category>/<name>/SKILL.md`). When the skill cannot be
    /// located, `Date()` is used (age 0 → no transition) so a locator miss
    /// can never cause a mistaken archive.
    private func skillFileLocator(name: String, skillsDir: URL) -> (URL?, Date) {
        guard let enumerator = FileManager.default.enumerator(
            at: skillsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return (nil, Date()) }

        var newest: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "SKILL.md" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent == name else { continue }
            guard let mtime = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate,
                mtime > newestDate else { continue }
            newestDate = mtime
            newest = url
        }
        guard let found = newest, newestDate != .distantPast else { return (nil, Date()) }
        return (found, newestDate)
    }
}
