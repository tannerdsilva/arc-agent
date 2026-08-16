import Foundation

// MARK: - HTML Escaping

/// Escape a string for safe inclusion in HTML content.
///
/// Replaces the five characters that have special meaning in HTML:
/// - `&` → `&amp;`
/// - `<` → `&lt;`
/// - `>` → `&gt;`
/// - `"` → `&quot;`
/// - `'` → `&#39;`
///
/// - Parameter string: The raw string to escape.
/// - Returns: An HTML-safe string.
public func htmlEscape(_ string: String) -> String {
    var result = string
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    result = result.replacingOccurrences(of: "'", with: "&#39;")
    return result
}

// MARK: - Markdown Rendering (Stub)

/// Render markdown text to HTML on the server side.
///
/// This is a pure Swift function — no JS markdown library,
/// no client-side processing. Code blocks are pre-highlighted
/// using ``highlightCode(code:language:)``.
///
/// ## Supported Syntax
///
/// - Headings (`#` through `######`)
/// - Bold (`**text**`) and italic (`*text*`)
/// - Inline code (`` `code` ``)
/// - Code blocks (```` ```language ... ``` ````)
/// - Links (`[text](url)`)
/// - Unordered lists (`- item`)
/// - Ordered lists (`1. item`)
/// - Blockquotes (`> text`)
/// - Horizontal rules (`---`)
///
/// - Parameter markdown: The markdown text to render.
/// - Returns: HTML string with syntax-highlighted code blocks.
///
/// > Phase W4: This is a stub that returns the input wrapped in
/// > `<p>` tags. The full implementation will use Swift Regex
/// > for parsing.
public func markdownToHTML(_ markdown: String) -> String {
    // Phase W4 implementation placeholder
    // Returns the input as a simple paragraph for now
    "<p>\(htmlEscape(markdown))</p>"
}

// MARK: - Syntax Highlighting (Stub)

/// Syntax-highlight code on the server side.
///
/// Produces `<span>` elements with class names for keywords,
/// strings, comments, types, and numbers. The CSS design system
/// (``AppStyles``) defines the colors for each token class.
///
/// ## Supported Languages
///
/// - Swift
/// - Python
/// - Rust
/// - JavaScript / TypeScript
/// - Go
/// - Ruby
/// - Shell / Bash
///
/// - Parameters:
///   - code: The source code to highlight.
///   - language: The programming language identifier.
/// - Returns: HTML string with `<span class="token ...">` elements.
///
/// > Phase W4: This is a stub that returns the code HTML-escaped
/// > without highlighting. The full implementation will use Swift
/// > Regex for tokenization.
public func highlightCode(_ code: String, language: String) -> String {
    // Phase W4 implementation placeholder
    // Returns the code HTML-escaped without highlighting for now
    htmlEscape(code)
}
