import WebUI

/// A native disclosure whose `<summary>` carries its own attributes.
///
/// `WebUICore.Details` emits a bare `<summary>`, which is enough when the head
/// is plain content. A panel head is not plain: it is a styled row that must
/// stay OUT of the tab order (the session buckets) or keep the exact class the
/// sheet keys the caret on (the skill categories). Neither can be expressed
/// through a modifier — the framework has no summary-level attribute seam — so
/// the head's class, title and tabindex are constructor parameters here, and
/// everything the caller chains (`.addClass`, `.id`, `.data`, `.behavior`)
/// lands on the `<details>` itself, because that is the first element opened.
///
/// The pair `id` + `.behavior(Disclosure())` is what makes the open state
/// survive a patch: the engine records `open` for every `details[data-preserve-open]`
/// with an id before it swaps a fragment, and restores it after.
public struct ArcDisclosure<Summary: WebUI.View, Content: WebUI.View>: WebUI.View {
	public let isOpen: Bool
	/// the head's class token; `nil` leaves the summary unclassed.
	public let summaryClass: ClassName?
	/// the head's tab stop. `-1` keeps a quiet utility out of the tab order
	/// exactly as `tabIndex: -1` does on `ArcButton`.
	public let summaryTabIndex: Int?
	public let summaryTitle: String?
	/// the head's accessible name. A summary whose visible content is a graphic
	/// (the context ring) has no text to name it with, so the label is explicit.
	public let summaryLabel: String?
	public let summary: Summary
	public let content: Content

	public init(
		open: Bool = false,
		summaryClass: ClassName? = nil,
		summaryTabIndex: Int? = nil,
		summaryTitle: String? = nil,
		summaryLabel: String? = nil,
		@ElementBuilder summary: () -> Summary,
		@ElementBuilder content: () -> Content
	) {
		self.isOpen = open
		self.summaryClass = summaryClass
		self.summaryTabIndex = summaryTabIndex
		self.summaryTitle = summaryTitle
		self.summaryLabel = summaryLabel
		self.summary = summary()
		self.content = content()
	}

	public func render(into buffer: inout HTMLBuffer) {
		var summaryAttributes = ""
		if let summaryClass, !summaryClass.value.isEmpty {
			summaryAttributes += " class=\"\(htmlEscape(summaryClass.value))\""
		}
		if let summaryTabIndex {
			summaryAttributes += " tabindex=\"\(summaryTabIndex)\""
		}
		if let summaryTitle, !summaryTitle.isEmpty {
			summaryAttributes += " title=\"\(htmlEscape(summaryTitle))\""
		}
		if let summaryLabel, !summaryLabel.isEmpty {
			summaryAttributes += " aria-label=\"\(htmlEscape(summaryLabel))\""
		}
		buffer.beginElement("details", isOpen ? " open" : "")
		buffer.endOpenTag()
		buffer.beginElement("summary", summaryAttributes)
		buffer.endOpenTag()
		summary.render(into: &buffer)
		buffer.endElement()
		content.render(into: &buffer)
		buffer.endElement()
	}
}
