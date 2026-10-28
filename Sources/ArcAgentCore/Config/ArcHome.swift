import Foundation

/// Central resolver for this instance's data/config root.
///
/// The default is `~/.arc` (homeDirectoryForCurrentUser/.arc), matching the
/// established behaviour exactly. Setting the `ARC_HOME` environment variable
/// relocates the whole instance root, so a second agent can run on the same
/// machine/user with its own config, secrets, and data — its own identity
/// (`ARC_TESSERA_PRIVATE_KEY` in `$ARC_HOME/.env`), its own `tessera.application`
/// namespace, and its own on-disk state.
///
/// Interactive commands (e.g. `arc setup`) may set an in-process override with
/// ``setOverride(_:)`` after prompting; that takes precedence over the env var
/// for the rest of the process. A nil override leaves the env var / default in
/// force.
public enum ArcHome {

    /// In-process override set by interactive commands (e.g. `arc setup`).
    /// Takes precedence over the env var; `nil` when unset. Reset per-process.
    nonisolated(unsafe) private static var overrideRoot: String?

    /// Whether this process has an explicit home set (override or env var).
    /// When `false`, the resolved root is the default `~/.arc`.
    public static var overridden: Bool {
        overrideRoot != nil || ProcessInfo.processInfo.environment["ARC_HOME"] != nil
    }

    /// The invoking user's home directory.
    private static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Set/clear the in-process override. Pass `nil` to clear.
    ///
    /// Used by interactive commands that ask the user for an instance directory
    /// so the chosen value drives every subsequent path in the same run.
    public static func setOverride(_ path: String?) {
        overrideRoot = path
    }

    /// The instance root directory: `$ARC_HOME` (or the in-process override,
    /// which wins), else `~/.arc`.
    ///
    /// `~` is expanded from the home directory; the value is standardized.
    public static var root: URL {
        let value = overrideRoot ?? ProcessInfo.processInfo.environment["ARC_HOME"]
        if let value, !value.isEmpty {
            let expanded: String
            if value == "~" {
                expanded = FileManager.default.homeDirectoryForCurrentUser.path
            } else if value.hasPrefix("~/") {
                expanded = FileManager.default.homeDirectoryForCurrentUser.path + value.dropFirst(1)
            } else {
                expanded = value
            }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc", isDirectory: true)
    }

    // MARK: Config + secrets

    /// `<root>/config.json`
    public static var config: URL { root.appendingPathComponent("config.json") }

    /// `<root>/.env` (secrets only: `ARC_TESSERA_PRIVATE_KEY`, API keys).
    public static var env: URL { root.appendingPathComponent(".env") }

    /// `<root>/daemon.json` (daemon surfaces; env-var override wins).
    public static var daemon: URL { root.appendingPathComponent("daemon.json") }

    // MARK: Data directories

    public static var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public static var memories: URL { root.appendingPathComponent("memories", isDirectory: true) }
    public static var skills: URL { root.appendingPathComponent("skills", isDirectory: true) }
    public static var skillBundles: URL { root.appendingPathComponent("skill-bundles", isDirectory: true) }
    public static var skillPackages: URL { root.appendingPathComponent("skill-packages", isDirectory: true) }
    public static var skillsHub: URL { root.appendingPathComponent("skills-hub", isDirectory: true) }
    public static var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }
    public static var cron: URL { root.appendingPathComponent("cron", isDirectory: true) }
    public static var cronJobs: URL { root.appendingPathComponent("cron-jobs.json") }
    public static var kanban: URL { root.appendingPathComponent("kanban", isDirectory: true) }
    public static var projects: URL { root.appendingPathComponent("projects.json") }
    public static var goals: URL { root.appendingPathComponent("goals.json") }
    public static var heartbeats: URL { root.appendingPathComponent("heartbeats.json") }
    public static var hooks: URL { root.appendingPathComponent("hooks", isDirectory: true) }
    public static var checkpoints: URL { root.appendingPathComponent("checkpoints", isDirectory: true) }
    public static var profiles: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public static var workspaces: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    public static var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public static var curator: URL { root.appendingPathComponent("curator", isDirectory: true) }
    public static var tessera: URL { root.appendingPathComponent("tessera", isDirectory: true) }

    // MARK: UI + usage state

    /// WebUI state root. `~/.arc-agent-webui` by default; relocated under the
    /// override (as `<home>/webui`) when `ARC_HOME` is set so a second
    /// instance's UI settings are isolated too.
    public static var webUI: URL {
        if overridden {
            return root.appendingPathComponent("webui", isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".arc-agent-webui", isDirectory: true)
    }

    /// `<webUI>/settings.json` — persisted UI + app settings / storage picker /
    /// context defaults.
    public static var webUISettings: URL { webUI.appendingPathComponent("settings.json") }

    /// `<webUI>/insights.json` — web UI insights (skill usage counters, etc.).
    public static var webUIInsights: URL { webUI.appendingPathComponent("insights.json") }

    /// Usage-ledger root. `~/.arc-agent` by default; relocated under the
    /// override (as `<home>/usage`) when `ARC_HOME` is set.
    public static var usage: URL {
        if overridden {
            return root.appendingPathComponent("usage", isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".arc-agent", isDirectory: true)
    }

    /// `<usage>/usage.json` — per-day token/call ledger.
    public static var usageLedger: URL { usage.appendingPathComponent("usage.json") }
}
