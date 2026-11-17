import Foundation
import Logging
import ServiceLifecycle

extension KanbanAgent {

    /// Why a transition was refused or overridden — surfaced in logs/events.
    public enum EngineNotice: Sendable, Equatable, CustomStringConvertible {
        case cycleBudgetExhausted(cardID: String, columnID: String, routedTo: String)
        case judgeUnavailable(cardID: String, reason: String)
        case staleMotionFallback(cardID: String, edgeID: String)
        case timerReleased(cardID: String, edgeID: String)
        case boardInvalid([KanbanAgent.GraphViolation])
        case leaseHeld(other: String)
        case idling
        case generationFailed(cardID: String, reason: String)
        case childrenMinted(cardID: String, count: Int)

        public var description: String {
            switch self {
            case .cycleBudgetExhausted(let c, let col, let to):
                return "cycle budget exhausted for card \(c) re-entering \(col); routed to triage \(to)"
            case .judgeUnavailable(let c, let r):
                return "judge unavailable for card \(c): \(r)"
            case .staleMotionFallback(let c, let e):
                return "stale-motion fallback moved card \(c) along \(e)"
            case .timerReleased(let c, let e):
                return "timer released card \(c) along \(e)"
            case .boardInvalid(let v):
                return "board refused to run: \(v.map(\.description).joined(separator: "; "))"
            case .leaseHeld(let other):
                return "lease held by \(other)"
            case .idling:
                return "no runnable cards; all roots terminal — idling"
            case .generationFailed(let c, let r):
                return "generation for card \(c) failed: \(r)"
            case .childrenMinted(let c, let n):
                return "\(n) children minted for card \(c)"
            }
        }
    }

    /// One persisted outcome of a tick pass.
    public struct TickReport: Sendable, Equatable {
        public var boardID: String
        public var executedCardID: String?
        public var notices: [EngineNotice]

        public init(boardID: String, executedCardID: String?, notices: [EngineNotice]) {
            self.boardID = boardID
            self.executedCardID = executedCardID
            self.notices = notices
        }
    }

    /// The serial run loop (spec 04). One engine actor, many boards: each
    /// board advances its own root serially; separate boards run their
    /// passes in a `TaskGroup` inside the same tick. The engine is the only
    /// writer to its boards — single-writer discipline by actor isolation.
    ///
    /// ## Law of the Land
    ///
    /// - **First Law**: the tick is a `TaskGroup`; per-board passes are
    ///   structured child tasks; no locks — the actor is the lock.
    /// - **Second Law**: a `Service` in the lifecycle tree; `run()` returns
    ///   on graceful shutdown.
    public actor KanbanEngineService: Service {

        private let store: any KanbanAgentStore
        private let judge: any KanbanJudge
        private let executor: any CardExecutor
        private let ownerID: String
        private let pollInterval: UInt64
        /// Lease heartbeat staleness: a lease older than this is dead and
        /// the board may be claimed (default 3 poll intervals).
        private let leaseTimeout: TimeInterval
        private let logger: Logger

        public init(
            store: any KanbanAgentStore,
            judge: any KanbanJudge,
            executor: any CardExecutor,
            ownerID: String,
            pollInterval: TimeInterval = 5,
            logger: Logger = .init(label: "kanban-engine")
        ) {
            self.store = store
            self.judge = judge
            self.executor = executor
            self.ownerID = ownerID
            self.pollInterval = UInt64(max(0.05, pollInterval) * 1_000_000_000)
            self.leaseTimeout = max(15, pollInterval * 3)
            self.logger = logger
        }

        /// The tick loop (spec 04 §4). Until cancellation.
        public func run() async throws {
            logger.info("kanban engine started", metadata: ["owner": "\(ownerID)"])
            while !Task.isCancelled {
                await tick()
                try await Task.sleep(nanoseconds: pollInterval)
            }
            logger.info("kanban engine stopping")
        }

        /// One pass over all boards, fanned out in a TaskGroup.
        @discardableResult
        public func tick(now: Date = Date()) async -> [TickReport] {
            guard let boards = try? await store.listBoards() else { return [] }
            let boardIDs = boards.map(\.id)
            let reports = await withTaskGroup(of: TickReport.self) { group in
                for id in boardIDs {
                    group.addTask { await self.pass(boardID: id, now: now) }
                }
                var out: [TickReport] = []
                for await report in group { out.append(report) }
                return out.sorted { $0.boardID < $1.boardID }
            }
            return reports
        }

        // MARK: - Per-board pass

        private func pass(boardID: String, now: Date) async -> TickReport {
            var notices: [EngineNotice] = []
            var executed: String?

            // Lease (spec 04 §1): refuse a second driver on the same board.
            guard var board = try? await store.getBoard(id: boardID) ?? nil else {
                return TickReport(boardID: boardID, executedCardID: nil, notices: [])
            }
            if let lease = board.engineLease,
               lease.ownerID != ownerID,
               now.timeIntervalSince(lease.heartbeatAt) < leaseTimeout {
                notices.append(.leaseHeld(other: lease.ownerID))
                return TickReport(boardID: boardID, executedCardID: nil, notices: notices)
            }

            // Load + validate: hard rules only — refuse to run an invalid
            // board (spec 04 §4 step 1).
            let graph = BoardGraph(board: board)
            let violations = graph.validate()  // BoardGraph(board:) takes the document
            let hard = violations.filter { !$0.isWarning }
            guard hard.isEmpty else {
                notices.append(.boardInvalid(hard))
                return TickReport(boardID: boardID, executedCardID: nil, notices: notices)
            }

            do {
                // Advance timers (step 2).
                let timerNotices = try await advanceTimers(&board, graph: graph, now: now)
                notices.append(contentsOf: timerNotices)

                // Stale-motion fallback (invariant 4): a card that finished
                // but could not transition moves along its default edge
                // after the timeout — nothing silently spins.
                let stale = try await releaseStaleCards(&board, graph: graph, now: now)
                notices.append(contentsOf: stale)

                // Root queue (spec 04 §3): first running root, creation order.
                guard let root = KanbanTraversal.nextRoot(in: board) else {
                    if !board.roots.isEmpty { notices.append(.idling) }
                    try await persist(board)
                    return TickReport(boardID: boardID, executedCardID: nil, notices: notices)
                }

                // Pending transitions first: a card with a result waiting on
                // the judge (steps 5–6 resume across ticks after failures).
                let cards = try await store.cards(boardID: boardID)
                let pending = KanbanTraversal.pendingTransitions(in: cards, root: root, graph: graph)
                if let card = pending.first {
                    // Generation point (spec 05 §3): a parent with a fresh
                    // result and no children may mint the next generation
                    // before its own transition consumes the result.
                    if try await mintChildren(for: card, board: &board, graph: graph, root: root, cards: cards, notices: &notices) {
                        try await persist(board)
                        return TickReport(boardID: boardID, executedCardID: card.id, notices: notices)
                    }
                    try await transition(card, board: &board, graph: graph, root: root, now: now, notices: &notices)
                    try await persist(board)
                    return TickReport(boardID: boardID, executedCardID: card.id, notices: notices)
                }

                // Pick the next runnable card (step 3).
                guard let next = KanbanTraversal.nextRunnableCard(in: cards, root: root, graph: graph, now: now) else {
                    // No runnable card → evaluation point (exhaustion or
                    // between generations; Verb 2 arrives in phase 4).
                    try await evaluateRoot(root, board: &board, cards: cards, reAskNote: nil, notices: &notices)
                    try await persist(board)
                    return TickReport(boardID: boardID, executedCardID: nil, notices: notices)
                }

                // Execute (step 4) — serial within the board's traversal.
                let prompt = buildPrompt(for: next, root: root, cards: cards, graph: graph)
                var running = next
                let previousResult = running.result
                running.readiness = .running
                try await store.saveCard(running, boardID: board.id)
                let result = try await executor.run(prompt, card: running, settings: board.settings)
                // Triage re-arm (answer 10): a repeat result in the triage
                // column stays parked — re-arm the cooldown, skip transition.
                if running.columnID == graph.triageColumn()?.id,
                   let previousResult, previousResult == result {
                    var parked = running
                    parked.triageRetryAt = now.addingTimeInterval(board.settings.triageCooldownSeconds)
                    try await store.saveCard(parked, boardID: board.id)
                    executed = parked.id
                    try await persist(board)
                    return TickReport(boardID: boardID, executedCardID: executed, notices: notices)
                }
                running.result = result
                try await store.saveCard(running, boardID: board.id)
                executed = running.id

                // Generation point (spec 05 §3): between the result and its
                // consuming transition, a childless parent under budget may
                // mint the next generation — children then run first
                // (post-order) before the parent's transition.
                if try await mintChildren(for: running, board: &board, graph: graph, root: root, cards: cards + [running], notices: &notices) {
                    try await persist(board)
                    return TickReport(boardID: boardID, executedCardID: executed, notices: notices)
                }

                // Transition (step 5).
                try await transition(running, board: &board, graph: graph, root: root, now: now, notices: &notices)
                try await persist(board)
            } catch {
                // The board is left as-is; the next tick retries. The card
                // stays in `running` readiness — a crash marker the stale
                // path will resolve after the lease timeout.
                logger.warning("pass failed", metadata: ["board": "\(boardID)", "error": "\(error)"])
                notices.append(.judgeUnavailable(cardID: "?", reason: "\(error)"))
            }
            return TickReport(boardID: boardID, executedCardID: executed, notices: notices)
        }

        // MARK: - Steps

        /// Step 2: timer columns release their cards along the column's
        /// configured release edge, else the ask-the-user edge.
        private func advanceTimers(_ board: inout BoardDocument, graph: BoardGraph, now: Date) async throws -> [EngineNotice] {
            var notices: [EngineNotice] = []
            let timerColumns = graph.columns.filter { $0.kind == .timerWait }
            guard !timerColumns.isEmpty else { return notices }
            let cards = try await store.cards(boardID: board.id)
            for card in cards where card.result == nil {
                guard let column = graph.column(id: card.columnID), column.kind == .timerWait,
                      let duration = column.timerSeconds else { continue }
                let enteredAt = card.transitionProvenance.last?.at ?? card.triageRetryAt
                guard let enteredAt, now.timeIntervalSince(enteredAt) >= duration else { continue }
                // Release edge: configured, else ask-the-user, else fixed policy.
                let edge = graph.edges(from: column.id).first { $0.id == column.defaultEdgeID }
                    ?? graph.askTheUserEdge(from: column.id)
                    ?? graph.edges(from: column.id).first { $0.decision == .policy && $0.policy == .fixed }
                guard let edge else { continue }
                var moved = card
                move(&moved, along: edge, reasoning: "timer elapsed (\(Int(duration))s)", decidedBy: .fallback)
                try await store.saveCard(moved, boardID: board.id)
                notices.append(.timerReleased(cardID: moved.id, edgeID: edge.id))
            }
            return notices
        }

        /// Invariant 4: cards whose result is set but that never transitioned
        /// (judge unavailable across ticks) move along `defaultEdgeID` after
        /// `staleMotionTimeoutSeconds`, `decidedBy: .fallback`.
        private func releaseStaleCards(_ board: inout BoardDocument, graph: BoardGraph, now: Date) async throws -> [EngineNotice] {
            var notices: [EngineNotice] = []
            let timeout = board.settings.staleMotionTimeoutSeconds
            let cards = try await store.cards(boardID: board.id)
            for card in cards {
                guard let result = card.result,
                      graph.column(id: card.columnID)?.kind == .agentWork,
                      now.timeIntervalSince(result.producedAt) >= timeout,
                      let edgeID = graph.column(id: card.columnID)?.defaultEdgeID,
                      let edge = graph.edges.first(where: { $0.id == edgeID })
                else { continue }
                var moved = card
                move(&moved, along: edge, reasoning: "stale-motion fallback (judge unavailable)", decidedBy: .fallback)
                try await store.saveCard(moved, boardID: board.id)
                notices.append(.staleMotionFallback(cardID: moved.id, edgeID: edge.id))
            }
            return notices
        }

        /// Step 5: resolve and apply the transition (spec 05 §2 order —
        /// deterministic first, then fixed, then counter, then agent).
        private func transition(
            _ card: Card, board: inout BoardDocument, graph: BoardGraph,
            root: Root, now: Date, notices: inout [EngineNotice]
        ) async throws {
            guard let result = card.result else { return }
            let legal = graph.edges(from: card.columnID)
            var card = card

            // Cycle budget (invariant 1): re-entering a column beyond the
            // budget routes to triage instead (answer 10).
            let targetCounts = card.traversalCounts
            let deterministic = legal.first { $0.decision == .deterministic && $0.outcomeLabel == result.outcome }
            let resolved: (Edge, DecidedBy, String)
            if let edge = deterministic {
                resolved = (edge, .deterministic, "outcome '\(result.outcome)' maps to this edge")
            } else {
                let fixed = legal.first { $0.decision == .policy && $0.policy == .fixed }
                let counterEdges = legal.filter { $0.decision == .policy && $0.policy == .counter }.sorted { $0.id < $1.id }
                let agentEdges = legal.filter { $0.decision == .policy && $0.policy == .agent }
                if let edge = fixed {
                    resolved = (edge, .fallback, "fixed policy edge")
                } else if !counterEdges.isEmpty {
                    let count = targetCounts[card.columnID] ?? 0
                    let edge = counterEdges[count % counterEdges.count]
                    resolved = (edge, .fallback, "counter rotation \(count)")
                } else if !agentEdges.isEmpty {
                    resolved = try await askJudge(card: card, result: result, edges: agentEdges, graph: graph, root: root, notices: &notices)
                } else if let ask = graph.askTheUserEdge(from: card.columnID) {
                    resolved = (ask, .fallback, "no other legal move; asking the user")
                } else {
                    // Should not happen on a valid board; log and stall-safe.
                    notices.append(.judgeUnavailable(cardID: card.id, reason: "no legal edges"))
                    return
                }
            }

            var (edge, decidedBy, reasoning) = resolved
            // Cycle-budget override: the target would exceed the budget.
            if let target = graph.column(id: edge.toColumnID),
               target.kind != .terminal, target.id != graph.triageColumn()?.id,
               (targetCounts[target.id] ?? 0) >= board.settings.cycleBudget,
               let triage = graph.triageColumn() {
                edge = Edge(id: edge.id, fromColumnID: edge.fromColumnID, toColumnID: triage.id, decision: .policy, policy: .agent, isAskTheUser: false)
                decidedBy = .fallback
                reasoning = "cycle budget for \(target.id) spent; routed to triage"
                notices.append(.cycleBudgetExhausted(cardID: card.id, columnID: target.id, routedTo: triage.id))
            }

            move(&card, along: edge, reasoning: reasoning, decidedBy: decidedBy, at: now)
            // Terminal arrival marks done; triage arrival arms the cooldown.
            if graph.column(id: card.columnID)?.kind == .terminal {
                card.readiness = .done
            } else if card.columnID == graph.triageColumn()?.id {
                card.triageRetryAt = now.addingTimeInterval(board.settings.triageCooldownSeconds)
            }
            try await store.saveCard(card, boardID: board.id)
        }

        /// The judge path with the tie-break ladder (spec 05 §2.3): illegal
        /// answer → re-ask once → ask-the-user edge with the annotated
        /// best guess preserved.
        private func askJudge(
            card: Card, result: CardResult, edges: [Edge], graph: BoardGraph,
            root: Root, notices: inout [EngineNotice]
        ) async throws -> (Edge, DecidedBy, String) {
            let req = TransitionRequest(
                card: card, result: result, legalEdges: edges,
                subtree: [], definitionOfDone: root.definitionOfDone)
            do {
                let decision = try await judge.chooseTransition(req)
                if let edge = edges.first(where: { $0.id == decision.edgeID }) {
                    return (edge, .agent, decision.reasoning)
                }
                // Illegal — re-ask once with the violation named.
                let note = "illegal edge '\(decision.edgeID)'; legal: \(edges.map(\.id).joined(separator: ", "))"
                let second = try await judge.chooseTransition(req)
                if let edge = edges.first(where: { $0.id == second.edgeID }) {
                    return (edge, .agent, note + " — " + second.reasoning)
                }
                if let ask = graph.askTheUserEdge(from: card.columnID) {
                    return (ask, .fallback, note + "; best guess preserved: \(second.reasoning)")
                }
                throw KanbanJudgeUnavailable("judge returned illegal edges twice and no ask edge exists")
            } catch is KanbanJudgeUnavailable {
                throw KanbanJudgeUnavailable("judge unavailable for card \(card.id)")
            } catch {
                throw error
            }
        }

        /// Verb 2 (spec 05 §3): mint the next generation under a parent.
        /// Returns false when minting is not applicable (no budget, already
        /// has children, judge unavailable) — the caller falls through to the
        /// normal transition. Contract validation is hard: a defective
        /// generation is re-asked once; a second failure is a structured
        /// error notice, never a silent drop.
        private func mintChildren(
            for card: Card, board: inout BoardDocument, graph: BoardGraph,
            root: Root, cards: [Card], notices: inout [EngineNotice]
        ) async throws -> Bool {
            // Always-legal exits are outside the budget (spec 05 §3).
            let minted = KanbanTraversal.mintedChildren(of: root, in: cards)
            guard card.generation < board.settings.maxDepth else {
                notices.append(.generationFailed(cardID: card.id, reason: "\(GenerationDefect.depthCapReached)"))
                return false
            }
            guard minted < board.settings.mintAllowance else {
                notices.append(.generationFailed(cardID: card.id, reason: "\(GenerationDefect.mintAllowanceExhausted)"))
                return false
            }
            // A parent that already has children does not mint again.
            guard !cards.contains(where: { $0.parentID == card.id }) else { return false }
            guard graph.column(id: card.columnID)?.kind == .agentWork,
                  let result = card.result else { return false }

            func buildRequest(_ note: String?) -> GenerationRequest {
                GenerationRequest(
                    parentCard: card, parentResult: result, root: root, graph: graph,
                    mintAllowanceRemaining: board.settings.mintAllowance - minted,
                    maxDepth: board.settings.maxDepth, reAskNote: note)
            }
            var children: [GeneratedChild]
            do {
                children = try await judge.generateChildren(buildRequest(nil))
            } catch {
                notices.append(.judgeUnavailable(cardID: card.id, reason: "\(error)"))
                return false
            }
            // Contract validation (spec 05 §3): the three fields, hard.
            var defects = contractDefects(children, graph: graph, parentID: card.id)
            if !defects.isEmpty {
                children = try await judge.generateChildren(
                    buildRequest(defects.joined(separator: "; ")))
                defects = contractDefects(children, graph: graph, parentID: card.id)
                guard defects.isEmpty else {
                    notices.append(.generationFailed(cardID: card.id, reason: "\(GenerationDefect.contractFailedTwice(defects: defects))"))
                    return false
                }
            }
            // Stamp lineage and place each child (engine-side, not judge).
            let remaining = board.settings.mintAllowance - minted
            var placed = 0
            for child in children.prefix(remaining) {
                guard let edge = graph.edges(from: card.columnID).first(where: { $0.toColumnID == child.targetColumnID }) else {
                    notices.append(.generationFailed(cardID: card.id, reason: "\(GenerationDefect.targetUnreachable(columnID: child.targetColumnID))"))
                    continue
                }
                let new = Card(
                    id: UUID().uuidString, laneID: card.laneID, columnID: child.targetColumnID,
                    goal: child.goal, input: child.input, doneCondition: child.doneCondition,
                    parentID: card.id, rootID: root.id, birthEdgeID: edge.id,
                    generation: card.generation + 1)
                var stamped = new
                stamped.transitionProvenance = [TransitionRecord(
                    edgeID: edge.id, fromColumnID: card.columnID, toColumnID: edge.toColumnID,
                    reasoning: "minted: \(child.whyNext)", decidedBy: .agent, at: Date())]
                stamped.traversalCounts[child.targetColumnID, default: 0] = 1
                try await store.saveCard(stamped, boardID: board.id)
                placed += 1
            }
            if placed > 0 {
                notices.append(.childrenMinted(cardID: card.id, count: placed))
                try await appendRootEvent(board, rootID: root.id, kind: .cardCreate,
                                          payload: "{\"mintedBy\": \"\(card.id)\", \"count\": \(placed)}")
            }
            return placed > 0
        }

        /// The three hard contract fields (spec 05 §3).
        private func contractDefects(_ children: [GeneratedChild], graph: BoardGraph, parentID: String) -> [String] {
            var defects: [String] = []
            for child in children {
                if child.goal.trimmingCharacters(in: .whitespaces).isEmpty {
                    defects.append("\(GenerationDefect.emptyGoal)")
                }
                if child.doneCondition.trimmingCharacters(in: .whitespaces).isEmpty {
                    defects.append("\(GenerationDefect.emptyDoneCondition)")
                }
                if child.input.sourceCardID != parentID {
                    defects.append("\(GenerationDefect.inputSourceNotParent)")
                }
                let workTargets = graph.columns.filter { $0.kind == .agentWork || $0.kind == .timerWait }.map(\.id)
                if !workTargets.contains(child.targetColumnID) {
                    defects.append("\(GenerationDefect.targetUnreachable(columnID: child.targetColumnID))")
                }
            }
            return defects
        }

        /// Append a root-scoped board event (next seq).
        private func appendRootEvent(
            _ board: BoardDocument, rootID: String,
            kind: BoardEventKind, payload: String
        ) async throws {
            let last = (try? await store.events(boardID: board.id, after: 0, limit: 10_000))?.last?.seq ?? 0
            try await store.appendEvent(
                BoardEvent(seq: last + 1, kind: kind, cardID: rootID, payload: payload),
                boardID: board.id)
        }

        /// Step 6: the evaluate verb (spec 05 §4) — fires at every
        /// evaluation point. Green/yellow verdicts are validated and
        /// re-asked once on defect; a still-invalid verdict forces yellow
        /// with an engine-composed report (the agent cannot be stuck).
        private func evaluateRoot(
            _ root: Root, board: inout BoardDocument, cards: [Card],
            reAskNote: String?, notices: inout [EngineNotice]
        ) async throws {
            let tree = KanbanTraversal.tree(of: root, in: cards)
            let minted = KanbanTraversal.mintedChildren(of: root, in: cards)
            let req = EvaluationRequest(
                root: root, tree: tree,
                mintedChildren: minted, maxDepth: board.settings.maxDepth,
                reAskNote: reAskNote)
            var verdict: RootVerdict
            do {
                verdict = try await judge.evaluateRoot(req)
            } catch {
                notices.append(.judgeUnavailable(cardID: root.id, reason: "\(error)"))
                return  // nothing to do this tick; next tick re-evaluates
            }
            if let defect = KanbanAgent.validateVerdict(verdict, definitionOfDone: root.definitionOfDone, tree: tree) {
                // Re-ask once with the defect named.
                var second = req
                second.reAskNote = "\(defect)"
                let retry = try await judge.evaluateRoot(second)
                if let defect2 = KanbanAgent.validateVerdict(retry, definitionOfDone: root.definitionOfDone, tree: tree) {
                    // Force yellow (spec 05 §4 last line): no viable move IS
                    // an evaluation, and a stuck judge cannot wedge the root.
                    verdict = .yellow(MissingReport(
                        attempts: [],
                        blockingUnknown: "engine forced yellow: judge verdict invalid twice (\(defect), \(defect2))",
                        userMustProvide: .decision("review the root's definition of done and resume")))
                } else {
                    verdict = retry
                }
            }
            guard let index = board.roots.firstIndex(where: { $0.id == root.id }) else { return }
            switch verdict {
            case .continue:
                break  // phase 4: Verb 2 generation happens here
            case .green(let chain):
                board.roots[index].state = .green
                board.roots[index].evidence = chain
            case .yellow(let report):
                board.roots[index].state = .yellow
                board.roots[index].missingReport = report
            }
        }

        /// The user's resume verb (spec 04 §3): a yellow root returns to the
        /// queue head, tree intact.
        public func resume(rootID: String, boardID: String, context: String?) async throws {
            guard var board = try await store.getBoard(id: boardID) else { throw KanbanAgentStoreError.boardNotFound(boardID) }
            guard let index = board.roots.firstIndex(where: { $0.id == rootID }) else {
                throw KanbanAgentStoreError.cardNotFound(boardID: boardID, cardID: rootID)
            }
            // Green is closed forever (spec 06 §1) — resume is refused.
            guard board.roots[index].state != .green else {
                throw KanbanAgentStoreError.cardNotFound(boardID: boardID, cardID: "\(rootID) (green roots cannot resume)")
            }
            board.roots[index].state = .running
            board.roots[index].resumeContext = context
            try await appendRootEvent(board, rootID: rootID, kind: .settingsChange,
                                      payload: "{\"resumed\": true, \"context\": \(context.map { "\"\($0)\"" } ?? "null")}")
            // Head of the queue: move before all other running roots.
            let root = board.roots.remove(at: index)
            let head = board.roots.firstIndex { $0.state == .running } ?? 0
            board.roots.insert(root, at: head)
            board.revision += 1
            try await store.saveBoard(board)
        }

        // MARK: - Plumbing

        private func buildPrompt(for card: Card, root: Root, cards: [Card], graph: BoardGraph) -> CardPrompt {
            let parent = card.parentID.flatMap { id in cards.first { $0.id == id } }
            return KanbanAgent.buildPrompt(for: card, parent: parent, graph: graph)
        }

        /// The one mutation helper: stamp provenance, edge, counts.
        private func move(_ card: inout Card, along edge: Edge, reasoning: String, decidedBy: DecidedBy, at: Date = Date()) {
            card.transitionProvenance.append(TransitionRecord(
                edgeID: edge.id, fromColumnID: edge.fromColumnID, toColumnID: edge.toColumnID,
                reasoning: reasoning, decidedBy: decidedBy, at: at))
            card.lastEdgeID = edge.id
            card.columnID = edge.toColumnID
            card.traversalCounts[edge.toColumnID, default: 0] += 1  // arrivals: visits to the destination
            card.triageRetryAt = nil
        }

        private func persist(_ board: BoardDocument) async throws {
            var doc = board
            doc.engineLease = EngineLease(ownerID: ownerID)
            doc.revision += 1
            try await store.saveBoard(doc)
        }
    }
}
