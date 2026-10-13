// MARK: - SidebarTabHTML

/// Small HTML helpers for tab content. The kit is dependency-free, so
/// plugins get escaping here instead of pulling a web-engine or
/// application module.
public enum SidebarTabHTML {

    /// Escape text for HTML element content: `&`, `<`, `>`, `"`, `'`.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Truncate a string to at most `max` characters, appending an
    /// ellipsis when truncated (the ellipsis counts toward `max`).
    public static func trunc(_ s: String, _ max: Int) -> String {
        guard s.count > max, max > 2 else { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    /// Join a list of HTML strings with no separator.
    public static func join(_ parts: [String]) -> String {
        parts.joined()
    }
}
