import WebUI

/// A key/value row: `.akv` wrapping `.akv-k` and `.akv-v` spans.
///
/// The value can be a plain string (escaped) or a view tree.
public struct AkvRow<Key: WebUI.View, Value: WebUI.View>: WebUI.View {
	public let key: Key
	public let value: Value

	public init(
		@ElementBuilder key: () -> Key,
		@ElementBuilder value: () -> Value
	) {
		self.key = key()
		self.value = value()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"akv\"")
		buffer.endOpenTag()
		buffer.beginElement("span", "class=\"akv-k\"")
		buffer.endOpenTag()
		key.render(into: &buffer)
		buffer.endElement()
		buffer.beginElement("span", "class=\"akv-v\"")
		buffer.endOpenTag()
		value.render(into: &buffer)
		buffer.endElement()
		buffer.endElement()
	}
}

extension AkvRow where Key == Text, Value == Text {
	/// the plain-string row: both cells are one escaped string.
	public init(key: String, value: String) {
		self.init(key: { Text(key) }, value: { Text(value) })
	}
}
