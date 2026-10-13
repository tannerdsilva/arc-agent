import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Browser cloud providers (reference `plugins/browser/<name>/provider.py`)

@Suite("Browser cloud providers", .serialized)
struct BrowserCloudTests {

    @Test("availability checks env vars")
    func availability() async {
        unsetenv("BROWSERBASE_API_KEY"); unsetenv("BROWSERBASE_PROJECT_ID")
        #expect(!(await BrowserbaseSessionProvider().isAvailable()))
        setenv("BROWSERBASE_API_KEY", "k", 1); setenv("BROWSERBASE_PROJECT_ID", "p", 1)
        #expect(await BrowserbaseSessionProvider().isAvailable())
        unsetenv("BROWSERBASE_API_KEY"); unsetenv("BROWSERBASE_PROJECT_ID")
        unsetenv("BROWSER_USE_API_KEY"); unsetenv("FIRECRAWL_API_KEY")
        #expect(!(await BrowserUseSessionProvider().isAvailable()))
        #expect(!(await FirecrawlSessionProvider().isAvailable()))
    }

    @Test("createSession hits the reference endpoints (mock server)")
    func referenceEndpoints() async throws {
        // Mock server recording requests.
        let mock = try MockBrowserServer()
        let logURL = mock.logURL
        setenv("BROWSERBASE_BASE_URL", mock.baseURL, 1)
        setenv("BROWSERBASE_API_KEY", "bb-key", 1)
        setenv("BROWSERBASE_PROJECT_ID", "proj-1", 1)
        setenv("BROWSER_USE_BASE_URL", mock.baseURL + "/api/v3", 1)
        setenv("BROWSER_USE_API_KEY", "bu-key", 1)
        setenv("FIRECRAWL_API_URL", mock.baseURL, 1)
        setenv("FIRECRAWL_API_KEY", "fc-key", 1)

        // Browserbase: POST /v1/sessions with X-BB-API-Key + projectId.
        let bb = try await BrowserCloudCoordinator.shared.connect(providerName: "browserbase", taskID: "sess-1")
        #expect(bb.contains("ws://mock/bb-cdp"))

        // Browser Use: POST /api/v3/browsers with X-Browser-Use-API-Key.
        let bu = try await BrowserUseSessionProvider().createSession(taskID: "sess-2")
        #expect(bu.cdpURL.contains("bu-cdp"))

        // Firecrawl: POST /v2/browser with Bearer auth + ttl.
        let fc = try await FirecrawlSessionProvider().createSession(taskID: "sess-3")
        #expect(fc.cdpURL.contains("fc-cdp"))

        // Close: DELETE endpoints.
        _ = try await BrowserbaseSessionProvider().closeSession(sessionID: "bb-1")

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("POST /v1/sessions"))
        #expect(log.contains("X-BB-API-Key"))
        #expect(log.contains("proj-1"))
        #expect(log.contains("POST /api/v3/browsers"))
        #expect(log.contains("X-Browser-Use-API-Key"))
        #expect(log.contains("POST /v2/browser"))
        #expect(log.contains("Bearer"))
        #expect(log.contains("DELETE /v1/sessions/bb-1"))

        _ = await BrowserCloudCoordinator.shared.close()
        unsetenv("BROWSERBASE_API_KEY"); unsetenv("BROWSERBASE_PROJECT_ID")
        unsetenv("BROWSER_USE_API_KEY"); unsetenv("FIRECRAWL_API_KEY")
    }

    @Test("unknown provider errors clearly")
    func unknownProvider() async {
        do {
            _ = try await BrowserCloudCoordinator.shared.connect(providerName: "nope")
            Issue.record("expected throw")
        } catch {
            #expect("\(error)".contains("Unknown browser provider"))
        }
    }
}

/// Minimal HTTP mock: records method/path/headers to a log file and answers
/// with the reference-ish session payloads per route.
final class MockBrowserServer {
    let port = 9909
    let logURL: URL
    var baseURL: String { "http://127.0.0.1:\(port)" }
    private var process: Process?

    init() throws {
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("arc-browser-mock-\(UUID().uuidString).log")
        let script = """
        import http.server, json, sys
        LOG = "\(logURL.path)"
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _record(self, body):
                with open(LOG, "a") as f:
                    f.write(self.command + " " + self.path + " " + json.dumps({k: v for k, v in self.headers.items()}) + " " + (body or "") + "\\n")
            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
                self._record(body)
                if self.path == "/v1/sessions":
                    out = {"id": "bb-1", "connectUrl": "ws://mock/bb-cdp"}
                elif self.path.startswith("/api/v3/browsers"):
                    out = {"id": "bu-1", "cdpUrl": "ws://mock/bu-cdp"}
                elif self.path == "/v2/browser":
                    out = {"id": "fc-1", "cdpUrl": "ws://mock/fc-cdp"}
                else:
                    out = {"id": "x"}
                data = json.dumps(out).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data))); self.end_headers()
                self.wfile.write(data)
            def do_DELETE(self):
                self._record("")
                self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers()
                self.wfile.write(b"{}")
            def do_GET(self):
                self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers()
                self.wfile.write(b"ok")
        http.server.HTTPServer(("127.0.0.1", \(port)), H).serve_forever()
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("arc-browser-mock-\(UUID().uuidString).py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-u", scriptURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        // Wait for the server to accept connections.
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/__ping")!), !data.isEmpty { break }
            usleep(100_000)
        }
    }

    deinit {
        process?.terminate()
    }
}
