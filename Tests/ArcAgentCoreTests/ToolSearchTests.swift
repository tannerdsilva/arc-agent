import Testing
@testable import ArcAgentCore
import Foundation

extension ArcCoreTestRoot {
    /// `tool_search` catalog search tests (reference `tools/tool_search.py` parity).
    ///
    /// Serialization is kept from the days of the `ToolSearchTool.registry`
    /// static, when parallel tests raced each other's deallocs. Each test now
    /// owns its surface and its slot (GROUNDZERO slice 6), so nothing is
    /// shared — the trait is harmless, and dropping it is a separate change.
    @Suite("Tool search", .serialized)
    struct ToolSearchTests {

        @Test("search ranks name matches above description-only matches")
        func ranking() {
            let catalog = [
                ToolSearchTool.CatalogEntry(name: "read_file", description: "Read a text file with line numbers", toolset: "file"),
                ToolSearchTool.CatalogEntry(name: "write_file", description: "Write a file", toolset: "file"),
                ToolSearchTool.CatalogEntry(name: "browser_navigate", description: "Navigate the browser to a URL", toolset: "browser"),
            ]
            let results = ToolSearchTool.search(catalog, query: "file", limit: 5)
            #expect(results.first?.name == "read_file")
            #expect(results.contains { $0.name == "write_file" })
        }

        @Test("empty query returns everything; limit applies")
        func listingAll() {
            let catalog = (0..<10).map {
                ToolSearchTool.CatalogEntry(name: "tool\($0)", description: "desc \($0)", toolset: "t")
            }
            let all = ToolSearchTool.search(catalog, query: "", limit: 5)
            #expect(all.count == 5)
        }

        @Test("handler lists the catalog grouped by toolset")
        func handlerListing() async throws {
            let deps = ToolDependencies()
            let registry = try ArcAgentCore.testRegistry(dependencies: deps)
            let out = try await ToolSearchTool.entry(registry: deps.toolSearchRegistry)
                .handler(["query": "file", "limit": 100])
            #expect(out.contains("read_file"))
            #expect(out.contains("Matching tools"))
            // Listing form groups under 📦
            #expect(out.contains("📦"))
        }

        @Test("handler names form returns bare names")
        func handlerNames() async throws {
            let deps = ToolDependencies()
            _ = try ArcAgentCore.testRegistry(dependencies: deps)
            let out = try await ToolSearchTool.entry(registry: deps.toolSearchRegistry)
                .handler(["query": "read", "form": "names"])
            #expect(out.contains("read_file"))
            #expect(!out.contains("—"))
        }

        @Test("invalid form errors clearly")
        func invalidForm() async throws {
            let deps = ToolDependencies()
            _ = try ArcAgentCore.testRegistry(dependencies: deps)
            let out = try await ToolSearchTool.entry(registry: deps.toolSearchRegistry)
                .handler(["query": "x", "form": "grid"])
            #expect(out.contains("invalid form"))
        }
    }
}
