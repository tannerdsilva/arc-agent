import Foundation

extension KanbanAgent {

    /// The composed task prompt for one card execution (spec 04 §5): goal +
    /// declared input (rendered per passing mode) + done condition. The
    /// turn runs in the board's profile with standing context only — no
    /// cross-run transcript history.
    public struct CardPrompt: Sendable, Equatable {
        public var goal: String
        /// Rendered input: the parent's output summary/inclusion text, or a
        /// reference pointer (mode preserved so the executor can fetch).
        public var inputMode: InputPassingMode?
        public var inputText: String?
        public var inputArtifactID: String?
        public var doneCondition: String
        /// The legal outcomes the card may claim (deterministic labels from
        /// its current column), so the executor's label is a legal claim.
        public var expectedOutcomes: [String]

        public init(goal: String, inputMode: InputPassingMode?, inputText: String?, inputArtifactID: String?, doneCondition: String, expectedOutcomes: [String]) {
            self.goal = goal
            self.inputMode = inputMode
            self.inputText = inputText
            self.inputArtifactID = inputArtifactID
            self.doneCondition = doneCondition
            self.expectedOutcomes = expectedOutcomes
        }
    }

    /// Builds a card's prompt from the board state. `resolveReference` is
    /// called only for `reference`-mode inputs; the engine injects the
    /// parent's stored result summary (the v1 artifact store is the card
    /// result itself).
    public static func buildPrompt(
        for card: Card, parent: Card?, graph: BoardGraph
    ) -> CardPrompt {
        var inputMode: InputPassingMode?
        var inputText: String?
        var inputArtifactID: String?
        if let passing = card.input {
            inputMode = passing.mode
            switch passing.mode {
            case .reference:
                inputArtifactID = passing.payload
                inputText = parent?.result?.summary
            case .summary, .inclusion:
                inputText = passing.payload
            }
        }
        let outcomes = graph.edges(from: card.columnID)
            .filter { $0.decision == .deterministic }
            .compactMap { $0.outcomeLabel }
        return CardPrompt(
            goal: card.goal,
            inputMode: inputMode,
            inputText: inputText,
            inputArtifactID: inputArtifactID,
            doneCondition: card.doneCondition,
            expectedOutcomes: outcomes
        )
    }

    /// Executes a card's body. The v1 implementation reuses the daemon's
    /// session/turn machinery (the cron path); tests use a scripted double.
    public protocol CardExecutor: Sendable {
        func run(_ prompt: CardPrompt, card: Card, settings: BoardSettings) async throws -> CardResult
    }
}
