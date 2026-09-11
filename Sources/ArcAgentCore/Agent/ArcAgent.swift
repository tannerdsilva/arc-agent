import Foundation
import AsyncHTTPClient
import Logging
import ServiceLifecycle

/// The central agent loop that drives one user turn through the agent.
///
/// ``ArcAgent`` is an **actor** conforming to Swift Service Lifecycle's
/// ``Service`` protocol. All state mutations are serialized by the actor.
/// The HTTP client is created in ``run()`` and torn down after all work
/// completes — no ad-hoc shutdown methods, no resource leaks.
///
/// ## Turn Loop
///
/// 1. Build system prompt (identity, skills index, memory, context files)
/// 2. Build turn context (messages + tool schemas)
/// 3. Call LLM with retry logic and fallback models
/// 4. Parse response — if text, return; if tool_calls, dispatch
/// 5. Append results to history, repeat from step 2
/// 6. Post-turn hooks (memory write, session persistence)
public actor ArcAgent: Service {

    // MARK: - Configuration

    /// Configuration for the agent.
    public struct Configuration: Sendable {
        /// The model to use.
        public var model: String
        /// The provider name.
        public var provider: String
        /// The API base URL.
        public var baseURL: URL
        /// The API key.
        public var apiKey: String
        /// The tool registry.
        public var registry: CompileTimeToolRegistry
        /// The session store.
        public var sessionStore: SessionStore
        /// The memory provider for persistent memory injection.
        public var memoryProvider: MemoryProvider?
        /// Discovered skills for the skills index.
        public var skills: [Skill]
        /// Maximum iterations per conversation.
        public var maxIterations: Int
        /// Maximum duration per turn in seconds.
        public var maxTurnDuration: Int
        /// Whether to persist sessions.
        public var persistSessions: Bool
        /// The approval mode for dangerous commands.
        public var approvalMode: ApprovalMode
        /// Single query mode. If set, the agent processes one query and exits.
        public var query: String?
        /// Approximate max context tokens before auto-compression.
        public var maxContextTokens: Int
        /// Hermes-parity auxiliary-model overrides (`auxiliary.<task>`), used
        /// for smart approval, LLM compression, and task routing.
        public var auxiliary: AuxiliaryModelSet

        /// Mixture-of-Agents configuration (Hermes `moa` config block).
        public var moa: MoAConfig

        /// The session ID to restore persisted history from. `nil` starts a
        /// fresh session with a new UUID.
        public var sessionID: String?

        /// The model's context length in tokens (used to derive the
        /// compression threshold; Hermes parity: threshold = context / 2).
        /// `nil` falls back to ``maxContextTokens``.
        public var contextLength: Int?

        /// Additional API keys for the same endpoint, tried in order when a
        /// key returns 401 (CredentialPool rotation).
        public var fallbackAPIKeys: [String]

        /// Inject project context files (AGENTS.md, .hermes.md, CLAUDE.md,
        /// .cursorrules) from the working directory into the system prompt.
        public var injectProjectContext: Bool

        /// Directory scanned for project context files. `nil` = current
        /// working directory (the default for the CLI).
        public var contextDirectory: URL?

        /// Platform label for the prompt's session line (Hermes parity).
        public var platformHint: String

        public init(
            model: String,
            provider: String = "openai",
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            apiKey: String,
            registry: CompileTimeToolRegistry,
            sessionStore: SessionStore = FileSessionStore(),
            memoryProvider: MemoryProvider? = FileMemoryProvider(),
            skills: [Skill] = [],
            maxIterations: Int = 25,
            maxTurnDuration: Int = 120,
            persistSessions: Bool = true,
            approvalMode: ApprovalMode = .manual,
            query: String? = nil,
            maxContextTokens: Int = 64_000,
            auxiliary: AuxiliaryModelSet = AuxiliaryModelSet(),
            sessionID: String? = nil,
            contextLength: Int? = nil,
            fallbackAPIKeys: [String] = [],
            injectProjectContext: Bool = true,
            contextDirectory: URL? = nil,
            platformHint: String = "cli",
            moa: MoAConfig = MoAConfig()
        ) {
            self.model = model
            self.provider = provider
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.registry = registry
            self.sessionStore = sessionStore
            self.memoryProvider = memoryProvider
            self.skills = skills
            self.maxIterations = maxIterations
            self.maxTurnDuration = maxTurnDuration
            self.persistSessions = persistSessions
            self.approvalMode = approvalMode
            self.query = query
            self.maxContextTokens = maxContextTokens
            self.auxiliary = auxiliary
            self.sessionID = sessionID
            self.contextLength = contextLength
            self.fallbackAPIKeys = fallbackAPIKeys
            self.injectProjectContext = injectProjectContext
            self.contextDirectory = contextDirectory
            self.platformHint = platformHint
            self.moa = moa
        }
    }

    // MARK: - State

    private let config: Configuration
    private var llmClient: (any LLMClient)?
    private var httpClient: HTTPClient?
    private var auxRouter: AuxiliaryModelRouter?
    private var messageHistory: [Message]
    private let sessionID: String
    /// How many messages of `messageHistory` have been persisted to the
    /// session store. Grows monotonically across turns.
    private var persistedMessageCount = 0
    /// Whether the session metadata event has been created in the store.
    private var sessionCreatedInStore = false
    /// Whether persisted history has been loaded for this session. Guards the
    /// one-shot restore so repeated turns never re-read the store.
    private var sessionRestored = false
    private let retryHandler = RetryHandler(maxRetries: 3, baseDelay: 1.0)
    /// Circuit breaker for the primary LLM endpoint.
    private let circuitBreaker = CircuitBreaker(label: "primary-llm", threshold: 3, resetTimeout: 30)

    /// Per-turn recovery counters (Hermes conversation-loop parity).
    private var turnRecoveryState = TurnRecoveryState()
    /// Rate-limit buckets per route (Hermes rate_limit_tracker parity).
    private let rateLimitTracker = RateLimitTracker()
    /// Consecutive stale-stream giveups (Hermes staleness watchdog parity).
    private let staleTracker = StaleStreakTracker()
    /// Mixture-of-Agents service (Hermes moa_loop parity; built from config).
    private lazy var moaService: MoAService = {
        let baseProfile = BundledProviders.resolve(config.provider)
        return MoAService(config: config.moa, aggregatorModelName: currentModelName) { [weak self] role, apiKey in
            guard let self else { return nil }
            guard let hc = await self.httpClient else { return nil }
            let profile = role.provider.flatMap { BundledProviders.resolve($0) } ?? baseProfile
            guard let profile else { return nil }
            let key = apiKey.isEmpty ? await self.currentAPIKey : apiKey
            return ClientFactory.makeClient(
                profile: profile, model: role.model, apiKey: key, httpClient: hc
            )
        }
    }()
    /// Structured logger for diagnostic output.
    private let logger = Logger(label: "com.arc-agent.agent")
    private let approvalManager: ApprovalManager
    private let delegationManager: DelegationManager
    /// Cached system prompt, rebuilt only when memory or skills change.
    private var cachedSystemPrompt: String?
    /// Version counter for cache invalidation. Incremented when memory or
    /// skills change; the cache is only rebuilt when this version changes.
    private var systemPromptVersion: Int = 0
    private var lastBuiltVersion: Int = -1
    /// Credential pool for 401 rotation (built in ``setupClient``/``run``).
    private var credentialPool: CredentialPool?
    /// The API key the current client was built with.
    private var currentAPIKey: String = ""
    /// The model the current client targets (tracks /model + fallback swaps).
    private var currentModelName: String = ""
    /// Cached token estimate for the tool schemas (static per agent).
    private var toolSchemaTokenEstimate: Int?
    /// Cached project context files (static per agent/working directory).
    private var contextFilesCache: [(name: String, content: String)]?
    /// Compression cool-down: summary-LLM rate limit parks us until this date.
    private var compressionCooldownUntil: Date?
    /// Anti-thrash: after two consecutive low-savings compressions, suspend
    /// compression for the remainder of the turn.
    private var compressionThrottled = false
    private var lastTwoCompressionSavings: [Int] = []
    /// Mid-turn steering messages, drained before the next LLM request.
    private var pendingSteers: [String] = []
    /// Cooperative interrupt flag, honored at iteration boundaries.
    private var turnInterrupted = false

    // MARK: - Init

    public init(config: Configuration) {
        self.config = config
        self.messageHistory = []
        self.sessionID = config.sessionID ?? UUID().uuidString
        // The smart-approval classifier is wired from `wireSmartApproval()`
        // (once the agent's own state is fully initialized).
        self.approvalManager = ApprovalManager(mode: config.approvalMode)
        self.delegationManager = DelegationManager(maxChildren: 10)
    }

    /// Wire the `approval` auxiliary model into smart approval mode.
    private func wireSmartApproval() async {
        guard config.approvalMode == .smart else { return }
        await approvalManager.setClassifier { [weak self] command in
            guard let self else { return nil }
            return await self.classifyApprovalRisk(command)
        }
    }

    /// Smart-approval risk classification via the `approval` auxiliary model.
    /// Returns nil when no approval override is configured or the call fails,
    /// letting the regex detector stand in.
    private func classifyApprovalRisk(_ command: String) async -> DangerLevel? {
        guard let router = auxRouter, router.hasOverride(.approval) else { return nil }
        guard let hc = httpClient,
              let client = router.makeClient(task: .approval, httpClient: hc) else { return nil }
        let prompt = """
        You classify shell commands for an autonomous coding agent. Reply with exactly one word from: safe, suspicious, dangerous, critical. Consider destructive or exfiltrating operations (rm -rf, mkfs, dd, diskutil erase, curl | sh) critical or dangerous.

        Command: \(command)
        """
        do {
            let resp = try await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil,
                reasoningEffort: nil
            )
            let low = (resp.content ?? "").lowercased()
            if low.contains("critical") { return .critical }
            if low.contains("danger") { return .dangerous }
            if low.contains("suspicious") { return .suspicious }
            return .safe
        } catch {
            return nil
        }
    }

    /// Build the auxiliary-model router once a client HTTP stack exists.
    private func makeAuxRouter() {
        auxRouter = AuxiliaryModelRouter(
            set: config.auxiliary,
            main: ModelConfig(
                defaultModel: config.model,
                provider: config.provider,
                baseURL: config.baseURL.absoluteString
            ),
            mainAPIKey: config.apiKey
        )
    }

    /// Set up the LLM client for gateway use (without calling `run()`).
    /// The caller owns the HTTPClient lifecycle.
    func setupClient(httpClient: HTTPClient) async {
        self.httpClient = httpClient
        makeAuxRouter()
        await wireSmartApproval()
        let pool = CredentialPool(credentials: [config.apiKey] + config.fallbackAPIKeys)
        self.credentialPool = pool
        self.currentAPIKey = config.apiKey
        self.currentModelName = config.model
        let resolvedKey = await pool.acquireLease() ?? config.apiKey
        self.llmClient = OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: resolvedKey,
            model: config.model,
            httpClient: httpClient
        )
        // The memory tool writes through the agent's configured provider so
        // the model reads and writes use the same backend as this agent.
        MemoryTool.provider = config.memoryProvider
        // The session-search tool reads through the agent's session store.
        SessionSearchTool.store = config.sessionStore
    }

    /// Replace the LLM client for this agent.
    ///
    /// Lets callers substitute a client built for a specific conversation
    /// (profile model, provider, or a mock in tests) instead of the
    /// configuration-derived default.
    func setClient(_ client: any LLMClient) {
        self.llmClient = client
    }

    /// Inject a system message at the beginning of the conversation.
    /// Used by the gateway to inject profile-specific SOUL.md content.
    func injectSystemMessage(_ content: String) async {
        // Remove any existing system messages with the same prefix
        messageHistory.removeAll { msg in
            msg.role == .system && (msg.content?.hasPrefix("[Profile:") ?? false)
        }
        messageHistory.insert(Message(role: .system, content: "[Profile: \(config.model)]\n\(content)"), at: 0)
        systemPromptVersion += 1
    }

    // MARK: - Service

    public func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        self.httpClient = httpClient
        makeAuxRouter()
        await wireSmartApproval()

        // Wire the credential pool (multi-key rotation on 401)
        let pool = CredentialPool(credentials: [config.apiKey] + config.fallbackAPIKeys)
        self.credentialPool = pool
        self.currentAPIKey = config.apiKey
        self.currentModelName = config.model
        let resolvedKey = await pool.acquireLease() ?? config.apiKey

        let client = OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: resolvedKey,
            model: config.model,
            httpClient: httpClient
        )
        self.llmClient = client

        // Wire delegation tools to the manager
        DelegateTaskTool.manager = delegationManager
        ListChildrenTool.manager = delegationManager
        SteerChildTool.manager = delegationManager
        StopChildTool.manager = delegationManager

        // The memory tool writes through the agent's configured provider.
        MemoryTool.provider = config.memoryProvider
        SessionSearchTool.store = config.sessionStore

        if let q = config.query {
            let response = try await runConversation(message: q)
            print(response)
        } else {
            try await runInteractive()
        }

        try? await httpClient.shutdown()
    }

    // MARK: - Interactive REPL

    /// Readline handle for async stdin access.
    private let stdinHandle = FileHandle.standardInput

    /// Run the interactive readline REPL with slash commands.
    private func runInteractive() async throws {
        print("⚡ ARC Agent — interactive mode")
        print("   Type your message, or /quit to exit.")
        print("   Commands: /model, /retry, /help, /compress, /quit\n")
        print("> ", terminator: "")

        for try await input in stdinHandle.bytes.lines {
            if input.hasPrefix("/") {
                let handled = try await handleSlashCommand(input)
                if handled {
                    print("> ", terminator: "")
                    continue
                } else {
                    break
                }
            }

            let response = try await runConversation(message: input)
            print(response)
            print("")
            print("> ", terminator: "")
        }
    }

    /// Handle a slash command. Returns `false` if the command should exit.
    private func handleSlashCommand(_ input: String) async throws -> Bool {
        let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts.first?.lowercased() ?? ""
        let args = parts.count > 1 ? parts[1] : ""

        switch command {
        case "/quit", "/exit":
            return false

        case "/help":
            print("""
            Available commands:
              /help           — Show this help
              /model <name>   — Switch model (e.g. /model gpt-4o)
              /retry          — Retry the last message
              /compress       — Compress conversation history
              /quit           — Exit
            """)
            print("")
            return true

        case "/model":
            guard !args.isEmpty else {
                print("Usage: /model <model-name>")
                print("")
                return true
            }
            if var client = self.llmClient, let hc = self.httpClient {
                client = OpenAICompatibleClient(
                    baseURL: config.baseURL,
                    apiKey: config.apiKey,
                    model: args,
                    httpClient: hc
                )
                self.llmClient = client
                self.currentModelName = args
            }
            print("Switched to model: \(args)")
            print("")
            return true

        case "/retry":
            if let lastMsg = messageHistory.last, lastMsg.role == .assistant {
                messageHistory.removeLast()
            }
            if let lastUserIndex = messageHistory.lastIndex(where: { $0.role == .user }) {
                let lastUserMessage = messageHistory[lastUserIndex].content ?? ""
                let response = try await runConversation(message: lastUserMessage)
                print(response)
                print("")
            } else {
                print("No previous message to retry.")
                print("")
            }
            return true

        case "/compress":
            let maxMessages = 20
            if messageHistory.count > maxMessages {
                let systemMessages = messageHistory.filter { $0.role == .system }
                let recentMessages = messageHistory.suffix(maxMessages - systemMessages.count)
                messageHistory = Array(systemMessages) + Array(recentMessages)
                print("Compressed: keeping last \(messageHistory.count) messages.")
            } else {
                print("History is already compact (\(messageHistory.count) messages).")
            }
            print("")
            return true

        default:
            print("Unknown command: \(command). Type /help for available commands.")
            print("")
            return true
        }
    }

    // MARK: - Conversation

    /// Restore persisted history for this session from the session store.
    ///
    /// One-shot and best-effort: a configured ``Configuration.sessionID``
    /// loads the stored messages into ``messageHistory`` so a restarted
    /// agent continues where it left off. Load failures are logged and the
    /// agent starts fresh — persistence must never fail a turn.
    func restoreSessionIfNeeded() async {
        guard !sessionRestored else { return }
        sessionRestored = true
        guard let sid = config.sessionID else { return }
        do {
            if let session = try await config.sessionStore.get(id: sid) {
                messageHistory = Self.sanitizeMessages(session.messages)
                persistedMessageCount = messageHistory.count
                sessionCreatedInStore = true
                logger.info("restored \(session.messages.count) message(s) for session \(sid)")
            } else {
                logger.info("session \(sid) not found in store; starting fresh")
            }
        } catch {
            logger.error("failed to restore session \(sid): \(error)")
        }
    }

    /// Reset per-turn recovery/interruption state at the start of a turn.
    /// ``turnInterrupted`` is intentionally NOT reset here: an interrupt
    /// request is sticky until a turn boundary consumes it.
    private func resetTurnState() {
        compressionThrottled = false
        lastTwoCompressionSavings = []
        turnRecoveryState = TurnRecoveryState()
    }

    /// Inject a mid-turn steering instruction. Drained before the next LLM
    /// request so the model sees it on this iteration (Hermes `/steer`
    /// parity). Rendered as a distinct `[steer: …]` user turn.
    func steer(_ message: String) {
        pendingSteers.append(message)
    }

    /// Request cooperative interruption of the current turn. Honored at the
    /// next iteration boundary — in-flight API calls finish first.
    func interruptTurn() {
        turnInterrupted = true
    }

    /// Drain pending steering messages into the history.
    private func drainSteers() {
        guard !pendingSteers.isEmpty else { return }
        let steers = pendingSteers
        pendingSteers.removeAll()
        for s in steers {
            messageHistory.append(Message(role: .user, content: "[steer: \(s)]"))
        }
    }

    /// Generate a session title in the background via the `title_generation`
    /// auxiliary model (Hermes parity). No-op when no override is configured
    /// or persistence is off; best-effort by design.
    private func maybeGenerateTitle() async {
        guard config.persistSessions, sessionCreatedInStore else { return }
        guard let router = auxRouter, router.hasOverride(.titleGeneration) else { return }
        guard let hc = httpClient,
              let client = router.makeClient(task: .titleGeneration, httpClient: hc) else { return }
        let recent = messageHistory.suffix(6).compactMap { $0.content }.joined(separator: "\n")
        guard !recent.isEmpty else { return }
        let prompt = "Generate a short title (max 6 words) for this conversation:\n\n\(recent)"
        do {
            let resp = try await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil,
                reasoningEffort: nil
            )
            guard let title = resp.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.count <= 60 else { return }
            if var session = try? await config.sessionStore.get(id: sessionID) {
                session.title = (session.title?.isEmpty == false ? session.title : title)
                try? await config.sessionStore.update(session)
            }
        } catch {
            logger.debug("title generation failed: \(error)")
        }
    }

    /// Run a single conversation turn with the given user message.
    func runConversation(message: String) async throws -> String {
        guard let llmClient else {
            return "Error: Agent not started. Call run() first."
        }

        // Sticky interrupt: a queued interrupt cancels this turn before any
        // work (including restore) happens.
        if turnInterrupted {
            turnInterrupted = false
            return "Interrupted by user."
        }

        await restoreSessionIfNeeded()
        resetTurnState()
        messageHistory.append(Message(role: .user, content: message))

        let response = try await runTurnLoop(client: llmClient)

        await persistConversationIfNeeded()

        // Hermes parity: background title generation via the auxiliary router.
        Task { await self.maybeGenerateTitle() }

        return response
    }

    /// Persist any messages not yet stored for this session.
    ///
    /// The first persist creates the session (metadata + messages in one
    /// event batch); later turns append new messages and bump the metadata.
    /// Storage failures are logged but never fail the turn — the agent and
    /// the conversation must stay alive even if a server is briefly down.
    private func persistConversationIfNeeded() async {
        let store = config.sessionStore
        guard config.persistSessions, messageHistory.count > persistedMessageCount else { return }
        let history = messageHistory
        // Guard against the history shrinking (extractive compression
        // replaces older messages): never index out of range.
        let newMessages: [Message]
        if persistedMessageCount < history.count {
            newMessages = Array(history[persistedMessageCount...])
        } else {
            newMessages = []
        }
        persistedMessageCount = history.count
        guard !newMessages.isEmpty else { return }

        do {
            if !sessionCreatedInStore {
                try await store.create(Session(
                    id: sessionID,
                    createdAt: Date(),
                    updatedAt: Date(),
                    model: config.model,
                    provider: config.provider,
                    messages: newMessages
                ))
                sessionCreatedInStore = true
            } else {
                for message in newMessages {
                    try await store.appendMessage(sessionID: sessionID, message: message)
                }
            }
            logger.info("persisted \(newMessages.count) message(s) to session store")
        } catch {
            logger.error("failed to persist conversation to session store: \(error)")
        }
    }

    // MARK: - Token Counting

    /// Calibrated token counter for estimating context usage.
    private let tokenCounter = TokenCounter()

    /// Estimate the token count of the FULL request: system prompt (cached),
    /// conversation history, and tool schemas. The old history-only estimate
    /// hid a whole scaffold of tokens and under-fired compression.
    private func estimateRequestTokens() async -> Int {
        var total = tokenCounter.count(messages: messageHistory, model: config.model)
        if let prompt = cachedSystemPrompt {
            total += tokenCounter.count(prompt, model: config.model)
        } else if let prompt = try? await buildSystemPrompt() {
            total += tokenCounter.count(prompt, model: config.model)
        }
        total += toolSchemaTokens()
        return total
    }

    /// Effective compression threshold: 50% of the model context length when
    /// known (Hermes parity), otherwise the configured ``maxContextTokens``.
    nonisolated func effectiveContextLimit() -> Int {
        if let ctx = config.contextLength, ctx > 0 {
            return ctx / 2
        }
        return config.maxContextTokens
    }

    /// Token estimate for the tool schemas, cached (schema set is static).
    private func toolSchemaTokens() -> Int {
        if let cached = toolSchemaTokenEstimate { return cached }
        let schemas = config.registry.buildToolSchemas(enabled: [], disabled: [])
        guard let data = try? JSONSerialization.data(withJSONObject: schemas),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        let estimate = tokenCounter.count(text, model: config.model)
        toolSchemaTokenEstimate = estimate
        return estimate
    }

    /// Auto-compress history if the FULL estimated request (system prompt +
    /// history + tool schemas) exceeds the effective context limit.
    ///
    /// Hermes-parity guards: head protection (first exchange is never
    /// summarized), token-budget tail (~20K), iterative summary updates,
    /// summary-model cool-down after rate limits, and anti-thrash that
    /// suspends compression after two consecutive low-savings rounds.
    private func autoCompressIfNeeded() async {
        guard !compressionThrottled else { return }
        let limit = effectiveContextLimit()
        let estimated = await estimateRequestTokens()
        guard estimated > limit else { return }

        let systemMessages = messageHistory.filter { $0.role == .system }
        let nonSystem = messageHistory.filter { $0.role != .system }

        // Head protection: never summarize the first exchange.
        let head = Array(nonSystem.prefix(min(2, nonSystem.count)))
        let middle = Array(nonSystem.dropFirst(head.count))

        // Tail protection: token budget (~20K, at least the last 4 messages).
        let tailBudget = min(20_000, limit / 3)
        var tailTokens = 0
        var tailCount = 0
        for msg in middle.reversed() {
            tailTokens += tokenCounter.count(msg.content ?? "", model: config.model) + 4
            tailCount += 1
            if tailTokens >= tailBudget && tailCount >= 4 { break }
        }
        let tail = Array(middle.suffix(tailCount))
        let compressible = Array(middle.prefix(max(0, middle.count - tailCount)))

        guard !compressible.isEmpty else {
            // Even the protected window alone exceeds the budget.
            messageHistory = systemMessages + Array(nonSystem.suffix(min(8, nonSystem.count)))
            return
        }

        let beforeTokens = tokenCounter.count(messages: messageHistory, model: config.model)

        // Iterative: fold the existing summary into the material so a
        // re-compression updates the summary instead of starting over.
        var material: [Message] = compressible
        if let existing = systemMessages.first(where: { ($0.content ?? "").hasPrefix(Self.compressionSummaryPrefix) }),
           let summaryBody = existing.content {
            material.insert(Message(role: .system, content: summaryBody), at: 0)
        }

        let summaryText: String
        if let summarized = await summarizeForCompression(material) {
            summaryText = summarized
        } else {
            summaryText = Self.compressedRecord(material)
            logger.warning("compression: aux summary unavailable; using extractive record")
        }

        let newSystem = systemMessages.filter { !($0.content ?? "").hasPrefix(Self.compressionSummaryPrefix) }
        let summaryMessage = Message(
            role: .system,
            content: "\(Self.compressionSummaryPrefix) Key information, decisions, and facts from these exchanges are preserved below:\n\n\(summaryText)"
        )
        messageHistory = newSystem + [summaryMessage] + head + tail

        // Anti-thrash: two consecutive compressions that each saved less than
        // 10% of the limit suspend compression for the rest of the turn.
        let afterTokens = tokenCounter.count(messages: messageHistory, model: config.model)
        let saved = beforeTokens - afterTokens
        lastTwoCompressionSavings.append(saved)
        if lastTwoCompressionSavings.count > 2 { lastTwoCompressionSavings.removeFirst() }
        if lastTwoCompressionSavings.count == 2,
           lastTwoCompressionSavings.allSatisfy({ $0 < limit / 10 }) {
            compressionThrottled = true
            logger.warning("compression throttled: last two compressions saved <10% each")
        }

        // Rebuild the system prompt with fresh memory/skills (Hermes parity).
        invalidateSystemPrompt()
    }

    /// Attempt an LLM summarization of older messages using the `compression`
    /// auxiliary model. Returns nil when no override is configured, when the
    /// summary model is in cool-down, or when the call fails — callers fall
    /// back to the extractive record.
    private func summarizeForCompression(_ messages: [Message]) async -> String? {
        // Cool-down after the summary model was rate-limited (Hermes parity).
        if let until = compressionCooldownUntil, Date() < until { return nil }
        guard let router = auxRouter, router.hasOverride(.compression) else { return nil }
        guard let hc = httpClient,
              let client = router.makeClient(task: .compression, httpClient: hc) else { return nil }
        let record = Self.compressedRecord(messages)
        let prompt = """
        You are the context compressor for a long agent conversation. Produce a dense summary
        of the conversation excerpts below. Preserve every decision, fact, path, tool result,
        and instruction verbatim where practical. Target 150-400 words.

        \(record)
        """
        do {
            let resp = try await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil,
                reasoningEffort: nil
            )
            let text = (resp.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            if case LLMError.rateLimited = error {
                compressionCooldownUntil = Date().addingTimeInterval(60)
                logger.warning("compression aux model rate-limited; cool-down 60s")
            } else {
                logger.warning("compression aux model failed: \(error)")
            }
            return nil
        }
    }

    /// Extractive compression record: concatenate older messages with context
    /// markers (the fallback when no compression auxiliary model is set).
    private static func compressedRecord(_ messages: [Message]) -> String {
        messages.compactMap { msg -> String? in
            guard let content = msg.content, !content.isEmpty else { return nil }
            let roleLabel: String
            switch msg.role {
            case .user: roleLabel = "User"
            case .assistant: roleLabel = "Assistant"
            case .system: roleLabel = "System"
            case .tool: roleLabel = "Tool"
            default: roleLabel = "Unknown"
            }
            return "[\(roleLabel)]: \(content)"
        }.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Turn Loop

    /// The core turn loop with retry logic, fallback models, and timeout.
    private func runTurnLoop(client: any LLMClient) async throws -> String {
        guard let hc = self.httpClient else {
            return "Error: Agent HTTP client not initialized."
        }
        var currentClient = client
        var fallbackIndex = 0
        let fallbacks = BundledProviders.resolve(config.provider)?.fallbackModels ?? []
        var emptyAfterToolsNudges = 0
        var emptyToolCallsNudges = 0
        var truncationContinuations = 0
        /// Whether the *previous* iteration appended tool results — used by
        /// the empty-response recovery on the following iteration. Persists
        /// across iterations (per-turn state), not per-iteration.
        var appendedToolResults = false

        for iteration in 0..<config.maxIterations {
            if turnInterrupted {
                turnInterrupted = false
                return "Interrupted by user."
            }
            drainSteers()

            // Auto-compress if context is too large
            await autoCompressIfNeeded()

            // 1. Build system prompt with memory and skills (cached)
            let systemPrompt = try await buildSystemPrompt()

            // 2. Build messages array
            var messages: [Message] = [Message(role: .system, content: systemPrompt)]
            messages.append(contentsOf: Self.sanitizeMessages(messageHistory))

            // 3. Build tool schemas
            let toolSchemas = config.registry.buildToolSchemas(
                enabled: [],
                disabled: []
            )

            // 3b. Mixture-of-Agents advisory context (Hermes moa_loop: the
            // acting model sees synthesized reference advice before it acts).
            if config.moa.enabled {
                let moaResult = await moaService.aggregate(
                    userPrompt: messageHistory.last(where: { $0.role == .user })?.content ?? "",
                    apiMessages: Self.apiForm(messages)
                )
                if !moaResult.advisoryBlock.isEmpty {
                    messages.append(Message(
                        role: .system,
                        content: "Advisory context from reference models (Mixture of Agents):\n\(moaResult.advisoryBlock)"
                    ))
                }
            }

            // 4. Call LLM with retry logic and per-turn timeout
            let response: LLMResponse
            do {
                response = try await callWithRetry(
                    client: currentClient,
                    makeClient: { self.freshClient() ?? currentClient },
                    messages: messages,
                    tools: toolSchemas,
                    timeout: config.maxTurnDuration
                )
            } catch {
                let errorClass = classifyError(error)

                // Rate-limit recovery: honor Retry-After, bounded per turn.
                if case LLMError.rateLimited(let retryAfter) = error,
                   turnRecoveryState.rateLimitRecoveries < TurnRecoveryState.maxRateLimitRecoveries {
                    turnRecoveryState.rateLimitRecoveries += 1
                    await rateLimitTracker.recordThrottle(route: rateLimitRoute(), retryAfter: retryAfter)
                    let delay = FailureBackoff.delay(for: .rateLimit, attempt: 0, retryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Credential rotation: an auth failure means this key is bad.
                if case LLMError.authenticationFailed = error,
                   let rotated = await rotatedClient() {
                    currentClient = rotated
                    continue
                }

                // Try fallback models on permanent or retryable errors
                if errorClass == .permanent || errorClass == .retryable {
                    if fallbackIndex < fallbacks.count {
                        let fallbackModel = fallbacks[fallbackIndex]
                        fallbackIndex += 1
                        logger.warning("Falling back to \(fallbackModel)")
                        currentModelName = fallbackModel
                        currentClient = OpenAICompatibleClient(
                            baseURL: config.baseURL,
                            apiKey: config.apiKey,
                            model: fallbackModel,
                            httpClient: hc
                        )
                        continue
                    }
                }

                return "Error: \(error.localizedDescription)"
            }

            // 5. Truncation recovery — "length"/"max_tokens" means the answer
            // was cut off. Keep the partial, nudge a bounded continuation,
            // and loop instead of returning a half answer.
            let finishReason = response.finishReason ?? ""
            if (finishReason == "length" || finishReason == "max_tokens"),
               (response.toolCalls ?? []).isEmpty,
               let partial = response.content, !partial.isEmpty,
               truncationContinuations < Self.maxTruncationContinuations {
                messageHistory.append(Message(role: .assistant, content: partial))
                messageHistory.append(Message(role: .system, content: Self.truncationNudge))
                truncationContinuations += 1
                continue
            }

            // 6. Parse response — tool calls take precedence over content.
            switch Self.classifyTurn(content: response.content, toolCalls: response.toolCalls) {
            case .text(let content):
                messageHistory.append(Message(role: .assistant, content: content))
                turnRecoveryState.markProviderSuccess()
                return content

            case .toolCalls(let toolCalls):
                messageHistory.append(Message(
                    role: .assistant,
                    content: response.content,
                    toolCalls: toolCalls
                ))

                let outcomes = await executeToolCalls(toolCalls)
                for (call, result) in outcomes {
                    messageHistory.append(Message(
                        role: .tool,
                        content: result,
                        name: call.function.name,
                        toolCallID: call.id
                    ))
                }
                appendedToolResults = !outcomes.isEmpty
                turnRecoveryState.markProviderSuccess()

                continue

            case .empty:
                // Neither real content nor tool calls. Two known model
                // failures get bounded synthetic nudges before plain
                // re-prompting: an empty tool-calls array under
                // finish_reason == "tool_calls", and silence right after
                // tool results were delivered.
                if finishReason == "tool_calls",
                   emptyToolCallsNudges < Self.maxEmptyToolCallsNudges {
                    messageHistory.append(Message(role: .system, content: Self.emptyToolCallsNudge))
                    emptyToolCallsNudges += 1
                    continue
                }
                if appendedToolResults,
                   emptyAfterToolsNudges < Self.maxEmptyAfterToolsNudges {
                    messageHistory.append(Message(role: .system, content: Self.emptyAfterToolsNudge))
                    emptyAfterToolsNudges += 1
                    continue
                }
                // Empty-response storm guard (Hermes bounded empty responses):
                // after N consecutive empty replies, stop re-prompting.
                turnRecoveryState.emptyStormStreak += 1
                if turnRecoveryState.emptyStormStreak >= TurnRecoveryState.emptyStormThreshold {
                    return RecoveryNudges.emptyStormExhaustedMessage
                }
                // Reasoning models can emit a whitespace-only prefix — loop.
                continue
            }

            if iteration == config.maxIterations - 1 {
                return "I encountered an issue processing your request. Please try again."
            }
        }

        return "The conversation reached the maximum iteration limit. Please start a new session."
    }

    // MARK: - Streaming Turn Loop

    /// Run the agent loop with streaming responses.
    /// Yields tokens as they arrive from the LLM, then yields the final
    /// response text. Tool calls are executed synchronously and their
    /// results are yielded as single chunks.
    public func streamConversation(message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    await restoreSessionIfNeeded()
                    resetTurnState()
                    messageHistory.append(Message(role: .user, content: message))
                    try await runStreamingTurnLoop(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// The core streaming turn loop.
    private func runStreamingTurnLoop(
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let hc = self.httpClient else {
            continuation.yield("Error: Agent HTTP client not initialized.")
            continuation.finish()
            return
        }
        var currentClient = self.llmClient ?? OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            httpClient: hc
        )
        var fallbackIndex = 0
        let fallbacks = BundledProviders.resolve(config.provider)?.fallbackModels ?? []
        var emptyAfterToolsNudges = 0
        var emptyToolCallsNudges = 0
        var truncationContinuations = 0
        /// Whether the *previous* iteration appended tool results (see
        /// runTurnLoop) — per-turn state that survives the iteration boundary.
        var appendedToolResults = false

        for iteration in 0..<config.maxIterations {
            if turnInterrupted {
                turnInterrupted = false
                continuation.yield("Interrupted by user.")
                continuation.finish()
                return
            }
            drainSteers()
            await autoCompressIfNeeded()
            var streamFinishReason: String? = nil

            let systemPrompt = try await buildSystemPrompt()
            var messages: [Message] = [Message(role: .system, content: systemPrompt)]
            messages.append(contentsOf: Self.sanitizeMessages(messageHistory))

            let toolSchemas = config.registry.buildToolSchemas(
                enabled: [],
                disabled: []
            )

            // MoA advisory context (Hermes moa_loop parity).
            if config.moa.enabled {
                let moaResult = await moaService.aggregate(
                    userPrompt: messageHistory.last(where: { $0.role == .user })?.content ?? "",
                    apiMessages: Self.apiForm(messages)
                )
                if !moaResult.advisoryBlock.isEmpty {
                    messages.append(Message(
                        role: .system,
                        content: "Advisory context from reference models (Mixture of Agents):\n\(moaResult.advisoryBlock)"
                    ))
                }
            }

            var accumulatedContent = ""
            var accumulatedToolCalls: [ToolCall] = []

            do {
                let stream = try await callStreamWithRetry(
                    client: currentClient,
                    makeClient: { self.freshClient() ?? currentClient },
                    messages: messages,
                    tools: toolSchemas,
                    timeout: config.maxTurnDuration
                )

                for try await delta in stream {
                    if let content = delta.content {
                        accumulatedContent += content
                        continuation.yield(content)
                    }
                    if let toolCallDeltas = delta.toolCalls {
                        for tcd in toolCallDeltas {
                            if tcd.index < accumulatedToolCalls.count {
                                let existing = accumulatedToolCalls[tcd.index]
                                let newArgs = (existing.function.arguments) + (tcd.arguments ?? "")
                                accumulatedToolCalls[tcd.index] = ToolCall(
                                    id: tcd.id ?? existing.id,
                                    type: "function",
                                    function: ToolCallFunction(
                                        name: tcd.name ?? existing.function.name,
                                        arguments: newArgs
                                    )
                                )
                            } else if let id = tcd.id, let name = tcd.name {
                                let tc = ToolCall(
                                    id: id,
                                    type: "function",
                                    function: ToolCallFunction(
                                        name: name,
                                        arguments: tcd.arguments ?? ""
                                    )
                                )
                                accumulatedToolCalls.append(tc)
                            }
                        }
                    }
                    if let finish = delta.finishReason {
                        streamFinishReason = finish
                        break
                    }
                }
            } catch {
                let errorClass = classifyError(error)

                // Stale-stream recovery (Hermes staleness watchdog with
                // patience budget + give-up streak): reconnect once per turn,
                // then give up after the streak threshold.
                if error is StaleStreamError {
                    _ = await staleTracker.recordStale()
                    if await staleTracker.shouldGiveUp {
                        continuation.yield("The model stream stalled repeatedly. Please try again.")
                        continuation.finish()
                        return
                    }
                    if !turnRecoveryState.primaryRecoveryAttempted {
                        turnRecoveryState.primaryRecoveryAttempted = true
                        logger.warning("stale stream detected; reconnecting")
                        currentClient = freshClient() ?? currentClient
                        continue
                    }
                }

                // Rate-limit recovery: honor Retry-After, bounded per turn.
                if case LLMError.rateLimited(let retryAfter) = error,
                   turnRecoveryState.rateLimitRecoveries < TurnRecoveryState.maxRateLimitRecoveries {
                    turnRecoveryState.rateLimitRecoveries += 1
                    await rateLimitTracker.recordThrottle(route: rateLimitRoute(), retryAfter: retryAfter)
                    let delay = FailureBackoff.delay(for: .rateLimit, attempt: 0, retryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Credential rotation: an auth failure means this key is bad.
                if case LLMError.authenticationFailed = error,
                   let rotated = await rotatedClient() {
                    currentClient = rotated
                    continue
                }

                if errorClass == .permanent || errorClass == .retryable {
                    if fallbackIndex < fallbacks.count {
                        let fallbackModel = fallbacks[fallbackIndex]
                        fallbackIndex += 1
                        currentModelName = fallbackModel
                        currentClient = OpenAICompatibleClient(
                            baseURL: config.baseURL,
                            apiKey: config.apiKey,
                            model: fallbackModel,
                            httpClient: hc
                        )
                        continue
                    }
                }
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
                return
            }

            // Truncation recovery (same contract as runTurnLoop).
            let streamFinish = streamFinishReason ?? ""
            if (streamFinish == "length" || streamFinish == "max_tokens"),
               accumulatedToolCalls.isEmpty,
               !accumulatedContent.isEmpty,
               truncationContinuations < Self.maxTruncationContinuations {
                messageHistory.append(Message(role: .assistant, content: accumulatedContent))
                messageHistory.append(Message(role: .system, content: Self.truncationNudge))
                truncationContinuations += 1
                continue
            }

            // Tool calls take precedence over content — classify with the
            // same rules as runTurnLoop (see classifyTurn).
            switch Self.classifyTurn(
                content: accumulatedContent,
                toolCalls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
            ) {
            case .text(let content):
                messageHistory.append(Message(role: .assistant, content: content))
                turnRecoveryState.markProviderSuccess()
                continuation.finish()
                return

            case .toolCalls(let toolCalls):
                messageHistory.append(Message(
                    role: .assistant,
                    content: accumulatedContent.isEmpty ? nil : accumulatedContent,
                    toolCalls: toolCalls
                ))

                let outcomes = await executeToolCalls(toolCalls)
                for (call, result) in outcomes {
                    messageHistory.append(Message(
                        role: .tool,
                        content: result,
                        name: call.function.name,
                        toolCallID: call.id
                    ))
                    continuation.yield("[Tool: \(call.function.name)] \(result)\n")
                }
                appendedToolResults = !outcomes.isEmpty
                turnRecoveryState.markProviderSuccess()
                continue

            case .empty:
                // Bounded nudges for the same two failure modes as
                // runTurnLoop, then plain re-prompting.
                if streamFinish == "tool_calls",
                   emptyToolCallsNudges < Self.maxEmptyToolCallsNudges {
                    messageHistory.append(Message(role: .system, content: Self.emptyToolCallsNudge))
                    emptyToolCallsNudges += 1
                    continue
                }
                if appendedToolResults,
                   emptyAfterToolsNudges < Self.maxEmptyAfterToolsNudges {
                    messageHistory.append(Message(role: .system, content: Self.emptyAfterToolsNudge))
                    emptyAfterToolsNudges += 1
                    continue
                }
                // Whitespace-only prefix — keep the loop going, but bounded by
                // the empty-response storm guard (Hermes).
                turnRecoveryState.emptyStormStreak += 1
                if turnRecoveryState.emptyStormStreak >= TurnRecoveryState.emptyStormThreshold {
                    continuation.yield(RecoveryNudges.emptyStormExhaustedMessage)
                    continuation.finish()
                    return
                }
                continue
            }

            if iteration == config.maxIterations - 1 {
                continuation.yield("I encountered an issue processing your request. Please try again.")
                continuation.finish()
                return
            }
        }

        continuation.yield("The conversation reached the maximum iteration limit. Please start a new session.")
        continuation.finish()
    }

    /// Call the LLM with retry logic, circuit breaker, and exponential backoff.
    ///
    /// - Parameters:
    ///   - client: The LLM client to use.
    ///   - messages: The message history to send.
    ///   - tools: The tool schemas to include.
    ///   - timeout: Per-call timeout in seconds (default: 120).
    /// - Returns: The LLM response.
    /// - Throws: ``LLMError`` if all retries are exhausted or the error is permanent.
    ///   Throws ``CircuitBreakerError.open`` if the circuit is open.
    private func callWithRetry(
        client: any LLMClient,
        makeClient: @escaping () -> any LLMClient,
        messages: [Message],
        tools: [[String: Any]]?,
        timeout: Int = 120
    ) async throws -> LLMResponse {
        // Check circuit breaker — if open, reject immediately
        let cbState = await circuitBreaker.currentState()
        if case .open(let resetAt) = cbState {
            throw CircuitBreakerError.open(
                label: circuitBreaker.label,
                resetAt: resetAt,
                lastFailureReason: "Circuit breaker is open"
            )
        }

        var lastError: Error? = nil
        /// Client rebuilt by PRIMARY transport recovery (used only after a
        /// transport-level failure; the injected client stays authoritative).
        var recoveredClient: (any LLMClient)? = nil
        let toolsData: Data?
        if let tools, !tools.isEmpty {
            toolsData = try JSONSerialization.data(withJSONObject: tools)
        } else {
            toolsData = nil
        }

        for attempt in 0..<retryHandler.maxRetries {
            do {
                let activeClient = recoveredClient ?? client
                let toolsArg: [[String: Any]]?
                if let toolsData {
                    toolsArg = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]]
                } else {
                    toolsArg = nil
                }

                let toolsPayload: Data
                if let toolsArg {
                    toolsPayload = try JSONSerialization.data(withJSONObject: toolsArg)
                } else {
                    toolsPayload = Data()
                }

                let result = try await withThrowingTaskGroup(of: LLMResponse.self) { group in
                    group.addTask {
                        let deserialized: [[String: Any]]?
                        if toolsPayload.isEmpty {
                            deserialized = nil
                        } else {
                            deserialized = try JSONSerialization.jsonObject(
                                with: toolsPayload
                            ) as? [[String: Any]]
                        }
                        return try await activeClient.complete(
                            messages: messages,
                            tools: deserialized
                        )
                    }

                    group.addTask {
                        try await Task.sleep(
                            nanoseconds: UInt64(timeout) * 1_000_000_000
                        )
                        throw LLMError.timeout(TimeInterval(timeout))
                    }

                    let result = try await group.next()
                    group.cancelAll()

                    guard let response = result else {
                        throw LLMError.timeout(TimeInterval(timeout))
                    }

                    // Record metrics using the calibrated counter, not /4
                    await Metrics.shared.recordTokens(self.tokenCounter.count(response.content ?? ""))
                    return response
                }

                // Success — reset circuit breaker
                await circuitBreaker.reset()
                await rateLimitTracker.recordSuccess(route: rateLimitRoute())
                turnRecoveryState.markProviderSuccess()
                return result
            } catch {
                lastError = error
                let errorClass = classifyError(error)
                await Metrics.shared.recordError("\(errorClass)")
                let failure = ErrorClassifier.classify(error)

                // Rate-limit backoff honoring Retry-After (Hermes).
                if case LLMError.rateLimited(let retryAfter) = error {
                    await rateLimitTracker.recordThrottle(route: rateLimitRoute(), retryAfter: retryAfter)
                    let delay = FailureBackoff.delay(for: .rateLimit, attempt: attempt, retryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Primary transport recovery: rebuild the connection once per
                // turn on transport-level failures (Hermes
                // `_try_recover_primary_transport`).
                if !turnRecoveryState.primaryRecoveryAttempted,
                   failure.reason == .timeout || failure.reason == .tls {
                    turnRecoveryState.primaryRecoveryAttempted = true
                    logger.warning("recovering primary transport after \(failure.reason.rawValue)")
                    recoveredClient = makeClient()
                    continue
                }

                switch errorClass {
                case .permanent:
                    throw error
                case .retryable:
                    if retryHandler.shouldRetry(attempt) {
                        try await retryHandler.wait(for: attempt)
                        continue
                    }
                case .contextOverflow:
                    await autoCompressIfNeeded()
                    if retryHandler.shouldRetry(attempt) {
                        try await retryHandler.wait(for: attempt)
                        continue
                    }
                }
            }
        }

        // All retries exhausted — record failure with circuit breaker
        if let last = lastError {
            await circuitBreaker.recordFailure(last)
        }

        throw lastError ?? LLMError.networkError("Request failed after \(retryHandler.maxRetries) retries")
    }

    /// Call the LLM with streaming response, retry logic, and circuit breaker.
    private func callStreamWithRetry(
        client: any LLMClient,
        makeClient: @escaping () -> any LLMClient,
        messages: [Message],
        tools: [[String: Any]]?,
        timeout: Int = 120
    ) async throws -> any AsyncSequence<LLMDelta, Error> {
        let cbState = await circuitBreaker.currentState()
        if case .open(let resetAt) = cbState {
            throw CircuitBreakerError.open(
                label: circuitBreaker.label,
                resetAt: resetAt,
                lastFailureReason: "Circuit breaker is open"
            )
        }

        var lastError: Error? = nil
        /// Client rebuilt by PRIMARY transport recovery (used only after a
        /// transport-level failure; the injected client stays authoritative).
        var recoveredClient: (any LLMClient)? = nil
        let toolsData: Data?
        if let tools, !tools.isEmpty {
            toolsData = try JSONSerialization.data(withJSONObject: tools)
        } else {
            toolsData = nil
        }

        // Staleness patience for this request (Hermes stream stale watchdog).
        let patience = streamPatience(for: messages)

        for attempt in 0..<retryHandler.maxRetries {
            do {
                let activeClient = recoveredClient ?? client
                let toolsArg: [[String: Any]]?
                if let toolsData {
                    toolsArg = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]]
                } else {
                    toolsArg = nil
                }

                let stream = try await activeClient.stream(
                    messages: messages,
                    tools: toolsArg
                )

                await circuitBreaker.reset()
                await rateLimitTracker.recordSuccess(route: rateLimitRoute())
                turnRecoveryState.markProviderSuccess()
                // Apply the per-provider stale watchdog (Hermes
                // stream-stale patience budget).
                return IdleTimeoutStream(stream, idleSeconds: patience)
            } catch {
                lastError = error
                let errorClass = classifyError(error)
                let failure = ErrorClassifier.classify(error)

                // Rate-limit backoff honoring Retry-After (Hermes).
                if case LLMError.rateLimited(let retryAfter) = error {
                    await rateLimitTracker.recordThrottle(route: rateLimitRoute(), retryAfter: retryAfter)
                    let delay = FailureBackoff.delay(for: .rateLimit, attempt: attempt, retryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Primary transport recovery on transport failures.
                if !turnRecoveryState.primaryRecoveryAttempted,
                   failure.reason == .timeout || failure.reason == .tls {
                    turnRecoveryState.primaryRecoveryAttempted = true
                    logger.warning("recovering primary transport after \(failure.reason.rawValue)")
                    recoveredClient = makeClient()
                    continue
                }

                switch errorClass {
                case .permanent:
                    throw error
                case .retryable:
                    if retryHandler.shouldRetry(attempt) {
                        try await retryHandler.wait(for: attempt)
                        continue
                    }
                case .contextOverflow:
                    await autoCompressIfNeeded()
                    if retryHandler.shouldRetry(attempt) {
                        try await retryHandler.wait(for: attempt)
                        continue
                    }
                }
            }
        }

        if let last = lastError {
            await circuitBreaker.recordFailure(last)
        }
        throw lastError ?? LLMError.networkError("Request failed after \(retryHandler.maxRetries) retries")
    }

    // MARK: - Credential Rotation

    /// Park the current API key (it just failed auth) and build a client with
    /// the next available key. Returns nil when no rotation is possible.
    private func rotatedClient() async -> OpenAICompatibleClient? {
        guard let pool = credentialPool, await pool.count > 1, let hc = httpClient else { return nil }
        await pool.reportExhaustion(key: currentAPIKey)
        guard let next = await pool.acquireLease(), next != currentAPIKey else { return nil }
        currentAPIKey = next
        logger.warning("rotating API key after authentication failure")
        return OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: next,
            model: currentModelName,
            httpClient: hc
        )
    }

    /// Rebuild the primary transport client from current state (Hermes
    /// `_try_recover_primary_transport`: fresh connection, fresh credentials
    /// — once per turn). Used when the transport itself went bad (timeout,
    /// TLS, reset) rather than the model or key.
    private func freshClient() -> OpenAICompatibleClient? {
        guard let hc = self.httpClient else { return nil }
        return OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: currentAPIKey,
            model: currentModelName,
            httpClient: hc
        )
    }

    /// Route label for rate-limit tracking (provider/model), matching Hermes'
    /// per-route buckets.
    private func rateLimitRoute() -> String {
        "\(config.provider)/\(currentModelName)"
    }

    /// Stream patience for the current model (Hermes staleness watchdog).
    private func streamPatience(for messages: [Message]) -> Double {
        let estimated = messages.reduce(0) { $0 + self.tokenCounter.count($1.content ?? "") }
        let meta = ModelMetadataRegistry.shared.metadata(for: currentModelName, provider: config.provider)
        return StalenessPolicy.streamPatience(estimatedTokens: estimated, metadata: meta)
    }

    // MARK: - Wire Laundering

    /// Redact likely secrets from text before it enters model context.
    /// NSRegularExpression is thread-safe, so these are safe static patterns.
    private static let secretPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]{16,}\b"#),
        try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        try! NSRegularExpression(pattern: #"\bAKIA[0-9A-Z]{16}\b"#),
        try! NSRegularExpression(pattern: #"\bBearer\s+[A-Za-z0-9._\-]{16,}\b"#),
        try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ]

    static func redactSecrets(_ text: String) -> String {
        var result = text
        for pattern in secretPatterns {
            let full = NSRange(result.startIndex..<result.endIndex, in: result)
            result = pattern.stringByReplacingMatches(
                in: result, options: [], range: full, withTemplate: "***REDACTED***"
            )
        }
        return result
    }

    /// Convert `[Message]` to the wire API form (Hermes api_messages shape)
    /// so MoA advisory views can preserve tool calls and results.
    static func apiForm(_ messages: [Message]) -> [[String: Any]] {
        messages.map { message in
            var dict: [String: Any] = ["role": message.role.rawValue]
            if let content = message.content { dict["content"] = content }
            if let calls = message.toolCalls, !calls.isEmpty {
                dict["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.function.name,
                            "arguments": call.function.arguments,
                        ],
                    ]
                }
            }
            return dict
        }
    }

    /// Canonicalize a tool call's arguments JSON (parse + re-serialize). A
    /// corrupted payload becomes `{}` so the tool gets a clean, parseable
    /// shape instead of an unparseable one.
    private static func canonicalizeToolCall(_ call: ToolCall) -> ToolCall {
        let args = call.function.arguments
        let canonical: String
        if let data = args.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let reparsed = try? JSONSerialization.data(withJSONObject: obj) {
            canonical = String(data: reparsed, encoding: .utf8) ?? args
        } else {
            canonical = "{}"
        }
        return ToolCall(
            id: call.id,
            type: call.type,
            function: ToolCallFunction(name: call.function.name, arguments: canonical)
        )
    }

    /// Launder a message array before sending it to the provider or before
    /// restoring it into history (Hermes api_messages parity):
    /// - drop orphaned tool results (no matching preceding assistant call);
    /// - add missing stubs so every assistant tool call has a result;
    /// - drop thinking-only assistant turns, merging a user message that
    ///   becomes adjacent *because of the drop* (never across turn
    ///   boundaries — those must stay visible to the model);
    /// - canonicalize tool-call argument JSON;
    /// - redact secrets from tool contents.
    static func sanitizeMessages(_ messages: [Message]) -> [Message] {
        // Pass 1: drop orphans, canonicalize, strip thinking-only, redact,
        // and repair only the adjacency the drop itself creates.
        var cleaned: [Message] = []
        var mergeNextUser = false
        for msg in messages {
            switch msg.role {
            case .tool:
                guard let id = msg.toolCallID,
                      cleaned.contains(where: { ass in
                          ass.role == .assistant
                              && (ass.toolCalls ?? []).contains { $0.id == id }
                      })
                else { continue } // orphaned result with no preceding call — drop
                mergeNextUser = false
                let content = msg.content.map { redactSecrets($0) }
                cleaned.append(Message(
                    role: .tool, content: content, name: msg.name,
                    toolCallID: msg.toolCallID, createdAt: msg.createdAt
                ))
            case .assistant:
                let thinkingOnly = (msg.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (msg.toolCalls ?? []).isEmpty
                if thinkingOnly {
                    // Only a drop directly after a user message creates an
                    // adjacency that needs repair.
                    mergeNextUser = (cleaned.last?.role == .user)
                    continue
                }
                mergeNextUser = false
                if let calls = msg.toolCalls {
                    cleaned.append(Message(
                        role: .assistant, content: msg.content, name: msg.name,
                        toolCalls: calls.map { canonicalizeToolCall($0) },
                        toolCallID: msg.toolCallID, createdAt: msg.createdAt,
                        reasoning: msg.reasoning, usage: msg.usage, tps: msg.tps
                    ))
                } else {
                    cleaned.append(msg)
                }
            case .user:
                if mergeNextUser, cleaned.last?.role == .user {
                    let last = cleaned[cleaned.count - 1]
                    let combined = (last.content ?? "") + "\n\n" + (msg.content ?? "")
                    cleaned[cleaned.count - 1] = Message(role: .user, content: combined, createdAt: last.createdAt)
                } else {
                    cleaned.append(msg)
                }
                mergeNextUser = false
            default:
                mergeNextUser = false
                cleaned.append(msg)
            }
        }
        // Pass 2: missing stubs — every assistant tool call needs a result.
        var withStubs: [Message] = []
        for (idx, msg) in cleaned.enumerated() {
            withStubs.append(msg)
            guard msg.role == .assistant, let calls = msg.toolCalls else { continue }
            let following = cleaned.dropFirst(idx + 1)
            for call in calls {
                guard !following.contains(where: { $0.role == .tool && $0.toolCallID == call.id }) else { continue }
                withStubs.append(Message(
                    role: .tool,
                    content: "<no result - tool call was never executed>",
                    name: call.function.name,
                    toolCallID: call.id
                ))
            }
        }
        return withStubs
    }

    // MARK: - Tool Dispatch

    /// Tools that are safe to run concurrently within one batch: read-only,
    /// no shared mutable state, no side effects observable by a sibling call.
    static let parallelSafeTools: Set<String> = [
        "read_file", "web_search", "web_extract", "skill_view",
        "kanban_list", "kanban_show", "list_profiles", "get_profile",
    ]

    /// Bounded recovery budgets. Each limits how many times a synthetic nudge
    /// is injected for a failure mode before the loop falls through to plain
    /// re-prompting (overall bounded by ``Configuration.maxIterations``).
    static let maxEmptyAfterToolsNudges = 2
    static let maxEmptyToolCallsNudges = 3
    static let maxTruncationContinuations = 2

    /// Nudge injected after tool results produced no response content.
    static let emptyAfterToolsNudge =
        "The previous turn ended without any response content. Using the tool results above, provide your answer now."
    /// Nudge injected when finish_reason is `tool_calls` but no calls arrived.
    static let emptyToolCallsNudge =
        "You requested tool calls but did not specify any. Call a tool with valid arguments, or answer directly."
    /// Nudge injected when output was truncated (finish_reason is "length").
    static let truncationNudge =
        "Your previous response was truncated. Continue exactly where it ended, without repeating yourself."

    /// Prefix marking the compression summary system message (also used to
    /// find and fold the previous summary on re-compression).
    static let compressionSummaryPrefix =
        "The following is a compressed record of earlier conversation context."

    /// Floor cap for injected project context files (chars).
    static let contextFileBudgetChars = 16_000

    /// Hermes-parity mandatory skills framing that precedes the index.
    static let skillsMandatoryFraming =
        "Before replying, scan the skills below. If a skill matches or is even partially "
        + "relevant to your task, you MUST load it with skill_view(name) and follow its "
        + "instructions. Err on the side of loading — it is always better to have context "
        + "you don't need than to miss critical steps, pitfalls, or established workflows. "
        + "Skills contain specialized knowledge — API endpoints, tool-specific commands, "
        + "and proven workflows that outperform general-purpose approaches."
    /// The outcome of parsing a single LLM turn.
    ///
    /// Tool calls always take precedence over content: some providers
    /// (notably Qwen3-family reasoning models) emit a small content prefix
    /// (e.g. `"\n\n"`) alongside `tool_calls`. Returning that prefix as the
    /// final answer would silently discard the tool calls.
    enum TurnOutcome {
        case toolCalls([ToolCall])
        case text(String)
        case empty
    }

    /// Classify a parsed LLM response into a ``TurnOutcome``.
    ///
    /// - Tool calls win over content, even when both are present.
    /// - Content that is empty or whitespace-only is treated as `.empty`
    ///   (reasoning models emit `"\n\n"` prefixes that are not answers).
    static func classifyTurn(content: String?, toolCalls: [ToolCall]?) -> TurnOutcome {
        if let toolCalls, !toolCalls.isEmpty {
            return .toolCalls(toolCalls)
        }
        if let content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(content)
        }
        return .empty
    }

    private func dispatchToolCall(_ toolCall: ToolCall) async throws -> String {
        guard let entry = config.registry.lookup(name: toolCall.function.name) else {
            return "Error: Unknown tool '\(toolCall.function.name)'."
        }

        guard let data = toolCall.function.arguments.data(using: .utf8) else {
            return "Error: Invalid arguments JSON for tool '\(toolCall.function.name)'."
        }
        let args: [String: Any]
        do {
            args = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            // Invalid-JSON recovery (Hermes `_invalid_json_retries`): feed the
            // parse failure back as a tool result and let the model retry —
            // bounded per turn so a broken model cannot loop forever.
            turnRecoveryState.invalidJSONRetries += 1
            if turnRecoveryState.invalidJSONRetries <= TurnRecoveryState.maxInvalidJSONRetries {
                return RecoveryNudges.invalidJSONToolResult(
                    toolName: toolCall.function.name,
                    error: String(describing: error)
                )
            }
            return "Error: Invalid arguments JSON for tool '\(toolCall.function.name)'."
        }

        do {
            return try await entry.handler(args)
        } catch {
            return "Error executing tool '\(toolCall.function.name)': \(error.localizedDescription)"
        }
    }

    /// Split a tool-call batch into ordered execution segments: maximal runs
    /// of parallel-safe calls, with every other call as its own single-call
    /// segment. Callers execute segments sequentially and the calls within a
    /// parallel segment concurrently, preserving emission order of results.
    static func planToolBatch(_ toolCalls: [ToolCall]) -> [[ToolCall]] {
        var segments: [[ToolCall]] = []
        var run: [ToolCall] = []
        for call in toolCalls {
            if parallelSafeTools.contains(call.function.name) {
                run.append(call)
            } else {
                if !run.isEmpty {
                    segments.append(run)
                    run = []
                }
                segments.append([call])
            }
        }
        if !run.isEmpty {
            segments.append(run)
        }
        return segments
    }

    /// Execute a batch of tool calls with a simple planner.
    ///
    /// Maximal runs of parallel-safe calls run concurrently in a ``TaskGroup``
    /// (First Law — no hand-rolled threads); every other call runs alone so
    /// side effects stay ordered. Results are returned in emission order.
    private func executeToolCalls(_ toolCalls: [ToolCall]) async -> [(ToolCall, String)] {
        var outcomes: [(ToolCall, String)] = []
        for segment in Self.planToolBatch(toolCalls) {
            if segment.count == 1 {
                let call = segment[0]
                outcomes.append((call, await runToolCall(call)))
                continue
            }
            let ordered = await withTaskGroup(of: (Int, String).self) { group in
                for (index, call) in segment.enumerated() {
                    group.addTask {
                        let result = await self.runToolCall(call)
                        return (index, result)
                    }
                }
                var collected: [(Int, String)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }
            outcomes.append(contentsOf: ordered.sorted { $0.0 < $1.0 }.map { (segment[$0.0], $0.1) })
        }
        return outcomes
    }

    /// Run one tool call end to end: terminal approval gate, dispatch, and
    /// metrics. Returns the string that becomes the tool result message.
    private func runToolCall(_ toolCall: ToolCall) async -> String {
        if toolCall.function.name == "terminal" {
            let args = toolCall.function.arguments
            if await approvalManager.needsApproval(command: args, sessionKey: sessionID) {
                switch await approvalManager.requestApproval(
                    command: args,
                    description: "Execute shell command",
                    sessionKey: sessionID
                ) {
                case .denied:
                    return "Error: Command blocked by security policy."
                case .requiresReview:
                    return "⚠️ Command requires manual approval. Run it yourself or disable the approval system."
                case .approved:
                    break
                }
            }
        }
        let result: String
        do {
            result = try await dispatchToolCall(toolCall)
        } catch {
            result = "Error executing tool '\(toolCall.function.name)': \(error.localizedDescription)"
        }
        await Metrics.shared.recordToolCall()
        return Self.redactSecrets(result)
    }

    // MARK: - Prompt Building

    /// Build the system prompt as three ordered cache tiers (Hermes parity):
    /// - **stable**: identity, rules, tool index, environment hints — never
    ///   changes within a session, so provider prefix caches stay warm;
    /// - **context**: workspace project context files (AGENTS.md etc.);
    /// - **volatile**: skills index first, then the frozen memory/user
    ///   snapshot, then the date-only session line — the only parts that
    ///   change when the prompt is rebuilt.
    /// Results are cached and only rebuilt when the cache version changes
    /// (compression events and profile injection).
    private func buildSystemPrompt() async throws -> String {
        if lastBuiltVersion == systemPromptVersion, let cached = cachedSystemPrompt {
            return cached
        }

        // ── Stable tier ──
        var stable = """
            You are ARC Agent, an intelligent AI assistant created by Nous Research.
            You are helpful, knowledgeable, and direct. You assist users with a wide
            range of tasks including answering questions, writing and editing code,
            analyzing information, creative work, and executing actions via your tools.

            You communicate clearly, admit uncertainty when appropriate, and prioritize
            being genuinely useful over being verbose.

            ## Available Tools

            You have access to the following tools. Use them when needed to accomplish
            the user's request.

            \(buildToolsIndex())

            ## Rules

            - Use your tools to take action — do not describe what you would do without
              actually doing it.
            - When you say you will perform an action, do it immediately.
            - Keep working until the task is actually complete.
            """

        // Environment hints (stable per machine).
        let osDescription: String
        #if os(macOS)
        osDescription = "macOS (\(ProcessInfo.processInfo.operatingSystemVersionString))"
        #else
        osDescription = "\(ProcessInfo.processInfo.operatingSystemName) \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        stable += """


            ## Environment

            - OS: \(osDescription)
            - Home directory: \(NSHomeDirectory())
            - Desktop: \(NSHomeDirectory())/Desktop
            - Working directory for tools (relative paths resolve here): \(FileManager.default.currentDirectoryPath)
            - Use ~/... paths (or absolute paths) for user-visible locations; the `terminal` tool's shell expands `~`, and `write_file` accepts paths relative to the working directory.
            """

        // ── Context tier ──
        var context = ""
        if config.injectProjectContext {
            let files = await loadContextFiles()
            if !files.isEmpty {
                context += "## Workspace & Project Context\n\n"
                for (name, content) in files {
                    context += "### \(name)\n\(content)\n\n"
                }
            }
        }

        // ── Volatile tier ──
        var volatile = ""
        if !config.skills.isEmpty {
            volatile += "## Skills (mandatory)\n\n\(Self.skillsMandatoryFraming)\n\n<available_skills>\n\(buildSkillsIndex(config.skills))\n</available_skills>\n\n"
        }
        if let memory = config.memoryProvider {
            let memoryContent = MemoryManager.scrub(try await memory.readMemory())
            if !memoryContent.isEmpty {
                volatile += "## Memory (Your Persistent Notes)\n\n\(MemoryManager.fence(memoryContent))\n\n"
            }
            let userContent = try await memory.readUser()
            if !userContent.isEmpty {
                volatile += "## User Profile\n\n\(MemoryManager.scrub(userContent))\n\n"
            }
        }
        volatile += Self.timestampLine(
            sessionID: sessionID,
            model: config.model,
            provider: config.provider,
            platform: config.platformHint
        )

        let prompt = stable + "\n\n" + context + "\n\n" + volatile
        cachedSystemPrompt = prompt
        lastBuiltVersion = systemPromptVersion
        return prompt
    }

    /// Discover and cache project context files (AGENTS.md, .hermes.md,
    /// CLAUDE.md, .cursorrules) from the working directory, floor-capped by
    /// the context window so they never crowd out the conversation.
    private func loadContextFiles() async -> [(name: String, content: String)] {
        if let cached = contextFilesCache { return cached }
        var result: [(name: String, content: String)] = []
        let fm = FileManager.default
        let base = config.contextDirectory ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        let names = ["AGENTS.md", ".hermes.md", "CLAUDE.md", ".cursorrules"]
        var budget = min(Self.contextFileBudgetChars, max(4_000, effectiveContextLimit() / 4))
        for name in names {
            let url = base.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let take = min(trimmed.count, budget)
            result.append((name, String(trimmed.prefix(take))))
            budget -= take
            if budget <= 0 { break }
        }
        contextFilesCache = result
        return result
    }

    /// Date-only session line. Minute precision is deliberately avoided so
    /// rebuilding the prompt (rare) does not bust the provider prefix cache.
    static func timestampLine(sessionID: String, model: String, provider: String, platform: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM dd, yyyy"
        return "Conversation started: \(formatter.string(from: Date())) | Session: \(sessionID.prefix(8)) | Model: \(model) | Provider: \(provider) | Platform: \(platform)"
    }

    /// Force a system-prompt rebuild on the next turn (used by compression so
    /// memory/skills are reloaded — Hermes `invalidate_system_prompt`).
    private func invalidateSystemPrompt() {
        cachedSystemPrompt = nil
        systemPromptVersion += 1
    }

    private func buildToolsIndex() -> String {
        let tools = config.registry.allTools
        return tools.map { tool in
            let emoji = tool.emoji ?? "🔧"
            return "\(emoji) `\(tool.name)` [\(tool.toolset)] — \(tool.description)"
        }.joined(separator: "\n")
    }
}
