import Foundation

// MARK: - Mixture of Agents (Hermes `moa_loop.py`)

/// Advisory reference prompt — references are NOT the acting agent, cannot
/// call tools, and must never claim actions (Hermes `_REFERENCE_SYSTEM_PROMPT`).
public enum MoAPrompts {
    public static let referenceSystemPrompt = """
    You are a reference advisor in a Mixture of Agents (MoA) process. You are \
    NOT the acting agent and you do NOT execute anything: you cannot call \
    tools, run commands, browse, or access files, repositories, or URLs, and \
    you should not try to or apologize for being unable to. A separate \
    aggregator/orchestrator model holds those capabilities and will take the \
    actual actions.

    CRITICAL: You must NEVER claim or imply that you have executed a command, \
    downloaded a file, accessed a URL, or performed any action. You can only \
    analyze and advise based on the conversation context.

    The conversation below is the current state of a task handled by that \
    acting agent. Your job is to give your most intelligent analysis of that \
    state: understand the goal, reason about the problem, and advise on what \
    to do next. Surface the best approach, concrete next steps and tool-use \
    strategy, likely pitfalls and risks, and anything the acting agent may \
    have missed.
    """

    /// Trailing marker appended when the advisory view ends on an assistant
    /// turn (every tool iteration after the first), so references respond to
    /// the current state (Hermes `_ADVISORY_INSTRUCTION`).
    public static let advisoryInstruction = """
    [The conversation above is the current state of the task. Give your \
    most intelligent judgement: what is going on, what should happen next, \
    what risks or mistakes you see, and how the acting agent should proceed.]
    """
}

/// Runs the reference fan-out and synthesizes an advisory context block.
/// Every failure is turned into a model-specific note instead of aborting
/// the turn (Hermes `aggregate_moa_context`): the main model can still act
/// with partial context.
public actor MoAService {

    public static let maxConcurrentReferences = 8
    public static let referencePollIntervalSeconds = 5.0
    public static let toolResultBudgetChars = 4_000
    public static let referenceDefaultOutputReserve = 8_192
    public static let referenceTrimSafetyFraction = 0.10

    /// Client factory so tests can inject scripted clients; default builds
    /// OpenAI-compatible clients from the profile.
    public typealias ClientFactory = @Sendable (MoAConfig.Role, String) async throws -> (any LLMClient)?

    let config: MoAConfig
    let makeClient: ClientFactory
    let aggregatorModelName: String?
    /// Trace writer sink (default: in-memory only; callers may attach).
    public private(set) var lastTrace: MoATrace?

    public init(
        config: MoAConfig,
        aggregatorModelName: String? = nil,
        makeClient: @escaping ClientFactory = { role, apiKey in
            _ = apiKey
            return nil
        }
    ) {
        self.config = config
        self.aggregatorModelName = aggregatorModelName
        self.makeClient = makeClient
    }

    public struct Result: Sendable {
        public let advisoryBlock: String
        public let notes: [String]
        public let trace: MoATrace
    }

    /// Run all references, join their advice, and produce the advisory block
    /// appended to the acting model's context (Hermes joins each advisor as
    /// `Reference N — label:`). Failure notes are always included so the main
    /// model sees what could not be consulted.
    public func aggregate(
        userPrompt: String,
        apiMessages: [[String: Any]],
        turnID: String = UUID().uuidString
    ) async -> Result {
        let started = Date()
        guard config.enabled || !config.referenceModels.isEmpty, !config.referenceModels.isEmpty else {
            return Result(advisoryBlock: "", notes: [], trace: MoATrace(turnID: turnID, startedAt: started))
        }

        let results = await runReferencesParallel(userPrompt: userPrompt, apiMessages: apiMessages)

        var blocks: [String] = []
        var notes: [String] = []
        for (index, result) in results.enumerated() where result.status == "ok" {
            if let text = result.text, !text.isEmpty {
                blocks.append("Reference \(index + 1) — \(result.label):\n\(text)")
            } else {
                notes.append("[MoA] Reference \(index + 1) (\(result.label)) produced no advice.")
            }
        }
        for (index, result) in results.enumerated() where result.status != "ok" {
            if result.status == "skipped" {
                notes.append("[MoA] Reference \(index + 1) (\(result.label)) — skipped: interrupted by user.")
            } else {
                let detail = result.error ?? "unknown error"
                notes.append("[MoA] Reference \(index + 1) (\(result.label)) — failed: \(detail)")
            }
        }

        let advisoryBlock: String
        if blocks.isEmpty {
            advisoryBlock = instructions(for: notes)
        } else {
            let joined = blocks.joined(separator: "\n\n")
            advisoryBlock = joined + "\n\n" + instructions(for: notes)
        }

        let trace = MoATrace(
            turnID: turnID,
            startedAt: started,
            referenceResults: results,
            joinedAt: Date(),
            aggregatorModel: aggregatorModelName ?? config.aggregator?.model
        )
        lastTrace = trace
        return Result(advisoryBlock: advisoryBlock, notes: notes, trace: trace)
    }

    func instructions(for notes: [String]) -> String {
        guard config.degradedReferencePolicy == "loud", !notes.isEmpty else { return "" }
        return "Note: some reference advisors could not be consulted:\n\(notes.joined(separator: "\n"))"
    }

    // MARK: - Reference fan-out (Hermes `_run_references_parallel`)

    func runReferencesParallel(userPrompt: String, apiMessages: [[String: Any]]) async -> [MoAReferenceResult] {
        // Slots = configured references, capped at the concurrent limit.
        let slots = Array(config.referenceModels.prefix(config.maxConcurrentReferences))
        let advisoryView = Self.advisoryMessages(apiMessages: apiMessages, userPrompt: userPrompt)

        return await withTaskGroup(of: (Int, MoAReferenceResult).self) { group in
            for (index, slot) in slots.enumerated() {
                group.addTask {
                    let result = await self.runOneReference(slot: slot, messages: advisoryView)
                    return (index, result)
                }
            }
            var results: [Int: MoAReferenceResult] = [:]
            for await (index, result) in group {
                results[index] = result
            }
            return slots.indices.compactMap { results[$0] }
        }
    }

    func runOneReference(slot: MoAConfig.Role, messages: [[String: Any]]) async -> MoAReferenceResult {
        let started = Date()
        let label = slot.model
        let apiKey = referenceAPIKey(for: slot)
        do {
            guard let client = try await makeClient(slot, apiKey) else {
                return MoAReferenceResult(label: label, model: slot.model, status: "failed",
                                          outputTokens: nil, durationMs: nil,
                                          error: "no client factory for role", text: nil)
            }
            let refMessages: [Message] = [Message(role: .system, content: MoAPrompts.referenceSystemPrompt)]
                + trimmed(messages, model: slot.model).map { entry in
                    Message(
                        role: (entry["role"] as? String) == "assistant" ? .assistant : .user,
                        content: entry["content"] as? String ?? ""
                    )
                }
            let response = try await client.complete(
                messages: refMessages,
                tools: nil
            )
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            return MoAReferenceResult(
                label: label, model: slot.model, status: "ok",
                outputTokens: response.usage?.completionTokens,
                durationMs: durationMs,
                error: nil,
                text: response.content
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            return MoAReferenceResult(
                label: label, model: slot.model, status: "failed",
                outputTokens: nil, durationMs: durationMs,
                error: String(describing: error), text: nil
            )
        }
    }

    func referenceAPIKey(for slot: MoAConfig.Role) -> String {
        // Key resolution is delegated to the caller's client factory in the
        // port; a placeholder is passed through so factories can ignore it.
        ""
    }

    /// Advisory view of the conversation (Hermes `_reference_messages`): keep
    /// the agent's tool calls and results, trim for the reference's smaller
    /// window (reserving output headroom + 10% safety), and append the
    /// advisory instruction when the view ends on an assistant turn.
    func trimmed(_ messages: [[String: Any]], model: String) -> [[String: Any]] {
        var view = messages
        // Reserve output headroom (Hermes `_REFERENCE_DEFAULT_OUTPUT_RESERVE`).
        let meta = ModelMetadataRegistry.shared.metadata(for: model, provider: nil)
        let window = meta.contextLength
        let reserve = config.referenceMaxTokens ?? Self.referenceDefaultOutputReserve
        let budget = Int(Double(window) * (1 - Self.referenceTrimSafetyFraction)) - reserve
        // Rough char→token estimate (chars/4, Hermes estimate_messages_tokens_rough).
        var used = 0
        var kept: [[String: Any]] = []
        for msg in view.reversed() {
            let text = (msg["content"] as? String) ?? ""
            used += text.utf8.count / 4
            kept.insert(msg, at: 0)
            if used > budget { break }
        }
        view = kept

        // Append advisory instruction if the view ends on an assistant turn.
        if let last = view.last, (last["role"] as? String) == "assistant" {
            view.append(["role": "user", "content": MoAPrompts.advisoryInstruction])
        } else if let last = view.last, (last["role"] as? String) == "user",
                  (last["content"] as? String) != MoAPrompts.advisoryInstruction {
            // Ends on the fresh user turn: the reference answers directly.
        }
        if view.isEmpty {
            view = [["role": "user", "content": "Provide your analysis."]]
        }
        return view
    }

    /// Build the advisory message list (Hermes `_reference_messages` +
    /// system prompt prepend) as plain `[user/assistant]` turns.
    public static func advisoryMessages(apiMessages: [[String: Any]], userPrompt: String) -> [[String: Any]] {
        var view: [[String: Any]] = []
        for msg in apiMessages {
            let role = (msg["role"] as? String) ?? "user"
            // Preserve tool calls and tool results so references see what the
            // agent actually did (Hermes keeps both sides).
            if role == "tool" {
                view.append(["role": "user", "content": "[tool result] \(msg["content"] as? String ?? "")"])
                continue
            }
            var content = msg["content"] as? String ?? ""
            if let calls = msg["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let fn = (call["function"] as? [String: Any]) ?? [:]
                    content += "\n[tool call] \(fn["name"] as? String ?? "")(\(fn["arguments"] as? String ?? ""))"
                }
            }
            if content.isEmpty { continue }
            view.append(["role": role == "system" ? "user" : role, "content": content])
        }
        if let last = view.last, (last["role"] as? String) == "assistant" {
            view.append(["role": "user", "content": MoAPrompts.advisoryInstruction])
        }
        if view.isEmpty {
            view = [["role": "user", "content": userPrompt.isEmpty ? "Provide your analysis." : userPrompt]]
        }
        return view
    }
}
