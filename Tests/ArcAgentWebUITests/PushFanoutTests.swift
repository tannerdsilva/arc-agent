import Testing

@testable import ArcWebUI

/// what one producer push reaches.
///
/// this suite used to pin the opposite shape: ONE `PageDiffer` for the process,
/// so two tabs shared a baseline and a push fanned out as a single broadcast of
/// bytes no client could be a frame ahead of. That mechanism is retired (A10b):
/// the server keeps a baseline per render session, so each page is diffed
/// against the bytes it was served.
///
/// the door still issues exactly ONE refresh call per structural batch
/// (`PushDiffTests` pins the order and the count); what changed is that the call
/// names every page this host served. The registry of "every page" is the one
/// the page route already keeps — `UploadTokenStore`, because a render token IS
/// a render session — so this suite pins that registry, which is now the reach
/// of every producer push:
///
/// - every served page is named once, oldest first, so a structural batch
///   re-renders all of them;
/// - the set is bounded, because a daemon runs for weeks and every page load
///   mints a token;
/// - a page re-served the same token is named once, so a reload cannot make one
///   page cost two renders.
///
/// The retired assertions and where their meaning went:
/// - "one push is one broadcast, so every connected page receives identical
///   bytes" → `PushDiffTests.mixedBatchPartitions` (one broadcast per push) and
///   `TwoPopulationDispatchTests.refreshIsSessionScoped` (who receives it).
/// - "a tab that joins late converges on the next push, and a repeat push is
///   silent" → the server's per-session baseline; a repeat refresh whose render
///   is unchanged sends nothing, proven in
///   `ProducerRefreshWireTests.aSecondRefreshWithNoByteChangeShipsNothing`.

extension ArcWebUITestRoot {
	@Suite("push fan-out", .serialized)
	struct PushFanoutTests {

		@Test("every page the host served is named once, in serve order")
		func everyServedPageIsNamed() async {
			let tokens = UploadTokenStore()
			await tokens.record("tok-a")
			await tokens.record("tok-b")
			await tokens.record("tok-c")

			let snapshot = await tokens.snapshot()
			#expect(snapshot == ["tok-a", "tok-b", "tok-c"],
				"the door names the tokens in serve order: \(snapshot)")
			#expect(Set(snapshot).count == snapshot.count, "a page was named twice")
		}

		@Test("a re-served token is one page, not two")
		func aReservedTokenIsOnePage() async {
			let tokens = UploadTokenStore()
			await tokens.record("tok-a")
			await tokens.record("tok-b")
			// the same page reloaded: the same session id, so the door must not
			// refresh it twice in one pass.
			await tokens.record("tok-a")

			let snapshot = await tokens.snapshot()
			#expect(snapshot == ["tok-a", "tok-b"], "a re-served page was named twice: \(snapshot)")
		}

		@Test("an old page falls out of the set at capacity")
		func theSetIsBounded() async {
			// bounded on purpose: a daemon runs for weeks, so the registry cannot
			// grow with every page load. The oldest page stops being refreshed
			// before it reloads — a liveness hint, never a durable guarantee.
			let tokens = UploadTokenStore(capacity: 3)
			for index in 0..<5 {
				await tokens.record("tok-\(index)")
			}

			let snapshot = await tokens.snapshot()
			#expect(snapshot == ["tok-2", "tok-3", "tok-4"],
				"the oldest pages were not evicted in serve order: \(snapshot)")
			#expect(await tokens.count == 3, "the store outgrew its capacity")
		}

		@Test("an empty token is not a page")
		func anEmptyTokenIsNotAPage() async {
			// the framework's mint can fail; a page that carries no token must not
			// put "" in the refresh set, or the door would name a session that
			// cannot exist.
			let tokens = UploadTokenStore()
			await tokens.record("")
			#expect(await tokens.snapshot().isEmpty, "an empty token entered the refresh set")
		}
	}
}
