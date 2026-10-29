import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared probes for the subprocess suites.
///
/// Liveness, process-group placement and session membership are asserted
/// **in-process** (`kill`, `getpgid`, `getsid`), never through `ps`/`pgrep`, so
/// macOS and Linux agree and the assertions can live in the shipped suite.
enum SubprocessProbe {

	/// A fresh per-test scratch directory (removed by the caller).
	static func makeScratch(_ label: String) throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("arc-subprocess-\(label)-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// Reads a single positive pid from a marker file, or nil if it is absent or
	/// not yet written.
	static func readPID(_ path: String) -> Int32? {
		guard let text = try? String(contentsOfFile: path, encoding: .utf8),
		      let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
		      value > 0
		else {
			return nil
		}
		return value
	}

	/// Polls for a marker file to appear (bounded), so a caller can observe a
	/// child while it is still alive.
	static func waitForPID(_ path: String, within bound: Duration = .seconds(5)) async -> Int32? {
		let deadline = ContinuousClock.now + bound
		while ContinuousClock.now < deadline {
			if let value = readPID(path) {
				return value
			}
			try? await Task.sleep(for: .milliseconds(20))
		}
		return nil
	}

	/// Reads a `key=value` report written by a fixture.
	static func readReport(_ path: String) throws -> [String: String] {
		let text = try String(contentsOfFile: path, encoding: .utf8)
		var report: [String: String] = [:]
		for line in text.split(separator: "\n") {
			guard let separator = line.firstIndex(of: "=") else { continue }
			report[String(line[..<separator])] = String(line[line.index(after: separator)...])
		}
		return report
	}

	/// Polls for a fixture report to appear (bounded).
	static func waitForReport(_ path: String, within bound: Duration = .seconds(10)) async -> [String: String]? {
		let deadline = ContinuousClock.now + bound
		while ContinuousClock.now < deadline {
			if let report = try? readReport(path) {
				return report
			}
			try? await Task.sleep(for: .milliseconds(20))
		}
		return nil
	}

	/// Whether a pid is gone. The probe is per-pid on purpose: a wildcard
	/// `waitpid(-1, …)` would steal the launch's own reap.
	static func isGone(_ pid: Int32) -> Bool {
		kill(pid, 0) == -1 && errno == ESRCH
	}

	/// Polls for a pid to disappear (bounded) — a signalled process may need a
	/// moment to be reaped after its owner returns.
	static func waitUntilGone(_ pid: Int32, within bound: Duration = .seconds(3)) async -> Bool {
		let deadline = ContinuousClock.now + bound
		while ContinuousClock.now < deadline {
			if isGone(pid) { return true }
			try? await Task.sleep(for: .milliseconds(20))
		}
		return isGone(pid)
	}

	/// Sends one signal to a process group.
	static func signalGroup(_ pgid: Int32, _ signal: Int32) {
		_ = kill(-pgid, signal)
	}

	/// Locates the built `ArcSubprocessFixture` binary. `swift build` must have
	/// run first (the test target does not build the executable itself).
	static func fixturePath() throws -> String {
		let source = URL(fileURLWithPath: #filePath)
		let repoRoot = source
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let candidates = ["debug", "arm64-apple-macosx/debug", "out/Products/Debug"]
			.map { repoRoot.appendingPathComponent(".build/\($0)/ArcSubprocessFixture") }
		for path in candidates where FileManager.default.fileExists(atPath: path.path) {
			return path.path
		}
		throw SubprocessProbeError.fixtureMissing
	}

	enum SubprocessProbeError: Error { case fixtureMissing }
}