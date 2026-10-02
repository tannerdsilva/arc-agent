import ArcAgentCore
import Foundation
import Logging
import ServiceLifecycle
import WebUI
import WebUIServer

/// Drops fragment updates whose HTML repeats the last push for the same id.
///
/// Streaming turns re-emit chrome that did not change between token pushes (the
/// composer flyout, the session-row spinner), and the client would tear down and
/// rebuild identical nodes for nothing. Empty html means "remove the node" and
/// always passes: a skipped removal could strand a node an intervening parent
/// push re-created.
actor PushDeduper {
    private var last: [String: String] = [:]

    func filter(_ updates: [FragmentUpdate]) -> [FragmentUpdate] {
        updates.filter { update in
            if update.html.isEmpty { return true }
            if last[update.id] == update.html { return false }
            last[update.id] = update.html
            return true
        }
    }
}

/// The Web UI host: boots the app state, serves the page through no-webui's
/// `WebUIServer`, and streams logs + the workspace tree while it runs.
///
/// The daemon (`ArcDaemon`) mounts this as a service with prebuilt storage and
/// the log sink already installed, and reaches back through
/// `runScheduledJob(_:)` for cron. Constructed bare (the retired standalone
/// shim's shape, still exercised by tests) the host resolves its own storage
/// under the original 12 s timebox.
public struct WebUIHost: Service {

    public let host: String
    public let port: Int
    public let tesseraOff: Bool
    /// Storage prebuilt by the daemon; nil = resolve our own (standalone).
    public let storage: StorageRuntime?

    /// The UI's state actor. Created eagerly so the daemon can reach it (the
    /// cron runner) without racing the boot.
    let app: AppState

    public init(
        host: String = "127.0.0.1",
        port: Int = 8890,
        tesseraOff: Bool = false,
        storage: StorageRuntime? = nil
    ) throws {
        self.host = host
        self.port = port
        self.tesseraOff = tesseraOff
        self.storage = storage
        self.app = try AppState()
    }

    /// Run one scheduled job headless and return its output — the daemon's
    /// cron runner (`AppState` owns the model config, the sessions and the
    /// approval-aware headless tool path).
    public func runScheduledJob(_ job: CronJob) async -> String {
        await app.runScheduledJob(job)
    }

    public func run() async throws {
        // Route every swift-log line into the in-app ring buffer instead of
        // stdout, so the Logs panel is the operator view. Idempotent: the
        // daemon usually installed it first; this is a no-op then.
        WebUILogging.install()
        let logger = Logger(label: "arc-agent.webui")
        logger.info("starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        let app = self.app
        if let storage {
            // the daemon prebuilt the process storage and already probed it:
            // attach it (one store pair for the whole process) and boot plain —
            // there is nothing left to time out.
            await app.attachRuntime(storage)
            await app.boot()
            await app.crumb("host: boot on attached storage (backend=\(storage.backend))")
        } else {
            if tesseraOff {
                await app.overrideTesseraOff(true)
            }

            // Timeboxed boot: a Tessera tunnel that never handshakes must not
            // wedge the whole UI — fall back to file storage after 12s.
            // Implemented as an AsyncStream race: a TaskGroup's next() never
            // delivers a timer child's throw while the boot child is suspended
            // forever (Swift 6.3 behavior, observed live), which turns the
            // timeout into a deadlock.
            struct BootTimeout: Error {}
            let stream = AsyncStream<Result<Void, Error>>.makeStream()
            let c = stream.continuation
            // Hold the boot task handle so a timed-out first boot can be CANCELLED
            // before the fallback runs — otherwise it finishes last (~45-70s) and
            // overwrites the store state the fallback just built, blanking the
            // sidebar, and leaks the tunnel it spawned.
            let bootTask = Task {
                do {
                    await app.boot()
                    c.yield(.success(())); c.finish()
                } catch {
                    c.yield(.failure(error)); c.finish()
                }
            }
            Task {
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch {}
                c.yield(.failure(BootTimeout())); c.finish()
            }
            switch await stream.stream.first(where: { _ in true }) {
            case .success:
                await app.crumb("entry: boot race completed cleanly")
            case .failure:
                await app.crumb("entry: boot timeout — fallback to file")
                logger.warning("boot timed out (Tessera unreachable?) — using file storage")
                bootTask.cancel()
                await app.forceTesseraOff()
                await app.boot()
                await app.crumb("entry: fallback boot done")
            case nil:
                await app.crumb("entry: boot race stream ended empty")
            }
        }
        await app.crumb("entry: boot block done")
        logger.info("boot complete")
        let storageDesc = await app.storageDescription()
        logger.info("storage=\(storageDesc)")
        let boot = (
            sessions: await app.sessionCount(),
            skills: await app.skillCount(),
            profiles: await app.profileCount(),
            tools: await app.toolCount()
        )
        logger.info("sessions=\(boot.sessions) skills=\(boot.skills) profiles=\(boot.profiles) tools=\(boot.tools)")

        // Pick a chat to open: the active one if set, else the newest, else a
        // fresh starter chat on a completely empty store.
        if let active = await app.activeSessionIDValue() {
            await app.reloadSessions(selecting: active)
        } else if let newest = await app.newestSessionID() {
            await app.setActiveSession(newest)
        } else {
            await app.ensureRuntime()
            if let store = await app.storeRef() {
                let s = Session()
                try? await store.create(s)
                await app.reloadSessions(selecting: s.id)
            }
        }

        // Wire the router (hand-written fixed component ids). The controller is
        // created further down, once the server that carries its pushes exists.
        let router = EventRouter()

        // The shipped assets — address, bytes and registration all live in
        // `AppShell.Assets`; this host only serves them.
        let sheet = AppShell.Assets.sheet
        let overlay = AppShell.Assets.overlay

        // Assemble the page (external /ui/* assets keep each response small).
        // The document template wraps whatever body the app currently renders,
        // so a refresh ALWAYS reflects live store state (a boot-cached page
        // would show sessions deleted after startup).
        // The theme attributes belong on `<html>`, not on `#app`: the engine writes them on
        // `documentElement` and the theme is scoped to `:root`. `themeAttrs` is the server's
        // default, which the engine overrides from storage before first paint.
        let makeDocument = AppShell.makeDocument(sheetURL: sheet.url, overlayURL: overlay.url)
        let pageProvider: @Sendable (String?) async -> String = { [app] deepLink in
            if let sid = deepLink, !sid.isEmpty {
                await app.openDeepLink(sid)
            }
            await app.armScrollToBottom()
            let shell = await app.appShell()
            return makeDocument(shell, AppShell.themeAttrs(await app.themeDefaults())).render()
        }

        let server = WebUIServer(
            requestRender: { request in
                // ?s=<id> opens that conversation directly (copy-link flow).
                await pageProvider(request.value("s"))
            },
            router: router,
            config: WebUIServerConfig(
                host: host,
                port: port,
                pagePath: "/",
                // Registered at the bare path — the server strips a request's query before
                // the asset lookup, so a stamped url resolves to the same bytes. The `?v=`
                // is the *client's* cache key: a rebuilt asset is a new url and cannot be
                // served from a year-long cache under the old one.
                assets: [
                    sheet.registration,
                    overlay.registration,
                ]
            ),
            logger: logger
        )

        let deduper = PushDeduper()
        let controller = Controller(app: app, push: { updates in
            await server.broadcast(await deduper.filter(updates))
        })
        controller.wireAll(router)

        // the boot page is rendered here, once the stamped asset urls exist, purely
        // so the log line reports a real byte count.
        let bootPageBytes = makeDocument(
            await app.appShell(),
            AppShell.themeAttrs(await app.themeDefaults())
        ).render().utf8.count
        logger.info("serving http://\(host):\(port) (page \(bootPageBytes) bytes)")
        // no cron engine here: the daemon owns the one scheduler and calls
        // back into this host's `runScheduledJob` for job execution.

        // Live log stream: drain the ring buffer and push the log box to
        // connected clients while the server runs.
        let logStreamer = IntervalService(name: "log-stream", interval: .milliseconds(400)) { [app] in
            guard !LogCollector.shared.drainNew().isEmpty else { return }
            guard await app.isLogsView() else { return }
            await server.broadcast(await app.liveLogFragments())
        }
        // Live workspace tree: while the right-hand panel is open, re-scan on a
        // slow cadence and push a fragment only when the listing changed.
        let wsStreamer = IntervalService(name: "workspace-tree", interval: .seconds(3)) { [app] in
            guard await app.isWorkspaceOpen() else { return }
            guard await app.scanWorkspaceTree() else { return }
            await server.broadcast(await app.liveWorkspaceFragments())
        }

        // The UI is only reachable once the server binds; record it so the
        // profile card can show the "Gateway running" badge truthfully.
        await app.markGatewayUp()

        // Second Law: the server and both streamers are Services in one group,
        // so startup is ordered and shutdown is graceful — cancellation stops
        // the loops and the listener together instead of leaving ad-hoc Tasks.
        //
        // Shutdown shape: the streamers observe graceful shutdown directly;
        // no-webui's `WebUIServerService` ends on CANCELLATION only, so this
        // host converts the inherited graceful shutdown into exactly that —
        // held in a task handle so the conversion is deterministic and the
        // subtree stops promptly instead of waiting out the grace period.
        let group = ServiceGroup(
            services: [
                WebUIServerService(server: server, logger: logger),
                logStreamer,
                wsStreamer,
            ],
            logger: logger
        )
        let run = Task { try await group.run() }
        do {
            try await withTaskCancellationOrGracefulShutdownHandler {
                try await run.value
            } onCancelOrGracefulShutdown: {
                run.cancel()
            }
        } catch is CancellationError {
            // expected: the inherited shutdown cancelled the subtree
        }
    }
}