import WebUI

/// A toggle switch: `label.switch > input[type=checkbox][data-no-restore] +
/// span.track + span.knob`. Used at 13 sites.
///
/// `component: nil` and `component: ""` both omit `data-component-id`.
/// `on` emits `checked=""`; `value` is the checkbox's `value` attribute (several
/// arc switches carry `sk-toggle-<enc>` / `ts-<enc>` there and their change
/// wires read it).
///
/// deliberately not an `Element`: `extraAttributes` is a raw seam carrying
/// `controlAttributes` / `DismissStack` / `FocusReturn` / `Clipboard` strings,
/// so expressing the open tag through the typed bag would need a second
/// attribute parser.
public struct ArcSwitch: WebUI.View {
	public let id: String
	public let on: Bool
	public let component: String?
	public let event: String?
	public let value: String?
	public let ariaLabel: String?
	/// raw attributes emitted verbatim after the routing pair — a leading space
	/// included. the seam a render-time control uses to carry
	/// `controlAttributes` output (id + event) it registered while rendering.
	public var extraAttributes: String = ""

	public init(
		id: String,
		on: Bool,
		component: String? = nil,
		event: String? = nil,
		value: String? = nil,
		ariaLabel: String? = nil,
		extraAttributes: String = ""
	) {
		self.id = id
		self.on = on
		self.component = component
		self.event = event
		self.value = value
		self.ariaLabel = ariaLabel
		self.extraAttributes = extraAttributes
	}

	public func render(into buffer: inout HTMLBuffer) {
		var attributes = ""
		if let component, !component.isEmpty {
			attributes += " data-component-id=\"\(htmlEscape(component))\""
		}
		if let event, !event.isEmpty {
			attributes += " data-event=\"\(htmlEscape(event))\""
		}
		if !extraAttributes.isEmpty { attributes += extraAttributes }
		if let value, !value.isEmpty {
			attributes += " value=\"\(htmlEscape(value))\""
		}
		attributes += " data-no-restore=\"\""
		if let ariaLabel, !ariaLabel.isEmpty {
			attributes += " aria-label=\"\(htmlEscape(ariaLabel))\""
		}
		if on { attributes += " checked=\"\"" }

		buffer.beginElement("label", "class=\"switch\"")
		buffer.endOpenTag()
		buffer.voidElement("input", "type=\"checkbox\" id=\"\(htmlEscape(id))\"\(attributes)")
		buffer.beginElement("span", "class=\"track\"")
		buffer.endOpenTag()
		buffer.endElement()
		buffer.beginElement("span", "class=\"knob\"")
		buffer.endOpenTag()
		buffer.endElement()
		buffer.endElement()
	}
}
