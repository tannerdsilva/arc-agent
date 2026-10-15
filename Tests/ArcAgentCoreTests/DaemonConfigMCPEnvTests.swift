import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// `MCP_SERVER_*` is a documented env override for the daemon's MCP surface
    /// (`DaemonConfig.load` → `MCPServerSurfaceConfig(dict:env:)` → `DaemonPlan`).
    /// It had no coverage, and the surface would not come up from env alone.
    @Suite("Daemon MCP surface env overrides", .serialized)
    struct DaemonConfigEnvTests {

        @Test("env-only config honors MCP_SERVER_ENABLED/HOST/PORT")
        func envOnlyMCPServer() {
            let config = DaemonConfig.load(
                home: URL(fileURLWithPath: "/nonexistent-arc-home"),
                environment: [
                    "MCP_SERVER_ENABLED": "1",
                    "MCP_SERVER_HOST": "127.0.0.1",
                    "MCP_SERVER_PORT": "18081",
                ]
            )
            #expect(config.mcpServer.enabled)
            #expect(config.mcpServer.host == "127.0.0.1")
            #expect(config.mcpServer.port == 18081)
        }

        @Test("the env override is off unless it says so")
        func disabledWithoutEnv() {
            let config = DaemonConfig.load(
                home: URL(fileURLWithPath: "/nonexistent-arc-home"),
                environment: [:]
            )
            #expect(config.mcpServer.enabled == false)
        }
    }
}