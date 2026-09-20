import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging

/// The top-level gateway service that manages the HTTP server, browser
/// frontend, platform adapters, session registry, and message routing.
///
/// ``GatewayService`` is a ``Service`` that composes:
/// - ``HTTPServerService`` — REST API endpoints
/// - ``WebUIService`` — the no-webui browser frontend (chat/bots/settings)
/// - ``TelegramAdapter`` — Telegram Bot API long polling
/// - ``SessionRegistry`` — active session agents (no cache, Tessera is
///   the source of truth)
/// - ``DeliveryManager`` — routes responses to the correct platform
/// - ``BotMessagingService`` — inter-agent messaging
/// - ``GroupChatManager`` — multi-agent coordination rooms
///
/// All components are managed by a ``ServiceGroup``.
public struct GatewayService: Service {

	private let httpServer: HTTPServerService
	private let webUI: WebUIService?
	private let webCredential: WebUICredential?
	private let telegramAdapter: TelegramAdapter?
	private let registry: SessionRegistry
	private let deliveryManager: DeliveryManager
	private let botMessaging: BotMessagingService
	private let groupChatManager: GroupChatManager
	private let profileManager: ProfileManager
	private let logger: Logger

	public init(
		host: String = "127.0.0.1",
		port: Int = 8080,
		telegramToken: String? = nil,
		agentConfig: SessionRegistry.AgentConfig,
		config: ArcConfig = ArcConfig(),
		webCredential: WebUICredential? = nil
	) throws {
		let pm = ProfileManager()
		let dm = DeliveryManager()
		let bm = BotMessagingService(profileManager: pm)
		let gcm = GroupChatManager(profileManager: pm)
		let reg = SessionRegistry(
			agentConfig: agentConfig,
			deliveryManager: dm,
			profileManager: pm
		)
		let log = Logger(label: "com.arc-agent.gateway")

		self.profileManager = pm
		self.deliveryManager = dm
		self.botMessaging = bm
		self.groupChatManager = gcm
		self.registry = reg
		self.logger = log
		self.webCredential = webCredential

		// Wire up the messaging service
		Task {
			await reg.setMessagingService(bm)
			await gcm.setMessagingService(bm)
		}

		// Build the HTTP server
		self.httpServer = HTTPServerService(
			config: .init(host: host, port: port),
			onChat: { [reg] sessionID, message in
				let handle = await reg.getOrCreate(sessionID: sessionID)
				let incoming = IncomingMessage(
					id: UUID().uuidString,
					chat: ChatTarget(platform: "api", chatID: sessionID),
					text: message,
					senderID: "api"
				)
				handle.inputContinuation.yield(incoming)
				// Await the agent's streamed response; take the answer envelope
				// (interim envelopes carry live reasoning/tool progress).
				var responseText = ""
				for await response in handle.responses {
					let turn = AgentTurn.decodeEnvelope(response)
					if !turn.finalResponse.isEmpty { responseText = turn.finalResponse }
					if turn.done { break }
				}
				return responseText.isEmpty ? "Message received" : responseText
			}
		)

		// Build the browser frontend: pages, design-system assets, and the
		// interactive websocket channel. the gateway resolves the web ui
		// credential once (config or first-run-generated) and hands it in.
		if config.web.enabled {
			self.webUI = try WebUIService(configuration: WebUIService.Configuration(
				host: config.web.host,
				port: config.web.port,
				maxConnections: config.web.maxConnections,
				authEnabled: config.web.authEnabled,
				credential: webCredential,
				registry: reg,
				profileManager: pm,
				messagingService: bm,
				arcConfig: config
			))
		} else {
			self.webUI = nil
		}

		// Set up Telegram adapter if token is provided
		if let token = telegramToken {
			self.telegramAdapter = TelegramAdapter(
				botToken: token,
				httpClient: HTTPClient(eventLoopGroupProvider: .singleton)
			)
		} else {
			self.telegramAdapter = nil
		}
	}

	// MARK: - Service

	public func run() async throws {
		logger.info("Starting ARC Agent Gateway (Bot Mode)...")

		var services: [any Service] = [httpServer, botMessaging]
		if let webUI {
			services.append(webUI)
		}
		if let telegram = telegramAdapter {
			services.append(telegram)
		}

		let serviceGroup = ServiceGroup(
			configuration: ServiceGroupConfiguration(
				services: services,
				logger: logger
			)
		)

		do {
			try await serviceGroup.run()
		} catch {
			// Release the shared Tessera connection (WireGuard tunnel) at
			// teardown.
			await TesseraConnection.shared.shutdown()
			throw error
		}
		// Release the shared Tessera connection (WireGuard tunnel) at
		// teardown.
		await TesseraConnection.shared.shutdown()
	}
}
