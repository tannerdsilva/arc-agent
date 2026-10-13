import Foundation

// MARK: - Profile editing tool
//
// The ONLY sanctioned agent path for editing MEMORY.md / USER.md / SOUL.md /
// AGENTS.md while the profile lockdown is active (see ``AgentPowers``). The
// general `memory` tool's writes are gated by the same locks, and
// `write_file`/`terminal` refuse the locked files as defense in depth — so
// this tool is the only way in until the user unlocks a surface in Settings →
// Agent powers.

public enum ProfileEditTool {

    /// Where MEMORY.md / USER.md live. Defaults to ``AgentPowers/memoriesDirectory``
    /// so tests can redirect by overriding that.
    static var memoriesDirectory: URL {
        AgentPowers.memoriesDirectory
    }

    static let validFiles: Set<String> = ["memory", "user", "soul", "agents"]

    public static let entry = ToolEntry(
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

            guard validFiles.contains(file) else {
                return "Error: 'file' must be one of: memory, user, soul, agents."
            }
            guard action == "read" || action == "write" else {
                return "Error: 'action' must be 'read' or 'write'."
            }

            // Writes are locked; reads always allowed.
            if action == "write", let refusal = AgentPowers.profileWriteRefusal(file: file) {
                return "Error: " + refusal
            }

            switch file {
            case "memory", "user":
                let url = memoriesDirectory
                    .appendingPathComponent(file == "memory" ? "MEMORY.md" : "USER.md")
                if action == "read" {
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                        return "No \(file.uppercased()) content yet."
                    }
                    return content.isEmpty ? "No \(file.uppercased()) content yet." : content
                }
                do {
                    try FileManager.default.createDirectory(
                        at: memoriesDirectory, withIntermediateDirectories: true)
                    try ((args["content"] as? String) ?? "").write(to: url, atomically: true, encoding: .utf8)
                    return "Updated \(file.uppercased())."
                } catch {
                    return "Error: could not write \(file.uppercased()): \(error.localizedDescription)"
                }

            case "soul":
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

            case "agents":
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

            default:
                return "Error: unknown file '\(file)'."
            }
        },
        emoji: "🛡️"
    )
}
