import Foundation
import Testing

@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// the click/change identity contract of the no-webui engine, pinned against arc's own
    /// markup and wire registrations.
    ///
    /// the engine routes an event to the nearest `data-component-id` boundary in the event's
    /// path and then reports:
    ///   - `click`: `targetId` = the nearest id-bearing element *inside* that boundary. the
    ///     boundary's own id is never reported (`clickTargetData` walks `owner !== componentEl`).
    ///   - `input`/`change`: `{value, checked}` only — **no `targetId` at all**.
    ///
    /// arc's markup was written against its own forked runtime (retired in `7b62a2df`), which
    /// reported the clicked element's own id as `targetId` and attached `targetId` to change
    /// frames. when the engine took over, every control that put `id` and `data-component-id` on
    /// the same element went inert with no error on either side: the session list never switched,
    /// the ⋮ menu's actions, category chips, theme/scheme pickers, log filters, workspace rows,
    /// tool/skill/profile rows and every row-identity checkbox did nothing.
    ///
    /// these tests fail on the two shapes that cannot work, not on a replica of the fix.
    @Suite("Click identity contract", .serialized)
    struct ClickIdentityContractTests {

        private static let sourcesRoot = "Sources/ArcWebUI"

        /// every `.swift` file in the web-UI target, keyed by name.
        private static func sourceFiles() -> [(name: String, text: String)] {
            guard let walker = FileManager.default.enumerator(atPath: sourcesRoot) else { return [] }
            var out: [(String, String)] = []
            for case let path as String in walker where path.hasSuffix(".swift") {
                let text = (try? String(contentsOfFile: "\(sourcesRoot)/\(path)", encoding: .utf8)) ?? ""
                out.append((path, text))
            }
            return out.sorted { $0.0 < $1.0 }
        }

        /// text as the *client* sees it: line comments stripped (prose is not markup — a comment
        /// describing `data-component-id` is not an emitter) and Swift's `\"` unescaped so the
        /// plain and escaped spellings of an attribute are one shape.
        static func clientText(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[..<comment.lowerBound])
                }
                .joined(separator: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }

        /// every `wire(router, id: "<literal>" …)` registration, paired with the text of its
        /// body (up to the next registration). a wire's id is a literal — a dynamic id is not
        /// routable — so the literal is the whole key.
        static func wireRegistrations(in text: String) -> [(id: String, body: String)] {
            let anchor = "wire(router, id: \""
            var hits: [(id: String, start: String.Index)] = []
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: anchor, range: search) {
                let rest = text[found.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                hits.append((String(rest[..<close]), found.lowerBound))
                search = rest.index(after: close)..<text.endIndex
            }
            return hits.enumerated().map { index, hit in
                let end = index + 1 < hits.count ? hits[index + 1].start : text.endIndex
                return (hit.id, String(text[hit.start..<end]))
            }
        }

        /// the value of one attribute, or nil. the leading space keeps `data-sid="…"` and
        /// `data-component-id="…"` from answering for `id="…"`.
        static func attribute(_ name: String, in tag: String) -> String? {
            let needle = " \(name)=\""
            guard let found = tag.range(of: needle) else { return nil }
            let rest = tag[found.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<close])
        }

        // MARK: the scanners are themselves pinned

        @Test("the scanners see markup and wires, and ignore prose")
        func scannerSelfCheck() {
            let wireSample = #"""
            wire(router, id: "stable", events: ["click", "change"]) { event in
                guard let tid = event.string("targetId") else { return [] }
                return []
            }
            """#
            let markupSample = #"""
            <button id="row-1" data-component-id="stable">x</button>
            <input id="row-2" data-component-id="other" data-sid="noise">
            """#
            let text = Self.clientText(wireSample)

            let wires = Self.wireRegistrations(in: text)
            #expect(wires.map(\.id) == ["stable"], "a commented-out registration is not a wire")
            #expect(wires.first?.body.contains("targetId") == true, "the wire body must be carried")

            // the rendered scanner must see tags in real markup:
            let tags = RenderedMarkup.controlTagsInHTMLForTest(markupSample)
            #expect(tags.count == 2, "both the button and the input must be seen")
            #expect(Self.attribute("data-component-id", in: tags[0]) == "stable")
            #expect(Self.attribute("id", in: tags[0]) == "row-1")
            #expect(Self.attribute("data-component-id", in: tags[1]) == "other")
            #expect(Self.attribute("id", in: tags[1]) == "row-2", "`data-sid` must not answer for `id`")
        }

        // MARK: the contract

        @Test("no click control carries the boundary whose wire dispatches on targetId")
        func clickControlsDoNotOwnTheirBoundary() async throws {
            // wires live in source (Actions, NewFeatures, Queue, …): a wire's body runs to the
            // next registration. scanning one file keeps a wire's wires from bleeding into another.
            let files = Self.sourceFiles()
            let identityWires = files
                .flatMap { Self.wireRegistrations(in: Self.clientText($0.text)) }
                .filter { $0.body.contains("\"click\"") && $0.body.contains("targetId") }
                .map(\.id)
            #expect(
                !identityWires.isEmpty,
                "no targetId-dispatching click wires were found — the scan is broken, not the markup"
            )

            // controls come from rendered bytes, not source spellings:
            let controls = await RenderedMarkup.allControls()
            #expect(
                controls.count >= 144,
                "the rendered scan found \(controls.count) controls — the scan is broken, not the markup (gate at half of the 289 measured)"
            )

            var offenders: [String] = []
            for control in controls
                where Self.attribute("data-component-id", in: control.tag).map(identityWires.contains) == true
                    && Self.attribute("id", in: control.tag) != nil
                    && Self.attribute("data-event", in: control.tag) != "change"
            {
                offenders.append("\(control.region): \(control.tag.prefix(140))")
            }

            #expect(
                offenders.isEmpty,
                """
                these controls put their id on the same element as their `data-component-id`, so \\
                the engine — which reports `targetId` as the nearest id-bearing element *inside* \\
                the boundary, never the boundary's own id — can never tell the handler which \\
                control was clicked. move the boundary to an enclosing element and leave the id \\
                on the control:
                \(offenders.joined(separator: "\n"))
                """
            )
        }

        @Test("no rendered control carries id and data-component-id on the same element")
        func renderedControlsDoNotCollapseIdIntoBoundary() async {
            // the old helper-built control test (`btn("x", "x", …)` / `ddRow(id:component:)`)
            // hid 18 controls behind string call sites the scanner could not see. the helpers
            // are gone, and every control now flows through rendered bytes, so the id-on-the-
            // boundary defect is visible directly in HTML. this pins that shape: a control
            // whose `id` equals its `data-component-id` AND whose component wire dispatches
            // on `targetId` is the inert-control defect, full stop.
            let files = Self.sourceFiles()
            let identityWires = files
                .flatMap { Self.wireRegistrations(in: Self.clientText($0.text)) }
                .filter { $0.body.contains("\"click\"") && $0.body.contains("targetId") }
                .map(\.id)

            let controls = await RenderedMarkup.allControls()
            #expect(
                controls.count > 50,
                "the rendered scan found \(controls.count) controls — the scan is broken, not the markup"
            )

            var offenders: [String] = []
            for control in controls
                where Self.attribute("id", in: control.tag) != nil
                    && Self.attribute("id", in: control.tag) == Self.attribute("data-component-id", in: control.tag)
                    && Self.attribute("data-component-id", in: control.tag).map(identityWires.contains) == true
                    && Self.attribute("data-event", in: control.tag) != "change"
            {
                offenders.append("\(control.region): \(control.tag.prefix(140))")
            }

            #expect(
                offenders.isEmpty,
                """
                these rendered controls put the same string on both `id` and `data-component-id` \\
                for a `targetId`-dispatching wire, so the engine reports the boundary's own id \\
                as `targetId` and never tells the handler which control was clicked. move the \\
                boundary to an enclosing element and leave the id on the control:
                \(offenders.joined(separator: "\n"))
                """
            )
        }

        @Test("an empty component never becomes a boundary")
        func emptyComponentIsNotABoundary() async {
            // `findComponent` matches on attribute *presence*, so `data-component-id=""` is a
            // boundary that routes nowhere: it shadows the container and the engine drops the
            // click (`if (!componentId) return`). measured live: the kanban form's Cancel
            // button did nothing. `ArcButton` omits the attribute for an empty component.
            let silent = ArcButton("Cancel", id: "x", component: "", class: "ghost-btn").markup.html
            #expect(!silent.contains("data-component-id"), "an empty component must omit the attribute: \(silent)")
            #expect(silent.contains("id=\"x\""), "the id must survive: \(silent)")
            let routed = ArcButton("Cancel", id: "x", component: "row-actions", class: "ghost-btn").markup.html
            #expect(routed.contains("data-component-id=\"row-actions\""), "the boundary must ride a non-empty component: \(routed)")

            // scan rendered bytes for empty boundaries — a scan that finds none is broken:
            let controls = await RenderedMarkup.allControls()
            #expect(
                controls.count >= 144,
                "the rendered scan found \(controls.count) controls — the scan is broken, not the markup (gate at half of the 289 measured)"
            )
            let emptyBoundaries = controls
                .filter { Self.attribute("data-component-id", in: $0.tag) == "" }
                .map { "\($0.region): \($0.tag.prefix(100))" }
            #expect(
                emptyBoundaries.isEmpty,
                "empty boundaries shadow the container:\n\(emptyBoundaries.joined(separator: "\n"))"
            )
        }

        @Test("change wires that dispatch on row identity read the value channel")
        func changeWiresUseTheValueChannel() throws {
            let files = Self.sourceFiles()
            let identityChangeWires = files
                .flatMap { Self.wireRegistrations(in: Self.clientText($0.text)) }
                .filter { $0.body.contains("\"change\"") && $0.body.contains("targetId") }
            #expect(
                !identityChangeWires.isEmpty,
                "no change wires dispatching on row identity were found — the scan is broken, not the wires"
            )

            let offenders = identityChangeWires
                .filter { !$0.body.contains("string(\"value\")") }
                .map(\.id)

            #expect(
                offenders.isEmpty,
                """
                a change frame carries `{value, checked}` and no `targetId` at all, so these wires \\
                can never see the row they act on. read `event.string("value")` (the markup emits \\
                each control's row id as its value) or drop the change registration:
                \(offenders.joined(separator: ", "))
                """
            )
        }
    }
}
