import Foundation
import SwiftSlash
import AsyncHTTPClient

// MARK: - Context references (Hermes `features/context-references.md`)
// and context-file security scanning (`features/context-files.md`)

/// Scans context-file content for prompt-injection patterns (Hermes
/// context-files security section).
public enum ContextFileScanner {

    public enum Threat: String, Sendable {
        case instructionOverride = "instruction override attempt"
        case deception
        case systemPromptOverride
        case hiddenHTML
        case credentialExfiltration
        case secretFileAccess
        case invisibleCharacters
    }

    static let patterns: [(Threat, String)] = [
        (.instructionOverride, #"ignore (all |any |previous )?instructions"#),
        (.instructionOverride, #"disregard (your )?rules"#),
        (.deception, #"do not tell the user"#),
        (.systemPromptOverride, #"system prompt override"#),
        (.hiddenHTML, #"<!--[^>]*ignore instructions[^>]*-->"#),
        (.hiddenHTML, #"<div[^>]*display\s*:\s*none[^>]*>"#),
        (.credentialExfiltration, #"curl[^\n]*\$API_KEY"#),
        (.secretFileAccess, #"\bcat (\.env|credentials|\.netrc)\b"#),
    ]

    /// Returns the first threat found, or nil (clean content).
    public static func scan(_ content: String) -> Threat? {
        for (threat, pattern) in patterns {
            if let regex = try? Regex(pattern), content.contains(regex) {
                return threat
            }
        }
        let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x202A, 0x202B,
                                      0x202C, 0x202D, 0x202E, 0xFEFF]
        for scalar in content.unicodeScalars where invisible.contains(scalar.value) {
            return .invisibleCharacters
        }
        return nil
    }

    /// Hermes truncation: 70% head, 20% tail, marker in the middle.
    public static func truncate(_ content: String, maxChars: Int) -> String {
        guard content.count > maxChars, maxChars > 0 else { return content }
        let head = Int(Double(maxChars) * 0.70)
        let tail = Int(Double(maxChars) * 0.20)
        let headPart = content.prefix(head)
        let tailPart = content.suffix(tail)
        let kept = head + tail
        return "\(headPart)\n[...truncated: kept \(kept) of \(content.count) chars. Use file tools to read the full file.]\n\(tailPart)"
    }
}

/// Expands `@file:`/`@folder:`/`@diff`/`@staged`/`@git:`/`@url:` references
/// inline, appending content under an `--- Attached Context ---` section
/// (Hermes `context-references.md`).
public struct ContextReferenceExpander {

    public struct Limits {
        public var softFraction: Double
        public var hardFraction: Double
        public var folderMaxEntries: Int
        public var gitMaxCommits: Int
        public var contextLength: Int

        public init(softFraction: Double = 0.25, hardFraction: Double = 0.50,
                    folderMaxEntries: Int = 200, gitMaxCommits: Int = 10,
                    contextLength: Int = 64_000) {
            self.softFraction = softFraction
            self.hardFraction = hardFraction
            self.folderMaxEntries = folderMaxEntries
            self.gitMaxCommits = gitMaxCommits
            self.contextLength = contextLength
        }
    }

    static let blockedPaths: [String] = [
        ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/authorized_keys", ".ssh/config",
        ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile",
        ".netrc", ".pgpass", ".npmrc", ".pypirc",
    ]
    static let blockedDirs: [String] = [".ssh", ".aws", ".gnupg", ".kube", ".hub"]

    public struct FileFetcher: Sendable {
        public let readFile: @Sendable (String) async throws -> String?
        public let fetchURL: @Sendable (String) async throws -> String?

        public init(
            readFile: @escaping @Sendable (String) async throws -> String?,
            fetchURL: @escaping @Sendable (String) async throws -> String?
        ) {
            self.readFile = readFile
            self.fetchURL = fetchURL
        }
    }

    /// Parse one reference token into a kind + argument (punctuation is
    /// stripped; `@file:x.py:10-25` keeps the range in the arg).
    public static func parse(_ token: String) -> (kind: String, arg: String)? {
        var t = token.trimmingCharacters(in: .whitespaces)
        while let last = t.last, [",", ".", ";", "!", "?"].contains(last) {
            t.removeLast()
        }
        if t == "@diff" { return ("diff", "") }
        if t == "@staged" { return ("staged", "") }
        if t.hasPrefix("@git") {
            let rest = t.dropFirst("@git".count)
            let count = Int(rest.drop { $0 == ":" }) ?? 5
            return ("git", String(count))
        }
        for kind in ["file", "folder", "url"] {
            let prefix = "@\(kind):"
            if t.hasPrefix(prefix) {
                return (kind, String(t.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    public static func isBlocked(resolved: String) -> Bool {
        for dir in blockedDirs where resolved.contains("/\(dir)/") {
            return true
        }
        for file in blockedPaths where resolved.hasSuffix("/\(file)") {
            return true
        }
        return false
    }

    public static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    /// Minimal HTML → text extraction (tags stripped, entities decoded).
    public static func htmlToText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<script[^>]*>.*?</script>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<style[^>]*>.*?</style>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"&nbsp;"#, with: " ")
        text = text.replacingOccurrences(of: #"&amp;"#, with: "&")
        text = text.replacingOccurrences(of: #"&lt;"#, with: "<")
        text = text.replacingOccurrences(of: #"&gt;"#, with: ">")
        text = text.replacingOccurrences(of: #"&#39;"#, with: "'")
        text = text.replacingOccurrences(of: #"&quot;"#, with: "\"")
        let collapsed = text.split(separator: "\n").map {
            $0.split(separator: " ").joined(separator: " ")
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Default fetcher: local files from disk, URLs via AsyncHTTPClient.
    public static func defaultFetcher(workspaceRoot: String) -> FileFetcher {
        FileFetcher(
            readFile: { path in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                if looksBinary(data) { return nil }
                return String(data: data, encoding: .utf8)
            },
            fetchURL: { urlString in
                guard let url = URL(string: urlString) else { return nil }
                let client = HTTPClient(eventLoopGroupProvider: .singleton)
                defer { try? client.syncShutdown() }
                do {
                    let response = try await client.get(url: url.absoluteString).get()
                    guard var body = response.body else { return nil }
                    guard let data = body.readData(length: body.readableBytes) else { return nil }
                    guard let html = String(data: data, encoding: .utf8) else { return nil }
                    return htmlToText(html)
                } catch {
                    return nil
                }
            }
        )
    }

    /// Expands all references in a message. Returns rewritten text + warnings.
    public static func expand(
        _ message: String,
        workspaceRoot: String,
        limits: Limits = Limits(),
        fetcher: FileFetcher
    ) async -> (text: String, warnings: [String]) {
        var warnings: [String] = []
        func note(_ w: String) { warnings.append(w) }

        // Tokenize: @-words bounded by whitespace or punctuation.
        var tokens: [(range: Range<String.Index>, kind: String, arg: String)] = []
        var index = message.startIndex
        while index < message.endIndex {
            guard message[index] == "@" else {
                index = message.index(after: index)
                continue
            }
            var end = index
            while end < message.endIndex, !message[end].isWhitespace {
                end = message.index(after: end)
            }
            let raw = String(message[index..<end])
            if let parsed = parse(raw) {
                tokens.append((index..<end, parsed.kind, parsed.arg))
            }
            index = end
        }
        guard !tokens.isEmpty else { return (message, warnings) }

        let softLimit = Int(Double(limits.contextLength) * limits.softFraction)
        let hardLimit = Int(Double(limits.contextLength) * limits.hardFraction)
        var used = 0
        var attachments: [String] = []

        for token in tokens {
            var expansion = ""
            switch token.kind {
            case "file":
                guard let resolved = resolvePath(token.arg, workspaceRoot: workspaceRoot) else {
                    let rawResolved = URL(fileURLWithPath: token.arg).standardizedFileURL.path
                    if isBlocked(resolved: rawResolved) {
                        note("path is a sensitive credential path: \(token.arg)")
                    } else {
                        note("path is outside the allowed workspace: \(token.arg)")
                    }
                    break
                }
                guard !isBlocked(resolved: resolved) else {
                    note("path is a sensitive credential path: \(token.arg)")
                    break
                }
                guard let content = try? await fetcher.readFile(resolved) else {
                    note("file not found: \(token.arg)")
                    break
                }
                var body = content
                let rangeParse = token.arg.parseLineRange()
                if let (s, e) = rangeParse {
                    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                    let start = max(1, s)
                    let end = min(lines.count, e < s ? s : e)
                    if start <= lines.count {
                        body = lines[(start - 1)...(end - 1)].joined(separator: "\n")
                    }
                }
                expansion = "### \(resolved)\n\n\(body)"
            case "folder":
                guard let resolved = resolvePath(token.arg, workspaceRoot: workspaceRoot) else {
                    note("folder not found: \(token.arg)")
                    break
                }
                let dir = URL(fileURLWithPath: resolved)
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    note("folder not found: \(token.arg)")
                    break
                }
                var lines = ["### \(resolved)", ""]
                for entry in entries.prefix(limits.folderMaxEntries) {
                    let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    let isDir = values?.isDirectory == true
                    let size = values?.fileSize ?? 0
                    lines.append("\(isDir ? "📁" : "📄") \(entry.lastPathComponent)  (\(size)B)")
                }
                if entries.count > limits.folderMaxEntries { lines.append("- ...") }
                expansion = lines.joined(separator: "\n")
            case "diff", "staged":
                let flag = token.kind == "staged" ? "--staged" : ""
                if let (exit, out) = try? await git(["diff", flag], root: workspaceRoot) {
                    if exit == 0 { expansion = "### git \(token.kind)\n\n\(out)" }
                    else { note("git command failed: \(out.prefix(120))") }
                }
            case "git":
                let count = max(1, min(Int(token.arg) ?? 5, limits.gitMaxCommits))
                if let (exit, out) = try? await git(["log", "-\(count)", "--patch"], root: workspaceRoot) {
                    if exit == 0 { expansion = "### git last \(count) commits\n\n\(out)" }
                    else { note("git command failed: \(out.prefix(120))") }
                }
            case "url":
                guard let content = try? await fetcher.fetchURL(token.arg) else {
                    note("no content extracted: \(token.arg)")
                    break
                }
                expansion = "### URL: \(token.arg)\n\n\(content)"
            default:
                continue
            }
            guard !expansion.isEmpty else { continue }

            let cost = expansion.count
            if used + cost > hardLimit {
                note("context reference exceeded the hard limit (50% of context) — message returned unchanged")
                return (message, warnings)
            }
            if used + cost > softLimit {
                note("large context reference (soft limit reached) — proceeding")
            }
            used += cost
            attachments.append(expansion)
        }

        guard !attachments.isEmpty else { return (message, warnings) }

        // Rewrite tokens to plain path text, then attach.
        var text = message
        for token in tokens.reversed() {
            let replacement = token.arg.isEmpty ? "@\(token.kind)" : "`\(token.arg)`"
            text.replaceSubrange(token.range, with: replacement)
        }
        text += "\n\n--- Attached Context ---\n\n" + attachments.joined(separator: "\n\n")
        return (text, warnings)
    }

    private static func resolvePath(_ raw: String, workspaceRoot: String) -> String? {
        var path = raw
        if path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst(1) }
        let base = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let resolved = URL(fileURLWithPath: path).standardizedFileURL
        guard resolved.path.hasPrefix(base.path) else { return nil }
        return resolved.path
    }

    private static func git(_ args: [String], root: String) async throws -> (Int32, String) {
        var shell = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", "git " + args.joined(separator: " ")])
        shell.inheritCurrentEnvironment()
        shell.workingDirectory = Path(root)
        let outcome = try await SubprocessRunner.runBytes(shell, timeout: 15)
        let out = String(data: outcome.stdout, encoding: .utf8) ?? ""
        let err = String(data: outcome.stderr, encoding: .utf8) ?? ""
        return (outcome.exitCodeValue, err.isEmpty ? out : out + "\n" + err)
    }
}

// MARK: - Small helpers

extension String {
    /// `path:10-25` or `path:42` → (10, 25) / (42, 42).
    func parseLineRange() -> (Int, Int)? {
        guard let colon = lastIndex(of: ":") else { return nil }
        let rangePart = self[index(after: colon)...]
        let parts = rangePart.split(separator: "-").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 { return (parts[0], parts[0]) }
        return (parts[0], parts[1])
    }
}
