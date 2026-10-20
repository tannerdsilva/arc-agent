import WebUI

/// a panel navigation row: `.list-row` > anchor > `.lr-name`.
///
/// the anchor's `color:inherit;text-decoration:none;flex:1` was repeated as an
/// inline style on all seven settings rows; `.panel-nav-link` carries it once.
public struct PanelNavRow: WebUI.View {
	public let title: String
	public let href: String

	public init(_ title: String, href: String) {
		self.title = title
		self.href = href
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"list-row\"")
		buffer.endOpenTag()
		buffer.beginElement("a", "href=\"\(htmlEscape(href))\" class=\"panel-nav-link\"")
		buffer.endOpenTag()
		buffer.beginElement("span", "class=\"lr-name\"")
		buffer.endOpenTag()
		Text(title).render(into: &buffer)
		buffer.endElement()
		buffer.endElement()
		buffer.endElement()
	}
}
