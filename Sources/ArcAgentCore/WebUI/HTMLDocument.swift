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
/// assembles them into a complete `<!DOCTYPE html>` document.
///
/// In **production mode** (default), CSS and JS are inlined via
/// `<style>` and `<script>` tags — everything is self-contained.
///
/// In **dev mode** (`devMode: true`), CSS and JS are linked as
/// external resources (`/ui/styles.css`, `/ui/scripts.js`) so the
/// browser fetches them from the server on every request. This
/// enables live-reload iteration without recompiling the binary.
public struct HTMLDocument: Sendable {
    /// The page title (used in `<title>`).
    public let title: String
    /// The rendered HTML body content.
    public let body: String
    /// The CSS stylesheet to inline (production) or ignore (dev).
    public let styles: CSSStylesheet
    /// The JavaScript to inline (production) or ignore (dev).
    public let scripts: String
    /// WebSocket URL for real-time communication.
    public let wsURL: String
    /// Optional settings panel HTML.
    public let settingsHTML: String
    /// When true, link CSS/JS as external resources instead of inlining.
    /// Set automatically by the HTTP server in debug builds.
    public let devMode: Bool

    /// Create a complete HTML document.
    /// - Parameters:
    ///   - title: The page title.
    ///   - body: The rendered HTML body.
    ///   - styles: The CSS stylesheet (defaults to ``AppStyles/all``).
    ///   - scripts: The JavaScript (defaults to ``Scripts/runtime``).
    ///   - wsURL: WebSocket URL (defaults to `ws://127.0.0.1:8081`).
    ///   - settingsHTML: Optional settings panel HTML.
    ///   - devMode: When true, link external assets instead of inlining.
    public init(
        title: String = "ARC Agent",
        body: String,
        styles: CSSStylesheet = CSSStylesheet(AppStyles.all),
        scripts: String = Scripts.runtime,
        wsURL: String = "ws://127.0.0.1:8081",
        settingsHTML: String = "",
        devMode: Bool = false
    ) {
        self.title = title
        self.body = body
        self.styles = styles
        self.scripts = scripts
        self.wsURL = wsURL
        self.settingsHTML = settingsHTML
        self.devMode = devMode
    }

    /// Render the complete HTML document.
    ///
    /// Produces a `<!DOCTYPE html>` document with:
    /// - Inline `<style>` containing all CSS rules (production)
    ///   or `<link>` to `/ui/styles.css` (dev)
    /// - Inline `<script>` containing the JS runtime (production)
    ///   or `<script src="/ui/scripts.js">` (dev)
    /// - Responsive viewport meta tag
    /// - UTF-8 charset declaration
    ///
    /// - Returns: A complete HTML document string.
    public func render() -> String {
        let styleTag: String
        let scriptTag: String
        if devMode {
            styleTag = "<link rel=\"stylesheet\" href=\"/ui/styles.css\">"
            scriptTag = "<script src=\"/ui/scripts.js\"></script>"
        } else {
            styleTag = "<style>\n\(styles.render())\n</style>"
            scriptTag = "<script>\n\(scripts)\n</script>"
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <meta name="theme-color" content="#0c0c0e">
          <title>\(htmlEscape(title))</title>
          \(styleTag)
        </head>
        <body>
          <div id="app" data-ws-url="\(wsURL)">
            \(body)
            \(settingsHTML)
          </div>
          \(scriptTag)
        </body>
        </html>
        """
    }
}
