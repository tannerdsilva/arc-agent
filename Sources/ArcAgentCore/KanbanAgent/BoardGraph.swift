import Foundation

extension KanbanAgent {

    /// A graph rule violation (spec 02 §4). Rules 1–2 are *warnings* — the
    /// user may be mid-shape and the board still loads; rules 3+ are *hard* —
    /// the engine refuses to **run** (not load) a board that violates them.
    public enum GraphViolation: Equatable, Sendable, CustomStringConvertible {
        /// Column unreachable from every entry column (rule 1, warning).
        case orphanColumn(columnID: String)
        /// Non-terminal column with no outgoing edges (rule 2, warning).
        case deadEndColumn(columnID: String)
        /// No column marked `isTriage` (rule 3).
        case missingTriage
        /// Column lacks an ask-the-user edge (rule 4).
        case missingAskTheUser(columnID: String)
        /// Terminal column has outgoing edges (rule 5).
        case terminalWithOutgoing(columnID: String)
        /// Edge references a nonexistent column (rule 6).
        case danglingEdge(edgeID: String)
        /// Deterministic edge missing its outcome label (rule 7).
        case deterministicWithoutLabel(edgeID: String)
        /// Policy edge carrying an outcome label (rule 8).
        case policyWithLabel(edgeID: String)
        /// More than one ask-the-user edge from one column (rule 9).
        case multipleAskTheUser(columnID: String)
        /// Ask-the-user edge whose target is not the board's `humanWait`
        /// column (rule 4's target half; spec lists nine cases, this is the
        /// target-check half of rule 4).
        case askTheUserTargetInvalid(edgeID: String)

        public var isWarning: Bool {
            switch self {
            case .orphanColumn, .deadEndColumn: return true
            default: return false
            }
        }

        public var description: String {
            switch self {
            case .orphanColumn(let c): return "column '\(c)' is unreachable from every entry column"
            case .deadEndColumn(let c): return "column '\(c)' has no outgoing edges and is not terminal"
            case .missingTriage: return "no column is marked as triage"
            case .missingAskTheUser(let c): return "column '\(c)' has no ask-the-user edge"
            case .terminalWithOutgoing(let c): return "terminal column '\(c)' has outgoing edges"
            case .danglingEdge(let e): return "edge '\(e)' references a nonexistent column"
            case .deterministicWithoutLabel(let e): return "deterministic edge '\(e)' is missing its outcome label"
            case .policyWithLabel(let e): return "policy edge '\(e)' must not carry an outcome label"
            case .multipleAskTheUser(let c): return "column '\(c)' has more than one ask-the-user edge"
            case .askTheUserTargetInvalid(let e): return "ask-the-user edge '\(e)' must target the humanWait column"
            }
        }
    }

    /// Stateless helper over the board's columns and edges (spec 02 §2).
    /// The edge list lives inside the board document — graph is board data,
    /// editable by the user at any time.
    public struct BoardGraph: Sendable, Equatable {
        public var columns: [Column]
        public var edges: [Edge]

        public init(columns: [Column], edges: [Edge]) {
            self.columns = columns
            self.edges = edges
        }

        public init(board: BoardDocument) {
            self.init(columns: board.columns, edges: board.edges)
        }

        public func column(id: String) -> Column? {
            columns.first { $0.id == id }
        }

        public func edges(from columnID: String) -> [Edge] {
            edges.filter { $0.fromColumnID == columnID }
        }

        /// The deterministic edge carrying exactly this outcome label.
        /// Matching is exact — it is a mapping, not a choice.
        public func deterministicEdge(from columnID: String, outcome: String) -> Edge? {
            edges(from: columnID).first {
                $0.decision == .deterministic && $0.outcomeLabel == outcome
            }
        }

        public func policyEdges(from columnID: String) -> [Edge] {
            edges(from: columnID).filter { $0.decision == .policy }
        }

        public func askTheUserEdge(from columnID: String) -> Edge? {
            edges(from: columnID).first { $0.isAskTheUser }
        }

        /// Columns with no incoming edges — the graph's entry points.
        public func entryColumns() -> [Column] {
            let targets = Set(edges.map(\.toColumnID))
            return columns.filter { !targets.contains($0.id) }
        }

        public func terminalColumns() -> [Column] {
            columns.filter { $0.kind == .terminal }
        }

        public func triageColumn() -> Column? {
            columns.first { $0.isTriage }
        }

        public func humanWaitColumn() -> Column? {
            columns.first { $0.kind == .humanWait }
        }

        // MARK: - Validation (spec 02 §4)

        /// All violations, warnings and hard rules alike. Severity is on the
        /// violation (``GraphViolation/isWarning``).
        public func validate() -> [GraphViolation] {
            var violations: [GraphViolation] = []
            let byID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })

            // Rule 6: dangling edges.
            for edge in edges where byID[edge.fromColumnID] == nil || byID[edge.toColumnID] == nil {
                violations.append(.danglingEdge(edgeID: edge.id))
            }
            let internallyValid = edges.filter { edge in
                byID[edge.fromColumnID] != nil && byID[edge.toColumnID] != nil
            }

            // Rules 7/8: label/decision agreement.
            for edge in internallyValid {
                switch edge.decision {
                case .deterministic where edge.outcomeLabel == nil:
                    violations.append(.deterministicWithoutLabel(edgeID: edge.id))
                case .policy where edge.outcomeLabel != nil:
                    violations.append(.policyWithLabel(edgeID: edge.id))
                default:
                    break
                }
            }

            let humanWait = humanWaitColumn()

            for column in columns {
                let outgoing = internallyValid.filter { $0.fromColumnID == column.id }

                // Rule 5: terminals have no outgoing edges.
                if column.kind == .terminal && !outgoing.isEmpty {
                    violations.append(.terminalWithOutgoing(columnID: column.id))
                }

                // Rules 4 + 9: exactly one ask-the-user edge per column,
                // targeting the board's single humanWait column.
                let asks = outgoing.filter { $0.isAskTheUser }
                if asks.count > 1 {
                    violations.append(.multipleAskTheUser(columnID: column.id))
                } else if asks.count == 1 {
                    if let hw = humanWait, asks[0].toColumnID != hw.id {
                        violations.append(.askTheUserTargetInvalid(edgeID: asks[0].id))
                    }
                } else if column.kind != .terminal && column.kind != .humanWait {
                    // The humanWait column *is* the ask destination — it
                    // cannot ask the user itself; terminals have no exits.
                    violations.append(.missingAskTheUser(columnID: column.id))
                }
            }

            // Rule 3: triage presence.
            if triageColumn() == nil {
                violations.append(.missingTriage)
            }

            // Rules 1/2: reachability from entry columns (warnings).
            // An entry is a column with no incoming edges AND at least one
            // outgoing edge — an isolated column (no in, no out) is not a
            // root, it is an orphan.
            let incoming = Set(internallyValid.map(\.toColumnID))
            let roots = columns.filter { col in
                !incoming.contains(col.id) && internallyValid.contains { $0.fromColumnID == col.id }
            }
            let entryRoots = roots.isEmpty ? columns : roots // cycle-only graphs: everything is a root
            var reachable = Set(entryRoots.map(\.id))
            var queue = entryRoots.map(\.id)
            while let current = queue.popLast() {
                for edge in internallyValid where edge.fromColumnID == current && reachable.insert(edge.toColumnID).inserted {
                    queue.append(edge.toColumnID)
                }
            }
            for column in columns where !reachable.contains(column.id) {
                violations.append(.orphanColumn(columnID: column.id))
            }
            for column in columns
            where column.kind != .terminal && reachable.contains(column.id)
                && !internallyValid.contains(where: { $0.fromColumnID == column.id }) {
                violations.append(.deadEndColumn(columnID: column.id))
            }

            return violations
        }

        /// The hard (engine-refuses-to-run) subset.
        public func hardViolations() -> [GraphViolation] {
            validate().filter { !$0.isWarning }
        }
    }

    // MARK: - Editing protocol (spec 02 §3)

    /// A typed graph edit. The only way the graph changes — the agent has no
    /// channel (spec 02 §5); the user owns these.
    public enum BoardGraphEdit: Equatable, Sendable {
        case addColumn(Column)
        case removeColumn(id: String)
        case renameColumn(id: String, name: String)
        case setKind(id: String, kind: ColumnKind)
        case addEdge(Edge)
        case removeEdge(id: String)
    }

    public enum GraphEditError: Error, Equatable, CustomStringConvertible {
        /// `removeColumn` refused: cards still occupy the column.
        case columnOccupied(columnID: String)
        /// `removeColumn`/`setKind` would orphan the triage or humanWait role.
        case roleColumnProtected(columnID: String, role: String)

        public var description: String {
            switch self {
            case .columnOccupied(let c):
                return "cannot remove column '\(c)': cards still occupy it"
            case .roleColumnProtected(let c, let role):
                return "cannot remove column '\(c)': it is the board's \(role) column"
            }
        }
    }

    public enum BoardGraphEditor {

        /// Apply one edit to the board document. Refusals throw; everything
        /// else applies and returns the post-edit violations so the caller
        /// can surface warnings (orphan/dead-end shapes) without blocking
        /// the edit — a broken graph does not brick the board, the engine
        /// just refuses to run it.
        public static func apply(
            _ edit: BoardGraphEdit,
            to board: inout BoardDocument,
            occupiedColumns: Set<String>
        ) throws -> [GraphViolation] {
            var graph = BoardGraph(board: board)

            switch edit {
            case .addColumn(let column):
                if !graph.columns.contains(where: { $0.id == column.id }) {
                    graph.columns.append(column)
                }

            case .removeColumn(let id):
                guard !occupiedColumns.contains(id) else {
                    throw GraphEditError.columnOccupied(columnID: id)
                }
                if let removed = graph.column(id: id) {
                    if removed.isTriage {
                        throw GraphEditError.roleColumnProtected(columnID: id, role: "triage")
                    }
                    if removed.kind == .humanWait {
                        throw GraphEditError.roleColumnProtected(columnID: id, role: "humanWait")
                    }
                }
                graph.columns.removeAll { $0.id == id }
                graph.edges.removeAll { $0.fromColumnID == id || $0.toColumnID == id }

            case .renameColumn(let id, let name):
                if let idx = graph.columns.firstIndex(where: { $0.id == id }) {
                    graph.columns[idx].name = name
                }

            case .setKind(let id, let kind):
                if let idx = graph.columns.firstIndex(where: { $0.id == id }) {
                    graph.columns[idx].kind = kind
                }

            case .addEdge(let edge):
                if !graph.edges.contains(where: { $0.id == edge.id }) {
                    graph.edges.append(edge)
                }

            case .removeEdge(let id):
                graph.edges.removeAll { $0.id == id }
            }

            board.columns = graph.columns
            board.edges = graph.edges
            board.revision += 1
            return graph.validate()
        }
    }
}
