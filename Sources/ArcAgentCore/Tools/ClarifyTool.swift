import Foundation

/// Hermes-parity `clarify` tool.
///
/// Asks the user a question (optionally with up to 4 choices) and returns
/// their response as the tool result. The WebUI intercepts this tool before
/// dispatch and renders the Hermes-style "Clarification needed" card attached
/// to the composer; the answer (or a best-judgement timeout notice after 120 s)
/// is returned to the model as the tool result.
///
/// In execution contexts without a UI (CLI TUI, gateway, headless), invoking
/// this tool returns an error — matching Hermes' clarify tool behaviour when
/// no platform callback is injected.
public enum ClarifyTool {

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
        handler: { _ in
            "Error: Clarify tool is not available in this execution context."
        }
    )
}
