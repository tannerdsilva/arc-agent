import Foundation

// MARK: - Projects (reference `tools/project_tools.py` + `arc_cli/projects_db.py`)

/// A named workspace (reference "Project"): the intentional way to group work
/// in a repo/folder. The agent's handle on workspaces — never a side effect
/// of a terminal `cd`.
public struct ArcProject: Codable, Sendable, Equatable {
    public let id: String
    public let slug: String
    public let name: String
    public var primaryPath: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, slug: String, name: String, primaryPath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.slug = slug
        self.name = name
        self.primaryPath = primaryPath
        self.createdAt = createdAt
    }
}

/// Persistence + active-selection for Projects (reference `projects.db` analog,
/// stored as `~/.arc/projects.json`). An actor: all mutation is serialized.
public actor ProjectStore {

    private static var _fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/projects.json")

    /// Locations file (test seam — redirects storage, never touches the real
    /// `~/.arc/projects.json` in tests).
    public static func setStorageURL(_ url: URL) { _fileURL = url }
    public static func storageURL() -> URL { _fileURL }

    /// Re-anchor hook: called after a create/switch with the project's
    /// primary path so live sessions (webui sidebar, CLI cwd) can follow.
    /// `nil` in contexts with no live workspace to move.
    public static var workspaceHook: (@Sendable (String?) async -> Void)?

    private var projects: [ArcProject] = []
    private var activeID: String?
    private var loaded = false

    public init() {}

    // MARK: - CRUD

    private func loadLocked() throws {
        guard !loaded else { return }
        loaded = true
        let url = Self._fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ProjectsFile.self, from: data) {
            projects = decoded.projects
            activeID = decoded.activeID
        }
    }

    private func saveLocked() throws {
        let url = Self._fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(ProjectsFile(projects: projects, activeID: activeID))
        try data.write(to: url, options: .atomic)
    }

    /// All non-archived projects (reference `list_projects`).
    public func list() throws -> [ArcProject] {
        try loadLocked()
        return projects
    }

    public func active() throws -> ArcProject? {
        try loadLocked()
        guard let activeID else { return nil }
        return projects.first { $0.id == activeID }
    }

    /// Create a project and activate it (reference `create_project` then
    /// `set_active`). `path` is expanded + absolutized.
    @discardableResult
    public func create(name: String, path: String?) async throws -> ArcProject {
        try loadLocked()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.invalidName("name is required")
        }
        let folder = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath = folder.isEmpty ? nil : URL(fileURLWithPath: folder).standardizedFileURL.path
        let project = ArcProject(slug: Self.slugify(trimmed), name: trimmed, primaryPath: resolvedPath)
        projects.append(project)
        activeID = project.id
        try saveLocked()
        await Self.workspaceHook?(resolvedPath)
        return project
    }

    /// Switch the active project by id, slug, or name (case-insensitive).
    @discardableResult
    public func switchTo(token: String) async throws -> ArcProject {
        try loadLocked()
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.notFound("no project matching ''")
        }
        guard let match = resolveLocked(trimmed) else {
            throw ProjectError.notFound("no project matching '\(trimmed)'")
        }
        activeID = match.id
        try saveLocked()
        await Self.workspaceHook?(match.primaryPath)
        return match
    }

    private func resolveLocked(_ token: String) -> ArcProject? {
        if let exact = projects.first(where: { $0.id == token || $0.slug == token || $0.name == token }) {
            return exact
        }
        let low = token.lowercased()
        return projects.first { $0.slug.lowercased() == low || $0.name.lowercased() == low }
    }

    static func slugify(_ name: String) -> String {
        let lower = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "project" : String(trimmed.prefix(48))
    }
}

private struct ProjectsFile: Codable {
    var projects: [ArcProject]
    var activeID: String?
}

/// Errors surfaced by the project tools (reference `{"success": false, ...}`).
public enum ProjectError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalidName(let m): return m
        case .notFound(let m): return m
        }
    }
}
