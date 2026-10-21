import WebUI

/// a `<label for="…">` whose content is more than one string — the create form
/// needs `Name` followed by a `Required` tag inside the SAME label element, and
/// `Label` only takes a plain string.
///
/// both shapes are separate types on purpose: `FieldLabel` wraps a field it
/// does not name, this one names a field it does not wrap. merging them would
/// make `for` optional and let a label drift away from its control.
public struct FormLabel: WebUI.View {
	public let target: String
	public let children: [any WebUI.View]

	public init(for target: String, @ViewBuilder content: () -> [any WebUI.View]) {
		self.target = target
		self.children = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("label", "for=\"\(htmlEscape(target))\"")
		buffer.endOpenTag()
		for view in children { view.render(into: &buffer) }
		buffer.endElement()
	}
}