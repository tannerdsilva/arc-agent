import Foundation

/// Per-model, per-provider quirk metadata (Hermes `model_metadata` +
/// `usage_pricing` − runtime discovery). The registry is consulted before
/// every request to decide wire shapes, cache markers, thinking fields,
/// token budgets, and patience floors — so pointing arc-agent at Anthropic,
/// Gemini, Bedrock, or Codex is a config change, not a rewrite.
///
/// Lookup is exact-model first, then family-prefix match (longest prefix
/// wins), then provider-family defaults, then safe global defaults.
public struct ModelMetadata: Sendable, Equatable {
    /// Model identifier (may contain a provider prefix like `anthropic/claude-…`).
    public let model: String
    /// Provider family this metadata was declared for (`openai`, `anthropic`, …).
    public let provider: String
    /// Context window in tokens.
    public let contextLength: Int
    /// Hard output cap (max_tokens): `nil` = provider default.
    public let maxOutputTokens: Int?
    /// Whether the model accepts a separate thinking/reasoning request field.
    public let supportsThinking: Bool
    /// How thinking effort is spelled on the wire for this family.
    public let thinkingField: ThinkingField
    /// How prompt cache markers are emitted (`cache_control`, `prompt_caching`, none).
    public let cacheStyle: CacheStyle
    /// Tool schema dialect to emit.
    public let toolSchemaStyle: ToolSchemaStyle
    /// Willing levels for reasoning effort (Hermes vocabulary), `nil` = provider default.
    public let reasoningEffortLevels: [String]?
    /// Minimum staleness patience (seconds) for this model family (reasoning floor).
    public let staleTimeoutFloor: Double?
    /// Pricing per million tokens (USD); nil = unknown.
    public let pricing: ModelPricing?

    public init(
        model: String,
        provider: String,
        contextLength: Int,
        maxOutputTokens: Int? = nil,
        supportsThinking: Bool = false,
        thinkingField: ThinkingField = .none,
        cacheStyle: CacheStyle = .none,
        toolSchemaStyle: ToolSchemaStyle = .openAI,
        reasoningEffortLevels: [String]? = nil,
        staleTimeoutFloor: Double? = nil,
        pricing: ModelPricing? = nil
    ) {
        self.model = model
        self.provider = provider
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.supportsThinking = supportsThinking
        self.thinkingField = thinkingField
        self.cacheStyle = cacheStyle
        self.toolSchemaStyle = toolSchemaStyle
        self.reasoningEffortLevels = reasoningEffortLevels
        self.staleTimeoutFloor = staleTimeoutFloor
        self.pricing = pricing
    }
}

/// How a thinking request field is spelled per provider family.
public enum ThinkingField: String, Sendable, Equatable {
    /// No separate field — thinking arrives inline or is not offered.
    case none
    /// OpenAI-style `reasoning_effort`.
    case reasoningEffort
    /// Anthropic adaptive thinking (`thinking: {type: "enabled", budget_tokens: N}`)
    /// — effort spelled with `output_config.effort` on 4.7+ models.
    case anthropicAdaptive
    /// Gemini `thinkingConfig: {thinkingBudget / includeThoughts}`.
    case geminiThinking
    /// Moonshot `thinking: {type: "enabled", budget_tokens: N}`.
    case moonshotThinking
}

/// Prompt-cache marker style per provider.
public enum CacheStyle: String, Sendable, Equatable {
    /// No explicit cache markers (OpenAI/vLLM automatic prefix caching).
    case none
    /// Anthropic `cache_control: {type: ephemeral, ttl}` on content blocks.
    case anthropicCacheControl
    /// Gemini `cachedContent`-adjacent semantics: no per-message markers.
    case gemini
}

/// Tool-schema dialect emitted per provider.
public enum ToolSchemaStyle: String, Sendable, Equatable {
    case openAI
    case anthropic
    case gemini
    case moonshot
    case bedrock
}

/// USD pricing per million tokens (Hermes `PricingEntry`).
public struct ModelPricing: Sendable, Equatable {
    public let inputPerMillion: Double?
    public let outputPerMillion: Double?
    public let cacheReadPerMillion: Double?
    public let cacheWritePerMillion: Double?
    public let requestCost: Double?

    public init(
        inputPerMillion: Double? = nil,
        outputPerMillion: Double? = nil,
        cacheReadPerMillion: Double? = nil,
        cacheWritePerMillion: Double? = nil,
        requestCost: Double? = nil
    ) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.requestCost = requestCost
    }
}

/// Table-driven registry with alias + family resolution. Thread-safe by
/// construction (immutable after load).
public struct ModelMetadataRegistry: Sendable {
    public let entries: [ModelMetadata]
    public let defaultContextLength: Int

    public init(entries: [ModelMetadata] = ModelMetadataRegistry.builtInEntries,
                defaultContextLength: Int = 128_000) {
        self.entries = entries
        self.defaultContextLength = defaultContextLength
    }

    public static let shared = ModelMetadataRegistry()

    /// Resolve metadata for a model (exact → family prefix → provider
    /// family default → safe default). `contextLength` from configuration
    /// always wins (Hermes: config overrides discovery).
    public func metadata(
        for model: String,
        provider: String? = nil,
        configuredContextLength: Int? = nil
    ) -> ModelMetadata {
        // Exact match on full id, with or without provider prefix.
        let lower = model.lowercased()
        let bare = lower.contains("/") ? String(lower.split(separator: "/").last ?? "") : lower
        let family = (provider ?? "").lowercased()

        if let exact = entries.first(where: { $0.model.lowercased() == lower || $0.model.lowercased() == bare }) {
            return merging(exact, configuredContextLength: configuredContextLength)
        }
        // Longest family-prefix match (e.g. `claude-sonnet-4-5` → claude).
        let candidates = entries
            .filter { e in bare.hasPrefix(e.model.lowercased()) || e.provider == family }
            .sorted { $0.model.count > $1.model.count }
        if let byPrefix = candidates.first(where: { bare.hasPrefix($0.model.lowercased()) }) {
            return merging(byPrefix, configuredContextLength: configuredContextLength)
        }
        // Provider-family default: first entry whose provider matches.
        if let byProvider = candidates.first(where: { $0.provider == family }) {
            return merging(byProvider, configuredContextLength: configuredContextLength)
        }
        return ModelMetadata(
            model: model,
            provider: family.isEmpty ? "unknown" : family,
            contextLength: configuredContextLength ?? defaultContextLength
        )
    }

    private func merging(_ meta: ModelMetadata, configuredContextLength: Int?) -> ModelMetadata {
        guard let configured = configuredContextLength else { return meta }
        var m = meta
        return ModelMetadata(
            model: meta.model, provider: meta.provider,
            contextLength: configured,
            maxOutputTokens: meta.maxOutputTokens,
            supportsThinking: meta.supportsThinking,
            thinkingField: meta.thinkingField,
            cacheStyle: meta.cacheStyle,
            toolSchemaStyle: meta.toolSchemaStyle,
            reasoningEffortLevels: meta.reasoningEffortLevels,
            staleTimeoutFloor: meta.staleTimeoutFloor,
            pricing: meta.pricing
        )
    }

    /// Hermes effort → provider-specific thinking payload.
    public func thinkingPayload(effort: String?, metadata: ModelMetadata) -> [String: Any]? {
        guard let effort = effort, !effort.isEmpty, !effort.isEmpty else { return nil }
        switch metadata.thinkingField {
        case .reasoningEffort:
            return ["reasoning_effort": effort]
        case .anthropicAdaptive:
            // 4.7+ expose low/medium/high/xhigh/max; pre-4.7 accept
            // low/medium/high/max. Hermes downgrades xhigh → max on
            // pre-4.7 (mirrored here).
            let levels = metadata.reasoningEffortLevels ?? ["low", "medium", "high", "max"]
            var e = effort
            if effort == "xhigh", !levels.contains("xhigh") { e = "max" }
            if effort == "minimal" { e = "low" }
            if levels.contains(e) {
                return ["output_config": ["effort": e]]
            }
            return nil
        case .geminiThinking:
            let budget = metadata.maxOutputTokens.map { $0 / 2 } ?? 16_384
            return ["thinkingConfig": ["thinkingBudget": budget, "includeThoughts": true]]
        case .moonshotThinking:
            let budget = metadata.maxOutputTokens.map { $0 / 2 } ?? 16_384
            return ["thinking": ["type": "enabled", "budget_tokens": budget]]
        case .none:
            return nil
        }
    }

    // MARK: - Built-in table (subset of Hermes' official pricing + model
    // families; context lengths are the provider-declared windows).

    public static let builtInEntries: [ModelMetadata] = [
        .init(model: "gpt-4o", provider: "openai", contextLength: 128_000, maxOutputTokens: 16_384,
              pricing: .init(inputPerMillion: 2.5, outputPerMillion: 10)),
        .init(model: "gpt-4o-mini", provider: "openai", contextLength: 128_000, maxOutputTokens: 16_384,
              pricing: .init(inputPerMillion: 0.15, outputPerMillion: 0.6)),
        .init(model: "gpt-4.1", provider: "openai", contextLength: 1_047_576, maxOutputTokens: 32_768),
        .init(model: "gpt-5", provider: "openai", contextLength: 400_000, maxOutputTokens: 128_000,
              supportsThinking: true, thinkingField: .reasoningEffort,
              reasoningEffortLevels: ["minimal", "low", "medium", "high"]),
        .init(model: "o3", provider: "openai", contextLength: 200_000, maxOutputTokens: 100_000,
              supportsThinking: true, thinkingField: .reasoningEffort,
              reasoningEffortLevels: ["low", "medium", "high"], staleTimeoutFloor: 300),
        .init(model: "o4-mini", provider: "openai", contextLength: 200_000, maxOutputTokens: 100_000,
              supportsThinking: true, thinkingField: .reasoningEffort,
              reasoningEffortLevels: ["low", "medium", "high"], staleTimeoutFloor: 300),
        .init(model: "claude-opus-4-5", provider: "anthropic", contextLength: 200_000, maxOutputTokens: 64_000,
              supportsThinking: true, thinkingField: .anthropicAdaptive, cacheStyle: .anthropicCacheControl,
              toolSchemaStyle: .anthropic, reasoningEffortLevels: ["low", "medium", "high", "xhigh", "max"],
              staleTimeoutFloor: 300,
              pricing: .init(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25)),
        .init(model: "claude-sonnet-4-5", provider: "anthropic", contextLength: 200_000, maxOutputTokens: 64_000,
              supportsThinking: true, thinkingField: .anthropicAdaptive, cacheStyle: .anthropicCacheControl,
              toolSchemaStyle: .anthropic, reasoningEffortLevels: ["low", "medium", "high", "xhigh", "max"],
              staleTimeoutFloor: 240,
              pricing: .init(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)),
        .init(model: "claude-sonnet-4", provider: "anthropic", contextLength: 200_000, maxOutputTokens: 64_000,
              supportsThinking: true, thinkingField: .anthropicAdaptive, cacheStyle: .anthropicCacheControl,
              toolSchemaStyle: .anthropic, reasoningEffortLevels: ["low", "medium", "high", "max"],
              staleTimeoutFloor: 240,
              pricing: .init(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)),
        .init(model: "claude-3-7", provider: "anthropic", contextLength: 200_000, maxOutputTokens: 64_000,
              supportsThinking: true, thinkingField: .anthropicAdaptive, cacheStyle: .anthropicCacheControl,
              toolSchemaStyle: .anthropic, reasoningEffortLevels: ["low", "medium", "high", "max"]),
        .init(model: "gemini-2.5", provider: "google", contextLength: 1_048_576, maxOutputTokens: 65_536,
              supportsThinking: true, thinkingField: .geminiThinking, cacheStyle: .gemini,
              toolSchemaStyle: .gemini, reasoningEffortLevels: ["low", "medium", "high"]),
        .init(model: "gemini-2.0", provider: "google", contextLength: 1_048_576, maxOutputTokens: 8_192,
              supportsThinking: true, thinkingField: .geminiThinking, cacheStyle: .gemini,
              toolSchemaStyle: .gemini),
        .init(model: "gemini-3", provider: "google", contextLength: 1_048_576, maxOutputTokens: 65_536,
              supportsThinking: true, thinkingField: .geminiThinking, cacheStyle: .gemini,
              toolSchemaStyle: .gemini, reasoningEffortLevels: ["low", "medium", "high", "max"]),
        .init(model: "deepseek", provider: "deepseek", contextLength: 128_000, maxOutputTokens: 8_192,
              supportsThinking: true, thinkingField: .reasoningEffort,
              reasoningEffortLevels: ["low", "medium", "high"], staleTimeoutFloor: 180),
        .init(model: "qwen", provider: "qwen", contextLength: 262_144, maxOutputTokens: 32_768,
              supportsThinking: true, thinkingField: .reasoningEffort,
              reasoningEffortLevels: ["low", "medium", "high"]),
        .init(model: "kimi", provider: "moonshot", contextLength: 262_144, maxOutputTokens: 16_384,
              supportsThinking: true, thinkingField: .moonshotThinking,
              toolSchemaStyle: .moonshot, reasoningEffortLevels: ["low", "medium", "high"]),
        .init(model: "glm", provider: "zhipu", contextLength: 200_000, maxOutputTokens: 32_768),
        .init(model: "minimax", provider: "minimax", contextLength: 1_000_000, maxOutputTokens: 32_768),
        .init(model: "llama", provider: "meta", contextLength: 128_000, maxOutputTokens: 8_192),
        .init(model: "grok", provider: "xai", contextLength: 262_144, maxOutputTokens: 32_768,
              supportsThinking: true, thinkingField: .reasoningEffort),
        .init(model: "claude", provider: "anthropic", contextLength: 200_000, maxOutputTokens: 64_000,
              supportsThinking: true, thinkingField: .anthropicAdaptive, cacheStyle: .anthropicCacheControl,
              toolSchemaStyle: .anthropic),
    ]
}

/// Hermes effort vocabulary persistence: `none|minimal|low|medium|high|xhigh|max|ultra`.
public enum ReasoningEffort: String, Sendable, CaseIterable {
    case off = "off"
    case minimal, low, medium, high, xhigh, max, ultra
}
