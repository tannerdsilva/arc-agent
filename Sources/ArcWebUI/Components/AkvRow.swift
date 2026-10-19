import WebUI

/// A key/value row: `.akv` wrapping `.akv-k` and `.akv-v` spans.
///
/// The value can be a plain string (escaped) or a view tree.
public struct AkvRow: WebUI.View {
	public let key: [any WebUI.View]
	public let value: [any WebUI.View]

	public init(key: String, value: String) {
		self.key = [Text(key)]
		self.value = [Text(value)]
	}

	public init(
		@ViewBuilder key: () -> [any WebUI.View],
		@ViewBuilder value: () -> [any WebUI.View]
	) {
		self.key = key()
		self.value = value()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"akv\"")
		buffer.endOpenTag()
		buffer.beginElement("span", "class=\"akv-k\"")
		buffer.endOpenTag()
		for view in key { view.render(into: &buffer) }
		buffer.endElement()
		buffer.beginElement("span", "class=\"akv-v\"")
		buffer.endOpenTag()
		for view in value { view.render(into: &buffer) }
		buffer.endElement()
		buffer.endElement()
	}
}
