import Foundation
import SwiftSlash

/// Agent Client Protocol (ACP) host client (Hermes `copilot_acp_client.py`):
/// spawns a `copilot` ACP subprocess and speaks JSON-RPC 2.0 over stdio —
/// `initialize`, `session/new`, `session/prompt`. Used for the `copilot`
/// auth type. Pure `Process` + `AsyncBytes` (no threads, no queues).
public actor ACPClient {

    public struct Config: Sendable {
        public let command: String
        public let args: [String]
        public let workingDirectory: String?
        public let metadata: ModelMetadata
        public let maxTokens: Int
        public let temperature: Double?

        public init(
            command: String = "/usr/local/bin/copilot",
            args: [String] = [],
            workingDirectory: String? = nil,
            metadata: ModelMetadata? = nil,
            maxTokens: Int = 8192,
            temperature: Double? = nil
        ) {
            self.command = command
            self.args = args
            self.workingDirectory = workingDirectory
            self.metadata = metadata ?? ModelMetadataRegistry.shared.metadata(for: "copilot-acp", provider: "copilot")
            self.maxTokens = maxTokens
            self.temperature = temperature
        }
    }

    private let config: Config
    /// SwiftSlash child; stdin/stdout are the built-in channels (newline
    /// framing matches ACP's JSON-RPC line protocol exactly).
    private var child: ChildProcess?
    /// Detached reaper: `run()` suspends until the process exits, so the
    /// child is always reaped (no zombies) even after abrupt disconnects.
    private var runTask: Task<Void, Never>?
    private var nextID: Int = 1

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle (Hermes initialize / session/new)

    /// Start the ACP process and run `initialize`; returns the server info.
    public func start() async throws -> [String: Any] {
        if child == nil {
            var command = Command(
                absolutePath: Path(config.command),
                arguments: config.args)
            command.inheritCurrentEnvironment()
            if let cwd = config.workingDirectory {
                command.workingDirectory = Path(cwd)
            }
            let acp = ChildProcess(command, dataChannels: [
                STDOUT_FILENO: .write(.toParentProcess(stream: .init(), separator: [0x0A])),
                STDERR_FILENO: .write(.toNull),  // stderr is never protocol data
                STDIN_FILENO: .read(.fromParentProcess(stream: .init())),
            ])
            self.child = acp
            // Reap in a detached task: run() suspends for the process's
            // lifetime and returns once it exits (after shutdown signal).
            self.runTask = Task { try? await acp.run(cancellationSignal: SIGTERM) }
        }
        return try await rpc(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true]],
            "clientInfo": ["name": "arc-agent", "version": "1.0"],
        ])
    }

    /// Create a session (Hermes `session/new`).
    public func newSession(instruction: String) async throws -> String {
        let result = try await rpc(method: "session/new", params: [
            "cwd": config.workingDirectory ?? FileManager.default.currentDirectoryPath,
            "mcpServers": [],
        ])
        if let sessionID = result["sessionId"] as? String {
            return sessionID
        }
        if let meta = result["_meta"] as? [String: Any], let mcp = meta["mcpServers"] as? [String: Any] {
            _ = mcp
        }
        // ACP returns the id at top level or inside sessionData.
        if let session = result["session"] as? [String: Any], let id = session["id"] as? String {
            return id
        }
        throw LLMError.decodingError("ACP session/new response has no session id")
    }

    /// Send a user prompt and await the model reply (Hermes `session/prompt`).
    public func prompt(sessionID: String, content: String) async throws -> [String: Any] {
        try await rpc(method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [
                ["type": "text", "text": content],
            ],
        ])
    }

    public func shutdown() async {
        guard let child else { return }
        // Close stdin (child sees EOF) then signal the process group so
        // `run()` unwinds and reaps; await the reaper before returning.
        child.stdin.closeDataChannel()
        try? await child.signal(SIGTERM)
        await runTask?.value
        self.child = nil
        self.runTask = nil
    }

    // MARK: - JSON-RPC plumbing (AsyncBytes — no threads)

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let child else { throw LLMError.networkError("ACP client not started") }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let framed = data + Data([0x0A])
        try await child.stdin.write(Array(framed))

        // ACP responses are newline-framed JSON; SwiftSlash's line channel
        // yields exactly those frames. Requests are strictly sequential per
        // client, so this single-consumer sequence is unambiguous.
        var sawAny = false
        var collectorBytes = 0
        for await chunk in child.stdout {
            for line in chunk {
                sawAny = true
                collectorBytes += line.count
                if collectorBytes > 4_000_000 {
                    throw LLMError.decodingError("ACP response exceeded 4 MB")
                }
                if let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   (json["id"] as? Int) == id {
                    if let error = json["error"] as? [String: Any] {
                        throw LLMError.apiError(statusCode: -32000, message: String(describing: error))
                    }
                    return json["result"] as? [String: Any] ?? [:]
                }
            }
        }
        throw LLMError.decodingError(
            "ACP process closed before responding to \(method)" + (sawAny ? "" : " (no output)")
        )
    }

    // MARK: - LLMClient adapter (maps a prompt to a chat round)

    func asLLMClient() async throws -> ACPChatAdapter {
        _ = try await start()
        return ACPChatAdapter(client: self)
    }
}

/// Bridges an ACP session to the `LLMClient` shape for a single prompt round
/// (Hermes codex_acp path; the ACP protocol is prompt-oriented, so
/// `complete` maps messages → one prompt and returns the final message).
public struct ACPChatAdapter: LLMClient {
    let client: ACPClient
    var sessionID: String?

    public init(client: ACPClient, sessionID: String? = nil) {
        self.client = client
        self.sessionID = sessionID
    }

    public func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        let sid: String
        if let sessionID {
            sid = sessionID
        } else {
            sid = try await client.newSession(instruction: arcAgentSystemPrompt(messages))
        }
        let content = messages.compactMap { $0.content }.joined(separator: "\n\n")
        let result = try await client.prompt(sessionID: sid, content: content)
        // ACP `session/prompt` result carries the reply message.
        let reply = (result["message"] as? [String: Any]) ?? result
        let text = ((reply["content"] as? [Any]) ?? [])
            .compactMap { ($0 as? [String: Any])?["text"] as? String }
            .joined()
        let stopReason = (reply["stopReason"] as? String) ?? "stop"
        return LLMResponse(
            content: text.isEmpty ? nil : text,
            toolCalls: nil,
            finishReason: stopReason == "maxTokens" ? "length" : "stop",
            usage: nil
        )
    }

    public func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await complete(messages: messages, tools: tools)
                    if let content = response.content {
                        continuation.yield(LLMDelta(content: content))
                    }
                    continuation.yield(LLMDelta(content: nil, finishReason: response.finishReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func arcAgentSystemPrompt(_ messages: [Message]) -> String {
        // ACP session instructions: use the first system message if present.
        messages.first(where: { $0.role == .system })?.content ?? "You are arc-agent, a helpful coding agent."
    }
}
