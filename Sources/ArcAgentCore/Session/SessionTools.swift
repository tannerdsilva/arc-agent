import Foundation

// MARK: - Session standards (reference `user-guide/sessions.md`)

/// Title rules (reference `sessions.md` § Session Naming).
public enum SessionTitle {

    /// Max title length (reference: 100).
    public static let maxLength = 100

    /// Strip control characters, zero-width chars, and RTL overrides.
    public static func sanitized(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            guard v >= 0x20, !(0x7F...0x9F).contains(v) else { return false }
            if v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFEFF || v == 0x061C { return false }
            if (0x200E...0x200F).contains(v) { return false }   // LRM/RLM
            if (0x202A...0x202E).contains(v) { return false }   // bidi embeddings
            if (0x2066...0x2069).contains(v) { return false }   // bidi isolates
            return true
        }
        let string = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(string.prefix(maxLength))
    }

    /// Numbered lineage name (reference: "my project" → "my project #2").
    /// `existing` is the set of current titles to find the next free number.
    public static func lineageNext(_ base: String, existing: Set<String>) -> String {
        let clean = sanitized(base)
        if !existing.contains(clean) { return clean }
        var n = 2
        while existing.contains("\(clean) #\(n)") { n += 1 }
        return "\(clean) #\(n)"
    }
}

/// Export formats (reference `sessions export`).
public enum SessionExportFormat: String, CaseIterable {
    case jsonl
    case trace
}

/// JSONL + trace export with optional secret redaction (reference
/// `sessions export`; `--redact` scrubs API keys/tokens/credentials).
public enum SessionExporter {

    static let redactionPatterns: [String] = [
        #"sk-[A-Za-z0-9_-]{16,}"#,
        #"(?i)bearer\s+[A-Za-z0-9._-]{16,}"#,
        #"api[_-]?key=([A-Za-z0-9._-]{8,})"#,
        #"(?i)x-api-key[\":\s]+[A-Za-z0-9._-]{16,}"#,
        #"ghp_[A-Za-z0-9]{20,}"#,
        #"AIza[0-9A-Za-z_-]{30,}"#,
    ]

    /// Scrub secrets from exported content (reference `--redact`).
    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in redactionPatterns {
            result = result.replacingOccurrences(
                of: pattern, with: "[REDACTED]", options: .regularExpression
            )
        }
        return result
    }

    /// One JSONL record per session (reference `--format jsonl`, default).
    public static func jsonlRecord(session: Session, redacted: Bool) throws -> Data {
        var session = session
        if redacted {
            session = Session(
                id: session.id, createdAt: session.createdAt, updatedAt: session.updatedAt,
                model: session.model, provider: session.provider,
                title: session.title, messageCount: session.messageCount,
                messages: session.messages.map { m in
                    Message(role: m.role, content: m.content.map(redact), name: m.name,
                            toolCalls: m.toolCalls, toolCallID: m.toolCallID,
                            reasoning: m.reasoning, terminalReason: m.terminalReason)
                },
                source: session.source, userID: session.userID,
                parentSessionID: session.parentSessionID, workspaceKey: session.workspaceKey,
                endedAt: session.endedAt, inputTokens: session.inputTokens,
                outputTokens: session.outputTokens, systemPrompt: session.systemPrompt.map(redact)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(session)
        var line = data
        line.append(0x0A)
        return line
    }

    /// Claude Code JSONL trace record (reference `--format trace`; one
    /// `client...` message per conversation item).
    public static func traceRecord(session: Session) throws -> Data {
        var lines = Data()
        for message in session.messages {
            let record: [String: Any] = [
                "type": "message",
                "timestamp": ISO8601DateFormatter().string(from: session.updatedAt),
                "client": "arc-agent",
                "message": Self.claudeMessage(message),
                "session_id": session.id,
            ]
            let data = try JSONSerialization.data(withJSONObject: record,
                options: [.sortedKeys])
            lines.append(data)
            lines.append(0x0A)
        }
        return lines
    }

    static func claudeMessage(_ m: Message) -> [String: Any] {
        let content: Any
        switch m.role {
        case .user:
            content = [["type": "text", "text": m.content ?? ""]]
        case .assistant:
            var blocks: [[String: Any]] = []
            if let content = m.content, !content.isEmpty {
                blocks.append(["type": "text", "text": content])
            }
            for call in m.toolCalls ?? [] {
                blocks.append(["type": "tool_use", "id": call.id,
                               "name": call.function.name,
                               "input": Self.parseJSON(call.function.arguments)])
            }
            content = blocks.isEmpty ? "" : blocks
        case .tool:
            content = [["type": "tool_result",
                        "tool_use_id": m.toolCallID ?? "",
                        "content": m.content ?? ""]]
        default:
            content = m.content ?? ""
        }
        return ["role": m.role.rawValue, "content": content]
    }

    private static func parseJSON(_ s: String) -> Any {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return s }
        return obj
    }
}

/// Prune filter (reference `sessions prune`): ended sessions inactive for
/// the given duration; any other selector narrows; `--dry-run` previews.
public struct SessionPruneFilter: Sendable {
    public var olderThanDays: Int?       // default 90 when no selector at all
    public var source: String?

    public init(olderThanDays: Int? = nil, source: String? = nil) {
        self.olderThanDays = olderThanDays
        self.source = source
    }

    /// `true` when the session should be pruned at `now`.
    public func matches(_ session: Session, now: Date) -> Bool {
        if let source, session.source != source { return false }
        let inactiveDays = olderThanDays ?? 90
        guard let endedAt = session.endedAt else {
            // Ended sessions only (reference: prune ended sessions).
            return false
        }
        let days = now.timeIntervalSince(endedAt) / 86_400
        return days >= Double(inactiveDays)
    }
}
