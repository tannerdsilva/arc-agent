import Foundation

// MARK: - Skill package (a distributable bundle of skills + a manifest recipe)
//
// A skill package is a directory (or zip) containing a `manifest.json` recipe
// and a `skills/` tree of SKILL.md files. The manifest *describes* the bundle
// — which skills to install, an optional suggested model, optional blueprint
// schedulers and an optional starter prompt — but never carries personal
// identity, credentials or profile state. Installing drops the skills into
// the target profile's skills directory; anything personal stays with the
// user. This is the arc-agent counterpart of Hermes' skill distribution:
// packages ship *capability*, not profile state.
//
// Safety posture:
//  - Every SKILL.md (and supporting text file) is run through
//    ``ContextFileScanner`` (the same injection-pattern gate used by
//    context files) before anything is copied. A package that triggers the
//    scanner is rejected atomically — nothing is partially installed —
//    unless `allowUnsafe` is set.
//  - Install is non-destructive by default: an already-present skill is
//    skipped (recorded in the report) rather than overwritten, unless
//    `overwrite` is set.
//  - The manifest's model hint / enabled-skills / blueprints are surfaced as
//    *suggestions* in the install report. They are never silently written
//    into the user's config — applying them is an explicit, separate step.

/// The current manifest recipe format. Bump on any breaking schema change;
/// loaders refuse manifests with an unknown `format`.
public let skillPackageFormat = 1

/// A skill package manifest recipe.
public struct SkillPackageManifest: Codable, Sendable, Equatable {

    /// Optional suggested model hint. A recommendation only.
    public struct ModelHint: Codable, Sendable, Equatable {
        public let provider: String?
        public let model: String?
        public init(provider: String?, model: String?) {
            self.provider = provider
            self.model = model
        }
    }

    /// One skill to install from the package.
    public struct SkillSpec: Codable, Sendable, Equatable {
        /// Path to the skill directory relative to the package root
        /// (default: `skills/<name>`). May be a plain `name` or a nested path.
        public let source: String?
        /// The skill's install name; must be a valid skill slug.
        public let name: String
        /// Category written into the skill's frontmatter on install (optional).
        public let category: String?
        /// Whether the skill should be enabled after install. A suggestion
        /// only — the agent reads enabled state from config, not the package.
        public let enabled: Bool?
        public init(source: String? = nil, name: String, category: String? = nil, enabled: Bool? = nil) {
            self.source = source
            self.name = name
            self.category = category
            self.enabled = enabled
        }
    }

    /// An optional scheduled blueprint carried by the package. Surfaced as a
    /// suggestion; never auto-registered.
    public struct BlueprintSpec: Codable, Sendable, Equatable {
        public let file: String
        public let prompt: String
        public let schedule: String
        public init(file: String, prompt: String, schedule: String) {
            self.file = file
            self.prompt = prompt
            self.schedule = schedule
        }
    }

    public let format: Int
    public let name: String
    public let description: String?
    public let version: String?
    public let author: String?
    public let model: ModelHint?
    public let skills: [SkillSpec]
    public let blueprints: [BlueprintSpec]?
    /// Optional starter prompt file (e.g. `starter.md`) appended to the
    /// agent's personality as a *suggestion*.
    public let starter: String?

    public init(
        format: Int = skillPackageFormat,
        name: String,
        description: String? = nil,
        version: String? = nil,
        author: String? = nil,
        model: ModelHint? = nil,
        skills: [SkillSpec],
        blueprints: [BlueprintSpec]? = nil,
        starter: String? = nil
    ) {
        self.format = format
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.model = model
        self.skills = skills
        self.blueprints = blueprints
        self.starter = starter
    }
}

/// Errors surfaced by package loading and installation.
public enum SkillPackageError: Error, Sendable, Equatable, CustomStringConvertible {
    case manifestMissing
    case manifestInvalid(String)
    case unsupportedFormat(Int)
    case invalidPackageName(String)
    case invalidSkillName(String)
    case skillSourceMissing(String)
    case noSkillsSpecified
    case securityRejected([String])
    case directoryCopyFailed(String)

    public var description: String {
        switch self {
        case .manifestMissing:
            return "No manifest.json found in the package."
        case .manifestInvalid(let detail):
            return "manifest.json is invalid: \(detail)"
        case .unsupportedFormat(let format):
            return "Unsupported manifest format \(format) (this build supports \(skillPackageFormat))."
        case .invalidPackageName(let name):
            return "Invalid package name '\(name)'. Use lowercase letters, digits, hyphens or underscores (1-64 chars)."
        case .invalidSkillName(let name):
            return "Invalid skill name '\(name)'. Use lowercase letters, digits, hyphens or underscores (1-64 chars)."
        case .skillSourceMissing(let rel):
            return "Skill source '\(rel)' does not exist or has no SKILL.md."
        case .noSkillsSpecified:
            return "The manifest lists no skills to install."
        case .securityRejected(let names):
            return "Security scan rejected skill(s): \(names.joined(separator: ", ")). Refusing to install an unsafe package. Pass --allow-unsafe to override."
        case .directoryCopyFailed(let detail):
            return "Failed to copy skill files: \(detail)"
        }
    }
}

/// A single skill installation outcome.
public struct SkillInstallFailure: Sendable, Equatable, CustomStringConvertible {
    public let name: String
    public let reason: String
    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
    public var description: String { "\(name): \(reason)" }
}

/// The result of installing a skill package.
public struct SkillInstallReport: Sendable, Equatable, CustomStringConvertible {
    /// Skills successfully copied into the skills directory.
    public let installed: [String]
    /// Skills skipped because they already existed (and overwrite was off).
    public let skipped: [String]
    /// Skills that failed validation/install, with reasons.
    public let failures: [SkillInstallFailure]
    /// The manifest's suggested model hint (recommendation only).
    public let modelHint: SkillPackageManifest.ModelHint?
    /// The manifest's optional blueprint suggestions.
    public let blueprints: [SkillPackageManifest.BlueprintSpec]
    /// The manifest's optional starter prompt file (recommendation only).
    public let starter: String?
    /// The skills directory that was targeted.
    public let targetDirectory: String

    public init(
        installed: [String],
        skipped: [String],
        failures: [SkillInstallFailure],
        modelHint: SkillPackageManifest.ModelHint?,
        blueprints: [SkillPackageManifest.BlueprintSpec],
        starter: String?,
        targetDirectory: String
    ) {
        self.installed = installed
        self.skipped = skipped
        self.failures = failures
        self.modelHint = modelHint
        self.blueprints = blueprints
        self.starter = starter
        self.targetDirectory = targetDirectory
    }

    public var installedCount: Int { installed.count }
    public var skippedCount: Int { skipped.count }
    public var failureCount: Int { failures.count }

    public var description: String {
        var lines: [String] = []
        lines.append("⚡ ARC Agent — Skill package installed")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        lines.append("  Target:  \(targetDirectory)")
        lines.append("  Installed: \(installedCount)")
        for name in installed { lines.append("    + \(name)") }
        if !skipped.isEmpty {
            lines.append("  Skipped (already present): \(skippedCount)")
            for name in skipped { lines.append("    = \(name)") }
        }
        if !failures.isEmpty {
            lines.append("  Failed: \(failureCount)")
            for f in failures { lines.append("    ! \(f.description)") }
        }
        if let hint = modelHint {
            var s = "  Suggested model: \(hint.model ?? "(default)")"
            if let provider = hint.provider { s += " (\(provider))" }
            lines.append(s)
            lines.append("    (recommendation only — apply with `arc config` if desired.)")
        }
        if !blueprints.isEmpty {
            lines.append("  Suggested blueprints (not auto-scheduled):")
            for b in blueprints {
                lines.append("    · \(b.file) — \(b.schedule)")
            }
        }
        if let starter {
            lines.append("  Suggested starter prompt: \(starter)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Installs a skill package (a directory with `manifest.json` + `skills/`)
/// into a target skills directory.
///
/// The installer is deliberately the *only* place that touches the target
/// skills tree, so the flow is isolated, testable and safe: scan everything
/// first, then copy.
public enum SkillPackageInstaller {

    /// Validate a skill install name (slugs only: lowercase, digits, hyphen,
    /// underscore). Mirrors the skill file naming rules so installed skills
    /// are discovered by the existing skill scanning.
    public static func isValidSkillName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let pattern = #"^[a-z0-9][a-z0-9-_]*$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Validate a package name (same slug rules).
    public static func isValidPackageName(_ name: String) -> Bool {
        isValidSkillName(name)
    }

    /// Load and validate a manifest from a package root directory.
    public static func loadManifest(packageDirectory: URL) throws -> SkillPackageManifest {
        let manifestURL = packageDirectory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SkillPackageError.manifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw SkillPackageError.manifestInvalid(error.localizedDescription)
        }
        let manifest: SkillPackageManifest
        do {
            manifest = try JSONDecoder().decode(SkillPackageManifest.self, from: data)
        } catch {
            throw SkillPackageError.manifestInvalid(error.localizedDescription)
        }
        guard manifest.format == skillPackageFormat else {
            throw SkillPackageError.unsupportedFormat(manifest.format)
        }
        guard isValidPackageName(manifest.name) else {
            throw SkillPackageError.invalidPackageName(manifest.name)
        }
        guard !manifest.skills.isEmpty else {
            throw SkillPackageError.noSkillsSpecified
        }
        return manifest
    }

    /// Scan a skill directory's SKILL.md and supporting text files for
    /// injection patterns. Returns the names of offending files, or empty if
    /// the skill is clean.
    public static func securityFindings(skillDirectory: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: skillDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var findings: [String] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            // Scan markdown and plain-text skill sources; skip binaries.
            guard ["md", "markdown", "txt", "sh", "swift", "js", "py", "json", "yaml", "yml"].contains(ext)
                || ext.isEmpty else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if let threat = ContextFileScanner.scan(content) {
                let rel = fileURL.path.replacingOccurrences(of: skillDirectory.path + "/", with: "")
                findings.append("\(rel) (\(threat.rawValue))")
            }
        }
        return findings
    }

    /// Install a skill package into `skillsRoot`.
    ///
    /// - Parameters:
    ///   - packageDirectory: Directory containing `manifest.json` + `skills/`.
    ///   - skillsRoot: The target skills directory (e.g. `~/.arc/skills`).
    ///   - overwrite: Replace already-present skills instead of skipping them.
    ///   - allowUnsafe: Bypass the injection-pattern scan (not recommended).
    /// - Returns: A ``SkillInstallReport`` describing what happened.
    /// - Throws: ``SkillPackageError`` on a manifest/validation/scan failure.
    public static func install(
        packageDirectory: URL,
        into skillsRoot: URL,
        overwrite: Bool = false,
        allowUnsafe: Bool = false
    ) throws -> SkillInstallReport {
        let manifest = try loadManifest(packageDirectory: packageDirectory)
        let fm = FileManager.default

        // Resolve each skill source to a directory and validate names + scan
        // up-front, so we never partially install a rejected package.
        struct Prepared {
            let name: String
            let sourceDir: URL
            let category: String?
        }
        var prepared: [Prepared] = []
        var validationFailures: [SkillInstallFailure] = []
        var scanViolations: [String] = []

        for spec in manifest.skills {
            guard isValidSkillName(spec.name) else {
                validationFailures.append(SkillInstallFailure(name: spec.name, reason: "invalid skill name"))
                continue
            }
            let rel = spec.source ?? "skills/\(spec.name)"
            let sourceDir = packageDirectory.appendingPathComponent(rel)
            let skillFile = sourceDir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else {
                validationFailures.append(SkillInstallFailure(name: spec.name, reason: "missing source \(rel)/SKILL.md"))
                continue
            }
            let findings = securityFindings(skillDirectory: sourceDir)
            if !findings.isEmpty {
                // Fail closed unless the caller explicitly bypassed the gate.
                if !allowUnsafe {
                    for f in findings { scanViolations.append("\(spec.name): \(f)") }
                    continue
                }
            }
            prepared.append(Prepared(name: spec.name, sourceDir: sourceDir, category: spec.category))
        }

        // A rejected package installs nothing — fail closed.
        if !scanViolations.isEmpty {
            throw SkillPackageError.securityRejected(scanViolations)
        }

        // Make the target directory.
        try fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)

        var installed: [String] = []
        var skipped: [String] = []
        var failures = validationFailures

        for item in prepared {
            let target = skillsRoot.appendingPathComponent(item.name)
            if fm.fileExists(atPath: target.path) {
                if overwrite {
                    do { try fm.removeItem(at: target) }
                    catch {
                        failures.append(SkillInstallFailure(name: item.name, reason: "could not overwrite: \(error.localizedDescription)"))
                        continue
                    }
                } else {
                    skipped.append(item.name)
                    continue
                }
            }
            do {
                try fm.copyItem(at: item.sourceDir, to: target)
                if let category = item.category {
                    try applyCategory(category, to: target.appendingPathComponent("SKILL.md"))
                }
                installed.append(item.name)
            } catch {
                failures.append(SkillInstallFailure(name: item.name, reason: error.localizedDescription))
            }
        }

        return SkillInstallReport(
            installed: installed,
            skipped: skipped,
            failures: failures,
            modelHint: manifest.model,
            blueprints: manifest.blueprints ?? [],
            starter: manifest.starter,
            targetDirectory: skillsRoot.path
        )
    }

    /// Inject (or replace) the `category` frontmatter key in an installed
    /// SKILL.md, preserving all other keys. Idempotent and non-destructive.
    static func applyCategory(_ category: String, to skillFile: URL) throws {
        guard let original = try? String(contentsOf: skillFile, encoding: .utf8) else { return }
        let rewritten = injectCategory(category, into: original)
        try rewritten.write(to: skillFile, atomically: true, encoding: .utf8)
    }

    /// Rewrite frontmatter setting/updating the `category` key.
    static func injectCategory(_ category: String, into content: String) -> String {
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.hasPrefix("---\n"), let end = content.range(of: "\n---\n") else {
            return content
        }
        let front = String(content.dropFirst(4)[..<end.lowerBound])
        var lines: [String] = []
        var found = false
        for line in front.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("category:") {
                lines.append("category: \(trimmedCategory)")
                found = true
            } else {
                lines.append(String(line))
            }
        }
        if !found {
            lines.append("category: \(trimmedCategory)")
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + String(content[end.upperBound...])
    }
}
