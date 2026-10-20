// the rendered-markup entry point: the full shell and each named fragment,
// rendered from the shared fixture (a deterministic state with no storage,
// no config reads and no background work).
//
// this is the scanner input for the contract-pin migration: every later-phase
// pin reads bytes through here instead of grepping Views.swift source.
// page() returns the same bytes the server would send.
// fragment(_:) returns "" for an unsupported name on purpose: pins assert on
// content, so an empty string fails loudly, while a crash would fail the whole
// suite opaquely. fatalError is never used here.

@testable import ArcWebUI
import WebUI

enum RenderedMarkup {

    /// the full shell (app div, topbar, iconbar, panel, main, dock, modal
    /// root, toasts) rendered from the shared fixture.
    static func page() async -> String {
        let app = AppState(renderFixture: seededFixture())
        return await app.appShell().markup.html
    }

    /// one fragment by builder name, for a fragment-scoped pin.
    /// supported names: "topbar", "iconbar", "panel", "main", "dock",
    /// "toasts", "modal-root"
    /// unsupported names return "" — deliberate; see the file comment.
    static func fragment(_ name: String) async -> String {
        let app = AppState(renderFixture: seededFixture())
        switch name {
        case "topbar":       return await app.topbarHTML().markup.html
        case "iconbar":      return await app.iconbarHTML().markup.html
        case "panel":        return await app.panelHTML()
        case "main":         return await app.mainContentHTML()
        case "dock":         return await app.workspaceDockHTML()
        case "toasts":       return await app.toastsHTML().markup.html
        case "modal-root":   return await app.modalRootHTML().markup.html
        default:             return ""
        }
    }

    /// a fixture that seeds the fields the bare defaults leave empty, so every
    /// supported fragment actually renders content instead of an empty string.
    /// the page itself stays fully deterministic (fixed ids, fixed dates).
    private static func seededFixture() -> AppState.RenderFixture {
        var fixture = AppState.RenderFixture()
        fixture.toasts = [
            Toast(id: 1, text: "Conversation deleted", kind: "info",
                  action: ToastAction(id: "undo-1", label: "Undo")),
        ]
        fixture.pendingConfirm = ConfirmRequest(
            kind: "chat", id: "sess-a",
            title: "Delete conversation?",
            body: "The chat “Session A” will be deleted. You can undo this for 10 seconds.")
        return fixture
    }
}

// MARK: - control scan (for ClickIdentityContractTests)

extension RenderedMarkup {
    /// every control tag the server can push, paired with the region it came from.
    static func allControls() async -> [(region: String, tag: String)] {
        let app = AppState(renderFixture: seededFixture())
        var results: [(region: String, tag: String)] = []

        results.append(contentsOf: controlTags(in: await app.appShell().markup.html, region: "shell"))
        for kind in ViewID.allCases {
            results.append(contentsOf: controlTags(in: await app.renderPanel(for: kind), region: "panel.\(kind.rawValue)"))
            results.append(contentsOf: controlTags(in: await app.renderMain(for: kind), region: "main.\(kind.rawValue)"))
        }
        results.append(contentsOf: controlTags(in: await app.workspaceDockHTML(), region: "workspace.dock"))
        results.append(contentsOf: controlTags(in: await app.workspacePanelHTML(), region: "workspace.panel"))
        results.append(contentsOf: controlTags(in: await app.workspaceBodyHTML(), region: "workspace.body"))
        results.append(contentsOf: controlTags(in: await app.workspaceTreeHTML(), region: "workspace.tree"))
        results.append(contentsOf: controlTags(in: await app.modalHTML().markup.html, region: "modal"))
        results.append(contentsOf: controlTags(in: await app.categoryMenuHTML().markup.html, region: "category-menu"))
        return results
    }

    /// scan one html string for `<button` / `<input` open tags.
    static func controlTagsInHTMLForTest(_ html: String) -> [String] {
        var out: [String] = []
        for opener in ["<button", "<input"] {
            var search = html.startIndex..<html.endIndex
            while let found = html.range(of: opener, range: search) {
                guard let close = html[found.lowerBound...].firstIndex(of: ">") else { break }
                out.append(String(html[found.lowerBound...close]))
                search = html.index(after: close)..<html.endIndex
            }
        }
        return out
    }

    private static func controlTags(in html: String, region: String) -> [(region: String, tag: String)] {
        var out: [(region: String, tag: String)] = []
        for tag in controlTagsInHTMLForTest(html) {
            out.append((region, tag))
        }
        return out
    }
}

// MARK: - class census (for HostStylesheetContractTests)

extension RenderedMarkup {
    /// every class token emitted by rendered output.
    static func allClasses() async -> [String] {
        let app = AppState(renderFixture: seededFixture())
        var html = await app.appShell().markup.html

        for kind in ViewID.allCases {
            html += await app.renderPanel(for: kind)
            html += await app.renderMain(for: kind)
        }

        html += await app.workspaceDockHTML()
        html += await app.workspacePanelHTML()
        html += await app.workspaceBodyHTML()
        html += await app.workspaceTreeHTML()
        html += await app.modalHTML().markup.html
        html += await app.categoryMenuHTML().markup.html

        return classTokens(in: html)
    }

    /// extract `class="…"` tokens from one html string.
    private static func classTokens(in html: String) -> [String] {
        var tokens: Set<String> = []
        var search = html.startIndex..<html.endIndex
        while let found = html.range(of: "class=\"", range: search) {
            let rest = html[found.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { break }
            let value = rest[..<close]
            for token in value.split(separator: " ") where !token.isEmpty {
                tokens.insert(String(token))
            }
            search = rest.index(after: close)..<html.endIndex
        }
        return tokens.sorted()
    }
}
