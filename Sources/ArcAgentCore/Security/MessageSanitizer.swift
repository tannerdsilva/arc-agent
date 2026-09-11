import Foundation
import CryptoKit

// MARK: - Message sanitization (Hermes `message_sanitization.py`)

/// Laundering rules beyond the core `sanitizeMessages` pass: surrogate and
/// control cleanup, JSON argument repair, interrupted tool sequences,
/// deterministic call ids, reasoning echo stripping, image stripping.
public enum MessageSanitizer {

    /// Replace unpaired surrogates and control characters with U+FFFD
    /// (Hermes `sanitize_unicode`).
    public static func sanitizeUnicode(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            if (0xD800...0xDFFF).contains(scalar.value) {
                return "\u{FFFD}"
            }
            if scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D {
                return "\u{FFFD}"
            }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Repair corrupted tool-call argument JSON: unescaped newlines and
    /// quotes inside strings. Try the raw payload first; on failure, apply
    /// the standard recoveries in order and re-validate (Hermes
    /// `repair_tool_call_arguments`).
    public static func repairToolCallArguments(_ raw: String) -> (json: String, repaired: Bool) {
        if parse(raw) != nil { return (raw, false) }
        // Recovery 1: escape literal newlines/quotes inside string values.
        let escaped = escapeStringLiterals(raw)
        if parse(escaped) != nil { return (escaped, true) }
        // Recovery 2: wrap unquoted keys in quotes (common in hand-rolled args).
        let quoted = quoteBareKeys(escaped)
        if parse(quoted) != nil { return (quoted, true) }
        return (raw, false)
    }

    /// Deterministic tool call ids for calls that lack one (Hermes
    /// `make_deterministic_tool_call_ids`: stable hash-based ids so repeated
    /// turns don't drift).
    public static func deterministicToolCallID(index: Int, name: String) -> String {
        let digest = SHA256.hash(data: Data("\(index):\(name)".utf8))
        return "call_" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Close an interrupted tool sequence: when the transcript ends with
    /// assistant tool_calls that have NO results (user interrupted), inject
    /// a synthetic tool result per unpaired call (Hermes
    /// `close_interrupted_tool_sequence`).
    public static func closeInterruptedToolSequence(_ messages: [Message]) -> [Message] {
        var result = messages
        guard !result.isEmpty else { return result }
        let last = result[result.count - 1]
        guard last.role == .assistant, let calls = last.toolCalls, !calls.isEmpty else { return result }
        // Find ids that already have results.
        let resolved = Set(result.compactMap { msg -> String? in
            guard msg.role == .tool else { return nil }
            return msg.toolCallID
        })
        let unpaired = calls.filter { !resolved.contains($0.id) }
        guard !unpaired.isEmpty else { return result }
        for call in unpaired {
            result.append(Message(
                role: .tool,
                content: "Tool sequence interrupted by user before this call completed." ,
                toolCallID: call.id,
                createdAt: Date()
            ))
        }
        return result
    }

    /// Drop reasoning-echo families: assistant content that merely repeats the
    /// system prompt's opening (Hermes reason-echo prevention).
    public static func stripReasoningEcho(_ content: String, systemPrefix: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > systemPrefix.count / 2 else { return content }
        if trimmed.hasPrefix(systemPrefix.prefix(min(systemPrefix.count, 200)).description) {
            return ""
        }
        return content
    }

    /// Strip inline image references (data: URLs and markdown images) from
    /// content passed to text-only models (Hermes `strip_images`).
    public static func stripImages(_ content: String) -> String {
        var result = content
        let dataPattern = #"data:image/[a-z+]+;base64,[A-Za-z0-9+/=]+"#
        result = replaceAll(result, dataPattern, "[image omitted]")
        result = replaceAll(result, #"!\[[^\]]*\]\([^)]*\)"#, "[image omitted]")
        return result
    }

    /// Optionally restrict content to ASCII (Hermes `sanitize_non_ascii`).
    public static func stripNonASCII(_ content: String) -> String {
        String(content.unicodeScalars.filter { $0.value < 0x80 || $0.value == 0x0A || $0.value == 0x09 })
    }

    /// Full message-level sanitize (surrogate/control + interrupt-close).
    public static func sanitize(_ messages: [Message]) -> [Message] {
        let unicodeCleaned = messages.map { msg -> Message in
            guard let content = msg.content else { return msg }
            return Message(role: msg.role, content: sanitizeUnicode(content),
                           name: msg.name, toolCalls: msg.toolCalls,
                           toolCallID: msg.toolCallID, createdAt: msg.createdAt)
        }
        return closeInterruptedToolSequence(unicodeCleaned)
    }

    // MARK: - Helpers

    static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Escape literal newlines/tabs/quotes that appear INSIDE JSON string
    /// values (heuristic: a newline preceded by `"` or `,` or `{` shape).
    static func escapeStringLiterals(_ raw: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for ch in raw {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if ch == "\"" { inString.toggle(); out.append(ch); continue }
            if inString && (ch == "\n" || ch == "\t" || ch == "\r") {
                out.append(ch == "\n" ? "\\n" : (ch == "\t" ? "\\t" : "\\r"))
                continue
            }
            out.append(ch)
        }
        return out
    }

    /// Wrap bare object keys (identifiers not surrounded by quotes) in quotes.
    static func quoteBareKeys(_ raw: String) -> String {
        let pattern = #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)"#
        return replaceAll(raw, pattern) { match in
            "\(match.groups[0]) \"\(match.groups[1])\"\(match.groups[2])"
        }
    }

    // MARK: - Tiny regex helper (avoid Regex API uncertainties)

    static func replaceAll(_ text: String, _ pattern: String, _ replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
    }

    static func replaceAll(_ text: String, _ pattern: String, _ transform: (GroupMatch) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let mutable = NSMutableString(string: text)
        for m in matches.reversed() {
            let groups = (1..<m.numberOfRanges).map { i -> String in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
            mutable.replaceCharacters(in: m.range, with: transform(GroupMatch(groups: groups)))
        }
        return mutable as String
    }

    struct GroupMatch { let groups: [String] }
}

// MARK: - Think scrubber (Hermes `think_scrubber.py`)

/// Strip leaked reasoning text from assistant output before it reaches the
/// user: leading "thinking" preambles and fenced thinking blocks.
public enum ThinkScrubber {
    /// Preamble markers (Hermes strips reasoning preambles that models
    /// sometimes emit as literal text).
    static let preambleMarkers = ["thinking:", "thought:", "reasoning:", "analysis:"]

    /// Fenced blocks to remove.
    static let fencePatterns = [
        #"(?s)```(?:thinking|reasoning|thought)\s*\n.*?```"#,
        #"(?s)<thinking>.*?</thinking>"#,
        #"(?s)<reasoning>.*?</reasoning>"#,
    ]

    public static func scrub(_ content: String) -> String {
        var result = content
        for pattern in fencePatterns {
            result = replaceAll(result, pattern, "")
        }
        // Leading preamble lines: "thinking: ..." repeated blocks.
        var lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var firstNonEmpty = 0
        while firstNonEmpty < lines.count {
            let l = lines[firstNonEmpty].trimmingCharacters(in: .whitespaces)
            let lower = l.lowercased()
            if preambleMarkers.contains(where: { lower.hasPrefix($0) }) {
                lines.remove(at: firstNonEmpty)
            } else {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    static func replaceAll(_ text: String, _ pattern: String, _ replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
    }
}
