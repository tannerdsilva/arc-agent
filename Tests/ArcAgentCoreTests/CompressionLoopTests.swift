import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// MARK: - Compression loop reproducer
// =========================================================================

/// The compression loop must converge. Once a request is over budget, a pass
/// has to bring it back under (or make real progress and stop) — not replace
/// the middle with a copy of itself and fire again on the next iteration.
extension ArcCoreTestRoot {
    @Suite("Compression loop convergence", .serialized)
    struct CompressionLoopTests {

        private func makeAgent(
            registry: CompileTimeToolRegistry,
            httpClient: HTTPClient,
            client: any LLMClient,
            initialHistory: [Message],
            budget: Int,
            maxIterations: Int
        ) async -> ArcAgent {
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: String(),
                registry: registry,
                skills: [],
                maxIterations: maxIterations,
                maxTurnDuration: 30,
                persistSessions: false,
                approvalMode: .off,
                query: nil,
                maxContextTokens: budget,
                contextLength: nil,
                compressionBudget: budget,
                injectProjectContext: false,
                initialHistory: initialHistory,
                autoCompression: true
            )
            let agent = ArcAgent(config: config)
            await agent.setupClient(httpClient: httpClient)
            await agent.setClient(client)
            return agent
        }

        /// Deterministic filler: `TokenCounter` scores this at ~0.22 tok/char.
        private func filler(_ tag: String, chars: Int) -> String {
            let unit = "alpha beta gamma delta epsilon zeta eta theta iota kappa. "
            var s = "\(tag) "
            while s.count < chars { s += unit }
            return String(s.prefix(chars))
        }

        private func seedHistory(exchanges: Int, charsEach: Int) -> [Message] {
            var seed: [Message] = []
            for i in 0..<exchanges {
                seed.append(Message(role: .user, content: filler("q\(i)", chars: charsEach)))
                seed.append(Message(role: .assistant, content: filler("a\(i)", chars: charsEach)))
            }
            return seed
        }

        /// Every round calls a tool, so the turn loop iterates; each round adds
        /// a tool result to the history (the loop the bug lived in).
        private func toolCallingClient() -> EventScriptClient {
            let call = ToolCallDelta(
                index: 0,
                id: "call_1",
                name: "read_file",
                arguments: #"{"path":"arc-does-not-exist.txt"}"#
            )
            return EventScriptClient(
                first: .init(toolCalls: [call]),
                final: .init(toolCalls: [call])
            )
        }

        private func schemaTokens(_ registry: CompileTimeToolRegistry, budget: Int) throws -> Int {
            let schemas = ProgressiveToolDisclosure.buildPromptSchemas(
                registry: registry, disabled: [], config: ToolSearchConfig(), contextLength: budget
            )
            let data = try JSONSerialization.data(withJSONObject: schemas)
            return TokenCounter().count(String(data: data, encoding: .utf8) ?? "")
        }

        @Test("one over-budget turn converges: compression does not run every iteration")
        func convergesWithinOneTurn() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let counter = TokenCounter()
            let budget = 32_000
            let seed = seedHistory(exchanges: 30, charsEach: 1_600)
            let client = toolCallingClient()
            let registry = try ArcAgentCore.testRegistry()
            let agent = await makeAgent(
                registry: registry, httpClient: httpClient, client: client,
                initialHistory: seed, budget: budget, maxIterations: 8
            )

            var compressions = 0
            for try await event in agent.streamTurn(message: "go") {
                if case .compressing = event { compressions += 1 }
            }

            let schemas = try schemaTokens(registry, budget: budget)
            let sizes = client.allRecordedMessages.map { counter.count(messages: $0) }
            // The real request is messages + tool schemas (the estimate the
            // engine gates on). Every request after the single pass must fit.
            let requests = sizes.map { $0 + schemas }
            #expect(compressions == 1,
                "compression ran \(compressions) times in one turn (requests: \(requests))")
            #expect(requests.allSatisfy { $0 <= budget },
                "a request still exceeded the budget after compression: \(requests)")
            // The pass must summarize the middle, not take the empty-middle
            // emergency branch that keeps only the last few messages.
            let survived = try #require(client.allRecordedMessages.first)
                .filter { $0.role != .system }.count
            #expect(survived >= 20,
                "compression collapsed the conversation to \(survived) non-system messages")
        }

        @Test("compression makes real progress, not a same-size copy")
        func compressionReducesTheRequest() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let counter = TokenCounter()
            let budget = 32_000
            let seed = seedHistory(exchanges: 30, charsEach: 1_600)
            let client = toolCallingClient()
            let registry = try ArcAgentCore.testRegistry()
            let agent = await makeAgent(
                registry: registry, httpClient: httpClient, client: client,
                initialHistory: seed, budget: budget, maxIterations: 2
            )

            for try await _ in agent.streamTurn(message: "go") {}

            // First recorded request is the post-compression one. The seed +
            // system prompt alone is ~27K; a working pass must cut it hard.
            let firstRequest = counter.count(messages: try #require(client.allRecordedMessages.first))
            #expect(firstRequest < 24_000,
                "compression left the request at \(firstRequest) tokens — the middle was copied, not summarized")
        }
    }
}

// =========================================================================
// MARK: - Budgeting primitives
// =========================================================================

extension ArcCoreTestRoot {
    @Suite("Compression budgeting")
    struct CompressionBudgetingTests {

        private let counter = TokenCounter()

        private func count(_ s: String) -> Int { counter.count(s, model: "gpt-4o") }

        private func msg(_ role: Message.Role, _ content: String, name: String? = nil) -> Message {
            Message(role: role, content: content, name: name)
        }

        private func body(chars: Int, tag: String = "") -> String {
            let unit = "alpha beta gamma delta epsilon zeta eta theta iota kappa. "
            var s = tag
            while s.count < chars { s += unit }
            return String(s.prefix(chars))
        }

        @Test("history budget subtracts the fixed overhead")
        func requestBudget() {
            let b = ContextCompression.RequestBudget(limit: 32_000, overhead: 11_500)
            #expect(b.historyBudget == 20_500)
            // overhead can never push the budget negative
            #expect(ContextCompression.RequestBudget(limit: 100, overhead: 500).historyBudget == 0)
        }

        @Test("tail and summary share what the head leaves")
        func budgets() {
            let wide = ContextCompression.budgets(
                historyBudget: 100_000, headTokens: 1_000, compressibleTokens: 90_000
            )
            #expect(wide.tail <= 20_000)
            #expect(wide.summary == 6_000)

            let tight = ContextCompression.budgets(
                historyBudget: 20_000, headTokens: 1_000, compressibleTokens: 22_000
            )
            #expect(tight.tail + tight.summary <= 19_000)
            #expect(tight.summary > 0)

            let none = ContextCompression.budgets(
                historyBudget: 500, headTokens: 900, compressibleTokens: 4_000
            )
            #expect(none.tail == 0 && none.summary == 0)

            // A history far under the budget must still keep half of its
            // compressible region out of the tail — otherwise the tail
            // swallows the middle and the pass destroys instead of summarizes.
            let small = ContextCompression.budgets(
                historyBudget: 9_000, headTokens: 100, compressibleTokens: 4_000
            )
            #expect(small.tail <= 1_950)
            #expect(small.tail + small.summary <= 8_900)
        }

        @Test("extractive summary is bounded by its budget")
        func extractiveBounded() {
            let material = (0..<40).map {
                msg($0.isMultiple(of: 2) ? .user : .assistant, body(chars: 2_000, tag: "m\($0) "))
            }
            let budget = 1_000
            let summary = ContextCompression.extractiveSummary(
                previous: "", material: material, budget: budget, countTokens: count
            )
            #expect(!summary.isEmpty)
            #expect(count(summary) <= budget,
                "extractive summary exceeded its budget: \(count(summary)) > \(budget)")
        }

        @Test("extractive summary folds the previous summary instead of dropping it")
        func extractiveFoldsPrevious() {
            let previous = "## Historical Task Snapshot\nUser asked: keep the parser work. " + body(chars: 1_200)
            let material = [msg(.assistant, body(chars: 3_000, tag: "new "))]
            let summary = ContextCompression.extractiveSummary(
                previous: previous, material: material, budget: 2_000, countTokens: count
            )
            #expect(summary.contains("keep the parser work"))
            #expect(summary.contains("new "))
            #expect(count(summary) <= 2_000)
        }

        @Test("extractive summary keeps the newest material and truncates huge lines")
        func extractiveNewestFirst() {
            let huge = msg(.tool, body(chars: 20_000, tag: "HUGE "), name: "terminal")
            let recent = msg(.assistant, body(chars: 400, tag: "RECENT "))
            let summary = ContextCompression.extractiveSummary(
                previous: "", material: [huge, recent], budget: 600, countTokens: count
            )
            #expect(summary.contains("RECENT"))
            #expect(count(summary) <= 600)
        }

        @Test("boundToTokenBudget clamps an over-eager model summary")
        func boundToBudget() {
            let text = body(chars: 40_000)
            let bounded = ContextCompression.boundToTokenBudget(text, budget: 1_000, countTokens: count)
            #expect(count(bounded) <= 1_000)
            #expect(bounded.contains("truncated"))
            // under budget: untouched
            let small = "short summary"
            #expect(ContextCompression.boundToTokenBudget(small, budget: 1_000, countTokens: count) == small)
        }

        @Test("clampToBudget trims the oldest tail messages, never the protected prefix")
        func clampTrimsTail() {
            var msgs = [Message(role: .system, content: "summary marker")]
            msgs += (0..<20).map { msg(.user, body(chars: 1_000, tag: "t\($0) ")) }
            let clamped = ContextCompression.clampToBudget(
                msgs, protectedPrefix: 1, budget: 2_000, countTokens: count
            )
            #expect(clamped.first?.role == .system)
            #expect(clamped.count < msgs.count)
            #expect(clamped.count >= 1 + 2)
            // the newest message survives, the oldest tail does not
            #expect(clamped.last?.content == msgs.last?.content)
            #expect(!clamped.contains { $0.content == msgs[1].content })
        }

        @Test("clamping the tail never leaves orphaned tool results on the wire")
        func clampKeepsWireConsistency() {
            var msgs = [Message(role: .system, content: "summary marker")]
            for i in 0..<10 {
                msgs.append(Message(
                    role: .assistant, content: nil,
                    toolCalls: [ToolCall(id: "c\(i)", function: ToolCallFunction(name: "read_file", arguments: "{}"))]
                ))
                msgs.append(Message(role: .tool, content: body(chars: 1_000, tag: "r\(i) "), name: "read_file", toolCallID: "c\(i)"))
            }
            let trimmed = ContextCompression.orphanCleanup(
                ContextCompression.clampToBudget(msgs, protectedPrefix: 1, budget: 1_500, countTokens: count)
            )
            let declared = Set(trimmed.filter { $0.role == .assistant }.flatMap { ($0.toolCalls ?? []).map(\.id) })
            let results = trimmed.filter { $0.role == .tool }.compactMap(\.toolCallID)
            #expect(trimmed.count < msgs.count, "the clamp did not trim anything")
            #expect(!results.isEmpty)
            #expect(results.allSatisfy { declared.contains($0) },
                "trimming left tool results without their assistant call")
        }

        @Test("clampToBudget leaves a fitting history untouched")
        func clampNoop() {
            let msgs = (0..<4).map { msg(.user, "small \($0)") }
            let clamped = ContextCompression.clampToBudget(
                msgs, protectedPrefix: 1, budget: 10_000, countTokens: count
            )
            #expect(clamped == msgs)
        }
    }
}
