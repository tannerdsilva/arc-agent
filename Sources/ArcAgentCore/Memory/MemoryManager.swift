import Foundation

// MARK: - Memory manager (Hermes `memory_manager.py`)

/// Builds the memory-context block injected into prompts with fence tags and
/// bounded head/tail trimming (Hermes: 6000-char cap, 4000 head, 1500 tail,
/// truncation marker), plus scrubber rules and the provider-tools block.
public enum MemoryManager {

    public static let maxContextChars = 6_000
    public static let headChars = 4_000
    public static let tailChars = 1_500
    public static let truncationMarker = "\n...[memory provider context truncated]...\n"

    /// Fence tags (Hermes memory-context tags; the agent must not confuse
    /// memory text with the live conversation).
    public static let openTag = "<memory-context>"
    public static let closeTag = "</memory-context>"

    /// Scrub dangerous content out of memory entries before they enter the
    /// context (Hermes scrubber): drop zero-width/control characters and
    /// strip ANSI escape sequences.
    public static func scrub(_ text: String) -> String {
        var result = text
        // ANSI escapes: ESC [ ... letter
        result = result.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        // Zero-width and control characters (keep \n \t \r).
        result = String(result.unicodeScalars.filter { scalar in
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D { return true }
            if scalar.value < 0x20 { return false }          // C0 controls
            if scalar.value == 0x7F { return false }          // DEL
            if (0x200B...0x200F).contains(scalar.value) { return false }  // zero-width
            if (0x2028...0x2029).contains(scalar.value) { return false }
            return true
        })
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Render the memory context block: newest entries first, head+tail
    /// trimming, fenced with the tags (Hermes memory_context build).
    public static func buildContext(entries: [(priority: Double, text: String)]) -> String? {
        guard !entries.isEmpty else { return nil }
        let ordered = entries.sorted { $0.priority > $1.priority }
        let scrubbed = ordered.map { scrub($0.text) }.filter { !$0.isEmpty }
        let joined = scrubbed.joined(separator: "\n\n")
        let bounded: String
        if joined.utf8.count <= maxContextChars {
            bounded = joined
        } else {
            let head = String(joined.prefix(headChars))
            let tail = String(joined.suffix(tailChars))
            bounded = head + truncationMarker + tail
        }
        return "\(openTag)\n\(bounded)\n\(closeTag)"
    }

    /// Provider-tools injection block (Hermes memory provider tools context):
    /// tells the agent which memory operations are available.
    public static func providerToolsBlock(providerName: String, hasSearch: Bool, hasWrite: Bool) -> String {
        var block = "<memory-provider name=\"\(providerName)\">"
        if hasSearch { block += "\n- search: query the memory store by keywords" }
        if hasWrite { block += "\n- write: persist a durable fact" }
        block += "\n</memory-provider>"
        return block
    }

    /// Fence + bound a single pre-rendered memory block (used by prompt
    /// builders that receive memory as one string).
    public static func fence(_ text: String) -> String {
        let scrubbed = scrub(text)
        let bounded: String
        if scrubbed.utf8.count <= maxContextChars {
            bounded = scrubbed
        } else {
            let head = String(scrubbed.prefix(headChars))
            let tail = String(scrubbed.suffix(tailChars))
            bounded = head + truncationMarker + tail
        }
        return "\(openTag)\n\(bounded)\n\(closeTag)"
    }
}
