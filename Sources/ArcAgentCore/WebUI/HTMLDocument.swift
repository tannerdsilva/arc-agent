import Foundation

// MARK: - HTMLDocument

/// A complete HTML document.
///
/// Assembled from four independent parts:
/// - `body`: the rendered view tree HTML
/// - `styles`: static CSS from the design system
/// - `scripts`: static JS from ``Scripts``
/// - `settings`: optional settings panel
///
/// Each part is produced independently. The ``render()`` method
/// assembles them into a complete `<!DOCTYPE html>` document
/// with inline `<style>` and `<script>` tags.
public struct HTMLDocument: Sendable {
    /// The page title (used in `<title>`).
    public let title: String
    /// The rendered HTML body content.
    public let body: String
    /// The CSS stylesheet to inline.
    public let styles: CSSStylesheet
    /// The JavaScript to inline.
    public let scripts: String
    /// WebSocket URL for real-time communication.
    public let wsURL: String
    /// Optional settings panel HTML.
    public let settingsHTML: String

    /// Create a complete HTML document.
    /// - Parameters:
    ///   - title: The page title.
    ///   - body: The rendered HTML body.
    ///   - styles: The CSS stylesheet (defaults to ``AppStyles/all``).
    ///   - scripts: The JavaScript (defaults to ``Scripts/runtime``).
    ///   - wsURL: WebSocket URL (defaults to `ws://127.0.0.1:8081`).
    ///   - settingsHTML: Optional settings panel HTML.
    public init(
        title: String = "ARC Agent",
        body: String,
        styles: CSSStylesheet = CSSStylesheet(AppStyles.all),
        scripts: String = Scripts.runtime,
        wsURL: String = "ws://127.0.0.1:8081",
        settingsHTML: String = ""
    ) {
        self.title = title
        self.body = body
        self.styles = styles
        self.scripts = scripts
        self.wsURL = wsURL
        self.settingsHTML = settingsHTML
    }

    /// Render the complete HTML document.
    ///
    /// Produces a `<!DOCTYPE html>` document with:
    /// - Inline `<style>` containing all CSS rules
    /// - Inline `<script>` containing the JS runtime
    /// - Responsive viewport meta tag
    /// - UTF-8 charset declaration
    ///
    /// - Returns: A complete HTML document string.
    public func render() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <meta name="theme-color" content="#0c0c0e">
          <title>\(htmlEscape(title))</title>
          <style>
        \(styles.render())
          </style>
        </head>
        <body>
          <div id="app" data-ws-url="\(wsURL)">
            \(body)
            \(settingsHTML)
          </div>
          <script>
        \(scripts)
          </script>
        </body>
        </html>
        """
    }
}
