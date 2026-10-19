import WebUI

/// A typed button that replaces `Helpers.btn(...)` and every literal `<button>`.
///
/// `component: nil` and `component: ""` both omit `data-component-id` — the
/// engine matches on attribute presence, so `data-component-id=""` would shadow
/// its container and swallow the click. A non-empty component emits the attribute.
///
/// `disabled` and `hidden` emit `name=""` (boolean attribute spelling), never
/// `name="false"`, and are omitted when false.
public struct ArcButton: WebUI.View {
	public enum ButtonType: String, Sendable {
		case button = "button"
		case submit = "submit"
		case reset = "reset"
	}

	public let label: String
	public let id: String?
	public let component: String?
	public let `class`: String
	public let type: ButtonType
	public let tabIndex: Int?
	public let disabled: Bool
	public let hidden: Bool
	public let children: [any WebUI.View]

	public init(
		_ label: String,
		id: String? = nil,
		component: String? = nil,
		class: String,
		type: ButtonType = .button,
		tabIndex: Int? = nil,
		disabled: Bool = false,
		hidden: Bool = false,
		@ViewBuilder content: () -> [any WebUI.View] = { [] }
	) {
		self.label = label
		self.id = id
		self.component = component
		self.class = `class`
		self.type = type
		self.tabIndex = tabIndex
		self.disabled = disabled
		self.hidden = hidden
		self.children = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		var attributes = ""
		if let id { attributes += " id=\"\(htmlEscape(id))\"" }
		if let component, !component.isEmpty {
			attributes += " data-component-id=\"\(htmlEscape(component))\""
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
		if children.isEmpty {
			Text(label).render(into: &buffer)
		} else {
			for child in children { child.render(into: &buffer) }
		}
		buffer.endElement()
	}
}
