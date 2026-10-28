import ArgumentParser
import Foundation
import ArcAgentCore

// MARK: - `arc skillbundle` — install distributable skill packages
//
// A skill package is a directory (or zip) carrying a `manifest.json` recipe
// plus a `skills/` tree. `arc skillbundle install <bundle>` validates the
// manifest, security-scans every skill with the same injection gate the agent
// uses for context files, then copies the skills into the skills directory.
// Packages ship *capability*, never personal profile state — identity,
// credentials and existing skills are never overwritten.

struct SkillBundleCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "skillbundle",
        abstract: "Install distributable skill packages.",
        subcommands: [SkillBundleInstall.self, SkillBundleList.self]
    )
}

/// `arc skillbundle install <bundle>` — install a skill package.
struct SkillBundleInstall: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a skill package into the skills directory."
    )

    /// The bundle to install: a directory path, `.zip` path, http(s) URL, or
    /// a bare name resolved against the package registry.
    @Argument(help: "Bundle to install (directory, .zip, http(s) URL, or registry name).")
    var bundle: String

    /// Skills directory to install into. Defaults to `~/.arc/skills`
    /// (the same root `skill_manage` and skill discovery use).
    @Option(name: .long, help: "Install into this skills directory (default: ~/.arc/skills).")
    var directory: String?

    /// Registry searched for a bare bundle name (default: ~/.arc/skill-packages).
    @Option(name: .long, help: "Registry directory for bare bundle names (default: ~/.arc/skill-packages).")
    var registry: String?

    /// Overwrite already-present skills instead of skipping them.
    @Flag(name: .shortAndLong, help: "Overwrite skills that already exist.")
    var force: Bool = false

    /// Bypass the injection-pattern security scan (not recommended).
    @Flag(name: .long, help: "Skip the injection-pattern security scan (not recommended).")
    var allowUnsafe: Bool = false

    func run() async throws {
        // Target skills root: flag override, else the canonical agent root.
        let skillsRoot: URL
        if let directory {
            skillsRoot = URL(fileURLWithPath: directory)
        } else {
            skillsRoot = AgentPowers.skillsDirectory
        }

        // Resolve the user-facing bundle reference to a package directory.
        let packageDirectory = try await SkillPackageSource.resolve(
            bundle: bundle,
            registry: registry.map { URL(fileURLWithPath: $0) }
        )

        // Validate + scan + copy.
        let report = try SkillPackageInstaller.install(
            packageDirectory: packageDirectory,
            into: skillsRoot,
            overwrite: force,
            allowUnsafe: allowUnsafe
        )

        print(report.description)

        if !report.failures.isEmpty {
            throw ExitCode.failure
        }
    }
}

/// `arc skillbundle list` — list bundles available in the registry.
struct SkillBundleList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List skill packages available in the registry."
    )

    /// Registry directory to inspect (default: ~/.arc/skill-packages).
    @Option(name: .long, help: "Registry directory (default: ~/.arc/skill-packages).")
    var registry: String?

    func run() throws {
        let reg = registry.map { URL(fileURLWithPath: $0) }
            ?? ArcHome.skillPackages
        let fm = FileManager.default
        guard fm.fileExists(atPath: reg.path) else {
            print("No package registry at \(reg.path). Drop package directories or .zip files there.")
            return
        }
        let entries = (try? fm.contentsOfDirectory(atPath: reg.path)) ?? []
        if entries.isEmpty {
            print("No packages in \(reg.path).")
            return
        }
        print("⚡ ARC Agent — Skill packages")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for entry in entries.sorted() {
            let item = reg.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue,
               fm.fileExists(atPath: item.appendingPathComponent("manifest.json").path) {
                if let manifest = try? SkillPackageInstaller.loadManifest(packageDirectory: item) {
                    let name = manifest.name
                    let version = manifest.version ?? ""
                    print("  \(name) \(version)")
                    print("     \(manifest.description ?? "(no description)")")
                } else {
                    print("  \(entry) (unreadable manifest)")
                }
            } else if item.pathExtension.lowercased() == "zip" {
                print("  \(entry) (.zip)")
            }
        }
    }
}
