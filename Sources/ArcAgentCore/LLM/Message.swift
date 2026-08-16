/// A message in a conversation with an LLM.
///
/// Mirrors the OpenAI Chat Completions message format. Each message has a
/// ``Role`` and optional content. Assistant messages may also carry tool call
/// requests, and tool messages carry the result of a tool execution.
public struct Message: Sendable, Codable, Equatable {

    /// The role of the message author.
    public enum Role: String, Sendable, Codable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    /// The role of the message author.
    public let role: Role

    /// The text content of the message. `nil` for tool call requests.
    public let content: String?

    /// The name of the tool that produced this result (tool role only).
    public let name: String?

    /// Tool call requests from the assistant.
    public let toolCalls: [ToolCall]?

    /// The ID of the tool call this message is responding to (tool role only).
    public let toolCallID: String?

    public init(
        role: Role,
        content: String? = nil,
        name: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// A tool call request from the LLM.
public struct ToolCall: Sendable, Codable, Equatable {

    /// The ID of this tool call (used to match results).
    public let id: String

    /// The type of tool call (always "function" for OpenAI-compatible APIs).
    public let type: String

    /// The function details.
    public let function: ToolCallFunction

    public init(id: String, type: String = "function", function: ToolCallFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

/// The function details of a tool call.
public struct ToolCallFunction: Sendable, Codable, Equatable {

    /// The name of the tool to call.
    public let name: String

    /// The arguments as a JSON string.
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

/// Usage statistics from an LLM response.
public struct Usage: Sendable, Codable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

/// The response from an LLM call.
public struct LLMResponse: Sendable {

    /// The text content of the response. `nil` if the response only contains tool calls.
    public let content: String?

    /// Tool call requests, if any.
    public let toolCalls: [ToolCall]?

    /// The reason the generation finished.
    public let finishReason: String?

    /// Usage statistics, if provided by the API.
    public let usage: Usage?

    public init(
        content: String?,
        toolCalls: [ToolCall]? = nil,
        finishReason: String? = nil,
        usage: Usage? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// A delta chunk from a streaming LLM response.
public struct LLMDelta: Sendable {
    /// The content delta.
    public let content: String?
    /// Partial tool call deltas.
    public let toolCalls: [ToolCallDelta]?
    /// The finish reason, if this is the final chunk.
    public let finishReason: String?

    public init(content: String?, toolCalls: [ToolCallDelta]? = nil, finishReason: String? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }
}

/// A partial tool call delta from a streaming response.
public struct ToolCallDelta: Sendable {
    /// The index of this tool call in the array.
    public let index: Int
    /// The tool call ID (only on the first delta for each call).
    public let id: String?
    /// The function name delta.
    public let name: String?
    /// The arguments delta (partial JSON string).
    public let arguments: String?

    public init(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
