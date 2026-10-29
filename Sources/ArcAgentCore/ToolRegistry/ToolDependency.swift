import Synchronization

// MARK: - ToolDependency

/// A late-bound slot for one dependency of one tool surface.
///
/// GROUNDZERO slice 6 deleted the last twelve `nonisolated(unsafe) static var`
/// process globals in `Tools/`. Every one of them was the same shape: the
/// agent creates a resource *after* the registry exists (the session's
/// ``TodoStore``, the ``DelegationManager``, the kanban board, the session
/// store, the delivery path), then points the tool that needs it at the
/// resource. The registry could not be finished afterwards — ``ArcAgent``'s
/// configuration holds `any ToolRegistry` and ``MutableToolRegistry`` is a
/// value — so the pointer lived in a process global and the last surface to
/// start won.
///
/// A box is that same late binding, moved from process-global to per-agent: it
/// is a reference, so copying the tool entry copies the *slot*, and the agent
/// that owns the resource fills the slot the registry captured.
///
/// Locking is `Synchronization.Mutex` — the Swift standard library's, not a
/// third-party type — so this stays `Sendable` without `@unchecked`: the
/// compiler checks the guarantee instead of the reader.
///
/// ```swift
/// let store = ToolDependency<TodoStore>()   // registry captures this
/// store.set(TodoStore())                    // agent fills it later
/// store.get()                               // tool body reads it
/// ```
public final class ToolDependency<Value: Sendable>: Sendable {

    private let box: Mutex<Value?>

    /// Create a slot, empty unless an initial value is given.
    public init(_ initial: Value? = nil) {
        self.box = Mutex(initial)
    }

    /// Fill (or, with `nil`, clear) the slot.
    ///
    /// Last write wins, per agent — one agent's fill cannot reach another
    /// agent's slot.
    public func set(_ value: Value?) {
        box.withLock { slot in slot = value }
    }

    /// Read the slot, `nil` when nothing has been bound yet.
    public func get() -> Value? {
        box.withLock { slot in slot }
    }
}

// MARK: - ToolDependencies

/// The per-agent dependency slots of one tool surface.
///
/// ``ArcAgentCore/buildRegistry(context:profiles:memory:sessions:messaging:groupChats:kanban:delivery:dependencies:)``
/// creates (or accepts) one bundle, hands each slot to the tool that needs it,
/// and the bundle rides the registry itself — a surface built by that builder
/// conforms to ``ToolDependencyCarrying``, so ``ArcAgent`` adopts **the same**
/// slots instead of inventing a second set. That is what makes the invariant
/// true by construction rather than by convention at eight call sites:
/// *the agent's slots are the tools' slots*.
///
/// A caller that owns a resource before building the surface (the daemon's
/// delivery manager, a test with a fixture board) fills the slot on the bundle
/// it passes in; a caller that creates the resource afterwards (the agent's
/// own ``TodoStore`` and ``DelegationManager``) lets ``ArcAgent`` fill it.
public struct ToolDependencies: Sendable {

    /// The session-scoped todo list `todo` reads and writes. Filled by
    /// ``ArcAgent`` (one store per agent instance).
    public let todoStore: ToolDependency<TodoStore>

    /// The store `session_search` reads. Filled by the builder: the store is a
    /// constructor parameter, and a surface searches what its caller owns.
    public let sessionStore: ToolDependency<any SessionStore>

    /// The manager `delegate_task`, `list_children`, `steer_child` and
    /// `stop_child` act through. Filled by ``ArcAgent``.
    public let delegationManager: ToolDependency<DelegationManager>

    /// The board the `kanban_*` tools act on. Filled by the builder when its
    /// caller supplies one; a surface built without a board carries the tools
    /// but they report that no board is available.
    public let kanbanBoard: ToolDependency<any KanbanBoard>

    /// The registry `tool_search` searches. Filled by the builder with the
    /// registry it just built, then re-pointed by ``ArcAgent`` at the agent's
    /// own registry (which may carry plugin tools) — the self-reference the
    /// plan listed as a blocker, resolved without a special case.
    public let toolSearchRegistry: ToolDependency<any ToolRegistry>

    /// The delivery path `send_message` acts through. Filled by whoever owns
    /// one (the daemon's session host); empty in a surface with no delivery.
    public let sendMessageDelivery: ToolDependency<DeliveryManager>

    /// Resolves a bare platform name to its home chat id for `send_message`.
    public let homeChatResolver: ToolDependency<SendMessageTool.HomeChatResolver>

    /// Overrides the `execute_code` script timeout (seconds). Empty in
    /// production (the tool's default applies); tests fill it.
    public let executeCodeTimeout: ToolDependency<Double>

    /// Create a bundle of empty slots.
    public init(
        todoStore: ToolDependency<TodoStore> = ToolDependency(),
        sessionStore: ToolDependency<any SessionStore> = ToolDependency(),
        delegationManager: ToolDependency<DelegationManager> = ToolDependency(),
        kanbanBoard: ToolDependency<any KanbanBoard> = ToolDependency(),
        toolSearchRegistry: ToolDependency<any ToolRegistry> = ToolDependency(),
        sendMessageDelivery: ToolDependency<DeliveryManager> = ToolDependency(),
        homeChatResolver: ToolDependency<SendMessageTool.HomeChatResolver> = ToolDependency(),
        executeCodeTimeout: ToolDependency<Double> = ToolDependency()
    ) {
        self.todoStore = todoStore
        self.sessionStore = sessionStore
        self.delegationManager = delegationManager
        self.kanbanBoard = kanbanBoard
        self.toolSearchRegistry = toolSearchRegistry
        self.sendMessageDelivery = sendMessageDelivery
        self.homeChatResolver = homeChatResolver
        self.executeCodeTimeout = executeCodeTimeout
    }
}

// MARK: - ToolDependencyCarrying

/// A registry that carries the dependency slots its tools were built with.
///
/// ``ArcAgent`` reads this instead of taking a second, separately-passed
/// bundle: a caller that hands the agent `try buildRegistry(...)` gets the
/// slots that builder created, so `todo`'s store and the agent's store cannot
/// drift apart. A surface assembled some other way simply does not conform and
/// the agent falls back to a fresh bundle.
public protocol ToolDependencyCarrying: Sendable {

    /// The slots this surface's tools were built with.
    var toolDependencies: ToolDependencies { get }
}

/// The built-in tier carries the bundle it built its tools with.
extension CompileTimeToolRegistry: ToolDependencyCarrying {}

/// The runtime tier forwards its built-in tier's bundle: plugin tools carry no
/// slots of their own, and a surface must have exactly one bundle.
extension MutableToolRegistry: ToolDependencyCarrying {}
