import WebUI

/// A dropdown row: `<button type="button" class="dd-row [extraClass]">`.
///
/// There is NO `component` parameter — the boundary lives on the popover, not
/// the row (see `ddRow` in Views.swift).
public struct DropdownRow: WebUI.View {
	public let id: String
	public let `class`: String?
	public let children: [any WebUI.View]

	public init(
		id: String,
		class: String? = nil,
		@ViewBuilder content: () -> [any WebUI.View]
	) {
		self.id = id
		self.class = `class`
		self.children = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		var attributes = ""
		attributes += " id=\"\(htmlEscape(id))\""
		if let `class`, !`class`.isEmpty {
			attributes += " class=\"dd-row \(htmlEscape(`class`))\""
		} else {
			attributes += " class=\"dd-row\""
		}

		buffer.beginElement("button", "type=\"button\"\(attributes)")
		buffer.endOpenTag()
		for view in children { view.render(into: &buffer) }
		buffer.endElement()
	}
}
