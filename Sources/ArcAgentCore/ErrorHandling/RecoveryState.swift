import Foundation

// MARK: - Per-turn recovery state + nudge texts (Hermes `conversation_loop`
// recovery counters and `_get_continuation_prompt` shapes).

/// Per-turn recovery counters. Reset at every turn boundary; limits mirror
/// Hermes' bounded-recovery philosophy (never loop forever on a bad model).
public struct TurnRecoveryState {
    /// Consecutive invalid-JSON tool-call injections (Hermes `_invalid_json_retries`).
    public var invalidJSONRetries = 0
    public static let maxInvalidJSONRetries = 3
    /// Consecutive fully-empty responses in one turn (~storm guard).
    public var emptyStormStreak = 0
    public static let emptyStormThreshold = 3
    /// Whether the primary transport was already rebuilt once this turn
    /// (Hermes `_try_recover_primary_transport` once-per-turn flag).
    public var primaryRecoveryAttempted = false
    /// Consecutive stale giveups this turn (kept across iterations).
    public var staleStreak = 0
    /// Rate-limit recoveries performed this turn (bounded).
    public var rateLimitRecoveries = 0
    public static let maxRateLimitRecoveries = 2

    public init() {}

    /// Success from the provider on any recovery-prone path → clear counters.
    public mutating func markProviderSuccess() {
        invalidJSONRetries = 0
        emptyStormStreak = 0
    }
}

/// Recovery nudge texts mirroring Hermes' conversation-loop nudges.
public enum RecoveryNudges {
    /// Invalid-JSON tool arguments: tell the model what broke and how to fix it
    /// (Hermes injects a tool result: "Error: Invalid JSON arguments. …").
    public static func invalidJSONToolResult(toolName: String, error: String) -> String {
        "Error: Invalid JSON arguments for tool '\(toolName)': \(error). Retry the tool call with valid JSON arguments."
    }

    /// Continuation prompt when a stream was cut off mid-tool-call
    /// (Hermes `_get_continuation_prompt`): the dropped calls are named so
    /// the model can continue exactly where it stopped.
    public static func continuationPrompt(droppedToolNames: [String]) -> String {
        var prompt = "The previous response was interrupted before it completed"
        if !droppedToolNames.isEmpty {
            prompt += " the call(s): " + droppedToolNames.joined(separator: ", ")
        }
        prompt += ". Continue exactly where you left off without repeating completed steps."
        return prompt
    }

    /// Reasoning-timeout nudge: thinking took too long with nothing to show.
    public static let reasoningTimeoutNudge = "The previous attempt took too long thinking and produced nothing. Try a different approach with less deliberation."

    /// Empty-response storm: after this many consecutive empty replies, the
    /// loop stops re-prompting (Hermes `empty_response_exhausted`).
    public static let emptyStormExhaustedMessage = "The model returned empty responses repeatedly. Please try again with a different phrasing or model."
}
