import Foundation
import Testing

import ArcTheme
@testable import ArcWebUI

/// The UX-hardening contract: pins for the fixes landed in
/// `.hermes/plans/2026-10-02_165446-ux-usability-hardening.md` (Phase A + B).
///
/// These are the failures that were silent at runtime — a copy string nobody
/// could reach, a flex basis that was a height, a dismiss path wired to an
/// element that did not exist, a control the engine logged as unwired. Each pin
/// names the regression it catches, because "contains this string" is only
/// worth writing when you know what its absence means.
///
/// CSS pins read the SOURCE (`Sources/ArcTheme/ChromeSheet.swift`) the way the
/// click-identity suite reads arc's markup: the served sheet is a minified build
/// product, and both spellings must stay honest, so the built product is checked
/// separately below for the two load-bearing ones.
@Suite("UX hardening contract")
struct UXHardeningContractTests {

    private static func source(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Text as the *client* sees it: Swift's `\"` unescaped, so an attribute
    /// written inside a single-line literal and the same attribute written
    /// inside a `"""` block are one shape to a pin. (The alternative — writing
    /// each pin twice, once per spelling — is how a pin quietly stops matching.)
    private static func clientText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static var sheetSource: String { source("Sources/ArcTheme/ChromeSheet.swift") }
    private static var views: String { clientText(source("Sources/ArcWebUI/Views.swift")) }
    private static var insights: String { clientText(source("Sources/ArcWebUI/Insights.swift")) }
    private static var actions: String { clientText(source("Sources/ArcWebUI/Actions.swift")) }
    private static var appState: String { source("Sources/ArcWebUI/AppState.swift") }
    private static var appStateActions: String { source("Sources/ArcWebUI/AppState+Actions.swift") }
    private static var overlay: String { source("Sources/ArcWebUI/Assets/overlay.js") }
    private static var host: String { source("Sources/ArcWebUI/WebUIHost.swift") }
    private static var fileStore: String { source("Sources/ArcAgentCore/Session/SessionStore.swift") }

    // MARK: - A1/F38 the task form's dead gap

    @Test("the task form's field basis is scoped to the row that shares it")
    func taskFieldBasisIsScoped() {
        let css = Self.sheetSource
        // the old rule put `flex: 1 1 220px` on every `.task-field`; inside the
        // column parent `.task-add` that basis is a HEIGHT, so the Title label
        // stood 220px tall and left a dead gap above Start.
        #expect(css.contains(".task-add-row .task-field { flex: 1 1 220px; }"),
                "the shared row must keep the growth basis")
        #expect(!css.contains("font-weight: 600; flex: 1 1 220px; }"),
                "an unscoped `.task-field { … flex: 1 1 220px }` is back: the title field will stretch again")
    }

    // MARK: - A2/F01 the glued captions

    @Test("a caption under a .detail-sub heading is its own line")
    func detailSubCaptionIsBlock() {
        #expect(Self.sheetSource.contains(".detail-sub small { display: block;"),
                "without this the Agent-powers sub-heads render \"Locked profile filesThese cannot…\"")
    }

    // MARK: - A4/F48 + A5/F12 empty-state copy

    @Test("an unmatched chat filter does not claim the workspace is empty")
    func chatFilterEmptyCopy() {
        let views = Self.views
        #expect(views.contains("No chats match “\\(chatFilter)”."),
                "the filter-empty state must name the filter (F48)")
        #expect(views.contains("No chats in this category yet."),
                "the category-empty state needs its own copy too")
    }

    @Test("a zero-skill library gets the create-first copy, not the filter copy")
    func skillsEmptyCopy() {
        let views = Self.views
        #expect(views.contains("No skills yet — press + to create one."))
        #expect(views.contains("No skills yet — create your first one with + above."))
        #expect(!views.contains("\"No skills match.\""),
                "the unconditional \"No skills match.\" claimed an empty library was a filtered one")
    }

    // MARK: - A11/F34 the chart that lied

    @Test("a zero day draws a gap, never a small red bar")
    func insightsZeroDayIsAGap() {
        let insights = Self.insights
        #expect(insights.contains("let pct = v == 0 ? 0 : max(5"),
                "a 3%-height stub made an empty month look like a month of activity")
        #expect(insights.contains("ins-bar ins-bar-empty"), "empty days need their own class")
        let css = Self.sheetSource
        #expect(css.contains(".ins-bar-empty { background: var(--border-strong); height: 2px !important; }"),
                "the empty-day tick must not inherit the accent fill or an inline height")
        #expect(insights.contains("peak \\(Self.fmtCount(maxVal))"),
                "the chart needs a scale label; values only in a title tooltip are unreadable")
    }

    // MARK: - A13/F36 the log legend

    @Test("the log legend labels its counts")
    func logLegendIsLabelled() {
        let views = Self.views
        #expect(views.contains("\\(info) info"))
        #expect(views.contains("\\(warn) warn"))
        #expect(views.contains("\\(err) error"))
        #expect(!views.contains("class=\"log-stat\"><span class=\"dot dot-info\"></span>\\(info)</span>"),
                "bare numbers under coloured dots are back")
    }

    // MARK: - A14/F16 the toast that never left

    @Test("errors expire on their own and the tick stays silent otherwise")
    func toastsExpire() {
        #expect(Self.appState.contains("static let toastTTL: TimeInterval = 8"))
        #expect(Self.appState.contains("func expireToasts(now: Date = Date()"),
                "expiry must be a tested unit, not a comment")
        #expect(Self.host.contains("IntervalService(name: \"toast-expiry\""),
                "Second Law: the sweep is a Service in the host's group")
        #expect(Self.host.contains("guard await app.expireToasts() else { return }"),
                "the tick must broadcast only when a toast actually dropped")
    }

    // MARK: - B1/F52 Enter sends

    @Test("Enter sends from the composer; Shift+Enter keeps the newline")
    func enterSends() {
        let js = Self.overlay
        #expect(js.contains("t.id !== 'composer-input'"), "the handler must be scoped to the composer")
        #expect(js.contains("e.shiftKey"), "Shift+Enter must stay a newline")
        #expect(js.contains("form.requestSubmit()"),
                "the submit path must be the form's own, so the engine flushes and reads live values")
        #expect(js.contains("e.keyCode === 229"), "an IME commit must not send")
    }

    // MARK: - B2/F45 dropdown dismissal

    @Test("the dropdown dismiss boundary is rendered AND fired")
    func dropdownDismissIsWired() {
        #expect(Self.views.contains("id=\"dd-dismiss\""),
                "the `dd-dismiss` handler existed for months with no element carrying the id")
        #expect(Self.actions.contains("wire(router, id: \"dd-dismiss\""),
                "the server half must stay registered")
        #expect(Self.overlay.contains("function dismissDropdowns()"))
        #expect(Self.overlay.contains("dismissDropdowns();"), "Escape/outside-click must call it")
    }

    // MARK: - B3/F47 the dialog that was a div

    @Test("the confirmation is a dialog with focus, Escape and a trap")
    func modalIsADialog() {
        #expect(Self.views.contains("role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"modal-title\""),
                "no-webui treats a plain div as a div; assistive tech needs the role")
        #expect(Self.views.contains("id=\"modal-title\""), "the label target must exist")
        #expect(Self.overlay.contains("function syncModalFocus()"))
        #expect(Self.overlay.contains("if (e.key === 'Escape') {"),
                "Escape used to do nothing at all in the modal")
        #expect(Self.overlay.contains("card.contains(document.activeElement)"),
                "Tab escaped the dialog to a control behind the scrim")
    }

    // MARK: - A15/F27/F58/F60 the guarded deletes

    @Test("kanban cards arm a two-step delete like the column header")
    func kanbanCardGuard() {
        #expect(Self.actions.contains("await app.confirmCard == id"),
                "a card ✕ used to delete on one click with no guard and no undo")
        #expect(Self.views.contains("let delCls = armed ? \"sess-confirm\" : \"icon-mini danger\""),
                "the armed label must not carry `icon-mini`: a fixed 24x24 box clipped \"Confirm?\"")
        #expect(Self.sheetSource.contains("white-space: nowrap;"),
                ".sess-confirm must never wrap or inherit an icon's width")
    }

    @Test("workspace deletes confirm, and `main` offers no delete at all")
    func workspaceGuard() {
        #expect(Self.actions.contains("kind: \"workspace\", id: name"),
                "the workspace ✕ removed the entry immediately (F26/F27)")
        #expect(Self.views.contains("entry.name == \"main\" ? \"\" : btn(\"ws-del-"),
                "`main` could not be deleted, but the row still offered a dialog that always refused")
    }

    @Test("skills are deletable from the UI")
    func skillDeleteExists() {
        #expect(Self.views.contains("btn(\"sk-delete\", \"skill-delete\""),
                "`deleteSkill` shipped with no trigger rendered anywhere (F58)")
        #expect(Self.actions.contains("wire(router, id: \"skill-delete\""))
        #expect(Self.actions.contains("kind: \"skill\", id: name"),
                "removing a folder on disk must confirm first")
    }

    // MARK: - B5/F49 the type floor

    @Test("nothing a reader needs renders below the floor")
    func typeFloor() {
        let css = Self.sheetSource
        #expect(css.contains(".sess-meta { font-size: 12px;"), "session meta was 10.5px")
        #expect(css.contains(".panel-title {\n      font-size: 12px;"), "panel titles were 11px")
        #expect(css.contains(".md { font-size: 1em;"), "chat body was 13.44px (0.96em of 14px)")
        #expect(css.contains(".dd-trigger {\n      display: inline-flex; align-items: center; gap: 5px;\n      background: transparent; border: none; color: var(--muted);\n      font-family: inherit; font-size: 0.86em;"),
                "composer chip labels were 11.89px")
        // a caption inside a 0.92em label needs 0.92em itself to clear 12px;
        // 0.86em computed to 11.47px on a real page (measured in light theme).
        #expect(css.contains(".set-row .set-label small { display: block; color: var(--muted); font-size: 0.92em;"),
                "Settings captions fell back under the floor")
        // the Small text-size variant was the other way a sub-12px size could
        // reach a reader; it must stay at the floor, not below it.
        #expect(!css.contains("data-size=\"sm\"] .sess-meta { font-size: 10px; }"))
    }

    @Test("the built sheet carries the floor too (minifier cannot eat it)")
    func typeFloorSurvivesTheBuild() {
        let built = ThemeSheetAssets.text.replacingOccurrences(of: " ", with: "")
        #expect(built.contains(".sess-meta{font-size:12px;"),
                "the minified product must still declare the 12px session meta")
        #expect(built.contains(".md{font-size:1em;") || built.contains(".md{font-size:1.0em;"),
                "the minified product must still declare the 1em chat body")
    }

    // MARK: - B6/F51 the composer at narrow widths

    @Test("the composer wraps and its chips go icon-only before they overflow")
    func composerSurvivesNarrowWindows() {
        let css = Self.sheetSource
        #expect(css.contains(".composer-toolbar { display: flex; align-items: center; gap: 2px; padding: 2px 2px 0; flex-wrap: wrap;"),
                "without wrap, `#cb-send` rendered 200px off-screen at an 820px window")
        #expect(css.contains("@media (max-width: 1180px) {"))
        #expect(css.contains(".composer-toolbar .dd-trigger-label { display: none; }"),
                "the model chip is ~210px on its own; icon-only is what keeps the row on one line")
        #expect(css.contains(".composer-toolbar .send-btn { flex: 0 0 auto; }"),
                "the send button must never be the thing that shrinks away")
    }

    // MARK: - B7/F46/F53 the outline

    @Test("the outline is a wired control with a server-owned open state")
    func outlineIsWired() {
        #expect(Self.views.contains("data-component-id=\"outline-toggle\""),
                "client-only wiring made the engine log '[WebUIEngine] click on unwired control'")
        #expect(Self.views.contains("data-component-id=\"outline-close\""))
        #expect(Self.appState.contains("var outlineOpen = false"))
        #expect(Self.actions.contains("wire(router, id: \"outline-toggle\""))
        #expect(Self.overlay.contains("function syncOutline()"),
                "the overlay still owns the entry list, keyed off the server-rendered shell")
        #expect(!Self.overlay.contains("panel.hidden = !panel.hidden"),
                "the client must not flip `hidden` behind the server's back")
    }

    @Test("the open outline moves the reading column clear of itself")
    func outlineReservesSpace() {
        let css = Self.sheetSource
        #expect(css.contains(".chat-scroll-wrap:has(#outline-panel:not([hidden])) .chat-scroll { padding-right: 348px !important; }"),
                "the panel floated over the transcript; `!important` is needed to outrank '#main .chat-scroll'")
        #expect(css.contains("@media (max-width: 1200px) {"),
                "below 1200px there is no room to shift, so the panel overlays by design")
    }

    // MARK: - B8/F03/F04 Settings density + the storage control

    @Test("the auxiliary list fits its card at any width")
    func auxListFits() {
        #expect(Self.sheetSource.contains("grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));"),
                "a fixed `1fr 1fr` grid overflowed the card at 1440 and clipped the right column")
        #expect(Self.views.contains("<div class=\"aux-list\">\\(auxRows)</div>"))
    }

    @Test("the storage backend names both of its states")
    func storageBackendIsASegmentedControl() {
        #expect(Self.views.contains("id=\"set-backend-file\""))
        #expect(Self.views.contains("id=\"set-backend-tessera\""))
        #expect(!Self.views.contains("data-component-id=\"set-tessera\""),
                "the old switch's ON meant FILE storage — the opposite of every other switch (F04)")
        #expect(Self.actions.contains("guard await self.app.currentTesseraOff() != off else { return [] }"),
                "clicking the active side must not rebuild the store")
    }

    // MARK: - A20/F07 real session titles

    @Test("unloaded session summaries carry a title hint")
    func summariesCarryATitleHint() {
        let store = Self.fileStore
        #expect(store.contains("session.title = String(text.replacingOccurrences(of: \"\\n\", with: \" \").prefix(64))"),
                "the sidebar showed \"New chat\" for every row: the bodies are decoded here and then discarded")
        #expect(store.contains("if (session.title ?? \"\").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"),
                "the hint must never overwrite a real title")
    }

    // MARK: - B4/F17/F41 landing on content

    @Test("list/detail pages open on their first item and keep a previous choice")
    func listDetailPagesAutoSelect() {
        let actions = Self.appStateActions
        #expect(actions.contains("if selectedSkill == nil { selectedSkill = skills.first?.name }"))
        #expect(actions.contains("if selectedProfile == nil { selectedProfile = profiles.first?.name }"))
        #expect(actions.contains("if selectedTool == nil { selectedTool = registry.allTools.first?.name }"))
        #expect(actions.contains("if memoryDoc == nil { openMemoryDoc(\"memory\") }"))
        #expect(actions.contains("if tasksSelectedID == nil { tasksSelectedID = settings.scheduledJobs.first?.id }"))
        #expect(actions.contains("await githubSelect(sha: first.sha)"),
                "the GitHub pane rested on \"Select a commit…\" with commits in the panel")
    }
}