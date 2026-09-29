import Foundation

/// A parsed inbound email message (RFC 822 subset reference email parity needs).
public struct ParsedEmail: Sendable {
    public let from: String
    public let to: String
    public let subject: String
    public let body: String
    public let messageID: String?
    public let inReplyTo: String?
    public let references: String?

    public init(
        from: String, to: String, subject: String, body: String,
        messageID: String?, inReplyTo: String?, references: String?
    ) {
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
    }
}

/// Parses raw RFC 822 messages into ``ParsedEmail``.
///
/// Supports: header lines (with unfolding), `text/plain` + `text/html`
/// bodies, quoted-printable and base64 content transfer encodings, and the
/// headers needed for reply threading (Message-ID, In-Reply-To, References).
public enum EmailMessageParser {

    public static func parse(_ raw: Data) -> ParsedEmail? {
        guard let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) else {
            return nil
        }
        let separator = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
        let head = separator.map { String(text[..<$0.lowerBound]) } ?? text
        let bodyPart = separator.map { String(text[$0.upperBound...]) } ?? ""

        var headers: [String: String] = [:]
        var currentKey: String? = nil
        for rawLine in head.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            // Unfold continuation lines.
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let key = currentKey {
                    headers[key] = (headers[key] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip RFC quoted-printable soft breaks in header values.
            value = value.replacingOccurrences(of: "=\r\n", with: "")
            headers[key] = value
            currentKey = key
        }

        let boundary = extractBoundary(from: headers["content-type"])
        let transferEncoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let (body, _) = decodeBody(bodyPart, boundary: boundary, transferEncoding: transferEncoding)

        let from = extractAddress(headers["from"] ?? "unknown")
        let to = extractAddress(headers["to"] ?? "")
        let subject = decodeMimeWords(headers["subject"] ?? "")
        let messageID = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        let inReplyTo = headers["in-reply-to"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        let references = headers["references"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return ParsedEmail(
            from: from, to: to, subject: subject, body: body,
            messageID: messageID, inReplyTo: inReplyTo, references: references
        )
    }

    // MARK: - Body

    private static func decodeBody(_ raw: String, boundary: String?, transferEncoding: String = "") -> (String, Bool) {
        guard let boundary else {
            let decoded = decodeTransfer(raw, encoding: transferEncoding)
            let isHTML = raw.localizedCaseInsensitiveContains("text/html") || transferEncoding.isEmpty == false && raw.contains("<html") || raw.contains("<body")
            return (isHTML ? EmailFormat.stripHTML(decoded) : decoded, isHTML)
        }

        // Multipart: walk parts, prefer text/plain, fall back to text/html.
        var selected: String? = nil
        var selectedHTML = false
        for part in raw.components(separatedBy: "--\(boundary)") {
            guard let sep = part.range(of: "\n\n") else { continue }
            let head = String(part[..<sep.lowerBound])
            let content = String(part[sep.upperBound...])
            let ct = head.lowercased()
            guard ct.contains("text/plain") || ct.contains("text/html") else {
                if selected == nil, ct.contains("multipart/") {
                    // Nested multipart (e.g. multipart/related): recurse.
                    let nested = decodeBody(content, boundary: extractBoundary(from: head), transferEncoding: "")
                    if !nested.0.isEmpty && !nested.1 {
                        selected = nested.0
                        selectedHTML = false
                        break
                    }
                }
                continue
            }
            let encoding = ct.contains("base64") ? "base64"
                : ct.contains("quoted-printable") ? "quoted-printable" : "7bit"
            let decoded = decodeTransfer(content, encoding: encoding)
            let isHTML = ct.contains("text/html")
            if !isHTML {
                selected = decoded
                selectedHTML = false
                break // plain text preferred
            }
            selected = decoded
            selectedHTML = true
        }
        if let selected {
            return (selectedHTML ? EmailFormat.stripHTML(selected) : selected, selectedHTML)
        }
        return ("", false)
    }

    private static func decodeTransfer(_ text: String, encoding: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        switch encoding {
        case "base64":
            let compact = normalized.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: compact) else { return text }
            return String(data: data, encoding: .utf8) ?? text
        case "quoted-printable":
            return decodeQuotedPrintable(normalized)
        default:
            return normalized
        }
    }

    /// Decode quoted-printable text. `=XX` escapes are re-encoded to bytes and
    /// then interpreted as UTF-8 (fallback Latin-1) — so `=C3=A9` becomes `é`.
    static func decodeQuotedPrintable(_ text: String) -> String {
        var lines: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = String(line)
            if l.hasSuffix("\r") { l.removeLast() }
            if l.hasSuffix("=") {
                l.removeLast()
                current += l
                continue // soft break: the = at EOL joins to the next line
            }
            current += l
            lines.append(current)
            current = ""
        }
        if !current.isEmpty { lines.append(current) }
        return decodeEscapedBytes(lines.joined(separator: "\n"))
    }

    /// Convert `=XX` / `%XX` escape sequences into bytes, then decode the
    /// result as UTF-8, falling back to Latin-1.
    static func decodeEscapedBytes(_ s: String) -> String {
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "=" || s[i] == "%" {
                if let a = s.index(i, offsetBy: 1, limitedBy: s.endIndex),
                   let b = s.index(a, offsetBy: 1, limitedBy: s.endIndex),
                   a < s.endIndex, b < s.endIndex,
                   let byte = UInt8(String(s[a...b]), radix: 16) {
                    data.append(byte)
                    i = s.index(after: b)
                    continue
                }
            }
            data.append(contentsOf: String(s[i]).utf8)
            i = s.index(after: i)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? s
    }

    // MARK: - Helpers

    static func extractBoundary(from contentType: String?) -> String? {
        guard let ct = contentType, let range = ct.range(of: "boundary=") else { return nil }
        var value = String(ct[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") || value.hasPrefix("'") {
            value = String(value.dropFirst())
        }
        if let end = value.firstIndex(of: "\"") ?? value.firstIndex(of: "'") {
            value = String(value[..<end])
        } else if let semi = value.firstIndex(of: ";") {
            value = String(value[..<semi]).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? nil : value
    }

    /// "Name <addr>" → "addr" (lowercased, bare).
    static func extractAddress(_ value: String) -> String {
        if let open = value.firstIndex(of: "<"), let close = value.firstIndex(of: ">"), open < close {
            return String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return value.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Decode RFC 2047 encoded words `=?utf-8?B?...?=` / `=?utf-8?Q?...?=`.
    static func decodeMimeWords(_ value: String) -> String {
        var result = value
        let pattern = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)
        var last = result.startIndex
        var out = ""
        for match in pattern.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result)) {
            guard let r = Range(match.range, in: result) else { continue }
            out += result[last..<r.lowerBound]
            let charset = (result as NSString).substring(with: match.range(at: 1))
            _ = charset
            let mode = (result as NSString).substring(with: match.range(at: 2))
            let payload = (result as NSString).substring(with: match.range(at: 3))
            var decoded: String? = nil
            if mode.lowercased() == "b", let data = Data(base64Encoded: payload) {
                decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            } else if mode.lowercased() == "q" {
                decoded = payload.replacingOccurrences(of: "_", with: " ").decodingPercentHex()
            }
            out += decoded ?? payload
            last = r.upperBound
        }
        out += result[last...]
        return out
    }
}

private extension String {
    /// Decode `%XX` and `=XX` sequences (quoted-printable / Q-encoding).
    func decodingPercentHex() -> String {
        var out = ""
        var i = startIndex
        while i < endIndex {
            if (self[i] == "%" || self[i] == "="), let next = index(i, offsetBy: 1, limitedBy: endIndex),
               let next2 = index(next, offsetBy: 1, limitedBy: endIndex),
               let byte = UInt8(String(self[next...next2]), radix: 16) {
                out.append(Character(UnicodeScalar(byte)))
                i = index(after: next2)
                continue
            }
            out.append(self[i])
            i = index(after: i)
        }
        return out
    }
}
