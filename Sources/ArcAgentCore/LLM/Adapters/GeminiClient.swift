import Foundation
import AsyncHTTPClient

/// Google Gemini native API client (Hermes `gemini_native_adapter.py`):
/// `contents` / `systemInstruction` / `generationConfig` request shape,
/// `functionDeclarations` tools, `functionCall`/`functionResponse` parts, and
/// streamed `data:` SSE events with `usageMetadata`.
public struct GeminiClient: LLMClient {
    public let baseURL: URL       // https://generativelanguage.googleapis.com/v1beta (or v1alpha)
    public let apiKey: String
    public let model: String
    public let metadata: ModelMetadata
    public let maxOutputTokens: Int?
    public let temperature: Double?
    public let thinkingPayload: [String: Any]?
    public let transport: WireTransport

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        metadata: ModelMetadata? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        thinkingEffort: String? = nil,
        httpClient: HTTPClient
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.metadata = metadata ?? ModelMetadataRegistry.shared.metadata(for: model, provider: "google")
        self.maxOutputTokens = maxOutputTokens ?? self.metadata.maxOutputTokens
        self.temperature = temperature
        self.thinkingPayload = ModelMetadataRegistry.shared.thinkingPayload(effort: thinkingEffort, metadata: self.metadata)
        self.transport = WireTransport(httpClient: httpClient, defaultTimeoutSeconds: 300)
    }

    // MARK: - LLMClient

    public func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        let body = try buildRequest(messages: messages, tools: tools, stream: false)
        let resp = try await transport.post(url: completeURL(), headers: Self.headers(apiKey: apiKey), body: body)
        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        guard let json else { throw LLMError.decodingError("Gemini response is not a JSON object") }
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
                    var headers = Self.headers(apiKey: self.apiKey)
                    headers["Accept"] = "text/event-stream"
                    let resp = try await self.transport.post(
                        url: self.streamURL(), headers: headers, body: request, accepted: 200...200
                    )
                    let text = String(data: resp.body, encoding: .utf8) ?? ""
                    let deltas = self.parseStream(text)
                    for d in deltas { continuation.yield(d) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request building (Hermes build_gemini_request)

    func buildRequest(messages: [Message], tools: [[String: Any]]?, stream: Bool) throws -> Data {
        var body: [String: Any] = [:]
        var contents: [[String: Any]] = []
        var systemInstruction: [String: Any]?

        for message in messages {
            let role = message.role.rawValue
            switch role {
            case "system":
                if systemInstruction == nil {
                    systemInstruction = ["parts": [["text": message.content ?? ""]]]
                } else if var parts = systemInstruction?["parts"] as? [[String: Any]],
                          let text = message.content {
                    parts.append(["text": text])
                    systemInstruction?["parts"] = parts
                }
            case "tool":
                // tool_result → functionResponse part, attached to the
                // preceding assistant turn (Gemini has no separate role).
                contents.append([
                    "role": "user",
                    "parts": [[
                        "functionResponse": [
                            "name": toolResultName(from: message),
                            "response": ["result": message.content ?? ""],
                        ],
                    ]],
                ])
            case "assistant":
                var parts: [[String: Any]] = []
                if let content = message.content, !content.isEmpty {
                    parts.append(["text": content])
                }
                if let calls = message.toolCalls {
                    for call in calls {
                        let args = (try? JSONSerialization.jsonObject(
                            with: Data(call.function.arguments.utf8))) ?? [:]
                        parts.append([
                            "functionCall": [
                                "name": call.function.name,
                                "args": args,
                            ],
                        ])
                    }
                }
                contents.append(["role": "model", "parts": parts])
            default: // user
                var parts: [[String: Any]] = []
                if let content = message.content, !content.isEmpty {
                    // image parts (OpenAI shape) → inlineData
                    if let parsed = try? JSONSerialization.jsonObject(
                        with: Data(content.utf8)) as? [[String: Any]],
                       parsed.contains(where: { ($0["type"] as? String) == "image_url" }) {
                        for part in parsed {
                            if part["type"] as? String == "image_url",
                               let url = (part["image_url"] as? [String: Any])?["url"] as? String,
                               let comma = url.firstIndex(of: ",") {
                                parts.append([
                                    "inlineData": [
                                        "mimeType": mediaType(fromDataURL: url) ?? "image/png",
                                        "data": String(url[url.index(after: comma)...]),
                                    ],
                                ])
                            } else if let text = part["text"] as? String {
                                parts.append(["text": text])
                            }
                        }
                    } else {
                        parts.append(["text": content])
                    }
                }
                contents.append(["role": "user", "parts": parts])
            }
        }

        body["contents"] = contents
        if let systemInstruction { body["systemInstruction"] = systemInstruction }

        var generation: [String: Any] = [:]
        if let maxOutputTokens { generation["maxOutputTokens"] = maxOutputTokens }
        if let temperature { generation["temperature"] = temperature }
        if let thinkingPayload {
            generation.merge(thinkingPayload) { _, new in new }
        }
        if !generation.isEmpty { body["generationConfig"] = generation }
        body["stream"] = stream

        if let tools, !tools.isEmpty {
            let declarations = tools.map { tool -> [String: Any] in
                let function = tool["function"] as? [String: Any] ?? tool
                return [
                    "name": function["name"] as? String ?? "",
                    "description": function["description"] as? String ?? "",
                    "parameters": function["parameters"] as? [String: Any] ?? ["type": "object"],
                ]
            }
            body["tools"] = [["functionDeclarations": declarations]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func streamURL() -> String {
        // v1beta:models/{model}:streamGenerateContent?alt=sse&key=…
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        let modelID = model.contains("/") ? String(model.split(separator: "/").last ?? "") : model
        let url = "\(base)models/\(modelID):streamGenerateContent?alt=sse&key=\(apiKey)"
        return url
    }

    func completeURL() -> String {
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        let modelID = model.contains("/") ? String(model.split(separator: "/").last ?? "") : model
        return "\(base)models/\(modelID):generateContent?key=\(apiKey)"
    }

    static func headers(apiKey: String) -> [String: String] {
        // Gemini accepts ?key= in the URL; keep the header for x-goog-* parity.
        ["Content-Type": "application/json"]
    }

    // MARK: - Parsing (Hermes translate_gemini_response / translate_stream_event)

    func parseResponse(_ json: [String: Any]) throws -> LLMResponse {
        var content = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var finishReason: String?
        var usage: Usage?

        if let meta = json["usageMetadata"] as? [String: Any] {
            usage = Usage(
                promptTokens: meta["promptTokenCount"] as? Int ?? 0,
                completionTokens: meta["candidatesTokenCount"] as? Int ?? 0,
                totalTokens: meta["totalTokenCount"] as? Int ?? 0,
                cachedPromptTokens: nil
            )
        }
        let candidates = json["candidates"] as? [[String: Any]]
        if let candidate = candidates?.first {
            let parts = candidate["content"] as? [String: Any]
            for part in (parts?["parts"] as? [[String: Any]]) ?? [] {
                if let text = part["text"] as? String { content += text }
                if let fc = part["functionCall"] as? [String: Any] {
                    let name = fc["name"] as? String ?? ""
                    let args = fc["args"] ?? [:]
                    let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                    toolCalls.append(ToolCall(
                        id: "gemini-\(toolCalls.count)",
                        type: "function",
                        function: ToolCallFunction(name: name, arguments: String(data: data, encoding: .utf8) ?? "{}")
                    ))
                }
            }
            finishReason = Self.mapFinishReason(candidate["finishReason"] as? String)
            if let thought = candidate["content"] as? [String: Any],
               let parts = thought["parts"] as? [[String: Any]] {
                for p in parts where p["thought"] as? Bool == true {
                    reasoning += p["text"] as? String ?? ""
                }
            }
        }
        return LLMResponse(
            content: content.isEmpty ? nil : content,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            finishReason: finishReason,
            usage: usage
        )
    }

    func parseStream(_ text: String) -> [LLMDelta] {
        var deltas: [LLMDelta] = []
        var content = ""
        var reasoning = ""
        var toolAccs: [Int: ToolCallAccumulator] = [:]
        var finish: String?
        for lineS in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineS)
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let meta = json["usageMetadata"] as? [String: Any] {
                deltas.append(LLMDelta(content: nil, usage: Usage(
                    promptTokens: meta["promptTokenCount"] as? Int ?? 0,
                    completionTokens: meta["candidatesTokenCount"] as? Int ?? 0,
                    totalTokens: meta["totalTokenCount"] as? Int ?? 0,
                    cachedPromptTokens: nil
                )))
            }
            for candidate in (json["candidates"] as? [[String: Any]]) ?? [] {
                if let finishReason = candidate["finishReason"] as? String {
                    finish = Self.mapFinishReason(finishReason)
                }
                let contentObj = candidate["content"] as? [String: Any]
                for part in (contentObj?["parts"] as? [[String: Any]]) ?? [] {
                    if let text = part["text"] as? String {
                        content += text
                        deltas.append(LLMDelta(content: text))
                    }
                    if part["thought"] as? Bool == true, let text = part["text"] as? String {
                        reasoning += text
                        deltas.append(LLMDelta(content: nil, reasoning: text))
                    }
                    if let fc = part["functionCall"] as? [String: Any] {
                        let idx = toolAccs.count
                        let name = fc["name"] as? String ?? ""
                        let args = (try? JSONSerialization.data(withJSONObject: fc["args"] ?? [:])) ?? Data("{}".utf8)
                        toolAccs[idx] = ToolCallAccumulator(id: "gemini-\(idx)", name: name, index: idx)
                        deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(
                            index: idx, id: "gemini-\(idx)", name: name,
                            arguments: String(data: args, encoding: .utf8) ?? "{}"
                        )]))
                    }
                }
            }
        }
        if let finish {
            deltas.append(LLMDelta(content: nil, finishReason: finish))
            // Complete tool calls for merge-by-index consumers.
            for acc in toolAccs.values.sorted(by: { $0.index < $1.index }) {
                deltas.append(LLMDelta(content: nil, toolCalls: [ToolCallDelta(
                    index: acc.index, id: acc.id, name: acc.name, arguments: acc.arguments.isEmpty ? "{}" : acc.arguments
                )]))
            }
        }
        return deltas
    }

    static func mapFinishReason(_ reason: String?) -> String? {
        switch reason {
        case "STOP": return "stop"
        case "MAX_TOKENS": return "length"
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
            return "content_filter"
        case "FINISH_REASON_UNSPECIFIED", nil, "": return nil
        default: return reason?.lowercased()
        }
    }

    func toolResultName(from message: Message) -> String {
        // Gemini functionResponse reuses the CALL name; Hermes tracks it by
        // matching the previous functionCall. Best-effort: fall back to the
        // tool name given in the message name field.
        return message.name ?? "unknown_tool"
    }

    func mediaType(fromDataURL url: String) -> String? {
        guard let semicolon = url.firstIndex(of: ";") else { return nil }
        let head = String(url[..<semicolon])
        return head.hasPrefix("data:") ? String(head.dropFirst(5)) : nil
    }
}
