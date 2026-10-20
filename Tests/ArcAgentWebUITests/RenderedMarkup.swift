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
