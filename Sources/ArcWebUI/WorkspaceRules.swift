import Foundation

/// Rules for workspace directory presets — how a user-entered folder path and
/// an optional display name become a stored `WorkspaceEntry`.
///
/// The two fields are distinct by design:
/// - `path` is required and follows Unix path standards: absolute or
///   `~`-anchored, tilde-expanded, lexically standardized (`.`, `..`, repeated
///   and trailing separators collapse) and it must point at an existing
///   directory. It is the folder the session actually works in.
/// - `name` is an optional label. Left blank it is derived from the folder's
///   last path component; a derived collision auto-numbers (`tools-2`) so a
///   create never fails for a reason the user did not type. An explicit name
///   must stay a label — no `/`, no control characters — and a collision is an
///   error: the user typed that name.
///
/// Filesystem access is injected (`isDirectory`) so the rule matrix is pinned
/// in tests without touching disk.
enum WorkspaceRules {

    /// The filesystem seam: true when `path` exists and is a directory.
    static func isExistingDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Tilde-expand, require an absolute Unix path, and lexically standardize
    /// it (`//`, `.`, `..`, trailing separators). Control characters are
    /// rejected: they cannot round-trip through the UI and the settings JSON.
    static func normalizePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceRuleError.pathRequired }
        guard !hasControlCharacters(trimmed) else {
            throw WorkspaceRuleError.pathContainsControlCharacters
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else {
            throw WorkspaceRuleError.pathNotAbsolute(trimmed)
        }
        return (expanded as NSString).standardizingPath
    }

    /// Derive a display name from a folder path (the last component). The
    /// filesystem root has no component — it gets the fallback `workspace`.
    static func derivedName(forPath path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return (last.isEmpty || last == "/") ? "workspace" : last
    }

    /// Validate an explicit label, or derive one from the path when blank.
    /// Derived names auto-number on collision; explicit names error instead.
    static func resolveName(_ raw: String, path: String, existingNames: [String]) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return uniqueName(derivedName(forPath: path), existing: existingNames)
        }
        guard !trimmed.contains("/") else { throw WorkspaceRuleError.nameContainsSlash }
        guard !hasControlCharacters(trimmed) else {
            throw WorkspaceRuleError.nameInvalid("control characters")
        }
        guard trimmed != "." && trimmed != ".." else {
            throw WorkspaceRuleError.nameInvalid("'.' and '..' are reserved")
        }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw WorkspaceRuleError.nameExists(trimmed)
        }
        return trimmed
    }

    /// First free variant of `base` (`base`, `base-2`, `base-3`, …).
    static func uniqueName(_ base: String, existing: [String]) -> String {
        func taken(_ candidate: String) -> Bool {
            existing.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        guard taken(base) else { return base }
        var i = 2
        while taken("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    /// The full create/attach plan: the path is required, validated against
    /// Unix path standards, must be an existing directory, and no other entry
    /// may already point at it. The name is optional and derived when blank.
    static func planEntry(
        name rawName: String,
        path rawPath: String,
        existing: [WorkspaceEntry],
        isDirectory: (String) -> Bool = isExistingDirectory
    ) throws -> WorkspaceEntry {
        let path = try normalizePath(rawPath)
        guard isDirectory(path) else { throw WorkspaceRuleError.pathNotAFolder(path) }
        if let holder = existing.first(where: { sameLocation($0.path, path) }) {
            throw WorkspaceRuleError.pathAlreadyUsed(path: path, name: holder.name)
        }
        let name = try resolveName(rawName, path: path, existingNames: existing.map(\.name))
        return WorkspaceEntry(name: name, path: path)
    }

    /// Location comparison for duplicate detection: stored entries may carry
    /// unnormalized text (hand-edited settings), so both sides are loosely
    /// canonicalized before comparing.
    static func sameLocation(_ lhs: String, _ rhs: String) -> Bool {
        looselyCanonical(lhs) == looselyCanonical(rhs)
    }

    private static func looselyCanonical(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

/// Errors surfaced by the workspace create flow. Each carries its user-facing
/// message so the UI can toast the reason as-is.
enum WorkspaceRuleError: Error, Equatable, CustomStringConvertible {
    case pathRequired
    case pathNotAbsolute(String)
    case pathContainsControlCharacters
    case pathNotAFolder(String)
    case nameContainsSlash
    case nameInvalid(String)
    case nameExists(String)
    case pathAlreadyUsed(path: String, name: String)

    var description: String {
        switch self {
        case .pathRequired:
            return "Folder path is required — it is the folder this workspace points at."
        case .pathNotAbsolute(let raw):
            return "Folder path '\(raw)' must be absolute: start with '/' or use '~' for your home folder."
        case .pathContainsControlCharacters:
            return "Folder path contains control characters and cannot be stored."
        case .pathNotAFolder(let path):
            return "No folder at '\(path)' — create it first, or check the path."
        case .nameContainsSlash:
            return "Workspace names can't contain '/'. If you meant a folder, put it in the Folder path field — the name is just a label."
        case .nameInvalid(let reason):
            return "Invalid workspace name (\(reason))."
        case .nameExists(let name):
            return "A workspace named '\(name)' already exists."
        case .pathAlreadyUsed(let path, let name):
            return "'\(path)' is already the folder for workspace '\(name)'."
        }
    }
}