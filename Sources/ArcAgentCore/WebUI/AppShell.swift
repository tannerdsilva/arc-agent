import WebUI
import WebUIDesignSystem

/// the shared arc-agent page shell: a full-height icon rail (`WebUISidebar`
/// in `.rail` mode) on the left and the page content filling the rest.
/// every page is assembled through ``AppShell/document(title:active:content:identity:csrfToken:renderToken:fills:)``.
/// the shell is built from framework layout primitives and design-system
/// components — no hand-written css or raw div/button markup.
public enum AppShell {

	/// a navigation section. the current section renders as an emphasized
	/// rail item; the rest render as links.
	public struct Section: Equatable, Sendable {
		public let name: String
		public let path: String
		public let icon: IconName

		public init(name: String, path: String, icon: IconName) {
			self.name = name
			self.path = path
			self.icon = icon
		}

		public static let chat = Section(name: "Chat", path: "/", icon: .bot)
		public static let bots = Section(name: "Bots", path: "/bots", icon: .users)
		public static let settings = Section(name: "Settings", path: "/settings", icon: .settings)

		public static let all: [Section] = [.chat, .bots, .settings]
	}

	/// assemble a complete html document for a page.
	/// - Parameters:
	///   - title: the browser tab title.
	///   - active: the nav section this page belongs to.
	///   - content: the already-rendered page body (fragment- or view-built).
	///   - identity: the signed-in username, nil when auth is disabled.
	///   - csrfToken: a session csrf token for the logout form ("" when auth
	///     is disabled).
	///   - renderToken: the per-render websocket binding token minted by the
	///     server; the runtime echoes it with every ws event.
	///   - fills: when true the content area is NOT wrapped in the shell's
	///     scroll container; instead the content receives all remaining space
	///     (full width, full height) and manages its own scrolling. chat uses
	///     this: the message thread scrolls, the composer stays docked.
	public static func document(
		title: String,
		active: Section,
		content: String,
		identity: String?,
		csrfToken: String,
		renderToken: String,
		fills: Bool = false
	) -> String {
		let contentArea: String
		if fills {
			// the content owns its own scroll regions; hand it all remaining
			// space instead of double-wrapping it in a scrolling container.
			contentArea = Raw(content).fill().render()
		} else {
			contentArea = ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					Raw(content).stretch()
				}
				.padding(.six)
			}
			.fill()
			.render()
		}

		let body = HStack(alignment: .top, spacing: 0) {
			navRail(active: active)
				.stretch()
			Raw(contentArea)
		}
		.height("100vh")
		.render()
		return WebUIDocument(title: title, body: body, runtimeConfig: RuntimeConfig(renderToken: renderToken)).render()
	}

	// MARK: - nav rail

	private static func navRail(active: Section) -> some View {
		let items = Section.all.map { section in
			WebUISidebarItem(
				id: section.name.lowercased(),
				label: section.name,
				icon: section.icon,
				href: section.path
			)
		}
		return WebUISidebar(
			items: items,
			activeID: active.name.lowercased(),
			id: "nav-rail",
			style: .rail
		)
	}
}
