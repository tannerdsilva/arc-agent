import ArcToolKit

// MARK: - ToolContext
//
// The identity a tool call acts within, captured when the tool is built.
//
// Before this value, a tool answered "which profile am I?" by reading a
// process-global static (`AgentPowers.memoriesDirectory`, `MemoryTool.provider`,
// `ProfileManager()`), so two profiles in one process addressed the same
// documents. The context makes the answer a parameter: the scope is chosen by
// the caller that constructs the tool, and a tool body cannot re-interpret it.
//
// Everything here is a value and a `let`. A context cannot be widened after
// construction, and `grant` is the *only* authority a tool built from it has.

/// The calling identity one agent's tools act within.
///
/// Constructed per agent (GROUNDZERO §10): `ArcAgentCore.buildRegistry(context:…)`
/// builds value-typed tools that close over this context and the services they
/// need. It is not a service locator — every field is a value the caller must
/// already have.
public struct ToolContext: Sendable {

    /// The profile whose documents this call addresses.
    public let profile: ProfileName

    /// The session this call belongs to. Empty for callers with no session
    /// (CLI introspection, batch runs).
    public let sessionID: String

    /// The workspace root a call resolves relative paths against — the
    /// `AGENTS.md` that `profile_edit` reads and writes, and the project
    /// context directory. A path, not a `URL`: the Foundation-bearing targets
    /// own the `URL` form.
    public let workspace: String

    /// What this caller may mutate. Immutable for the life of the tool.
    public let grant: ToolGrant

    /// Capture `profile`'s scope.
    ///
    /// `grant` is not derived from `profile` here: authority is handed in by
    /// the caller that read the gate (`AgentPowers.grant(profile:)` in
    /// production), so a tool can never see a grant that disagrees with the
    /// documents it was given.
    public init(
        profile: ProfileName,
        sessionID: String,
        workspace: String,
        grant: ToolGrant
    ) {
        self.profile = profile
        self.sessionID = sessionID
        self.workspace = workspace
        self.grant = grant
    }
}
