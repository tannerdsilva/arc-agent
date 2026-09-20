import Foundation
import Testing
import WebUI
import WebUIDesignSystem
@testable import ArcAgentCore

/// tests for the no-webui browser frontend: config plumbing, credential
/// resolution, form parsing, chat coordinator state, page rendering, and
/// interactive routing registration.
@Suite("Web UI")
struct WebUITests {

	// MARK: - config

	@Test("web config decodes partially against defaults")
	func webConfigPartialDecode() throws {
		let data = Data(#"{"port": 9999}"#.utf8)
		let config = try JSONDecoder().decode(WebConfig.self, from: data)
		#expect(config.port == 9999)
		#expect(config.enabled == true)
		#expect(config.host == "127.0.0.1")
		#expect(config.authEnabled == true)
		#expect(config.maxConnections == 64)
	}

	@Test("web section rides through the full config")
	func arcConfigCarriesWebSection() throws {
		var config = ArcConfig()
		config.web.port = 8123
		config.web.authEnabled = false
		let decoded = try JSONDecoder().decode(ArcConfig.self, from: try JSONEncoder().encode(config))
		#expect(decoded.web.port == 8123)
		#expect(decoded.web.authEnabled == false)
	}

	// MARK: - credentials

	@Test("credential resolution is nil when auth is disabled")
	func credentialDisabled() throws {
		var web = WebConfig()
		web.authEnabled = false
		#expect(try web.resolveCredential(persistingTo: nil) == nil)
	}

	@Test("configured password produces a hash and is never echoed")
	func credentialFromPassword() throws {
		var web = WebConfig()
		web.password = "hunter2"
		let credential = try web.resolveCredential(persistingTo: nil)
		#expect(credential != nil)
		#expect(credential?.username == "admin")
		#expect(credential?.generatedPassword == nil)
		// the hash round-trips through its phc encoding.
		let record = credential?.record
		#expect(record != nil)
	}

	@Test("first-run generation creates a random password once")
	func credentialGenerated() throws {
		var web = WebConfig()
		web.passwordHash = ""
		// persist into a temp config file so generation is not repeated.
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("webui-test-\(UUID().uuidString)")
		let configURL = dir.appendingPathComponent("config.json")
		let credential = try web.resolveCredential(persistingTo: configURL)
		#expect(credential?.generatedPassword != nil)
		#expect(credential?.generatedPassword?.isEmpty == false)
		// persisted config now carries the hash and the generated password is
		// not stored in plaintext.
		let persisted = loadConfig(from: configURL)
		#expect(persisted.web.passwordHash.isEmpty == false)
		#expect(persisted.web.password.isEmpty == true)
		try? FileManager.default.removeItem(at: dir)
	}

	// MARK: - form parsing

	@Test("url-encoded forms parse and decode percent-encoding")
	func urlEncodedFormParses() throws {
		let fields = try URLEncodedForm.parse("username=admin&password=a%20b%26c&empty=")
		#expect(fields["username"] == "admin")
		#expect(fields["password"] == "a b&c")
		#expect(fields["empty"] == "")
	}

	// MARK: - chat coordinator

	@Test("coordinator appends and replaces messages in a thread")
	func coordinatorThread() async {
		let coordinator = ChatCoordinator()
		await coordinator.append(sessionID: "s1", profile: "default", messages: [
			ChatMessage(id: "m0", role: .user, text: "hi")
		])
		var messages = await coordinator.messages(for: "s1")
		#expect(messages.count == 1)
		#expect(messages[0].role == .user)

		await coordinator.replace(
			sessionID: "s1", profile: "default", messageID: "m0",
			with: ChatMessage(id: "m0", role: .assistant, text: "yo")
		)
		messages = await coordinator.messages(for: "s1")
		#expect(messages[0].role == .assistant)
		#expect(messages[0].text == "yo")
	}

	@Test("coordinator bounds a thread at maxThreadLength")
	func coordinatorBounds() async {
		let coordinator = ChatCoordinator()
		let many = (0..<250).map { ChatMessage(id: "m\($0)", role: .user, text: "\($0)") }
		await coordinator.append(sessionID: "s2", profile: "default", messages: many)
		let messages = await coordinator.messages(for: "s2")
		#expect(messages.count == ChatCoordinator.maxThreadLength)
	}

	// MARK: - page rendering

	@Test("app shell document carries title, csp nonce, and render token")
	func shellDocument() {
		let html = AppShell.document(
			title: "Test · ARC Agent",
			active: .chat,
			content: "<p>hi</p>",
			identity: nil,
			csrfToken: "tok",
			renderToken: "rt"
		)
		#expect(html.contains("Test · ARC Agent"))
		#expect(html.contains("nonce="))
		#expect(html.contains("\"renderToken\":\"rt\""))
		#expect(html.contains("href=\"/bots\""))
	}

	@Test("bots page renders profile cards and the create form")
	func botsPageRenders() {
		let profile = Profile(name: "bob", title: "Researcher", description: "does research")
		let html = BotViews.renderBotsPage(profiles: [profile], activeSince: [], csrfToken: "tok")
		#expect(html.contains("bob"))
		#expect(html.contains("Researcher"))
		#expect(html.contains("New agent"))
		#expect(html.contains("action=\"/bots\""))
	}

	@Test("settings page renders config and empty cron state")
	func settingsPageRenders() {
		let html = SettingsViews.renderSettingsPage(config: ArcConfig(), cronJobs: [])
		#expect(html.contains("Settings"))
		#expect(html.contains("General"))
		#expect(html.contains("No cron jobs"))
	}

	@Test("message bubbles render user, assistant, and status variants")
	func messageBubbles() {
		let user = MessageBubble(message: ChatMessage(id: "1", role: .user, text: "hello")).render()
		#expect(user.contains("hello"))

		let assistant = MessageBubble(message: ChatMessage(id: "2", role: .assistant, text: "**bold**")).render()
		#expect(assistant.contains("bold"))

		let status = MessageBubble(message: ChatMessage(id: "3", role: .status, text: "thinking…", streaming: true)).render()
		#expect(status.contains("thinking"))
	}

	@Test("login page renders without a javascript runtime")
	func loginPageRenders() {
		let html = AuthViews.renderLoginPage(error: "nope", csrfToken: "tok")
		#expect(html.contains("Sign in failed"))
		#expect(html.contains("nope"))
		#expect(html.contains("name=\"_csrf\""))
	}

	// MARK: - interactive routing

	@Test("chat bar registers a stable submit route during a render pass")
	func chatBarRegistersHandler() {
		let router = EventRouter()
		let submit: EventHandler = { _ in [] }
		let html = RenderContext.$current.withValue(RenderContext(router: router)) {
			ChatConnection.renderChatBar(inputID: "chat-input-0", submitHandler: submit)
		}
		#expect(html.contains("data-component-id=\"chat-bar\""))
		#expect(html.contains("data-event=\"submit\""))
		#expect(router.handlerCount == 1)
	}

	@Test("chat sidebar registers one route per profile")
	func chatSidebarRegistersHandlers() {
		let router = EventRouter()
		let profiles = [Profile(name: "a"), Profile(name: "b")]
		let html = RenderContext.$current.withValue(RenderContext(router: router)) {
			profiles.map { profile in
				let button = WebUIButton(profile.name, variant: .ghost, size: .sm, fullWidth: true).render()
				let attrs = controlAttributes(id: "side-\(profile.name)", handler: { _ in [] })
				return injectAttributes(into: button, attrs)
			}.joined()
		}
		_ = html
		#expect(router.handlerCount == 2)
	}

	@Test("message thread renders an empty state before any messages")
	func threadEmptyState() {
		let html = ChatConnection.renderThread(messages: [])
		#expect(html.contains("chat-thread"))
		#expect(html.contains("Start a conversation"))
	}

	@Test("assistant bubbles render turn transparency via toolkit components")
	func assistantTurnTransparency() {
		let message = ChatMessage(
			id: "m4",
			role: .assistant,
			text: "answer",
			reasoning: "think <step>",
			toolSteps: [
				AgentToolStep(name: "read_file", arguments: "path: a", result: "ok", durationMs: 120)
			],
			summary: "1 tool · 1.2k tokens"
		)
		let html = MessageBubble(message: message).render()
		#expect(html.contains("turn-reasoning"))
		#expect(html.contains("<summary>Reasoning</summary>"))
		#expect(html.contains("turn-tool"))
		#expect(html.contains("turn-tool__name"))
		#expect(html.contains("read_file"))
		#expect(html.contains("turn-summary"))
		// content is escaped by the toolkit components, never injected raw.
		#expect(!html.contains("<step>"))
		#expect(html.contains("&lt;step&gt;"))
		#expect(!html.contains("<script>"))
	}
}
