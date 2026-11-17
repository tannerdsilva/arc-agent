import Foundation
import Logging

extension KanbanAgent {

    /// The real judge (spec 05 §5): one structured sub-call per verb through
    /// the normal provider stack — the cron aux classifier's pattern
    /// (constrained output, first-parse fallback, never a free chat).
    ///
    /// Prompts are composed per call from board state; the raw document is
    /// never shipped. Unparseable output throws `KanbanJudgeUnavailable`,
    /// which the engine handles like any judge unavailability (retry, then
    /// stale-motion/forced fallbacks).
    public struct LLMKanbanJudge: KanbanJudge {
        public let client: LLMClient
        public let model: String
        public var log: Logger = .init(label: "kanban.judge")

        public init(client: LLMClient, model: String) {
            self.client = client
            self.model = model
        }

        // MARK: Verb 1 — transition

        public func chooseTransition(_ req: TransitionRequest) async throws -> TransitionDecision {
            let edges = req.legalEdges.map { edge in
                var line = "- id: \(edge.id) → column '\(edge.toColumnID)'"
                if edge.decision == .deterministic, let label = edge.outcomeLabel {
                    line += " (deterministic: outcome \(label))"
                } else if edge.isAskTheUser {
                    line += " (asks the user — use when you cannot proceed)"
                }
                return line
            }.joined(separator: "\n")
            let system = """
            You are the transition judge for a kanban agent. A card finished \
            executing. Choose exactly one legal edge id for its next column \
            and give a one-sentence reasoning. Reply with ONLY a JSON object: \
            {"edgeID": "...", "reasoning": "..."}
            """
            let user = """
            Card: \(req.card.id) — \(req.card.goal)
            Outcome: \(req.result.outcome)
            Summary: \(req.result.summary)
            Legal edges:
            \(edges)
            \(req.reAskNote.map { "NOTE: \($0)" } ?? "")
            """
            return try await call(system, user) { raw in
                guard let obj = Self.object(raw),
                      let edgeID = obj["edgeID"] as? String, !edgeID.isEmpty,
                      let reasoning = obj["reasoning"] as? String, !reasoning.isEmpty else {
                    throw KanbanJudgeUnavailable("unparseable transition decision")
                }
                return TransitionDecision(edgeID: edgeID, reasoning: reasoning)
            }
        }

        // MARK: Verb 2 — generation

        public func generateChildren(_ req: GenerationRequest) async throws -> [GeneratedChild] {
            let columns = req.graph.columns
                .filter { $0.kind == .agentWork || $0.kind == .timerWait }
                .map { "- \($0.id) (\($0.name))" }
                .joined(separator: "\n")
            let system = """
            You are the generation judge for a kanban agent. Decompose the \
            parent's remaining work into children. Each child needs: goal \
            (specific), input mode (summary|inclusion|reference with the \
            parent's id as sourceCardID), doneCondition, targetColumnID from \
            the list, and whyNext. Reply with ONLY JSON: \
            {"children": [{"goal": "...", "inputMode": "...", "inputPayload": "...", \
            "doneCondition": "...", "targetColumnID": "...", "whyNext": "..."}]}
            """
            let user = """
            Root goal: \(req.root.title)
            Definition of done: \(req.root.definitionOfDone)
            Parent: \(req.parentCard.id) — \(req.parentCard.goal)
            Parent result: \(req.parentResult.outcome) — \(req.parentResult.summary)
            Children allowed: \(max(0, req.mintAllowanceRemaining)); current depth \(req.parentCard.generation) of max \(req.maxDepth).
            Target columns:
            \(columns)
            \(req.reAskNote.map { "NOTE (fix this): \($0)" } ?? "")
            """
            return try await call(system, user) { raw in
                guard let obj = Self.object(raw),
                      let children = obj["children"] as? [[String: Any]] else {
                    throw KanbanJudgeUnavailable("unparseable generation")
                }
                return try children.map { child in
                    guard let goal = child["goal"] as? String, !goal.isEmpty,
                          let modeRaw = child["inputMode"] as? String,
                          let mode = InputPassingMode(rawValue: modeRaw),
                          let done = child["doneCondition"] as? String, !done.isEmpty,
                          let target = child["targetColumnID"] as? String,
                          let why = child["whyNext"] as? String else {
                        throw KanbanJudgeUnavailable("generated child missing contract fields")
                    }
                    return GeneratedChild(
                        goal: goal,
                        input: InputPassing(
                            mode: mode, sourceCardID: req.parentCard.id,
                            payload: (child["inputPayload"] as? String) ?? ""),
                        doneCondition: done,
                        targetColumnID: target,
                        whyNext: why)
                }
            }
        }

        // MARK: Verb 3 — evaluation

        public func evaluateRoot(_ req: EvaluationRequest) async throws -> RootVerdict {
            let results = req.tree.compactMap { card -> String? in
                guard let result = card.result else { return nil }
                return "- \(card.id) (gen \(card.generation)): \(result.outcome) — \(result.summary)"
            }.joined(separator: "\n")
            let system = """
            You are the evaluation judge for a kanban agent. Judge the root \
            against its definition of done. Reply with ONLY a JSON object:
            - {"verdict": "continue"}
            - {"verdict": "green", "evidence": [{"clause": "<exact dod line>", \
            "cardIDs": ["..."], "reasoning": "..."}]}
            - {"verdict": "yellow", "attempts": [{"cardID": "...", "whatWasTried": "...", \
            "outcome": "..."}], "blockingUnknown": "...", "provision": \
            {"kind": "decision|credential|information|capability", "detail": "..."}, \
            "alternativesConsidered": ["..."]}
            """
            let user = """
            Root: \(req.root.title)
            Definition of done (one clause per line):
            \(req.root.definitionOfDone)
            Completed results:
            \(results.isEmpty ? "(none)" : results)
            Minted so far: \(req.mintedChildren) (max depth \(req.maxDepth))
            \(req.root.resumeContext.map { "The user resumed this root with: \($0)" } ?? "")
            \(req.reAskNote.map { "NOTE (fix this): \($0)" } ?? "")
            """
            return try await call(system, user) { raw in
                guard let obj = Self.object(raw),
                      let verdict = obj["verdict"] as? String else {
                    throw KanbanJudgeUnavailable("unparseable verdict")
                }
                switch verdict {
                case "continue":
                    return .continue
                case "green":
                    guard let entries = obj["evidence"] as? [[String: Any]], !entries.isEmpty else {
                        return .green(EvidenceChain(entries: [], evaluatedAt: Date()))
                    }
                    let parsed: [EvidenceChain.Entry] = entries.compactMap { entry in
                        guard let clause = entry["clause"] as? String,
                              let cardIDs = entry["cardIDs"] as? [String],
                              let reasoning = entry["reasoning"] as? String else { return nil }
                        return .init(clause: clause, cardIDs: cardIDs, reasoning: reasoning)
                    }
                    return .green(EvidenceChain(entries: parsed, evaluatedAt: Date()))
                case "yellow":
                    let attempts = ((obj["attempts"] as? [[String: Any]]) ?? []).compactMap { a -> MissingReport.Attempt? in
                        guard let cardID = a["cardID"] as? String,
                              let tried = a["whatWasTried"] as? String,
                              let outcome = a["outcome"] as? String else { return nil }
                        return .init(cardID: cardID, whatWasTried: tried, outcome: outcome)
                    }
                    var provision: UserProvision?
                    if let p = obj["provision"] as? [String: Any],
                       let kind = p["kind"] as? String, let detail = p["detail"] as? String {
                        switch kind {
                        case "decision": provision = .decision(detail)
                        case "credential": provision = .credential(detail)
                        case "information": provision = .information(detail)
                        case "capability": provision = .capability(detail)
                        default: provision = .information(detail)
                        }
                    }
                    return .yellow(MissingReport(
                        attempts: attempts,
                        blockingUnknown: (obj["blockingUnknown"] as? String) ?? "",
                        userMustProvide: provision ?? .information("unspecified"),
                        alternativesConsidered: (obj["alternativesConsidered"] as? [String]) ?? [],
                        reportedAt: Date()))
                default:
                    throw KanbanJudgeUnavailable("unknown verdict '\(verdict)'")
                }
            }
        }

        // MARK: plumbing

        /// One structured call; the closure parses the raw text into the
        /// verb's output type. Unparseable → KanbanJudgeUnavailable.
        private func call<T>(
            _ system: String, _ user: String,
            _ parse: @Sendable @escaping (String) throws -> T
        ) async throws -> T {
            let response = try await client.complete(
                messages: [
                    Message(role: .system, content: system),
                    Message(role: .user, content: user),
                ],
                tools: nil)
            do {
                return try parse(response.content ?? "")
            } catch let err as KanbanJudgeUnavailable {
                log.warning("kanban judge parse failure", metadata: ["reason": .init(stringLiteral: err.reason)])
                throw err
            }
        }

        /// Extract the first {...} JSON object from a response (tolerates
        /// prose wrappers and code fences).
        static func object(_ raw: String) -> [String: Any]? {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("```") {
                text = String(text.drop(while: { $0 == "`" || $0.isNewline }))
                if let fence = text.range(of: "```") { text = String(text[..<fence.lowerBound]) }
            }
            guard let start = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}") else { return nil }
            let json = String(text[start...end])
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }
    }
}
