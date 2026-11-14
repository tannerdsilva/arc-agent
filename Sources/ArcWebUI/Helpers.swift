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
/// `FragmentUpdate.html` is a `String`; converting at this one edge is what lets
/// a builder return a typed view while the wire type stays a string.
///
/// **This helper is for direct broadcasts only.** Anything that flows through the
/// push door (`Controller.push` → `PushEdge`) must NOT assemble html: it returns
/// `structuralChange()` and the door asks the server to re-render the pages it
/// served, whose diff decides every region.
/// The surviving callers are the producers that never reach that door:
///
/// - `liveLogFragments()` (`log-lines`) and `liveWorkspaceFragments()` (`ws-tree`)
///   are broadcast straight to `WebUIServer.broadcast` by `WebUIHost`'s
///   interval streamers, so the door never sees or refreshes them;
/// - `liveFragments()`' three nodes (`live-turn`, `composer-flyout`, `ctx-meter`)
///   are replaced inside a batch the door treats as structural, so their bytes
///   are discarded and the server's render carries them.
///
/// Deltas (`FragmentUpdate.text`) are the other sanctioned explicit shape: they
/// target a node another producer owns, and the door forwards them untouched.
///
/// Every frame this helper builds carries `transition: false` — the server's
/// refresh frames carry the same flag from the diff policy ("the diff is not a
/// navigation and must not animate", `AppShell.refreshPolicy`), and these frames
/// bypass that door. An un-flagged broadcast frame opts INTO the engine's
/// `startViewTransition` wrapper, whose update callback starves in a
/// compositor-starved tab: `callbackPending` sticks and the engine refuses every
/// later fragment batch until real compositing resumes (the 2026-11-01 audit's
/// toast-expiry defect). Streamer ticks land mid-anything — they never animate.
@inlinable
func fragment(_ id: String, _ view: some WebUI.View) -> FragmentUpdate {
    FragmentUpdate(id: id, html: view.markup.html, transition: false)
}

/// render a typed view where a `-> String` signature must survive one more phase.
@inlinable
func render<V: WebUI.View>(_ view: V) -> String { view.markup.html }

/// existential overload: a `[any View]` element (a block collected into a list)
/// still needs to become bytes at the push edge.
@inlinable
func render(_ view: any WebUI.View) -> String { view.markup.html }

// MARK: - Vocabulary attributes

extension WebUI.View {
    /// `data-open` + `data-dismiss` in one contribution: no-webui 2.15.0's
    /// dismiss arming makes the pair one contract (a layer arms only while its
    /// `data-open` holder is open, so the state and the membership can never be
    /// stated apart), and one contribution instead of two modifiers keeps a
    /// popover's chain from growing a second cliff — D-5(a′) measured that
    /// modifier chains at this seam can segfault the whole shell render.
    ///
    /// - parameter serial: the open serial to render, or nil for the closed
    ///   state. The engine reads the attribute's PRESENCE; the changing value is
    ///   what makes an open render byte-different from the previous one, so the
    ///   diff ships it even when the server rendered that popover open before
    ///   the client dismissed it (see `AppState.composerPopoverSerial`).
    func dismissibleOpen(_ serial: Int?) -> ModifiedView<Self, AttributeContribution> {
        guard let serial else {
            return ModifiedView(content: self, modifier: AttributeContribution(""))
        }
        return ModifiedView(content: self, modifier: AttributeContribution(
            " data-open=\"\(serial)\" data-dismiss=\"\""))
    }

    /// emit `data-focus-into="<id>"` when `id` is non-nil, and nothing otherwise
    /// — the same contribution shape as `dismissibleOpen`, for a one-render
    /// focus statement (the new-chat caret). Typed: the attribute text comes
    /// from `FocusInto`, never a hand-written string.
    func focusInto(_ id: String?) -> ModifiedView<Self, AttributeContribution> {
        guard let id else {
            return ModifiedView(content: self, modifier: AttributeContribution(""))
        }
        return ModifiedView(content: self, modifier: AttributeContribution(
            FocusInto(id: id).attribute().attributeText))
    }

    /// attach an `AttributeRepresentable` value (a behavior's attribute, e.g.
    /// `UploadDestination`) to this element.
    ///
    /// the vocabulary owns the name *and* the spelling: `attributeText` escapes
    /// the value and emits the bare form for an empty one, so a call site never
    /// writes a `data-` literal (the attribute census fails on those) and an
    /// empty value cannot become the second spelling `name=""`. this is the same
    /// text the framework's own components splice into a tag.
    func attribute<A: AttributeRepresentable>(_ value: A) -> ModifiedView<Self, AttributeContribution> {
        ModifiedView(content: self, modifier: AttributeContribution(value.attributeText))
    }
}
