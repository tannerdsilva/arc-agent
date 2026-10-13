import Foundation

// MARK: - Personalities (reference `features/personality.md`, `/personality`)

/// A named personality overlay from `agent.personalities` in config.
///
/// Two shapes are supported (arc parity):
/// - a plain string — the overlay IS the system-prompt text;
/// - a dict `{description?, system_prompt?, tone?, style?}` — composed as
///   the system prompt plus `Tone:` / `Style:` lines.
public enum PersonalityOverlay: Codable, Sendable, Equatable {
    case text(String)
    case defined(PersonalityDefinition)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .defined(try container.decode(PersonalityDefinition.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .defined(let def): try container.encode(def)
        }
    }

    /// Compose the effective overlay text (reference `_resolve_personality_prompt`).
    public func resolve() -> String {
        switch self {
        case .text(let text):
            return text
        case .defined(let def):
            var out = def.systemPrompt ?? ""
            if let tone = def.tone, !tone.isEmpty {
                out += out.isEmpty ? "Tone: \(tone)" : "\nTone: \(tone)"
            }
            if let style = def.style, !style.isEmpty {
                out += out.isEmpty ? "Style: \(style)" : "\nStyle: \(style)"
            }
            return out
        }
    }

    /// One-line preview (for listings).
    public func preview() -> String {
        switch self {
        case .text(let text):
            return String(text.prefix(50))
        case .defined(let def):
            return (def.description ?? def.systemPrompt ?? "").prefix(50).description
        }
    }
}

public struct PersonalityDefinition: Codable, Sendable, Equatable {
    public var description: String?
    public var systemPrompt: String?
    public var tone: String?
    public var style: String?

    public init(description: String? = nil, systemPrompt: String? = nil,
                tone: String? = nil, style: String? = nil) {
        self.description = description
        self.systemPrompt = systemPrompt
        self.tone = tone
        self.style = style
    }
}
