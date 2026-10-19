// pinned contract for the rendered-markup entry point. every assertion reads
// rendered bytes, never Views.swift source.

@testable import ArcWebUI
import Foundation
import Testing
import WebUI

extension ArcWebUITestRoot {

    @Suite("rendered markup", .serialized)
    struct RenderedMarkupTests {

        @Test("the page renders its regions and carries real state")
        func thePageRendersAndCarriesItsRegions() async {
            let html = await RenderedMarkup.page()
            #expect(html.contains("id=\"app\""))
            #expect(html.contains("id=\"topbar\""))
            #expect(html.contains("id=\"iconbar\""))
            #expect(html.count > 5_000, "the page is suspiciously small — the fixture is not seeding state")
        }

        @Test("every supported fragment returns non-empty markup")
        func everySupportedFragmentIsNonEmpty() async {
            let names = ["topbar", "iconbar", "panel", "main", "dock", "toasts", "modal-root"]
            for name in names {
                let html = await RenderedMarkup.fragment(name)
                #expect(!html.isEmpty, "fragment \(name) rendered empty — the mapping is broken")
            }
        }

        @Test("the page is deterministic across renders")
        func thePageIsDeterministic() async {
            let first = await RenderedMarkup.page()
            let second = await RenderedMarkup.page()
            #expect(first == second, "the page is not deterministic across renders")
        }
    }
}
