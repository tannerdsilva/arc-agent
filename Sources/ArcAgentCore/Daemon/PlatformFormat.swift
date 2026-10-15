import Foundation

/// Splits long messages into platform-sized chunks while trying to keep
/// markdown structures (``` fences) intact.
///
/// reference `truncate_message` parity: prefer to break at line boundaries,
/// never mid-code-fence, and apply an `ellipsis` marker to non-final chunks.
public enum PlatformChunker {
    /// Split `text` into chunks of at most `maxLength` characters.
    ///
    /// The chunker never splits inside a ``` fence: if a fence is opened but
    /// not closed within `maxLength`, the whole fence moves to the next chunk.
    /// Non-final chunks get ` …` (or configurable suffix) appended as long as
    /// that does not push them over the limit.
    public static func chunk(_ text: String, maxLength: Int, suffix: String = " …") -> [String] {
        guard maxLength > 0 else { return [text] }
        if text.count <= maxLength { return [text] }

        var chunks: [String] = []
        var remaining = Substring(text)

        while !remaining.isEmpty {
            if remaining.count <= maxLength {
                chunks.append(String(remaining))
                break
            }
            // Candidate cut: last newline or space at/before maxLength.
            var cut = remaining.index(remaining.startIndex, offsetBy: maxLength)
            // Walk back to a line boundary when one exists within the last 40%.
            let minBoundary = remaining.index(remaining.startIndex, offsetBy: maxLength * 6 / 10)
            var boundary: String.Index? = nil
            var probe = cut
            while probe > minBoundary {
                probe = remaining.index(before: probe)
                let ch = remaining[probe]
                if ch == "\n" || ch == " " {
                    boundary = probe
                    break
                }
            }
            if let b = boundary {
                cut = remaining.index(after: b)
            }

            // Never cut inside a ``` fence: if the prefix opens a fence that
            // stays open, extend until the fence closes (or the text ends).
            let prefix = String(remaining[..<cut])
            let opens = countFence(prefix)
            if opens {
                if let closeRange = remaining[cut...].range(of: "```", options: .literal) {
                    cut = closeRange.upperBound
                } else {
                    cut = remaining.endIndex // fence never closes; take the rest
                }
            }

            guard cut > remaining.startIndex else {
                // Degenerate: maxLength too small for even one char + suffix.
                let head = String(remaining.prefix(maxLength))
                chunks.append(head)
                remaining = remaining.dropFirst(maxLength)
                continue
            }

            var chunk = String(remaining[..<cut])
            remaining = remaining[cut...]
            if !remaining.isEmpty, chunk.count + suffix.count <= maxLength {
                chunk += suffix
            }
            chunks.append(chunk)
        }
        return chunks
    }

    /// Count fence markers in `s`; returns true if the prefix ends inside an
    /// unclosed fence (odd number of ``` delimiters).
    private static func countFence(_ s: String) -> Bool {
        var count = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "`" {
                var j = i
                var run = 0
                while j < s.endIndex, s[j] == "`" {
                    run += 1
                    j = s.index(after: j)
                }
                if run >= 3 { count += 1 }
                i = j
            } else {
                i = s.index(after: i)
            }
        }
        return count % 2 == 1
    }
}

/// Telegram MarkdownV2 renderer (reference `format_message` parity).
///
/// 17 special characters must be backslash-escaped *outside* of code spans
/// and ``` fences; inside them they are literal.
public enum TelegramFormat {
    private static let special: Set<Character> = [
        "_", "*", "[", "]", "(", ")", "~", "`", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!",
    ]

    /// Max characters for a single MarkdownV2 message (Bot API limit).
    public static let maxMessageLength = 4096

    public static func format(_ text: String) -> String {
        var out = ""
        var inCodeSpan = false
        var inFence = false
        var i = text.startIndex

        func isTripleBacktick(at idx: String.Index) -> Bool {
            guard let a = text.index(idx, offsetBy: 1, limitedBy: text.endIndex), a < text.endIndex,
                  let b = text.index(a, offsetBy: 1, limitedBy: text.endIndex), b < text.endIndex
            else { return false }
            return text[a] == "`" && text[b] == "`"
        }

        while i < text.endIndex {
            let ch = text[i]
            if inFence {
                out.append(ch)
                if ch == "`", isTripleBacktick(at: i) {
                    out.append("``")
                    inFence = false
                    i = text.index(i, offsetBy: 3)
                    continue
                }
            } else if inCodeSpan {
                out.append(ch)
                if ch == "`" { inCodeSpan = false }
            } else if ch == "`" {
                out.append(ch)
                if isTripleBacktick(at: i) {
                    out.append("``")
                    inFence = true
                    i = text.index(i, offsetBy: 3)
                    continue
                }
                inCodeSpan = true
            } else if special.contains(ch) {
                out.append("\\")
                out.append(ch)
            } else {
                out.append(ch)
            }
            i = text.index(after: i)
        }
        return out
    }
}

/// Slack mrkdwn renderer (reference slack-bolt rendering parity).
public enum SlackFormat {
    public static func format(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                out.append(trimmed)
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(line)
                continue
            }
            var converted = line
            // Headings: "### text" → "*text*" (mrkdwn has no heading syntax).
            if let match = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                converted = "*" + String(trimmed[match.upperBound...]) + "*"
            }
            // Links: [label](url) → <url|label>
            converted = convertLinks(converted)
            // Bullets: "- x" / "* x" → "• x"
            if converted.hasPrefix("- ") {
                converted = "• " + String(converted.dropFirst(2))
            } else if converted.hasPrefix("* ") {
                converted = "• " + String(converted.dropFirst(2))
            }
            out.append(converted)
        }
        return out.joined(separator: "\n")
    }

    private static func convertLinks(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\((https?://[^)]+)\)"#)
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(match.range, in: text) else { continue }
            result += text[last..<r.lowerBound]
            let label = (text as NSString).substring(with: match.range(at: 1))
            let url = (text as NSString).substring(with: match.range(at: 2))
            result += "<\(url)|\(label)>"
            last = r.upperBound
        }
        result += text[last...]
        return result
    }
}

/// Email body renderer: markdown is left intact (plain text). `stripHTML`
/// converts HTML-only emails on the inbound path.
public enum EmailFormat {
    public static func format(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    public static func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "</div>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</tr>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&copy;", "©"), ("&mdash;", "—"),
            ("&hellip;", "…"),
        ]
        for (from, to) in entities {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
