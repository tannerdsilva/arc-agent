import Foundation
import AsyncHTTPClient
import Logging
import ServiceLifecycle
import SwiftSlash

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
        /// The tool registry (built-ins plus any runtime-discovered plugin
        /// tools; see ``MutableToolRegistry``).
        public var registry: any ToolRegistry
        /// The session store.
        public var sessionStore: SessionStore
        /// The memory provider for persistent memory injection.
        public var memoryProvider: MemoryProvider?
        /// Discovered skills for the skills index.
        public var skills: [Skill]
        /// Maximum iterations per conversation.
        public var maxIterations: Int
        /// Per-tool call cap override (nil = default 25; 0/negative =
        /// unlimited). Mirrors `guardrails.toolLoopCap` in `~/.arc/config.json`.
        public var toolLoopCap: Int?
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
        /// arc-parity auxiliary-model overrides (`auxiliary.<task>`), used
        /// for smart approval, LLM compression, and task routing.
        public var auxiliary: AuxiliaryModelSet

        /// Personality overlay text (`/personality <name>`), appended to the
        /// system prompt as a `## Personality` section. Empty = no overlay.
        public var personalityPrompt: String = ""

        /// reference micro-compaction (docs/micro-compaction.md): after each
        /// completed turn, absorb one exchange into a rolling summary. Off by
        /// default; enabled via `compression.micro_compact`.
        public var microCompact: MicroCompactConfig = MicroCompactConfig()

        /// Agent-powers lockdown gate (skills + profile files). All locks
        /// default to OFF; the running agent installs this into
        /// ``AgentPowers`` at init so tools refuse locked surfaces.
        public var agentPowers: AgentPowersConfig = AgentPowersConfig()

        /// Mixture-of-Agents configuration (reference `moa` config block).
        public var moa: MoAConfig
        /// Tool-gateway policy (reference `tool_gateway`), enforced at dispatch.
        public var gateway: ToolGatewayConfig = ToolGatewayConfig()
        /// Progressive tool disclosure (reference `tools.tool_search`): which
        /// tools are deferred behind tool_search/tool_describe/tool_call.
        public var toolSearch: ToolSearchConfig = ToolSearchConfig()

        /// Run inline `!`cmd`` blocks in skill content at load time (reference
        /// `skill_preprocessing.py`). Templates are always expanded; this
        /// gates the shell-execution half. Default ON (skills are trusted).
        public var skillInlineCommands: Bool = true

        /// Periodic background review of recent tool calls by an auxiliary
        /// model (reference `background_review`). Default off
        /// (`afterToolCalls: 0` = disabled).
        public var backgroundReview: BackgroundReview.Settings = BackgroundReview.Settings()

        /// Verify work at turn end (reference `verify_on_stop`): evidence nudge
        /// plus an aux verification pass appended to the response.
        public var verifyOnStop: Bool = false

        /// The session ID to restore persisted history from. `nil` starts a
        /// fresh session with a new UUID.
        public var sessionID: String?

        /// Reasoning effort sent to the provider (reference `reasoning_effort`).
        public var reasoningEffort: String?

        /// Sampling temperature (0.0 - 2.0) sent to the provider.
        public var temperature: Double?

        /// Nucleus sampling threshold (0.0 - 1.0) sent to the provider.
        public var topP: Double?

        /// Explicit generation budget (max_tokens); nil = metadata/registry.
        public var maxOutputTokens: Int?

        /// The model's context length in tokens (used to derive the
        /// compression threshold; arc parity: threshold = context / 2).
        /// `nil` falls back to ``maxContextTokens``.
        public var contextLength: Int?

        /// Additional API keys for the same endpoint, tried in order when a
        /// key returns 401 (CredentialPool rotation).
        public var fallbackAPIKeys: [String]

        /// Inject project context files (AGENTS.md, .arc.md, CLAUDE.md,
        /// .cursorrules) from the working directory into the system prompt.
        public var injectProjectContext: Bool

        /// Directory scanned for project context files. `nil` = current
        /// working directory (the default for the CLI).
        public var contextDirectory: URL?

        /// Platform label for the prompt's session line (arc parity).
        public var platformHint: String

        public init(
            model: String,
            provider: String = "openai",
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            apiKey: String,
            registry: any ToolRegistry,
            sessionStore: SessionStore = FileSessionStore(),
            memoryProvider: MemoryProvider? = FileMemoryProvider(),
            skills: [Skill] = [],
            maxIterations: Int = 25,
            toolLoopCap: Int? = nil,
            maxTurnDuration: Int = 120,
            persistSessions: Bool = true,
            approvalMode: ApprovalMode = .manual,
            query: String? = nil,
            maxContextTokens: Int = 64_000,
            auxiliary: AuxiliaryModelSet = AuxiliaryModelSet(),
            personalityPrompt: String = "",
            microCompact: MicroCompactConfig = MicroCompactConfig(),
            sessionID: String? = nil,
            contextLength: Int? = nil,
            fallbackAPIKeys: [String] = [],
            injectProjectContext: Bool = true,
            contextDirectory: URL? = nil,
            platformHint: String = "cli",
            moa: MoAConfig = MoAConfig(),
            toolSearch: ToolSearchConfig = ToolSearchConfig(),
            skillInlineCommands: Bool = true,
            backgroundReview: BackgroundReview.Settings = BackgroundReview.Settings(),
            verifyOnStop: Bool = false,
            reasoningEffort: String? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            maxOutputTokens: Int? = nil,
            agentPowers: AgentPowersConfig = AgentPowersConfig(),
            mcpServers: [String: MCPServerConfig] = [:],
            disabledToolsets: Set<String> = []
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
            self.toolLoopCap = toolLoopCap
            self.maxTurnDuration = maxTurnDuration
            self.persistSessions = persistSessions
            self.approvalMode = approvalMode
            self.query = query
            self.maxContextTokens = maxContextTokens
            self.auxiliary = auxiliary
            self.personalityPrompt = personalityPrompt
            self.microCompact = microCompact
            self.agentPowers = agentPowers
            self.sessionID = sessionID
            self.reasoningEffort = reasoningEffort
            self.temperature = temperature
            self.topP = topP
            self.maxOutputTokens = maxOutputTokens
            self.contextLength = contextLength
            self.fallbackAPIKeys = fallbackAPIKeys
            self.injectProjectContext = injectProjectContext
            self.contextDirectory = contextDirectory
            self.platformHint = platformHint
            self.moa = moa
            self.toolSearch = toolSearch
            self.skillInlineCommands = skillInlineCommands
            self.backgroundReview = backgroundReview
            self.verifyOnStop = verifyOnStop
            self.mcpServers = mcpServers
            self.disabledToolsets = disabledToolsets
        }

        /// External MCP servers (reference `mcp_servers`).
        public var mcpServers: [String: MCPServerConfig]

        /// Toolsets to disable for this agent run (reference `--toolsets`).
        public var disabledToolsets: Set<String>
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

    /// Local usage ledger (reference usage_pricing/credits parity).
    private let usageLedger = UsageLedger()
    /// Pluggable context engine (reference context_engine; ARC_CONTEXT_ENGINE).
    private let contextEngine: any ContextEngine = ContextEngineRouter.resolve()

    /// Per-turn recovery counters (reference conversation-loop parity).
    private var turnRecoveryState = TurnRecoveryState()
    /// Changed paths observed from terminal-tool evidence during the current
    /// turn (feeds the verify-on-stop nudge).
    private var turnChangedPaths: [String] = []
    /// Session-scoped todo list (reference `todo_tool.py`). One per agent
    /// instance — re-injected after context compression.
    private let todoStore = TodoStore()
    /// Streaming reasoning-tag scrubber (reference `think_scrubber.py`
    /// `StreamingThinkScrubber`). Re-entrant per stream — reset at the top
    /// of every new streamed turn so a hung block from an interrupted prior
    /// stream cannot taint the next turn's output.
    private var streamThinkScrubber = StreamingThinkScrubber()
    /// Tool calls issued in the current turn (background-review cadence).
    private var toolCallsThisTurn = 0
    /// Guidance from a background review, injected at the start of the next
    /// user turn (reference `background_review`: reviews inject only on issues).
    private var pendingBackgroundGuidance: String?
    /// Rate-limit buckets per route (reference rate_limit_tracker parity).
    private let rateLimitTracker = RateLimitTracker()
    /// Consecutive stale-stream giveups (reference staleness watchdog parity).
    private let staleTracker = StaleStreakTracker()
    /// Per-turn tool loop caps + repeat/synthetic results (reference
    /// tool_guardrails parity).
    private let toolGuardrails: ToolGuardrails
    /// Mixture-of-Agents service (reference moa_loop parity; built from config).
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
    /// Effective reasoning effort for this run (reference `reasoning_effort`).
    private var currentReasoningEffort: String?
    /// Cached token estimate for the tool schemas (static per agent).
    private var toolSchemaTokenEstimate: Int?
    /// Cached project context files (static per agent/working directory).
    private var contextFilesCache: [(name: String, content: String)]?
    /// Compression cool-down: summary-LLM rate limit parks us until this date.
    private var compressionCooldownUntil: Date?
    /// Anti-thrash: after two consecutive low-savings compressions, suspend
    /// compression for the remainder of the turn.
    private var compressionThrottled = false

    /// Micro-compaction session state (cursor, rolling summary, failure
    /// tracking). Lives across turns; the transcript is the source of truth
    /// for cursor recovery after a restart.
    private var microState = MicroCompactState()
    private var lastTwoCompressionSavings: [Int] = []
    /// Mid-turn steering messages, drained before the next LLM request.
    private var pendingSteers: [String] = []
    /// Cooperative interrupt flag, honored at iteration boundaries.
    private var turnInterrupted = false

    // MARK: - Init

    public init(config: Configuration) {
        // Install the lockdown gate so every tool consults the same live
        // config (skills, profile files). AgentPowers is a process-global
        // gate, so only apply a *non-default* powers config here — an agent
        // constructed with default (all-unlocked) powers must not clobber a
        // lockdown active in another session.
        if config.agentPowers != AgentPowersConfig() {
            AgentPowers.configure(config.agentPowers)
        }
        self.config = config
        self.messageHistory = []
        self.sessionID = config.sessionID ?? UUID().uuidString
        // The smart-approval classifier is wired from `wireSmartApproval()`
        // (once the agent's own state is fully initialized).
        self.approvalManager = ApprovalManager(mode: config.approvalMode)
        self.toolGuardrails = ToolGuardrails(limits: .init(loopCap: config.toolLoopCap))
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

    /// Register the human-approval presenter for this agent's turns.
    ///
    /// The presenter is consulted for dangerous commands in
    /// ``ApprovalMode/manual`` and suspicious-or-worse commands in
    /// ``ApprovalMode/smart``. It belongs to the renderer: the web UI wires a
    /// permission card, a TUI wires a prompt. Without one the historic
    /// headless behaviour stands — the tool result reports that manual
    /// approval is required. The agent is per-session, so the presenter can
    /// route its request to the right surface.
    public func setApprovalPresenter(_ presenter: ApprovalPresenter?) async {
        await approvalManager.setPresenter(presenter)
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

    /// End-of-turn verification (reference `verify_on_stop`): an aux pass that
    /// checks whether the work is actually complete/consistent. Fail-open.
    public func runVerificationCheck(lastResponse: String) async -> String? {
        guard let router = auxRouter, let hc = httpClient,
              let client = router.makeClient(task: .verification, httpClient: hc) else {
            return nil
        }
        do {
            // Changed-file evidence (reference filter_non_code_change_paths +
            // verify_on_stop nudge) frames the aux verification pass.
            let nudge = Verification.verifyNudge(changedPaths: turnChangedPaths)
            let prompt = (nudge.isEmpty ? "" : nudge + "\n\n") + """
            The assistant just finished responding to the user. Independently verify \
            the work: is anything claimed but missing, broken, or unverified? \
            If all is well reply "verified". If something needs attention, say \
            exactly what (max 3 sentences).\n\nResponse:\n\(lastResponse)
            """
            let resp = try await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil,
                reasoningEffort: nil
            )
            let content = (resp.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.lowercased() != "verified" else { return nil }
            return "⚠️ Verify-on-stop: \(content)"
        } catch {
            return nil
        }
    }

    /// Run the standing-goal judge (reference `goal_judge` auxiliary task).
    /// Fail-open: returns nil on any error (caller treats as `continue`).
    public func runGoalJudge(goal: GoalState, lastResponse: String) async -> GoalJudgeResult? {
        guard let router = auxRouter, let hc = httpClient,
              let client = router.makeClient(task: .goalJudge, httpClient: hc) else {
            return nil
        }
        do {
            let resp = try await client.complete(
                messages: [Message(role: .user, content: GoalLoop.judgePrompt(goal: goal, finalResponse: lastResponse))],
                tools: nil,
                reasoningEffort: nil
            )
            return GoalJudgeResult.parse(resp.content ?? "")
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
            httpClient: httpClient,
            defaultParameters: RequestParameters(
                temperature: config.temperature,
                maxTokens: config.maxOutputTokens,
                topP: config.topP
            )
        )
        // The memory tool writes through the agent's configured provider so
        // the model reads and writes use the same backend as this agent.
        MemoryTool.provider = config.memoryProvider
        // The session-search tool reads through the agent's session store.
        SessionSearchTool.store = config.sessionStore
        // The todo tool is session-scoped: one list per agent instance.
        TodoTool.store = todoStore
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

        /// One-time setup: HTTP client, auth pool, provider client, and tool
    /// wiring. Idempotent — safe to call from `run()` and `streamConversation`.
    public func prime() async throws {
        if httpClient != nil { return }
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        self.httpClient = httpClient
        makeAuxRouter()
        await wireSmartApproval()

        // Wire the credential pool (multi-key rotation on 401)
        let pool = CredentialPool(credentials: [config.apiKey] + config.fallbackAPIKeys)
        self.credentialPool = pool
        self.currentAPIKey = config.apiKey
        self.currentModelName = config.model
        self.currentReasoningEffort = config.reasoningEffort
        let resolvedKey = await pool.acquireLease() ?? config.apiKey

        let client = OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: resolvedKey,
            model: config.model,
            httpClient: httpClient,
            // arc parity: always declare a generation budget. Without an
            // explicit max_tokens some OpenAI-compatible servers silently
            // cap output at their default (often 4096), truncating long
            // answers with finish_reason == "length" and no error.
            defaultParameters: RequestParameters(
                maxTokens: config.maxOutputTokens
                    ?? ModelMetadataRegistry.shared.metadata(
                        for: config.model,
                        provider: config.provider
                    ).maxOutputTokens
                    ?? 32_768
            )
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
        // Session-scoped todo list (one per agent instance).
        TodoTool.store = todoStore
    }

    /// Tear the HTTP client down (streaming callers own their client).
    public func shutdownHTTPClient() async {
        try? await httpClient?.shutdown()
        httpClient = nil
    }

    public func run() async throws {
        await MCPClientManager.shared.configure(config.mcpServers)
        try await prime()

        if let q = config.query {
            let response = try await runConversation(message: q)
            print(response)
        } else {
            try await runInteractive()
        }

        try? await httpClient?.shutdown()
    }

    // MARK: - Interactive REPL

    /// Readline handle for async stdin access.
    private let stdinHandle = FileHandle.standardInput

    /// Run the interactive readline REPL with slash commands.
    private func runInteractive() async throws {
        print("⚡ ARC Agent — interactive mode")
        print("   Type your message, or /quit to exit.")
        print("   Commands: /model, /retry, /help, /compress, /skills, /memory, /session, /tokens, /status, /clear, /tools, /profiles, /quit")
        print("   Prefix with ! to run a shell command directly.\n")
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

            // reference `!` shell mode: run the rest as a shell command and show
            // its output without involving the model.
            if input.hasPrefix("!") {
                await runShellPassthrough(String(input.dropFirst()).trimmingCharacters(in: .whitespaces))
                print("> ", terminator: "")
                continue
            }

            let response = try await runConversation(message: input)
            print(response)
            print("")
            print("> ", terminator: "")
        }
    }

    /// Execute a shell command via the sanctioned subprocess runner (reference
    /// bang-shell mode: no model round-trip, output shown verbatim).
    private func runShellPassthrough(_ command: String) async {
        guard !command.isEmpty else {
            print("(empty command)")
            return
        }
        do {
            let shell = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", command])
            let outcome = try await SubprocessRunner.runBytes(shell, timeout: 60)
            if !outcome.stdout.isEmpty {
                print(String(decoding: outcome.stdout, as: UTF8.self), terminator: "")
            }
            if !outcome.stderr.isEmpty {
                print(String(decoding: outcome.stderr, as: UTF8.self), terminator: "")
            }
            if outcome.exitCode != 0 {
                print("[exit \(outcome.exitCode ?? -1)]")
            }
        } catch {
            print("shell error: \(error)")
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
              /help            — Show this help
              /model <name>    — Switch model (e.g. /model gpt-4o)
              /retry           — Retry the last message
              /compress [focus]— Compress conversation history
              /skills          — List loaded skills
              /memory          — Show the memory block
              /session         — Show the current session ID
              /tokens          — Show estimated token usage
              /status          — Show agent status
              /clear           — Clear conversation history
              /tools           — List available tools
              /profiles        — List agent profiles
              /quit            — Exit
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
            // reference `/compress [focus]`: run the compression engine with an
            // optional focus topic (prioritised detail) and force=True so a
            // manual request bypasses throttling and the summary cooldown.
            let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
            let focus = parts.count > 1 ? parts[1] : nil
            await autoCompressIfNeeded(focus: focus, force: true)
            print("Compressed: history now \(messageHistory.count) messages.")
            print("")
            return true

        case "/skills":
            if config.skills.isEmpty {
                print("No skills loaded.")
            } else {
                print("Loaded skills:")
                for skill in config.skills {
                    print("  \(skill.name) — \(skill.description.prefix(90))")
                }
            }
            print("")
            return true

        case "/memory":
            do {
                let content = try await config.memoryProvider?.readMemory() ?? ""
                print(content.isEmpty ? "(memory empty)" : content)
            } catch {
                print("memory error: \(error)")
            }
            print("")
            return true

        case "/session":
            print(config.sessionID ?? "(no session ID — a new one is created per run)")
            print("")
            return true

        case "/tokens":
            let historyTokens = tokenCounter.count(
                messageHistory.compactMap(\.content).joined(separator: "\n"),
                model: currentModelName
            )
            let schemas = toolSchemaTokens()
            let systemTokens: Int
            do {
                systemTokens = tokenCounter.count(try await buildSystemPrompt(), model: currentModelName)
            } catch {
                systemTokens = 0
            }
            print("Context estimate: system \(systemTokens) + schemas \(schemas) + history \(historyTokens) tokens")
            print("")
            return true

        case "/status":
            print("Model: \(currentModelName) (\(config.provider))")
            print("Session: \(config.sessionID ?? "(new)")")
            print("Messages: \(messageHistory.count) (persisted: \(persistedMessageCount))")
            print("Skills: \(config.skills.count) loaded")
            print("Toolsets disabled: \(config.disabledToolsets.sorted().isEmpty ? "(none)" : config.disabledToolsets.sorted().joined(separator: ", "))")
            print("")
            return true

        case "/clear":
            messageHistory.removeAll()
            print("Conversation history cleared.")
            print("")
            return true

        case "/tools":
            print(buildToolsIndex())
            print("")
            return true

        case "/profiles":
            do {
                let manager = ProfileManager()
                let profiles = try await manager.list()
                if profiles.isEmpty {
                    print("No profiles.")
                } else {
                    print("Profiles:")
                    for p in profiles {
                        print("  \(p.name) — \(p.model ?? "(default model)") [\(p.provider ?? "(default provider)")]")
                    }
                }
            } catch {
                print("profile error: \(error)")
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
        turnChangedPaths = []
        toolCallsThisTurn = 0
    }

    private func appendUserMessage(_ message: Message) {
        messageHistory.append(message)
    }

    /// Inject a mid-turn steering instruction. Drained before the next LLM
    /// request so the model sees it on this iteration (reference `/steer`
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
    /// auxiliary model (arc parity). No-op when no override is configured
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
        try await withSkillContext {
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
            let composed = await self.composeUserContent(self.effectiveUserText(message))
            messageHistory.append(Message(role: .user, content: composed))

            let response = try await runTurnLoop(client: llmClient)

            await persistConversationIfNeeded()

            // arc parity (docs/micro-compaction.md): after each completed turn,
            // absorb the oldest un-absorbed exchange into the rolling summary.
            // Best-effort — a failure leaves the transcript unchanged and the
            // turn standing; the user's messages are never touched.
            await maybeMicroCompact()

            // arc parity: background title generation via the auxiliary router.
            Task { await self.maybeGenerateTitle() }

            // Verify-on-stop (reference `verify_on_stop`): evidence nudge first,
            // then the aux verification pass; both appended when enabled.
            if config.verifyOnStop,
               let verification = await runVerificationCheck(lastResponse: response) {
                return response + "\n\n" + verification
            }

            return response
        }
    }

    /// Prepend pending background-review guidance to the next user turn
    /// (consumed once; reviews inject only when they found an issue).
    private func effectiveUserText(_ message: String) -> String {
        guard let guidance = pendingBackgroundGuidance else { return message }
        pendingBackgroundGuidance = nil
        return guidance + "\n\n" + message
    }

    /// Run `body` with the skill-context TaskLocals anchored to this agent's
    /// session (reference skill_preprocessing needs the session for `${ARC_SESSION_ID}`).
    private nonisolated func withSkillContext<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await SkillContext.$sessionID.withValue(config.sessionID ?? "") {
            try await SkillContext.$allowInlineCommands.withValue(config.skillInlineCommands) {
                try await body()
            }
        }
    }

    /// Compose the API-bound user content for a turn: the clean message plus
    /// optional memory-provider recall (reference `turn_context` external-memory
    /// prefetch). Trivial prompts are skipped; recall is wrapped in the
    /// fenced `<memory-context>` block with the system note. Best-effort —
    /// a missing/stuck provider never blocks the turn.
    private func composeUserContent(_ message: String) async -> String {
        guard !MemoryRecall.isTrivialPrompt(message) else { return message }
        guard let provider = config.memoryProvider else { return message }
        let raw = await MemoryRecall.prefetchWithTimeout {
            try await provider.prefetch(query: message)
        }
        guard let block = MemoryManager.recallBlock(raw) else { return message }
        return message + "\n\n" + block
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
    /// known (arc parity), otherwise the configured ``maxContextTokens``.
    nonisolated func effectiveContextLimit() -> Int {
        if let ctx = config.contextLength, ctx > 0 {
            return ctx / 2
        }
        return config.maxContextTokens
    }

    /// Token estimate for the tool schemas, cached (schema set is static).
    private func toolSchemaTokens() -> Int {
        if let cached = toolSchemaTokenEstimate { return cached }
        let schemas = ProgressiveToolDisclosure.buildPromptSchemas(
            registry: config.registry,
            disabled: config.disabledToolsets,
            config: config.toolSearch,
            contextLength: config.maxContextTokens
        )
        guard let data = try? JSONSerialization.data(withJSONObject: schemas),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        let estimate = tokenCounter.count(text, model: config.model)
        toolSchemaTokenEstimate = estimate
        return estimate
    }

    /// Auto-compress history if the FULL estimated request (system prompt +
    /// history + tool schemas) exceeds the effective context limit.
    ///
    /// arc-parity guards: head protection (first exchange is never
    /// summarized), token-budget tail (~20K), iterative summary updates,
    /// summary-model cool-down after rate limits, and anti-thrash that
    /// suspends compression after two consecutive low-savings rounds.
    private func autoCompressIfNeeded(focus: String? = nil, force: Bool = false) async {
        if !force { guard !compressionThrottled else { return } }
        let limit = effectiveContextLimit()
        let estimated = await estimateRequestTokens()
        guard force || estimated > limit else { return }

        // Pluggable context engines (reference context_engine): the
        // prune-tool-results variant trims tool output only; everything else
        // uses the default summarize-and-window engine below.
        if contextEngine.name == "prune_tool_results" {
            messageHistory = contextEngine.pruneToolResultsOnly(
                messages: messageHistory,
                maxBytes: 32_000
            )
            return
        }

        let systemMessages = messageHistory.filter { $0.role == .system }
        let nonSystem = messageHistory.filter { $0.role != .system }

        // Head protection: never summarize the first exchange. Tail
        // protection: token budget (~20K, at least the last 4 messages) —
        // reference compress() steps 2-4, extracted for testability.
        let tailBudget = min(20_000, limit / 3)
        let window = ContextCompression.window(
            nonSystem,
            tailBudget: tailBudget,
            countTokens: { [config] text in tokenCounter.count(text, model: config.model) }
        )
        var head = window.head
        var middle = window.middle
        let tail = window.tail

        // Cheap pre-pass (reference Phase 1): prune old tool results before any
        // summary decision, so an aborted compression still returns the win.
        middle = ContextCompression.pruneToolResults(middle)

        guard !middle.isEmpty else {
            // Even the protected window alone exceeds the budget.
            messageHistory = systemMessages + Array(nonSystem.suffix(min(8, nonSystem.count)))
            messageHistory = ContextCompression.orphanCleanup(messageHistory)
            return
        }

        let beforeTokens = tokenCounter.count(messages: messageHistory, model: config.model)

        // Iterative: fold the existing summary into the material so a
        // re-compression updates the summary instead of starting over
        // (reference: previous summary + new turns, bounded).
        var existingSummary: String?
        for msg in systemMessages where (msg.content ?? "").hasPrefix(Self.compressionSummaryPrefix) {
            existingSummary = msg.content
            break
        }
        let memoryContext = (try? await config.memoryProvider?.readMemory()) ?? ""

        let prompt: ContextCompression.SummaryPrompt?
        if let existing = existingSummary {
            let body = String(existing.dropFirst(Self.compressionSummaryPrefix.count))
            prompt = ContextCompression.updateSummaryPrompt(
                previousSummary: body,
                newTurns: middle,
                focus: focus,
                memoryContext: memoryContext
            )
        } else {
            prompt = ContextCompression.firstSummaryPrompt(
                material: middle,
                focus: focus,
                memoryContext: memoryContext
            )
        }

        let summaryText: String
        if let prompt, let summarized = await summarizeForCompression(prompt.userContent) {
            summaryText = summarized
        } else {
            summaryText = ContextCompression.compressedRecord(middle)
            logger.warning("compression: aux summary unavailable; using extractive record")
        }

        let newSystem = systemMessages.filter { !($0.content ?? "").hasPrefix(Self.compressionSummaryPrefix) }
        let summaryMessage = Message(
            role: .system,
            content: "\(Self.compressionSummaryPrefix)\n\n\(summaryText)"
        )
        messageHistory = ContextCompression.orphanCleanup(
            newSystem + [summaryMessage] + head + tail
        )

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

        // Rebuild the system prompt with fresh memory/skills (arc parity).
        invalidateSystemPrompt()
    }

    /// Attempt an LLM summarization using the `compression` auxiliary model
    /// with the given reference-structured prompt. Returns nil when no override
    /// is configured, when the summary model is in cool-down, or when the
    /// call fails — callers fall back to the extractive record.
    private func summarizeForCompression(_ userContent: String) async -> String? {
        // Cool-down after the summary model was rate-limited (arc parity).
        if let until = compressionCooldownUntil, Date() < until { return nil }
        guard let router = auxRouter, router.hasOverride(.compression) else { return nil }
        guard let hc = httpClient,
              let client = router.makeClient(task: .compression, httpClient: hc) else { return nil }
        do {
            let resp = try await client.complete(
                messages: [Message(role: .user, content: userContent)],
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

    // MARK: - Micro-compaction (reference docs/micro-compaction.md)

    /// Run one micro-compaction pass after a completed turn. Best-effort by
    /// contract: every failure path keeps the conversation unchanged and the
    /// turn stands. Off unless `compression.micro_compact` is enabled.
    private func maybeMicroCompact() async {
        guard config.microCompact.enabled else { return }
        guard let hc = httpClient,
              let router = auxRouter,
              router.hasOverride(.compression),
              let client = router.makeClient(task: .compression, httpClient: hc) else {
            // No compression aux model: passes cannot run (batch-only, reference
            // parity — micro-compaction uses `auxiliary.compression`).
            return
        }
        var state = microState
        let limit = effectiveContextLimit()
        let run = await MicroCompactor.run(
            messages: messageHistory,
            state: &state,
            config: config.microCompact,
            limit: limit,
            countTokens: { [config] text in tokenCounter.count(text, model: config.model) },
            summarize: { existing, exchange in
                let prompt = await self.microSummaryPrompt(existing: existing, exchange: exchange)
                return await self.microAuxComplete(client: client, prompt: prompt)
            },
            defragSummarize: { baggy in
                let prompt = await self.microSummaryPrompt(existing: "", exchange: baggy)
                return await self.microAuxComplete(client: client, prompt: prompt)
            }
        )
        microState = state

        if run.outcome == .absorbed || run.outcome == .defrag {
            if run.messages != messageHistory {
                messageHistory = run.messages
                invalidateSystemPrompt()
                await persistCompactIfNeeded(run.messages)
            }
        }
        emitMicroTelemetry(run, limit: limit)
    }

    /// reference `_build_micro_summary_prompt`: merge one exchange into the
    /// running summary. The same builder serves defrag (empty base + the
    /// baggy summary as the "exchange").
    private func microSummaryPrompt(existing: String, exchange: String) -> [Message] {
        let summaryBlock = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(No previous summary yet.)" : existing
        let user = "You are a summarization agent creating a compact record of an ongoing conversation.  "
            + "You are given a running summary and the next exchange from the conversation.  "
            + "Merge the exchange's key decisions, requirements, file paths, and open questions into the "
            + "summary.  Preserve the summary's structure.  Drop resolved details that are no longer "
            + "relevant.  Add new decisions, file paths, and open questions.\n\n"
            + "NEVER include API keys, tokens, passwords, secrets, credentials, or connection strings "
            + "in the summary — replace any that appear with [REDACTED].\n\n"
            + "## Current Running Summary\n" + summaryBlock + "\n\n"
            + "## Next Exchange to Merge\n" + exchange + "\n\n"
            + "Return ONLY the updated summary text, no preamble or explanation.  "
            + "Do not include this instruction block in your output."
        return [
            Message(role: .system, content: "You are a conversation summarization assistant."),
            Message(role: .user, content: user)
        ]
    }

    /// One aux call to the `auxiliary.compression` model (mirrors
    /// ``summarizeForCompression``'s call shape).
    private func microAuxComplete(client: any LLMClient, prompt: [Message]) async -> String? {
        do {
            let resp = try await client.complete(messages: prompt, tools: nil, reasoningEffort: nil)
            let text = (resp.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            logger.warning("micro-compaction aux model failed: \(error)")
            return nil
        }
    }

    /// Rewrite the persisted session after a splice/defrag so a resume does
    /// not double-load the summary AND the exchanges it replaced (reference
    /// `archive_and_compact` equivalent). Mirror of the append-only flush:
    /// soft failure only — the transcript stays consistent in memory and the
    /// next batch compaction cleans up the double-load on resume.
    private func persistCompactIfNeeded(_ messages: [Message]) async {
        guard config.persistSessions, sessionCreatedInStore else { return }
        do {
            try await config.sessionStore.update(Session(
                id: sessionID,
                createdAt: Date(),
                updatedAt: Date(),
                model: config.model,
                provider: config.provider,
                messages: messages
            ))
            persistedMessageCount = messages.count
            logger.info("micro-compaction: session store rewritten (\(messages.count) messages)")
        } catch {
            logger.warning("micro-compaction: session store update failed: \(error)")
        }
    }

    /// One content-free telemetry JSON line, same shape as the batch path
    /// (docs: occupancy_pct is the headroom figure; tokens_delta negative when
    /// the pass shrank the transcript).
    private func emitMicroTelemetry(_ run: MicroCompactRun, limit: Int) {
        let delta = run.tokensAfter - run.tokensBefore
        var occupancy: Double? = nil
        if limit > 0, run.tokensAfter > 0 {
            occupancy = Double(run.tokensAfter) / Double(limit) * 100
        }
        let payload: [String: Any] = [
            "event": "micro_compaction",
            "session_id": sessionID,
            "outcome": run.outcome.rawValue,
            "tokens_before": run.tokensBefore,
            "tokens_after": run.tokensAfter,
            "tokens_delta": delta,
            "exchange_tokens": run.exchangeTokens ?? -1,
            "rolling_summary_tokens": tokenCounter.count(microState.rollingSummary, model: config.model),
            "cursor": microState.cursor,
            "passes_total": microState.passes,
            "tokens_saved_total": microState.tokensSavedTotal,
            "duration_ms": run.durationMs ?? -1,
            "threshold_tokens": limit,
            "context_limit": config.contextLength ?? config.maxContextTokens,
            "occupancy_pct": occupancy ?? -1,
            "main_model": config.model,
            "aux_model": config.auxiliary.override(for: .compression)?.model ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            logger.info("micro compaction telemetry: \(json)")
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
        await toolGuardrails.resetTurn()
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

        let maxIters = config.maxIterations > 0 ? config.maxIterations : Int.max
        for iteration in 0..<maxIters {
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

            // 3. Build tool schemas (progressive disclosure: deferred tools
            // appear as tool_search/tool_describe/tool_call + manifest).
            let toolSchemas = ProgressiveToolDisclosure.buildPromptSchemas(
                registry: config.registry,
                disabled: config.disabledToolsets,
                config: config.toolSearch,
                contextLength: config.maxContextTokens
            )

            // 3b. Mixture-of-Agents advisory context (reference moa_loop: the
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
                    timeout: config.maxTurnDuration,
                    reasoningEffort: currentReasoningEffort
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

            // 4b. Non-streaming parity: the streaming loop scrubs reasoning
            // tags per-delta (StreamingThinkScrubber); on this path the whole
            // response arrives at once, so run the batch scrubber
            // (ThinkScrubber.scrub) on the content before it is persisted or
            // classified. Tool calls are unaffected (schema keeps its
            // arguments intact; only visible text is scrubbed).
            let response2: LLMResponse
            if let rawContent = response.content, !rawContent.isEmpty {
                let scrubbed = ThinkScrubber.scrub(rawContent)
                if scrubbed != rawContent {
                    response2 = LLMResponse(
                        content: scrubbed.isEmpty ? nil : scrubbed,
                        toolCalls: response.toolCalls,
                        finishReason: response.finishReason,
                        usage: response.usage
                    )
                } else {
                    response2 = response
                }
            } else {
                response2 = response
            }
            // 5. Truncation recovery — "length"/"max_tokens" means the answer
            // was cut off. Keep the partial, nudge a bounded continuation,
            // and loop instead of returning a half answer.
            let finishReason = response2.finishReason ?? ""
            if (finishReason == "length" || finishReason == "max_tokens"),
               (response2.toolCalls ?? []).isEmpty,
               let partial = response2.content, !partial.isEmpty,
               truncationContinuations < Self.maxTruncationContinuations {
                messageHistory.append(Message(role: .assistant, content: partial))
                messageHistory.append(Message(role: .system, content: Self.truncationNudge))
                truncationContinuations += 1
                continue
            }

            // 6. Parse response — tool calls take precedence over content.
            switch Self.classifyTurn(content: response2.content, toolCalls: response2.toolCalls) {
            case .text(let content):
                messageHistory.append(Message(role: .assistant, content: content))
                turnRecoveryState.markProviderSuccess()
                return content

            case .toolCalls(let toolCalls):
                messageHistory.append(Message(
                    role: .assistant,
                    content: response2.content,
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
                // Empty-response storm guard (reference bounded empty responses):
                // after N consecutive empty replies, stop re-prompting.
                turnRecoveryState.emptyStormStreak += 1
                if turnRecoveryState.emptyStormStreak >= TurnRecoveryState.emptyStormThreshold {
                    return RecoveryNudges.emptyStormExhaustedMessage
                }
                // Reasoning models can emit a whitespace-only prefix — loop.
                continue
            }

            if iteration == maxIters - 1 {
                return "I encountered an issue processing your request. Please try again."
            }
        }

        return "The conversation reached the maximum iteration limit. Please start a new session."
    }

    // MARK: - Streaming Turn Loop

    /// Run the agent loop and stream structured ``AgentTurnEvent`` values.
    ///
    /// This is the primary streaming surface: text deltas, reasoning deltas,
    /// tool-call lifecycle, usage, and the terminal completion or error
    /// notice. Text-only consumers (CLI, gateway, TUI) use
    /// ``streamConversation(message:)`` — a projection over this same
    /// execution, so both surfaces observe identical turns.
    nonisolated public func streamTurn(message: String) -> AsyncThrowingStream<AgentTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await withSkillContext {
                        try await prime()
                        await restoreSessionIfNeeded()
                        await resetTurnState()
                        await self.appendUserMessage(Message(role: .user, content: self.effectiveUserText(message)))
                        try await runStreamingTurnLoop(emit: { event in continuation.yield(event) })
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Run the agent loop with streaming responses, yielding plain text.
    ///
    /// A projection of ``streamTurn(message:)``: forwards ``AgentTurnEvent/textDelta(_:)``
    /// and ``AgentTurnEvent/failed(_:)`` verbatim, and synthesises the historic
    /// `[Tool: name] result` lines from ``AgentTurnEvent/toolCallFinished(id:name:result:)``.
    /// Byte-compatible with the pre-event implementation for CLI and gateway
    /// consumers.
    nonisolated public func streamConversation(message: String) -> AsyncThrowingStream<String, Error> {
        let events = streamTurn(message: message)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in events {
                        switch event {
                        case .textDelta(let text), .failed(let text):
                            continuation.yield(text)
                        case .toolCallFinished(_, let name, let result):
                            continuation.yield("[Tool: \(name)] \(result)\n")
                        case .reasoningDelta, .toolCallStarted, .usage, .completed:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// The core streaming turn loop.
    private func runStreamingTurnLoop(
        emit: @Sendable (AgentTurnEvent) -> Void
    ) async throws {
        await toolGuardrails.resetTurn()
        guard let hc = self.httpClient else {
            emit(.failed("Error: Agent HTTP client not initialized."))
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

        let maxIters = config.maxIterations > 0 ? config.maxIterations : Int.max
        for iteration in 0..<maxIters {
            if turnInterrupted {
                turnInterrupted = false
                emit(.textDelta("Interrupted by user."))
                emit(.completed(finalText: "Interrupted by user."))
                return
            }
            drainSteers()
            await autoCompressIfNeeded()
            var streamFinishReason: String? = nil

            let systemPrompt = try await buildSystemPrompt()
            var messages: [Message] = [Message(role: .system, content: systemPrompt)]
            messages.append(contentsOf: Self.sanitizeMessages(messageHistory))

            let toolSchemas = ProgressiveToolDisclosure.buildPromptSchemas(
                registry: config.registry,
                disabled: config.disabledToolsets,
                config: config.toolSearch,
                contextLength: config.maxContextTokens
            )

            // MoA advisory context (reference moa_loop parity).
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
            var streamUsage: Usage?
            var accumulatedToolCalls: [ToolCall] = []
            // Fresh stream → fresh scrubber state (a hung thinking block from
            // an interrupted prior stream must not taint this turn's output).
            streamThinkScrubber.reset()

            do {
                let stream = try await callStreamWithRetry(
                    client: currentClient,
                    makeClient: { self.freshClient() ?? currentClient },
                    messages: messages,
                    tools: toolSchemas,
                    timeout: config.maxTurnDuration,
                    reasoningEffort: currentReasoningEffort
                )

                for try await delta in stream {
                    if let usage = delta.usage {
                        streamUsage = usage
                        emit(.usage(usage))
                    }
                    if let reasoning = delta.reasoning, !reasoning.isEmpty {
                        emit(.reasoningDelta(reasoning))
                    }
                    if let content = delta.content {
                        // Strip streamed reasoning blocks with a stateful
                        // scrubber (reference `StreamingThinkScrubber`): a
                        // batch per-delta regex erases the open tag and
                        // leaks the reasoning that follows. Partial tags at
                        // delta boundaries are held back until resolved;
                        // flushed by `finishReason`/end-of-stream.
                        let visible = streamThinkScrubber.feed(content)
                        accumulatedContent += visible
                        if !visible.isEmpty {
                            emit(.textDelta(visible))
                        }
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
                // End of stream: flush any held-back partial-tag prose that
                // turned out not to be a real tag (reference flush()). If
                // still inside an unterminated block, flush() discards it.
                let tail = streamThinkScrubber.flush()
                if !tail.isEmpty {
                    accumulatedContent += tail
                    emit(.textDelta(tail))
                }
            } catch {
                let errorClass = classifyError(error)

                // Stale-stream recovery (reference staleness watchdog with
                // patience budget + give-up streak): reconnect once per turn,
                // then give up after the streak threshold.
                if error is StaleStreamError {
                    _ = await staleTracker.recordStale()
                    if await staleTracker.shouldGiveUp {
                        let text = "The model stream stalled repeatedly. Please try again."
                        emit(.textDelta(text))
                        emit(.completed(finalText: text))
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
                emit(.failed("Error: \(error.localizedDescription)"))
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
                if let streamUsage { await recordUsage(streamUsage) }
                emit(.completed(finalText: content))
                return

            case .toolCalls(let toolCalls):
                messageHistory.append(Message(
                    role: .assistant,
                    content: accumulatedContent.isEmpty ? nil : accumulatedContent,
                    toolCalls: toolCalls
                ))

                let outcomes = await executeToolCalls(toolCalls, emit: emit)
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
                if let streamUsage { await recordUsage(streamUsage) }
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
                // the empty-response storm guard (reference).
                turnRecoveryState.emptyStormStreak += 1
                if turnRecoveryState.emptyStormStreak >= TurnRecoveryState.emptyStormThreshold {
                    emit(.textDelta(RecoveryNudges.emptyStormExhaustedMessage))
                    emit(.completed(finalText: RecoveryNudges.emptyStormExhaustedMessage))
                    return
                }
                continue
            }

            if iteration == maxIters - 1 {
                let text = "I encountered an issue processing your request. Please try again."
                emit(.textDelta(text))
                emit(.completed(finalText: accumulatedContent.isEmpty ? text : accumulatedContent + "\n" + text))
                return
            }
        }

        let limitText = "The conversation reached the maximum iteration limit. Please start a new session."
        emit(.textDelta(limitText))
        emit(.completed(finalText: limitText))
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
        timeout: Int = 120,
        reasoningEffort: String? = nil
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
                            tools: deserialized,
                            reasoningEffort: reasoningEffort
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
                await recordUsage(result.usage)
                return result
            } catch {
                lastError = error
                let errorClass = classifyError(error)
                await Metrics.shared.recordError("\(errorClass)")
                let failure = ErrorClassifier.classify(error)

                // Rate-limit backoff honoring Retry-After (reference).
                if case LLMError.rateLimited(let retryAfter) = error {
                    await rateLimitTracker.recordThrottle(route: rateLimitRoute(), retryAfter: retryAfter)
                    let delay = FailureBackoff.delay(for: .rateLimit, attempt: attempt, retryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Empty-response storm guard (reference `_check_empty_storm`):
                // empty 200s retry, but a streak means the provider is stuck —
                // stop with a visible reason instead of looping.
                if case LLMError.emptyResponse = error {
                    turnRecoveryState.emptyStormStreak += 1
                    logger.warning("empty response \(turnRecoveryState.emptyStormStreak)/\(TurnRecoveryState.emptyStormThreshold) from provider")
                    if turnRecoveryState.emptyStormStreak > TurnRecoveryState.emptyStormThreshold {
                        throw error
                    }
                }

                // Primary transport recovery: rebuild the connection once per
                // turn on transport-level failures (reference
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
        timeout: Int = 120,
        reasoningEffort: String? = nil
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

        // Staleness patience for this request (reference stream stale watchdog).
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
                    tools: toolsArg,
                    reasoningEffort: reasoningEffort
                )

                await circuitBreaker.reset()
                await rateLimitTracker.recordSuccess(route: rateLimitRoute())
                turnRecoveryState.markProviderSuccess()
                // Apply the per-provider stale watchdog (reference
                // stream-stale patience budget).
                return IdleTimeoutStream(stream, idleSeconds: patience)
            } catch {
                lastError = error
                let errorClass = classifyError(error)
                let failure = ErrorClassifier.classify(error)

                // Rate-limit backoff honoring Retry-After (reference).
                if case LLMError.rateLimited(let retryAfter) = error {
                    await rateLimitTracker.recordThrottle(route: rateLimitRoute(), retryAfter: retryAfter)
                    let delay = FailureBackoff.delay(for: .rateLimit, attempt: attempt, retryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Empty-response storm guard (reference `_check_empty_storm`).
                if case LLMError.emptyResponse = error {
                    turnRecoveryState.emptyStormStreak += 1
                    logger.warning("empty response \(turnRecoveryState.emptyStormStreak)/\(TurnRecoveryState.emptyStormThreshold) from provider (stream)")
                    if turnRecoveryState.emptyStormStreak > TurnRecoveryState.emptyStormThreshold {
                        throw error
                    }
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

    /// Record a turn's usage into the local ledger (reference usage_pricing +
    /// credits_tracker parity; local JSON — usage is not session data).
    private func recordUsage(_ usage: Usage?) async {
        guard let usage else { return }
        let route = BillingRoute(
            provider: config.provider,
            model: currentModelName,
            baseURL: config.baseURL.absoluteString
        )
        await usageLedger.record(
            route: route,
            usage: CanonicalUsage(
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                cacheReadTokens: usage.cachedPromptTokens ?? 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                requestCount: 1
            )
        )
    }

    /// Rebuild the primary transport client from current state (reference
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

    /// Route label for rate-limit tracking (provider/model), matching reference'
    /// per-route buckets.
    private func rateLimitRoute() -> String {
        "\(config.provider)/\(currentModelName)"
    }

    /// Stream patience for the current model (reference staleness watchdog).
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

    /// Convert `[Message]` to the wire API form (reference api_messages shape)
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

    /// Post-execution laundering (reference `redact.py` parity): terminal tool
    /// output is scrubbed for secret shapes before it is shown to the model.
    static func launderToolResult(_ call: ToolCall, _ result: String) async -> String {
        if call.function.name == "terminal" {
            return Redactor.redact(Redactor.redactTerminalOutput(result))
        }
        return result
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
    /// restoring it into history (reference api_messages parity):
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
        // Pass 3: reference message sanitization — unicode/control cleanup and
        // interrupted tool-sequence closing (synthetic results for unpaired
        // trailing calls; a no-op for well-formed transcripts).
        return MessageSanitizer.sanitize(withStubs)
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

    /// Keep the system messages plus the most recent `maxMessages - systems`
    /// non-system messages (the `/compress` REPL window).
    ///
    /// The count is clamped to `>= 0` so a history whose system messages
    /// alone exceed the cap degrades to "system messages only" instead of
    /// trapping (`Array.suffix(_:)` raises "Can't take a suffix of negative
    /// length" for a negative argument — a process crash).
    static func compressWindow(
        history: [Message],
        systemMessages: [Message],
        maxMessages: Int
    ) -> [Message] {
        let limit = max(0, maxMessages - systemMessages.count)
        return systemMessages + Array(history.suffix(limit))
    }

    /// Floor cap for injected project context files (chars).
    static let contextFileBudgetChars = 16_000

    /// arc-parity mandatory skills framing that precedes the index.
    /// Moved to ``SkillsPrompt`` so the CLI harness and the webui turn engine
    /// share one block (the webui was drifting — bare list, no instruction).
    static let skillsMandatoryFraming = SkillsPrompt.mandatoryFraming
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

    /// Bridge translation for tool_describe / tool_call (arc parity).
    private func handleBridgeCall(name: String, argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: Invalid arguments for '\(name)'."
        }
        guard let tool = args["tool"] as? String, !tool.isEmpty else {
            return "Error: 'tool' (string) is required."
        }
        if name == "tool_describe" {
            guard let entry = config.registry.lookup(name: tool) else {
                return "Error: Unknown tool '\(tool)'."
            }
            let schema = ProgressiveToolDisclosure.schema(for: entry)
            guard let pretty = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: pretty, encoding: .utf8) else {
                return "Error: could not serialize schema for '\(tool)'."
            }
            return "## \(tool)\n\n\(text)"
        }
        // tool_call
        guard tool != "tool_call", tool != "tool_describe", tool != "tool_search" else {
            return "Error: cannot invoke bridge tool '\(tool)' through tool_call."
        }
        guard config.registry.lookup(name: tool) != nil else {
            return "Error: Unknown tool '\(tool)'."
        }
        let inner: String
        if let innerArgs = args["arguments"] as? [String: Any] {
            guard let d = try? JSONSerialization.data(withJSONObject: innerArgs) else {
                return "Error: invalid 'arguments' for '\(tool)'."
            }
            inner = String(data: d, encoding: .utf8) ?? "{}"
        } else if let raw = args["arguments"] as? String, !raw.isEmpty {
            inner = raw
        } else {
            inner = "{}"
        }
        return (try? await dispatchToolCall(ToolCall(
            id: "bridge-\(UUID().uuidString)",
            function: ToolCallFunction(name: tool, arguments: inner)
        ))) ?? "Error: bridge dispatch failed for '\(tool)'."
    }

    // MARK: Tool invocation
    //
    // Workspace anchoring (arc parity): every handler runs with
    // `WorkspacePath.root` bound to the CLI's launch directory (the CLI has
    // no per-conversation workspace registry — reference' CLI equivalent is
    // `$TERMINAL_CWD`, also the launch cwd). The webui binds its per-session
    // workspace instead. File tools anchor relative paths to this root and
    // warn when one escapes it.
    private func dispatchToolCall(_ toolCall: ToolCall) async throws -> String {
        // ── Progressive tool disclosure bridge (reference `tools/tool_search.py`):
        // tool_describe/tool_call are not registered tools; the bridge
        // translates them and routes the target through THIS dispatch, so
        // guardrails, approvals, and the tool gateway all fire normally.
        if toolCall.function.name == "tool_describe" || toolCall.function.name == "tool_call" {
            return await handleBridgeCall(name: toolCall.function.name, argumentsJSON: toolCall.function.arguments)
        }

        guard let entry = config.registry.lookup(name: toolCall.function.name) else {
            return "Error: Unknown tool '\(toolCall.function.name)'."
        }

        // ── Tool gateway (reference `tool_gateway` / managed scope): policy is
        // evaluated before any approval/danger logic and before execution. ──
        let gate = ToolGateway.decide(
            toolName: toolCall.function.name,
            toolset: entry.toolset,
            config: config.gateway
        )
        switch gate.action {
        case .deny:
            return "[BLOCKED by tool gateway: \(toolCall.function.name) is not permitted\(gate.reason.map { " — \($0)" } ?? "")]"
        case .requireApproval:
            return "[REQUIRES APPROVAL (tool gateway): \(toolCall.function.name)\(gate.reason.map { " — \($0)" } ?? "") — enable the rule's scope or switch the rule to deny/allow]"
        case .allow:
            break
        }

        guard let data = toolCall.function.arguments.data(using: .utf8) else {
            return "Error: Invalid arguments JSON for tool '\(toolCall.function.name)'."
        }
        var args: [String: Any]
        do {
            args = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            // reference `repair_tool_call_arguments`: recover corrupted JSON
            // (unescaped newlines/quotes, bare keys) before failing.
            let rawArgs = String(data: data, encoding: .utf8) ?? ""
            let repair = MessageSanitizer.repairToolCallArguments(rawArgs)
            if repair.repaired,
               let repairedArgs = try? JSONSerialization.jsonObject(
                   with: Data(repair.json.utf8)) as? [String: Any] {
                args = repairedArgs
            } else {
                // Invalid-JSON recovery (reference `_invalid_json_retries`): feed
                // the parse failure back as a tool result and let the model
                // retry — bounded per turn so a broken model cannot loop.
                turnRecoveryState.invalidJSONRetries += 1
                if turnRecoveryState.invalidJSONRetries <= TurnRecoveryState.maxInvalidJSONRetries {
                    return RecoveryNudges.invalidJSONToolResult(
                        toolName: toolCall.function.name,
                        error: String(describing: error)
                    )
                }
                return "Error: Invalid arguments JSON for tool '\(toolCall.function.name)'."
            }
        }

        // Tool guardrails (reference tool_guardrails): loop caps, per-turn
        // budgets, and repeated-call synthetic results.
        switch await toolGuardrails.decide(toolName: toolCall.function.name, args: args) {
        case .synthetic(let message):
            return message
        case .allow:
            break
        }

        do {
            // Ambient tool dispatcher for execute_code: child Python processes
            // dispatch tools back into THIS agent (same registry, guardrails,
            // and session) via the loopback RPC server.
            await ExecuteCodeTool.dispatcher.setHost { [weak self] name, args in
                guard let self else {
                    throw ToolError.execution("execute_code host agent no longer active")
                }
                return try await self.dispatchAmbientTool(name: name, args: args)
            }
            return try await WorkspacePath.$root.withValue(FileManager.default.currentDirectoryPath) {
                try await entry.handler(args)
            }
        } catch {
            return "Error executing tool '\(toolCall.function.name)': \(error.localizedDescription)"
        }
    }

    /// Re-enter the tool pipeline from execute_code's RPC dispatcher (returns
    /// the tool result text, same as a direct tool call).
    private func dispatchAmbientTool(name: String, args: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        let call = ToolCall(
            id: "ambient-\(name)",
            function: ToolCallFunction(
                name: name,
                arguments: String(data: data, encoding: .utf8) ?? "{}"))
        return try await dispatchToolCall(call)
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
    ///
    /// Every call emits ``AgentTurnEvent/toolCallStarted(id:name:arguments:)``
    /// before it runs and ``AgentTurnEvent/toolCallFinished(id:name:result:)``
    /// with its laundered result afterwards. Non-streaming callers pass the
    /// default no-op emitter.
    private func executeToolCalls(
        _ toolCalls: [ToolCall],
        emit: @Sendable (AgentTurnEvent) -> Void = { _ in }
    ) async -> [(ToolCall, String)] {
        var outcomes: [(ToolCall, String)] = []
        toolCallsThisTurn += toolCalls.count
        for segment in Self.planToolBatch(toolCalls) {
            for call in segment {
                emit(.toolCallStarted(
                    id: call.id, name: call.function.name, arguments: call.function.arguments
                ))
            }
            if segment.count == 1 {
                let call = segment[0]
                let result = await Self.launderToolResult(call, await runToolCall(call))
                emit(.toolCallFinished(id: call.id, name: call.function.name, result: result))
                outcomes.append((call, result))
                continue
            }
            // reference concurrent-batch watchdog parity: capped concurrency
            // (max 8) + a 420 s batch deadline. On deadline the batch is
            // abandoned and still-running calls become explicit
            // "timed out after 420.0s" results — a wedged swift test can no
            // longer hang the turn for hours.
            let batch = await ToolBatchExecutor.run(
                segment,
                nameOf: { $0.function.name },
                body: { call in
                    let result = await self.runToolCall(call)
                    return await Self.launderToolResult(call, result)
                }
            )
            for (call, outcome) in zip(segment, batch) {
                emit(.toolCallFinished(id: call.id, name: call.function.name, result: outcome.result))
                outcomes.append((call, outcome.result))
            }
        }
        // Verification evidence (reference `verification_evidence`): collect the
        // changed paths terminal tools attached, for the verify-on-stop nudge.
        for (_, result) in outcomes {
            turnChangedPaths.append(contentsOf: Self.parseEvidencePaths(result))
        }
        await maybeRunBackgroundReview(recentCalls: toolCalls.map { $0.function.name })
        return outcomes
    }

    /// Parse `[evidence] changed paths (N): a, b, …` out of a tool result.
    private static func parseEvidencePaths(_ result: String) -> [String] {
        guard let marker = result.range(of: "[evidence] changed paths ("),
              let close = result.range(of: "): ", range: marker.upperBound..<result.endIndex) else {
            return []
        }
        let tail = result[close.upperBound...]
        let line = tail.prefix(while: { $0 != "\n" })
        return line.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// reference `background_review` cadence: every `afterToolCalls` tool calls,
    /// an auxiliary model reviews the recent calls for loops/wasted work and
    /// its guidance (when not "OK") is injected into the next user turn.
    private func maybeRunBackgroundReview(recentCalls: [String]) async {
        let settings = config.backgroundReview
        guard settings.afterToolCalls > 0 else { return }
        guard toolCallsThisTurn > 0, toolCallsThisTurn % settings.afterToolCalls == 0 else { return }
        guard let router = auxRouter, let hc = httpClient,
              // Review uses the verification aux lane; the canonical 16-task
              // auxiliary set stays reference-identical (parity test guard).
              let client = router.makeClient(task: .verification, httpClient: hc) else { return }
        let windowCalls = Array(recentCalls.suffix(settings.window))
        guard !windowCalls.isEmpty else { return }
        let prompt = BackgroundReview.reviewPrompt(toolCalls: windowCalls)
        do {
            let resp = try await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil,
                reasoningEffort: nil
            )
            if let guidance = BackgroundReview.guidanceBlock(resp.content ?? "") {
                pendingBackgroundGuidance = guidance
            }
        } catch {
            // Fail-open: no guidance.
        }
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

    /// Build the system prompt as three ordered cache tiers (arc parity):
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

        // ── Personality overlay (reference `/personality`, `agent.system_prompt`) ──
        if !config.personalityPrompt.isEmpty {
            stable += "\n\n## Personality\n\n\(config.personalityPrompt)"
        }

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
        // The mandatory framing instructs the model to load skills with
        // `skill_view`; inject the section only when the registry actually
        // exposes the loader, so the prompt never advertises a tool the
        // surface lacks.
        if !config.skills.isEmpty, config.registry.lookup(name: "skill_view") != nil {
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

    /// Discover and cache project context files (AGENTS.md, .arc.md,
    /// CLAUDE.md, .cursorrules) from the working directory, floor-capped by
    /// the context window so they never crowd out the conversation.
    private func loadContextFiles() async -> [(name: String, content: String)] {
        if let cached = contextFilesCache { return cached }
        var result: [(name: String, content: String)] = []
        let fm = FileManager.default
        let base = config.contextDirectory ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        let names = ["AGENTS.md", ".arc.md", "CLAUDE.md", ".cursorrules"]
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
    /// memory/skills are reloaded — reference `invalidate_system_prompt`).
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
