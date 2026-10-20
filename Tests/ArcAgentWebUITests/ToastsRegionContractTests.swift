import Testing
import Foundation
@testable import ArcWebUI

/// the toasts region is a PATCH TARGET, and the engine deletes a patch target
/// whose replacement fragment is empty (`replaceElement` → `el.remove()`).
/// so a push of "no toasts" must still carry the container, or `#toasts` dies
/// on the first dismiss and every later toast is silently swallowed.
/// measured live 2026-10-20: ten `[WebUIEngine] Element not found: #toasts`
/// warnings after five popover open/dismiss cycles against a running daemon.
@Suite("toasts region contract")
struct ToastsRegionContractTests {

    private static func source(at path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// code only — this suite's own doc comment quotes the banned shape.
    private static func stripComments(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    @Test("no toasts push sends inner-only markup")
    func pushesCarryTheContainer() {
        let src = Self.stripComments(Self.source(at: "Sources/ArcWebUI/Actions.swift"))
        let offenders = src
            .components(separatedBy: .newlines)
            .filter { $0.contains("\"toasts\"") && $0.contains("toastsHTML()") }
        #expect(offenders.isEmpty,
                "an inner-only toasts push deletes #toasts for the session: \(offenders)")
    }

    @Test("the empty shell still renders the patch target")
    func shellAlwaysPresent() async {
        let app = AppState(renderFixture: AppState.RenderFixture())
        let html = await app.toastsShell().markup.html
        #expect(html.contains("id=\"toasts\""),
                "the shell must emit the patch target even with nothing to show")
        #expect(html.contains("data-component-id=\"toast-dismiss\""),
                "the shell must keep its routing anchor across a replacement")
    }
}