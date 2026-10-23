import WebUI
import WebUIDesignSystem

/// A typed button that replaces `Helpers.btn(...)` and every literal `<button>`.
///
/// Content has exactly one source: a text label, or a view builder — never both.
/// The `@HTMLComponent` macro generates one init per content case; every stored
/// property becomes a shared parameter (order and defaults preserved).
///
/// `component: nil` and `component: ""` both omit `data-component-id` — the
/// engine matches on attribute presence, so `data-component-id=""` would shadow
/// its container and swallow the click. A non-empty component emits the attribute.
///
/// `routing` is the typed escape for the four sites whose `data-component-id`
/// differs from their `id` (`cb-send`→`stop-turn`, `sk-edit`→`skill-edit`,
/// `sk-delete`→`skill-delete`, `skill-new-main`→`skill-new`). When `routing` is
/// non-nil it wins over `component`; otherwise `component` is used as before.
///
/// `disabled` and `hidden` emit `name=""` (boolean attribute spelling), never
/// `name="false"`, and are omitted when false.
@HTMLComponent(.text("label", unlabeled: true), .builder("views"))
public struct ArcButton: WebUI.View {

	public enum ButtonType: String, Sendable {
		case button = "button"
		case submit = "submit"
	}

	public var id: String? = nil
	public var component: String? = nil
	public var routing: ComponentID? = nil
	public var `class`: String
	public var type: ButtonType = .button
	public var tabIndex: Int? = nil
	public var disabled: Bool = false
	public var hidden: Bool = false

	public func render(into buffer: inout HTMLBuffer) {
		var attributes = ""
		if let id { attributes += " id=\"\(htmlEscape(id))\"" }
		let componentId = routing.map { $0.value } ?? component
		if let componentId, !componentId.isEmpty {
			attributes += " data-component-id=\"\(htmlEscape(componentId))\""
		}
		if !self.class.isEmpty {
			attributes += " class=\"\(htmlEscape(self.class))\""
		}
		attributes += " type=\"\(type.rawValue)\""
		if let tabIndex { attributes += " tabindex=\"\(tabIndex)\"" }
		if disabled { attributes += " disabled=\"\"" }
		if hidden { attributes += " hidden=\"\"" }

		buffer.beginElement("button", attributes)
		buffer.endOpenTag()
		switch content {
		case .label(let label): Text(label).render(into: &buffer)
		case .views(let views): for view in views { view.render(into: &buffer) }
		}
		buffer.endElement()
	}
}
