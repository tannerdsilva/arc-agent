import Foundation

// MARK: - Batch runner (reference `batch_runner.py`)

/// Options for a batch run (reference CLI flags).
public struct BatchOptions: Sendable {
    public var datasetFile: String
    public var batchSize: Int
    public var runName: String
    public var distribution: String = "default"
    public var model: String
    public var apiKey: String?
    public var baseURL: String?
    public var maxTurns: Int = 10
    public var numWorkers: Int = 4
    public var resume: Bool = false
    public var verbose: Bool = false
    public var ephemeralSystemPrompt: String?
    public var logPrefixChars: Int = 100
    public var maxSamples: Int?

    public init(
        datasetFile: String, batchSize: Int, runName: String,
        distribution: String = "default", model: String, apiKey: String? = nil,
        baseURL: String? = nil, maxTurns: Int = 10, numWorkers: Int = 4,
        resume: Bool = false, verbose: Bool = false,
        ephemeralSystemPrompt: String? = nil, logPrefixChars: Int = 100,
        maxSamples: Int? = nil
    ) {
        self.datasetFile = datasetFile
        self.batchSize = batchSize
        self.runName = runName
        self.distribution = distribution
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maxTurns = maxTurns
        self.numWorkers = numWorkers
        self.resume = resume
        self.verbose = verbose
        self.ephemeralSystemPrompt = ephemeralSystemPrompt
        self.logPrefixChars = logPrefixChars
        self.maxSamples = maxSamples
    }
}

/// Per-batch outcome returned by a worker.
struct BatchOutcome: Sendable {
    let batchNum: Int
    let processed: Int
    let skipped: Int
    let discardedNoReasoning: Int
    let completedPrompts: [Int]
    let toolStats: [String: ToolCallStat]
    let reasoning: ReasoningStats
    static func merged(_ results: [BatchOutcome]) -> BatchOutcome {
        BatchOutcome(
            batchNum: -1,
            processed: results.reduce(0) { $0 + $1.processed },
            skipped: results.reduce(0) { $0 + $1.skipped },
            discardedNoReasoning: results.reduce(0) { $0 + $1.discardedNoReasoning },
            completedPrompts: results.flatMap(\.completedPrompts),
            toolStats: results.reduce([:]) { merged, next in
                var m = merged
                for (name, stat) in next.toolStats {
                    var s = m[name] ?? ToolCallStat()
                    s.count += stat.count; s.success += stat.success; s.failure += stat.failure
                    m[name] = s
                }
                return m
            },
            reasoning: results.reduce(ReasoningStats()) { $0.merged($1.reasoning) }
        )
    }
}

struct ReasoningStats: Sendable {
    var totalAssistantTurns = 0
    var turnsWithReasoning = 0
    var turnsWithoutReasoning = 0
    mutating func merge(_ other: ReasoningStats) {
        totalAssistantTurns += other.totalAssistantTurns
        turnsWithReasoning += other.turnsWithReasoning
        turnsWithoutReasoning += other.turnsWithoutReasoning
    }
    func merged(_ other: ReasoningStats) -> ReasoningStats {
        var r = self
        r.merge(other)
        return r
    }
}

/// Immutable per-run state handed to concurrent workers (region-safe: no
/// actor `self` capture inside TaskGroup closures).
struct BatchContext: Sendable {
    let options: BatchOptions
    let outputDir: URL
    let allToolsets: [String]
    let allToolNames: Set<String>
}

/// Runs a dataset of prompts through fresh agent instances in parallel,
/// writing ShareGPT trajectories, statistics, and a resume checkpoint
/// (reference `BatchRunner`).
public actor BatchRunner {

    private let options: BatchOptions
    private let outputDir: URL

    private let allToolsets: [String]
    private let allToolNames: Set<String>

    public init(options: BatchOptions, allToolsets: [String], allToolNames: Set<String>) {
        self.options = options
        self.allToolsets = allToolsets
        self.allToolNames = allToolNames
        self.outputDir = URL(fileURLWithPath: "data", isDirectory: true)
            .appendingPathComponent(options.runName, isDirectory: true)
    }

    /// Output directory (`data/<run_name>`).
    public func outputDirectory() -> URL { outputDir }

    // MARK: - Run

    public func run() async throws -> Bool {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var dataset = try BatchDatasetLoader.load(URL(fileURLWithPath: options.datasetFile))
        let total = dataset.count
        if let maxSamples = options.maxSamples, maxSamples < dataset.count {
            print("✂️  Truncated dataset from \(dataset.count) to \(maxSamples) samples (--max_samples)")
            dataset = Array(dataset.prefix(maxSamples))
        }
        guard !dataset.isEmpty else {
            print("❌ Error: dataset is empty")
            return false
        }
        guard options.batchSize >= 1 else {
            print("❌ Error: --batch_size must be a positive integer")
            return false
        }

        guard let distribution = BatchDistribution.named(options.distribution, universe: allToolsets) else {
            print("❌ Error: Unknown distribution: \(options.distribution). Available: \(BatchDistribution.registry(universe: allToolsets).map(\.name))")
            return false
        }

        // Chunk into batches: [(batchNum, [(datasetIndex, entry)])].
        var builtBatches: [(Int, [(Int, BatchDatasetEntry)])] = []
        var current: [(Int, BatchDatasetEntry)] = []
        for (index, entry) in dataset.enumerated() {
            current.append((index, entry))
            if current.count == options.batchSize {
                builtBatches.append((builtBatches.count, current))
                current = []
            }
        }
        if !current.isEmpty { builtBatches.append((builtBatches.count, current)) }
        // Immutable copy: TaskGroup closures are `sending`, and mutable
        // locals cannot be captured concurrently (region isolation).
        let batches = builtBatches

        print("📊 Batch Runner Initialized")
        print("   Dataset: \(options.datasetFile) (\(dataset.count) prompts)")
        print("   Batch size: \(options.batchSize)")
        print("   Total batches: \(batches.count)")
        print("   Run name: \(options.runName)")
        print("   Distribution: \(options.distribution)")
        print("   Output directory: \(outputDir.path)")
        print("   Workers: \(options.numWorkers)")

        // Resume: content-match completed prompts from existing batch files.
        var completedPromptTexts = Set<String>()
        if options.resume {
            completedPromptTexts = await scanCompletedPrompts()
            if !completedPromptTexts.isEmpty {
                print("   Found \(completedPromptTexts.count) already-completed prompts by content matching")
            }
        }

        let ctx = BatchContext(
            options: options, outputDir: outputDir,
            allToolsets: allToolsets, allToolNames: allToolNames
        )
        let workerCount = max(1, options.numWorkers)
        let startTime = Date()

        // Parallel batch processing — static helper: TaskGroup closures are
        // `sending`, so no actor-isolated state may be captured (see
        // ToolBatchExecutor for the same shape).
        let outcomes = await Self.runParallel(
            ctx: ctx, batches: batches, distribution: distribution,
            completedPromptTexts: completedPromptTexts, workerCount: workerCount
        )

        // ── Aggregate + finalize ───────────────────────────────────────────
        var totalToolStats: [String: ToolCallStat] = [:]
        var totalReasoning = ReasoningStats()
        var totalProcessed = 0
        var totalSkipped = 0
        var totalDiscarded = 0
        for outcome in outcomes {
            for (name, stat) in outcome.toolStats {
                var s = totalToolStats[name] ?? ToolCallStat()
                s.count += stat.count; s.success += stat.success; s.failure += stat.failure
                totalToolStats[name] = s
            }
            totalReasoning.merge(outcome.reasoning)
            totalProcessed += outcome.processed
            totalSkipped += outcome.skipped
            totalDiscarded += outcome.discardedNoReasoning
        }

        // Success rates (reference: per-tool success/failure percent).
        var normalized: [String: [String: Double]] = [:]
        for (name, stat) in totalToolStats {
            let totalCalls = stat.success + stat.failure
            let successRate = totalCalls > 0 ? Double(stat.success) / Double(totalCalls) * 100 : 0
            let failureRate = totalCalls > 0 ? Double(stat.failure) / Double(totalCalls) * 100 : 0
            normalized[name] = [
                "count": Double(stat.count),
                "success": Double(stat.success),
                "failure": Double(stat.failure),
                "success_rate": (successRate * 100).rounded() / 100,
                "failure_rate": (failureRate * 100).rounded() / 100,
            ]
        }

        let duration = Date().timeIntervalSince(startTime)
        let finalStats: [String: Any] = [
            "run_name": options.runName,
            "distribution": options.distribution,
            "total_prompts": total,
            "total_batches": batches.count,
            "batch_size": options.batchSize,
            "model": options.model,
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "duration_seconds": (duration * 100).rounded() / 100,
            "processed": totalProcessed,
            "skipped": totalSkipped,
            "discarded_no_reasoning": totalDiscarded,
            "tool_statistics": normalized,
            "reasoning_statistics": [
                "total_assistant_turns": totalReasoning.totalAssistantTurns,
                "turns_with_reasoning": totalReasoning.turnsWithReasoning,
                "turns_without_reasoning": totalReasoning.turnsWithoutReasoning,
            ],
        ]
        try Self.writePrettyJSON(finalStats, to: outputDir.appendingPathComponent("statistics.json"))

        // Checkpoint (reference checkpoint.json: completed_prompts + batch_stats).
        var checkpoint: [String: Any] = ["completed_prompts": outcomes.flatMap(\.completedPrompts).sorted()]
        var batchStats: [String: [String: Int]] = [:]
        for outcome in outcomes where outcome.batchNum >= 0 {
            batchStats["\(outcome.batchNum)"] = [
                "processed": outcome.processed,
                "skipped": outcome.skipped,
                "discarded_no_reasoning": outcome.discardedNoReasoning,
            ]
        }
        checkpoint["batch_stats"] = batchStats
        try Self.writePrettyJSON(checkpoint, to: outputDir.appendingPathComponent("checkpoint.json"))

        // Combine all batch files into trajectories.jsonl (filter corrupted).
        let combined = try Self.combineTrajectories(ctx: ctx)

        print("\n📦 Combined batch files into \(outputDir.appendingPathComponent("trajectories.jsonl").lastPathComponent) (\(combined) entries)")
        print("✅ Statistics written to \(outputDir.appendingPathComponent("statistics.json").path)")
        return true
    }

    // MARK: - Parallel batch execution (nonisolated static: region-safe)

    nonisolated private static func runParallel(
        ctx: BatchContext,
        batches: [(Int, [(Int, BatchDatasetEntry)])],
        distribution: BatchDistribution,
        completedPromptTexts: Set<String>,
        workerCount: Int
    ) async -> [BatchOutcome] {
        let coordinator = BatchCoordinator(batchCount: batches.count)
        return await withTaskGroup(of: BatchOutcome.self) { group in
            var aggregated: [BatchOutcome] = []
            for _ in 0..<workerCount {
                group.addTask {
                    var results: [BatchOutcome] = []
                    while let item = await coordinator.nextItem() {
                        let (batchNum, batchData) = batches[item]
                        results.append(await Self.processBatch(
                            ctx: ctx, batchNum: batchNum, batchData: batchData,
                            distribution: distribution,
                            completedPromptTexts: completedPromptTexts
                        ))
                    }
                    return BatchOutcome.merged(results)
                }
            }
            for await outcome in group {
                aggregated.append(outcome)
            }
            return aggregated
        }
    }

    // MARK: - Single batch (nonisolated static — safe for TaskGroup)

    nonisolated private static func processBatch(
        ctx: BatchContext,
        batchNum: Int,
        batchData: [(Int, BatchDatasetEntry)],
        distribution: BatchDistribution,
        completedPromptTexts: Set<String>
    ) async -> BatchOutcome {
        let batchFile = ctx.outputDir.appendingPathComponent("batch_\(batchNum).jsonl")
        var processed = 0
        var skipped = 0
        var discarded = 0
        var completed: [Int] = []
        var toolStats: [String: ToolCallStat] = [:]
        var reasoning = ReasoningStats()

        for (index, entry) in batchData {
            let trimmedPrompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if completedPromptTexts.contains(trimmedPrompt) {
                skipped += 1
                continue
            }
            let outcome = await processOne(
                ctx: ctx, promptIndex: index, prompt: entry.prompt,
                batchNum: batchNum, distribution: distribution
            )
            guard let result = outcome else {
                processed += 1
                continue
            }
            let s = result.reasoning
            reasoning.totalAssistantTurns += s.turnsWithReasoning + s.turnsWithoutReasoning
            reasoning.turnsWithReasoning += s.turnsWithReasoning
            reasoning.turnsWithoutReasoning += s.turnsWithoutReasoning
            if s.turnsWithReasoning == 0 && s.totalAssistantTurns > 0 {
                discarded += 1
                processed += 1
                completed.append(index)
                continue
            }

            let entryJSON = encodeEntry(result.entry)
            appendLine(entryJSON, to: batchFile)
            processed += 1
            completed.append(index)
            for (name, stat) in result.entry.toolStats {
                var merged = toolStats[name] ?? ToolCallStat()
                merged.count += stat.count; merged.success += stat.success; merged.failure += stat.failure
                toolStats[name] = merged
            }
        }
        return BatchOutcome(
            batchNum: batchNum, processed: processed, skipped: skipped,
            discardedNoReasoning: discarded, completedPrompts: completed,
            toolStats: toolStats, reasoning: reasoning
        )
    }

    // MARK: - One prompt

    private struct PromptOutcome: Sendable {
        let entry: TrajectoryEntry
        let reasoning: ReasoningStats
    }

    nonisolated private static func processOne(
        ctx: BatchContext,
        promptIndex: Int, prompt: String, batchNum: Int,
        distribution: BatchDistribution
    ) async -> PromptOutcome? {
        let seed = UInt64(promptIndex) &* 0x9E3779B97F4A7C15 &+ UInt64(batchNum)
        let selectedToolsets = distribution.sample(seed: seed, universe: ctx.allToolsets)
        let disabled = Set(ctx.allToolsets.filter { !selectedToolsets.contains($0) })

        let effectiveBase = ctx.options.baseURL
            ?? ProcessInfo.processInfo.environment["ARC_BASE_URL"]
            ?? loadConfig().model.baseURL
            ?? "https://api.openai.com/v1"
        let effectiveKey = ctx.options.apiKey
            ?? ProcessInfo.processInfo.environment["ARC_API_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""
        let agentConfig = ArcAgent.Configuration(
            model: ctx.options.model,
            provider: loadConfig().model.provider,
            baseURL: URL(string: effectiveBase) ?? URL(string: "https://api.openai.com/v1")!,
            apiKey: effectiveKey,
            registry: (try? ArcAgentCore.buildDefaultRegistry()) ?? CompileTimeToolRegistry(),
            maxIterations: ctx.options.maxTurns,
            injectProjectContext: false,
            disabledToolsets: disabled
        )
        let agent = ArcAgent(config: agentConfig)
        do {
            let result = try await agent.runForBatch(prompt: prompt)
            let indexText = await agent.toolsIndexText()
            let conversations = ShareGPTTrajectory.make(
                messages: result.messages, userQuery: prompt,
                completed: result.completed, toolsIndexText: indexText
            )
            let assistantTurns = result.messages.filter { $0.role == Message.Role.assistant }.count
            let withReasoning = result.messages.filter {
                $0.role == Message.Role.assistant && !($0.reasoning ?? "").isEmpty
            }.count
            let entry = TrajectoryEntry(
                promptIndex: promptIndex,
                conversations: conversations,
                metadata: [
                    "batch_num": String(batchNum),
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "model": ctx.options.model,
                ],
                completed: result.completed,
                partial: result.partial,
                apiCalls: result.apiCalls,
                toolsetsUsed: selectedToolsets.sorted(),
                toolStats: result.toolStats
            )
            await agent.shutdownHTTPClient()
            return PromptOutcome(
                entry: entry,
                reasoning: ReasoningStats(
                    totalAssistantTurns: assistantTurns,
                    turnsWithReasoning: withReasoning,
                    turnsWithoutReasoning: assistantTurns - withReasoning
                )
            )
        } catch {
            if ctx.options.verbose {
                print("❌ Error processing prompt \(promptIndex): \(error)")
            }
            await agent.shutdownHTTPClient()
            return nil
        }
    }

    // MARK: - Resume scan

    private func scanCompletedPrompts() async -> Set<String> {
        var completed = Set<String>()
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: outputDir, includingPropertiesForKeys: nil
        ).filter({ $0.lastPathComponent.hasPrefix("batch_") && $0.pathExtension == "jsonl" }) else {
            return completed
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(TrajectoryEntry.self, from: data) else { continue }
                if entry.completed, let human = entry.conversations.first(where: { $0.from == "human" }) {
                    completed.insert(human.value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return completed
    }

    // MARK: - Combine

    nonisolated private static func combineTrajectories(ctx: BatchContext) throws -> Int {
        let fileManager = FileManager.default
        let batchFiles = try fileManager.contentsOfDirectory(
            at: ctx.outputDir, includingPropertiesForKeys: nil
        ).filter({ $0.lastPathComponent.hasPrefix("batch_") && $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        let combinedFile = ctx.outputDir.appendingPathComponent("trajectories.jsonl")
        try? fileManager.removeItem(at: combinedFile)
        var count = 0
        for file in batchFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(TrajectoryEntry.self, from: data) else { continue }
                // Filter corrupted entries (invalid tool names) — reference.
                let invalid = entry.toolStats.keys.filter { !ctx.allToolNames.contains($0) }
                if !invalid.isEmpty {
                    if ctx.options.verbose {
                        print("   ⚠️  Filtering corrupted entry: invalid tool '\(invalid[0])'")
                    }
                    continue
                }
                if let json = try? JSONEncoder().encode(entry),
                   let lineOut = String(data: json, encoding: .utf8) {
                    appendLine(lineOut, to: combinedFile)
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Helpers

    nonisolated private static func encodeEntry(_ entry: TrajectoryEntry) -> String {
        (try? JSONEncoder().encode(entry)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    nonisolated private static func appendLine(_ line: String, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? (line + "\n").data(using: .utf8)?.write(to: url)
        }
    }

    nonisolated private static func writePrettyJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}

// MARK: - Work coordination (bounded worker pool without semaphores)

/// Hands out batch indexes to workers. First Law: actor, no locks.
private actor BatchCoordinator {
    private var next = 0
    private let batchCount: Int
    init(batchCount: Int) { self.batchCount = batchCount }
    func nextItem() -> Int? {
        guard next < batchCount else { return nil }
        defer { next += 1 }
        return next
    }
}
