import Foundation

/// The built-in context segments that can be included or excluded from the
/// system prompt on a per-session basis.
///
/// Each segment maps to one region of `ArcAgent.buildSystemPrompt`. The
/// keys here are what a user toggles in the "Context" editor.
public enum ContextSegment: String, CaseIterable, Codable, Sendable, Hashable {
    case memory          // "Memory (Your Persistent Notes)"
    case userProfile     // "User Profile"
    case skills          // "Skills (mandatory)" index
    case projectContext  // "Workspace & Project Context"
    case environment     // "## Environment"
    case guidance        // task-completion / parallel-tool / tool-aware rules
    case personality     // "## Personality" overlay
    case timestamp       // "Conversation started: ..." session line
    case tools           // "Available Tools" index

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
        case .tools: return "Tools index"
        }
    }
}

/// A partial set of per-segment overrides. A key that is absent inherits
/// from the next level up; `nil` at any level means "fully inherit".
///
/// ## Precedence
/// `session` > `profile` > `global` > built-in default (all on).
public struct ContextRecipe: Codable, Sendable, Equatable {
    public var segments: [ContextSegment: Bool]

    public init(segments: [ContextSegment: Bool] = [:]) {
        self.segments = segments
    }

    public var isEmpty: Bool { segments.isEmpty }
}

/// The fully-resolved recipe: every segment has a concrete boolean. This is
/// what flows into `ArcAgent.Configuration`; the prompt builder consumes it.
public struct ResolvedContextRecipe: Codable, Sendable, Equatable {
    public var segments: [ContextSegment: Bool]

    public init(segments: [ContextSegment: Bool] = [:]) {
        self.segments = segments
    }

    /// A recipe with every segment set to `value`.
    public init(all value: Bool = true) {
        self.segments = Dictionary(uniqueKeysWithValues: ContextSegment.allCases.map { ($0, value) })
    }

    public static let allOn = ResolvedContextRecipe(all: true)

    public func isEnabled(_ seg: ContextSegment) -> Bool {
        segments[seg] ?? true
    }

    /// Flatten the three override levels into a single concrete set.
    /// A segment resolves to the nearest explicit value, defaulting on.
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
        return out
    }
}
