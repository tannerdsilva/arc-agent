import ArcToolKit
import Foundation
import Synchronization
import Testing
@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - A8 prompt parity (CONVERGE A8, §3.2)
//
// The UI's `buildSystemPrompt` is gone; the core's tiered builder is the only
// prompt builder. The inventory that justified the deletion captured both
// prompts for one fixture conversation (`.hermes/reports/CONVERGE/a8-prompts/`)
// and accepted this delta:
//
//   carried by the core, wording/format changed:
//     - identity + rules  → core identity preamble, Rules block, guidance
//     - "Active configuration: model X via Y"  → the date/session line's
//       `Model: X | Provider: Y`
//     - "Persistent notes (internal memory)"  → `## Memory` + fenced block
//     - "About the user"  → `## User Profile` (scrubbed)
//   carried by the core unchanged:
//     - the skills section and index (same framing, same filtered list)
//     - profile SOUL, as an injected system message
//   ported as config, because the core builder cannot express them:
//     - pinned profile skills (full SKILL.md bodies) → `injectSystemMessage`
//     - the session workspace as the tools' working directory → the factory's
//       `workspaceRoot`, which the environment section now names
//   added by the core (not a UI loss):
//     - tool index, environment block, project-context files, session line
//
// This suite pins that accepted state: every section a chat relies on must
// still reach the model, and the two ports must stay wired.
// ===========================================================================

/// a memory provider with distinct text per block, so the diff can tell the
/// memory section from the user-profile section.
private struct ParityMemory: MemoryProvider {
    let memoryText: String
    let userText: String
    func readMemory() async throws -> String { memoryText }
    func readUser() async throws -> String { userText }
    func appendMemory(_ text: String) async throws {}
    func replaceMemory(old: String, new: String) async throws {}
    func writeMemory(_ text: String) async throws {}
    func appendUser(_ text: String) async throws {}
    func replaceUser(old: String, new: String) async throws {}
    func writeUser(_ text: String) async throws {}
}

/// records every request the core sends; answers with one short final reply.
private final class PromptRecordingClient: LLMClient, Sendable {
    private let requests = Mutex<[[Message]]>([])

    var captured: [[Message]] { requests.withLock { $0 } }

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        throw LLMError.apiError(statusCode: 500, message: "scripted client is streaming-only")
    }

    func complete(
        messages: [Message], tools: [[String: Any]]?, reasoningEffort: String?
    ) async throws -> LLMResponse {
        try await complete(messages: messages, tools: tools)
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        requests.withLock { $0.append(messages) }
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMDelta(content: "ok"))
            continuation.yield(LLMDelta(content: nil, finishReason: "stop"))
            continuation.finish()
        }
    }

    func stream(
        messages: [Message], tools: [[String: Any]]?, reasoningEffort: String?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        stream(messages: messages, tools: tools)
    }
}

extension ArcWebUITestRoot {

    @Suite("prompt parity", .serialized)
    struct PromptParityTests {

        static let preset = ModelConfigPreset(
            name: "a8-parity",
            model: "a8-parity-model",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            contextLength: 8_000,
            maxOutputTokens: 512
        )

        static let sessionID = "s-a8-parity"
        static let workspaceMarker = "a8-parity-workspace"
        static let soulMarker = "SOUL-MARKER"
        static let pinnedMarker = "PINNED-BODY-MARKER"
        static let memoryMarker = "MEMORY-MARKER"
        static let userMarker = "USER-MARKER"
        static let contextMarker = "a8 fixture project context"

        static func skill(_ name: String, _ description: String, _ body: String) -> Skill {
            Skill(name: name, description: description, content: body,
                  path: URL(fileURLWithPath: "/tmp/a8-skills/\(name)"))
        }

        /// one fixture conversation: a profile with a SOUL and one pinned skill,
        /// a disabled skill, memory and user notes, and a session workspace
        /// carrying a project-context file.
        static func fixture() throws -> (app: AppState, workspace: URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(workspaceMarker)-\(UUID().uuidString)", isDirectory: true)
            let workspace = root.appendingPathComponent(workspaceMarker, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try contextMarker.write(
                to: workspace.appendingPathComponent("AGENTS.md"),
                atomically: true, encoding: .utf8)

            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [preset]
            f.settings.activeConfig = preset.name
            f.settings.workspaces = [WorkspaceEntry(name: "a8", path: workspace.path)]
            f.settings.activeWorkspace = "a8"
            f.settings.sessionProfile[sessionID] = "a8-parity"
            f.settings.disabledSkills = ["disabled-skill"]
            f.profiles = [
                Profile(
                    name: "a8-parity",
                    title: "A8 parity",
                    description: "fixture profile",
                    soulMD: "You are A8-PARITY, the fixture profile. \(soulMarker).",
                    contextSkills: ["pinned-skill"]
                )
            ]
            f.skills = [
                skill("pinned-skill", "pinned fixture skill", "# Pinned Skill\n\n\(pinnedMarker)"),
                skill("kept-skill", "kept fixture skill", "# kept"),
                skill("disabled-skill", "disabled fixture skill", "# disabled"),
            ]
            f.memory = ParityMemory(
                memoryText: "\(memoryMarker) the assistant remembers",
                userText: "\(userMarker) the user profile"
            )
            f.registryTools = [
                StubTool(name: "skill_view", toolset: "skills",
                         description: "Load a skill's full content."),
                StubTool(name: "echo", toolset: "test", description: "Echo one value."),
            ]
            var session = Session(id: sessionID, title: "A8 parity")
            session.messages = [
                Message(role: .user, content: "earlier question", createdAt: Date()),
                Message(role: .assistant, content: "earlier answer", createdAt: Date()),
            ]
            f.sessions = [session]
            f.activeSessionID = sessionID
            f.activeTabID = "logs"
            return (AppState(renderFixture: f), workspace)
        }

        /// the messages one chat turn actually sends, through the production
        /// factory (presenters included).
        static func modelFacingMessages() async throws -> (messages: [Message], workspace: URL) {
            let (app, workspace) = try fixture()
            let client = PromptRecordingClient()
            await app.bindRecordingClient(client)
            let minted = await app.makeTurnAgent(
                preset: preset,
                profileContext: nil,
                thinking: "off",
                headless: true,
                sessionID: sessionID,
                initialHistory: nil,
                pusher: { _ in }
            )
            try await minted.agent.prime()
            for try await _ in minted.agent.streamTurn(message: "hello") {}
            await minted.agent.shutdownHTTPClient()
            let captured = client.captured
            return (try #require(captured.first, "the turn must send a request"), workspace)
        }

        @Test("every UI prompt section still reaches the model")
        func sectionsSurvive() async throws {
            let (messages, workspace) = try await Self.modelFacingMessages()
            let system = try #require(messages.first?.content, "the first message is the system prompt")

            // identity + rules: the core's own wording, same job.
            #expect(system.contains("You are ARC Agent"), "identity preamble")
            #expect(system.contains("## Rules"), "rules block")

            // tools index (the UI builder never had one).
            #expect(system.contains("`skill_view`"), "tool index names the loader")

            // skills: same framing and the same filtered index as the builder.
            #expect(system.contains("## Skills (mandatory)"), "skills framing")
            #expect(system.contains(SkillsPrompt.mandatoryFraming), "skills guidance")
            #expect(system.contains("- `kept-skill`"), "allowed skill is indexed")
            #expect(system.contains("- `pinned-skill`"), "pinned skill is indexed")
            #expect(!system.contains("- `disabled-skill`"), "disabled skill is filtered out")

            // memory + user notes: reframed and fenced, content intact.
            #expect(system.contains(Self.memoryMarker), "memory text")
            #expect(system.contains("## Memory"), "memory section")
            #expect(system.contains(Self.userMarker), "user profile text")
            #expect(system.contains("## User Profile"), "user profile section")

            // the retired "Active configuration" line: model and provider now
            // ride the session line, so the information is not lost.
            #expect(system.contains("Model: a8-parity-model | Provider: custom"),
                    "model and provider still reach the model")
            #expect(!system.contains("Active configuration"), "the retired line stays retired")

            // the ported working-directory section: the tools' real root.
            #expect(
                system.contains("Working directory for tools (relative paths resolve here): \(workspace.path)"),
                "the environment section names the session workspace, not the process cwd"
            )

            // project context came along through `contextDirectory`.
            #expect(system.contains(Self.contextMarker), "workspace project context")
        }

        @Test("the profile SOUL and its pinned skills reach the model as a system message")
        func profileBlocksAreInjected() async throws {
            let (messages, _) = try await Self.modelFacingMessages()
            let injected = messages.filter { $0.role == .system }
            #expect(injected.count >= 2,
                    "the tiered prompt plus the injected profile block are separate system messages")

            let block = try #require(
                injected.first(where: { $0.content?.contains(Self.soulMarker) == true }),
                "the SOUL block must be injected")
            #expect(block.content?.contains(Self.pinnedMarker) == true,
                    "the pinned skill's full body rides the same injected message")
            #expect(block.content?.contains("## Pinned Profile Skills") == true,
                    "pinned skills keep their section")
            #expect(messages.first(where: { $0.role == .user })?.content == "hello",
                    "the profile blocks never become the user turn")
        }

        @Test("the retired UI builder is gone; the core builder is the only one")
        func onlyOneBuilder() {
            let ui = Self.sources(in: "Sources/ArcWebUI")
            #expect(!ui.contains("func buildSystemPrompt"),
                    "no UI source may build a system prompt")
            let core = Self.sources(in: "Sources/ArcAgentCore")
            #expect(core.contains("func buildSystemPrompt"),
                    "the core's tiered builder is the surviving one")
        }

        /// every `.swift` file under one source root, concatenated — the check
        /// is existence, not a byte contract.
        static func sources(in directory: String) -> String {
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return ""
            }
            var out = ""
            for case let url as URL in walker where url.pathExtension == "swift" {
                out += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            return out
        }
    }
}

/// the scripted provider seam is an actor-isolated var; a parity run binds it
/// the same way the golden suite does.
private extension AppState {
    func bindRecordingClient(_ client: any LLMClient) {
        self.turnClientOverride = client
    }
}