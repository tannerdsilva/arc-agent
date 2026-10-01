import ArcAgentCore
import ArgumentParser
import Foundation
import Logging
import ServiceLifecycle
import WebUI
import WebUIDesignSystem
import WebUIServer

// MARK: - Entry point

@main
struct ArcAgentWebUI: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "arc-agent-webui",
        abstract: "ARC Agent web UI (no-webui engine).",
        discussion: """
        Serves the ARC Agent interface: chat, skills, profiles, tools,
        workspaces and settings — built entirely on the no-webui Swift
        library. Sessions and memory use the same stores as the CLI.
        """
    )

    @Option(name: .shortAndLong, help: "Host to bind.")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Port to bind.")
    var port: Int = 8890

    @Flag(name: .long, help: "Use file storage instead of Tessera.")
    var tesseraOff: Bool = false

    /// `data-scheme`/`data-theme` for `<html>`, escaped like every other attribute the
    /// framework emits.
    static func themeAttrs(_ theme: (scheme: String, mode: String)) -> String {
        "data-scheme=\"\(esc(theme.scheme))\" data-theme=\"\(esc(theme.mode))\""
    }

    /// The page template: the framework's component sheet links FIRST, arc's own chrome +
    /// scheme sheet LAST.
    ///
    /// Two parameters, not one, and the order is the contract. `HTMLDocument` emits
    /// `stylesheetURL:` (the base sheet) before `themeStylesheetURL:`, and its `head:` slot —
    /// where arc's link used to live — renders *before* both. arc's markup leans on the
    /// framework's `.icon { width:1em }` base (15 of its rules size an svg's presentation
    /// only), so the component sheet must be linked; and arc's sheet must follow it, or the
    /// three colliding `:root` tokens (`--radius-sm/md/lg`) and ten like-named classes
    /// (`chip`, `kv`, `toast`, …) silently change ownership.
    static func makeDocument(
        sheetURL: String,
        overlayURL: String
    ) -> @Sendable (String, String) -> WebUI.HTMLDocument {
        { body, themeAttrs in
            WebUI.HTMLDocument(
                title: "ARC Agent",
                body: body,
                rawStyles: [],
                head: """
                <script src="\(overlayURL)"></script>
                """,
                htmlAttributes: themeAttrs,
                devMode: false,
                // Extras, not a restated policy: a full policy names no nonce source, and
                // `HTMLDocument` then suppresses the pre-paint theme prelude rather than
                // emit an inline script the browser refuses (a stored scheme would flash
                // on every load). This directive is all arc needs beyond the framework
                // default — remote images in rendered markdown.
                contentSecurityPolicyExtras: "img-src 'self' data: https: blob:",
                // framework components (base sheet, emitted first)…
                stylesheetURL: DesignSystemAssets.stylesheetURL,
                // …then arc's chrome + 27 schemes, so its tokens win the collisions
                themeStylesheetURL: sheetURL
            )
        }
    }

    func run() async throws {
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

        // The sheet is a build product (`ArcAssetTool theme-sheet`): rendered from
        // `Sources/ArcTheme/`, stamped with the sha256 its url carries, and gzipped at build
        // time. One `WebUIAsset` owns the bytes, the url a page links and the registration the
        // server answers with, so the address, the bytes and the cache policy cannot disagree —
        // and a test pins the product against the source it came from.
        let sheet = WebUIAsset(ThemeSheetAssets.self, path: "/ui/style.css")

        // The overlay is a shipped asset too: no-webui's embed plugin generates
        // `EmbeddedAssets.swift` from `Assets/webui-assets.json` on every build, so the
        // script's bytes, its address and its registration all come from one value as well.
        let overlay = WebUIAsset(ArcOverlay.self, path: "/ui/init.js")

        // Assemble the page (external /ui/* assets keep each response small).
        // The document template wraps whatever body the app currently renders,
        // so a refresh ALWAYS reflects live store state (a boot-cached page
        // would show sessions deleted after startup).
        // The theme attributes belong on `<html>`, not on `#app`: the engine writes them on
        // `documentElement` and the theme is scoped to `:root`. `themeAttrs` is the server's
        // default, which the engine overrides from storage before first paint.
        let makeDocument = Self.makeDocument(sheetURL: sheet.url, overlayURL: overlay.url)
        let pageProvider: @Sendable (String?) async -> String = { [app] deepLink in
            if let sid = deepLink, !sid.isEmpty {
                await app.openDeepLink(sid)
            }
            await app.armScrollToBottom()
            let shell = await app.appShell()
            return makeDocument(shell, Self.themeAttrs(await app.themeDefaults())).render()
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
            Self.themeAttrs(await app.themeDefaults())
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
