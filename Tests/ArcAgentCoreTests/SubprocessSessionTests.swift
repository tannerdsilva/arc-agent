import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ArcAgentCore

extension ArcCoreTestRoot {

	/// The long-lived spawn entry point, on its own.
	///
	/// `processGroup: .own` is the whole reason this type exists — it is what
	/// lets one signal reach a child's tree — so it is asserted against the
	/// kernel rather than inferred from the code. Byte fidelity is asserted in
	/// the same suite because the two choices interact: a line separator would
	/// have been simpler and would have silently eaten newlines out of every
	/// background log.
	@Suite("Subprocess session", .serialized, .timeLimit(.minutes(2)))
	struct SubprocessSessionTests {

		@Test("the child leads its own group, and terminate() reaps it")
		func placementAndReap() async throws {
			let session = SubprocessSession(
				executable: "/bin/sh",
				arguments: ["-c", "exec sleep 30"])
			let pid = try #require(await session.start())
			#expect(pid > 0, "start() must return the pid the kernel assigned")

			// asked of the kernel, not of the script: `.own` means the child leads
			// its own group, while the session stays arc's.
			#expect(getpgid(pid) == pid, "the session's child must lead its own process group")
			#expect(getsid(pid) == getsid(0), "the session's child must stay in arc's session")

			let running = await session.isRunning()
			#expect(running)

			await session.terminate(grace: .seconds(2))

			let status = await session.exitStatus()
			#expect(status != nil, "terminate() must reap and record the exit")

			// ESRCH proves the pid is gone; probed in-process, never through ps, so
			// the assertion does not depend on shell plumbing.
			errno = 0
			let gone = kill(pid, 0) == -1 && errno == ESRCH
			#expect(gone, "the child must be gone once terminate() returns")
		}

		@Test("raw bytes survive: no separator is eaten")
		func rawBytesSurvive() async throws {
			// no trailing newline on the second line — a line separator would strip
			// it, which is exactly the corruption a build log cannot survive.
			let session = SubprocessSession(
				executable: "/bin/sh",
				arguments: ["-c", "printf 'one\\ntwo'"])
			_ = try await session.start()

			var collected: [UInt8] = []
			for await chunk in session.stdout {
				collected.append(contentsOf: chunk)
			}
			let text = String(decoding: collected, as: UTF8.self)
			#expect(text == "one\ntwo", "expected byte-exact 'one\\ntwo', got \(text.debugDescription)")

			let code = await session.waitForExit()
			#expect(code == 0)
		}

		@Test("a command that cannot exec is refused, not left to hang")
		func refusesUnreachableCommand() async throws {
			// a bare name, not an absolute path. unguarded, this produces no child
			// at all and the launch waits on a continuation nothing resumes — a hang
			// with no diagnostic instead of an error.
			let session = SubprocessSession(executable: "sh")
			do {
				_ = try await session.start()
				Issue.record("a bare command name must be refused")
			} catch {
				// expected: a value, not a hang
			}
		}
	}
}