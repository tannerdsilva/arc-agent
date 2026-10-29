import ArcToolKit
import ArgumentParser
import ArcAgentCore
import ArcDaemon
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        // Surface introspection only: this command measures the compiled tool
        // schemas and never dispatches one, so it builds a `.default` context
        // with no document authority.
        let registry = try ArcAgentCore.buildRegistry(
            context: ToolContext(
                profile: .default,
                sessionID: "",
                workspace: FileManager.default.currentDirectoryPath,
                grant: ToolGrant(profile: .default, documentAccess: .none)
            ),
            profiles: TesseraProfileStore.shared,
            memory: FileMemoryProvider(),
            sessions: FileSessionStore()
        )
        let full = registry.buildToolSchemas(enabled: [], disabled: [])
        let deferredSchemas = ProgressiveToolDisclosure.buildPromptSchemas(
            registry: registry, disabled: [], config: config.toolSearch,
            contextLength: contextLength)
        let deferredPlan = DeferredToolPolicy.plan(
            entries: registry.allTools.map { $0.tool },
            config: config.toolSearch)
        let manifestTokens = ProgressiveToolDisclosure.manifest(
            deferred: deferredPlan.deferred, config: config.toolSearch,
            contextLength: contextLength).map { charsToTokens($0.count) } ?? 0

        let skills = discoverSkills()
        let skillsIndex = buildSkillsIndex(skills)
        let memory = readHomeFiles("memory.md") + "\n" + readHomeFiles("user.md")
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
        let url = ArcHome.root.appendingPathComponent(rel)
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
        let configURL = ArcHome.config
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

        let dataDir = ArcHome.root
        let writable = FileManager.default.isWritableFile(atPath: dataDir.path)
        report(writable ? "✅" : "❌", writable ? "data dir writable (\(dataDir.path))" : "data dir NOT writable (\(dataDir.path))")

        if !config.mcpServers.isEmpty {
            print("ℹ️  \(config.mcpServers.count) MCP server(s) configured: \(config.mcpServers.keys.sorted().joined(separator: ", "))")
        }
        if let tessera = config.tessera {
            print("ℹ️  tessera storage configured: \(tessera)")
            // The tunnel probe: bounded handshake against the relay. This is
            // the check that proves the wire, not just the config — an
            // unregistered user or a dead relay surfaces here, not at first
            // write time.
            let clock = ContinuousClock()
            let reachable = await TesseraAvailability.shared.isTesseraActive()
            let elapsed = clock.now.duration(to: .now)
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            if reachable {
                report("✅", String(format: "tessera tunnel reachable (%@:%d, handshake %.0f ms)", tessera.serverIP, tessera.serverPort, Double(ms)))
            } else {
                report("⚠️", "tessera tunnel NOT reachable (\(tessera.serverIP):\(tessera.serverPort)) — storage falls back to files; see arc-serve.log for the handshake error")
            }
        } else {
            print("ℹ️  tessera storage not configured (file storage in use)")
        }

        // Tool plugins (deployment surface): discovery never blocks boot —
        // issues are captured and reported here for operators.
        let pluginRegistry = PluginRegistry.shared
        do {
            try await pluginRegistry.loadAll()
        } catch {
            report("⚠️", "tool plugin discovery failed: \(error)")
        }
        let pluginManifests = await pluginRegistry.plugins()
        let pluginTools = await pluginRegistry.tools()
        let pluginIssues = await pluginRegistry.discoveryIssues()
        let pluginsStatus = pluginIssues.isEmpty ? "✅" : "⚠️"
        let pluginsMessage = "tool plugins: \(pluginManifests.count) plugin(s), \(pluginTools.count) tool(s)"
            + (pluginIssues.isEmpty ? "" : " — issues: \(pluginIssues.joined(separator: "; "))")
        report(pluginsStatus, pluginsMessage)

        print(ok ? "✅ doctor: all checks passed" : "❌ doctor: issues found — see above")
    }
}

/// `arc status` — the daemon's surfaces and store sizes.
struct StatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the daemon's surfaces and stores."
    )
    @Option(help: "Override the API port to probe (default: daemon.json / API_PORT).")
    var apiPort: Int?

    func run() async throws {
        print("arc-agent \(ArcAgentCore.version)")
        let config = loadConfig()
        print("model:     \(config.model.provider)/\(config.model.defaultModel)")
        print("baseURL:   \(config.model.baseURL ?? "(default)")")
        print("")

        // The surfaces are the ones `arc serve` would compose: same file, same
        // resolution (`DaemonPlan`), one probe per enabled surface.
        let arcHome = ArcHome.root
        let daemonConfig = DaemonConfig.load(
            home: arcHome,
            environment: ProcessInfo.processInfo.environment
        )
        let plan = DaemonPlan.resolve(config: daemonConfig, overrides: .init(port: apiPort))

        print("daemon:    one process — `arc serve`")
        if let api = plan.api {
            await probe(label: "api  ", host: api.host, port: api.port, path: "/health")
        } else {
            print("  api    disabled (daemon.json)")
        }
        if let webui = plan.webui {
            await probe(label: "webui", host: webui.host, port: webui.port, path: "/")
        } else {
            print("  webui  disabled (daemon.json)")
        }
        if daemonConfig.telegramAdapterReady { print("  telegram: enabled (adapter)") }
        if daemonConfig.emailAdapterReady { print("  email:    enabled (adapter)") }
        if daemonConfig.slackAdapterReady { print("  slack:    enabled (adapter)") }
        print("")

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
        let dataDir = ArcHome.root
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dataDir.path),
           let size = attrs[.size] as? Int64 {
            print("data dir:  \(size / 1024) KB")
        }
    }

    private func probe(label: String, host: String, port: Int, path: String) async {
        let url = URL(string: "http://\(host):\(port)\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code < 500 {
                print("  \(label) http://\(host):\(port)  ✅ listening (\(code))")
            } else {
                print("  \(label) http://\(host):\(port)  ⚠️ responding (\(code))")
            }
        } catch {
            print("  \(label) http://\(host):\(port)  ❌ not reachable")
        }
    }
}
