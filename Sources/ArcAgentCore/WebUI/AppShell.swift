import WebUI
import WebUIDesignSystem

/// the shared arc-agent page shell: brand header with session identity, a
/// navigation sidebar, and the page content area. every page is assembled
/// through ``AppShell/document(title:active:content:identity:csrfToken:renderToken:)``.
/// the whole shell is built from framework layout primitives, design-system
/// components, and tokens — no hand-written css.
public enum AppShell {

	/// a navigation section. the current section renders as an emphasized
	/// text row; the rest render as links.
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
	public static func document(
		title: String,
		active: Section,
		content: String,
		identity: String?,
		csrfToken: String,
		renderToken: String
	) -> String {
		let body = VStack(spacing: 0) {
			header(identity: identity, csrfToken: csrfToken)
			HStack(alignment: .top, spacing: 0) {
				sidebar(active: active)
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						Raw(content)
					}
					.padding(24)
				}
			}
		}
		.render()
		return WebUIDocument(title: title, body: body, runtimeConfig: RuntimeConfig(renderToken: renderToken)).render()
	}

	// MARK: - header

	private static func header(identity: String?, csrfToken: String) -> some View {
		HStack(spacing: 8) {
			HStack(spacing: 4) {
				WebUIIcon(.bot, size: .medium)
				Text("ARC Agent").font(size: 16, weight: .semibold)
			}

			Spacer(minSize: 8)

			if let identity {
				WebUIBadge(identity, variant: .secondary, size: .sm)
				if !csrfToken.isEmpty {
					Form(action: "/logout", method: "post", csrfToken: csrfToken) {
						Button("sign out", class: "button button--ghost button--sm", type: .submit)
					}
				}
			} else {
				Text("local").foregroundColor(.textMuted).font(size: 13)
			}
		}
		.padding(horizontal: 16, vertical: 10)
		.backgroundColor("var(--color-bg-raised)")
		.border("1px solid var(--color-border)")
	}

	// MARK: - sidebar

	private static func sidebar(active: Section) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(Section.all) { section in
				if section == active {
					row(section: section, emphasized: true)
				} else {
					Link(section.name, href: section.path)
				}
			}
			Spacer(minSize: 16)
		}
		.padding(16)
		.width("220px")
		.backgroundColor("var(--color-bg-subtle)")
		.border("1px solid var(--color-border)")
		.cornerRadius("10px")
	}

	private static func row(section: Section, emphasized: Bool) -> some View {
		HStack(spacing: 6) {
			WebUIIcon(section.icon, size: .small)
			Text(section.name)
				.font(size: 14, weight: emphasized ? .semibold : .normal)
				.foregroundColor(emphasized ? .primary : .textMuted)
		}
		.padding(6)
	}
}
