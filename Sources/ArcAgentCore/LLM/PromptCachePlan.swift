import Foundation

/// Anthropic prompt-caching plan (Hermes `prompt_caching.py`).
///
/// Default layout uses 4 `cache_control` breakpoints: the static system
/// prefix, the end of the system prompt, and the last 2 non-system
/// messages. Without a static system prefix, it falls back to one system
/// breakpoint + the last 2 non-system messages. Markers are
/// `{"type": "ephemeral", "ttl": "5m"}` (or `1h`).
public enum PromptCachePlan {

    /// Number of Anthropic cache breakpoints in the default layout.
    public static let defaultBreakpoints = 4
    public static let defaultTTL = "5m"
    public static let longTTL = "1h"

    static func marker(ttl: String = defaultTTL) -> [String: String] {
        var m: [String: String] = ["type": "ephemeral"]
        if ttl == longTTL { m["ttl"] = ttl }
        return m
    }

    /// Add `cache_control` to a single message dict.
    /// Mirrors Hermes `_apply_cache_marker` handling all shape variations:
    /// - Native Anthropic layout: top-level `cache_control` (adapter moves it
    ///   inside the tool_result block).
    /// - Empty tool message with `role: tool` on non-native routes: skipped
    ///   (OpenRouter rejects top-level markers on role:tool).
    /// - String content is converted to a single text block carrying the marker.
    /// - List content: marker lands on the last block.
    public static func applyMarker(to message: inout [String: Any], ttl: String = defaultTTL) {
        let marker = marker(ttl: ttl)
        let role = message["role"] as? String ?? ""
        var content = message["content"]

        if content == nil || (content as? String)?.isEmpty == true {
            if role == "tool" { return }
            message["cache_control"] = marker
            return
        }
        if let text = content as? String {
            message["content"] = [["type": "text", "text": text, "cache_control": marker]]
            return
        }
        if var blocks = content as? [[String: Any]], !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = marker
            message["content"] = blocks
        }
    }

    /// Strip all `cache_control` markers from messages (Hermes
    /// `strip_anthropic_cache_control`) — used for providers/copies where
    /// markers must not leak.
    public static func stripMarkers(from messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { msg in
            var m = msg
            m.removeValue(forKey: "cache_control")
            var content = m["content"]
            if var blocks = content as? [[String: Any]] {
                for i in blocks.indices { blocks[i].removeValue(forKey: "cache_control") }
                m["content"] = blocks
            } else if var text = content as? [String: Any] {
                text.removeValue(forKey: "cache_control")
                m["content"] = text
            }
            return m
        }
    }

    /// Strip markers from a tool-schemas array (Hermes
    /// `strip_anthropic_tool_cache_control`).
    public static func stripToolMarkers(from tools: [[String: Any]]) -> [[String: Any]] {
        tools.map { t in
            var tool = t
            tool.removeValue(forKey: "cache_control")
            var function = tool["function"] as? [String: Any] ?? [:]
            function.removeValue(forKey: "cache_control")
            tool["function"] = function
            return tool
        }
    }

    /// Apply the 4-breakpoint plan to OpenAI-format `apiMessages`.
    /// `staticSystemPrefix` is the byte-stable first tier of the system prompt;
    /// when present it is split at the boundary so the prefix gets its own
    /// cache breakpoint (Hermes `apply_anthropic_cache_control` +
    /// `build_prompt_cache_plan`).
    public static func plan(
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        cacheTTL: String = defaultTTL,
        staticSystemPrefix: String? = nil
    ) -> (messages: [[String: Any]], tools: [[String: Any]]) {
        var plannedMessages = messages
        let plannedTools = stripToolMarkers(from: tools ?? [])

        // Breakpoint budget: staticSystemPrefix breakpoint, system-end
        // breakpoint, then the last 2 non-system messages — max 4.
        var remaining = defaultBreakpoints
        var marker = marker(ttl: cacheTTL)

        if let prefix = staticSystemPrefix, !prefix.isEmpty {
            // Split the first system message at the prefix boundary.
            if let idx = plannedMessages.firstIndex(where: { ($0["role"] as? String) == "system" }),
               var system = plannedMessages[idx] as? [String: Any] {
                let full = (system["content"] as? String) ?? ""
                if full.hasPrefix(prefix) {
                    let suffix = String(full.dropFirst(prefix.count))
                    var prefixBlock: [String: Any] = ["type": "text", "text": prefix, "cache_control": marker]
                    var suffixBlock: [String: Any] = ["type": "text", "text": suffix]
                    var blocks: [[String: Any]] = [prefixBlock]
                    if !suffix.isEmpty { blocks.append(suffixBlock) }
                    system["content"] = blocks
                    plannedMessages[idx] = system
                    remaining -= 1
                }
            }
        }

        // System-end breakpoint: last message with role == system (or the
        // first assistant boundary if no system message exists).
        let lastSystem = plannedMessages.lastIndex { ($0["role"] as? String) == "system" }
        if remaining > 0, let ls = lastSystem {
            var msg = plannedMessages[ls]
            PromptCachePlan.applyMarker(to: &msg, ttl: cacheTTL)
            plannedMessages[ls] = msg
            remaining -= 1
        }

        // Last 2 non-system messages.
        let nonSystem = plannedMessages.indices.filter { idx in (plannedMessages[idx]["role"] as? String) != "system" }
        for idx in nonSystem.suffix(min(2, max(0, remaining))).reversed() {
            guard remaining > 0 else { break }
            var msg = plannedMessages[idx]
            let role = msg["role"] as? String ?? ""
            if role == "tool" {
                // Non-native route: top-level marker on role:tool is rejected;
                // the adapter moves the marker inside the tool_result block.
                if var contentList = msg["content"] as? [[String: Any]], !contentList.isEmpty {
                    contentList[contentList.count - 1]["cache_control"] = marker
                    msg["content"] = contentList
                }
            } else {
                PromptCachePlan.applyMarker(to: &msg, ttl: cacheTTL)
            }
            plannedMessages[idx] = msg
            remaining -= 1
        }

        return (plannedMessages, plannedTools)
    }
}
