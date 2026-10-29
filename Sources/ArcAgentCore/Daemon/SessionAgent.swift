import ArcToolKit
import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging

/// A long-lived session agent Service managed by the session host.
public actor SessionAgent: Service {

    public let sessionID: String
    public let profile: String

    private let agentConfig: SessionRegistry.AgentConfig
    private let profileManager: ProfileManager
    private let incomingMessages: AsyncStream<IncomingMessage>
    private let deliveryManager: DeliveryManager
    private let registry: SessionRegistry
    private let responseContinuation: AsyncStream<String>.Continuation
    private let logger = Logger(label: "com.arc-agent.session-agent")

    public init(
        sessionID: String,
        profile: String = "default",
        agentConfig: SessionRegistry.AgentConfig,
        profileManager: ProfileManager,
        incomingMessages: AsyncStream<IncomingMessage>,
        deliveryManager: DeliveryManager,
        registry: SessionRegistry,
        responseContinuation: AsyncStream<String>.Continuation
    ) {
        self.sessionID = sessionID
        self.profile = profile
        self.agentConfig = agentConfig
        self.profileManager = profileManager
        self.incomingMessages = incomingMessages
        self.deliveryManager = deliveryManager
        self.registry = registry
        self.responseContinuation = responseContinuation
    }

    // MARK: - Service

    public func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        do {
            // Resolve profile-specific configuration
            let resolvedModel: String
            let resolvedProvider: String
            let resolvedBaseURL: URL
            let resolvedSOUL: String?
            let resolvedContext: ProfileContextConfig?
            let resolvedProfileDefaults: ContextRecipe?

            if let profileConfig = try await profileManager.get(name: profile) {
                resolvedModel = profileConfig.model ?? agentConfig.model
                resolvedProvider = profileConfig.provider ?? agentConfig.provider
                // Safe URL resolution — no force-unwrap
                if let profileURL = profileConfig.baseURL.flatMap({ URL(string: $0) }) {
                    resolvedBaseURL = profileURL
                } else if let configURL = URL(string: agentConfig.baseURL) {
                    resolvedBaseURL = configURL
                } else {
                    resolvedBaseURL = URL(string: "https://api.openai.com/v1")!
                }
                resolvedSOUL = profileConfig.soulMD
                resolvedContext = profileConfig.context
                resolvedProfileDefaults = profileConfig.contextDefaults
            } else {
                resolvedModel = agentConfig.model
                resolvedProvider = agentConfig.provider
                if let url = URL(string: agentConfig.baseURL) {
                    resolvedBaseURL = url
                } else {
                    resolvedBaseURL = URL(string: "https://api.openai.com/v1")!
                }
                resolvedSOUL = nil
                resolvedContext = nil
                resolvedProfileDefaults = nil
            }

            // Storage backend. When Tessera is configured, sessions and
            // memory flow through the shared Tessera connection (signed
            // NOSTR events). Without it we fall back to local files so the
            // daemon can still run without a server.
            logger.info("step: opening session storage")
            let sessionStore: any SessionStore
            let memoryProvider: any MemoryProvider
            if let storage = agentConfig.storage {
                // the daemon prebuilt ONE storage pair for the whole process;
                // constructing a second pair here would open a second env on
                // the same store directories.
                sessionStore = storage.store
                memoryProvider = storage.memory
            } else if let tessera = agentConfig.tessera {
                await TesseraConnection.shared.configure(tessera)
                sessionStore = TesseraSessionStore()
                memoryProvider = TesseraMemoryProvider()
            } else {
                sessionStore = FileSessionStore()
                // Rooted at the profile's directory: `MEMORY.md`/`USER.md`
                // there are the same documents `profile_edit` addresses, so
                // the `memory` tool and `profile_edit` cannot disagree
                // (GROUNDZERO slice 4, the memory-addressing defect).
                memoryProvider = FileMemoryProvider(
                    directory: ProfileManager.memoryURL(for: profile))
            }

            logger.info("step: building tool registry")
            // The session's scope: its profile (the daemon always has one),
            // its session id, the workspace it runs in, and the live gate.
            // `agentConfig.profiles` is the process's one roster writer — the
            // same `ProfileService` the daemon put in its ServiceGroup — so
            // the roster tools act through the single writer, not a new one.
            let sessionProfile = ProfileName(profile) ?? .default
            let toolContext = ToolContext(
                profile: sessionProfile,
                sessionID: sessionID,
                // A daemon session has no per-session workspace root (the web
                // UI does): `AGENTS.md` resolves where it always has, relative
                // to the process.
                workspace: FileManager.default.currentDirectoryPath,
                grant: AgentPowers.grant(profile: sessionProfile)
            )
            let toolRegistry = try await MutableToolRegistry.make(
                context: toolContext,
                profiles: agentConfig.profiles ?? TesseraProfileStore.shared,
                memory: memoryProvider,
                sessions: sessionStore,
                // Messaging is register-when-available: a daemon session host
                // owns both services, so its sessions carry both tools; a
                // surface without them carries neither.
                messaging: await registry.messagingService,
                groupChats: await registry.groupChats,
                // The daemon's one board, not a per-session one: `kanban_list`
                // reads the in-memory cache a `FileKanbanBoard` keeps, so a
                // second instance over the same directory would not see the
                // tasks another surface created.
                kanban: agentConfig.kanban,
                enabledPlugins: pluginAllowList()
            )

            // `send_message` acts on the delivery path this host owns, bound to
            // *this session's* surface: the slot travels with the registry, so
            // a second session in the same process cannot answer for it (the
            // process-global it replaced is gone — GROUNDZERO slice 6).
            toolRegistry.toolDependencies.sendMessageDelivery.set(deliveryManager)

            // Resolve the per-session context recipe: global defaults <
            // profile defaults < session overrides.
            logger.info("step: resolving context recipe")
            let sessionOverrides: ContextRecipe?
            if let existingSession = try? await sessionStore.get(id: sessionID) {
                sessionOverrides = existingSession.contextOverrides
            } else {
                sessionOverrides = nil
            }
            let resolvedRecipe = ResolvedContextRecipe.resolve(
                global: agentConfig.contextDefaults,
                profile: resolvedProfileDefaults,
                session: sessionOverrides
            )

            // Host/guest split (Phase 1): the owner is the sole host. When
            // this process holds a grant (not ownership) on a shared session,
            // we must not build or run a second agent — this side is a tunnel
            // that relays only. Resolve the turn mode from the store's owner +
            // live grants before constructing the engine, so a guest process
            // skips the model/provider/tool-registry cost entirely. (With no
            // resolvable identity, or a session owned by this identity, we
            // fall through to the normal host path.)
            logger.info("step: resolving turn mode")
            if let identity = await TesseraConnection.shared.nostrPublicKeyString {
                let grants = await TesseraShareStore.shared.latestGrants()
                // Grant-based pre-check: a grant naming this process as a
                // grantee means the owner is elsewhere, even if the session
                // meta (owner field) has not been ingested yet.
                let grantedElsewhere = grants.contains { grant in
                    grant.sessionID == sessionID
                        && grant.owner != identity
                        && grant.grantees.contains(where: { $0.pubkey == identity })
                }
                var isGuest = grantedElsewhere
                if !isGuest, let stored = try? await sessionStore.get(id: sessionID) {
                    isGuest = SharedSessionACL.turnMode(
                        identity: identity, sessionID: sessionID,
                        sessionOwner: stored.owner, grants: grants
                    ) == .guest
                }
                if isGuest {
                    logger.info("step: session \\(sessionID) is shared to this process as a guest; owner is sole host — skipping agent construction")
                    return
                }
            }

            logger.info("step: creating ArcAgent")
            let agent = ArcAgent(config: ArcAgent.Configuration(
                model: resolvedModel,
                provider: resolvedProvider,
                baseURL: resolvedBaseURL,
                apiKey: agentConfig.apiKey,
                registry: toolRegistry,
                sessionStore: sessionStore,
                memoryProvider: memoryProvider,
                skills: [],
                maxIterations: agentConfig.maxIterations ?? 25,
                toolLoopCap: agentConfig.toolLoopCap,
                maxTurnDuration: 120,
                persistSessions: agentConfig.tessera != nil ? agentConfig.persistSessions : false,
                approvalMode: .manual,
                // Session agents are long-lived, but seed the persisted
                // "Always allow" list so allowlist entries span restarts.
                alwaysAllowedCommands: loadConfig().security.alwaysAllowedCommands,
                query: nil,
                maxContextTokens: 64_000,
                sessionID: sessionID,
                contextLength: resolvedContext?.contextLength,
                compressionBudget: resolvedContext?.compressionBudget,
                platformHint: "daemon",
                moa: agentConfig.moa,
                skillInlineCommands: agentConfig.skillInlineCommands,
                backgroundReview: BackgroundReview.Settings(
                    afterToolCalls: agentConfig.backgroundReviewAfter,
                    window: agentConfig.backgroundReviewWindow
                ),
                verifyOnStop: agentConfig.verifyOnStop,
                reasoningEffort: resolvedContext?.reasoningEffort,
                temperature: resolvedContext?.temperature,
                topP: resolvedContext?.topP,
                maxOutputTokens: resolvedContext?.maxOutputTokens,
                mcpServers: agentConfig.mcpServers,
                contextRecipe: resolvedRecipe,
                // The prompt's "Active ARC profile" line and `profile_edit`'s
                // SOUL default both read this; it had no caller before slice 4.
                profileName: profile
            ))
            logger.info("step: setting up client")
            await agent.setupClient(httpClient: httpClient)

            // Inject the SOUL.md as a system message if present
            logger.info("step: checking soul")
            if let soul = resolvedSOUL {
                await agent.injectSystemMessage(soul)
            }

            // Process incoming messages (with session-heartbeat injection:
            // an idle session fires its `/heartbeat` prompt as a user turn).
            logger.info("step: entering message loop")
            let heartbeatStore = HeartbeatStore()
            // Standing goals: Tessera-backed when active, file otherwise —
            // same gate as sessions/memory.
            let goalStore: any GoalStoring = await TesseraAvailability.shared.isTesseraActive()
                ? TesseraGoalStore()
                : GoalStore()
            let mergedMessages = HeartbeatInjector.merged(
                over: incomingMessages,
                sessionID: sessionID,
                store: heartbeatStore
            )
            for try await firstMessage in mergedMessages {
                var currentMessage: IncomingMessage? = firstMessage
                while let message = currentMessage {
                currentMessage = nil
                if message.senderID == "heartbeat" {
                    logger.info("step: heartbeat fired for session \(sessionID)")
                } else {
                    // The daemon learns the delivery chat for CLI-set heartbeats.
                    await heartbeatStore.adoptChat(sessionID: sessionID, chat: message.chat)
                }
                logger.info("step: running conversation")
                let chat = message.chat

                // Host-runs-every-turn: only the owner generates a response for a
                // **shared** session. A contributing sharee's message is already
                // persisted by appendMessage; the owner's agent picks it up. When
                // ownership can't be resolved (standalone gateway without a store,
                // or a session we can't see) we run the turn as before, so a
                // single-user deployment behaves exactly as it did.
                if let store = agentConfig.storage?.store,
                   let stored = try? await store.get(id: sessionID),
                   let storedOwner = stored.owner,
                   let identity = await TesseraConnection.shared.nostrPublicKeyString,
                   !SharedSessionACL.isOwner(identity, sessionOwner: storedOwner) {
                    logger.info("step: session \(sessionID) is shared to this process and not the owner; contribution recorded, skipping turn")
                    continue
                }

                // Live streaming delivery (arc parity): typing indicator +
                // in-place edits while the agent streams, final edit/send at end.
                var editable = await deliveryManager.canEdit(to: chat)
                var buffer = ""
                var latestID: String? = nil
                var lastEditAt = Date.distantPast
                let typingTask = Task {
                    while !Task.isCancelled {
                        try? await deliveryManager.sendTyping(to: chat)
                        try? await Task.sleep(for: .seconds(3.5))
                    }
                }
                var streamError: Error? = nil
                do {
                    // Structured turn events: text deltas drive live
                    // delivery. Tool results are re-projected as the historic
                    // `[Tool: name] result` lines, so platform output stays
                    // byte-identical; usage and reasoning feed diagnostics
                    // instead of the visible reply.
                    let stream = agent.streamTurn(message: message.text)
                    for try await event in stream {
                        switch event {
                        case .textDelta(let delta), .failed(let delta):
                            buffer += delta
                        case .toolCallFinished(_, let name, let result):
                            buffer += "[Tool: \(name)] \(result)\n"
                        case .toolCallStarted(_, let name, _):
                            logger.debug("session: tool started: \(name) (session \(sessionID))")
                        case .reasoningDelta(let delta):
                            logger.debug("session: reasoning delta \(delta.count) chars (session \(sessionID))")
                        case .usage(let usage):
                            logger.debug("session: usage prompt=\(usage.promptTokens) completion=\(usage.completionTokens) (session \(sessionID))")
                        case .compressing:
                            logger.info("session: compressing context (session \(sessionID))")
                        case .completed:
                            break
                        }
                        if editable, let id = latestID,
                           Date().timeIntervalSince(lastEditAt) > 0.8 {
                            do {
                                try await deliveryManager.update(
                                    messageID: id, text: buffer, parseMode: nil, to: chat
                                )
                                lastEditAt = Date()
                            } catch {
                                // Adapter rejects in-place edits (too long,
                                // unsupported) — drop the partial and fall
                                // back to send-once at the end.
                                logger.notice("session: edit fell back: \(error)")
                                if let id = latestID {
                                    try? await deliveryManager.delete(messageID: id, to: chat)
                                }
                                latestID = nil
                                editable = false
                            }
                        } else if editable, latestID == nil {
                            // First delta becomes the initial message to edit.
                            let result = try await deliveryManager.send(
                                message: OutgoingMessage(text: buffer, isPartial: true), to: chat
                            )
                            latestID = result.messageID
                            lastEditAt = Date()
                        }
                    }
                } catch {
                    streamError = error
                }
                typingTask.cancel()

                let mutableFinal = buffer
                var finalText = mutableFinal
                if agentConfig.verifyOnStop,
                   let verification = await agent.runVerificationCheck(lastResponse: finalText) {
                    finalText += "\n\n" + verification
                }
                do {
                    if let error = streamError { throw error }
                    if editable, let id = latestID, finalText.count <= 4096 {
                        try await deliveryManager.update(
                            messageID: id, text: finalText, parseMode: nil, to: chat
                        )
                    } else {
                        // Email threading metadata from the inbound message
                        // (subject / In-Reply-To / References) rides along on
                        // final delivery so replies continue the thread.
                        let meta = emailMetadata(for: message)
                        // Deliverable mode (reference deliverable-mode.md):
                        // ship generated files as native attachments and
                        // strip the paths from the visible message.
                        let (cleanText, paths) = DeliverableExtractor.extract(finalText)
                        let attachments: [OutgoingMessage.Attachment]? = paths.isEmpty ? nil : paths.map {
                            OutgoingMessage.Attachment(filename: ($0 as NSString).lastPathComponent, url: $0)
                        }
                        let result = try await deliveryManager.send(
                            message: OutgoingMessage(text: cleanText, attachments: attachments, metadata: meta), to: chat
                        )
                        latestID = result.messageID
                    }
                } catch {
                    logger.error("session: delivery failed for \(chat.platform): \(error)")
                }

                // Send response through BOTH channels:
                // 1. Response continuation (for HTTP API callers awaiting the result)
                responseContinuation.yield(finalText)
                // 2. Delivery manager (for platform adapters like Telegram)

                // Report activity for the "active now" strip
                if let messaging = await registry.messagingService {
                    await messaging.reportActivity(profile: profile, kind: .turnCompleted)
                }

                // ── Standing-goal loop (reference `/goal`): judge after the turn
                // and feed a continuation turn back into this session. ──
                let outcome = try await GoalLoop.afterTurn(
                    sessionID: sessionID,
                    store: goalStore,
                    finalResponse: finalText,
                    judge: { goal, last in
                        await agent.runGoalJudge(goal: goal, lastResponse: last)
                    },
                    gateRunner: GoalLoop.defaultGateRunner(workdir: nil),
                    workspaceRoot: WorkspacePath.root
                )
                switch outcome {
                case .continueTurn(let continuationText):
                    logger.info("goal: continuing turn for session \(sessionID)")
                    currentMessage = IncomingMessage(
                        id: "goal-\(Int(Date().timeIntervalSince1970))",
                        chat: chat,
                        text: continuationText,
                        senderID: "goal",
                        senderName: nil,
                        isReply: false,
                        replyToID: nil,
                        isMention: false,
                        raw: nil
                    )
                case .stopped(let stopMessage):
                    _ = try? await deliveryManager.send(
                        message: OutgoingMessage(text: stopMessage), to: chat
                    )
                case .idle:
                    break
                }
                }
            }
        } catch {
            try? await httpClient.shutdown()
            responseContinuation.finish()
            // Supervise the crash: identity-aware removal plus a bounded
            // auto-restart by the registry (keeps the session live through
            // transient failures). A superseded generation's crash is a no-op.
            await registry.handleAgentCrash(sessionID: sessionID, agent: self)
            throw error
        }

        try? await httpClient.shutdown()
        responseContinuation.finish()
        await registry.removeIfCurrent(sessionID: sessionID, agent: self)
    }

    /// Extract email reply-threading metadata carried on the inbound message.
    private nonisolated func emailMetadata(for message: IncomingMessage) -> [String: String]? {
        guard message.chat.platform == "email",
              let raw = message.raw,
              let subject = raw["emailSubject"]?.value as? String else { return nil }
        return [
            "subject": subject,
            "inReplyTo": (raw["emailMessageID"]?.value as? String) ?? "",
            "references": (raw["emailReferences"]?.value as? String) ?? "",
        ]
    }
}
