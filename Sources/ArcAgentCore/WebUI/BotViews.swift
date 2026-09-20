import Foundation
import WebUI
import WebUIDesignSystem

/// the bots (profile roster) page. server-rendered per request; the only
/// round-trip is the csrf-protected native create form posted to `/bots`.
public enum BotViews {

	/// render the full bots page body (shell content).
	public static func renderBotsPage(profiles: [Profile], activeSince: [String], csrfToken: String) -> String {
		VStack(alignment: .leading, spacing: 16) {
			if !activeSince.isEmpty {
				HStack(spacing: 8) {
					WebUIBadge("active now", variant: .success, size: .sm, dot: true)
					ForEach(activeSince) { name in
						Text(name).font(size: 13).foregroundColor(.textMuted)
					}
				}
			}

			Heading("Bots", level: .h2)

			if profiles.isEmpty {
				WebUIEmptyState(
					icon: .users,
					title: "No bots yet",
					message: "Create an agent below, or run `arc profile create <name>`."
				)
			} else {
				Grid(columns: .autoFit(BotLayout.cardMinWidth), spacing: 12) {
					ForEach(profiles) { profile in
						Raw(profileCard(profile).render())
					}
				}
			}

			WebUICard(variant: .outlined) {
				VStack(alignment: .leading, spacing: 12) {
					Heading("New agent", level: .h3)
					Form(action: "/bots", method: "post", csrfToken: csrfToken) {
						VStack(alignment: .leading, spacing: 12) {
							Label("Name", for: "profile-name")
							Input(id: "profile-name", name: "name", placeholder: "e.g. researcher", type: .text, required: true)
							Label("Title", for: "profile-title")
							Input(id: "profile-title", name: "title", placeholder: "e.g. Research Lead", type: .text)
							Label("Description", for: "profile-description")
							TextArea(id: "profile-description", name: "description", placeholder: "one-line mission", rows: 2)
							WebUIButton("Create agent", variant: .primary, size: .md)
						}
					}
				}
			}
			.maxWidth(BotLayout.formMaxWidth)
		}
		.render()
	}

	/// one profile card: avatar, display name, role title, and identity
	/// badges (group, pinned, model).
	private static func profileCard(_ profile: Profile) -> some View {
		WebUICard(variant: .elevated) {
			VStack(alignment: .leading, spacing: 8) {
				HStack(spacing: 8) {
					WebUIAvatar(initials: initials(profile.displayName), size: .md)
					VStack(alignment: .leading, spacing: 4) {
						Text(profile.displayName).font(size: 16, weight: .semibold)
						if !profile.title.isEmpty {
							Text(profile.title).font(size: 14).foregroundColor(.textMuted)
						}
					}
				}
				HStack(spacing: 8) {
					WebUIBadge("@\(profile.handle)", variant: .secondary, size: .sm)
					if profile.isPinned {
						WebUIBadge("pinned", variant: .info, size: .sm)
					}
					if let group = profile.group {
						WebUIBadge(group, variant: .neutral, size: .sm)
					}
					if let model = profile.model {
						WebUIBadge(model, variant: .neutral, size: .sm)
					}
				}
			}
		}
	}

	private static func initials(_ name: String) -> String {
		let parts = name.split(separator: " ").prefix(2)
		let value = parts.compactMap { $0.first.map(String.init) }.joined()
		return value.isEmpty ? "?" : String(value.prefix(2)).uppercased()
	}
}

/// fixed app-side layout dimensions for the bots page. the design system has
/// no width token scale, so these are named file-scope constants rather than
/// inline literals.
enum BotLayout {
	static let cardMinWidth = 220
	static let formMaxWidth = "480px"
}
