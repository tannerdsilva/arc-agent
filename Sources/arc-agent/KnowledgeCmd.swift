import ArgumentParser
import ArcAgentCore
import AsyncHTTPClient
import Foundation
import NIOCore

// MARK: - Security & knowledge CLI batch (reference `reference security`, `skills_*`, `learning_graph.py`)

/// `arc security osv` — OSV supply-chain audit of Package.resolved pins.
struct SecurityCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "security",
        abstract: "Supply-chain and approvals tooling.",
        subcommands: [SecurityOSV.self]
    )
}

struct SecurityOSV: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "osv", abstract: "Audit dependency pins against OSV.dev.")
    @Option() var file: String = "Package.resolved"
    @Option() var api: String = "https://api.osv.dev/v1/querybatch"
    @Option(help: "OSV ecosystem id (e.g. PyPI, npm, crates.io). Swift is not supported by OSV.")
    var ecosystem: String = "Swift"
    func run() async throws {
        guard let data = FileManager.default.contents(atPath: file) else {
            print("No Package.resolved at \(file). Run from a SwiftPM package directory.")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = json["pins"] as? [[String: Any]] else {
            print("\(file) is not a v2 Package.resolved.")
            return
        }
        var queries: [[String: Any]] = []
        var labels: [String] = []
        for pin in pins {
            guard let name = pin["identity"] as? String,
                  let state = pin["state"] as? [String: Any],
                  let v = state["version"] as? String else { continue }
            if v.hasPrefix("[") { continue }
            queries.append(["package": ["name": name, "ecosystem": ecosystem], "version": v])
            labels.append("\(name)@\(v)")
        }
        if queries.isEmpty { print("No resolvable pins found."); return }
        print("Auditing \(queries.count) pins (ecosystem: \(ecosystem))…")
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? client.syncShutdown() }
        var request = HTTPClientRequest(url: api)
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: ["queries": queries])))
        let response = try await client.execute(request, timeout: .seconds(60))
        let body = try await response.body.collect(upTo: 8 * 1024 * 1024)
        guard response.status == .ok else {
            // OSV has no Swift ecosystem: be honest and list pins for review.
            print("OSV refused the audit (HTTP \(response.status.code)) — OSV has no '\(ecosystem)' ecosystem.")
            print("Pins for manual review:")
            for label in labels { print("  \(label)") }
            print("Tip: re-run with --ecosystem of a supported format (PyPI, npm, crates.io…).")
            return
        }
        guard let results = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
              let vulns = results["results"] as? [[String: Any]] else {
            print("OSV response unreadable (HTTP \(response.status.code))."); return
        }
        var total = 0
        for (i, result) in vulns.enumerated() {
            guard let list = result["vulns"] as? [[String: Any]], !list.isEmpty else { continue }
            let label = i < labels.count ? labels[i] : "#\(i)"
            print("🔴 \(label): \(list.count) advisory/a(s)")
            for v in list {
                let id = v["id"] as? String ?? "?"
                let summary = (v["summary"] as? String ?? "")
                let aliases = (v["aliases"] as? [String] ?? []).joined(separator: ", ")
                let sev = ((v["database_specific"] as? [String: Any])?["severity"] as? String) ?? ""
                print("   \(id)\(sev.isEmpty ? "" : " [\(sev)]") \(summary)\(aliases.isEmpty ? "" : " (aliases: \(aliases))")")
            }
            total += list.count
        }
        if total == 0 { print("✅ No known vulnerabilities across \(queries.count) pins.") }
    }
}

/// Skills auxiliary verbs: audit / usage / provenance / sync (hub).
/// (Registered as subcommands of the existing `arc skills` group.)

struct SkillsAudit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit", abstract: "Validate every installed SKILL.md (frontmatter/AST).")
    func run() throws {
        let skills = discoverSkills()
        var issues = 0
        for skill in skills {
            let md = skillMarkdown(skill)
            guard let text = try? String(contentsOfFile: md.path, encoding: .utf8) else {
                print("✘ \(skill.name): SKILL.md unreadable"); issues += 1; continue
            }
            if !text.hasPrefix("---") {
                print("✘ \(skill.name): missing YAML frontmatter"); issues += 1
            }
            if skill.description.isEmpty {
                print("✘ \(skill.name): missing description"); issues += 1
            }
            // Frontmatter must contain name (matches directory).
            if !text.split(separator: "\n").prefix(20).contains(where: { $0.hasPrefix("name:") }) {
                print("✘ \(skill.name): missing name field"); issues += 1
            }
            if let threat = ContextFileScanner.scan(text) {
                print("✘ \(skill.name): injection pattern (\(threat.rawValue))"); issues += 1
            }
        }
        print(issues == 0 ? "✅ All \(skills.count) skills pass validation." : "❌ \(issues) issue(s) across \(skills.count) skills.")
    }
}

struct SkillsUsage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "usage", abstract: "Show skill usage counts (recorded on load).")
    func run() throws {
        let skills = discoverSkills()
        for skill in skills.sorted(by: { $0.name < $1.name }) {
            let counts = usageFor(skill)
            print("\(counts.loads) loads | \(counts.lastLoaded) | \(skill.name)")
        }
    }
}

func usageFor(_ skill: Skill) -> (loads: Int, lastLoaded: String) {
    let file = skill.path.deletingLastPathComponent().appendingPathComponent(".usage.json")
    guard let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (0, "-")
    }
    return (json["loads"] as? Int ?? 0, json["last"] as? String ?? "-")
}

struct SkillsProvenance: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "provenance", abstract: "Show a skill's provenance metadata.")
    @Argument var skill: String
    func run() throws {
        guard let s = discoverSkills().first(where: { $0.name == skill }) else {
            print("Skill '\(skill)' not found."); return
        }
        let dir = s.path.deletingLastPathComponent()
        let provenance = dir.appendingPathComponent("provenance.yaml")
        print("skill:      \(s.name)")
        print("directory:  \(dir.path)")
        let attrs = try? FileManager.default.attributesOfItem(atPath: s.path.path)
        let created = (attrs?[.creationDate] as? Date)?.description ?? "-"
        let modified = (attrs?[.modificationDate] as? Date)?.description ?? "-"
        print("created:    \(created)")
        print("modified:   \(modified)")
        if let text = try? String(contentsOfFile: provenance.path, encoding: .utf8), !text.isEmpty {
            print("provenance: \(provenance.path)")
            print(text)
        } else {
            print("provenance: (none recorded — local skill)")
        }
    }
}

struct SkillsSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync", abstract: "Synchronize the local skills tree with a hub directory.",
        subcommands: [SkillsSyncStatus.self, SkillsSyncPull.self, SkillsSyncPush.self]
    )
}

struct SkillsSyncStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Diff local skills against the hub.")
    @Option() var hub: String = "~/.arc/skills-hub"
    func run() throws {
        let hubDir = expand(hub)
        guard FileManager.default.fileExists(atPath: hubDir) else {
            print("Hub not found at \(hubDir). Create it with `arc skills sync push`."); return
        }
        let local = Dictionary(uniqueKeysWithValues: discoverSkills().map { (URL(fileURLWithPath: $0.path.path).deletingLastPathComponent().lastPathComponent, $0.path) })
        _ = local
        let localNames = Set(discoverSkills().map(\.name))
        let hubNames = Set(hubSkillDates(hubDir).keys)
        for missing in hubNames.subtracting(localNames) { print("→ hub-only: \(missing)") }
        for extra in localNames.subtracting(hubNames) { print("← local-only: \(extra)") }
        for common in localNames.intersection(hubNames).sorted() {
            let hm = hubSkillDates(hubDir)[common] ?? .distantPast
            let lm: Date? = (try? FileManager.default.attributesOfItem(
                atPath: discoverSkills().first { $0.name == common }!.path.path
            ))?[.modificationDate] as? Date
            if let lm, lm > hm { print("≈ newer locally: \(common)") }
            else if let lm, lm < hm { print("≈ newer in hub: \(common)") }
        }
    }
}

struct SkillsSyncPull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Copy hub skills into the local tree (does not overwrite newer local).")
    @Option() var hub: String = "~/.arc/skills-hub"
    func run() throws {
        let hubDir = expand(hub)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hubDir) else {
            print("Hub not found at \(hubDir)."); return
        }
        let localSkills = try skillsDir()
        for entry in entries where !entry.hasPrefix(".") {
            let src = URL(fileURLWithPath: hubDir).appendingPathComponent(entry)
            let dst = localSkills.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: dst.path) {
                let srcDate = (try FileManager.default.attributesOfItem(atPath: src.path)[.modificationDate] as? Date) ?? .distantPast
                let dstDate = (try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? .distantFuture
                if srcDate <= dstDate { continue }
            }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            print("⬇  \(entry)")
        }
    }
}

struct SkillsSyncPush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Copy local skills into the hub (does not overwrite newer hub).")
    @Option() var hub: String = "~/.arc/skills-hub"
    func run() throws {
        let hubDir = URL(fileURLWithPath: expand(hub))
        try FileManager.default.createDirectory(at: hubDir, withIntermediateDirectories: true)
        for skill in discoverSkills() {
            let dir = skill.path.deletingLastPathComponent()
            let name = dir.lastPathComponent
            let dst = hubDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) {
                let srcDate = (try FileManager.default.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date) ?? .distantPast
                let dstDate = (try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? .distantFuture
                if srcDate <= dstDate { continue }
            }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: dir, to: dst)
            print("⬆  \(name)")
        }
    }
}

private func hubSkillDates(_ dir: String) -> [String: Date] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }
    var result: [String: Date] = [:]
    for entry in entries where !entry.hasPrefix(".") {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(entry)
        result[entry] = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
    }
    return result
}

private func expand(_ path: String) -> String {
    path.hasPrefix("~/") ? NSHomeDirectory() + path.dropFirst(1) : path
}

private func skillsDir() throws -> URL {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arc/skills")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// `arc learning` — knowledge derivation (`reference learning/memory-graph`),
/// `arc journey` — the history of your sessions as a timeline.
struct LearningCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "learning",
        abstract: "Derive knowledge graphs and session journeys.",
        subcommands: [LearningGraph.self, LearningJourney.self]
    )
}

struct LearningGraph: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory-graph", abstract: "Emit a DOT graph of topics ↔ sessions ↔ skills.")
    func run() async throws {
        let store = FileSessionStore()
        let sessions = try await store.list(limit: 500)
        var edges: Set<String> = []
        var nodes: Set<String> = []
        for session in sessions {
            let sessionID = session.id
            nodes.insert("s_\(sessionID)")
            var topics = Set<String>()
            if let title = session.title, !title.isEmpty {
                topics.insert(titleToken(title))
            }
            for t in topics {
                nodes.insert("t_\(t)")
                edges.insert("\"s_\(sessionID)\" -- \"t_\(t)\"")
            }
        }
        print("digraph arc_learning {")
        print("  rankdir=LR;")
        for node in nodes { print("  \(node);") }
        for edge in edges { print("  \(edge);") }
        print("}")
    }

    private func titleToken(_ title: String) -> String {
        let cleaned = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(3)
            .joined(separator: "_")
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}

struct LearningJourney: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "journey", abstract: "A day-by-day timeline of your sessions.")
    func run() async throws {
        let store = FileSessionStore()
        let sessions = try await store.list(limit: 500)
        let grouped = Dictionary(grouping: sessions) { Calendar.current.startOfDay(for: $0.updatedAt) }
        for day in grouped.keys.sorted(by: >) {
            let daySessions = grouped[day]!.sorted { $0.updatedAt > $1.updatedAt }
            print("— \(day.formatted(date: .abbreviated, time: .omitted)) —")
            for session in daySessions.prefix(5) {
                let turns = String(session.messageCount)
                print("  • \(session.title ?? String(session.id.prefix(8)))  [\(turns) turns]")
            }
        }
        if sessions.isEmpty { print("No sessions yet.") }
    }
}
