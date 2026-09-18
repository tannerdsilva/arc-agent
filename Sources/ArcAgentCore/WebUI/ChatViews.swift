import Foundation
import NIOCore
import NIOWebSocket
import WebUI
import WebUIDesignSystem

/// per-connection chat state for one browser tab: the active chat target,
/// the outbound relay (attached to this tab's websocket), and the turn
/// runner that streams agent responses into the shared thread.
public actor ChatConnection {

	private let coordinator: ChatCoordinator
	private let registry: SessionRegistry
	private let profileManager: ProfileManager
	private let profiles: [Profile]

	private let relay = OutboundRelay()
	private var sessionID: String
	private var profile: String
	private var attachment: UUID?
	private var inputSequence = 0
	private var busy = false
	private var wired = false
	private var turnTasks: [Task<Void, Never>] = []

	public init(
		coordinator: ChatCoordinator,
		registry: SessionRegistry,
		profileManager: ProfileManager,
		profiles: [Profile]
	) {
		self.coordinator = coordinator
		self.registry = registry
		self.profileManager = profileManager
		self.profiles = profiles
		let target = ChatCoordinator.defaultTarget()
		self.sessionID = target.sessionID
		self.profile = target.profile
	}

	// MARK: - websocket lifecycle

	/// the relay the ws loop attaches its outbound writer to.
	public var relayRef: OutboundRelay { relay }

	/// the session this connection's relay is currently bound to.
	public var sessionIDRef: String { sessionID }

	/// the submit closure the host passes into every chat-bar render.
	nonisolated public var submitHandlerRef: EventHandler {
		{ [weak self] event in
			guard let self else { return [] }
			return await self.submitHandler(event)
		}
	}

	/// attach the ws writer and bind the relay to the active session.
	public func wireOn(_ writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async {
		await relay.attach(writer)
		attachment = await coordinator.attach(sessionID: sessionID, relay: relay)
	}

	/// attach exactly once — the host calls this on a socket's first verified
	/// event so a page that never reaches the server cannot consume a slot.
	/// returns true when this call performed the wiring.
	@discardableResult
	public func wireOnOnce(_ writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async -> Bool {
		guard wired == false else { return false }
		wired = true
		await wireOn(writer)
		return true
	}

	/// detach the ws writer and unbind from the active session.
	public func wireOff() async {
		if let attachment {
			await coordinator.detach(sessionID: sessionID, id: attachment)
			self.attachment = nil
		}
		await relay.detach()
	}

	// MARK: - interactive handlers

	/// the chat-bar submit handler: fires a turn and returns the cleared
	/// input bar fragment (the thread itself arrives via the coordinator's
	/// broadcast so every tab of the session sees it).
	public func submitHandler(_ event: EventData) async -> [FragmentUpdate] {
		guard !busy,
			  let text = event.string("message")?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !text.isEmpty else { return [] }
		busy = true

		let userID = await coordinator.nextMessageID()
		let statusID = await coordinator.nextMessageID()
		await coordinator.setInflight(sessionID: sessionID, profile: profile, true)
		await coordinator.append(sessionID: sessionID, profile: profile, messages: [
			ChatMessage(id: userID, role: .user, text: text),
			ChatMessage(id: statusID, role: .status, text: "thinking…", streaming: true),
		])

		turnTasks.append(Task { [weak self] in
			await self?.runTurn(userID: userID, statusID: statusID, text: text)
		})
		turnTasks.removeAll { $0.isCancelled }

		let inputID = nextInputID()
		return [FragmentUpdate(id: "chat-bar", html: Self.renderChatBar(inputID: inputID, isBusy: true, submitHandler: submitHandlerRef))]
	}

	/// a sidebar row click handler: switches the active chat target for this
	/// tab and returns the sidebar + thread fragments for this tab only.
	nonisolated func selectHandler(profile target: String) -> EventHandler {
		{ [weak self] _ in
			guard let self else { return [] }
			return await self.select(target: target)
		}
	}

	private func select(target: String) async -> [FragmentUpdate] {
		let newSession: String
		if target == "default" {
			newSession = "default"
		} else if let canonical = try? await profileManager.getOrCreateCanonicalChat(profile: target) {
			newSession = canonical
		} else {
			return []
		}

		if newSession != sessionID {
			if let attachment {
				await coordinator.detach(sessionID: sessionID, id: attachment)
				self.attachment = nil
			}
			sessionID = newSession
			profile = target
			attachment = await coordinator.attach(sessionID: newSession, relay: relay)
		}

		let messages = await coordinator.messages(for: newSession)
		let inflight = await coordinator.isInflight(newSession)
		return [
			FragmentUpdate(id: "chat-sidebar", html: Self.renderSidebar(profiles: profiles, active: target, connection: self)),
			FragmentUpdate(id: "chat-thread", html: Self.renderThread(messages: messages, inflight: inflight)),
		]
	}

	// MARK: - turn runner

	private func runTurn(userID: String, statusID: String, text: String) async {
		defer { busy = false }
		do {
			let handle = await registry.getOrCreate(sessionID: sessionID, profile: profile)
			let incoming = IncomingMessage(
				id: UUID().uuidString,
				chat: ChatTarget(platform: "web", chatID: sessionID),
				text: text,
				senderID: "web"
			)
			handle.inputContinuation.yield(incoming)

			var first = true
			var received = false
			for await response in handle.responses {
				if first {
					await coordinator.replace(
						sessionID: sessionID, profile: profile, messageID: statusID,
						with: ChatMessage(id: statusID, role: .assistant, text: response, streaming: false)
					)
					first = false
				} else {
					let id = await coordinator.nextMessageID()
					await coordinator.append(sessionID: sessionID, profile: profile, messages: [
						ChatMessage(id: id, role: .assistant, text: response, streaming: false)
					])
				}
				received = true
			}
			if !received {
				await coordinator.replace(
					sessionID: sessionID, profile: profile, messageID: statusID,
					with: ChatMessage(id: statusID, role: .status, text: "no response", streaming: false)
				)
			}
		} catch is CancellationError {
			await coordinator.replace(
				sessionID: sessionID, profile: profile, messageID: statusID,
				with: ChatMessage(id: statusID, role: .status, text: "cancelled", streaming: false)
			)
		} catch {
			await coordinator.replace(
				sessionID: sessionID, profile: profile, messageID: statusID,
				with: ChatMessage(id: statusID, role: .status, text: "turn failed", streaming: false)
			)
		}
		await coordinator.setInflight(sessionID: sessionID, profile: profile, false)
	}

	// MARK: - rendering

	/// the message thread fragment (id `chat-thread`).
	public static func renderThread(messages: [ChatMessage], inflight: Bool) -> String {
		Div(id: "chat-thread") {
			if messages.isEmpty {
				WebUIEmptyState(
					icon: .bot,
					title: "Start a conversation",
					message: "Send a message to begin chatting with the agent."
				)
			} else {
				ForEach(messages) { message in
					MessageBubble(message: message)
				}
			}
		}
		.render()
	}

	/// the target sidebar fragment (id `chat-sidebar`).
	public static func renderSidebar(profiles: [Profile], active: String, connection: ChatConnection) -> String {
		Div(id: "chat-sidebar") {
			ForEach(profiles) { profile in
				Raw(sidebarRow(profile: profile, active: profile.name == active, connection: connection))
			}
		}
		.render()
	}

	private static func sidebarRow(profile: Profile, active: Bool, connection: ChatConnection) -> String {
		let label = active ? "◉ \(profile.displayName)" : profile.displayName
		let button = WebUIButton(
			label,
			variant: active ? .primary : .ghost,
			size: .sm,
			fullWidth: true
		).render()
		let attrs = controlAttributes(id: "side-\(profile.name)", handler: connection.selectHandler(profile: profile.name))
		return injectAttributes(into: button, attrs)
	}

	/// the input bar fragment (id `chat-bar`). each render mints a fresh
	/// textarea id so the runtime's input-state preservation cannot restore a
	/// sent message into the cleared field; the form keeps its stable
	/// `chat-bar` component id so routing survives the patch.
	public static func renderChatBar(inputID: String, isBusy: Bool, submitHandler: @escaping EventHandler) -> String {
		let form = Form(action: "/", method: "post", id: "chat-bar") {
			HStack(spacing: 8) {
				TextArea(
					id: inputID,
					name: "message",
					placeholder: "Message…",
					rows: 1
				)
				.width("100%")
				WebUIButton("Send", variant: .primary, size: .md, disabled: isBusy)
			}
		}
		.render()
		let attrs = controlAttributes(id: "chat-bar", event: .submit, handler: submitHandler)
		return injectAttributes(into: form, attrs)
	}

	/// the next textarea id (called inside the actor, so sequence is safe).
	public func nextInputID() -> String {
		defer { inputSequence += 1 }
		return "chat-input-\(inputSequence)"
	}
}

// MARK: - Message bubble

/// one message in the chat thread: a right-aligned flat card for the user, a
/// left-aligned raised card for the assistant (server-side markdown), and a
/// spinner chip for status rows.
public struct MessageBubble: View {

	public let message: ChatMessage

	public init(message: ChatMessage) {
		self.message = message
	}

	public func render() -> String {
		let isUser = message.role == .user
		let isStatus = message.role == .status

		return HStack(spacing: 8) {
			if isUser { Spacer(minSize: 120) }

			if isStatus {
				HStack(spacing: 8) {
					WebUISpinner(size: .sm)
					Text(message.text).foregroundColor(.textMuted)
				}
				.padding(12)
				.backgroundColor("var(--color-bg-subtle)")
				.cornerRadius("10px")
			} else {
				VStack(alignment: .leading, spacing: 4) {
					WebUIBadge(
						isUser ? "you" : "agent",
						variant: isUser ? .info : .primary,
						size: .sm
					)
					if isUser {
						Text(message.text)
					} else {
						Raw(markdownToHTML(message.text))
					}
				}
				.padding(12)
				.backgroundColor(isUser ? "var(--color-bg-inset)" : "var(--color-bg-raised)")
				.cornerRadius("12px")
				.maxWidth("80%")
			}

			if !isUser { Spacer(minSize: 120) }
		}
		.render()
	}
}
