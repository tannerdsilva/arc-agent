import WebUI

/// A detail card: `.detail-card` with a `.detail-title` heading and a
/// `.detail-sub` sub-line, plus body children.
public struct DetailCard: WebUI.View {
	public let title: String
	public let sub: String
	public let body: [any WebUI.View]

	public init(
		title: String,
		sub: String,
		@ViewBuilder body: () -> [any WebUI.View] = { [] }
	) {
		self.title = title
		self.sub = sub
		self.body = body()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"detail-card\"")
		buffer.endOpenTag()
		buffer.beginElement("h1", "class=\"detail-title\"")
		buffer.endOpenTag()
		Text(title).render(into: &buffer)
		buffer.endElement()
		buffer.beginElement("div", "class=\"detail-sub\"")
		buffer.endOpenTag()
		Text(sub).render(into: &buffer)
		buffer.endElement()
		for view in body { view.render(into: &buffer) }
		buffer.endElement()
	}
}
