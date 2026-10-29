import Foundation
import Testing
import SwiftSlash
@testable import ArcAgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension ArcCoreTestRoot {

	/// The placement decision, observed from where it actually differs.
	///
	/// From a top-level process the resolved default and an explicit `.own` look
	/// identical — the default *is* `.own` there — so a suite that never leaves a
	/// launch cannot tell them apart. arc asks for `.own` explicitly because of
	/// the other case: when arc is itself a launch child (a harness spawning arc,
	/// arc's own integration runs), the default would hand arc's child to the
	/// *enclosing* group, and arc's cancellation would degrade to a pid-only kill
	/// that reaches nothing else in the tree. ``ArcSubprocessFixture`` is the
	/// launch child that makes the difference observable.
	///
	/// The second half is the cascade: a program spawned from inside a launch by
	/// *plain* SwiftSlash — no placement argument, the shape a nested SwiftSlash
	/// program has, such as swift-mcp's subprocess transport — joins the group it
	/// was started into instead of escaping into one of its own.
	@Suite("Subprocess placement cascade", .serialized)
	struct SubprocessCascadeTests {

		private func bash(_ script: String) -> Command {
			var cmd = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", script])
			cmd.inheritCurrentEnvironment()
			return cmd
		}

		@Test("arc's explicit .own keeps its child in arc's own group, even from inside a launch")
		func explicitOwnFromInsideALaunch() async throws {
			let scratch = try SubprocessProbe.makeScratch("own")
			defer { try? FileManager.default.removeItem(at: scratch) }
			let marker = scratch.appendingPathComponent("report.txt").path
			let fixture = try SubprocessProbe.fixturePath()

			let out = try await SubprocessRunner.runBytes(
				bash("'\(fixture)' placement '\(marker)'"), timeout: 30)
			#expect(out.exitCode == 0)

			let report = try SubprocessProbe.readReport(marker)
			// the fixture is a launch child: without that, the placement question
			// below cannot be asked at all.
			#expect(report["launch"] == "present")
			// the fixture itself leads the group arc gave it.
			#expect(report["fixturepgid"] == report["fixturepid"])

			// the child the fixture spawned through arc's runner leads its OWN
			// group — arc asked for `.own` rather than accepting the resolved
			// `.inherited` that this launch would otherwise supply.
			#expect(report["childpgid"] == report["childpid"])
			#expect(report["childpgid"] != report["fixturepid"])

			// ...and it is in the same session: nothing arc starts is detached.
			#expect(report["childsid"] == report["fixturesid"])
			// arc's cancellation — the group signal — swept it.
			#expect(report["afterCancelAlive"] == "0")
		}

		@Test("a nested plain-SwiftSlash spawn joins the group arc owns, and one signal takes the tree")
		func nestedSpawnJoinsArcGroup() async throws {
			let scratch = try SubprocessProbe.makeScratch("cascade")
			defer { try? FileManager.default.removeItem(at: scratch) }
			let marker = scratch.appendingPathComponent("report.txt").path
			let fixture = try SubprocessProbe.fixturePath()

			// the fixture holds its tree open until it is signalled, so the
			// mechanism is asserted before the signal and the outcome after it.
			let run = Task {
				try? await SubprocessRunner.runBytes(
					bash("'\(fixture)' cascade '\(marker)'"), timeout: 60)
			}
			let report = try #require(await SubprocessProbe.waitForReport(marker))

			let fixturePID = try #require(Int32(report["fixturepid"] ?? ""))
			let shellPID = try #require(Int32(report["shellpid"] ?? ""))
			let grandchildPID = try #require(Int32(report["gcpid"] ?? ""))

			// the mechanism, read from inside the nest:
			// the fixture leads the group arc gave it …
			#expect(report["fixturepgid"] == report["fixturepid"])
			// … the shell the fixture started (plain SwiftSlash, no placement
			// argument) joined that group rather than escaping into its own …
			#expect(report["shellpgid"] == report["fixturepid"])
			// … and so did the shell's own backgrounded child.
			#expect(report["gcpgid"] == report["fixturepid"])
			// nothing in the tree leads a second group, and nothing is detached.
			#expect(report["gcpgid"] != report["gcpid"])
			#expect(report["gcsid"] == report["fixturesid"])

			// the outcome: ONE group signal from the owner takes the whole tree.
			run.cancel()
			_ = await run.value
			#expect(await SubprocessProbe.waitUntilGone(fixturePID))
			#expect(await SubprocessProbe.waitUntilGone(shellPID))
			#expect(await SubprocessProbe.waitUntilGone(grandchildPID))

			// never leave a survivor behind, even on a failed expectation.
			for pid in [grandchildPID, shellPID, fixturePID] where !SubprocessProbe.isGone(pid) {
				SubprocessProbe.signalGroup(pid, SIGKILL)
				_ = kill(pid, SIGKILL)
			}
		}
	}
}