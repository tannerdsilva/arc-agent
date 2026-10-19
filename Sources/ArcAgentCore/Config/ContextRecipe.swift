import Foundation

/// The built-in context segments that can be included or excluded from the
/// system prompt on a per-session basis.
///
/// Each segment maps to one region of `ArcAgent.buildSystemPrompt`. The
/// keys here are what a user toggles in the "Create session" panel.
///
/// The `.tools` segment is intentionally absent: tool availability is
/// controlled by the profile/global `disabledToolsets`, not a prompt-only
/// toggle. The "Available Tools" index is therefore always included.
public enum ContextSegment: String, CaseIterable, Codable, Sendable, Hashable {
    case memory          // "Memory (Your Persistent Notes)"
    case userProfile     // "User Profile"
    case skills          // "Skills (mandatory)" index
    case projectContext  // "Workspace & Project Context"
    case environment     // "## Environment"
    case guidance        // task-completion / parallel-tool / tool-aware rules
    case personality     // "## Personality" overlay
    case timestamp       // "Conversation started: ..." session line

    /// Human-facing label for the UI.
    public var label: String {
        switch self {
        case .memory: return "Memory"
        case .userProfile: return "User Profile"
        case .skills: return "Skills index"
        case .projectContext: return "Project context"
        case .environment: return "Environment"
        case .guidance: return "Guidance"
        case .personality: return "Personality"
        case .timestamp: return "Timestamp"
        }
    }
}

/// A partial set of per-segment overrides. A key that is absent inherits
/// from the next level up; `nil` at any level means "fully inherit".
///
/// `custom` carries the user-authored free-form context blocks attached to
/// a session (or a global/profile default). The prompt builder stitches
/// them into a single "## Custom Context" section.
///
/// ## Precedence
/// `session` > `profile` > `global` > built-in default (all on).
public struct ContextRecipe: Codable, Sendable, Equatable {
    public var segments: [ContextSegment: Bool]
    /// User-authored free-form context blocks, stitched into one section.
    /// Optional so older persisted recipes (without this key) still decode.
    public var custom: [String]?

    public init(segments: [ContextSegment: Bool] = [:], custom: [String]? = nil) {
        self.segments = segments
        self.custom = custom
    }

    /// Non-optional view of the free-form blocks.
    public var customItems: [String] { custom ?? [] }

    public var isEmpty: Bool { segments.isEmpty && customItems.isEmpty }

    /// Stitch user-authored free-form rows into a `custom` block list: blank
    /// rows are dropped and exact duplicates removed. nil when nothing was
    /// entered, so callers can distinguish "no override" from an override that
    /// carries a block.
    public static func stitchCustom(_ rows: [String]) -> [String]? {
        var items: [String] = []
        var seen = Set<String>()
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            items.append(trimmed)
        }
        return items.isEmpty ? nil : items
    }
}

/// The fully-resolved recipe: every segment has a concrete boolean, plus the
/// merged custom blocks. This is what flows into `ArcAgent.Configuration`;
/// the prompt builder consumes it.
public struct ResolvedContextRecipe: Codable, Sendable, Equatable {
    public var segments: [ContextSegment: Bool]
    public var custom: [String]

    public init(segments: [ContextSegment: Bool] = [:], custom: [String] = []) {
        self.segments = segments
        self.custom = custom
    }

    /// A recipe with every segment set to `value`.
    public init(all value: Bool = true) {
        self.segments = Dictionary(uniqueKeysWithValues: ContextSegment.allCases.map { ($0, value) })
        self.custom = []
    }

    public static let allOn = ResolvedContextRecipe(all: true)

    public func isEnabled(_ seg: ContextSegment) -> Bool {
        segments[seg] ?? true
    }

    /// Flatten the three override levels into a single concrete set.
    /// A segment resolves to the nearest explicit value, defaulting on.
    /// Custom blocks are concatenated (global < profile < session) with
    /// duplicates dropped and empty blocks skipped.
    public static func resolve(
        global: ContextRecipe? = nil,
        profile: ContextRecipe? = nil,
        session: ContextRecipe? = nil
    ) -> ResolvedContextRecipe {
        var out = ResolvedContextRecipe(all: true)
        for seg in ContextSegment.allCases {
            out.segments[seg] =
                session?.segments[seg]
                ?? profile?.segments[seg]
                ?? global?.segments[seg]
                ?? true
        }
        var seen = Set<String>()
        out.custom = []
        for items in [global?.customItems ?? [], profile?.customItems ?? [], session?.customItems ?? []] {
            for item in items {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if seen.insert(trimmed).inserted { out.custom.append(trimmed) }
            }
        }
        return out
    }
}
