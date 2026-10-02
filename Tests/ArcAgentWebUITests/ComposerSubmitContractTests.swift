import Foundation
import Testing

/// The overlay's composer handling must cooperate with the ENGINE's event
/// delegation (document-level, bubble, registered when the engine script
/// runs). The submit-time clear is the order-sensitive one: registered on
/// `document` it runs BEFORE the engine reads the field — because the overlay
/// registers first — and every send carries `""` (measured live 2026-10-01:
/// submit frames showed `{"composer-input": ""}` with a filled textarea).
@Suite("Composer submit contract")
struct ComposerSubmitContractTests {

    private static func overlaySource() throws -> String {
        let path = "Sources/ArcWebUI/Assets/overlay.js"
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("the submit clear runs after the engine's read (window, not document)")
    func clearRunsAfterEngineRead() throws {
        let source = try Self.overlaySource()
        #expect(
            source.contains("window.addEventListener('submit'"),
            """
            the composer clear must register on window: the engine's delegated \
            submit listener lives on document, and a document-level clear \
            (registered earlier) erases the value before the engine reads it
            """
        )
        #expect(
            !source.contains("document.addEventListener('submit'"),
            """
            a document-level submit listener runs before the engine's own and \
            would clear the composer before the engine reads it — every send \
            then carries an empty field
            """
        )
    }
}