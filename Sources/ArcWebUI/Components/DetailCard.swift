import ArcTheme
import WebUI
import WebUIDesignSystem

// MARK: - Detail card

/// a detail card: `.detail-card` with a `.detail-title` heading and a
/// `.detail-sub` sub-line, plus body children.
///
/// the base class derives from the type name, so `detail-card` is written
/// nowhere; the two optional lines above the body are declared as parts and the
/// shared renderer emits them in declaration order, with no renderer here.
///
/// a line that does not exist in the source must not exist in the output: the
/// sheet gives both `.detail-title` and `.detail-sub` their own margins, so an
/// empty part is omitted entirely rather than rendered as an empty node.
///
/// the part tokens are named through `ArcClass` rather than spelled as strings,
/// so the enum stays the only place a token is written. they cannot go through a
/// `ClassName` static yet: `Div(class:)` still carries both an `ArcClass` and a
/// `ClassName` overload, and a static would make every bare `.detailSub` call
/// site ambiguous — the statics and the removal of those overloads move together
/// in Slice B.
@StyledElement(.div)
public struct DetailCard<Content: WebUI.View> {
	@Part(.h1, class: ClassName(ArcClass.detailTitle)) public var title: String = ""
	@Part(.div, class: ClassName(ArcClass.detailSub)) public var sub: String = ""
}
