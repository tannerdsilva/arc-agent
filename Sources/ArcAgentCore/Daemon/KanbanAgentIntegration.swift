import ArcAgentCore
import Foundation
import Logging

// MARK: - Kanban-agent daemon integration (spec 04 §6)
//
// The engine rides the daemon's service tree (Second Law) and executes
// cards and judge sub-calls through the session host's turn machinery —
// one prompt in, first response out, fresh context each run (same shape
// as the cron path, and the standing context comes along for free).

extension KanbanAgent {

    /// Real executor: the card's body is rendered by ``cardPrompt(_:_:)``
    /// into a prompt and run through the host's one-shot turn.
    public struct SessionCardExecutor: CardExecutor {

        /// `(prompt) -> first response`.
        private let runner: @Sendable (String) async throws -> String

        public init(runner: @escaping @Sendable (String) async throws -> String) {
            self.runner = runner
        }

        public func run(_ prompt: CardPrompt, card: Card, settings: BoardSettings) async throws -> CardResult {
            var text = "You are executing one card of a kanban board.\n\n"
            text += "Goal: \\(prompt.goal)\n"
            if let input = prompt.inputText, !input.isEmpty {
                text += "\nInput (\\(prompt.inputMode.rawValue)): \\(input)\n"
            }
            if let artifact = prompt.inputArtifactID, !artifact.isEmpty {
                text += "\nInput artifact: \\(artifact)\n"
            }
            text += "\nDone condition (verbatim, you are not done until this holds): \\(prompt.doneCondition)\n"
            if !prompt.expectedOutcomes.isEmpty {
                text += "\nExpected outcomes (use one verbatim as your outcome):\n"
                for o in prompt.expectedOutcomes { text += "- \\(o)\n" }
            }
            text += "\nEnd your reply with two lines:\nOUTCOME: <outcome label>\nSUMMARY: <one paragraph>"

            let response = try await runner(text)
            let (outcome, summary) = Self.parse(response, expected: prompt.expectedOutcomes)
            return CardResult(outcome: outcome, summary: summary)
        }

        /// Outcome = the `OUTCOME:` line if present and (leniently) among
        /// the expected labels; otherwise the last line. Summary strips the
        /// outcome line from the body.
        public static func parse(_ response: String, expected: [String]) -> (String, String) {
            var outcome: String?
            var summaryLines: [String] = []
            var explicitSummary: String?
            for line in response.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("OUTCOME:"), outcome == nil {
                    let raw = trimmed.dropFirst("OUTCOME:".count).trimmingCharacters(in: .whitespaces)
                    if expected.contains(raw) || expected.isEmpty { outcome = raw }
                    else if let match = expected.first(where: { $0.compare(raw, options: .caseInsensitive) == .orderedSame }) {
                        outcome = match
                    }
                } else if trimmed.hasPrefix("SUMMARY:") {
                    let text = trimmed.dropFirst("SUMMARY:".count).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { explicitSummary = text }
                } else {
                    summaryLines.append(trimmed)
                }
            }
            let body = summaryLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = explicitSummary ?? (body.isEmpty ? response : body)
            return (outcome ?? (expected.first ?? response), summary)
        }
    }

    /// The judge's structured sub-calls ride the same turn machinery: the
    /// session agent's full context (SOUL.md, tools, profile) answers the
    /// classification prompt; the adapter's `model` parameter is ignored in
    /// favour of the profile default.
    public struct SessionJudgeClient: LLMClient {

        private let runner: @Sendable (String) async throws -> String

        public init(runner: @escaping @Sendable (String) async throws -> String) {
            self.runner = runner
        }

        public func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
            let text = messages.map { msg in
                let body = msg.content ?? ""
                return "\(msg.role): \(body)"
            }.joined(separator: "\n")
            return LLMResponse(content: try await runner(text))
        }

        public func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
            let request = messages
            let hasTools = tools != nil
            return AsyncThrowingStream { continuation in
                Task { [runner] in
                    do {
                        let response = try await Self(runner: runner).complete(messages: request, tools: hasTools ? [] : nil)
                        if let text = response.content {
                            continuation.yield(LLMDelta(content: text))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}
