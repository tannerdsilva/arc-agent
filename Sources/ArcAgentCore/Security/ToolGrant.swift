// MARK: - ToolGrant
//
// Authority is a value, not a process-global switch. A tool that mutates an
// authority-bearing surface takes a `ToolGrant` at construction time and can
// only ever exercise what the grant says it may — there is no ambient read to
// fall back on and no re-read to disagree with.
//
// The refusal sentences are the operator-facing strings the gate has always
// emitted (`AgentPowers.profileWriteRefusal(file:)`); they are reproduced
// byte-for-byte here because the settings UI and the tests quote them. Do not
// reword them.
//
// ## Encoding of "profile editing is off"
//
// The gate has two independent locks: the global `profileEdit` switch and the
// per-file `lockedProfileFiles` list. A grant carries only the *result* — the
// set of documents this caller may edit — so the global switch is encoded as
// the empty set, which is exactly what it means. A profile that has all four
// documents individually locked therefore reads back as the global sentence
// (the surface is fully closed either way); every other configuration maps
// one-to-one.

/// What one caller may do to the profile's authority-bearing surfaces.
public struct ToolGrant: Sendable, Hashable {

    /// The profile this grant is for.
    public let profile: ProfileName

    /// The documents this caller may write. Empty means profile editing is
    /// off globally.
    public let editableDocuments: Set<ProfileFile>

    /// Whether this caller may create or edit skills.
    public let mayManageSkills: Bool

    /// Create a grant.
    ///
    /// Defaults to a fully-editable profile with no skill management, i.e. the
    /// value of a gate that has never been locked down.
    public init(
        profile: ProfileName,
        editableDocuments: Set<ProfileFile> = Set(ProfileFile.allCases),
        mayManageSkills: Bool = false
    ) {
        self.profile = profile
        self.editableDocuments = editableDocuments
        self.mayManageSkills = mayManageSkills
    }

    /// The refusal reason for writing `file`, or `nil` when allowed.
    ///
    /// Byte-identical to `AgentPowers.profileWriteRefusal(file:)` for every
    /// configuration except "global lock on OR all four individually locked",
    /// which share the empty set — see the note above.
    public func refusal(for file: ProfileFile) -> String? {
        if editableDocuments.contains(file) { return nil }
        if editableDocuments.isEmpty {
            return "Refused: profile editing is locked in Settings (Agent powers → Profile). "
                + "The agent cannot modify MEMORY/USER/SOUL/AGENTS while 'Agent can edit profile' is off."
        }
        return "Refused: \(file.displayName) is locked in Settings (Agent powers → Profile). "
            + "Unlock it there before editing."
    }

    /// The refusal reason for writing the document `path` names, or `nil` when
    /// the path is not one of the four documents or the grant allows it.
    ///
    /// This is the shape the arbitrary-executor tools (`patch`, `terminal`,
    /// `execute_code`) need: they hold a path or a command string, never a
    /// ``ProfileFile``.
    public func refusal(forPath path: String) -> String? {
        guard let file = ProfileFile.at(path: path) else { return nil }
        return refusal(for: file)
    }
}
