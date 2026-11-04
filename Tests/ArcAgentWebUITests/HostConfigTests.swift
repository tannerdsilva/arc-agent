import Testing
import WebUIServer

@testable import ArcWebUI

/// the config arc actually runs, observed rather than restated.
///
/// every value here is a default `WebUIServerConfig` supplies and arc inherits
/// silently. pinning them through the host's own factory means a moved default
/// fails here instead of changing behaviour in the dark — and a test that
/// restated the numbers would keep passing after the real config changed.

extension ArcWebUITestRoot {
	@Suite("host config", .serialized)
	struct HostConfigTests {
		private let config = WebUIHost.serverConfig(host: "127.0.0.1", port: 8890)

		@Test("arc keeps render tokens off")
		func renderTokenPolicy() {
			// arc threads the page's render token into the document — uploads
			// carry it in `X-Render-Token` — but leaves `requireRenderToken`
			// off: the token is minted per render and lives only in this
			// process, so a page served before a restart (or held open past the
			// router reaping its session) would have every event refused. the
			// socket stays tolerant; uploads do their own check.
			// documented, not accidental.
			#expect(config.requireRenderToken == false)
		}

		@Test("arc runs the documented capacity defaults")
		func capacityDefaults() {
			// 178 handlers are registered against this cap: ~56× headroom.
			#expect(config.maxHandlers == 10_000)
			#expect(config.maxConnections == 256)
			#expect(config.maxSessions == 1_024)
		}

		@Test("the page route is the root")
		func routes() {
			#expect(config.pagePath == "/")
		}

		@Test("a refused render notifies the client rather than failing the page")
		func handlerFailurePolicy() {
			// the plan's ledger assumed `.strict`; the pin's default is `.notifyClient`
			// and arc does not override it. pinned so the assumption cannot drift back.
			#expect(config.handlerFailurePolicy == .notifyClient)
		}

		@Test("the host and port are threaded, not defaulted")
		func endpointIsThreaded() {
			let other = WebUIHost.serverConfig(host: "0.0.0.0", port: 18890)
			#expect(other.host == "0.0.0.0")
			#expect(other.port == 18890)
			#expect(config.host == "127.0.0.1")
			#expect(config.port == 8890)
		}

		@Test("both shipped assets are registered")
		func assetsAreRegistered() {
			#expect(config.assets.count == 2, "the sheet and the overlay are the two files the page loads")
		}
	}
}
