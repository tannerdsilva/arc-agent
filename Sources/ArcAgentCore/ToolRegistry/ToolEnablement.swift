import Foundation

// MARK: - Per-tool enablement

/// The three lists that decide whether one tool is advertised and dispatchable.
///
/// The toolset switch (`tools.disabledToolsets`) is the norm and the default:
/// it is the switch an operator reaches for first, and it is coarse on purpose.
/// The two per-tool lists are the exception — a single tool turned off without
/// darkening its whole toolset.
///
/// This type exists so the two places that answer "may this tool run?" — the
/// schema renderer and `ArcAgent.dispatchToolCall` — cannot answer differently.
/// Before it, each site filtered `disabledToolsets` itself and the invariant
/// that dispatch enforces exactly what the schema advertised was a comment
/// rather than a value.
public struct ToolEnablementConfig: Sendable, Equatable {

    /// Toolsets removed from the surface. The coarse switch; beats everything.
    public var disabledToolsets: Set<String>

    /// Individual tool names removed from the surface.
    public var disabledTools: Set<String>

    /// Individual tool names pinned on — the later list in the precedence
    /// below. It cannot beat a disabled toolset.
    public var enabledTools: Set<String>

    public init(
        disabledToolsets: Set<String> = [],
        disabledTools: Set<String> = [],
        enabledTools: Set<String> = []
    ) {
        self.disabledToolsets = disabledToolsets
        self.disabledTools = disabledTools
        self.enabledTools = enabledTools
    }

    /// Nothing disabled: what a config written before per-tool lists existed
    /// means, and the identity the surface digest is pinned against.
    public static let none = ToolEnablementConfig()
}

/// The one enablement decision, shared by the schema path and dispatch.
///
/// ## Precedence
///
/// Highest first:
///
/// 1. **a disabled toolset.** The coarse switch wins outright. A per-tool
///    enable must not be able to smuggle a tool back into a surface the
///    operator turned off — that would make the toolset switch a lie, and it is
///    the switch every other surface (CLI `--toolsets`, profile allowlists,
///    the daemon's floor) also honours.
/// 2. **a per-tool disable**, unless the same name is also in
///    `enabledTools` — the explicit enable is the later statement.
/// 3. **else enabled.** The default surface is every tool; enablement is a
///    deny list, never an allow list.
///
/// A name in both per-tool lists therefore resolves *enabled* — the enable is
/// read last. That is the only precedence rule worth documenting, because it
/// is the only one a config can contradict itself over.
public enum ToolEnablement {

    /// Whether a tool is advertised and dispatchable.
    ///
    /// - Parameters:
    ///   - tool: The registered tool's name.
    ///   - toolset: The toolset the tool declares (``Toolset``, not its string
    ///     spelling — the resolver owns the name join).
    ///   - config: The three lists this process resolved.
    public static func isEnabled(
        tool: String,
        toolset: Toolset,
        config: ToolEnablementConfig
    ) -> Bool {
        // 1. the coarse switch: nothing re-enables inside a disabled toolset.
        if config.disabledToolsets.contains(toolset.name) { return false }
        // 2. per-tool deny, unless the same name is explicitly enabled.
        if config.disabledTools.contains(tool) { return config.enabledTools.contains(tool) }
        // 3. nothing denied it.
        return true
    }

    /// Names in the config that no registered tool matches — F18's silent
    /// no-op, surfaced instead of swallowed.
    ///
    /// A typo in `tools.disabledTools` disables nothing and, before this,
    /// said nothing: the panel showed every tool on and the operator's edit
    /// had no effect anywhere. Both per-tool lists are checked; toolset names
    /// are not, because a toolset may legitimately be configured before any
    /// tool declares it (a plugin that has not loaded yet) and `Toolset` is a
    /// closed catalog rather than a per-registry fact.
    ///
    /// - Returns: The unknown names, deduplicated and sorted.
    public static func unknownNames(
        in config: ToolEnablementConfig,
        catalog: [RegisteredTool]
    ) -> [String] {
        unknownNames(in: config, knownToolNames: Set(catalog.map(\.name)))
    }

    /// ``unknownNames(in:catalog:)`` for a surface that is already a name list
    /// (the web UI's tool model carries `any AgentTool`, not the registry's
    /// provenance-carrying wrappers).
    public static func unknownNames(
        in config: ToolEnablementConfig,
        knownToolNames: Set<String>
    ) -> [String] {
        config.disabledTools
            .union(config.enabledTools)
            .subtracting(knownToolNames)
            .sorted()
    }
}
