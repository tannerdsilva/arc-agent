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

/// A base URL trimmed for a dropdown's secondary line: strip the scheme and a
/// trailing slash, so `https://api.example.com/` reads `api.example.com`.
func shortURL(_ s: String) -> String {
    var u = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if u.hasSuffix("/") { u.removeLast() }
    if let range = u.range(of: "://") {
        u = String(u[u.index(range.lowerBound, offsetBy: 3)...])
    }
    return u.isEmpty ? s : u
}

/// A short human-readable timestamp (e.g. "2:41 pm").
func shortTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
}

/// Format a token count with thousands separators (reference: `1,234 in · 567 out`).
func fmtTokens(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

/// Format tokens-per-second (reference: ≥100 rounds + groups, below shows 1dp).
func fmtTps(_ v: Double) -> String {
    guard v.isFinite, v > 0 else { return "" }
    if v >= 100 { return "\(fmtTokens(Int(v.rounded()))) t/s" }
    return String(format: "%.1f t/s", v)
}

// MARK: - Typed markup bridge

/// materialize a fragment view into the wire type the push pipeline carries.
///
/// `FragmentUpdate.html` is a `String`; converting at this one edge is what
/// lets every builder above it return a typed view while the push path, the
/// deduper and the client stay unchanged.
@inlinable
func fragment(_ id: String, _ view: some WebUI.View) -> FragmentUpdate {
    FragmentUpdate(id: id, html: view.markup.html)
}

/// render a typed view where a `-> String` signature must survive one more phase.
@inlinable
func render<V: WebUI.View>(_ view: V) -> String { view.markup.html }

/// existential overload: a `[any View]` element (a block collected into a list)
/// still needs to become bytes at the push edge.
@inlinable
func render(_ view: any WebUI.View) -> String { view.markup.html }
