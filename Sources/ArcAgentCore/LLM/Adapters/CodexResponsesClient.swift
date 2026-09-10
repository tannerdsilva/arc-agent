import Foundation
import AsyncHTTPClient

/// OpenAI Responses API client (Hermes `codex_responses_adapter.py`): the
/// `responses` endpoint used for Codex/GPT-5.x models — `instructions` +
/// `input` item arrays, typed function tools, and event-based streaming.
public struct CodexResponsesClient: LLMClient {
    public let baseURL: URL      // e.g. https://api.openai.com/v1
    public let apiKey: String
    public let model: String
    public let metadata: ModelMetadata
    public let maxOutputTokens: Int?
    public let temperature: Double?
    public let transport: WireTransport
    public let reasoningPayload: [String: Any]?

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        metadata: ModelMetadata? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        reasoningEffort: String? = nil,
        httpClient: HTTPClient
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.metadata = metadata ?? ModelMetadataRegistry.shared.metadata(for: model, provider: "openai")
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        var payload: [String: Any]?
        if let effort = reasoningEffort, !effort.isEmpty {
            payload = ModelMetadataRegistry.shared.thinkingPayload(effort: effort, metadata: self.metadata)
            if payload?["reasoning_effort"] == nil {
                payload = ["reasoning": ["effort": effort]]
            }
        }
        self.reasoningPayload = payload
        self.transport = WireTransport(httpClient: httpClient, defaultTimeoutSeconds: 300)
    }

    // MARK: - LLMClient

    public func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        let body = try buildRequest(messages: messages, tools: tools, stream: false)
        let resp = try await transport.post(
            url: baseURL.appendingPathComponent("responses").absoluteString,
            headers: Self.headers(apiKey: apiKey),
            body: body
        )
        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        guard let json else { throw LLMError.decodingError("Responses response is not a JSON object") }
        return try parseComplete(json)
    }

    public func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        let request: Data
        do {
            request = try buildRequest(messages: messages, tools: tools, stream: true)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var headers = Self.headers(apiKey: self.apiKey)
                    headers["Accept"] = "text/event-stream"
                    let resp = try await self.transport.post(
                        url: self.baseURL.appendingPathComponent("responses").absoluteString,
                        headers: headers, body: request
                    )
                    let text = String(data: resp.body, encoding: .utf8) ?? ""
                    for d in self.parseStream(text) { continuation.yield(d) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request building (Hermes _chat_messages_to_responses_input)

    func buildRequest(messages: [Message], tools: [[String: Any]]?, stream: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
        ]
        if let maxOutputTokens { body["max_output_tokens"] = maxOutputTokens }
        if let temperature { body["temperature"] = temperature }
        if let reasoningPayload { body.merge(reasoningPayload) { _, new in new } }

        // instructions = last system message (Hermes: instructions carries the
        // system prompt; input holds the conversation).
        var input: [[String: Any]] = []
        var instructions: String?
        for message in messages {
            switch message.role.rawValue {
            case "system":
                if let content = message.content {
                    instructions = instructions.map { $0 + "\n" + content } ?? content
                }
            case "user":
                var item: [String: Any] = ["type": "message", "role": "user"]
                if let content = message.content { item["content"] = content }
                input.append(item)
            case "assistant":
                var item: [String: Any] = ["type": "message", "role": "assistant"]
                var contentArr: [[String: Any]] = []
                if let content = message.content, !content.isEmpty {
                    contentArr.append(["type": "output_text", "text": content])
                }
                if let calls = message.toolCalls {
                    for call in calls {
                        contentArr.append([
                            "type": "function_call",
                            "call_id": call.id,
                            "name": call.function.name,
                            "arguments": call.function.arguments,
                        ])
                    }
                }
                if !contentArr.isEmpty { item["content"] = contentArr }
                input.append(item)
            case "tool":
                input.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallID ?? "",
                    "output": message.content ?? "",
                ])
            default:
                break
            }
        }
        if let instructions, !instructions.isEmpty { body["instructions"] = instructions }
        body["input"] = input

        if let tools, !tools.isEmpty {
            var typed: [[String: Any]] = []
            for tool in tools {
                let function = tool["function"] as? [String: Any] ?? tool
                typed.append([
                    "type": "function",
                    "name": function["name"] as? String ?? "",
                    "description": function["description"] as? String ?? "",
                    "parameters": function["parameters"] as? [String: Any] ?? ["type": "object"],
                ])
            }
            body["tools"] = typed
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func headers(apiKey: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)",
        ]
    }

    // MARK: - Parsing

    func parseComplete(_ json: [String: Any]) throws -> LLMResponse {
        var content = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        let status = json["status"] as? String

        for raw in (json["output"] as? [[String: Any]]) ?? [] {
            let type = raw["type"] as? String ?? ""
            if type == "message" {
                for c in (raw["content"] as? [[String: Any]]) ?? [] {
                    if let text = c["text"] as? String {
                        if c["type"] as? String == "output_text" { content += text }
                        if c["type"] as? String == "reasoning" { reasoning += text }
                    }
                }
            } else if type == "function_call" {
                toolCalls.append(ToolCall(
                    id: raw["call_id"] as? String ?? "",
                    type: "function",
                    function: ToolCallFunction(
                        name: raw["name"] as? String ?? "",
                        arguments: raw["arguments"] as? String ?? "{}"
                    )
                ))
            }
        }
        let finishReason = Self.mapStatus(status ?? "completed")
        let usage: Usage? = nil // Responses reports usage events in-stream; callers may attach later.
        return LLMResponse(
            content: content.isEmpty ? nil : content,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            finishReason: finishReason,
            usage: usage
        )
    }

    /// Responses streaming: `response.output_text.delta`,
    /// `response.output_item.added` (function_call), `response.completed`.
    func parseStream(_ text: String) -> [LLMDelta] {
        var deltas: [LLMDelta] = []
        var currentCallID: String?
        var currentCallName: String?
        var args = ""
        for lineS in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineS)
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = json["type"] as? String ?? ""
            switch type {
            case "response.output_text.delta":
                if let d = json["delta"] as? String {
                    deltas.append(LLMDelta(content: d))
                }
            case "response.reasoning_summary_text.delta":
                if let d = json["delta"] as? String {
                    deltas.append(LLMDelta(content: nil, reasoning: d))
                }
            case "response.output_item.added":
                if let item = json["item"] as? [String: Any],
                   item["type"] as? String == "function_call" {
                    currentCallID = item["call_id"] as? String
                    currentCallName = item["name"] as? String
                    args = ""
                    deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(
                        index: 0, id: currentCallID, name: currentCallName, arguments: ""
                    )]))
                }
            case "response.function_call_arguments.delta":
                if let d = json["delta"] as? String {
                    args += d
                    deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(index: 0, id: nil, name: nil, arguments: d)]))
                }
            case "response.completed":
                let status = (json["response"] as? [String: Any])?["status"] as? String ?? "completed"
                deltas.append(LLMDelta(content: nil, finishReason: Self.mapStatus(status)))
                if let id = currentCallID, let name = currentCallName {
                    deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(index: 0, id: id, name: name, arguments: args)]))
                }
                return deltas
            case "response.failed", "response.incomplete":
                deltas.append(LLMDelta(content: nil, finishReason: Self.mapStatus("incomplete")))
                return deltas
            default:
                break
            }
        }
        return deltas
    }

    static func mapStatus(_ status: String) -> String? {
        switch status {
        case "completed": return "stop"
        case "incomplete": return "length"
        case "failed": return "content_filter"
        default: return nil
        }
    }
}
