import ArcAgentCore
import ArcWebUI
import Foundation
import Logging
import ServiceLifecycle

/// The single composition root: one `ServiceGroup`, surfaces assembled from a
/// ``DaemonPlan``.
///
/// `arc serve` is a thin shell over ``run(arc:gateway:overrides:)``; the web UI
/// host mounts here in phase 2 of the consolidation (see
/// `.hermes/plans/2026-10-01_093852-unify-the-daemon.md`).
public enum ArcDaemon {

    /// Compose and run the daemon.
    ///
    /// Owns the root `ServiceGroup` — the only signal owner in the process:
    /// `SIGTERM`/`SIGINT` trigger graceful shutdown, escalated to cancellation
    /// after a bounded grace period so an unresponsive service can never wedge
    /// shutdown.
    public static func run(
        arc: ArcConfig,
        gateway: GatewayConfig,
        overrides: DaemonPlan.Overrides = DaemonPlan.Overrides()
    ) async throws {
        // Route every swift-log line into the web UI's ring buffer; the
        // daemon's own loggers (and a hosted UI's) all land there. Idempotent:
        // whichever of daemon/host runs first installs it.
        WebUILogging.install()

        let plan = DaemonPlan.resolve(gateway: gateway, overrides: overrides)
        let gatewayConfig = plan.gatewayWithFilledToken(gateway)
        let logger = Logger(label: "arc-agent.gateway")

        // ONE storage decision for the whole process: the gateway's session
        // agents and the web UI share this exact pair (no second env on the
        // same store directories).
        let storage = await StorageRuntime.resolve(tessera: arc.tessera, tesseraOff: plan.tesseraOff)

        let agentConfig = SessionRegistry.AgentConfig(
            model: arc.model.defaultModel,
            provider: arc.model.provider,
            baseURL: arc.model.baseURL ?? "https://api.openai.com/v1",
            apiKey: ProcessInfo.processInfo.environment["ARC_API_KEY"] ?? "",
            tessera: arc.tessera,
            persistSessions: arc.agent.persistSessions,
            maxIterations: arc.effectiveMaxTurns(),
            toolLoopCap: arc.effectiveToolLoopCap(),
            mcpServers: arc.mcpServers,
            storage: storage
        )

        var services: [any Service] = []
        if let api = plan.api {
            services.append(GatewayService(
                host: api.host,
                port: api.port,
                telegramToken: plan.telegramToken,
                gatewayConfig: gatewayConfig,
                agentConfig: agentConfig
            ))
        }
        if let webui = plan.webui {
            services.append(try WebUIHost(
                host: webui.host,
                port: webui.port,
                tesseraOff: plan.tesseraOff,
                storage: storage
            ))
        }

        printBanner(plan: plan, gateway: gatewayConfig)

        guard !services.isEmpty else {
            logger.warning("no daemon surfaces enabled (see gateway.json) — nothing to run")
            return
        }

        var configuration = ServiceGroupConfiguration(
            services: services,
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        // Safety net: a service that ignores graceful shutdown is escalated to
        // task cancellation after this bound instead of hanging forever.
        configuration.maximumGracefulShutdownDuration = .seconds(5)

        try await ServiceGroup(configuration: configuration).run()
    }

    /// Startup banner — parity with the pre-daemon `arc serve` output.
    private static func printBanner(plan: DaemonPlan, gateway: GatewayConfig) {
        print("⚡ ARC Agent Gateway")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if let api = plan.api {
            print("HTTP server: http://\(api.host):\(api.port)")
        } else {
            print("HTTP server: disabled")
        }
        if let webui = plan.webui {
            print("Web UI:     http://\(webui.host):\(webui.port)")
        } else {
            print("Web UI:     disabled")
        }
        if gateway.telegram.enabled { print("Telegram: enabled") }
        if gateway.email.enabled { print("Email: enabled") }
        if gateway.slack.enabled { print("Slack: enabled") }
        print("")
    }
}