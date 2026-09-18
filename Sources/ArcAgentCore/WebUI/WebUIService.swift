import Foundation
import ServiceLifecycle
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import WebUI
import WebUIDesignSystem
import WebUIAuth

/// the web ui host: a raw-nio http/websocket server that serves the arc-agent
/// chat, bots, and settings pages (rendered by the no-webui toolkit) and
/// routes interactive events through per-render `EventRouter`s bound to a
/// session's websocket. gated by ``WebUIAuth`` sessions when auth is enabled.
///
/// this is the toolkit's canonical hosting pattern (see `WebUIAuthExample`);
/// the html, css, and js the browser receives are all toolkit-generated.
public final class WebUIService: Service {

	public struct Configuration: Sendable {
		public let host: String
		public let port: Int
		public let maxConnections: Int
		public let authEnabled: Bool
		public let credential: WebUICredential?
		public let registry: SessionRegistry
		public let profileManager: ProfileManager
		public let messagingService: BotMessagingService?
		public let arcConfig: ArcConfig

		public init(
			host: String = "127.0.0.1",
			port: Int = 8088,
			maxConnections: Int = 64,
			authEnabled: Bool = true,
			credential: WebUICredential? = nil,
			registry: SessionRegistry,
			profileManager: ProfileManager,
			messagingService: BotMessagingService? = nil,
			arcConfig: ArcConfig
		) {
			self.host = host
			self.port = port
			self.maxConnections = maxConnections
			self.authEnabled = authEnabled
			self.credential = credential
			self.registry = registry
			self.profileManager = profileManager
			self.messagingService = messagingService
			self.arcConfig = arcConfig
		}
	}

	static let cookieName = "arcweb"
	static let maxAgeSeconds = 8 * 60 * 60
	static let maxBodyBytes = 16 * 1024
	/// the session hash used when auth is disabled so ws message routing and
	/// ping/pong still resolve to the page's router.
	static let anonSessionHash = [UInt8](repeating: 0, count: 1)

	private let config: Configuration
	private let logger: Logger

	// chat state (shared across all sessions).
	private let coordinator = ChatCoordinator()

	// per-session auth state.
	private let routers: RouterRegistry
	private let connections: AuthConnectionRegistry
	let sessionStore = InMemoryAuthSessionStore()
	private let csrfSecret: String
	private let loginThrottle: LoginThrottle
	private let loginPageThrottle: LoginThrottle
	private let loginTokenStore: SingleUseTokenStore
	private let argon2Limiter: AsyncSemaphore
	private let argonPool: NIOThreadPool
	private let connectionGate: ConnectionGate

	public init(configuration: Configuration) throws {
		self.config = configuration
		self.logger = Logger(label: "com.arc-agent.webui")
		self.routers = RouterRegistry()
		self.connections = AuthConnectionRegistry()
		self.csrfSecret = try CSRFProtection.generateSecret()
		self.loginThrottle = LoginThrottle(windowSeconds: 60, maxAttempts: 20)
		self.loginPageThrottle = LoginThrottle(windowSeconds: 60, maxAttempts: 60)
		self.loginTokenStore = SingleUseTokenStore()
		self.argon2Limiter = AsyncSemaphore(permits: 4)
		self.argonPool = NIOThreadPool(numberOfThreads: 2)
		self.argonPool.start()
		self.connectionGate = ConnectionGate(maximum: configuration.maxConnections)
	}

	// MARK: - Service

	public func run() async throws {
		logger.info("web ui on http://\(config.host):\(config.port) (ws://\(config.host):\(config.port)/ws)")

		// prewarm the hoisted minified sheets so the one-time ~10 ms minify
		// never lands inside the first request handler.
		DesignSystemAssets.prewarm()

		if let credential = config.credential {
			if let generated = credential.generatedPassword {
				logger.notice("web ui password generated for '\(credential.username)': \(generated)")
			} else {
				logger.info("web ui auth enabled for '\(credential.username)'")
			}
		} else {
			logger.info("web ui auth disabled")
		}

		let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
		let bootstrap = ServerBootstrap(group: group)
			.serverChannelOption(ChannelOptions.backlog, value: 128)
			.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

		let channel: NIOAsyncChannel<EventLoopFuture<WebUIUpgradeResult>, Never> = try await bootstrap.bind(
			host: config.host, port: config.port
		) { channel in
			channel.eventLoop.makeCompletedFuture { () -> EventLoopFuture<WebUIUpgradeResult> in
				guard self.connectionGate.tryAcquire() else {
					channel.close(promise: nil)
					return channel.eventLoop.makeFailedFuture(ConnectionGateError.atCapacity)
				}
				try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: .seconds(120)))
				try channel.pipeline.syncOperations.addHandler(WebUIIdleCloseHandler())
				try channel.pipeline.syncOperations.addHandler(ConnectionGateReleaser(gate: self.connectionGate))
				let upgrader = NIOTypedWebSocketServerUpgrader<WebUIUpgradeResult>(
					shouldUpgrade: { channel, head in
						let structurallyValid = head.method == .GET
							&& head.uri == "/ws"
							&& self.originMatchesHost(head: head)
						guard structurallyValid else {
							return self.rejectUpgrade(channel: channel, status: .forbidden)
						}
						if self.config.authEnabled {
							let sessionValid: EventLoopFuture<Bool> = channel.eventLoop.makeFutureWithTask {
								guard let tokenHash = self.tokenHash(for: head),
									  let session = try? await self.sessionStore.find(tokenHash: tokenHash),
									  !session.isExpired() else {
									return false
								}
								return true
							}
							return sessionValid.flatMap { valid in
								if valid {
									return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
								}
								return self.rejectUpgrade(channel: channel, status: .forbidden)
							}
						}
						return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
					},
					upgradePipelineHandler: { channel, head in
						channel.eventLoop.makeCompletedFuture {
							let ws = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
							let tokenHash = self.config.authEnabled ? self.tokenHash(for: head) : Self.anonSessionHash
							return WebUIUpgradeResult.websocket(ws, tokenHash: tokenHash)
						}
					}
				)
				let config = NIOTypedHTTPServerUpgradeConfiguration(
					upgraders: [upgrader],
					notUpgradingCompletionHandler: { channel in
						channel.eventLoop.makeCompletedFuture {
							try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
							let http = try NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>(wrappingChannelSynchronously: channel)
							return WebUIUpgradeResult.http(http)
						}
					}
				)
				let pipelineConfig = NIOUpgradableHTTPServerPipelineConfiguration(upgradeConfiguration: config)
				return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(configuration: pipelineConfig)
			}
		}

		logger.info("web ui accepting connections")

		try await withThrowingDiscardingTaskGroup { taskGroup in
			taskGroup.addTask {
				// maintenance: keep the session store, router registry, and
				// throttle windows bounded for the life of the process.
				while !Task.isCancelled {
					do { try await Task.sleep(for: .seconds(60)) } catch { break }
					await self.runMaintenance()
				}
			}
			try await channel.executeThenClose { inbound in
				for try await negotiationFuture in inbound {
					taskGroup.addTask {
						await self.handle(negotiationFuture)
					}
				}
			}
		}

		try await group.shutdownGracefully()
		try await self.argonPool.shutdownGracefully()
	}

	// MARK: - connection handling

	private func handle(_ negotiationFuture: EventLoopFuture<WebUIUpgradeResult>) async {
		do {
			switch try await negotiationFuture.get() {
			case .websocket(let ws, let tokenHash):
				try await handleWebsocket(ws, tokenHash: tokenHash)
			case .http(let http):
				try await handleHTTP(http)
			}
		} catch {
			// connection error or a refused admission (gate failure); ignore.
		}
	}

	// MARK: - websocket

	private func handleWebsocket(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, tokenHash: [UInt8]?) async throws {
		var connectionID: Int?
		if let tokenHash {
			connectionID = await connections.register(channel, tokenHash: tokenHash)
		}
		// the chat connection this socket wired (nil until the first verified
		// event) — set from the single ws loop task, so a plain var suffices.
		var socketWiring = SocketWiring()
		do {
			try await channel.executeThenClose { inbound, outbound in
				try await withThrowingTaskGroup(of: Void.self) { tg in
					tg.addTask {
						for try await frame in inbound {
							switch frame.opcode {
							case .text:
								let payload = String(buffer: frame.unmaskedData)
								await self.dispatch(eventText: payload, tokenHash: tokenHash, outbound: outbound, wiring: socketWiring)
							case .ping:
								let buf = ByteBuffer()
								let pong = WebSocketFrame(fin: true, opcode: .pong, data: buf)
								try await outbound.write(pong)
							case .connectionClose:
								var data = frame.unmaskedData
								let code = data.readSlice(length: 2) ?? ByteBuffer()
								let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: code)
								try await outbound.write(close)
								return
							default:
								break
							}
						}
					}
					try await tg.next()
					tg.cancelAll()
				}
			}
		} catch {
			// connection error; the unregister below still runs.
		}
		// release the chat relay this socket was wired to (only if it still
		// owns the sink — a newer socket that took over must not be torn
		// down by a stale socket's close).
		await socketWiring.connection?.wireOffIfCurrent(socketID: socketWiring.socketID)
		if let tokenHash, let connectionID {
			await connections.unregister(connectionID, tokenHash: tokenHash)
		}
	}

	private func dispatch(
		eventText payload: String,
		tokenHash: [UInt8]?,
		outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
		wiring: SocketWiring
	) async {
		do {
			let msg = try WSIncoming(jsonText: payload)
			switch msg {
			case .event(let component, let event, let data, let token):
				guard await sessionIsAlive(tokenHash: tokenHash, outbound: outbound) else { return }
				guard let entry = await boundEntry(token: token, tokenHash: tokenHash, outbound: outbound) else { return }
				if let connection = await wireOnce(entry: entry, outbound: outbound, wiring: wiring) {
					wiring.connection = connection
				}
				let eventData = EventData(component: ComponentID(component), event: event, data: data)
				let updates = await entry.router.handle(eventData)
				guard !updates.isEmpty else { return }
				let out = WSOutgoing.update(fragments: updates)
				try await writeJSON(out, outbound: outbound)
			case .ping(let token):
				guard await sessionIsAlive(tokenHash: tokenHash, outbound: outbound) else { return }
				guard let entry = await boundEntry(token: token, tokenHash: tokenHash, outbound: outbound) else { return }
				if let connection = await wireOnce(entry: entry, outbound: outbound, wiring: wiring) {
					wiring.connection = connection
				}
				try await writeJSON(WSOutgoing.pong, outbound: outbound)
			case .navigate:
				break
			}
		} catch {
			let err = WSOutgoing.error(code: "decode", message: "bad event: \(error)")
			try? await writeJSON(err, outbound: outbound)
		}
	}

	/// attach a page's chat connection to this socket exactly once (its first
	/// verified event); all subsequent events and the coordinator's broadcasts
	/// flow through the connection's relay. returns the connection when this
	/// call performed the wiring.
	private func wireOnce(entry: RouterRegistry.Entry, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>, wiring: SocketWiring) async -> ChatConnection? {
		if await entry.connection.wireOnOnce(outbound, socketID: wiring.socketID) {
			return entry.connection
		}
		return nil
	}

	/// the router + chat connection for a message presenting `token` on a
	/// session's socket, or nil when the token is absent or unknown.
	private func boundEntry(token: String?, tokenHash: [UInt8]?, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async -> RouterRegistry.Entry? {
		guard let tokenHash else {
			try? await writeJSON(WSOutgoing.redirect(url: "/login", replace: true), outbound: outbound)
			try? await writeClose(outbound: outbound)
			return nil
		}
		if let token, let entry = routers.resolve(forTokenHash: tokenHash, renderToken: token) {
			return entry
		}
		if await sessionExists(tokenHash) {
			try? await writeJSON(WSOutgoing.redirect(url: "/", replace: true), outbound: outbound)
		} else {
			try? await writeJSON(WSOutgoing.redirect(url: "/login", replace: true), outbound: outbound)
		}
		try? await writeClose(outbound: outbound)
		return nil
	}

	/// true when the session behind `tokenHash` is still live (or is the
	/// anonymous auth-disabled sentinel). on a revoked/expired session the
	/// client is redirected to /login and the socket closed.
	private func sessionIsAlive(tokenHash: [UInt8]?, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async -> Bool {
		if let tokenHash, !tokenHash.elementsEqual(Self.anonSessionHash) {
			let session = try? await sessionStore.find(tokenHash: tokenHash)
			guard session != nil, !(session?.isExpired() ?? true) else {
				try? await writeJSON(WSOutgoing.redirect(url: "/login", replace: true), outbound: outbound)
				try? await writeClose(outbound: outbound)
				return false
			}
		}
		return true
	}

	private func sessionExists(_ tokenHash: [UInt8]) async -> Bool {
		if tokenHash.elementsEqual(Self.anonSessionHash) { return true }
		guard let session = try? await sessionStore.find(tokenHash: tokenHash) else { return false }
		return !session.isExpired()
	}

	private func writeClose(outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async throws {
		var buf = ByteBuffer()
		buf.writeInteger(UInt16(1000))
		let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: buf)
		try await outbound.write(close)
	}

	private func writeJSON(_ msg: WSOutgoing, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async throws {
		let bytes = msg.jsonBytes
		var buf = ByteBuffer()
		buf.writeBytes(bytes)
		let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
		try await outbound.write(frame)
	}

	// MARK: - HTTP

	private func handleHTTP(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws {
		try await channel.executeThenClose { inbound, outbound in
			var requestHead: HTTPRequestHead?
			var bodyBytes: [UInt8] = []
			var bodyTooLarge = false
			for try await part in inbound {
				switch part {
				case .head(let head):
					requestHead = head
				case .body(let buffer):
					guard !bodyTooLarge else { continue }
					var buffer = buffer
					if let b = buffer.readBytes(length: buffer.readableBytes) {
						bodyBytes.append(contentsOf: b)
						if bodyBytes.count > Self.maxBodyBytes {
							bodyTooLarge = true
							bodyBytes = []
						}
					}
				case .end:
					guard let head = requestHead else { return }
					if bodyTooLarge {
						try await httpResponse(channel: channel.channel, status: .payloadTooLarge, headers: [], body: "request body too large")
					} else {
						let peerIP = channel.channel.remoteAddress?.ipAddress ?? "unknown"
						try await self.route(head: head, body: bodyBytes, peerIP: peerIP, channel: channel.channel)
					}
					return
				}
			}
		}
	}

	private func route(head: HTTPRequestHead, body: [UInt8], peerIP: String, channel: Channel) async throws {
		// public assets.
		switch (head.method, head.uri) {
		case (.GET, "/__assets/css"):
			try await httpResponse(channel: channel, status: .ok, headers: [("Content-Type", "text/css; charset=utf-8")], body: DesignSystemAssets.minifiedCss)
			return
		case (.GET, "/__assets/js"):
			try await httpResponse(channel: channel, status: .ok, headers: [("Content-Type", "text/javascript; charset=utf-8")], body: WebUIAssets.js)
			return
		default:
			break
		}

		switch (head.method, head.uri) {
		case (.GET, "/login"):
			try await handleLoginPage(head: head, peerIP: peerIP, channel: channel)
		case (.POST, "/login"):
			try await handleLogin(head: head, body: body, peerIP: peerIP, channel: channel)
		case (.POST, "/logout"):
			try await handleLogout(head: head, body: body, channel: channel)
		case (.GET, "/logout"):
			try await httpResponse(channel: channel, status: .methodNotAllowed, headers: [], body: "")
		case (.POST, "/bots"):
			try await handleCreateBot(head: head, body: body, channel: channel)
		case (.GET, "/"):
			try await handleIndex(head: head, path: "/", channel: channel)
		case (.GET, "/bots"):
			try await handleIndex(head: head, path: "/bots", channel: channel)
		case (.GET, "/settings"):
			try await handleIndex(head: head, path: "/settings", channel: channel)
		case (_, "/ws"):
			try await httpResponse(channel: channel, status: .notFound, headers: [("Content-Type", "text/plain; charset=utf-8")], body: "not found")
		default:
			try await httpResponse(channel: channel, status: .notFound, headers: [("Content-Type", "text/plain; charset=utf-8")], body: "not found")
		}
	}

	// MARK: - auth pages

	private func handleLoginPage(head: HTTPRequestHead, peerIP: String, channel: Channel) async throws {
		if config.authEnabled, await sessionDescription(for: head) != nil {
			return try await redirect(channel: channel, to: "/")
		}
		let ipKey = "ip:\(peerIP)"
		guard loginPageThrottle.record(ipKey) else {
			return try await httpResponse(channel: channel, status: .tooManyRequests, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Retry-After", "60")], body: "too many login pages — try again later")
		}
		let token = try CSRFProtection.token(for: "login", secret: csrfSecret)
		guard await loginTokenStore.reserve(token, expiresAt: CSRFProtection.expiry(of: token) ?? Date().timeIntervalSince1970, key: ipKey) else {
			return try await httpResponse(channel: channel, status: .tooManyRequests, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Retry-After", "60")], body: "too many outstanding login forms — submit one first")
		}
		try await httpResponse(channel: channel, status: .ok, headers: [("Content-Type", "text/html; charset=utf-8")], body: AuthViews.renderLoginPage(error: nil, csrfToken: token))
	}

	private func handleLogin(head: HTTPRequestHead, body: [UInt8], peerIP: String, channel: Channel) async throws {
		func failure(_ message: String) async throws {
			let token = try CSRFProtection.token(for: "login", secret: csrfSecret)
			try await httpResponse(channel: channel, status: .ok, headers: [("Content-Type", "text/html; charset=utf-8")], body: AuthViews.renderLoginPage(error: message, csrfToken: token))
		}
		func tooMany(_ message: String) async throws {
			try await httpResponse(channel: channel, status: .tooManyRequests, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Retry-After", "60")], body: message)
		}

		guard let contentType = head.headers.first(name: "content-type")?.lowercased(),
			  contentType.hasPrefix("application/x-www-form-urlencoded") else {
			try await httpResponse(channel: channel, status: .unsupportedMediaType, headers: [], body: "expected application/x-www-form-urlencoded")
			return
		}

		let bodyText = String(decoding: body, as: UTF8.self)
		guard let fields = try? URLEncodedForm.parse(bodyText),
			  let csrf = fields["_csrf"],
			  CSRFProtection.validate(csrf, for: "login", secret: csrfSecret) else {
			return try await failure("invalid or expired form token — try again")
		}
		let username = fields["username"] ?? ""
		let password = fields["password"] ?? ""

		let ipKey = "ip:\(peerIP)"
		guard await loginTokenStore.consume(csrf, expiresAt: CSRFProtection.expiry(of: csrf) ?? Date().timeIntervalSince1970, key: ipKey) else {
			return try await failure("invalid or expired form token — try again")
		}
		guard loginThrottle.record(ipKey) else {
			return try await tooMany("too many attempts — try again later")
		}
		let userKey = "user:\(username.lowercased())"
		guard loginThrottle.record(userKey) else {
			return try await tooMany("too many attempts — try again later")
		}

		guard let credential = config.credential else {
			return try await failure("auth not configured")
		}
		let expectedUsername = credential.username
		let userMatches = constantTimeEquals([UInt8](username.utf8), [UInt8](expectedUsername.utf8))
		let passwordValid: Bool
		await argon2Limiter.wait()
		defer { argon2Limiter.signal() }
		passwordValid = try await argonPool.runIfActive {
			try PasswordVerifier.verify(password: [UInt8](password.utf8), record: credential.record)
		}
		guard userMatches, passwordValid else {
			return try await failure("invalid credentials")
		}
		loginThrottle.reset(userKey)

		let token = try SessionToken.generate()
		guard let sessionID = SecureRandom.bytes(16),
			  let sessionSeed = SecureRandom.bytes(16) else {
			throw SessionToken.TokenError.entropyUnavailable
		}
		let session = AuthenticatedSession(
			id: sessionID,
			tokenHash: try SessionToken.hash(token),
			identityID: expectedUsername,
			csrfSeed: sessionSeed,
			createdAt: Date(),
			expiresAt: Date().addingTimeInterval(TimeInterval(Self.maxAgeSeconds)),
			lastSeenAt: Date()
		)
		try await sessionStore.create(session)

		let cookie = try HTTPCookie(
			name: Self.cookieName,
			value: Base64.encode(token),
			attributes: .init(maxAge: Self.maxAgeSeconds, path: "/", httpOnly: true, sameSite: .lax)
		).setCookieHeaderValue()
		try await redirect(channel: channel, to: "/", setCookies: [("Set-Cookie", cookie)])
	}

	private func handleLogout(head: HTTPRequestHead, body: [UInt8], channel: Channel) async throws {
		let bodyText = String(decoding: body, as: UTF8.self)
		guard let fields = try? URLEncodedForm.parse(bodyText),
			  let csrf = fields["_csrf"],
			  CSRFProtection.validate(csrf, for: "logout", secret: csrfSecret) else {
			try await httpResponse(channel: channel, status: .forbidden, headers: [], body: "invalid or expired form token")
			return
		}

		var clearCookie: String?
		if let cookieHeader = head.headers.first(name: "cookie"),
		   let token = CookieParser.requestCookies(cookieHeader)[Self.cookieName],
		   let tokenHash = try? SessionToken.hash(Self.decodeCookieToken(token)) {
			if let session = try? await sessionStore.find(tokenHash: tokenHash) {
				try? await sessionStore.invalidate(id: session.id)
				routers.remove(forTokenHash: tokenHash)
				await connections.closeAll(forTokenHash: tokenHash)
			}
			clearCookie = try HTTPCookie(
				name: Self.cookieName,
				value: "",
				attributes: .init(maxAge: 0, path: "/", httpOnly: true, sameSite: .lax)
			).setCookieHeaderValue()
		}
		var cookies: [(String, String)] = []
		if let clearCookie {
			cookies.append(("Set-Cookie", clearCookie))
		}
		try await redirect(channel: channel, to: "/login", setCookies: cookies)
	}

	// MARK: - application pages

	private func handleIndex(head: HTTPRequestHead, path: String, channel: Channel) async throws {
		let tokenHash: [UInt8]?
		if config.authEnabled {
			guard let (session, token) = await sessionDescription(for: head) else {
				return try await redirect(channel: channel, to: "/login")
			}
			var refreshed = session
			refreshed.lastSeenAt = Date()
			try? await sessionStore.touch(refreshed)
			tokenHash = try SessionToken.hash(token)
		} else {
			tokenHash = Self.anonSessionHash
		}

		let body = try await renderPage(path: path, tokenHash: tokenHash)
		try await httpResponse(channel: channel, status: .ok, headers: [("Content-Type", "text/html; charset=utf-8")], body: body)
	}

	/// render one of the application pages (chat / bots / settings) and mint
	/// its per-render websocket token + router.
	private func renderPage(path: String, tokenHash: [UInt8]?) async throws -> String {
		let logoutToken = try CSRFProtection.token(for: "logout", secret: csrfSecret)
		guard let renderTokenBytes = SecureRandom.bytes(16) else {
			throw SessionToken.TokenError.entropyUnavailable
		}
		let renderToken = Base64.encodeURL(renderTokenBytes)
		let identity = config.credential.map { Identity(id: $0.username, roles: [Role.member, Role.admin]) }

		if let tokenHash {
			let router = EventRouter(logger: Logger(label: "webui.arc"))
			let connection = makeChatConnection()
			routers.set(.init(router: router, connection: connection), forTokenHash: tokenHash, renderToken: renderToken)
		}

		switch path {
		case "/bots":
			let profiles = (try? await config.profileManager.list()) ?? []
			let active = await config.messagingService?.recentActivity(within: 90) ?? []
			let content = BotViews.renderBotsPage(profiles: profiles, activeSince: active, csrfToken: logoutToken)
			return AppShell.document(
				title: "Bots · ARC Agent",
				active: .bots,
				content: content,
				identity: identity?.id,
				csrfToken: logoutToken,
				renderToken: renderToken
			)

		case "/settings":
			let content = SettingsViews.renderSettingsPage(config: config.arcConfig, cronJobs: await cronJobs())
			return AppShell.document(
				title: "Settings · ARC Agent",
				active: .settings,
				content: content,
				identity: identity?.id,
				csrfToken: logoutToken,
				renderToken: renderToken
			)

		default:
			return await renderChatPage(tokenHash: tokenHash, csrfToken: logoutToken, identity: identity, renderToken: renderToken)
		}
	}

	/// a fresh chat connection for a page render (never wired until a socket
	/// drives an event against this page).
	private func makeChatConnection() -> ChatConnection {
		ChatConnection(
			coordinator: coordinator,
			registry: config.registry,
			profileManager: config.profileManager,
			profiles: []
		)
	}

	/// render the chat page and register its interactive router under the
	/// session's render token.
	private func renderChatPage(tokenHash: [UInt8]?, csrfToken: String, identity: Identity?, renderToken: String) async -> String {
		let profiles = (try? await config.profileManager.list()) ?? []
		let connection = ChatConnection(
			coordinator: coordinator,
			registry: config.registry,
			profileManager: config.profileManager,
			profiles: profiles
		)
		let inputID = await connection.nextInputID()
		let submitHandler = await connection.submitHandlerRef
		let messages = await coordinator.messages(for: "default")
		let inflight = await coordinator.isInflight("default")

		let router = EventRouter(logger: Logger(label: "webui.arc.chat"))
		let html = RenderContext.$current.withValue(RenderContext(router: router)) {
			let content = HStack(alignment: .top, spacing: 16) {
				VStack(alignment: .leading, spacing: 8) {
					Heading("Conversations", level: .h3)
					Raw(ChatConnection.renderSidebar(profiles: profiles, active: "default", connection: connection))
				}
				.width("240px")

				VStack(alignment: .leading, spacing: 8) {
					Raw(ChatConnection.renderThread(messages: messages, inflight: inflight))
					Raw(ChatConnection.renderChatBar(inputID: inputID, isBusy: false, submitHandler: submitHandler))
				}
			}
			.render()
			return AppShell.document(
				title: "Chat · ARC Agent",
				active: .chat,
				content: content,
				identity: identity?.id,
				csrfToken: csrfToken,
				renderToken: renderToken
			)
		}

		if let tokenHash {
			routers.set(.init(router: router, connection: connection), forTokenHash: tokenHash, renderToken: renderToken)
		}
		return html
	}

	private func cronJobs() async -> [CronJob] {
		(try? await FileCronStore().listAll()) ?? []
	}

	// MARK: - bots creation

	private func handleCreateBot(head: HTTPRequestHead, body: [UInt8], channel: Channel) async throws {
		if config.authEnabled {
			guard await sessionDescription(for: head) != nil else {
				return try await redirect(channel: channel, to: "/login")
			}
		}
		let bodyText = String(decoding: body, as: UTF8.self)
		guard let fields = try? URLEncodedForm.parse(bodyText),
			  let csrf = fields["_csrf"],
			  CSRFProtection.validate(csrf, for: "logout", secret: csrfSecret) else {
			try await httpResponse(channel: channel, status: .forbidden, headers: [], body: "invalid or expired form token")
			return
		}
		let name = (fields["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else {
			return try await redirect(channel: channel, to: "/bots")
		}
		var profile = try await config.profileManager.create(name: name, cloneFrom: nil)
		profile.title = fields["title"] ?? ""
		profile.description = fields["description"] ?? ""
		try await config.profileManager.update(profile)
		try await redirect(channel: channel, to: "/bots")
	}

	// MARK: - helpers

	private func sessionDescription(for request: HTTPRequestHead) async -> (session: AuthenticatedSession, token: [UInt8])? {
		guard let cookieHeader = request.headers.first(name: "cookie"),
			  let cookieValue = CookieParser.requestCookies(cookieHeader)[Self.cookieName] else {
			return nil
		}
		let tokenBytes = Self.decodeCookieToken(cookieValue)
		guard let tokenHash = try? SessionToken.hash(tokenBytes) else { return nil }
		guard let session = try? await sessionStore.find(tokenHash: tokenHash),
			  !session.isExpired() else {
			return nil
		}
		return (session, tokenBytes)
	}

	private func tokenHash(for request: HTTPRequestHead) -> [UInt8]? {
		guard let cookieHeader = request.headers.first(name: "cookie"),
			  let cookieValue = CookieParser.requestCookies(cookieHeader)[Self.cookieName] else {
			return nil
		}
		return try? SessionToken.hash(Self.decodeCookieToken(cookieValue))
	}

	private static func decodeCookieToken(_ token: String) -> [UInt8] {
		Base64.decode(token) ?? []
	}

	private func originMatchesHost(head: HTTPRequestHead) -> Bool {
		guard let origin = head.headers.first(name: "origin") else { return false }
		let host = (head.headers.first(name: "host") ?? "").lowercased()
		guard let url = URL(string: origin) else { return false }
		var authority = (url.host ?? "").lowercased()
		if let port = url.port {
			authority += ":\(port)"
		}
		return authority == host
	}

	// MARK: - maintenance

	private func runMaintenance() async {
		let now = Date()
		_ = (try? await sessionStore.purgeExpired(before: now)) ?? 0
		loginThrottle.prune(before: now)
		loginPageThrottle.prune(before: now)
		await loginTokenStore.prune(now: now.timeIntervalSince1970)
		for hash in routers.allTokenHashes() {
			if !(await sessionExists(hash)) {
				routers.remove(forTokenHash: hash)
			}
		}
	}

	// MARK: - response helpers

	private func httpResponse(channel: Channel, status: HTTPResponseStatus, headers: [(String, String)], body: String) async throws {
		var head = HTTPResponseHead(version: .http1_1, status: status)
		head.headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
		head.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
		head.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
		for (name, value) in headers {
			head.headers.replaceOrAdd(name: name, value: value)
		}
		head.headers.replaceOrAdd(name: "Content-Length", value: "\(body.utf8.count)")
		head.headers.replaceOrAdd(name: "Connection", value: "close")
		var buf = ByteBuffer()
		buf.writeString(body)
		// await the terminal write promise: the async channel writer does not
		// await write promises, and a large response would lose its tail when
		// the connection closes right after writing.
		_ = channel.write(HTTPPart<HTTPResponseHead, ByteBuffer>.head(head))
		_ = channel.write(HTTPPart<HTTPResponseHead, ByteBuffer>.body(buf))
		try await channel.writeAndFlush(HTTPPart<HTTPResponseHead, ByteBuffer>.end(nil)).get()
	}

	private func redirect(channel: Channel, to target: String, setCookies: [(String, String)] = []) async throws {
		var headers = setCookies
		headers.insert(("Location", target), at: 0)
		try await httpResponse(channel: channel, status: .seeOther, headers: headers, body: "")
	}

	private func rejectUpgrade(channel: Channel, status: HTTPResponseStatus) -> EventLoopFuture<HTTPHeaders?> {
		var head = HTTPResponseHead(version: .http1_1, status: status)
		head.headers.replaceOrAdd(name: "Content-Length", value: "0")
		head.headers.replaceOrAdd(name: "Connection", value: "close")
		head.headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
		let body = ByteBuffer(string: "")
		_ = channel.writeAndFlush(HTTPServerResponsePart.head(head))
		_ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(body)))
		return channel.writeAndFlush(HTTPServerResponsePart.end(nil))
			.map { nil as HTTPHeaders? }
	}
}

// MARK: - upgrade result

enum WebUIUpgradeResult: Sendable {
	case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, tokenHash: [UInt8]?)
	case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

// MARK: - per-socket wiring

/// tracks the chat connection a socket wired to, so teardown can detach its
/// channel from the coordinator. set from the socket's single read task.
final class SocketWiring: Sendable {
	private let state = Mutex<ChatConnection?>(nil)

	/// this socket's identity in the connection's sink negotiation.
	let socketID = UUID()

	var connection: ChatConnection? {
		get { state.withLock { $0 } }
		set { state.withLock { $0 = newValue } }
	}
}

// MARK: - connection plumbing

enum ConnectionGateError: Error { case atCapacity }

final class ConnectionGateReleaser: ChannelInboundHandler {
	typealias InboundIn = IOData
	private let gate: ConnectionGate
	init(gate: ConnectionGate) { self.gate = gate }
	func channelInactive(context: ChannelHandlerContext) {
		gate.release()
		context.fireChannelInactive()
	}
}

final class WebUIIdleCloseHandler: ChannelInboundHandler {
	typealias InboundIn = WebSocketFrame
	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		if event is IdleStateHandler.IdleStateEvent {
			context.close(promise: nil)
		} else {
			context.fireUserInboundEventTriggered(event)
		}
	}
}

final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
	typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
	typealias OutboundOut = HTTPServerResponsePart
	func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
		let part = Self.unwrapOutboundIn(data)
		switch part {
		case .head(let head):
			context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
		case .body(let buffer):
			context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
		case .end(let trailers):
			context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
		}
	}
}

// MARK: - URL-encoded form

enum URLEncodedForm {
	enum ParseError: Error {
		case invalidPercentEncoding
	}
	static func parse(_ body: String) throws -> [String: String] {
		var result: [String: String] = [:]
		for pair in body.split(separator: "&") {
			let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard components.count == 2 else { continue }
			let key = String(components[0]).replacingOccurrences(of: "+", with: " ")
			let value = String(components[1]).replacingOccurrences(of: "+", with: " ")
			guard let decodedKey = key.removingPercentEncoding,
				  let decodedValue = value.removingPercentEncoding else {
				throw ParseError.invalidPercentEncoding
			}
			result[decodedKey] = decodedValue
		}
		return result
	}
}
