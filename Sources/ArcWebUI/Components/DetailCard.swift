import WebUI

/// A detail card: `.detail-card` with a `.detail-title` heading and a
/// `.detail-sub` sub-line, plus body children.
public struct DetailCard<Body: WebUI.View>: WebUI.View {
	public let title: String
	public let sub: String
	public let body: Body
	/// an additional class on the card itself (e.g. a spacing modifier)
	public let extraClass: String

	public init(
		title: String = "",
		sub: String = "",
		extraClass: String = "",
		@ElementBuilder body: () -> Body = { EmptyView() }
	) {
		self.title = title
		self.sub = sub
		self.extraClass = extraClass
		self.body = body()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", extraClass.isEmpty ? "class=\"detail-card\"" : "class=\"detail-card \(htmlEscape(extraClass))\"")
		buffer.endOpenTag()
		// a line that does not exist in the source must not exist in the output:
		// the sheet gives both `.detail-title` and `.detail-sub` their own
		// margins, so an empty node renders a visible gap.
		if !title.isEmpty {
			buffer.beginElement("h1", "class=\"detail-title\"")
			buffer.endOpenTag()
			Text(title).render(into: &buffer)
			buffer.endElement()
		}
		if !sub.isEmpty {
			buffer.beginElement("div", "class=\"detail-sub\"")
			buffer.endOpenTag()
			Text(sub).render(into: &buffer)
			buffer.endElement()
		}
		body.render(into: &buffer)
		buffer.endElement()
	}
}
