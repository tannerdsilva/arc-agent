import ArcAgentCore

/// The transcript notice a failed turn leaves behind.
///
/// The generic "connection to the model was lost" line is the fallback, not the
/// rule: an endpoint that did not answer is reported by name, because the
/// address is the one thing the reader can act on — a stale preset and a dead
/// server both read as "connection lost" otherwise, with nothing to fix.
enum TurnFailureNotice {

    /// - Parameters:
    ///   - stopped: the user asked for the stop, which is an outcome, not a failure.
    ///   - failure: the error the turn actually threw, when there was one.
    static func text(stopped: Bool, failure: Error?) -> String {
        if stopped {
            return "Turn interrupted — stopped by the user."
        }
        if let llm = failure as? LLMError,
           case .endpointUnreachable(let endpoint, let detail) = llm {
            return "Cannot reach the model endpoint \(endpoint) — \(detail)"
        }
        return "Turn interrupted — the connection to the model was lost."
    }
}
