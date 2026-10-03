import WebUICore

// MARK: - EventData + checked
//
// The engine sends `checked` (checkbox/radio change frames) as a JSON
// boolean, never a string. `EventData.string(_:)` only matches `.string`
// values, so every `event.string("checked") == "true"` comparison was
// silently always-false — toggles everywhere (settings switches, tool
// sets, skill locks, sidebar chips, plugin toggles) appeared dead.
// This accessor reads the boolean channel; `nil` means the frame carried
// no checked state.

extension EventData {
    /// The boolean `checked` value from a change frame, or nil when absent
    /// (or not a boolean).
    public var checked: Bool? {
        if case .bool(let value)? = data["checked"] { return value }
        return nil
    }
}
