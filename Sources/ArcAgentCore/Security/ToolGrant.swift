// MARK: - ToolGrant
//
// Authority is a value, not a process-global switch. A tool that mutates an
// authority-bearing surface takes a `ToolGrant` at construction time and can
// only ever exercise what the grant says it may — there is no ambient read to
// fall back on and no re-read to disagree with.
//
// The refusal sentences are the operator-facing strings the gate has always
// emitted; they are reproduced byte-for-byte here because the settings UI and
// the tests quote them. Do not reword them.
//
// ## The two locks are two values
//
// The gate has two independent locks: the global `profileEdit` switch and the
// per-file `lockedProfileFiles` list. A grant carries the *result* as a
// ``DocumentAccess``, which keeps them distinct:
//
// - `profileEdit: false` → `.none` → the global sentence;
// - `profileEdit: true` with all four locked → `.only([])` → the per-file
//   sentence for whichever document was asked about.
//
// Before ``DocumentAccess`` both arrived as an empty set and both produced the
// global sentence — defect D1 in the GROUNDZERO journal.

/// What one caller may do to the profile's authority-bearing surfaces.
public struct ToolGrant: Sendable, Hashable {

    /// The profile this grant is for.
    public let profile: ProfileName

    /// The documents this caller may write, and *why* the others are closed.
    public let documentAccess: DocumentAccess

    /// Whether this caller may create or edit skills.
    public let mayManageSkills: Bool

    /// Create a grant.
    ///
    /// Defaults to a fully-editable profile with no skill management, i.e. the
    /// value of a gate that has never been locked down.
    public init(
        profile: ProfileName,
        documentAccess: DocumentAccess = .all,
        mayManageSkills: Bool = false
    ) {
        self.profile = profile
        self.documentAccess = documentAccess
        self.mayManageSkills = mayManageSkills
    }

    /// The refusal reason for writing `file`, or `nil` when allowed.
    ///
    /// The sentence names the lock that actually applies: the global switch,
    /// or the one document. `.none` and `.only([…])` never share an answer.
    public func refusal(for file: ProfileFile) -> String? {
        switch documentAccess {
        case .all:
            return nil
        case .only(let files) where files.contains(file):
            return nil
        case .none:
            return "Refused: profile editing is locked in Settings (Agent powers → Profile). "
                + "The agent cannot modify MEMORY/USER/SOUL/AGENTS while 'Agent can edit profile' is off."
        case .only:
            return "Refused: \(file.displayName) is locked in Settings (Agent powers → Profile). "
                + "Unlock it there before editing."
        }
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
