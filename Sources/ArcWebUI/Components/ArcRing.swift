import WebUI

/// A typed replacement for the context-window ring drawn by `ctxIndicatorHTML`.
/// Emits the `<svg>` with two `<circle>` elements (track + value) using the
/// same `stroke-dasharray` / `stroke-dashoffset` computation as the legacy
/// string builder. Element names are confined to this one type.
///
/// No `Raw` — every value written is either a literal or a computed number,
/// neither of which can contain user data that needs escaping.
public struct ArcRing: WebUI.View {

    /// Completion in 0...100, clamped to that range at render time.
    public let percentage: Int

    public init(percentage: Int) {
        self.percentage = percentage
    }

    public func render(into buffer: inout HTMLBuffer) {
        let pct = min(100, max(0, percentage))
        let circ = 61.261056745
        let offset = circ * (1 - Double(pct) / 100)
        buffer.beginElement("svg", " class=\"ctx-ring-svg\" viewBox=\"0 0 24 24\" aria-hidden=\"true\"")
        buffer.endOpenTag()
        buffer.beginElement("circle", " class=\"ctx-ring-track\" cx=\"12\" cy=\"12\" r=\"9.75\"")
        buffer.endOpenTag()
        buffer.endElement()
        buffer.beginElement("circle", " class=\"ctx-ring-value\" cx=\"12\" cy=\"12\" r=\"9.75\" style=\"stroke-dasharray:\(circ);stroke-dashoffset:\(offset)\"")
        buffer.endOpenTag()
        buffer.endElement()
        buffer.endElement()
    }
}
