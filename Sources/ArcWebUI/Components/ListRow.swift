import WebUI

/// A list row: `.list-row` wrapping `.lr-name` and `.lr-sub` spans.
///
/// Usage: `ListRow { name } sub: { sub }` — or just children for the whole row
/// body when the row is a button/anchor wrapper.
public struct ListRow: WebUI.View {
	public let children: [any WebUI.View]

	public init(@ViewBuilder content: () -> [any WebUI.View]) {
		self.children = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"list-row\"")
		buffer.endOpenTag()
		for view in children { view.render(into: &buffer) }
		buffer.endElement()
	}
}

/// A named list row: `.list-row` > `.lr-name` + `.lr-sub`.
public struct NamedListRow: WebUI.View {
	public let name: String
	public let sub: String?

	public init(_ name: String, sub: String? = nil) {
		self.name = name
		self.sub = sub
	}

	public func render(into buffer: inout HTMLBuffer) {
		buffer.beginElement("div", "class=\"list-row\"")
		buffer.endOpenTag()
		buffer.beginElement("span", "class=\"lr-name\"")
		buffer.endOpenTag()
		Text(name).render(into: &buffer)
		buffer.endElement()
		if let sub {
			buffer.beginElement("span", "class=\"lr-sub\"")
			buffer.endOpenTag()
			Text(sub).render(into: &buffer)
			buffer.endElement()
		}
		buffer.endElement()
	}
}
