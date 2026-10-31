import Testing
import Foundation
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {

    /// The retired `settings.tesseraOff` / `settings.activeStorage` pair
    /// (settings backbone, slice 4).
    ///
    /// The storage medium is policy, not view state: it lives in
    /// `~/.arc/config.json` as `storage.active`. The old pair is decode-only,
    /// lifted once at boot, and cleared — so a second boot writes nothing and
    /// the keys never come back on a write.
    @Suite("storage migration", .serialized)
    struct StorageMigrationTests {

        private static let connection = TesseraStorageConnection(
            id: "conn-1",
            name: "Home node",
            serverIP: "10.0.0.5",
            serverPort: 51921,
            application: 7,
            serverPublicKey: "npub-server",
            myPrivateKey: "nsec-client-secret"
        )

        /// A config file at a scratch path holding exactly `json`
        /// (nil = no file at all, the "fresh install" case).
        private func configStore(_ json: String?) throws -> ConfigurationStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-s4-migration-\(UUID().uuidString)", isDirectory: true)
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

        private func backupExists(_ store: ConfigurationStore) async -> Bool {
            let url = await store.snapshot().url
            return FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path)
        }

        @Test("a legacy tessera-off toggle lifts into storage.active = file")
        func tesseraOffLiftsToFile() async throws {
            let store = try configStore(#"""
            {"tessera": {"serverIP": "10.0.0.5", "serverPort": 51921,
                         "serverPublicKey": "npub-server", "myPrivateKey": "",
                         "application": 7}}
            """#)
            var s = try settings(#"{"tesseraOff": true, "activeStorage": "config"}"#)

            let lift = await AppState.liftLegacyStoragePolicy(s, configStore: store)
            s = lift.settings

            #expect(lift.clearedLegacyKeys)
            #expect(lift.declared?.storage.active == StorageMedium.file.rawValue)
            #expect(await store.declared().storage.active == StorageMedium.file.rawValue,
                    "the lift is written through the store")
            #expect(StoreSelection.resolve(await store.resolved()).backend == .file,
                    "the daemon's resolver reads the same medium")
            #expect(s.tesseraOff == nil, "the legacy toggle is cleared after the lift")
            #expect(s.activeStorage == nil, "the legacy picker key is cleared too")

            let encoded = try JSONEncoder().encode(s)
            let text = String(decoding: encoded, as: UTF8.self)
            #expect(!text.contains("tesseraOff"))
            #expect(!text.contains("activeStorage"))
        }

        @Test("a legacy config.json selection lifts into tessera")
        func configMediumLiftsToTessera() async throws {
            let store = try configStore(#"""
            {"tessera": {"serverIP": "10.0.0.5", "serverPort": 51921,
                         "serverPublicKey": "npub-server", "myPrivateKey": "",
                         "application": 7}}
            """#)
            var s = try settings(#"{"activeStorage": "config"}"#)

            let lift = await AppState.liftLegacyStoragePolicy(s, configStore: store)
            s = lift.settings

            #expect(await store.declared().storage.active == StorageMedium.tessera.rawValue)
            #expect(StoreSelection.resolve(await store.resolved()).backend == .tessera)
            #expect(s.activeStorage == nil)
        }

        @Test("a legacy file selection lifts into file")
        func fileMediumLiftsToFile() async throws {
            let store = try configStore("{}")
            var s = try settings(#"{"activeStorage": "file"}"#)

            let lift = await AppState.liftLegacyStoragePolicy(s, configStore: store)
            s = lift.settings

            #expect(await store.declared().storage.active == StorageMedium.file.rawValue)
            #expect(s.activeStorage == nil)
        }

        @Test("a saved connection lifts only when its tunnel is already in config.json")
        func connectionLiftsOnlyWithItsBlock() async throws {
            let withBlock = try configStore(#"""
            {"tessera": {"serverIP": "10.0.0.5", "serverPort": 51921,
                         "serverPublicKey": "npub-server", "myPrivateKey": "",
                         "application": 7}}
            """#)
            var lifted = try settings(#"{"activeStorage": "conn-1", "storageConnections": [{"id": "conn-1", "name": "Home node", "serverIP": "10.0.0.5", "serverPort": 51921, "application": 7, "serverPublicKey": "npub-server", "myPrivateKey": "nsec-client-secret"}]}"#)

            let lift = await AppState.liftLegacyStoragePolicy(lifted, configStore: withBlock)
            lifted = lift.settings

            #expect(await withBlock.declared().storage.active == StorageMedium.tessera.rawValue)
            #expect(StoreSelection.resolve(await withBlock.resolved()).backend == .tessera)
            #expect(lifted.activeStorage == nil)

            // …and without the block the selection is left alone for the
            // picker: guessing would put the install on a relay the file does
            // not describe.
            let withoutBlock = try configStore("{}")
            var kept = try settings(#"{"activeStorage": "conn-1", "storageConnections": [{"id": "conn-1", "name": "Home node", "serverIP": "10.0.0.5", "serverPort": 51921, "application": 7, "serverPublicKey": "npub-server", "myPrivateKey": "nsec-client-secret"}]}"#)

            let blocked = await AppState.liftLegacyStoragePolicy(kept, configStore: withoutBlock)
            kept = blocked.settings

            #expect(blocked.clearedLegacyKeys == false)
            #expect(blocked.unmigratedSelection == "conn-1")
            #expect(kept.activeStorage == "conn-1", "the intent survives until the block lands")
            #expect(await withoutBlock.declared().storage.active == nil, "no policy is invented")
            let blockedBackup = await backupExists(withoutBlock)
            #expect(!blockedBackup, "and nothing is written")
        }

        @Test("a second boot is a no-op")
        func idempotent() async throws {
            let store = try configStore("{}")
            var s = try settings(#"{"activeStorage": "config"}"#)

            s = await AppState.liftLegacyStoragePolicy(s, configStore: store).settings
            let url = await store.snapshot().url
            // the lift wrote once and backed the old file up. Drop the backup:
            // any further write would recreate it.
            try FileManager.default.removeItem(at: url.appendingPathExtension("bak"))

            let second = await AppState.liftLegacyStoragePolicy(s, configStore: store)
            s = second.settings

            #expect(second.clearedLegacyKeys == false)
            #expect(second.declared == nil)
            let secondBackup = await backupExists(store)
            #expect(!secondBackup, "the second pass must not write")
            #expect(await store.declared().storage.active == StorageMedium.tessera.rawValue)
        }

        @Test("an explicit policy in the file wins over the stale pair")
        func explicitPolicyWins() async throws {
            let store = try configStore(#"{"storage": {"active": "tessera"}, "tessera": {"serverIP": "10.0.0.5", "serverPort": 51921, "serverPublicKey": "npub-server", "myPrivateKey": "", "application": 7}}"#)
            var s = try settings(#"{"tesseraOff": true}"#)

            let lift = await AppState.liftLegacyStoragePolicy(s, configStore: store)
            s = lift.settings

            #expect(lift.clearedLegacyKeys)
            #expect(lift.declared == nil, "a policy that already holds is not rewritten")
            #expect(await store.declared().storage.active == StorageMedium.tessera.rawValue)
            let policyBackup = await backupExists(store)
            #expect(!policyBackup)
            #expect(s.tesseraOff == nil, "the stale key is still discarded")
        }

        @Test("a render fixture owns no store and migrates nothing")
        func noStoreNoWrite() async throws {
            var s = try settings(#"{"tesseraOff": true}"#)

            let lift = await AppState.liftLegacyStoragePolicy(s, configStore: nil)
            s = lift.settings

            #expect(lift.clearedLegacyKeys == false)
            #expect(lift.declared == nil)
            #expect(s.tesseraOff == true, "without a store the value stays in memory, untouched")
        }

        @Test("no legacy keys means no read and no write")
        func absentKeysAreNoOp() async throws {
            let store = try configStore("{}")
            let s = try settings(#"{"theme": "dark"}"#)

            let lift = await AppState.liftLegacyStoragePolicy(s, configStore: store)

            #expect(lift.clearedLegacyKeys == false)
            #expect(lift.declared == nil)
            #expect(lift.settings == s)
            let absentBackup = await backupExists(store)
            #expect(!absentBackup)
        }

        @Test("the retired keys decode to nil and are omitted on write")
        func retiredKeysAreDecodeOnly() throws {
            let legacy = try settings(#"{"tesseraOff": false, "activeStorage": "conn-9"}"#)
            #expect(legacy.tesseraOff == false)
            #expect(legacy.activeStorage == "conn-9")
            // the declarations are optionals: a settings document that never
            // carried them decodes to nil, which is what the encoder omits.
            #expect(try settings("{}").tesseraOff == nil)
            #expect(try settings("{}").activeStorage == nil)
        }
    }
}
