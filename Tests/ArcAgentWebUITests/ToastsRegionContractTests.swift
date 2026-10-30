import Testing
import Foundation
@testable import ArcWebUI

/// the toasts region is a PATCH TARGET, and the engine deletes a patch target
/// whose replacement fragment is empty (`replaceElement` → `el.remove()`).
/// so a push of "no toasts" must still carry the container, or `#toasts` dies
/// on the first dismiss and every later toast is silently swallowed.
/// measured live 2026-10-20: ten `[WebUIEngine] Element not found: #toasts`
/// warnings after five popover open/dismiss cycles against a running daemon.
///
/// the push-side half of this used to be a source grep over `Actions.swift`
/// (`"toasts"` + `toastsHTML()` on one line). Producers do not write toasts html
/// any more — the push edge derives it — so the grep could only pass vacuously.
/// The behaviour is pinned where it now lives:
/// `PushDiffTests.toastsChangeCarriesTheContainer` (a toasts change ships the
/// region, and the region's html is the container, appearing AND dismissing).

extension ArcWebUITestRoot {
	@Suite("toasts region contract", .serialized)
	struct ToastsRegionContractTests {

	    @Test("the empty shell still renders the patch target")
	    func shellAlwaysPresent() async {
	        let app = AppState(renderFixture: AppState.RenderFixture())
	        let html = await app.toastsShell().markup.html
	        #expect(html.contains("id=\"toasts\""),
	                "the shell must emit the patch target even with nothing to show")
	        #expect(html.contains("data-component-id=\"toast-dismiss\""),
	                "the shell must keep its routing anchor across a replacement")
	    }
	}
}
