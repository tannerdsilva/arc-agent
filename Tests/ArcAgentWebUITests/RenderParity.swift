@testable import ArcWebUI
import ArcAgentCore
import Foundation
import Testing
import WebUI

// the render parity harness. a golden is the *legacy* output captured before
// conversion; the converted view must match it after `Parity.normalize`.
//
// goldens live in Tests/ArcAgentWebUITests/Fixtures/parity/<builder>.html and
// are read by source-relative path (cwd is the package root under `swift test`),
// with a Bundle.module fallback for runners that don't vend the working directory.
//
// `ARC_PARITY_CAPTURE=1 swift test --filter RenderParity` writes the goldens
// from the legacy builders; a normal `swift test` never writes.

// MARK: - normalizer

/// parity revision of an html fragment:
///  - drops whitespace-only text nodes between tags and collapses runs of
///    whitespace inside text nodes to one space
///  - normalizes boolean attributes to `name=""` (hidden, checked, disabled,
///    selected, open, multiple, required, readonly, data-no-restore)
///  - drops an empty `class=""` / `style=""` attribute
///  - decodes numeric character references in text (`&#9776;` == `☰`)
///  - sorts the attributes of every open tag
///
/// the result is what "the same markup" means in this migration; anything the
/// normalizer hides is a real difference the migration did not intend.
///
/// inside `<pre>` and `<code>` whitespace is not collapsed — content there is
/// literal.
///
/// the scanner is written by hand (no NSRegularExpression) so it stays exact
/// and has no availability question.
enum ParityNormalize {

    private static let booleanAttributes: Set<String> = [
        "hidden", "checked", "disabled", "selected", "open", "multiple",
        "required", "readonly", "data-no-restore",
    ]

    static func normalize(_ html: String) -> String {
        let chars = Array(html)
        var out = ""
        var i = chars.startIndex
        // tags whose text content must not be whitespace-normalized
        var literalStack: [String] = []

        while i < chars.endIndex {
            if chars[i] == "<" {
                // look ahead
                let after = chars.index(i, offsetBy: 1, limitedBy: chars.endIndex)
                if let after, chars[after] == "/" {
                    // closing tag: skip the `/` before scanning the name — passing
                    // `after` itself scans from the slash, finds no tag-name
                    // character and emits `</>`, which silently breaks every
                    // multi-element comparison.
                    let nameStart = chars.index(after: after)
                    let (tag, end) = scanTagName(chars, nameStart)
                    out += "</\(tag)>"
                    if !literalStack.isEmpty && literalStack.last == tag {
                        literalStack.removeLast()
                    }
                    i = end
                    continue
                } else if let after, chars[after] == "!" {
                    // comment or doctype: emit verbatim to the end of the tag
                    let end = scanToClose(chars, after)
                    out += String(chars[i..<end])
                    i = end
                    continue
                } else if let after, chars[after] == "?" {
                    // processing instruction
                    let end = scanToClose(chars, after)
                    out += String(chars[i..<end])
                    i = end
                    continue
                } else {
                    // open tag
                    let (tag, end, attrs) = scanOpenTag(chars, after ?? chars.endIndex)
                    let normalizedAttrs = normalizeAttributes(attrs)
                    let attrText = normalizedAttrs.isEmpty ? "" : " " + normalizedAttrs.joined(separator: " ")
                    out += "<\(tag)\(attrText)>"
                    if tag == "pre" || tag == "code" {
                        literalStack.append(tag)
                    }
                    i = end
                    continue
                }
            }

            // text
            let (text, end) = scanText(chars, i)
            let processed = processText(text, literalStack)
            if !processed.isEmpty {
                out += processed
            }
            i = end
        }

        return out
    }

    // MARK: scanning

    /// scan an open tag from just after `<`. returns (tagName, indexAfterClose, attributes).
    private static func scanOpenTag(_ chars: [Character], _ start: Int) -> (String, Int, [(String, String)]) {
        var i = start
        // tag name
        var name = ""
        while i < chars.endIndex, isTagNameChar(chars[i]) {
            name.append(chars[i])
            i += 1
        }
        // attributes
        var attrs: [(String, String)] = []
        while i < chars.endIndex && chars[i] != ">" {
            if chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" || chars[i] == "\r" {
                i += 1
                continue
            }
            if let (attr, next) = scanAttribute(chars, i) {
                attrs.append(attr)
                i = next
            } else {
                i += 1
            }
        }
        let end = chars.index(i, offsetBy: 1, limitedBy: chars.endIndex) ?? i
        return (name, end, attrs)
    }

    /// scan an attribute: `name` or `name="value"` or `name='value'` or `name=value`.
    private static func scanAttribute(_ chars: [Character], _ start: Int) -> ((String, String), Int)? {
        var i = start
        var name = ""
        while i < chars.endIndex, isAttrNameChar(chars[i]) {
            name.append(chars[i])
            i += 1
        }
        if name.isEmpty { return nil }
        var value = ""
        if i < chars.endIndex && chars[i] == "=" {
            i += 1
            if i < chars.endIndex && (chars[i] == "\"" || chars[i] == "'") {
                let quote = chars[i]
                i += 1
                while i < chars.endIndex && chars[i] != quote {
                    value.append(chars[i])
                    i += 1
                }
                if i < chars.endIndex { i += 1 } // consume closing quote
            } else {
                while i < chars.endIndex, isAttrValueChar(chars[i]) {
                    value.append(chars[i])
                    i += 1
                }
            }
        }
        return ((name, value), i)
    }

    /// scan a closing tag name from just after `</`. returns (tagName, indexAfterClose).
    private static func scanTagName(_ chars: [Character], _ start: Int) -> (String, Int) {
        var i = start
        var name = ""
        while i < chars.endIndex, isTagNameChar(chars[i]) {
            name.append(chars[i])
            i += 1
        }
        // skip to `>`
        while i < chars.endIndex && chars[i] != ">" { i += 1 }
        let end = chars.index(i, offsetBy: 1, limitedBy: chars.endIndex) ?? i
        return (name, end)
    }

    /// scan to the closing `>` of a comment/doctype/pi (quote-aware).
    private static func scanToClose(_ chars: [Character], _ start: Int) -> Int {
        var i = start
        var inQuote: Character? = nil
        while i < chars.endIndex {
            let c = chars[i]
            if let q = inQuote {
                if c == q { inQuote = nil }
            } else if c == "\"" || c == "'" {
                inQuote = c
            } else if c == ">" {
                return chars.index(i, offsetBy: 1, limitedBy: chars.endIndex) ?? i
            }
            i += 1
        }
        return i
    }

    /// scan text from `start` up to the next `<`. returns (text, indexOfOpenBracket).
    private static func scanText(_ chars: [Character], _ start: Int) -> (String, Int) {
        var i = start
        while i < chars.endIndex && chars[i] != "<" {
            i += 1
        }
        return (String(chars[start..<i]), i)
    }

    private static func isTagNameChar(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") ||
            c == "-" || c == "_" || c == ":"
    }

    private static func isAttrNameChar(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") ||
            c == "-" || c == "_" || c == ":" || c == "."
    }

    private static func isAttrValueChar(_ c: Character) -> Bool {
        c != " " && c != "\t" && c != "\n" && c != "\r" && c != ">" && c != "\"" && c != "'" && c != "="
    }

    // MARK: attribute normalization

    private static func normalizeAttributes(_ attrs: [(String, String)]) -> [String] {
        var result: [String] = []
        for (name, value) in attrs {
            if booleanAttributes.contains(name) {
                result.append("\(name)=\"\"")
            } else if name == "class" {
                // `class` is a space-separated token SET, so a leading, trailing
                // or doubled space is semantically invisible. The legacy
                // builders emitted `class=" menu-sel"` by interpolating a
                // prefixed flag; comparing the canonical token list lets the
                // typed tree emit the plain spelling instead of carrying a
                // stray space forever.
                let tokens = value.split(whereSeparator: \.isWhitespace)
                if tokens.isEmpty { continue } // drop empty class=""
                result.append("class=\"\(escapeAttr(tokens.joined(separator: " ")))\"")
            } else if name == "style" && value.isEmpty {
                continue // drop empty style=""
            } else {
                result.append("\(name)=\"\(escapeAttr(value))\"")
            }
        }
        result.sort { $0 < $1 }
        return result
    }

    private static func escapeAttr(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: text processing

    private static func processText(_ text: String, _ literalStack: [String]) -> String {
        if !literalStack.isEmpty {
            return decodeNumericRefs(text)
        }
        // drop whitespace-only text nodes between tags
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        // collapse runs of whitespace to one space
        var collapsed = ""
        var prevSpace = false
        for c in trimmed {
            if c.isWhitespace {
                if !prevSpace {
                    collapsed.append(" ")
                    prevSpace = true
                }
            } else {
                collapsed.append(c)
                prevSpace = false
            }
        }
        return decodeNumericRefs(collapsed)
    }

    private static func decodeNumericRefs(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = chars.startIndex
        while i < chars.endIndex {
            if chars[i] == "&",
               i + 1 < chars.endIndex,
               chars[i + 1] == "#",
               i + 2 < chars.endIndex,
               (chars[i + 2] == "x" || chars[i + 2] == "X") {
                // hex: &#xHHHH;
                let hexStart = i + 3
                var hexEnd = hexStart
                while hexEnd < chars.endIndex,
                      "0123456789abcdefABCDEF".contains(chars[hexEnd]) {
                    hexEnd += 1
                }
                if hexEnd < chars.endIndex && chars[hexEnd] == ";" {
                    let hexDigits = String(chars[hexStart..<hexEnd])
                    if let value = UInt32(hexDigits, radix: 16),
                       let scalar = UnicodeScalar(value) {
                        out.append(Character(scalar))
                        i = hexEnd + 1
                        continue
                    }
                }
            } else if chars[i] == "&",
               i + 1 < chars.endIndex,
               chars[i + 1] == "#" {
                // decimal: &#NNN;
                let numStart = i + 2
                var numEnd = numStart
                while numEnd < chars.endIndex,
                      "0123456789".contains(chars[numEnd]) {
                    numEnd += 1
                }
                if numEnd < chars.endIndex && chars[numEnd] == ";" {
                    let numDigits = String(chars[numStart..<numEnd])
                    if let value = UInt32(numDigits),
                       let scalar = UnicodeScalar(value) {
                        out.append(Character(scalar))
                        i = numEnd + 1
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}

// MARK: - parity API

enum Parity {

    private static var fixturesDir: String {
        "Tests/ArcAgentWebUITests/Fixtures/parity"
    }

    /// capture the legacy builder's output as the golden. only runs when
    /// `ARC_PARITY_CAPTURE=1`, so a normal `swift test` never writes.
    static func capture(_ html: String, as name: String) {
        guard ProcessInfo.processInfo.environment["ARC_PARITY_CAPTURE"] == "1" else { return }
        let url = URL(fileURLWithPath: fixturesDir)
            .appendingPathComponent("\(name).html")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? html.data(using: .utf8)?.write(to: url)
    }

    /// assert a converted view renders the golden (normalized).
    static func expect<V: WebUI.View>(_ view: V, matches name: String) {
        let html = view.markup.html
        expect(html, matches: name)
    }

    /// assert two strings are parity-equal (for builders that stay `-> String`).
    static func expect(_ html: String, matches name: String) {
        let golden = readGolden(name)
        let normalized = ParityNormalize.normalize(html)
        let normalizedGolden = ParityNormalize.normalize(golden)
        #expect(normalized == normalizedGolden, "\(parityFailure(name: name, got: normalized, expected: normalizedGolden))")
    }

    /// build a failure message that names the golden, the first diverging
    /// offset, and ±120 chars of context from both sides.
    private static func parityFailure(name: String, got: String, expected: String) -> String {
        let gotChars = Array(got)
        let expChars = Array(expected)
        let limit = min(gotChars.count, expChars.count)
        var firstDiff = limit
        for k in 0..<limit where gotChars[k] != expChars[k] {
            firstDiff = k
            break
        }
        let window = 120
        let lo = max(0, firstDiff - window)
        let hi = min(gotChars.count, firstDiff + window + 1)
        let expHi = min(expChars.count, firstDiff + window + 1)
        let gotCtx = String(gotChars[lo..<hi])
        let expCtx = String(expChars[lo..<expHi])
        return """
        parity mismatch for \(name):
          first diverging offset: \(firstDiff) (got length \(gotChars.count), expected length \(expChars.count))
          got:      \(debugWindow(gotCtx, anchor: firstDiff - lo))
          expected: \(debugWindow(expCtx, anchor: firstDiff - lo))
        """
    }

    /// render a context window with a caret under the anchor offset.
    private static func debugWindow(_ s: String, anchor: Int) -> String {
        let pad = String(repeating: " ", count: max(0, anchor))
        return s + "\n            \(pad)^"
    }

    private static func readGolden(_ name: String) -> String {
        let url = URL(fileURLWithPath: fixturesDir).appendingPathComponent("\(name).html")
        if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
            return s
        }
        // Bundle.module fallback for runners that don't vend the working directory
        if let url = Bundle.module.url(forResource: name, withExtension: "html",
                                       subdirectory: "Fixtures/parity"),
           let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }
}

// MARK: - canaries

@Suite("Render parity", .serialized)
struct RenderParityTests {

    @Test("topbar matches golden")
    func topbarMatchesGolden() async {
        let app = AppState(renderFixture: .init())
        let html = await app.topbarHTML().markup.html
        Parity.capture(html, as: "topbar")
        Parity.expect(html, matches: "topbar")
    }

    @Test("session group matches golden")
    func sessionGroupMatchesGolden() async {
        let app = AppState(renderFixture: .init(sessions: [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    title: "Session A", messages: []),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
                    title: "Session B", messages: []),
        ]))
        let html = await app.groupHTML(key: "recent", title: "Recent", sessions: await app.sessions).markup.html
        Parity.capture(html, as: "sessionGroup")
        Parity.expect(html, matches: "sessionGroup")
    }

    // MARK: - phase 3 message-tree fixtures

    private static func phase3Thread() -> [Message] {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = Usage(promptTokens: 1200, completionTokens: 340, totalTokens: 1540)
        return [
            Message(role: .user, content: "hello **there**", createdAt: t0),
            Message(role: .assistant, content: nil,
                    toolCalls: [ToolCall(id: "call_1",
                                         function: ToolCallFunction(name: "read_file",
                                                                    arguments: "{\"path\":\"README.md\"}"))],
                    createdAt: t0),
            Message(role: .tool, content: "file contents", name: "read_file",
                    toolCallID: "call_1", createdAt: t0),
            Message(role: .assistant, content: "All done.", createdAt: t0,
                    usage: usage, tps: 42.5, turnDuration: 3.2),
        ]
    }

    @Test("phase 3: user message matches golden")
    func phase3UserMessage() async {
        let app = AppState(renderFixture: .init())
        let html = await app.messageHTML(Self.phase3Thread()[0], rawIdx: 0).markup.html
        Parity.capture(html, as: "message-user")
        Parity.expect(html, matches: "message-user")
    }

    @Test("phase 3: assistant message with tool calls matches golden")
    func phase3AssistantMessage() async {
        let app = AppState(renderFixture: .init())
        let html = await app.messageHTML(Self.phase3Thread()[1], rawIdx: 1).markup.html
        Parity.capture(html, as: "message-assistant-tools")
        Parity.expect(html, matches: "message-assistant-tools")
    }

    @Test("phase 3: assistant message with usage matches golden")
    func phase3AssistantUsage() async {
        let app = AppState(renderFixture: .init())
        let html = await app.messageHTML(Self.phase3Thread()[3], rawIdx: 3).markup.html
        Parity.capture(html, as: "message-assistant-usage")
        Parity.expect(html, matches: "message-assistant-usage")
    }

    @Test("phase 3: tool result message matches golden")
    func phase3ToolMessage() async {
        let app = AppState(renderFixture: .init())
        let html = await app.messageHTML(Self.phase3Thread()[2], rawIdx: 2).markup.html
        Parity.capture(html, as: "message-tool")
        Parity.expect(html, matches: "message-tool")
    }

    @Test("phase 3: turn block matches golden")
    func phase3TurnBlock() async {
        let app = AppState(renderFixture: .init())
        let seg = Array(Self.phase3Thread()[1...3])
        let html = await app.turnBlockHTML(seg, mode: "compact_worklog", turnIndex: 1) ?? ""
        Parity.capture(html, as: "turn-block")
        Parity.expect(html, matches: "turn-block")
    }

    @Test("phase 3: composer matches golden")
    func phase3Composer() async {
        var fixture = AppState.RenderFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat",
                                    messageCount: 1, messages: [Message(role: .user, content: "hi")])]
        let app = AppState(renderFixture: fixture)
        let html = await app.composerHTML().markup.html
        Parity.capture(html, as: "composer")
        Parity.expect(html, matches: "composer")
    }

    @Test("phase 3: chat main matches golden")
    func phase3ChatMain() async {
        var fixture = AppState.RenderFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat",
                                    messageCount: 4, messages: Self.phase3Thread())]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatMain()
        Parity.capture(html, as: "chat-main")
        Parity.expect(html, matches: "chat-main")
    }

    @Test("phase 3: chat main empty state matches golden")
    func phase3ChatMainEmpty() async {
        let app = AppState(renderFixture: .init())
        let html = await app.chatMain()
        Parity.capture(html, as: "chat-main-empty")
        Parity.expect(html, matches: "chat-main-empty")
    }

    @Test("chat header matches golden")
    func chatHeaderMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Active Session",
                    messageCount: 2, messages: [
                        Message(role: .user, content: "hello"),
                        Message(role: .assistant, content: "hi there"),
                    ]),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatHeaderHTML().markup.html
        Parity.capture(html, as: "chat-header")
        Parity.expect(html, matches: "chat-header")
    }

    @Test("chat header without messages hides the count")
    func chatHeaderFreshChatHidesCount() async {
        var fixture = AppState.RenderFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Fresh",
                    messageCount: 0, messages: []),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatHeaderHTML().markup.html
        Parity.capture(html, as: "chat-header-empty")
        Parity.expect(html, matches: "chat-header-empty")
    }

    @Test("assistant message matches golden")
    func assistantMessageMatchesGolden() async {
        let app = AppState(renderFixture: .init())
        let m = Message(role: .assistant, content: "Hello, world")
        let html = await app.messageHTML(m).markup.html
        Parity.capture(html, as: "assistantMessage")
        Parity.expect(html, matches: "assistantMessage")
    }

    @Test("normalizer is pinned")
    func normalizerIsPinned() {
        // escaped entities decode to their character
        #expect(ParityNormalize.normalize("&#9776;") == "☰")
        #expect(ParityNormalize.normalize("&#8595;") == "↓")
        #expect(ParityNormalize.normalize("a&<>\"'") == "a&<>\"'")
        // boolean attribute normalization
        #expect(ParityNormalize.normalize("<div hidden>") == "<div hidden=\"\">")
        #expect(ParityNormalize.normalize("<input checked disabled>")
            == "<input checked=\"\" disabled=\"\">")
        // empty class / style dropped
        #expect(ParityNormalize.normalize("<div class=\"\">x</div>") == "<div>x</div>")
        #expect(ParityNormalize.normalize("<div style=\"\">x</div>") == "<div>x</div>")
        // attribute sorting
        #expect(ParityNormalize.normalize("<div b=\"1\" a=\"2\">") == "<div a=\"2\" b=\"1\">")
        // whitespace collapse, whitespace-only text nodes dropped
        #expect(ParityNormalize.normalize("<div>  a   b  </div>") == "<div>a b</div>")
        #expect(ParityNormalize.normalize("<div>\n  </div><span>x</span>") == "<div></div><span>x</span>")
        // boolean: data-no-restore normalizes to name=""
        #expect(ParityNormalize.normalize("<div data-no-restore>") == "<div data-no-restore=\"\">")
        // attribute values containing > are kept intact (not cut at the >)
        #expect(ParityNormalize.normalize("<div title=\"a>b\">x</div>") == "<div title=\"a>b\">x</div>")
        // pre content is literal (whitespace preserved)
        #expect(ParityNormalize.normalize("<pre>  a   b\n</pre>") == "<pre>  a   b\n</pre>")
        // code content is literal
        #expect(ParityNormalize.normalize("<code>x  y</code>") == "<code>x  y</code>")
    }

    @Test("shell default matches golden")
    func shellDefaultMatchesGolden() async {
        let app = AppState(renderFixture: .init(activeTabID: "chat"))
        let shell = await app.appShell()
        Parity.capture(shell.markup.html, as: "shell-default")
        Parity.expect(shell.markup.html, matches: "shell-default")
    }

    @Test("shell drawer matches golden")
    func shellDrawerMatchesGolden() async {
        let app = AppState(renderFixture: .init(activeTabID: "chat"))
        let shell = await app.appShell()
        Parity.capture(shell.markup.html, as: "shell-drawer")
        Parity.expect(shell.markup.html, matches: "shell-drawer")
    }

    @Test("iconbar chat matches golden")
    func iconbarChatMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.settings.sidebarTabs = ["skills", "profiles", "tools", "workspaces", "kanban"]
        let app = AppState(renderFixture: fixture)
        let html = await app.iconbarHTML().markup.html
        Parity.capture(html, as: "iconbar-chat")
        Parity.expect(html, matches: "iconbar-chat")
    }

    @Test("iconbar settings matches golden")
    func iconbarSettingsMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.settings.sidebarTabs = ["skills", "profiles", "tools", "workspaces", "kanban"]
        fixture.activeTabID = "settings"
        let app = AppState(renderFixture: fixture)
        let html = await app.iconbarHTML().markup.html
        Parity.capture(html, as: "iconbar-settings")
        Parity.expect(html, matches: "iconbar-settings")
    }

    @Test("toasts empty matches golden")
    func toastsEmptyMatchesGolden() async {
        let app = AppState(renderFixture: .init(toasts: []))
        let html = await app.toastsShell().markup.html
        Parity.capture(html, as: "toasts-empty")
        Parity.expect(html, matches: "toasts-empty")
    }

    @Test("toasts three matches golden")
    func toastsThreeMatchesGolden() async {
        let app = AppState(renderFixture: .init(toasts: [
            Toast(id: 1, text: "Processing", kind: "info"),
            Toast(id: 2, text: "Saved", kind: "success", action: ToastAction(id: "undo", label: "Undo")),
            Toast(id: 3, text: "Failed", kind: "error"),
        ]))
        let html = await app.toastsShell().markup.html
        Parity.capture(html, as: "toasts-three")
        Parity.expect(html, matches: "toasts-three")
    }

    @Test("toasts overflow matches golden")
    func toastsOverflowMatchesGolden() async {
        let app = AppState(renderFixture: .init(toasts: [
            Toast(id: 1, text: "One", kind: "info"),
            Toast(id: 2, text: "Two", kind: "info"),
            Toast(id: 3, text: "Three", kind: "info"),
            Toast(id: 4, text: "Four", kind: "info"),
            Toast(id: 5, text: "Five", kind: "info"),
        ]))
        let html = await app.toastsShell().markup.html
        Parity.capture(html, as: "toasts-overflow")
        Parity.expect(html, matches: "toasts-overflow")
    }

    @Test("toasts pending copy matches golden")
    func toastsPendingCopyMatchesGolden() async {
        let app = AppState(renderFixture: .init(toasts: [], pendingCopyURL: "https://example.com/x"))
        let html = await app.toastsShell().markup.html
        Parity.capture(html, as: "toasts-pending-copy")
        Parity.expect(html, matches: "toasts-pending-copy")
    }

    @Test("modal armed matches golden")
    func modalArmedMatchesGolden() async {
        let app = AppState(renderFixture: .init(
            pendingConfirm: ConfirmRequest(
                kind: "chat", id: "sess-a",
                title: "Delete conversation?",
                body: "The chat “A” will be deleted. You can undo this for 10 seconds."
            )
        ))
        let html = await app.modalHTML().markup.html
        Parity.capture(html, as: "modal-armed")
        Parity.expect(html, matches: "modal-armed")
    }

    @Test("modal empty matches golden")
    func modalEmptyMatchesGolden() async {
        let app = AppState(renderFixture: .init())
        let html = await app.modalHTML().markup.html
        Parity.capture(html, as: "modal-empty")
        Parity.expect(html, matches: "modal-empty")
    }

    @Test("category menu matches golden")
    func categoryMenuMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.categoryMenu = CategoryMenu(categoryID: "c1", x: 40, y: 60)
        fixture.settings.chatCategories = [ChatCategory(id: "c1", name: "C1", color: "#B8860B")]
        let app = AppState(renderFixture: fixture)
        let html = await app.categoryMenuHTML().markup.html
        Parity.capture(html, as: "category-menu")
        Parity.expect(html, matches: "category-menu")
    }

    @Test("category menu clamped matches golden")
    func categoryMenuClampedMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.categoryMenu = CategoryMenu(categoryID: "c1", x: 2000, y: 900)
        fixture.settings.chatCategories = [ChatCategory(id: "c1", name: "C1", color: "#B8860B")]
        let app = AppState(renderFixture: fixture)
        let html = await app.categoryMenuHTML().markup.html
        Parity.capture(html, as: "category-menu-clamped")
        Parity.expect(html, matches: "category-menu-clamped")
    }

    @Test("category menu rename matches golden")
    func categoryMenuRenameMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.categoryMenu = CategoryMenu(categoryID: "c1", x: 40, y: 60)
        fixture.categoryMenuRename = true
        fixture.settings.chatCategories = [ChatCategory(id: "c1", name: "C1", color: "#B8860B")]
        let app = AppState(renderFixture: fixture)
        let html = await app.categoryMenuHTML().markup.html
        Parity.capture(html, as: "category-menu-rename")
        Parity.expect(html, matches: "category-menu-rename")
    }

    // MARK: Task 2.1 — chat-panel goldens (captured from legacy builders)

    @Test("panel chat matches golden")
    func panelChatMatchesGolden() async {
        let app = AppState(renderFixture: .init(activeTabID: "chat"))
        let html = await app.panelHTML().markup.html
        Parity.capture(html, as: "panel-chat")
        Parity.expect(html, matches: "panel-chat")
    }

    @Test("chat panel empty matches golden")
    func chatPanelEmptyMatchesGolden() async {
        let app = AppState(renderFixture: .init())
        let html = await app.chatPanel()
        Parity.capture(html, as: "chat-panel-empty")
        Parity.expect(html, matches: "chat-panel-empty")
    }

    @Test("chat panel three matches golden")
    func chatPanelThreeMatchesGolden() async {
        let m1 = Message(role: .user, content: "Hello")
        let m2 = Message(role: .assistant, content: "Hi")
        var fixture = AppState.RenderFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Session A",
                    messageCount: 2, messages: [m1, m2]),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Session B",
                    messageCount: 0, messages: []),
            Session(id: "sess-c", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Session C",
                    messageCount: 0, messages: []),
        ]
        fixture.settings.archivedSessions = ["sess-b"]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatPanel()
        Parity.capture(html, as: "chat-panel-three")
        Parity.expect(html, matches: "chat-panel-three")
    }

    @Test("chat panel filtered empty matches golden")
    func chatPanelFilteredEmptyMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.chatFilter = "zzz"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Alpha"),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600), title: "Beta"),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatPanel()
        Parity.capture(html, as: "chat-panel-filtered-empty")
        Parity.expect(html, matches: "chat-panel-filtered-empty")
    }

    @Test("chat panel archived matches golden")
    func chatPanelArchivedMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.showArchived = true
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Session A"),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Session B",
                    messageCount: 0, messages: []),
        ]
        fixture.settings.archivedSessions = ["sess-b"]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatPanel()
        Parity.capture(html, as: "chat-panel-archived")
        Parity.expect(html, matches: "chat-panel-archived")
    }

    @Test("chat panel todos matches golden")
    func chatPanelTodosMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Session A"),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600), title: "Session B"),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatPanel(todos: true)
        Parity.capture(html, as: "chat-panel-todos")
        Parity.expect(html, matches: "chat-panel-todos")
    }

    @Test("chat panel clearable matches golden")
    func chatPanelClearableMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Draft A",
                    messageCount: 0, messages: []),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600), title: "Draft B",
                    messageCount: 0, messages: []),
            Session(id: "sess-c", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + 7200),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + 7200), title: "Draft C",
                    messageCount: 0, messages: []),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.chatPanel()
        Parity.capture(html, as: "chat-panel-clearable")
        Parity.expect(html, matches: "chat-panel-clearable")
    }

    @Test("session group matches golden")
    func sessionGroupTask21MatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Session A"),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600), title: "Session B"),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.groupHTML(key: "today", title: "Today", sessions: fixture.sessions).markup.html
        Parity.capture(html, as: "sess-group")
        Parity.expect(html, matches: "sess-group")
    }

    @Test("session row active matches golden")
    func sessionRowActiveMatchesGolden() async {
        let msgs = (0..<4).map { Message(role: .user, content: "msg \($0)") }
        var fixture = AppState.RenderFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Active Session",
                    messageCount: 4, messages: msgs),
        ]
        fixture.settings.bookmarkedSessions = ["sess-a"]
        fixture.settings.chatCategories = [ChatCategory(id: "c1", name: "Work", color: "#E5484D")]
        fixture.settings.sessionCategories = ["sess-a": "c1"]
        let app = AppState(renderFixture: fixture)
        let html = await app.sessionRow(fixture.sessions[0]).markup.html
        Parity.capture(html, as: "sess-row-active")
        Parity.expect(html, matches: "sess-row-active")
    }

    @Test("session row idle matches golden")
    func sessionRowIdleMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.sessions = [
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Idle Session",
                    messageCount: 0, messages: []),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.sessionRow(fixture.sessions[0]).markup.html
        Parity.capture(html, as: "sess-row-idle")
        Parity.expect(html, matches: "sess-row-idle")
    }

    @Test("session row archived matches golden")
    func sessionRowArchivedMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.sessions = [
            Session(id: "sess-c", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Archived Session",
                    messageCount: 0, messages: []),
        ]
        fixture.settings.archivedSessions = ["sess-c"]
        let app = AppState(renderFixture: fixture)
        let html = await app.sessionRow(fixture.sessions[0]).markup.html
        Parity.capture(html, as: "sess-row-archived")
        Parity.expect(html, matches: "sess-row-archived")
    }

    @Test("an unarchived row beside an archived one still offers Archive")
    func sessionRowArchivedMenuMatchesGolden() async {
        // the plan asked for a "showArchived" variant, but showArchived never reaches
        // sessionRow — it rendered byte-identical to sess-row-archived and pinned
        // nothing. this case instead proves the menu wording is per-session: with an
        // archived session PRESENT in state, a non-archived row must still say
        // "Archive conversation". a list-derived label (the bug this guards) would
        // say "Unarchive" for every row as soon as one session is archived.
        var fixture = AppState.RenderFixture()
        fixture.showArchived = true
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Live Session",
                    messageCount: 0, messages: []),
            Session(id: "sess-c", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Archived Session",
                    messageCount: 0, messages: []),
        ]
        fixture.settings.archivedSessions = ["sess-c"]
        let app = AppState(renderFixture: fixture)
        let html = await app.sessionRow(fixture.sessions[0]).markup.html
        #expect(html.contains("Archive conversation"),
                "an unarchived row offered Unarchive — the menu label is reading the archived LIST, not this session")
        #expect(!html.contains("Unarchive conversation"),
                "an unarchived row must not offer Unarchive just because another session is archived")
        Parity.capture(html, as: "sess-row-unarchived-beside-archived")
        Parity.expect(html, matches: "sess-row-unarchived-beside-archived")
    }

    @Test("session row live matches golden")
    func sessionRowLiveMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.activeSessionID = "sess-a"
        fixture.activeTurns = ["sess-a": LiveTurn(sessionID: "sess-a", userText: "", attachments: [])]
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Live Session",
                    messageCount: 1, messages: [Message(role: .user, content: "hi")]),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.sessionRow(fixture.sessions[0]).markup.html
        Parity.capture(html, as: "sess-row-live")
        Parity.expect(html, matches: "sess-row-live")
    }

    @Test("session row todos matches golden")
    func sessionRowTodosMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.sessions = [
            Session(id: "sess-d", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Todo Session",
                    messageCount: 0, messages: []),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.sessionRow(fixture.sessions[0], todos: true).markup.html
        Parity.capture(html, as: "sess-row-todos")
        Parity.expect(html, matches: "sess-row-todos")
    }

    @Test("category cloud matches golden")
    func categoryCloudMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.activeCategory = "all"
        fixture.settings.chatCategories = [
            ChatCategory(id: "c1", name: "Work", color: "#E5484D"),
            ChatCategory(id: "c2", name: "Personal", color: "#2F9EB7"),
            ChatCategory(id: "c3", name: "Admin", color: "#9D5CD0"),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.categoryCloudHTML().markup.html
        Parity.capture(html, as: "cat-cloud")
        Parity.expect(html, matches: "cat-cloud")
    }

    @Test("category cloud creating matches golden")
    func categoryCloudCreatingMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.addingCategory = true
        fixture.activeCategory = "c1"
        fixture.settings.chatCategories = [
            ChatCategory(id: "c1", name: "Work", color: "#E5484D"),
            ChatCategory(id: "c2", name: "Personal", color: "#2F9EB7"),
        ]
        let app = AppState(renderFixture: fixture)
        let html = await app.categoryCloudHTML().markup.html
        Parity.capture(html, as: "cat-cloud-creating")
        Parity.expect(html, matches: "cat-cloud-creating")
    }

    @Test("status pill live matches golden")
    func statusPillLiveMatchesGolden() async {
        var fixture = AppState.RenderFixture()
        fixture.activeTurns = ["sess-a": LiveTurn(sessionID: "sess-a", userText: "", attachments: [])]
        let app = AppState(renderFixture: fixture)
        let html = await app.liveStatusPill("sess-a").markup.html
        Parity.capture(html, as: "status-pill-live")
        Parity.expect(html, matches: "status-pill-live")
    }

    @Test("status pill idle matches golden")
    func statusPillIdleMatchesGolden() async {
        let app = AppState(renderFixture: .init())
        let html = await app.liveStatusPill("sess-a").markup.html
        Parity.capture(html, as: "status-pill-idle")
        Parity.expect(html, matches: "status-pill-idle")
    }
}
