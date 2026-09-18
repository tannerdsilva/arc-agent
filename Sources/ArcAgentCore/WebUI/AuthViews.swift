import WebUI
import WebUIDesignSystem

/// the login page: a static document (no js runtime), a native form post, a
/// synchronizer csrf token, and a hardened csp. layout is built entirely
/// from design-system components and tokens.
public enum AuthViews {

	public static func renderLoginPage(error: String?, csrfToken: String) -> String {
		let body = VStack(alignment: .center, spacing: 0) {
			WebUICard(variant: .elevated) {
				VStack(alignment: .leading, spacing: 12) {
					HStack(spacing: 6) {
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
			.padding(24)
		}
		.render()
		return WebUIDocument(
			title: "Sign in · ARC Agent",
			body: body,
			includeRuntime: false,
			contentSecurityPolicy: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; base-uri 'self'"
		).render()
	}
}
