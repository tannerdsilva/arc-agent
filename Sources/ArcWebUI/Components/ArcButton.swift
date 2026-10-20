import WebUI

/// A typed button that replaces `Helpers.btn(...)` and every literal `<button>`.
///
/// Content has exactly one source: a text label, or a view builder — never both.
/// Two initializers make that a compile-time rule. The earlier shape took
/// `_ label:` AND a builder and rendered only the builder when children were
/// present, so every icon button passed a label it never rendered — and a test
/// asserted the dropped label as if it were the contract.
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
	}

	private enum Content {
		case text(String)
		case views([any WebUI.View])
	}

	private let id: String?
	private let component: String?
	private let `class`: String
	private let type: ButtonType
	private let tabIndex: Int?
	private let disabled: Bool
	private let hidden: Bool
	private let content: Content

	/// a button whose content is a text label.
	public init(
		_ label: String,
		id: String? = nil,
		component: String? = nil,
		class: String,
		type: ButtonType = .button,
		tabIndex: Int? = nil,
		disabled: Bool = false,
		hidden: Bool = false
	) {
		self.init(
			id: id, component: component, class: `class`, type: type,
			tabIndex: tabIndex, disabled: disabled, hidden: hidden,
			content: .text(label)
		)
	}

	/// a button whose content is views — an icon, a badge, a stack. there is no
	/// label parameter: a label beside a builder would be a second content
	/// source, and the silent winner was the bug this shape removes.
	public init(
		id: String? = nil,
		component: String? = nil,
		class: String,
		type: ButtonType = .button,
		tabIndex: Int? = nil,
		disabled: Bool = false,
		hidden: Bool = false,
		@ViewBuilder content: () -> [any WebUI.View]
	) {
		self.init(
			id: id, component: component, class: `class`, type: type,
			tabIndex: tabIndex, disabled: disabled, hidden: hidden,
			content: .views(content())
		)
	}

	private init(
		id: String?,
		component: String?,
		class: String,
		type: ButtonType,
		tabIndex: Int?,
		disabled: Bool,
		hidden: Bool,
		content: Content
	) {
		self.id = id
		self.component = component
		self.class = `class`
		self.type = type
		self.tabIndex = tabIndex
		self.disabled = disabled
		self.hidden = hidden
		self.content = content
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
		switch content {
		case .text(let label): Text(label).render(into: &buffer)
		case .views(let views): for view in views { view.render(into: &buffer) }
		}
		buffer.endElement()
	}
}