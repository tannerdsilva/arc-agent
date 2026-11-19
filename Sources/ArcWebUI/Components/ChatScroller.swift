import WebUI

/// The chat transcript scroller: one open tag that states the engine's three
/// scroll consequences — follow across deltas (`data-follow`), the reading
/// keys (`data-reading-keys`) and the per-session position memory
/// (`data-scroll-key`, keyed by conversation) — plus the focusability the
/// reading keys need. The engine writes `data-follow-state="away"` itself;
/// that output is never an input here.
///
/// **A component, not a modifier chain**, for the same reason `UploadZone` is
/// one: `chatMain()` participates in the shell's `TupleView`, and four more
/// modifier nodes on this element segfault every render (measured: signal 11
/// in the render-parity suite — the D-5(a′) bad pack-copy retain, not a stack
/// overflow). Writing the attributes into the element's own open tag adds the
/// markup and leaves the chain untouched.
///
/// `session` is the conversation id, not a constant key: a rail return
/// restores this chat's offset and a session switch never inherits another
/// chat's. The engine ignores an empty key, so an unauthenticated render emits
/// none.
struct ChatScroller<Content: WebUI.View>: WebUI.View {
    /// the id the scroller is keyed by — `chat-scroll` in the chat panel.
    var id: String
    /// the conversation this transcript belongs to; the scroll-memory key.
    var session: String
    let content: Content

    init(
        id: String = "chat-scroll",
        session: String,
        @ElementBuilder content: () -> Content
    ) {
        self.id = id
        self.session = session
        self.content = content()
    }

    func render(into buffer: inout HTMLBuffer) {
        var attributes = " id=\"\(htmlEscape(id))\""
        attributes += " class=\"\(htmlEscape(ClassName(.chatScroll).value))\""
        attributes += " data-session=\"\(htmlEscape(session))\""
        attributes += ScrollFollowAttribute(mode: .bottom).attributeText
        attributes += ReadingKeysAttribute().attributeText
        if !session.isEmpty {
            attributes += ScrollKeyAttribute(key: session).attributeText
        }
        // `data-reading-keys` acts only while the region contains focus.
        attributes += " tabindex=\"0\""
        buffer.beginElement("div", attributes)
        buffer.endOpenTag()
        content.render(into: &buffer)
        buffer.endElement()
    }
}
