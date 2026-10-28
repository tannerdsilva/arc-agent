import Foundation

// MARK: - Profile editing tool
//
// The ONLY sanctioned agent path for editing MEMORY.md / USER.md / SOUL.md /
// AGENTS.md while the profile lockdown is active. The authority it exercises
// is the ``ToolGrant`` it was built with — not a process-global read — and the
// memory/user documents are read and written through ``ProfileDocuments``,
// which is bound to exactly one root.
//
// The general `memory` tool's writes are gated by the same locks, and
// `write_file`/`terminal` refuse the locked files as defense in depth — so
// this tool is the only way in until the user unlocks a surface in Settings →
// Agent powers.

public enum ProfileEditTool {

    /// Where MEMORY.md / USER.md live. Defaults to ``AgentPowers/memoriesDirectory``
    /// so tests can redirect by overriding that. Slice 4 of the GROUNDZERO
    /// plan replaces this root with the per-profile one.
    static var memoriesDirectory: URL {
        AgentPowers.memoriesDirectory
    }

    /// The tool, with the authority `grant` carries captured inside it.
    public static func entry(grant: ToolGrant) -> ToolEntry {
        ToolEntry(
            name: "profile_edit",
            toolset: "profile",
            description: "Read or edit the agent's profile files: MEMORY (the agent's persistent "
                + "notes), USER (the user profile), SOUL (the profile persona/prompt), AGENTS "
                + "(workspace AGENTS.md). Read is always allowed; writes refuse locked files. "
                + "The ONLY sanctioned way to edit these while lockdowns are active in Settings "
                + "(Agent powers → Profile).",
            schema: .object(
                description: "Profile edit parameters",
                properties: [
                    "file": .enum(
                        description: "Which profile file: 'memory', 'user', 'soul' or 'agents'.",
                        values: ["memory", "user", "soul", "agents"]
                    ),
                    "action": .enum(
                        description: "Operation: 'read' to view, 'write' to replace the content.",
                        values: ["read", "write"]
                    ),
                    "content": .string(description: "Replacement content (required for 'write')."),
                    "profile": .string(description: "Profile name for SOUL editing (default 'default')."),
                ],
                required: ["file", "action"]
            ),
            handler: { args in
                let file = (args["file"] as? String) ?? ""
                let action = (args["action"] as? String) ?? "read"

                guard let document = ProfileFile(rawValue: file) else {
                    return "Error: 'file' must be one of: memory, user, soul, agents."
                }
                guard action == "read" || action == "write" else {
                    return "Error: 'action' must be 'read' or 'write'."
                }

                // Writes are gated by the captured grant; reads always allowed.
                if action == "write", let refusal = grant.refusal(for: document) {
                    return "Error: " + refusal
                }

                switch document {
                case .memory, .user:
                    let documents = ProfileDocuments(root: memoriesDirectory, grant: grant)
                    if action == "read" {
                        let content = (try? documents.read(document)) ?? ""
                        return content.isEmpty
                            ? "No \(document.displayName) content yet."
                            : content
                    }
                    do {
                        try documents.write(document, (args["content"] as? String) ?? "")
                        return "Updated \(document.displayName)."
                    } catch {
                        return "Error: could not write \(document.displayName): \(error.localizedDescription)"
                    }

                case .soul:
                    let profileName = (args["profile"] as? String) ?? "default"
                    let manager = ProfileManager()
                    guard var profile = try await manager.get(name: profileName) else {
                        return "Error: profile '\(profileName)' not found."
                    }
                    if action == "read" {
                        return profile.soulMD ?? "(no SOUL content set for '\(profileName)')"
                    }
                    profile.soulMD = (args["content"] as? String) ?? ""
                    do {
                        try await manager.update(profile)
                        return "Updated SOUL for profile '\(profileName)'."
                    } catch {
                        return "Error: could not update SOUL: \(error.localizedDescription)"
                    }

                case .agents:
                    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("AGENTS.md")
                    if action == "read" {
                        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                            return "No AGENTS.md in the workspace."
                        }
                        return content
                    }
                    do {
                        try ((args["content"] as? String) ?? "").write(to: url, atomically: true, encoding: .utf8)
                        return "Updated AGENTS.md."
                    } catch {
                        return "Error: could not write AGENTS.md: \(error.localizedDescription)"
                    }
                }
            },
            emoji: "🛡️"
        )
    }

    /// The tool under today's process-global gate.
    ///
    /// Computed, deliberately: a `static let` would capture the grant once at
    /// first access, and every later reconfiguration of ``AgentPowers`` (the
    /// web UI toggles, the tests) would keep seeing the stale capture. Slice 4
    /// replaces this with per-agent construction and deletes it.
    public static var entry: ToolEntry {
        entry(grant: AgentPowers.grant(profile: .default))
    }
}
