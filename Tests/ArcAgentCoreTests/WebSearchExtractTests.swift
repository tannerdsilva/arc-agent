import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Web search & extract (reference `plugins/web/*`)

@Suite("Web search and extract")
struct WebSearchExtractTests {

    @Test("Firecrawl search JSON parsing")
    func firecrawlSearch() throws {
        let body = Data(#"{"success":true,"data":[{"url":"https://a.dev","title":"A","description":"desc A"},{"url":"https://b.dev","title":"B","markdown":"md B"}]}"#.utf8)
        let results = try FirecrawlProvider.parseSearchJSON(body)
        #expect(results.count == 2)
        #expect(results[0].url == "https://a.dev")
        #expect(results[1].description == "md B")
    }

    @Test("Exa search JSON parsing")
    func exaSearch() throws {
        let body = Data(#"{"results":[{"url":"https://ex.dev","title":"Ex","text":"body"},{"url":"https://ex2.dev","title":"Ex2","highlights":["one","two"]}]}"#.utf8)
        let results = try ExaSearchProvider.parseSearchJSON(body)
        #expect(results.count == 2)
        #expect(results[1].description == "one two")
    }

    @Test("legacy preference walk picks first available extractor")
    func prefWalk() async {
        await SearchRegistry.shared.reset()
        // Only exa + firecrawl keys available → firecrawl wins (reference order).
        await SearchRegistry.shared.register(ExaSearchProvider(apiKey: "exa-key"))
        await SearchRegistry.shared.register(FirecrawlProvider(apiKey: "fc-key"))
        let resolved = await SearchRegistry.shared.resolveExtractor(configured: nil)
        #expect(resolved?.1 == "firecrawl")
        // Config key wins even when another is available (reference rule 1).
        let configured = await SearchRegistry.shared.resolveExtractor(configured: "exa")
        #expect(configured?.1 == "exa")
        await SearchRegistry.shared.reset()
    }

    @Test("URL secret guard")
    func secretGuard() {
        #expect(WebExtractTool.containsEmbeddedSecret("https://api.example.com/v1?api_key=secret123"))
        #expect(WebExtractTool.containsEmbeddedSecret("https://x.dev/a?access_token=abc"))
        #expect(!WebExtractTool.containsEmbeddedSecret("https://example.com/article?ref=home"))
    }

    @Test("inline base64 replaced with [IMAGE: alt]")
    func base64Images() {
        let html = #"<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==">text after"#
        let out = WebExtractTool.replaceInlineBase64(html)
        #expect(out.contains("[IMAGE: inline base64]"))
        #expect(!out.contains("base64,iVBOR"))
        #expect(out.contains("text after"))
    }

    @Test("URL collection: single, array, and objects")
    func urlCollection() throws {
        #expect(try WebExtractTool.collectURLs(["url": "https://a.dev"]) == ["https://a.dev"])
        #expect(try WebExtractTool.collectURLs(["urls": ["https://a.dev", "https://b.dev"]]) == ["https://a.dev", "https://b.dev"])
        #expect(try WebExtractTool.collectURLs(["urls": [["url": "https://x.dev"], ["href": "https://y.dev"]]]) == ["https://x.dev", "https://y.dev"])
        #expect(throws: ToolError.self) { _ = try WebExtractTool.collectURLs([:]) }
    }

    @Test("stripHTML removes tags and whitespace")
    func stripHTMLTest() {
        let html = "<html><head><style>body{color:red}</style><script>alert(1)</script></head><body><p>Hello   world</p></body></html>"
        let out = WebExtractTool.stripHTML(html)
        #expect(out.contains("Hello world"))
        #expect(!out.contains("<p>"))
        #expect(!out.contains("color:red"))
        #expect(!out.contains("alert(1)"))
    }
}
