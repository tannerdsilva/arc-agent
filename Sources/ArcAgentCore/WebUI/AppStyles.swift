import Foundation

// MARK: - AppStyles

/// The ARC Agent design system.
///
/// All CSS rules are defined here as static `let` constants.
/// Views reference class names from this enum. No CSS is
/// defined or accumulated anywhere else.
///
/// This is an enum with no cases — it cannot be instantiated.
/// It exists purely as a namespace for static CSS data.
///
/// ## Usage
///
/// To generate the complete stylesheet:
///
/// ```swift
/// let stylesheet = CSSStylesheet(AppStyles.all)
/// let css = stylesheet.render()
/// ```
public enum AppStyles {

    // ── Theme (CSS Custom Properties) ──────────────────────────

    /// CSS custom properties for the dark theme.
    ///
    /// All colors, fonts, and spacing values are defined as
    /// CSS variables on `:root`. Theme switching is a matter
    /// of swapping the `:root` variable definitions.
    public static let theme = CSSRule(":root", [
        ("--bg-primary", "#0d1117"),
        ("--bg-secondary", "#161b22"),
        ("--bg-tertiary", "#21262d"),
        ("--bg-hover", "#30363d"),
        ("--text-primary", "#e6edf3"),
        ("--text-secondary", "#8b949e"),
        ("--text-muted", "#6e7681"),
        ("--accent", "#58a6ff"),
        ("--accent-hover", "#79c0ff"),
        ("--accent-muted", "rgba(88, 166, 255, 0.15)"),
        ("--border", "#30363d"),
        ("--border-hover", "#484f58"),
        ("--success", "#3fb950"),
        ("--warning", "#d29922"),
        ("--danger", "#f85149"),
        ("--danger-muted", "rgba(248, 81, 73, 0.15)"),
        ("--font-mono", "'SF Mono', 'Fira Code', 'Cascadia Code', monospace"),
        ("--font-sans", "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"),
        ("--radius-sm", "6px"),
        ("--radius-md", "8px"),
        ("--radius-lg", "12px"),
        ("--radius-xl", "16px"),
        ("--shadow-sm", "0 1px 2px rgba(0, 0, 0, 0.3)"),
        ("--shadow-md", "0 4px 12px rgba(0, 0, 0, 0.4)"),
        ("--transition-fast", "150ms ease"),
        ("--transition-normal", "250ms ease"),
    ])

    // ── Base Reset ─────────────────────────────────────────────

    /// Universal box-sizing reset.
    public static let reset = CSSRule("*", [
        ("margin", "0"),
        ("padding", "0"),
        ("box-sizing", "border-box"),
    ])

    /// Base body styling.
    public static let body = CSSRule("body", [
        ("font-family", "var(--font-sans)"),
        ("background-color", "var(--bg-primary)"),
        ("color", "var(--text-primary)"),
        ("line-height", "1.6"),
        ("-webkit-font-smoothing", "antialiased"),
        ("overflow", "hidden"),
        ("height", "100vh"),
    ])

    /// HTML and body full-height setup.
    public static let html = CSSRule("html", [
        ("height", "100vh"),
    ])

    // ── Layout ─────────────────────────────────────────────────

    /// Vertical flexbox container.
    public static let vstack = CSSRule(".vstack", [
        ("display", "flex"),
        ("flex-direction", "column"),
    ])

    /// Horizontal flexbox container.
    public static let hstack = CSSRule(".hstack", [
        ("display", "flex"),
        ("flex-direction", "row"),
    ])

    /// Scrollable container.
    public static let scrollview = CSSRule(".scrollview", [
        ("overflow-y", "auto"),
        ("flex", "1"),
    ])

    /// Flexible spacer.
    public static let spacer = CSSRule(".spacer", [
        ("flex", "1"),
    ])

    // ── Header ─────────────────────────────────────────────────

    /// The top header bar.
    public static let header = CSSRule(".header", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "space-between"),
        ("padding", "12px 20px"),
        ("border-bottom", "1px solid var(--border)"),
        ("background-color", "var(--bg-secondary)"),
        ("flex-shrink", "0"),
    ])

    /// Header title text.
    public static let headerTitle = CSSRule(".header h1", [
        ("font-size", "18px"),
        ("font-weight", "600"),
        ("color", "var(--text-primary)"),
    ])

    // ── Chat ───────────────────────────────────────────────────

    /// The message list container.
    public static let messageList = CSSRule(".message-list", [
        ("display", "flex"),
        ("flex-direction", "column"),
        ("gap", "8px"),
        ("padding", "16px 20px"),
        ("overflow-y", "auto"),
        ("flex", "1"),
    ])

    /// A single message bubble.
    public static let messageBubble = CSSRule(".message-bubble", [
        ("max-width", "80%"),
        ("padding", "10px 16px"),
        ("border-radius", "var(--radius-lg)"),
        ("font-size", "14px"),
        ("line-height", "1.6"),
        ("word-wrap", "break-word"),
        ("white-space", "pre-wrap"),
        ("animation", "fadeIn var(--transition-normal)"),
    ])

    /// User message bubble (right-aligned, accent background).
    public static let userMessage = CSSRule(".message-bubble.user", [
        ("align-self", "flex-end"),
        ("background-color", "var(--accent)"),
        ("color", "#ffffff"),
        ("border-bottom-right-radius", "var(--radius-sm)"),
    ])

    /// Assistant message bubble (left-aligned, tertiary background).
    public static let assistantMessage = CSSRule(".message-bubble.assistant", [
        ("align-self", "flex-start"),
        ("background-color", "var(--bg-tertiary)"),
        ("border-bottom-left-radius", "var(--radius-sm)"),
    ])

    /// Streaming message indicator.
    public static let streaming = CSSRule(".message-bubble.streaming", [
        ("border-left", "3px solid var(--accent)"),
    ])

    /// Fade-in animation for new messages.
    public static let fadeIn = CSSRule("@keyframes fadeIn", [
        ("from", "opacity: 0; transform: translateY(4px)"),
        ("to", "opacity: 1; transform: translateY(0)"),
    ])

    // ── Input Bar ──────────────────────────────────────────────

    /// The input bar at the bottom of the chat.
    public static let inputBar = CSSRule(".input-bar", [
        ("display", "flex"),
        ("gap", "8px"),
        ("padding", "12px 20px"),
        ("border-top", "1px solid var(--border)"),
        ("background-color", "var(--bg-secondary)"),
        ("flex-shrink", "0"),
    ])

    /// The text input field.
    public static let inputField = CSSRule(".input-field", [
        ("flex", "1"),
        ("padding", "10px 14px"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "var(--bg-primary)"),
        ("color", "var(--text-primary)"),
        ("font-size", "14px"),
        ("font-family", "var(--font-sans)"),
        ("outline", "none"),
        ("transition", "border-color var(--transition-fast)"),
    ])

    /// Input field focus state.
    public static let inputFieldFocus = CSSRule(".input-field:focus", [
        ("border-color", "var(--accent)"),
        ("box-shadow", "0 0 0 3px var(--accent-muted)"),
    ])

    /// The send button.
    public static let sendButton = CSSRule(".send-btn", [
        ("padding", "10px 20px"),
        ("border", "none"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "var(--accent)"),
        ("color", "#ffffff"),
        ("font-size", "14px"),
        ("font-weight", "500"),
        ("font-family", "var(--font-sans)"),
        ("cursor", "pointer"),
        ("transition", "background-color var(--transition-fast)"),
        ("white-space", "nowrap"),
    ])

    /// Send button hover state.
    public static let sendButtonHover = CSSRule(".send-btn:hover", [
        ("background-color", "var(--accent-hover)"),
    ])

    /// Send button disabled state.
    public static let sendButtonDisabled = CSSRule(".send-btn:disabled", [
        ("opacity", "0.5"),
        ("cursor", "not-allowed"),
    ])

    // ── Connection Status ──────────────────────────────────────

    /// Connection status indicator.
    public static let connectionStatus = CSSRule("#conn", [
        ("font-size", "12px"),
        ("padding", "4px 10px"),
        ("border-radius", "var(--radius-sm)"),
        ("font-weight", "500"),
        ("transition", "all var(--transition-fast)"),
    ])

    /// Connected state (green).
    public static let connected = CSSRule("#conn.on", [
        ("background-color", "rgba(63, 185, 80, 0.15)"),
        ("color", "var(--success)"),
    ])

    /// Disconnected state (red).
    public static let disconnected = CSSRule("#conn.off", [
        ("background-color", "var(--danger-muted)"),
        ("color", "var(--danger)"),
    ])

    // ── Markdown ───────────────────────────────────────────────

    /// Markdown rendered content.
    public static let markdown = CSSRule(".markdown", [
        ("font-size", "14px"),
        ("line-height", "1.7"),
    ])

    /// Inline code within markdown.
    public static let markdownCode = CSSRule(".markdown code", [
        ("font-family", "var(--font-mono)"),
        ("font-size", "13px"),
        ("padding", "2px 6px"),
        ("border-radius", "var(--radius-sm)"),
        ("background-color", "rgba(255, 255, 255, 0.08)"),
    ])

    /// Code block within markdown.
    public static let markdownPre = CSSRule(".markdown pre", [
        ("padding", "12px 16px"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "rgba(0, 0, 0, 0.3)"),
        ("overflow-x", "auto"),
        ("margin", "8px 0"),
        ("border", "1px solid var(--border)"),
    ])

    /// Code block inner code element.
    public static let markdownPreCode = CSSRule(".markdown pre code", [
        ("background", "none"),
        ("padding", "0"),
        ("font-size", "13px"),
        ("line-height", "1.5"),
    ])

    /// Paragraph within markdown.
    public static let markdownParagraph = CSSRule(".markdown p", [
        ("margin", "4px 0"),
    ])

    /// List within markdown.
    public static let markdownList = CSSRule(".markdown ul, .markdown ol", [
        ("margin", "4px 0"),
        ("padding-left", "20px"),
    ])

    /// Blockquote within markdown.
    public static let markdownBlockquote = CSSRule(".markdown blockquote", [
        ("margin", "4px 0"),
        ("padding-left", "12px"),
        ("border-left", "3px solid var(--border)"),
        ("color", "var(--text-secondary)"),
    ])

    /// Heading within markdown.
    public static let markdownHeading = CSSRule(".markdown h1, .markdown h2, .markdown h3, .markdown h4", [
        ("margin", "8px 0 4px"),
        ("font-weight", "600"),
    ])

    /// Link within markdown.
    public static let markdownLink = CSSRule(".markdown a", [
        ("color", "var(--accent)"),
        ("text-decoration", "none"),
    ])

    /// Link hover within markdown.
    public static let markdownLinkHover = CSSRule(".markdown a:hover", [
        ("text-decoration", "underline"),
    ])

    // ── Syntax Highlighting ────────────────────────────────────

    /// Keyword token in highlighted code.
    public static let tokenKeyword = CSSRule(".token.keyword", [
        ("color", "#ff7b72"),
    ])

    /// String token in highlighted code.
    public static let tokenString = CSSRule(".token.string", [
        ("color", "#a5d6ff"),
    ])

    /// Comment token in highlighted code.
    public static let tokenComment = CSSRule(".token.comment", [
        ("color", "#8b949e"),
        ("font-style", "italic"),
    ])

    /// Type token in highlighted code.
    public static let tokenType = CSSRule(".token.type", [
        ("color", "#ffa657"),
    ])

    /// Number token in highlighted code.
    public static let tokenNumber = CSSRule(".token.number", [
        ("color", "#79c0ff"),
    ])

    // ── Scrollbar ──────────────────────────────────────────────

    /// Custom scrollbar styling.
    public static let scrollbar = CSSRule("::-webkit-scrollbar", [
        ("width", "8px"),
        ("height", "8px"),
    ])

    /// Scrollbar track.
    public static let scrollbarTrack = CSSRule("::-webkit-scrollbar-track", [
        ("background", "transparent"),
    ])

    /// Scrollbar thumb.
    public static let scrollbarThumb = CSSRule("::-webkit-scrollbar-thumb", [
        ("background", "var(--bg-hover)"),
        ("border-radius", "4px"),
    ])

    /// Scrollbar thumb hover.
    public static let scrollbarThumbHover = CSSRule("::-webkit-scrollbar-thumb:hover", [
        ("background", "var(--border-hover)"),
    ])

    // ── All Styles ─────────────────────────────────────────────

    /// All CSS rules in the design system, in order.
    ///
    /// Rules are ordered so that more general rules come first
    /// and more specific rules override them naturally.
    public static let all: [CSSRule] = [
        // Theme
        theme,

        // Base
        reset, html, body,

        // Layout
        vstack, hstack, scrollview, spacer,

        // Header
        header, headerTitle,

        // Chat
        messageList, messageBubble, userMessage, assistantMessage, streaming,
        fadeIn,

        // Input Bar
        inputBar, inputField, inputFieldFocus,
        sendButton, sendButtonHover, sendButtonDisabled,

        // Connection Status
        connectionStatus, connected, disconnected,

        // Markdown
        markdown, markdownCode, markdownPre, markdownPreCode,
        markdownParagraph, markdownList, markdownBlockquote,
        markdownHeading, markdownLink, markdownLinkHover,

        // Syntax Highlighting
        tokenKeyword, tokenString, tokenComment, tokenType, tokenNumber,

        // Scrollbar
        scrollbar, scrollbarTrack, scrollbarThumb, scrollbarThumbHover,
    ]
}
