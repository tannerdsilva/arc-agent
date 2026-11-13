/// the client overlay's size ceiling — F10.
///
/// the framework's `budget` plugin pins the engine, the sheet, the shell and
/// every island artifact, but a consumer overlay is invisible to it: nothing in
/// this tree counts `Assets/overlay.js` bytes, and `PageFrameBudgetTests` covers
/// the websocket frame budget, not asset bytes. 104 KB therefore grew to 1.65×
/// the engine it drives with nothing to trip.
///
/// the ceiling is a **ratchet**. a commit that deletes from the overlay lowers
/// it to the new count in the same commit; a commit that adds raises it and says
/// why in its message. that is the only mechanic in this repo by which the
/// migration paydown is visible in a diff instead of being recalled.
@testable import ArcWebUI
import Foundation
import Testing

extension ArcWebUITestRoot {
	@Suite("Client asset budget", .serialized)
	struct ClientAssetBudgetTests {

		/// measured 85,453 bytes / 1,915 lines after A2 (no-webui 2.6.0): the
		/// engine's dispatch table replaced the panel-scroll, skip-link, reorder,
		/// ticking-label, roving, scrollspy and copy blocks (2,394 → 1,915
		/// lines). the merged file runs 3,760 bytes above the local line's
		/// 81,693 because the upstream composer-attachment, workspace-delete and
		/// popover blocks are still in it; the commits that follow in this
		/// program retire those into engine behavior too, so the ceiling keeps
		/// falling rather than resting here. one byte of headroom, which is the
		/// ratchet working as intended.
		private static let ceiling = 85_454

		private static let sourcePath = "Sources/ArcWebUI/Assets/overlay.js"

		@Test("the overlay stays inside its byte ceiling")
		func overlayWithinCeiling() {
			// cwd is the package root under `swift test` (the same assumption
			// `Parity.readGolden` makes), so this reads the file the build embeds.
			let data = try? Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
			let count = data?.count ?? 0
			#expect(count > 0, "could not read \(Self.sourcePath) — is cwd the package root?")

			let lines = data.map { bytes in bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } } ?? 0
			#expect(
				count <= Self.ceiling,
				"""
				the overlay is \(count) bytes / \(lines) lines, over its \(Self.ceiling)-byte \
				ceiling. growth here is a decision: raise the ceiling *and* say why in the \
				commit message, or make the addition smaller
				"""
			)
		}

		@Test("the served overlay is the file this budget measures")
		func embeddedOverlayTracksSource() {
			// the budget is meaningless if it measures a file the daemon does not
			// serve: `Assets/overlay.js` is embedded at build time and served as
			// /ui/init.js, so the embedded copy is the artifact a client receives.
			let served = AppShell.Assets.overlay.bytes
			let onDisk = (try? Data(contentsOf: URL(fileURLWithPath: Self.sourcePath)))?.count ?? 0
			#expect(
				served.count == onDisk,
				"""
				the served overlay is \(served.count) bytes but \(Self.sourcePath) is \(onDisk) — \
				the embed did not track the source, so this budget is measuring the wrong file
				"""
			)
		}
	}
}
