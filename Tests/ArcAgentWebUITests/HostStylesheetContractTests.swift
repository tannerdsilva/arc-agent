import Foundation
import Testing

import ArcTheme
import WebUIDesignSystem
@testable import arc_agent_webui

/// The host stylesheet contract (ARC-5): a served page must link every stylesheet its
/// markup depends on, and arc's own sheet must come *after* the framework's.
///
/// The failure this pins, measured on the shipped page before the fix: 55 of 233
/// framework icons at 240 px (and one at 718 px) plus a permanently visible
/// "reconnecting…" chip, because the page linked only arc's own sheet. `makeDocument` is
/// the production seam — these tests render through it, not a replica of it.
@Suite("Host stylesheet contract")
struct HostStylesheetContractTests {

    /// The page template, rendered with stamped-asset-shaped urls and a themed `<html>`.
    private static func renderedPage(body: String = "") -> String {
        ArcAgentWebUI.makeDocument(
            sheetURL: "/ui/style.css?v=abc123",
            overlayURL: "/ui/init.js?v=def456"
        )(body, "data-scheme=\"poseidon\" data-theme=\"dark\"").render()
    }

    @Test("the frame document links the framework component sheet and arc's sheet, in that order")
    func sheetsAreLinkedInOrder() throws {
        let html = Self.renderedPage()
        let framework = DesignSystemAssets.stylesheetURL
        let arc = "/ui/style.css?v=abc123"

        let frameworkRange = try #require(
            html.range(of: framework), "the framework component sheet is not linked"
        )
        let arcRange = try #require(html.range(of: arc), "arc's own sheet is not linked")
        // later source order, same specificity: arc's `:root` tokens and its like-named
        // classes must win the collisions (see the fix). if this order flips, arc's radii
        // silently shrink.
        #expect(
            frameworkRange.lowerBound < arcRange.lowerBound,
            "arc's sheet must be linked after the framework's"
        )
        // the overlay script still rides the head slot
        #expect(html.contains("<script src=\"/ui/init.js?v=def456\"></script>"))
    }

    @Test("a class no sheet defines fails the guardrail on this page")
    func strayClassIsCaught() {
        // the framework's own validator, wired to the page arc actually serves: this is
        // what makes the old "nothing in arc's tests can notice" (ARC-5) false.
        let html = Self.renderedPage(body: "<div class=\"totally-bogus-arc-42\">x</div>")
        let arcSheet = HTMLClassValidator.definedClasses(css: ThemeSheetAssets.text)
        let undefined = HTMLClassValidator.undefinedClasses(in: html, extra: arcSheet)
        #expect(undefined == ["totally-bogus-arc-42"], "undefined classes: \(undefined)")
    }

    // MARK: - ARC-3 debt / markup census

    /// class tokens arc's own markup strings emit that neither sheet defines. ARC-3's
    /// audit found these on the live DOM: leftovers from removed features, hooks kept
    /// only for a js selector, or styling never written. They render acceptably today
    /// (the unstyled default happens to be fine) — which is exactly the failure mode the
    /// framework sheet's absence shared, one layer down.
    ///
    /// every entry is pinned here so a **new** stray fails this test instead of rendering
    /// silently unstyled. shrinking this set is ARC-3's cleanup task (one commit per
    /// group); growing it is a regression.
    private static let documentedDeadClasses: Set<String> = [
        "approval-title", "arch-ico", "btn", "chat-menu-items", "clarify-title",
        "color-value", "ctx-swatches", "dd-list-profile", "gh-refs", "iconbar-top",
        "ins-more-row", "insights-main", "msg-copy-btn", "outline-toggle-btn", "panel-note",
        "pill-other", "queue-card", "queue-loop-count-label", "result__a",
        "result__snippet", "skill-cat-title", "task-ctrl-main", "thinking-detail",
        "todo-list", "token", "ws-head", "ws-menu", "yolo-text",
    ]

    /// every complete (non-interpolated) class token written into a `class="…"` attribute
    /// by arc's own markup strings. an interpolated value (`class="panel--\(state)"`) is
    /// dropped whole: a prefix can never be looked up in a sheet, and guessing it would
    /// make this census lie.
    ///
    /// the scan reads markup, not prose: `//` comments are stripped (a comment mentioning
    /// `class="language-…"` is not an emitter — Views.swift carries exactly that line),
    /// and a token must be identifier-safe, which every real class name is by construction.
    /// both filters make the census a floor: it can fail to see a stray, it never invents one.
    private static func isIdentifierSafe(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter || first == "_" else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// the token extraction itself, over one source text (pure, so the scanner can be
    /// pinned by a synthetic sample instead of trusted).
    static func classTokens(in text: String) -> [String] {
        let scanned = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")
        var tokens = Set<String>()
        var search = scanned[...]
        while let found = search.range(of: "class=\"") {
            let rest = search[found.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { break }
            let value = rest[..<close]
            if !value.contains("\\") {
                for token in value.split(separator: " ") where !token.hasSuffix("-") {
                    if isIdentifierSafe(String(token)) {
                        tokens.insert(String(token))
                    }
                }
            }
            search = rest[close...]
        }
        return tokens.sorted()
    }

    private static func markupClassTokens() throws -> [String] {
        let root = "Sources/ArcAgentWebUI"
        var tokens = Set<String>()
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        for case let path as String in walker where path.hasSuffix(".swift") {
            let text = (try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8)) ?? ""
            tokens.formUnion(Self.classTokens(in: text))
        }
        return tokens.sorted()
    }

    @Test("the census scanner sees markup and ignores prose (its own precondition)")
    func scannerSelfCheck() {
        // a probe that can silently see nothing is not a probe. this pins the extraction
        // against the four shapes arc actually writes.
        let sample = """
        let a = #"<div class="lr-name icon--sm">"#
        // a comment mentioning class="language-…" is not an emitter
        let b = "<span class=\\"panel--\\(state)\\">"
        let c = "<b class='single-quoted-is-not-scanned'>"
        """
        let tokens = Self.classTokens(in: sample)
        #expect(tokens.contains("lr-name"))
        #expect(tokens.contains("icon--sm"))
        #expect(!tokens.contains { $0.hasPrefix("panel--") }, "an interpolated value must be dropped whole")
        #expect(!tokens.contains("language-…"), "comment prose must not reach the census")
        #expect(!tokens.contains("single-quoted-is-not-scanned"), "the scanner anchors on class=\\\" only")
    }

    @Test("no new undefined classes in arc's own markup strings")
    func markupCensus() throws {
        let tokens = try Self.markupClassTokens()
        #expect(!tokens.isEmpty, "the census found no markup strings — the scan is broken, not the markup")
        let html = tokens.map { "class=\"\($0)\"" }.joined(separator: " ")
        let arcSheet = HTMLClassValidator.definedClasses(css: ThemeSheetAssets.text)
        let undefined = HTMLClassValidator.undefinedClasses(in: html, extra: arcSheet)
        let unexpected = Set(undefined).subtracting(Self.documentedDeadClasses)
        #expect(
            unexpected.isEmpty,
            """
            markup strings emit classes that neither sheet defines — give each one a rule \
            or drop it from the markup (documented ARC-3 debt lives in this file):
            \(unexpected.sorted().joined(separator: "\n"))
            """
        )
    }
}