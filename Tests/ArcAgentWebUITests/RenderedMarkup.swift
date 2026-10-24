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
import ArcAgentCore
import Foundation
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
        case "panel":        return await app.panelHTML().markup.html
        case "main":         return await app.mainContentHTML().markup.html
        case "dock":         return await app.workspaceDockHTML().markup.html
        case "toasts":       return await app.toastsHTML().markup.html
        case "modal-root":   return await app.modalRootHTML().markup.html
        default:             return ""
        }
    }

    /// the session-list panel WITH rows in it: the default fixture seeds none,
    /// so a row pin rendered against it would silently assert nothing. one row is
    /// active (roving tab stop 0), one is archived, and the active row's title is
    /// longer than the 40-char display clamp so a "full title" pin can tell the
    /// full string from the truncated one.
    static func panelWithRows() async -> String {
        var fixture = seededFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    title: "A conversation title long enough to be truncated by the row clamp",
                    messageCount: 2, messages: []),
            Session(id: "sess-b", createdAt: Date(timeIntervalSince1970: 1_700_000_300),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_300), title: "Second chat",
                    messageCount: 1, messages: []),
        ]
        let app = AppState(renderFixture: fixture)
        return await app.panelHTML().markup.html
    }

    /// an assistant reply carrying a tool card and a foot: one render exercises
    /// the two copy buttons (tool arguments + response) and their tab order.
    static func assistantReplyWithToolCall() async -> String {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let m = Message(role: .assistant, content: "done",
                        toolCalls: [ToolCall(id: "call_1",
                                             function: ToolCallFunction(name: "read_file",
                                                                        arguments: "{\"path\":\"README.md\"}"))],
                        createdAt: t0)
        let app = AppState(renderFixture: seededFixture())
        return await app.messageHTML(m, rawIdx: 0).markup.html
    }

    /// a user and an assistant message with their address ids, for the
    /// streaming-push contract (the push targets `#msg-<rawIdx>`).
    static func addressedMessages() async -> String {
        let app = AppState(renderFixture: seededFixture())
        let user = await app.messageHTML(Message(role: .user, content: "hi"), rawIdx: 0).markup.html
        let assistant = await app.messageHTML(Message(role: .assistant, content: "hello"), rawIdx: 1).markup.html
        return user + assistant
    }

    /// the composer rendered with a live session and two model configs, so the
    /// dropdown rows and the send control all exist for pinning.
    static func composer() async -> String {
        var fixture = seededFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat",
                                    messageCount: 1, messages: [Message(role: .user, content: "hi")])]
        let app = AppState(renderFixture: fixture)
        return await app.composerHTML().markup.html
    }

    /// the composer with two model configs, so the dropdown actually has rows
    /// to render (a census against an empty list proves nothing).
    static func composerWithModels() async -> String {
        var fixture = seededFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat",
                                    messageCount: 1, messages: [Message(role: .user, content: "hi")])]
        fixture.settings.modelConfigs = [
            ModelConfigPreset(name: "primary", model: "gpt-4o", provider: "openai", baseURL: ""),
            ModelConfigPreset(name: "local", model: "llama-3", provider: "ollama", baseURL: "http://localhost:11434"),
        ]
        fixture.settings.activeConfig = "primary"
        let app = AppState(renderFixture: fixture)
        return await app.composerHTML().markup.html
    }

    /// the chat main region with a session, for outline/scroller pins.
    static func chatMain() async -> String {
        var fixture = seededFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat",
                                    messageCount: 1, messages: [Message(role: .user, content: "hi")])]
        let app = AppState(renderFixture: fixture)
        return await app.chatMain().markup.html
    }

    /// a compact-worklog turn block: one tool round plus a final reply.
    static func turnBlock() async -> String {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let app = AppState(renderFixture: seededFixture())
        let seg = [
            Message(role: .assistant, content: nil,
                    toolCalls: [ToolCall(id: "call_1",
                                         function: ToolCallFunction(name: "read_file",
                                                                    arguments: "{\"path\":\"README.md\"}"))],
                    createdAt: t0, reasoning: "thinking it over"),
            Message(role: .tool, content: "file contents", name: "read_file",
                    toolCallID: "call_1", createdAt: t0),
            Message(role: .assistant, content: "All done.", createdAt: t0, turnDuration: 3.2),
        ]
        return await app.turnBlockHTML(seg, mode: "compact_worklog", turnIndex: 1).map { render($0) } ?? ""
    }

    /// a running live turn: structural pins only — its elapsed label is clock
    /// derived, so it can never be pinned byte-for-byte.
    static func liveTurn() async -> String {
        let app = AppState(renderFixture: seededFixture())
        var live = LiveTurn(sessionID: "sess-a", userText: "hi", attachments: [])
        live.assistantText = "streaming reply"
        live.status = "tool"
        live.toolName = "read_file"
        live.toolStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        live.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return await app.liveMessageHTML(live).markup.html
    }

    /// the composer's queue row: two mid-stream sends waiting on the turn.
    static func queuedRow() async -> String {
        var fixture = seededFixture()
        fixture.activeSessionID = "sess-a"
        fixture.queuedSends = ["sess-a": [QueuedSend(id: 1, text: "first queued message"),
                                          QueuedSend(id: 2, text: "second queued message")]]
        let app = AppState(renderFixture: fixture)
        return await app.queuedSendsHTML().markup.html
    }

    /// the chat header rendered with a live session, for header-scoped pins.
    static func chatHeader() async -> String {
        var fixture = seededFixture()
        fixture.activeSessionID = "sess-a"
        fixture.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Pinned chat",
                    messageCount: 1, messages: [Message(role: .user, content: "hello")]),
        ]
        let app = AppState(renderFixture: fixture)
        return await app.chatHeaderHTML().markup.html
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
            results.append(contentsOf: controlTags(in: await app.renderPanel(for: kind).markup.html, region: "panel.\(kind.rawValue)"))
            results.append(contentsOf: controlTags(in: await app.renderMain(for: kind), region: "main.\(kind.rawValue)"))
        }
        results.append(contentsOf: controlTags(in: await app.workspaceDockHTML().markup.html, region: "workspace.dock"))
        results.append(contentsOf: controlTags(in: await app.workspacePanelHTML().markup.html, region: "workspace.panel"))
        results.append(contentsOf: controlTags(in: await app.workspaceBodyHTML().markup.html, region: "workspace.body"))
        results.append(contentsOf: controlTags(in: await app.workspaceTreeHTML().markup.html, region: "workspace.tree"))
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
            html += await app.renderPanel(for: kind).markup.html
            html += await app.renderMain(for: kind)
        }

        html += await app.workspaceDockHTML().markup.html
        html += await app.workspacePanelHTML().markup.html
        html += await app.workspaceBodyHTML().markup.html
        html += await app.workspaceTreeHTML().markup.html
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
