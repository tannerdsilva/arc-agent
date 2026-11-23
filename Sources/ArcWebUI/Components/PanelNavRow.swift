import ArcTheme
import WebUI

/// a panel navigation row: `.list-row` > anchor > `.lr-name`.
///
/// the anchor's `color:inherit;text-decoration:none;flex:1` was repeated as an
/// inline style on all seven settings rows; `.panel-nav-link` carries it once.
///
/// the three elements are built through `Element`, so the href and the two
/// class tokens ride the typed attribute bag and the shared serializer. the
/// two declared tokens are spelled from `ClassName`'s generated statics
/// (`.listRow`, `.lrName`) rather than as string literals, which is what the
/// class-vocabulary adoption ratchet requires.
public struct PanelNavRow: WebUI.View {
	public let title: String
	public let href: String

	public init(_ title: String, href: String) {
		self.title = title
		self.href = href
	}

	public func render(into buffer: inout HTMLBuffer) {
		Element(.div, class: .listRow) {
			Element(.a, [.href(href), .class(.panelNavLink)]) {
				Element(.span, class: .lrName) { Text(title) }
			}
		}.render(into: &buffer)
	}
}
