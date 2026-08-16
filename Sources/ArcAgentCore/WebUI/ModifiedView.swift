import Foundation

// MARK: - ModifiedView

/// A view that wraps another view with a modifier.
///
/// The generic `Content` parameter preserves the concrete type
/// of the wrapped view, enabling the compiler to specialize
/// through the modifier chain.
///
/// You typically do not create ``ModifiedView`` directly — use
/// the modifier methods on ``View`` instead:
///
/// ```swift
/// Text("Hello")
///     .font(size: 16, weight: "600")
///     .foregroundColor("#e0e0e0")
/// ```
///
/// Each modifier method returns a ``ModifiedView`` that chains
/// the previous view with the new modifier.
public struct ModifiedView<Content: View>: View {
    /// The wrapped view.
    public let content: Content
    /// The modifier to apply.
    public let modifier: any ViewModifier

    /// Create a modified view.
    /// - Parameters:
    ///   - content: The view to wrap.
    ///   - modifier: The modifier to apply.
    public init(content: Content, modifier: any ViewModifier) {
        self.content = content
        self.modifier = modifier
    }

    public func render() -> String {
        modifier.apply(to: content.render())
    }
}

// MARK: - Concrete Modifiers

/// A modifier that applies an inline CSS style attribute.
///
/// Renders as `style="property: value;"` on a `<span>` wrapper.
public struct InlineStyle: ViewModifier {
    /// The CSS property name.
    public let property: String
    /// The CSS property value.
    public let value: String

    /// Create an inline style modifier.
    /// - Parameters:
    ///   - property: CSS property name (e.g. `"color"`, `"font-size"`).
    ///   - value: CSS property value (e.g. `"#e0e0e0"`, `"16px"`).
    public init(_ property: String, _ value: String) {
        self.property = property
        self.value = value
    }

    public func apply(to html: String) -> String {
        "<span style=\"\(property): \(value);\">\(html)</span>"
    }
}

/// A modifier that applies an HTML attribute.
///
/// Renders as `key="value"` on a `<span>` wrapper.
public struct HTMLAttribute: ViewModifier {
    /// The attribute name.
    public let key: String
    /// The attribute value.
    public let value: String

    /// Create an HTML attribute modifier.
    /// - Parameters:
    ///   - key: Attribute name (e.g. `"id"`, `"class"`).
    ///   - value: Attribute value.
    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    public func apply(to html: String) -> String {
        "<span \(key)=\"\(value)\">\(html)</span>"
    }
}

// MARK: - Modifier Composition

/// Two modifiers applied in sequence.
///
/// The first modifier is applied to the content, then the second
/// modifier is applied to the result. This enables chaining:
///
/// ```swift
/// InlineStyle("color", "red")
///     .andThen(InlineStyle("font-weight", "bold"))
/// ```
public struct ComposedModifier<First: ViewModifier, Second: ViewModifier>: ViewModifier {
    /// The first modifier to apply.
    public let first: First
    /// The second modifier to apply.
    public let second: Second

    /// Create a composed modifier.
    /// - Parameters:
    ///   - first: The first modifier.
    ///   - second: The second modifier.
    public init(first: First, second: Second) {
        self.first = first
        self.second = second
    }

    public func apply(to html: String) -> String {
        second.apply(to: first.apply(to: html))
    }
}

extension ViewModifier {
    /// Compose this modifier with another, applying both in sequence.
    /// - Parameter other: The modifier to apply after this one.
    /// - Returns: A composed modifier that applies both.
    public func andThen<Other: ViewModifier>(_ other: Other) -> ComposedModifier<Self, Other> {
        ComposedModifier(first: self, second: other)
    }
}

/// A modifier that does nothing — passes content through unchanged.
///
/// Used as a default or no-op in conditional modifier chains.
/// Applying this modifier is a no-op: the content is returned verbatim.
public struct NoopModifier: ViewModifier {
    public init() {}
    public func apply(to html: String) -> String { html }
}
