import Foundation

// MARK: - VStack

/// A view that arranges its children vertically.
///
/// Renders as a `<div>` with flexbox column layout.
/// Uses class names defined in ``AppStyles``.
///
/// ```swift
/// VStack(spacing: 12) {
///     Text("First")
///     Text("Second")
/// }
/// ```
public struct VStack: View {
    /// The horizontal alignment of children.
    public let alignment: HorizontalAlignment
    /// The spacing between children in pixels.
    public let spacing: Int
    /// The child views.
    public let children: [any View]

    /// Create a vertical stack.
    /// - Parameters:
    ///   - alignment: Horizontal alignment of children.
    ///   - spacing: Spacing between children in pixels.
    ///   - content: A view builder for the children.
    public init(
        alignment: HorizontalAlignment = .leading,
        spacing: Int = 8,
        @ViewBuilder content: () -> [any View]
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.children = content()
    }

    public func render() -> String {
        let alignClass = "align-\(alignment.cssValue)"
        return """
        <div class="vstack spacing-\(spacing) \(alignClass)">
        \(children.map { $0.render() }.joined())
        </div>
        """
    }
}

// MARK: - HStack

/// A view that arranges its children horizontally.
///
/// Renders as a `<div>` with flexbox row layout.
/// Uses class names defined in ``AppStyles``.
///
/// ```swift
/// HStack(spacing: 8) {
///     Text("Left")
///     Text("Right")
/// }
/// ```
public struct HStack: View {
    /// The vertical alignment of children.
    public let alignment: HorizontalAlignment
    /// The spacing between children in pixels.
    public let spacing: Int
    /// The child views.
    public let children: [any View]

    /// Create a horizontal stack.
    /// - Parameters:
    ///   - alignment: Vertical alignment of children.
    ///   - spacing: Spacing between children in pixels.
    ///   - content: A view builder for the children.
    public init(
        alignment: HorizontalAlignment = .center,
        spacing: Int = 8,
        @ViewBuilder content: () -> [any View]
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.children = content()
    }

    public func render() -> String {
        let alignClass = "align-\(alignment.cssValue)"
        return """
        <div class="hstack spacing-\(spacing) \(alignClass)">
        \(children.map { $0.render() }.joined())
        </div>
        """
    }
}

// MARK: - Spacer

/// A flexible space view that pushes sibling views apart.
///
/// Renders as an empty `<div>` with `flex: 1`.
///
/// ```swift
/// HStack {
///     Text("Left")
///     Spacer()
///     Text("Right")
/// }
/// ```
public struct Spacer: View {
    /// The minimum size of the spacer.
    public let minSize: Int

    /// Create a spacer.
    /// - Parameter minSize: Minimum size in pixels (default: 0).
    public init(minSize: Int = 0) {
        self.minSize = minSize
    }

    public func render() -> String {
        "<div class=\"spacer\" style=\"flex:1;min-width:\(minSize)px;min-height:\(minSize)px\"></div>"
    }
}

// MARK: - ScrollView

/// A scrollable container view.
///
/// Renders as a `<div>` with `overflow: auto`.
///
/// ```swift
/// ScrollView {
///     MessageList(messages: allMessages)
/// }
/// ```
public struct ScrollView: View {
    /// The child views.
    public let children: [any View]

    /// Create a scroll view.
    /// - Parameter content: A view builder for the children.
    public init(@ViewBuilder content: () -> [any View]) {
        self.children = content()
    }

    public func render() -> String {
        """
        <div class="scrollview">
        \(children.map { $0.render() }.joined())
        </div>
        """
    }
}
