import Testing
@testable import ArcAgentCore
import Foundation

/// Web search provider registry tests (Hermes `web_search_registry.py` +
/// `web_search_provider.py` parity): config decoding, resolve semantics,
/// response normalization (no network).
@Suite("Web search providers", .serialized)
struct SearchProviderTests {

    struct MockProvider: SearchProvider {
        let name: String
        let available: Bool
        let results: [SearchResult]
        func isAvailable() -> Bool { available }
        func search(query: String, limit: Int) async throws -> [SearchResult] {
            Array(results.prefix(limit))
        }
    }

    @Test("config decodes web.search_backend and legacy web.backend")
    func configDecode() throws {
        let json = """
        {
          "web": {"search_backend": "tavily"},
          "model": {"provider": "openai"}
        }
        """
        let config = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
        #expect(config.web.searchBackend == "tavily")
        #expect(config.web.effectiveSearchBackend == "tavily")

        let legacy = """
        {"web": {"backend": "brave"}}
        """
        let config2 = try JSONDecoder().decode(ArcConfig.self, from: Data(legacy.utf8))
        #expect(config2.web.searchBackend == nil)
        #expect(config2.web.effectiveSearchBackend == "brave")
    }

    @Test("registry resolve: explicit match > first available; no provider errors clearly")
    func registryResolve() async {
        let registry = SearchRegistry.shared
        await registry.reset()

        let a = MockProvider(name: "alpha", available: true, results: [])
        let b = MockProvider(name: "brave-ish", available: false, results: [])
        await registry.register(a)
        await registry.register(b)

        await registry.configure(backend: "alpha")
        #expect(await registry.resolve()?.name == "alpha")

        // Unavailable configured provider is returned so the caller can report it.
        await registry.configure(backend: "brave-ish")
        #expect(await registry.resolve()?.name == "brave-ish")

        // Unknown configured name falls back to first available.
        await registry.configure(backend: "nope")
        #expect(await registry.resolve()?.name == "alpha")

        await registry.reset()
        #expect(await registry.resolve() == nil)

        do {
            _ = try await registry.perform(query: "q", limit: 3)
            Issue.record("expected noProviderConfigured")
        } catch let e as SearchError {
            #expect(e.description.contains("No web search provider"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        await registry.reset()
    }

    @Test("perform routes through the configured provider and returns its results")
    func performRoutes() async throws {
        let registry = SearchRegistry.shared
        await registry.reset()
        let canned = [SearchResult(title: "One", url: "https://example.com/1", description: "first", position: 0)]
        await registry.register(MockProvider(name: "canned", available: true, results: canned))
        await registry.configure(backend: "canned")
        let results = try await registry.perform(query: "x", limit: 5)
        #expect(results == canned)
        await registry.reset()
    }

    @Test("searxng json normalizes to the contract shape")
    func searxngParse() throws {
        let body = Data("""
        {"results": [{"url": "https://a.dev", "title": "A", "content": "about a"},
                     {"title": "no url"}, {"url": "https://b.dev", "title": "B", "content": "about b"}]}
        """.utf8)
        let results = try SearXNGSearchProvider.parseSearchJSON(body, endpoint: "x")
        #expect(results.count == 2)
        #expect(results[0].title == "A")
        #expect(results[0].position == 0)
        #expect(results[1].url == "https://b.dev")
        #expect(results[1].position == 1)
    }

    @Test("brave json normalizes web.results")
    func braveParse() throws {
        let body = Data("""
        {"web": {"results": [{"title": "T", "url": "https://t.dev", "description": "d"}]}}
        """.utf8)
        let results = try BraveSearchProvider.parseSearchJSON(body)
        #expect(results.count == 1)
        #expect(results[0].title == "T")
        #expect(results[0].description == "d")
    }

    @Test("tavily json normalizes results")
    func tavilyParse() throws {
        let body = Data("""
        {"results": [{"title": "X", "url": "https://x.dev", "content": "c"}]}
        """.utf8)
        let results = try TavilySearchProvider.parseSearchJSON(body)
        #expect(results.count == 1)
        #expect(results[0].url == "https://x.dev")
        #expect(results[0].description == "c")
    }

    @Test("duckduckgo html parse extracts results (best effort)")
    func ddgParse() throws {
        let html = """
        <html><body>
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com">Example &amp; Join</a>
        <a class="result__snippet">A domain for <b>examples</b>.</a>
        </body></html>
        """
        let results = try DuckDuckGoSearchProvider.parseSearchHTML(Data(html.utf8), limit: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "Example & Join")
        #expect(results[0].url == "https://example.com")
        #expect(results[0].description.contains("examples"))
    }
}
