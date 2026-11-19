import Testing
// `WebUIIslandWire` re-exports the framework's Foundation-free leaf
// (`@_exported import WebUISharedCore`), so `htmlEscape` is reachable here
// without a second package dependency.
import WebUIIslandWire

/// HTML escaping, pinned to the framework's single implementation (F4 / Task
/// 1.3).
///
/// arc used to carry a second `htmlEscape` in
/// `ArcAgentCore/WebUI/Utilities.swift`. Its only consumers were its own five
/// internal uses in that file and one unit test in `ArcAgentCoreTests.swift`:
/// every `ArcWebUI` call site already bound the framework's through
/// `WebUI` → `WebUICore` → `WebUISharedCore`, all `@_exported`.
///
/// Phase A of the consolidation asserts this table against arc's copy, with
/// only `ArcAgentCore` imported. Phase B changes the import to the framework's
/// carrier and deletes arc's function: the literals do not move, so two green
/// runs prove the two implementations byte-identical rather than assumed.
@Suite("HTML escape")
struct HTMLEscapeTests {
    /// Inputs chosen so the two implementations cannot silently diverge: each
    /// of the five special characters alone, all five together, already-escaped
    /// and partial entity text (the double-escaping trap), the empty string, a
    /// lone ampersand in prose, multi-scalar graphemes (ZWJ emoji, combining
    /// marks) that must pass through untouched, whitespace controls, and a
    /// 200-character mixed payload.
    static let cases: [(input: String, expected: String)] = [
        ("&", "&amp;"),
        ("<", "&lt;"),
        (">", "&gt;"),
        ("\"", "&quot;"),
        ("'", "&#39;"),
        ("&<>\"'", "&amp;&lt;&gt;&quot;&#39;"),
        ("&amp;lt;", "&amp;amp;lt;"),
        ("&amp", "&amp;amp"),
        ("", ""),
        ("a & b", "a &amp; b"),
        ("👩‍👩‍👧‍👦🚀", "👩‍👩‍👧‍👦🚀"),
        ("e\u{0301}a\u{0308}", "e\u{0301}a\u{0308}"),
        ("line1\nline2\ttab", "line1\nline2\ttab"),
        (
            String(repeating: "a&<>\"'", count: 33) + "ab",
            String(repeating: "a&amp;&lt;&gt;&quot;&#39;", count: 33) + "ab"
        ),
    ]

    @Test("escaping spelling is pinned input for input")
    func goldenSpelling() {
        for (input, expected) in HTMLEscapeTests.cases {
            #expect(htmlEscape(input) == expected, "input: \(input.debugDescription)")
        }
    }
}
