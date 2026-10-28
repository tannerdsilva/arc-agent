import Foundation

// MARK: - Profile editing tool
//
// The ONLY sanctioned agent path for editing MEMORY.md / USER.md / SOUL.md /
// AGENTS.md while the profile lockdown is active. The authority it exercises
// is the ``ToolGrant`` inside the caller's ``ToolContext`` — not a
// process-global read — and each document resolves to exactly one address:
//
// - `memory` / `user` → the ``ProfileDocuments`` this tool was built with,
//   bound to the calling profile's directory;
// - `soul` → the calling profile's record (``ToolContext/profile``), unless
//   the caller names another profile explicitly;
// - `agents` → `AGENTS.md` under ``ToolContext/workspace``, not the process's
//   working directory.
//
// The general `memory` tool's writes are gated by the same grant, and
// `write_file`/`terminal` refuse the locked files as defense in depth — so
// this tool is the only way in until the user unlocks a surface in Settings →
// Agent powers.

public enum ProfileEditTool {

    /// The tool, scoped to one caller.
    ///
    /// - Parameters:
    ///   - context: the calling identity. Its `profile` is the default SOUL
    ///     address and its `workspace` is where `AGENTS.md` lives; its `grant`
    ///     decides every write.
    ///   - documents: the calling profile's MEMORY.md / USER.md, bound to one
    ///     root. A write to another profile's document is not representable.
    ///   - profiles: the roster, for SOUL (stored in the profile record).
    public static func entry(
        context: ToolContext,
        documents: ProfileDocuments,
        profiles: any ProfileStore
    ) -> ToolEntry {
        ToolEntry(
            name: "profile_edit",
            toolset: "profile",
            description: "Read or edit the agent's profile files: MEMORY (the agent's persistent "
                + "notes), USER (the user profile), SOUL (the profile persona/prompt), AGENTS "
                + "(workspace AGENTS.md). Read is always allowed; writes refuse locked files. "
                + "SOUL defaults to your own profile. "
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
                    "profile": .string(description: "Profile name for SOUL editing (default: your own profile)."),
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
                if action == "write", let refusal = context.grant.refusal(for: document) {
                    return "Error: " + refusal
                }

                switch document {
                case .memory, .user:
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
                    // The caller's own profile unless another is named: a
                    // missing `profile` argument must not silently address
                    // `default` from a profile-scoped agent.
                    let profileName = (args["profile"] as? String) ?? context.profile.rawValue
                    guard let name = ProfileName(profileName) else {
                        return "Error: invalid profile name '\(profileName)'."
                    }
                    guard var profile = try await profiles.get(name) else {
                        return "Error: profile '\(profileName)' not found."
                    }
                    if action == "read" {
                        return profile.soulMD ?? "(no SOUL content set for '\(profileName)')"
                    }
                    profile.soulMD = (args["content"] as? String) ?? ""
                    profile.updatedAt = Date()
                    do {
                        try await profiles.put(profile)
                        return "Updated SOUL for profile '\(profileName)'."
                    } catch {
                        return "Error: could not update SOUL: \(error.localizedDescription)"
                    }

                case .agents:
                    let url = URL(fileURLWithPath: context.workspace)
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
}
