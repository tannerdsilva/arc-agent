import Foundation
import PackagePlugin

/// Generates the web UI's embedded assets before every build: the vendored KaTeX files, and
/// the theme sheet (raw, content address, and pre-compressed form).
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
        let fileManager = FileManager.default
        var commands: [Command] = []

        // ── vendored KaTeX ────────────────────────────────────────
        let vendor = context.package.directory.appending(
            ["Sources", "ArcAgentWebUI", "Assets", "vendor", "katex"]
        )
        let fontsDir = vendor.appending("fonts")

        var katexInputs = [vendor.appending("katex.min.js"), vendor.appending("katex.min.css")]
        let fontNames = (try? fileManager.contentsOfDirectory(atPath: fontsDir.string)) ?? []
        for name in fontNames.sorted() where name.hasSuffix(".woff2") {
            katexInputs.append(fontsDir.appending(name))
        }

        let katexOutput = context.pluginWorkDirectory.appending("KaTeXAssets.swift")
        commands.append(
            .buildCommand(
                displayName: "Embed vendored KaTeX assets",
                executable: tool.path,
                arguments: ["katex", vendor.string, katexOutput.string],
                inputFiles: katexInputs,
                outputFiles: [katexOutput]
            )
        )

        // ── the theme sheet ───────────────────────────────────────
        // the inputs are the theme sources, so a palette edit re-runs the tool even though the
        // tool binary itself would change too (belt and braces: an output that lags its input
        // is exactly the drift this plugin exists to prevent).
        let themeDir = context.package.directory.appending(["Sources", "ArcTheme"])
        let themeInputs = ((try? fileManager.contentsOfDirectory(atPath: themeDir.string)) ?? [])
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { themeDir.appending($0) }

        let sheetOutput = context.pluginWorkDirectory.appending("ThemeSheetAssets.swift")
        commands.append(
            .buildCommand(
                displayName: "Render the theme sheet (raw + gzip + content address)",
                executable: tool.path,
                arguments: ["theme-sheet", sheetOutput.string],
                inputFiles: themeInputs,
                outputFiles: [sheetOutput]
            )
        )

        return commands
    }
}