import Foundation
import Testing
import WebUI
import WebUIServer

@testable import ArcWebUI

// MARK: - harness

/// A real `WebUIServer` carrying the host's own page route. The assertion is
/// made against the bytes a browser receives, not a hand-rendered document, so
/// the page builder, the server config and the wire are all in the check.
private struct PageBudgetHarness {
    let port: Int
    let server: WebUIServer
    let run: Task<Void, Error>
    /// the config the server was built with — the one value the page reads.
    let config: WebUIServerConfig

    func page() async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "GET / answered \(status)")
        return String(decoding: data, as: UTF8.self)
    }

    func stop() async {
        await server.stop()
        run.cancel()
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        _ = await waitUntilServingPage(timeout: 5) {
            do {
                _ = try await URLSession(configuration: .ephemeral).data(from: url)
                return false
            } catch {
                return true
            }
        }
    }

    /// The parsed `webui-config` meta: the boot glue's whole view of the
    /// runtime, read the way the engine reads it (attribute-unescaped json).
    static func meta(inPage page: String) -> [String: Any]? {
        guard let name = page.range(of: "name=\"webui-config\"") else { return nil }
        let rest = page[name.upperBound...]
        guard let open = rest.range(of: "content=\"") else { return nil }
        let tail = rest[open.upperBound...]
        guard let close = tail.range(of: "\">") else { return nil }
        let escaped = String(tail[..<close.lowerBound])
        let json = escaped
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

/// boot the harness on a free port, run `body`, and always stop the server.
private func withPageBudgetServer(
    budget: Int,
    _ body: (PageBudgetHarness) async throws -> Void
) async throws {
    var harness: PageBudgetHarness?
    for _ in 0..<8 {
        let port = Int.random(in: 20000..<40000)
        // the config arc runs, with the one field under test moved off its
        // default: a page that restated 256 KiB would pass at the default and
        // prove nothing about where the number comes from.
        var config = WebUIHost.serverConfig(host: "127.0.0.1", port: port)
        config.maxFrameSize = budget
        // the `@Sendable` page closure below takes a value, not the mutable var
        // it was built from.
        let serverConfig = config
        let router = Router {
            WorkspaceUpload.pageRoute("/", tokens: UploadTokenStore()) { _, token in
                // the production page seam: the same call `run()` makes.
                WebUIHost.pageDocument(
                    config: serverConfig,
                    sheetURL: "/ui/style.css",
                    overlayURL: "/ui/init.js",
                    renderToken: token
                )(
                    UnsafeMarkup.trusted("<p id=\"budget-probe\">frame budget harness</p>"),
                    "data-scheme=\"poseidon\" data-theme=\"dark\""
                )
            }
        }
        let server = WebUIServer(router: router, config: serverConfig)
        let run = Task { try await server.start() }
        if await waitUntilServingPage(timeout: 3, { (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/")!)) != nil }) {
            harness = PageBudgetHarness(port: port, server: server, run: run, config: serverConfig)
            break
        }
        await server.stop()
        run.cancel()
    }
    guard let harness else { throw PageBudgetHarnessError.couldNotBind }
    do {
        try await body(harness)
    } catch {
        await harness.stop()
        throw error
    }
    await harness.stop()
}

private enum PageBudgetHarnessError: Error {
    case couldNotBind
}

/// poll an async condition until it holds or the deadline passes.
private func waitUntilServingPage(
    timeout: TimeInterval,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return await condition()
}

// MARK: - tests

extension ArcWebUITestRoot {
    /// Section D's publish half: the frame budget lives on the server config,
    /// and the page must carry the same number so the engine can refuse an
    /// over-budget frame before the socket answers it with a 1009 close.
    ///
    /// The failure this pins: a page whose `webui-config` meta carries no
    /// budget (or a stale literal) lets the client build a frame the server
    /// will kill the connection for. Read from the served markup, not from the
    /// builder's arguments, so a host that stops threading the config is red.
    @Suite("page frame budget", .serialized)
    struct PageFrameBudgetTests {

        @Test("the served page publishes the frame budget the server enforces")
        func servedPagePublishesTheFrameBudget() async throws {
            // not the default: the page must read the config, not restate 256 KiB.
            let budget = 96 * 1024
            try await withPageBudgetServer(budget: budget) { harness in
                let page = try await harness.page()
                let meta = try #require(
                    PageBudgetHarness.meta(inPage: page),
                    "the served page carried no parseable webui-config meta"
                )
                let published = try #require(
                    meta["maxFrameBytes"] as? Int,
                    "the served page's webui-config meta carried no maxFrameBytes: \(meta)"
                )
                #expect(
                    published == harness.config.maxFrameSize,
                    "the page published \(published) but the server enforces \(harness.config.maxFrameSize)"
                )
                #expect(
                    published == budget,
                    "the page published \(published), not the configured \(budget)"
                )
            }
        }

        /// The budget must not depend on a token being present: an upload-less
        /// page still needs the refusal, and a page rendered without a token is
        /// the case where the meta used to be `{}`.
        @Test("the budget is published even without a render token")
        func budgetIsPublishedWithoutAToken() {
            let page = AppShell.makeDocument(
                sheetURL: "/ui/style.css",
                overlayURL: "/ui/init.js",
                maxFrameBytes: 131_072
            )(
                UnsafeMarkup.trusted("<p>probe</p>"),
                "data-scheme=\"poseidon\" data-theme=\"dark\""
            ).markup.html
            let meta = PageBudgetHarness.meta(inPage: page)
            #expect(meta?["maxFrameBytes"] as? Int == 131_072, "the budget was dropped without a token")
            #expect(meta?["renderToken"] == nil, "a page rendered without a token carried one")
        }
    }
}
