import Foundation

/// Live, user-selectable agent settings (provider + reasoning effort) chosen
/// from the top bar. The agent re-reads this at the start of each turn and
/// rebuilds its LLM client when the provider/effort changed, so a selection
/// takes effect on the next message. Non-persistent (resets on process start).
public actor RuntimeSettings {

    public static let shared = RuntimeSettings()

    /// `low` | `medium` | `high` — sent as the model's `reasoning_effort`.
    private(set) var reasoningEffort: String = "medium"
    /// A user-selected provider override (nil = use the configured provider).
    private(set) var providerName: String?
    private(set) var providerBaseURL: String?

    public init() {}

    public func setEffort(_ effort: String) {
        reasoningEffort = effort
    }

    public func overrideProvider(name: String, baseURL: String?) {
        providerName = name
        providerBaseURL = baseURL
    }

    public func clearProvider() {
        providerName = nil
        providerBaseURL = nil
    }

    public func snapshot() -> (effort: String, providerName: String?, baseURL: String?) {
        (reasoningEffort, providerName, providerBaseURL)
    }
}
