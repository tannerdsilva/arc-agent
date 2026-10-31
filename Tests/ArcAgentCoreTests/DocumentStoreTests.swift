import Testing
import Foundation
@testable import ArcAgentCore

// MARK: - the generic document store

extension ArcCoreTestRoot {
    /// `DocumentStore` is the one actor behind `config.json` and `settings.json`.
    /// These tests pin the guarantees on a document that is neither, so a
    /// regression in the generic body cannot hide behind `ArcConfig`.
    @Suite("document store", .serialized)
    struct DocumentStoreTests {

        /// A document shape the store has never seen: two fields, plain JSON.
        struct Note: ConfigurationDocument {
            var title: String = ""
            var body: String = ""

            static var defaultURL: URL {
                FileManager.default.temporaryDirectory.appendingPathComponent("note.json")
            }
            static var defaultValue: Note { Note() }
        }

        /// A fresh note URL under a unique scratch directory.
        private func scratch() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-document-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("note.json")
        }

        @Test("a missing document reads as its default and is never created")
        func missingDocumentIsDefault() async throws {
            let url = try scratch()
            let store = DocumentStore<Note>(url: url, environment: [:], resolve: { document, _ in document })

            #expect(await store.failure() == nil)
            #expect(await store.snapshot().declared == Note())
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        @Test("mutate writes atomically, decodes back, and keeps one .bak generation")
        func mutateWritesAndBacksUp() async throws {
            let url = try scratch()
            let store = DocumentStore<Note>(url: url, environment: [:], resolve: { document, _ in document })

            _ = try await store.mutate { $0.title = "first" }
            #expect(try DocumentStore<Note>.read(url).title == "first")

            _ = try await store.mutate { $0.title = "second" }

            #expect(try DocumentStore<Note>.read(url).title == "second")
            let backup = url.appendingPathExtension("bak")
            #expect(try DocumentStore<Note>.read(backup).title == "first")
        }

        @Test("a corrupt document is refused and its bytes are untouched")
        func corruptDocumentRefused() async throws {
            let url = try scratch()
            try Data("{ not json".utf8).write(to: url)
            let store = DocumentStore<Note>(url: url, environment: [:], resolve: { document, _ in document })

            #expect(await store.failure() != nil)
            await #expect(throws: ConfigError.self) {
                _ = try await store.mutate { $0.title = "clobber" }
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        }

        @Test("resolution is published but never written")
        func resolutionIsPublishOnly() async throws {
            let url = try scratch()
            let store = DocumentStore<Note>(
                url: url,
                environment: ["ARC_NOTE": "overlay"],
                resolve: { note, environment in
                    var copy = note
                    copy.title = environment["ARC_NOTE"] ?? note.title
                    return copy
                }
            )

            _ = try await store.mutate { $0.body = "kept" }
            let snapshot = await store.snapshot()

            #expect(snapshot.resolved.title == "overlay")
            #expect(try DocumentStore<Note>.read(url).title == "")
        }
    }
}
