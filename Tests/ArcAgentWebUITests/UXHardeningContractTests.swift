import Foundation
import Testing

import ArcTheme
@testable import ArcWebUI

extension ArcWebUITestRoot {
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
    @Suite("UX hardening contract", .serialized)
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

        // MARK: - UX-02 (2026-10-18) tool/MCP schema rows use the adaptive card

        @Test("the tool/MCP schema renderer emits .akv rows, never the dark .kv card")
        func schemaRowsUseAdaptiveKV() {
            let views = Self.views
            // `schemaHTML` shared the design system's `.kv` card (a permanently-dark
            // navy code card) with the migrated tool card, so tool parameter rows were
            // black-on-navy in light themes (UX-02, observed 1.23:1). The schema rows
            // must use the arc `.akv` classes like the Description/Toolset meta rows.
            guard let start = views.range(of: "func schemaHTML(_ schema: JSONSchema) -> String {") else {
                #expect(Bool(false), "schemaHTML must still exist")
                return
            }
            let rest = views[start.upperBound...]
            let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
            let body = String(rest[..<end])
            #expect(body.contains("class=\"akv\">"), "the schema rows must use the adaptive .akv card")
            #expect(body.contains("class=\"akv-k\""), "the schema key span must use .akv-k")
            #expect(body.contains("class=\"akv-v\""), "the schema value span must use .akv-v")
            #expect(!body.contains("class=\"kv\""),
                    "the dark .kv card is back in schemaHTML: tool/MCP parameter rows go black-on-navy in light themes")
            #expect(!body.contains("class=\"k\""), "the design-system .k key span is back in schemaHTML")
            #expect(!body.contains("class=\"v\""), "the design-system .v value span is back in schemaHTML")
        }

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
            #expect(views.contains("No skills yet."))
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
            #expect(Self.appState.contains("static let toastTTL: TimeInterval = 10"))
            #expect(Self.appState.contains("func expireToasts(now: Date = Date()"),
                    "expiry must be a tested unit, not a comment")
            #expect(Self.host.contains("IntervalService(name: \"toast-expiry\""),
                    "Second Law: the sweep is a Service in the host's group")
            #expect(Self.host.contains("guard await app.expireToasts() else { return }"),
                    "the tick must broadcast only when a toast actually dropped")
        }

        // MARK: - UX-27 toast kinds, anchor and stack cap

        @Test("toasts are kind-aware: red only for failures, anchored clear of the header, capped")
        func toastsAreKindAware() {
            // The stack must sit at the BOTTOM edge — a success toast anchored top-right
            // used to land over the chat-header action icons, and the whole stack over
            // the window strip (w1v-12, w1v-23). UX-58 raised the anchor (16 → 120px)
            // so it also floats clear of the composer's Send button.
            #expect(Self.sheetSource.contains("#toasts {\n      position: fixed;"),
                    "the toast stack must be anchored to the bottom edge")
            #expect(Self.sheetSource.contains("bottom: 120px;\n      right: 14px;"),
                    "UX-58: the stack must float clear of the composer bar (bottom: 120px)")
            // The base bubble must be NEUTRAL: a success confirmation must not read
            // as a red error in either theme.
            let sheet = Self.sheetSource
            #expect(sheet.contains("background: var(--surface);"),
                    "the base toast must use the neutral surface, not the danger tint")
            #expect(sheet.contains(".toast.error {\n      background: var(--danger-soft);"),
                    "only the error kind may use the danger palette")
            #expect(sheet.contains(".toast.success {\n      background: color-mix(in srgb, var(--success) 14%, transparent);"),
                    "success confirms must be green-tinted, never red")
            #expect(sheet.contains(".toast.toast-more {"),
                    "the overflow marker must exist and be visually distinct")
            // Server-side cap: newest 3 + "+N more".
            let views = Self.views
            #expect(views.contains("let visible = toasts.suffix(3)"),
                    "the rendered stack must be capped at the newest three toasts")
            #expect(views.contains("class=\"toast toast-more\""),
                    "older toasts must collapse into a +N more marker")
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

        // MARK: - UX-28 slash menu whole-row scroll + initial active row (T25)

        @Test("the slash dropdown sizes itself to whole rows and opens with the first row active")
        func slashMenuWholeRows() {
            let overlay = Self.overlay
            let css = Self.sheetSource
            // The regression (w1v-02, w2f-02): a 232px max-height against 57.5px
            // rows showed a 2px sliver of the next row. The scroll region is now a
            // borderless `.cmd-list` inner wrapper, and the overlay sizes it to a
            // floor of the available space over the measured row pitch — so the
            // border-box height IS the content height and lands exactly on a row
            // boundary.
            #expect(overlay.contains(".cmd-list"),
                    "the rows must live in the borderless inner wrapper whose box owns the clip")
            #expect(overlay.contains("list.style.maxHeight = (Math.round((whole * rowH) * 4) / 4) + 'px'"),
                    "the scroll region's max-height must be an exact multiple of the row pitch")
            #expect(overlay.contains("var whole = Math.max(1, Math.floor(avail / rowH));"),
                    "the visible row count must be floored, never truncated mid-row")
            #expect(overlay.contains("list.scrollTop"), "revealing the active row must scroll the inner list")
            // UX-54: the cap rose 232 → 460px (8 of 10 commands visible instead
            // of a four-row fold) and the inner list shows a slim always-visible
            // scrollbar so the remaining rows advertise themselves.
            #expect(css.contains(".cmd-list { max-height: 460px; overflow-y: auto; scrollbar-gutter: stable; }"),
                    "the clip lives on the inner borderless list, not the bordered dropdown")
            #expect(css.contains(".cmd-list::-webkit-scrollbar-thumb"),
                    "UX-54: the inner list must advertise overflow with a visible scrollbar")
            #expect(overlay.contains("Math.min(460, composerTop - 12)"),
                    "UX-54: the menu must claim the available space up to 460px, not a four-row fold")
            // Opening the menu must reset the highlight to the first row so Enter's
            // target is unambiguous after a prior interaction moved the selection.
            #expect(overlay.contains("if (!wasOpen) slashSel = 0;"),
                    "a fresh open must mark the first item active")
            // The active row carries the class the visible treatment keys on, and
            // the sheet gives it an accent-tinted fill plus a left accent bar.
            #expect(overlay.contains("b.className = 'cmd-item' + (idx === slashSel ? ' active' : '')"),
                    "the selected row must carry the .active class")
            #expect(css.contains(".cmd-item.active { background: var(--accent-soft); box-shadow: inset 3px 0 0 var(--accent-strong); }"),
                    "the active row must read as active: accent fill + left bar")
        }

        // MARK: - UX-33 focus survives the fragment patch (T26)

        @Test("the overlay restores focus to the control the patch just replaced")
        func focusRestoredAfterPatch() {
            let overlay = Self.overlay
            // The regression (steps-w2f-i): activating a settings chip with Enter
            // or Space toggled it correctly but the server re-render replaced the
            // node, so `document.activeElement` fell back to <body>. The overlay
            // must remember the control that blurred and re-focus its replacement
            // (matched by id, or data-sid for roving session rows) inside the
            // post-patch seam.
            #expect(overlay.contains("lastFocusedControl"), "the overlay must remember the control that had focus")
            #expect(overlay.contains("document.getElementById(rec.id)"),
                    "focus must be restored by id — the node was replaced, a cached reference is stale")
            #expect(overlay.contains("restoreFocusAfterPatch();"),
                    "the restore must run in the post-patch seam (enhancePatched)")
            #expect(overlay.contains("rec.el.isConnected"),
                    "restore must be skipped when the focused node survived or focus moved on purpose")
            #expect(overlay.contains("nu.focus({ preventScroll: true })"),
                    "the re-focused control must not scroll the page")
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

        // MARK: - UX-02 attach popover joins the dismissal system

        @Test("the attach popover is dismissed by the same Escape/outside-click path")
        func filePopDismissalIsOwned() {
            let overlay = Self.overlay
            #expect(overlay.contains("var fp = document.getElementById('file-pop');"),
                    "dismissDropdowns must own #file-pop: it is not a `.dd-pop`, so no boundary ever fired for it")
            #expect(overlay.contains("if (fp && !fp.classList.contains('hidden')) {"),
                    "closing must be gated on the popover actually being open")
            #expect(overlay.contains("e.target.closest('.file-pop')"),
                    "a click inside the popover (path input / recents) must not dismiss it")
            let appStateActions = Self.appStateActions
            #expect(appStateActions.contains("if filePopOpen { closeSelectorPanels() }"),
                    "opening the attach popover must close any open composer selector (without re-closing itself)")
            #expect(appStateActions.contains("filePopOpen = false"),
                    "closing the composer selectors must close the attach popover too (mutual exclusivity)")
        }

        // MARK: - UX-03 workspace dock keeps its routing anchor

        @Test("the workspace dock keeps its routing anchor and a collapse tab in both states")
        func workspaceDockAnchorIsStable() {
            #expect(!Self.views.contains("guard !workspaceOpen else { return \"<div id=\"ws-dock\"></div>\" }"),
                    "the open-state patch replaced the anchored `#ws-dock` root with an anchor-less div, so the engine dropped routing for the region")
            #expect(Self.views.contains("<div id=\"ws-dock\" data-component-id=\"workspace\" data-event=\"click\">"),
                    "the dock wrapper must carry the component anchor in every render")
            #expect(Self.views.contains("let title = open ? \"Collapse workspace\" : \"Open workspace\""),
                    "the open-state dock must be a discoverable collapse tab, not an empty div")
            let overlay = Self.overlay
            #expect(overlay.contains("var wsPanel = document.getElementById('ws-panel');"),
                    "the overlay must own Escape-to-close for the workspace panel like it does for the outline")
            #expect(overlay.contains("document.getElementById('w-close') || document.getElementById('w-dock')"),
                    "Escape must fall back to the collapse tab when the panel's ✕ is absent")
            let css = Self.sheetSource
            #expect(css.contains(".ws-dock-btn.ws-dock-open { opacity: 1; }"),
                    "the collapse affordance exists only on hover — Escape/click are its only closers")
        }

        @Test("an open workspace panel shows exactly one close control — the collapse tab is hidden")
        func workspaceDockHidesWhenOpen() {
            let views = Self.views
            // UX-30: the open-state dock tab floated at the panel's mid-right edge
            // over the file rows — two competing close affordances. While open the
            // collapse tab must be hidden so the header ✕ is the single close
            // control (the anchored wrapper stays, so routing never drops).
            #expect(views.contains("let attrHidden = open ? \" hidden\" : \"\""),
                    "the open state must mark the collapse tab hidden")
            #expect(views.contains("id=\"w-dock\" class=\"\\(cls)\"\\(attrHidden)"),
                    "the hidden marker must ride the dock button itself")
            #expect(Self.sheetSource.contains(".ws-dock-btn[hidden] { display: none; }"),
                    ".ws-dock-btn declares display:flex — without an explicit [hidden] rule the UA rule loses and the dead chevron stays visible")
        }

        // MARK: - UX-05 the topbar follows the auto-title

        @Test("the turn-chrome push carries the topbar so auto-titles reach the window strip")
        func turnChromeCarriesTopbar() {
            #expect(Self.actions.contains("FragmentUpdate(id: \"topbar\", html: topbarHTML())"),
                    "the top strip showed \"New chat\" after an auto-title: the title mutation pushed chat-header but never the topbar — the topbar must ride the same turn chrome the header does")
            #expect(Self.actions.components(separatedBy: "FragmentUpdate(id: \"topbar\"").count >= 3,
                    "the topbar must be owned by BOTH the title-generating path and every turn-chrome boundary — a single owner leaves one of them stale")
        }

        // MARK: - UX-06 feedback + undo for copy / delete

        @Test("deleting a chat surfaces an Undo toast and the wire can restore it")
        func deleteHasUndoToast() {
            let appState = Self.appState
            #expect(appState.contains("func surfaceToast(_ text: String, kind: String = \"info\", action: ToastAction? = nil)"),
                    "routine toasts stay quiet by preference — feedback toasts must be surfaced explicitly")
            #expect(appState.contains("let action: ToastAction?"), "Toast must be able to carry an action")
            let appStateActions = Self.appStateActions
            #expect(appStateActions.contains("ToastAction(id: \"undo-delete\", label: \"Undo\")"),
                    "deleting a chat must offer Undo")
            #expect(appStateActions.contains("func undoDeleteChat()"), "the restore path must exist")
            #expect(appStateActions.contains("try await store.create(saved.session)"),
                    "Undo must re-create the session in the store with its messages")
            #expect(appStateActions.contains("preserveUndo: true"),
                    "the delete path's auto-select must not clear the undo slot")
            #expect(Self.views.contains("ta-\\(a.id)-\\(t.id)"),
                    "the toast action button must be rendered with a wireable id")
            #expect(Self.actions.contains("if actionID == \"undo-delete\""),
                    "the toast wire must dispatch the undo action")
            #expect(Self.overlay.contains("if (kind === 'quiet') return"),
                    "copy-link feedback toasts must surface (only explicit quiet stays silent)")
            // The copy side effect is server-owned (single owner for toast+URL),
            // and the clipboard write is a post-patch handoff via #pending-copy.
            // (T23 audit: wired regions do not swallow client listeners on this
            // pair — probes showed all phases firing — so this is an ownership
            // choice, not a workaround for lost events.)
            // UX-24: the overlay owns the copy toast now; the server only
            // stages the URL marker. The overlay's post-patch pass reads it,
            // writes the clipboard, and flashes exactly one toast.
            #expect(!Self.actions.contains("surfaceToast(\"Conversation link copied.\")"),
                    "the server must NOT surface the copy toast — the overlay owns it (UX-24)")
            #expect(Self.appState.contains("func markCopyLink(_ sessionID: String)"),
                    "the server must stage the link for the client clipboard write")
            #expect(Self.appState.contains("var pendingCopyURL: String? = nil"),
                    "the staged link must ride the toasts fragment")
            #expect(Self.views.contains("id=\"pending-copy\" data-copy-url"),
                    "the hidden copy marker must be rendered inside #toasts")
            #expect(Self.overlay.contains("function copyFromServerMarker()"),
                    "the overlay must consume the marker and write the clipboard")
            #expect(Self.overlay.contains("copyFromServerMarker();"),
                    "the clipboard handoff must run out of the post-patch seam")
        }
        // MARK: - UX-24 regression guard: the copy-link fragment must interpolate

        /// The copy-link branch builds its `#toasts` fragment by hand. A
        /// double-escaped interpolation compiles clean and ships the literal
        /// source text instead of the rendered toasts — the marker never
        /// reaches the client, the clipboard is never written, and the toast
        /// box displays the raw interpolation. The older pin only asserted
        /// that the server's own success toast was gone, so it could not see
        /// this. This pin reads the interpolation itself.
        @Test("the copy-link toasts fragment interpolates toastsHTML(), never literal source")
        func copyLinkToastsInterpolates() {
            let actions = Self.actions
            #expect(actions.contains("\\(await self.app.toastsHTML())</div>"),
                    "the copy-link branch must interpolate its toasts fragment")
            #expect(!actions.contains("\\\\(await self.app.toastsHTML())</div>"),
                    "a double-escaped interpolation ships literal source text — the marker never renders")
        }


        // MARK: - UX-12 regression guard: preview reasons + live chrome

        /// The preview pane must keep the reason it cannot render (binary,
        /// too large, not utf-8, read failure) instead of an empty <pre>, and
        /// every control in its head must have an owner: the copy control is
        /// client-side, the open-in-editor control was markup-only and is gone.
        @Test("workspace previews keep their no-preview reason and the copy control is wired")
        func workspacePreviewContracts() {
            let views = Self.views
            let overlay = Self.overlay
            #expect(views.contains("esc(previewNote ?? \"No preview.\")"),
                    "an unreadable preview must name the reason, not render an empty box")
            #expect(overlay.contains("#ws-preview-copy"),
                    "the preview copy control must have a client owner")
            #expect(!views.contains("ws-preview-open"),
                    "the unwired open-in-editor control must not ship")
        }


        // MARK: - UX-01 slash autocomplete consumer

        @Test("the slash menu payload has a client consumer wired to open/filter/insert")
        func slashMenuIsConsumed() {
            let overlay = Self.overlay
            // The regression: `#slash-data` and `#cmd-dropdown` were rendered but
            // nothing consumed them after the engine migration — `/` did nothing.
            #expect(overlay.contains("function slashItems()"),
                    "the overlay must parse the server-rendered slash payload")
            #expect(overlay.contains("JSON.parse(host.textContent || '{}')"),
                    "the menu must read `#slash-data`, not a hardcoded copy")
            #expect(overlay.contains("function syncSlashMenu(value)"),
                    "opening/filtering must be driven by composer input")
            #expect(overlay.contains("e.key === 'ArrowDown' || e.key === 'ArrowUp'"),
                    "ArrowUp/Down must move the selection")
            #expect(overlay.contains("e.key === 'Enter' || e.key === 'Tab'"),
                    "Enter/Tab must insert the highlighted command")
            #expect(overlay.contains("chooseSlash("), "an insert path must exist")
            #expect(overlay.contains("function closeSlashMenu()"),
                    "Escape/outside-click must be able to close it")
            #expect(overlay.contains("if (slashMenuOpen()) return;"),
                    "Enter with the menu open must insert, not submit the stale `/…` text")
            #expect(Self.views.contains("id=\"slash-data\""),
                    "the payload node must stay in the composer markup")
        }

        // MARK: - UX-04 honest mid-stream queue

        @Test("mid-stream sends queue visibly and drain in order")
        func midStreamSendsQueue() {
            let views = Self.views
            #expect(views.contains("Send another message — queued after this reply."),
                    "the running placeholder must say the message is queued, not that it steers")
            #expect(views.contains("func queuedSendsHTML() -> String"),
                    "the composer must render the queued chips")
            #expect(views.contains("id=\"queued-sends\""),
                    "the queue row must exist as a wired boundary")
            #expect(views.contains("qs-del-\\(q.id)"),
                    "each chip must be removable through the wire")
            let appStateActions = Self.appStateActions
            #expect(appStateActions.contains("func queueSend(_ text: String, sessionID: String)"),
                    "submitting during a turn must enqueue")
            #expect(appStateActions.contains("func popQueuedSend(_ sessionID: String) -> QueuedSend?"),
                    "the turn-end drain needs a pop")
            #expect(appStateActions.contains("func removeQueuedSend(_ id: Int, sessionID: String)"),
                    "a chip ✕ must be able to cancel a queued message")
            let actions = Self.actions
            #expect(!actions.contains("submitSteer"), "the steering path is gone — queue replaced it")
            #expect(actions.contains("if !wasStopped, let next = self.popQueuedSend(sessionID)"),
                    "the turn end must drain one queued message so order matches the chips")
            #expect(actions.contains("wire(router, id: \"queued-sends\""),
                    "the queue row must be wired")
            #expect(!Self.overlay.contains("steer"), "no steer wording may survive")
        }

        // MARK: - UX-29 queued-chip copy

        @Test("the queued chip counts once: instruction in the placeholder, count+excerpt+✕ in the chip")
        func queuedChipCopy() {
            let views = Self.views
            // The chip repeated the placeholder sentence verbatim (w1v-17): the
            // instruction must now appear exactly once — in the composer placeholder.
            #expect(views.components(separatedBy: "Send another message — queued after this reply.").count == 2,
                    "the running-composer sentence must appear exactly once (the placeholder owns it; N occurrences → N+1 components)")
            #expect(!views.contains("queued-chip-lbl"),
                    "the chip's sentence-label span is gone — a chip no longer restates the instruction")
            #expect(views.contains("aria-label=\"\\(removeTip)\""),
                    "the ✕ must explain removal in its aria-label")
            #expect(views.contains(" title=\"\\(removeTip)\""),
                    "the ✕ must explain removal in its title as well")
            #expect(views.contains("class=\"queued-chip-x\""),
                    "each chip keeps its remove control")
            #expect(views.contains("<span class=\"queued-count\">Queued · \\(list.count)</span>"),
                    "the count must stay once per queue row")
        }

        // MARK: - UX-07 keyboard path: skip link, roving rows, quiet utilities

        @Test("the chat is reachable by keyboard: skip link first, roving rows, quiet utilities")
        func chatIsKeyboardReachable() {
            let views = Self.views
            #expect(views.contains("<a class=\"skip-link\" href=\"#composer-input\">Skip to composer</a>"),
                    "a skip-to-composer link must be the first focusable element (UX-07)")
            #expect(views.contains("tabindex=\"\\(rowTab)\" role=\"group\""),
                    "each session row must be the roving tab stop (active 0, others -1)")
            #expect(views.contains("class=\"sess-open\" tabindex=\"-1\""),
                    "the per-row open button must be out of the tab order")
            #expect(views.contains("class=\"menu-dots\" title=\"Chat actions\" tabindex=\"-1\""),
                    "the per-row ⋮ must be out of the tab order (reachable via Menu/Shift+F10)")
            #expect(views.contains("class=\"tw-copy\" type=\"button\" data-copy-target=\"\\(target)\" title=\"Copy this activity\" tabindex=\"-1\""),
                    "worklog copy buttons must be quiet (out of the tab order)")
            #expect(views.contains("class=\"tc-copy\" type=\"button\" data-copy=\"\" + esc(args) + \"\" title=\"Copy arguments\" tabindex=\"-1\""),
                    "tool-card copy buttons must be quiet")
            // The two copy attributes above are built by string concatenation; the
            // doubled-backslash spelling emits the LITERAL text `\(target)` and the
            // doubled-quote spelling emits `data-copy=""<args>""`. Both render bugs
            // live inside Swift-side escaping that clientText cannot see (it only
            // unescapes `\"`), so pin the raw source spelling directly.
            let rawViews = Self.source("Sources/ArcWebUI/Views.swift")
            #expect(!rawViews.contains("\\\"\\\" + esc(args) + \\\"\\\""),
                    "the doubled-quote spelling is back: tool-card copy emits data-copy=\"\"<args>\"\"")
            #expect(views.contains("data-copy=\"\\(esc(m.content ?? \"\"))\" title=\"Copy response\" tabindex=\"-1\""),
                    "message copy buttons must be quiet")
            let overlay = Self.overlay
            #expect(overlay.contains("function visibleSessionRows()"),
                    "the overlay must rove across visible rows only")
            #expect(overlay.contains("roveRowFocus("),
                    "roving must move tabindex with focus")
            #expect(overlay.contains("if (e.key === 'Menu' || (e.shiftKey && e.key === 'F10'))"),
                    "the Menu key must open a row's ⋮ menu")
            #expect(overlay.contains(".sess-row[tabindex]')) return;"),
                    "the transcript-scroll keys must never steal a session row's arrows")
            let sheet = Self.sheetSource
            #expect(sheet.contains(".skip-link:focus { left: 0; }"),
                    "the skip link must be invisible until focused, then visible")
            #expect(sheet.contains(".sess-row:focus-visible"),
                    "a roving row needs a visible focus ring")
            #expect(sheet.contains(".sess-row:focus-within .menu-dots"),
                    "the quiet ⋮ must reveal while its row has focus")
        }

        // MARK: - UX-32 the skills search field clears the rail tooltip pill

        @Test("the filter field is padded so the rail tooltip pill never covers its text")
        func filterFieldClearsRailTooltip() {
            let sheet = Self.sheetSource
            #expect(sheet.contains("padding: 7px 10px 7px 52px;"),
                    "the rail tooltip pill (~58…116px into the panel) must not cover the search placeholder (UX-32)")
        }

        // MARK: - UX-11 no autocomplete hint on the private-key input

        @Test("the client private key input opts out of password autofill")
        func privateKeyInputSilencesAutofillHint() {
            let views = Self.views
            #expect(views.contains("id=\"sc-priv\" name=\"sc-priv\" data-component-id=\"sc-priv\" type=\"password\" autocomplete=\"new-password\""),
                    "the browser warns on password inputs without autocomplete (UX-11)")
        }
        // MARK: - UX-10 log level badge never wraps

        @Test("the log level badge keeps WARNING on one line")
        func logLevelBadgeNeverWraps() {
            let sheet = Self.sheetSource
            #expect(sheet.contains(".log-lvl { flex: 0 0 auto; min-width: 44px; white-space: nowrap;"),
                    "a fixed width of 44px made WARNING wrap mid-word (UX-10)")
        }
        // MARK: - UX-09 "1 message" pluralization

        @Test("message counts pluralize the noun")
        func messageCountsPluralize() {
            let views = Self.views
            #expect(views.contains("count == 1 ? \"message\" : \"messages\""),
                    "the sidebar meta must say \"1 message\", not \"1 messages\" (UX-09)")
            #expect(!views.contains("count) messages\""),
                    "the unconditional \"messages\" spelling is back")
        }
        // MARK: - UX-12/T09 one tooltip system, one label

        @Test("the rail and header buttons use one tooltip mechanism with one label")
        func oneTooltipSystemOneLabel() {
            let views = Self.views
            let sheet = Self.sheetSource
            #expect(!views.contains("title=\"\\(esc(tab.title))\" data-tip="),
                    "the rail must not emit a native title next to data-tip (double tooltip)")
            #expect(!views.contains("title=\"Settings\" data-tip=\"Settings\""),
                    "the settings rail button must not emit title next to data-tip")
            #expect(views.contains("data-tip=\"\\(esc(tab.title))\""),
                    "the rail pill carries the unified full tab label (Chats, not Chat)")
            #expect(views.contains("data-tip=\"Settings\""),
                    "the settings pill label is Settings")
            #expect(views.contains("data-tip=\"Regenerate last reply\""),
                    "header icon button (regen) uses the data-tip pill, not a native title")
            #expect(views.contains("data-tip=\"Delete chat\""),
                    "header icon button (chatdel) uses the data-tip pill, not a native title")
            #expect(views.contains("data-tip=\"Attach a file\""),
                    "header icon button (cbfile) uses the data-tip pill, not a native title")
            #expect(views.contains("data-tip=\"Bookmark this chat\""),
                    "header icon button (cbmark) uses the data-tip pill, not a native title")
            #expect(views.contains("data-tip=\"Conversation outline\""),
                    "header icon button (outline) uses the data-tip pill, not a native title")
            #expect(sheet.contains(".icon-mini[data-tip]::after"),
                    "the header pill styling must exist for icon-mini/tool-btn/outline-toggle")
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

        @Test("the composer wraps; its chips keep short labels to 700px then go icon-only, with >= 44px targets at the tablet widths")
        func composerSurvivesNarrowWindows() {
            let css = Self.sheetSource
            #expect(css.contains(".composer-toolbar { display: flex; align-items: center; gap: 2px; padding: 2px 2px 0; flex-wrap: wrap;"),
                    "without wrap, `#cb-send` rendered 200px off-screen at an 820px window")
            #expect(css.contains("@media (max-width: 1180px) {"),
                    "the composer's first narrow breakpoint must exist")
            #expect(css.contains(".composer-toolbar .send-btn { flex: 0 0 auto; }"),
                    "the send button must never be the thing that shrinks away")
            // UX-05: at 1024 the chips went icon-only with 21px-tall hit
            // targets. Labels must stay visible down to the mobile breakpoint
            // (truncated, never dropped), every glyph-only control must reach
            // a 44px target at the tablet widths, and only below 700px — where
            // there is no hover title at all — do the chips go icon-only.
            #expect(css.contains(".composer-toolbar .dd-trigger-label { max-width: 150px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }"),
                    "at the 1180 breakpoint the chip labels must truncate, not disappear (UX-05)")
            #expect(css.contains(".composer-toolbar .tool-btn { width: 44px; height: 44px; }"),
                    "the attach/bookmark glyphs must reach a 44px target at 1024 (UX-05)")
            #expect(css.contains(".composer-toolbar .send-btn { width: 44px; height: 44px; }"),
                    "Send must reach a 44px target at 1024 (UX-05)")
            #expect(css.contains("@media (max-width: 700px) {\n      .composer-toolbar .dd-trigger-label { display: none; }"),
                    "labels go icon-only only below 700px; at 1024 they stay visible (UX-05)")
            // Every glyph-only composer button carries an accessible name to
            // back the icon-only state (the data-tip pill is hover-only).
            let views = Self.views
            #expect(views.contains("data-tip=\"Attach a file\" aria-label=\"Attach a file\""),
                    "the attach button must carry an aria-label (UX-05)")
            #expect(views.contains("data-tip=\"Bookmark this chat\" aria-label=\"Bookmark this chat\""),
                    "the bookmark button must carry an aria-label (UX-05)")
            #expect(views.contains("id=\"cb-send\" data-component-id=\"cb-send\" class=\"send-btn\" title=\"Send\" aria-label=\"Send\""),
                    "Send must carry an aria-label matching its title (UX-05)")
            #expect(views.contains("class=\"dd-trigger\" title=\"\\(esc(tip))\" aria-label=\"\\(esc(tip))\""),
                    "every .dd-trigger chip must carry an aria-label so the icon-only state stays named (UX-05)")
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

        @Test("the storage surface names the active medium — no backwards ON switch")
        func storageBackendNamesItsStates() {
            // The surface is the medium picker (tessera's storage-connection
            // architecture): the trigger names the medium in use and the popover
            // badges the active row. There is no ON/OFF switch whose ON meant FILE
            // (F04) — the ambiguity B8 fixed cannot recur in this shape.
            #expect(Self.views.contains("label: storageMediumLabel(effectiveMedium)"))
            #expect(Self.views.contains("data-component-id=\"storage-pick\""))
            #expect(!Self.views.contains("data-component-id=\"set-tessera\""),
                    "the old switch's ON meant FILE storage — the opposite of every other switch (F04)")
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
        }

        // MARK: - UX-18 filter verb + archive affordance (T13)

        @Test("one filter verb across panels and one archived-toggle control")
        func filterVerbAndArchiveControl() {
            let views = Self.views
            // The chat and skills sidebars are the same kind of surface — one
            // verb, not "Filter conversations…" vs "Search skills…".
            #expect(views.contains("placeholder=\"Filter conversations…\""),
                    "the chats filter keeps the Filter verb")
            #expect(views.contains("placeholder=\"Filter skills…\""),
                    "the skills filter must use the same verb as chats")
            #expect(!views.contains("Search skills…"),
                    "the chats/skills split is back (one verb pattern, UX-18)")
            // One archive affordance: the explicit text link stays (now the only
            // control, so it carries the keyboard stop), the header glyph is gone.
            #expect(!views.contains("btn(\"chat-showarch\""),
                    "the redundant header archive glyph is gone (UX-18)")
            #expect(views.contains("id=\"chat-showarch-link\" data-component-id=\"chat-showarch\" class=\"arch-link\" title=\"Toggle archived\">"),
                    "the text link is the single archive control and sits in the tab order (no tabindex=-1)")
        }

        // MARK: - UX-20 model dropdown rows (T13)

        @Test("model dropdown: one calm row per model with a state marker, no shouty badges or section header")
        func modelDropdownRowsAreClean() {
            let views = Self.views
            // The old shouty row is gone: the uppercase "(CUSTOM)" pill that rode
            // the config name (scoped to the model dropdown — the aux/workspace
            // pickers are different surfaces and keep their own badge patterns).
            #expect(!views.contains("<span class=\"dd-badges\"><span class=\"dd-badge\">\\(esc(c.name.uppercased())) (CUSTOM)"),
                    "the shouty (CUSTOM) pill is gone from the model rows (UX-20)")
            #expect(!views.contains("<div class=\"dd-section\">CONFIGURED</div>"),
                    "the CONFIGURED micro-caps section header is gone (UX-20)")
            // One row per model: state dot on the left, name in normal case +
            // check when selected, a secondary line with model/provider.
            #expect(views.contains("extraClass: \"dd-model-row\""),
                    "model rows must carry the row layout class")
            #expect(views.contains("<span class=\"dd-dot\\(sel ? \" on\" : \"\")\"></span>"),
                    "each row must carry a state dot (green when active)")
            #expect(views.contains("<span class=\"dd-row-title\">\\(esc(c.name))\\(check)</span>"),
                    "the row title is the config name in normal case, with a check for the selected row")
            #expect(views.contains("<span class=\"dd-row-sub\">\\(sub)</span>"),
                    "the secondary line (model · provider · base URL) must exist")
            #expect(views.contains("id=\"model-search-input\""),
                    "the search input must stay (UX-20 keeps it)")
            let css = Self.sheetSource
            #expect(css.contains(".dd-model-row { flex-direction: row; gap: 10px; align-items: flex-start; }"),
                    "the row must lay the dot beside the model text, not above it")
        }

        // MARK: - UX-21 auxiliary model descriptions (T13)

        @Test("auxiliary model descriptions clamp to two lines with the full text on hover, not mid-word truncation")
        func auxDescriptionsClampToTwoLines() {
            let sheet = Self.sheetSource
            // The regression (12-set-1950.png): a one-line `white-space: nowrap`
            // + ellipsis cut descriptions mid-word ("Context summarizati…").
            #expect(sheet.contains(".aux-list .set-label { white-space: normal; }"),
                    "the aux label must stop hard-truncating on one line (UX-21)")
            #expect(sheet.contains("-webkit-line-clamp: 2;"),
                    "the description must clamp to two lines, not one")
            #expect(sheet.contains("overflow-wrap: anywhere;"),
                    "a clamped line must break words rather than clip the card")
            #expect(!sheet.contains(".aux-list .set-label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }"),
                    "the old single-line ellipsis on the aux label is gone (UX-21)")
            // Configure stays right-aligned: the buttons live in the shrink-proof
            // .aux-right while only the label grows.
            #expect(sheet.contains(".set-row .aux-right { display: flex; gap: 8px; flex-shrink: 0; }"),
                    "Configure/Edit must not be squeezed by the taller label")
            // The full description still rides the row's title for hover.
            #expect(Self.views.contains("title=\"\\(esc(task.detail))\""),
                    "the full description must stay available on hover via the row title")
        }

        // MARK: - UX-22 tool-plugin chips (T13)

        @Test("tool-plugin chips wrap instead of clipping at the card edge")
        func toolPluginChipsWrap() {
            let views = Self.views
            // The chip row now lives in a wrapping `.plug-chips` flex row with the
            // "Tools:" prefix kept outside it.
            #expect(views.contains("Tools: <span class=\"plug-chips\">"),
                    "the chips must ride in the wrapping plug-chips container (UX-22)")
            #expect(!views.contains("style='margin-right:4px'"),
                    "the old inline-margin chip string is gone (UX-22)")
            let sheet = Self.sheetSource
            #expect(sheet.contains(".plug-chips { display: inline-flex; flex-wrap: wrap; gap: 6px; margin-left: 2px; max-width: 100%; vertical-align: middle; }"),
                    "the chip row must be a wrapping flex container")
            #expect(sheet.contains(".plug-chips .mc-badge { margin-right: 0; max-width: 100%; overflow-wrap: anywhere; }"),
                    "a long package token must break inside its badge, never clip at the card edge")
        }

        // MARK: - UX-25 log line hanging indent (T13)

        @Test("a wrapped log message continues with a hanging indent inside its own column")
        func logWrappedLinesIndent() {
            let sheet = Self.sheetSource
            // The regression (07-logs.png): `display: flex` let pre-wrap text wrap
            // to the container's left edge, so continuation lines restarted under
            // the timestamp. A 3-column grid gives the message its own 1fr column;
            // wrapping stays inside it, so every line aligns with the first.
            #expect(sheet.contains(".log-line {\n      display: grid;\n      grid-template-columns: auto auto 1fr;"),
                    "the log line must be a 3-column grid (time / lvl / message) (UX-25)")
            #expect(sheet.contains(".log-line .log-msg { color: var(--text); min-width: 0; }"),
                    "the message cell must be allowed to shrink so it wraps inside its own column")
            #expect(!sheet.contains(".log-line {\n      display: flex; align-items: baseline; gap: 10px;"),
                    "the flex log line is gone — that layout wrapped continuation text to column 0")
        }

        // MARK: - UX-19 responsive chrome: overlay drawer + compact rail (T12)

        @Test("below 1024px the panel is an overlay drawer with a topbar toggle and scrim")
        func responsiveDrawerChrome() {
            let views = Self.views
            // The toggle is a real button in the topbar (client-owned; CSS hides
            // it at >= 1024px). It must be keyboard-reachable and announce state.
            #expect(views.contains("btn(\"drawer-toggle\", \"\", \"drawer-toggle-btn\", \"&#9776;\","),
                    "the drawer-toggle button must be rendered in the topbar")
            #expect(views.contains("aria-label=\"Toggle sidebar\" aria-expanded=\"false\""),
                    "the toggle must be labelled and start aria-expanded=false")
            // The scrim is the outside-click dismissal surface; it must live in
            // the shell so every tab gets one.
            #expect(views.contains("id=\"drawer-scrim\" class=\"drawer-scrim\" aria-hidden=\"true\""),
                    "the drawer scrim must be part of the app shell, not one tab")
            let css = Self.sheetSource
            // Below 1024px the panel docks over the chat (fixed, off-canvas at
            // rest, `visibility: hidden` so closed controls leave the tab order).
            #expect(css.contains("@media (max-width: 1023.98px) {"),
                    "the drawer breakpoint must exist")
            #expect(css.contains("position: fixed; top: 38px; bottom: 0; left: var(--iconbar-w);"),
                    "the panel must become a fixed overlay below the topbar, clear of the rail")
            // UX-61: the drawer starts AFTER the rail so the rail is never the
            // thing the panel hides. Panel and scrim are both offset by
            // `--iconbar-w`, so a rail tap reaches the button instead of the
            // scrim ("the sidebar icons don't work" on a narrow window).
            #expect(css.contains("transform: translateX(calc(-100% - var(--iconbar-w)));"),
                    "the closed drawer must be slid off-canvas, past the rail")
            #expect(css.contains(".drawer-scrim { left: var(--iconbar-w); }"),
                    "the scrim must dim the content column but never the rail")
            #expect(css.contains("visibility: hidden;"),
                    "the closed drawer's controls must leave the tab order (visibility, not just transform)")
            #expect(css.contains("#app.drawer-open #panel {\n        transform: translateX(0);\n        visibility: visible;"),
                    "the open state must live on #app (survives panel re-renders) and reveal the drawer")
            #expect(css.contains("#app.drawer-open .drawer-scrim { opacity: 1; pointer-events: auto; }"),
                    "the scrim must dim the chat and swallow outside clicks only while open")
            #expect(css.contains("@media (min-width: 1024px) { .drawer-toggle-btn { display: none; } }"),
                    "at >= 1024px the toggle must be gone (and with it its tab stop)")
            #expect(css.contains("@media (min-width: 1024px) { .drawer-scrim { display: none; } }"),
                    "at >= 1024px the scrim must not exist")
        }

        @Test("below 720px the rail compacts but keeps >= 40px hit targets, and the floats re-anchor")
        func compactRailAndFloatLane() {
            let css = Self.sheetSource
            #expect(css.contains("@media (max-width: 719.98px) {"),
                    "the compact breakpoint must exist")
            #expect(css.contains(":root { --iconbar-w: 46px; }"),
                    "the rail must compact at narrow widths")
            #expect(css.contains(".icon-btn { font-size: 17px; border-radius: 10px; }"),
                    "rail glyphs get smaller at the compact breakpoint")
            #expect(!css.contains(".icon-btn { width: 40px; height: 40px; font-size: 17px;"),
                    "the 40px icon-btn hit target must survive the compact breakpoint untouched")
            #expect(css.contains("#main .chat-scroll { padding: 0 48px 0 12px !important; }"),
                    "the transcript gutter narrows with the rail, keeping a lane for the floats")
            #expect(css.contains("#outline-toggle { right: 8px; }"),
                    "the outline circle re-anchors flush to the edge inside the lane")
            #expect(css.contains(".scroll-to-bottom-btn { right: 8px; }"),
                    "the jump circle re-anchors flush to the edge inside the lane")
        }

        @Test("the overlay owns drawer open/close: Escape, outside click, session pick, breakpoint reset")
        func overlayDrawerLogic() {
            let overlay = Self.overlay
            #expect(overlay.contains("function openDrawer()"), "an open path must exist")
            #expect(overlay.contains("function closeDrawer(returnFocus)"), "a close path must exist")
            #expect(overlay.contains("a.classList.add('drawer-open')"),
                    "open must flip the class on #app, not #panel (the panel node is replaced by patches)")
            #expect(overlay.contains("a.classList.remove('drawer-open')"), "close must undo the class")
            #expect(overlay.contains("if (drawerOpen()) closeDrawer(true);\n      else openDrawer();"),
                    "the toggle must toggle (and return focus on close)")
            #expect(overlay.contains("t.closest('#drawer-scrim')"), "outside click (the scrim) must close")
            #expect(overlay.contains("t.closest('.sess-row') || t.closest('#chat-new')"),
                    "picking a conversation (or minting one) must close the drawer")
            #expect(overlay.contains("t.closest('#iconbar')"),
                    "a rail switch must close the drawer so the chosen view owns the canvas (UX-61)")
            #expect(overlay.contains("if (isNarrow() && drawerOpen()) { closeDrawer(true); return; }"),
                    "Escape must own the drawer while it is open, before the other Escape targets")
            #expect(overlay.contains("mq.addEventListener('change'"),
                    "growing past the breakpoint must reset the drawer state so aria stays honest")
            // Focus moves into the drawer on open and back to the toggle on close —
            // the keyboard path in and out of the drawer.
            #expect(overlay.contains("p.querySelector('input') || p.querySelector('a[href], button, select, textarea, [tabindex]')"),
                    "open must focus a real control inside the drawer (search input preferred, anchors for settings)")
            #expect(overlay.contains("if (returnFocus && t && t.focus) t.focus({ preventScroll: true });"),
                    "close must return focus to the toggle")
        }

        // MARK: - UX-60/61/62 (round 8): the "stuck in Settings" freeze, the
        // drawer covering the rail, and the empty-draft clutter.

        /// UX-60 — the S1 freeze. A Settings sub-nav row is `<a href="#appearance">`.
        /// Left to the browser the hash jump pushes a history entry and fires
        /// `popstate`; the engine reports that as a `navigate` frame, and the
        /// server's navigate re-render RESETS the render session arc registered its
        /// handlers in at boot. Every control then goes dead — the rail, the
        /// settings chips, the composer — until the server restarts. The overlay
        /// must intercept the jump so the URL (and the history stack) never move.
        @Test("in-page #anchors are intercepted so they can never fire a navigate")
        func inPageAnchorsDoNotNavigate() {
            let overlay = Self.overlay
            #expect(overlay.contains("closest('a[href^=\"#\"]')"),
                    "the overlay must intercept same-page anchors before the browser navigates")
            #expect(overlay.contains("e.preventDefault();"),
                    "the jump must be prevented (no hash change → no popstate → no navigate frame)")
            #expect(overlay.contains("target.scrollIntoView"),
                    "the anchor must still move the view to its target")
            #expect(overlay.contains("target.focus({ preventScroll: true })"),
                    "a control target must receive focus (that is the skip link's whole job)")
            // The settings sub-nav rows must stay real, named, focusable links.
            let views = Self.views
            for sec in ["appearance", "preferences", "storage", "tool-plugins", "sidebar-plugins", "about"] {
                #expect(views.contains("<a href=\"#\(sec)\""),
                        "the settings sub-nav must keep its #\(sec) anchor")
            }
        }

        /// UX-62 — empty drafts. The list showed three identical "New chat · 0 msg"
        /// rows with no way to remove them. The cleanup is guarded by the shared
        /// confirm modal, and the delete is judged on the store-backed count: a
        /// summary's `messages` is empty BY DESIGN, so a structural read alone
        /// would delete real conversations.
        @Test("the empty-draft cleanup is guarded, honest about emptiness, and spares the open chat")
        func emptyDraftCleanup() {
            let views = Self.views
            #expect(views.contains("\"chat-clear-empty\""), "the Chats panel must offer the cleanup")
            #expect(views.contains("Clear \\(clearableDrafts) empty chat"),
                    "the affordance must state how many drafts it will remove")
            #expect(views.contains("let clearBtn = (!todos && !showArchived && clearableDrafts > 0)"),
                    "the cleanup must be hidden where it does not apply (Todos page, archived view, nothing to clear)")
            let actions = Self.actions
            #expect(actions.contains("wire(router, id: \"chat-clear-empty\""), "the control must be wired")
            #expect(actions.contains("case \"empty-drafts\":"), "the shared confirm modal must dispatch the bulk delete")
            let app = Self.appStateActions
            #expect(app.contains("func clearEmptyDrafts() async -> Int"), "the bulk delete must exist")
            #expect(app.contains("$0.messageCount == 0 && $0.id != keep"),
                    "emptiness must be read from the store-backed count, and the open chat kept")
            #expect(app.contains("await ensureSessionMessages(s.id)"),
                    "each candidate must be materialized before it is judged empty")
            #expect(app.contains("if sessions[i].messages.isEmpty { doomed.append(s.id) }"),
                    "a summary's empty `messages` alone must never be enough to delete")
            #expect(app.contains("undoableDelete = nil"),
                    "a bulk delete must not ride the single-slot undo")
        }

        /// UX-61 — the rail must survive the drawer. The scrim is offset by the
        /// rail width, and a rail tap closes the drawer.
        @Test("the narrow-width drawer clears the rail, and a rail tap closes it")
        func drawerClearsRail() {
            #expect(Self.sheetSource.contains(".drawer-scrim { left: var(--iconbar-w); }"),
                    "the scrim must not cover the rail")
            #expect(Self.overlay.contains("t.closest('#iconbar')"),
                    "a rail switch must close the drawer")
        }

        /// A placeholder is not a label: it vanishes on input and is not an
        /// accessible name. Every filter field needs one.
        // MARK: - UX-03 (2026-10-18 wave 2) Settings gear reachable at short heights

        /// At 1280×577 the 12-icon rail (570px at default spacing) overflowed the
        /// 539px app body and pushed the Settings gear below the fold with no
        /// scroll path. The bottom slot must be pinned to the rail's bottom edge
        /// (out of flow) and the rail must compact at short heights; the geometry
        /// freedoms that made the old inline styles unreachable are gone too.
        @Test("the icon rail compacts at short heights and pins the Settings slot")
        func iconRailKeepsSettingsReachable() {
            let css = Self.sheetSource
            let views = Self.views
            #expect(css.contains("#iconbar .iconbar-bottom {\n      position: absolute; bottom: 6px; left: 0; right: 0;"),
                    "the Settings slot must be pinned to the rail's bottom edge (UX-03)")
            #expect(!css.contains("#iconbar .iconbar-bottom { margin-top: auto; }"),
                    "the margin-top:auto pin is back: an over-full rail pushes the gear below the fold")
            #expect(css.contains("@media (max-height: 640px) {"),
                    "the short-height compaction breakpoint must exist (UX-03)")
            #expect(css.contains("#iconbar { gap: 2px; padding: 6px 0; }"),
                    "the rail must compact at short heights (was 6px gaps / 12px padding)")
            #expect(!views.contains("style=\"display:flex;flex-direction:column;gap:6px;align-items:center;\""),
                    "the inline group styles (which blocked any compaction rule) must stay gone")
        }

        // MARK: - UX-04 (2026-10-18 wave 2) markdown tables scroll instead of breaking tokens

        /// At 1024 the six-column target table compressed its columns and
        /// `.msg-body`'s `overflow-wrap: anywhere` split identifiers and
        /// numbers mid-word (`ArcAgentCo` / `re`, `~28,0` / `00`). The renderer
        /// now wraps tables in `.msg-table-wrap` (asserted in MarkdownParityTests)
        /// and the sheet gives the wrapper the horizontal overflow contract,
        /// with cells breaking only at word boundaries.
        @Test("markdown tables size to their content and scroll in a wrapper, never breaking identifiers mid-word")
        func markdownTablesScrollInsteadOfBreakingTokens() {
            let css = Self.sheetSource
            #expect(css.contains(".msg-table-wrap { overflow-x: auto; max-width: 100%; }"),
                    "the table wrapper must own the horizontal scroll (UX-04)")
            #expect(css.contains(".msg-table-wrap table { min-width: 100%; }"),
                    "the table must at least fill the wrapper so headers span it (UX-04)")
            #expect(css.contains(".msg-body table th,\n    .msg-body table td { overflow-wrap: break-word; }"),
                    "cells must break only at word boundaries — the inherited `anywhere` split identifiers (UX-04)")
            #expect(!css.contains(".msg.assistant .msg-body table { display: block; overflow-x: auto; max-width: 100%; }"),
                    "the old display:block table rule is gone — with the wrapper it clipped the scroll path (UX-04)")
        }

        // MARK: - UX-06 (2026-10-18 wave 2) full session title on hover + accessible name

        /// Identical 40-char-truncated titles made conversations
        /// indistinguishable: the visible clamp is fine, but the full stored
        /// title must ride the row's `title`, its accessible name, and a
        /// `data-full-title` attribute that the rename flow seeds from
        /// (wave 4, UX-21) — seeds it from the rendered text and the stored
        /// title is silently lost.
        @Test("session rows carry the full title on hover, as their accessible name, and in data-full-title")
        func sessionRowsCarryTheFullTitle() {
            let views = Self.views
            // Both row variants (chat list and todos page) must splice the
            // full-title attribute bundle in (exactly two splice sites).
            let splice = views.components(separatedBy: "role=\"group\"\\(fullAttr)").count
            #expect(splice == 3,
                    "both session-row variants must splice the full-title bundle on the row (found \\(splice - 1) sites)")
            #expect(views.contains("title=\"\\(esc(full))\" aria-label=\"\\(esc(full))\" data-full-title=\"\\(esc(full))\""),
                    "the bundle must carry title + aria-label + data-full-title, all with the FULL stored title (UX-06)")
            #expect(!views.contains("role=\"group\" aria-label=\"\\(esc(title))\""),
                    "the accessible name must no longer be the 40-char truncated string (UX-06)")
        }

        // MARK: - UX-08 (2026-10-18 wave 2) names, pressed state, sort labels, focus restore

        /// The audit found 16 visible buttons with no text/aria/title (12 rail
        /// icons + regen + chat-del + file + bookmark) and selection cards that
        /// only painted `.active`. Icon-only controls need real accessible
        /// names; selection cards need aria-pressed mirroring the selection.
        @Test("icon-only shell buttons carry accessible names and selection cards carry aria-pressed")
        func shellButtonsAreNamedAndSelectionIsPressed() {
            let views = Self.views
            // Every rail icon (nav-<id>) keeps its data-tip pill AND gains an
            // aria-label for AT/touch (the pill is hover-only). Settings too.
            #expect(views.contains("data-tip=\"\\(esc(tab.title))\" aria-label=\"\\(esc(tab.title))\""),
                    "each rail button must pair its hover pill with an aria-label (UX-08)")
            #expect(views.contains("data-tip=\"Settings\" aria-label=\"Settings\""),
                    "the Settings rail button must carry an aria-label (UX-08)")
            // Theme / text-size / scheme cards mark selection with .active —
            // that state must reach assistive tech as aria-pressed.
            #expect(views.contains("class=\"theme-pick-btn\\(active)\" title=\"\\(t.label)\" aria-pressed=\"\\(pressed)\""),
                    "theme cards must reflect selection via aria-pressed (UX-08)")
            #expect(views.contains("class=\"font-size-pick-btn\\(active)\" title=\"\\(s.label)\" aria-pressed=\"\\(pressed)\""),
                    "text-size cards must reflect selection via aria-pressed (UX-08)")
            #expect(views.contains("aria-pressed=\"\\(pressed)\" style=\"--sw-accent:\\(accent)\""),
                    "scheme tiles must reflect selection via aria-pressed (UX-08)")
        }

        /// The markdown-table enhancer minted sort buttons whose whole accessible
        /// name was the '⇅' glyph, a filter input with only a placeholder, and no
        /// sort-order announcement; and closing the delete modal dropped focus to
        /// <body> because the modal's own focus moves overwrote the generic
        /// patch-restore's memory.
        ///
        /// The focus fix is pinned at the mechanism, not the symptom: the very
        /// patch that OPENS the dialog re-renders the chat header and disconnects
        /// the focused trigger, so the trigger has to be snapshotted by a
        /// capture-phase click listener BEFORE that patch (focus-time recording
        /// already sees <body>), and restore has to resolve the snapshot through
        /// the session row's data-sid because the trigger's node gets replaced.
        ///
        /// Wave-2: the close round-trip delivers several fragment patches in one
        /// batch, so restore is keyed to syncModalFocus's open→closed transition
        /// (modalWasOpen) — it fires exactly on the pass where the card is first
        /// gone, and no early-clear guard may wipe the memory while an earlier
        /// fragment still has the dialog in the DOM.
        @Test("table sort/filter controls are named and the modal returns focus to its trigger")
        func tableControlsNamedAndModalRestoresFocus() {
            let overlay = Self.overlay
            #expect(overlay.contains("sort.setAttribute('aria-label', 'Sort by '"),
                    "the sort button must announce the column it sorts (UX-08)")
            #expect(overlay.contains("hc.removeAttribute('aria-sort')"),
                    "aria-sort must be cleared from the other columns on each sort (UX-08)")
            #expect(overlay.contains("target.setAttribute('aria-sort', dir === 'asc' ? 'ascending' : 'descending')"),
                    "the sorted column must announce ascending/descending (UX-08)")
            #expect(overlay.contains("filter.setAttribute('aria-label', 'Filter table rows')"),
                    "the filter field needs an accessible name — a placeholder is not one (UX-08)")
            // The modal block: state, pointer capture, sync, restore, then the
            // Escape/Tab trap. Scoped so the pins cannot match lookalike code
            // elsewhere in the overlay (six other document click listeners).
            guard let m0 = overlay.range(of: "var modalReturnFocus = null;"),
                  let m1 = overlay.range(of: "document.addEventListener('keydown', function (e) {",
                                         range: m0.upperBound..<overlay.endIndex) else {
                #expect(Bool(false), "the modal focus block (state + capture + sync + restore) must exist (UX-08)")
                return
            }
            let modal = overlay[m0.lowerBound..<m1.lowerBound]
            #expect(modal.contains("document.addEventListener('click', function (e) {") &&
                    modal.contains("closest('[id]')") &&
                    modal.contains("}, true);"),
                    "the trigger must be snapshotted by a capture-phase click listener, before the patch that adds the dialog replaces it (UX-08)")
            #expect(modal.contains("modalReturnFocus = { id: (t.id || '').trim(), sid: rowSidOf(t) };"),
                    "the snapshot must remember the activated control by id and session-row sid (UX-08)")
            #expect(modal.contains("card.contains(e.target)"),
                    "clicks inside the dialog itself must not overwrite the remembered trigger (UX-08)")
            #expect(modal.contains("!modalReturnFocus && document.activeElement") &&
                    !modal.contains("document.activeElement !== document.body &&"),
                    "when the modal patch has already dropped focus to <body>, syncModalFocus must keep/proceed with the pointer snapshot instead of skipping — the old body-excluding gate is what lost the trigger (UX-08)")
            #expect(modal.contains("rowSidOf(document.activeElement)"),
                    "a live non-body trigger is still recorded by sid as a fallback (UX-08)")
            #expect(modal.contains("var modalWasOpen = false;") && modal.contains("modalWasOpen = true;"),
                    "syncModalFocus must track the open/closed transition so the restore fires only after the removal patch lands (UX-08)")
            #expect(modal.contains("if (modalWasOpen) {") &&
                    modal.contains("restoreFocusToTrigger();") &&
                    modal.contains("modalWasOpen = false;"),
                    "the restore must run exactly once, on the pass where the card is first gone (UX-08)")
            #expect(!modal.contains("document.activeElement !== document.body) { modalReturnFocus = null"),
                    "no early-clear guard may wipe the trigger memory while the dialog is still present in the DOM (UX-08)")
            #expect(modal.contains("function restoreFocusToTrigger()"),
                    "a restore path for the dialog's trigger must exist (UX-08)")
            #expect(modal.contains(".sess-row[data-sid]") && modal.contains("getAttribute('data-sid') === sid"),
                    "restore must resolve the trigger's replacement through the session row's data-sid (UX-08)")
            #expect(modal.contains("nu.setAttribute('tabindex', '0')"),
                    "a re-focused session row must become keyboard-focusable (UX-08)")
            #expect(modal.contains("if (!nu) return;"),
                    "an unresolvable trigger (the session was actually deleted) must no-op, not throw (UX-08)")
            #expect(!overlay.contains("restoreModalFocus();"),
                    "the restore must ride syncModalFocus's transition — no separate post-patch call that could double-fire (UX-08)")
        }

        // MARK: - UX-07 (2026-10-18 wave 2) collapse the rail on narrow widths

        /// At 480×900 the 12-icon vertical rail persisted and ate a 46px column
        /// (rail 46 / main 434). Below 600px the rail must collapse into a
        /// horizontal strip under the topbar: window never scrolls horizontally
        /// (the strip's own overflow owns that), Settings stays pinned at the
        /// visible right edge, and the drawer clears the strip so every nav
        /// destination stays reachable.
        @Test("below 600px the rail collapses to a horizontal strip without taxing the window width")
        func railCollapsesAtNarrowWidths() {
            let css = Self.sheetSource
            #expect(css.contains("@media (max-width: 599.98px) {"),
                    "the rail-collapse breakpoint must exist below 600px (UX-07)")
            #expect(css.contains("#app-body { flex-direction: column; }"),
                    "the app body must stack so the rail stops taxing the window width (UX-07)")
            let railBlock = "@media (max-width: 599.98px) {"
            guard let r0 = css.range(of: railBlock) else { return }
            let rest = css[r0.upperBound...]
            let block = rest.prefix(900)
            #expect(block.contains("flex: 0 0 auto; width: 100%; height: 44px;"),
                    "the rail must become a full-width horizontal strip (UX-07)")
            #expect(block.contains("flex-direction: row; align-items: center;"),
                    "the strip lays its icons out in a row (UX-07)")
            #expect(block.contains("overflow-x: auto; overflow-y: hidden;"),
                    "the strip scrolls internally so the WINDOW never overflows (UX-07)")
            #expect(block.contains("position: sticky; bottom: auto; left: auto; right: 0;"),
                    "the Settings slot must stay pinned to the visible right edge of the strip (UX-07)")
            #expect(block.contains("#panel { top: 82px; left: 0; width: 100vw; }"),
                    "the drawer must open below the rail strip so the rail stays tappable (UX-07)")
        }

        @Test("the filter fields carry accessible names")
        func filterFieldsAreNamed() {
            let views = Self.views
            #expect(views.contains("aria-label=\"Filter conversations\""), "the conversation filter must be named")
            #expect(views.contains("aria-label=\"Filter skills\""), "the skills filter must be named")
            #expect(views.contains("aria-label=\"Search workspaces\""), "the workspace search must be named")
            #expect(views.contains("aria-label=\"Search models\""), "the model search must be named")
        }

        @Test("outline entries are client-side links that keep the panel open")
        func outlineEntriesKeepPanelOpen() {
            let overlay = Self.overlay
            #expect(overlay.contains("var b = document.createElement('a')"),
                    "outline entries must be <a> links, not <button>s (UX-20)")
            #expect(overlay.contains("b.href = '#' + m.id"),
                    "each entry must point at its message anchor (UX-20)")
            #expect(overlay.contains("e.preventDefault();"),
                    "entry click must be prevented from server round-trip (UX-20)")
            #expect(overlay.contains("e.preventDefault();"),
                    "outline entry click must be prevented from server round-trip (UX-20)")
            #expect(overlay.contains("m.scrollIntoView({ block: 'start', behavior: 'smooth' })"),
                    "outline entry click must scroll the target message into view (UX-20)")
            #expect(overlay.contains("m.scrollIntoView({ block: 'start', behavior: 'smooth' })"),
                    "entry click must scroll the target message into view (UX-20)")
        }

        // MARK: - UX-21 (wave 4) rename seeds from the full stored title

        @Test("rename input seeds from data-full-title, not the truncated row text")
        func renameSeedsFromFullTitle() {
            let overlay = Self.overlay
            let views = Self.views
            #expect(views.contains("data-full-title="),
                    "the session row must carry the full stored title (UX-06/UX-21)")
            #expect(overlay.contains("row.getAttribute('data-full-title')"),
                    "rename must seed from the row's data-full-title (UX-21)")
            #expect(overlay.contains("data-full-title"),
                    "rename must not seed from the truncated row text (UX-21)")
        }

    }
}
