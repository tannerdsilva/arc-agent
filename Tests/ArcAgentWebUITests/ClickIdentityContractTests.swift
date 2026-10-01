import Foundation
import Testing

@testable import arc_agent_webui

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
@Suite("Click identity contract")
struct ClickIdentityContractTests {

    private static let sourcesRoot = "Sources/ArcAgentWebUI"

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

    /// every `<button …>` / `<input …>` tag in the text, verbatim.
    static func controlTags(in text: String) -> [String] {
        var out: [String] = []
        for opener in ["<button", "<input"] {
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: opener, range: search) {
                guard let close = text[found.lowerBound...].firstIndex(of: ">") else { break }
                out.append(String(text[found.lowerBound...close]))
                search = text.index(after: close)..<text.endIndex
            }
        }
        return out
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

    /// every `btn("<id>", "<component>" …)` / `ddRow(id: "<id>", component: "<component>" …)`
    /// call site. the helpers emit `id` and `data-component-id` on one element, so a call
    /// that passes a targetId-dispatching component is the same defect as a literal tag —
    /// and a tag scan cannot see it. (18 controls hid here: the four composer dropdowns,
    /// the toast ✕, the attachment ✕, the profile action buttons and every kanban button.)
    static func helperControlCalls(in text: String) -> [(kind: String, id: String, component: String)] {
        var out: [(String, String, String)] = []
        func scan(_ marker: String, _ kind: String, separator: String) {
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: marker, range: search) {
                let rest = text[found.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                let id = String(rest[..<close])
                let tail = rest[close...]
                if let compStart = tail.range(of: separator),
                   let compEnd = tail[compStart.upperBound...].firstIndex(of: "\"") {
                    out.append((kind, id, String(tail[compStart.upperBound..<compEnd])))
                }
                search = rest.index(after: close)..<text.endIndex
            }
        }
        scan("btn(\"", "btn", separator: ", \"")
        scan("ddRow(id: \"", "ddRow", separator: ", component: \"")
        return out
    }

    // MARK: the scanners are themselves pinned

    @Test("the scanners see markup and wires, and ignore prose")
    func scannerSelfCheck() {
        let sample = """
        // wire(router, id: "commented-out", events: ["click"]) { _ in }
        wire(router, id: "stable", events: ["click", "change"]) { event in
            guard let tid = event.string("targetId") else { return [] }
            return []
        }
        let a = "<button type=\\"button\\" id=\\"row-1\\" data-component-id=\\"stable\\">x</button>"
        let b = #"<input id="row-2" data-component-id="other" data-sid="noise">"#
        """
        let text = Self.clientText(sample)

        let wires = Self.wireRegistrations(in: text)
        #expect(wires.map(\.id) == ["stable"], "a commented-out registration is not a wire")
        #expect(wires.first?.body.contains("targetId") == true, "the wire body must be carried")

        let tags = Self.controlTags(in: text)
        #expect(tags.count == 2, "both the escaped and the raw spelling must be seen")
        #expect(Self.attribute("data-component-id", in: tags[0]) == "stable")
        #expect(Self.attribute("id", in: tags[0]) == "row-1")
        #expect(Self.attribute("data-component-id", in: tags[1]) == "other")
        #expect(Self.attribute("id", in: tags[1]) == "row-2", "`data-sid` must not answer for `id`")

        // helper-built controls: the helpers put id + boundary on one element
        let calls = Self.helperControlCalls(in: Self.clientText("""
        _ = btn("row-3", "stable", "x", "y")
        rows.append(ddRow(id: "pick-1", component: "other", body: "z"))
        """))
        #expect(calls.count == 2, "both helper shapes must be seen")
        #expect(calls.first?.kind == "btn")
        #expect(calls.first?.id == "row-3")
        #expect(calls.first?.component == "stable")
        #expect(calls.last?.component == "other")
    }

    // MARK: the contract

    @Test("no click control carries the boundary whose wire dispatches on targetId")
    func clickControlsDoNotOwnTheirBoundary() throws {
        let files = Self.sourceFiles()
        #expect(!files.isEmpty, "no web-UI sources were found — the scan is broken, not the markup")

        let actions = try #require(
            files.first { $0.name == "Actions.swift" }?.text,
            "Actions.swift holds the wire registrations"
        )
        let identityWires = Self.wireRegistrations(in: Self.clientText(actions))
            .filter { $0.body.contains("\"click\"") && $0.body.contains("targetId") }
            .map(\.id)
        #expect(
            !identityWires.isEmpty,
            "no targetId-dispatching click wires were found — the scan is broken, not the markup"
        )

        var offenders: [String] = []
        for file in files {
            let text = Self.clientText(file.text)
            for tag in Self.controlTags(in: text) {
                guard let component = Self.attribute("data-component-id", in: tag),
                      identityWires.contains(component),
                      Self.attribute("id", in: tag) != nil
                else { continue }
                offenders.append("\(file.name): \(tag.prefix(140))")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            these controls put their id on the same element as their `data-component-id`, so \
            the engine — which reports `targetId` as the nearest id-bearing element *inside* \
            the boundary, never the boundary's own id — can never tell the handler which \
            control was clicked. move the boundary to an enclosing element and leave the id \
            on the control:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("no helper-built control carries a boundary whose wire dispatches on targetId")
    func helperControlsDoNotOwnTheirBoundary() throws {
        let files = Self.sourceFiles()
        let actions = try #require(files.first { $0.name == "Actions.swift" }?.text)
        let identityWires = Self.wireRegistrations(in: Self.clientText(actions))
            .filter { $0.body.contains("\"click\"") && $0.body.contains("targetId") }
            .map(\.id)
        #expect(!identityWires.isEmpty, "no targetId-dispatching click wires were found — the scan is broken")

        var offenders: [String] = []
        for file in files {
            for call in Self.helperControlCalls(in: Self.clientText(file.text))
            where identityWires.contains(call.component) {
                offenders.append("\(file.name): \(call.kind)(id: \(call.id), component: \(call.component))")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            these helper-built controls hand the helper both an id and a targetId-dispatching \
            component, so the helper emits the boundary on the control itself — and the engine \
            never reports it. pass "" as the component (or `ddRow` without one) and put the \
            boundary on an enclosing element:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("an empty component never becomes a boundary")
    func emptyComponentIsNotABoundary() {
        // `findComponent` matches on attribute *presence*, so `data-component-id=""` is a
        // boundary that routes nowhere: it shadows the container and the engine drops the
        // click (`if (!componentId) return`). measured live: the kanban form's Cancel
        // button did nothing. the helper omits the attribute for an empty component.
        let silent = btn("x", "", "ghost-btn", "Cancel")
        #expect(!silent.contains("data-component-id"), "an empty component must omit the attribute: \(silent)")
        #expect(silent.contains("id=\"x\""), "the id must survive: \(silent)")
        let routed = btn("x", "row-actions", "ghost-btn", "Cancel")
        #expect(routed.contains("data-component-id=\"row-actions\""), "the boundary must ride a non-empty component: \(routed)")

        var offenders: [String] = []
        for file in Self.sourceFiles() {
            for tag in Self.controlTags(in: Self.clientText(file.text))
            where Self.attribute("data-component-id", in: tag) == "" {
                offenders.append("\(file.name): \(tag.prefix(100))")
            }
        }
        #expect(offenders.isEmpty, "empty boundaries shadow the container:\n\(offenders.joined(separator: "\n"))")
    }

    @Test("change wires that dispatch on row identity read the value channel")
    func changeWiresUseTheValueChannel() throws {
        let actions = try #require(
            Self.sourceFiles().first { $0.name == "Actions.swift" }?.text,
            "Actions.swift holds the wire registrations"
        )
        let identityChangeWires = Self.wireRegistrations(in: Self.clientText(actions))
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
            a change frame carries `{value, checked}` and no `targetId` at all, so these wires \
            can never see the row they act on. read `event.string("value")` (the markup emits \
            each control's row id as its value) or drop the change registration:
            \(offenders.joined(separator: ", "))
            """
        )
    }
}