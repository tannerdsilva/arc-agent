import Foundation

/// A structured event emitted while a streaming turn runs.
///
/// ``ArcAgent/streamTurn(message:)`` yields these events as the turn
/// progresses. The string-oriented ``ArcAgent/streamConversation(message:)``
/// is a projection of the same execution: it forwards ``textDelta(_:)``
/// verbatim, synthesises the historic `[Tool: name] result` lines from
/// ``toolCallFinished(id:name:result:)``, and forwards ``failed(_:)`` — so
/// existing CLI and gateway consumers see byte-identical output.
///
/// ## Ordering
///
/// ``completed(finalText:)`` and ``failed(_:)`` are terminal: no event
/// follows them and the stream finishes. All other events may interleave
/// (``toolCallStarted(id:name:arguments:)`` / ``toolCallFinished(id:name:result:)``
/// bracket each tool call; ``usage(_:)`` appears when the provider reports it).
///
/// ## Concurrency
///
/// ``AgentTurnEvent`` is ``Sendable``; events cross from the agent actor to
/// the consuming task and contain only value types.
public enum AgentTurnEvent: Sendable {

    /// Visible assistant text, with streamed think-blocks already scrubbed.
    case textDelta(String)

    /// Thinking/reasoning text from a reasoning model. Delivered for display
    /// only — it never reaches ``completed(finalText:)``.
    case reasoningDelta(String)

    /// A tool call started executing. `arguments` is the full JSON argument
    /// string assembled from the stream.
    case toolCallStarted(id: String, name: String, arguments: String)

    /// A tool call finished. `result` is the complete, redacted tool result —
    /// the same string appended to the transcript.
    case toolCallFinished(id: String, name: String, result: String)

    /// Token usage reported by the provider for one model round.
    case usage(Usage)

    /// The turn finished with a visible answer. `finalText` is the full
    /// assistant-visible text — the concatenation of the turn's
    /// ``textDelta(_:)`` payloads. Terminal.
    case completed(finalText: String)

    /// The turn stopped on an error or an interruption notice. `message` is
    /// the complete visible text (already prefixed, e.g. `Error: …`).
    /// Terminal.
    case failed(String)
}