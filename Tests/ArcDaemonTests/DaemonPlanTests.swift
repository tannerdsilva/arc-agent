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
}