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
    /// Tests for the SwiftSlash-backed subprocess runner (byte-exact capture,
    /// bounded timeout + process-group kill, stdin payloads, capture caps).
    @Suite("SubprocessRunner", .serialized)
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

        // MARK: - process-group placement (the SwiftSlash 6 spawn contract)

        /// every arc spawn site asks for `.own`, so a child leads its own process
        /// group: one group signal tears down the child's whole tree and never
        /// touches arc's own group. The session check is the observational half
        /// of "no detached processes" — a `.detached` child leads its own
        /// session, and nothing arc starts may do that.
        @Test("a child arc spawns leads its own group and stays in arc's session")
        func childLeadsItsOwnGroup() async throws {
            let scratch = try SubprocessProbe.makeScratch("placement")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let pidFile = scratch.appendingPathComponent("child.pid").path

            let run = Task {
                try await SubprocessRunner.runBytes(
                    bash("echo $$ > '\(pidFile)'; exec sleep 30"), timeout: 20)
            }
            let pid = try #require(await SubprocessProbe.waitForPID(pidFile))

            // read the placement while the child is still alive.
            #expect(getpgid(pid) == pid)        // leads its own group
            #expect(getpgid(pid) != getpgid(0)) // ...not this process's
            #expect(getsid(pid) == getsid(0))   // same session: nothing detached

            run.cancel()
            _ = try? await run.value
            #expect(await SubprocessProbe.waitUntilGone(pid))
        }

        /// cancellation signals the child's *group*, so a backgrounded
        /// descendant of an `sh -c` orchestration goes with it. This is the
        /// shape that produced the original orphan: a timed-out invoke left
        /// `swift-package-tool overview` and its `swift build` compiling.
        @Test("the timeout's group signal reaches a child's whole tree")
        func timeoutReachesTheTree() async throws {
            let scratch = try SubprocessProbe.makeScratch("tree")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let grandchildFile = scratch.appendingPathComponent("gc.pid").path

            let out = try await SubprocessRunner.runBytes(
                bash("sleep 30 & echo $! > '\(grandchildFile)'; wait"), timeout: 1)
            #expect(out.timedOut)

            let grandchild = try #require(SubprocessProbe.readPID(grandchildFile))
            #expect(await SubprocessProbe.waitUntilGone(grandchild))
        }

        /// the boundary the terminal tool's refusal closes (see
        /// `DetachmentPolicy`). A shell that exits on its own leaves its
        /// backgrounded grandchild running: arc signals nothing on the normal
        /// path because there is no teardown to make, so the survivor stays —
        /// inside the group arc gave the shell. `&` is refused before the shell
        /// ever runs rather than relying on a cleanup that cannot happen.
        @Test("a backgrounded grandchild outlives a shell that exits normally")
        func backgroundedGrandchildOutlivesAnExitingShell() async throws {
            let scratch = try SubprocessProbe.makeScratch("boundary")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let grandchildFile = scratch.appendingPathComponent("gc.pid").path

            let out = try await SubprocessRunner.runBytes(
                bash("sleep 30 & echo $! > '\(grandchildFile)'; exit 0"), timeout: 5)
            #expect(!out.timedOut)      // the shell left on its own
            #expect(out.exitCode == 0)

            let grandchild = try #require(SubprocessProbe.readPID(grandchildFile))
            defer {
                let pgid = getpgid(grandchild)
                if pgid > 0 { SubprocessProbe.signalGroup(pgid, SIGKILL) }
                _ = kill(grandchild, SIGKILL)
            }

            #expect(!SubprocessProbe.isGone(grandchild))  // still running
            #expect(getpgid(grandchild) != grandchild)    // leads no group of its own
        }
    }
}
