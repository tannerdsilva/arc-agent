import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Progressive tool disclosure (S1 — reference `tools/tool_search` parity)

@Suite("ProgressiveToolDisclosure")
struct ProgressiveToolDisclosureTests {

    private func entry(
        _ name: String,
        toolset: String,
        description: String = "Does useful things with parameters and returns a result.",
        check: (@Sendable () -> Bool)? = nil
    ) -> ToolEntry {
        ToolEntry(
            name: name,
            toolset: toolset,
            description: description,
            schema: .object(properties: [:], required: []),
            handler: { _ in "ok" },
            checkFn: check
        )
    }

    // MARK: Policy

    @Test func coreToolsetsNeverDefer() {
        let config = ToolSearchConfig()
        for toolset in ["core", "browser", "file", "terminal", "tools", "web", "skills"] {
            #expect(!DeferredToolPolicy.isDeferred(name: "read_file", toolset: toolset, config: config))
        }
    }

    @Test func nonCoreToolsetsDefer() {
        let config = ToolSearchConfig()
        #expect(DeferredToolPolicy.isDeferred(name: "kanban_show", toolset: "kanban", config: config))
        #expect(DeferredToolPolicy.isDeferred(name: "mcp_tool", toolset: "mcp", config: config))
        #expect(DeferredToolPolicy.isDeferred(name: "image_generate", toolset: "media", config: config) == false)
        #expect(DeferredToolPolicy.isDeferred(name: "text_to_speech", toolset: "media", config: config) == false)
        #expect(DeferredToolPolicy.isDeferred(name: "transcription", toolset: "media", config: config))
    }

    @Test func bridgeNeverDefersAndOffDisables() {
        #expect(!DeferredToolPolicy.isDeferred(name: "tool_call", toolset: "tools", config: ToolSearchConfig()))
        #expect(!DeferredToolPolicy.isDeferred(name: "tool_search", toolset: "tools", config: ToolSearchConfig()))
        let off = ToolSearchConfig(enabled: "off")
        #expect(!DeferredToolPolicy.isDeferred(name: "kanban_show", toolset: "kanban", config: off))
    }

    @Test func customDeferredToolsetsWin() {
        let config = ToolSearchConfig(deferredToolsets: ["kanban"])
        #expect(DeferredToolPolicy.isDeferred(name: "kanban_show", toolset: "kanban", config: config))
        #expect(!DeferredToolPolicy.isDeferred(name: "mcp_tool", toolset: "mcp", config: config))
    }

    @Test func unavailableEntriesAreExcludedFromBothLists() {
        let withCheck = entry("gated", toolset: "kanban", check: { false })
        let config = ToolSearchConfig()
        let (visible, deferred) = DeferredToolPolicy.plan(
            entries: [entry("core_tool", toolset: "core"), withCheck],
            config: config)
        #expect(visible.map(\.name) == ["core_tool"])
        #expect(deferred.isEmpty)
    }

    // MARK: Config normalization

    @Test func configDecodesAndClamps() throws {
        let json = """
        {"enabled": "bogus", "threshold_pct": -5, "listing_max_tokens": 999999, "listing": "off"}
        """
        let c = try JSONDecoder().decode(ToolSearchConfig.self, from: Data(json.utf8))
        #expect(c.enabled == "auto")          // invalid binding normalized
        #expect(c.thresholdPct == 0)          // clamped to 0
        #expect(c.listingMaxTokens == 60_000) // clamped to max
        #expect(c.listing == "off")
    }

    @Test func configParsesSnakeCaseShapes() throws {
        let json = """
        {"enabled": true, "threshold_pct": 3}
        """
        let c = try JSONDecoder().decode(ToolSearchConfig.self, from: Data(json.utf8))
        #expect(c.enabled == "on")
        #expect(c.thresholdPct == 3)
        #expect(c.listingMaxTokens == 4000)
    }

    // MARK: Manifest

    @Test func manifestRendersGroupedListing() {
        let deferred = [
            entry("kanban_show", toolset: "kanban"),
            entry("kanban_list", toolset: "kanban"),
            entry("mcp_tool", toolset: "mcp", description: "Calls a remote MCP server tool by name with parameters and returns the result text."),
        ]
        let m = ProgressiveToolDisclosure.manifest(deferred: deferred, config: ToolSearchConfig(), contextLength: 200_000)
        #expect(m != nil)
        #expect(m!.contains("📦 kanban"))
        #expect(m!.contains("kanban_show"))
        #expect(m!.contains("mcp_tool"))
    }

    @Test func manifestDegradesToNamesThenNil() {
        let deferred = (0..<40).map { entry("tool_\($0)", toolset: "kanban") }
        // Names-only budget: full listing cannot fit, names must.
        let tiny = ToolSearchConfig(thresholdPct: 1.2, listingMaxTokens: 120)
        let m = ProgressiveToolDisclosure.manifest(deferred: deferred, config: tiny, contextLength: 10_000)
        #expect(m != nil)
        #expect(!m!.contains("—"))
        // Off listing → nil.
        let off = ToolSearchConfig(listing: "off")
        #expect(ProgressiveToolDisclosure.manifest(deferred: deferred, config: off, contextLength: 200_000) == nil)
    }

    @Test func shortDescClipsAtSentence() {
        let desc = "Loads the full schema of a deferred tool by exact name. Returns JSON."
        #expect(ProgressiveToolDisclosure.shortDesc(desc) == "Loads the full schema of a deferred tool by exact name")
    }

    @Test func manifestBudgetUsesContextPercentAndCap() {
        let c = ToolSearchConfig(thresholdPct: 10, listingMaxTokens: 1000)
        #expect(ProgressiveToolDisclosure.manifestBudget(config: c, contextLength: 100_000) == 1000) // 10% = 10k > cap
        let c2 = ToolSearchConfig(thresholdPct: 1, listingMaxTokens: 4000)
        #expect(ProgressiveToolDisclosure.manifestBudget(config: c2, contextLength: 100_000) == 1000) // 1% = 1k < cap
    }

    // MARK: Prompt schema assembly

    @Test func promptSchemasDeferAndAddBridge() {
        let registry = StubRegistry(allTools: [
            entry("read_file", toolset: "file"),
            entry("kanban_show", toolset: "kanban"),
        ])
        let schemas = ProgressiveToolDisclosure.buildPromptSchemas(
            registry: registry, disabled: [], config: ToolSearchConfig(), contextLength: 200_000)
        let names = schemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names.contains("read_file"))
        #expect(names.contains("tool_search"))
        #expect(names.contains("tool_describe"))
        #expect(names.contains("tool_call"))
        #expect(!names.contains("kanban_show"))
        // Manifest rides in tool_search description.
        let searchDesc = schemas.first { schema in
            guard let fn = schema["function"] as? [String: Any] else { return false }
            return (fn["name"] as? String) == "tool_search"
        }
        let searchDescription = (searchDesc?["function"] as? [String: Any])?["description"] as? String ?? ""
        #expect(searchDescription.contains("kanban_show"))
    }

    @Test func promptSchemasEagerWhenOff() {
        let registry = StubRegistry(allTools: [
            entry("read_file", toolset: "file"),
            entry("kanban_show", toolset: "kanban"),
        ])
        let schemas = ProgressiveToolDisclosure.buildPromptSchemas(
            registry: registry, disabled: [], config: ToolSearchConfig(enabled: "off"), contextLength: 200_000)
        let names = schemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names.contains("kanban_show"))
        #expect(!names.contains("tool_describe"))
        #expect(names.count == 2)
    }

    @Test func deferralStrictlyReducesSchemaTokens() {
        // Deferred tools carry rich schemas (the expensive ones in the real
        // registry); core tools are minimal. Deferring must strictly shrink
        // the prompt's tools array even after adding bridge + manifest.
        func rich(_ name: String, toolset: String) -> ToolEntry {
            ToolEntry(
                name: name,
                toolset: toolset,
                description: "Synchronizes with a remote service: lists, creates, and mutates entities "
                    + "with detailed parameter documentation covering every field, default, and edge case.",
                schema: .object(properties: [
                    "id": .string(description: "Entity identifier, alphanumeric, 8–64 chars"),
                    "state": .string(description: "One of pending, running, blocked, complete"),
                    "owner": .string(description: "Profile that owns the entity"),
                    "tags": .string(description: "Comma-separated labels for filtering"),
                    "note": .string(description: "Free-form annotation"),
                ], required: ["id", "state"]),
                handler: { _ in "ok" }
            )
        }
        func slim(_ name: String) -> ToolEntry {
            entry(name, toolset: "core")
        }
        let all = (0..<15).map { rich("deferred_\($0)", toolset: "kanban") } + (0..<15).map { slim("core_\($0)") }
        let registry = StubRegistry(allTools: all)
        let eager = registry.buildToolSchemas(enabled: [], disabled: [])
        let deferred = ProgressiveToolDisclosure.buildPromptSchemas(
            registry: registry, disabled: [], config: ToolSearchConfig(), contextLength: 200_000)
        let eagerTokens = ProgressiveToolDisclosure.estimateTokens(schemas: eager)
        let deferredTokens = ProgressiveToolDisclosure.estimateTokens(schemas: deferred)
        #expect(deferredTokens < eagerTokens)
    }

    @Test func bridgeSchemasHaveExpectedShape() {
        let describe = ProgressiveToolDisclosure.toolDescribeSchema()
        let fn = describe["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "tool_describe")
        let desc = fn?["description"] as? String
        #expect(desc?.contains("tool_call") == true)
        let call = ProgressiveToolDisclosure.toolCallSchema()
        let callFn = call["function"] as? [String: Any]
        #expect(callFn?["name"] as? String == "tool_call")
    }
}

/// Minimal in-test registry.
private struct StubRegistry: ToolRegistry {
    let allTools: [ToolEntry]
    func lookup(name: String) -> ToolEntry? { allTools.first { $0.name == name } }
    mutating func register(_ tool: ToolEntry) throws {}
    func buildToolSchemas(enabled: Set<String>, disabled: Set<String>) -> [[String: Any]] {
        allTools
            .filter { !disabled.contains($0.toolset) }
            .map { entry in
                [
                    "type": "function",
                    "function": [
                        "name": entry.name,
                        "description": entry.description,
                        "parameters": entry.schema.asDictionary(),
                    ] as [String: Any],
                ] as [String: Any]
            }
    }
}
