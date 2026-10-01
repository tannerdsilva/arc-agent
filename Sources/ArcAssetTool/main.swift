import ArcTheme
import Foundation
import WebUIBuild

// arc-agent-webui's asset generator: the served theme sheet.
//
// invoked by `ArcAssetPlugin` on every build — there is no shell script and no hand-run step.
//
//   usage: ArcAssetTool theme-sheet <out.swift>
//
// the body is one call into `WebUIBuild`: the framework renders the payload's address,
// compresses it and writes the declaration, and this tool exists only because a SwiftPM
// build-tool plugin cannot import a consumer's own theme types (it cannot render them itself).

let arguments = CommandLine.arguments

guard arguments.count == 3, arguments[1] == "theme-sheet" else {
    FileHandle.standardError.write(
        Data("usage: ArcAssetTool theme-sheet <out.swift>\n".utf8)
    )
    exit(2)
}

let output = URL(fileURLWithPath: arguments[2])

do {
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let emitted = try WebUIAssetBuilder.emit(
        shipped: Theme.css + ArcThemeCatalog.stylesheet(),
        typeName: "ThemeSheetAssets",
        options: .init(minify: false, prose: .off, contentType: "text/css; charset=utf-8"),
        to: output
    )
    print("  sheet \(emitted.bytes) bytes, stamp \(emitted.stamp), gzip \(emitted.gzipBytes ?? 0) bytes")
} catch {
    FileHandle.standardError.write(Data("ArcAssetTool: \(error)\n".utf8))
    exit(1)
}