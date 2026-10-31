import Foundation

/// A numeric cap that is either bounded or explicitly unlimited.
///
/// Before this type, "unlimited" was a sentinel each layer re-interpreted:
/// the settings UI wrote `-1`, the config accessors returned `Int.max`, and
/// `ToolGuardrails` read `Int.max > 0` as a *bounded* cap. `Limit` makes the
/// state representable so no consumer has to guess.
///
/// Decoding accepts any integer for backward compatibility — zero or a
/// negative value means ``unlimited`` — while encoding always emits the
/// canonical form: `0` for unlimited, the bound otherwise.
public enum Limit: Sendable, Equatable, Hashable {
    /// No cap: the work runs until it finishes on its own.
    case unlimited
    /// A positive cap.
    case bounded(Int)

    /// Normalize a raw integer: anything `<= 0` is ``unlimited``.
    public init(raw: Int) {
        self = raw > 0 ? .bounded(raw) : .unlimited
    }

    public var isUnlimited: Bool { self == .unlimited }

    /// The bound, or `nil` when unlimited.
    public var bound: Int? {
        if case .bounded(let n) = self { return n }
        return nil
    }

    /// The value an `Int`-shaped boundary needs (an agent loop bound):
    /// the bound, or `Int.max` for unlimited.
    public var effectiveValue: Int { bound ?? Int.max }

    /// The value written to a config file: the bound, or `0` for unlimited.
    public var encodedValue: Int { bound ?? 0 }
}

extension Limit: Codable {
    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }
}

/// The three budgets that bound one turn, in one section.
///
/// This replaces the four keys that used to describe the same idea
/// (`max_turns` at the root, `agent.max_turns`, `agent.maxIterations`, and
/// `guardrails.toolLoopCap`). A `nil` field means "not configured" and falls
/// back to the compiled default for that budget.
public struct Limits: Codable, Sendable, Equatable {
    /// Model rounds per turn (one round = one model call plus its tool calls).
    public var turns: Limit?
    /// Calls of one tool per turn before a synthetic result is returned.
    public var perToolCalls: Limit?
    /// Wall-clock seconds per turn.
    public var turnDuration: Limit?

    public init(turns: Limit? = nil, perToolCalls: Limit? = nil, turnDuration: Limit? = nil) {
        self.turns = turns
        self.perToolCalls = perToolCalls
        self.turnDuration = turnDuration
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.turns = try container.decodeIfPresent(Limit.self, forKey: .turns)
        self.perToolCalls = try container.decodeIfPresent(Limit.self, forKey: .perToolCalls)
        self.turnDuration = try container.decodeIfPresent(Limit.self, forKey: .turnDuration)
    }
}
