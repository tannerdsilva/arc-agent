import WebUI

/// A no-webui 2.11.0 upload zone: the element's own open tag names where a drop
/// lands (`data-upload-into`), the route it posts to (`data-upload-to`) and —
/// when a template is given — how the engine should name each file
/// (`data-upload-name-template`). The engine owns the transport for the whole
/// subtree: drag & drop (directories recurse), image paste, the XHR, progress
/// and the tray.
///
/// **A component, not a modifier chain.** `modalHTML()` records the cliff
/// (D-5(a)): a builder that participates in the shell's `TupleView` dies with
/// signal 11 once its modifier chain grows, and the fault is a bad retain in the
/// generated pack copy, not a stack overflow. Measured here: `#ws-dock` with
/// three more modifiers renders alone and segfaults every `appShell()` render.
/// Writing the attributes into the element's own open tag adds the markup and
/// leaves the chain untouched.
///
/// `component` + `event` are the routing identity the engine dispatches
/// `upload-complete` on: a zone that declares that event alone swallows no
/// click (the engine delivers only the event a component declares), which is why
/// the composer form — which must also submit — keeps its plain modifiers.
struct UploadZone<Content: WebUI.View>: WebUI.View {
    var id: String?
    var className: ClassName?
    /// where the file lands, as the route named it.
    var destination: UploadDestination
    /// the route the engine posts the body to.
    var route: String
    /// the filename template resolved before the path is composed; `nil` sends
    /// the file's own name and emits nothing.
    var nameTemplate: UploadNameTemplate?
    /// the component id `upload-complete` is dispatched on; `nil` leaves the zone
    /// unrouted (the upload still lands, nothing repaints).
    var component: String?
    /// the event this element declares.
    var event: HTMLEvent
    let content: Content

    init(
        id: String? = nil,
        className: ClassName? = nil,
        destination: UploadDestination,
        route: String = "/api/upload",
        nameTemplate: UploadNameTemplate? = nil,
        component: String? = nil,
        event: HTMLEvent = .click,
        @ElementBuilder content: () -> Content
    ) {
        self.id = id
        self.className = className
        self.destination = destination
        self.route = route
        self.nameTemplate = nameTemplate
        self.component = component
        self.event = event
        self.content = content()
    }

    func render(into buffer: inout HTMLBuffer) {
        var attributes = ""
        if let id { attributes += " id=\"\(htmlEscape(id))\"" }
        if let className { attributes += " class=\"\(htmlEscape(className.value))\"" }
        // the vocabulary owns the name and the spelling of both: `attributeText`
        // escapes the value and emits the bare form for an empty destination.
        attributes += destination.attributeText
        if let nameTemplate { attributes += nameTemplate.attributeText }
        attributes += " data-upload-to=\"\(htmlEscape(route))\""
        if let component, !component.isEmpty {
            attributes += Wire(ComponentID(component), on: event).attributeText
        }
        buffer.beginElement("div", attributes)
        buffer.endOpenTag()
        content.render(into: &buffer)
        buffer.endElement()
    }
}
