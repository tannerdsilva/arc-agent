import System
import Foundation

/// The `patch` tool: targeted find-and-replace edits (replace mode) or a V4A
/// diff patch for multi-file edits (patch mode). Faithful port of Hermes
/// `patch` with the full 9-strategy fuzzy matcher.
public enum PatchTool {

    public static let entry = ToolEntry(
        name: "patch",
        toolset: "file",
        description: "Targeted find-and-replace edits. "
            + "Use this instead of write_file for surgical changes. "
            + "Replace mode: path + old_string + new_string (optionally "
            + "replace_all for multiple occurrences). Patch mode: a V4A diff "
            + "patch (*** Begin Patch ... *** End Patch) for multi-file edits. "
            + "Auto-runs syntax checks and returns a unified diff.",
        schema: .object(properties: [
            "mode": .string(description: "replace (default) or patch", default: "replace"),
            "path": .string(description: "Path of the file to edit"),
            "old_string": .string(description: "Exact text to find"),
            "new_string": .string(description: "Replacement text"),
            "replace_all": .boolean(description: "Replace all occurrences instead of requiring a unique match (default: false)", default: false),
            "patch": .string(description: "V4A diff patch content (patch mode)"),
        ]),
        handler: { args in
            let mode = (args["mode"] as? String) ?? "replace"
            switch mode {
            case "patch":
                let patchText: String = try Self.required(args, key: "patch")
                return try await Self.applyV4A(patchText)
            default:
                let path: String = try Self.required(args, key: "path")
                let oldString: String = try Self.required(args, key: "old_string")
                let newString: String = try Self.required(args, key: "new_string")
                let replaceAll = (args["replace_all"] as? Bool) ?? false
                return try await Self.replace(path: path, old: oldString, new: newString, replaceAll: replaceAll)
            }
        },
        emoji: "🔧"
    )

    // MARK: - Replace mode

    private static func replace(path: String, old: String, new: String, replaceAll: Bool) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if FileSafety.isWriteDenied(expanded) {
            return "Error: Refusing to patch a protected path: \(path). Choose a different location."
        }
        guard FileManager.default.fileExists(atPath: expanded) else {
            return "Error: File not found: \(expanded)."
        }
        guard let original = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return "Error: Could not read file as UTF-8: \(expanded)."
        }

        // Preserve the file's line-ending style (CRLF vs LF).
        let crlf = original.contains("\r\n")
        let content = original.replacingOccurrences(of: "\r\n", with: "\n")

        let (result, count, strategy, error) = FuzzyMatch.fuzzyFindAndReplace(
            content: content, old: old, new: new, replaceAll: replaceAll)

        if count == 0 {
            if FuzzyMatch.isAlreadyApplied(content: content, old: old, new: new) {
                return "Patch appears to have already been applied (no changes made)."
            }
            var msg = error ?? "Error: Could not find a match for old_string."
            msg += FuzzyMatch.formatNoMatchHint(error: error, matchCount: count, old: old, content: content)
            return "Error: \(msg)"
        }

        guard result != content else {
            return "Error: The patch was attempted but produced no change (old_string and "
                + "new_string may be insufficiently different)."
        }

        let finalText = crlf ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
        guard let data = finalText.data(using: .utf8) else {
            return "Error: Could not encode patched content as UTF-8."
        }

        let filePath = FilePath(expanded)
        try createParentDirectory(for: filePath)
        let fd = try FileDescriptor.open(filePath, .writeOnly, options: [.create, .truncate], permissions: .ownerReadWrite)
        defer { try? fd.close() }
        try data.withUnsafeBytes { rawBuffer in
            var totalWritten = 0
            while totalWritten < data.count {
                let remaining = UnsafeRawBufferPointer(
                    start: rawBuffer.baseAddress!.advanced(by: totalWritten),
                    count: data.count - totalWritten
                )
                totalWritten += try fd.write(remaining)
            }
        }

        var message = "Successfully applied patch to '\(expanded)' (\(count) match\(count == 1 ? "" : "es")):"
        if let strategy, strategy != "exact" {
            message += "\n(fuzzy matched with \(strategy) strategy)"
        }
        var diff = unifiedDiff(old: content, new: result, oldPath: "a/\(expanded)", newPath: "b/\(expanded)")
        if diff.count > 4000 {
            diff = String(diff.prefix(4000)) + "\n... (diff truncated)"
        }
        return message + "\n" + diff
    }

    // MARK: - Patch (V4A) mode

    private static func applyV4A(_ patchText: String) async throws -> String {
        let (operations, parseError) = V4APatch.parseV4APatch(patchText)
        if let parseError {
            return "Error: \(parseError)"
        }
        if operations.isEmpty {
            return "Error: No operations found in the patch (expected *** Begin Patch ... *** End Patch)."
        }
        let outcome = V4APatch.applyV4AOperations(operations, fileOps: FileSystemV4AOps())
        if !outcome.success {
            return "Error: \(outcome.error ?? "Patch failed")"
        }
        var message = "Successfully applied V4A patch:"
        if !outcome.filesModified.isEmpty {
            message += "\nModified: \(outcome.filesModified.joined(separator: ", "))"
        }
        if !outcome.filesCreated.isEmpty {
            message += "\nCreated: \(outcome.filesCreated.joined(separator: ", "))"
        }
        if !outcome.filesDeleted.isEmpty {
            message += "\nDeleted: \(outcome.filesDeleted.joined(separator: ", "))"
        }
        var diff = outcome.diff
        if diff.count > 8000 {
            diff = String(diff.prefix(8000)) + "\n... (diff truncated)"
        }
        if !diff.isEmpty {
            message += "\n" + diff
        }
        return message
    }

    // MARK: - Helpers

    private static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }

    private static func createParentDirectory(for path: FilePath) throws {
        let parent = path.removingLastComponent()
        let parentStr = parent.string
        guard !parentStr.isEmpty, parentStr != path.string else { return }
        try FileManager.default.createDirectory(atPath: parentStr, withIntermediateDirectories: true, attributes: nil)
    }
}

/// Filesystem-backed V4AFileOps with the same guards as WriteFileTool.
struct FileSystemV4AOps: V4AFileOps {
    func readFileRaw(_ path: String) -> (String?, String?) {
        let expanded = (path as NSString).expandingTildeInPath
        if FileSafety.isWriteDenied(expanded) {
            return (nil, "Refusing to access a protected path: \(path)")
        }
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return (nil, "file not found or not UTF-8: \(expanded)")
        }
        return (content, nil)
    }

    func writeFile(_ path: String, _ content: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if FileSafety.isWriteDenied(expanded) {
            return "Refusing to write to a protected path: \(path)"
        }
        let fm = FileManager.default
        let parent = (expanded as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: nil)
            try content.data(using: .utf8)?.write(to: URL(fileURLWithPath: expanded))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteFile(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if FileSafety.isWriteDenied(expanded) {
            return "Refusing to delete a protected path: \(path)"
        }
        do {
            try FileManager.default.removeItem(atPath: expanded)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func moveFile(_ from: String, _ to: String) -> String? {
        let f = (from as NSString).expandingTildeInPath
        let t = (to as NSString).expandingTildeInPath
        if FileSafety.isWriteDenied(f) {
            return "Refusing to move a protected path: \(from)"
        }
        do {
            try FileManager.default.moveItem(atPath: f, toPath: t)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
