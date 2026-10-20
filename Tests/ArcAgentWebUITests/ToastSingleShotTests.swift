/// Single-shot semantics for the `pendingCopyURL` marker.
///
/// The builder reads `pendingCopyURL`, emits the `<span id="pending-copy" data-copy-url="…">`
/// marker, and clears it — all before any view renders. A second render of the same
/// fragment must not contain the marker, because a later toast push must never
/// re-emit the link.
@testable import ArcWebUI
import Testing

@Suite("Toast single-shot", .serialized)
struct ToastSingleShotTests {

    @Test("the pending-copy marker is emitted on the first render and cleared on the second")
    func pendingCopyIsSingleShot() async {
        var fixture = AppState.RenderFixture()
        fixture.toasts = [Toast(id: 1, text: "Conversation deleted", kind: "info")]
        fixture.pendingCopyURL = "https://example.com/x"

        let app = AppState(renderFixture: fixture)
        let first = await app.toastsHTML().markup.html

        #expect(first.contains("id=\"pending-copy\" data-copy-url=\"https://example.com/x\""),
                "the first render must carry the pending-copy marker")
        #expect(first.contains("<span id=\"pending-copy\""),
                "the first render must emit an empty <span> (the legacy spelling)")

        // A second render of the same fragment — the consumer re-renders #toasts
        // after a push — must not re-emit the marker. The builder cleared it.
        let second = await app.toastsHTML().markup.html
        #expect(!second.contains("pending-copy"),
                "the second render must not contain the pending-copy marker: single-shot state is gone")
    }

    @Test("a render without a pending URL emits no marker at all")
    func noPendingUrlRendersNothing() async {
        let app = AppState(renderFixture: .init(toasts: [Toast(id: 1, text: "One", kind: "info")]))
        let html = await app.toastsHTML().markup.html
        #expect(!html.contains("pending-copy"),
                "with no pendingCopyURL there is no marker node to emit")
    }
}
