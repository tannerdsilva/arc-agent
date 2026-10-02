import Foundation

// MARK: - Batch processing (reference `batch_runner.py`)

/// Per-tool usage statistics captured during a run.
public struct ToolCallStat: Codable, Sendable, Equatable {
    public var count = 0
    public var success = 0
    public var failure = 0
    public init() {}
}

/// Result of running one prompt to completion for trajectory export.
public struct BatchTurnResult: Sendable {
    public let messages: [Message]
    public let toolStats: [String: ToolCallStat]
    /// Terminal reason when the turn stopped abnormally (e.g. max_iterations);
    /// nil when the model produced a normal final answer.
    public let terminalReason: String?
    public init(messages: [Message], toolStats: [String: ToolCallStat], terminalReason: String?) {
        self.messages = messages
        self.toolStats = toolStats
        self.terminalReason = terminalReason
    }
    public var completed: Bool { terminalReason == nil }
    public var partial: Bool { terminalReason != nil }
    /// Number of LLM API calls = assistant turns (reference `api_calls`).
    public var apiCalls: Int { messages.filter { $0.role == .assistant }.count }
    public var toolsetsUsed: [String] { [] }
}

// MARK: - ShareGPT trajectory format

/// One ShareGPT-style conversation message (`from`/`value`).
public struct TrajectoryChatMessage: Codable, Sendable, Equatable {
    public let from: String
    public let value: String
    public init(from: String, value: String) {
        self.from = from
        self.value = value
    }
}

/// One JSONL trajectory entry (reference schema from `_process_batch_worker`).
public struct TrajectoryEntry: Codable, Sendable {
    public let promptIndex: Int
    public let conversations: [TrajectoryChatMessage]
    public let metadata: [String: String]
    public let completed: Bool
    public let partial: Bool
    public let apiCalls: Int
    public let toolsetsUsed: [String]
    public let toolStats: [String: ToolCallStat]
    public let toolErrorCounts: [String: Int]

    public init(
        promptIndex: Int, conversations: [TrajectoryChatMessage],
        metadata: [String: String], completed: Bool, partial: Bool,
        apiCalls: Int, toolsetsUsed: [String],
        toolStats: [String: ToolCallStat]
    ) {
        self.promptIndex = promptIndex
        self.conversations = conversations
        self.metadata = metadata
        self.completed = completed
        self.partial = partial
        self.apiCalls = apiCalls
        self.toolsetsUsed = toolsetsUsed
        self.toolStats = toolStats
        self.toolErrorCounts = toolStats.mapValues { $0.failure }
    }

    enum CodingKeys: String, CodingKey {
        case promptIndex = "prompt_index"
        case conversations
        case metadata
        case completed
        case partial
        case apiCalls = "api_calls"
        case toolsetsUsed = "toolsets_used"
        case toolStats = "tool_stats"
        case toolErrorCounts = "tool_error_counts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptIndex = try c.decode(Int.self, forKey: .promptIndex)
        conversations = try c.decode([TrajectoryChatMessage].self, forKey: .conversations)
        metadata = try c.decode([String: String].self, forKey: .metadata)
        completed = try c.decode(Bool.self, forKey: .completed)
        partial = try c.decode(Bool.self, forKey: .partial)
        apiCalls = try c.decode(Int.self, forKey: .apiCalls)
        toolsetsUsed = try c.decode([String].self, forKey: .toolsetsUsed)
        toolStats = try c.decode([String: ToolCallStat].self, forKey: .toolStats)
        toolErrorCounts = try c.decodeIfPresent([String: Int].self, forKey: .toolErrorCounts) ?? [:]
    }
}

public enum ShareGPTTrajectory {

    /// Convert an arc message history to the reference ShareGPT trajectory.
    ///
    /// Mirrors `agent_runtime_helpers.convert_to_trajectory_format`: system
    /// preamble, the dataset prompt as `human`, assistant turns with 思考
    /// reasoning blocks and `<tool_call>` XML, and all tool responses of a
    /// turn joined into a single `tool` message. Every `gpt` value carries an
    /// (empty) 思考 block so the format is consistent for training data.
    public static func make(
        messages: [Message],
        userQuery: String,
        completed: Bool,
        toolsIndexText: String
    ) -> [TrajectoryChatMessage] {
        var trajectory: [TrajectoryChatMessage] = []
        trajectory.append(TrajectoryChatMessage(from: "system", value: systemPreamble(tools: toolsIndexText)))
        trajectory.append(TrajectoryChatMessage(from: "human", value: userQuery))

        // messages[0] is the user prompt — already emitted above (reference
        // skips index 0 for the same reason).
        var i = 1
        while i < messages.count {
            let message = messages[i]
            switch message.role {
            case .assistant:
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    var content = ""
                    if let reasoning = message.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        content += "思考\n" + reasoning + "\n思考\n"
                    }
                    if let text = message.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        content += text + "\n"
                    }
                    for toolCall in toolCalls {
                        let args = normalizeArguments(toolCall.function.arguments)
                        let payload = ["name": toolCall.function.name, "arguments": args] as [String: Any]
                        let json = jsonString(payload)
                        content += "<tool_call>\n\(json)\n</tool_call>\n"
                    }
                    if !content.contains("思考") {
                        content = "思考\n思考\n" + content
                    }
                    trajectory.append(TrajectoryChatMessage(from: "gpt", value: content.trimmingCharacters(in: .whitespacesAndNewlines)))

                    // Collect subsequent tool responses into one message.
                    var toolResponses: [String] = []
                    var j = i + 1
                    var toolIndex = 0
                    while j < messages.count, messages[j].role == .tool {
                        let toolMessage = messages[j]
                        var payload: [String: Any] = [
                            "tool_call_id": toolMessage.toolCallID ?? "",
                            "name": toolIndex < toolCalls.count ? toolCalls[toolIndex].function.name : "unknown",
                            "content": rawContent(toolMessage.content ?? ""),
                        ]
                        _ = payload["name"] // keep
                        toolResponses.append("<tool_response>\n" + jsonString(payload) + "\n</tool_response>")
                        toolIndex += 1
                        j += 1
                    }
                    if !toolResponses.isEmpty {
                        trajectory.append(TrajectoryChatMessage(from: "tool", value: toolResponses.joined(separator: "\n")))
                    }
                    i = j
                    continue
                } else {
                    var content = ""
                    if let reasoning = message.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        content += "思考\n" + reasoning + "\n思考\n"
                    }
                    content += message.content ?? ""
                    if !content.contains("思考") {
                        content = "思考\n思考\n" + content
                    }
                    trajectory.append(TrajectoryChatMessage(from: "gpt", value: content.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            case .user:
                trajectory.append(TrajectoryChatMessage(from: "human", value: message.content ?? ""))
            case .system, .tool:
                break
            }
            i += 1
        }
        return trajectory
    }

    /// Reference preamble text (function-calling prompt) with the agent's
    /// tool index in `<tools>` XML tags.
    static func systemPreamble(tools: String) -> String {
        "You are a function calling AI model. You are provided with function signatures within <tools> </tools> XML tags. "
        + "You may call one or more functions to assist with the user query. If available tools are not relevant in assisting "
        + "with user query, just respond in natural conversational language. Don't make assumptions about what values to plug "
        + "into functions. After calling & executing the functions, you will be provided with function results within "
        + "<tool_response> </tool_response> XML tags. Here are the available tools:\n"
        + "<tools>\n\(tools)\n</tools>\n"
        + "For each function call return a JSON object, with the following pydantic model json schema for each:\n"
        + "{'title': 'FunctionCall', 'type': 'object', 'properties': {'name': {'title': 'Name', 'type': 'string'}, "
        + "'arguments': {'title': 'Arguments', 'type': 'object'}}, 'required': ['name', 'arguments']}\n"
        + "Each function call should be enclosed within <tool_call> </tool_call> XML tags.\n"
        + "Example:\n<tool_call>\n{'name': <function-name>,'arguments': <args-dict>}\n</tool_call>"
    }

    /// Reference tolerance for tool content that looks like JSON (parsed and
    /// re-embedded as a JSON value) vs plain text.
    static func rawContent(_ text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
        }
        return text
    }

    /// Parse arguments JSON, falling back to the raw string (reference uses
    /// `{}` on failure; keeping the string is lossless for trajectories).
    static func normalizeArguments(_ raw: String) -> Any {
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        return raw
    }

    static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            return String(describing: object)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(data: data, encoding: .utf8) ?? String(describing: object)
        } catch {
            return String(describing: object)
        }
    }
}

// MARK: - Tool result success classification (reference `_extract_tool_stats`)

extension ToolCallStat {
    /// Reference semantics: JSON `{"error": non-null}` or `{"success": false}`
    /// → failure; explicit `Error:` prefix → failure; empty → failure.
    public static func resultIsError(_ result: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.lowercased().hasPrefix("error:") { return true }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"], !(error is NSNull) { return true }
            if let success = object["success"] as? Bool, !success { return true }
        }
        return false
    }

    public mutating func record(_ isError: Bool) {
        count += 1
        if isError { failure += 1 } else { success += 1 }
    }
}

// MARK: - Dataset

/// A dataset entry: either `{"prompt": "..."}` or a `conversations` array.
public struct BatchDatasetEntry: Sendable {
    public let prompt: String
    public init(prompt: String) { self.prompt = prompt }
}

public enum BatchDatasetLoader {
    /// JSONL lines; supports `prompt` and conversations (`role`/`from` user
    /// or human) entry shapes (reference `_load_dataset` + `_filter_dataset_by_completed`).
    public static func load(_ url: URL) throws -> [BatchDatasetEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [BatchDatasetEntry] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let prompt = object["prompt"] as? String, !prompt.isEmpty {
                entries.append(BatchDatasetEntry(prompt: prompt))
                continue
            }
            if let conversations = object["conversations"] as? [[String: Any]] {
                for message in conversations {
                    let role = (message["role"] as? String) ?? (message["from"] as? String) ?? ""
                    if role == "user" || role == "human" {
                        let content = (message["content"] as? String) ?? (message["value"] as? String) ?? ""
                        if !content.isEmpty {
                            entries.append(BatchDatasetEntry(prompt: content))
                        }
                        break
                    }
                }
            }
        }
        return entries
    }
}

// MARK: - Toolset distributions (reference `toolset_distributions.py`)

public struct BatchDistribution: Sendable {
    public let name: String
    public let description: String
    /// toolset → inclusion weight (percent). 100 = always.
    public let weights: [String: Int]
    public init(name: String, description: String, weights: [String: Int]) {
        self.name = name
        self.description = description
        self.weights = weights
    }

    /// Sample the toolset subset for one prompt (deterministic per seed).
    public func sample(seed: UInt64, universe: [String]) -> Set<String> {
        var rng = SplitMix64(seed: seed)
        var selected = Set<String>()
        for toolset in universe {
            let weight = weights[toolset] ?? 0
            if weight >= 100 || (weight > 0 && rng.next() % 100 < UInt64(weight)) {
                selected.insert(toolset)
            }
        }
        return selected
    }

    public static func registry(universe: [String]) -> [BatchDistribution] {
        [
            BatchDistribution(
                name: "default",
                description: "All available tools, all the time",
                weights: Dictionary(uniqueKeysWithValues: universe.map { ($0, 100) })
            ),
            BatchDistribution(
                name: "image_gen",
                description: "Heavy focus on image generation with vision and web support",
                weights: ["image_gen": 90, "vision": 90, "web": 55, "terminal": 45]
            ),
            BatchDistribution(
                name: "research",
                description: "Web research with vision analysis and reasoning",
                weights: ["web": 90, "browser": 70, "vision": 50, "terminal": 45]
            ),
        ]
    }

    public static func named(_ name: String, universe: [String]) -> BatchDistribution? {
        registry(universe: universe).first { $0.name == name }
    }
}

/// Deterministic PRNG (SplitMix64) so resume re-samples the same toolsets.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
