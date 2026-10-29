import WebUI

/// the CSS custom properties arc sets per element.
///
/// each one carries a **value the stylesheet cannot know** — a tree depth, a
/// colour the user picked — and nothing else. the arithmetic
/// (`calc(12px + var(--ws-depth) * 15px)`) and the presentation live in
/// `ChromeSheet`; swift supplies the number.
///
/// naming every variable here is the point: `cssVar(.depth, "3")` cannot be
/// mistyped into a property the sheet does not read, and a colour cannot be
/// passed where a depth belongs.
public enum ArcVar: String, Sendable {
	/// nesting level of a workspace-tree row. unbounded, so it cannot be a
	/// finite set of `[data-depth]` class rules.
	case depth = "--ws-depth"
	/// extra indent for a file row relative to its folder (4px).
	case extra = "--ws-extra"
	/// a user-chosen colour rendered as a swatch or a column stripe.
	case accent = "--accent"
}

extension WebUI.View {
	/// set one CSS custom property on this view.
	///
	/// chained calls fold into a **single** `style` attribute with the
	/// declarations in order, so an element can carry a depth *and* a colour
	/// without either call hand-writing the attribute.
	///
	/// this is the only sanctioned way to write a `style` attribute in this
	/// codebase: values ride as data, the sheet decides what they mean.
	public func cssVar(_ variable: ArcVar, _ value: String) -> some WebUI.View {
		// the mechanism lives in no-webui (`cssVar(CSSVariable, CSSValue)`); this
		// overload exists only to keep arc's variable NAMES typed, so there is one
		// implementation of the style-attribute contract, not two.
		cssVar(CSSVariable(variable.rawValue), .raw(value))
	}
}