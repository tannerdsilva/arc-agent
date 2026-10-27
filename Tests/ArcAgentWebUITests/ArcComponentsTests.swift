@testable import ArcWebUI
import Foundation
import Testing
import WebUI

/// Contract tests for the typed composite layer.
///
/// Every assertion is against `.markup.html` output. No goldens — the output
/// is pinned structurally here.
@Suite("Arc components", .serialized)
struct ArcComponentsTests {

    // MARK: ArcButton

    @Test("arc button emits label as text children")
    func arcButtonLabel() {
        let html = ArcButton("Save", class: "primary-btn").markup.html
        #expect(html.contains("type=\"button\""))
        #expect(html.contains("class=\"primary-btn\""))
        #expect(html.contains(">Save</button>"))
    }

    @Test("arc button renders its content views")
    func arcButtonChildrenRenderInside() {
        // the initializer that takes a label has no content builder and this one
        // has no label, so the old "label silently dropped" case cannot be written
        let html = ArcButton(class: "sess-open") {
            Span { Text("click me") }
        }.markup.html
        #expect(html.contains("<span>click me</span>"))
        #expect(html.contains("type=\"button\""))
    }

    @Test("arc button omits data-component-id when component is nil")
    func arcButtonOmitsComponentWhenNil() {
        let html = ArcButton("x", id: "b1", component: nil, class: "c").markup.html
        #expect(!html.contains("data-component-id"))
        #expect(html.contains("id=\"b1\""))
    }

    @Test("arc button omits data-component-id when component is empty")
    func arcButtonOmitsComponentWhenEmpty() {
        let html = ArcButton("x", id: "b2", component: "", class: "c").markup.html
        #expect(!html.contains("data-component-id"))
        #expect(html.contains("id=\"b2\""))
    }

    @Test("arc button emits data-component-id when component is non-empty")
    func arcButtonEmitsComponentWhenNonEmpty() {
        let html = ArcButton("x", id: "b3", component: "my-boundary", class: "c").markup.html
        #expect(html.contains("data-component-id=\"my-boundary\""))
    }

    @Test("arc button type defaults to button")
    func arcButtonDefaultType() {
        let html = ArcButton("x", class: "c").markup.html
        #expect(html.contains("type=\"button\""))
    }

    @Test("arc button emits type=submit")
    func arcButtonSubmitType() {
        let html = ArcButton("Send", class: "c", type: .submit).markup.html
        #expect(html.contains("type=\"submit\""))
    }

    @Test("arc button disabled emits disabled=\"\" not disabled=\"false\"")
    func arcButtonDisabled() {
        let html = ArcButton("x", class: "c", disabled: true).markup.html
        #expect(html.contains("disabled=\"\""))
        #expect(!html.contains("disabled=\"false\""))
    }

    @Test("arc button disabled=false omits the attribute")
    func arcButtonNotDisabled() {
        let html = ArcButton("x", class: "c", disabled: false).markup.html
        #expect(!html.contains("disabled"))
    }

    @Test("arc button hidden emits hidden=\"\"")
    func arcButtonHidden() {
        let html = ArcButton("x", class: "c", hidden: true).markup.html
        #expect(html.contains("hidden=\"\""))
    }

    @Test("arc button hidden=false omits the attribute")
    func arcButtonNotHidden() {
        let html = ArcButton("x", class: "c", hidden: false).markup.html
        #expect(!html.contains("hidden"))
    }

    @Test("arc button emits its exact class")
    func arcButtonClass() {
        let html = ArcButton("x", class: "ghost-btn danger").markup.html
        #expect(html.contains("class=\"ghost-btn danger\""))
    }

    @Test("arc button output is a single button element, no wrapper span")
    func arcButtonIsOneButtonElement() {
        let html = ArcButton("Press", class: "c").markup.html
        let openCount = html.split(separator: "<", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("button") || $0.hasPrefix("/button") }.count
        #expect(openCount == 2, "expected exactly one <button> and one </button>, got \(html)")
        #expect(!html.contains("<span"))
        #expect(html.hasPrefix("<button"))
        #expect(html.hasSuffix("</button>"))
    }

    // MARK: ArcSwitch

    @Test("arc switch renders the switch shape")
    func arcSwitchShape() {
        let html = ArcSwitch(id: "sk-toggle-abc", on: true, value: "sk-toggle-abc").markup.html
        #expect(html.hasPrefix("<label class=\"switch\">"))
        #expect(html.contains("<input type=\"checkbox\""))
        #expect(html.contains("id=\"sk-toggle-abc\""))
        #expect(html.contains("value=\"sk-toggle-abc\""))
        #expect(html.contains("data-no-restore=\"\""))
        #expect(html.contains("checked=\"\""))
        #expect(html.contains("<span class=\"track\"></span>"))
        #expect(html.contains("<span class=\"knob\"></span>"))
        #expect(html.contains("</label>"))
    }

    @Test("arc switch omits checked when off")
    func arcSwitchOff() {
        let html = ArcSwitch(id: "s1", on: false).markup.html
        #expect(!html.contains("checked"))
    }

    @Test("arc switch omits data-component-id when nil")
    func arcSwitchOmitsComponentNil() {
        let html = ArcSwitch(id: "s2", on: true, component: nil).markup.html
        #expect(!html.contains("data-component-id"))
    }

    @Test("arc switch omits data-component-id when empty")
    func arcSwitchOmitsComponentEmpty() {
        let html = ArcSwitch(id: "s3", on: true, component: "").markup.html
        #expect(!html.contains("data-component-id"))
    }

    @Test("arc switch emits data-component-id when non-empty")
    func arcSwitchEmitsComponent() {
        let html = ArcSwitch(id: "s4", on: true, component: "tools-toggle").markup.html
        #expect(html.contains("data-component-id=\"tools-toggle\""))
    }

    // MARK: SettingRow

    @Test("setting row emits set-row and set-label")
    func settingRow() {
        let html = SettingRow(label: { [Text("Appearance")] }, control: { [ArcButton("Open", class: "c")] }).markup.html
        #expect(html.contains("class=\"set-row\""))
        #expect(html.contains("class=\"set-label\""))
        #expect(html.contains("Appearance"))
        #expect(html.contains("<button"))
    }

    // MARK: AkvRow

    @Test("akv row emits akv / akv-k / akv-v")
    func akvRow() {
        let html = AkvRow(key: "Name", value: "arc").markup.html
        #expect(html.contains("class=\"akv\""))
        #expect(html.contains("class=\"akv-k\">Name</span>"))
        #expect(html.contains("class=\"akv-v\">arc</span>"))
    }

    @Test("akv row view variant")
    func akvRowViewVariant() {
        let html = AkvRow(key: { [Text("Model")] }, value: { [Text("gpt-4o")] }).markup.html
        #expect(html.contains("class=\"akv-k\">Model</span>"))
        #expect(html.contains("class=\"akv-v\">gpt-4o</span>"))
    }

    // MARK: DetailCard

    @Test("detail card emits detail-card / detail-title / detail-sub")
    func detailCard() {
        let html = DetailCard(title: "Skill", sub: "devops") {
            Paragraph("body")
        }.markup.html
        #expect(html.contains("class=\"detail-card\""))
        #expect(html.contains("class=\"detail-title\">Skill</h1>"))
        #expect(html.contains("class=\"detail-sub\">devops</div>"))
    }

    @Test("a detail card with no sub-line omits the node entirely")
    func detailCardWithoutSub() {
        let html = DetailCard(title: "Skill") { Paragraph("body") }.markup.html
        #expect(html.contains("class=\"detail-card\""))
        #expect(!html.contains("detail-sub"), "an empty sub-line renders a visible gap in the sheet")
    }

    @Test("a bare detail card emits no title and no sub")
    func detailCardBare() {
        let html = DetailCard { Paragraph("body") }.markup.html
        #expect(html.contains("class=\"detail-card\""))
        #expect(!html.contains("detail-title"), "most legacy detail cards carry no title line")
        #expect(!html.contains("detail-sub"))
        #expect(html.contains("body"))
    }

    // MARK: W3 — typed builder byte contract

    @Test("field label wraps its child, byte for byte")
    func fieldLabelBytes() {
        let html = FieldLabel(class: "aux-field") { Text("hi") }.markup.html
        #expect(html == #"<label class="aux-field">hi</label>"#)
    }

    @Test("form label names its control, byte for byte")
    func formLabelBytes() {
        let html = FormLabel(for: "skill-name-input") { Text("Name") }.markup.html
        #expect(html == #"<label for="skill-name-input">Name</label>"#)
    }

    @Test("akv row string convenience, byte for byte")
    func akvRowStringBytes() {
        let html = AkvRow(key: "Name", value: "arc").markup.html
        #expect(html == #"<div class="akv"><span class="akv-k">Name</span><span class="akv-v">arc</span></div>"#)
    }

    @Test("akv row view builders, byte for byte")
    func akvRowViewBytes() {
        let html = AkvRow(key: { [Text("Model")] }, value: { [Text("gpt-4o")] }).markup.html
        #expect(html == #"<div class="akv"><span class="akv-k">Model</span><span class="akv-v">gpt-4o</span></div>"#)
    }

    @Test("detail card body, byte for byte")
    func detailCardBytes() {
        let html = DetailCard(title: "Skill", sub: "devops") { Paragraph("body") }.markup.html
        #expect(html == #"<div class="detail-card"><h1 class="detail-title">Skill</h1><div class="detail-sub">devops</div><p>body</p></div>"#)
    }

    @Test("bare detail card body, byte for byte")
    func detailCardBareBytes() {
        let html = DetailCard { Paragraph("body") }.markup.html
        #expect(html == #"<div class="detail-card"><p>body</p></div>"#)
    }

    @Test("a detail card with no body at all renders an empty card")
    func detailCardNoBodyBytes() {
        // the `EmptyView` default is the only place that type is used, so it
        // gets its own pin rather than riding on a body-carrying call site.
        let html = DetailCard().markup.html
        #expect(html == #"<div class="detail-card"></div>"#)
    }

    @Test("main scroll wraps its content, byte for byte")
    func mainScrollBytes() async {
        let state = AppState(renderFixture: AppState.RenderFixture())
        let html = await state.mainScroll { Text("hi") }.markup.html
        #expect(html == #"<div class="main-view"><div id="main-scroll" class="main-scroll" data-scroll-key="main-scroll">hi</div></div>"#)
    }

    @Test("a dropdown row forwards id, class and children, byte for byte")
    func dropdownRowHelperBytes() async {
        var f = AppState.RenderFixture()
        f.settings.modelConfigs = [ModelConfigPreset(name: "fast", model: "gpt-5-mini",
                                                     provider: "openai", baseURL: "",
                                                     maxOutputTokens: 4096)]
        f.settings.activeConfig = "fast"
        let html = await AppState(renderFixture: f).mainModelDropdown().markup.html
        let row = #"<button id="mainmc-pick-ZmFzdA" class="dd-row" type="button"><span class="dd-model-main"><span class="dd-row-title">fast<span class="dd-badge sel">SELECTED</span></span><span class="dd-row-sub">gpt-5-mini @ openai</span></span></button>"#
        #expect(html.contains(row), "the row's own bytes are the helper's contract")
    }
}
