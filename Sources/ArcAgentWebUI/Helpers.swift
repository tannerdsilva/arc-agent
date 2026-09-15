import Foundation
import WebUI

// MARK: - Encoding helpers

/// Base64url encode (no padding) — safe for HTML ids/attributes.
func enc(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Base64url decode (accepts missing padding).
func dec(_ s: String) -> String? {
    var b = s
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    guard let d = Data(base64Encoded: b) else { return nil }
    return String(data: d, encoding: .utf8)
}

/// HTML-escape arbitrary text for safe embedding.
func esc(_ s: String) -> String {
    htmlEscape(s)
}

/// Truncate a string to `max` characters, appending an ellipsis.
func trunc(_ s: String, _ max: Int) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= max { return trimmed }
    return String(trimmed.prefix(max)) + "…"
}

/// A short human-readable timestamp (e.g. "2:41 pm").
func shortTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
}

/// Format a token count with thousands separators (Hermes: `1,234 in · 567 out`).
func fmtTokens(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

/// Format tokens-per-second (Hermes: ≥100 rounds + groups, below shows 1dp).
func fmtTps(_ v: Double) -> String {
    guard v.isFinite, v > 0 else { return "" }
    if v >= 100 { return "\(fmtTokens(Int(v.rounded()))) t/s" }
    return String(format: "%.1f t/s", v)
}

// MARK: - Small HTML fragments

/// A tiny attribute string builder used across renderers.
func attr(_ name: String, _ value: String) -> String {
    " \(name)=\"\(esc(value))\""
}

func div(_ id: String?, _ cls: String, _ content: String) -> String {
    let idAttr = id.map { " id=\"\($0)\"" } ?? ""
    return "<div\(idAttr) class=\"\(cls)\">\(content)</div>"
}

func btn(_ id: String, _ component: String, _ cls: String, _ label: String, _ extra: String = "") -> String {
    "<button type=\"button\" id=\"\(id)\"\(extra) data-component-id=\"\(component)\" class=\"\(cls)\">\(label)</button>"
}
