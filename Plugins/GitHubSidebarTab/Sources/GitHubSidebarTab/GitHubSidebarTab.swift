import ArcSidebarTabs
import Foundation
import WebUI

// MARK: - GitHubSidebarTab
//
// The GitHub sidebar tab, provided as a third-party plugin package
// (see `GitHubSidebarTabPlugin`). It inspects the active workspace's
// local git repository — committing, branches, and per-commit file
// changes — with no network access.
//
// The tab is an actor: all state is isolated, and every protocol method
// is async, so the host can render and drive it from anywhere.

public actor GitHubSidebarTab: SidebarTab {

    // MARK: State

    private var page: GitHubPageState = .idle
    private var commits: [GitHubCommit] = []
    private var selectedSHA: String? = nil
    private var detail: GitHubDetail? = nil
    /// The workspace path the current state describes (nil until the
    /// first activation).
    private var loadedPath: String? = nil

    public init() {}

    // MARK: SidebarTab - identity

    public nonisolated var id: String { "github" }
    public nonisolated var title: String { "GitHub" }
    public nonisolated var tooltip: String { "GitHub" }
    public nonisolated var icon: SidebarTabIcon { .named("git-branch") }

    // MARK: SidebarTab - content

    public func panelHTML() async -> String {
        let refreshBtn = btn(
            "gh-refresh", WebUIIcon(.refreshCw, size: .medium).render(),
            " title=\"Refresh repository\" data-tip=\"Refresh\"")
        let head = """
        <div class="panel-head">
          <span class="panel-title">\(esc(title))</span>
          <div class="panel-actions">\(refreshBtn)</div>
        </div>
        """
        let body: String
        switch page {
        case .idle, .loading:
            body = "<div class=\"empty-hint\">Loading repository…</div>"
        case .notARepo(let path):
            body = """
            <div class="gh-notice">
              <div class="gh-notice-title">Not a git project</div>
              <div class="gh-notice-body">The workspace <code>\(esc(path))</code> is not a git repository, so there is nothing to show. Open a chat whose workspace is a git project, or change the default workspace under Settings → Workspaces.</div>
            </div>
            """
        case .error(let msg):
            body = "<div class=\"empty-hint\">\(esc(msg))</div>"
        case .repo(let path, let branch, let remote):
            var meta: [String] = []
            if let branch { meta.append("branch <b>\(esc(branch))</b>") }
            if let remote { meta.append("<span class=\"gh-remote\">\(esc(remote))</span>") }
            let unpushedCount = commits.filter(\.unpushed).count
            var sub = "\(esc(path)) · \(commits.count) commits"
            if unpushedCount > 0 {
                sub += " · <span class=\"gh-unpushed\">\(unpushedCount) unpushed</span>"
            }
            let summary = """
            <div class="gh-summary">
              <div class="gh-summary-meta">\(meta.joined(separator: " · "))</div>
              <div class="gh-summary-sub">\(sub)</div>
            </div>
            """
            let rows = commits.map { commitRow($0) }.joined()
            if commits.isEmpty {
                body = summary + "<div class=\"empty-hint\">No commits found.</div>"
            } else {
                body = summary + "<div class=\"gh-list\" data-component-id=\"gh-commit\" data-event=\"click\">\(rows)</div>"
            }
        }
        return head + "<div class=\"panel-body gh-panel-body\" id=\"gh-list-body\">\(body)</div>"
    }

    public func mainHTML() async -> String {
        guard let sha = selectedSHA else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div class="big">\(WebUIIcon(.gitBranch, size: .extraLarge).render())</div><div>Select a commit on the left to see its message and files.</div></div>
            </div>
            """
        }
        guard let detail else {
            return """
            <div class="main-view" style="justify-content:center">
              <div class="blank"><div>Loading commit \(esc(sha))…</div></div>
            </div>
            """
        }
        let filesHTML = detail.files.map { f -> String in
            let plus = f.insertions > 0 ? "<span class=\"gh-num-add\">+\(f.insertions)</span>" : ""
            let minus = f.deletions > 0 ? "<span class=\"gh-num-del\">−\(f.deletions)</span>" : ""
            return """
            <div class="gh-file">
              <span class="gh-status \(f.statusClass)">\(esc(f.statusLabel))</span>
              <span class="gh-file-path">\(esc(f.path))</span>
              <span class="gh-nums">\(plus)\(minus)</span>
            </div>
            """
        }.joined()
        let bodyHTML = detail.body.isEmpty
            ? ""
            : "<div class=\"gh-body\">\(esc(detail.body))</div>"
        return """
        <div class="main-view">
          <div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">
            <div class="detail-card gh-detail">
              <div class="gh-detail-subject">\(esc(detail.subject))</div>
              <div class="gh-detail-meta">
                <span class="gh-sha">\(esc(detail.sha))</span> · \(esc(detail.author)) · \(ghShortDate(detail.dateISO))
              </div>
              \(bodyHTML)
              <div class="gh-files-head">Files changed <span class="gh-files-count">\(detail.files.count)</span></div>
              <div class="gh-files">\(filesHTML.isEmpty ? "<div class=\"empty-hint\">No file changes (merge or empty commit).</div>" : filesHTML)</div>
            </div>
          </div>
        </div>
        """
    }

    // MARK: SidebarTab - wiring

    public func install(_ registration: SidebarTabRegistration) async {
        // Refresh button: re-inspect the repo + reload commits.
        registration.on("gh-refresh", events: ["click"]) { _ in
            await self.reload(path: self.loadedPath)
            return await self.fragments()
        }
        // Commit rows: load the selected commit's message + file changes.
        registration.on("gh-commit", events: ["click"]) { event in
            guard let tid = event.string("targetId"), tid.hasPrefix("gh-commit-") else { return [] }
            let sha = String(tid.dropFirst("gh-commit-".count))
            await self.select(sha: sha)
            return await self.fragments()
        }
    }

    // MARK: SidebarTab - lifecycle

    /// First open (or any re-open) inspects the active chat's workspace;
    /// subsequent activations are instant unless the workspace changed.
    public func onActivate(_ host: SidebarTabHost) async {
        let path = await host.workspacePath()
        await ensureLoaded(path: path)
    }

    // MARK: Loading

    /// Load (once) when the tab becomes active; reload on demand.
    private func ensureLoaded(path: String) async {
        guard loadedPath != path else { return }
        await reload(path: path)
    }

    /// Full reload: re-inspect the repo and rebuild the commit list.
    private func reload(path: String?) async {
        guard let path, !path.isEmpty else {
            page = .idle
            commits = []
            selectedSHA = nil
            detail = nil
            loadedPath = nil
            return
        }
        loadedPath = path
        selectedSHA = nil
        detail = nil
        page = .loading(path)
        let state = await GitHubLoader.state(for: path)
        switch state {
        case .repo(let p, let branch, let remote):
            let list = await GitHubLoader.commits(for: p)
            commits = list
            page = .repo(p, branch: branch, remote: remote)
        default:
            commits = []
            page = state
        }
    }

    /// Select a commit and load its detail.
    private func select(sha: String) async {
        selectedSHA = sha
        detail = nil
        if case .repo(let path, _, _) = page {
            detail = await GitHubLoader.detail(for: path, sha: sha)
        }
    }

    private func fragments() async -> [SidebarFragment] {
        [.panel(await panelHTML()), .main(await mainHTML())]
    }

    // MARK: Rendering helpers

    private func commitRow(_ c: GitHubCommit) -> String {
        let active = c.sha == selectedSHA ? " active" : ""
        let unpushed = c.unpushed ? "<span class=\"gh-unpushed-badge\">↑ unpushed</span>" : ""
        let refs = c.refs.isEmpty
            ? ""
            : "<span class=\"gh-refs\">\(esc(SidebarTabHTML.trunc(c.refs, 40)))</span>"
        let date = ghShortDate(c.dateISO)
        return """
        <button type="button" id="gh-commit-\(c.sha)" class="gh-commit\(active)">
          <span class="gh-commit-row">
            <span class="gh-sha">\(esc(c.short))</span>
            <span class="gh-commit-subject">\(esc(SidebarTabHTML.trunc(c.subject, 56)))</span>
          </span>
          <span class="gh-commit-meta">\(esc(c.author)) · \(date)\(unpushed)</span>
          \(refs.isEmpty ? "" : "<span class=\"gh-commit-refs\">\(refs)</span>")
        </button>
        """
    }

    /// Compact display date for a git ISO-8601 timestamp (%aI).
    private func ghShortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let date = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d, HH:mm"
        return out.string(from: date)
    }

    private func esc(_ s: String) -> String { SidebarTabHTML.escape(s) }

    private func btn(_ id: String, _ inner: String, _ attrs: String) -> String {
        "<button type=\"button\" id=\"\(id)\" class=\"icon-btn\"\(attrs)>\(inner)</button>"
    }
}

// MARK: - GitHubSidebarTabPlugin

/// Plugin bundle descriptor for the GitHub sidebar tab.
public struct GitHubSidebarTabPlugin: SidebarTabPlugin {
    public let name = "github-sidebar-tab"
    public let version = "1.0.0"
    public let description = "Local git repository explorer: commit list for the active workspace, with per-commit messages and file changes. No network access."

    public init() {}

    public func tabs() -> [any SidebarTab] {
        [GitHubSidebarTab()]
    }
}
