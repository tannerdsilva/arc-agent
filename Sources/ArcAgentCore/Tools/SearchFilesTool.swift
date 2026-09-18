import Foundation

/// The `search_files` tool: ripgrep-backed content/file search.
/// Faithful port of Hermes `search_files` (rg flags, output modes, zero-match
/// probes, densified match rendering).
public enum SearchFilesTool {

    public static let entry = ToolEntry(
        name: "search_files",
        toolset: "file",
        description: "Search file contents or find files by name. Use this instead of grep/rg/find/ls in terminal. Ripgrep-backed, faster than shell equivalents. "
            + "Content search (target='content'): Regex search inside files. Output modes: full matches with line numbers, file paths only, or match counts. "
            + "File search (target='files'): Find files by glob pattern (e.g., '*.py', '*config*'). Also use this instead of ls — results sorted by modification time.",
        schema: .object(properties: [
            "pattern": .string(description: "Regex pattern for content search, or glob pattern (e.g., '*.py') for file search"),
            "target": .string(description: "'content' searches inside file contents, 'files' searches for files by name", default: "content"),
            "path": .string(description: "Directory or file to search in (default: current working directory)", default: "."),
            "file_glob": .string(description: "Filter files by pattern in grep mode (e.g., '*.py' to only search Python files)"),
            "limit": .integer(description: "Maximum number of results to return (default: 50)", default: 50),
            "offset": .integer(description: "Skip first N results for pagination (default: 0)", default: 0),
            "output_mode": .string(description: "Output format for grep mode: 'content' shows matching lines with line numbers, 'files_only' lists file paths, 'count' shows match counts per file", default: "content"),
            "context": .integer(description: "Number of context lines before and after each match (grep mode only)", default: 0),
        ], required: ["pattern"]),
        handler: { args in
            let pattern: String = try Self.required(args, key: "pattern")
            let target = (args["target"] as? String) ?? "content"
            let path = (args["path"] as? String) ?? "."
            let fileGlob = args["file_glob"] as? String
            let limit = (args["limit"] as? Int) ?? 50
            let offset = (args["offset"] as? Int) ?? 0
            let outputMode = (args["output_mode"] as? String) ?? "content"
            let context = (args["context"] as? Int) ?? 0
            return Self.search(
                pattern: pattern, path: path, target: target, fileGlob: fileGlob,
                limit: limit, offset: offset, outputMode: outputMode, context: context)
        },
        emoji: "🔍"
    )

    // MARK: - Result model

    struct MatchResult {
        var path: String
        var lineNumber: Int
        var content: String
    }

    struct SearchOutcome {
        var matches: [MatchResult] = []
        var files: [String] = []
        var counts: [String: Int] = [:]
        var contextRows: [String] = []
        var totalCount: Int = 0
        var truncated = false
        var warning: String?
        var error: String?
    }

    // MARK: - Handler

    static func search(
        pattern: String, path: String, target: String, fileGlob: String?,
        limit: Int, offset: Int, outputMode: String, context: Int
    ) -> String {
        let clampedLimit = min(max(limit, 1), 500)
        let clampedOffset = max(offset, 0)

        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            var hintParts = ["Path not found: \(path)"]
            let parent = (expandedPath as NSString).deletingLastPathComponent
            let base = (expandedPath as NSString).lastPathComponent
            if FileManager.default.fileExists(atPath: parent), !base.isEmpty {
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: parent) {
                    let lowerQ = base.lowercased()
                    let candidates = entries.filter { entry in
                        let le = entry.lowercased()
                        return lowerQ.contains(le) || le.contains(lowerQ) || le.hasPrefix(String(lowerQ.prefix(3)))
                    }.prefix(5).map { "\(parent)/\($0)" }
                    if !candidates.isEmpty {
                        hintParts.append("Similar paths: " + candidates.joined(separator: ", "))
                    }
                }
            }
            return json(["error": hintParts.joined(separator: ". "), "total_count": 0])
        }

        let bs = String(UnicodeScalar(92)!)  // backslash
        var outcome: SearchOutcome
        if target == "files" {
            outcome = searchFiles(pattern: pattern, path: expandedPath, limit: clampedLimit, offset: clampedOffset)
        } else {
            outcome = searchContent(
                pattern: pattern, path: expandedPath, fileGlob: fileGlob,
                limit: clampedLimit, offset: clampedOffset, outputMode: outputMode,
                context: context, backslash: bs)
        }

        // Zero-match steering probes (Hermes parity).
        if outcome.error == nil && outcome.totalCount == 0
            && outcome.matches.isEmpty && outcome.files.isEmpty && outcome.counts.isEmpty {
            if let hint = zeroMatchProbe(pattern: pattern, path: expandedPath, fileGlob: fileGlob, backslash: bs) {
                outcome.warning = hint
            }
        }

        var dict: [String: Any] = ["total_count": outcome.totalCount]
        if !outcome.matches.isEmpty {
            if outcome.matches.count >= 5 {
                dict["matches_format"] = "path-grouped: each file path on its own line, followed by indented '<line>: <content>' rows for matches in that file"
                dict["matches_text"] = densify(matches: outcome.matches)
            } else {
                dict["matches"] = outcome.matches.map { ["path": $0.path, "line": $0.lineNumber, "content": $0.content] }
            }
        }
        if !outcome.files.isEmpty { dict["files"] = outcome.files }
        if !outcome.counts.isEmpty { dict["counts"] = outcome.counts }
        if outcome.truncated { dict["truncated"] = true }
        if let w = outcome.warning { dict["warning"] = w }
        if let e = outcome.error { dict["error"] = e }

        var resultText = json(dict)
        if outcome.truncated {
            resultText += "\n\n[Hint: Results truncated. Use offset=\(clampedOffset + clampedLimit) to see more, or narrow with a more specific pattern or file_glob.]"
        }
        return resultText
    }

    // MARK: - Content search

    static func searchContent(
        pattern: String, path: String, fileGlob: String?, limit: Int, offset: Int,
        outputMode: String, context: Int, backslash: String
    ) -> SearchOutcome {
        var result = SearchOutcome()
        // Foundation-native fallback when ripgrep is unavailable.
        if !rgAvailable() {
            return foundationSearchContent(
                pattern: pattern, path: path, fileGlob: fileGlob,
                limit: limit, offset: offset, outputMode: outputMode, context: context)
        }
        var args = ["rg", "--line-number", "--no-heading", "--with-filename"]

        let hasRealNewline = pattern.contains("\n")
        let hasEscapedNewline = pattern.contains(backslash + "n")
        if hasRealNewline || hasEscapedNewline {
            args.append("--multiline")
        }
        if context > 0 {
            args += ["-C", String(context)]
        }
        if let fileGlob, !fileGlob.isEmpty {
            args += ["--glob", fileGlob]
        }
        if outputMode == "files_only" {
            args.append("-l")
        } else if outputMode == "count" {
            args.append("-c")
        }
        args.append(pattern)
        args.append(path)

        let (stdout, stderr, exitCode) = runProcess(args)
        let diagnostics = (stderr.isEmpty ? stdout : stderr)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("rg: ") }
            .joined(separator: "\n")
        if exitCode == 2 && stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.error = "Search failed: \(diagnostics.isEmpty ? stdout : diagnostics)"
            return result
        }

        let lines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        if outputMode == "content" {
            var matchList: [MatchResult] = []
            var contextRows: [String] = []
            for raw in lines {
                if raw == "--" { continue }  // rg context group separator
                if raw.hasPrefix(backslash) { continue }
                if raw.hasPrefix("-") || raw.hasPrefix("+") || raw.hasPrefix(" ") {
                    if context > 0 { contextRows.append(raw) }
                    continue
                }
                guard let (mPath, lineNum, content) = parseMatchLine(raw) else { continue }
                matchList.append(MatchResult(path: mPath, lineNumber: lineNum, content: content))
            }
            let page = Array(matchList[offset..<min(offset + limit, matchList.count)])
            result.matches = page
            result.totalCount = page.count
            result.truncated = matchList.count > offset + limit
            if !contextRows.isEmpty {
                result.warning = "Context rows (context=\(context)) rendered as `path[-|+|space]line-content` below."
            }
            _ = contextRows
        } else if outputMode == "files_only" {
            let files = Array(lines[offset..<min(offset + limit, lines.count)])
            result.files = files
            result.truncated = lines.count > offset + limit
        } else if outputMode == "count" {
            var counts: [String: Int] = [:]
            for raw in lines {
                let parts = raw.components(separatedBy: ":")
                guard parts.count >= 2, let n = Int(parts.last ?? "") else { continue }
                let filePath = parts.dropLast().joined(separator: ":")
                counts[filePath] = n
            }
            result.counts = counts
            result.totalCount = counts.count
        }
        return result
    }

    /// Parse `path:line:content` (path may legitimately contain colons on
    /// macOS; the line number is the second-to-last colon-delimited segment).
    static func parseMatchLine(_ raw: String) -> (String, Int, String)? {
        var colons: [String.Index] = []
        var ci = raw.startIndex
        while ci < raw.endIndex {
            if raw[ci] == ":" { colons.append(ci) }
            ci = raw.index(after: ci)
        }
        guard colons.count >= 2 else { return nil }
        let lineSegment = String(raw[raw.index(after: colons[colons.count - 2])..<colons[colons.count - 1]])
        guard let line = Int(lineSegment) else { return nil }
        let path = String(raw[..<colons[colons.count - 2]])
        let content = String(raw[raw.index(after: colons[colons.count - 1])...])
        return (path, line, content)
    }

    // MARK: - File search

    static func searchFiles(pattern: String, path: String, limit: Int, offset: Int) -> SearchOutcome {
        let globPattern: String
        if !pattern.contains("/") && !pattern.hasPrefix("*") {
            globPattern = "*\(pattern)"
        } else {
            globPattern = pattern
        }
        // Foundation-native fallback when ripgrep is unavailable.
        if !rgAvailable() {
            return foundationSearchFiles(pattern: globPattern, path: path, limit: limit, offset: offset)
        }
        var lines: [String] = []
        var (stdout, _, code) = runProcess(["rg", "--files", "--sortr=modified", "-g", globPattern, path])
        if code == 0 && !stdout.isEmpty {
            lines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        if lines.isEmpty {
            (stdout, _, _) = runProcess(["rg", "--files", "-g", globPattern, path])
            lines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        var result = SearchOutcome()
        let page = Array(lines[offset..<min(offset + limit, lines.count)])
        result.files = page
        result.totalCount = lines.count
        result.truncated = lines.count > offset + limit
        return result
    }

    // MARK: - Zero-match probes (Hermes parity)

    static func zeroMatchProbe(pattern: String, path: String, fileGlob: String?, backslash: String) -> String? {
        var globArgs: [String] = []
        if let fileGlob, !fileGlob.isEmpty {
            globArgs = ["--glob", fileGlob]
        }
        let (ciOut, _, _) = runProcess(["rg", "-i", "--count-matches"] + globArgs + [pattern, path])
        var ciTotal = 0
        var ciFiles = 0
        for line in ciOut.components(separatedBy: "\n") {
            if let colon = line.lastIndex(of: ":"), let n = Int(line[line.index(after: colon)...]) {
                ciTotal += n
                ciFiles += 1
            }
        }
        if ciTotal > 0 {
            return "0 exact matches, but \(ciTotal) case-insensitive match(es) in \(ciFiles) file(s) — the pattern's casing may be wrong."
        }
        let (hiddenOut, _, _) = runProcess(["rg", "--hidden", "--no-ignore", "--count-matches"] + globArgs + [pattern, path])
        var hTotal = 0
        var hFiles = 0
        for line in hiddenOut.components(separatedBy: "\n") {
            if let colon = line.lastIndex(of: ":"), let n = Int(line[line.index(after: colon)...]) {
                hTotal += n
                hFiles += 1
            }
        }
        if hTotal > 0 {
            return "0 matches in visible files, but \(hTotal) match(es) in \(hFiles) hidden or gitignored file(s) — these are excluded by default. Search the hidden path explicitly to include them."
        }
        if pattern.range(of: ".[\\[\\](){}?*+^$|]", options: .regularExpression) != nil {
            let (fixedOut, _, _) = runProcess(["rg", "-F", "--count-matches"] + globArgs + [pattern, path])
            var fTotal = 0
            for line in fixedOut.components(separatedBy: "\n") {
                if let colon = line.lastIndex(of: ":"), let n = Int(line[line.index(after: colon)...]) {
                    fTotal += n
                }
            }
            if fTotal > 0 {
                return "0 regex matches, but \(fTotal) literal match(es) — the pattern contains regex metacharacters that likely need escaping (or pass a simpler substring)."
            }
        }
        return nil
    }

    // MARK: - Rendering / helpers

    static func densify(matches: [MatchResult]) -> String {
        var lines: [String] = []
        var currentPath: String?
        for m in matches {
            if m.path != currentPath {
                lines.append(m.path)
                currentPath = m.path
            }
            let trimmed = m.content.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            lines.append("  \(m.lineNumber): \(trimmed)")
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func rgAvailable() -> Bool {
        let (_, _, code) = runProcess(["rg", "--version"])
        return code == 0
    }

    static func runProcess(_ args: [String]) -> (String, String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rg"] + Array(args.dropFirst())
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = String(data: outData, encoding: .utf8) ?? ""
            return (out, "", process.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }

    private static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }

    // MARK: - Foundation-native fallback (no ripgrep)

    /// Enumerate candidate files under `root`, skipping VCS/build/vendor dirs,
    /// hidden entries (except when `includeHidden`), binaries, and huge files.
    static func enumerateFiles(root: String, includeHidden: Bool = false) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: includeHidden ? [] : [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return out }
        let skipDirs: Set<String> = [".git", ".build", "node_modules", ".venv", "venv",
                                     "DerivedData", "Pods", ".swiftpm", ".hg", ".svn"]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                if !includeHidden && skipDirs.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > 2_000_000 { continue }
            out.append(url)
        }
        return out
    }

    /// Read a text file; nil for binaries / non-UTF8.
    static func readTextFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let head = data.prefix(8192)
        if head.contains(0) { return nil }  // NUL byte → binary
        return String(data: data, encoding: .utf8)
    }

    /// Convert a shell glob (`*.swift`, `foo/bar*`) to a regex string.
    static func globToRegex(_ glob: String) -> String {
        var out = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            if c == "*" {
                out += ".*"
            } else if c == "?" {
                out += "."
            } else if c == "[" {
                // character class — pass through until ]
                out.append("[")
                var j = glob.index(after: i)
                while j < glob.endIndex, glob[j] != "]" {
                    if glob[j] == "\\" || glob[j] == "]" { out.append("\\") }
                    out.append(glob[j])
                    j = glob.index(after: j)
                }
                if j < glob.endIndex { out.append("]"); i = j }
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = glob.index(after: i)
        }
        out += "$"
        return out
    }

    static func matchesGlob(_ url: URL, glob: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: globToRegex(glob)) else { return true }
        let name = url.lastPathComponent
        let path = url.path
        let nsName = name as NSString
        let nsPath = path as NSString
        return regex.firstMatch(in: name, options: [], range: NSRange(location: 0, length: nsName.length)) != nil
            || regex.firstMatch(in: path, options: [], range: NSRange(location: 0, length: nsPath.length)) != nil
    }

    /// Content search without ripgrep: enumerate text files, regex per line.
    static func foundationSearchContent(
        pattern: String, path: String, fileGlob: String?, limit: Int, offset: Int,
        outputMode: String, context: Int
    ) -> SearchOutcome {
        var result = SearchOutcome()
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            result.error = "Invalid search pattern: " + pattern
            return result
        }
        let files = enumerateFiles(root: path)
        var matches: [MatchResult] = []
        var counts: [String: Int] = [:]
        var contextRows: [String] = []

        for url in files {
            if let fileGlob, !fileGlob.isEmpty, !matchesGlob(url, glob: fileGlob) { continue }
            guard let text = readTextFile(url) else { continue }
            let lines = text.components(separatedBy: "\n")
            var fileCount = 0
            for (idx, line) in lines.enumerated() {
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    fileCount += 1
                    if outputMode == "content" || outputMode == "count" {
                        matches.append(MatchResult(path: url.path, lineNumber: idx + 1, content: line))
                    }
                    if context > 0 && outputMode == "content" {
                        for c in max(0, idx - context)..<min(lines.count, idx + context + 1) where c != idx {
                            contextRows.append(url.path + ":" + String(c + 1) + ": " + lines[c])
                        }
                    }
                }
            }
            if fileCount > 0 { counts[url.path] = fileCount }
        }
        matches.sort { ($0.path, $0.lineNumber) < ($1.path, $1.lineNumber) }

        if outputMode == "files_only" {
            let filesHit = counts.keys.sorted()
            let page = Array(filesHit[offset..<min(offset + limit, filesHit.count)])
            result.files = page
            result.totalCount = filesHit.count
            result.truncated = filesHit.count > offset + limit
            return result
        }
        if outputMode == "count" {
            let filesHit = counts.keys.sorted()
            let page = Array(filesHit[offset..<min(offset + limit, filesHit.count)])
            result.counts = Dictionary(uniqueKeysWithValues: page.map { ($0, counts[$0] ?? 0) })
            result.totalCount = filesHit.count
            result.truncated = filesHit.count > offset + limit
            return result
        }
        let page = Array(matches[offset..<min(offset + limit, matches.count)])
        result.matches = page
        result.totalCount = matches.count
        result.truncated = matches.count > offset + limit
        if !contextRows.isEmpty { result.contextRows = contextRows }
        return result
    }

    /// File search without ripgrep: enumerate paths matching the glob,
    /// newest first (mirrors `rg --files --sortr=modified`).
    static func foundationSearchFiles(pattern: String, path: String, limit: Int, offset: Int) -> SearchOutcome {
        var result = SearchOutcome()
        let files = enumerateFiles(root: path)
            .filter { matchesGlob($0, glob: pattern) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        let paths = files.map { $0.path }
        let page = Array(paths[offset..<min(offset + limit, paths.count)])
        result.files = page
        result.totalCount = paths.count
        result.truncated = paths.count > offset + limit
        return result
    }
}
