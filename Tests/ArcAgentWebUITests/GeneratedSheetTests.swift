import CryptoKit
import Foundation
import Testing

import ArcTheme
@testable import arc_agent_webui

/// The served sheet is a build product: `ArcAssetTool theme-sheet` renders it from
/// `Sources/ArcTheme/`, stamps it with the sha256 its url carries, and gzips it.
///
/// These tests are the drift guard. A plugin that silently stopped re-running — the failure
/// mode the plugin exists to prevent — a stamp that names other bytes than the server serves,
/// or a gzip that inflates to something else, fails here rather than on a page.
@Suite("Generated theme sheet")
struct GeneratedSheetTests {

    @Test("the generated sheet is exactly what the theme source emits")
    func sheetMatchesTheSource() {
        #expect(ThemeSheetAssets.sheet == Theme.css + ArcThemeCatalog.stylesheet())
    }

    @Test("the stamp is the sha256 prefix of the served bytes")
    func stampNamesTheBytes() {
        let digest = SHA256.hash(data: Data(ThemeSheetAssets.sheet.utf8))
        let expected = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        #expect(ThemeSheetAssets.stamp == expected)
        #expect(ThemeSheetAssets.stamp.count == 12)
    }

    @Test("the gzip variant inflates to the served sheet, byte for byte")
    func gzipInflatesToTheSheet() throws {
        let gzip = ThemeSheetAssets.gzip
        // no gzip in the product means the build host had none: the server serves the
        // uncompressed form, and there is nothing to assert.
        guard !gzip.isEmpty else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/gunzip") else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-sheet-\(UUID().uuidString).css.gz")
        try Data(gzip).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", tmp.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        // drain before waiting, or a payload larger than the pipe buffer deadlocks.
        let inflated = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: inflated, as: UTF8.self) == ThemeSheetAssets.sheet)
        // the point of the variant: it is smaller than the bytes it stands for.
        #expect(gzip.count < ThemeSheetAssets.sheet.utf8.count)
    }
}