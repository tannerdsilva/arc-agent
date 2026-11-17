import Foundation

extension KanbanAgent {

    /// The judgment surface (spec 05 §1). The engine depends on this
    /// protocol, never on an LLM — `ScriptedKanbanJudge` gates the early
    /// phases; `LLMKanbanJudge` (phase 4+) is the real implementation.
    ///
    /// Every call embeds composed context (card, tree, definition-of-done,
    /// legal edges, budgets) — no hidden transcript dependency.
    public protocol KanbanJudge: Sendable {
        /// Verb 1 — classify a finished card along a legal edge.
        func chooseTransition(_ req: TransitionRequest) async throws -> TransitionDecision
        /// Verb 2 — author the next generation of cards (spec 05 §3).
        func generateChildren(_ req: GenerationRequest) async throws -> [GeneratedChild]
        /// Verb 3 — three-way verdict on the root.
        func evaluateRoot(_ req: EvaluationRequest) async throws -> RootVerdict
    }

    /// Verb 2 input: the parent, its result, and the budgets (spec 05 §3).
    public struct GenerationRequest: Sendable {
        public var parentCard: Card
        public var parentResult: CardResult
        public var root: Root
        public var graph: BoardGraph
        public var mintAllowanceRemaining: Int
        public var maxDepth: Int
        /// Non-nil when re-asking after a contract violation — names the
        /// defect so the judge can fix it (spec 05 §3).
        public var reAskNote: String?

        public init(parentCard: Card, parentResult: CardResult, root: Root, graph: BoardGraph,
                    mintAllowanceRemaining: Int, maxDepth: Int, reAskNote: String? = nil) {
            self.parentCard = parentCard
            self.parentResult = parentResult
            self.root = root
            self.graph = graph
            self.mintAllowanceRemaining = mintAllowanceRemaining
            self.maxDepth = maxDepth
            self.reAskNote = reAskNote
        }
    }

    /// One authored child. The judge supplies intent; the engine stamps the
    /// lineage (parentID, birthEdgeID, generation) — spec 05 §3.
    public struct GeneratedChild: Sendable, Equatable {
        public var goal: String
        public var input: InputPassing
        public var doneCondition: String
        /// The column the child should start in — must be reachable from the
        /// parent's column via a legal edge.
        public var targetColumnID: String
        public var whyNext: String

        public init(goal: String, input: InputPassing, doneCondition: String,
                    targetColumnID: String, whyNext: String) {
            self.goal = goal
            self.input = input
            self.doneCondition = doneCondition
            self.targetColumnID = targetColumnID
            self.whyNext = whyNext
        }
    }

    /// Contract violations (spec 05 §3) — hard, engine-enforced. Each names
    /// the field so the re-ask can fix it; a second failure is a structured
    /// generation error, never a silent drop.
    public enum GenerationDefect: Error, Equatable, CustomStringConvertible {
        case emptyGoal
        case emptyDoneCondition
        case inputSourceNotParent
        case inputModeUndeclared
        case referenceUnresolvable(cardID: String)
        case targetUnreachable(columnID: String)
        case mintAllowanceExhausted
        case depthCapReached
        case contractFailedTwice(defects: [String])

        public var description: String {
            switch self {
            case .emptyGoal: return "generated child has an empty goal"
            case .emptyDoneCondition: return "generated child has an empty done condition"
            case .inputSourceNotParent: return "child input.sourceCardID must be the parent card"
            case .inputModeUndeclared: return "child input mode is undeclared"
            case .referenceUnresolvable(let id): return "child input references unresolvable card '\(id)'"
            case .targetUnreachable(let id): return "target column '\(id)' is not reachable from the parent's column"
            case .mintAllowanceExhausted: return "mint allowance exhausted"
            case .depthCapReached: return "max depth reached"
            case .contractFailedTwice(let defects): return "generation rejected twice: \(defects.joined(separator: "; "))"
            }
        }
    }

    /// Verb 1 input: the finished card and its legal moves (spec 05 §2).
    public struct TransitionRequest: Sendable {
        public var card: Card
        public var result: CardResult
        /// The legal edges out of the card's current column.
        public var legalEdges: [Edge]
        /// The card's subtree (children first), for context.
        public var subtree: [Card]
        /// The root's definition of done — the standing constitution.
        public var definitionOfDone: String
        /// Non-nil on a tie-break re-ask — names the defect (spec 05 §2.3).
        public var reAskNote: String?

        public init(card: Card, result: CardResult, legalEdges: [Edge], subtree: [Card], definitionOfDone: String, reAskNote: String? = nil) {
            self.card = card
            self.result = result
            self.legalEdges = legalEdges
            self.subtree = subtree
            self.definitionOfDone = definitionOfDone
            self.reAskNote = reAskNote
        }
    }

    /// Verb 1 output: one legal edge id plus required reasoning.
    public struct TransitionDecision: Sendable, Equatable {
        public var edgeID: String
        public var reasoning: String

        public init(edgeID: String, reasoning: String) {
            self.edgeID = edgeID
            self.reasoning = reasoning
        }
    }

    /// Verb 3 input: the root and its full tree at the evaluation point.
    public struct EvaluationRequest: Sendable {
        public var root: Root
        /// The root's tree, traversal order.
        public var tree: [Card]
        /// Budgets still available (minted children so far, depth cap).
        public var mintedChildren: Int
        public var maxDepth: Int
        /// Non-nil when this evaluation was forced by an engine re-ask —
        /// names the previous verdict's defect (spec 05 §4).
        public var reAskNote: String?

        public init(root: Root, tree: [Card], mintedChildren: Int, maxDepth: Int, reAskNote: String? = nil) {
            self.root = root
            self.tree = tree
            self.mintedChildren = mintedChildren
            self.maxDepth = maxDepth
            self.reAskNote = reAskNote
        }
    }

    /// Verb 3 output (spec 05 §4).
    public enum RootVerdict: Sendable {
        case `continue`
        /// Requires a valid `EvidenceChain` (spec 06 §1) — rejected otherwise.
        case green(EvidenceChain)
        /// Requires a valid `MissingReport` (spec 06 §2) — rejected otherwise.
        case yellow(MissingReport)
    }

    /// Errors surfaced by verdict validation (the re-ask note's text).
    public enum VerdictDefect: Error, Equatable, CustomStringConvertible {
        case greenWithoutEvidence
        case evidenceClauseUnknown(clause: String)
        case evidenceCardNotDone(cardID: String)
        case yellowWithoutReport
        case reportIncomplete(String)

        public var description: String {
            switch self {
            case .greenWithoutEvidence: return "green verdict without an evidence chain"
            case .evidenceClauseUnknown(let c): return "evidence clause not in the definition of done: '\(c)'"
            case .evidenceCardNotDone(let id): return "evidence cites unfinished card '\(id)'"
            case .yellowWithoutReport: return "yellow verdict without a missing report"
            case .reportIncomplete(let why): return "incomplete missing report: \(why)"
            }
        }
    }

    /// The test double that gates phases 1–3 (spec 05 §1) — and a usable
    /// dry-run judge afterwards. Verdicts come from caller-supplied queues;
    /// each consumed on use.
    public final class ScriptedKanbanJudge: KanbanJudge, @unchecked Sendable {
        private final class State: @unchecked Sendable {
            var transitions: [TransitionDecision] = []
            var verdicts: [RootVerdict] = []
            var generations: [[GeneratedChild]] = []
            var transitionCalls: [TransitionRequest] = []
            var evaluationCalls: [EvaluationRequest] = []
            var generationCalls: [GenerationRequest] = []
            var illegalEdgeOnce: String? = nil   // first transition answer, if set, is an illegal edge id
        }

        private let state = State()

        public init() {}

        /// Queue a transition decision (or an illegal edge id to exercise
        /// the tie-break ladder).
        public func enqueueTransition(_ decision: TransitionDecision) {
            state.transitions.append(decision)
        }
        public func enqueueIllegalTransition(edgeID: String) {
            state.illegalEdgeOnce = edgeID
        }
        public func enqueueVerdict(_ verdict: RootVerdict) {
            state.verdicts.append(verdict)
        }
        public func enqueueGeneration(_ children: [GeneratedChild]) {
            state.generations.append(children)
        }

        public var transitionCallCount: Int { state.transitionCalls.count }
        public var evaluationCallCount: Int { state.evaluationCalls.count }
        public var generationCallCount: Int { state.generationCalls.count }
        public var transitionCalls: [TransitionRequest] { state.transitionCalls }
        public var evaluationCalls: [EvaluationRequest] { state.evaluationCalls }
        public var generationCalls: [GenerationRequest] { state.generationCalls }

        public func generateChildren(_ req: GenerationRequest) async throws -> [GeneratedChild] {
            state.generationCalls.append(req)
            guard !state.generations.isEmpty else {
                throw KanbanJudgeUnavailable("scripted judge has no queued generation")
            }
            return state.generations.removeFirst()
        }

        public func chooseTransition(_ req: TransitionRequest) async throws -> TransitionDecision {
            state.transitionCalls.append(req)
            if let illegal = state.illegalEdgeOnce {
                state.illegalEdgeOnce = nil
                return TransitionDecision(edgeID: illegal, reasoning: "scripted illegal answer")
            }
            guard !state.transitions.isEmpty else {
                throw KanbanJudgeUnavailable("scripted judge has no queued transition")
            }
            return state.transitions.removeFirst()
        }

        public func evaluateRoot(_ req: EvaluationRequest) async throws -> RootVerdict {
            state.evaluationCalls.append(req)
            guard !state.verdicts.isEmpty else {
                throw KanbanJudgeUnavailable("scripted judge has no queued verdict")
            }
            return state.verdicts.removeFirst()
        }
    }

    /// Thrown when a judge has nothing scripted — the engine treats it like
    /// any other judge unavailability (stale-motion fallback applies).
    public struct KanbanJudgeUnavailable: Error, CustomStringConvertible {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }
}

extension KanbanAgent {

    /// Validates a verdict against the spec-06 requirements. Returns the
    /// defect to re-ask with, or nil when the verdict is well-formed.
    public static func validateVerdict(
        _ verdict: RootVerdict, definitionOfDone: String, tree: [Card]
    ) -> VerdictDefect? {
        let clauses = definitionOfDone.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        switch verdict {
        case .continue:
            return nil
        case .green(let chain):
            guard !chain.entries.isEmpty else { return .greenWithoutEvidence }
            for entry in chain.entries {
                guard clauses.contains(entry.clause) else { return .evidenceClauseUnknown(clause: entry.clause) }
                for cardID in entry.cardIDs {
                    guard let card = tree.first(where: { $0.id == cardID }) else {
                        return .evidenceCardNotDone(cardID: cardID)
                    }
                    if card.readiness != .done {
                        return .evidenceCardNotDone(cardID: cardID)
                    }
                }
            }
            return nil
        case .yellow(let report):
            // A yellow without attempts is "giving up" (spec 06 §2).
            guard !report.attempts.isEmpty else { return .yellowWithoutReport }
            if report.blockingUnknown.trimmingCharacters(in: .whitespaces).isEmpty {
                return .reportIncomplete("blockingUnknown is empty")
            }
            // A concrete provision is required — "unspecified" is not one.
            if case .information(let detail) = report.userMustProvide,
               detail == "unspecified" {
                return .reportIncomplete("userMustProvide is not concrete")
            }
            return nil
        }
    }
}
