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

/// How strongly a user-authored custom-context block should influence the
/// model. There is no literal per-token weight; the "effective weight" is an
/// emergent property of where a block sits in the assembled prompt and how it
/// is framed. These tiers map to that position + framing:
///
/// - `.high`:   promoted into the stable (rules) tier, imperative framing.
/// - `.medium`: rendered at the top of the context tier, instructive framing.
/// - `.low`:    rendered at the bottom of the context tier, advisory framing.
public enum CustomContextWeight: String, Codable, Sendable, CaseIterable, Hashable {
    case low, medium, high
}

/// One user-authored custom-context block: its text plus the effective weight
/// it should carry in the prompt.
///
/// Decodes tolerantly from either a bare JSON string (weight defaults to
/// `.medium`, preserving recipes persisted by earlier builds) or a
/// `{text, weight}` object.
public struct CustomContextItem: Codable, Sendable, Equatable {
    public var text: String
    public var weight: CustomContextWeight

    public init(text: String, weight: CustomContextWeight = .medium) {
        self.text = text
        self.weight = weight
    }

    private enum CodingKeys: String, CodingKey { case text, weight }

    public init(from decoder: Decoder) throws {
        // Tolerant decode: a bare string (weight defaults to `.medium`,
        // preserving recipes persisted by earlier builds) or a {text, weight}
        // object. Assign both stored properties on every path — do not mix a
        // delegating `self.init` with direct assignment.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.text = s
            self.weight = .medium
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decode(String.self, forKey: .text)
        self.weight = (try? c.decode(CustomContextWeight.self, forKey: .weight)) ?? .medium
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(weight, forKey: .weight)
    }
}

/// A partial set of per-segment overrides. A key that is absent inherits
/// from the next level up; `nil` at any level means "fully inherit".
///
/// `custom` carries the user-authored free-form context blocks attached to
/// a session (or a global/profile default). The prompt builder stitches
/// them into "Custom Context" sections, ranked by their effective weight.
///
/// ## Precedence
/// `session` > `profile` > `global` > built-in default (all on).
public struct ContextRecipe: Codable, Sendable, Equatable {
    public var segments: [ContextSegment: Bool]
    /// User-authored free-form context blocks (text + effective weight),
    /// stitched into ranked sections. Optional so older persisted recipes
    /// (without this key, or with bare-string blocks) still decode.
    public var custom: [CustomContextItem]?

    public init(segments: [ContextSegment: Bool] = [:], custom: [CustomContextItem]? = nil) {
        self.segments = segments
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey {
        case segments, custom
    }

    /// Tolerant decoding: an unknown segment key (e.g. the retired `.tools`
    /// segment persisted by an older build) is dropped instead of throwing,
    /// so a stale settings.json still loads. Each `custom` element is also
    /// decoded tolerantly (bare string or `{text, weight}`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var segments: [ContextSegment: Bool] = [:]
        if let raw = try c.decodeIfPresent([String: Bool].self, forKey: .segments) {
            for (key, value) in raw {
                if let seg = ContextSegment(rawValue: key) { segments[seg] = value }
            }
        }
        self.segments = segments
        self.custom = try c.decodeIfPresent([CustomContextItem].self, forKey: .custom)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: Bool] = [:]
        for (seg, value) in segments { raw[seg.rawValue] = value }
        try c.encode(raw, forKey: .segments)
        try c.encodeIfPresent(custom, forKey: .custom)
    }

    /// Non-optional view of the free-form blocks.
    public var customItems: [CustomContextItem] { custom ?? [] }

    public var isEmpty: Bool { segments.isEmpty && customItems.isEmpty }

    /// Stitch user-authored free-form rows into a `custom` block list: blank
    /// rows are dropped and exact duplicates removed (first occurrence wins,
    /// preserving its weight). nil when nothing was entered, so callers can
    /// distinguish "no override" from an override that carries a block.
    public static func stitchCustom(_ rows: [CustomContextItem]) -> [CustomContextItem]? {
        var items: [CustomContextItem] = []
        var seen = Set<String>()
        for row in rows {
            let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            items.append(CustomContextItem(text: trimmed, weight: row.weight))
        }
        return items.isEmpty ? nil : items
    }
}

/// The fully-resolved recipe: every segment has a concrete boolean, plus the
/// merged custom blocks (text + effective weight). This is what flows into
/// `ArcAgent.Configuration`; the prompt builder consumes it.
public struct ResolvedContextRecipe: Codable, Sendable, Equatable {
    public var segments: [ContextSegment: Bool]
    public var custom: [CustomContextItem]

    public init(segments: [ContextSegment: Bool] = [:], custom: [CustomContextItem] = []) {
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
    /// duplicates dropped (first occurrence wins) and empty blocks skipped.
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
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if seen.insert(trimmed).inserted {
                    out.custom.append(CustomContextItem(text: trimmed, weight: item.weight))
                }
            }
        }
        return out
    }
}
