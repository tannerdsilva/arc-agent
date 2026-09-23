import Foundation

/// Hermes `_resolve_path_for_task` / `_path_resolution_warning` parity.
///
/// Relative paths passed to file tools anchor to the **conversation's
/// configured workspace root** (the webui binds the session's workspace; the
/// CLI binds its launch cwd — the equivalent of Hermes' `TERMINAL_CWD`).
/// Absolute paths are resolved but never anchored.
///
/// A relative path that resolves OUTSIDE that root is surfaced as a warning
/// in the tool result instead of silently reading or editing a different
/// checkout — the worktree-cwd divergence bug Hermes guards against (a
/// future audit could read the wrong codebase and nobody would know).
///
/// Binding is `@TaskLocal`: the turn engine sets the root around every tool
/// dispatch, so one conversation's workspace can never leak into another's
/// resolution.
public enum WorkspacePath {

    /// Task-local workspace root (absolute) bound by the turn engine around
    /// every tool dispatch. `nil` = no root configured: resolution falls back
    /// to process-relative behavior (as it did before anchoring existed).
    @TaskLocal public static var root: String?

    private static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func isAbsolute(_ path: String) -> Bool {
        (path as NSString).isAbsolutePath
    }

    /// Resolve `path` (supports `~`, relative and absolute forms) against the
    /// bound workspace root. Symlinks are resolved so escape detection and
    /// I/O operate on the same real file (Hermes `.resolve()` parity).
    public static func resolve(_ path: String) -> String {
        let e = expanded(path)
        let url: URL
        if isAbsolute(e) {
            url = URL(fileURLWithPath: e)
        } else if let root {
            url = URL(fileURLWithPath: root).appendingPathComponent(e)
        } else {
            url = URL(fileURLWithPath: e)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Hermes `_path_resolution_warning` parity: warns when the ORIGINAL path
    /// was relative and RESOLVED outside the bound workspace root.
    ///
    /// - Returns: `nil` when the path is absolute, when no root is bound, or
    ///   when the resolved path is inside the root; otherwise a message naming
    ///   the absolute target so the divergence is visible, never silent.
    public static func divergenceWarning(original: String, resolved: String) -> String? {
        guard let root else { return nil }
        let e = expanded(original)
        if isAbsolute(e) { return nil }

        let rootURL = URL(fileURLWithPath: root)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        let resolvedPath = URL(fileURLWithPath: resolved)
            .standardizedFileURL.resolvingSymlinksInPath().path

        if resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") {
            return nil
        }
        return "WARNING: relative path '\(original)' resolved to '\(resolvedPath)', "
            + "which is OUTSIDE the active workspace ('\(rootPath)'). If this is not "
            + "intended (e.g. you meant a sibling checkout or an explicit absolute "
            + "path), use an absolute path — this operation will otherwise apply to a "
            + "different directory than the conversation workspace."
    }

    /// Convenience: resolve and warn in one step.
    public static func resolveChecked(_ path: String) -> (resolved: String, warning: String?) {
        let resolved = resolve(path)
        return (resolved, divergenceWarning(original: path, resolved: resolved))
    }
}
