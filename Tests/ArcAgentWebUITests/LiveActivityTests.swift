import Foundation
import Testing
@testable import arc_agent_webui

/// Renderer coverage for the live tool-activity rows (streaming bubble).
///
/// The user-facing requirement: while a turn is processing, every tool call
/// appears in the chat as it happens — the old live bubble only showed
/// name chips in `transparent_stream` mode and nothing visible in
/// `compact_worklog`, so tool calls were invisible until the turn completed
/// and the user opened the "Processed Xm Ys" worklog.
@Suite("Live tool activity rows")
struct LiveActivityTests {

    @Test("Empty rounds render nothing")
    func emptyRounds() {
        #expect(AppState.liveToolRoundsHTML([]) == "")
    }

    @Test("Running and done rounds render visible rows")
    func rendersBothStates() {
        let rounds = [
            LiveToolRound(id: "c1", name: "terminal", args: "pwd\nls", status: "running", resultPreview: nil),
            LiveToolRound(id: "c2", name: "read_file", args: "foo.swift", status: "done", resultPreview: "line 1\nline 2"),
        ]
        let html = AppState.liveToolRoundsHTML(rounds)
        #expect(html.contains("live-tool-stack"))
        #expect(html.contains("terminal</span>"))
        #expect(html.contains("read_file</span>"))
        #expect(html.contains("lt-state running"))
        #expect(html.contains("lt-state done"))
        #expect(html.contains("lt-preview"))
        #expect(html.contains("line 1"))
        // Elapsed args collapse whitespace for the inline row.
        #expect(html.contains("pwd ls"))
    }

    @Test("HTML in tool names, args, and previews is escaped")
    func escaping() {
        let rounds = [
            LiveToolRound(
                id: "c1",
                name: "terminal",
                args: "<script>alert(1)</script>",
                status: "done",
                resultPreview: "</div><img src=x onerror=alert(2)>"
            ),
        ]
        let html = AppState.liveToolRoundsHTML(rounds)
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;img"))
    }
}
