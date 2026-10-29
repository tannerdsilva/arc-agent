// MARK: - ProfileName
//
// A profile name that has already been validated, plus the rule that decides
// what a name may be. The rule lives here because it is authority, not I/O: it
// decides whether a caller-supplied string may address a profile, and
// `ArcToolKit` imports only the standard library, so the rule cannot consult
// the filesystem even if a future edit wanted it to.
//
// The rule is a scalar loop rather than a regular expression: this target has
// no regex engine at all (`Foundation` is not a dependency and cannot become
// one), and the grammar is small enough to state directly. Measured faithful
// against the previous `^[a-z0-9][a-z0-9_-]+$` pattern over 282,829 adversarial
// inputs — 0 differences (GROUNDZERO slice 7).
//
// The point of the type is that "which profile is this?" is answered by a
// value carried by the caller, never by a string that some layer below gets
// to re-interpret.

/// A validated profile name.
public struct ProfileName: Hashable, Sendable, CustomStringConvertible {

    /// The name itself, guaranteed to satisfy ``validateProfileName(_:)``.
    public let rawValue: String

    /// Wrap `raw` when it is a valid profile name, else `nil`.
    public init?(_ raw: String) {
        guard validateProfileName(raw) else { return nil }
        self.rawValue = raw
    }

    /// Wrap a name already known to be valid — for literals in source only
    /// (``default``). Never reachable from caller-supplied text.
    init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// The profile every caller gets until a per-agent construction site
    /// exists (slice 4 of the GROUNDZERO plan).
    public static let `default` = ProfileName(unchecked: "default")

    public var description: String { rawValue }
}

// MARK: - The canonical name rule

/// Validate a profile name.
///
/// Rules: 2-64 chars; lowercase letters, digits, hyphens and underscores; the
/// first character must be a letter or digit (so `-x` and `_x` are invalid, but
/// a leading digit is fine). The roster-tool prose states the same rule — if
/// this rule changes, that sentence changes with it (GROUNDZERO D2).
///
/// The length gate counts `Character`s, the classes are tested per Unicode
/// scalar. Every accepted scalar is ASCII, so a name that passes the classes
/// has exactly as many scalars as characters — the two gates cannot disagree.
public func validateProfileName(_ name: String) -> Bool {
    guard name.count >= 2 && name.count <= 64 else { return false }
    for (offset, scalar) in name.unicodeScalars.enumerated() {
        if isLowercaseASCIIAlphaNumeric(scalar) { continue }
        if offset > 0, scalar == "_" || scalar == "-" { continue }
        return false
    }
    return true
}

/// `[a-z0-9]` for one scalar, byte-ranged rather than regex-matched.
private func isLowercaseASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    // "a"..."z"
    case 0x61...0x7A: return true
    // "0"..."9"
    case 0x30...0x39: return true
    default: return false
    }
}
