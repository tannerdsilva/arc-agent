import ArgumentParser
import Foundation
import ArcAgentCore

// MARK: - Batch (reference `batch_runner.py`)

/// Run the agent across many prompts in parallel and export ShareGPT
/// trajectories (reference `batch_runner.py`).
struct BatchCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Run prompts in parallel and export ShareGPT trajectories (reference batch_runner).",
        discussion: """
            Processes a JSONL dataset of prompts through fresh agent instances with
            bounded parallelism, writing ShareGPT-format trajectories, statistics,
            and a resume checkpoint under data/<run_name>/.

            Examples:
              arc batch --dataset-file=data.jsonl --batch-size=10 --run-name=my_run
              arc batch --dataset-file=data.jsonl --batch-size=10 --run-name=my_run --resume
              arc batch --list-distributions
            """
    )

    @Option(name: .shortAndLong, help: "Path to JSONL dataset (each line: {\"prompt\": ...}).")
    var datasetFile: String?

    @Option(name: .long, help: "Number of prompts per batch.")
    var batchSize: Int?

    @Option(name: .long, help: "Name of the run (output directory data/<name>).")
    var runName: String?

    @Option(name: .long, help: "Toolset distribution (default: default).")
    var distribution: String = "default"

    @Option(name: .shortAndLong, help: "Model to use.")
    var model: String?

    @Option(name: .long, help: "API key.")
    var apiKey: String?

    @Option(name: .long, help: "API base URL.")
    var baseURL: String?

    @Option(name: .long, help: "Maximum tool iterations per prompt (default: 10).")
    var maxTurns: Int = 10

    @Option(name: .shortAndLong, help: "Number of parallel workers (default: 4).")
    var numWorkers: Int = 4

    @Flag(name: .long, help: "Resume from an interrupted run (content-matched).")
    var resume: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose output.")
    var verbose: Bool = false

    @Option(name: .long, help: "System prompt used during execution but NOT saved to trajectories.")
    var ephemeralSystemPrompt: String?

    @Option(name: .long, help: "Characters shown in log previews (default: 100).")
    var logPrefixChars: Int = 100

    @Option(name: .long, help: "Only process the first N samples.")
    var maxSamples: Int?

    @Flag(name: .long, help: "List available toolset distributions and exit.")
    var listDistributions: Bool = false

    func run() async throws {
        let arcConfig = loadConfig()
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let allToolsets = Array(Set(registry.allTools.map(\.toolset))).sorted()
        let allToolNames = Set(registry.allTools.map(\.name))

        if listDistributions {
            print("📊 Available Toolset Distributions")
            print(String(repeating: "=", count: 70))
            for dist in BatchDistribution.registry(universe: allToolsets).sorted(by: { $0.name < $1.name }) {
                let weights = dist.weights.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)%" }.joined(separator: ", ")
                print("  \(dist.name) — \(dist.description)")
                print("      toolsets: \(weights)")
            }
            print("""

            💡 Usage:
              arc batch --dataset-file=data.jsonl --batch-size=10 \\
                         --run-name=my_run --distribution=<name>
            """)
            return
        }

        guard let datasetFile, let batchSize, let runName else {
            print("❌ Error: --dataset-file, --batch-size and --run-name are required")
            return
        }
        guard batchSize >= 1 else {
            print("❌ Error: --batch_size must be a positive integer")
            return
        }

        let resolvedModel = model
            ?? ProcessInfo.processInfo.environment["ARC_MODEL"]
            ?? arcConfig.model.defaultModel

        let options = BatchOptions(
            datasetFile: datasetFile,
            batchSize: batchSize,
            runName: runName,
            distribution: distribution,
            model: resolvedModel,
            apiKey: apiKey,
            baseURL: baseURL,
            maxTurns: maxTurns,
            numWorkers: numWorkers,
            resume: resume,
            verbose: verbose,
            ephemeralSystemPrompt: ephemeralSystemPrompt,
            logPrefixChars: logPrefixChars,
            maxSamples: maxSamples
        )
        let runner = BatchRunner(options: options, allToolsets: allToolsets, allToolNames: allToolNames)
        _ = try await runner.run()
    }
}
