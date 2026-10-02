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

        // ONE gate install: the daemon's agents consult the same lockdown
        // config the CLI writes. `ArcAgent` only re-asserts a *non-default*
        // powers config, so this boot install (and the web UI's live toggle)
        // stay authoritative for the whole process.
        AgentPowers.configure(arc.agentPowers)

        // ONE storage decision for the whole process: the gateway's session
        // agents and the web UI share this exact pair (no second env on the
        // same store directories).
        // Storage decision: the web UI's Settings → Storage picker is the
        // highest-priority selection when it has one (persisted in
        // ~/.arc-agent-webui/settings.json). Falling back to the CLI config's
        // tessera block when the picker has no selection, or when the user
        // explicitly forced file mode on the command line.
        var effectiveTessera = arc.tessera
        var effectiveOff = plan.tesseraOff
        if !plan.tesseraOff, let selection = WebUIStorageSelection.loadFromDisk() {
            let resolution = resolveStorage(
                active: selection.activeStorage,
                connections: selection.connections,
                cliTessera: arc.tessera
            )
            effectiveTessera = resolution.config
            effectiveOff = resolution.backend == "file"
        }
        let storage = await StorageRuntime.resolve(tessera: effectiveTessera, tesseraOff: effectiveOff)

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

        // ── surfaces ────────────────────────────────────────────────
        var gateway: GatewayService?
        if let api = plan.api {
            gateway = GatewayService(
                host: api.host,
                port: api.port,
                telegramToken: plan.telegramToken,
                gatewayConfig: gatewayConfig,
                agentConfig: agentConfig
            )
        }
        var uiHost: WebUIHost?
        if let webui = plan.webui {
            uiHost = try WebUIHost(
                host: webui.host,
                port: webui.port,
                tesseraOff: plan.tesseraOff,
                storage: storage
            )
        }

        // ── cron: ONE engine, ONE store ─────────────────────────────
        // The daemon owns the scheduler; job execution prefers the web UI's
        // approval-aware headless runner and falls back to the gateway's
        // session-agent runner (the pre-daemon behavior) when the UI is off.
        let cronStore = RuntimeCronStore()
        await ScheduledJobsImport.runIfNeeded(into: cronStore)
        let jobRunner: @Sendable (CronJob) async throws -> String
        if let uiHost {
            jobRunner = { job in await uiHost.runScheduledJob(job) }
        } else if let gateway {
            jobRunner = gateway.cronRunner
        } else {
            jobRunner = { _ in "No runner: neither the web UI nor the API surface is enabled." }
        }
        let cronScheduler = CronScheduler(store: cronStore, jobRunner: jobRunner)

        printBanner(plan: plan, gateway: gatewayConfig)

        var services: [any Service] = []
        if let gateway { services.append(gateway) }
        if let uiHost { services.append(uiHost) }
        guard !services.isEmpty else {
            logger.warning("no daemon surfaces enabled (see gateway.json) — nothing to run")
            return
        }

        // Reference gateway event: `gateway:startup` (fires once per process
        // start; the platform list = the surfaces that were composed). The
        // outbound config and file-hook loading are installed by the CLI
        // entry before the daemon runs; this emit closes the loop.
        var startedPlatforms = ["http"]
        if gatewayConfig.telegram.enabled { startedPlatforms.append("telegram") }
        if gatewayConfig.email.enabled { startedPlatforms.append("email") }
        if gatewayConfig.slack.enabled { startedPlatforms.append("slack") }
        if plan.webui != nil { startedPlatforms.append("webui") }
        await HookBus.shared.emit("gateway:startup", ["platforms": .array(startedPlatforms)])

        // cron rides with a surface: jobs need a runner.
        services.append(cronScheduler)

        if let mcp = plan.mcpServer {
            // TCP only — stdio is meaningless for a daemon. Exposes every
            // BUILT-IN tool (plugin tools are not in the CompileTimeToolRegistry
            // the adapter takes); no auth, so the bind host is the boundary.
            services.append(try MCPServerAdapter(
                host: mcp.host,
                port: mcp.port,
                registry: try ArcAgentCore.buildDefaultRegistry()
            ))
        }
        if let kanban = plan.kanban {
            // CAVEAT: a stub executor that fabricates completion, polling the
            // CORE board (~/.arc/kanban), not the web UI's panel. Default off;
            // see KanbanGatewayConfig.
            services.append(KanbanDispatcher(
                board: FileKanbanBoard(),
                pollIntervalSeconds: UInt64(kanban.pollSeconds)
            ))
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