// MARK: - Tool origin (provenance assigned at admission)

/// Where a registered tool came from.
///
/// ``ToolOrigin`` is *assigned by the registry that admits the tool*, never
/// declared by the tool itself: a plugin tool cannot claim to be compiled in,
/// because ``MutableToolRegistry/install(pluginTool:)`` stamps `.plugin(…)`
/// on the way in. ``admissionRank`` orders the tiers — a later tier may never
/// take a name an earlier one already holds.
///
/// ## Why this exists
///
/// A registry that stores bare `any AgentTool` values can refuse a duplicate
/// name but cannot afterwards answer "was this compiled in?" — the provenance
/// is dropped at insertion. ``RegisteredTool`` keeps it attached to the name.
public enum ToolOrigin: Sendable, Hashable {

    /// Compiled into the binary and registered by
    /// ``ArcAgentCore/buildDefaultRegistry()``.
    case builtin

    /// Loaded from an executable plugin at `~/.arc/plugins/<name>/`; carries
    /// the plugin's own name.
    case plugin(String)

    /// Minted by a ``ToolSource`` at assembly time — a pack reached through a
    /// carrier, or any other runtime source; carries the source's name.
    case source(String)

    /// Admission ordering only: a later tier may never take a name an earlier
    /// one holds.
    public var admissionRank: Int {
        switch self {
        case .builtin: return 0
        case .plugin: return 1
        case .source: return 2
        }
    }

    /// Whether this tool is compiled into the binary.
    ///
    /// The question the registry could not answer while it stored bare
    /// `any AgentTool` values: after admission, nothing could tell a built-in
    /// from a plugin.
    public var isCompiledIn: Bool {
        if case .builtin = self { return true }
        return false
    }
}
