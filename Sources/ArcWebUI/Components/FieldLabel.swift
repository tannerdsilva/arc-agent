import WebUI

/// a `<label>` that wraps a field rather than naming one (`Label` takes a plain
/// string). the aux override editor needs the label to contain its dropdown.
///
/// the element is built through `Element(.label, class:)`: the class rides the
/// typed attribute bag and the shared serializer, not a hand-written attribute
/// string.
public struct FieldLabel<Content: WebUI.View>: WebUI.View {
	public let cls: ClassName
	public let content: Content

	public init(class cls: ClassName, @ElementBuilder content: () -> Content) {
		self.cls = cls
		self.content = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		Element(.label, class: cls) { content }.render(into: &buffer)
	}
}
