import Foundation

// MARK: - HTML Escaping

/// Escape a string for safe inclusion in HTML content.
///
/// Replaces the five characters that have special meaning in HTML:
/// - `&` → `&amp;`
/// - `<` → `&lt;`
/// - `>` → `&gt;`
/// - `"` → `&quot;`
/// - `'` → `&#39;`
///
/// - Parameter string: The raw string to escape.
/// - Returns: An HTML-safe string.
public func htmlEscape(_ string: String) -> String {
    var result = string
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    result = result.replacingOccurrences(of: "'", with: "&#39;")
    return result
}

// MARK: - URL Sanitization

private let unsafeURLProtocols: Set<String> = ["javascript", "data", "vbscript"]
private let urlForbiddenControlScalars: Set<UnicodeScalar> = {
    var set = Set<UnicodeScalar>()
    for value in 0x00...0x1F {
        if let scalar = UnicodeScalar(value) { set.insert(scalar) }
    }
    if let del = UnicodeScalar(0x7F) { set.insert(del) }
    return set
}()
private let urlWhitespaceScalars: Set<UnicodeScalar> = ["\t", "\n", "\u{0B}", "\u{0C}", "\r", " "]

/// The browser strips ASCII whitespace and C0 control characters from a URL
/// before parsing the scheme, so " javascript:" and "java\tscript:" both
/// execute as javascript. Strip the same set here so the scheme check sees
/// what the browser would see.
private func normalizedURLString(_ url: String) -> String {
    let forbidden = urlForbiddenControlScalars.union(urlWhitespaceScalars)
    let filtered = url.unicodeScalars.filter { !forbidden.contains($0) }
    return String(String.UnicodeScalarView(filtered))
}

/// Return the URL if its scheme is safe (http/https/etc.), else nil.
public func sanitizeURL(_ url: String) -> String? {
    let normalized = normalizedURLString(url)
    guard let colonIndex = normalized.firstIndex(of: ":") else { return normalized }
    let scheme = String(normalized[normalized.startIndex..<colonIndex]).lowercased()
    guard !unsafeURLProtocols.contains(scheme) else { return nil }
    return normalized
}

// MARK: - Markdown Rendering

/// Hermes-parity markdown renderer (mirrors the Hermes WebUI's streaming `smd`
/// feature set): ATX headings, paragraphs, soft/hard line breaks, horizontal
/// rules, nested blockquotes, ordered/unordered lists with nesting, task-list
/// checkboxes, pipe tables, and inline **bold**, __bold__, *emphasis*,
/// _emphasis_, `code`, ~~strikethrough~~, [links](url), ![images](url),
/// autolinked http(s) URLs, $inline$ / $$block$$ / \(...\) / \[...\] math, and
/// raw `<br>` passthrough.
///
/// Every byte of input is html-escaped before any token is recognized, so raw
/// HTML never reaches the document and link/image targets pass through
/// `sanitizeURL`. Math emits `<equation-inline>` / `<equation-block>` elements
/// holding the TeX source (HTML-escaped for transport; the client reads
/// `textContent`, which the browser decodes) that the WebUI runtime hands to
/// KaTeX — the same pattern as Hermes' smd + `renderKatexBlocks`.
public func markdownToHTML(_ markdown: String) -> String {
    var parser = MarkdownBlockParser(lines: markdown.components(separatedBy: "\n"))
    return parser.parseBlocks().joined(separator: "\n")
}

// MARK: Block parsing

private struct MarkdownBlockParser {
    var lines: [String]
    var i = 0

    mutating func parseBlocks() -> [String] {
        var out: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            if let eq = parseDisplayMath(trimmed) {
                out.append(eq)
                continue
            }
            if let h = Self.heading(trimmed) {
                out.append(h)
                i += 1
                continue
            }
            if Self.isHR(trimmed) {
                out.append("<hr>")
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                out.append(parseBlockquote())
                continue
            }
            if Self.looksLikeTable(lines, at: i) {
                out.append(parseTable())
                continue
            }
            if Self.listItem(trimmed) != nil {
                out.append(parseList())
                continue
            }
            out.append(parseParagraph())
        }
        return out
    }

    /// A paragraph consumes lines until a blank line or the start of another
    /// block. Single newlines are soft breaks (joined with a space); a line
    /// ending in two+ spaces or a backslash is a hard break (`<br>`).
    mutating func parseParagraph() -> String {
        var pieces: [(hard: Bool, line: String)] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if Self.heading(t) != nil { break }
            if Self.isHR(t) { break }
            if t.hasPrefix(">") { break }
            if Self.listItem(t) != nil { break }
            if Self.looksLikeTable(lines, at: i) { break }
            if Self.isDisplayMathLine(t) { break }
            var line = lines[i]
            var hard = false
            if line.hasSuffix("\\") && line.count > 1 {
                line = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                hard = true
            } else if line.hasSuffix("  ") {
                line = line.trimmingCharacters(in: .whitespaces)
                hard = true
            } else {
                line = line.trimmingCharacters(in: .whitespaces)
            }
            pieces.append((hard, line))
            i += 1
        }
        var para = ""
        var first = true
        var prevHard = false
        for (hard, line) in pieces {
            if !first { para += prevHard ? "<br>" : " " }
            para += line
            prevHard = hard
            first = false
        }
        return "<p>" + renderInlineMarkdown(para) + "</p>"
    }

    mutating func parseBlockquote() -> String {
        var quote: [String] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(">") else { break }
            var content = String(t.dropFirst())
            if content.hasPrefix(" ") { content = String(content.dropFirst()) }
            quote.append(content)
            i += 1
        }
        var sub = MarkdownBlockParser(lines: quote)
        let inner = sub.parseBlocks().joined(separator: "\n")
        return "<blockquote>\n" + inner + "\n</blockquote>"
    }

    mutating func parseList() -> String {
        // A list may start indented (e.g. inside a blockquote after the "> "
        // strip); base the level on the first item so the block always makes
        // progress and never spins on a >0 indent with no parent item.
        guard let first = Self.listItem(lines[i]) else { return "" }
        return listBlock(indent: first.indent)
    }

    /// Indentation-based nesting: items at `indent` belong to this list; items
    /// indented further open a sublist attached to the preceding item; a line
    /// that does not match (or is indented less) ends the block.
    mutating func listBlock(indent: Int) -> String {
        var ordered: Bool?
        var items: [String] = []
        while i < lines.count {
            let raw = lines[i]
            guard let item = Self.listItem(raw) else { break }
            if item.indent < indent { break }
            if item.indent > indent {
                guard !items.isEmpty else { break }
                let sub = listBlock(indent: item.indent)
                let last = items[items.count - 1]
                // The sublist belongs inside the parent item, before its </li>.
                if last.hasSuffix("</li>") {
                    items[items.count - 1] = String(last.dropLast("</li>".count)) + "\n" + sub + "</li>"
                } else {
                    items[items.count - 1] = last + "\n" + sub
                }
                continue
            }
            if ordered == nil { ordered = item.ordered }
            guard item.ordered == ordered else { break }
            var content = item.content
            var checked: Bool?
            if content.hasPrefix("[ ] ") {
                content = String(content.dropFirst(4))
                checked = false
            } else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                content = String(content.dropFirst(4))
                checked = true
            }
            let box = checked == nil ? "" : "<input type=\"checkbox\" disabled" + (checked == true ? " checked" : "") + ">"
            items.append("<li>" + box + renderInlineMarkdown(content) + "</li>")
            i += 1
        }
        let tag = (ordered == true) ? "ol" : "ul"
        return "<" + tag + ">" + items.joined() + "</" + tag + ">"
    }

    mutating func parseTable() -> String {
        let header = Self.splitRow(lines[i])
        // separator line is not a cell row; the table is already validated.
        i += 1
        if i < lines.count { i += 1 }
        var body: [[String]] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.contains("|") else { break }
            body.append(Self.splitRow(t))
            i += 1
        }
        let headCells = header.map { "<th>" + renderInlineMarkdown($0) + "</th>" }.joined()
        var bodyHTML = ""
        for row in body {
            let cells = row.map { "<td>" + renderInlineMarkdown($0) + "</td>" }.joined()
            bodyHTML += "<tr>" + cells + "</tr>\n"
        }
        return "<table>\n<thead>\n<tr>" + headCells + "</tr>\n</thead>\n<tbody>\n"
            + bodyHTML + "</tbody>\n</table>"
    }

    /// `$$...$$` (single or multi-line) and `\[...\]` display math.
    mutating func parseDisplayMath(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("$$"), trimmed.count > 4, trimmed.hasSuffix("$$") {
            let src = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            i += 1
            return "<equation-block>" + src + "</equation-block>"
        }
        if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
            let src = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            i += 1
            return "<equation-block>" + src + "</equation-block>"
        }
        if trimmed == "$$" || (trimmed.hasPrefix("$$") && !trimmed.hasSuffix("$$")) {
            var src = trimmed == "$$" ? "" : String(trimmed.dropFirst(2))
            i += 1
            while i < lines.count {
                let l = lines[i]
                if l.hasSuffix("$$") && l != "$$" {
                    src += String(l.dropLast(2))
                    i += 1
                    break
                }
                if l == "$$" {
                    i += 1
                    break
                }
                src += l + "\n"
                i += 1
            }
            return "<equation-block>" + src + "</equation-block>"
        }
        return nil
    }

    static func isDisplayMathLine(_ trimmed: String) -> Bool {
        trimmed == "$$" || (trimmed.hasPrefix("$$") && !trimmed.hasSuffix("$$"))
            || (trimmed.hasPrefix("\\[") && !trimmed.hasSuffix("\\]"))
    }

    static func heading(_ trimmed: String) -> String? {
        var idx = trimmed.startIndex
        var level = 0
        while idx < trimmed.endIndex, trimmed[idx] == "#" {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0 else { return nil }
        let text = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
        let h = min(level, 6)
        return "<h\(h)>" + renderInlineMarkdown(text) + "</h\(h)>"
    }

    static func isHR(_ trimmed: String) -> Bool {
        let t = trimmed
        guard t.count >= 3 else { return false }
        var char: Character = " "
        var seen = 0
        for c in t {
            if c == " " { continue }
            if c == "-" || c == "*" || c == "_" {
                if char == " " { char = c }
                if c != char { return false }
                seen += 1
            } else {
                return false
            }
        }
        return char != " " && seen >= 3
    }

    static func listItem(_ trimmed: String) -> (indent: Int, ordered: Bool, content: String)? {
        var indent = 0
        var t = String(trimmed)
        while t.hasPrefix(" ") || t.hasPrefix("\t") {
            t.removeFirst()
            indent += 1
        }
        guard let first = t.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = t.dropFirst()
            guard rest.hasPrefix(" ") else { return nil }
            return (indent, false, String(rest.dropFirst()))
        }
        var digits = 0
        var idx = t.startIndex
        while idx < t.endIndex, t[idx].isNumber {
            digits += 1
            idx = t.index(after: idx)
        }
        if digits > 0, idx < t.endIndex, t[idx] == "." || t[idx] == ")" {
            let rest = String(t[t.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            return (indent, true, rest)
        }
        return nil
    }

    static func looksLikeTable(_ lines: [String], at idx: Int) -> Bool {
        guard idx + 1 < lines.count else { return false }
        let cur = lines[idx].trimmingCharacters(in: .whitespaces)
        guard cur.contains("|") else { return false }
        let sep = lines[idx + 1].trimmingCharacters(in: .whitespaces)
        guard isTableSeparator(sep) else { return false }
        // The delimiter row must have one cell per header cell.
        return splitRow(sep).count == splitRow(cur).count
    }

    static func isTableSeparator(_ s: String) -> Bool {
        guard s.contains("-") else { return false }
        let cells = splitRow(s)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell -> Bool in
            var c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            if c.hasPrefix(":") { c = String(c.dropFirst()) }
            if c.hasSuffix(":") { c = String(c.dropLast()) }
            return c.count >= 1 && c.allSatisfy { $0 == "-" }
        }
    }

    static func splitRow(_ raw: String) -> [String] {
        var parts = raw.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if let f = parts.first, f.isEmpty { parts.removeFirst() }
        if let l = parts.last, l.isEmpty { parts.removeLast() }
        return parts
    }
}

// MARK: Inline parsing

private func renderInlineMarkdown(_ text: String) -> String {
    let escaped = htmlEscape(text)

    // 1. Carve code spans so their contents are never parsed for emphasis etc.
    var codeSpans: [String] = []
    var carved = ""
    var idx = escaped.startIndex
    var inCode = false
    var current = ""
    while idx < escaped.endIndex {
        if escaped[idx] == "`" {
            if inCode {
                codeSpans.append(current)
                carved += "\u{0}\(codeSpans.count - 1)\u{1}"
                current = ""
            }
            inCode.toggle()
        } else if inCode {
            current.append(escaped[idx])
        } else {
            carved.append(escaped[idx])
        }
        idx = escaped.index(after: idx)
    }
    if inCode { carved += "`" + current }

    // 2. Carve rendered links/images so autolinking never touches their URLs.
    var rich: [String] = []
    carved = carveLinksAndImages(carved, into: &rich)

    // 3. Autolink bare http(s) URLs outside of links/images.
    carved = autolinkURLs(carved, into: &rich)

    // 4. Inline math, strikethrough, emphasis (in that order).
    var out = renderMathInline(carved)
    out = renderStrikethrough(out)
    out = renderEmphasis(out)

    // 5. Restore carved spans.
    for (index, span) in codeSpans.enumerated() {
        out = out.replacingOccurrences(of: "\u{0}\(index)\u{1}", with: "<code>" + span + "</code>")
    }
    for (index, span) in rich.enumerated() {
        out = out.replacingOccurrences(of: "\u{3}\(index)\u{4}", with: span)
    }

    // 6. Allow-list raw <br> (everything else stays escaped).
    out = out.replacingOccurrences(of: "&lt;br /&gt;", with: "<br>")
    out = out.replacingOccurrences(of: "&lt;br/&gt;", with: "<br>")
    out = out.replacingOccurrences(of: "&lt;br&gt;", with: "<br>")
    return out
}

private func carveLinksAndImages(_ text: String, into rich: inout [String]) -> String {
    var result = ""
    var i = text.startIndex
    while i < text.endIndex {
        let isImage = text[i] == "!"
        if isImage || text[i] == "[" {
            let labelStart = isImage ? text.index(i, offsetBy: 2) : text.index(after: i)
            if let close = text[labelStart...].firstIndex(of: "]"),
               close < text.index(before: text.endIndex),
               text[text.index(after: close)] == "(" {
                let label = String(text[labelStart..<close])
                let urlStart = text.index(close, offsetBy: 2)
                if let urlEnd = text[urlStart...].firstIndex(of: ")") {
                    let url = String(text[urlStart..<urlEnd])
                    if let safe = sanitizeURL(url), !label.isEmpty {
                        if isImage {
                            rich.append("<img src=\"" + htmlEscape(safe) + "\" alt=\"" + htmlEscape(label) + "\">")
                        } else {
                            rich.append("<a href=\"" + htmlEscape(safe) + "\">" + label + "</a>")
                        }
                    } else {
                        rich.append((isImage ? "![" : "[") + label + "](" + url + ")")
                    }
                    result += "\u{3}\(rich.count - 1)\u{4}"
                    i = text.index(after: urlEnd)
                    continue
                }
            }
        }
        result.append(text[i])
        i = text.index(after: i)
    }
    return result
}

private func autolinkURLs(_ text: String, into rich: inout [String]) -> String {
    var result = ""
    var i = text.startIndex
    while i < text.endIndex {
        let rest = text[i...]
        if text[i] == "h" && (rest.hasPrefix("http://") || rest.hasPrefix("https://")) {
            var j = i
            var url = ""
            while j < text.endIndex {
                let c = text[j]
                if c == " " || c == "\n" || c == "\t" || c == "<" || c == ">" || c == ")"
                    || c == "]" || c == "}" || c == "\"" || c == "\u{0}" || c == "\u{3}" {
                    break
                }
                url.append(c)
                j = text.index(after: j)
            }
            if !url.isEmpty {
                rich.append("<a href=\"" + htmlEscape(url) + "\">" + url + "</a>")
                result += "\u{3}\(rich.count - 1)\u{4}"
                i = j
                continue
            }
        }
        result.append(text[i])
        i = text.index(after: i)
    }
    return result
}

private func renderMathInline(_ text: String) -> String {
    var result = ""
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == "$" {
            let after = text.index(after: i)
            if after < text.endIndex, text[after] != "$" {
                if let close = findInlineMarker(text, from: after, marker: "$") {
                    let src = String(text[after..<close])
                    if !src.isEmpty && src != " " {
                        result += "<equation-inline>" + src + "</equation-inline>"
                        i = text.index(after: close)
                        continue
                    }
                }
            }
        } else if text[i] == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "(" {
            let after = text.index(i, offsetBy: 2)
            if let close = findInlineMarker(text, from: after, marker: "\\)") {
                let src = String(text[after..<close])
                result += "<equation-inline>" + src + "</equation-inline>"
                i = text.index(close, offsetBy: 2)
                continue
            }
        }
        result.append(text[i])
        i = text.index(after: i)
    }
    return result
}

private func renderStrikethrough(_ text: String) -> String {
    var result = ""
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == "~", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "~" {
            let contentStart = text.index(i, offsetBy: 2)
            if let close = findInlineMarker(text, from: contentStart, marker: "~~") {
                let inner = String(text[contentStart..<close])
                if !inner.isEmpty && !inner.hasPrefix(" ") && !inner.hasSuffix(" ") {
                    result += "<s>" + renderEmphasis(inner) + "</s>"
                    i = text.index(close, offsetBy: 2)
                    continue
                }
            }
        }
        result.append(text[i])
        i = text.index(after: i)
    }
    return result
}

private func renderEmphasis(_ text: String) -> String {
    var result = ""
    var i = text.startIndex
    while i < text.endIndex {
        let ch = text[i]
        if ch == "*" || ch == "_" {
            let next = text.index(after: i)
            let isStrong = next < text.endIndex && text[next] == ch
            let markerLen = isStrong ? 2 : 1
            let contentStart = isStrong ? text.index(i, offsetBy: 2) : next
            // Underscore emphasis needs word-boundary guards so snake_case and
            // identifiers stay literal.
            if ch == "_" {
                let prevOK = i == text.startIndex || !isWordChar(text[text.index(before: i)])
                if !prevOK {
                    result.append(ch)
                    i = next
                    continue
                }
            }
            if let close = findInlineMarker(text, from: contentStart,
                                            marker: String(repeating: ch, count: markerLen)) {
                var inner = String(text[contentStart..<close])
                if ch == "_", close < text.index(before: text.endIndex) {
                    let afterClose = text.index(close, offsetBy: markerLen)
                    if afterClose < text.endIndex, isWordChar(text[afterClose]) {
                        // closing underscore inside a word — literal
                        result.append(ch)
                        i = next
                        continue
                    }
                }
                if !inner.isEmpty && !inner.hasPrefix(" ") && !inner.hasSuffix(" ") {
                    let open = isStrong ? "<strong>" : "<em>"
                    let closeTag = isStrong ? "</strong>" : "</em>"
                    result += open + renderEmphasis(inner) + closeTag
                    i = text.index(close, offsetBy: markerLen)
                    continue
                }
            }
        }
        result.append(text[i])
        i = text.index(after: i)
    }
    return result
}

private func findInlineMarker(_ text: String, from start: String.Index, marker: String) -> String.Index? {
    var j = start
    while j < text.endIndex {
        if text[j...].hasPrefix(marker) { return j }
        j = text.index(after: j)
    }
    return nil
}

private func isWordChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber
}

// MARK: - Syntax Highlighting (Stub)

/// Syntax-highlight code on the server side.
///
/// Produces `<span>` elements with class names for keywords,
/// strings, comments, types, and numbers. The CSS design system
/// (``AppStyles``) defines the colors for each token class.
///
/// ## Supported Languages
///
/// - Swift
/// - Python
/// - Rust
/// - JavaScript / TypeScript
/// - Go
/// - Ruby
/// - Shell / Bash
///
/// - Parameters:
///   - code: The source code to highlight.
///   - language: The programming language identifier.
/// - Returns: HTML string with `<span class="token ...">` elements.
///
/// > Phase W4: This is a stub that returns the code HTML-escaped
/// > without highlighting. The full implementation will use Swift
/// > Regex for tokenization.
public func highlightCode(_ code: String, language: String) -> String {
    // Phase W4 implementation placeholder
    // Returns the code HTML-escaped without highlighting for now
    htmlEscape(code)
}
