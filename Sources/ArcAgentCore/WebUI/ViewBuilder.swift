import Foundation

// MARK: - ViewBuilder

/// A result builder that composes views into an array.
///
/// This is the mechanism that enables SwiftUI-style syntax:
///
/// ```swift
/// Div {
///     Text("Hello")
///     Text("World")
/// }
/// ```
///
/// The result builder is resolved entirely at compile time.
/// The compiler generates the array construction — no runtime
/// reflection, no dynamic dispatch in the builder itself.
///
/// ## Supported Build Methods
///
/// - ``buildBlock(_:)`` — standard block of views
/// - ``buildExpression(_:)`` — single view expression
/// - ``buildOptional(_:)`` — `if` without `else`
/// - ``buildEither(first:)`` / ``buildEither(second:)`` — `if`/`else`
/// - ``buildArray(_:)`` — `for` loops over collections of views
/// - ``buildLimitedAvailability(_:)`` — `#available` blocks
@resultBuilder
public enum ViewBuilder {

    /// Build a block of view components.
    /// - Parameter components: The view components in the block.
    /// - Returns: A flattened array of views.
    public static func buildBlock(_ components: [any View]...) -> [any View] {
        components.flatMap { $0 }
    }

    /// Build a single view expression.
    /// - Parameter expression: A single view.
    /// - Returns: An array containing the view.
    public static func buildExpression(_ expression: any View) -> [any View] {
        [expression]
    }

    /// Build an optional view block.
    /// - Parameter component: The optional view array.
    /// - Returns: The view array, or an empty array if `nil`.
    public static func buildOptional(_ component: [any View]?) -> [any View] {
        component ?? []
    }

    /// Build the first branch of a conditional.
    /// - Parameter first: The view array for the `true` branch.
    /// - Returns: The view array unchanged.
    public static func buildEither(first: [any View]) -> [any View] {
        first
    }

    /// Build the second branch of a conditional.
    /// - Parameter second: The view array for the `false` branch.
    /// - Returns: The view array unchanged.
    public static func buildEither(second: [any View]) -> [any View] {
        second
    }

    /// Build an array of views from a loop.
    /// - Parameter components: The arrays of views from each iteration.
    /// - Returns: A flattened array of all views.
    public static func buildArray(_ components: [[any View]]) -> [any View] {
        components.flatMap { $0 }
    }

    /// Build a limited-availability block.
    /// - Parameter component: The view array for the available branch.
    /// - Returns: The view array unchanged.
    public static func buildLimitedAvailability(_ component: [any View]) -> [any View] {
        component
    }
}
