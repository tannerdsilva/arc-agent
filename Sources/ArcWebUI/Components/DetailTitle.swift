import WebUI

/// the `<h1 class="detail-title">` every main pane opens with. most carry a
/// leading icon, and the legacy markup put a single space between icon and
/// text — reproduced here so a typed title is byte-identical to the string it
/// replaced.
public struct DetailTitle: WebUI.View {
	public let text: String
	public let icon: IconName?
	public let extraClass: String

	public init(_ text: String, icon: IconName? = nil, class extraClass: String = "") {
		self.text = text
		self.icon = icon
		self.extraClass = extraClass
	}

	public func render(into buffer: inout HTMLBuffer) {
		let cls = extraClass.isEmpty ? "detail-title" : "detail-title \(htmlEscape(extraClass))"
		buffer.beginElement("h1", "class=\"\(cls)\"")
		buffer.endOpenTag()
		if let icon {
			WebUIIcon(icon, size: .large).render(into: &buffer)
			Text(" \(text)").render(into: &buffer)
		} else {
			Text(text).render(into: &buffer)
		}
		buffer.endElement()
	}
}