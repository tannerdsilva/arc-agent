//
//  ArcSubprocessFixture.swift
//  ArcSubprocessFixture
//
//  test-only fixture: observes process-group placement from *inside a launch*,
//  which is the only place arc's explicit `.own` changes anything.
//
//  arc asks every spawn site for `.own`, so the group of the child it starts is
//  the group arc can tear down with one signal — even when arc is itself a
//  launch child, where the automatic default would put that child into the
//  *enclosing* group and downgrade arc's teardown to a pid-only kill. from a
//  top-level test process both rules look identical (the default is already
//  `.own` there), so the difference is only visible from a process that a
//  launch started. this fixture is that process.
//
//  it also proves the other half of the cascade: a program spawned from inside
//  a launch by *plain* SwiftSlash (no placement argument — the shape a nested
//  SwiftSlash program has, such as swift-mcp's subprocess transport) joins the
//  group it was started into instead of escaping into a second one.
//
//  usage:
//    ArcSubprocessFixture placement <marker>
//      spawn through arc's SubprocessRunner, record the placement arc's spawn
//      contract produced, then cancel the run.
//    ArcSubprocessFixture cascade <marker>
//      spawn through plain SwiftSlash (no placement argument) and hold open, so
//      an owner can inspect the tree and then signal the group it owns.
//
//  the fixture writes `key=value` lines to <marker>; the suite reads them.
//

import Foundation
import SwiftSlash
import ArcAgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct ArcSubprocessFixture {
	static func main() async {
		let arguments = CommandLine.arguments
		guard arguments.count >= 3 else {
			fail("usage: ArcSubprocessFixture <placement|cascade> <marker>")
		}
		let mode = arguments[1]
		let marker = arguments[2]

		var report: [String: String] = [
			"fixturepid": String(getpid()),
			"fixturepgid": String(getpgid(0)),
			"fixturesid": String(getsid(0)),
			"launch": CurrentEnvironment.launchIdentity() == nil ? "nil" : "present",
			"mode": mode,
		]

		switch mode {
		case "placement":
			await placement(marker: marker, report: &report)
		case "cascade":
			await cascade(marker: marker, report: &report)
		default:
			report["error"] = "unknown mode \(mode)"
			write(report, to: marker)
			exit(2)
		}
	}

	/// spawn one child through arc's own runner and report the placement that
	/// runner's spawn contract produced for it.
	private static func placement(marker: String, report: inout [String: String]) async {
		let pidFile = marker + ".c"
		var command = Command(
			absolutePath: Path("/bin/sh"),
			arguments: ["-c", "echo $$ > '\(pidFile)'; exec sleep 30"])
		command.inheritCurrentEnvironment()

		let run = Task { try? await SubprocessRunner.runBytes(command, timeout: 20) }

		let childPID = await waitForPID(in: pidFile, within: .seconds(5))
		report["childpid"] = String(childPID)
		if childPID > 0 {
			report["childpgid"] = String(getpgid(childPID))
			report["childsid"] = String(getsid(childPID))
		}

		// cancel the run: arc's cancellation signals the group it owns, so the
		// fixture leaves nothing behind.
		run.cancel()
		_ = await run.value
		if childPID > 0, kill(childPID, 0) == 0 {
			report["afterCancelAlive"] = "1"
			_ = kill(childPID, SIGKILL)
		} else {
			report["afterCancelAlive"] = "0"
		}
		write(report, to: marker)
		exit(0)
	}

	/// spawn through plain SwiftSlash — no placement argument, so the enclosing
	/// launch decides — and hold open until the owner signals the group.
	private static func cascade(marker: String, report: inout [String: String]) async {
		let gcFile = marker + ".gc"
		var command = Command(
			absolutePath: Path("/bin/sh"),
			arguments: ["-c", "sleep 30 & echo $! > '\(gcFile)'; wait"])
		command.inheritCurrentEnvironment()

		let child = ChildProcess(command, dataChannels: [
			STDIN_FILENO: .read(.fromNull),
			STDOUT_FILENO: .write(.toNull),
			STDERR_FILENO: .write(.toNull),
		])
		let run = Task { try? await child.run(cancellationSignal: SIGTERM) }

		let shellPID = await waitForRunning(child, within: .seconds(5))
		let grandchildPID = await waitForPID(in: gcFile, within: .seconds(5))
		report["shellpid"] = String(shellPID)
		report["gcpid"] = String(grandchildPID)
		if shellPID > 0 {
			report["shellpgid"] = String(getpgid(shellPID))
			report["shellsid"] = String(getsid(shellPID))
		}
		if grandchildPID > 0 {
			report["gcpgid"] = String(getpgid(grandchildPID))
			report["gcsid"] = String(getsid(grandchildPID))
		}
		write(report, to: marker)

		// hold the tree open: the owner inspects it, then signals one group.
		// the run task doubles as the reaper when that signal arrives.
		_ = await run.value
		exit(0)
	}

	// MARK: - helpers

	private static func waitForPID(in path: String, within bound: Duration) async -> Int32 {
		let deadline = ContinuousClock.now + bound
		while ContinuousClock.now < deadline {
			if let text = try? String(contentsOfFile: path, encoding: .utf8),
			   let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
			   value > 0 {
				return value
			}
			try? await Task.sleep(for: .milliseconds(20))
		}
		return -1
	}

	private static func waitForRunning(_ child: ChildProcess, within bound: Duration) async -> Int32 {
		let deadline = ContinuousClock.now + bound
		while ContinuousClock.now < deadline {
			if case .running(let pid) = await child.state {
				return pid
			}
			try? await Task.sleep(for: .milliseconds(20))
		}
		return -1
	}

	private static func write(_ report: [String: String], to path: String) {
		let text = report.keys.sorted().map { "\($0)=\(report[$0]!)" }.joined(separator: "\n") + "\n"
		try? text.write(toFile: path, atomically: true, encoding: .utf8)
	}

	private static func fail(_ message: String) -> Never {
		FileHandle.standardError.write(Data((message + "\n").utf8))
		exit(2)
	}
}