import Foundation
import AsyncHTTPClient
import NIO
import Logging

/// An LLM client for OpenAI-compatible chat completion APIs.
///
/// Supports the vast majority of LLM providers (OpenAI, OpenRouter, DeepSeek,
/// xAI, MiniMax, Together, Groq, etc.) since they all implement the same
/// `/v1/chat/completions` endpoint with the same request/response format.
///
/// ## Lifecycle
///
/// The ``HTTPClient`` is provided at initialization — it is not owned by this
/// type. The caller (typically an ``ArcAgent`` service) is responsible for
/// the HTTP client's lifecycle via Swift Service Lifecycle.
///
/// ## Usage
/// ```swift
/// let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
/// defer { try? await httpClient.shutdown() }
///
/// let client = OpenAICompatibleClient(
///     baseURL: URL(string: "https://api.openai.com/v1")!,
///     apiKey: "...",
///     model: "gpt-4o",
///     httpClient: httpClient
/// )
/// let response = try await client.complete(messages: [...], tools: nil)
/// ```
public struct OpenAICompatibleClient: LLMClient {

    /// The base URL of the API (e.g. `https://api.openai.com/v1`).
    public let baseURL: URL

    /// The API key for authentication.
    public let apiKey: String

    /// The model to use for completions.
    public let model: String

    /// Optional default parameters sent with every request.
    public var defaultParameters: RequestParameters

    /// Additional HTTP headers sent with every request.
    public var additionalHeaders: [String: String]

    /// The HTTP client used for all requests.
    ///
    /// Not owned by this type — lifecycle is managed by the caller.
    private let httpClient: HTTPClient

    /// Create an OpenAI-compatible client.
    ///
    /// - Parameters:
    ///   - baseURL: The API base URL.
    ///   - apiKey: The API key.
    ///   - model: The model identifier.
    ///   - httpClient: The HTTP client to use. Lifecycle managed by the caller.
    ///   - defaultParameters: Optional default request parameters.
    ///   - additionalHeaders: Optional additional HTTP headers.
    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        httpClient: HTTPClient,
        defaultParameters: RequestParameters = RequestParameters(),
        additionalHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.httpClient = httpClient
        self.defaultParameters = defaultParameters
        self.additionalHeaders = additionalHeaders
    }

    // MARK: - LLMClient

    /// Plain two-argument form (protocol witness): delegates to the
    /// reasoning-effort variant with no effort.
    public func complete(
        messages: [Message],
        tools: [[String: Any]]?
    ) async throws -> LLMResponse {
        try await complete(messages: messages, tools: tools, reasoningEffort: nil)
    }

    public func complete(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String? = nil
    ) async throws -> LLMResponse {
        let body = try buildRequestBody(messages: messages, tools: tools, stream: false, reasoningEffort: reasoningEffort)
        let response = try await sendRequest(body: body)

        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw LLMError.decodingError("Response is not a JSON object")
        }

        return try parseResponse(json: json)
    }

    /// Plain two-argument form (protocol witness): delegates to the
    /// reasoning-effort variant with no effort.
    public func stream(
        messages: [Message],
        tools: [[String: Any]]?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        stream(messages: messages, tools: tools, reasoningEffort: nil)
    }

    public func stream(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String? = nil
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        // Serialize tools to Data before entering the closure to avoid
        // capturing non-Sendable types across a Task boundary.
        let toolsData: Data?
        if let tools {
            toolsData = try? JSONSerialization.data(withJSONObject: tools)
        } else {
            toolsData = nil
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let body: Data
                    if let toolsData {
                        guard let decoded = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]] else {
                            throw LLMError.decodingError("Failed to re-decode tools data")
                        }
                        body = try buildRequestBody(messages: messages, tools: decoded, stream: true, reasoningEffort: reasoningEffort)
                    } else {
                        body = try buildRequestBody(messages: messages, tools: nil, stream: true, reasoningEffort: reasoningEffort)
                    }
                    try await streamRequest(body: body, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request Building

    private func buildRequestBody(
        messages: [Message],
        tools: [[String: Any]]?,
        stream: Bool,
        reasoningEffort: String? = nil
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(encodeMessage),
            "stream": stream,
        ]

        // Merge default parameters
        if let temp = defaultParameters.temperature { body["temperature"] = temp }
        if let maxTokens = defaultParameters.maxTokens { body["max_tokens"] = maxTokens }
        if let topP = defaultParameters.topP { body["top_p"] = topP }
        if let stop = defaultParameters.stop { body["stop"] = stop }
        if let presencePenalty = defaultParameters.presencePenalty { body["presence_penalty"] = presencePenalty }
        if let frequencyPenalty = defaultParameters.frequencyPenalty { body["frequency_penalty"] = frequencyPenalty }
        // Reasoning effort (Hermes parity: off omits the field; low/medium/
        // high/max are sent through for providers that honor reasoning_effort).
        if let effort = reasoningEffort, !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
        // Ask for usage in stream chunks: OpenAI-compatible servers only emit
        // a final `usage` block when `stream_options.include_usage` is set.
        if stream {
            body["stream_options"] = ["include_usage": true]
        }

        // Attach tools if provided
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    private func encodeMessage(_ message: Message) -> [String: Any] {
        var dict: [String: Any] = ["role": message.role.rawValue]

        if let content = message.content {
            dict["content"] = content
        }

        if let name = message.name {
            dict["name"] = name
        }

        if let toolCalls = message.toolCalls {
            dict["tool_calls"] = toolCalls.map { tc in
                [
                    "id": tc.id,
                    "type": tc.type,
                    "function": [
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    ],
                ] as [String: Any]
            }
        }

        if let toolCallID = message.toolCallID {
            dict["tool_call_id"] = toolCallID
        }

        return dict
    }

    // MARK: - HTTP

    private func sendRequest(body: Data) async throws -> Data {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        for (key, value) in additionalHeaders {
            request.headers.add(name: key, value: value)
        }
        request.body = .bytes(body)

        let response = try await httpClient.execute(request, timeout: .seconds(120))

        // Check for error status codes
        guard (200...299).contains(response.status.code) else {
            let bodyData = try? await response.body.collect(upTo: 10_000)
            let bodyString = bodyData.flatMap { String(data: Data($0.readableBytesView), encoding: .utf8) } ?? "Unknown error"
            // Observability: log the offending status + body so misclassified
            // errors are diagnosable without a server round-trip.
            Logger(label: "com.arc-agent.llm").error("LLM HTTP \(response.status.code) from \(baseURL): \(bodyString.prefix(500))")

            if response.status.code == 429 {
                let retryAfter = response.headers.first(name: "retry-after").flatMap(Int.init) ?? 30
                throw LLMError.rateLimited(retryAfter: retryAfter)
            }
            if response.status.code == 401 {
                throw LLMError.authenticationFailed
            }

            // Detect context length exceeded from error body
            if response.status.code == 400, bodyString.contains("context_length") || bodyString.contains("maximum context") || bodyString.contains("token limit") {
                // Try to extract the limit from the error message
                let limit = extractContextLimit(from: bodyString)
                throw LLMError.contextLengthExceeded(limit: limit)
            }

            // Detect content policy violations
            if response.status.code == 400, bodyString.contains("content_filter") || bodyString.contains("content_policy") || bodyString.contains("safety") {
                throw LLMError.contentPolicyViolation(bodyString)
            }

            throw LLMError.apiError(statusCode: Int(response.status.code), message: bodyString)
        }

        var collected = Data()
        for try await chunk in response.body {
            collected.append(contentsOf: chunk.readableBytesView)
        }
        return collected
    }

    private func streamRequest(
        body: Data,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "Accept", value: "text/event-stream")
        for (key, value) in additionalHeaders {
            request.headers.add(name: key, value: value)
        }
        request.body = .bytes(body)

        let response = try await httpClient.execute(request, timeout: .seconds(300))

        guard response.status.code == 200 else {
            let bodyData = try? await response.body.collect(upTo: 10_000)
            let bodyString = bodyData.flatMap { String(data: Data($0.readableBytesView), encoding: .utf8) } ?? "Unknown error"
            continuation.finish(throwing: LLMError.apiError(statusCode: Int(response.status.code), message: bodyString))
            return
        }

        var buffer = ""
        for try await chunk in response.body {
            let text = String(buffer: chunk)
            buffer += text

            // Process complete SSE events
            while let lineEnd = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<lineEnd])
                buffer = String(buffer[buffer.index(after: lineEnd)...])

                guard line.hasPrefix("data: ") else { continue }
                let data = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)

                // SSE stream end
                guard data != "[DONE]" else {
                    continuation.finish()
                    return
                }

                guard let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                else { continue }

                // Some servers send a trailing chunk carrying only `usage`
                // (no choices) — surface it so consumers can account tokens.
                let usage = (json["usage"] as? [String: Any]).map { raw in
                    Usage(
                        promptTokens: raw["prompt_tokens"] as? Int ?? 0,
                        completionTokens: raw["completion_tokens"] as? Int ?? 0,
                        totalTokens: raw["total_tokens"] as? Int ?? 0
                    )
                }
                guard let choice = (json["choices"] as? [[String: Any]])?.first else {
                    if let usage {
                        continuation.yield(LLMDelta(content: nil, usage: usage))
                    }
                    continue
                }

                let rawDelta = choice["delta"] as? [String: Any] ?? [:]
                let finishReason = choice["finish_reason"] as? String

                let content = rawDelta["content"] as? String
                // DeepSeek streams chain-of-thought as `reasoning_content`;
                // some OpenAI-compatible servers use `reasoning`.
                let reasoning = rawDelta["reasoning_content"] as? String
                    ?? rawDelta["reasoning"] as? String
                let toolCallDeltas = (rawDelta["tool_calls"] as? [[String: Any]])?.map { tcDelta -> ToolCallDelta in
                    let index = tcDelta["index"] as? Int ?? 0
                    let id = tcDelta["id"] as? String
                    let function = tcDelta["function"] as? [String: Any]
                    return ToolCallDelta(
                        index: index,
                        id: id,
                        name: function?["name"] as? String,
                        arguments: function?["arguments"] as? String
                    )
                }

                let delta = LLMDelta(
                    content: content,
                    toolCalls: toolCallDeltas,
                    finishReason: finishReason,
                    reasoning: reasoning,
                    usage: usage
                )
                continuation.yield(delta)
            }
        }
        continuation.finish()
    }

    // MARK: - Response Parsing

    private func parseResponse(json: [String: Any]) throws -> LLMResponse {
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first
        else {
            throw LLMError.decodingError("Missing 'choices' in response")
        }

        let message = choice["message"] as? [String: Any] ?? [:]
        let finishReason = choice["finish_reason"] as? String
        let content = message["content"] as? String

        let toolCalls: [ToolCall]?
        if let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            toolCalls = rawToolCalls.map { tc in
                let function = tc["function"] as? [String: Any] ?? [:]
                return ToolCall(
                    id: tc["id"] as? String ?? "",
                    type: tc["type"] as? String ?? "function",
                    function: ToolCallFunction(
                        name: function["name"] as? String ?? "",
                        arguments: function["arguments"] as? String ?? "{}"
                    )
                )
            }
        } else {
            toolCalls = nil
        }

        let usage: Usage?
        if let rawUsage = json["usage"] as? [String: Any] {
            usage = Usage(
                promptTokens: rawUsage["prompt_tokens"] as? Int ?? 0,
                completionTokens: rawUsage["completion_tokens"] as? Int ?? 0,
                totalTokens: rawUsage["total_tokens"] as? Int ?? 0
            )
        } else {
            usage = nil
        }

        return LLMResponse(
            content: content,
            toolCalls: toolCalls,
            finishReason: finishReason,
            usage: usage
        )
    }
}

// MARK: - Request Parameters

/// Optional parameters sent with every LLM request.
public struct RequestParameters: Sendable {
    /// Sampling temperature (0.0 - 2.0).
    public var temperature: Double?
    /// Maximum tokens to generate.
    public var maxTokens: Int?
    /// Nucleus sampling threshold.
    public var topP: Double?
    /// Stop sequences.
    public var stop: [String]?
    /// Presence penalty.
    public var presencePenalty: Double?
    /// Frequency penalty.
    public var frequencyPenalty: Double?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        stop: [String]? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.stop = stop
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
    }
}

/// Extract the context token limit from an error message.
/// Looks for patterns like "maximum context length is 128000" or "limit of 64000".
private func extractContextLimit(from message: String) -> Int {
    // Scan for number patterns after known keywords
    let keywords = ["maximum context length is ", "limit of ", "maximum of "]
    for keyword in keywords {
        if let range = message.range(of: keyword) {
            let after = message[range.upperBound...]
            var digits = ""
            for ch in after {
                if ch.isNumber { digits.append(ch) }
                else { break }
            }
            if let limit = Int(digits) {
                return limit
            }
        }
    }
    return 128_000  // Default fallback
}
