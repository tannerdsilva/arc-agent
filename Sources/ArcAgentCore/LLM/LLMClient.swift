import Foundation

/// A client that communicates with an LLM provider.
///
/// ``LLMClient`` abstracts the API differences between providers. The two
/// primary operations are:
/// - ``complete(messages:tools:)`` — send messages and get a complete response
/// - ``stream(messages:tools:)`` — send messages and get a streaming response
///
/// ## Concurrency
///
/// ``LLMClient`` is ``Sendable``. Implementations must be safe to call from
/// any task. Most implementations are structs with no mutable state.
///
/// ## Design (Protocols First)
///
/// 1. **Protocol** — ``LLMClient`` (this protocol)
/// 2. **Concrete types** — ``OpenAICompatibleClient``, ``AnthropicMessagesClient``
/// 3. **Macros** — Likely none needed; the protocol is the right abstraction
public protocol LLMClient: Sendable {

    /// Send messages to the LLM and get a complete response.
    ///
    /// - Parameters:
    ///   - messages: The conversation history + new message.
    ///   - tools: Optional tool schemas for function calling.
    /// - Returns: The LLM's response, including any tool call requests.
    /// - Throws: ``LLMError`` for API errors, rate limits, auth failures.
    func complete(
        messages: [Message],
        tools: [[String: Any]]?
    ) async throws -> LLMResponse

    /// Send messages to the LLM and stream the response.
    ///
    /// - Parameters:
    ///   - messages: The conversation history + new message.
    ///   - tools: Optional tool schemas for function calling.
    /// - Returns: An async sequence of delta chunks.
    func stream(
        messages: [Message],
        tools: [[String: Any]]?
    ) -> AsyncThrowingStream<LLMDelta, Error>

    /// Send messages with a reasoning-effort request (arc-style levels:
    /// low / medium / high / max). Implementations that support effort send
    /// it; conformers that don't ignore the parameter (default impl).
    func complete(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String?
    ) async throws -> LLMResponse

    func stream(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String?
    ) -> AsyncThrowingStream<LLMDelta, Error>
}

extension LLMClient {
    /// Default reasoning-effort passthrough: ignore the parameter and use
    /// the plain two-argument requirement.
    public func complete(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String?
    ) async throws -> LLMResponse {
        try await complete(messages: messages, tools: tools)
    }

    public func stream(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        stream(messages: messages, tools: tools)
    }
}

// MARK: - Errors

/// Errors that can occur during LLM API calls.
public enum LLMError: Error, Sendable, CustomStringConvertible, LocalizedError {

    /// The API returned an error response.
    case apiError(statusCode: Int, message: String)

    /// Rate limited — retry after the given duration.
    case rateLimited(retryAfter: Int)

    /// Authentication failed.
    case authenticationFailed

    /// The model is unavailable or doesn't exist.
    case modelNotFound(String)

    /// The request timed out.
    case timeout(TimeInterval)

    /// A network error occurred.
    case networkError(String)

    /// The configured endpoint did not answer at all — refused, unroutable, or
    /// silent past the preflight deadline. Distinct from ``networkError`` so a
    /// dead `baseURL` is reported by name instead of as an anonymous transport
    /// failure, and permanent so a retry cycle cannot multiply the wait.
    case endpointUnreachable(endpoint: String, detail: String)

    /// The response could not be parsed.
    case decodingError(String)

    /// The provider returned an empty response (no choices / no content /
    /// no tool calls). Transient by nature — reference treats this as retryable
    /// with a storm guard, not as a permanent failure.
    case emptyResponse

    /// The context length was exceeded — messages need compression.
    case contextLengthExceeded(limit: Int)

    /// The request was rejected due to content policy.
    case contentPolicyViolation(String)

    /// Every surface renders `"\(error)"` (the CLI prints it, the web UI
    /// toasts it). Without this conformance that interpolation bridges to
    /// NSError and prints "LLMError error 5", which names nothing.
    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        case .rateLimited(let retryAfter):
            return "Rate limited. Retry after \(retryAfter)s."
        case .authenticationFailed:
            return "Authentication failed. Check your API key."
        case .modelNotFound(let model):
            return "Model '\(model)' not found or unavailable."
        case .timeout(let interval):
            return "Request timed out after \(interval)s."
        case .networkError(let message):
            return "Network error: \(message)"
        case .endpointUnreachable(let endpoint, let detail):
            return "Cannot reach the model endpoint \(endpoint): \(detail)"
        case .decodingError(let message):
            return "Failed to decode response: \(message)"
        case .emptyResponse:
            return "Provider returned an empty response"
        case .contextLengthExceeded(let limit):
            return "Context length exceeded (limit: \(limit) tokens). Compress history."
        case .contentPolicyViolation(let message):
            return "Content policy violation: \(message)"
        }
    }
}
