import ArcAgentCore
import ArcSidebarTabs
import Foundation
import Logging
import ServiceLifecycle
import WebUI
import WebUIServer
import WebUIState

/// The one structural push edge: the door every producer in arc pushes through,
/// standing on no-webui's `PageDiffer` instead of re-deriving a patch per
/// handler.
///
/// A batch means one of two things, and the door tells them apart rather than
/// trusting the producer to have:
///
/// - a **structural** op (`nil`/`.replace`) says "the page changed". The frame
///   the client needs is the difference between what it holds and a *fresh*
///   render, so the edge renders once and ships the differ's frames. The `html`
///   the producer sent is ignored: a handler that assembled markup is re-sending
///   bytes the render already contains, at best identical and at worst stale.
/// - a **delta** op (`.text`, `.append`) is a write against a node another
///   producer owns — the streaming spans, which `FragmentUpdate.text` rewrites on
///   every token. It goes to the wire verbatim, transition flag included;
///   re-deriving it would fight that writer.
///
/// Structure ships first, deltas second: a delta targets a node the structural
/// frame may have re-mounted, and the client would log "Element not found" for a
/// delta that beat its own container.
final class PushEdge: Sendable {

    /// The diff arc's page is served from.
    ///
    /// `elementID` identity is the only one that is a real address: the engine
    /// resolves a frame with `getElementById`, and the shell is full of elements
    /// that carry a component attribute but no `id`. `.finest` coverage is what
    /// keeps a chrome change from dragging `#app` onto the wire; `.nearestTrackedAncestor`
    /// makes an appeared node a parent replace instead of a whole page; the two
    /// excluded spans are the token-owned ones, whose bytes must not make their
    /// ancestors look changed. `transition: false` is a stated policy, not a `nil`
    /// delegation — the diff is not a navigation and must not animate as one.
    static let livePolicy = RegionPolicy(
        identity: .elementID,
        coverage: .finest,
        escalation: .nearestTrackedAncestor,
        excluded: ["live-turn-text", "live-turn-thinking"],
        transition: false
    )

    private let differ: PageDiffer
    /// the markup a fresh `app.appShell()` answers — the root element's own
    /// bytes, never a document (a document's diff is scoped to `<body>`, and the
    /// frames would then name a different root than every later render).
    private let render: @Sendable () async -> String
    /// the wire. A closure, not a `WebUIServer`: the door's whole job is to decide
    /// what crosses, and a test that has to conjure a live server to observe that
    /// decision is a test that will not be written.
    private let broadcast: @Sendable ([FragmentUpdate]) async -> Void

    init(
        differ: PageDiffer,
        render: @escaping @Sendable () async -> String,
        broadcast: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) {
        self.differ = differ
        self.render = render
        self.broadcast = broadcast
    }

    /// The door `Controller.push` is wired to.
    ///
    /// Partition, never assume: a batch is homogeneous today — all `.text` from
    /// the token stream, all `.replace` from a handler — but a door that assumed
    /// it would silently drop a delta the day a producer mixed the two, and the
    /// failure would look like a dropped keystroke rather than a dropped batch.
    func push(_ updates: [FragmentUpdate]) async {
        let deltas = updates.filter { $0.op == .text || $0.op == .append }
        let hasStructure = updates.contains { $0.op == nil || $0.op == .replace }

        if hasStructure {
            let frames = differ.messages(forMarkup: await render(), root: "app")
            // empty means "nothing moved" — the render that triggered this push
            // produced the bytes the client already holds, so there is no frame and
            // no reason to wake the wire.
            if !frames.isEmpty { await broadcast(frames) }
        }
        if !deltas.isEmpty { await broadcast(deltas) }
    }

    /// Declare what the client already holds — the page the host just served — so
    /// the first patch is a region instead of a whole-root replace.
    func seed(_ markup: String) { differ.seed(withMarkup: markup) }
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

    /// Sidecar plugin manager owned by the daemon; attached in `run()` so
    /// the plugin processes' host-side requests resolve while serving.
    let sidecarManager: SidecarPluginManager?

    public init(
        host: String = "127.0.0.1",
        port: Int = 8890,
        tesseraOff: Bool = false,
        storage: StorageRuntime? = nil,
        thirdPartyPlugins: [any SidebarTabPlugin] = [],
        sidecarManager: SidecarPluginManager? = nil
    ) async throws {
        self.host = host
        self.port = port
        self.tesseraOff = tesseraOff
        self.storage = storage
        self.sidecarManager = sidecarManager
        self.app = try await AppState(thirdPartyPlugins: thirdPartyPlugins)
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

        // Sidecar plugins answer host-side channel requests through the
        // app state; attach before the first render (their activate/render
        // calls can arrive as soon as the UI is up).
        if let sidecarManager {
            await sidecarManager.attachHost(self.app)
        }

        let app = self.app
        if let storage {
            // the daemon prebuilt the process storage and already probed it:
            // attach it (one store pair for the whole process) and boot plain —
            // there is nothing left to time out.
            await app.attachRuntime(storage)
            await app.boot()
            app.crumb("host: boot on attached storage (backend=\(storage.backend))")
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
                await app.boot()
                c.yield(.success(())); c.finish()
            }
            Task {
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch {}
                c.yield(.failure(BootTimeout())); c.finish()
            }
            switch await stream.stream.first(where: { _ in true }) {
            case .success:
                app.crumb("entry: boot race completed cleanly")
            case .failure:
                app.crumb("entry: boot timeout — fallback to file")
                logger.warning("boot timed out (Tessera unreachable?) — using file storage")
                bootTask.cancel()
                await app.forceTesseraOff()
                await app.boot()
                app.crumb("entry: fallback boot done")
            case nil:
                app.crumb("entry: boot race stream ended empty")
            }
        }
        app.crumb("entry: boot block done")
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
        // The page is a typed value now, not a string: this provider answers the
        // document itself and `Route.page` hands it to the server, which renders
        // it inside the render context the server owns. That is the 2.0 shape the
        // deprecated `requestRender:` init predates — and the reason arc needs no
        // materializer of its own.
        let pageProvider: @Sendable (String?) async -> WebUI.HTMLDocument = { [app] deepLink in
            if let sid = deepLink, !sid.isEmpty {
                await app.openDeepLink(sid)
            }
            await app.armScrollToBottom()
            let shell = await app.appShell()
            return makeDocument(shell.markup, AppShell.themeAttrs(await app.themeDefaults()))
        }

        // "/" is the page. "/index.html" was its alias before the router existed
        // and stays one, so an old deep link keeps resolving (the deprecated
        // render inits added it for the same reason).
        let pageRouter = Router {
            Route.page("/") { request in
                // ?s=<id> opens that conversation directly (copy-link flow).
                await pageProvider(request.query["s"])
            }
            Route.page("/index.html") { _ in
                await pageProvider(nil)
            }
        }

        // `eventRouter:` hands the server the router arc wires by hand: the
        // `wireAll` registrations below land in its default session, and without
        // this init they would land in a router the server never consults.
        let server = WebUIServer(
            router: pageRouter,
            eventRouter: router,
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

        // The one push edge. Every producer's batch crosses this door, and the
        // frame that reaches the wire is derived from a fresh render rather than
        // trusted from the producer.
        //
        // The boot shell is captured once and serves twice: the log line's byte
        // count, and the differ's seed. The seed is the shell's ELEMENT markup
        // (`#app`), not the document — every later `render()` answers `#app`, and
        // a document's diff is scoped to `<body>`. Seeding a document would diff
        // two different roots on the first push and ship the whole page.
        let bootShell = await app.appShell().markup
        let bootPageBytes = makeDocument(
            bootShell,
            AppShell.themeAttrs(await app.themeDefaults())
        ).markup.html.utf8.count

        let edge = PushEdge(
            differ: PageDiffer(policy: PushEdge.livePolicy),
            render: { [app] in await app.appShell().markup.html },
            broadcast: { [server] updates in await server.broadcast(updates) }
        )
        edge.seed(bootShell.html)
        let controller = Controller(app: app, push: { updates in
            await edge.push(updates)
        })
        await controller.wireAll(router)
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
        // Error toasts expire on their own (AppState.toastTTL). The tick is
        // silent unless a toast actually dropped, so an idle UI sees no traffic.
        let toastStreamer = IntervalService(name: "toast-expiry", interval: .seconds(1)) { [app] in
            guard await app.expireToasts() else { return }
            await server.broadcast(await app.toastFragments())
        }

        // The UI is only reachable once the server binds; record it so the
        // profile card can show the "Daemon running" badge truthfully.
        await app.markDaemonUp()

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
                toastStreamer,
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
        } catch {
            // Unexpected exit: release the app state before propagating. An
            // AsyncHTTPClient that was never shut down traps in its deinit.
            await app.shutdown()
            throw error
        }
        // Second Law: cleanup belongs at the end of `run()`, not in a deinit.
        // The daemon releases this host — and with it the app state — while the
        // process is still alive, so an un-shutdown AsyncHTTPClient would trap
        // on deinit (`Fatal error: Client not shut down before the deinit`).
        // That trap is the Ctrl-C crash on `arc serve`. Reached on the expected
        // cancellation path too: the `CancellationError` catch swallows instead
        // of rethrowing, so this is the single cleanup site for both.
        app.crumb("host: teardown — releasing app state")
        await app.shutdown()
    }

    /// Record sidecar startup outcomes on the app state, called by the daemon
    /// after discovery so the plugin row can render a failure badge (UX-25).
    public func setPluginStartupOutcomes(_ outcomes: [String: SidecarPluginManager.PluginStartupOutcome]) {
        for (name, outcome) in outcomes {
            switch outcome {
            case .running: Task { await self.app.setPluginStartupOutcome(name, nil) }
            case .failed(let reason): Task { await self.app.setPluginStartupOutcome(name, reason) }
            }
        }
    }
}