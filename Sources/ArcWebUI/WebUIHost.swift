import ArcAgentCore
import Foundation
import Logging
import ServiceLifecycle
import WebUI
import WebUIServer

/// The Web UI host: boots the app state, serves the page through no-webui's
/// `WebUIServer`, and streams logs + the workspace tree while it runs.
///
/// Today it owns the process bootstrap (swift-log into the in-app ring buffer) and its own
/// `ServiceGroup` — the standalone `arc-agent-webui` binary is a shim over this value. The
/// daemon consolidation (`.hermes/plans/2026-10-01_093852-unify-the-daemon.md`) hoists the
/// bootstrap to the daemon root and mounts this under the daemon's tree; that is why the
/// host is already a `Service`.
public struct WebUIHost: Service {

    public let host: String
    public let port: Int
    public let tesseraOff: Bool

    public init(host: String = "127.0.0.1", port: Int = 8890, tesseraOff: Bool = false) {
        self.host = host
        self.port = port
        self.tesseraOff = tesseraOff
    }

    public func run() async throws {
        // Route every swift-log line into the in-app ring buffer instead of
        // stdout, so logs stop appearing in the terminal and surface in the
        // web UI's Logs section. Must run before any Logger is created.
        LoggingSystem.bootstrap { label in
            WebUILogHandler(label: label)
        }
        let logger = Logger(label: "arc-agent.webui")
        logger.info("starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        let app = try AppState()
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

        let controller = Controller(app: app, push: { updates in
            await server.broadcast(updates)
        })
        controller.wireAll(router)

        // the boot page is rendered here, once the stamped asset urls exist, purely
        // so the log line reports a real byte count.
        let bootPageBytes = makeDocument(
            await app.appShell(),
            AppShell.themeAttrs(await app.themeDefaults())
        ).render().utf8.count
        logger.info("serving http://\(host):\(port) (page \(bootPageBytes) bytes)")
        await app.startCronEngine()

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
        let group = ServiceGroup(
            services: [
                WebUIServerService(server: server, logger: logger),
                logStreamer,
                wsStreamer,
            ],
            logger: logger
        )
        try await group.run()
    }
}