// MARK: - DocumentAccess
//
// Which of a profile's four documents a caller may write. (GROUNDZERO defect
// D1.) Folded into this file because it is ``ToolGrant/documentAccess``'s type
// and has no other reason to exist.
//
// The gate has two independent locks — the global `profileEdit` switch and the
// per-file `lockedProfileFiles` list — and a grant used to carry only *the
// resulting set*, so `profileEdit: false` and "all four individually locked"
// both arrived as `[]` and both produced the global refusal sentence. The
// access decision was the same; the operator-facing text was a lie in the
// second case ("Agent can edit profile is off" when it was on).
//
// A three-case enum makes the two states distinct values, so the sentence is
// chosen by the state rather than inferred from an empty set.

/// Which documents a caller may write.
public enum DocumentAccess: Sendable, Hashable {

    /// Every document is writable.
    case all

    /// Profile editing is switched off globally — the whole surface is closed.
    case none

    /// Only these documents are writable. `only([])` is a real state: profile
    /// editing is on, and all four documents are locked individually.
    case only(Set<ProfileFile>)

    /// Whether `file` may be written.
    public func allows(_ file: ProfileFile) -> Bool {
        switch self {
        case .all:
            return true
        case .none:
            return false
        case .only(let files):
            return files.contains(file)
        }
    }
}

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
//
// The conversion from a configuration to a grant is *not* here: that reads a
// core value (`AgentPowersConfig`), so it stays in core
// (`AgentPowers.grant(profile:)`). This target holds only the value.

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
