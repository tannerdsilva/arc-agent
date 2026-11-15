import Foundation
import Testing
import WebUI

import ArcTheme
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The sheet's own token census: every `var(--token)` the stylesheet paints with must
    /// resolve for **every** scheme and mode the page is served in.
    ///
    /// This is the instrument that replaces a hand-kept second palette. A duplicated copy of
    /// the palette can drift from the catalog silently — that is what the deleted
    /// `:root[data-theme=…]` blocks did — but a token nothing declares cannot paint, and it
    /// fails here instead of on a page. It reads `ThemeSheetAssets.text`, the served bytes
    /// (minified, stamped), so a minifier that ate a declaration fails too.
    ///
    /// Three resolution domains, because a served page has three:
    ///
    ///  * **arc's bare `:root`** — geometry (`--font-size`, `--radius-*`, `--panel-w`, …) and
    ///    the mode-independent fallbacks (only `--warning` today), declared once for the whole
    ///    document. `rootOnlyVocabularyIsNamed` below pins exactly which tokens may live only
    ///    there, so dodging the per-scheme requirement is a decision, not an accident.
    ///  * **the emitted scheme×mode blocks** — `ArcThemeCatalog.stylesheet()` renders every
    ///    scheme as `:root[data-scheme="<id>"][data-theme="<light|system|dark>"]`, plus the
    ///    `system` block inside `@media (prefers-color-scheme: dark)`: 27 × 4 blocks.
    ///  * **the framework sheet**, linked *before* arc's (`AppShell`): its `:root` declares the
    ///    design-system vocabulary arc references without restating (`--font-mono`,
    ///    `--border-width-2`, …). Reading it from `WebUIAssets.css` means the test answers the
    ///    question the browser answers, instead of hardcoding a copy of no-webui's tokens.
    ///
    /// A reference with a fallback (`var(--x, <anything>)`) always paints, so it is not a
    /// defect even when nothing declares `--x`: that is how element-scoped custom properties
    /// (`style="--colc: …"`, `Views.swift`) and deliberate inheritance (`--bg-subtle` in the
    /// markdown table header) are used.
    @Suite("Sheet token resolution", .serialized)
    struct SheetTokenResolutionTests {

        // MARK: - the readers

        /// one css rule: its selector, the at-rule chain it sits under, and its body.
        struct Rule {
            let atRules: [String]
            let selector: String
            let body: String

            /// how a failure names the rule that uses a token.
            var label: String {
                atRules.isEmpty ? selector : "\(atRules.joined(separator: " > ")) { \(selector) }"
            }
        }

        /// one `var(--token)` reference, and whether it carries a fallback.
        struct Reference {
            let token: String
            let hasFallback: Bool
        }

        /// the declarations of one theme block.
        struct ThemeBlock {
            let scheme: String
            let mode: String
            /// true for the block inside `@media (prefers-color-scheme: dark)`.
            let inDarkMediaPass: Bool
            let declarations: [String: String]

            var label: String { "\(scheme)/\(mode)\(inDarkMediaPass ? " (dark media pass)" : "")" }
        }

        /// every rule in `css`, with `@media`/`@layer`/`@keyframes` bodies flattened and the
        /// at-rule chain kept as a label. A css parser only in the sense the assertion needs:
        /// selectors, bodies, declarations, references.
        static func rules(_ css: String, atRules: [String] = []) -> [Rule] {
            var out: [Rule] = []
            var index = css.startIndex
            var selectorStart = css.startIndex
            while index < css.endIndex {
                switch css[index] {
                case "{":
                    let selector = String(css[selectorStart..<index])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    var depth = 0
                    var cursor = index
                    var close = css.endIndex
                    while cursor < css.endIndex {
                        if css[cursor] == "{" { depth += 1 }
                        if css[cursor] == "}" {
                            depth -= 1
                            if depth == 0 { close = cursor; break }
                        }
                        cursor = css.index(after: cursor)
                    }
                    guard close < css.endIndex else { return out }
                    let body = String(css[css.index(after: index)..<close])
                    if selector.hasPrefix("@") {
                        out += rules(body, atRules: atRules + [selector])
                    } else {
                        out.append(Rule(atRules: atRules, selector: selector, body: body))
                    }
                    index = css.index(after: close)
                    selectorStart = index
                case "}", ";":
                    index = css.index(after: index)
                    selectorStart = index
                default:
                    index = css.index(after: index)
                }
            }
            return out
        }

        /// the `--name: value` declarations of a rule body.
        static func declarations(_ body: String) -> [String: String] {
            var out: [String: String] = [:]
            for piece in body.split(separator: ";") {
                guard let colon = piece.firstIndex(of: ":") else { continue }
                let name = String(piece[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.hasPrefix("--") else { continue }
                out[name] = String(piece[piece.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return out
        }

        /// every `var(--token)` in a body, with its fallback state.
        static func references(in body: String) -> [Reference] {
            var out: [Reference] = []
            var index = body.startIndex
            while let found = body.range(of: "var(", range: index..<body.endIndex) {
                var cursor = found.upperBound
                while cursor < body.endIndex, body[cursor] == " " {
                    cursor = body.index(after: cursor)
                }
                guard cursor < body.endIndex, body[cursor] == "-" else {
                    index = found.upperBound
                    continue
                }
                let nameStart = cursor
                while cursor < body.endIndex,
                    body[cursor].isLetter || body[cursor].isNumber || body[cursor] == "-"
                {
                    cursor = body.index(after: cursor)
                }
                let token = String(body[nameStart..<cursor])
                // a comma at paren depth 1 is the fallback separator.
                var depth = 1
                var hasFallback = false
                var scan = cursor
                while scan < body.endIndex, depth > 0 {
                    switch body[scan] {
                    case "(": depth += 1
                    case ")": depth -= 1
                    case "," where depth == 1: hasFallback = true
                    default: break
                    }
                    scan = body.index(after: scan)
                }
                out.append(Reference(token: token, hasFallback: hasFallback))
                index = scan
            }
            return out
        }

        /// `:root[data-scheme="<id>"][data-theme="<mode>"]` → (id, mode); nil for any other
        /// selector (arc's `:root`, a paint rule, the framework sheet's `:root`).
        static func themeBlock(selector: String) -> (scheme: String, mode: String)? {
            let prefix = ":root[data-scheme=\""
            guard selector.hasPrefix(prefix), selector.hasSuffix("\"]") else { return nil }
            guard let separator = selector.range(of: "\"][data-theme=\"") else { return nil }
            let id = selector[selector.index(selector.startIndex, offsetBy: prefix.count)..<separator.lowerBound]
            let mode = selector[separator.upperBound...].dropLast(2)
            return (String(id), String(mode))
        }

        // MARK: - the fixtures

        /// the served sheet: arc's chrome + the catalog's scheme blocks, minified and stamped
        /// by the build-time asset tool.
        static var sheet: String { ThemeSheetAssets.text }

        /// the framework sheet `AppShell` links before arc's.
        static var frameworkSheet: String { WebUIAssets.css }

        static func allThemeBlocks() -> [ThemeBlock] {
            rules(sheet).compactMap { rule in
                guard let (scheme, mode) = themeBlock(selector: rule.selector) else { return nil }
                return ThemeBlock(
                    scheme: scheme,
                    mode: mode,
                    inDarkMediaPass: rule.atRules.contains { $0.hasPrefix("@media") },
                    declarations: declarations(rule.body)
                )
            }
        }

        /// the tokens the bare `:root` declares — `:root` only, no attributes, any at-rule.
        static func rootDeclarations(_ css: String) -> [String: String] {
            var out: [String: String] = [:]
            for rule in rules(css) where rule.selector == ":root" {
                out.merge(declarations(rule.body)) { _, later in later }
            }
            return out
        }

        /// The sheet's own tokens that nothing has ever declared. Named, sized, and pinned by
        /// `unresolvedTokensAreExactlyTheKnownOnes` below: a *new* unresolved token fails, a new
        /// *use* of one of these fails, and fixing one fails until its row is deleted. They are
        /// pre-existing (predate this slice) and fixing them means choosing a paint this slice
        /// does not own — every one is a token whose rule already paints *something* because the
        /// property is not declared at all (an inherited colour, a transparent background).
        static let knownUnresolved: [String: Int] = [
            // `.kb-col-head` and the queue chip's tint: no fallback, no declaration, renders
            // transparent. `--bg-subtle` is a design-system name that no-webui never shipped.
            "--bg-subtle": 2,
            // `.live-tool-row .lt-name`: resolves to the inherited text colour today.
            "--fg": 1,
            // `.tw-copy:hover`: resolves to no background today.
            "--surface-1": 1,
        ]

        /// the tokens that may live only in the bare `:root`: geometry, plus the one
        /// mode-independent ink the catalog deliberately leaves to the base sheet.
        static let rootOnlyVocabulary: Set<String> = [
            "--chat-measure", "--font-size", "--iconbar-w", "--panel-w",
            "--radius-lg", "--radius-md", "--radius-sm",
            "--warning",
        ]

        // MARK: - the assertions

        @Test("the sheet carries every scheme in all four served blocks")
        func sheetCarriesTheWholeMatrix() {
            let blocks = Self.allThemeBlocks()
            let ids = blocks.map(\.scheme)
            let expected = Set(ArcThemeCatalog.entries.map(\.id))

            #expect(Set(ids) == expected, "schemes emitted: \(Set(ids).sorted()); catalog: \(expected.sorted())")
            #expect(
                blocks.count == expected.count * 4,
                "\(blocks.count) theme blocks for \(expected.count) schemes — light, system, dark and the system block in the dark media pass are four"
            )
            for id in expected.sorted() {
                let mine = blocks.filter { $0.scheme == id }
                #expect(mine.filter { $0.mode == "light" }.count == 1, "\(id): one light block")
                #expect(mine.filter { $0.mode == "dark" }.count == 1, "\(id): one dark block")
                #expect(mine.filter { $0.mode == "system" }.count == 2, "\(id): two system blocks (literal + dark media pass)")
                #expect(
                    mine.filter { $0.mode == "system" && $0.inDarkMediaPass }.count == 1,
                    "\(id): the second system block is inside @media (prefers-color-scheme: dark)"
                )
            }
        }

        @Test("every var(--token) the sheet paints with resolves for every scheme")
        func everyReferenceResolves() {
            let sheetRules = Self.rules(Self.sheet)
            let blocks = Self.allThemeBlocks()
            let arcRoot = Self.rootDeclarations(Self.sheet)
            let frameworkRoot = Self.rootDeclarations(Self.frameworkSheet)

            /// token → the rules that use it without a fallback and the blocks that lack it.
            var unresolved: [String: (rules: Set<String>, missingBlocks: Set<String>)] = [:]

            for rule in sheetRules {
                // a theme block's own references are the alias indirections, checked below.
                if Self.themeBlock(selector: rule.selector) != nil { continue }
                for reference in Self.references(in: rule.body) where !reference.hasFallback {
                    let token = reference.token
                    if arcRoot[token] != nil { continue }
                    if frameworkRoot[token] != nil { continue }
                    let missing = blocks.filter { $0.declarations[token] == nil }
                    if missing.isEmpty { continue }
                    var entry = unresolved[token] ?? (rules: [], missingBlocks: [])
                    entry.rules.insert(rule.label)
                    for block in missing { entry.missingBlocks.insert(block.label) }
                    unresolved[token] = entry
                }
            }

            // one failure line per unresolved token, naming the token and the rule that uses it.
            // the named baseline below is exempt: those three are pre-existing, and the ratchet
            // assertion is what keeps them from growing.
            for token in unresolved.keys.sorted() where Self.knownUnresolved[token] == nil {
                let entry = unresolved[token]!
                let uses = entry.rules.sorted()
                let shown = uses.prefix(3).joined(separator: ", ")
                let more = uses.count > 3 ? " (+\(uses.count - 3) more)" : ""
                let sample = entry.missingBlocks.sorted().prefix(3).joined(separator: ", ")
                Issue.record(
                    "\(token): used by \(shown)\(more) — declared by neither :root nor the framework sheet, and \(entry.missingBlocks.count) of \(blocks.count) scheme×mode blocks lack it (\(sample)…)"
                )
            }

            let observed = unresolved.mapValues { $0.rules.count }
            if !observed.isEmpty {
                print(
                    "known-unresolved tokens (named, not fixed here): "
                        + observed.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
                        .joined(separator: ", "))
            }
            let appeared = Set(observed.keys).subtracting(Self.knownUnresolved.keys).sorted()
            let vanished = Set(Self.knownUnresolved.keys).subtracting(observed.keys).sorted()
            let reused = Set(observed.keys).intersection(Self.knownUnresolved.keys)
                .filter { observed[$0] != Self.knownUnresolved[$0] }.sorted()
            #expect(
                appeared.isEmpty && vanished.isEmpty && reused.isEmpty,
                "unresolved-token baseline moved — new: \(appeared); fixed (delete the row): \(vanished); new uses of a known one: \(reused)"
            )
        }

        @Test("every var(--token) a scheme block declares resolves inside that block")
        func aliasIndirectionsResolveInTheirBlock() {
            let blocks = Self.allThemeBlocks()
            let arcRoot = Self.rootDeclarations(Self.sheet)
            let frameworkRoot = Self.rootDeclarations(Self.frameworkSheet)

            var failures: [String] = []
            for block in blocks {
                for reference in Self.references(in: block.declarations.values.joined(separator: ";"))
                where !reference.hasFallback {
                    let token = reference.token
                    if block.declarations[token] != nil { continue }
                    if arcRoot[token] != nil || frameworkRoot[token] != nil { continue }
                    failures.append("\(block.label): \(token)")
                }
            }
            #expect(
                failures.isEmpty,
                "\(failures.count) alias indirection(s) resolve to nothing: \(failures.prefix(6).joined(separator: "; "))"
            )
        }

        @Test("only named tokens live in the bare :root")
        func rootOnlyVocabularyIsNamed() {
            let blocks = Self.allThemeBlocks()
            let arcRoot = Self.rootDeclarations(Self.sheet)
            var rootOnly: Set<String> = []
            for rule in Self.rules(Self.sheet) {
                if Self.themeBlock(selector: rule.selector) != nil { continue }
                for reference in Self.references(in: rule.body) where !reference.hasFallback {
                    let token = reference.token
                    guard arcRoot[token] != nil else { continue }
                    if blocks.allSatisfy({ $0.declarations[token] != nil }) { continue }
                    rootOnly.insert(token)
                }
            }
            #expect(
                rootOnly == Self.rootOnlyVocabulary,
                ":root-only tokens are \(rootOnly.sorted()) — a token declared only there is a second palette for every scheme that does not state it; add it to the catalog, or name it in rootOnlyVocabulary with the reason it is mode-independent"
            )
        }
    }
}
