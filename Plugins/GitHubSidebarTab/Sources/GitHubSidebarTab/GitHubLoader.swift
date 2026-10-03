import Foundation

// MARK: - GitHubLoader

/// Thin `git` wrapper for the tab: every call is bounded (20 s), runs
/// through the shared subprocess runner, and never raises — failures
/// become `.error`/`.notARepo` states instead of crashes.
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
        // local releases; the explicit set difference is unambiguous; with
        // no remote refs at all the set below is empty so every commit
        // counts.)
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

    /// Run git, returning trimmed stdout on success (exit 0).
    private static func git(_ args: [String]) async -> String? {
        let (stdout, code) = await GitRunner.run(args)
        guard let code, code == 0 else { return nil }
        return String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
