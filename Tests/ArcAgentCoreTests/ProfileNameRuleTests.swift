import ArcToolKit
import Testing
// Selective: `ArcAgentCore` is also an enum type, so the module cannot be
// qualified here, and both modules export `validateProfileName`.
import func ArcAgentCore.validateProfileName

// MARK: - The canonical profile-name rule

extension ArcCoreTestRoot {
    /// The rule moved to `ArcToolKit` (GROUNDZERO slice 7) so it lives in a
    /// target that cannot do I/O. Nothing in the tree pinned its semantics
    /// before this, which is why the rule is asserted here directly rather
    /// than through a roster tool: a name that `ProfileName` accepts is a name
    /// that addresses a profile directory.
    ///
    /// The last test is the one that matters for the move: core's free
    /// function must be a *delegation*, not a second copy. Two copies would
    /// let the validator a caller uses disagree with the one `ProfileName`
    /// validates with.
    @Suite("Profile name rule")
    struct ProfileNameRuleTests {

        /// Valid at the boundaries: two characters, sixty-four characters, a
        /// leading digit, a trailing separator, and the two names the journal's
        /// D2 called out as names an upgrade must not invalidate.
        private static let valid = [
            "ab",
            "a1",
            "3d-artist",
            "a_b",
            "a_",
            "a-",
            "default",
            String(repeating: "a", count: 63) + "9",
            String(repeating: "a", count: 64),
        ]

        /// Invalid for every distinct reason the rule has: too short, too long,
        /// a leading separator, uppercase, an interior character the rule does
        /// not allow, a non-ASCII scalar, a combining sequence, and a trailing
        /// newline (the ICU pattern this replaced rejected it, so this rule
        /// must too).
        private static let invalid = [
            "",
            "a",
            "-ab",
            "_ab",
            "Ab",
            "aB",
            "a b",
            "a.b",
            "a/b",
            "aé",
            "a\u{0301}b",
            "ab\n",
            String(repeating: "a", count: 65),
        ]

        /// The kit's rule. Wrapped in a helper so a module-qualified call never
        /// appears inside an `#expect` condition (the macro cannot carry one).
        private func kitRule(_ name: String) -> Bool {
            ArcToolKit.validateProfileName(name)
        }

        @Test("names the roster accepts, with the type that carries them")
        func acceptsValidNames() {
            for name in Self.valid {
                #expect(kitRule(name), "\(name) is a valid name")
                #expect(ProfileName(name) != nil, "\(name) wraps as a ProfileName")
                #expect(ProfileName(name)?.rawValue == name)
            }
        }

        @Test("names the roster refuses, with the type that refuses them")
        func refusesInvalidNames() {
            for name in Self.invalid {
                #expect(kitRule(name) == false, "\(name.debugDescription) is not a name")
                #expect(ProfileName(name) == nil, "\(name.debugDescription) does not wrap")
            }
        }

        @Test("core's free function delegates to the kit's rule")
        func coreDelegatesToTheKit() {
            for name in Self.valid + Self.invalid {
                let fromCore = validateProfileName(name)
                let fromKit = kitRule(name)
                #expect(fromCore == fromKit, "\(name.debugDescription): core and the kit disagree")
            }
        }
    }
}
