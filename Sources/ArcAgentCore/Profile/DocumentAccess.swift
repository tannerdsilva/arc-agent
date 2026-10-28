// MARK: - DocumentAccess
//
// Which of a profile's four documents a caller may write. (GROUNDZERO defect
// D1.)
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
