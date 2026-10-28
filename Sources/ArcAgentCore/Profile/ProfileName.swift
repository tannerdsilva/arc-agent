// MARK: - ProfileName
//
// A profile name that has already been validated. The rule is not restated
// here: `init?` delegates to the free ``validateProfileName(_:)`` in
// `Profile.swift`, which stays the single definition of what a profile name
// may be (2–64 chars, lowercase alphanumerics, hyphens and underscores).
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
