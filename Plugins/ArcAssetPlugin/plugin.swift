import Foundation
import PackagePlugin

/// Generates the web UI's embedded theme sheet before every build: the raw bytes, their
/// content address, and their pre-compressed form.
///
/// The alternative was a hand-run script plus a checked-in generated file: two things that
/// silently drift when someone updates the input and forgets the second step. Running the
/// generator as a build-tool plugin makes each embedded asset a build product of its input —
/// and the theme sheet additionally makes the *served* bytes a build product, so the url a
/// page links, the bytes a server serves and the sha256 that names them cannot disagree.
@main
struct ArcAssetPlugin: BuildToolPlugin {

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "ArcAssetTool")

        // ── the theme sheet ───────────────────────────────────────
        // the inputs are the theme sources, so a palette edit re-runs the tool even though the
        // tool binary itself would change too (belt and braces: an output that lags its input
        // is exactly the drift this plugin exists to prevent).
        let themeDir = context.package.directory.appending(["Sources", "ArcTheme"])
        let themeInputs = ((try? FileManager.default.contentsOfDirectory(atPath: themeDir.string)) ?? [])
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { themeDir.appending($0) }

        let sheetOutput = context.pluginWorkDirectory.appending("ThemeSheetAssets.swift")
        return [
            .buildCommand(
                displayName: "Render the theme sheet (raw + gzip + content address)",
                executable: tool.path,
                arguments: ["theme-sheet", sheetOutput.string],
                inputFiles: themeInputs,
                outputFiles: [sheetOutput]
            )
        ]
    }
}