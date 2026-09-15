import Foundation
import Testing
@testable import ArcAgentCore

// Hermes-parity markdown coverage: mirrors the Hermes WebUI's smd feature set
// (tables, blockquotes, nested lists, task checkboxes, strike, images,
// autolinks, math) plus the baseline behavior (headings, lists, emphasis,
// code spans, links, raw-HTML escaping, paragraphs).
@Suite("Markdown Hermes Parity")
struct MarkdownParityTests {

    // MARK: Baseline (pre-existing behavior, locked in)

    @Test("headings render atx levels and clamp above h6")
    func headings() {
        #expect(markdownToHTML("# Title") == "<h1>Title</h1>")
        #expect(markdownToHTML("###### Deep") == "<h6>Deep</h6>")
        #expect(markdownToHTML("####### Clamped") == "<h6>Clamped</h6>")
    }

    @Test("lists render from markup and numbered markers")
    func lists() {
        #expect(markdownToHTML("- a\n- b") == "<ul><li>a</li><li>b</li></ul>")
        #expect(markdownToHTML("* a\n* b") == "<ul><li>a</li><li>b</li></ul>")
        #expect(markdownToHTML("1. a\n2. b") == "<ol><li>a</li><li>b</li></ol>")
    }

    @Test("bold and emphasis wrap balanced delimiters")
    func inlineEmphasis() {
        #expect(markdownToHTML("hi **bold**") == "<p>hi <strong>bold</strong></p>")
        #expect(markdownToHTML("hi *em*") == "<p>hi <em>em</em></p>")
    }

    @Test("unpaired delimiters render literally")
    func unpairedDelimiters() {
        #expect(markdownToHTML("a ** b") == "<p>a ** b</p>")
        #expect(markdownToHTML("a *** b") == "<p>a *** b</p>")
    }

    @Test("code spans are never parsed for emphasis")
    func codeSpansProtectContent() {
        #expect(markdownToHTML("`**not bold**`") == "<p><code>**not bold**</code></p>")
    }

    @Test("links render safe targets and keep unsafe ones literal")
    func links() {
        #expect(markdownToHTML("[x](https://example.com)") == "<p><a href=\"https://example.com\">x</a></p>")
        #expect(markdownToHTML("[x](javascript:alert(1))") == "<p>[x](javascript:alert(1))</p>")
        #expect(markdownToHTML("[x]( java\tscript:alert(1))") == "<p>[x]( java\tscript:alert(1))</p>")
    }

    @Test("raw html in markdown is escaped, never emitted")
    func rawHTMLEscaped() {
        let html = markdownToHTML("<script>alert(1)</script>")
        #expect(html == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
        #expect(!html.contains("<script>"))
    }

    @Test("paragraphs join non-empty lines")
    func paragraphs() {
        #expect(markdownToHTML("one\n\ntwo") == "<p>one</p>\n<p>two</p>")
    }

    // MARK: Hermes parity additions

    @Test("pipe tables render header + body")
    func tables() {
        let html = markdownToHTML("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(html.contains("<table>"))
        #expect(html.contains("<thead>"))
        #expect(html.contains("<tr><th>a</th><th>b</th></tr>"))
        #expect(html.contains("<tr><td>1</td><td>2</td></tr>"))
        #expect(html.contains("<tbody>"))
    }

    @Test("table works without outer pipes")
    func tablesBare() {
        let html = markdownToHTML("a | b\n--|--\n1 | 2")
        #expect(html.contains("<th>a</th>"))
        #expect(html.contains("<td>1</td>"))
    }

    @Test("blockquotes wrap nested content")
    func blockquote() {
        let html = markdownToHTML("> quote line\n> second")
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("quote line"))
    }

    @Test("nested blockquotes nest tags")
    func nestedBlockquote() {
        let html = markdownToHTML("> outer\n>> inner")
        #expect(html.components(separatedBy: "<blockquote>").count == 3)
    }

    @Test("horizontal rules")
    func hr() {
        #expect(markdownToHTML("---") == "<hr>")
        #expect(markdownToHTML("***") == "<hr>")
        #expect(markdownToHTML("___") == "<hr>")
    }

    @Test("task list checkboxes")
    func taskList() {
        let html = markdownToHTML("- [ ] todo\n- [x] done")
        #expect(html.contains("<input type=\"checkbox\" disabled>"))
        #expect(html.contains("<input type=\"checkbox\" disabled checked>"))
        #expect(html.contains("<ul>"))
    }

    @Test("nested lists nest under the parent item")
    func nestedList() {
        let html = markdownToHTML("- a\n  - a1\n  - a2\n- b")
        #expect(html.contains("<li>a\n<ul><li>a1</li><li>a2</li></ul></li>"))
        #expect(html.hasPrefix("<ul>"))
    }

    @Test("strikethrough")
    func strike() {
        #expect(markdownToHTML("~~gone~~") == "<p><s>gone</s></p>")
    }

    @Test("images render sanitized")
    func images() {
        #expect(markdownToHTML("![alt](https://example.com/x.png)") == "<p><img src=\"https://example.com/x.png\" alt=\"alt\"></p>")
        #expect(markdownToHTML("![x](javascript:alert(1))").contains("![x](javascript:alert(1))"))
    }

    @Test("bare http urls autolink")
    func autolink() {
        let html = markdownToHTML("see https://example.com/page now")
        #expect(html.contains("<a href=\"https://example.com/page\">https://example.com/page</a>"))
    }

    @Test("autolink does not touch link targets")
    func autolinkSkipsLinkTargets() {
        #expect(markdownToHTML("[x](https://example.com)") == "<p><a href=\"https://example.com\">x</a></p>")
    }

    @Test("inline math emits equation-inline")
    func inlineMath() {
        #expect(markdownToHTML("e = $mc^2$ done").contains("<equation-inline>mc^2</equation-inline>"))
    }

    @Test("display math emits equation-block")
    func blockMath() {
        #expect(markdownToHTML("$$x^2 + y^2$$") == "<equation-block>x^2 + y^2</equation-block>")
        #expect(markdownToHTML("$$\nx^2\n$$").contains("<equation-block>"))
    }

    @Test("backslash paren math")
    func parenMath() {
        #expect(markdownToHTML("\\(a+b\\)").contains("<equation-inline>a+b</equation-inline>"))
    }

    @Test("underscore emphasis respects word boundaries")
    func underscoreGuard() {
        #expect(markdownToHTML("_em_") == "<p><em>em</em></p>")
        #expect(markdownToHTML("snake_case") == "<p>snake_case</p>")
    }

    @Test("hard line breaks")
    func hardBreaks() {
        #expect(markdownToHTML("line one  \nline two").contains("line one<br>line two"))
    }

    @Test("soft line breaks join with a space")
    func softBreaks() {
        #expect(markdownToHTML("one\ntwo") == "<p>one two</p>")
    }

    @Test("raw br passthrough is allowed")
    func rawBr() {
        #expect(markdownToHTML("a<br>b") == "<p>a<br>b</p>")
        #expect(markdownToHTML("a<br/>b") == "<p>a<br>b</p>")
    }

    @Test("blockquote containing a list does not spin")
    func quoteList() {
        let html = markdownToHTML("> - a\n> - b")
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<ul><li>a</li><li>b</li></ul>"))
    }

    @Test("indented list start does not spin")
    func indentedListStart() {
        #expect(markdownToHTML("  - a\n  - b") == "<ul><li>a</li><li>b</li></ul>")
    }

    @Test("math source is html-escaped in transit")
    func mathEscaped() {
        let html = markdownToHTML("$a < b$")
        #expect(html.contains("a &lt; b"))
        #expect(!html.contains("<equation-inline>a < b"))
    }
}
