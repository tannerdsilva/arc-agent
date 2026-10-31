import Testing
import Foundation
@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// One approval policy (settings backbone, slice 1).
    ///
    /// `security.approvalMode` (`manual` | `smart` | `off`) is the only
    /// approval setting. `ARC_YOLO` is its environment spelling, and a
    /// variable that *names* a mode (`ARC_APPROVAL_MODE`) wins over the
    /// boolean. The daemon's session config carries the resolved mode instead
    /// of hardcoding `.manual`.
    @Suite("Approval mode policy", .serialized)
    struct ApprovalModePolicyTests {

        /// A scratch `config.json` holding exactly `json`.
        private func scratchConfig(_ json: String) throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-approval-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            try Data(json.utf8).write(to: url)
            return url
        }

        /// Resolve `json` + `environment` exactly as a process does.
        private func resolved(
            _ json: String,
            environment: [String: String] = [:]
        ) async throws -> (mode: ApprovalMode, declared: String, resolved: String) {
            let url = try scratchConfig(json)
            let store = ConfigurationStore(url: url, environment: environment)
            let snapshot = await store.snapshot()
            return (
                ApprovalMode(configValue: snapshot.resolved.security.approvalMode),
                snapshot.declared.security.approvalMode,
                snapshot.resolved.security.approvalMode
            )
        }

        // MARK: - The declared policy

        @Test("each declared mode decodes and resolves to itself")
        func declaredModesRoundTrip() async throws {
            for (raw, expected) in [("manual", ApprovalMode.manual),
                                    ("smart", .smart),
                                    ("off", .off)] {
                let result = try await resolved("{\"security\":{\"approvalMode\":\"\(raw)\"}}")
                #expect(result.declared == raw)
                #expect(result.resolved == raw)
                #expect(result.mode == expected)
            }
        }

        @Test("an unknown mode falls back to manual, never to off")
        func unknownModeFailsSafe() async throws {
            let result = try await resolved("{\"security\":{\"approvalMode\":\"bogus\"}}")
            #expect(result.mode == .manual,
                    "an unrecognised mode must never silently disable approvals")
        }

        @Test("the deleted yoloMode key still decodes but changes nothing")
        func deletedYoloModeIsInert() async throws {
            // §8.4: deleting a key is a breaking change for hand-edited
            // configs, so an old file must still decode — it just has no
            // effect: `yoloMode` was written by ARC_YOLO and read by nobody.
            let result = try await resolved("{\"security\":{\"yoloMode\":true}}")
            #expect(result.declared == "manual")
            #expect(result.mode == .manual)
        }

        // MARK: - The environment spelling

        @Test("ARC_YOLO alone turns approvals off")
        func arcYoloMeansOff() async throws {
            let result = try await resolved("{}", environment: ["ARC_YOLO": "1"])
            #expect(result.resolved == "off")
            #expect(result.mode == .off)
            // an environment value is resolution, never a write: the file
            // still says what it said.
            #expect(result.declared == "manual")
        }

        @Test("ARC_YOLO is presence, not truthiness")
        func arcYoloIsPresence() async throws {
            // the old code tested `environment["ARC_YOLO"] != nil`, and
            // shells happily export `ARC_YOLO=0`; keeping presence semantics
            // means the mapping does not start guessing at values.
            let off = try await resolved("{}", environment: ["ARC_YOLO": "0"])
            #expect(off.mode == .off)
            let empty = try await resolved("{}", environment: ["ARC_YOLO": ""])
            #expect(empty.mode == .off)
        }

        @Test("a variable that names a mode beats the ARC_YOLO boolean")
        func namedModeBeatsYolo() async throws {
            // Precedence (decided here, enforced in `applyEnvironmentOverrides`):
            // a variable that NAMES a mode is a more specific instruction than
            // the legacy boolean, so ARC_APPROVAL_MODE wins when both are set.
            let manual = try await resolved(
                "{}", environment: ["ARC_YOLO": "1", "ARC_APPROVAL_MODE": "manual"])
            #expect(manual.mode == .manual)

            let smart = try await resolved(
                "{}", environment: ["ARC_YOLO": "1", "ARC_APPROVAL_MODE": "smart"])
            #expect(smart.mode == .smart)

            // and the named variable alone still works with no ARC_YOLO.
            let off = try await resolved("{}", environment: ["ARC_APPROVAL_MODE": "off"])
            #expect(off.mode == .off)
        }

        @Test("ARC_YOLO overrides a file that says manual or smart")
        func arcYoloOverridesTheFile() async throws {
            let fromManual = try await resolved(
                "{\"security\":{\"approvalMode\":\"manual\"}}", environment: ["ARC_YOLO": "1"])
            #expect(fromManual.mode == .off)
            let fromSmart = try await resolved(
                "{\"security\":{\"approvalMode\":\"smart\"}}", environment: ["ARC_YOLO": "1"])
            #expect(fromSmart.mode == .off)
        }

        // MARK: - The daemon

        @Test("SessionRegistry.AgentConfig carries the approval mode")
        func agentConfigCarriesTheMode() {
            let config = SessionRegistry.AgentConfig(
                model: "m", provider: "p", baseURL: "http://127.0.0.1:9/v1", apiKey: "k",
                approvalMode: .off
            )
            #expect(config.approvalMode == .off)
            #expect(SessionRegistry.AgentConfig(
                model: "m", provider: "p", baseURL: "http://127.0.0.1:9/v1", apiKey: "k"
            ).approvalMode == .manual)
        }

        @Test("SessionAgent builds its agent from the configured mode, not a hardcoded one")
        func sessionAgentReadsTheMode() throws {
            // source shape: `SessionRegistry` holds the policy, `ArcAgent` is
            // built from it. The hardcoded `.manual` is the bug this slice
            // removes, and it is not reachable as a pure unit (the build path
            // needs a store, an HTTP client and a registry).
            let source = (try? String(contentsOfFile: "Sources/ArcAgentCore/Daemon/SessionAgent.swift",
                                      encoding: .utf8)) ?? ""
            #expect(!source.isEmpty, "SessionAgent.swift must be readable from the package root")
            #expect(!source.contains("approvalMode: .manual"),
                    "SessionAgent must not hardcode the approval mode")
            #expect(source.contains("approvalMode: agentConfig.approvalMode"),
                    "SessionAgent must read the mode from its AgentConfig")
        }

        @Test("the daemon hands the resolved mode to its session config")
        func daemonPassesTheMode() throws {
            // source shape: the composition root is the one place that knows
            // the process's config, so it is where the mode enters the tree.
            let source = (try? String(contentsOfFile: "Sources/ArcDaemon/ArcDaemon.swift",
                                      encoding: .utf8)) ?? ""
            #expect(!source.isEmpty, "ArcDaemon.swift must be readable from the package root")
            #expect(source.contains("approvalMode: ApprovalMode(configValue: arc.security.approvalMode)"),
                    "ArcDaemon must pass the resolved security.approvalMode")
        }
    }
}
