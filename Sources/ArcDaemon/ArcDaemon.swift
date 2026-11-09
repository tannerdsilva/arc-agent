import ArcAgentCore
import ArcWebUI
import Foundation
import Logging
import ServiceLifecycle

/// The single composition root: one `ServiceGroup`, surfaces assembled from a
/// ``DaemonPlan``.
///
/// `arc serve` is a thin shell over ``run(arc:config:overrides:)``; every
/// surface — web UI, REST API, platform adapters, MCP, kanban — mounts here
/// (see `.hermes/plans/2026-10-01_093852-unify-the-daemon.md`).
public enum ArcDaemon {

    /// Compose and run the daemon.
    ///
    /// Owns the root `ServiceGroup` — the only signal owner in the process:
    /// `SIGTERM`/`SIGINT` trigger graceful shutdown, escalated to cancellation
    /// after a bounded grace period so an unresponsive service can never wedge
    /// shutdown.
    public static func run(
        arc: ArcConfig,
        config: DaemonConfig,
        overrides: DaemonPlan.Overrides = DaemonPlan.Overrides()
    ) async throws {
        // Route every swift-log line into the web UI's ring buffer; the
        // daemon's own loggers (and a hosted UI's) all land there. Idempotent:
        // whichever of daemon/host runs first installs it. `--log-level`
        // overrides the handler's capture threshold (default .info).
        WebUILogging.install(level: overrides.logLevel ?? .info)

        let plan = DaemonPlan.resolve(config: config, overrides: overrides)
        let daemonConfig = plan.configWithFilledToken(config)
        let logger = Logger(label: "arc-agent.daemon")

        // ONE gate install: the daemon's agents consult the same lockdown
        // config the CLI writes. `ArcAgent` only re-asserts a *non-default*
        // powers config, so this boot install (and the web UI's live toggle)
        // stay authoritative for the whole process.
        AgentPowers.configure(arc.agentPowers)

        // ONE roster writer for the process (GROUNDZERO slice 3). Every
        // `ProfileManager()` shim, the session agents, and the web UI resolve
        // to this service's store, so there is one cache and one serialized
        // read-modify-write of `index.json` instead of one per call site.
        let profileService = ProfileService()

        // Data continuity (GROUNDZERO slice 5, D15). Memory lives per profile
        // now, so an install that predates that still carries its memory in
        // `~/.arc/memories/`. Relocate it once, before any service reads a
        // profile document. Idempotent: a no-op from the second run on, and a
        // profile created later deliberately inherits nothing.
        await MemoryMigration.runIfNeeded(profiles: profileService)

        // Plan B: scoped process watcher. Configured always (so the
        // `process_watch` tool sees the rules even when disabled); the
        // service joins the tree only when enabled. Owned background
        // sessions are excluded from observation — they emit their own
        // `process:*` lifecycle events (plan A).
        await ProcessWatchService.shared.configure(arc.processWatch)
        let ownedPIDs = Set(await ProcessRegistry.shared.summaries().compactMap { summary in
            summary.status == "running" ? summary.pid : nil
        })
        await ProcessWatchService.shared.setAgentPIDs(ownedPIDs)

        // ONE storage decision for the whole process: the session host's
        // agents and the web UI share this exact pair (no second env on the
        // same store directories).
        //
        // The medium is policy — `storage.active` in config.json, resolved by
        // the one resolver the CLI and the web UI also use. Before settings
        // backbone slice 4 the daemon read the web UI's
        // `~/.arc-agent-webui/settings.json` instead, so the picker and the
        // daemon could disagree and a user who chose files kept getting
        // Tessera sessions from Telegram.
        //
        // `--tessera-off` is a per-process override of the resolved medium: it
        // forces files here and never rewrites `storage.active`.
        let selection = plan.tesseraOff ? StoreSelection.file : StoreSelection.resolve(arc)
        let storage = await StorageRuntime.resolve(
            tessera: selection.tessera,
            tesseraOff: selection.backend == .file
        )

        // ONE kanban board for the whole process (GROUNDZERO2 slice 1, D22).
        // The board is real and the daemon has always dispatched against one;
        // what was missing is the *join* — every agent surface builds its
        // registry through `MutableToolRegistry.make`, which had no `kanban:`
        // parameter, so the five `kanban_*` tools read an empty slot and
        // answered "board not available". One instance, handed to the sessions,
        // the MCP surface, the web UI's tool surface and the dispatcher below:
        // a `FileKanbanBoard` lists from its in-memory cache, so a second
        // instance over `~/.arc/kanban` would not see the first one's tasks.
        let kanbanBoard = FileKanbanBoard()

        // The tool/skill surface is policy: one `tools` block in config.json,
        // read by the daemon exactly as the CLI and the web UI read it. Before
        // settings-backbone slice 3 every hosted session ran with every toolset
        // enabled and no skills at all, whatever the file said.
        let toolSurface = arc.tools

        let agentConfig = SessionRegistry.AgentConfig(
            model: arc.model.defaultModel,
            provider: arc.model.provider,
            baseURL: arc.model.baseURL ?? "https://api.openai.com/v1",
            apiKey: ProcessInfo.processInfo.environment["ARC_API_KEY"] ?? "",
            tessera: arc.tessera,
            persistSessions: arc.agent.persistSessions,
            // MoA is policy, not a UI preference: every hosted session agent
            // gets the block the process config declares. Before slice 2 of
            // the settings backbone nothing passed it, so daemon sessions ran
            // with the compiled default (disabled, no reference models)
            // whatever config.json said.
            moa: arc.moa,
            // Tool and skill enablement, from the same `tools` block the other
            // surfaces read.
            disabledToolsets: toolSurface.disabledToolsetSet,
            skills: toolSurface.allowedSkills(from: discoverSkills()),
            maxIterations: arc.effectiveMaxTurns(),
            toolLoopCap: arc.toolCallLimit(),
            maxTurnDuration: arc.effectiveMaxTurnDuration() ?? 0,
            // The process's approval policy, resolved through config + env
            // (`ARC_YOLO` → off). Every hosted session agent gets this mode.
            approvalMode: ApprovalMode(configValue: arc.security.approvalMode),
            // Cron approval policy (`security.cronMode`): deny | smart,
            // unknown → deny with a warning (fail-closed, never a guess).
            cronMode: {
                switch arc.security.cronMode?.lowercased() {
                case "smart": return .smart
                case "deny", nil: return .deny
                case let other?:
                    print("⚠️ Unknown security.cronMode '\(other)' — using deny")
                    return .deny
                }
            }(),
            mcpServers: arc.mcpServers,
            contextDefaults: WebUIContextDefaults.loadFromDisk() ?? arc.contextDefaults,
            storage: storage,
            profiles: profileService,
            kanban: kanbanBoard
        )

        // ── surfaces ────────────────────────────────────────────────
        // Sidecar plugins: every valid install under ~/.arc/plugins/
        // spawns its own process and shows up as ordinary sidebar tabs.
        // Discovery happens before the host boots so the tab registry is
        // complete at
        // startup; the host state is attached afterwards for the
        // plugin→host channel (workspace path, toasts, navigation).
        let sidecarManager = SidecarPluginManager()
        // The session host hosts sessions and their feeding surfaces: the
        // REST API (when enabled) plus every configured platform adapter. It
        // composes whenever it has anything to serve — adapters are not
        // gated behind the API surface.
        var sessionHost: SessionHost?
        if plan.api != nil || daemonConfig.anyPlatformAdapterReady {
            sessionHost = SessionHost(
                api: plan.api.map { SessionHost.API(host: $0.host, port: $0.port) },
                telegramToken: plan.telegramToken,
                config: daemonConfig,
                agentConfig: agentConfig
            )
        }
        var uiHost: WebUIHost?
        if let webui = plan.webui {
            let sidecarPlugins = await sidecarManager.discover()
            uiHost = try await WebUIHost(
                host: webui.host,
                port: webui.port,
                tesseraOff: plan.tesseraOff,
                storage: storage,
                thirdPartyPlugins: sidecarPlugins,
                sidecarManager: sidecarManager,
                // The session host (built just above) owns the process's
                // platform adapters; the UI's `send_message` gets that path as
                // a per-surface slot (GROUNDZERO slice 6).
                delivery: sessionHost?.delivery,
                // Same board the sessions and the dispatcher use (GROUNDZERO2
                // slice 1): the UI's turn loop dispatches tools straight
                // through its own registry, so without this its `kanban_*`
                // tools would answer "board not available" in the one process
                // that has a board.
                kanban: kanbanBoard
            )
        }

        // ── tool plugins ──────────────────────────────────────────
        // Executable plugin tools under ~/.arc/plugins/<name>/ are loaded
        // per-session by MutableToolRegistry.make() (SessionAgent). Warm
        // discovery here so malformed installs and tool-set surprises show
        // up in the daemon log at boot (never blocking) instead of on the
        // first session.
        let pluginRegistry = PluginRegistry.shared
        do {
            try await pluginRegistry.loadAll()
        } catch {
            logger.warning("tool plugin discovery failed: \(error)")
        }
        let pluginManifests = await pluginRegistry.plugins()
        let pluginTools = await pluginRegistry.tools()
        let pluginIssues = await pluginRegistry.discoveryIssues()
        if !pluginManifests.isEmpty {
            logger.info("tool plugins: \(pluginManifests.count) plugin(s), \(pluginTools.count) tool(s) [\(pluginManifests.keys.sorted().joined(separator: ", "))]")
        } else if !pluginIssues.isEmpty {
            logger.warning("tool plugin discovery found \(pluginIssues.count) issue(s): \(pluginIssues.joined(separator: "; "))")
        }

        // ── cron: ONE engine, ONE store ─────────────────────────────
        // The daemon owns the scheduler; job execution prefers the web UI's
        // approval-aware headless runner and falls back to the session
        // host's session-agent runner (the pre-daemon behavior) when the UI
        // is off.
        let cronStore = RuntimeCronStore()
        await ScheduledJobsImport.runIfNeeded(into: cronStore)
        let cronTimeZone = daemonConfig.cron.timeZone.flatMap { TimeZone(identifier: $0) } ?? .current
        let cronHistory = RuntimeCronRunHistory()
        let jobRunner: @Sendable (CronJob) async throws -> CronRunResult
        // Script jobs (§6.2) bypass every agent surface — the shell line
        // is the whole job. Checked before the runner selection so the
        // web-UI path never spins a session for a script job.
        let selectedRunner: @Sendable (CronJob) async throws -> CronRunResult
        if let uiHost {
            selectedRunner = { job in CronRunResult(output: await uiHost.runScheduledJob(job)) }
        } else if let sessionHost {
            selectedRunner = sessionHost.cronRunner
        } else {
            selectedRunner = { _ in CronRunResult(output: "No runner: neither the web UI nor the session host is enabled.") }
        }
        jobRunner = { job in
            if let script = job.script, !script.isEmpty {
                let outcome = await CronScriptRunner.run(script: script)
                return CronRunResult(
                    output: outcome.failed ? (outcome.output ?? "script failed") : (outcome.output ?? ""),
                    deliveryError: nil
                )
            }
            // context_from chaining (§8): inject upstreams' latest ok
            // records into the firing prompt BEFORE the runner sees the
            // job. Script jobs don't chain (the shell line is the job).
            var runJob = job
            if let refs = job.contextFrom, !refs.isEmpty, (job.script ?? "").isEmpty {
                runJob.prompt = await CronChaining.injectedPrompt(
                    base: job.prompt,
                    contextFrom: refs,
                    resolve: CronChaining.makeResolver(store: cronStore, history: cronHistory)
                )
            }
            return try await selectedRunner(runJob)
        }
        // One daemon-wide wall-clock zone: jobs are statements about this
        // machine, so a job's hour means the hour *here* (`cron.time_zone`,
        // IANA name; absent = local). Per-job zones were considered and
        // rejected — they'd make two jobs' "9am" disagree silently.
        let cronScheduler = CronScheduler(store: cronStore, timeZone: cronTimeZone, history: cronHistory, jobRunner: jobRunner)
        if let sessionHost {
            await sessionHost.provideCron(store: cronStore, history: cronHistory)
        }

        printBanner(plan: plan, config: daemonConfig)

        var services: [any Service] = []
        if let sessionHost { services.append(sessionHost) }
        if let uiHost { services.append(uiHost) }
        // A surface can also arrive below as a service in its own right — the MCP
        // server and the kanban dispatcher are not HTTP/UI hosts. The guard must
        // account for every surface, or a daemon configured with only one of them
        // exits at boot ("nothing to run") while a configured surface is live.
        guard sessionHost != nil || uiHost != nil || plan.mcpServer != nil || plan.kanban != nil else {
            logger.warning("no daemon surfaces enabled (see daemon.json) — nothing to run")
            return
        }

        // Reference event: `daemon:startup` (fires once per process start; the
        // platform list = the surfaces that were composed). The outbound
        // config and file-hook loading are installed by the CLI entry before
        // the daemon runs; this emit closes the loop.
        var startedPlatforms: [String] = []
        if plan.api != nil { startedPlatforms.append("http") }
        if daemonConfig.telegramAdapterReady { startedPlatforms.append("telegram") }
        if daemonConfig.emailAdapterReady { startedPlatforms.append("email") }
        if daemonConfig.slackAdapterReady { startedPlatforms.append("slack") }
        if plan.webui != nil { startedPlatforms.append("webui") }
        await HookBus.shared.emit("daemon:startup", ["platforms": .array(startedPlatforms)])

        // cron rides with a surface: jobs need a runner.
        services.append(cronScheduler)

        // Second Law: the roster's single writer is a service in the tree. It
        // outlives every turn and every session agent, and its `run()` is the
        // service's lifetime (teardown belongs there, not in a caller's defer).
        services.append(profileService)

        // Sidecar plugin processes ride the same lifecycle: graceful stop
        // terminates every plugin child before the host exits.
        services.append(SidecarPluginService(manager: sidecarManager))

        // MCP sessions (from `mcp_servers`) spawn lazily on first use; this
        // service owns closing them at shutdown, so every child gets a clean
        // stdin EOF instead of a signal.
        services.append(MCPClientsService())

        // Plan B: scoped process watcher (Second Law — one Service in the
        // tree; polls, diffs, emits `process:*` HookBus events).
        if arc.processWatch.enabled {
            services.append(ProcessWatchService.shared)
        }

        if let mcp = plan.mcpServer {
            // TCP only — stdio is meaningless for a daemon. Exposes every
            // BUILT-IN tool (plugin tools are not in the CompileTimeToolRegistry
            // the adapter takes); no auth, so the bind host is the boundary.
            services.append(try MCPServerAdapter(
                host: mcp.host,
                port: mcp.port,
                registry: try ArcAgentCore.buildRegistry(
                    context: ToolContext(
                        profile: .default,
                        sessionID: "",
                        workspace: FileManager.default.currentDirectoryPath,
                        grant: AgentPowers.grant(profile: .default)
                    ),
                    profiles: TesseraProfileStore.shared,
                    memory: FileMemoryProvider(directory: ProfileManager.memoryURL(for: "default")),
                    sessions: FileSessionStore(),
                    // The session host owns the process's messaging services;
                    // with no host there is no delivery path, so the two tools
                    // are simply absent from this surface.
                    messaging: sessionHost?.messaging,
                    groupChats: sessionHost?.groupChats,
                    // The process's one board: an MCP client that calls
                    // `kanban_create` works the board the sessions see.
                    kanban: kanbanBoard,
                    // `send_message` reaches the same platform adapters the
                    // sessions do; the slot is this surface's own (slice 6).
                    delivery: sessionHost?.delivery,
                    // The MCP surface shares the daemon's cron store and
                    // history, so an MCP client manages the jobs the
                    // scheduler runs. MCP is the one TCP surface — auth is
                    // the bind host, so cron scoping (Phase 6) matters here.
                    cron: cronStore,
                    cronHistory: cronHistory
                )
            ))
        }
        if let kanban = plan.kanban {
            // CAVEAT: a stub executor that fabricates completion, polling the
            // CORE board (~/.arc/kanban), not the web UI's panel. Default off;
            // see KanbanConfig.
            services.append(KanbanDispatcher(
                board: kanbanBoard,
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

        do {
            try await ServiceGroup(configuration: configuration).run()
        } catch {
            // Release the process-scoped connection before propagating.
            await TesseraConnection.shared.shutdown()
            throw error
        }
        // Release the shared Tessera connection (WireGuard tunnel) at teardown.
        // The session host releases it for its own surface, but the daemon
        // owns the process: with the API surface disabled the web UI is the only
        // storage consumer, and the tunnel would otherwise be left open (an
        // un-shutdown tessera client traps in its deinit — see `Arc.swift`'s
        // `shutdownHTTPClient()` note on the CLI path).
        await TesseraConnection.shared.shutdown()
    }

    /// Startup banner — parity with the pre-daemon `arc serve` output.
    private static func printBanner(plan: DaemonPlan, config: DaemonConfig) {
        print("⚡ ARC Agent")
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
        if config.telegramAdapterReady { print("Telegram: enabled") }
        if config.emailAdapterReady { print("Email: enabled") }
        if config.slackAdapterReady { print("Slack: enabled") }
        print("")
    }
}