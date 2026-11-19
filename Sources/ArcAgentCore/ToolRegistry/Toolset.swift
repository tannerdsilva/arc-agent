/// A tool's grouping, carrying the two decisions that used to live in four
/// hand-maintained tables.
///
/// `toolset` was an untyped `String` and the join key of four closed sets:
/// the dispatcher's two reach rosters (`inProcessOnlyToolsets`,
/// `localMachineToolsets`) and the disclosure policy's two classification sets
/// (`defaultCoreToolsets`, `defaultDeferredToolsets`). Nothing tied a name in
/// one table to a name in another, so a typo disabled nothing and reported
/// nothing (F18), and a new toolset could pick up a reach nobody decided (F11).
///
/// This type makes the name the identity and the two decisions its payload, so
/// a toolset cannot be named without answering both questions. The catalog below
/// is **derived** from the four tables as they stood when the type landed, not
/// invented: `reach` is read off the two reach rosters, `disclosure` off the two
/// classification sets (deferred iff the name was in `defaultDeferredToolsets`).
///
/// T3a migrates the sites and keeps those tables in place; deriving the tables
/// from ``all`` is T3b. Until then the catalog is the single declaration of
/// intent and the tables are its legacy mirror.
public struct Toolset: Sendable, Hashable {

    /// Who may reach a toolset's tools.
    ///
    /// The two live values mirror the dispatcher's rosters exactly. ``network``
    /// exists so the vocabulary is closed and a future widening is a visible
    /// edit rather than an absence — nothing declares it today.
    public enum Reach: Sendable, Hashable {
        /// no socket caller, loopback included; the agent and the in-process
        /// carrier still reach it.
        case inProcessOnly

        /// a client on this machine may reach it.
        case loopback

        /// deliberately unused today.
        case network

        /// The operator-facing spelling. `Reach` decides access, so a surface
        /// that shows it must not invent a second vocabulary for it.
        public var displayName: String {
            switch self {
            case .inProcessOnly: return "in-process only"
            case .loopback: return "loopback"
            case .network: return "network"
            }
        }
    }

    /// Whether a toolset's tools render eagerly or behind the `tool_search` bridge.
    public enum Disclosure: Sendable, Hashable {
        case eager
        case deferred

        public var displayName: String {
            switch self {
            case .eager: return "eager"
            case .deferred: return "deferred"
            }
        }
    }

    /// The wire / config / display spelling (e.g. `"file"`).
    public let name: String

    /// Who may reach this toolset's tools.
    public let reach: Reach

    /// Whether this toolset's tools render eagerly or defer.
    public let disclosure: Disclosure

    /// Field-synthesis init, internal on purpose: a caller outside this file
    /// cannot mint a `Toolset` whose name disagrees with ``all``. Names enter
    /// through ``init(claimed:)``, which normalises to the canonical entry.
    init(name: String, reach: Reach, disclosure: Disclosure) {
        self.name = name
        self.reach = reach
        self.disclosure = disclosure
    }

    /// The canonical entry for a claimed name.
    ///
    /// A foreign name lands on ``Reach/inProcessOnly`` / ``Disclosure/eager`` and
    /// can therefore only ever narrow reach: a plugin that claims `file` gets
    /// arc's `file` entry (no wider than the roster allows), and a plugin that
    /// claims a name arc has never heard of gets the most restrictive answer
    /// rather than an accident.
    ///
    /// Canonical **lookup**, not field synthesis, is what makes
    /// `Toolset(claimed: "file") == .file` true and keeps ``Hashable`` honest:
    /// equality is the name plus the two derived decisions, so two instances
    /// that claim the same known name are the same value.
    public init(claimed name: String) {
        if let known = Self.all.first(where: { $0.name == name }) {
            self = known
        } else {
            self.init(name: name, reach: .inProcessOnly, disclosure: .eager)
        }
    }

    // MARK: - The catalog

    /// Every toolset arc recognises, in name order.
    ///
    /// 19 entries. The first 13 are arc's own vocabulary across the two reach
    /// rosters; `scheduling` is F11 (declared by `cronjob`, in neither roster —
    /// `.inProcessOnly` is its **current** behaviour, and widening it needs the
    /// sign-off tracked as T3c); the last two are admitted **foreign namespaces**
    /// (`swift-package-utilitykit` is the one installed plugin's claim, `plugins`
    /// arc's fallback for a manifest that omits the field), named here so a
    /// plugin's claim cannot expand reach.
    ///
    /// The disclosure sets also held six phantom names no tool ever declared —
    /// `sandbox`, `media`, `webhooks`, `weather`, `messaging_bot`, `swift-demo`.
    /// They are not catalog entries; a name nothing declares is not a toolset.
    public static let all: [Toolset] = [
        Toolset(name: "browser", reach: .inProcessOnly, disclosure: .eager),
        Toolset(name: "code_execution", reach: .inProcessOnly, disclosure: .eager),
        Toolset(name: "computer_use", reach: .inProcessOnly, disclosure: .eager),
        Toolset(name: "core", reach: .loopback, disclosure: .eager),
        Toolset(name: "delegation", reach: .loopback, disclosure: .eager),
        Toolset(name: "file", reach: .inProcessOnly, disclosure: .eager),
        Toolset(name: "kanban", reach: .loopback, disclosure: .deferred),
        Toolset(name: "mcp", reach: .loopback, disclosure: .deferred),
        Toolset(name: "messaging", reach: .loopback, disclosure: .deferred),
        Toolset(name: "plugins", reach: .loopback, disclosure: .eager),
        Toolset(name: "profile", reach: .loopback, disclosure: .deferred),
        Toolset(name: "project", reach: .loopback, disclosure: .deferred),
        Toolset(name: "scheduling", reach: .inProcessOnly, disclosure: .eager),
        Toolset(name: "skills", reach: .loopback, disclosure: .eager),
        Toolset(name: "swift-package-utilitykit", reach: .loopback, disclosure: .deferred),
        Toolset(name: "terminal", reach: .inProcessOnly, disclosure: .eager),
        Toolset(name: "todo", reach: .loopback, disclosure: .eager),
        Toolset(name: "tools", reach: .loopback, disclosure: .eager),
        Toolset(name: "web", reach: .loopback, disclosure: .eager),
    ]

    /// arbitrary filesystem reads and writes.
    public static let file = Toolset(name: "file", reach: .inProcessOnly, disclosure: .eager)

    /// shell execution and process control.
    public static let terminal = Toolset(name: "terminal", reach: .inProcessOnly, disclosure: .eager)

    /// in-process swift / script evaluation.
    public static let codeExecution = Toolset(
        name: "code_execution", reach: .inProcessOnly, disclosure: .eager)

    /// desktop control through the accessibility surface.
    public static let computerUse = Toolset(
        name: "computer_use", reach: .inProcessOnly, disclosure: .eager)

    /// the cdp browser driver.
    public static let browser = Toolset(name: "browser", reach: .inProcessOnly, disclosure: .eager)

    /// arc's own always-eager identity and memory tools.
    public static let core = Toolset(name: "core", reach: .loopback, disclosure: .eager)

    /// outbound web fetch and search.
    public static let web = Toolset(name: "web", reach: .loopback, disclosure: .eager)

    /// skill discovery and the unified `skill_manage`.
    public static let skills = Toolset(name: "skills", reach: .loopback, disclosure: .eager)

    /// the todo list.
    public static let todo = Toolset(name: "todo", reach: .loopback, disclosure: .eager)

    /// the `tool_search` bridge trio.
    public static let tools = Toolset(name: "tools", reach: .loopback, disclosure: .eager)

    /// subagent spawning, steering and stopping.
    public static let delegation = Toolset(
        name: "delegation", reach: .loopback, disclosure: .eager)

    /// project tracking; defers behind the bridge.
    public static let project = Toolset(name: "project", reach: .loopback, disclosure: .deferred)

    /// the kanban board; defers behind the bridge.
    public static let kanban = Toolset(name: "kanban", reach: .loopback, disclosure: .deferred)

    /// bot profiles and their context; defers behind the bridge.
    public static let profile = Toolset(name: "profile", reach: .loopback, disclosure: .deferred)

    /// telegram / bot delivery; defers behind the bridge.
    public static let messaging = Toolset(
        name: "messaging", reach: .loopback, disclosure: .deferred)

    /// mcp client tools; defer behind the bridge.
    public static let mcp = Toolset(name: "mcp", reach: .loopback, disclosure: .deferred)

    /// cron scheduling. `cronjob` is its only declarer; in neither reach roster,
    /// so `.inProcessOnly` is today's behaviour by accident (F11). widening it
    /// is T3c and needs sign-off.
    public static let scheduling = Toolset(
        name: "scheduling", reach: .inProcessOnly, disclosure: .eager)

    /// arc's fallback namespace for a plugin manifest that omits a toolset.
    public static let plugins = Toolset(name: "plugins", reach: .loopback, disclosure: .eager)

    /// the installed plugin's admitted foreign namespace (25 tools, all claiming
    /// this name as measured 2026-10-16).
    public static let swiftPackageUtilityKit = Toolset(
        name: "swift-package-utilitykit", reach: .loopback, disclosure: .deferred)
}
