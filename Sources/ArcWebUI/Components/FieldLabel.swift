import WebUI

/// a `<label>` that wraps a field rather than naming one (`Label` takes a plain
/// string). the aux override editor needs the label to contain its dropdown.
public struct FieldLabel: WebUI.View {
	public let cls: String
	public let children: [any WebUI.View]

	public init(class cls: String, @ViewBuilder content: () -> [any WebUI.View]) {
		self.cls = cls
		self.children = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("label", "class=\"\(htmlEscape(cls))\"")
		buffer.endOpenTag()
		for view in children { view.render(into: &buffer) }
		buffer.endElement()
	}
}
