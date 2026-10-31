import Testing
import Foundation
@testable import ArcAgentCore

extension ArcCoreTestRoot {

    /// MoA enablement is policy (settings backbone, slice 2).
    ///
    /// `moa.enabled` in `~/.arc/config.json` is the one MoA switch. The daemon's
    /// session config must carry the block it is handed — before this slice the
    /// composition root never passed `moa` at all, so every daemon session ran
    /// with the compiled default (disabled, no reference models) whatever the
    /// file said.
    @Suite("moa daemon policy", .serialized)
    struct MoADaemonPolicyTests {

        /// The JSON the file carries when MoA is on with one reference model.
        private static let enabledJSON = """
        {"moa": {"enabled": true, "reference_models": [{"model": "m"}]}}
        """

        @Test("SessionRegistry.AgentConfig carries the config's MoA block")
        func agentConfigCarriesMoA() throws {
            let arc = try JSONDecoder().decode(ArcConfig.self, from: Data(Self.enabledJSON.utf8))
            #expect(arc.moa.enabled, "the fixture really enables MoA")

            let config = SessionRegistry.AgentConfig(
                model: "m",
                provider: "p",
                baseURL: "http://127.0.0.1:9/v1",
                apiKey: "",
                moa: arc.moa
            )
            #expect(config.moa.enabled)
            #expect(config.moa.referenceModels.map(\.model) == ["m"])

            // the default stays honest: no moa argument means a disabled block.
            let bare = SessionRegistry.AgentConfig(
                model: "m", provider: "p", baseURL: "http://127.0.0.1:9/v1", apiKey: "")
            #expect(bare.moa.enabled == false)
        }

        @Test("the daemon hands the config's MoA block to its session config")
        func daemonPassesMoA() throws {
            // source shape: the composition root is the one place that knows
            // the process's config, so it is where the block enters the tree.
            // It cannot be reached as a pure unit (the build path needs a
            // store, an HTTP client and a registry).
            let source = try String(contentsOfFile: "Sources/ArcDaemon/ArcDaemon.swift",
                                    encoding: .utf8)
            #expect(!source.isEmpty)
            #expect(source.contains("moa: arc.moa"),
                    "ArcDaemon must pass the config's moa block into SessionRegistry.AgentConfig")
        }

        @Test("SessionAgent builds its agent from the configured MoA block")
        func sessionAgentReadsMoA() throws {
            let source = try String(contentsOfFile: "Sources/ArcAgentCore/Daemon/SessionAgent.swift",
                                    encoding: .utf8)
            #expect(!source.isEmpty)
            #expect(source.contains("moa: agentConfig.moa"),
                    "SessionAgent must hand its AgentConfig's block to the agent")
        }
    }
}
