import WebUI

/// a `<label>` that wraps a field rather than naming one (`Label` takes a plain
/// string). the aux override editor needs the label to contain its dropdown.
public struct FieldLabel<Content: WebUI.View>: WebUI.View {
	public let cls: ClassName
	public let content: Content

	public init(class cls: ClassName, @ElementBuilder content: () -> Content) {
		self.cls = cls
		self.content = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("label", "class=\"\(htmlEscape(cls.value))\"")
		buffer.endOpenTag()
		content.render(into: &buffer)
		buffer.endElement()
	}
}
