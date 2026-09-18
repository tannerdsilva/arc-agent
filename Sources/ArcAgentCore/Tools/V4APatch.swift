import Foundation

// MARK: - V4A patch format (faithful port of Hermes tools/patch_parser.py)
//
// Parses and applies the V4A patch format used by codex, cline, and other
// coding agents: *** Begin Patch / *** Update File / *** Add File /
// *** Delete File / *** Move File / *** End Patch, with hunks of
// ' ' (context), '-' (remove), '+' (add) lines and optional @@ hint @@.

enum V4AOperationType {
    case add, update, delete, move
}

struct V4AHunkLine {
    let prefix: Character   // ' ', '-', '+'
    let content: String
}

struct V4AHunk {
    var contextHint: String?
    var lines: [V4AHunkLine] = []
}

struct V4APatchOperation {
    let operation: V4AOperationType
    let filePath: String
    var newPath: String?
    var hunks: [V4AHunk] = []
    var content: String?
}

enum V4APatch {

    static let bs = String(UnicodeScalar(92)!)  // backslash, byte-safe

    // MARK: - Parse

    static func parseV4APatch(_ patchContent: String) -> (operations: [V4APatchOperation], error: String?) {
        // Tolerate CRLF patch bodies: strip a trailing \r from every line so
        // markers match and hunk content stays clean.
        let lines = patchContent.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var operations: [V4APatchOperation] = []

        func isBegin(_ l: String) -> Bool { matches(l, "***", "Begin", "Patch") }
        func isEnd(_ l: String) -> Bool { matches(l, "***", "End", "Patch") }

        var startIdx: Int?
        var endIdx: Int?
        for (i, line) in lines.enumerated() {
            if isBegin(line) { startIdx = i }
            else if isEnd(line) { endIdx = i; break }
        }
        if startIdx == nil { startIdx = -1 }
        if endIdx == nil { endIdx = lines.count }

        var i = (startIdx ?? -1) + 1
        var currentOp: V4APatchOperation?
        var currentHunk: V4AHunk?

        func flush() {
            if var op = currentOp {
                if let h = currentHunk, !h.lines.isEmpty {
                    op.hunks.append(h)
                }
                operations.append(op)
            }
        }

        while i < endIdx! {
            let line = lines[i]
            if let m = markerMatch(line, "Update", "File:") {
                flush()
                currentOp = V4APatchOperation(operation: .update, filePath: m)
                currentHunk = nil
            } else if let m = markerMatch(line, "Add", "File:") {
                flush()
                currentOp = V4APatchOperation(operation: .add, filePath: m)
                currentHunk = V4AHunk()
            } else if let m = markerMatch(line, "Delete", "File:") {
                flush()
                operations.append(V4APatchOperation(operation: .delete, filePath: m))
                currentOp = nil
                currentHunk = nil
            } else if let m = moveMatch(line) {
                flush()
                operations.append(V4APatchOperation(operation: .move, filePath: m.0, newPath: m.1))
                currentOp = nil
                currentHunk = nil
            } else if line.hasPrefix("@@") {
                if currentOp != nil {
                    if let h = currentHunk, !h.lines.isEmpty {
                        currentOp?.hunks.append(h)
                    }
                    let hint = contextHint(line)
                    currentHunk = V4AHunk(contextHint: hint)
                }
            } else if currentOp != nil && !line.isEmpty {
                if currentHunk == nil { currentHunk = V4AHunk() }
                if line.hasPrefix("+") {
                    currentHunk?.lines.append(V4AHunkLine(prefix: "+", content: String(line.dropFirst())))
                } else if line.hasPrefix("-") {
                    currentHunk?.lines.append(V4AHunkLine(prefix: "-", content: String(line.dropFirst())))
                } else if line.hasPrefix(" ") {
                    currentHunk?.lines.append(V4AHunkLine(prefix: " ", content: String(line.dropFirst())))
                } else if line.hasPrefix(bs) {
                    // "\ No newline at end of file" marker — skip
                } else {
                    currentHunk?.lines.append(V4AHunkLine(prefix: " ", content: line))
                }
            }
            i += 1
        }
        flush()

        if operations.isEmpty {
            return (operations, nil)
        }

        var parseErrors: [String] = []
        for op in operations {
            if op.filePath.isEmpty {
                parseErrors.append("Operation with empty file path")
            }
            if op.operation == .update && op.hunks.isEmpty {
                parseErrors.append("UPDATE \(op.filePath): no hunks found")
            }
            if op.operation == .move && (op.newPath?.isEmpty ?? true) {
                parseErrors.append("MOVE \(op.filePath): missing destination path (expected 'src -> dst')")
            }
        }
        if !parseErrors.isEmpty {
            return ([], "Parse error: " + parseErrors.joined(separator: "; "))
        }
        return (operations, nil)
    }

    static func matches(_ line: String, _ a: String, _ b: String, _ c: String) -> Bool {
        let comps = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return comps.count == 3 && comps[0] == a && comps[1] == b && comps[2] == c
    }

    static func markerMatch(_ line: String, _ verb: String, _ verbFile: String) -> String? {
        // *** Update File: path/to/file.py  (markers must start at column 0)
        guard line.hasPrefix("***") else { return nil }
        var rest = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix(verb) else { return nil }
        rest = String(rest.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix(verbFile) else { return nil }
        let path = String(rest.dropFirst(verbFile.count)).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    static func moveMatch(_ line: String) -> (String, String)? {
        guard let m = markerMatch(line, "Move", "File:") else { return nil }
        guard let arrowRange = m.range(of: "->") else { return nil }
        let src = String(m[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let dst = String(m[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (src, dst)
    }

    static func contextHint(_ line: String) -> String? {
        guard line.hasPrefix("@@") else { return nil }
        let body = String(line.dropFirst(2))
        guard let end = body.range(of: "@@") else { return nil }
        let hint = String(body[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        return hint.isEmpty ? nil : hint
    }

    static func countOccurrences(_ text: String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var start = text.startIndex
        while start < text.endIndex {
            guard let r = text.range(of: needle, range: start..<text.endIndex) else { break }
            count += 1
            start = r.upperBound
        }
        return count
    }

    // MARK: - Validation

    /// Validate all operations without writing; returns error strings.
    static func validateOperations(
        _ operations: [V4APatchOperation],
        fileOps: V4AFileOps
    ) -> [String] {
        var errors: [String] = []
        var realChangeCount = 0
        var pendingContent: [String: String] = [:]
        var removedPaths = Set<String>()

        func read(_ path: String) -> (String?, String?) {
            if removedPaths.contains(path) && pendingContent[path] == nil {
                return (nil, "file not found")
            }
            if let c = pendingContent[path] {
                return (c, nil)
            }
            return fileOps.readFileRaw(path)
        }

        for op in operations {
            if op.operation != .update { realChangeCount += 1 }
            switch op.operation {
            case .update:
                let (content, readErr) = read(op.filePath)
                if let readErr {
                    errors.append("\(op.filePath): \(readErr)")
                    continue
                }
                var simulated = content ?? ""
                for (hunkIndex, hunk) in op.hunks.enumerated() {
                    let searchLines = hunk.lines.filter { $0.prefix == " " || $0.prefix == "-" }.map { $0.content }
                    let removedLines = hunk.lines.filter { $0.prefix == "-" }.map { $0.content }
                    let addedLines = hunk.lines.filter { $0.prefix == "+" }.map { $0.content }
                    if removedLines.isEmpty && addedLines.isEmpty {
                        continue  // inert anchor hunk
                    }
                    realChangeCount += 1
                    if searchLines.isEmpty {
                        // Addition-only hunk: validate context hint uniqueness
                        if let hint = hunk.contextHint {
                            let occurrences = countOccurrences(simulated, hint)
                            if occurrences == 0 {
                                errors.append("\(op.filePath): addition-only hunk context hint '\(hint)' not found")
                            } else if occurrences > 1 {
                                errors.append("\(op.filePath): addition-only hunk context hint '\(hint)' is ambiguous (\(occurrences) occurrences)")
                            }
                        }
                        continue
                    }
                    let searchPattern = searchLines.joined(separator: "\n")
                    var replaceLines: [String] = []
                    for l in hunk.lines {
                        if l.prefix == " " || l.prefix == "+" { replaceLines.append(l.content) }
                    }
                    let replacement = replaceLines.joined(separator: "\n")

                    let (newSimulated, count, _, matchError) = FuzzyMatch.fuzzyFindAndReplace(
                        content: simulated, old: searchPattern, new: replacement, replaceAll: false)
                    if count == 0 {
                        if FuzzyMatch.isAlreadyApplied(content: simulated, old: searchPattern, new: replacement) {
                            continue
                        }
                        let label = hunk.contextHint.map { "'\($0)'" } ?? "(no hint)"
                        var msg = "\(op.filePath): hunk \(hunkIndex + 1) \(label) not found"
                        if let me = matchError { msg += " — \(me)" }
                        msg += FuzzyMatch.formatNoMatchHint(error: matchError, matchCount: count, old: searchPattern, content: simulated)
                        errors.append(msg)
                    } else {
                        simulated = newSimulated
                    }
                }
                pendingContent[op.filePath] = simulated

            case .delete:
                let (_, readErr) = read(op.filePath)
                if readErr != nil {
                    errors.append("\(op.filePath): file not found for deletion")
                } else {
                    removedPaths.insert(op.filePath)
                    pendingContent.removeValue(forKey: op.filePath)
                }

            case .move:
                guard let newPath = op.newPath, !newPath.isEmpty else {
                    errors.append("\(op.filePath): MOVE operation missing destination path")
                    continue
                }
                let (srcContent, srcErr) = read(op.filePath)
                if srcErr != nil {
                    errors.append("\(op.filePath): source file not found for move")
                }
                let (_, dstErr) = read(newPath)
                if dstErr == nil {
                    errors.append("\(newPath): destination already exists — move would overwrite")
                }
                if srcErr == nil && dstErr != nil {
                    pendingContent[newPath] = srcContent ?? ""
                    pendingContent.removeValue(forKey: op.filePath)
                    removedPaths.insert(op.filePath)
                }

            case .add:
                break  // parent dir creation handled by write; no pre-check
            }
        }

        if errors.isEmpty && realChangeCount == 0 {
            errors.append("Patch contains no changes (only context lines were provided)")
        }
        return errors
    }

    // MARK: - Apply

    /// Two-phase validate-then-apply. Returns a PatchOutcome.
    static func applyV4AOperations(
        _ operations: [V4APatchOperation],
        fileOps: V4AFileOps
    ) -> PatchOutcome {
        let validationErrors = validateOperations(operations, fileOps: fileOps)
        if !validationErrors.isEmpty {
            return PatchOutcome(
                success: false,
                error: "Patch validation failed (no files were modified):\n"
                    + validationErrors.map { "  • \($0)" }.joined(separator: "\n"))
        }

        var filesModified: [String] = []
        var filesCreated: [String] = []
        var filesDeleted: [String] = []
        var allDiffs: [String] = []
        var errors: [String] = []

        for op in operations {
            switch op.operation {
            case .add:
                if let r = applyAdd(op, fileOps: fileOps) {
                    filesCreated.append(op.filePath)
                    allDiffs.append(r)
                } else {
                    errors.append("Failed to add \(op.filePath)")
                }
            case .delete:
                if let r = applyDelete(op, fileOps: fileOps) {
                    filesDeleted.append(op.filePath)
                    allDiffs.append(r)
                } else {
                    errors.append("Failed to delete \(op.filePath)")
                }
            case .move:
                if let r = applyMove(op, fileOps: fileOps) {
                    filesModified.append("\(op.filePath) -> \(op.newPath ?? "")")
                    allDiffs.append(r)
                } else {
                    errors.append("Failed to move \(op.filePath)")
                }
            case .update:
                if let r = applyUpdate(op, fileOps: fileOps) {
                    filesModified.append(op.filePath)
                    allDiffs.append(r)
                } else {
                    errors.append("Failed to update \(op.filePath)")
                }
            }
        }

        let combinedDiff = allDiffs.joined(separator: "\n")
        if !errors.isEmpty {
            return PatchOutcome(
                success: false,
                diff: combinedDiff,
                filesModified: filesModified,
                filesCreated: filesCreated,
                filesDeleted: filesDeleted,
                error: "Apply phase failed (state may be inconsistent — run `git diff` to assess):\n"
                    + errors.map { "  • \($0)" }.joined(separator: "\n"))
        }
        return PatchOutcome(
            success: true,
            diff: combinedDiff,
            filesModified: filesModified,
            filesCreated: filesCreated,
            filesDeleted: filesDeleted)
    }

    static func applyAdd(_ op: V4APatchOperation, fileOps: V4AFileOps) -> String? {
        var contentLines: [String] = []
        for hunk in op.hunks {
            for line in hunk.lines where line.prefix == "+" {
                contentLines.append(line.content)
            }
        }
        let content = contentLines.joined(separator: "\n")
        if fileOps.writeFile(op.filePath, content) != nil {
            return nil
        }
        var diff = "--- /dev/null\n+++ b/\(op.filePath)\n"
        diff += contentLines.map { "+\($0)" }.joined(separator: "\n")
        return diff
    }

    static func applyDelete(_ op: V4APatchOperation, fileOps: V4AFileOps) -> String? {
        let (readResult, readErr) = fileOps.readFileRaw(op.filePath)
        if readErr != nil {
            return nil
        }
        if fileOps.deleteFile(op.filePath) != nil {
            return nil
        }
        let removedLines = (readResult ?? "").components(separatedBy: "\n")
        var diff = ""
        diff += "--- a/\(op.filePath)\n+++ /dev/null\n"
        for line in removedLines where !line.isEmpty {
            diff += "-\(line)\n"
        }
        return diff.isEmpty ? "# Deleted: \(op.filePath)" : diff
    }

    static func applyMove(_ op: V4APatchOperation, fileOps: V4AFileOps) -> String? {
        guard let newPath = op.newPath else { return nil }
        if fileOps.moveFile(op.filePath, newPath) != nil {
            return nil
        }
        return "# Moved: \(op.filePath) -> \(newPath)"
    }

    static func applyUpdate(_ op: V4APatchOperation, fileOps: V4AFileOps) -> String? {
        let (readResult, readErr) = fileOps.readFileRaw(op.filePath)
        if let readErr {
            return nil
        }
        var newContent = readResult ?? ""

        for hunk in op.hunks {
            var searchLines: [String] = []
            var replaceLines: [String] = []
            for line in hunk.lines {
                if line.prefix == " " {
                    searchLines.append(line.content)
                    replaceLines.append(line.content)
                } else if line.prefix == "-" {
                    searchLines.append(line.content)
                } else if line.prefix == "+" {
                    replaceLines.append(line.content)
                }
            }
            if !searchLines.isEmpty && searchLines == replaceLines {
                continue
            }
            if !searchLines.isEmpty {
                let searchPattern = searchLines.joined(separator: "\n")
                let replacement = replaceLines.joined(separator: "\n")
                var (result, count, _, error) = FuzzyMatch.fuzzyFindAndReplace(
                    content: newContent, old: searchPattern, new: replacement, replaceAll: false)
                if error != nil && count == 0 {
                    if let hint = hunk.contextHint {
                        if let hintPos = newContent.range(of: hint) {
                            let offset = newContent.distance(from: newContent.startIndex, to: hintPos.lowerBound)
                            let windowStart = max(0, offset - 500)
                            let windowEnd = min(newContent.count, offset + 2000)
                            let ws = newContent.index(newContent.startIndex, offsetBy: windowStart)
                            let we = newContent.index(newContent.startIndex, offsetBy: windowEnd)
                            let window = String(newContent[ws..<we])
                            let (windowNew, wCount, _, _) = FuzzyMatch.fuzzyFindAndReplace(
                                content: window, old: searchPattern, new: replacement, replaceAll: false)
                            if wCount > 0 {
                                let prefix = String(newContent[..<ws])
                                let suffix = String(newContent[we...])
                                result = prefix + windowNew + suffix
                                count = wCount
                                error = nil
                            }
                        }
                    }
                    if error != nil {
                        if FuzzyMatch.isAlreadyApplied(content: newContent, old: searchPattern, new: replacement) {
                            continue
                        }
                        var errMsg = "Could not apply hunk: \(error ?? "")"
                        errMsg += FuzzyMatch.formatNoMatchHint(error: error, matchCount: 0, old: searchPattern, content: newContent)
                        return nil
                    }
                }
                newContent = result
            } else {
                // Addition-only hunk: insert at hint location or EOF.
                let insertText = replaceLines.joined(separator: "\n")
                if let hint = hunk.contextHint {
                    let occurrences = countOccurrences(newContent, hint)
                    if occurrences == 0 {
                        newContent = newContent.trimmingCharacters(in: .newlines) + "\n" + insertText + "\n"
                    } else if occurrences > 1 {
                        return nil  // ambiguous
                    } else if let hintPos = newContent.range(of: hint) {
                        let eol = newContent[hintPos.upperBound...].firstIndex(of: "\n")
                        if let eol {
                            let insertIdx = newContent.index(after: eol)
                            newContent.insert(contentsOf: insertText + "\n", at: insertIdx)
                        } else {
                            newContent += "\n" + insertText
                        }
                    }
                } else {
                    newContent = newContent.trimmingCharacters(in: .newlines) + "\n" + insertText + "\n"
                }
            }
        }

        if let err = fileOps.writeFile(op.filePath, newContent) {
            return nil
        }
        return unifiedDiff(
            old: readResult ?? "", new: newContent, oldPath: "a/\(op.filePath)", newPath: "b/\(op.filePath)")
    }
}

// MARK: - Outcomes & file ops

struct PatchOutcome {
    var success: Bool
    var diff: String = ""
    var filesModified: [String] = []
    var filesCreated: [String] = []
    var filesDeleted: [String] = []
    var error: String?
}

/// The minimal file operations surface V4A needs (adapter over the real
/// filesystem — see PatchTool).
protocol V4AFileOps {
    func readFileRaw(_ path: String) -> (String?, String?)
    func writeFile(_ path: String, _ content: String) -> String?
    func deleteFile(_ path: String) -> String?
    func moveFile(_ from: String, _ to: String) -> String?
}

// MARK: - Unified diff

/// Minimal difflib.unified_diff equivalent (LCS-based).
func unifiedDiff(old: String, new: String, oldPath: String, newPath: String) -> String {
    if old == new {
        return "--- \(oldPath)\n+++ \(newPath)\n"
    }
    let oldLines = old.components(separatedBy: "\n")
    let newLines = new.components(separatedBy: "\n")
    let opcodes = diffOpcodes(a: oldLines, b: newLines)

    var out = "--- \(oldPath)\n+++ \(newPath)\n"
    let header = "@@"
    out += "\(header) @@\n"
    for op in opcodes {
        switch op.tag {
        case "equal":
            for k in op.i1..<op.i2 { out += " " + oldLines[k] + "\n" }
        case "delete":
            for k in op.i1..<op.i2 { out += "-" + oldLines[k] + "\n" }
        case "insert":
            for k in op.j1..<op.j2 { out += "+" + newLines[k] + "\n" }
        case "replace":
            for k in op.i1..<op.i2 { out += "-" + oldLines[k] + "\n" }
            for k in op.j1..<op.j2 { out += "+" + newLines[k] + "\n" }
        default:
            break
        }
    }
    return out
}

struct DiffOpcode {
    let tag: String
    let i1: Int, i2: Int, j1: Int, j2: Int
}

func diffOpcodes(a: [String], b: [String]) -> [DiffOpcode] {
    let n = a.count, m = b.count
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            if a[i] == b[j] {
                dp[i][j] = dp[i + 1][j + 1] + 1
            } else {
                dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
            }
        }
    }
    var result: [DiffOpcode] = []
    var i = 0, j = 0
    while i < n && j < m {
        if a[i] == b[j] {
            let i1 = i, j1 = j
            while i < n && j < m && a[i] == b[j] { i += 1; j += 1 }
            result.append(DiffOpcode(tag: "equal", i1: i1, i2: i, j1: j1, j2: j))
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            let i1 = i
            while i < n && j < m && a[i] != b[j] && dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            result.append(DiffOpcode(tag: "delete", i1: i1, i2: i, j1: j, j2: j))
        } else {
            let j1 = j
            while i < n && j < m && a[i] != b[j] && dp[i + 1][j] < dp[i][j + 1] { j += 1 }
            result.append(DiffOpcode(tag: "insert", i1: i, i2: i, j1: j1, j2: j))
        }
    }
    if i < n { result.append(DiffOpcode(tag: "delete", i1: i, i2: n, j1: j, j2: j)) }
    if j < m { result.append(DiffOpcode(tag: "insert", i1: i, i2: i, j1: j, j2: m)) }

    var simplified: [DiffOpcode] = []
    for op in result {
        if op.tag == "delete",
           let last = simplified.last, last.tag == "insert" {
            simplified[simplified.count - 1] = DiffOpcode(
                tag: "replace", i1: last.i1, i2: op.i2, j1: last.j1, j2: last.j2)
        } else if op.tag == "insert",
                  let last = simplified.last, last.tag == "delete" {
            simplified[simplified.count - 1] = DiffOpcode(
                tag: "replace", i1: last.i1, i2: last.i2, j1: last.j1, j2: op.j2)
        } else {
            simplified.append(op)
        }
    }
    return simplified
}
