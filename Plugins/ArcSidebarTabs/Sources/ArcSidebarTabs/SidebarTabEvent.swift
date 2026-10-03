// MARK: - SidebarTabEvent & SidebarFragment

/// An event delivered to a tab handler.
///
/// The host adapts its own event shape to this type at registration
/// time, so plugins never depend on application or web-engine internals.
public struct SidebarTabEvent: Sendable, Equatable {
    /// The `id` of the component that produced the event
    /// (the id the tab registered with `SidebarTabRegistration.on`).
    public let componentID: String

    /// The event type (e.g. `"click"`, `"change"`, `"submit"`, `"input"`).
    public let event: String

    /// Flat string payload (value, targetId, checked, …). Non-string
    /// payloads are flattened to their textual form where possible.
    public let values: [String: String]

    public init(componentID: String, event: String, values: [String: String] = [:]) {
        self.componentID = componentID
        self.event = event
        self.values = values
    }

    /// A flat string field (most payloads: `value`, `targetId`, `key`).
    public func string(_ key: String) -> String? {
        values[key]
    }

    /// A boolean field, parsed from `"true"` / `"false"`.
    public func bool(_ key: String) -> Bool? {
        values[key].flatMap(Bool.init)
    }
}

/// The regions a tab handler can ask the host to re-render.
///
/// Plugins never name the host's concrete region ids — the host maps
/// these semantic regions onto its own render pipeline.
public enum SidebarFragment: Sendable, Equatable {
    /// Replace the tab's panel content.
    case panel(String)

    /// Replace the tab's main page content.
    case main(String)

    /// No updates (e.g. after a side-effect that needs no re-render).
    case none
}
