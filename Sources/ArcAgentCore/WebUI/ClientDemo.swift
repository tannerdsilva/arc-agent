import Foundation
import Synchronization
import WebUI
import WebUIDesignSystem

/// the client-mode demo surface: serves the no-webui wasm module through
/// arc's own serving stack so the applet/worker-offload framework features
/// can be validated end-to-end in a real host (search vertical, typed table,
/// self-wiring applets, capability grants, indexeddb persistence).
///
/// the page is a `WebUIDocument(clientMode:)` — the chamber scripts
/// (`/__assets/webui-client.js` + boot glue) and the content-addressed wasm
/// route are served by `WebUIService`, and every response already carries the
/// cross-origin-isolation pair so the chamber boots the module in a worker.
public enum ClientDemo {

	/// artifact locations, first existing one wins: explicit override, then
	/// the no-webui checkout (path dependency) and a local `.build/out` for
	/// in-checkout runs.
	static func wasmArtifactCandidates() -> [String] {
		var candidates: [String] = []
		if let env = ProcessInfo.processInfo.environment["ARC_WASM_PATH"] {
			candidates.append(env)
		}
		candidates.append("../no-webui/.build/out/Products/Release-webassembly-wasm32/WebUIClient.wasm")
		candidates.append(".build/out/Products/Release-webassembly-wasm32/WebUIClient.wasm")
		return candidates
	}

	/// the artifact bytes + content hash, loaded once. absent artifact ⇒
	/// empty bytes and the hash stays blank (routes degrade to a hint).
	static func artifact() -> (bytes: [UInt8], hash: String) {
		cache.withLock { cached in
			if let cached { return cached }
			var result: (bytes: [UInt8], hash: String) = ([], "")
			for path in wasmArtifactCandidates() {
				guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
				      !data.isEmpty else { continue }
				let bytes = [UInt8](data)
				result = (bytes, WebUIBoot.wasmHash(of: bytes))
				break
			}
			cached = result
			return result
		}
	}

	private static let cache = Mutex<(bytes: [UInt8], hash: String)?>(nil)

	/// the content-addressed wasm url (immutable-cached) or the no-store
	/// alias when the artifact is absent.
	static func wasmURL(hash: String) -> String {
		hash.isEmpty ? "/__assets/app.wasm" : "/__assets/app.\(hash).wasm"
	}

	/// render the standalone `/client` document (auth handled by the caller).
	static func renderPage(wasmPresent: Bool, wasmHash: String) -> String {
		guard wasmPresent else {
			let body = Div(class: "client-demo") {
				VStack(alignment: .leading, spacing: 12) {
					Heading("Client demo not built", level: .h2)
					Text("the wasm artifact was not found — build it with the wasm sdk:")
					Text("swift build -c release --swift-sdk swift-6.4.0-RELEASE_wasm --product WebUIClient (in the no-webui checkout)")
				}
			}.render()
			return WebUIDocument(title: "Client Demo · ARC Agent", body: body).render()
		}

		let boot = ClientBoot(
			wasmURL: wasmURL(hash: wasmHash),
			mode: .app,
			config: RuntimeConfig(
				capabilities: ["focus", "clipboard", "broadcast", "files", "fullscreen", "media"],
				persistence: "indexeddb"
			),
			scriptURLs: ["/__assets/webui-client.js", "/__assets/arc-client-boot.js"]
		)

		let body = Div(class: "client-demo") {
			VStack(alignment: .leading, spacing: 16) {
				Heading("Client mode · applets & worker offload", level: .h1)
				Text("this page boots the no-webui wasm module through arc's serving stack — the search vertical, typed table and self-wiring applet card all run inside the module, off the main thread, with zero websocket traffic on the hot path.")
				Div(id: "search-app") { EmptyView() }
			}
		}.render()

		return WebUIDocument(
			title: "Client Demo · ARC Agent",
			body: body,
			clientMode: boot,
			includeRuntime: false,
			rawStyles: [Self.demoStyles]
		).render()
	}

	/// page-scoped styles for the module's demo markup (lands after the shared
	/// sheet, so it extends without overriding the design-system defaults).
	static let demoStyles = """
	.client-demo { max-width: 960px; margin: 0 auto; padding: var(--space-6) var(--space-4); }
	/* the module mounts into #search-app inside a leading-aligned stack, so give
	   the mount (and thus the search/table/chart/applet) the full column width
	   instead of collapsing to the content's intrinsic width. */
	#search-app { width: 100%; }
	.search { display: flex; flex-direction: column; gap: var(--space-4); width: 100%; }
	.search__field { display: flex; align-items: center; width: 100%; }
	.search__field input { width: 100%; padding: var(--space-2) var(--space-3); font: inherit; color: var(--color-text); background: var(--color-bg-raised); border: 1px solid var(--color-border); border-radius: var(--radius-md); }
	.search__field input:focus { outline: none; border-color: var(--color-primary-500); box-shadow: var(--ring-focus); }
	/* table: lift data cells out of muted so rows read clearly in both themes;
	   keep the selection/expand controls subdued. */
	.search__rows { overflow-x: auto; }
	.search__rows table td { color: var(--color-text); }
	.search__rows table td.table__expand-col, .search__rows table td.table__select-col { color: var(--color-text-muted); }
	/* chart: full-width, legible axes, subtle grid, refined rounded bars. */
	.search__chart { width: 100%; }
	.search__chart svg { width: 100%; height: auto; display: block; }
	.search__chart .chart__axis-label { fill: var(--color-text-muted); font-size: var(--font-size-sm); }
	.search__chart .chart__grid { stroke: var(--color-border); opacity: 0.5; }
	.search__chart .chart__baseline { stroke: var(--color-border); }
	.search__chart .chart__bar { fill: var(--color-primary-500); clip-path: inset(0 round 7px 7px 0 0); }
	.search__chart .chart__bar:hover { fill: var(--color-primary-600); }
	.search__meta, .search__error, .search__valid { color: var(--color-text-muted); font-size: var(--font-size-sm); }
	.search__error { color: var(--color-danger); }
	.search__valid { color: var(--color-success); }
	.applet-card { width: 100%; }
	.applet-card__meta { color: var(--color-text-muted); font-size: var(--font-size-sm); margin-top: var(--space-1); }
	"""
}
