import Foundation
import Testing

/// the `AsyncHTTPClient` teardown contract.
///
/// The dependency traps in its deinit when a client was never shut down
/// (`Fatal error: Client not shut down before the deinit`), and that trap is what
/// a Ctrl-C on `arc serve` hits: the daemon's teardown releases the whole UI
/// object graph while the process is still alive. Nothing at runtime catches the
/// mistake, so these tests scan the sources — the same house pattern as
/// `StreamingDomContractTests` and `ClickIdentityContractTests`, including a
/// self-check that pins the scanners themselves.
@Suite("HTTP client teardown contract")
struct HTTPClientTeardownContractTests {

    private static func source(at path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Source text with comments removed — the house scanners read code, not
    /// prose. A doc comment that *quotes* a shape (this suite's rule,
    /// `OneShotHTTPClient`'s rationale) must not trip the scan.
    static func stripComments(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    return ""
                }
                guard let cut = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<cut.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// The rule: cleanup deferred into an unstructured task cannot run before the
    /// caller returns, so the client can still be deinitialized open.
    static func isDeferredShutdown(_ line: String) -> Bool {
        line.contains("defer { Task {") && line.lowercased().contains("shutdown")
    }

    /// every Swift file under `root`, relative to the package directory.
    private static func swiftFiles(under root: String) -> [String] {
        guard let walk = FileManager.default.enumerator(atPath: root) else { return [] }
        return walk.compactMap { entry in
            guard let entry = entry as? String, entry.hasSuffix(".swift") else { return nil }
            return "\(root)/\(entry)"
        }
    }

    private static func code(at path: String) -> String {
        stripComments(source(at: path))
    }

    @Test("the scanners bite")
    func scannerSelfCheck() {
        let offending = "        defer { Task { try? await client.shutdown() } }"
        let benign = "        defer { Task { try? await client.logout() } }"
        let prose = "/// a `defer { Task { try? await client.shutdown() } }` does not fix it"
        #expect(Self.isDeferredShutdown(offending),
                "the deferred-shutdown rule must match the shape it bans")
        #expect(!Self.isDeferredShutdown(benign),
                "an unrelated client's deferred cleanup is not this rule's business")
        #expect(!Self.stripComments(prose).contains("defer { Task {"),
                "prose that quotes the shape must be stripped before the scan")
    }

    @Test("the app state owns a teardown that shuts its client down")
    func appStateOwnsItsTeardown() {
        let app = Self.source(at: "Sources/ArcWebUI/AppState.swift")
        #expect(app.contains("func shutdown() async"),
                "AppState must expose the teardown its host calls")
        #expect(app.contains("client.shutdown()"),
                "AppState.shutdown() must shut the HTTP client down, not just drop it")
    }

    @Test("the web UI host releases the app on every exit path")
    func hostReleasesTheApp() {
        let host = Self.source(at: "Sources/ArcWebUI/WebUIHost.swift")
        let sites = host.components(separatedBy: "await app.shutdown()").count - 1
        #expect(sites >= 2,
                """
                WebUIHost.run() must release the app on the expected-cancellation \
                path and in an unexpected-error catch (found \(sites))
                """)
    }

    @Test("no client shutdown is deferred into an unstructured task")
    func noDeferredShutdown() {
        var offenders: [String] = []
        for file in Self.swiftFiles(under: "Sources") {
            for line in Self.code(at: file).split(separator: "\n")
            where Self.isDeferredShutdown(String(line)) {
                offenders.append(file)
            }
        }
        #expect(offenders.isEmpty,
                """
                a `defer { Task { … } }` cannot await a shutdown before the caller \
                returns — use withOneShotHTTPClient: \(offenders.sorted())
                """)
    }

    @Test("every client constructor has a shutdown beside it")
    func constructorsHaveAHome() {
        let constructors = Self.swiftFiles(under: "Sources").filter {
            Self.code(at: $0).contains("HTTPClient(eventLoopGroupProvider")
        }
        #expect(!constructors.isEmpty,
                "the scan found no client constructors — has the source root moved?")
        let unowned = constructors.filter { !Self.code(at: $0).lowercased().contains("shutdown") }
        #expect(unowned.isEmpty,
                "these files construct an AsyncHTTPClient but never mention shutting one down: \(unowned.sorted())")
    }
}