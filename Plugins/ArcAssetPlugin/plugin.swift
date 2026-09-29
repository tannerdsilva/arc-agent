import Foundation
import PackagePlugin

/// Embeds the vendored KaTeX assets before every build of the web UI target.
///
/// The alternative was a hand-run Python script plus a checked-in generated
/// file: two things that silently drift when someone updates
/// `Assets/vendor/katex/` and forgets the second step. Running the generator as
/// a build-tool plugin makes the embedded asset a build product of its input,
/// so it cannot be stale — and there is no shell script in the loop.
@main
struct ArcAssetPlugin: BuildToolPlugin {

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "ArcAssetTool")

        let vendor = context.package.directory.appending(
            ["Sources", "ArcAgentWebUI", "Assets", "vendor", "katex"]
        )
        let fontsDir = vendor.appending("fonts")

        var inputs = [vendor.appending("katex.min.js"), vendor.appending("katex.min.css")]
        let fontNames = (try? FileManager.default.contentsOfDirectory(atPath: fontsDir.string)) ?? []
        for name in fontNames.sorted() where name.hasSuffix(".woff2") {
            inputs.append(fontsDir.appending(name))
        }

        let output = context.pluginWorkDirectory.appending("KaTeXAssets.swift")

        return [
            .buildCommand(
                displayName: "Embed vendored KaTeX assets",
                executable: tool.path,
                arguments: [vendor.string, output.string],
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}