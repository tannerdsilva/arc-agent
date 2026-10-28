import WebUI

/// A settings row: `.set-row` with a label (`.set-label`) and a control.
///
/// Usage: `SettingRow { "Label text" } control: { ... }`
///
/// generic over the two built subtrees rather than storing `[any View]` arrays:
/// `@ElementBuilder` folds a block of children into one view (`ErasedViews`),
/// so the stored value is a `View` the row renders — the erased array is the
/// shape no-webui retired.
public struct SettingRow<Label: WebUI.View, Control: WebUI.View>: WebUI.View {
	public let label: Label
	public let control: Control

	public init(
		@ElementBuilder label: () -> Label,
		@ElementBuilder control: () -> Control
	) {
		self.label = label()
		self.control = control()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"set-row\"")
		buffer.endOpenTag()
		buffer.beginElement("div", "class=\"set-label\"")
		buffer.endOpenTag()
		label.render(into: &buffer)
		buffer.endElement()
		control.render(into: &buffer)
		buffer.endElement()
	}
}
