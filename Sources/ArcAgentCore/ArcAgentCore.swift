/// The core library for ARC Agent.
///
/// This module contains the agent loop, tool registry, provider profiles,
/// session management, and all other subsystems described in VISION.md.
///
/// For now it is a stub. Each subsystem will be fleshed out incrementally
/// as we validate the architecture through prototypes.

public struct ArcAgentCore {

    /// The current library version.
    public static let version = "0.0.0"

    /// Create a new core instance.
    public init() {}

    /// A placeholder that will eventually become ``run_conversation()``.
    public func greet() -> String {
        "ARC Agent Core v\(Self.version) — ready for exploration."
    }
}
