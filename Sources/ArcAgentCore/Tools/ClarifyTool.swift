import Foundation

/// arc-parity `clarify` tool.
///
/// Asks the user a question (optionally with up to 4 choices) and returns
/// their response as the tool result. The WebUI intercepts this tool before
/// dispatch and renders the arc-style "Clarification needed" card attached
/// to the composer; the answer (or a best-judgement timeout notice after 120 s)
/// is returned to the model as the tool result.
///
/// In execution contexts without a UI (CLI TUI, gateway, headless), invoking
/// this tool returns an error — matching reference' clarify tool behaviour when
/// no platform callback is injected. A host that CAN ask a human (the web UI,
/// a TUI) injects a ``Presenter`` through ``presenters`` before its turn
/// dispatches tools; the answer then becomes the tool result.
public enum ClarifyTool {

    /// Presents a clarification question to a human and returns their answer.
    /// `nil` (or an empty answer) means the question went unanswered — the
    /// tool then tells the model to use its best judgement.
    public typealias Presenter = @Sendable (_ question: String, _ choices: [String]) async -> String?

    /// Actor holding the ambient presenter. Injected by the execution host
    /// before a turn dispatches tools — the same pattern as
    /// ``ExecuteCodeTool/Dispatcher``: the host binds a presenter for the
    /// session whose turn is running, and the tool snapshots it per call.
    public actor PresenterBox {
        private var presenter: Presenter?

        public func set(_ presenter: Presenter?) {
            self.presenter = presenter
        }

        func current() -> Presenter? {
            presenter
        }
    }

    /// The process-wide presenter box (nil = headless: the tool errors).
    public static let presenters = PresenterBox()

    /// Answer used when a presenter is injected but the question went
    /// unanswered (user stop, timeout with no fallback).
    static let unansweredText = "No response from the user. Use your best judgement and proceed."

    /// Ask through the ambient presenter (or report unavailability).
    static func ask(args: [String: Any]) async -> String {
        let question = ((args["question"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return "Error: clarify requires a question."
        }
        let choices = Array(((args["choices"] as? [String]) ?? []).prefix(4))
        guard let presenter = await presenters.current() else {
            return "Error: Clarify tool is not available in this execution context."
        }
        guard let answer = await presenter(question, choices),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unansweredText
        }
        return answer
    }

    static let entry = ToolEntry(
        name: "clarify",
        toolset: "core",
        description: "Ask the user a question and wait for their answer. "
            + "Pass up to 4 predefined choices when the answer is one of a set; "
            + "the user may also type a free-form response. The turn pauses until "
            + "the user responds (up to 120 s); if they do not respond in time, "
            + "the tool returns a notice telling you to use your best judgement "
            + "and proceed. Use this instead of guessing when the user's intent "
            + "is genuinely ambiguous and the decision matters.",
        schema: .object(
            description: "Clarification parameters",
            properties: [
                "question": .string(
                    description: "The question to present to the user."
                ),
                "choices": .array(
                    description: "Up to 4 predefined answer choices. Omit for a purely open-ended question.",
                    items: .string(description: "One answer choice.")
                ),
            ],
            required: ["question"]
        ),
        handler: { args in
            await ClarifyTool.ask(args: args)
        }
    )
}
