import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Ops CLIs (reference `prompt-size`, `doctor`, `status`)

/// `arc prompt-size` — token breakdown of the model-visible prompt surface.
struct PromptSizeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt-size",
        abstract: "Estimate prompt tokens per section (tools, skills, memory, personality)."
    )
    @Option() var contextLength: Int = 200_000

    func run() async throws {
        let config = loadConfig()
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let full = registry.buildToolSchemas(enabled: [], disabled: [])
        let deferredSchemas = ProgressiveToolDisclosure.buildPromptSchemas(
            registry: registry, disabled: [], config: config.toolSearch,
            contextLength: contextLength)
        let deferredPlan = DeferredToolPolicy.plan(
            entries: registry.allTools,
            config: config.toolSearch)
        let manifestTokens = ProgressiveToolDisclosure.manifest(
            deferred: deferredPlan.deferred, config: config.toolSearch,
            contextLength: contextLength).map { charsToTokens($0.count) } ?? 0

        let skills = discoverSkills()
        let skillsIndex = buildSkillsIndex(skills)
        let memory = readHomeFiles(".arc/memory.md") + "\n" + readHomeFiles(".arc/user.md")
        let personality = config.agent.systemPrompt

        let fullTokens = tokens(schemas: full)
        let deferredTokens = tokens(schemas: deferredSchemas)
        let escaped = [("Eager tools (no deferral)", fullTokens, "all \(full.count) schemas"),
                       ("Deferred layout (S1)", deferredTokens, "\(deferredSchemas.count) schemas + bridge/manifest"),
                       ("Tool savings", max(0, fullTokens - deferredTokens), "with tool_search enabled")]

        var sections: [(String, String, Int)] = escaped.map { ($0.0, $0.2, $0.1) }
        sections.append(("Skills index", "\(skills.count) skills", charsToTokens(skillsIndex.count)))
        sections.append(("Memory + USER", "(profiles)", charsToTokens(memory.count)))
        sections.append(("Personality", "agent.system_prompt", charsToTokens(personality.count)))
        sections.append(("Manifest listing", config.toolSearch.listing, manifestTokens))

        if json {
            let dict = Dictionary(uniqueKeysWithValues: sections.map { ($0.0, $0.2) })
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        var total = 0
        print("⚡ arc-agent prompt-size (chars/4 estimate)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for (name, detail, tokens) in sections {
            total += tokens
            print("\(name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(String(format: "%6d", tokens)) tok  (\(detail))")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Estimated prompt (tool schemas + index): \(total) tokens (system prompt text built per session)")
        print("Tip: deferral is configurable via `tool_search` (enabled: auto|on|off).")
    }

    @Flag var json = false

    private func tokens(schemas: [[String: Any]]) -> Int {
        ProgressiveToolDisclosure.estimateTokens(schemas: schemas)
    }

    private func charsToTokens(_ chars: Int) -> Int {
        Int(ceil(Double(chars) / 4.0))
    }

    private func readHomeFiles(_ rel: String) -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// `arc doctor` — configuration and environment health checks.
struct DoctorCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check configuration, credentials, and runtime surfaces."
    )
    func run() async throws {
        var ok = true
        func report(_ status: String, _ message: String) {
            if status == "❌" { ok = false }
            print("\(status) \(message)")
        }
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arc/config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("❌ No config at \(configURL.path). Run `arc setup` first.")
            return
        }
        let config = loadConfig()
        report("✅", "config parses (\(configURL.path))")
        let env = ProcessInfo.processInfo.environment
        let hasKey = env["ARC_API_KEY"].map { !$0.isEmpty } == true
            || env["OPENAI_API_KEY"].map { !$0.isEmpty } == true
            || env["ANTHROPIC_API_KEY"].map { !$0.isEmpty } == true
            || config.model.provider == "local"
        report(hasKey ? "✅" : "⚠️", hasKey ? "model credential present (\(config.model.provider))" : "no API key set (config.model.api_key or ARC_API_KEY)")

        let skills = discoverSkills()
        report(skills.isEmpty ? "⚠️" : "✅", skills.isEmpty ? "no skills installed" : "skills index: \(skills.count) skills")

        let dataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arc")
        let writable = FileManager.default.isWritableFile(atPath: dataDir.path)
        report(writable ? "✅" : "❌", writable ? "data dir writable (\(dataDir.path))" : "data dir NOT writable (\(dataDir.path))")

        if !config.mcpServers.isEmpty {
            print("ℹ️  \(config.mcpServers.count) MCP server(s) configured: \(config.mcpServers.keys.sorted().joined(separator: ", "))")
        }
        if let tessera = config.tessera {
            print("ℹ️  tessera storage configured: \(tessera)")
        }
        print(ok ? "✅ doctor: all checks passed" : "❌ doctor: issues found — see above")
    }
}

/// `arc status` — component liveness and store sizes.
struct StatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show status of components (gateway, webui, stores)."
    )
    @Option() var gatewayPort: Int = 8080
    @Option() var webuiPort: Int = 8890

    func run() async throws {
        print("arc-agent \(ArcAgentCore.version)")
        let config = loadConfig()
        print("model:     \(config.model.provider)/\(config.model.defaultModel)")
        print("baseURL:   \(config.model.baseURL ?? "(default)")")
        print("")

        _ = await probe(port: webuiPort, path: "/")
        _ = await probe(port: gatewayPort, path: "/health")

        do {
            let sessions = try await FileSessionStore().list(limit: 100_000)
            print("sessions:  \(sessions.count) persisted")
        } catch {
            print("sessions:  ⚠️ \(error)")
        }
        print("skills:    \(discoverSkills().count) installed")
        do {
            let jobs = try await RuntimeCronStore().listAll()
            print("cron:      \(jobs.count) job(s)")
        } catch {
            print("cron:      ⚠️ \(error)")
        }
        let dataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arc")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dataDir.path),
           let size = attrs[.size] as? Int64 {
            print("data dir:  \(size / 1024) KB")
        }
    }

    private func probe(port: Int, path: String) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                print("port \(port):  ✅ listening (\(http.statusCode))")
                return true
            }
            print("port \(port):  ⚠️ responding (\((response as? HTTPURLResponse)?.statusCode ?? -1))")
            return false
        } catch {
            print("port \(port):  ❌ not reachable (\(error.localizedDescription.prefix(48)))")
            return false
        }
    }
}
