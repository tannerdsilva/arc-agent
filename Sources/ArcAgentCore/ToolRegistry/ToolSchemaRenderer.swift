import Foundation

/// The one schema path: registry entries in, OpenAI function-schema dicts out.
///
/// Three renderers used to exist — ``ToolRegistry``'s requirement plus its
/// default implementation, `MutableToolRegistry`'s override, and
/// ``ProgressiveToolDisclosure``'s prompt composition. Any pair of them could
/// drift, and two already had (F2, F3). This type is the single implementation,
/// and the protocol requirement is gone, so a registry can no longer supply a
/// fourth.
///
/// ## Why this is stateless
///
/// A memo was designed, measured, and is **not expressible** under Swift 6
/// region isolation. The rendered array is `[[String: Any]]`, and `Any` is not
/// `Sendable`: a value stored behind shared state cannot also escape to the
/// caller. Storing it in a `Mutex` inside a `Sendable` final class fails codegen
/// (not typecheck) with
///
///     error: 'inout sending' parameter '$0' is accessible to code in the
///     current isolation context at end of function [#RegionIsolation]
///
/// and neither remaining escape is available: an `@unchecked Sendable` box is
/// forbidden by the First Law, and an actor that returns the array it retains
/// hits the same region rule. So rendering is a pure function, recomputed per
/// call, with no cache, no revision key, and no counters.
public enum ToolSchemaRenderer {

    /// The eager array: every tool, filtered by enabled/disabled and by
    /// ``ToolAvailability``.
    ///
    /// - Parameters:
    ///   - registry: The surface to render.
    ///   - enablement: The one enablement decision (``ToolEnablement``) — a
    ///     disabled toolset, the per-tool overrides, or neither.
    ///   - enabled: A toolset allow-list projection. Empty admits every
    ///     non-disabled toolset. This is a *narrowing on top of* `enablement`,
    ///     not a second enablement decision: it cannot re-enable a tool the
    ///     resolver refused.
    /// - Returns: One OpenAI function-calling schema per surviving tool, in
    ///   `allTools` order.
    public static func eagerSchemas(
        registry: any ToolRegistry,
        enablement: ToolEnablementConfig,
        enabled: Set<String> = []
    ) -> [[String: Any]] {
        // one environment read per render, not one per tool.
        let env = ProcessInfo.processInfo.environment
        return registry.allTools
            .filter { entry in
                // the shared verdict: the same call dispatch enforces.
                guard ToolEnablement.isEnabled(
                    tool: entry.name, toolset: entry.toolset, config: enablement
                ) else { return false }

                // If enabled is non-empty, toolset must be in it.
                if !enabled.isEmpty {
                    guard enabled.contains(entry.toolsetName) else { return false }
                }

                // a tool whose declared requirement is unmet is not advertised.
                guard entry.availability.unavailableReason(env: env) == nil else { return false }

                return true
            }
            .map { schema(for: $0.tool) }
    }

    /// The prompt array: eager plus progressive disclosure.
    ///
    /// Core tools stay; deferrable tools are replaced by the bridge trio, and
    /// the manifest rides in the `tool_search` description. When nothing is
    /// deferrable (or the feature is off) the result is byte-identical to the
    /// eager layout.
    ///
    /// - Parameters:
    ///   - registry: The surface to render.
    ///   - enablement: The one enablement decision (``ToolEnablement``).
    ///   - config: The disclosure policy — which toolsets defer, how the
    ///     manifest degrades.
    ///   - contextLength: The model's window, for the manifest budget. `nil`
    ///     falls back to 200K.
    /// - Returns: Visible schemas in `allTools` order, then
    ///   `tool_search`/`tool_describe`/`tool_call` when anything deferred.
    public static func promptSchemas(
        registry: any ToolRegistry,
        enablement: ToolEnablementConfig,
        config: ToolSearchConfig,
        contextLength: Int?
    ) -> [[String: Any]] {
        let candidates = registry.allTools
            .filter { ToolEnablement.isEnabled(tool: $0.name, toolset: $0.toolset, config: enablement) }
            .map { $0.tool }
        // one environment read per render; the policy evaluates it per tool.
        let (visible, deferred) = DeferredToolPolicy.plan(
            entries: candidates, config: config, env: ProcessInfo.processInfo.environment)
        guard deferred.isEmpty == false, config.enabled != "off" else {
            // Eager path — identical output to the plain registry rendering.
            return visible.map { schema(for: $0) }
        }
        var schemas = visible.map { schema(for: $0) }
        schemas.append(toolSearchSchema(manifest: ProgressiveToolDisclosure.manifest(
            deferred: deferred, config: config, contextLength: contextLength)))
        schemas.append(toolDescribeSchema())
        schemas.append(toolCallSchema())
        return schemas
    }

    /// OpenAI function-schema dict for a tool (shared by the core agent,
    /// the disclosure path, and the webui `tool_describe` bridge translation).
    ///
    /// This is the single per-tool shape. Key order and values are the wire
    /// contract: the prompt array is pinned by digest in
    /// `ToolSurfaceInventoryTests`, so a change here is a declared delta.
    public static func schema(for entry: any AgentTool) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": entry.name,
                "description": entry.description,
                "parameters": entry.schema.asDictionary(),
            ] as [String: Any],
        ] as [String: Any]
    }

    /// The `tool_search` bridge schema, with the manifest appended to its
    /// description.
    ///
    /// `entry` is bound once: the old form constructed ``ToolSearchTool/entry()``
    /// three times per render, and each call allocates a fresh dependency slot
    /// (F13).
    static func toolSearchSchema(manifest: String?) -> [String: Any] {
        let entry = ToolSearchTool.entry()
        let description = manifest.map { "\(entry.description)\n\n\($0)" } ?? entry.description
        return [
            "type": "function",
            "function": [
                "name": entry.name,
                "description": description,
                "parameters": entry.schema.asDictionary(),
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
                    + "tool directly: guardrails, approvals, and tool policy rules all apply. "
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
