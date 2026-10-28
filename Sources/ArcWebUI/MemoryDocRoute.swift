import Foundation
import ArcAgentCore

/// Routes the web-UI "Memory" panel's documents to the agent's *real* memory
/// backend instead of a web-UI-only copy.
///
/// Previously the panel did raw file I/O against `~/.arc-agent-webui/{MEMORY,
/// USER, SOUL}.md` — a set of files the running agent never reads. That meant
/// edits in the Memory panel silently diverged from the memory the agent
/// actually injects into prompts. This router fixes it:
///
/// - `memory` and `user` go through the wired ``MemoryProvider`` (file-backed
///   `~/.arc/memories/` in file mode, or the Tessera store), so what the panel
///   edits is exactly what the agent reads.
/// - `soul` is profile-scoped (``Profile.soulMD``).
/// - `context` is a read-only workspace file and is handled separately by the
///   caller.
enum MemoryDocRoute {

    /// The display filename for a memory-panel doc key (toast text).
    static func fileName(_ key: String) -> String {
        switch key {
        case "memory": return "MEMORY.md"
        case "user": return "USER.md"
        case "soul": return "SOUL.md"
        default: return "file"
        }
    }

    /// The profile whose SOUL the panel reads/edits. Empty means "use the
    /// default primary profile". Passed in by the caller so this stays a pure
    /// function of its inputs (and testable without a full ``AppState``).
    static func load(
        _ key: String,
        memory: (any MemoryProvider)?,
        profileName: String?
    ) async -> String {
        switch key {
        case "memory":
            guard let memory else { return "" }
            return (try? await memory.readMemory()) ?? ""
        case "user":
            guard let memory else { return "" }
            return (try? await memory.readUser()) ?? ""
        case "soul":
            let name = (profileName?.isEmpty ?? true) ? "default" : profileName!
            guard let profile = try? await ProfileManager().get(name: name) else {
                return ""
            }
            return profile.soulMD ?? ""
        default:
            return ""
        }
    }

    /// Write `content` for a doc key; returns whether the write succeeded.
    static func save(
        _ key: String,
        content: String,
        memory: (any MemoryProvider)?,
        profileName: String?
    ) async -> Bool {
        switch key {
        case "memory":
            guard let memory else { return false }
            do { try await memory.writeMemory(content); return true }
            catch { return false }
        case "user":
            guard let memory else { return false }
            do { try await memory.writeUser(content); return true }
            catch { return false }
        case "soul":
            let name = (profileName?.isEmpty ?? true) ? "default" : profileName!
            let pm = ProfileManager()
            do {
                guard var profile = try await pm.get(name: name) else {
                    return false
                }
                profile.soulMD = content
                try await pm.update(profile)
                return true
            } catch {
                return false
            }
        default:
            return false
        }
    }
}
