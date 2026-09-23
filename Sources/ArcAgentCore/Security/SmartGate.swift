import Foundation

/// Hermes-parity smart-gate helpers shared by the webui settings and the
/// agent harness.
///
/// Hermes decides smart behaviors from configuration and a gate (the
/// auxiliary-LLM "guardian"). arc-agent mirrors that with two toggles:
///
/// - **Smart approval** (`settings.smartApproval`): when on, flagged
///   dangerous commands are assessed by the `approval` auxiliary model
///   (auto-approve low risk, deny high risk, prompt when uncertain) —
///   the exact semantics of Hermes `approvals.mode: smart`
///   (default). When off, the classic manual gate prompts for every
///   flagged command.
/// - **Smart pick-a-path** (`settings.smartPickAPath`): when on, a clarify
///   request that times out (the 120 s pick-a-path panel) is resolved by
///   the auxiliary model choosing among the offered answers instead of
///   the turn proceeding on the main model's unguided judgement.
public enum SmartGate {

    /// Resolve the effective ``ApprovalMode`` from the persisted security
    /// config plus the webui "smart approval" toggle.
    ///
    /// - `configMode == "off"` always wins (YOLO semantics: no approval
    ///   prompts at all, frozen at process start).
    /// - Otherwise the toggle picks smart (aux-LLM guardian) vs manual
    ///   (always prompt). This mirrors Hermes: `approvals.mode: smart`
    ///   is the default runtime choice, and turning it off means manual.
    public static func effectiveApprovalMode(configMode: String, smartApproval: Bool) -> ApprovalMode {
        if configMode == "off" { return .off }
        return smartApproval ? .smart : .manual
    }

    /// Match an auxiliary model's clarify response to one of the offered
    /// pick-a-path choices.
    ///
    /// The guardian is asked to copy one of the offered choices verbatim,
    /// but models routinely echo numbering ("2. Continue"), casing, or
    /// extra punctuation. This matcher is the tolerant counterpart of the
    /// exact-text contract: it normalizes whitespace and punctuation and
    /// prefers (in order) an exact match, a case-insensitive match, a
    /// prefix/numbered match, and finally a containment match. Ambiguous
    /// results (multiple candidates) return `nil` so the caller can fall
    /// back to the guardian's free-form answer.
    ///
    /// - Parameters:
    ///   - response: The raw guardian text.
    ///   - choices: The choices originally offered to the user.
    /// - Returns: The chosen choice (verbatim from `choices`), or `nil`
    ///   when nothing matches reliably.
    public static func matchClarifyChoice(_ response: String, choices: [String]) -> String? {
        let raw = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !choices.isEmpty else { return nil }

        func normalize(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: #"^[\s]*\d+[\.\)][\s]*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[\"\u201C']|[\"\u201D']$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[\.\s]+$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nr = normalize(raw)

        // Exact (verbatim) match wins.
        if let hit = choices.first(where: { $0 == raw }) { return hit }
        // Case-insensitive exact.
        if let hit = choices.first(where: { $0.lowercased() == raw.lowercased() }) { return hit }
        // Normalized (numbering/quotes/punctuation stripped) match.
        if let hit = choices.first(where: { normalize($0) == nr }) { return hit }
        // Containment: response contains a choice, or a choice contains the
        // response — only when unambiguous.
        let contained = choices.filter { c in
            let nc = normalize(c)
            return nc.contains(nr) || nr.contains(nc)
        }
        if contained.count == 1 { return contained[0] }
        return nil
    }
}
