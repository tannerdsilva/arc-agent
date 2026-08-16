import Foundation

// MARK: - CSSRule

/// A single CSS rule consisting of a selector and declarations.
///
/// ```swift
/// let rule = CSSRule(".message-bubble", [
///     ("border-radius", "12px"),
///     ("padding", "12px 16px"),
/// ])
/// ```
public struct CSSRule: Sendable {
    /// The CSS selector (e.g. `".message-bubble"`, `"#messages"`).
    public let selector: String
    /// The CSS declarations as property-value pairs.
    public let declarations: [(String, String)]

    /// Create a CSS rule.
    /// - Parameters:
    ///   - selector: The CSS selector.
    ///   - declarations: An array of (property, value) pairs.
    public init(_ selector: String, _ declarations: [(String, String)]) {
        self.selector = selector
        self.declarations = declarations
    }
}

// MARK: - CSSStylesheet

/// A complete CSS stylesheet consisting of multiple rules.
///
/// ```swift
/// let stylesheet = CSSStylesheet([
///     CSSRule("body", [("color", "#e6edf3")]),
///     CSSRule(".btn", [("cursor", "pointer")]),
/// ])
/// ```
public struct CSSStylesheet: Sendable {
    /// The CSS rules in this stylesheet.
    public let rules: [CSSRule]

    /// Create a stylesheet from an array of rules.
    /// - Parameter rules: The CSS rules to include.
    public init(_ rules: [CSSRule]) {
        self.rules = rules
    }

    /// Render the stylesheet to a CSS string.
    ///
    /// Each rule is rendered as:
    /// ```
    /// selector {
    ///   property: value;
    /// }
    /// ```
    /// - Returns: A complete CSS string.
    public func render() -> String {
        rules.map { rule in
            let declarations = rule.declarations.map { "  \($0.0): \($0.1);" }.joined(separator: "\n")
            return "\(rule.selector) {\n\(declarations)\n}"
        }.joined(separator: "\n\n")
    }
}
