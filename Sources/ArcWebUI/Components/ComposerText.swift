import WebUI
import WebUICore

/// The composer's textarea: one open tag that carries every consequence the
/// engine reads off it — the autogrow pass (`data-autogrow`), the draft's
/// per-chat identity and its server-rendered seed (no-webui 2.16.0's
/// `data-draft-id` / `data-draft-value`), and the routing attributes the
/// composer's own listeners key on.
///
/// **A component, not a modifier chain.** `chatMain()` participates in the
/// shell's `TupleView`, and the two draft behaviors on this textarea were the
/// fourth reproduction of D-5(a′): signal 11 in the render parity suite the
/// moment `DraftIdentity` + `DraftSeed` joined a six-modifier chain. Writing
/// the attributes into the element's own open tag adds the markup and leaves
/// the chain empty — the same mitigation `ChatScroller` and `UploadZone` carry.
///
/// `session` is the conversation this draft belongs to, not a constant key: the
/// engine's identity change (a session switch) writes `seed` and rewrites
/// `webui-draft:<session>`, so the reader's unsubmitted text never leaks into
/// another chat. A same-identity patch leaves the reader's keystrokes alone.
/// `seed` travels separately from the element's own value because `value` is
/// written as the textarea's text content, which the engine's state restore
/// overwrites with the pre-patch value.
struct ComposerText: WebUI.View {
    /// the field identity — `id` and `name`, one spelling.
    var field: FieldID
    /// the routing identity the engine dispatches `data-event` on.
    var component: String
    var placeholder: String
    /// the server's text: both the rendered content and the draft's seed.
    var value: String
    /// the conversation whose draft this is.
    var session: String
    var rows: Int

    init(
        field: FieldID,
        component: String,
        placeholder: String = "",
        value: String = "",
        session: String,
        rows: Int = 1
    ) {
        self.field = field
        self.component = component
        self.placeholder = placeholder
        self.value = value
        self.session = session
        self.rows = rows
    }

    func render(into buffer: inout HTMLBuffer) {
        var attributes = " id=\"\(htmlEscape(field.rawValue))\""
        attributes += " name=\"\(htmlEscape(field.rawValue))\""
        attributes += " rows=\"\(rows)\""
        if !placeholder.isEmpty {
            attributes += " placeholder=\"\(htmlEscape(placeholder))\""
        }
        attributes += " data-component-id=\"\(htmlEscape(component))\""
        attributes += AutogrowAttribute().attributeText
        // `data-session` is read by the round4 UX-40 gate, which witnesses the
        // switch by it; the identity below is the engine's own key.
        attributes += " data-session=\"\(htmlEscape(session))\""
        attributes += DraftIdentityAttribute(key: session).attributeText
        attributes += DraftSeedAttribute(text: value).attributeText
        // the sheet's `.composer-bar textarea` rule owns the box: `min-height:
        // 24px` and the `max-height: 180px` cap the old client resizer computed
        // in JS both live there, so the element carries no inline style.
        attributes += " data-prevent-enter=\"send\""
        buffer.beginElement("textarea", attributes)
        buffer.endOpenTag()
        buffer.appendEscaped(value)
        buffer.endElement()
    }
}
