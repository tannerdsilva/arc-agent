import WebUICore

// What a dispatched handler answered — the one assertion the render-contract
// suites share.
//
// 2.9.0 replaced the app-installed structural signal with
// `HandlerOutcome.refresh`: a handler no longer pushes an empty batch at a door
// the host installed, it answers the framework with the outcome the server
// turns into a re-render of the dispatch session's page. So the assertion that
// used to count nudges on a test door is now a question about the outcome
// itself — one outcome, one re-render, and the originating socket writes
// nothing by hand.
extension HandlerOutcome {
    /// the structural signal: re-render the page this event was dispatched in.
    var isRefresh: Bool {
        if case .refresh = self { return true }
        return false
    }
}
