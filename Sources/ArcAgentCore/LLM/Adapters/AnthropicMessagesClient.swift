import Foundation
import AsyncHTTPClient

/// Anthropic Messages API client — wire translator mirroring Hermes
/// `anthropic_adapter.py`: OpenAI-format messages in, Anthropic
/// content blocks out, with `cache_control` markers, adaptive-thinking
/// `output_config.effort`, tool-result blocks, and stream event mapping.
public struct AnthropicMessagesClient: LLMClient {
    public let baseURL: URL            // e.g. https://api.anthropic.com/v1
    public let apiKey: String
    public let model: String
    public let metadata: ModelMetadata
    public let maxTokens: Int
    public let temperature: Double?
    public let transport: WireTransport
    public let cacheTTL: String

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        metadata: ModelMetadata? = nil,
        maxTokens: Int = 8192,
        temperature: Double? = nil,
        httpClient: HTTPClient,
        cacheTTL: String = PromptCachePlan.defaultTTL
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.metadata = metadata ?? ModelMetadataRegistry.shared.metadata(for: model, provider: "anthropic")
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.transport = WireTransport(httpClient: httpClient, defaultTimeoutSeconds: 300)
        self.cacheTTL = cacheTTL
    }

    // MARK: - LLMClient

    public func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        let request = try buildRequest(messages: messages, tools: tools, stream: false)
        let resp = try await transport.post(
            url: baseURL.appendingPathComponent("messages").absoluteString,
            headers: Self.headers(apiKey: apiKey),
            body: request
        )
        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        guard let json else { throw LLMError.decodingError("Anthropic response is not a JSON object") }
        return try parseResponse(json)
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
                    let url = baseURL.appendingPathComponent("messages").absoluteString
                    var headers = Self.headers(apiKey: apiKey)
                    headers["Accept"] = "text/event-stream"
                    let resp = try await transport.post(url: url, headers: headers, body: request)
                    let text = String(data: resp.body, encoding: .utf8) ?? ""
                    var deltas: [LLMDelta] = []
                    var toolAccumulators: [Int: ToolCallAccumulator] = [:]
                    var content = ""
                    var reasoning = ""
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        let l = String(line)
                        guard l.hasPrefix("data: ") else { continue }
                        let payload = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        switch event["type"] as? String {
                        case "message_start":
                            if let usage = event["message"] as? [String: Any],
                               let raw = usage["usage"] as? [String: Any] {
                                deltas.append(LLMDelta(content: nil, usage: Self.parseUsage(raw)))
                            }
                        case "content_block_start":
                            if let block = event["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use",
                               let index = event["index"] as? Int {
                                let acc = ToolCallAccumulator(
                                    id: block["id"] as? String ?? "",
                                    name: block["name"] as? String ?? "",
                                    index: index
                                )
                                toolAccumulators[index] = acc
                            }
                        case "content_block_delta":
                            guard let index = event["index"] as? Int,
                                  let delta = event["delta"] as? [String: Any] else { continue }
                            switch delta["type"] as? String {
                            case "text_delta":
                                if let t = delta["text"] as? String {
                                    content += t
                                    deltas.append(LLMDelta(content: t))
                                }
                            case "thinking_delta":
                                if let t = delta["thinking"] as? String {
                                    reasoning += t
                                    deltas.append(LLMDelta(content: nil, reasoning: t))
                                }
                            case "input_json_delta":
                                if let t = delta["partial_json"] as? String,
                                   var acc = toolAccumulators[index] {
                                    acc.arguments += t
                                    toolAccumulators[index] = acc
                                    deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(index: index, id: nil, name: nil, arguments: t)]))
                                }
                            default: break
                            }
                        case "content_block_stop":
                            if var acc = toolAccumulators[event["index"] as? Int ?? -1] {
                                acc.final = true
                                toolAccumulators[event["index"] as? Int ?? -1] = acc
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any],
                               let stop = delta["stop_reason"] as? String {
                                deltas.append(LLMDelta(content: nil, finishReason: Self.mapStopReason(stop)))
                            }
                            if let usage = event["usage"] as? [String: Any] {
                                deltas.append(LLMDelta(content: nil, usage: Self.parseUsage(usage)))
                            }
                        case "message_stop":
                            // Emit complete tool calls on the final delta so the
                            // caller can merge by index.
                            for acc in toolAccumulators.values.sorted(by: { $0.index < $1.index }) {
                                deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(
                                    index: acc.index,
                                    id: acc.id,
                                    name: acc.name,
                                    arguments: acc.arguments
                                )]))
                            }
                            for d in deltas { continuation.yield(d) }
                            continuation.finish()
                            return
                        default: break
                        }
                    }
                    // Event stream ended without message_stop (truncated).
                    if !deltas.isEmpty {
                        let hasFinish = deltas.contains { $0.finishReason != nil }
                        if !hasFinish {
                            deltas.append(LLMDelta(content: nil, finishReason: "length"))
                        }
                        for d in deltas { continuation.yield(d) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request building

    func buildRequest(messages: [Message], tools: [[String: Any]]?, stream: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
        ]
        if let temperature { body["temperature"] = temperature }
        // Adaptive-thinking effort applied via thinkingPayload when configured.
        if let effortPayload = self.thinkingPayload {
            body.merge(effortPayload) { _, new in new }
        }

        let plan = PromptCachePlan.plan(
            messages: encodeMessages(messages, cacheTTL: cacheTTL),
            tools: convertTools(tools ?? [], cacheTTL: cacheTTL),
            cacheTTL: cacheTTL,
            staticSystemPrefix: self.staticSystemPrefix
        )
        var systemBlocks: [[String: Any]] = []
        var wireMessages: [[String: Any]] = []
        for msg in plan.messages {
            let role = msg["role"] as? String ?? ""
            if role == "system" {
                let content = msg["content"]
                if let text = content as? String {
                    systemBlocks.append(["type": "text", "text": text])
                } else if let blocks = content as? [[String: Any]] {
                    systemBlocks.append(contentsOf: blocks)
                }
                continue
            }
            wireMessages.append(msg)
        }
        if !systemBlocks.isEmpty {
            body["system"] = systemBlocks
        }
        if !wireMessages.isEmpty { body["messages"] = wireMessages }
        if !plan.tools.isEmpty {
            body["tools"] = plan.tools
            body["tool_choice"] = ["type": "auto"]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Encode `[Message]` → Anthropic wire messages (roles user/assistant,
    /// tool results as `tool_result` blocks, tool calls as `tool_use`
    /// blocks), with cache markers applied by `PromptCachePlan`.
    func encodeMessages(_ messages: [Message], cacheTTL: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            let role = message.role.rawValue
            if role == "system" {
                out.append(["role": "system", "content": message.content ?? ""])
                continue
            }
            if role == "tool" {
                let content: [Any] = [
                    ["type": "tool_result", "tool_use_id": Self.sanitizeToolID(message.toolCallID ?? ""),
                     "content": message.content ?? ""]
                ]
                let m: [String: Any] = ["role": "user", "content": content]
                out.append(m)
                continue
            }
            if role == "assistant" {
                var blocks: [[String: Any]] = []
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    blocks.append(["type": "thinking", "thinking": reasoning, "signature": ""])
                }
                if let content = message.content, !content.isEmpty {
                    blocks.append(["type": "text", "text": content])
                }
                if let calls = message.toolCalls, !calls.isEmpty {
                    for call in calls {
                        var block: [String: Any] = [
                            "type": "tool_use",
                            "id": Self.sanitizeToolID(call.id),
                            "name": call.function.name,
                        ]
                        if let args = try? JSONSerialization.jsonObject(
                            with: Data(call.function.arguments.utf8)) as? [String: Any] {
                            block["input"] = args
                        } else {
                            block["input"] = [:]
                        }
                        blocks.append(block)
                    }
                }
                out.append(["role": "assistant", "content": blocks])
                continue
            }
            // user
            var blocks: [[String: Any]] = []
            if let content = message.content, !content.isEmpty {
                // OpenAI image parts: [{"type":"image_url","image_url":{...}}]
                if let parts = try? JSONSerialization.jsonObject(
                    with: Data(content.utf8)) as? [[String: Any]],
                   parts.contains(where: { ($0["type"] as? String) == "image_url" }) {
                    for part in parts {
                        if part["type"] as? String == "image_url",
                           let url = (part["image_url"] as? [String: Any])?["url"] as? String {
                            blocks.append([
                                "type": "image",
                                "source": [
                                    "type": url.hasPrefix("data:") ? "base64" : "url",
                                    (url.hasPrefix("data:") ? "media_type" : "url"): self.imageSourceValue(url),
                                ],
                            ])
                        } else if let text = part["text"] as? String {
                            blocks.append(["type": "text", "text": text])
                        }
                    }
                } else {
                    blocks.append(["type": "text", "text": content])
                }
            }
            out.append(["role": "user", "content": blocks])
        }
        return out
    }

    private func imageSourceValue(_ url: String) -> Any {
        if let comma = url.firstIndex(of: ",") {
            return String(url[url.index(after: comma)...])
        }
        return url
    }

    /// Anthropic requires tool ids to match `^[a-zA-Z0-9_-]{1,64}$`; Hermes
    /// `_sanitize_tool_id` takes the last `~`-separated segment, then strips
    /// invalid characters.
    static func sanitizeToolID(_ id: String) -> String {
        var candidate = id
        if let idx = candidate.lastIndex(of: "~") {
            candidate = String(candidate[candidate.index(after: idx)...])
        }
        let cleaned = candidate.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(cleaned.prefix(64))
    }

    /// Convert OpenAI tool schema to Anthropic `input_schema` (with
    /// `cache_control` forwarded on the last tool, Hermes
    /// `convert_tools_to_anthropic`).
    func convertTools(_ tools: [[String: Any]], cacheTTL: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for tool in tools {
            let function = tool["function"] as? [String: Any] ?? tool
            let name = function["name"] as? String ?? ""
            let description = function["description"] as? String ?? ""
            let params = function["parameters"] as? [String: Any] ?? ["type": "object"]
            var t: [String: Any] = [
                "name": name,
                "description": description,
                "input_schema": normalizedInputSchema(params),
            ]
            if let cc = tool["cache_control"] as? [String: Any] {
                t["cache_control"] = cc
            }
            out.append(t)
        }
        // Hermes forwards cache_control on the LAST tool to cache the schema.
        if !out.isEmpty, let cc = out.last?["cache_control"] {
            var last = out[out.count - 1]
            last["cache_control"] = cc
            out[out.count - 1] = last
        }
        return out
    }

    /// Normalize an OpenAI JSON-schema to Anthropic-friendly input_schema
    /// (Hermes `_normalize_tool_input_schema`): wrap bare `type`-less
    /// objects, ensure `type: object`, and strip `additionalProperties`
    /// quirks Anthropic rejects.
    func normalizedInputSchema(_ params: [String: Any]) -> [String: Any] {
        var schema = params
        if schema["type"] == nil { schema["type"] = "object" }
        if schema["type"] as? String != "object" {
            schema = ["type": "object", "properties": [:]]
        }
        return schema
    }

    // MARK: - Response parsing

    static func parseUsage(_ raw: [String: Any]) -> Usage {
        let cacheRead = raw["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = raw["cache_creation_input_tokens"] as? Int ?? 0
        let input = raw["input_tokens"] as? Int ?? 0
        let output = raw["output_tokens"] as? Int ?? 0
        return Usage(
            promptTokens: input + cacheRead + cacheWrite,
            completionTokens: output,
            totalTokens: input + cacheRead + cacheWrite + output,
            cachedPromptTokens: cacheRead > 0 ? cacheRead : nil
        )
    }

    func parseResponse(_ json: [String: Any]) throws -> LLMResponse {
        var content = ""
        var toolCalls: [ToolCall] = []
        var reasoning = ""
        for block in (json["content"] as? [[String: Any]]) ?? [] {
            switch block["type"] as? String {
            case "text":
                content += (block["text"] as? String ?? "")
            case "thinking":
                reasoning += (block["thinking"] as? String ?? "")
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] ?? [:]
                let argsData = try? JSONSerialization.data(withJSONObject: input)
                toolCalls.append(ToolCall(
                    id: id,
                    type: "function",
                    function: ToolCallFunction(name: name, arguments: String(data: argsData ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
                ))
            default: break
            }
        }
        let usage = (json["usage"] as? [String: Any]).map(Self.parseUsage)
        return LLMResponse(
            content: content.isEmpty ? nil : content,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            finishReason: Self.mapStopReason(json["stop_reason"] as? String ?? "end_turn"),
            usage: usage
        )
    }

    static func mapStopReason(_ reason: String) -> String {
        switch reason {
        case "end_turn": return "stop"
        case "tool_use", "tool_uses": return "tool_calls"
        case "max_tokens": return "length"
        case "stop_sequence": return "stop"
        default: return reason.isEmpty ? "stop" : reason
        }
    }

    static func headers(apiKey: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
    }

    // MARK: - Optional configuration hooks

    public var thinkingPayload: [String: Any]?
    public var staticSystemPrefix: String?

    public func with(thinkingEffort: String?) -> AnthropicMessagesClient {
        var client = self
        if let effort = thinkingEffort, !effort.isEmpty {
            client.thinkingPayload = ModelMetadataRegistry.shared.thinkingPayload(effort: effort, metadata: metadata)
        }
        return client
    }
}

struct ToolCallAccumulator {
    var id: String
    var name: String
    var index: Int
    var arguments: String = ""
    var final: Bool = false
}
