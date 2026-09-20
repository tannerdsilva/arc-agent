import WebUI
import WebUIDesignSystem

/// the login page: a static document (no js runtime), a native form post, a
/// synchronizer csrf token, and a hardened csp. layout is built entirely
/// from design-system components and tokens.
///
/// the card is centred in the viewport: the root `VStack` shrink-wraps by
/// default, so it first fills the width (`width("100%")`) and the viewport
/// height (`minHeight("100vh")`), then the two flex spacers push the card to
/// the middle. see `css-layout-shrink-stretch` in the design skill.
public enum AuthViews {

	public static func renderLoginPage(error: String?, csrfToken: String) -> String {
		let body = VStack(alignment: .center, spacing: 0) {
			Spacer(minSize: 0)
			WebUICard(variant: .elevated) {
				VStack(alignment: .leading, spacing: 12) {
					HStack(spacing: 8) {
						WebUIIcon(.bot, size: .medium)
						Heading("ARC Agent", level: .h1)
					}
					if let error {
						WebUIAlert(variant: .danger, title: "Sign in failed", message: error)
					}
					Form(action: "/login", method: "post", csrfToken: csrfToken) {
						VStack(alignment: .leading, spacing: 12) {
							Label("Username", for: "username")
							Input(id: "username", name: "username", placeholder: "admin", type: .text, required: true)
							Label("Password", for: "password")
							Input(id: "password", name: "password", placeholder: "••••••••", type: .password, required: true)
							WebUIButton("Sign in", variant: .primary, size: .md)
						}
					}
				}
			}
			.maxWidth("24rem")
			.width("100%")
			// `.card` carries align-self: stretch (the design system's
			// shrink/stretch fix); stretched against max-width clamps the
			// box to the cross-start, so an explicit center is required to
			// truly centre the login card in the flex column.
			.style("align-self", "center")
			Spacer(minSize: 0)
		}
		.width("100%")
		.minHeight("100vh")
		.padding(.six)
		.render()
		return WebUIDocument(
			title: "Sign in · ARC Agent",
			body: body,
			includeRuntime: false,
			contentSecurityPolicy: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; base-uri 'self'"
		).render()
	}

	/// a styled "too many attempts" page for throttled login requests (a short
	/// wait message, not a bare plain-text 429 body).
	public static func renderThrottlePage(message: String) -> String {
		let body = VStack(alignment: .center, spacing: 0) {
			Spacer(minSize: 0)
			WebUICard(variant: .elevated) {
				VStack(alignment: .leading, spacing: 12) {
					Heading("ARC Agent", level: .h2)
					WebUIAlert(variant: .danger, title: "Too many attempts", message: message)
				}
			}
			.maxWidth("24rem")
			.width("100%")
			.style("align-self", "center")
			Spacer(minSize: 0)
		}
		.width("100%")
		.minHeight("100vh")
		.padding(.six)
		.render()
		return WebUIDocument(
			title: "Too many attempts · ARC Agent",
			body: body,
			includeRuntime: false,
			contentSecurityPolicy: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; base-uri 'self'"
		).render()
	}
}
