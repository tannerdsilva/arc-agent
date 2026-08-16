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
        /// Whether to persist sessions.
        public var persistSessions: Bool
        /// The approval mode for dangerous commands.
        public var approvalMode: ApprovalMode
        /// Single query mode. If set, the agent processes one query and exits.
        public var query: String?

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
            persistSessions: Bool = true,
            approvalMode: ApprovalMode = .manual,
            query: String? = nil
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
            self.persistSessions = persistSessions
            self.approvalMode = approvalMode
            self.query = query
        }
    }

    // MARK: - State

    private let config: Configuration
    private var llmClient: OpenAICompatibleClient?
    private var httpClient: HTTPClient?
    private var messageHistory: [Message]
    private let sessionID: String
    private let retryHandler = RetryHandler(maxRetries: 3, baseDelay: 1.0)
    private let approvalManager: ApprovalManager

    // MARK: - Init

    public init(config: Configuration) {
        self.config = config
        self.messageHistory = []
        self.sessionID = UUID().uuidString
        self.approvalManager = ApprovalManager(mode: config.approvalMode)
    }

    // MARK: - Service

    public func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        self.httpClient = httpClient

        let client = OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            httpClient: httpClient
        )
        self.llmClient = client

        if let q = config.query {
            let response = try await runConversation(message: q)
            print(response)
        } else {
            try await runInteractive()
        }

        try? await httpClient.shutdown()
    }

    // MARK: - Interactive REPL

    /// Run the interactive readline REPL with slash commands.
    private func runInteractive() async throws {
        print("⚡ ARC Agent — interactive mode")
        print("   Type your message, or /quit to exit.")
        print("   Commands: /model, /retry, /help, /compress, /quit\n")

        while true {
            print("> ", terminator: "")
            guard let input = readLine() else { break }

            if input.hasPrefix("/") {
                let handled = try await handleSlashCommand(input)
                if handled { continue } else { break }
            }

            let response = try await runConversation(message: input)
            print(response)
            print("")
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
            // Update the model on the LLM client
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
            // Remove the last assistant message and re-run
            if let lastMsg = messageHistory.last, lastMsg.role == .assistant {
                messageHistory.removeLast()
            }
            // Find the last user message
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
            // Simple compression: keep system prompt + last N messages
            let maxMessages = 20
            if messageHistory.count > maxMessages {
                // Keep the first (system) and last N-1 messages
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
    private func runConversation(message: String) async throws -> String {
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

    // MARK: - Turn Loop

    /// The core turn loop with retry logic and fallback models.
    private func runTurnLoop(client: OpenAICompatibleClient) async throws -> String {
        guard let hc = self.httpClient else {
            return "Error: Agent HTTP client not initialized."
        }
        var currentClient = client
        var fallbackIndex = 0
        let fallbacks = BundledProviders.resolve(config.provider)?.fallbackModels ?? []

        for iteration in 0..<config.maxIterations {
            // 1. Build system prompt with memory and skills
            let systemPrompt = try await buildSystemPrompt()

            // 2. Build messages array
            var messages: [Message] = [Message(role: .system, content: systemPrompt)]
            messages.append(contentsOf: messageHistory)

            // 3. Build tool schemas
            let toolSchemas = config.registry.buildToolSchemas(
                enabled: [],
                disabled: []
            )

            // 4. Call LLM with retry logic
            let response: LLMResponse
            do {
                response = try await callWithRetry(client: currentClient, messages: messages, tools: toolSchemas)
            } catch {
                let errorClass = classifyError(error)

                // Try fallback models on permanent errors
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

                // If we exhausted retries and fallbacks, return the error
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
                    // Check approval for terminal commands
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

    /// Call the LLM with retry logic and exponential backoff.
    private func callWithRetry(
        client: OpenAICompatibleClient,
        messages: [Message],
        tools: [[String: Any]]?
    ) async throws -> LLMResponse {
        var lastError: Error? = nil
        // Serialize tools to Data (Sendable) to avoid actor isolation issues
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
                return try await client.complete(
                    messages: messages,
                    tools: toolsArg
                )
            } catch {
                lastError = error
                let errorClass = classifyError(error)

                switch errorClass {
                case .permanent:
                    throw error  // Don't retry permanent errors
                case .retryable:
                    if retryHandler.shouldRetry(attempt) {
                        try await retryHandler.wait(for: attempt)
                        continue
                    }
                case .contextOverflow:
                    throw error
                }
            }
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
    private func buildSystemPrompt() async throws -> String {
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
