import Testing
import Foundation
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {

    /// The retired `settings.moaEnabled` toggle (settings backbone, slice 2).
    ///
    /// MoA enablement is policy, not view state: it lives in
    /// `~/.arc/config.json` as `moa.enabled`. The old boolean is a decode-only
    /// legacy field, lifted once at boot and then cleared, so a second boot is
    /// a no-op and the key never comes back on write.
    @Suite("moa migration", .serialized)
    struct MoAMigrationTests {

        /// A config file at a scratch path holding exactly `json` (nil = no
        /// file at all, the "fresh install" case).
        private func configStore(_ json: String?) throws -> ConfigurationStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-moa-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            if let json { try Data(json.utf8).write(to: url) }
            return ConfigurationStore(url: url, environment: [:])
        }

        /// Settings decoded from exactly `json` — the shape an old
        /// `settings.json` has on disk.
        private func settings(_ json: String) throws -> AppSettings {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        }

        @Test("a legacy on-toggle lifts into moa.enabled")
        func liftsTrue() async throws {
            let store = try configStore("{}")   // no moa block: the compiled default
            let configURL = await store.snapshot().url
            var s = try settings("{\"moaEnabled\": true}")

            let lift = await AppState.liftLegacyMoA(s, configStore: store)
            s = lift.settings

            let onDisk = await store.declared()
            #expect(lift.clearedLegacyKey)
            #expect(lift.declared?.moa.enabled == true)
            #expect(onDisk.moa.enabled, "the lift is written through the store")
            #expect(s.moaEnabled == nil, "the legacy key is cleared after the lift")

            let encoded = try JSONEncoder().encode(s)
            let text = String(decoding: encoded, as: UTF8.self)
            #expect(!text.contains("moaEnabled"),
                    "a cleared legacy key must not be written back to settings.json")

            // and the file on disk carries the block the daemon will read.
            let written = try JSONDecoder().decode(ArcConfig.self,
                                                   from: Data(contentsOf: configURL))
            #expect(written.moa.enabled)
        }

        @Test("a legacy off-toggle leaves MoA off and writes nothing")
        func falseStaysOff() async throws {
            let store = try configStore("{}")
            let configURL = await store.snapshot().url
            var s = try settings("{\"moaEnabled\": false}")

            let lift = await AppState.liftLegacyMoA(s, configStore: store)
            s = lift.settings

            let onDisk = await store.declared()
            #expect(lift.clearedLegacyKey)
            #expect(lift.declared == nil, "off → the default off is not a write")
            #expect(onDisk.moa.enabled == false)
            #expect(!FileManager.default.fileExists(atPath: configURL.appendingPathExtension("bak").path),
                    "no backup means no write happened")
            #expect(s.moaEnabled == nil)
        }

        @Test("a config that already enables MoA keeps it, whatever the stale boolean says")
        func explicitTrueWins() async throws {
            for legacy in ["true", "false"] {
                let store = try configStore("{\"moa\":{\"enabled\":true}}")
                var s = try settings("{\"moaEnabled\": \(legacy)}")

                let lift = await AppState.liftLegacyMoA(s, configStore: store)
                s = lift.settings

                let onDisk = await store.declared()
                #expect(lift.clearedLegacyKey)
                #expect(lift.declared == nil, "enabled → enabled is not a write")
                #expect(onDisk.moa.enabled, "an explicit on stays on")
                #expect(s.moaEnabled == nil, "the stale key is still discarded")
            }
        }

        @Test("a second boot is a no-op")
        func idempotent() async throws {
            let store = try configStore("{}")
            let configURL = await store.snapshot().url
            var s = try settings("{\"moaEnabled\": true}")

            s = await AppState.liftLegacyMoA(s, configStore: store).settings
            // the lift wrote once and backed the old file up. Drop the backup:
            // any further write would recreate it.
            try FileManager.default.removeItem(at: configURL.appendingPathExtension("bak"))

            let second = await AppState.liftLegacyMoA(s, configStore: store)
            s = second.settings

            let onDisk = await store.declared()
            #expect(second.clearedLegacyKey == false)
            #expect(second.declared == nil)
            #expect(!FileManager.default.fileExists(atPath: configURL.appendingPathExtension("bak").path),
                    "the second pass must not write")
            #expect(onDisk.moa.enabled)
        }

        @Test("a render fixture owns no store and migrates nothing")
        func noStoreNoWrite() async throws {
            var s = try settings("{\"moaEnabled\": true}")

            let lift = await AppState.liftLegacyMoA(s, configStore: nil)
            s = lift.settings

            #expect(lift.clearedLegacyKey == false)
            #expect(lift.declared == nil)
            #expect(s.moaEnabled == true, "without a store the value stays in memory, untouched")
        }

        @Test("no legacy key means no read and no write")
        func absentKeyIsNoOp() async throws {
            let store = try configStore("{}")
            let s = try settings("{\"theme\": \"dark\"}")

            let lift = await AppState.liftLegacyMoA(s, configStore: store)

            #expect(lift.clearedLegacyKey == false)
            #expect(lift.declared == nil)
            #expect(lift.settings == s)
        }
    }
}
