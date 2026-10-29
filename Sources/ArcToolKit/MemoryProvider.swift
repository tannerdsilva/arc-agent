/// A provider for the agent's persistent memory system.
///
/// ``MemoryProvider`` abstracts the storage of two memory files:
/// - **MEMORY.md** — the agent's persistent notes (environment facts, tool quirks, conventions)
/// - **USER.md** — the user's profile (name, role, preferences, style)
///
/// Both are injected into the system prompt at the start of each session and
/// updated when the agent calls the `memory` tool.
///
/// ## Design (Protocols First)
///
/// 1. **Protocol** — ``MemoryProvider`` (this protocol)
/// 2. **Concrete types** — `FileMemoryProvider` (in `ArcAgentCore`: it holds a
///    `URL` and touches the filesystem, which this target cannot)
/// 3. **Macros** — None needed
///
/// The protocol is intentionally minimal. If a second backend emerges (e.g. a
/// Tessera-backed store), the protocol is validated. If not, it may be
/// collapsed into the concrete type once the design is stable.
///
/// The protocol lives in `ArcToolKit`, which imports only the standard library,
/// so a memory *policy* expressed against it cannot open a file. The
/// implementations that do I/O stay in `ArcAgentCore`.
public protocol MemoryProvider: Sendable {

    /// Read the MEMORY.md content.
    func readMemory() async throws -> String

    /// Read the USER.md content.
    func readUser() async throws -> String

    /// Append text to MEMORY.md.
    func appendMemory(_ text: String) async throws

    /// Replace text in MEMORY.md (find-and-replace).
    func replaceMemory(old: String, new: String) async throws

    /// Overwrite MEMORY.md with the given content.
    func writeMemory(_ text: String) async throws

    /// Append text to USER.md.
    func appendUser(_ text: String) async throws

    /// Replace text in USER.md (find-and-replace).
    func replaceUser(old: String, new: String) async throws

    /// Overwrite USER.md with the given full text.
    func writeUser(_ text: String) async throws
}

// MARK: - Recall (arc memory-provider prefetch)

extension MemoryProvider {
    /// Semantic recall hook (reference `prefetch`): external memory providers
    /// override this to return context relevant to `query`; the built-in
    /// file provider needs no recall because its full memory block is
    /// already injected into the system prompt. Default: no recall.
    ///
    /// The default travels with the requirement: a conformer in any module
    /// gets it, so this stays in the target that declares the protocol.
    public func prefetch(query: String) async throws -> String { "" }
}
