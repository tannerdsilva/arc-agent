import WebUICore

// MARK: - Spacing door

/// an edge a single-sided margin lands on.
///
/// no-webui's master keeps `.margin(_:)` for one uniform length and dropped the
/// edge + `SpaceToken` overload the declared-surface line used. arc names the
/// edge and the token here, so the six single-sided call sites stay on the
/// design system's scale instead of hand-writing a style attribute.
public enum MarginEdge: String, Sendable {
	case top
	case bottom
	case left
	case right
}

extension View {

	/// one edge's margin, on the design system's space scale.
	public func margin(_ edge: MarginEdge, _ space: SpaceToken) -> ModifiedView<Self, InlineStyle> {
		ModifiedView(
			content: self,
			modifier: InlineStyle(.custom("margin-\(edge.rawValue)"),
			                      "var(\(space.cssVariable))")
		)
	}
}
