import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Blueprints CLI (reference `reference blueprint`)

/// `arc blueprint` — register a skill's embedded blueprint as a cron job.
/// (Parser lives in ArcAgentCore: `BlueprintParser`.)
struct BlueprintCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blueprint",
        abstract: "List skills with embedded blueprints and register them as cron jobs.",
        subcommands: [BlueprintList.self, BlueprintRun.self, BlueprintShow.self]
    )
}

func blueprintSkills() -> [Skill] { discoverSkills() }

func skillMarkdown(_ skill: Skill) -> URL {
    skill.path.lastPathComponent == "SKILL.md"
        ? skill.path
        : skill.path.appendingPathComponent("SKILL.md")
}

struct BlueprintList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List skills that are blueprints.")
    func run() throws {
        var found = 0
        for skill in blueprintSkills() {
            if let text = try? String(contentsOfFile: skillMarkdown(skill).path, encoding: .utf8),
               let spec = try? BlueprintParser.parse(text, fallbackName: skill.name) {
                found += 1
                print("\(skill.name)  [\(spec.schedule)]  model=\(spec.model ?? "-") toolsets=\(spec.enabledToolsets?.joined(separator: ",") ?? "-")")
            }
        }
        if found == 0 { print("No blueprint skills found.") }
    }
}

struct BlueprintShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a blueprint's parsed spec.")
    @Argument var skill: String
    func run() throws {
        guard let s = blueprintSkills().first(where: { $0.name == skill }) else {
            print("Skill '\(skill)' not found."); return
        }
        let text = try String(contentsOfFile: skillMarkdown(s).path, encoding: .utf8)
        guard let spec = try BlueprintParser.parse(text, fallbackName: s.name) else {
            print("Skill '\(skill)' has no blueprint block."); return
        }
        print("name:      \(spec.skillName)")
        print("schedule:  \(spec.schedule)")
        print("deliver:   \(spec.deliver)")
        print("prompt:    \(spec.prompt ?? "(skill default)")")
        print("no_agent:  \(spec.noAgent)")
        print("model:     \(spec.model ?? "(default)")")
        print("provider:  \(spec.provider ?? "(default)")")
        print("toolsets:  \(spec.enabledToolsets?.joined(separator: ", ") ?? "(all)")")
    }
}

struct BlueprintRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Register a blueprint skill as a cron job.")
    @Argument var skill: String
    @Option(name: .long, help: "Style: curl, cron, rfc (default curl / reference style).")
    var style: String = "curl"
    func run() async throws {
        guard let s = blueprintSkills().first(where: { $0.name == skill }) else {
            print("Skill '\(skill)' not found."); return
        }
        let text = try String(contentsOfFile: skillMarkdown(s).path, encoding: .utf8)
        guard let spec = try BlueprintParser.parse(text, fallbackName: s.name) else {
            print("Skill '\(skill)' has no blueprint block."); return
        }
        // Register a cron job through the same store the scheduler polls.
        // (Arc's CronJob carries schedule/prompt only; model/toolset/deliver
        // overrides are applied by the scheduler's host configuration.)
        let job = CronJob(
            id: "blueprint-\(spec.skillName)",
            name: "blueprint-\(spec.skillName)",
            schedule: spec.schedule,
            prompt: spec.prompt ?? "",
            isActive: true
        )
        do {
            let store = RuntimeCronStore()
            try await store.save(job)
            print("✔ Blueprint '\(spec.skillName)' registered: schedule=\(spec.schedule) (style: \(style))")
            print("  The cron scheduler polls this store; restart the gateway for it to pick up the job.")
        } catch {
            print("✘ register failed: \(error)")
        }
    }
}
