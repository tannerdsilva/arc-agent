import ArcWebUI
import ArgumentParser

// MARK: - Entry point

@main
struct ArcAgentWebUI: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "arc-agent-webui",
        abstract: "ARC Agent web UI (no-webui engine).",
        discussion: """
        Serves the ARC Agent interface: chat, skills, profiles, tools,
        workspaces and settings — built entirely on the no-webui Swift
        library. Sessions and memory use the same stores as the CLI.
        """
    )

    @Option(name: .shortAndLong, help: "Host to bind.")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Port to bind.")
    var port: Int = 8890

    @Flag(name: .long, help: "Use file storage instead of Tessera.")
    var tesseraOff: Bool = false

    func run() async throws {
        let ui = try WebUIHost(host: host, port: port, tesseraOff: tesseraOff)
        try await ui.run()
    }
}