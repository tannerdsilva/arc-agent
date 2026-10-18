import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ArcAgentCore

extension ArcCoreTestRoot {

	/// The ACP spawn contract, driven end to end against a fake server.
	///
	/// `ACPClient` is the second of arc's two SwiftSlash spawn sites, it has no
	/// construction site anywhere in `Sources/`, and it had no test at all — so
	/// the placement it asks for, the line protocol it speaks and the reaping its
	/// `shutdown()` promises were all unverified. An unreferenced type with a
	/// spawn site is exactly where drift hides; this is the coverage for it.
	///
	/// A real `copilot` binary is not required. The protocol is newline-framed
	/// JSON-RPC over stdin/stdout, so a script that answers each frame is a
	/// faithful enough peer to exercise the whole lifecycle — the same shape
	/// `MCPClientTests` uses for its fake MCP server. It reports its own pid so the
	/// *kernel*, not the script, is asked about the placement.
	@Suite("ACP spawn contract", .serialized, .timeLimit(.minutes(2)))
	struct ACPSpawnContractTests {

		/// A fake ACP peer: reports `pid=<n>` into `argv[1]`, then answers
		/// `initialize`, `session/new` and `session/prompt` with the request's own
		/// id. An unknown method is ignored, which is what a real server does with
		/// a notification it does not need to answer.
		///
		/// written in python3 for the same reason `MCPClientTests` writes its fake
		/// server there: JSON in, JSON out, and no shell quoting to get wrong.
		static func fakeServerScript() -> String {
			"""
			import json, os, sys

			NL = chr(10)
			state = sys.argv[1]
			with open(state, "w") as handle:
			    handle.write("pid=%d" % os.getpid() + NL)

			for raw in sys.stdin:
			    line = raw.strip()
			    if not line:
			        continue
			    try:
			        request = json.loads(line)
			    except ValueError:
			        continue
			    method = request.get("method")
			    identifier = request.get("id")
			    if method == "initialize":
			        result = {"protocolVersion": 1, "serverInfo": {"name": "fake-acp", "version": "0"}}
			    elif method == "session/new":
			        result = {"sessionId": "fake-session"}
			    elif method == "session/prompt":
			        result = {"message": {"content": [{"type": "text", "text": "pong"}]}, "stopReason": "stop"}
			    else:
			        continue
			    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "result": result}) + NL)
			    sys.stdout.flush()
			"""
		}

		/// The first executable named `name` on PATH.
		static func resolveExecutable(_ name: String) -> String? {
			let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
			for directory in searchPath.split(separator: ":") {
				let candidate = "\(directory)/\(name)"
				if FileManager.default.isExecutableFile(atPath: candidate) {
					return candidate
				}
			}
			return nil
		}

		@Test("a full ACP round trip, and the spawn contract it rides on")
		func roundTrip() async throws {
			let scratch = try SubprocessProbe.makeScratch("acp")
			defer { try? FileManager.default.removeItem(at: scratch) }

			let script = scratch.appendingPathComponent("fake_acp.py")
			try Self.fakeServerScript().write(to: script, atomically: true, encoding: .utf8)

			let statePath = scratch.appendingPathComponent("state").path
			// `ACPClient` takes the command as an ABSOLUTE path and never resolves
			// PATH — a real config names a binary. resolve one here so the spawn is
			// the only thing under test; a bare "python3" fails to exec, the rpc
			// wait never yields, and the failed spawn traps the bundle inside
			// SwiftSlash rather than throwing.
			let python = try #require(Self.resolveExecutable("python3"))
			let client = ACPClient(config: .init(command: python, args: [script.path, statePath]))

			// the only reachable entry point. `start()` returns `[String: Any]`,
			// which is not Sendable and so cannot cross the actor boundary at all —
			// its sole consumer is `asLLMClient()`, which calls it from inside the
			// actor. one `complete` therefore exercises the whole lifecycle:
			// initialize -> session/new -> session/prompt.
			let adapter = try await client.asLLMClient()
			let response = try await adapter.complete(
				messages: [Message(role: .user, content: "ping")],
				tools: nil
			)
			#expect(response.content == "pong", "the reply text must survive the adapter's reduction")
			#expect(response.finishReason == "stop")

			// the child leads its own group — `.own`, the placement arc asks for at
			// this site. asked of the kernel, not of the script.
			let report = try #require(await SubprocessProbe.waitForReport(statePath))
			let pid = try #require(Int32(report["pid"] ?? ""))
			#expect(getpgid(pid) == pid, "the ACP child must lead its own process group (pid \(pid))")

			await client.shutdown()

			// shutdown reaps: `run()` is awaited, so the pid is gone when it returns
			#expect(await SubprocessProbe.waitUntilGone(pid), "the ACP child must be gone after shutdown()")
		}

		@Test("a command that cannot exec is refused, not trapped")
		func refusesUnreachableCommand() async throws {
			// a bare name is what a mistyped config looks like. without the guard
			// this reaches SwiftSlash's spawn, which fails in a way that traps the
			// process — so the assertion is just that we get an error back and are
			// still running to see it.
			let client = ACPClient(config: .init(command: "python3"))
			do {
				_ = try await client.asLLMClient()
				Issue.record("a command that is not an absolute executable path must be refused")
			} catch {
				// expected: a value, not a trap
			}
		}
	}
}