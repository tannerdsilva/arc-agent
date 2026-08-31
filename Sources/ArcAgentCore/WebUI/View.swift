import Foundation

// MARK: - View Protocol

/// A view that renders to an HTML string.
///
/// Views are the building blocks of the ARC Agent web UI.
/// Each view produces an HTML string when rendered. Views are
/// value types — they are constructed, rendered, and discarded
/// within a single request. No mutable shared state.
///
/// `render()` is a pure function — the same view tree always
/// produces the same HTML string. No side effects, no context
/// parameter, no mutable state passed through the tree.
///
/// ## Concurrency
///
/// `View` conforms to `Sendable`. Views are value types with no
/// mutable state. The rendering pipeline is a pure function:
/// view tree → HTML string.
///
/// ## Usage
///
/// ```swift
/// struct Greeting: View {
///     let name: String
///     func render() -> String {
///         "<p>Hello, \(htmlEscape(name))!</p>"
///     }
/// }
/// ```
public protocol View: Sendable {
    /// Render this view to an HTML string.
    /// - Returns: The HTML representation of this view.
    func render() -> String
}

// MARK: - ViewModifier Protocol

/// A modifier that wraps rendered content with additional
/// HTML attributes or inline styles.
///
/// Modifiers are applied via methods on ``View``:
///
/// ```swift
/// Text("Hello")
///     .font(size: 16, weight: "600")
///     .foregroundColor("#e0e0e0")
/// ```
///
/// Each modifier returns a ``ModifiedView`` that preserves
/// the concrete type of the wrapped view through the chain.
///
/// ## Concurrency
///
/// `ViewModifier` conforms to `Sendable`. Modifiers are value
/// types with no mutable state.
public protocol ViewModifier: Sendable {
    /// Apply this modifier to rendered HTML content.
    /// - Parameter html: The rendered HTML of the wrapped view.
    /// - Returns: The modified HTML string.
    func apply(to html: String) -> String
}
