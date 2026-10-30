import Testing
@testable import ArcWebUI
import WebUI

// markup invariants the htmlstring-eliminate migration depends on.
// every assertion reads `.markup.html` — rendered bytes, never source.
// tabs, lowercase comments.

extension ArcWebUITestRoot {
	@Suite("Markup invariants", .serialized)
	struct MarkupInvariantTests {

	    // MARK: - escaping equivalence

	    @Test("text and attributes escape hostile payloads identically")
	    func escapingEquivalence() {
	        let script = "<script>alert(1)</script>"
	        let payload = "\"><img src=x onerror=alert(1)>"

	        let escapedScript = htmlEscape(script)
	        let escapedPayload = htmlEscape(payload)

	        // esc() and the framework's htmlEscape agree on every byte
	        #expect(esc(script) == escapedScript)
	        #expect(esc(payload) == escapedPayload)

	        // Text escapes both payloads; the leading " and the < are escaped,
	        // which neutralizes the tag breakout. `onerror=` itself is not an
	        // HTML-special character and passes through — that is the framework's
	        // escaping spelling (& < > " ' only).
	        let textScript = Text(script).markup.html
	        let textPayload = Text(payload).markup.html
	        #expect(textScript == escapedScript)
	        #expect(textPayload == escapedPayload)
	        #expect(!textScript.contains("<script"))
	        #expect(!textPayload.contains("<script"))
	        #expect(textPayload.contains("&quot;")) // the leading " is escaped
	        #expect(textPayload.contains("&lt;"))   // the < is escaped

	        // attribute values escape the same way (id, class, title)
	        let idAttr = Div { Text("x") }.attribute("id", payload).markup.html
	        let classAttr = Div { Text("x") }.attribute("class", payload).markup.html
	        let titleAttr = Div { Text("x") }.attribute("title", payload).markup.html
	        let idExpected = "id=\"\(escapedPayload)\""
	        let classExpected = "class=\"\(escapedPayload)\""
	        let titleExpected = "title=\"\(escapedPayload)\""
	        #expect(idAttr.contains(idExpected))
	        #expect(classAttr.contains(classExpected))
	        #expect(titleAttr.contains(titleExpected))
	        #expect(!idAttr.contains("<script"))
	        #expect(titleAttr.contains("&quot;"))
	        #expect(titleAttr.contains("&lt;"))

	        // Small / Paragraph / InlineCode carry agent output: escape identically
	        #expect(Small(script).markup.html.contains(escapedScript))
	        #expect(Paragraph(script).markup.html.contains(escapedScript))
	        #expect(InlineCode(script).markup.html.contains(escapedScript))
	        #expect(Small(payload).markup.html.contains(escapedPayload))
	        #expect(Paragraph(payload).markup.html.contains(escapedPayload))
	        #expect(InlineCode(payload).markup.html.contains(escapedPayload))
	    }

	    // MARK: - attribute escaping

	    @Test("attribute values escape & < > \" '")
	    func attributeEscaping() {
	        // the framework escapes & < > " ' in attribute values (htmlEscape);
	        // the parity normalizer may leave > unescaped in a quoted value, but
	        // that is normalization, not the framework's escaping spelling.
	        let value = "a\"b&c<d"
	        let escaped = htmlEscape(value)
	        let html = Div { }.attribute("title", value).markup.html
	        let expected = "title=\"\(escaped)\""
	        #expect(html.contains(expected))
	        #expect(!html.contains("a\"b&c<d"))

	        // > is escaped too
	        let gtHtml = Div { }.attribute("title", "x>y").markup.html
	        #expect(gtHtml.contains("title=\"x&gt;y\""))
	    }

	    // MARK: - empty component boundary

	    @Test("an empty component is not a boundary")
	    func emptyComponentIsNotABoundary() {
	        let nilHtml = ArcButton("x", component: nil, class: "c").markup.html
	        #expect(!nilHtml.contains("data-component-id"))
	        #expect(nilHtml.contains("class=\"c\""))

	        let emptyHtml = ArcButton("x", component: "", class: "c").markup.html
	        #expect(!emptyHtml.contains("data-component-id"))

	        let routedHtml = ArcButton("x", component: "k", class: "c").markup.html
	        #expect(routedHtml.contains("data-component-id=\"k\""))
	        // exactly once
	        let marker = "data-component-id=\"k\""
	        var count = 0
	        var search = routedHtml.startIndex..<routedHtml.endIndex
	        while let range = routedHtml.range(of: marker, range: search) {
	            count += 1
	            search = range.upperBound..<routedHtml.endIndex
	        }
	        #expect(count == 1, "expected exactly one data-component-id, got \(count): \(routedHtml)")
	    }

	    // MARK: - boolean attributes

	    @Test("boolean attributes are name=\"\" when true and absent when false")
	    func booleanAttributes() {
	        // ArcButton: disabled, hidden
	        let disabled = ArcButton("x", class: "c", disabled: true).markup.html
	        #expect(disabled.contains("disabled=\"\""))
	        #expect(!disabled.contains("disabled=\"false\""))
	        let notDisabled = ArcButton("x", class: "c", disabled: false).markup.html
	        #expect(!notDisabled.contains("disabled"))

	        let hidden = ArcButton("x", class: "c", hidden: true).markup.html
	        #expect(hidden.contains("hidden=\"\""))
	        let notHidden = ArcButton("x", class: "c", hidden: false).markup.html
	        #expect(!notHidden.contains("hidden"))

	        // ArcSwitch: checked, data-no-restore
	        let on = ArcSwitch(id: "s", on: true).markup.html
	        #expect(on.contains("checked=\"\""))
	        #expect(on.contains("data-no-restore=\"\""))
	        let off = ArcSwitch(id: "s", on: false).markup.html
	        #expect(!off.contains("checked"))
	        #expect(off.contains("data-no-restore=\"\""))

	        // disabled="false" must never occur anywhere
	        let all = disabled + notDisabled + hidden + notHidden + on + off
	        #expect(!all.contains("disabled=\"false\""))
	    }

	    // MARK: - pending-attribute placement

	    @Test("pending attributes settle on the element, not a wrapper")
	    func pendingAttributePlacement() {
	        // on a Div: the attribute lands on the div itself, no wrapper span
	        let divHtml = Div { Text("x") }.attribute("data-x", "1").markup.html
	        #expect(divHtml.hasPrefix("<div data-x=\"1\">"))
	        #expect(!divHtml.contains("<span"))

	        // on a bare Text: Text emits no element of its own, so a pending
	        // attribute must settle somewhere. the framework's buffer path wraps
	        // elementless content in `<span ...>` (the `settlePendingAttributes`
	        // fallback, `no-webui/Sources/WebUISharedCore/HTMLBuffer.swift:204`).
	        // pin the spelling — a future change that drops the span fails here.
	        let textHtml = Text("x").attribute("data-x", "1").markup.html
	        #expect(textHtml == "<span data-x=\"1\">x</span>", "pending attribute on Text must settle in a span, got: \(textHtml)")
	    }
	}
}
