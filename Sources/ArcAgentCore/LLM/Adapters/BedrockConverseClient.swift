import Foundation
import AsyncHTTPClient

/// AWS Bedrock Converse API client (Hermes `bedrock_adapter.py`):
/// `messages` with `content` blocks (`text`/`toolUse`/`toolResult`),
/// `system`, `inferenceConfig {maxTokens, temperature}`, and
/// `toolConfig.tools[].toolSpec {name, description, inputSchema}`.
/// Authentication uses AWS SigV4 (env credentials).
public struct BedrockConverseClient: LLMClient {
    public let region: String
    public let signer: AWSV4Signer
    public let model: String
    public let metadata: ModelMetadata
    public let maxTokens: Int
    public let temperature: Double?
    public let transport: WireTransport

    public init(
        region: String,
        signer: AWSV4Signer,
        model: String,
        metadata: ModelMetadata? = nil,
        maxTokens: Int = 8192,
        temperature: Double? = nil,
        httpClient: HTTPClient
    ) {
        self.region = region
        self.signer = signer
        self.model = model
        self.metadata = metadata ?? ModelMetadataRegistry.shared.metadata(for: model, provider: "anthropic")
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.transport = WireTransport(httpClient: httpClient, defaultTimeoutSeconds: 300)
    }

    func endpoint(stream: Bool) -> URL {
        let modelID = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let path = stream ? "/model/\(modelID)/converse-stream" : "/model/\(modelID)/converse"
        return URL(string: "https://bedrock-runtime.\(region).amazonaws.com\(path)")!
    }

    // MARK: - LLMClient

    public func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        let body = try buildConverseRequest(messages: messages, tools: tools)
        let url = endpoint(stream: false)
        let signed = signer.signedHeaders(method: "POST", url: url, payload: body)
        let headers: [String: String] = [
            "Content-Type": "application/json",
            "X-Amz-Date": signed.date,
            "Authorization": signed.authorization,
        ]
        let resp = try await transport.post(url: url.absoluteString, headers: headers, body: body)
        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        guard let json else { throw LLMError.decodingError("Bedrock response is not a JSON object") }
        return try parseConverse(json)
    }

    public func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        let body: Data
        do {
            body = try buildConverseRequest(messages: messages, tools: tools)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = self.endpoint(stream: true)
                    let signed = self.signer.signedHeaders(method: "POST", url: url, payload: body)
                    let headers: [String: String] = [
                        "Content-Type": "application/json",
                        "X-Amz-Date": signed.date,
                        "Authorization": signed.authorization,
                        "Accept": "application/json",
                    ]
                    let resp = try await self.transport.post(url: url.absoluteString, headers: headers, body: body)
                    let text = String(data: resp.body, encoding: .utf8) ?? ""
                    for d in self.parseConverseStream(text) { continuation.yield(d) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Wire translation (Hermes convert_messages_to_converse,
    // convert_tools_to_converse)

    func buildConverseRequest(messages: [Message], tools: [[String: Any]]?) throws -> Data {
        var body: [String: Any] = [
            "modelId": model,
            "inferenceConfig": ["maxTokens": maxTokens] as [String: Any],
        ]
        if let temperature { body["inferenceConfig"] = ["maxTokens": maxTokens, "temperature": temperature] }

        var wireMessages: [[String: Any]] = []
        var system: [[String: Any]] = []
        for message in messages {
            switch message.role.rawValue {
            case "system":
                if let content = message.content { system.append(["text": content]) }
            case "user":
                wireMessages.append(["role": "user", "content": [["text": message.content ?? ""]]])
            case "tool":
                wireMessages.append(["role": "user", "content": [[
                    "toolResult": [
                        "toolUseId": message.toolCallID ?? "",
                        "content": [["text": message.content ?? ""]],
                    ],
                ]]])
            case "assistant":
                var blocks: [[String: Any]] = []
                if let content = message.content, !content.isEmpty {
                    blocks.append(["text": content])
                }
                if let calls = message.toolCalls {
                    for call in calls {
                        var toolUse: [String: Any] = ["toolUseId": call.id, "name": call.function.name]
                        if let parsed = try? JSONSerialization.jsonObject(
                            with: Data(call.function.arguments.utf8)) {
                            toolUse["input"] = parsed
                        }
                        blocks.append(["toolUse": toolUse])
                    }
                }
                wireMessages.append(["role": "assistant", "content": blocks])
            default:
                break
            }
        }
        if !system.isEmpty { body["system"] = system }
        body["messages"] = wireMessages

        if let tools, !tools.isEmpty {
            var specs: [[String: Any]] = []
            for tool in tools {
                let function = tool["function"] as? [String: Any] ?? tool
                specs.append([
                    "toolSpec": [
                        "name": function["name"] as? String ?? "",
                        "description": function["description"] as? String ?? "",
                        "inputSchema": function["parameters"] as? [String: Any] ?? ["type": "object"],
                    ],
                ])
            }
            body["toolConfig"] = ["tools": specs, "toolChoice": ["auto": [:]]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func parseConverse(_ json: [String: Any]) throws -> LLMResponse {
        var content = ""
        var toolCalls: [ToolCall] = []
        let output = json["output"] as? [String: Any]
        let message = output?["message"] as? [String: Any]
        for block in (message?["content"] as? [[String: Any]]) ?? [] {
            if let text = block["text"] as? String { content += text }
            if let toolUse = block["toolUse"] as? [String: Any] {
                let args = (try? JSONSerialization.data(withJSONObject: toolUse["input"] ?? [:]))
                    ?? Data("{}".utf8)
                toolCalls.append(ToolCall(
                    id: toolUse["toolUseId"] as? String ?? "",
                    type: "function",
                    function: ToolCallFunction(
                        name: toolUse["name"] as? String ?? "",
                        arguments: String(data: args, encoding: .utf8) ?? "{}"
                    )
                ))
            }
        }
        let stop = json["stopReason"] as? String
        let rawUsage = json["usage"] as? [String: Any]
        let usage: Usage? = rawUsage.map {
            Usage(
                promptTokens: $0["inputTokens"] as? Int ?? 0,
                completionTokens: $0["outputTokens"] as? Int ?? 0,
                totalTokens: ($0["inputTokens"] as? Int ?? 0) + ($0["outputTokens"] as? Int ?? 0),
                cachedPromptTokens: nil
            )
        }
        return LLMResponse(
            content: content.isEmpty ? nil : content,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            finishReason: Self.mapStopReason(stop),
            usage: usage
        )
    }

    /// Converse streaming uses newline-delimited JSON events
    /// (`content_block_delta` / `message_stop`).
    func parseConverseStream(_ text: String) -> [LLMDelta] {
        var deltas: [LLMDelta] = []
        var content = ""
        var toolAccs: [Int: ToolCallAccumulator] = [:]
        var finish: String?
        for lineS in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineS)
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = json["type"] as? String ?? ""
            switch type {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any] ?? [:]
                if let t = delta["text"] as? String {
                    content += t
                    deltas.append(LLMDelta(content: t))
                }
                if let toolUse = delta["toolUse"] as? [String: Any] {
                    let idx = toolAccs.count
                    let acc = ToolCallAccumulator(
                        id: toolUse["toolUseId"] as? String ?? "",
                        name: toolUse["name"] as? String ?? "",
                        index: idx
                    )
                    toolAccs[idx] = acc
                    if let input = toolUse["input"] {
                        let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                        deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(
                            index: idx, id: acc.id, name: acc.name,
                            arguments: String(data: data, encoding: .utf8) ?? "{}"
                        )]))
                    }
                }
            case "message_stop":
                finish = "stop"
                for acc in toolAccs.values.sorted(by: { $0.index < $1.index }) {
                    deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(
                        index: acc.index, id: acc.id, name: acc.name, arguments: "{}"
                    )]))
                }
            default:
                if let stop = json["stopReason"] as? String { finish = Self.mapStopReason(stop) }
            }
        }
        if let finish { deltas.append(LLMDelta(content: nil, finishReason: finish)) }
        return deltas
    }

    static func mapStopReason(_ reason: String?) -> String? {
        switch reason {
        case "end_turn": return "stop"
        case "tool_use": return "tool_calls"
        case "max_tokens", "max_output_tokens": return "length"
        case "stop_sequence": return "stop"
        default: return reason == nil ? nil : reason
        }
    }
}
