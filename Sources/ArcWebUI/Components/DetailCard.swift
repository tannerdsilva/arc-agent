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
/// the part tokens are named through `ClassName` statics, so the enum stays the
/// only place a token is written and no call site spells a class string.
@StyledElement(.div)
public struct DetailCard<Content: WebUI.View> {
	@Part(.h1, class: .detailTitle) public var title: String = ""
	@Part(.div, class: .detailSub) public var sub: String = ""
}
