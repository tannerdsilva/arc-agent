import Foundation

/// A memory entry store with arc-parity semantics.
///
/// Mirrors `tools/memory_tool.py` (the `MemoryStore` inside it):
/// - Entries are §-delimited (`\n§\n`) — multiline entries allowed, one
///   logical entry per section.
/// - Character limits per target (not tokens, because char counts are
///   model-independent): 2,200 for `memory`, 1,375 for `user`.
/// - `add` rejects exact duplicates; missing and over-budget writes are
///   refused with the current entries and usage shown so the model can
///   consolidate in the same call.
/// - Batches are all-or-nothing: every op is validated against a working
///   copy and only the FINAL char budget matters; on any failure nothing
///   is written and the first problem is reported with live state.
/// - Content is scanned against strict threat patterns (injection /
///   exfiltration / persistence) before acceptance.
public struct MemoryStore: Sendable {

    public static let entryDelimiter = "\n§\n"
    public static let memoryCharLimit = 2_200
    public static let userCharLimit = 1_375

    private let provider: any MemoryProvider

    public init(provider: any MemoryProvider) {
        self.provider = provider
    }

    // MARK: - Targets

    public static func charLimit(for target: String) -> Int {
        target == "user" ? userCharLimit : memoryCharLimit
    }

    public func charLimit(target: String) -> Int {
        Self.charLimit(for: target)
    }

    // MARK: - Operations (reference semantics)

    /// Append a new entry. Returns an error dict if it would exceed the char limit.
    public func add(_ target: String, _ content: String) async throws -> [String: Any] {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            return error("Content cannot be empty.")
        }
        if let scanError = MemoryContentScanner.firstThreatMessage(content) {
            return error(scanError)
        }

        let entries = try await self.entries(target)
        if entries.contains(content) {
            return await success(target, "Entry already exists (no duplicate added).")
        }

        let limit = charLimit(target: target)
        let newEntries = entries + [content]
        let newTotal = joinedCount(newEntries)
        if newTotal > limit {
            let current = try await charCount(target: target)
            return consolidationFailure(
                target,
                error: "Memory at \(current.formatted())/\(limit.formatted()) chars. "
                    + "Adding this entry (\(content.count.formatted()) chars) would exceed the limit. "
                    + "Consolidate now: use 'replace' to merge overlapping entries into "
                    + "shorter ones or 'remove' stale or less important entries (see "
                    + "current_entries below), then retry this add — all in this turn.",
                currentEntries: entries,
                usage: usageLabel(current: current, limit: limit)
            )
        }

        try await setEntries(target, newEntries)
        return await success(target, "Entry added.")
    }

    /// Find the entry containing `oldText`, replace it with `newContent`.
    public func replace(_ target: String, _ oldText: String, _ newContent: String) async throws -> [String: Any] {
        let oldText = oldText.trimmingCharacters(in: .whitespacesAndNewlines)
        var newContent = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldText.isEmpty {
            return error("old_text cannot be empty.")
        }
        if newContent.isEmpty {
            return error("new_content cannot be empty. Use 'remove' to delete entries.")
        }
        if let scanError = MemoryContentScanner.firstThreatMessage(newContent) {
            return error(scanError)
        }

        let entries = try await self.entries(target)
        let matches = matches(of: oldText, in: entries)
        if matches.isEmpty {
            return consolidationFailure(
                target,
                error: "No entry matched '\(oldText)'. Check current_entries below and retry with the exact text of the entry you want to replace.",
                currentEntries: entries
            )
        }
        if uniqueTexts(of: matches, in: entries).count > 1 {
            return errorDict(
                "Multiple entries matched '\(oldText)'. Be more specific.",
                matches: previews(of: matches, in: entries)
            )
        }

        let idx = matches[0].index
        let limit = charLimit(target: target)
        var testEntries = entries
        testEntries[idx] = newContent
        let newTotal = joinedCount(testEntries)
        if newTotal > limit {
            let current = try await charCount(target: target)
            return consolidationFailure(
                target,
                error: "Replacement would put memory at \(newTotal.formatted())/\(limit.formatted()) chars. "
                    + "Shorten the new content, or 'remove' other stale or less important "
                    + "entries to make room (see current_entries below), then retry — all "
                    + "in this turn.",
                currentEntries: entries,
                usage: usageLabel(current: current, limit: limit)
            )
        }

        var committed = entries
        committed[idx] = newContent
        try await setEntries(target, committed)
        return await success(target, "Entry replaced.")
    }

    /// Remove the entry containing `oldText` (first match).
    public func remove(_ target: String, _ oldText: String) async throws -> [String: Any] {
        let oldText = oldText.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldText.isEmpty {
            return error("old_text cannot be empty.")
        }

        let entries = try await self.entries(target)
        let matches = matches(of: oldText, in: entries)
        if matches.isEmpty {
            return consolidationFailure(
                target,
                error: "No entry matched '\(oldText)'. Check current_entries below and retry with the exact text of the entry you want to remove.",
                currentEntries: entries
            )
        }
        if uniqueTexts(of: matches, in: entries).count > 1 {
            return errorDict(
                "Multiple entries matched '\(oldText)'. Be more specific.",
                matches: previews(of: matches, in: entries)
            )
        }

        var working = entries
        working.remove(at: matches[0].index)
        try await setEntries(target, working)
        return await success(target, "Entry removed.")
    }

    /// Apply a sequence of add/replace/remove ops atomically against the FINAL
    /// budget. All-or-nothing.
    public func applyBatch(_ target: String, _ operations: [[String: Any]]) async throws -> [String: Any] {
        if operations.isEmpty {
            return error("operations list is empty.")
        }

        // Scan every add/replace content BEFORE touching storage — a single
        // poisoned op rejects the whole batch.
        for (i, op) in operations.enumerated() {
            let act = op["action"] as? String
            let newContent = op["content"] as? String
            if act == "add" || act == "replace" {
                if let newContent, !newContent.isEmpty,
                   let scanError = MemoryContentScanner.firstThreatMessage(newContent) {
                    return error("Operation \(i + 1): \(scanError)")
                }
            }
        }

        var working = try await entries(target)
        let limit = charLimit(target: target)

        for (i, op) in operations.enumerated() {
            let act = op["action"] as? String ?? ""
            let content = (op["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let oldText = (op["old_text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pos = "Operation \(i + 1) (\(act.isEmpty ? "unknown" : act))"

            switch act {
            case "add":
                if content.isEmpty {
                    return await batchError(target, "\(pos): content is required.")
                }
                if working.contains(content) { continue } // idempotent — skip duplicate
                working.append(content)

            case "replace":
                if oldText.isEmpty {
                    return await batchError(target, "\(pos): old_text is required.")
                }
                if content.isEmpty {
                    return await batchError(target, "\(pos): content is required (use action='remove' to delete).")
                }
                let matches = matches(of: oldText, in: working)
                if matches.isEmpty {
                    return await batchError(target, "\(pos): no entry matched '\(oldText)'.")
                }
                if uniqueTexts(of: matches, in: working).count > 1 {
                    return await batchError(target, "\(pos): '\(oldText)' matched multiple distinct entries — be more specific.")
                }
                working[matches[0].index] = content

            case "remove":
                if oldText.isEmpty {
                    return await batchError(target, "\(pos): old_text is required.")
                }
                let matches = matches(of: oldText, in: working)
                if matches.isEmpty {
                    return await batchError(target, "\(pos): no entry matched '\(oldText)'.")
                }
                if uniqueTexts(of: matches, in: working).count > 1 {
                    return await batchError(target, "\(pos): '\(oldText)' matched multiple distinct entries — be more specific.")
                }
                working.remove(at: matches[0].index)

            default:
                return await batchError(target, "\(pos): unknown action. Use add, replace, or remove.")
            }
        }

        // Budget check against the FINAL state only.
        let newTotal = joinedCount(working)
        if newTotal > limit {
            let current = try await charCount(target: target)
            return consolidationFailure(
                target,
                error: "After applying all \(operations.count) operations, memory would be at "
                    + "\(newTotal.formatted())/\(limit.formatted()) chars — over the limit. Remove or shorten more "
                    + "entries in the same batch (see current_entries below), then retry.",
                currentEntries: try await entries(target),
                usage: usageLabel(current: current, limit: limit)
            )
        }

        try await setEntries(target, working)
        return await success(target, "Applied \(operations.count) operation(s).")
    }

    // MARK: - Reading (for tool feedback / tests)

    public func entries(_ target: String) async throws -> [String] {
        let raw = try await rawText(target)
        return raw.split(separator: "\n§\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    public func charCount(target: String) async throws -> Int {
        joinedCount(try await entries(target))
    }

    // MARK: - Private

    private func rawText(_ target: String) async throws -> String {
        if target == "user" {
            return try await provider.readUser()
        }
        return try await provider.readMemory()
    }

    private func setEntries(_ target: String, _ entries: [String]) async throws {
        let joined = entries.joined(separator: Self.entryDelimiter)
        if target == "user" {
            try await provider.writeUser(joined)
        } else {
            try await provider.writeMemory(joined)
        }
    }

    private func joinedCount(_ entries: [String]) -> Int {
        entries.joined(separator: Self.entryDelimiter).count
    }

    private struct Match {
        let index: Int
        let text: String
    }

    private func matches(of needle: String, in entries: [String]) -> [Match] {
        entries.enumerated().filter { $0.element.contains(needle) }.map { Match(index: $0.offset, text: $0.element) }
    }

    private func uniqueTexts(of matches: [Match], in entries: [String]) -> Set<String> {
        Set(matches.map(\.text))
    }

    private func previews(of matches: [Match], in entries: [String], width: Int = 80) -> [String] {
        matches.map { m in
            let e = m.text
            return e.count > width ? String(e.prefix(width)) + "..." : e
        }
    }

    private func usageLabel(current: Int, limit: Int) -> String {
        let pct = limit > 0 ? min(100, Int((Double(current) / Double(limit)) * 100)) : 0
        return "\(pct)% — \(current.formatted())/\(limit.formatted()) chars"
    }

    // MARK: - Response builders (reference key shapes)

    private func success(_ target: String, _ message: String) async -> [String: Any] {
        [
            "success": true,
            "done": true,
            "target": target,
            "usage": usageLabel(current: (try? await charCount(target: target)) ?? 0, limit: charLimit(target: target)),
            "entry_count": (try? await entries(target).count) ?? 0,
            "message": message,
            "note": "Write saved. This update is complete — do not repeat it.",
        ]
    }

    private func error(_ message: String) -> [String: Any] {
        ["success": false, "error": message]
    }

    private func errorDict(_ message: String, matches: [String]? = nil) -> [String: Any] {
        var d: [String: Any] = ["success": false, "error": message]
        if let matches { d["matches"] = matches }
        return d
    }

    private func consolidationFailure(
        _ target: String,
        error message: String,
        currentEntries: [String],
        usage: String? = nil
    ) -> [String: Any] {
        var d: [String: Any] = [
            "success": false,
            "error": message,
            "current_entries": currentEntries,
        ]
        if let usage { d["usage"] = usage }
        return d
    }

    private func batchError(_ target: String, _ message: String) async -> [String: Any] {
        var d: [String: Any] = [
            "success": false,
            "error": message + " No operations were applied (batch is all-or-nothing).",
        ]
        d["current_entries"] = (try? await entries(target)) ?? []
        if let current = try? await charCount(target: target) {
            d["usage"] = usageLabel(current: current, limit: charLimit(target: target))
        }
        return d
    }
}

/// Lightweight injection/exfiltration scanner for memory writes.
///
/// Port of the strict-scope patterns from reference `tools/threat_patterns.py`
/// (single source of truth for promptware scanning): persistence (SSH
/// backdoors, authorized_keys), exfiltration URLs/context dumps, secret
/// injection, and agent-config modification instructions.
public enum MemoryContentScanner {

    private struct Pattern {
        let regex: String
        let id: String
        let message: String
    }

    private static let patterns: [Pattern] = [
        Pattern(
            regex: #"(send|post|upload|transmit)\s+[^\n]{0,2048}\s+(to|at)\s+https?://"#,
            id: "send_to_url",
            message: "Content attempts to instruct exfiltration of data to a URL — blocked."
        ),
        Pattern(
            regex: #"(include|output|print|share)\s+(?:\w+\s+){0,8}(conversation|chat\s+history|previous\s+messages|full\s+context|entire\s+context)"#,
            id: "context_exfil",
            message: "Content attempts to dump conversation context — blocked."
        ),
        Pattern(
            regex: #"authorized_keys"#,
            id: "ssh_backdoor",
            message: "Content references SSH authorized_keys (persistence risk) — blocked."
        ),
        Pattern(
            regex: #"\$HOME/\.ssh|\~?/\.ssh"#,
            id: "ssh_access",
            message: "Content references SSH private key locations — blocked."
        ),
        Pattern(
            regex: #"\$HOME/\.arc/\.env|\~?/\.arc/\.env"#,
            id: "agent_env",
            message: "Content references the agent's .env secrets — blocked."
        ),
        Pattern(
            regex: #"(update|modify|edit|write|change|append|add\s+to)\s+[^\n]{0,2048}(?:AGENTS\.md|CLAUDE\.md|\.cursorrules|\.clinerules)"#,
            id: "agent_config_mod",
            message: "Content instructs modification of agent config files — blocked."
        ),
        Pattern(
            regex: #"(update|modify|edit|write|change|append|add\s+to)\s+[^\n]{0,2048}\.arc/(config\.yaml|SOUL\.md)"#,
            id: "arc_config_mod",
            message: "Content instructs modification of agent config — blocked."
        ),
        Pattern(
            regex: #"(?:api[_-]?key|token|secret|password)\s*[=:]\s*["'][A-Za-z0-9+/=_-]{20,}"#,
            id: "hardcoded_secret",
            message: "Content contains a hardcoded credential — blocked."
        ),
    ]

    /// Scan `content` (strict scope). Returns the first blocking message, if any.
    public static func firstThreatMessage(_ content: String) -> String? {
        let capped = String(content.prefix(65_536))
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern.regex, options: .caseInsensitive),
               regex.firstMatch(in: capped, range: NSRange(capped.startIndex..., in: capped)) != nil {
                return pattern.message
            }
        }
        return nil
    }
}
