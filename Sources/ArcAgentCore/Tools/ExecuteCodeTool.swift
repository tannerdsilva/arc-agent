import Foundation
import NIOCore
import NIO
import NIOPosix

/// The `execute_code` tool: run a Python script that calls arc tools
/// programmatically. Faithful port of Hermes `execute_code` (local backend).
///
/// Architecture: parent generates a `hermes_tools.py` stub, starts a loopback
/// TCP RPC listener, spawns `python3 script.py`, and tool calls travel over
/// the RPC socket back to the parent for dispatch. Only stdout returns to the
/// LLM; intermediate tool results never enter the context window.
public enum ExecuteCodeTool {

    static let defaultTimeoutSeconds: Double = 300
    static let maxToolCalls = 50
    static let maxStdoutBytes = 50_000

    static var timeoutSeconds: Double {
        if let override = timeoutOverride {
            return override
        }
        if let raw = ProcessInfo.processInfo.environment["ARC_EXECUTE_TIMEOUT"],
           let value = Double(raw), value > 0 {
            return value
        }
        return defaultTimeoutSeconds
    }

    /// Test hook: overrides the script timeout.
    static var timeoutOverride: Double?

    public static let entry = ToolEntry(
        name: "execute_code",
        toolset: "code_execution",
        description: "Run a Python script that calls arc tools programmatically. "
            + "Use when you need 3+ tool calls with logic between them: "
            + "filtering/reducing large outputs before they enter context, "
            + "conditional branching, or loops (N pages/files, retry on failure). "
            + "Use normal tool calls for single calls, results you must reason "
            + "over in full, or anything needing user interaction. "
            + "Available via `from hermes_tools import ...`: read_file, write_file, "
            + "patch, search_files, terminal, web_search, web_extract. "
            + "Limits: 5-minute timeout, 50KB stdout cap, max 50 tool calls per script. "
            + "terminal() is foreground-only (no background or pty). "
            + "Scripts run in the session's working directory with the active python. "
            + "Print your final result to stdout; stdlib (json, re, csv, datetime, ...) "
            + "is available for processing. Built-in helpers (no import): "
            + "json_parse(text) — tolerant json.loads for terminal() output; "
            + "shell_quote(s) — shlex.quote for dynamic shell args; "
            + "retry(fn, max_attempts=3, delay=2) — exponential backoff for transient failures.",
        schema: .object(properties: [
            "code": .string(description: "Python code to execute. Import tools with `from hermes_tools import ...` and print your final result to stdout."),
        ], required: ["code"]),
        handler: { args in
            let code: String = try Self.required(args, key: "code")
            return try await Self.execute(code: code)
        },
        emoji: "🐍"
    )

    // MARK: - Dispatcher (injected by the agent host)

    /// Actor holding the host tool-executor closure. Set once at startup by
    /// the agent (ArcAgent / AppState) so child Python processes can dispatch
    /// tools back into the SAME session.
    public actor Dispatcher {
        private var host: (@Sendable (String, [String: Any]) async throws -> String)?

        public func setHost(_ closure: @escaping @Sendable (String, [String: Any]) async throws -> String) {
            host = closure
        }

        /// Snapshot of the currently-registered host. Taken at the start of
        /// each execute run so the RPC server never observes a host that was
        /// swapped (or released) by a concurrent session mid-run.
        func currentHost() -> (@Sendable (String, [String: Any]) async throws -> String)? {
            host
        }
    }

    /// Per-script tool-call budget (max 50), scoped to a single execute run
    /// so concurrent scripts cannot cross-talk or exhaust each other.
    actor RunLimiter {
        private var remaining: Int
        init(budget: Int) {
            remaining = budget
        }
        func run(_ body: () async throws -> String) async throws -> String {
            guard remaining > 0 else {
                throw ToolError.execution("Tool-call budget exceeded (max \(ExecuteCodeTool.maxToolCalls) per script)")
            }
            remaining -= 1
            return try await body()
        }
        func callsMade() -> Int {
            ExecuteCodeTool.maxToolCalls - remaining
        }
    }

    public static let dispatcher = Dispatcher()

    // MARK: - Handler

    static func execute(code: String) async throws -> String {
        let start = Date()
        let limiter = RunLimiter(budget: maxToolCalls)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-execute-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let stubURL = tempDir.appendingPathComponent("hermes_tools.py")
            let scriptURL = tempDir.appendingPathComponent("script.py")
            let stub = Self.pythonStub(maxStdoutBytes: maxStdoutBytes)
            try stub.write(to: stubURL, atomically: true, encoding: .utf8)
            try code.write(to: scriptURL, atomically: true, encoding: .utf8)

            // 1) Snapshot the ambient host, then start the RPC server
            //    (loopback TCP, ephemeral port) bound to that snapshot.
            guard let host = await Self.dispatcher.currentHost() else {
                throw ToolError.execution(
                    "execute_code dispatcher not configured (host did not register a tool executor)")
            }
            let token = UUID().uuidString
            let (server, port) = try await ToolRPCServer.start(
                host: host, limiter: limiter, token: token)

            // 2) Spawn python3.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path]
            var env = ProcessInfo.processInfo.environment
            env["HERMES_TOOLS_RPC"] = "127.0.0.1:\(port)"
            env["HERMES_TOOLS_TOKEN"] = token
            env["PYTHONPATH"] = tempDir.path
            env["PYTHONIOENCODING"] = "utf-8"
            env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
            process.environment = env
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()

            // 3) Drain stdout/stderr concurrently (head/tail window cap).
            let (stdoutData, stderrData, timedOut) = try await drain(
                process: process, outPipe: outPipe, errPipe: errPipe,
                timeout: timeoutSeconds)

            let callsMade = await limiter.callsMade()

            let duration = Date().timeIntervalSince(start)
            var stdoutText = truncateHeadTail(stdoutData, cap: maxStdoutBytes)
            var stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            if stderrText.count > 10_000 {
                stderrText = String(stderrText.prefix(10_000)) + "\n... (stderr truncated)"
            }

            var result: [String: Any] = [
                "status": timedOut ? "timeout" : "success",
                "output": stdoutText,
                "exit_code": Int(process.terminationStatus),
                "tool_calls_made": callsMade,
                "duration_seconds": (duration * 100).rounded() / 100,
            ]

            if timedOut {
                let timeoutMsg = "Script timed out after \(Int(timeoutSeconds))s and was killed."
                result["error"] = timeoutMsg
                result["output"] = stdoutText.isEmpty
                    ? "⏰ \(timeoutMsg)"
                    : stdoutText + "\n\n⏰ \(timeoutMsg)"
            } else if process.terminationStatus != 0 {
                result["status"] = "error"
                result["error"] = stderrText.isEmpty
                    ? "Script exited with code \(process.terminationStatus)"
                    : stderrText
                result["output"] = stdoutText + "\n--- stderr ---\n" + stderrText
                if let hint = failureHint(stderr: stderrText) {
                    result["hint"] = hint
                }
            }

            await server.shutdown()
            cleanup(tempDir: tempDir)
            return try jsonString(result)
        } catch {
            let duration = Date().timeIntervalSince(start)
            cleanup(tempDir: tempDir)
            let result: [String: Any] = [
                "status": "error",
                "error": String(describing: error),
                "tool_calls_made": 0,
                "duration_seconds": (duration * 100).rounded() / 100,
            ]
            return try jsonString(result)
        }
    }

    // MARK: - Process drain + timeout (async-poll, no semaphores/threads)

    static func drain(
        process: Process, outPipe: Pipe, errPipe: Pipe, timeout: Double
    ) async throws -> (Data, Data, Bool) {
        let outTask = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            // brief grace for the pipe readers to finish
            try await Task.sleep(nanoseconds: 200_000_000)
            if process.isRunning {
                process.interrupt()
            }
        }
        let out = await outTask.value
        let err = await errTask.value
        return (out, err, timedOut)
    }

    /// Head/tail capture with explicit truncation metadata.
    static func truncateHeadTail(_ data: Data, cap: Int) -> String {
        guard data.count > cap else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        let headBytes = Int(Double(cap) * 0.4)
        let tailBytes = cap - headBytes
        let head = data.prefix(headBytes)
        let tail = data.suffix(tailBytes)
        let total = data.count
        let omitted = total - headBytes - tailBytes
        let headText = String(data: head, encoding: .utf8) ?? ""
        let tailText = String(data: tail, encoding: .utf8) ?? ""
        return headText
            + "\n\n... [OUTPUT TRUNCATED - \(omitted) bytes omitted out of \(total) total] ...\n\n"
            + tailText
    }

    static func failureHint(stderr: String) -> String? {
        if stderr.contains("ModuleNotFoundError: No module named 'hermes_tools'") {
            return "hermes_tools was not on PYTHONPATH — the stub module is generated in the script's temp dir; re-run without stdin override."
        }
        if stderr.contains("SyntaxError") {
            return "The script has a Python SyntaxError — check the indentation of the `code` parameter."
        }
        return nil
    }

    static func cleanup(tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }

    static func jsonString(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Python stub template (backslash-free: chr() where needed)

    static func pythonStub(maxStdoutBytes: Int) -> String {
        // Raw Swift string: {%BR%} markers replaced after transport to avoid
        // ANY backslash escaping ambiguity — see buildScript.
        let template = #"""
import json
import os as _os
import socket as _socket
import shlex as _shlex
import time as _time
import functools as _functools

_RPC = _os.environ.get("HERMES_TOOLS_RPC", "")
_TOKEN = _os.environ.get("HERMES_TOOLS_TOKEN", "")
_TOOLS = {"read_file", "write_file", "patch", "search_files", "terminal", "web_search", "web_extract"}

class ToolError(Exception):
    pass


def _call(tool, args):
    if tool not in _TOOLS:
        raise ToolError("tool not allowed inside execute_code: " + tool)
    host, port = _RPC.rsplit(":", 1)
    sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
    sock.settimeout(300)
    try:
        sock.connect((host, int(port)))
        payload = json.dumps({"tool": tool, "args": args, "token": _TOKEN}) + _chr10()
        sock.sendall(payload.encode("utf-8"))
        data = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
            if _chr10() in data.decode("utf-8", errors="ignore"):
                break
        resp = json.loads(data.decode("utf-8"))
        if resp.get("error"):
            raise ToolError(resp["error"])
        return resp.get("result", "")
    finally:
        sock.close()


def read_file(path, offset=1, limit=2000):
    return _call("read_file", {"path": path, "offset": offset, "limit": limit})


def write_file(path, content):
    return _call("write_file", {"path": path, "content": content})


def patch(path=None, old_string=None, new_string=None, replace_all=False, mode="replace", patch=None):
    args = {"mode": mode}
    if mode == "patch":
        args["patch"] = patch
    else:
        args["path"] = path
        args["old_string"] = old_string
        args["new_string"] = new_string
        args["replace_all"] = replace_all
    return _call("patch", args)


def search_files(pattern, target="content", path=".", file_glob=None, limit=50, offset=0, output_mode="content", context=0):
    return _call("search_files", {
        "pattern": pattern, "target": target, "path": path,
        "file_glob": file_glob, "limit": limit, "offset": offset,
        "output_mode": output_mode, "context": context,
    })


def terminal(command, timeout=120):
    return _call("terminal", {"command": command, "timeout": timeout})


def web_search(query, num_results=8):
    return _call("web_search", {"query": query, "num_results": num_results})


def web_extract(url, query=None):
    return _call("web_extract", {"url": url, "query": query})


def json_parse(text):
    import re as _re
    text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(text[start:end + 1])
        except Exception:
            pass
    raise ValueError("could not parse JSON from: " + text[:200])


def shell_quote(s):
    return _shlex.quote(s)


def retry(fn, max_attempts=3, delay=2):
    @_functools.wraps(fn)
    def wrapper(*a, **kw):
        last = None
        for attempt in range(max_attempts):
            try:
                return fn(*a, **kw)
            except Exception as e:
                last = e
                if attempt < max_attempts - 1:
                    _time.sleep(delay)
        raise last
    return wrapper


def _chr10():
    return chr(10)
"""#
        return template
    }
}
