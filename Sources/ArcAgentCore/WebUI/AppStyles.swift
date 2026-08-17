import Foundation

// MARK: - AppStyles

/// The ARC Agent design system — clean, modern, dark-first.
///
/// All CSS rules are defined here as static `let` constants.
/// Views reference class names from this enum. No CSS is
/// defined or accumulated anywhere else.
public enum AppStyles {

    // ── Theme (CSS Custom Properties) ──────────────────────────

    /// CSS custom properties for the dark theme.
    public static let theme = CSSRule(":root", [
        // Backgrounds
        ("--bg-primary", "#0c0c0e"),
        ("--bg-secondary", "#151517"),
        ("--bg-tertiary", "#1c1c1f"),
        ("--bg-hover", "#252528"),
        ("--bg-elevated", "#1e1e22"),

        // Text
        ("--text-primary", "#e8e8ed"),
        ("--text-secondary", "#9898a0"),
        ("--text-muted", "#6c6c74"),
        ("--text-inverse", "#0c0c0e"),

        // Accent
        ("--accent", "#6c8cff"),
        ("--accent-hover", "#8ba3ff"),
        ("--accent-muted", "rgba(108, 140, 255, 0.12)"),
        ("--accent-subtle", "rgba(108, 140, 255, 0.06)"),

        // Semantic
        ("--success", "#4cd964"),
        ("--warning", "#ffd60a"),
        ("--danger", "#ff453a"),
        ("--danger-muted", "rgba(255, 69, 58, 0.12)"),

        // Borders
        ("--border", "#2c2c30"),
        ("--border-hover", "#3a3a40"),

        // Typography
        ("--font-sans", "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Helvetica Neue', sans-serif"),
        ("--font-mono", "'SF Mono', 'SFMono-Regular', 'JetBrains Mono', 'Fira Code', monospace"),

        // Radii
        ("--radius-sm", "6px"),
        ("--radius-md", "8px"),
        ("--radius-lg", "12px"),
        ("--radius-xl", "16px"),
        ("--radius-full", "9999px"),

        // Shadows
        ("--shadow-sm", "0 1px 2px rgba(0,0,0,0.3)"),
        ("--shadow-md", "0 4px 12px rgba(0,0,0,0.4)"),
        ("--shadow-lg", "0 8px 30px rgba(0,0,0,0.5)"),

        // Transitions
        ("--transition-fast", "150ms cubic-bezier(0.4, 0, 0.2, 1)"),
        ("--transition-normal", "250ms cubic-bezier(0.4, 0, 0.2, 1)"),
        ("--transition-slow", "400ms cubic-bezier(0.4, 0, 0.2, 1)"),

        // Layout
        ("--header-height", "48px"),
        ("--input-bar-height", "auto"),
        ("--sidebar-width", "260px"),
        ("--max-chat-width", "800px"),
    ])

    // ── Base Reset ─────────────────────────────────────────────

    public static let reset = CSSRule("*, *::before, *::after", [
        ("margin", "0"),
        ("padding", "0"),
        ("box-sizing", "border-box"),
    ])

    public static let html = CSSRule("html", [
        ("height", "100%"),
        ("-webkit-font-smoothing", "antialiased"),
        ("-moz-osx-font-smoothing", "grayscale"),
    ])

    public static let body = CSSRule("body", [
        ("font-family", "var(--font-sans)"),
        ("background-color", "var(--bg-primary)"),
        ("color", "var(--text-primary)"),
        ("line-height", "1.6"),
        ("overflow", "hidden"),
        ("height", "100%"),
    ])

    // ── App Layout ─────────────────────────────────────────────

    public static let appLayout = CSSRule(".app-layout", [
        ("display", "flex"),
        ("flex-direction", "column"),
        ("height", "100vh"),
        ("max-width", "var(--max-chat-width)"),
        ("margin", "0 auto"),
        ("position", "relative"),
    ])

    // ── Header ─────────────────────────────────────────────────

    public static let chatHeader = CSSRule(".chat-header", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "space-between"),
        ("height", "var(--header-height)"),
        ("padding", "0 16px"),
        ("border-bottom", "1px solid var(--border)"),
        ("background-color", "var(--bg-secondary)"),
        ("flex-shrink", "0"),
        ("-webkit-app-region", "drag"),
        ("z-index", "10"),
    ])

    public static let headerLeft = CSSRule(".header-left", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "8px"),
        ("-webkit-app-region", "no-drag"),
    ])

    public static let headerLogo = CSSRule(".header-logo", [
        ("font-size", "18px"),
        ("line-height", "1"),
    ])

    public static let headerTitle = CSSRule(".header-title", [
        ("font-size", "13px"),
        ("font-weight", "600"),
        ("color", "var(--text-primary)"),
        ("letter-spacing", "-0.01em"),
    ])

    public static let headerCenter = CSSRule(".header-center", [
        ("display", "flex"),
        ("align-items", "center"),
        ("-webkit-app-region", "no-drag"),
    ])

    public static let headerRight = CSSRule(".header-right", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "8px"),
        ("-webkit-app-region", "no-drag"),
    ])

    // ── Model Select ───────────────────────────────────────────

    public static let modelSelect = CSSRule(".model-select", [
        ("appearance", "none"),
        ("-webkit-appearance", "none"),
        ("background", "var(--bg-tertiary)"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-sm)"),
        ("color", "var(--text-secondary)"),
        ("font-size", "11px"),
        ("font-family", "var(--font-mono)"),
        ("padding", "3px 20px 3px 8px"),
        ("cursor", "pointer"),
        ("outline", "none"),
        ("transition", "border-color var(--transition-fast)"),
        ("background-image", "url(\"data:image/svg+xml,%3Csvg width='8' height='6' viewBox='0 0 8 6' fill='none' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath d='M1 1.5L4 4.5L7 1.5' stroke='%239898a0' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E\")"),
        ("background-repeat", "no-repeat"),
        ("background-position", "right 6px center"),
        ("background-size", "8px 6px"),
    ])

    public static let modelSelectFocus = CSSRule(".model-select:focus", [
        ("border-color", "var(--accent)"),
    ])

    // ── Status Badge ───────────────────────────────────────────

    public static let statusBadge = CSSRule(".status-badge", [
        ("font-size", "11px"),
        ("padding", "2px 8px"),
        ("border-radius", "var(--radius-full)"),
        ("font-weight", "500"),
        ("transition", "all var(--transition-fast)"),
    ])

    public static let statusBadgeOn = CSSRule(".status-badge.on", [
        ("background-color", "rgba(76, 217, 100, 0.1)"),
        ("color", "var(--success)"),
    ])

    public static let statusBadgeOff = CSSRule(".status-badge.off", [
        ("background-color", "var(--danger-muted)"),
        ("color", "var(--danger)"),
    ])

    // ── Navigation Tabs ────────────────────────────────────────

    public static let headerNav = CSSRule(".header-nav", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "2px"),
        ("-webkit-app-region", "no-drag"),
    ])

    public static let navTab = CSSRule(".nav-tab", [
        ("padding", "4px 12px"),
        ("border-radius", "var(--radius-sm)"),
        ("font-size", "12px"),
        ("font-weight", "500"),
        ("color", "var(--text-muted)"),
        ("text-decoration", "none"),
        ("transition", "all var(--transition-fast)"),
        ("cursor", "pointer"),
    ])

    public static let navTabHover = CSSRule(".nav-tab:hover", [
        ("color", "var(--text-secondary)"),
        ("background-color", "var(--bg-hover)"),
    ])

    public static let navTabActive = CSSRule(".nav-tab.active", [
        ("color", "var(--text-primary)"),
        ("background-color", "var(--bg-tertiary)"),
    ])

    // ── Header Button ──────────────────────────────────────────

    public static let headerBtn = CSSRule(".header-btn", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("width", "28px"),
        ("height", "28px"),
        ("border", "none"),
        ("border-radius", "var(--radius-sm)"),
        ("background", "transparent"),
        ("color", "var(--text-muted)"),
        ("cursor", "pointer"),
        ("transition", "all var(--transition-fast)"),
    ])

    public static let headerBtnHover = CSSRule(".header-btn:hover", [
        ("background-color", "var(--bg-hover)"),
        ("color", "var(--text-primary)"),
    ])

    // ── Messages Container ─────────────────────────────────────

    public static let messagesContainer = CSSRule(".messages-container", [
        ("flex", "1"),
        ("display", "flex"),
        ("flex-direction", "column"),
        ("overflow", "hidden"),
        ("position", "relative"),
    ])

    public static let messagesScroll = CSSRule(".messages-scroll", [
        ("flex", "1"),
        ("overflow-y", "auto"),
        ("padding", "16px 16px 0"),
        ("scroll-behavior", "smooth"),
    ])

    // ── Welcome Screen ─────────────────────────────────────────

    public static let welcomeScreen = CSSRule(".welcome-screen", [
        ("display", "flex"),
        ("flex-direction", "column"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("height", "100%"),
        ("text-align", "center"),
        ("padding", "40px 20px"),
        ("animation", "fadeInUp var(--transition-slow)"),
    ])

    public static let welcomeIcon = CSSRule(".welcome-icon", [
        ("font-size", "48px"),
        ("margin-bottom", "16px"),
        ("opacity", "0.6"),
    ])

    public static let welcomeTitle = CSSRule(".welcome-title", [
        ("font-size", "24px"),
        ("font-weight", "700"),
        ("color", "var(--text-primary)"),
        ("margin-bottom", "8px"),
        ("letter-spacing", "-0.03em"),
    ])

    public static let welcomeSubtitle = CSSRule(".welcome-subtitle", [
        ("font-size", "15px"),
        ("color", "var(--text-secondary)"),
        ("margin-bottom", "32px"),
    ])

    public static let welcomeSuggestions = CSSRule(".welcome-suggestions", [
        ("display", "flex"),
        ("flex-wrap", "wrap"),
        ("gap", "8px"),
        ("justify-content", "center"),
        ("max-width", "480px"),
    ])

    public static let suggestionChip = CSSRule(".suggestion-chip", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "6px"),
        ("padding", "8px 14px"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-full)"),
        ("background", "var(--bg-tertiary)"),
        ("font-size", "13px"),
        ("color", "var(--text-secondary)"),
        ("cursor", "pointer"),
        ("transition", "all var(--transition-fast)"),
        ("user-select", "none"),
    ])

    public static let suggestionChipHover = CSSRule(".suggestion-chip:hover", [
        ("border-color", "var(--accent)"),
        ("background-color", "var(--accent-subtle)"),
        ("color", "var(--accent)"),
    ])

    public static let suggestionIcon = CSSRule(".suggestion-icon", [
        ("font-size", "14px"),
    ])

    // ── Message Row ────────────────────────────────────────────

    public static let messageRow = CSSRule(".message-row", [
        ("display", "flex"),
        ("gap", "12px"),
        ("padding", "8px 0"),
        ("animation", "fadeInUp var(--transition-normal)"),
        ("max-width", "100%"),
    ])

    public static let messageAvatar = CSSRule(".message-avatar", [
        ("width", "32px"),
        ("height", "32px"),
        ("border-radius", "var(--radius-full)"),
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("font-size", "14px"),
        ("flex-shrink", "0"),
        ("margin-top", "2px"),
    ])

    public static let avatarUser = CSSRule(".avatar-user", [
        ("background-color", "var(--accent-muted)"),
    ])

    public static let avatarAssistant = CSSRule(".avatar-assistant", [
        ("background-color", "var(--bg-tertiary)"),
        ("border", "1px solid var(--border)"),
    ])

    public static let messageContent = CSSRule(".message-content", [
        ("flex", "1"),
        ("min-width", "0"),
    ])

    public static let messageHeaderRow = CSSRule(".message-header-row", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "8px"),
        ("margin-bottom", "4px"),
    ])

    public static let messageRoleLabel = CSSRule(".message-role-label", [
        ("font-size", "12px"),
        ("font-weight", "600"),
        ("color", "var(--text-secondary)"),
    ])

    public static let messageTimestamp = CSSRule(".message-timestamp", [
        ("font-size", "11px"),
        ("color", "var(--text-muted)"),
    ])

    // ── Message Bubble ─────────────────────────────────────────

    public static let messageBubble = CSSRule(".message-bubble", [
        ("font-size", "14px"),
        ("line-height", "1.7"),
        ("color", "var(--text-primary)"),
        ("word-wrap", "break-word"),
        ("overflow-wrap", "break-word"),
    ])

    public static let streamingBubble = CSSRule(".streaming-bubble", [
        ("min-height", "24px"),
    ])

    // ── Streaming Row ──────────────────────────────────────────

    public static let streamingRow = CSSRule(".streaming-row", [
        ("opacity", "0.9"),
    ])

    // ── Typing Dots ────────────────────────────────────────────

    public static let typingDots = CSSRule(".typing-dots", [
        ("display", "inline-flex"),
        ("align-items", "center"),
        ("gap", "4px"),
        ("padding", "4px 0"),
    ])

    public static let dot = CSSRule(".typing-dots .dot", [
        ("width", "6px"),
        ("height", "6px"),
        ("border-radius", "50%"),
        ("background-color", "var(--text-muted)"),
        ("animation", "typingBounce 1.4s ease-in-out infinite"),
    ])

    public static let dot1 = CSSRule(".typing-dots .dot:nth-child(1)", [
        ("animation-delay", "0s"),
    ])

    public static let dot2 = CSSRule(".typing-dots .dot:nth-child(2)", [
        ("animation-delay", "0.2s"),
    ])

    public static let dot3 = CSSRule(".typing-dots .dot:nth-child(3)", [
        ("animation-delay", "0.4s"),
    ])

    public static let typingBounce = CSSRule("@keyframes typingBounce", [
        ("0%, 60%, 100%", "transform: translateY(0); opacity: 0.4"),
        ("30%", "transform: translateY(-4px); opacity: 1"),
    ])

    // ── Message Actions ────────────────────────────────────────

    public static let messageActions = CSSRule(".message-actions", [
        ("display", "flex"),
        ("gap", "2px"),
        ("margin-top", "4px"),
        ("opacity", "0"),
        ("transition", "opacity var(--transition-fast)"),
    ])

    public static let messageRowHoverActions = CSSRule(".message-row:hover .message-actions", [
        ("opacity", "1"),
    ])

    public static let actionBtn = CSSRule(".action-btn", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("width", "28px"),
        ("height", "28px"),
        ("border", "none"),
        ("border-radius", "var(--radius-sm)"),
        ("background", "transparent"),
        ("color", "var(--text-muted)"),
        ("cursor", "pointer"),
        ("transition", "all var(--transition-fast)"),
    ])

    public static let actionBtnHover = CSSRule(".action-btn:hover", [
        ("background-color", "var(--bg-hover)"),
        ("color", "var(--text-primary)"),
    ])

    // ── Input Bar ──────────────────────────────────────────────

    public static let inputBar = CSSRule(".input-bar", [
        ("padding", "12px 16px 16px"),
        ("border-top", "1px solid var(--border)"),
        ("background", "var(--bg-primary)"),
        ("flex-shrink", "0"),
    ])

    public static let inputContainer = CSSRule(".input-container", [
        ("display", "flex"),
        ("gap", "8px"),
        ("align-items", "flex-end"),
        ("background", "var(--bg-secondary)"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-lg)"),
        ("padding", "8px 8px 8px 16px"),
        ("transition", "border-color var(--transition-fast)"),
    ])

    public static let inputContainerFocus = CSSRule(".input-container:focus-within", [
        ("border-color", "var(--accent)"),
        ("box-shadow", "0 0 0 3px var(--accent-muted)"),
    ])

    public static let inputField = CSSRule(".input-field", [
        ("flex", "1"),
        ("border", "none"),
        ("background", "transparent"),
        ("color", "var(--text-primary)"),
        ("font-size", "14px"),
        ("font-family", "var(--font-sans)"),
        ("line-height", "1.5"),
        ("outline", "none"),
        ("resize", "none"),
        ("max-height", "200px"),
        ("padding", "4px 0"),
    ])

    public static let inputFieldPlaceholder = CSSRule(".input-field::placeholder", [
        ("color", "var(--text-muted)"),
    ])

    public static let sendBtn = CSSRule(".send-btn", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("width", "32px"),
        ("height", "32px"),
        ("border", "none"),
        ("border-radius", "var(--radius-md)"),
        ("background", "var(--accent)"),
        ("color", "#fff"),
        ("cursor", "pointer"),
        ("transition", "all var(--transition-fast)"),
        ("flex-shrink", "0"),
    ])

    public static let sendBtnHover = CSSRule(".send-btn:hover:not(:disabled)", [
        ("background-color", "var(--accent-hover)"),
        ("transform", "scale(1.05)"),
    ])

    public static let sendBtnDisabled = CSSRule(".send-btn:disabled", [
        ("opacity", "0.4"),
        ("cursor", "not-allowed"),
        ("transform", "none"),
    ])

    public static let inputHint = CSSRule(".input-hint", [
        ("font-size", "11px"),
        ("color", "var(--text-muted)"),
        ("text-align", "right"),
        ("margin-top", "4px"),
        ("padding", "0 4px"),
    ])

    // ── Settings Panel ─────────────────────────────────────────

    public static let settingsOverlay = CSSRule(".settings-overlay", [
        ("position", "fixed"),
        ("top", "0"),
        ("left", "0"),
        ("right", "0"),
        ("bottom", "0"),
        ("background", "rgba(0, 0, 0, 0.4)"),
        ("display", "flex"),
        ("align-items", "flex-start"),
        ("justify-content", "flex-end"),
        ("z-index", "100"),
        ("animation", "fadeIn var(--transition-fast)"),
    ])

    public static let settingsPanel = CSSRule(".settings-panel", [
        ("width", "320px"),
        ("height", "100%"),
        ("background", "var(--bg-secondary)"),
        ("border-left", "1px solid var(--border)"),
        ("display", "flex"),
        ("flex-direction", "column"),
        ("animation", "slideInRight var(--transition-normal)"),
        ("box-shadow", "var(--shadow-lg)"),
    ])

    public static let settingsHeader = CSSRule(".settings-header", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "space-between"),
        ("padding", "12px 16px"),
        ("border-bottom", "1px solid var(--border)"),
        ("flex-shrink", "0"),
    ])

    public static let settingsHeaderTitle = CSSRule(".settings-header h3", [
        ("font-size", "15px"),
        ("font-weight", "600"),
    ])

    public static let settingsBody = CSSRule(".settings-body", [
        ("flex", "1"),
        ("overflow-y", "auto"),
        ("padding", "16px"),
    ])

    public static let settingsSection = CSSRule(".settings-section", [
        ("margin-bottom", "20px"),
    ])

    public static let settingsLabel = CSSRule(".settings-label", [
        ("display", "block"),
        ("font-size", "12px"),
        ("font-weight", "500"),
        ("color", "var(--text-secondary)"),
        ("margin-bottom", "6px"),
    ])

    public static let settingsSelect = CSSRule(".settings-select", [
        ("width", "100%"),
        ("padding", "8px 10px"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-md)"),
        ("background", "var(--bg-primary)"),
        ("color", "var(--text-primary)"),
        ("font-size", "13px"),
        ("font-family", "var(--font-sans)"),
        ("outline", "none"),
    ])

    public static let settingsSlider = CSSRule(".settings-slider", [
        ("width", "100%"),
        ("height", "4px"),
        ("-webkit-appearance", "none"),
        ("appearance", "none"),
        ("background", "var(--bg-tertiary)"),
        ("border-radius", "2px"),
        ("outline", "none"),
    ])

    public static let settingsSliderThumb = CSSRule(".settings-slider::-webkit-slider-thumb", [
        ("-webkit-appearance", "none"),
        ("appearance", "none"),
        ("width", "16px"),
        ("height", "16px"),
        ("border-radius", "50%"),
        ("background", "var(--accent)"),
        ("cursor", "pointer"),
        ("border", "2px solid var(--bg-secondary)"),
        ("box-shadow", "var(--shadow-sm)"),
    ])

    public static let settingsValue = CSSRule(".settings-value", [
        ("font-size", "12px"),
        ("color", "var(--text-muted)"),
        ("font-family", "var(--font-mono)"),
        ("margin-left", "8px"),
    ])

    // ── Markdown ───────────────────────────────────────────────

    public static let markdown = CSSRule(".markdown", [
        ("font-size", "14px"),
        ("line-height", "1.7"),
    ])

    public static let markdownParagraph = CSSRule(".markdown p", [
        ("margin", "4px 0"),
    ])

    public static let markdownParagraphFirst = CSSRule(".markdown p:first-child", [
        ("margin-top", "0"),
    ])

    public static let markdownParagraphLast = CSSRule(".markdown p:last-child", [
        ("margin-bottom", "0"),
    ])

    public static let markdownCode = CSSRule(".markdown code:not(pre code)", [
        ("font-family", "var(--font-mono)"),
        ("font-size", "13px"),
        ("padding", "2px 6px"),
        ("border-radius", "var(--radius-sm)"),
        ("background-color", "rgba(255, 255, 255, 0.06)"),
        ("color", "var(--accent)"),
    ])

    public static let markdownPre = CSSRule(".markdown pre", [
        ("position", "relative"),
        ("padding", "14px 16px"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "var(--bg-tertiary)"),
        ("overflow-x", "auto"),
        ("margin", "8px 0"),
        ("border", "1px solid var(--border)"),
    ])

    public static let markdownPreCode = CSSRule(".markdown pre code", [
        ("font-family", "var(--font-mono)"),
        ("font-size", "13px"),
        ("line-height", "1.5"),
        ("background", "none"),
        ("padding", "0"),
        ("color", "var(--text-primary)"),
    ])

    public static let markdownList = CSSRule(".markdown ul, .markdown ol", [
        ("margin", "4px 0"),
        ("padding-left", "20px"),
    ])

    public static let markdownBlockquote = CSSRule(".markdown blockquote", [
        ("margin", "4px 0"),
        ("padding-left", "12px"),
        ("border-left", "3px solid var(--accent-muted)"),
        ("color", "var(--text-secondary)"),
    ])

    public static let markdownHeading = CSSRule(".markdown h1, .markdown h2, .markdown h3, .markdown h4", [
        ("margin", "12px 0 6px"),
        ("font-weight", "600"),
        ("color", "var(--text-primary)"),
    ])

    public static let markdownH1 = CSSRule(".markdown h1", [
        ("font-size", "20px"),
    ])

    public static let markdownH2 = CSSRule(".markdown h2", [
        ("font-size", "17px"),
    ])

    public static let markdownH3 = CSSRule(".markdown h3", [
        ("font-size", "15px"),
    ])

    public static let markdownLink = CSSRule(".markdown a", [
        ("color", "var(--accent)"),
        ("text-decoration", "none"),
        ("border-bottom", "1px solid transparent"),
        ("transition", "border-color var(--transition-fast)"),
    ])

    public static let markdownLinkHover = CSSRule(".markdown a:hover", [
        ("border-bottom-color", "var(--accent)"),
    ])

    public static let markdownTable = CSSRule(".markdown table", [
        ("border-collapse", "collapse"),
        ("width", "100%"),
        ("margin", "8px 0"),
        ("font-size", "13px"),
    ])

    public static let markdownTh = CSSRule(".markdown th", [
        ("padding", "8px 12px"),
        ("border", "1px solid var(--border)"),
        ("background-color", "var(--bg-tertiary)"),
        ("font-weight", "600"),
        ("text-align", "left"),
    ])

    public static let markdownTd = CSSRule(".markdown td", [
        ("padding", "8px 12px"),
        ("border", "1px solid var(--border)"),
    ])

    public static let markdownHr = CSSRule(".markdown hr", [
        ("border", "none"),
        ("border-top", "1px solid var(--border)"),
        ("margin", "16px 0"),
    ])

    // ── Syntax Highlighting ────────────────────────────────────

    public static let tokenKeyword = CSSRule(".token.keyword", [
        ("color", "#ff7b72"),
    ])

    public static let tokenString = CSSRule(".token.string", [
        ("color", "#a5d6ff"),
    ])

    public static let tokenComment = CSSRule(".token.comment", [
        ("color", "#8b949e"),
        ("font-style", "italic"),
    ])

    public static let tokenType = CSSRule(".token.type", [
        ("color", "#ffa657"),
    ])

    public static let tokenNumber = CSSRule(".token.number", [
        ("color", "#79c0ff"),
    ])

    public static let tokenFunction = CSSRule(".token.function", [
        ("color", "#d2a8ff"),
    ])

    public static let tokenOperator = CSSRule(".token.operator", [
        ("color", "#ff7b72"),
    ])

    // ── Animations ─────────────────────────────────────────────

    public static let fadeIn = CSSRule("@keyframes fadeIn", [
        ("from", "opacity: 0"),
        ("to", "opacity: 1"),
    ])

    public static let fadeInUp = CSSRule("@keyframes fadeInUp", [
        ("from", "opacity: 0; transform: translateY(8px)"),
        ("to", "opacity: 1; transform: translateY(0)"),
    ])

    public static let slideInRight = CSSRule("@keyframes slideInRight", [
        ("from", "transform: translateX(100%)"),
        ("to", "transform: translateX(0)"),
    ])

    public static let slideOutRight = CSSRule("@keyframes slideOutRight", [
        ("from", "transform: translateX(0)"),
        ("to", "transform: translateX(100%)"),
    ])

    // ── Scrollbar ──────────────────────────────────────────────

    public static let scrollbar = CSSRule("::-webkit-scrollbar", [
        ("width", "6px"),
        ("height", "6px"),
    ])

    public static let scrollbarTrack = CSSRule("::-webkit-scrollbar-track", [
        ("background", "transparent"),
    ])

    public static let scrollbarThumb = CSSRule("::-webkit-scrollbar-thumb", [
        ("background", "var(--bg-hover)"),
        ("border-radius", "3px"),
    ])

    public static let scrollbarThumbHover = CSSRule("::-webkit-scrollbar-thumb:hover", [
        ("background", "var(--border-hover)"),
    ])

    // ── Selection ──────────────────────────────────────────────

    public static let selection = CSSRule("::selection", [
        ("background-color", "var(--accent-muted)"),
        ("color", "var(--text-primary)"),
    ])

    // ── All Styles ─────────────────────────────────────────────

    /// All CSS rules in the design system, in order.
    public static let all: [CSSRule] = [
        // Theme
        theme,

        // Base
        reset, html, body,

        // Layout
        appLayout,

        // Header
        chatHeader, headerLeft, headerLogo, headerTitle,
        headerCenter, headerRight,

        // Navigation Tabs
        headerNav, navTab, navTabHover, navTabActive,

        // Model Select
        modelSelect, modelSelectFocus,

        // Status
        statusBadge, statusBadgeOn, statusBadgeOff,

        // Header Button
        headerBtn, headerBtnHover,

        // Messages
        messagesContainer, messagesScroll,

        // Welcome
        welcomeScreen, welcomeIcon, welcomeTitle, welcomeSubtitle,
        welcomeSuggestions, suggestionChip, suggestionChipHover, suggestionIcon,

        // Message Row
        messageRow, messageAvatar, avatarUser, avatarAssistant,
        messageContent, messageHeaderRow, messageRoleLabel, messageTimestamp,

        // Message Bubble
        messageBubble, streamingBubble,

        // Streaming
        streamingRow, typingDots, dot, dot1, dot2, dot3, typingBounce,

        // Actions
        messageActions, messageRowHoverActions,
        actionBtn, actionBtnHover,

        // Input Bar
        inputBar, inputContainer, inputContainerFocus,
        inputField, inputFieldPlaceholder,
        sendBtn, sendBtnHover, sendBtnDisabled,
        inputHint,

        // Settings
        settingsOverlay, settingsPanel,
        settingsHeader, settingsHeaderTitle, settingsBody,
        settingsSection, settingsLabel,
        settingsSelect, settingsSlider, settingsSliderThumb, settingsValue,

        // Markdown
        markdown, markdownParagraph, markdownParagraphFirst, markdownParagraphLast,
        markdownCode, markdownPre, markdownPreCode,
        markdownList, markdownBlockquote,
        markdownHeading, markdownH1, markdownH2, markdownH3,
        markdownLink, markdownLinkHover,
        markdownTable, markdownTh, markdownTd,
        markdownHr,

        // Syntax Highlighting
        tokenKeyword, tokenString, tokenComment, tokenType, tokenNumber,
        tokenFunction, tokenOperator,

        // Animations
        fadeIn, fadeInUp, slideInRight, slideOutRight,

        // Scrollbar
        scrollbar, scrollbarTrack, scrollbarThumb, scrollbarThumbHover,

        // Selection
        selection,
    ]
}
