import Foundation

// MARK: - MoA config (Hermes `moa` config block)

/// Mixture-of-Agents configuration. Mirrors Hermes' `moa` config block:
/// reference models (advisors), the aggregator (the acting model), per-role
/// temperature, output caps, and the degraded-reference policy.
public struct MoAConfig: Sendable, Equatable, Codable {
    public struct Role: Sendable, Equatable, Codable {
        public let model: String
        public let provider: String?
        public let temperature: Double?

        public init(model: String, provider: String? = nil, temperature: Double? = nil) {
            self.model = model
            self.provider = provider
            self.temperature = temperature
        }
    }

    public var enabled: Bool
    public var referenceModels: [Role]
    public var aggregator: Role?
    public var aggregatorTemperature: Double?
    public var referenceMaxTokens: Int?
    public var degradedReferencePolicy: String  // "loud" | "silent"
    public var maxConcurrentReferences: Int
    public var toolResultBudgetChars: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case referenceModels = "reference_models"
        case aggregator
        case aggregatorTemperature = "aggregator_temperature"
        case referenceMaxTokens = "reference_max_tokens"
        case degradedReferencePolicy = "degraded_reference_policy"
        case maxConcurrentReferences = "max_concurrent_references"
        case toolResultBudgetChars = "tool_result_budget"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.referenceModels = try container.decodeIfPresent([Role].self, forKey: .referenceModels) ?? []
        self.aggregator = try container.decodeIfPresent(Role.self, forKey: .aggregator)
        self.aggregatorTemperature = try container.decodeIfPresent(Double.self, forKey: .aggregatorTemperature)
            ?? container.decodeIfPresent(Int.self, forKey: .aggregatorTemperature).map(Double.init)
        self.referenceMaxTokens = try container.decodeIfPresent(Int.self, forKey: .referenceMaxTokens)
        self.degradedReferencePolicy = try container.decodeIfPresent(String.self, forKey: .degradedReferencePolicy) ?? "loud"
        self.maxConcurrentReferences = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentReferences)
            ?? MoAService.maxConcurrentReferences
        self.toolResultBudgetChars = try container.decodeIfPresent(Int.self, forKey: .toolResultBudgetChars)
            ?? MoAService.toolResultBudgetChars
    }

    public init(
        enabled: Bool = false,
        referenceModels: [Role] = [],
        aggregator: Role? = nil,
        aggregatorTemperature: Double? = nil,
        referenceMaxTokens: Int? = nil,
        degradedReferencePolicy: String = "loud",
        maxConcurrentReferences: Int = MoAService.maxConcurrentReferences,
        toolResultBudgetChars: Int = MoAService.toolResultBudgetChars
    ) {
        self.enabled = enabled
        self.referenceModels = referenceModels
        self.aggregator = aggregator
        self.aggregatorTemperature = aggregatorTemperature
        self.referenceMaxTokens = referenceMaxTokens
        self.degradedReferencePolicy = degradedReferencePolicy
        self.maxConcurrentReferences = maxConcurrentReferences
        self.toolResultBudgetChars = toolResultBudgetChars
    }

    /// Build an advisory message list from arbitrary DSL messages (kept for
    /// compatibility with the tolerant parse path); the Codable path uses the
    /// snake_case CodingKeys above.
    public static func from(_ dict: [String: Any]?) -> MoAConfig {
        guard let dict else { return MoAConfig() }
        func roles(_ raw: Any?) -> [Role] {
            guard let list = raw as? [[String: Any]] else { return [] }
            return list.compactMap { entry in
                guard let model = entry["model"] as? String else { return nil }
                return Role(
                    model: model,
                    provider: entry["provider"] as? String,
                    temperature: entry["temperature"] as? Double ?? (entry["temperature"] as? Int).map(Double.init)
                )
            }
        }
        func role(_ raw: Any?) -> Role? {
            guard let entry = raw as? [String: Any], let model = entry["model"] as? String else { return nil }
            return Role(model: model, provider: entry["provider"] as? String,
                        temperature: entry["temperature"] as? Double ?? (entry["temperature"] as? Int).map(Double.init))
        }
        return MoAConfig(
            enabled: dict["enabled"] as? Bool ?? false,
            referenceModels: roles(dict["reference_models"] ?? dict["referenceModels"]),
            aggregator: role(dict["aggregator"]),
            aggregatorTemperature: dict["aggregator_temperature"] as? Double ?? (dict["aggregator_temperature"] as? Int).map(Double.init),
            referenceMaxTokens: dict["reference_max_tokens"] as? Int,
            degradedReferencePolicy: dict["degraded_reference_policy"] as? String ?? "loud",
            maxConcurrentReferences: dict["max_concurrent_references"] as? Int ?? MoAService.maxConcurrentReferences,
            toolResultBudgetChars: dict["tool_result_budget"] as? Int ?? MoAService.toolResultBudgetChars
        )
    }
}

// MARK: - Trace

/// One reference run outcome (Hermes `moa_trace.py` fields).
public struct MoAReferenceResult: Sendable, Equatable {
    public let label: String
    public let model: String
    public let status: String        // "ok" | "failed" | "skipped"
    public let outputTokens: Int?
    public let durationMs: Int?
    public let error: String?
    public let text: String?
}

/// Trace for one MoA aggregation (written as one JSONL line per turn).
public struct MoATrace: Sendable, Equatable {
    public let turnID: String
    public let startedAt: Date
    public let referenceResults: [MoAReferenceResult]
    public let joinedAt: Date?
    public let aggregatorModel: String?

    public init(turnID: String, startedAt: Date = Date(),
                referenceResults: [MoAReferenceResult] = [],
                joinedAt: Date? = nil, aggregatorModel: String? = nil) {
        self.turnID = turnID
        self.startedAt = startedAt
        self.referenceResults = referenceResults
        self.joinedAt = joinedAt
        self.aggregatorModel = aggregatorModel
    }

    public var asJSON: [String: Any] {
        var dict: [String: Any] = [
            "turn_id": turnID,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "references": referenceResults.map { r in
                var d: [String: Any] = ["label": r.label, "model": r.model, "status": r.status]
                if let t = r.outputTokens { d["output_tokens"] = t }
                if let ms = r.durationMs { d["duration_ms"] = ms }
                if let e = r.error { d["error"] = e }
                if let t = r.text { d["text"] = t }
                return d
            },
        ]
        if let joinedAt { dict["joined_at"] = ISO8601DateFormatter().string(from: joinedAt) }
        if let model = aggregatorModel { dict["aggregator_model"] = model }
        return dict
    }
}
