import Foundation
import Testing
@testable import arc_agent_webui

/// Regression coverage for the storage-backend toggle (Settings → Storage).
///
/// The toggle must be able to move the runtime **cleanly** between the file
/// and Tessera stores. A boot-time Tessera probe timeout sets the transient
/// `runtimeTesseraOff` flag (forceTesseraOff); if the user then flips the
/// toggle back to Tessera, that explicit choice must clear the transient
/// flag — otherwise the runtime silently stays on file storage until the
/// process is restarted (observed design flaw, Sep 2026).
@MainActor
@Suite("Storage backend toggle", .serialized)
struct StorageToggleTests {

    /// Settings persistence must never touch the user's real settings file
    /// during tests.
    private func withTempSettings<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-webui-test-settings-\(UUID().uuidString).json")
        AppState.settingsURLOverride = url
        defer {
            AppState.settingsURLOverride = nil
            try? FileManager.default.removeItem(at: url)
        }
        return try await body()
    }

    @Test("Explicit toggle to Tessera clears the boot-time fallback flag")
    func toggleBackClearsRuntimeFallback() async throws {
        try await withTempSettings {
            let app = try AppState()
            // Simulate a boot-time relay outage fallback (transient, in-memory).
            await app.forceTesseraOff()
            #expect(await app.runtimeTesseraOff)

            // User flips the toggle back to Tessera (checkbox unchecked).
            await app.setTesseraOff(false)

            // The transient fallback must be gone: the effective backend is
            // driven solely by the persisted preference now.
            #expect(await app.runtimeTesseraOff == false)
            #expect(await app.settings.tesseraOff == false)
        }
    }

    @Test("Toggle off persists and clears the fallback flag too")
    func toggleOffPersists() async throws {
        try await withTempSettings {
            let app = try AppState()
            await app.forceTesseraOff()
            await app.setTesseraOff(true)

            #expect(await app.settings.tesseraOff == true)
            #expect(await app.runtimeTesseraOff == false)
            // The persisted choice survives a cold reload of the settings file.
            let reloaded = AppState.loadSettings()
            #expect(reloaded.tesseraOff == true)
        }
    }
}
