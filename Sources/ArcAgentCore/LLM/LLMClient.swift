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
}

// MARK: - Errors

/// Errors that can occur during LLM API calls.
public enum LLMError: Error, Sendable, CustomStringConvertible {

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

    /// The response could not be parsed.
    case decodingError(String)

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
        case .decodingError(let message):
            return "Failed to decode response: \(message)"
        }
    }
}
