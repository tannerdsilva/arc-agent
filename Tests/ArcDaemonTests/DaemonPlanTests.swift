import Foundation
import Testing

import ArcAgentCore
import ArcDaemon

/// The daemon composition matrix: a pure resolve step, no sockets bound.
@Suite("Daemon plan")
struct DaemonPlanTests {

    /// A gateway config loaded from a temp directory's `gateway.json` (or from
    /// nowhere when `json` is nil), with an explicit environment so ambient
    /// variables can never leak into an assertion.
    private func loadGateway(
        json: String? = nil,
        env: [String: String] = [:]
    ) throws -> GatewayConfig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-daemon-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if let json {
            try json.write(
                to: dir.appendingPathComponent("gateway.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return GatewayConfig.load(home: dir, environment: env)
    }

    @Test("the REST api surface is on by default, loopback:8080")
    func apiDefaults() throws {
        let plan = DaemonPlan.resolve(gateway: try loadGateway(), overrides: .init())
        #expect(plan.api == DaemonPlan.Surface(host: "127.0.0.1", port: 8080))
    }

    @Test("api.enabled: false removes the surface entirely")
    func apiDisabledRemovesSurface() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(json: #"{"api": {"enabled": false}}"#),
            overrides: .init()
        )
        #expect(plan.api == nil)
    }

    @Test("host and port come from gateway.json")
    func apiFromFile() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(json: #"{"api": {"host": "0.0.0.0", "port": 9999}}"#),
            overrides: .init()
        )
        #expect(plan.api == DaemonPlan.Surface(host: "0.0.0.0", port: 9999))
    }

    @Test("command-line overrides beat the file")
    func overridesBeatFile() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(json: #"{"api": {"host": "0.0.0.0", "port": 9999}}"#),
            overrides: .init(host: "10.0.0.5", port: 1234)
        )
        #expect(plan.api == DaemonPlan.Surface(host: "10.0.0.5", port: 1234))
    }

    @Test("the environment beats the file")
    func envBeatsFile() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(
                json: #"{"api": {"enabled": true, "port": 9999}}"#,
                env: ["API_PORT": "4321"]
            ),
            overrides: .init()
        )
        #expect(plan.api == DaemonPlan.Surface(host: "127.0.0.1", port: 4321))
    }

    @Test("API_ENABLED=false disables the surface from the environment")
    func envDisables() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(env: ["API_ENABLED": "false"]),
            overrides: .init()
        )
        #expect(plan.api == nil)
    }

    @Test("a command-line telegram token fills a config that carries none")
    func tokenFill() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(),
            overrides: .init(telegramToken: "tok-1")
        )
        let filled = plan.gatewayWithFilledToken(try loadGateway())
        #expect(filled.telegram.botToken == "tok-1")
        #expect(filled.telegram.enabled)
    }

    @Test("a file token is never overwritten by the flag")
    func tokenNeverOverridden() throws {
        let file = try loadGateway(json: #"{"telegram": {"bot_token": "file-tok"}}"#)
        let plan = DaemonPlan.resolve(gateway: file, overrides: .init(telegramToken: "cli-tok"))
        let filled = plan.gatewayWithFilledToken(file)
        #expect(filled.telegram.botToken == "file-tok")
    }

    @Test("the web UI surface is on by default (loopback:8890)")
    func webuiDefaultsOn() throws {
        let plan = DaemonPlan.resolve(gateway: try loadGateway(), overrides: .init())
        #expect(plan.webui == DaemonPlan.Surface(host: "127.0.0.1", port: 8890))
    }

    @Test("webui.enabled: true with host and port from the file")
    func webuiFromFile() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(json: #"{"webui": {"enabled": true, "host": "0.0.0.0", "port": 9998}}"#),
            overrides: .init()
        )
        #expect(plan.webui == DaemonPlan.Surface(host: "0.0.0.0", port: 9998))
    }

    @Test("--webui / --no-webui beat the file")
    func webuiOverrides() throws {
        let on = DaemonPlan.resolve(gateway: try loadGateway(), overrides: .init(webuiEnabled: true))
        #expect(on.webui == DaemonPlan.Surface(host: "127.0.0.1", port: 8890))

        let off = DaemonPlan.resolve(
            gateway: try loadGateway(json: #"{"webui": {"enabled": true}}"#),
            overrides: .init(webuiEnabled: false)
        )
        #expect(off.webui == nil)
    }

    @Test("tessera-off propagates into the plan")
    func tesseraOffPropagates() throws {
        let plan = DaemonPlan.resolve(gateway: try loadGateway(), overrides: .init(tesseraOff: true))
        #expect(plan.tesseraOff)
    }

    @Test("the MCP server and kanban dispatcher are off by default")
    func newGatesDefaultOff() throws {
        let plan = DaemonPlan.resolve(gateway: try loadGateway(), overrides: .init())
        #expect(plan.mcpServer == nil)
        #expect(plan.kanban == nil)
    }

    @Test("mcp_server {enabled, host, port} comes from the file")
    func mcpServerFromFile() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(json: #"{"mcp_server": {"enabled": true, "host": "0.0.0.0", "port": 9091}}"#),
            overrides: .init()
        )
        #expect(plan.mcpServer == DaemonPlan.Surface(host: "0.0.0.0", port: 9091))
    }

    @Test("the kanban gate carries its poll interval from the environment")
    func kanbanFromEnv() throws {
        let plan = DaemonPlan.resolve(
            gateway: try loadGateway(env: [
                "KANBAN_DISPATCHER_ENABLED": "true",
                "KANBAN_POLL_SECONDS": "1",
            ]),
            overrides: .init()
        )
        #expect(plan.kanban == DaemonPlan.KanbanLoop(pollSeconds: 1))
    }
}