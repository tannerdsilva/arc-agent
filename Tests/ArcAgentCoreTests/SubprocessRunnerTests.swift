import Foundation
import Testing
import SwiftSlash
@testable import ArcAgentCore

/// Tests for the SwiftSlash-backed subprocess runner (byte-exact capture,
/// bounded timeout + process-group kill, stdin payloads, capture caps).
@Suite("SubprocessRunner")
struct SubprocessRunnerTests {

    private func bash(_ script: String) -> Command {
        var cmd = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", script])
        cmd.inheritCurrentEnvironment()
        return cmd
    }

    @Test("runs a command and captures stdout byte-exactly")
    func basic() async throws {
        let out = try await SubprocessRunner.runBytes(bash("printf 'hello\\nworld\\n'"))
        #expect(String(data: out.stdout, encoding: .utf8) == "hello\nworld\n")
        #expect(out.exitCode == 0)
        #expect(!out.timedOut)
        #expect(!out.stdoutTruncated)
    }

    @Test("captures exit codes")
    func exitCode() async throws {
        let out = try await SubprocessRunner.runBytes(bash("exit 3"))
        #expect(out.exitCode == 3)
    }

    @Test("captures stderr separately")
    func stderr() async throws {
        let out = try await SubprocessRunner.runBytes(bash("echo oops >&2"))
        #expect(String(data: out.stderr, encoding: .utf8)?.contains("oops") == true)
    }

    @Test("timeout kills the process group and reports timedOut")
    func timeoutKills() async throws {
        let start = Date()
        let out = try await SubprocessRunner.runBytes(
            bash("sleep 5; echo never"), timeout: 1)
        #expect(out.timedOut)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(!String(data: out.stdout, encoding: .utf8)!.contains("never"))
    }

    @Test("large output does not deadlock (concurrent drain)")
    func largeOutput() async throws {
        let out = try await SubprocessRunner.runBytes(
            bash("for i in $(seq 1 50000); do echo line-$i; done"), timeout: 30)
        #expect(out.exitCode == 0)
        #expect(!out.timedOut)
        let text = String(data: out.stdout, encoding: .utf8)!
        #expect(text.hasSuffix("line-50000\n"))
        #expect(text.count > 200_000)
    }

    @Test("capture cap truncates while still collecting to completion")
    func captureCap() async throws {
        let out = try await SubprocessRunner.runBytes(
            bash("for i in $(seq 1 20000); do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done"),
            timeout: 30, captureCap: 10_000)
        #expect(out.stdoutTruncated)
        #expect(out.stdout.count <= 10_000)
        #expect(out.exitCode == 0)
    }

    @Test("stdin payload reaches the child (cat)")
    func stdinPayload() async throws {
        var cat = Command(absolutePath: Path("/usr/bin/env"), arguments: ["cat"])
        cat.inheritCurrentEnvironment()
        let out = try await SubprocessRunner.runBytes(cat, stdin: Array("payload-42".utf8))
        #expect(String(data: out.stdout, encoding: .utf8) == "payload-42")
        #expect(out.exitCode == 0)
    }

    @Test("spawn failure surfaces as an error")
    func spawnFailure() async throws {
        let cmd = Command(absolutePath: Path("/nonexistent/binary-xyz"), arguments: [])
        await #expect(throws: (any Error).self) {
            _ = try await SubprocessRunner.runBytes(cmd, timeout: 5)
        }
    }

    @Test("environment dict is passed verbatim (no implicit inheritance)")
    func envVerbatim() async throws {
        var envCmd = Command(absolutePath: Path("/usr/bin/env"), arguments: [])
        envCmd.environment = ["ARC_TEST_VAR": "42"]
        let out = try await SubprocessRunner.runBytes(envCmd)
        let text = String(data: out.stdout, encoding: .utf8) ?? ""
        #expect(text.contains("ARC_TEST_VAR=42"))
        // Parent env must not leak through: HOME is not set for the child.
        #expect(!text.contains("HOME="))
    }
}
