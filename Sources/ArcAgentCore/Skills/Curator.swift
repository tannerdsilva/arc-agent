import Foundation
import CryptoKit

// MARK: - Skill curator (Hermes `curator.py` + `curator_backup.py`)

/// Curator schedule/state semantics (Hermes `maybe_run_curator` defaults).
public enum CuratorPolicy {
    /// Minimum time between runs.
    public static let intervalHours = 168          // 7 days
    /// Minimum idle time (no skill use / no user activity) before running.
    public static let minIdleHours = 2.0
    /// Skills untouched for this long become review-worthy.
    public static let reviewWorthyDays = 30
    /// Skills untouched for this long are archived (moved out of the index).
    public static let archiveDays = 90
    /// Curation runs in dry-run mode by default (Hermes CURATOR_DRY_RUN).
    public static let defaultDryRun = true
    /// Backups to keep (Hermes curator_backup keeps the 5 newest).
    public static let backupKeep = 5
}

/// Persistent curator state (mirrors Hermes' curator state file).
public struct CuratorState: Codable, Sendable, Equatable {
    public var lastRunAt: Date?
    public var paused: Bool
    public var consecutiveRuns: Int

    public init(lastRunAt: Date? = nil, paused: Bool = false, consecutiveRuns: Int = 0) {
        self.lastRunAt = lastRunAt
        self.paused = paused
        self.consecutiveRuns = consecutiveRuns
    }

    public static func load(from url: URL) -> CuratorState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CuratorState.self, from: data) else {
            return CuratorState()
        }
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

/// One curator decision (Hermes returns a report of transitions).
public struct CuratorTransition: Sendable, Equatable {
    public enum Kind: String, Sendable { case reviewWorthy, archive, consolidate, rename }
    public let skill: String
    public let kind: Kind
    public let reason: String
}

/// A skill-use record (last-modified metadata is the offline signal; idle
/// detection uses the newest skill mtime in this port).
public struct CuratorInput: Sendable {
    public let name: String
    public let lastModified: Date
}

/// The curator engine. Scheduling + decisions are pure functions so they are
/// testable; the filesystem side effects are injected.
public enum Curator {

    /// Whether the curator is due to run now (Hermes `maybe_run_curator`:
    /// interval + minimum idle + not paused).
    public static func isDue(
        state: CuratorState,
        now: Date = Date(),
        idleSince: Date? = nil,
        intervalHours: Int = CuratorPolicy.intervalHours
    ) -> (due: Bool, reason: String?) {
        guard !state.paused else { return (false, "paused") }
        guard let lastRun = state.lastRunAt else { return (true, "never run") }
        let elapsed = now.timeIntervalSince(lastRun)
        if elapsed < Double(intervalHours) * 3600 {
            return (false, "within interval (\(Int(elapsed / 3600))h)")
        }
        if let idleSince, now.timeIntervalSince(idleSince) < CuratorPolicy.minIdleHours * 3600 {
            return (false, "not idle long enough")
        }
        return (true, "interval elapsed")
    }

    /// Compute automatic transitions (Hermes `apply_automatic_transitions`):
    /// skills older than `archiveDays` are archived; older than
    /// `reviewWorthyDays` are review-worthy. Skills referenced by cron jobs
    /// are never archived (Hermes protects cron-referenced skills).
    public static func transitions(
        skills: [CuratorInput],
        now: Date = Date(),
        cronReferenced: Set<String> = []
    ) -> [CuratorTransition] {
        skills.compactMap { skill in
            let age = now.timeIntervalSince(skill.lastModified)
            if age >= Double(CuratorPolicy.archiveDays) * 86_400, !cronReferenced.contains(skill.name) {
                return CuratorTransition(skill: skill.name, kind: .archive,
                                         reason: "unused for \(Int(age / 86_400)) days")
            }
            if age >= Double(CuratorPolicy.reviewWorthyDays) * 86_400 {
                return CuratorTransition(skill: skill.name, kind: .reviewWorthy,
                                         reason: "unused for \(Int(age / 86_400)) days")
            }
            return nil
        }
    }

    /// LLM review prompt for the curated batch (Hermes review prompt: asks an
    /// AUXILIARY model to judge quality: consolidate/improve/archive).
    public static func reviewPrompt(skills: [String]) -> String {
        """
        You are the skill curator. Review the following skills for quality \
        and relevance. For each, decide: KEEP, CONSOLIDATE (merge into an \
        existing related skill), IMPROVE (write a patch), or ARCHIVE (delete). \
        Be decisive; an unused or low-quality skill is worse than no skill.

        Skills under review:
        \(skills.map { "- \($0)" }.joined(separator: "\n"))

        Respond with one line per skill: "NAME: DECISION (one-line reason)".
        """
    }

    /// Read cron-referenced skill names from a cron-jobs JSON file so the
    /// curator never archives something a scheduled job depends on (Hermes
    /// `get_cron_referenced_skills`).
    public static func cronReferencedSkills(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var names = Set<String>()
        func collect(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let skills = dict["skills"] as? [String] { names.formUnion(skills) }
                if let job = dict["prompt"] as? String { _ = job }
                for (_, v) in dict { collect(v) }
            } else if let list = value as? [Any] {
                for v in list { collect(v) }
            }
        }
        collect(json)
        return names
    }
}

// MARK: - Backups (Hermes `curator_backup.py`)

/// One backup snapshot: UTC-id, creation time, and hashed skill files.
public struct CuratorBackup: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let path: String
        public let size: Int
        public let sha256: String
    }
    public let id: String
    public let createdAt: Date
    public let files: [File]

    public init(id: String, createdAt: Date = Date(), files: [File]) {
        self.id = id
        self.createdAt = createdAt
        self.files = files
    }
}

public enum CuratorBackupStore {
    public static let keep = CuratorPolicy.backupKeep

    /// UTC timestamp id (Hermes uses UTC microsecond ids).
    static func newID(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: now)
    }

    /// Snapshot every regular file under `skillsDir` into a manifest.
    public static func create(
        skillsDir: URL,
        backupsDir: URL,
        now: Date = Date()
    ) throws -> CuratorBackup {
        let fm = FileManager.default
        let id = newID(now: now)
        let dest = backupsDir.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        // Resolve symlinks: FileManager enumerates the /private real path of
        // a /var temporary directory on macOS, so normalize before comparing.
        let base = skillsDir.resolvingSymlinksInPath()

        var files: [CuratorBackup.File] = []
        guard let enumerator = fm.enumerator(at: base,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw CuratorError.backupFailed("cannot enumerate skills dir")
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            let relative = url.path.hasPrefix(base.path + "/")
                ? String(url.path.dropFirst(base.path.count + 1))
                : url.lastPathComponent
            files.append(CuratorBackup.File(
                path: relative,
                size: values?.fileSize ?? data.count,
                sha256: SHA256Digest.hex(data)
            ))
            // Copy the byte content for rollback.
            let target = dest.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }

        let backup = CuratorBackup(id: id, createdAt: now, files: files)
        let manifestURL = dest.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(backup).write(to: manifestURL, options: .atomic)
        try prune(directory: backupsDir)
        return backup
    }

    /// Keep only the newest `keep` backups (Hermes keeps 5).
    public static func prune(directory: URL, keep: Int = CuratorBackupStore.keep) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        let sorted = entries.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da > db
        }
        for stale in sorted.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }

    public static func list(directory: URL) throws -> [CuratorBackup] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else { return nil }
                return try? JSONDecoder().decode(CuratorBackup.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Restore a backup's files into the skills directory (idempotent:
    /// existing files are replaced).
    public static func rollback(backupID: String, backupsDir: URL, skillsDir: URL) throws {
        let src = backupsDir.appendingPathComponent(backupID)
        let manifestURL = src.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CuratorBackup.self, from: data) else {
            throw CuratorError.backupFailed("backup \(backupID) not found or corrupt")
        }
        let fm = FileManager.default
        let base = skillsDir.resolvingSymlinksInPath()
        for file in manifest.files {
            let source = src.appendingPathComponent(file.path)
            let target = base.appendingPathComponent(file.path)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
        }
    }
}

/// Tiny SHA-256 helper (CryptoKit; macOS 10.15+).
public enum SHA256Digest {
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CuratorError: Error, CustomStringConvertible {
    case backupFailed(String)

    public var description: String {
        switch self {
        case .backupFailed(let message): return "Curator backup failed: \(message)"
        }
    }
}
