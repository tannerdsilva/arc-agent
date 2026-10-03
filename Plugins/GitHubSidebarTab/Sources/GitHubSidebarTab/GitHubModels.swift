// MARK: - Models

/// One commit row in the panel.
public struct GitHubCommit: Identifiable, Sendable, Equatable {
    public let sha: String
    public let short: String
    public let author: String
    public let dateISO: String
    public let subject: String
    /// `git log` decorations (branch/remote refs) — displayed as a badge.
    public let refs: String
    /// True when the commit is reachable from HEAD but not from any remote
    /// ref (`git log --not --remotes`); with no remote at all, every commit
    /// counts as unpushed.
    public let unpushed: Bool
    public var id: String { sha }

    public init(sha: String, short: String, author: String, dateISO: String,
                subject: String, refs: String, unpushed: Bool) {
        self.sha = sha
        self.short = short
        self.author = author
        self.dateISO = dateISO
        self.subject = subject
        self.refs = refs
        self.unpushed = unpushed
    }
}

/// One changed file in a commit's detail.
public struct GitHubFileChange: Sendable, Equatable {
    public let path: String
    /// A (added), M (modified), D (deleted), R (renamed).
    public let status: String
    public let insertions: Int
    public let deletions: Int

    public init(path: String, status: String, insertions: Int, deletions: Int) {
        self.path = path
        self.status = status
        self.insertions = insertions
        self.deletions = deletions
    }

    public var statusLabel: String {
        switch status {
        case "A": return "Added"
        case "M": return "Modified"
        case "D": return "Deleted"
        case "R": return "Renamed"
        default: return status
        }
    }

    public var statusClass: String {
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
public struct GitHubDetail: Sendable, Equatable {
    public let sha: String
    public let author: String
    public let dateISO: String
    public let subject: String
    public let body: String
    public let files: [GitHubFileChange]

    public init(sha: String, author: String, dateISO: String, subject: String,
                body: String, files: [GitHubFileChange]) {
        self.sha = sha
        self.author = author
        self.dateISO = dateISO
        self.subject = subject
        self.body = body
        self.files = files
    }
}

/// Load state of the GitHub page.
public enum GitHubPageState: Sendable, Equatable {
    case idle
    case loading(String)          // repo path being inspected
    case notARepo(String)         // path that isn't a git work tree
    case repo(String, branch: String?, remote: String?)
    case error(String)
}
