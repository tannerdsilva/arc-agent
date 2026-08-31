import Foundation

// MARK: - Horizontal Alignment

/// Horizontal alignment options for layout views.
public enum HorizontalAlignment: Sendable {
    /// Align children to the leading edge (left in LTR).
    case leading
    /// Align children to the center.
    case center
    /// Align children to the trailing edge (right in LTR).
    case trailing

    /// The CSS `align-items` value for this alignment.
    public var cssValue: String {
        switch self {
        case .leading:  return "flex-start"
        case .center:   return "center"
        case .trailing: return "flex-end"
        }
    }
}

// MARK: - Text

/// A view that displays inline text content.
///
/// Text content is automatically HTML-escaped to prevent XSS.
/// Use ``Raw`` to render unescaped HTML content.
///
/// ```swift
/// Text("Hello, world!")
///     .font(size: 16, weight: "600")
///     .foregroundColor("#e0e0e0")
/// ```
public struct Text: View {
    /// The text content.
    public let content: String

    /// Create a text view with the given content.
    /// - Parameter content: The text to display (will be HTML-escaped).
    public init(_ content: String) {
        self.content = content
    }

    public func render() -> String {
        htmlEscape(content)
    }
}

/// A view that renders raw HTML content without escaping.
///
/// Use sparingly — only when you have pre-rendered HTML that
/// you trust (e.g., the output of `markdownToHTML()`).
///
/// ```swift
/// Raw("<strong>Bold text</strong>")
/// ```
public struct Raw: View {
    /// The raw HTML content.
    public let content: String

    /// Create a raw HTML view.
    /// - Parameter content: The HTML to render verbatim (not escaped).
    public init(_ content: String) {
        self.content = content
    }

    public func render() -> String {
        content
    }
}

// MARK: - Div

/// A generic block-level container view.
///
/// Renders as a `<div>` element. Use for layout and grouping.
///
/// ```swift
/// Div(class: "container") {
///     Text("Hello")
///     Text("World")
/// }
/// ```
public struct Div: View {
    /// The HTML `id` attribute.
    public let id: String?
    /// The HTML `class` attribute.
    public let `class`: String?
    /// The child views.
    public let children: [any View]

    /// Create a div container.
    /// - Parameters:
    ///   - id: Optional HTML `id` attribute.
    ///   - class: Optional HTML `class` attribute.
    ///   - content: A view builder for the children.
    public init(
        id: String? = nil,
        class: String? = nil,
        @ViewBuilder content: () -> [any View]
    ) {
        self.id = id
        self.class = `class`
        self.children = content()
    }

    public func render() -> String {
        var html = "<div"
        if let id { html += " id=\"\(id)\"" }
        if let `class` { html += " class=\"\(`class`)\"" }
        html += ">"
        for child in children {
            html += child.render()
        }
        html += "</div>"
        return html
    }
}

// MARK: - Span

/// A generic inline container view.
///
/// Renders as a `<span>` element. Use for inline styling
/// and grouping within text content.
///
/// ```swift
/// Span(class: "highlight") {
///     Text("Important")
/// }
/// ```
public struct Span: View {
    /// The HTML `id` attribute.
    public let id: String?
    /// The HTML `class` attribute.
    public let `class`: String?
    /// The child views.
    public let children: [any View]

    /// Create a span container.
    /// - Parameters:
    ///   - id: Optional HTML `id` attribute.
    ///   - class: Optional HTML `class` attribute.
    ///   - content: A view builder for the children.
    public init(
        id: String? = nil,
        class: String? = nil,
        @ViewBuilder content: () -> [any View]
    ) {
        self.id = id
        self.class = `class`
        self.children = content()
    }

    public func render() -> String {
        var html = "<span"
        if let id { html += " id=\"\(id)\"" }
        if let `class` { html += " class=\"\(`class`)\"" }
        html += ">"
        for child in children {
            html += child.render()
        }
        html += "</span>"
        return html
    }
}

// MARK: - Button

/// A clickable button view.
///
/// Renders as a `<button>` element. Interactivity is handled
/// by the JavaScript runtime via the element's `id`.
///
/// ```swift
/// Button("Send", id: "send-button")
/// ```
public struct Button: View {
    /// The button label text.
    public let label: String
    /// The HTML `id` attribute.
    public let id: String?
    /// Additional CSS class names.
    public let `class`: String?

    /// Create a button.
    /// - Parameters:
    ///   - label: The button text.
    ///   - id: Optional HTML `id` attribute.
    ///   - class: Optional CSS class names.
    public init(_ label: String, id: String? = nil, class: String? = nil) {
        self.label = label
        self.id = id
        self.class = `class`
    }

    public func render() -> String {
        var html = "<button"
        if let id { html += " id=\"\(id)\"" }
        html += " class=\"\(`class` ?? "btn")\""
        html += ">\(htmlEscape(label))</button>"
        return html
    }
}

// MARK: - Input

/// A text input field view.
///
/// Renders as an `<input type="text">` element. The JavaScript
/// runtime captures keyboard events on this element.
///
/// ```swift
/// Input(id: "message-input", placeholder: "Type a message...")
/// ```
public struct Input: View {
    /// The HTML `id` attribute.
    public let id: String?
    /// The placeholder text.
    public let placeholder: String
    /// The input `type` attribute.
    public let type: String
    /// Additional HTML attributes as key-value pairs.
    public let attributes: [(String, String)]

    /// Create a text input.
    /// - Parameters:
    ///   - id: Optional HTML `id` attribute.
    ///   - placeholder: Placeholder text.
    ///   - type: Input type (default: `"text"`).
    ///   - attributes: Additional HTML attributes.
    public init(
        id: String? = nil,
        placeholder: String = "",
        type: String = "text",
        attributes: [(String, String)] = []
    ) {
        self.id = id
        self.placeholder = placeholder
        self.type = type
        self.attributes = attributes
    }

    public func render() -> String {
        var html = "<input"
        if let id { html += " id=\"\(id)\"" }
        html += " type=\"\(type)\""
        html += " placeholder=\"\(htmlEscape(placeholder))\""
        for (key, value) in attributes {
            html += " \(key)=\"\(htmlEscape(value))\""
        }
        html += ">"
        return html
    }
}

// MARK: - Image

/// An embedded image view.
///
/// Renders as an `<img>` element.
///
/// ```swift
/// Image(src: "/ui/logo.svg", alt: "ARC Agent Logo")
/// ```
public struct Image: View {
    /// The image source URL.
    public let src: String
    /// The alt text.
    public let alt: String
    /// Optional CSS class names.
    public let `class`: String?

    /// Create an image view.
    /// - Parameters:
    ///   - src: The image source URL or path.
    ///   - alt: Descriptive alt text.
    ///   - class: Optional CSS class names.
    public init(src: String, alt: String, class: String? = nil) {
        self.src = src
        self.alt = alt
        self.class = `class`
    }

    public func render() -> String {
        var html = "<img src=\"\(htmlEscape(src))\" alt=\"\(htmlEscape(alt))\""
        if let `class` { html += " class=\"\(`class`)\"" }
        html += ">"
        return html
    }
}

// MARK: - Link

/// A hyperlink view.
///
/// Renders as an `<a>` element.
///
/// ```swift
 /// Link("Click here", href: "/page")
/// ```
public struct Link: View {
    /// The link text.
    public let text: String
    /// The `href` attribute.
    public let href: String
    /// Optional CSS class names.
    public let `class`: String?

    /// Create a hyperlink.
    /// - Parameters:
    ///   - text: The visible link text.
    ///   - href: The URL or path the link points to.
    ///   - class: Optional CSS class names.
    public init(_ text: String, href: String, class: String? = nil) {
        self.text = text
        self.href = href
        self.class = `class`
    }

    public func render() -> String {
        var html = "<a href=\"\(htmlEscape(href))\""
        if let `class` { html += " class=\"\(`class`)\"" }
        html += ">\(htmlEscape(text))</a>"
        return html
    }
}
