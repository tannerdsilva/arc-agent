import Foundation
import Testing
@testable import ArcAgentCore

extension ArcCoreTestRoot {

	/// I1's behavioural half — no detached processes, ever.
	///
	/// The refusal is absolute: it has no override flag, no configuration, and it
	/// fires identically on the foreground path and the `background=true` path.
	/// These tests pin both the policy matrix and the tool-level integration,
	/// including the syntaxes that merely *contain* the same characters and must
	/// stay allowed.
	@Suite("Detachment policy", .serialized)
	struct DetachmentPolicyTests {

		// MARK: - refused

		/// every simple command is inspected, not just the first word, and the
		/// scan follows the shell into command substitutions and `sh -c` strings.
		@Test("detachment wrappers are refused wherever a command appears", arguments: [
			"setsid sleep 5",
			"nohup ./run.sh",
			"disown %1",
			"env FOO=1 setsid x",
			"sudo setsid x",
			"cmd; setsid x",
			"a && nohup b",
			"make | setsid c",
			"echo $(nohup x)",
			"`setsid y`",
			"sh -c 'setsid z'",
			"bash -c 'nohup w'",
			"make > build.log; nohup make install",
			"/usr/bin/setsid sleep 5",
		])
		func refusesWrappers(_ command: String) throws {
			let refusal = try #require(DetachmentPolicy.refusal(for: command),
				"expected a refusal for: \(command)")
			// the refusal names the reason and the tracked alternative — never a bypass.
			#expect(refusal.contains("background=true"))
		}

		/// a bare `&` backgrounds the process outside arc's tree, so it is a
		/// detachment on its own, wherever it appears at the top level.
		@Test("a bare & is refused as a detachment", arguments: [
			"sleep 5 &",
			"a & b",
			"make -j8 &",
		])
		func refusesBackgrounding(_ command: String) {
			#expect(DetachmentPolicy.refusal(for: command) != nil)
		}

		// MARK: - allowed

		/// the syntaxes that merely look like detachments: quoting makes them
		/// literal, and `&&` / `|&` / `&>` / `>&` are not backgrounding.
		@Test("ordinary shell syntax that only resembles detachment is allowed", arguments: [
			"echo 'a & b'",
			"echo \"x; setsid y\"",
			"make 2>&1 | tail",
			"cmd &> log",
			"a |& b",
			"a && b",
			"grep -n 'nohup' README.md",
			"echo done",
			"swift build",
		])
		func allowsOrdinarySyntax(_ command: String) {
			#expect(DetachmentPolicy.refusal(for: command) == nil)
		}

		// MARK: - the tool

		/// the policy is a check inside the existing tool, applied before the
		/// foreground spawn.
		@Test("the terminal tool refuses detachment on the foreground path")
		func toolRefusesForeground() async throws {
			let result = try await TerminalTool.entry.handler(["command": "setsid sleep 5"])
			#expect(result.hasPrefix("Error: Refused:"))
			#expect(result.contains("background=true"))
		}

		/// ...and identically on the tracked path: a job that detaches outlives
		/// arc's tracking just as surely as a foreground one escapes it.
		@Test("the terminal tool refuses detachment on the background path too")
		func toolRefusesBackground() async throws {
			let wrapper = try await TerminalTool.entry.handler([
				"command": "nohup ./run.sh",
				"background": true,
			])
			#expect(wrapper.hasPrefix("Error: Refused:"))

			let ampersand = try await TerminalTool.entry.handler([
				"command": "sleep 5 &",
				"background": true,
			])
			#expect(ampersand.hasPrefix("Error: Refused:"))
		}
	}
}