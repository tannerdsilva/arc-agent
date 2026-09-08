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

        /// The session ID to restore persisted history from. `nil` starts a
        /// fresh session with a new UUID.
        public var sessionID: String?

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
            sessionID: String? = nil
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
        let pool = CredentialPool(credentials: [config.apiKey])
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

        // Wire the credential pool (no longer dead code)
        let pool = CredentialPool(credentials: [config.apiKey])
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
                messageHistory = session.messages
                persistedMessageCount = session.messages.count
                sessionCreatedInStore = true
                logger.info("restored \(session.messages.count) message(s) for session \(sid)")
            } else {
                logger.info("session \(sid) not found in store; starting fresh")
            }
        } catch {
            logger.error("failed to restore session \(sid): \(error)")
        }
    }

    /// Run a single conversation turn with the given user message.
    func runConversation(message: String) async throws -> String {
        guard let llmClient else {
            return "Error: Agent not started. Call run() first."
        }

        await restoreSessionIfNeeded()
        messageHistory.append(Message(role: .user, content: message))

        let response = try await runTurnLoop(client: llmClient)

        await persistConversationIfNeeded()

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

    /// Estimate the total token count of the current message history.
    private func estimateHistoryTokens() -> Int {
        tokenCounter.count(messages: messageHistory, model: config.model)
    }

    /// Auto-compress history if estimated tokens exceed the configured limit.
    private func autoCompressIfNeeded() async {
        let estimated = estimateHistoryTokens()
        guard estimated > config.maxContextTokens else { return }

        // Keep system messages intact
        let systemMessages = messageHistory.filter { $0.role == .system }
        let nonSystem = messageHistory.filter { $0.role != .system }

        // Keep the most recent 5 exchanges (10 messages) for active context
        let minRecent = min(10, nonSystem.count)
        let recent = nonSystem.suffix(minRecent)
        let compressible = nonSystem.prefix(nonSystem.count - minRecent)

        guard !compressible.isEmpty else {
            // Even the recent messages alone exceed budget — keep last 4
            let veryRecent = nonSystem.suffix(min(8, nonSystem.count))
            messageHistory = systemMessages + Array(veryRecent)
            return
        }

        // Hermes-parity compression: when a \`compression\` auxiliary model is
        // configured, produce a real summary with it; otherwise fall back to
        // the extractive record (older messages + context markers).
        let summaryText: String
        if let summarized = await summarizeForCompression(Array(compressible)) {
            summaryText = summarized
        } else {
            summaryText = Self.compressedRecord(Array(compressible))
        }

        let summaryMessage = Message(
            role: .system,
            content: """
            The following is a compressed record of earlier conversation context. \
            Key information, decisions, and facts from these exchanges are preserved below:

            \(summaryText)
            """
        )

        messageHistory = systemMessages + [summaryMessage] + Array(recent)
    }

    /// Attempt an LLM summarization of older messages using the \`compression\`
    /// auxiliary model. Returns nil when no override is configured or the
    /// call fails — callers fall back to the extractive record.
    private func summarizeForCompression(_ messages: [Message]) async -> String? {
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
            // Auto-compress if context is too large
            await autoCompressIfNeeded()

            // 1. Build system prompt with memory and skills (cached)
            let systemPrompt = try await buildSystemPrompt()

            // 2. Build messages array
            var messages: [Message] = [Message(role: .system, content: systemPrompt)]
            messages.append(contentsOf: messageHistory)

            // 3. Build tool schemas
            let toolSchemas = config.registry.buildToolSchemas(
                enabled: [],
                disabled: []
            )

            // 4. Call LLM with retry logic and per-turn timeout
            let response: LLMResponse
            do {
                response = try await callWithRetry(
                    client: currentClient,
                    messages: messages,
                    tools: toolSchemas,
                    timeout: config.maxTurnDuration
                )
            } catch {
                let errorClass = classifyError(error)

                // Try fallback models on permanent or retryable errors
                if errorClass == .permanent || errorClass == .retryable {
                    if fallbackIndex < fallbacks.count {
                        let fallbackModel = fallbacks[fallbackIndex]
                        fallbackIndex += 1
                        logger.warning("Falling back to \(fallbackModel)")
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
            await autoCompressIfNeeded()
            var streamFinishReason: String? = nil

            let systemPrompt = try await buildSystemPrompt()
            var messages: [Message] = [Message(role: .system, content: systemPrompt)]
            messages.append(contentsOf: messageHistory)

            let toolSchemas = config.registry.buildToolSchemas(
                enabled: [],
                disabled: []
            )

            var accumulatedContent = ""
            var accumulatedToolCalls: [ToolCall] = []

            do {
                let stream = try await callStreamWithRetry(
                    client: currentClient,
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
                if errorClass == .permanent || errorClass == .retryable {
                    if fallbackIndex < fallbacks.count {
                        let fallbackModel = fallbacks[fallbackIndex]
                        fallbackIndex += 1
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
                // Whitespace-only prefix — keep the loop going.
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
        let toolsData: Data?
        if let tools, !tools.isEmpty {
            toolsData = try JSONSerialization.data(withJSONObject: tools)
        } else {
            toolsData = nil
        }

        for attempt in 0..<retryHandler.maxRetries {
            do {
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
                        return try await client.complete(
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
                return result
            } catch {
                lastError = error
                let errorClass = classifyError(error)
                await Metrics.shared.recordError("\(errorClass)")

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
        messages: [Message],
        tools: [[String: Any]]?,
        timeout: Int = 120
    ) async throws -> AsyncThrowingStream<LLMDelta, Error> {
        let cbState = await circuitBreaker.currentState()
        if case .open(let resetAt) = cbState {
            throw CircuitBreakerError.open(
                label: circuitBreaker.label,
                resetAt: resetAt,
                lastFailureReason: "Circuit breaker is open"
            )
        }

        var lastError: Error? = nil
        let toolsData: Data?
        if let tools, !tools.isEmpty {
            toolsData = try JSONSerialization.data(withJSONObject: tools)
        } else {
            toolsData = nil
        }

        for attempt in 0..<retryHandler.maxRetries {
            do {
                let toolsArg: [[String: Any]]?
                if let toolsData {
                    toolsArg = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]]
                } else {
                    toolsArg = nil
                }

                let stream = try await client.stream(
                    messages: messages,
                    tools: toolsArg
                )

                await circuitBreaker.reset()
                return stream
            } catch {
                lastError = error
                let errorClass = classifyError(error)

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

        guard let data = toolCall.function.arguments.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
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
        return result
    }

    // MARK: - Prompt Building

    /// Build the system prompt with memory and skills injection.
    /// Results are cached and only rebuilt when the cache version changes.
    private func buildSystemPrompt() async throws -> String {
        if lastBuiltVersion == systemPromptVersion, let cached = cachedSystemPrompt {
            return cached
        }

        var prompt = """
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

        // Environment context — so the model can use paths like ~/Desktop
        // without a probe turn, and so relative tool paths resolve where
        // the user expects.
        let osDescription: String
        #if os(macOS)
        osDescription = "macOS (\(ProcessInfo.processInfo.operatingSystemVersionString))"
        #else
        osDescription = "\(ProcessInfo.processInfo.operatingSystemName) \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        prompt += """


            ## Environment

            - OS: \(osDescription)
            - Home directory: \(NSHomeDirectory())
            - Desktop: \(NSHomeDirectory())/Desktop
            - Working directory for tools (relative paths resolve here): \(FileManager.default.currentDirectoryPath)
            - Use ~/... paths (or absolute paths) for user-visible locations; the `terminal` tool's shell expands `~`, and `write_file` accepts paths relative to the working directory.
            """

        // Inject memory
        if let memory = config.memoryProvider {
            let memoryContent = try await memory.readMemory()
            if !memoryContent.isEmpty {
                prompt += "\n\n## Memory (Your Persistent Notes)\n\n\(memoryContent)"
            }

            let userContent = try await memory.readUser()
            if !userContent.isEmpty {
                prompt += "\n\n## User Profile\n\n\(userContent)"
            }
        }

        // Inject skills index
        if !config.skills.isEmpty {
            prompt += "\n\n## Available Skills\n\n\(buildSkillsIndex(config.skills))\n\n"
                + "Load a skill with `skill_view(name)` to follow its instructions."
        }

        cachedSystemPrompt = prompt
        lastBuiltVersion = systemPromptVersion
        return prompt
    }

    private func buildToolsIndex() -> String {
        let tools = config.registry.allTools
        return tools.map { tool in
            let emoji = tool.emoji ?? "🔧"
            return "\(emoji) `\(tool.name)` [\(tool.toolset)] — \(tool.description)"
        }.joined(separator: "\n")
    }
}
