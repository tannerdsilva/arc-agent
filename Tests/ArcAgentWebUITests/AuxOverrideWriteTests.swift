import Testing
import Foundation
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {

    /// Settings backbone, slice 5: the aux-model editor writes through the
    /// configuration store, like every other policy edit.
    ///
    /// `setAuxOverride` / `clearAuxOverride` used to read the in-memory
    /// declaration and write it back with `saveConfig`, which (a) bypassed the
    /// store's backup and decode-back and (b) wrote a *whole* config computed
    /// from a copy that could be stale, so an edit could erase sections it
    /// never touched. Both now go through ``AppState/updateConfig``.
    @Suite("aux override writes", .serialized)
    struct AuxOverrideWriteTests {

        /// A config file at a scratch path holding exactly `json`.
        private func scratchStore(_ json: String?) throws -> ConfigurationStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-aux-write-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            if let json { try Data(json.utf8).write(to: url) }
            return ConfigurationStore(url: url, environment: [:])
        }

        @Test("setAuxOverride writes through the store and publishes the declaration")
        func writesThroughStore() async throws {
            let store = try scratchStore("{}")
            let url = await store.snapshot().url
            let app = AppState(renderFixture: .init(), configurationStore: store)

            await app.setAuxOverride(
                task: .vision, provider: "openai", model: "gpt-vision",
                baseURL: "", apiKey: "")

            let declared = await store.declared()
            #expect(declared.auxiliary.byTask[.vision]?.model == "gpt-vision",
                    "the store owns the write, so its declaration carries the edit")

            let onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.auxiliary.byTask[.vision]?.model == "gpt-vision",
                    "and the bytes on disk agree")

            let inMemory = await app.arcConfig
            #expect(inMemory.auxiliary.byTask[.vision]?.model == "gpt-vision",
                    "the UI adopts the published snapshot")

            #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
                    "the store backs the file up before replacing it")
        }

        @Test("a refused write leaves arcConfig unchanged and surfaces the reason")
        func refusedWriteChangesNothing() async throws {
            let store = try scratchStore("{ not json")
            let url = await store.snapshot().url
            let before = try Data(contentsOf: url)
            let app = AppState(renderFixture: .init(), configurationStore: store)
            let configBefore = await app.arcConfig

            await app.setAuxOverride(
                task: .vision, provider: "openai", model: "gpt-vision",
                baseURL: "", apiKey: "")

            #expect(await app.arcConfig == configBefore,
                    "a refused write changes no in-memory state")
            #expect(try Data(contentsOf: url) == before,
                    "and no byte on disk")

            let toasts = await app.toasts
            #expect(toasts.contains { $0.kind == "error" && $0.text.contains("not saved") },
                    "the failure is surfaced; got: \(toasts.map { $0.text })")
        }

        @Test("clearAuxOverride removes the override from the declaration")
        func clearRemovesFromDeclaration() async throws {
            let store = try scratchStore(
                "{\"auxiliary\":{\"vision\":{\"provider\":\"openai\",\"model\":\"gpt-vision\"}}}")
            let app = AppState(renderFixture: .init(), configurationStore: store)

            await app.clearAuxOverride(task: .vision)

            let declared = await store.declared()
            #expect(declared.auxiliary.byTask[.vision] == nil,
                    "the clear edits the declaration, not a stale in-memory copy")
        }

        @Test("an all-empty override is a removal, through the same path")
        func emptyOverrideRemoves() async throws {
            let store = try scratchStore(
                "{\"auxiliary\":{\"vision\":{\"provider\":\"openai\",\"model\":\"gpt-vision\"}}}")
            let url = await store.snapshot().url
            let app = AppState(renderFixture: .init(), configurationStore: store)

            await app.setAuxOverride(task: .vision, provider: "", model: "", baseURL: "", apiKey: "")

            let declared = await store.declared()
            #expect(declared.auxiliary.byTask[.vision] == nil)
            let onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.auxiliary.byTask[.vision] == nil)
        }
    }
}
