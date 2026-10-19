import WebUI

/// A settings row: `.set-row` with a label (`.set-label`) and a control.
///
/// Usage: `SettingRow { "Label text" } control: { ... }`
public struct SettingRow: WebUI.View {
	public let label: [any WebUI.View]
	public let control: [any WebUI.View]

	public init(
		@ViewBuilder label: () -> [any WebUI.View],
		@ViewBuilder control: () -> [any WebUI.View]
	) {
		self.label = label()
		self.control = control()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"set-row\"")
		buffer.endOpenTag()
		buffer.beginElement("div", "class=\"set-label\"")
		buffer.endOpenTag()
		for view in label { view.render(into: &buffer) }
		buffer.endElement()
		for view in control { view.render(into: &buffer) }
		buffer.endElement()
	}
}
