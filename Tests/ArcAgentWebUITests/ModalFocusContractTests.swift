import Foundation
import Testing
import WebUI

import ArcAgentCore
@testable import ArcWebUI

// why the confirmation dialog's focus is the ENGINE's now, pinned from both
// sides, in-process, so the justification can never quietly rot back into the
// claim it replaced.
//
// no-webui 2.14.0 ships focus return BY ID (`data-focus-return`) and arc states
// the whole contract as two attributes instead of keeping a client block. the
// attribute is a declaration on BOTH ends of one round trip:
//  - the opener names the dialog it opens (`data-focus-return="modal-overlay"`),
//    which the engine's `noteOpener` records in `openerMemo` from a
//    document-level click / Enter / Space listener;
//  - the dialog's close control names the control focus goes back to
//    (`data-focus-return="<opener id>"`), and the patch funnel's `capture`
//    records every `[data-focus-return]` holder id — so the close control's own
//    removal by the closing patch is what makes `restoreRemovedOpener` focus
//    `openerMemo[<removed control id>]`, i.e. the opener, re-queried by id
//    after the patch replaced it.
// entry is `FocusInto(id:)` on the dialog's region ROOT (no-webui 3.1.0, A16d):
// the dialog is inserted by a patch and the binder focuses the named control
// when live focus is vacant or outside the region — the first open AND every
// later one, unlike `autofocus`'s once-per-document flush (F3). The engine's
// `.modal-overlay` keydown trap then keeps Tab inside the card, and Escape
// still fires the layer's `[data-dismiss]` control.
//
// half (a) pins the engine capabilities arc leans on, so an engine that drops
// one makes arc's emissions visibly orphaned instead of silently dead. half (b)
// pins the emissions on RENDERED bytes — what the server actually serves — and
// the absence of a SECOND implementation in the served overlay. the five names
// that absence pins are the deleted block's; a capability that genuinely needs
// client focus code again arrives under a new name with its own pin, because
// restoring one of these five is restoring the duplicate the engine replaced.
//
// both read what the daemon serves — `WebUIAssets.engine` and
// `AppShell.Assets.overlay.bytes` as /ui/init.js — never the sources on disk,
// so an embed that stopped tracking its source cannot leave these green.
extension ArcWebUITestRoot {

    @Suite("Modal focus", .serialized)
    struct ModalFocusContractTests {

        /// the engine as the daemon serves it, not the checkout under
        /// `.build/checkouts`.
        private static var engine: String { WebUIAssets.engine }

        /// the open tag carrying `id`, or nil. the leading space in the
        /// pattern keeps `data-component-id="x"` from answering for `id="x"`.
        static func openTag(_ html: String, id: String) -> String? {
            guard let r = html.range(of: "<[a-z]+[^>]* id=\"\(id)\"[^>]*>",
                                     options: .regularExpression) else { return nil }
            return String(html[r])
        }

        @Test("the served engine returns focus by id and traps Tab in .modal-overlay")
        func engineCarriesFocusReturnAndTheTrap() {
            let js = Self.engine
            #expect(
                js.contains("function noteOpener(target) {"),
                "the engine no longer records an opener — `data-focus-return` on a trigger is then inert"
            )
            #expect(
                js.contains("openerMemo[el.id] = el.getAttribute('data-focus-return') || el.id;"),
                "the engine no longer key its opener memo by element id — a patch-replaced trigger could not be re-queried"
            )
            #expect(
                js.contains("function restoreRemovedOpener() {"),
                "the engine no longer restores focus when the control that declared the return is removed — the dialog's close is then a dead end"
            )
            #expect(
                js.contains("focusMemo = decl ? { active: active, target: decl.getAttribute('data-focus-return') || decl.id } : null;"),
                "the engine no longer captures the focused control's `data-focus-return` region — T26 is then unowned on both sides"
            )
            #expect(
                js.contains("if (e.key !== 'Tab') return;") &&
                    js.contains("var modal = e.target.closest('.modal-overlay');"),
                "the .modal-overlay Tab trap is gone from the engine — arc keeps no trap of its own, so Tab would leave the card"
            )
            #expect(
                js.contains("function restoreModalFocus() {") && js.contains("modalFocus = from"),
                "the engine no longer captures the modal opener on focusout — the raw-reference half of its restore is gone"
            )
            #expect(
                js.contains("var opener = modalFocus;") && js.contains("opener.focus()"),
                "the engine no longer restores through its captured element — re-derive why arc's ids exist"
            )
        }

        @Test("Cancel names the opener that opened the dialog, autofocuses and dismisses")
        func cancelNamesItsOpener() async {
            // a workspace delete: the opener is a rendered control we can read
            // in the same fixture, so both ends of the round trip are pinned on
            // the bytes the server sends.
            var fixture = AppState.RenderFixture()
            fixture.settings.workspaces = [
                WorkspaceEntry(name: "main", path: WorkspaceEntry.defaultPath(for: "main")),
                WorkspaceEntry(name: "research", path: "/tmp/research"),
            ]
            fixture.pendingConfirm = ConfirmRequest(
                kind: "workspace", id: "research",
                title: "Delete workspace?",
                body: "The workspace “research” will be removed from the list. Files on disk are left alone.")

            let app = AppState(renderFixture: fixture)
            let openerID = "ws-del-\(enc("research"))"
            let panel = await app.workspacesPanel().markup.html
            let opener = Self.openTag(panel, id: openerID)
            #expect(opener?.contains("data-focus-return=\"modal-overlay\"") == true,
                    "the workspace ✕ must name the dialog it opens (`data-focus-return=\"modal-overlay\"`); without it the engine records no opener and the round trip is one-way")

            let html = await app.modalHTML().markup.html
            let cancel = Self.openTag(html, id: "modal-cancel")
            #expect(cancel != nil, "the dialog's Cancel did not render")
            #expect(cancel?.contains("data-focus-return=\"\(openerID)\"") == true,
                    "Cancel must name the control focus returns to — here the workspace ✕ (`data-focus-return=\"\(openerID)\"`). a bare opener id or a `modal-overlay` value leaves focus on <body> after the close patch")
            #expect(cancel?.contains("autofocus") == false,
                    "Cancel must NOT carry `autofocus`: it fires once per document, so the second open would leave focus on the opener (A12 row (f))")
            let overlay = Self.openTag(html, id: "modal-overlay")
            #expect(overlay?.contains("data-focus-into=\"modal-cancel\"") == true,
                    "the dialog's region root must declare `data-focus-into=\"modal-cancel\"` — 3.1.0's entry path, first and every later open")
            #expect(cancel?.contains("tabindex=") == false,
                    "Cancel must NOT state a tabindex: it is a native `button`. no-webui 3.1.1's `FocusInto` leaves an intrinsically focusable target alone, so the dialog's only tab stop survives without arc's help — a `0` here is a redundant second statement (the 3.1.0 workaround this pin removed), and a `-1` would drop the dialog's only tab stop")
            #expect(cancel?.contains("data-dismiss") == true,
                    "Cancel must stay the layer's `[data-dismiss]` control — the engine's Escape fires it, and Delete must never be the one Escape presses")
            #expect(Self.openTag(html, id: "modal-confirm")?.contains("data-focus-return") == false,
                    "Delete must not declare a focus return: the dialog's removal is what returns focus, and a second declaration on the confirming control would target a row that no longer exists")
        }

        @Test("every opener that names its dialog carries the declaration")
        func everyOpenerNamesItsDialog() async {
            // one surface per opener kind: the declaration is per control, so a
            // kind that stops emitting it is a silent one-way dialog, and the
            // failure must name the surface.
            func row(_ surface: String, _ html: String, _ id: String) -> (String, String, String?) {
                let tag = Self.openTag(html, id: id)
                #expect(tag?.contains("data-focus-return=\"modal-overlay\"") == true,
                        "\(surface): `#\(id)` must carry `data-focus-return=\"modal-overlay\"` — the opener names the dialog it opens, and the engine's opener memo is empty without it")
                return (surface, id, tag)
            }

            var chatFixture = AppState.RenderFixture()
            chatFixture.sessions = [
                Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat A",
                        messageCount: 2, messages: [Message(role: .user, content: "hi")]),
                Session(id: "sess-empty-1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "New chat",
                        messageCount: 0, messages: []),
                Session(id: "sess-empty-2", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "New chat",
                        messageCount: 0, messages: []),
            ]
            chatFixture.activeSessionID = "sess-a"
            let chatApp = AppState(renderFixture: chatFixture)
            let panel = await chatApp.chatPanel().markup.html
            _ = row("the chat list's row menu", panel, "sm-del-\(enc("sess-a"))")
            _ = row("the chat list's empty-draft cleanup", panel, "chat-clear-empty")

            var wsFixture = AppState.RenderFixture()
            wsFixture.settings.workspaces = [
                WorkspaceEntry(name: "main", path: WorkspaceEntry.defaultPath(for: "main")),
                WorkspaceEntry(name: "research", path: "/tmp/research"),
            ]
            _ = row("the workspaces panel", await AppState(renderFixture: wsFixture).workspacesPanel().markup.html,
                    "ws-del-\(enc("research"))")

            var skillFixture = AppState.RenderFixture()
            skillFixture.skills = [
                Skill(name: "deploy", description: "Ship the build",
                      content: "---\nname: deploy\ncategory: ops\n---\n\n# deploy\n\nbody",
                      tags: [], category: "ops", path: URL(fileURLWithPath: "/tmp/skills/deploy")),
            ]
            skillFixture.selectedSkill = "deploy"
            _ = row("the skills main pane", await AppState(renderFixture: skillFixture).skillsMain().markup.html,
                    "sk-delete")

            var profileFixture = AppState.RenderFixture()
            profileFixture.profiles = [
                Profile(name: "fast", title: "Fast", description: "Fast profile.", model: "gpt-5-mini"),
                Profile(name: "deep", title: "Deep", description: "Deep profile.", model: "claude-sonnet-4"),
            ]
            profileFixture.selectedProfile = "deep"
            _ = row("the profiles main pane", await AppState(renderFixture: profileFixture).profilesMain().markup.html,
                    "pr-del-\(enc("deep"))")

            var mcpFixture = AppState.RenderFixture()
            mcpFixture.arcConfig.mcpServers = [
                "filesystem": MCPServerConfig(command: "arc", args: ["tools", "mcp", "serve"]),
            ]
            _ = row("the MCP settings pane", await AppState(renderFixture: mcpFixture).mcpSettingsHTML().markup.html,
                    "mcp-del-\(enc("filesystem"))")
        }

        @Test("the render names the return target for the context pane's close")
        func contextChipNamesItself() async {
            // the ctx pane's close declares `data-focus-return="ctx-chip-summary"`,
            // so the target must be a real id on the chip's summary — a
            // `<details>` is not focusable, only its summary is, and an id on the
            // details would make the return silently no-op.
            var fixture = AppState.RenderFixture()
            let session = Session(
                id: "sess-ctx", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Context",
                messageCount: 1, messages: [Message(role: .user, content: "hello")])
            fixture.sessions = [session]
            fixture.activeSessionID = "sess-ctx"
            let ring = await AppState(renderFixture: fixture).ctxIndicatorHTML(session).markup.html
            let summary = Self.openTag(ring, id: "ctx-chip-summary")
            #expect(summary != nil,
                    "the chip's summary must carry `id=\"ctx-chip-summary\"` — it is the id the pane's close returns focus to")
            #expect(summary?.hasPrefix("<summary") == true,
                    "the return target must be the `<summary>`, not the `<details>`: a details is not focusable, so focusing it silently no-ops")

            // the pane's own close control is reachable only through
            // `openContextPane()` (it mints a turn agent), so its pair is pinned
            // on the emitting expression here and proven live in
            // `ux-gates.mjs --only=focus` (row b: Escape/close returns focus to
            // `#ctx-chip-summary`).
            let views = (try? String(contentsOfFile: "Sources/ArcWebUI/Views.swift", encoding: .utf8)) ?? ""
            guard let closeStart = views.range(of: "ArcButton(id: \"ctx-pane-close\""),
                  let closeEnd = views.range(of: "WebUIIcon(.x", range: closeStart.upperBound..<views.endIndex) else {
                #expect(Bool(false), "the context pane's close control is gone from Views.swift")
                return
            }
            let close = String(views[closeStart.lowerBound..<closeEnd.lowerBound])
            #expect(close.contains("FocusReturn(id: \"ctx-chip-summary\").attribute().attributeText"),
                    "the pane's close must declare `data-focus-return=\"ctx-chip-summary\"` — without it Escape/close leaves focus on <body>")
            #expect(!close.contains("autofocus"),
                    "the pane's close must not carry `autofocus`: 3.1.0's FocusInto is the entry path, first and every later open")
            #expect(!close.contains("tabindex="),
                    "the pane's close must NOT state a tabindex: 3.1.1's `FocusInto` leaves an intrinsically focusable `button` alone, so the Tab wrap keeps its stop without arc overriding the engine (the 3.1.0 `tabindex=\"0\"` compensation is gone)")
            #expect(views.contains("FocusInto(id: \"ctx-pane-close\").attribute()"),
                    "the pane's region root must declare `data-focus-into=\"ctx-pane-close\"` (A16d entry)")
        }

    }
}
