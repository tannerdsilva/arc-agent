import Testing
import Foundation
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {

    /// The retired `settings.smartApproval` toggle (settings backbone, slice 1).
    ///
    /// One approval policy, one key: `security.approvalMode`. The old boolean is
    /// a decode-only legacy field, lifted once at boot and then cleared, so a
    /// second boot is a no-op and the key never comes back on write.
    @Suite("smart approval migration", .serialized)
    struct SmartApprovalMigrationTests {

        private func scratch() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-approval-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("config.json")
        }

        /// A config store whose file is exactly `json`.
        private func configStore(_ json: String) throws -> ConfigurationStore {
            let url = try scratch()
            try Data(json.utf8).write(to: url)
            return ConfigurationStore(url: url, environment: [:])
        }

        /// Settings decoded from exactly `json` — the shape an old
        /// `settings.json` has on disk.
        private func settings(_ json: String) throws -> AppSettings {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        }

        @Test("a legacy on-toggle lifts into approvalMode smart")
        func liftsTrueToSmart() async throws {
            let store = try configStore("{\"security\":{\"approvalMode\":\"manual\"}}")
            var s = try settings("{\"smartApproval\": true}")

            let lift = await AppState.liftLegacySmartApproval(s, configStore: store)
            s = lift.settings

            let onDisk = await store.declared()
            #expect(lift.clearedLegacyKey)
            #expect(lift.declared?.security.approvalMode == "smart")
            #expect(onDisk.security.approvalMode == "smart")
            #expect(s.smartApproval == nil, "the legacy key is cleared after the lift")
            let encoded = try JSONEncoder().encode(s)
            let text = String(decoding: encoded, as: UTF8.self)
            #expect(!text.contains("smartApproval"),
                    "a cleared legacy key must not be written back to settings.json")
        }

        @Test("a legacy off-toggle leaves the default manual in place")
        func falseStaysManual() async throws {
            let store = try configStore("{\"security\":{\"approvalMode\":\"manual\"}}")
            let configURL = await store.snapshot().url
            var s = try settings("{\"smartApproval\": false}")

            let lift = await AppState.liftLegacySmartApproval(s, configStore: store)
            s = lift.settings

            let onDisk = await store.declared()
            #expect(lift.clearedLegacyKey)
            #expect(lift.declared == nil, "manual → manual is not a write")
            #expect(onDisk.security.approvalMode == "manual")
            #expect(!FileManager.default.fileExists(atPath: configURL.appendingPathExtension("bak").path),
                    "no backup means no write happened")
        }

        @Test("an explicit mode wins over the stale boolean")
        func explicitModeWins() async throws {
            for explicit in ["off", "smart"] {
                let store = try configStore("{\"security\":{\"approvalMode\":\"\(explicit)\"}}")
                var s = try settings("{\"smartApproval\": true}")

                let lift = await AppState.liftLegacySmartApproval(s, configStore: store)
                s = lift.settings

                let onDisk = await store.declared()
                #expect(lift.clearedLegacyKey)
                #expect(lift.declared == nil, "the explicit mode is not rewritten")
                #expect(onDisk.security.approvalMode == explicit)
                #expect(s.smartApproval == nil, "the stale key is still discarded")
            }
        }

        @Test("a second boot is a no-op")
        func idempotent() async throws {
            let store = try configStore("{\"security\":{\"approvalMode\":\"manual\"}}")
            let configURL = await store.snapshot().url
            var s = try settings("{\"smartApproval\": true}")

            s = await AppState.liftLegacySmartApproval(s, configStore: store).settings
            // the lift wrote once and backed the old file up. Drop the backup:
            // any further write would recreate it.
            try FileManager.default.removeItem(at: configURL.appendingPathExtension("bak"))

            let second = await AppState.liftLegacySmartApproval(s, configStore: store)
            s = second.settings

            let onDisk = await store.declared()
            #expect(second.clearedLegacyKey == false)
            #expect(second.declared == nil)
            #expect(!FileManager.default.fileExists(atPath: configURL.appendingPathExtension("bak").path),
                    "the second pass must not write")
            #expect(onDisk.security.approvalMode == "smart")
        }

        @Test("a render fixture owns no store and migrates nothing")
        func noStoreNoWrite() async throws {
            var s = try settings("{\"smartApproval\": true}")

            let lift = await AppState.liftLegacySmartApproval(s, configStore: nil)
            s = lift.settings

            #expect(lift.clearedLegacyKey == false)
            #expect(lift.declared == nil)
            #expect(s.smartApproval == true, "without a store the value stays in memory, untouched")
        }
    }

    /// The Settings → Assistance switch is a view of the one policy.
    @Suite("settings approval switch", .serialized)
    struct SettingsApprovalSwitchTests {

        /// The `<input …>` tag carrying `id="set-smart-approval"`.
        private func switchTag(_ html: String) -> Substring? {
            guard let idRange = html.range(of: "id=\"set-smart-approval\"") else { return nil }
            // the nearest `<input` BEFORE the id (a forward search from the top
            // of the page would span every earlier control).
            let head = html[html.startIndex..<idRange.lowerBound]
            let start = head.range(of: "<input", options: .backwards)?.lowerBound
                ?? idRange.lowerBound
            let end = html.range(of: ">", range: idRange.upperBound..<html.endIndex)?.upperBound
                ?? idRange.upperBound
            return html[start..<end]
        }

        private func settingsMain(_ configure: (inout AppState.RenderFixture) -> Void) async -> String {
            var fixture = AppState.RenderFixture()
            fixture.settings.theme = "light"
            configure(&fixture)
            return await AppState(renderFixture: fixture).settingsMain().markup.html
        }

        @Test("the switch is on exactly when the policy says smart")
        func switchRendersTheMode() async {
            for (mode, expected) in [("smart", true), ("manual", false), ("off", false)] {
                let html = await settingsMain { $0.arcConfig.security.approvalMode = mode }
                let tag = switchTag(html)
                #expect(tag != nil, "the assistance section must render the smart-approval switch")
                #expect(tag?.contains("checked") == expected,
                        "approvalMode \(mode) must render the switch \(expected ? "on" : "off")")
            }
        }

        @Test("the switch does not read a stored toggle")
        func switchDoesNotReadSettings() throws {
            let views = (try? String(contentsOfFile: "Sources/ArcWebUI/Views.swift",
                                     encoding: .utf8)) ?? ""
            #expect(!views.isEmpty)
            #expect(!views.contains("settings.smartApproval"),
                    "the switch must read security.approvalMode, not a settings.json toggle")
            let state = (try? String(contentsOfFile: "Sources/ArcWebUI/AppState.swift",
                                     encoding: .utf8)) ?? ""
            #expect(!state.contains("smartApproval: settings."),
                    "nothing may pass a settings smartApproval into the approval manager")
        }
    }
}
