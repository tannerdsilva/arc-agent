import Foundation

// MARK: - Progressive tool disclosure (reference `tools/tool_search.py`)

/// Config for the deferred tool registry (reference `tools.tool_search`).
///
/// When active, non-core tools are removed from the model-visible tools array
/// and replaced by three bridge tools (`tool_search`, `tool_describe`,
/// `tool_call`) plus a budgeted name + short-description manifest of the
/// deferred tools. Core tools are never deferred.
public struct ToolSearchConfig: Codable, Sendable, Equatable {
    /// "auto" | "on" | "off". `auto` and `on` activate whenever at least one
    /// deferrable tool exists.
    public var enabled: String
    /// Listing budget as a percentage of the model's context window
    /// (bounds the embedded manifest). Default 5.0.
    public var thresholdPct: Double
    /// Absolute cap on the embedded manifest, regardless of context size.
    public var listingMaxTokens: Int
    /// "auto" | "on" | "off": keep the manifest listing in the tool_search
    /// bridge description ("auto" degrades to names-only then none).
    public var listing: String
    /// Toolsets that participate in deferral. Explicit list wins; when empty
    /// the default core/deferred sets are used.
    public var deferredToolsets: [String]

    public init(
        enabled: String = "auto",
        thresholdPct: Double = 5.0,
        listingMaxTokens: Int = 4000,
        listing: String = "auto",
        deferredToolsets: [String] = []
    ) {
        var normalized = enabled.lowercased().trimmingCharacters(in: .whitespaces)
        if ["true", "1", "yes"].contains(normalized) { normalized = "on" }
        if ["false", "0", "no"].contains(normalized) { normalized = "off" }
        if !["auto", "on", "off"].contains(normalized) { normalized = "auto" }
        self.enabled = normalized
        self.thresholdPct = max(0.0, min(100.0, thresholdPct))
        self.listingMaxTokens = max(200, min(60_000, listingMaxTokens))
        self.listing = ["auto", "on", "off"].contains(listing) ? listing : "auto"
        self.deferredToolsets = deferredToolsets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try Self.decodeFlexibleString(c, forKey: .enabled) ?? "auto",
            thresholdPct: try c.decodeIfPresent(Double.self, forKey: .thresholdPct) ?? 5.0,
            listingMaxTokens: try c.decodeIfPresent(Int.self, forKey: .listingMaxTokens) ?? 4000,
            listing: try c.decodeIfPresent(String.self, forKey: .listing) ?? "auto",
            deferredToolsets: try c.decodeIfPresent([String].self, forKey: .deferredToolsets) ?? []
        )
    }

    /// Accept `true`/`false` booleans for string enums (user configs often
    /// write `enabled: true`; reference tolerates both shapes).
    private static func decodeFlexibleString(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        do {
            if let s = try c.decodeIfPresent(String.self, forKey: key) { return s }
        } catch {}
        do {
            if let b = try c.decodeIfPresent(Bool.self, forKey: key) { return b ? "on" : "off" }
        } catch {}
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, thresholdPct = "threshold_pct"
        case listingMaxTokens = "listing_max_tokens"
        case listing
        case deferredToolsets = "deferred_toolsets"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(thresholdPct, forKey: .thresholdPct)
        try c.encode(listingMaxTokens, forKey: .listingMaxTokens)
        try c.encode(listing, forKey: .listing)
        try c.encode(deferredToolsets, forKey: .deferredToolsets)
    }
}

/// Classification policy: which tools defer and which never do.
///
/// Faithful to reference: core tools are never deferred; project/kanban/media
/// (non-core) surfaces defer. A tool defers iff its toolset is not a core
/// toolset AND its name is not in `coreToolNames` (per-tool exceptions, e.g.
/// image/video generation stay eager like reference) AND it is not a bridge tool.
public enum DeferredToolPolicy {

    /// Toolsets that are always eager (the core-toolset grouping).
    public static let defaultCoreToolsets: Set<String> = [
        "core", "browser", "delegation", "file", "sandbox", "code_execution",
        "skills", "terminal", "tools", "web",
    ]

    /// Toolsets that defer by default (non-core in reference: project, kanban,
    /// media-adjacent, MCP/plugin surfaces).
    public static let defaultDeferredToolsets: Set<String> = [
        "kanban", "media", "mcp", "profile", "project", "webhooks", "weather",
        "messaging", "messaging_bot", "swift-package-utilitykit", "swift-demo",
    ]

    /// Per-tool exceptions that stay eager even inside a deferred toolset
    /// (reference keeps image/video/text-to-speech in the core list).
    public static let coreToolNames: Set<String> = [
        "image_generate", "video_generate", "text_to_speech",
    ]

    public static let bridgeNames: Set<String> = [
        "tool_search", "tool_describe", "tool_call",
    ]

    /// Whether a tool is eligible for deferral under the given configuration.
    public static func isDeferred(
        name: String,
        toolset: String,
        config: ToolSearchConfig
    ) -> Bool {
        if bridgeNames.contains(name) { return false }
        if config.enabled == "off" { return false }
        if coreToolNames.contains(name) { return false }
        if !config.deferredToolsets.isEmpty {
            return config.deferredToolsets.contains(toolset)
        }
        if defaultCoreToolsets.contains(toolset) { return false }
        return defaultDeferredToolsets.contains(toolset)
    }

    /// Split entries into (visible, deferred), mirroring
    /// `classify_tools` in reference. Availability checks are applied first so a
    /// tool whose requirements are unmet never reaches either list.
    public static func plan(
        entries: [ToolEntry],
        config: ToolSearchConfig
    ) -> (visible: [ToolEntry], deferred: [ToolEntry]) {
        var visible: [ToolEntry] = []
        var deferred: [ToolEntry] = []
        for entry in entries {
            if let check = entry.checkFn, !check() { continue }
            if isDeferred(name: entry.name, toolset: entry.toolset, config: config) {
                deferred.append(entry)
            } else {
                visible.append(entry)
            }
        }
        return (visible, deferred)
    }
}

/// Manifest rendering + prompt-schema assembly (reference tiered disclosure).
public enum ProgressiveToolDisclosure {

    /// Cheap chars/4 token estimate (reference `CHARS_PER_TOKEN = 4.0`).
    public static func estimateTokens(schemas: [[String: Any]]) -> Int {
        let count = schemas.reduce(0) { partial, schema in
            guard let data = try? JSONSerialization.data(withJSONObject: schema, options: []) else {
                return partial + String(describing: schema).count
            }
            return partial + data.count
        }
        return Int(ceil(Double(count) / 4.0))
    }

    /// Effective manifest budget: min(listingMaxTokens, thresholdPct% of
    /// context). Without a known window reference falls back to 5% of 200K.
    public static func manifestBudget(config: ToolSearchConfig, contextLength: Int?) -> Int {
        let pctLeg = (contextLength ?? 200_000) > 0
            ? Int(Double(contextLength ?? 200_000) * (config.thresholdPct / 100.0))
            : 10_000
        return max(0, min(config.listingMaxTokens, pctLeg))
    }

    /// First sentence of a description, clipped (skills-listing convention).
    public static func shortDesc(_ description: String, maxChars: Int = 60) -> String {
        let text = description.split(separator: " ").joined(separator: " ")
        guard !text.isEmpty else { return "" }
        var clipped = text
        if let sentenceEnd = text.rangeOfCharacter(from: .punctuationCharacters) {
            // Cut at first sentence-ending punctuation.
            let endIndex = sentenceEnd.lowerBound
            clipped = String(text[..<endIndex])
        }
        if clipped.count <= maxChars { return clipped }
        let head = String(clipped.prefix(maxChars))
        if let lastSpace = head.lastIndex(where: { $0 == " " }) {
            return String(head[..<lastSpace]) + "…"
        }
        return head + "…"
    }

    /// Grouped name + short-description listing (arc skills-style).
    public static func renderListing(_ deferred: [ToolEntry]) -> String {
        var lines: [String] = ["Deferred tools (load a schema with tool_describe, call with tool_call):\n"]
        let groups = Dictionary(grouping: deferred, by: { $0.toolset })
        for (toolset, entries) in groups.sorted(by: { $0.key < $1.key }) {
            lines.append("📦 \(toolset)")
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                lines.append("  \(entry.name) — \(shortDesc(entry.description))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Names-only fallback (over budget for full listing).
    public static func renderNames(_ deferred: [ToolEntry]) -> String {
        let names = deferred.map { $0.name }.sorted().joined(separator: ", ")
        return "Deferred tools (load a schema with tool_describe): \(names)"
    }

    /// The manifest text to embed in the tool_search bridge description,
    /// degrades listing → names-only → nil (bare bridge). `nil` when the
    /// feature is off or nothing deferred.
    public static func manifest(
        deferred: [ToolEntry],
        config: ToolSearchConfig,
        contextLength: Int?
    ) -> String? {
        guard deferred.isEmpty == false, config.enabled != "off" else { return nil }
        guard config.listing != "off" else { return nil }
        let budget = manifestBudget(config: config, contextLength: contextLength)
        let listing = renderListing(deferred)
        if estimateTokens(schemas: [["listing": listing]]) <= budget || config.listing == "on" {
            return listing
        }
        let names = renderNames(deferred)
        if estimateTokens(schemas: [["names": names]]) <= budget {
            return names
        }
        return nil
    }

    /// Build the full model-visible tools array with deferral applied.
    ///
    /// mirrors the reference client: core tools stay, deferrable tools are replaced by the
    /// bridge trio, and the manifest rides in the `tool_search` description.
    /// When nothing is deferrable (or the feature is off) the result is
    /// byte-identical to the eager layout.
    public static func buildPromptSchemas(
        registry: any ToolRegistry,
        disabled: Set<String>,
        config: ToolSearchConfig,
        contextLength: Int?
    ) -> [[String: Any]] {
        let candidates = registry.allTools.filter { !disabled.contains($0.toolset) }
        let (visible, deferred) = DeferredToolPolicy.plan(entries: candidates, config: config)
        guard deferred.isEmpty == false, config.enabled != "off" else {
            // Eager path — identical output to the plain registry rendering.
            return visible.map { Self.schema(for: $0) }
        }
        var schemas = visible.map { Self.schema(for: $0) }
        schemas.append(Self.toolSearchSchema(manifest: manifest(deferred: deferred, config: config, contextLength: contextLength)))
        schemas.append(Self.toolDescribeSchema())
        schemas.append(Self.toolCallSchema())
        return schemas
    }

    /// OpenAI function-schema dict for a tool entry (shared by the core agent
    /// and the webui `tool_describe` bridge translation).
    public static func schema(for entry: ToolEntry) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": entry.name,
                "description": entry.description,
                "parameters": entry.schema.asDictionary(),
            ] as [String: Any],
        ] as [String: Any]
    }

    static func toolSearchSchema(manifest: String?) -> [String: Any] {
        let base = ToolSearchTool.entry.description
        let description = manifest.map { "\(base)\n\n\($0)" } ?? base
        return [
            "type": "function",
            "function": [
                "name": ToolSearchTool.entry.name,
                "description": description,
                "parameters": ToolSearchTool.entry.schema.asDictionary(),
            ] as [String: Any],
        ] as [String: Any]
    }

    static func toolDescribeSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "tool_describe",
                "description": "Load the full JSON schema (name + parameters) for a deferred tool by name. "
                    + "Use `tool_search` to find deferred tools; use `tool_describe` before `tool_call` "
                    + "when you do not know a tool's parameters.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "tool": ["type": "string", "description": "Exact tool name, e.g. 'kanban_show'."]
                    ] as [String: Any],
                    "required": ["tool"],
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any]
    }

    static func toolCallSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "tool_call",
                "description": "Call a deferred tool by name with its parameters. Equivalent to calling the "
                    + "tool directly: guardrails, approvals, and the tool gateway all apply. "
                    + "Pass parameters as an object; results are returned exactly as if the tool were called directly.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "tool": ["type": "string", "description": "Exact deferred tool name."],
                        "arguments": ["type": "object", "description": "The tool's parameters (see tool_describe)."],
                    ] as [String: Any],
                    "required": ["tool"],
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any]
    }
}
