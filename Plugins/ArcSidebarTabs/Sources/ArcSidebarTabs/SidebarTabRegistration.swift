// MARK: - SidebarTabRegistration

/// The registrar handed to a tab's `install(_:)`. A tab calls `on(_:)`
/// for every interactive component it renders; the host translates the
/// registration into its own event router without the tab knowing any
/// host types.
public protocol SidebarTabRegistrar: Sendable {
    /// Register a handler for all events on a fixed-id component.
    /// - Parameters:
    ///   - id: the component id the tab emitted in its HTML, e.g.
    ///     `"gh-refresh"`. Must be unique within the tab (the host
    ///     prefixes registrations so plugin ids never collide with
    ///     built-in components or other plugins).
    ///   - events: the event types to route (`click`, `change`,
    ///     `submit`, `input`, …).
    ///   - handler: the closure run on each matching event.
    func register(
        id: String,
        events: Set<String>,
        handler: @escaping @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    )
}

/// Value passed to `SidebarTab.install(_:)`.
public struct SidebarTabRegistration: Sendable {
    let registrar: any SidebarTabRegistrar

    public init(_ registrar: any SidebarTabRegistrar) {
        self.registrar = registrar
    }

    /// Events routed by default when `events:` is omitted.
    public static let defaultEvents: Set<String> = ["click", "change", "submit", "input"]

    /// Register a handler for a fixed-id component.
    public func on(
        _ id: String,
        events: Set<String> = SidebarTabRegistration.defaultEvents,
        _ handler: @escaping @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    ) {
        registrar.register(id: id, events: events, handler: handler)
    }
}
