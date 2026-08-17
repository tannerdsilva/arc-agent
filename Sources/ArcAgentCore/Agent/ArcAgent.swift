import Foundation
import AsyncHTTPClient
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
            maxContextTokens: Int = 64_000
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
        }
    }

    // MARK: - State

    private let config: Configuration
    private var llmClient: OpenAICompatibleClient?
    private var httpClient: HTTPClient?
    private var messageHistory: [Message]
    private let sessionID: String
    private let retryHandler = RetryHandler(maxRetries: 3, baseDelay: 1.0)
    /// Circuit breaker for the primary LLM endpoint.
    private let circuitBreaker = CircuitBreaker(label: "primary-llm", threshold: 3, resetTimeout: 30)
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
        self.sessionID = UUID().uuidString
        self.approvalManager = ApprovalManager(mode: config.approvalMode)
        self.delegationManager = DelegationManager(maxChildren: 10)
    }

    /// Set up the LLM client for gateway use (without calling `run()`).
    /// The caller owns the HTTPClient lifecycle.
    func setupClient(httpClient: HTTPClient) async {
        self.httpClient = httpClient
        let pool = CredentialPool(credentials: [config.apiKey])
        let resolvedKey = await pool.acquireLease() ?? config.apiKey
        self.llmClient = OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: resolvedKey,
            model: config.model,
            httpClient: httpClient
        )
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

    /// Run a single conversation turn with the given user message.
    func runConversation(message: String) async throws -> String {
        guard let llmClient else {
            return "Error: Agent not started. Call run() first."
        }

        messageHistory.append(Message(role: .user, content: message))

        if config.persistSessions {
            let session = Session(
                id: sessionID,
                model: config.model,
                provider: config.provider,
                messages: messageHistory
            )
            try await config.sessionStore.create(session)
        }

        let response = try await runTurnLoop(client: llmClient)

        if config.persistSessions {
            let session = Session(
                id: sessionID,
                model: config.model,
                provider: config.provider,
                messages: messageHistory
            )
            try await config.sessionStore.update(session)
        }

        return response
    }

    // MARK: - Token Counting

    /// Calibrated token counter for estimating context usage.
    private let tokenCounter = TokenCounter()

    /// Estimate the total token count of the current message history.
    private func estimateHistoryTokens() -> Int {
        tokenCounter.count(messages: messageHistory, model: config.model)
    }

    /// Auto-compress history if estimated tokens exceed the configured limit.
    private func autoCompressIfNeeded() {
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

        // Extractive compression: concatenate older messages with context markers
        let compressedContent = compressible.compactMap { msg -> String? in
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

        let summaryMessage = Message(
            role: .system,
            content: """
            The following is a compressed record of earlier conversation context. \
            Key information, decisions, and facts from these exchanges are preserved below:

            \(compressedContent)
            """
        )

        messageHistory = systemMessages + [summaryMessage] + Array(recent)
    }

    // MARK: - Turn Loop

    /// The core turn loop with retry logic, fallback models, and timeout.
    private func runTurnLoop(client: OpenAICompatibleClient) async throws -> String {
        guard let hc = self.httpClient else {
            return "Error: Agent HTTP client not initialized."
        }
        var currentClient = client
        var fallbackIndex = 0
        let fallbacks = BundledProviders.resolve(config.provider)?.fallbackModels ?? []

        for iteration in 0..<config.maxIterations {
            // Auto-compress if context is too large
            autoCompressIfNeeded()

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
                        print("⚠️ Falling back to \(fallbackModel)...")
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

            // 5. Parse response
            if let content = response.content, !content.isEmpty {
                messageHistory.append(Message(role: .assistant, content: content))
                return content
            }

            // 6. Handle tool calls
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                messageHistory.append(Message(
                    role: .assistant,
                    content: nil,
                    toolCalls: toolCalls
                ))

                for toolCall in toolCalls {
                    if toolCall.function.name == "terminal" {
                        let args = toolCall.function.arguments
                        let needsApproval = await approvalManager.needsApproval(
                            command: args,
                            sessionKey: sessionID
                        )
                        if needsApproval {
                            let result = await approvalManager.requestApproval(
                                command: args,
                                description: "Execute shell command",
                                sessionKey: sessionID
                            )
                            switch result {
                            case .denied:
                                messageHistory.append(Message(
                                    role: .tool,
                                    content: "Error: Command blocked by security policy.",
                                    name: toolCall.function.name,
                                    toolCallID: toolCall.id
                                ))
                                continue
                            case .requiresReview:
                                messageHistory.append(Message(
                                    role: .tool,
                                    content: "⚠️ Command requires manual approval. "
                                        + "Run it yourself or disable the approval system.",
                                    name: toolCall.function.name,
                                    toolCallID: toolCall.id
                                ))
                                continue
                            case .approved:
                                break
                            }
                        }
                    }

                    let result = try await dispatchToolCall(toolCall)
                    messageHistory.append(Message(
                        role: .tool,
                        content: result,
                        name: toolCall.function.name,
                        toolCallID: toolCall.id
                    ))
                }

                continue
            }

            if iteration == config.maxIterations - 1 {
                return "I encountered an issue processing your request. Please try again."
            }
        }

        return "The conversation reached the maximum iteration limit. Please start a new session."
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
        client: OpenAICompatibleClient,
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
                    return response
                }

                // Success — reset circuit breaker
                await circuitBreaker.reset()
                return result
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
                    autoCompressIfNeeded()
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

    // MARK: - Tool Dispatch

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
