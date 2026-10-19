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

    @Test("arc button renders children instead of label")
    func arcButtonChildrenRenderInside() {
        let html = ArcButton("ignored", class: "sess-open") {
            Span { Text("click me") }
        }.markup.html
        #expect(html.contains("<span>click me</span>"))
        #expect(html.contains("type=\"button\""))
        #expect(!html.contains("ignored"))
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

    // MARK: DropdownRow

    @Test("dropdown row emits dd-row with id and type button")
    func dropdownRow() {
        let html = DropdownRow(id: "mainmc-pick-arc") {
            Span { Text("row") }
        }.markup.html
        #expect(html.contains("type=\"button\""))
        #expect(html.contains("id=\"mainmc-pick-arc\""))
        #expect(html.contains("class=\"dd-row\""))
    }

    @Test("dropdown row merges extra class")
    func dropdownRowExtraClass() {
        let html = DropdownRow(id: "x", class: "dd-model-row") {
            Span { Text("row") }
        }.markup.html
        #expect(html.contains("class=\"dd-row dd-model-row\""))
    }

    // MARK: ListRow

    @Test("list row emits list-row")
    func listRow() {
        let html = ListRow {
            Span { Text("x") }
            Span { Text("y") }
        }.markup.html
        #expect(html.contains("class=\"list-row\""))
        #expect(html.contains("<span>x</span>"))
        #expect(html.contains("<span>y</span>"))
    }

    @Test("named list row emits lr-name and lr-sub")
    func namedListRow() {
        let html = NamedListRow("Appearance", sub: "Theme").markup.html
        #expect(html.contains("class=\"list-row\""))
        #expect(html.contains("class=\"lr-name\">Appearance</span>"))
        #expect(html.contains("class=\"lr-sub\">Theme</span>"))
    }

    @Test("named list row omits lr-sub when nil")
    func namedListRowNoSub() {
        let html = NamedListRow("Appearance").markup.html
        #expect(!html.contains("lr-sub"))
    }
}
