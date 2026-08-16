import Foundation
import AsyncHTTPClient
import ServiceLifecycle

/// The central agent loop that drives one user turn through the agent.
///
/// ``ArcAgent`` is an **actor** conforming to Swift Service Lifecycle's
/// ``Service`` protocol. All state mutations are serialized by the actor.
/// The HTTP client is created in ``run()`` and torn down in a ``defer`` block
/// — no ad-hoc shutdown methods, no resource leaks.
///
/// ## Turn Loop
///
/// 1. Build system prompt (identity, skills index, memory, context files)
/// 2. Build turn context (messages + tool schemas)
/// 3. Call LLM
/// 4. Parse response — if text, return; if tool_calls, dispatch
/// 5. Append results to history, repeat from step 2
/// 6. Post-turn hooks (memory write, session persistence)
///
/// ## Lifecycle
///
/// The agent is started via a ``ServiceGroup``. The ``run()`` method manages
/// the HTTP client's lifetime — it is created on entry and shut down in a
/// ``defer`` block when the service is cancelled or returns.
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
        /// Maximum iterations per conversation.
        public var maxIterations: Int
        /// Whether to persist sessions.
        public var persistSessions: Bool
        /// Single query mode. If set, the agent processes one query and exits.
        /// If nil, the agent runs an interactive readline loop.
        public var query: String?

        public init(
            model: String,
            provider: String = "openai",
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            apiKey: String,
            registry: CompileTimeToolRegistry,
            sessionStore: SessionStore = FileSessionStore(),
            maxIterations: Int = 25,
            persistSessions: Bool = true,
            query: String? = nil
        ) {
            self.model = model
            self.provider = provider
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.registry = registry
            self.sessionStore = sessionStore
            self.maxIterations = maxIterations
            self.persistSessions = persistSessions
            self.query = query
        }
    }

    // MARK: - State

    private let config: Configuration
    private var llmClient: OpenAICompatibleClient?
    private var messageHistory: [Message]
    private let sessionID: String

    // MARK: - Init

    /// Create a new agent with the given configuration.
    ///
    /// - Parameter config: The agent configuration.
    public init(config: Configuration) {
        self.config = config
        self.messageHistory = []
        self.sessionID = UUID().uuidString
    }

    // MARK: - Service

    /// Run the agent service.
    ///
    /// Creates the HTTP client on entry and shuts it down in a ``defer`` block
    /// when the service is cancelled or returns. This is the only place the
    /// HTTP client is managed — no ad-hoc shutdown methods.
    public func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        let client = OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            httpClient: httpClient
        )
        self.llmClient = client

        if let q = config.query {
            // Single-query mode
            let response = try await runConversation(message: q)
            print(response)
        } else {
            // Interactive mode
            print("⚡ ARC Agent — interactive mode")
            print("   Type your message, or /quit to exit.\n")
            while true {
                print("> ", terminator: "")
                guard let input = readLine(), input != "/quit" else { break }
                let response = try await runConversation(message: input)
                print(response)
                print("")
            }
        }

        // HTTP client shutdown — runs after all conversation work completes.
        // In interactive mode this fires when the user types /quit.
        // In single-query mode it fires after the response is printed.
        // On SIGINT the ServiceGroup cancels the task and the OS reclaims
        // the connections — acceptable for the CLI use case.
        try? await httpClient.shutdown()
    }

    // MARK: - Conversation

    /// Run a single conversation turn with the given user message.
    ///
    /// This runs the full agent loop: build prompt → call LLM → dispatch tools
    /// → repeat until done.
    ///
    /// - Parameter message: The user's message.
    /// - Returns: The agent's final text response.
    private func runConversation(message: String) async throws -> String {
        guard let llmClient else {
            return "Error: Agent not started. Call run() first."
        }

        // Add user message to history
        messageHistory.append(Message(role: .user, content: message))

        // Ensure session exists in store
        if config.persistSessions {
            let session = Session(
                id: sessionID,
                model: config.model,
                provider: config.provider,
                messages: messageHistory
            )
            try await config.sessionStore.create(session)
        }

        // Run the turn loop
        let response = try await runTurnLoop(client: llmClient)

        // Persist session
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

    /// The core turn loop: build prompt → call LLM → dispatch tools → repeat.
    private func runTurnLoop(client: OpenAICompatibleClient) async throws -> String {
        for iteration in 0..<config.maxIterations {
            // 1. Build system prompt
            let systemPrompt = buildSystemPrompt()

            // 2. Build messages array (system + history)
            var messages: [Message] = [Message(role: .system, content: systemPrompt)]
            messages.append(contentsOf: messageHistory)

            // 3. Build tool schemas
            let toolSchemas = config.registry.buildToolSchemas(
                enabled: [],
                disabled: []
            )

            // 4. Call LLM
            let response = try await client.complete(
                messages: messages,
                tools: toolSchemas.isEmpty ? nil : toolSchemas
            )

            // 5. Parse response
            if let content = response.content, !content.isEmpty {
                // Text response — append to history and return
                messageHistory.append(Message(
                    role: .assistant,
                    content: content
                ))
                return content
            }

            // 6. Handle tool calls
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                // Append assistant message with tool calls
                messageHistory.append(Message(
                    role: .assistant,
                    content: nil,
                    toolCalls: toolCalls
                ))

                // Dispatch each tool call
                for toolCall in toolCalls {
                    let result = try await dispatchToolCall(toolCall)
                    messageHistory.append(Message(
                        role: .tool,
                        content: result,
                        name: toolCall.function.name,
                        toolCallID: toolCall.id
                    ))
                }

                // Continue loop — the tool results will be sent back to the LLM
                continue
            }

            // 7. Empty response — retry
            if iteration == config.maxIterations - 1 {
                return "I encountered an issue processing your request. Please try again."
            }
        }

        return "The conversation reached the maximum iteration limit. Please start a new session."
    }

    // MARK: - Tool Dispatch

    /// Dispatch a single tool call to the registered handler.
    private func dispatchToolCall(_ toolCall: ToolCall) async throws -> String {
        guard let entry = config.registry.lookup(name: toolCall.function.name) else {
            return "Error: Unknown tool '\(toolCall.function.name)'."
        }

        // Parse arguments
        guard let data = toolCall.function.arguments.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "Error: Invalid arguments JSON for tool '\(toolCall.function.name)'."
        }

        // Execute the handler
        do {
            return try await entry.handler(args)
        } catch {
            return "Error executing tool '\(toolCall.function.name)': \(error.localizedDescription)"
        }
    }

    // MARK: - Prompt Building

    /// Build the system prompt for the agent.
    private func buildSystemPrompt() -> String {
        """
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
    }

    /// Build the tools index for the system prompt.
    private func buildToolsIndex() -> String {
        let tools = config.registry.allTools
        return tools.map { tool in
            let emoji = tool.emoji ?? "🔧"
            return "\(emoji) `\(tool.name)` [\(tool.toolset)] — \(tool.description)"
        }.joined(separator: "\n")
    }
}
