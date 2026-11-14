import ArcAgentCore
import ArcSidebarTabs
import Foundation
import Logging
import ServiceLifecycle
import WebUI
import WebUIServer
import WebUIState

/// The push edge: the door arc's producers push through.
///
/// **What still crosses it, and what no longer does.**
///
/// - Render-time handlers do not: they answer `HandlerOutcome.refresh` (no-webui
///   2.9.0), and the server re-renders the dispatch session's page against the
///   baseline it owns, then fans the frames out itself.
/// - The `@Wired` host handlers do not either (no-webui 2.12.0): a handler's
///   return type picks its registration, so a structural handler declares
///   `HandlerOutcome` and answers `.refresh` (`Controller.changed()`) through
///   `register(outcome:)`. Nothing a handler returns reaches this door.
/// - The turn loop's structural boundaries and token deltas do: a turn runs in a
///   detached `Task`, and `.refresh` is only reachable from an event dispatch.
///
/// A batch means one of two things, and the door tells them apart rather than
/// trusting the producer to have:
///
/// - a **structural** op (`nil`/`.replace`, or an empty batch) says "the page
///   changed". The client needs the difference between what it holds and a
///   *fresh* render, and only the server can derive that: it served the page, so
///   it owns the baseline. The door therefore asks the server to refresh every
///   page this host served (`refresh`), and the server's own diff decides what
///   ships. **A structural batch never forwards its own html.** The producer
///   assembled it before the render that describes the same change, so at best
///   it is identical and at worst stale; forwarding it would also be a second
///   diff regime over one page, which is what this door exists to not be.
/// - a **delta** op (`.text`, `.append`) is a write against a node another
///   producer owns — the streaming spans, which `FragmentUpdate.text` rewrites on
///   every token. It goes to the wire verbatim, transition flag included;
///   re-deriving it would fight that writer.
///
/// Structure ships first, deltas second: a delta targets a node the structural
/// frame may have re-mounted, and the client would log "Element not found" for a
/// delta that beat its own container. Both are awaited, in that order.
final class PushEdge: Sendable {

    /// Ask the server to re-render every page this host served and ship what
    /// moved.
    ///
    /// A closure, not a `WebUIServer`: the door's whole job is to decide which
    /// half of a batch costs a refresh, and a test that has to conjure a live
    /// server to observe that decision is a test that will not be written. The
    /// host wires it to `server.refresh(session:)` over the render tokens the
    /// page route recorded; a suite wires it to a counter.
    private let refresh: @Sendable () async -> Void
    /// the wire for the half that crosses verbatim. Also a closure, for the same
    /// reason.
    private let broadcast: @Sendable ([FragmentUpdate]) async -> Void

    init(
        refresh: @escaping @Sendable () async -> Void,
        broadcast: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) {
        self.refresh = refresh
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
        // an empty batch is a producer saying "look at the page": the whole point
        // of the nudge. it costs one refresh, and the server ships nothing unless
        // the render moved bytes.
        let structural = updates.isEmpty || updates.contains { $0.op == nil || $0.op == .replace }

        if structural { await refresh() }
        if !deltas.isEmpty { await broadcast(deltas) }
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

    /// Sidecar plugin manager owned by the daemon; attached in `run()` so
    /// the plugin processes' host-side requests resolve while serving.
    let sidecarManager: SidecarPluginManager?

    public init(
        host: String = "127.0.0.1",
        port: Int = 8890,
        tesseraOff: Bool = false,
        storage: StorageRuntime? = nil,
        thirdPartyPlugins: [any SidebarTabPlugin] = [],
        sidecarManager: SidecarPluginManager? = nil,
        delivery: DeliveryManager? = nil,
        kanban: (any KanbanBoard)? = nil
    ) async throws {
        self.host = host
        self.port = port
        self.tesseraOff = tesseraOff
        self.storage = storage
        self.sidecarManager = sidecarManager
        self.app = try await AppState(
            thirdPartyPlugins: thirdPartyPlugins,
            // The daemon's platform delivery path, when it has one: the UI's
            // `send_message` binds this slot instead of the process global it
            // used to find (GROUNDZERO slice 6).
            delivery: delivery,
            // The daemon's one kanban board, when hosted in the daemon: the
            // UI's `kanban_*` tools then act on the board the sessions and the
            // dispatcher use (GROUNDZERO2 slice 1). Standalone, the UI builds
            // its own over the same `~/.arc/kanban` directory.
            kanban: kanban
        )
        // the origin this host serves on, for the one control that must carry an
        // absolute URL (the row menu's "Copy conversation link"): a render has no
        // request, so a server-rendered `data-copy` value cannot learn the
        // browser's origin, and a relative `?s=` copies nothing pasteable.
        await self.app.setPublicOrigin(Self.publicOrigin(host: host, port: port))
    }

    /// The absolute origin the page is served from, as a browser would spell it.
    ///
    /// A wildcard bind is not an origin any browser can use, so it reads as
    /// loopback — the address `arc serve` prints and the one a local browser is
    /// on. Port 80 keeps the default spelling.
    static func publicOrigin(host: String, port: Int) -> String {
        let h = (host.isEmpty || host == "0.0.0.0" || host == "::") ? "127.0.0.1" : host
        return port == 80 ? "http://\(h)" : "http://\(h):\(port)"
    }

    /// Run one scheduled job headless and return its output — the daemon's
    /// cron runner (`AppState` owns the model config, the sessions and the
    /// approval-aware headless tool path).
    public func runScheduledJob(_ job: CronJob) async -> String {
        await app.runScheduledJob(job)
    }

    /// the config the server is built with.
    ///
    /// exposed as one value so a test observes what arc actually runs instead of
    /// restating the literal: every field below is a default arc relies on
    /// (capacity headroom, render tokens off, the root page path), and a
    /// restated literal keeps passing after the real one moves.
    public var serverConfig: WebUIServerConfig { Self.serverConfig(host: host, port: port) }

    /// the config shape arc runs, independent of an instance.
    ///
    /// static because constructing a host resolves storage and a config file: a
    /// test that pins the server's capacity defaults must not need either.
    public static func serverConfig(host: String, port: Int) -> WebUIServerConfig {
        WebUIServerConfig(
            host: host,
            port: port,
            pagePath: "/",
            // registered at the bare path — the server strips a request's query
            // before the asset lookup, so a stamped url resolves to the same
            // bytes. the `?v=` is the *client's* cache key: a rebuilt asset is a
            // new url and cannot be served from a year-long cache under the old
            // one.
            assets: [
                AppShell.Assets.sheet.registration,
                AppShell.Assets.overlay.registration,
            ],
            // Workspace uploads stream over their own HTTP route with a
            // token-bound budget; the socket body limit stays off so large
            // request payloads elsewhere are not truncated (user request).
            maxBodyBytes: .max,
            // The server owns the baseline a re-render diffs against, and this is
            // the only dial that tells it which regions a re-render may ship.
            // `HandlerOutcome.refresh` and a producer refresh both diff here, so
            // one value keeps the two doors from ever disagreeing about what
            // crosses — `AppShell` owns it because it also owns the page region
            // those bytes land in.
            refreshPolicy: AppShell.refreshPolicy,
        )
    }

    /// the page document this host renders, from the config the server is built with.
    ///
    /// `maxFrameBytes` is read from `config.maxFrameSize` at the one place the page
    /// is assembled, so the budget the engine refuses on and the budget the socket
    /// enforces are the same number: a host that tunes the server cannot leave the
    /// page publishing the old one.
    static func pageDocument(
        config: WebUIServerConfig,
        sheetURL: String,
        overlayURL: String,
        renderToken: String? = nil
    ) -> @Sendable (UnsafeMarkup, String) -> WebUI.HTMLDocument {
        AppShell.makeDocument(
            sheetURL: sheetURL,
            overlayURL: overlayURL,
            renderToken: renderToken,
            maxFrameBytes: config.maxFrameSize
        )
    }

    public func run() async throws {
        // Route every swift-log line into the in-app ring buffer instead of
        // stdout, so the Logs panel is the operator view. Idempotent: the
        // daemon usually installed it first; this is a no-op then.
        WebUILogging.install()
        let logger = Logger(label: "arc-agent.webui")
        logger.info("starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        // one config value reaches the server and the page it serves: the frame
        // budget the page publishes is the one the socket enforces.
        let config = serverConfig

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
        let makeDocument = Self.pageDocument(config: config, sheetURL: sheet.url, overlayURL: overlay.url)
        // the tokens this host served, so `POST /api/upload` can tell a page it
        // rendered from a request that never loaded one. Bounded (see
        // `UploadTokenStore`): a daemon runs for weeks.
        let uploadTokens = UploadTokenStore()
        // The page is a typed value now, not a string: this provider answers the
        // document itself and `Route.page` hands it to the server, which renders
        // it inside the render context the server owns. That is the 2.0 shape the
        // deprecated `requestRender:` init predates — and the reason arc needs no
        // materializer of its own.
        //
        // The token is the one THIS response was minted for, and it is both
        // credentials at once: `webui-config`'s `renderToken` (the engine echoes
        // it, so every frame resolves to the session this render's
        // `controlAttributes` handlers registered into) and the upload route's
        // `X-Render-Token` (validated against the store below). no-webui 2.11.0
        // deleted the reason for a second meta — its upload transport reads
        // `engine.config.renderToken`, which is this value.
        // The shell above is rendered OUTSIDE a render pass — it is the same
        // document skeleton on every response — so it registers no session
        // handlers; the app's `appShell()` render is the one that runs inside the
        // server's `RenderContext` and lands in this token's session.
        let pageProvider: @Sendable (String?, String, RenderIntent) async -> WebUI.HTMLDocument = { [app] deepLink, renderToken, intent in
            // One render pipeline, three occasions (no-webui `RenderIntent`):
            // a load opens the deep link and arms scroll-to-bottom; a client
            // navigation re-arms the scroll; a `refresh` — a handler answered
            // `HandlerOutcome.refresh` — replays NEITHER, or every settings
            // toggle would drag the chat to the bottom and re-open a `?s=`.
            switch intent {
            case .load:
                if let sid = deepLink, !sid.isEmpty {
                    await app.openDeepLink(sid)
                }
                await app.armScrollToBottom()
            case .navigate:
                await app.armScrollToBottom()
            case .refresh:
                break
            }
            let shell = await app.appShell()
            return Self.pageDocument(
                config: config,
                sheetURL: sheet.url,
                overlayURL: overlay.url,
                renderToken: renderToken
            )(shell.markup, AppShell.themeAttrs(await app.themeDefaults()))
        }

        // "/" is the page. "/index.html" was its alias before the router existed
        // and stays one, so an old deep link keeps resolving (the deprecated
        // render inits added it for the same reason).
        //
        // Both page routes record the token they serve; the upload route is the
        // one POST arc answers itself (streamed to disk, never buffered).
        let pageRouter = Router {
            WorkspaceUpload.pageRoute("/", tokens: uploadTokens) { deepLink, token, intent in
                // ?s=<id> opens that conversation directly (copy-link flow).
                await pageProvider(deepLink, token, intent)
            }
            WorkspaceUpload.pageRoute("/index.html", tokens: uploadTokens) { _, token, intent in
                await pageProvider(nil, token, intent)
            }
            WorkspaceUpload.uploadRoute(
                root: { [app] in await app.workspaceRootURL() },
                tokenStore: uploadTokens,
                limit: WorkspaceUpload.configuredCap,
                onUploaded: { [app] in await app.clearWorkspaceTreeCache() }
            )
            // Composer uploads stage OUTSIDE any workspace: one folder per
            // chat under ~/.arc/uploads, removed when the chat is deleted.
            // The client names the destination `<sessionID>/<file>` in the
            // X-Upload-Path header; the path rules (no `..`, containment)
            // apply unchanged.
            WorkspaceUpload.uploadRoute(
                path: "/api/upload/chat",
                root: { await AppState.chatUploadsRootURL() },
                tokenStore: uploadTokens,
                limit: WorkspaceUpload.configuredCap
            )
        }

        // `eventRouter:` hands the server the router arc wires by hand: the
        // `wireAll` registrations below land in its HOST table — one table for
        // the whole router, sealed after the boot wiring and consulted by every
        // dispatch after the page's own session (§22.1/D1). Without this init
        // they would land in a router the server never consults.
        let server = WebUIServer(
            router: pageRouter,
            eventRouter: router,
            config: config,
            logger: logger
        )

        // The one push edge. The producers that still cross this door — the turn
        // loop's structural boundaries and its token deltas — get the door's own
        // decision: a structural batch asks the server to re-render the pages it
        // served, a delta is forwarded verbatim. Handlers no longer cross it:
        // `Controller.changed()` answers `HandlerOutcome.refresh`, and the server
        // re-renders the dispatch session's page itself (no-webui 2.12.0).
        //
        // Three producers do NOT cross it, by design: the log and workspace
        // streamers broadcast their fragments straight to `server.broadcast`
        // (they are not page regions the client patches from a page render), and
        // the token stream's `FragmentUpdate.text` deltas target nodes another
        // producer owns.
        //
        // The boot shell is captured once for the boot log line's byte count.
        let bootShell = await app.appShell().markup
        let bootPageBytes = makeDocument(
            bootShell,
            AppShell.themeAttrs(await app.themeDefaults())
        ).markup.html.utf8.count

        // Every page this host served is a structural refresh target.
        //
        // `uploadTokens` records each render token the page route handed out,
        // and the token IS the render session (`RenderSessionID(rawValue:)`), so
        // the store is the registry of "pages this host rendered". One structural
        // batch therefore asks the server to re-render each of them — the same
        // reach the retired single-differ broadcast had — and each page gets its
        // own diff against the baseline the server recorded when it served it. A
        // page that has not loaded yet is simply not in the set; a page older
        // than the store's capacity is not refreshed until it reloads (a daemon
        // runs for weeks, and an unbounded registry is a slow leak).
        //
        // `server.refresh(session:)` is a no-op before `start()` — the same shape
        // `broadcast` has — so a push that races boot costs nothing.
        let edge = PushEdge(
            refresh: { [server] in
                for token in await uploadTokens.snapshot() {
                    await server.refresh(session: RenderSessionID(token))
                }
            },
            broadcast: { [server] updates in await server.broadcast(updates) }
        )
        let controller = Controller(app: app, push: { updates in
            await edge.push(updates)
        })
        await controller.wireAll(router)
        // the host table is complete: seal it before the server can bind, so a
        // registration made without a session is a logged refusal (`.error`,
        // naming the id) instead of a table that grows under a live listener.
        // `wireAll` is arc's only host-table writer — every other registration
        // is a render pass (`controlAttributes`), and the seal does not touch
        // those. `WebUIServer.start()` seals too; the call is idempotent, and
        // sealing here states the ordering as arc's contract rather than as an
        // implementation detail of the server.
        router.sealHostRegistrations()
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
        // Scheduled-tasks liveness: the daemon's scheduler writes job records
        // and job chats out-of-band, so the Tasks page re-pulls on a slow
        // cadence and pushes a structural change only when something visible
        // moved (category moves, last/next run, the job's live chat thread).
        // An idle page sends nothing.
        let tasksStreamer = IntervalService(name: "scheduled-tasks", interval: .seconds(2)) { [app] in
            guard await app.syncScheduledJobs() else { return }
            await server.broadcast(await app.structuralChange())
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
                tasksStreamer,
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