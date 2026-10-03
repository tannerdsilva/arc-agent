import Foundation
import SwiftSlash
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - GitRunner
//
// A minimal bounded subprocess runner for the plugin's `git` calls,
// built directly on SwiftSlash (posix_spawn + async reaping + process
// group cancellation). This is the same execution model arc-agent uses
// in its own SubprocessRunner — ported here so the plugin stays
// independent of the host application.

enum GitRunner {

    /// Default byte cap per stream.
    static let captureCap = 8_000_000

    /// The built-in channel separator is a NUL: never produced by text
    /// output, so segment reconstruction is byte-exact.
    static let separator: [UInt8] = [0x00]

    static func run(
        _ args: [String],
        timeout: TimeInterval = 20
    ) async -> (stdout: Data, exitCode: Int32?) {
        var command = Command(absolutePath: Path("/usr/bin/git"), arguments: args)
        command.inheritCurrentEnvironment()
        let child = ChildProcess(command, dataChannels: [
            STDOUT_FILENO: .write(.toParentProcess(stream: .init(), separator: separator)),
            STDERR_FILENO: .write(.toParentProcess(stream: .init(), separator: separator)),
            STDIN_FILENO: .read(.fromNull),
        ])
        let drainOut = Task { await drain(child.stdout, cap: captureCap) }
        let drainErr = Task { await drain(child.stderr, cap: captureCap) }

        let exit = await runWithTimeout(child, timeout: timeout)

        let out = await drainOut.value
        _ = await drainErr.value

        let code: Int32?
        switch exit {
        case .code(let c): code = c
        case .signal: code = nil
        }
        return (out, code)
    }

    private enum RunSignal: Sendable {
        case exit(ChildProcess.Exit)
        case timeout
    }

    /// Race the child against the timeout; cancellation signals the
    /// child's whole process group, so no orphan survives.
    private static func runWithTimeout(
        _ child: ChildProcess,
        timeout: TimeInterval
    ) async -> ChildProcess.Exit {
        let first = await withTaskGroup(of: RunSignal.self) { group in
            group.addTask {
                do {
                    return .exit(try await child.run(cancellationSignal: SIGTERM))
                } catch is CancellationError {
                    return .exit(.signal(SIGTERM))
                } catch {
                    return .exit(.signal(SIGTERM))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timeout
            }
            let winner = await group.next() ?? .timeout
            group.cancelAll()
            _ = await group.next()
            return winner
        }
        switch first {
        case .exit(let exit): return exit
        case .timeout: return .signal(SIGTERM)
        }
    }

    private static func drain(
        _ stream: DataChannel.ChildWrite.ParentRead,
        cap: Int
    ) async -> Data {
        var collected = Data()
        for await chunk in stream {
            for (index, line) in chunk.enumerated() {
                if index > 0, collected.count < cap {
                    collected.append(separator[0])
                }
                if collected.count < cap {
                    collected.append(contentsOf: line)
                }
            }
        }
        return collected
    }
}
