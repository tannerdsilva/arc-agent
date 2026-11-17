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
/// The default answer is the toolset's own ``Toolset/Disclosure`` — the single
/// declaration the four hand-maintained tables collapsed into (T3b). Core
/// toolsets are `.eager`; project/kanban/profile/messaging/mcp defer. Operator
/// config still wins over the default, and a per-tool exception or a bridge tool
/// never defers.
public enum DeferredToolPolicy {

    /// Per-tool exceptions that stay eager even inside a deferred toolset
    /// (reference keeps image/video/text-to-speech in the core list).
    public static let coreToolNames: Set<String> = [
        "image_generate", "video_generate", "text_to_speech",
    ]

    public static let bridgeNames: Set<String> = [
        "tool_search", "tool_describe", "tool_call",
    ]

    /// Whether a tool is eligible for deferral under the given configuration.
    ///
    /// A foreign claim (`Toolset(claimed:)`) is `.eager`, so an unadmitted
    /// plugin namespace renders its tools inline instead of deferring them —
    /// the six reference-vocabulary names the old `defaultDeferredToolsets`
    /// carried (`media`, `webhooks`, `weather`, `messaging_bot`, `swift-demo`,
    /// and `sandbox` in the core list) are gone by construction.
    public static func isDeferred(
        name: String,
        toolset: Toolset,
        config: ToolSearchConfig
    ) -> Bool {
        if bridgeNames.contains(name) { return false }
        if config.enabled == "off" { return false }
        if coreToolNames.contains(name) { return false }
        if !config.deferredToolsets.isEmpty {
            return config.deferredToolsets.contains(toolset.name)
        }
        return toolset.disclosure == .deferred
    }

    /// Split entries into (visible, deferred), mirroring
    /// `classify_tools` in reference. Availability checks are applied first so a
    /// tool whose requirements are unmet never reaches either list.
    public static func plan(
        entries: [any AgentTool],
        config: ToolSearchConfig
    ) -> (visible: [any AgentTool], deferred: [any AgentTool]) {
        var visible: [any AgentTool] = []
        var deferred: [any AgentTool] = []
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

/// Manifest policy and rendering for tiered disclosure (reference
/// `tools/tool_search.py`): which tools defer, how the listing degrades
/// under a token budget, and the text embedded in `tool_search`.
///
/// Schema rendering is deliberately **not** here — ``ToolSchemaRenderer``
/// owns the one schema path. This type decides what the manifest says;
/// that type decides how a tool becomes a wire dict.
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

    /// Chars/4 over the text itself, without a JSON round-trip.
    ///
    /// The estimate exists to compare against a token budget; the old call site
    /// serialised a one-key dictionary every turn to measure a string already in
    /// hand. Internal on purpose: ``estimateTokens(schemas:)`` stays the public
    /// measure of a schema array, and this one is used only by ``manifest``.
    static func estimateTokens(text: String) -> Int {
        Int(ceil(Double(text.utf8.count) / 4.0))
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
    public static func renderListing(_ deferred: [any AgentTool]) -> String {
        var lines: [String] = ["Deferred tools (load a schema with tool_describe, call with tool_call):\n"]
        let groups = Dictionary(grouping: deferred, by: { $0.toolsetName })
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
    public static func renderNames(_ deferred: [any AgentTool]) -> String {
        let names = deferred.map { $0.name }.sorted().joined(separator: ", ")
        return "Deferred tools (load a schema with tool_describe): \(names)"
    }

    /// The manifest text to embed in the tool_search bridge description,
    /// degrades listing → names-only → nil (bare bridge). `nil` when the
    /// feature is off or nothing deferred.
    public static func manifest(
        deferred: [any AgentTool],
        config: ToolSearchConfig,
        contextLength: Int?
    ) -> String? {
        guard deferred.isEmpty == false, config.enabled != "off" else { return nil }
        guard config.listing != "off" else { return nil }
        let budget = manifestBudget(config: config, contextLength: contextLength)
        let listing = renderListing(deferred)
        if estimateTokens(text: listing) <= budget || config.listing == "on" {
            return listing
        }
        let names = renderNames(deferred)
        if estimateTokens(text: names) <= budget {
            return names
        }
        return nil
    }
}
