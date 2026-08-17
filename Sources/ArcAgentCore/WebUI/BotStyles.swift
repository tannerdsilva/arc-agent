import Foundation

// MARK: - Bot Mode Styles

/// CSS rules for the Bot Mode UI (Bots pane, Routines pane, avatars).
extension AppStyles {

    // ── Bots Pane ──────────────────────────────────────────────

    /// The left-side bot roster panel.
    public static let botsPane = CSSRule(".bots-pane", [
        ("display", "flex"),
        ("flex-direction", "column"),
        ("height", "100%"),
        ("background-color", "var(--bg-secondary)"),
        ("border-right", "1px solid var(--border)"),
        ("min-width", "0"),
    ])

    /// The bots pane header.
    public static let botsHeader = CSSRule(".bots-header", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "space-between"),
        ("padding", "10px 12px"),
        ("border-bottom", "1px solid var(--border)"),
        ("flex-shrink", "0"),
    ])

    /// Bots header title.
    public static let botsHeaderTitle = CSSRule(".bots-header h2", [
        ("font-size", "11px"),
        ("font-weight", "600"),
        ("text-transform", "uppercase"),
        ("letter-spacing", "0.05em"),
        ("color", "var(--text-muted)"),
    ])

    /// The bot roster list container.
    public static let botRoster = CSSRule(".bot-roster", [
        ("flex", "1"),
        ("overflow-y", "auto"),
        ("padding", "4px"),
    ])

    /// A single bot row in the roster.
    public static let botRow = CSSRule(".bot-row", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "8px"),
        ("padding", "6px 8px"),
        ("border-radius", "var(--radius-md)"),
        ("cursor", "pointer"),
        ("transition", "background-color var(--transition-fast)"),
        ("user-select", "none"),
    ])

    /// Bot row hover state.
    public static let botRowHover = CSSRule(".bot-row:hover", [
        ("background-color", "var(--bg-hover)"),
    ])

    /// Bot row active/selected state.
    public static let botRowActive = CSSRule(".bot-row.active", [
        ("background-color", "var(--accent-muted)"),
    ])

    /// Bot avatar container.
    public static let botAvatar = CSSRule(".bot-avatar", [
        ("width", "32px"),
        ("height", "32px"),
        ("border-radius", "22%"),
        ("flex-shrink", "0"),
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("overflow", "hidden"),
        ("position", "relative"),
    ])

    /// Bot avatar image.
    public static let botAvatarImg = CSSRule(".bot-avatar img", [
        ("width", "100%"),
        ("height", "100%"),
        ("object-fit", "cover"),
        ("border-radius", "22%"),
    ])

    /// Bot info container (name + preview).
    public static let botInfo = CSSRule(".bot-info", [
        ("flex", "1"),
        ("min-width", "0"),
        ("overflow", "hidden"),
    ])

    /// Bot display name.
    public static let botName = CSSRule(".bot-name", [
        ("font-size", "13px"),
        ("font-weight", "500"),
        ("color", "var(--text-primary)"),
        ("white-space", "nowrap"),
        ("overflow", "hidden"),
        ("text-overflow", "ellipsis"),
    ])

    /// Bot message preview.
    public static let botPreview = CSSRule(".bot-preview", [
        ("font-size", "11px"),
        ("color", "var(--text-muted)"),
        ("white-space", "nowrap"),
        ("overflow", "hidden"),
        ("text-overflow", "ellipsis"),
        ("line-height", "1.3"),
    ])

    /// Bot timestamp.
    public static let botTimestamp = CSSRule(".bot-timestamp", [
        ("font-size", "10px"),
        ("color", "var(--text-muted)"),
        ("flex-shrink", "0"),
        ("margin-left", "auto"),
    ])

    /// Active now presence dot.
    public static let activeDot = CSSRule(".active-dot", [
        ("width", "8px"),
        ("height", "8px"),
        ("border-radius", "50%"),
        ("background-color", "var(--success)"),
        ("flex-shrink", "0"),
        ("animation", "pulse 2s ease-in-out infinite"),
    ])

    /// Pulse animation for active dot.
    public static let pulseKeyframes = CSSRule("@keyframes pulse", [
        ("0%, 100%", "opacity: 1"),
        ("50%", "opacity: 0.4"),
    ])

    /// Unread badge.
    public static let unreadBadge = CSSRule(".unread-badge", [
        ("background-color", "var(--accent)"),
        ("color", "#fff"),
        ("font-size", "10px"),
        ("font-weight", "600"),
        ("padding", "1px 5px"),
        ("border-radius", "10px"),
        ("min-width", "16px"),
        ("text-align", "center"),
        ("flex-shrink", "0"),
    ])

    /// Needs-you badge for group chats.
    public static let needsYouBadge = CSSRule(".needs-you-badge", [
        ("background-color", "var(--accent)"),
        ("color", "#fff"),
        ("font-size", "9px"),
        ("font-weight", "600"),
        ("padding", "1px 6px"),
        ("border-radius", "10px"),
        ("text-transform", "uppercase"),
        ("letter-spacing", "0.03em"),
    ])

    /// Search field in the bots pane.
    public static let botSearch = CSSRule(".bot-search", [
        ("margin", "4px 8px"),
        ("padding", "6px 10px"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "var(--bg-primary)"),
        ("color", "var(--text-primary)"),
        ("font-size", "12px"),
        ("font-family", "var(--font-sans)"),
        ("outline", "none"),
        ("width", "calc(100% - 16px)"),
    ])

    /// Search field focus.
    public static let botSearchFocus = CSSRule(".bot-search:focus", [
        ("border-color", "var(--accent)"),
    ])

    /// Group header in the roster.
    public static let groupHeader = CSSRule(".group-header", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "6px"),
        ("padding", "8px 8px 4px"),
        ("font-size", "10px"),
        ("font-weight", "600"),
        ("text-transform", "uppercase"),
        ("letter-spacing", "0.05em"),
        ("color", "var(--text-muted)"),
    ])

    /// Group header separator line.
    public static let groupSeparator = CSSRule(".group-separator", [
        ("flex", "1"),
        ("height", "1px"),
        ("background-color", "var(--border)"),
    ])

    // ── Active Now Strip ───────────────────────────────────────

    /// The "active now" presence strip above the roster.
    public static let activeNowStrip = CSSRule(".active-now-strip", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "4px"),
        ("padding", "4px 8px"),
        ("border-bottom", "1px solid var(--border)"),
        ("overflow-x", "auto"),
        ("flex-shrink", "0"),
    ])

    /// Active now chip.
    public static let activeNowChip = CSSRule(".active-now-chip", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "4px"),
        ("padding", "2px 8px"),
        ("border-radius", "12px"),
        ("background-color", "rgba(63, 185, 80, 0.1)"),
        ("font-size", "11px"),
        ("color", "var(--success)"),
        ("white-space", "nowrap"),
        ("cursor", "pointer"),
    ])

    /// Active now chip hover.
    public static let activeNowChipHover = CSSRule(".active-now-chip:hover", [
        ("background-color", "rgba(63, 185, 80, 0.2)"),
    ])

    // ── Routines Pane ──────────────────────────────────────────

    /// The routines/cronjobs tile.
    public static let routinesPane = CSSRule(".routines-pane", [
        ("display", "flex"),
        ("flex-direction", "column"),
        ("height", "100%"),
        ("background-color", "var(--bg-secondary)"),
        ("border-left", "1px solid var(--border)"),
    ])

    /// Routines header.
    public static let routinesHeader = CSSRule(".routines-header", [
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "space-between"),
        ("padding", "8px 12px"),
        ("border-bottom", "1px solid var(--border)"),
        ("flex-shrink", "0"),
    ])

    /// Routines header title.
    public static let routinesHeaderTitle = CSSRule(".routines-header h3", [
        ("font-size", "11px"),
        ("font-weight", "600"),
        ("text-transform", "uppercase"),
        ("letter-spacing", "0.05em"),
        ("color", "var(--text-muted)"),
    ])

    /// Routines list.
    public static let routinesList = CSSRule(".routines-list", [
        ("flex", "1"),
        ("overflow-y", "auto"),
        ("padding", "4px"),
    ])

    /// A single routine row.
    public static let routineRow = CSSRule(".routine-row", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "8px"),
        ("padding", "6px 8px"),
        ("border-radius", "var(--radius-md)"),
        ("font-size", "12px"),
        ("color", "var(--text-primary)"),
    ])

    /// Routine schedule text.
    public static let routineSchedule = CSSRule(".routine-schedule", [
        ("font-size", "10px"),
        ("color", "var(--text-muted)"),
        ("font-family", "var(--font-mono)"),
    ])

    /// Routine prompt preview.
    public static let routinePrompt = CSSRule(".routine-prompt", [
        ("font-size", "11px"),
        ("color", "var(--text-secondary)"),
        ("white-space", "nowrap"),
        ("overflow", "hidden"),
        ("text-overflow", "ellipsis"),
    ])

    // ── New Agent Dialog ───────────────────────────────────────

    /// Dialog overlay.
    public static let dialogOverlay = CSSRule(".dialog-overlay", [
        ("position", "fixed"),
        ("top", "0"),
        ("left", "0"),
        ("right", "0"),
        ("bottom", "0"),
        ("background-color", "rgba(0, 0, 0, 0.5)"),
        ("display", "flex"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("z-index", "100"),
    ])

    /// Dialog content.
    public static let dialogContent = CSSRule(".dialog-content", [
        ("background-color", "var(--bg-secondary)"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-lg)"),
        ("padding", "20px"),
        ("min-width", "360px"),
        ("max-width", "480px"),
        ("box-shadow", "var(--shadow-md)"),
    ])

    /// Dialog title.
    public static let dialogTitle = CSSRule(".dialog-title", [
        ("font-size", "16px"),
        ("font-weight", "600"),
        ("margin-bottom", "16px"),
    ])

    /// Form field label.
    public static let formLabel = CSSRule(".form-label", [
        ("display", "block"),
        ("font-size", "12px"),
        ("font-weight", "500"),
        ("color", "var(--text-secondary)"),
        ("margin-bottom", "4px"),
    ])

    /// Form input.
    public static let formInput = CSSRule(".form-input", [
        ("width", "100%"),
        ("padding", "8px 10px"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "var(--bg-primary)"),
        ("color", "var(--text-primary)"),
        ("font-size", "13px"),
        ("font-family", "var(--font-sans)"),
        ("outline", "none"),
        ("margin-bottom", "12px"),
    ])

    /// Form input focus.
    public static let formInputFocus = CSSRule(".form-input:focus", [
        ("border-color", "var(--accent)"),
    ])

    /// Form textarea.
    public static let formTextarea = CSSRule(".form-textarea", [
        ("width", "100%"),
        ("padding", "8px 10px"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "var(--bg-primary)"),
        ("color", "var(--text-primary)"),
        ("font-size", "13px"),
        ("font-family", "var(--font-sans)"),
        ("outline", "none"),
        ("resize", "vertical"),
        ("min-height", "60px"),
        ("margin-bottom", "12px"),
    ])

    /// Form actions row.
    public static let formActions = CSSRule(".form-actions", [
        ("display", "flex"),
        ("justify-content", "flex-end"),
        ("gap", "8px"),
        ("margin-top", "8px"),
    ])

    /// Primary button.
    public static let btnPrimary = CSSRule(".btn-primary", [
        ("padding", "8px 16px"),
        ("border", "none"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "var(--accent)"),
        ("color", "#fff"),
        ("font-size", "13px"),
        ("font-weight", "500"),
        ("cursor", "pointer"),
        ("transition", "background-color var(--transition-fast)"),
    ])

    /// Primary button hover.
    public static let btnPrimaryHover = CSSRule(".btn-primary:hover", [
        ("background-color", "var(--accent-hover)"),
    ])

    /// Secondary button.
    public static let btnSecondary = CSSRule(".btn-secondary", [
        ("padding", "8px 16px"),
        ("border", "1px solid var(--border)"),
        ("border-radius", "var(--radius-md)"),
        ("background-color", "transparent"),
        ("color", "var(--text-primary)"),
        ("font-size", "13px"),
        ("font-weight", "500"),
        ("cursor", "pointer"),
        ("transition", "all var(--transition-fast)"),
    ])

    /// Secondary button hover.
    public static let btnSecondaryHover = CSSRule(".btn-secondary:hover", [
        ("background-color", "var(--bg-hover)"),
    ])

    /// Empty state.
    public static let emptyState = CSSRule(".empty-state", [
        ("display", "flex"),
        ("flex-direction", "column"),
        ("align-items", "center"),
        ("justify-content", "center"),
        ("padding", "24px"),
        ("text-align", "center"),
        ("color", "var(--text-muted)"),
        ("font-size", "13px"),
        ("gap", "8px"),
    ])

    /// Empty state icon.
    public static let emptyStateIcon = CSSRule(".empty-state .icon", [
        ("font-size", "28px"),
        ("opacity", "0.5"),
    ])

    // ── Avatar Shapes ──────────────────────────────────────────

    /// SVG avatar container.
    public static let avatarSvg = CSSRule(".avatar-svg", [
        ("display", "block"),
        ("overflow", "visible"),
    ])

    /// Working dots below avatar.
    public static let workingDots = CSSRule(".working-dots", [
        ("display", "flex"),
        ("gap", "2px"),
        ("justify-content", "center"),
        ("margin-top", "2px"),
    ])

    /// Working dot.
    public static let workingDot = CSSRule(".working-dot", [
        ("width", "4px"),
        ("height", "4px"),
        ("border-radius", "50%"),
        ("animation", "bounce 1.2s ease-in-out infinite"),
    ])

    /// Bounce animation for working dots.
    public static let bounceKeyframes = CSSRule("@keyframes bounce", [
        ("0%, 100%", "opacity: 0.3; transform: translateY(0)"),
        ("50%", "opacity: 1; transform: translateY(-3px)"),
    ])

    // ── Bot Chat Header ────────────────────────────────────────

    /// Bot chat header in the main chat area.
    public static let botChatHeader = CSSRule(".bot-chat-header", [
        ("display", "flex"),
        ("align-items", "center"),
        ("gap", "10px"),
        ("padding", "8px 16px"),
        ("border-bottom", "1px solid var(--border)"),
        ("background-color", "var(--bg-secondary)"),
        ("flex-shrink", "0"),
    ])

    /// Bot chat header name.
    public static let botChatHeaderName = CSSRule(".bot-chat-header .bot-name", [
        ("font-size", "14px"),
        ("font-weight", "600"),
    ])

    /// Bot chat header handle.
    public static let botChatHeaderHandle = CSSRule(".bot-chat-header .bot-handle", [
        ("font-size", "11px"),
        ("color", "var(--text-muted)"),
        ("font-family", "var(--font-mono)"),
    ])
}

// MARK: - All Bot Styles

/// All bot mode CSS rules, appended to the main stylesheet.
extension AppStyles {
    public static let botStyles: [CSSRule] = [
        // Bots pane
        botsPane, botsHeader, botsHeaderTitle,
        botRoster, botRow, botRowHover, botRowActive,
        botAvatar, botAvatarImg,
        botInfo, botName, botPreview, botTimestamp,
        activeDot, pulseKeyframes,
        unreadBadge, needsYouBadge,
        botSearch, botSearchFocus,
        groupHeader, groupSeparator,

        // Active now
        activeNowStrip, activeNowChip, activeNowChipHover,

        // Routines pane
        routinesPane, routinesHeader, routinesHeaderTitle,
        routinesList, routineRow, routineSchedule, routinePrompt,

        // Dialog
        dialogOverlay, dialogContent, dialogTitle,
        formLabel, formInput, formInputFocus,
        formTextarea, formActions,
        btnPrimary, btnPrimaryHover,
        btnSecondary, btnSecondaryHover,

        // Empty state
        emptyState, emptyStateIcon,

        // Avatars
        avatarSvg, workingDots, workingDot, bounceKeyframes,

        // Bot chat header
        botChatHeader, botChatHeaderName, botChatHeaderHandle,
    ]
}
