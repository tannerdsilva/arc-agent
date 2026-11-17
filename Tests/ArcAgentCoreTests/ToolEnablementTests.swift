import AsyncHTTPClient
import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Tool enablement (T6)

/// One tool, three questions: is it advertised, is it dispatchable, and does
/// the operator get told when the config names nothing?
///
/// The matrix below is the plan's T6 table, one test per row. The last two
/// tests are the invariant the slice exists for: the schema array and dispatch
/// cannot disagree, because both read ``ToolEnablement``.
extension ArcCoreTestRoot {
    @Suite("tool enablement", .serialized)
    struct ToolEnablementTests {

        // MARK: The resolution matrix

        @Test("toolset on, no override: enabled")
        func toolsetOnNoOverride() {
            let config = ToolEnablementConfig()
            #expect(ToolEnablement.isEnabled(tool: "write_file", toolset: .file, config: config))
        }

        @Test("toolset off beats a per-tool enable")
        func toolsetOffBeatsToolOn() {
            let config = ToolEnablementConfig(
                disabledToolsets: ["file"], enabledTools: ["write_file"])
            #expect(ToolEnablement.isEnabled(tool: "write_file", toolset: .file, config: config) == false)
        }

        @Test("toolset on, tool off: disabled")
        func toolsetOnToolOff() {
            let config = ToolEnablementConfig(disabledTools: ["write_file"])
            #expect(ToolEnablement.isEnabled(tool: "write_file", toolset: .file, config: config) == false)
            // the sibling in the same toolset is untouched: this is the
            // per-tool switch, not a second toolset switch.
            #expect(ToolEnablement.isEnabled(tool: "read_file", toolset: .file, config: config))
        }

        @Test("toolset on, tool on: enabled")
        func toolsetOnToolOn() {
            let config = ToolEnablementConfig(enabledTools: ["write_file"])
            #expect(ToolEnablement.isEnabled(tool: "write_file", toolset: .file, config: config))
        }

        @Test("toolset off beats a whole-toolset per-tool enable list")
        func toolsetOffBeatsGlobalToolEnable() {
            let config = ToolEnablementConfig(
                disabledToolsets: ["file"],
                enabledTools: ["read_file", "write_file", "patch"]
            )
            for tool in ["read_file", "write_file", "patch"] {
                #expect(ToolEnablement.isEnabled(tool: tool, toolset: .file, config: config) == false)
            }
        }

        @Test("an explicit enable beats a per-tool disable for the same name")
        func enableIsReadAfterDisable() {
            // the one precedence rule a config can contradict itself over.
            let config = ToolEnablementConfig(
                disabledTools: ["write_file"], enabledTools: ["write_file"])
            #expect(ToolEnablement.isEnabled(tool: "write_file", toolset: .file, config: config))
        }

        // MARK: Unknown names (F18)

        @Test("unknownNames reports a typo in either list")
        func unknownNamesReportsTypos() throws {
            let registry = try ArcAgentCore.testRegistry()
            let config = ToolEnablementConfig(
                disabledTools: ["raed_file"],       // typo in the deny list
                enabledTools: ["wrtie_file"]        // typo in the enable list
            )
            #expect(ToolEnablement.unknownNames(in: config, catalog: registry.allTools)
                == ["raed_file", "wrtie_file"])
        }

        @Test("unknownNames reports nothing for a clean config")
        func unknownNamesClean() throws {
            let registry = try ArcAgentCore.testRegistry()
            let config = ToolEnablementConfig(
                disabledTools: ["write_file"],
                enabledTools: ["read_file"]
            )
            #expect(ToolEnablement.unknownNames(in: config, catalog: registry.allTools).isEmpty)
            // an empty config — the shape every file written before T6 decodes
            // to — says nothing, which is also what it means.
            #expect(ToolEnablement.unknownNames(in: .none, catalog: registry.allTools).isEmpty)
        }

        @Test("the config block decodes with and without the per-tool keys")
        func configShapeIsTolerant() throws {
            let legacy = try JSONDecoder().decode(
                ToolsConfig.self,
                from: Data(#"{"disabledToolsets":["terminal"],"disabledSkills":[]}"#.utf8))
            #expect(legacy.disabledTools == nil)
            #expect(legacy.enabledTools == nil)
            #expect(legacy.disabledToolsetSet == ["terminal"])
            #expect(legacy.toolEnablement == ToolEnablementConfig(disabledToolsets: ["terminal"]))

            let current = try JSONDecoder().decode(
                ToolsConfig.self,
                from: Data(#"{"disabledTools":["write_file"],"enabledTools":["read_file"]}"#.utf8))
            #expect(current.disabledToolSet == ["write_file"])
            #expect(current.enabledToolSet == ["read_file"])
            #expect(current.disabledToolsets.isEmpty)

            // and a re-encode of the legacy shape does not invent the keys.
            let encoded = try JSONEncoder().encode(legacy)
            let text = String(decoding: encoded, as: UTF8.self)
            #expect(!text.contains("disabledTools\""))
            #expect(!text.contains("enabledTools\""))
        }

        // MARK: The two-consumer invariant

        @Test("a per-tool disable removes the schema and is refused at dispatch, same text")
        func schemaAndDispatchAgree() async throws {
            let registry = try ArcAgentCore.testRegistry()

            // consumer 1: the renderer. the baseline render carries the tool;
            // the per-tool disable removes exactly that one.
            let baseline = ToolSchemaRenderer.eagerSchemas(
                registry: registry, enablement: .none)
            let baselineNames = baseline.compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
            #expect(baselineNames.contains("read_file"), "fixture assumption: read_file is advertised")

            let filtered = ToolSchemaRenderer.eagerSchemas(
                registry: registry,
                enablement: ToolEnablementConfig(disabledTools: ["read_file"]))
            let filteredNames = filtered.compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
            #expect(!filteredNames.contains("read_file"))
            #expect(filteredNames.count == baselineNames.count - 1)

            // consumer 2: dispatch. the model names the tool the schema no
            // longer offers — exactly what the enforcement exists for.
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }
            let agent = await Self.makeAgent(
                registry: registry,
                httpClient: httpClient,
                disabledTools: ["read_file"]
            )
            await agent.setClient(DisabledToolProbeClient(tool: "read_file"))
            let response = try await agent.runConversation(message: "read the file")

            // exact equality: the refusal quotes the tool name, so a `contains`
            // assertion here would pass on any string that mentions it.
            #expect(response == "Error: Tool 'read_file' is disabled (the tool itself is disabled by configuration).")
        }

        @Test("the toolset refusal keeps its wording, and the per-tool rule names itself")
        func refusalNamesTheRuleThatFired() async throws {
            let registry = try ArcAgentCore.testRegistry()
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let byToolset = await Self.makeAgent(
                registry: registry,
                httpClient: httpClient,
                disabledToolsets: ["file"]
            )
            await byToolset.setClient(DisabledToolProbeClient(tool: "read_file"))
            let response = try await byToolset.runConversation(message: "read the file")
            #expect(response == "Error: Tool 'read_file' is disabled (toolset 'file' is disabled by configuration).")
        }

        /// the agent every dispatch assertion runs through: the
        /// `AgentIntegrationTests` shape, minimal and scripted.
        private static func makeAgent(
            registry: CompileTimeToolRegistry,
            httpClient: HTTPClient,
            disabledToolsets: Set<String> = [],
            disabledTools: Set<String> = []
        ) async -> ArcAgent {
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "",
                registry: registry,
                skills: [],
                maxIterations: 3,
                maxTurnDuration: 30,
                persistSessions: false,
                approvalMode: .manual,
                query: nil,
                maxContextTokens: 64_000,
                disabledToolsets: disabledToolsets,
                disabledTools: disabledTools
            )
            let agent = ArcAgent(config: config)
            await agent.setupClient(httpClient: httpClient)
            return agent
        }
    }
}

/// Names one tool unconditionally on turn 1 — whether or not the schema
/// advertises it, which is the case dispatch has to refuse — then answers with
/// the tool's result verbatim on turn 2.
struct DisabledToolProbeClient: LLMClient {

    let tool: String

    private func refusalOrAnswer(_ messages: [Message]) -> String? {
        messages.last(where: { $0.role == .tool })?.content
    }

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        if let answer = refusalOrAnswer(messages) {
            return LLMResponse(content: answer)
        }
        return LLMResponse(
            content: nil,
            toolCalls: [
                ToolCall(
                    id: "call_disabled",
                    function: ToolCallFunction(name: tool, arguments: "{}")
                )
            ]
        )
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        let answer = refusalOrAnswer(messages)
        let tool = self.tool
        return AsyncThrowingStream { continuation in
            Task {
                if let answer {
                    continuation.yield(LLMDelta(content: answer))
                } else {
                    continuation.yield(LLMDelta(
                        content: nil,
                        toolCalls: [
                            ToolCallDelta(
                                index: 0,
                                id: "call_disabled",
                                name: tool,
                                arguments: "{}"
                            )
                        ]
                    ))
                }
                continuation.finish()
            }
        }
    }
}
