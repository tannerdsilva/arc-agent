import Foundation

/// The kanban-agent domain model (docs/kanban-specs/01-domain-model.md).
///
/// All types are namespaced under ``KanbanAgent`` to keep the board's
/// vocabulary (`Card`, `Column`, `Root`) unambiguous next to the legacy
/// `KanbanTask` queue in `Kanban/`. The model is the phase-1 slice of the
/// kanban-agent design (docs/kanban-agent-design.md): value types only,
/// Swift 6 `Sendable`, lineage fields immutable by shape.
public enum KanbanAgent {}

// MARK: - Lane (§2)

extension KanbanAgent {

    /// A lane — the structural axis. Purely organizational; the agent owns
    /// lane assignments and they are stable (design doc §1).
    public struct Lane: Sendable, Codable, Equatable, Identifiable {
        public let id: String
        public var name: String

        public init(id: String = UUID().uuidString, name: String) {
            self.id = id
            self.name = name
        }
    }
}

// MARK: - Column (§3)

extension KanbanAgent {

    /// How cards move out of a column — the board's physics (design doc §1).
    public enum ColumnKind: String, Sendable, Codable, CaseIterable {
        /// The agent executes the card body here.
        case agentWork
        /// Parked until the user releases it.
        case humanWait
        /// Releases after a delay (`timerDuration`).
        case timerWait
        /// Absorbing; no outgoing edges.
        case terminal
    }

    /// A column — the semantic axis, authored by the user (design doc §1).
    public struct Column: Sendable, Codable, Equatable, Identifiable {
        public let id: String
        public var name: String
        public var kind: ColumnKind
        /// A reachable start for new/created cards.
        public var isEntry: Bool
        /// The board's mandatory triage column (invariant 3).
        public var isTriage: Bool
        /// `timerWait` only: the release delay.
        public var timerSeconds: Double?
        /// Stale-motion fallback target (invariant 4).
        public var defaultEdgeID: String?

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: ColumnKind,
            isEntry: Bool = false,
            isTriage: Bool = false,
            timerSeconds: Double? = nil,
            defaultEdgeID: String? = nil
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.isEntry = isEntry
            self.isTriage = isTriage
            self.timerSeconds = timerSeconds
            self.defaultEdgeID = defaultEdgeID
        }
    }
}

// MARK: - Edges (spec 02 §1)

extension KanbanAgent {

    /// Who decides an edge: the outcome (deterministic) or someone's policy.
    public enum EdgeDecision: String, Sendable, Codable {
        /// The outcome maps to the destination; the agent never judges.
        case deterministic
        /// Multiple destinations are valid; a policy picks.
        case policy
    }

    /// How a policy edge is resolved.
    public enum EdgePolicy: String, Sendable, Codable {
        /// The agent's judgment picks the edge.
        case agent
        /// Rule-based: first matching outcome label.
        case fixed
        /// Rotate through destinations by traversal count.
        case counter
    }

    /// A directed transition between columns (design doc §2).
    public struct Edge: Sendable, Codable, Equatable, Identifiable {
        public let id: String
        public let fromColumnID: String
        public let toColumnID: String
        public var decision: EdgeDecision
        /// Policy edges only.
        public var policy: EdgePolicy?
        /// Deterministic edges only: the outcome this edge carries.
        public var outcomeLabel: String?
        /// The mandatory "ask the user" edge (invariant 3) — target is the
        /// board's single `humanWait` column.
        public var isAskTheUser: Bool

        public init(
            id: String = UUID().uuidString,
            fromColumnID: String,
            toColumnID: String,
            decision: EdgeDecision,
            policy: EdgePolicy? = nil,
            outcomeLabel: String? = nil,
            isAskTheUser: Bool = false
        ) {
            self.id = id
            self.fromColumnID = fromColumnID
            self.toColumnID = toColumnID
            self.decision = decision
            self.policy = policy
            self.outcomeLabel = outcomeLabel
            self.isAskTheUser = isAskTheUser
        }
    }
}

// MARK: - Card (§4)

extension KanbanAgent {

    /// Whether a card can execute — the readiness dimension under position
    /// (design doc §1, "card position vs card state").
    public enum Readiness: String, Sendable, Codable, CaseIterable {
        case runnable
        case waitingOnChildren
        case running
        case done
    }

    /// How a parent's output reaches a child (design doc §3).
    public enum InputPassingMode: String, Sendable, Codable, CaseIterable {
        /// Pointer; the child reads the output from storage when working.
        case reference
        /// Agent-distilled text inlined in the child's input.
        case summary
        /// Raw copy, small outputs only.
        case inclusion
    }

    /// Declared output passing — on the child, never silent (design doc §3).
    public struct InputPassing: Sendable, Codable, Equatable {
        public var mode: InputPassingMode
        /// The parent card whose output this builds on.
        public var sourceCardID: String
        /// reference: artifact/record id; summary/inclusion: text.
        public var payload: String

        public init(mode: InputPassingMode, sourceCardID: String, payload: String) {
            self.mode = mode
            self.sourceCardID = sourceCardID
            self.payload = payload
        }
    }

    /// Who made a transition decision.
    public enum DecidedBy: String, Sendable, Codable {
        case deterministic
        case agent
        case fallback
    }

    /// One recorded move, appended for the life of the card (design doc §3).
    public struct TransitionRecord: Sendable, Codable, Equatable {
        public let edgeID: String
        public let fromColumnID: String
        public let toColumnID: String
        /// Required, non-empty.
        public let reasoning: String
        public let decidedBy: DecidedBy
        public let at: Date

        public init(
            edgeID: String, fromColumnID: String, toColumnID: String,
            reasoning: String, decidedBy: DecidedBy, at: Date = Date()
        ) {
            self.edgeID = edgeID
            self.fromColumnID = fromColumnID
            self.toColumnID = toColumnID
            self.reasoning = reasoning
            self.decidedBy = decidedBy
            self.at = at
        }
    }

    /// The structured output of an executed card.
    public struct CardResult: Sendable, Codable, Equatable {
        /// Free-text classification label — names a deterministic edge when
        /// one matches from the current column.
        public var outcome: String
        public var summary: String
        public var producedAt: Date

        public init(outcome: String, summary: String, producedAt: Date = Date()) {
            self.outcome = outcome
            self.summary = summary
            self.producedAt = producedAt
        }
    }

    /// A card — the unit of work (design doc §3). Position is (lane, column)
    /// with a separate readiness dimension; lineage fields are immutable
    /// after creation (`let`), so amnesia is impossible by shape.
    public struct Card: Sendable, Codable, Equatable, Identifiable {
        // Position
        public var laneID: String
        public var columnID: String
        public var readiness: Readiness

        // Body — the child task contract (design doc §5, Verb 2)
        public var goal: String
        public var input: InputPassing?
        public var doneCondition: String

        // Lineage — immutable after creation
        public let id: String
        /// nil = the root's first card, created by the user with the root.
        public let parentID: String?
        /// Every card belongs to exactly one root.
        public let rootID: String
        /// The edge it was generated along.
        public let birthEdgeID: String?
        /// Depth from the root, for the generation budget.
        public let generation: Int

        // Judgment memory
        /// Which transition brought the card to its current column.
        public var lastEdgeID: String?
        /// Per-column re-entry counts, feeding the cycle budget.
        public var traversalCounts: [String: Int]
        /// The reasoning for each move, oldest first.
        public var transitionProvenance: [TransitionRecord]

        // Output
        public var result: CardResult?
        /// Artifact ids — raw outputs live here, not in the body.
        public var attachments: [String]

        public init(
            id: String = UUID().uuidString,
            laneID: String,
            columnID: String,
            readiness: Readiness = .runnable,
            goal: String,
            input: InputPassing? = nil,
            doneCondition: String,
            parentID: String?,
            rootID: String,
            birthEdgeID: String? = nil,
            generation: Int = 0
        ) {
            self.id = id
            self.laneID = laneID
            self.columnID = columnID
            self.readiness = readiness
            self.goal = goal
            self.input = input
            self.doneCondition = doneCondition
            self.parentID = parentID
            self.rootID = rootID
            self.birthEdgeID = birthEdgeID
            self.generation = generation
            self.lastEdgeID = nil
            self.traversalCounts = [:]
            self.transitionProvenance = []
            self.result = nil
            self.attachments = []
        }
    }
}

// MARK: - Root (§5)

extension KanbanAgent {

    /// Root lifecycle: running, or one of the two terminal states (§7).
    public enum RootState: String, Sendable, Codable, CaseIterable {
        case running
        case green
        case yellow
    }

    /// Evidence chain for a green root (spec 06 §1): clause → cards → why.
    public struct EvidenceChain: Sendable, Codable, Equatable {
        public struct Entry: Sendable, Codable, Equatable {
            public var clause: String
            public var cardIDs: [String]
            public var reasoning: String

            public init(clause: String, cardIDs: [String], reasoning: String) {
                self.clause = clause
                self.cardIDs = cardIDs
                self.reasoning = reasoning
            }
        }

        public var entries: [Entry]
        public var evaluatedAt: Date

        public init(entries: [Entry], evaluatedAt: Date = Date()) {
            self.entries = entries
            self.evaluatedAt = evaluatedAt
        }
    }

    /// What the user must provide to resolve a yellow (spec 06 §2).
    public enum UserProvision: Sendable, Codable, Equatable {
        case decision(String)
        case credential(String)
        case information(String)
        case capability(String)
    }

    /// Structured "what's missing" report — required for yellow (§4).
    public struct MissingReport: Sendable, Codable, Equatable {
        public struct Attempt: Sendable, Codable, Equatable {
            public var cardID: String
            public var whatWasTried: String
            public var outcome: String

            public init(cardID: String, whatWasTried: String, outcome: String) {
                self.cardID = cardID
                self.whatWasTried = whatWasTried
                self.outcome = outcome
            }
        }

        public var attempts: [Attempt]
        public var blockingUnknown: String
        public var userMustProvide: UserProvision
        public var alternativesConsidered: [String]
        public var reportedAt: Date

        public init(
            attempts: [Attempt], blockingUnknown: String,
            userMustProvide: UserProvision,
            alternativesConsidered: [String] = [], reportedAt: Date = Date()
        ) {
            self.attempts = attempts
            self.blockingUnknown = blockingUnknown
            self.userMustProvide = userMustProvide
            self.alternativesConsidered = alternativesConsidered
            self.reportedAt = reportedAt
        }
    }

    /// A root — the user-owned intent whose tree is the agent's plan (§4).
    public struct Root: Sendable, Codable, Equatable, Identifiable {
        public let id: String
        public var title: String
        /// The constitution the agent judges against; one clause per line.
        public var definitionOfDone: String
        public var state: RootState
        /// The root's original card; the tree is derived by walking parents.
        public var firstCardID: String
        /// Green only.
        public var evidence: EvidenceChain?
        /// Yellow only.
        public var missingReport: MissingReport?
        /// The user's answer on resume, injected into the next evaluation.
        public var resumeContext: String?
        public var createdAt: Date

        public init(
            id: String = UUID().uuidString,
            title: String,
            definitionOfDone: String,
            state: RootState = .running,
            firstCardID: String,
            evidence: EvidenceChain? = nil,
            missingReport: MissingReport? = nil,
            resumeContext: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.definitionOfDone = definitionOfDone
            self.state = state
            self.firstCardID = firstCardID
            self.evidence = evidence
            self.missingReport = missingReport
            self.resumeContext = resumeContext
            self.createdAt = createdAt
        }
    }
}

// MARK: - Board settings (§1)

extension KanbanAgent {

    /// Per-board configuration. Defaults only — every field is user-editable
    /// via the board settings dropdown (spec 08 §1). Durations are stored as
    /// seconds (`Duration` is not `Codable`).
    public struct BoardSettings: Sendable, Codable, Equatable {
        /// Profile the board's agent turns run as; nil = daemon default.
        public var profile: String?
        /// Re-entries per column per card before triage routing (invariant 1).
        public var cycleBudget: Int
        /// Maximum generations from a root (design doc §5, Verb 2).
        public var maxDepth: Int
        /// Children minted per root.
        public var mintAllowance: Int
        /// Judge-unreachable fallback delay (invariant 4).
        public var staleMotionTimeoutSeconds: Double
        /// Delay before a triaged card re-runs (invariant 1).
        public var triageCooldownSeconds: Double

        public init(
            profile: String? = nil,
            cycleBudget: Int = 3,
            maxDepth: Int = 8,
            mintAllowance: Int = 25,
            staleMotionTimeoutSeconds: Double = 600,
            triageCooldownSeconds: Double = 300
        ) {
            self.profile = profile
            self.cycleBudget = cycleBudget
            self.maxDepth = maxDepth
            self.mintAllowance = mintAllowance
            self.staleMotionTimeoutSeconds = staleMotionTimeoutSeconds
            self.triageCooldownSeconds = triageCooldownSeconds
        }

        public static let `default` = BoardSettings()
    }
}

// MARK: - Board document (§1)

extension KanbanAgent {

    /// The persisted board: graph, lanes, roots, settings — cards are their
    /// own records (spec 03 §2), so the document stays small and
    /// replace-on-write stays cheap.
    public struct BoardDocument: Sendable, Codable, Equatable {
        public static let schemaVersion = 1

        /// Stable slug, e.g. "default".
        public let id: String
        public var name: String
        public var lanes: [Lane]
        public var columns: [Column]
        public var edges: [Edge]
        public var roots: [Root]
        public var settings: BoardSettings
        /// Bumped on every save; the store refuses stale writers.
        public var revision: Int
        public let schemaVersion: Int

        public init(
            id: String = "default",
            name: String = "Default",
            lanes: [Lane] = [],
            columns: [Column] = [],
            edges: [Edge] = [],
            roots: [Root] = [],
            settings: BoardSettings = .default,
            revision: Int = 0
        ) {
            self.id = id
            self.name = name
            self.lanes = lanes
            self.columns = columns
            self.edges = edges
            self.roots = roots
            self.settings = settings
            self.revision = revision
            self.schemaVersion = Self.schemaVersion
        }
    }

    /// The in-memory view: board document plus its cards, assembled by the
    /// store's read path (spec 01 §1).
    public struct Board: Sendable, Codable, Equatable {
        public var document: BoardDocument
        public var cards: [Card]

        public init(document: BoardDocument, cards: [Card] = []) {
            self.document = document
            self.cards = cards
        }
    }
}

// MARK: - Events (spec 03 §2)

extension KanbanAgent {

    /// Append-only audit record for every board mutation (spec 03 §2).
    public enum BoardEventKind: String, Sendable, Codable, CaseIterable {
        case transition
        case generate
        case evaluate
        case laneMove
        case graphEdit
        case rootStateChange
        case artifactAdd
        case cardCreate
        case settingsChange
    }

    public struct BoardEvent: Sendable, Codable, Equatable {
        /// Monotonic per-board sequence (= previous + 1).
        public let seq: Int
        public let kind: BoardEventKind
        public var cardID: String?
        /// JSON of the payload — typed per `kind` at the call site.
        public var payload: String
        public let at: Date

        public init(seq: Int, kind: BoardEventKind, cardID: String? = nil, payload: String, at: Date = Date()) {
            self.seq = seq
            self.kind = kind
            self.cardID = cardID
            self.payload = payload
            self.at = at
        }
    }
}

// MARK: - Validation (§7)

extension KanbanAgent {

    /// Typed validation failures, each nameable and testable (spec 01 §7).
    public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        case unknownColumn(cardID: String, columnID: String)
        case unknownLane(cardID: String, laneID: String)
        case unknownRoot(cardID: String, rootID: String)
        case unknownParent(cardID: String, parentID: String)
        case crossRootParent(cardID: String, parentID: String)
        case missingInput(cardID: String)
        case inputNotFromParent(cardID: String)
        case doneWithoutResult(cardID: String)
        case columnKindMismatch(columnID: String)
        case emptyGoal(cardID: String)
        case emptyDoneCondition(cardID: String)

        public var description: String {
            switch self {
            case .unknownColumn(let card, let column):
                return "card '\(card)' references unknown column '\(column)'"
            case .unknownLane(let card, let lane):
                return "card '\(card)' references unknown lane '\(lane)'"
            case .unknownRoot(let card, let root):
                return "card '\(card)' references unknown root '\(root)'"
            case .unknownParent(let card, let parent):
                return "card '\(card)' references unknown parent '\(parent)'"
            case .crossRootParent(let card, let parent):
                return "card '\(card)' has parent '\(parent)' from a different root"
            case .missingInput(let card):
                return "card '\(card)' has a parent but no declared input"
            case .inputNotFromParent(let card):
                return "card '\(card)' input source is not its parent"
            case .doneWithoutResult(let card):
                return "card '\(card)' is done but has no result"
            case .columnKindMismatch(let column):
                return "column '\(column)' has a kind-dependent field mismatch"
            case .emptyGoal(let card):
                return "card '\(card)' has an empty goal"
            case .emptyDoneCondition(let card):
                return "card '\(card)' has an empty done-condition"
            }
        }
    }
}

extension KanbanAgent.Card {
    /// Validate a card against its board context (spec 01 §7).
    public func validate(lanes: [KanbanAgent.Lane], columns: [KanbanAgent.Column], roots: [KanbanAgent.Root], cards: [KanbanAgent.Card]) -> [KanbanAgent.ValidationError] {
            var errors: [KanbanAgent.ValidationError] = []
            if !columns.contains(where: { $0.id == columnID }) {
                errors.append(.unknownColumn(cardID: id, columnID: columnID))
            }
            if !lanes.contains(where: { $0.id == laneID }) {
                errors.append(.unknownLane(cardID: id, laneID: laneID))
            }
            if !roots.contains(where: { $0.id == rootID }) {
                errors.append(.unknownRoot(cardID: id, rootID: rootID))
            }
            if let parentID {
                if let parent = cards.first(where: { $0.id == parentID }) {
                    if parent.rootID != rootID {
                        errors.append(.crossRootParent(cardID: id, parentID: parentID))
                    }
                } else {
                    errors.append(.unknownParent(cardID: id, parentID: parentID))
                }
                if input == nil {
                    errors.append(.missingInput(cardID: id))
                } else if input?.sourceCardID != parentID {
                    errors.append(.inputNotFromParent(cardID: id))
                }
            }
            if readiness == .done && result == nil {
                errors.append(.doneWithoutResult(cardID: id))
            }
            if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyGoal(cardID: id))
            }
            if doneCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyDoneCondition(cardID: id))
            }
            return errors
    }
}

extension KanbanAgent.Column {
    /// Kind-dependent fields must match the kind (spec 01 §7).
    public func validate() -> KanbanAgent.ValidationError? {
        if kind == .timerWait && timerSeconds == nil { return .columnKindMismatch(columnID: id) }
        if kind == .terminal && defaultEdgeID != nil { return .columnKindMismatch(columnID: id) }
        return nil
    }
}
