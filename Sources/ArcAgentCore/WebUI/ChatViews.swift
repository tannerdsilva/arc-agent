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
	private var wiredSocketID: UUID?
	private var turnTasks: [Task<Void, Never>] = []
	/// which workspace-tree nodes are expanded (server-driven, shared across
	/// the session's tabs so a toggle re-renders consistently).
	private var treeExpanded: Set<String> = ["arc-agent", "sources", "webui"]

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

	/// the submit closure the host passes into the composer render.
	nonisolated public var submitHandlerRef: EventHandler {
		{ [weak self] event in
			guard let self else { return [] }
			return await self.submitHandler(event)
		}
	}

	/// the conversation-list selection closure (dispatches on the clicked
	/// row's `targetId`, which is the bare conversation id).
	nonisolated public func listSelectHandler() -> EventHandler {
		{ [weak self] event in
			guard let self, let target = event.string("targetId") else { return [] }
			return await self.select(target: target)
		}
	}

	/// the workspace-tree toggle closure (dispatches on the clicked row's
	/// `<base>-node-<id>` targetId).
	nonisolated public func treeToggleHandler() -> EventHandler {
		{ [weak self] event in
			guard let self, let target = event.string("targetId") else { return [] }
			return await self.toggleWorkspaceNode(target)
		}
	}

	/// toggle a workspace-tree node open/closed and re-render just the tree
	/// fragment (the routing anchor on the tree container persists, so the
	/// page-build registration keeps routing subsequent clicks).
	private func toggleWorkspaceNode(_ target: String) async -> [FragmentUpdate] {
		let prefix = "workspace-tree-node-"
		let node = target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : target
		if treeExpanded.contains(node) {
			treeExpanded.remove(node)
		} else {
			treeExpanded.insert(node)
		}
		return [FragmentUpdate(id: "workspace-tree", html: Self.renderWorkspaceTree(expanded: treeExpanded, onToggle: treeToggleHandler()))]
	}

	/// render the workspace tree fragment with a given expanded set.
	static func renderWorkspaceTree(expanded: Set<String>, onToggle: EventHandler?) -> String {
		WebUITree(nodes: ChatPage.workspaceTree(), id: "workspace-tree", expanded: expanded, selected: nil, onToggle: onToggle).render()
	}

	/// attach the ws writer and bind the relay to the active session.
	public func wireOn(_ writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async {
		await relay.attach(writer)
		attachment = await coordinator.attach(sessionID: sessionID, relay: relay)
	}

	/// attach a socket as the connection's active sink (its writer is bound
	/// into the relay and the relay into the coordinator). called on a
	/// socket's first verified event so a page that never reaches the server
	/// cannot consume a slot. a newer socket (browser reconnect) seamlessly
	/// claims the sink from an older one; returns whether this socket now owns
	/// the sink.
	@discardableResult
	public func wireOnOnce(_ writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>, socketID: UUID) async -> Bool {
		guard wiredSocketID != socketID else { return false }
		wiredSocketID = socketID
		await wireOn(writer)
		return true
	}

	/// detach the relay from the coordinator and drop the writer, but only if
	/// `socketID` currently owns the sink — a stale socket closing must not
	/// tear down the socket that succeeded it.
	public func wireOffIfCurrent(socketID: UUID) async {
		guard wiredSocketID == socketID else { return }
		wiredSocketID = nil
		if let attachment {
			await coordinator.detach(sessionID: sessionID, id: attachment)
			self.attachment = nil
		}
		await relay.detach()
	}

	// MARK: - interactive handlers

	/// the composer submit handler: fires a turn and returns the cleared
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
		return [FragmentUpdate(id: "chat-bar", html: Self.renderChatBar(inputID: inputID, submitHandler: submitHandlerRef))]
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
		return [
			FragmentUpdate(id: "conv-list", html: Self.renderConversationList(profiles: profiles, active: target)),
			FragmentUpdate(id: "chat-thread", html: Self.renderThread(messages: messages)),
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

	// MARK: - rendering (built from no-webui components)

	/// the message thread fragment (id `chat-thread`). the thread takes the
	/// full remaining height of the chat pane and scrolls internally; the
	/// composer below it stays docked at the bottom. `max-width: 100%` keeps
	/// the scrolling container inside the pane instead of growing past it.
	public static func renderThread(messages: [ChatMessage]) -> String {
		let body: some View = ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				if messages.isEmpty {
					WebUIEmptyState(
						icon: .bot,
						title: "Start a conversation",
						message: "Send a message to begin chatting with the agent."
					)
					.stretch()
				} else {
					ForEach(messages) { message in
						MessageBubble(message: message)
					}
				}
			}
			.padding(20)
		}
		.id("chat-thread")
		.fill()
		.maxWidth("100%")
		return body.render()
	}

	/// the conversation list fragment (id `conv-list`).
	public static func renderConversationList(profiles: [Profile], active: String) -> String {
		var items: [WebUIListItem] = [
			WebUIListItem(id: "default", title: "ARC Agent", subtitle: "local", icon: .bot)
		]
		items += profiles.map { profile in
			WebUIListItem(id: profile.name, title: profile.displayName, subtitle: "@\(profile.name)", icon: .users)
		}
		let list = WebUIListView(items: items, selectedID: active, id: "conv-list")
		return list.render()
	}

	/// the composer fragment (id `chat-bar`). each render mints a fresh
	/// textarea id so the runtime's input-state preservation cannot restore a
	/// sent message into the cleared field; the form keeps its stable
	/// `chat-bar` component id so routing survives the patch.
	public static func renderChatBar(inputID: String, submitHandler: @escaping EventHandler) -> String {
		WebUIComposer(
			placeholder: "Message…",
			inputID: inputID,
			id: "chat-bar",
			onSubmit: submitHandler
		).render()
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

// MARK: - Chat page shell

/// the full chat page: a three-pane row — conversation list panel, the
/// message thread + composer, and a workspace/file-tree panel — composed
/// entirely from no-webui components.
public enum ChatPage {

	/// render the chat page content (the region the shell hands all remaining
	/// space, via `fills: true`).
	public static func render(
		profiles: [Profile],
		messages: [ChatMessage],
		inputID: String,
		active: String,
		workspace: [WebUITree.Node],
		submitHandler: @escaping EventHandler,
		listSelect: @escaping EventHandler,
		treeToggle: EventHandler? = nil
	) -> String {
		let conversationItems = ChatConversationPanel.items(profiles: profiles)
		let page: some View = HStack(alignment: .top, spacing: 0) {
			ChatConversationPanel.render(
				items: conversationItems,
				active: active,
				onSelect: listSelect
			)
			.stretch()

			VStack(alignment: .leading, spacing: 0) {
				Raw(ChatConnection.renderThread(messages: messages))
				Raw(ChatConnection.renderChatBar(inputID: inputID, submitHandler: submitHandler))
			}
			.fill()
			.backgroundColor("var(--color-bg)")

			WorkspacePanel.render(nodes: workspace, onToggle: treeToggle)
				.stretch()
		}
		.fill()
		return page.render()
	}

	/// a representative file tree of the arc-agent repo, rooted at `arc-agent`.
	public static func workspaceTree() -> [WebUITree.Node] {
		func dir(_ id: String, _ label: String, _ children: [WebUITree.Node]) -> WebUITree.Node {
			WebUITree.Node(id: id, label: label, icon: .folder, children: children)
		}
		func file(_ id: String, _ label: String, _ icon: IconName = .fileText) -> WebUITree.Node {
			WebUITree.Node(id: id, label: label, icon: icon)
		}
		return [
			dir("arc-agent", "arc-agent", [
				dir("build", ".build", []),
				dir("sources", "Sources", [
					dir("agent", "Agent", [file("agent-arc", "ArcAgent.swift")]),
					file("arcagentcore", "ArcAgentCore.swift"),
					dir("config", "Config", []),
					dir("cron", "Cron", []),
					dir("delegation", "Delegation", []),
					dir("errorhandling", "ErrorHandling", []),
					dir("gateway", "Gateway", []),
					dir("kanban", "Kanban", []),
					dir("llm", "LLM", []),
					dir("memory", "Memory", []),
					dir("metrics", "Metrics", []),
					dir("profile", "Profile", []),
					dir("provider", "Provider", []),
					dir("security", "Security", []),
					dir("session", "Session", []),
					dir("skills", "Skills", []),
					dir("storage", "Storage", []),
					dir("toolregistry", "ToolRegistry", []),
					dir("tools", "Tools", []),
					dir("webui", "WebUI", [file("appshell", "AppShell.swift"), file("chatviews", "ChatViews.swift")]),
				]),
				file("main", "main.swift", .braces),
			]),
		]
	}
}

// MARK: - Conversations panel

private enum ChatConversationPanel {

	static func items(profiles: [Profile]) -> [WebUIListItem] {
		var items: [WebUIListItem] = [
			WebUIListItem(id: "default", title: "ARC Agent", subtitle: "local", icon: .bot)
		]
		items += profiles.map { profile in
			WebUIListItem(id: profile.name, title: profile.displayName, subtitle: "@\(profile.name)", icon: .users)
		}
		return items
	}

	static func render(items: [WebUIListItem], active: String, onSelect: @escaping EventHandler) -> some View {
		WebUIPanel(
			title: "Chat",
			subtitle: "\(items.count)",
			edge: .leading,
			actions: [
				WebUIButton("New", variant: .ghost, size: .sm)
			]
		) {
			VStack(alignment: .leading, spacing: 12) {
				WebUISearchField(placeholder: "Filter conversations…", id: "conv-search")
				WebUISegmentedControl(
					items: [
						WebUISegmentedItem(id: "sessions", label: "Sessions", count: items.count),
						WebUISegmentedItem(id: "cli", label: "CLI", count: 0),
					],
					selectedID: "sessions",
					id: "conv-tabs"
				)
				WebUIListView(items: items, selectedID: active, id: "conv-list", onSelect: onSelect)
			}
			.padding(12)
		}
		.width("280px")
	}
}

// MARK: - Workspace panel

private enum WorkspacePanel {

	static func render(nodes: [WebUITree.Node], onToggle: EventHandler? = nil) -> some View {
		WebUIPanel(
			title: "Workspace",
			subtitle: "\(nodes.count)",
			edge: .trailing
		) {
			VStack(alignment: .leading, spacing: 12) {
				WebUITabs(
					tabs: [TabItem(id: "files", label: "Files"), TabItem(id: "artifacts", label: "Artifacts")],
					activeTab: "files",
					id: "workspace-tabs"
				)
				WebUITree(nodes: nodes, id: "workspace-tree", expanded: ["arc-agent", "sources", "webui"], selected: nil, onToggle: onToggle)
			}
			.padding(12)
		}
		.width("320px")
	}
}
