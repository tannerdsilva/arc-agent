import ArcAgentCore
import Foundation
import SwiftSlash
import WebUI

// =========================================================================
// GitHub integration page: repository view for the active workspace.
//
// The page is a left-panel commit list (newest first, unpushed commits
// tinted with the theme accent) plus a main detail pane that shows the
// selected commit's message and file changes. All data comes from local
// `git` — no GitHub API or network calls. If the workspace is not a git
// repository, the page tells the user instead of showing an empty list.
// =========================================================================

// MARK: - Models

/// One commit row in the left panel.
struct GitHubCommit: Identifiable, Sendable, Equatable {
    let sha: String
    let short: String
    let author: String
    let dateISO: String
    let subject: String
    /// `git log` decorations (branch/remote refs) — displayed as a badge.
    let refs: String
    /// True when the commit is reachable from HEAD but not from any remote
    /// ref (`git log --not --remotes`); with no remote at all, every commit
    /// counts as unpushed.
    let unpushed: Bool
    var id: String { sha }
}

/// One changed file in a commit's detail pane.
struct GitHubFileChange: Sendable, Equatable {
    let path: String
    /// A (added), M (modified), D (deleted), R (renamed).
    let status: String
    let insertions: Int
    let deletions: Int

    var statusLabel: String {
        switch status {
        case "A": return "Added"
        case "M": return "Modified"
        case "D": return "Deleted"
        case "R": return "Renamed"
        default: return status
        }
    }
    var statusClass: String {
        switch status {
        case "A": return "gh-status-a"
        case "M": return "gh-status-m"
        case "D": return "gh-status-d"
        case "R": return "gh-status-r"
        default: return "gh-status-m"
        }
    }
}

/// The detail view for one selected commit.
struct GitHubDetail: Sendable, Equatable {
    let sha: String
    let author: String
    let dateISO: String
    let subject: String
    let body: String
    let files: [GitHubFileChange]
}

/// Load state of the GitHub page.
enum GitHubPageState: Sendable {
    case idle
    case loading(String)          // repo path being inspected
    case notARepo(String)         // path that isn't a git work tree
    case repo(String, branch: String?, remote: String?)
    case error(String)
}

// MARK: - Loader

/// Thin `git` wrapper for the page: every call is bounded (20 s), runs via
/// the shared `SubprocessRunner`, and never raises — failures become
/// `.error`/`.notARepo` states instead of crashes.
enum GitHubLoader {

    static func state(for path: String) async -> GitHubPageState {
        guard await isRepo(path) else {
            return .notARepo(path)
        }
        let branch = await git(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
            .flatMap { $0.isEmpty ? nil : $0 }
        // `git remote get-url origin` exits 1 when no remote exists; the
        // loader tolerates that (null → no remote badge).
        let remote = await git(["-C", path, "remote", "get-url", "origin"])
            .flatMap { $0.isEmpty ? nil : $0 }
        return .repo(path, branch: branch, remote: remote)
    }

    static func commits(for path: String, limit: Int = 60) async -> [GitHubCommit] {
        let format = "%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1f%d"
        guard let log = await git(["-C", path, "log", "-n", "\(limit)", "--pretty=format:\(format)"]),
              !log.isEmpty else {
            return []
        }
        let unpushed = await unpushedSHAs(for: path)
        return log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { return nil }
            let sha = parts[0]
            return GitHubCommit(
                sha: sha,
                short: parts[1],
                author: parts[2],
                dateISO: parts[3],
                subject: parts[4],
                refs: parts.count > 5 ? parts[5] : "",
                unpushed: unpushed.contains(sha)
            )
        }
    }

    private static func unpushedSHAs(for path: String) async -> Set<String> {
        // Unpushed = commits reachable from HEAD but not from any remote
        // tracking ref. (`git log --not --remotes` has parser quirks with
        // local releases; the explicit set difference is unambiguous; with no
        // remote refs at all the set below is empty so every commit counts.)
        guard let head = await git(["-C", path, "rev-list", "HEAD"]),
              let remote = await git(["-C", path, "rev-list", "--remotes"]) else {
            return []
        }
        let remotelyKnown = Set(remote.split(separator: "\n").map(String.init))
        return Set(head.split(separator: "\n").map(String.init)).subtracting(remotelyKnown)
    }

    static func detail(for path: String, sha: String) async -> GitHubDetail? {
        let fmt = "%H%x1f%an%x1f%aI%x1f%s%x1f%B"
        guard let head = await git(["-C", path, "show", "-s", "--format=\(fmt)", sha]), !head.isEmpty else {
            return nil
        }
        let parts = head.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let subject = parts[3]
        var body = parts.count > 4 ? parts[4] : ""
        // `git show --format=%B` prints the body followed by a trailing
        // newline per format record; trim the stray spacing.
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // File changes: `--name-status` for the A/M/D/R letters and
        // `--numstat` for +/- counts, joined by path.
        let nameStatus = await git(["-C", path, "diff-tree", "--no-commit-id", "--name-status", "-r", "-M", sha]) ?? ""
        let numstat = await git(["-C", path, "show", "--numstat", "--format=", sha]) ?? ""
        var counts: [String: (Int, Int)] = [:]
        for line in numstat.split(separator: "\n") {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count >= 3,
                  let ins = Int(cells[0]) ?? (cells[0] == "-" ? 0 : nil),
                  let del = Int(cells[1]) ?? (cells[1] == "-" ? 0 : nil) else { continue }
            counts[cells[2]] = (ins, del)
        }
        let files: [GitHubFileChange] = nameStatus.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            // Renames emit `R100\told\tnew`; everything else is `X\tpath`.
            guard let status = cells.first, !status.isEmpty, cells.count >= 2 else { return nil }
            let path = cells.count >= 3 ? cells[2] : cells[1]
            let (ins, del) = counts[path] ?? (0, 0)
            return GitHubFileChange(path: path, status: status, insertions: ins, deletions: del)
        }
        return GitHubDetail(
            sha: parts[0],
            author: parts[1],
            dateISO: parts[2],
            subject: subject,
            body: body,
            files: files
        )
    }

    // MARK: - git plumbing

    private static func isRepo(_ path: String) async -> Bool {
        let ok = await git(["-C", path, "rev-parse", "--is-inside-work-tree"])
        return ok?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Run git, returning trimmed stdout on success (exit 0, no timeout).
    private static func git(_ args: [String]) async -> String? {
        var cmd = Command(absolutePath: Path("/usr/bin/git"), arguments: args)
        cmd.inheritCurrentEnvironment()
        let outcome = try? await SubprocessRunner.runBytes(cmd, timeout: 20)
        guard let outcome, !outcome.timedOut, let code = outcome.exitCode, code == 0 else {
            return nil
        }
        return String(data: outcome.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AppState integration

extension AppState {

    /// Workspace the GitHub page inspects: the active chat's workspace when a
    /// chat is open, otherwise the active default workspace.
    func githubWorkspacePath() -> String {
        workspacePath(for: activeSessionID)
    }

    /// Load (once) when the GitHub view is opened; reload on demand.
    func githubEnsureLoaded() async {
        let path = githubWorkspacePath()
        let loaded: String?
        switch githubPage {
        case .repo(let p, _, _): loaded = p
        case .notARepo(let p): loaded = p
        case .error, .loading, .idle: loaded = nil
        }
        // Reload when nothing is loaded or the active chat's workspace
        // changed since the last load (chat/workspace switches).
        guard loaded != path else { return }
        await githubReload()
    }

    /// Full reload: re-inspect the repo and rebuild the commit list.
    func githubReload() async {
        let path = githubWorkspacePath()
        githubSelectedSHA = nil
        githubDetail = nil
        githubPage = .loading(path)
        let state = await GitHubLoader.state(for: path)
        switch state {
        case .repo(let p, let branch, let remote):
            let commits = await GitHubLoader.commits(for: p)
            githubCommits = commits
            githubPage = .repo(p, branch: branch, remote: remote)
        default:
            githubCommits = []
            githubPage = state
        }
        // Touch the panel via the standard refresh (the view is active).
        let _ = await refreshFragments()
    }

    /// Select a commit and load its detail.
    func githubSelect(sha: String) async {
        githubSelectedSHA = sha
        githubDetail = nil
        if case .repo(let path, _, _) = githubPage {
            githubDetail = await GitHubLoader.detail(for: path, sha: sha)
        }
        let _ = await refreshFragments()
    }

    /// Fragment refresh used by the GitHub page (panel + main).
    func githubFragments() async -> [FragmentUpdate] {
        await refreshFragments()
    }
}
