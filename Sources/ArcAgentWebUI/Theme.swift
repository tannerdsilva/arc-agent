import Foundation

// MARK: - Themes

/// Hermes-style cream/sepia light theme + a dark theme, driven by CSS custom
/// properties on the `#app` root so theme, accent and text-size changes can be
/// re-rendered as a single fragment.
/// Full color schemes. Each scheme defines a complete palette for both light
/// and dark modes, applied through CSS custom properties keyed off
/// `#app[data-scheme="..."]` so switching schemes re-renders as one fragment.
struct ColorScheme {
    static let all: [ColorScheme] = [
        .defaultScheme, .ares, .mono, .graphite, .github, .codex, .terracotta, .slate,
        .poseidon, .sisyphus, .charizard, .sienna, .catppuccin, .hepburn, .nous, .neon,
        .neonSoft, .neonPaint, .geistContrast, .zeus, .verdigris, .dracula, .gruvbox,
        .oneDark, .tokyoNight, .rosePine, .solarizedDark,
    ]

    let id: String
    let label: String
    /// Used as the settings swatch accent (selection border color).
    let accentHex: String
    /// The three swatch dots shown in the Settings → Skin grid (accent trio).
    let dots: [String]
    fileprivate let light: [String: String]
    fileprivate let dark: [String: String]

    private init(id: String, label: String, accentHex: String, dots: [String], light: [String: String], dark: [String: String]) {
        self.id = id
        self.label = label
        self.accentHex = accentHex
        self.dots = dots
        self.light = light
        self.dark = dark
    }

    /// `#app[data-scheme="<id>"][data-theme="light|dark"] { --var: value; ... }`
    var cssBlocks: String {
        block(theme: "light", vars: light) + "\n" + block(theme: "dark", vars: dark)
            + "\n" + block(theme: "system", vars: light)
            + "\n@media (prefers-color-scheme: dark) {\n" + block(theme: "system", vars: dark) + "\n}"
    }

    private func block(theme: String, vars: [String: String]) -> String {
        let body = vars.map { "      --\($0.key): \($0.value);" }.joined(separator: "\n")
        return "#app[data-scheme=\"\(id)\"][data-theme=\"\(theme)\"] {\n" + body + "\n    }"
    }

    // MARK: Schemas
    static let defaultScheme = ColorScheme(id: "default", label: "Default", accentHex: "#B8860B", dots: ["#D9A441", "#B8860B", "#8A5A2B"],
        light: ["bg": "#FDFBF7", "surface": "#FFFFFF", "surface-2": "#F7F3EA", "sidebar": "#FAF7F0",
                "border": "#EAE2D3", "border-strong": "#D5CEBE", "text": "#2A2723", "muted": "#8A8271",
                "accent": "#B8860B", "accent-strong": "#9A6F09", "accent-soft": "rgba(184, 134, 11, 0.10)",
                "accent-border": "rgba(184, 134, 11, 0.45)", "link": "#0288A8", "danger": "#B34141",
                "danger-soft": "rgba(179, 65, 65, 0.10)", "success": "#4E7C3A",
                "shadow": "0 2px 12px rgba(60, 50, 30, 0.08)", "user-bubble": "rgba(184, 134, 11, 0.10)",
                "code-bg": "#F4EFE3", "scroll-thumb": "#D8D0BE"],
        dark: ["bg": "#17171B", "surface": "#1F1F24", "surface-2": "#26262C", "sidebar": "#1B1B20",
               "border": "#2E2E36", "border-strong": "#3C3C46", "text": "#E8E6E1", "muted": "#9A9486",
               "accent": "#D9A441", "accent-strong": "#E3B45C", "accent-soft": "rgba(217, 164, 65, 0.14)",
               "accent-border": "rgba(217, 164, 65, 0.5)", "link": "#58B7D6", "danger": "#E06C6C",
               "danger-soft": "rgba(224, 108, 108, 0.14)", "success": "#7FB069",
               "shadow": "0 2px 14px rgba(0, 0, 0, 0.35)", "user-bubble": "rgba(217, 164, 65, 0.13)",
               "code-bg": "#2A2A31", "scroll-thumb": "#3A3A44"])

    static let poseidon = ColorScheme(id: "poseidon", label: "Poseidon", accentHex: "#0E7C9B", dots: ["#4FC3E8", "#0E7C9B", "#0B4E63"],
        light: ["bg": "#F4FAFC", "surface": "#FFFFFF", "surface-2": "#EAF3F6", "sidebar": "#F0F7F9",
                "border": "#D8E7EC", "border-strong": "#C0D6DE", "text": "#17313A", "muted": "#5F7A84",
                "accent": "#0E7C9B", "accent-strong": "#0A6580", "accent-soft": "rgba(14, 124, 155, 0.10)",
                "accent-border": "rgba(14, 124, 155, 0.42)", "link": "#0E7C9B", "danger": "#C04040",
                "danger-soft": "rgba(192, 64, 64, 0.10)", "success": "#2E7D5B",
                "shadow": "0 2px 12px rgba(20, 90, 110, 0.08)", "user-bubble": "rgba(14, 124, 155, 0.10)",
                "code-bg": "#E8F2F5", "scroll-thumb": "#C4DCE4"],
        dark: ["bg": "#0E1B22", "surface": "#14242D", "surface-2": "#1B2D38", "sidebar": "#101E25",
               "border": "#24404B", "border-strong": "#315463", "text": "#DBE9EF", "muted": "#7E9AA6",
               "accent": "#4FC3E8", "accent-strong": "#6BD3F2", "accent-soft": "rgba(79, 195, 232, 0.14)",
               "accent-border": "rgba(79, 195, 232, 0.5)", "link": "#4FC3E8", "danger": "#EF7A7A",
               "danger-soft": "rgba(239, 122, 122, 0.14)", "success": "#63D0A0",
               "shadow": "0 2px 14px rgba(0, 0, 0, 0.4)", "user-bubble": "rgba(79, 195, 232, 0.13)",
               "code-bg": "#1C3140", "scroll-thumb": "#2E4961"])

    static let rosePine = ColorScheme(id: "rosepine", label: "Rosé Pine", accentHex: "#B4637A", dots: ["#E0DEF4", "#B4637A", "#8A7AB5"],
        light: ["bg": "#FAF4F4", "surface": "#FFFBFB", "surface-2": "#F3E9E9", "sidebar": "#F7EEEE",
                "border": "#E4D6D6", "border-strong": "#D0BABA", "text": "#32211F", "muted": "#8F7777",
                "accent": "#B4637A", "accent-strong": "#9C4D63", "accent-soft": "rgba(180, 99, 122, 0.10)",
                "accent-border": "rgba(180, 99, 122, 0.42)", "link": "#9A7ED9", "danger": "#C04C4C",
                "danger-soft": "rgba(192, 76, 76, 0.10)", "success": "#6F9F5C",
                "shadow": "0 2px 12px rgba(120, 60, 70, 0.08)", "user-bubble": "rgba(180, 99, 122, 0.10)",
                "code-bg": "#F2E7E7", "scroll-thumb": "#DCC7C6"],
        dark: ["bg": "#191724", "surface": "#1F1D2E", "surface-2": "#26233A", "sidebar": "#1B1926",
               "border": "#322F4A", "border-strong": "#403E5C", "text": "#E0DEF4", "muted": "#908CAA",
               "accent": "#EBBCBA", "accent-strong": "#F0C6C4", "accent-soft": "rgba(235, 188, 186, 0.14)",
               "accent-border": "rgba(235, 188, 186, 0.5)", "link": "#9CCFD8", "danger": "#EB6F92",
               "danger-soft": "rgba(235, 111, 146, 0.14)", "success": "#9CCFD8",
               "shadow": "0 2px 14px rgba(0, 0, 0, 0.4)", "user-bubble": "rgba(235, 188, 186, 0.13)",
               "code-bg": "#26233A", "scroll-thumb": "#3C3955"])

    static let dracula = ColorScheme(id: "dracula", label: "Dracula", accentHex: "#BD93F9", dots: ["#BD93F9", "#FF79C6", "#50FA7B"],
        light: ["bg": "#F8F7FC", "surface": "#FFFFFF", "surface-2": "#EFEDF7", "sidebar": "#F4F2FA",
                "border": "#DDD9EC", "border-strong": "#C6C0DC", "text": "#282433", "muted": "#7D7792",
                "accent": "#6C4FA1", "accent-strong": "#58408A", "accent-soft": "rgba(108, 79, 161, 0.10)",
                "accent-border": "rgba(108, 79, 161, 0.42)", "link": "#4E7CE0", "danger": "#C94A5E",
                "danger-soft": "rgba(201, 74, 94, 0.10)", "success": "#3B8C5A",
                "shadow": "0 2px 12px rgba(60, 50, 100, 0.08)", "user-bubble": "rgba(108, 79, 161, 0.10)",
                "code-bg": "#ECEAF4", "scroll-thumb": "#C9C4DD"],
        dark: ["bg": "#282A36", "surface": "#2F3240", "surface-2": "#383A4A", "sidebar": "#2B2D3B",
               "border": "#44475A", "border-strong": "#565975", "text": "#F8F8F2", "muted": "#8C90A6",
               "accent": "#BD93F9", "accent-strong": "#CBA3FA", "accent-soft": "rgba(189, 147, 249, 0.15)",
               "accent-border": "rgba(189, 147, 249, 0.5)", "link": "#8BE9FD", "danger": "#FF5555",
               "danger-soft": "rgba(255, 85, 85, 0.15)", "success": "#50FA7B",
               "shadow": "0 2px 14px rgba(0, 0, 0, 0.45)", "user-bubble": "rgba(189, 147, 249, 0.13)",
               "code-bg": "#383A4A", "scroll-thumb": "#4B4E61"])

    static let neon = ColorScheme(id: "neon", label: "Neon", accentHex: "#00B8FF", dots: ["#A855F7", "#00B8FF", "#22D3EE"],
        light: ["bg": "#F7F9FB", "surface": "#FFFFFF", "surface-2": "#ECF0F4", "sidebar": "#F1F4F7",
                "border": "#D9E0E8", "border-strong": "#BFCAD6", "text": "#1B2230", "muted": "#68788C",
                "accent": "#0896C2", "accent-strong": "#067A9F", "accent-soft": "rgba(0, 184, 255, 0.09)",
                "accent-border": "rgba(0, 152, 214, 0.42)", "link": "#7B61FF", "danger": "#E6386E",
                "danger-soft": "rgba(230, 56, 110, 0.10)", "success": "#00A97F",
                "shadow": "0 2px 12px rgba(0, 80, 140, 0.08)", "user-bubble": "rgba(0, 184, 255, 0.09)",
                "code-bg": "#E9EFF5", "scroll-thumb": "#CAD5E0"],
        dark: ["bg": "#0B0D12", "surface": "#12151C", "surface-2": "#1A1E28", "sidebar": "#0E1116",
               "border": "#252B38", "border-strong": "#333B4C", "text": "#E9EEF7", "muted": "#7E8AA0",
               "accent": "#00E5FF", "accent-strong": "#33EBFF", "accent-soft": "rgba(0, 229, 255, 0.14)",
               "accent-border": "rgba(0, 229, 255, 0.5)", "link": "#7B61FF", "danger": "#FF3D71",
               "danger-soft": "rgba(255, 61, 113, 0.14)", "success": "#00F0A0",
               "shadow": "0 2px 14px rgba(0, 0, 0, 0.45)", "user-bubble": "rgba(0, 229, 255, 0.12)",
               "code-bg": "#1A1E28", "scroll-thumb": "#2E3546"])

    static let codex = ColorScheme(id: "codex", label: "Codex", accentHex: "#0969DA", dots: ["#10A37F", "#E8E8E8", "#333333"],
        light: ["bg": "#F6F8FA", "surface": "#FFFFFF", "surface-2": "#EDF0F3", "sidebar": "#F2F4F7",
                "border": "#D8DEE4", "border-strong": "#C2CAD1", "text": "#24292F", "muted": "#6A737D",
                "accent": "#0969DA", "accent-strong": "#0757B8", "accent-soft": "rgba(9, 105, 218, 0.09)",
                "accent-border": "rgba(9, 105, 218, 0.40)", "link": "#0969DA", "danger": "#CF222E",
                "danger-soft": "rgba(207, 34, 46, 0.09)", "success": "#1A7F37",
                "shadow": "0 2px 12px rgba(20, 40, 70, 0.07)", "user-bubble": "rgba(9, 105, 218, 0.09)",
                "code-bg": "#F1F2F4", "scroll-thumb": "#C9D1D9"],
        dark: ["bg": "#0D1117", "surface": "#161B22", "surface-2": "#1C2129", "sidebar": "#0D1117",
               "border": "#30363D", "border-strong": "#3F4751", "text": "#E6EDF3", "muted": "#8B949E",
               "accent": "#58A6FF", "accent-strong": "#79B8FF", "accent-soft": "rgba(88, 166, 255, 0.14)",
               "accent-border": "rgba(88, 166, 255, 0.5)", "link": "#58A6FF", "danger": "#F85149",
               "danger-soft": "rgba(248, 81, 73, 0.14)", "success": "#3FB950",
               "shadow": "0 2px 14px rgba(0, 0, 0, 0.4)", "user-bubble": "rgba(88, 166, 255, 0.12)",
               "code-bg": "#161B22", "scroll-thumb": "#30363D"])

    /// Hermes WebUI dark + Sisyphus (violet) — mirrors the Hermes chat UI.
    static let sisyphus = ColorScheme(id: "sisyphus", label: "Sisyphus", accentHex: "#A78BFA", dots: ["#C4B5FD", "#8B5CF6", "#5B21B6"],
        light: ["bg": "#FEFCF7", "surface": "#FFFFFF", "surface-2": "#F3EEE3", "sidebar": "#FAF7F0",
                "border": "#E0D8C8", "border-strong": "#D0C8B8", "text": "#1A1610", "muted": "#5C5344",
                "accent": "#7C3AED", "accent-strong": "#6D28D9", "accent-soft": "rgba(124, 58, 237, 0.08)",
                "accent-border": "rgba(124, 58, 237, 0.40)", "link": "#6D28D9", "danger": "#C62828",
                "danger-soft": "rgba(198, 40, 40, 0.10)", "success": "#3D8B40",
                "shadow": "0 2px 12px rgba(60, 50, 30, 0.08)", "user-bubble": "rgba(124, 58, 237, 0.08)",
                "code-bg": "#F5F0E5", "scroll-thumb": "#D8D0BE"],
        dark: ["bg": "#0D0D1A", "surface": "#1A1A2E", "surface-2": "#20203A", "sidebar": "#141425",
               "border": "#2A2A45", "border-strong": "#3A3A5C", "text": "#FFF8DC", "muted": "#C0C0C0",
               "accent": "#A78BFA", "accent-strong": "#8B5CF6", "accent-soft": "rgba(167, 139, 250, 0.08)",
               "accent-border": "rgba(167, 139, 250, 0.35)", "link": "#A78BFA", "danger": "#EF5350",
               "danger-soft": "rgba(239, 83, 80, 0.14)", "success": "#4CAF50",
               "shadow": "0 2px 14px rgba(0, 0, 0, 0.4)", "user-bubble": "rgba(167, 139, 250, 0.08)",
               "code-bg": "#1A1A2E", "code-text": "#E2E8F0", "code-inline-bg": "rgba(0, 0, 0, 0.35)",
               "input-bg": "rgba(255, 255, 255, 0.04)", "hover-bg": "rgba(255, 255, 255, 0.06)",
               "border-subtle": "rgba(255, 255, 255, 0.075)", "scroll-thumb": "#2A2A45"])

    // MARK: Generated palettes (Hermes Skin grid — 3-dot accent swatches)

    /// Build a scheme from an accent trio; light/dark variants are derived
    /// from the accent plus a neutral base so all 27 Skin entries stay
    /// compact while reading cleanly in both themes.
    static func make(id: String, label: String, accent: String, strong: String, dots: [String]) -> ColorScheme {
        let light: [String: String] = [
            "bg": "#F7F7F9", "surface": "#FFFFFF", "surface-2": "#EFEFF3",
            "sidebar": "#F2F2F5", "border": "#E2E2E8", "border-strong": "#D0D0D8",
            "text": "#1D1D24", "muted": "#71717A",
            "accent": accent, "accent-strong": strong,
            "accent-soft": rgba(accent, 0.10), "accent-border": rgba(accent, 0.45),
            "link": strong, "danger": "#C43C3C", "danger-soft": "rgba(196, 60, 60, 0.10)",
            "success": "#3D8B52",
            "shadow": "0 2px 12px rgba(30, 30, 40, 0.08)",
            "user-bubble": rgba(accent, 0.10), "code-bg": "#F0F0F4",
            "code-text": "#1D1D24", "code-inline-bg": "rgba(0, 0, 0, 0.05)",
            "input-bg": "rgba(0, 0, 0, 0.02)", "hover-bg": "rgba(0, 0, 0, 0.04)",
            "border-subtle": "rgba(0, 0, 0, 0.08)", "scroll-thumb": "#D4D4DC",
        ]
        let dark: [String: String] = [
            "bg": "#131318", "surface": "#1B1B22", "surface-2": "#23232C",
            "sidebar": "#17171D", "border": "#2C2C36", "border-strong": "#3A3A46",
            "text": "#E6E6EC", "muted": "#9A9AA5",
            "accent": accent, "accent-strong": strong,
            "accent-soft": rgba(accent, 0.15), "accent-border": rgba(accent, 0.5),
            "link": strong, "danger": "#E5484D", "danger-soft": "rgba(229, 72, 77, 0.14)",
            "success": "#46A758",
            "shadow": "0 2px 14px rgba(0, 0, 0, 0.35)",
            "user-bubble": rgba(accent, 0.13), "code-bg": "#23232C",
            "code-text": "#E6E6EC", "code-inline-bg": "rgba(0, 0, 0, 0.35)",
            "input-bg": "rgba(255, 255, 255, 0.04)", "hover-bg": "rgba(255, 255, 255, 0.06)",
            "border-subtle": "rgba(255, 255, 255, 0.075)", "scroll-thumb": "#33333E",
        ]
        return ColorScheme(id: id, label: label, accentHex: accent, dots: dots, light: light, dark: dark)
    }

    private static func rgba(_ hex: String, _ alpha: Double) -> String {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return hex }
        let r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF
        return "rgba(\(r), \(g), \(b), \(alpha))"
    }

    static let ares = make(id: "ares", label: "Ares", accent: "#E5484D", strong: "#C6373C", dots: ["#E5484D", "#F06A75", "#F8A5AE"])
    static let mono = make(id: "mono", label: "Mono", accent: "#8B8B93", strong: "#6E6E76", dots: ["#C8C8CD", "#8B8B93", "#4A4A52"])
    static let graphite = make(id: "graphite", label: "Graphite", accent: "#6E6E76", strong: "#55555C", dots: ["#FFFFFF", "#B8B8C0", "#3A3A42"])
    static let github = make(id: "github", label: "GitHub", accent: "#0969DA", strong: "#0857B0", dots: ["#0969DA", "#1F883D", "#30363D"])
    static let terracotta = make(id: "terracotta", label: "Terracotta", accent: "#C0785A", strong: "#A8624A", dots: ["#C08A6D", "#E8E8E8", "#3A3A42"])
    static let slate = make(id: "slate", label: "Slate", accent: "#4E7C99", strong: "#3D647D", dots: ["#7DA7C4", "#4E7C99", "#2A3F4C"])
    static let charizard = make(id: "charizard", label: "Charizard", accent: "#F97316", strong: "#C2410C", dots: ["#F9A03F", "#F97316", "#C2410C"])
    static let sienna = make(id: "sienna", label: "Sienna", accent: "#A9714B", strong: "#8A5A3B", dots: ["#D2A17E", "#A9714B", "#6B4632"])
    static let catppuccin = make(id: "catppuccin", label: "Catppuccin", accent: "#C6A0F6", strong: "#A480E4", dots: ["#CDD6F4", "#C6A0F6", "#7C6FA8"])
    static let hepburn = make(id: "hepburn", label: "Hepburn", accent: "#F472B6", strong: "#E75CA8", dots: ["#F472B6", "#F9A8D4", "#FBCFE8"])
    static let nous = make(id: "nous", label: "Nous", accent: "#3B82F6", strong: "#2563EB", dots: ["#93C5FD", "#3B82F6", "#1E3A8A"])
    static let neonSoft = make(id: "neon-soft", label: "Neon Soft", accent: "#C084FC", strong: "#A855F7", dots: ["#C084FC", "#67E8F9", "#BAE6FD"])
    static let neonPaint = make(id: "neon-paint", label: "Neon Paint", accent: "#EC4899", strong: "#DB2777", dots: ["#EC4899", "#22D3EE", "#FDE047"])
    static let geistContrast = make(id: "geist-contrast", label: "Geist Contrast", accent: "#FFF175", strong: "#E5D95B", dots: ["#000000", "#FFFFFF", "#FFF175"])
    static let zeus = make(id: "zeus", label: "Zeus", accent: "#E5B75D", strong: "#C9A227", dots: ["#E5B75D", "#C9A227", "#365314"])
    static let verdigris = make(id: "verdigris", label: "Verdigris", accent: "#2F5D50", strong: "#24493F", dots: ["#C0A080", "#2F5D50", "#3A3A42"])
    static let gruvbox = make(id: "gruvbox", label: "Gruvbox", accent: "#D79921", strong: "#B07E15", dots: ["#D79921", "#FE8019", "#B8BB26"])
    static let oneDark = make(id: "one-dark", label: "One Dark", accent: "#61AFEF", strong: "#4A93CC", dots: ["#61AFEF", "#C678DD", "#98C379"])
    static let tokyoNight = make(id: "tokyo-night", label: "Tokyo Night", accent: "#7AA2F7", strong: "#5E88E8", dots: ["#7AA2F7", "#BB9AF7", "#9ECE6A"])
    static let solarizedDark = make(id: "solarized-dark", label: "Solarized Dark", accent: "#268BD2", strong: "#1B6FA8", dots: ["#268BD2", "#2AA198", "#859900"])
}

enum ThemeSize: String, CaseIterable {
    case sm = "sm"
    case md = "md"
    case lg = "lg"
    case xl = "xl"

    var label: String {
        switch self {
        case .sm: return "Small"
        case .md: return "Default"
        case .lg: return "Large"
        case .xl: return "Extra Large"
        }
    }
    /// "Aa" preview size inside the picker card (mirrors Hermes webui).
    var previewPx: String {
        switch self {
        case .sm: return "10px"
        case .md: return "13px"
        case .lg: return "17px"
        case .xl: return "20px"
        }
    }
    var px: String {
        switch self {
        case .sm: return "13px"
        case .md: return "14.5px"
        case .lg: return "17px"
        case .xl: return "18.5px"
        }
    }
}

enum Theme {

static let css: String = """
    :root {
      --font-size: 14.5px;
      --iconbar-w: 56px;
      --panel-w: 280px;
      --radius-lg: 16px;
      --radius-md: 11px;
      --radius-sm: 8px;
      --warning: #E68A00;
    }
    /* Text size (user setting -> #app data-size; md = default) */
    #app[data-size="sm"] { --font-size: 13px; }
    #app[data-size="lg"] { --font-size: 16.5px; }

    * { box-sizing: border-box; }
    html, body { height: 100%; margin: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      font-size: var(--font-size);
      -webkit-font-smoothing: antialiased;
    }

    /* ─── Light theme ─────────────────────────────────────────── */
    #app[data-theme="light"] {
      --bg: #FDFBF7;
      --surface: #FFFFFF;
      --surface-2: #F7F3EA;
      --sidebar: #FAF7F0;
      --border: #EAE2D3;
      --border-strong: #D5CEBE;
      --text: #2A2723;
      --muted: #8A8271;
      --accent: #B8860B;
      --accent-strong: #9A6F09;
      --accent-soft: rgba(184, 134, 11, 0.10);
      --accent-border: rgba(184, 134, 11, 0.45);
      --link: #0288A8;
      --danger: #B34141;
      --danger-soft: rgba(179, 65, 65, 0.10);
      --success: #4E7C3A;
      --shadow: 0 2px 12px rgba(60, 50, 30, 0.08);
      --user-bubble: rgba(184, 134, 11, 0.10);
      --code-bg: #F4EFE3;
      --scroll-thumb: #D8D0BE;
    }

    /* ─── Dark theme (Hermes dark + Sisyphus violet) ───────────── */
    #app[data-theme="dark"] {
      --bg: #0D0D1A;
      --surface: #1A1A2E;
      --surface-2: #20203A;
      --sidebar: #141425;
      --border: #2A2A45;
      --border-strong: #3A3A5C;
      --text: #FFF8DC;
      --muted: #C0C0C0;
      --accent: #A78BFA;
      --accent-strong: #8B5CF6;
      --accent-soft: rgba(167, 139, 250, 0.08);
      --accent-border: rgba(167, 139, 250, 0.35);
      --link: #A78BFA;
      --danger: #EF5350;
      --danger-soft: rgba(239, 83, 80, 0.14);
      --success: #4CAF50;
      --shadow: 0 2px 14px rgba(0, 0, 0, 0.4);
      --user-bubble: rgba(167, 139, 250, 0.08);
      --code-bg: #1A1A2E;
      --code-text: #E2E8F0;
      --code-inline-bg: rgba(0, 0, 0, 0.35);
      --input-bg: rgba(255, 255, 255, 0.04);
      --hover-bg: rgba(255, 255, 255, 0.06);
      --border-subtle: rgba(255, 255, 255, 0.075);
      --scroll-thumb: #2A2A45;
    }

    /* ─── System theme (light by default; follows the OS) ──────── */
    #app[data-theme="system"] {
      --bg: #FDFBF7;
      --surface: #FFFFFF;
      --surface-2: #F7F3EA;
      --sidebar: #FAF7F0;
      --border: #EAE2D3;
      --border-strong: #D5CEBE;
      --text: #2A2723;
      --muted: #8A8271;
      --accent: #B8860B;
      --accent-strong: #9A6F09;
      --accent-soft: rgba(184, 134, 11, 0.10);
      --accent-border: rgba(184, 134, 11, 0.45);
      --link: #0288A8;
      --danger: #B34141;
      --danger-soft: rgba(179, 65, 65, 0.10);
      --success: #4E7C3A;
      --shadow: 0 2px 12px rgba(60, 50, 30, 0.08);
      --user-bubble: rgba(184, 134, 11, 0.10);
      --code-bg: #F4EFE3;
      --scroll-thumb: #D8D0BE;
    }
    @media (prefers-color-scheme: dark) {
      #app[data-theme="system"] {
        --bg: #17171B;
        --surface: #1F1F24;
        --surface-2: #26262C;
        --sidebar: #1B1B20;
        --border: #2E2E36;
        --border-strong: #3C3C46;
        --text: #E8E6E1;
        --muted: #9A9486;
        --accent: #D9A441;
        --accent-strong: #E3B45C;
        --accent-soft: rgba(217, 164, 65, 0.14);
        --accent-border: rgba(217, 164, 65, 0.5);
        --link: #58B7D6;
        --danger: #E06C6C;
        --danger-soft: rgba(224, 108, 108, 0.14);
        --success: #7FB069;
        --shadow: 0 2px 14px rgba(0, 0, 0, 0.35);
        --user-bubble: rgba(217, 164, 65, 0.13);
        --code-bg: #2A2A31;
        --scroll-thumb: #3A3A44;
      }
    }

    /* ─── App chrome ──────────────────────────────────────────── */
    #app {
      display: flex;
      flex-direction: column;
      height: 100vh;
      background: var(--bg);
      color: var(--text);
      font-size: var(--font-size);
    }
    #app-body {
      display: flex;
      flex: 1;
      min-height: 0;
    }

    /* Full-width top bar (Hermes-style): thin strip, centred bolt + chat name */
    #topbar {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 38px;
      flex: 0 0 38px;
      background: var(--sidebar);
      border-bottom: 1px solid var(--border);
      position: relative;
      z-index: 5;
    }
    .topbar-center { display: flex; align-items: center; gap: 7px; }
    .topbar-bolt { display: inline-flex; color: var(--muted); }
    .topbar-bolt svg { display: block; }
    .topbar-name {
      font-size: 0.95em;
      font-weight: 600;
      color: var(--text);
      letter-spacing: 0.01em;
      max-width: 420px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    /* Icon sidebar */
    #iconbar {
      width: var(--iconbar-w);
      flex: 0 0 var(--iconbar-w);
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 12px 0;
      gap: 6px;
      background: var(--sidebar);
      border-right: 1px solid var(--border);
    }
    .icon-btn {
      width: 40px; height: 40px;
      display: flex; align-items: center; justify-content: center;
      border: none; border-radius: 11px;
      background: transparent;
      color: var(--muted);
      font-size: 19px;
      cursor: pointer;
      transition: background 0.15s, color 0.15s;
    }
    .icon-btn:hover { background: var(--surface-2); color: var(--text); }
    .icon-btn.active {
      background: var(--accent-soft);
      color: var(--accent-strong);
    }
    /* Hover tooltip pill to the right of each iconbar button */
    .icon-btn { position: relative; }
    .icon-btn[data-tip]::after {
      content: attr(data-tip);
      position: absolute;
      left: calc(100% + 10px);
      top: 50%;
      transform: translateY(-50%);
      padding: 3px 9px;
      background: var(--surface);
      color: var(--text);
      border: 1px solid var(--border-strong);
      border-radius: 999px;
      box-shadow: var(--shadow);
      font-size: 0.62em;
      font-weight: 600;
      letter-spacing: 0.03em;
      white-space: nowrap;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.16s ease;
      z-index: 90;
    }
    .icon-btn[data-tip]:hover::after { opacity: 1; transition-delay: 0.18s; }
    #iconbar .iconbar-bottom { margin-top: auto; }

    /* Panel (left of main, same width for every view) */
    #panel {
      width: var(--panel-w);
      flex: 0 0 var(--panel-w);
      display: flex;
      flex-direction: column;
      background: var(--sidebar);
      border-right: 1px solid var(--border);
      min-width: 0;
    }
    .panel-head {
      display: flex; align-items: center; justify-content: space-between;
      padding: 12px 16px;
    }
    .panel-title {
      font-size: 11px; font-weight: 600; letter-spacing: 0.1em;
      text-transform: uppercase; color: var(--muted);
    }
    .panel-actions { display: flex; gap: 4px; }
    .plus-btn {
      width: 30px; height: 30px;
      border: none; border-radius: 9px;
      background: transparent;
      color: var(--muted);
      font-size: 18px; line-height: 1;
      cursor: pointer;
    }
    .plus-btn:hover { background: var(--surface-2); color: var(--accent-strong); }

    /* Global scrollbar theming: every scrollable surface (dropdowns, chips
       rows, queue feeds, textareas, …) uses the theme scroll thumb, never
       the native light scrollbar. */
    * { scrollbar-width: thin; scrollbar-color: var(--scroll-thumb) transparent; }
    *::-webkit-scrollbar { width: 8px; height: 8px; }
    *::-webkit-scrollbar-track { background: transparent; }
    *::-webkit-scrollbar-thumb { background: var(--scroll-thumb); border-radius: 4px; }
    *::-webkit-scrollbar-corner { background: transparent; }
    *::-webkit-scrollbar-button { display: none; }

    .panel-body { flex: 1; overflow-y: auto; padding: 4px 8px 12px; }
    .panel-body::-webkit-scrollbar, .chat-scroll::-webkit-scrollbar { width: 8px; }
    .panel-body::-webkit-scrollbar-track, .chat-scroll::-webkit-scrollbar-track { background: transparent; }
    .panel-body::-webkit-scrollbar-thumb, .chat-scroll::-webkit-scrollbar-thumb {
      background: var(--scroll-thumb); border-radius: 4px;
    }

    /* Main */
    #main { flex: 1; min-width: 0; min-height: 0; display: flex; flex-direction: column; overflow: hidden; }

    /* ─── Logs view ───────────────────────────────────────────── */
    .logs-view {
      flex: 1; min-width: 0; min-height: 0;
      display: flex; flex-direction: column;
      padding: 18px;
      box-sizing: border-box;
      overflow: hidden;
    }
    .logs-box {
      flex: 1; min-height: 0;
      display: flex; flex-direction: column;
      box-sizing: border-box;
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      overflow: hidden;
    }
    .logs-head {
      display: flex; align-items: center; justify-content: space-between;
      padding: 10px 16px;
      border-bottom: 1px solid var(--border);
      flex-shrink: 0;
    }
    .logs-title { font-weight: 650; font-size: 0.98em; }
    .logs-meta { font-size: 0.78em; color: var(--muted); }
    .logs-lines {
      flex: 1; min-height: 0;
      overflow-y: auto;
      padding: 8px 14px 16px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.82em;
      line-height: 1.55;
    }
    .log-line {
      display: flex; align-items: baseline; gap: 10px;
      padding: 1px 0;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .log-line .log-time { flex: 0 0 auto; color: var(--muted); font-variant-numeric: tabular-nums; }
    .log-line .log-lvl { flex: 0 0 auto; width: 44px; text-transform: uppercase; font-size: 0.8em; opacity: 0.85; }
    .log-line .log-msg { color: var(--text); }
    .log-line.lvl-info .log-lvl { color: var(--muted); }
    .log-line.lvl-warn .log-lvl { color: var(--warning); }
    .log-line.lvl-err .log-lvl { color: var(--danger); }
    .log-line.lvl-debug .log-lvl { color: var(--muted); font-style: italic; }

    /* Logs panel */
    .log-stats { display: flex; gap: 12px; margin: 2px 6px 10px; }
    .log-stat { display: inline-flex; align-items: center; gap: 6px; font-size: 0.85em; color: var(--text); font-variant-numeric: tabular-nums; }
    .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
    .dot-info { background: var(--muted); }
    .dot-warn { background: var(--warning); }
    .dot-err { background: var(--danger); }
    .log-chips { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 6px 12px; }
    .chip-btn {
      border: 1px solid var(--border); background: var(--surface-2);
      color: var(--muted); font-size: 0.8em; padding: 4px 12px;
      border-radius: 999px; cursor: pointer; transition: all 0.15s;
    }
    .chip-btn:hover { color: var(--text); border-color: var(--accent-border); }
    .chip-btn.active { background: var(--accent-soft); color: var(--accent-strong); border-color: var(--accent-border); }
    .log-panel-note { font-size: 0.8em; color: var(--muted); line-height: 1.5; margin: 4px 6px 0; }

    /* ─── Chat list rows ──────────────────────────────────────── */
    .sess-group { margin: 2px 0 4px; }
    .sess-group-head {
      display: flex; align-items: center; gap: 6px; width: 100%;
      padding: 6px 8px;
      background: transparent; border: none;
      color: var(--muted);
      font-size: 11px; font-weight: 600;
      letter-spacing: 0.06em; text-transform: uppercase;
      cursor: pointer; border-radius: 8px; text-align: left;
    }
    .sess-group-head:hover { color: var(--text); background: var(--surface-2); }
    .sess-group-head:focus-visible { outline: 1px solid var(--accent-border); }
    .sess-caret { display: inline-flex; align-items: center; opacity: 0.7; transition: transform 0.15s ease; }
    .sess-caret svg { width: 10px; height: 10px; }
    .sess-group-head .sess-group-title { flex: 0 0 auto; }
    .sess-group-count { margin-left: auto; opacity: 0.55; font-weight: 500; }
    /* Collapsed buckets hide their rows; the caret rotates from down to right. */
    .sess-group.collapsed .sess-caret { transform: rotate(-90deg); }
    .sess-group.collapsed .sess-group-rows { display: none; }
    .sess-group-rows { display: flex; flex-direction: column; }
    .rel-time { white-space: nowrap; font-variant-numeric: tabular-nums; }
    .sess-row {
      display: flex; align-items: stretch; gap: 2px;
      border-radius: 8px;
      margin-bottom: 2px;
      position: relative;
    }
    .sess-row:hover { background: var(--hover-bg); }
    .sess-row.active { background: var(--accent-soft); }
    .sess-row.active::before {
      content: ""; position: absolute; left: 2px; top: 8px; bottom: 8px;
      width: 2px; border-radius: 999px; background: var(--accent-strong); opacity: 0.55;
    }
    .sess-open {
      flex: 1; min-width: 0;
      display: flex; flex-direction: column; gap: 2px;
      text-align: left;
      background: transparent; border: none;
      padding: 8px 8px;
      cursor: pointer;
      border-radius: 8px;
      color: var(--muted);
      font-size: 13px;
    }
    .sess-row.active .sess-open { color: var(--text); }
    .sess-title { font-size: 13px; font-weight: 550; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sess-meta { font-size: 10.5px; color: var(--muted); display: flex; gap: 6px; opacity: 0.85; }
    .row-actions { display: flex; flex-direction: column; justify-content: center; gap: 2px; padding-right: 4px; }
    .icon-mini {
      width: 24px; height: 24px;
      display: flex; align-items: center; justify-content: center;
      border: none; border-radius: 7px;
      background: transparent; color: var(--muted);
      font-size: 13px; cursor: pointer;
    }
    .icon-mini:hover { background: var(--surface); color: var(--text); }
    .icon-mini.booked { color: var(--accent-strong); }
    .icon-mini.danger:hover { color: var(--danger); background: var(--danger-soft); }
    .sess-confirm {
      border: 1px solid var(--danger); color: var(--danger);
      background: var(--danger-soft); border-radius: 7px;
      font-size: 0.72em; padding: 2px 5px; cursor: pointer;
      font-weight: 600;
    }
    .empty-hint { color: var(--muted); font-size: 0.85em; padding: 12px 10px; }

    /* Filter (Hermes sidebar-search look) */
    .filter-bar { position: relative; padding: 8px 12px; }
    .filter-ico {
      position: absolute; left: 21px; top: 50%; transform: translateY(-50%);
      display: inline-flex; color: var(--muted); pointer-events: none; opacity: 0.8;
    }
    .filter-ico svg { width: 13px; height: 13px; }
    .filter-bar input {
      width: 100%;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--text);
      padding: 7px 10px 7px 32px;
      font-size: 13px;
      outline: none;
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .filter-bar input::placeholder { color: var(--muted); opacity: 0.7; }
    .filter-bar input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }

    /* ─── Chat categories / filters ──────────────────────────── */
    .cat-bar { display: flex; flex-wrap: wrap; gap: 6px; padding: 0 12px 6px; }
    .cat-chip {
      display: inline-flex; align-items: center; gap: 6px;
      border: 1px solid var(--border-subtle); background: var(--input-bg);
      color: var(--muted); border-radius: 999px;
      padding: 3px 9px; font-size: 11px; cursor: pointer;
      transition: background 0.15s, border-color 0.15s, color 0.15s;
    }
    .cat-chip:hover { background: var(--hover-bg); color: var(--text); }
    .cat-chip.active { background: var(--accent-soft); border-color: var(--accent-border); color: var(--accent-strong); }
    .cat-chip-btn {
      display: inline-flex; align-items: center; gap: 6px;
      border: none; background: transparent; color: inherit;
      font-size: inherit; padding: 0; cursor: pointer;
    }
    .cat-chip .chip-x { margin-left: 1px; }
    .cat-chip.cat-add { font-weight: 650; color: var(--muted); min-width: 26px; justify-content: center; }
    .cat-chip.cat-add:hover { color: var(--accent-strong); }
    .cat-dot {
      width: 10px; height: 10px; border-radius: 50%;
      display: inline-block; flex: 0 0 10px;
    }
    .cat-rowdot { width: 9px; height: 9px; flex: 0 0 9px; }
    .chip-x {
      width: 16px; height: 16px; display: inline-flex; align-items: center; justify-content: center;
      border: none; background: transparent; color: var(--muted);
      font-size: 11px; cursor: pointer; border-radius: 50%;
    }
    .chip-x:hover { background: var(--danger-soft); color: var(--danger); }
    .arch-link {
      display: block; text-align: left; width: 100%;
      border: none; background: transparent; color: var(--muted);
      font-size: 0.78em; padding: 4px 14px 8px; cursor: pointer;
    }
    .arch-link:hover { color: var(--accent-strong); }
    .cat-add-form {
      background: var(--surface-2); border: 1px dashed var(--border-strong);
      border-radius: var(--radius-md); margin: 6px 12px 8px; padding: 9px 10px;
    }
    .cat-add-form input[type="text"] {
      width: 100%; background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-sm); color: var(--text);
      padding: 6px 9px; font-size: 0.88em; outline: none;
    }
    .cat-add-form input:focus { border-color: var(--accent-border); }
    .cat-swatches { display: flex; flex-wrap: wrap; gap: 6px; margin: 8px 0; }

    /* Right-click category menu (rename / colors / delete) */
    .ctx-backdrop { position: fixed; inset: 0; z-index: 460; background: transparent; }
    .ctx-menu {
      position: fixed; z-index: 470; min-width: 188px; padding: 6px;
      background: var(--surface-2); border: 1px solid var(--border-strong);
      border-radius: 10px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.38);
      display: flex; flex-direction: column; gap: 2px;
    }
    .ctx-item {
      display: flex; align-items: center; gap: 8px; width: 100%;
      padding: 7px 10px; border: 0; background: transparent;
      color: var(--text); border-radius: 7px; font-size: 0.9em;
      cursor: pointer; text-align: left;
    }
    .ctx-item:hover { background: var(--surface); }
    .ctx-danger { color: var(--danger); font-weight: 650; }
    .ctx-danger:hover { background: var(--danger-soft); }
    .ctx-divider { height: 1px; margin: 5px 2px; background: var(--border-strong); }
    .ctx-label {
      font-size: 0.72em; color: var(--muted); text-transform: uppercase;
      letter-spacing: 0.05em; padding: 2px 10px;
    }
    .ctx-swatch-row { display: flex; flex-wrap: wrap; gap: 6px; padding: 2px 10px 8px; }
    .menu-swatch {
      width: 20px; height: 20px; border-radius: 50%; padding: 0;
      border: 2px solid transparent; background-clip: padding-box; cursor: pointer;
    }
    .menu-swatch:hover { transform: scale(1.15); }
    .menu-swatch.sel { border-color: var(--text); }
    .ctx-rename { display: flex; gap: 6px; padding: 4px 6px 8px; }
    .ctx-rename input {
      flex: 1; background: var(--surface); color: var(--text);
      border: 1px solid var(--border-strong); border-radius: 7px;
      padding: 6px 8px; font-size: 0.9em; min-width: 0;
    }
    .ctx-rename input:focus { outline: none; border-color: var(--accent-border); }
    .cat-swatch {
      width: 22px; height: 22px; border-radius: 50%; border: 2px solid transparent; cursor: pointer;
    }
    .cat-swatch.sel { border-color: var(--text); box-shadow: 0 0 0 2px var(--surface); }
    .cat-add-actions { display: flex; gap: 8px; }
    .cat-add-actions .primary-btn, .cat-add-actions .ghost-btn {
      padding: 5px 12px; font-size: 0.82em; border-radius: var(--radius-sm);
    }
    .menu-left { display: flex; align-items: center; padding-right: 2px; }
    .menu-label {
      font-size: 0.7em; text-transform: uppercase; letter-spacing: 0.05em;
      color: var(--muted); padding: 7px 12px 3px;
    }
    .chat-menu button.menu-sel { color: var(--accent-strong); }
    .chat-menu button > .cat-dot + span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

    /* ─── Skill rows / toggles ────────────────────────────────── */
    .skill-row {
      display: flex; align-items: center; gap: 7px;
      padding: 3px 8px 3px 10px;
      border-radius: var(--radius-md);
      cursor: pointer;
    }
    .skill-row:hover { background: var(--surface-2); }
    .skill-row.active { background: var(--accent-soft); }
    .skill-group { margin-bottom: 4px; }
    .skill-cat-head {
      display: flex; align-items: center; gap: 6px; width: 100%;
      padding: 3px 8px; background: transparent; border: none;
      color: var(--text); font-size: 0.74em; font-weight: 700;
      letter-spacing: 0.05em; text-transform: uppercase;
      cursor: pointer; border-radius: 8px; text-align: left;
    }
    .skill-cat-head:hover { background: var(--surface-2); }
    .skill-cat-caret { display: inline-flex; opacity: 0.7; transition: transform 0.15s ease; }
    .skill-cat-caret svg { width: 11px; height: 11px; }
    .skill-group.collapsed .skill-cat-caret { transform: rotate(-90deg); }
    .skill-group.collapsed .skill-cat-rows { display: none; }
    .skill-cat-count { opacity: 0.55; font-weight: 600; }
    .skill-cat-rows { display: flex; flex-direction: column; }
    .skill-row .skill-open { flex: 1; min-width: 0; flex-direction: column; align-items: flex-start; gap: 0; line-height: 1.25; padding: 0; }
    .skill-row .sk-name { flex: none; width: 100%; font-size: 0.93em; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .skill-row .sk-desc { width: 100%; font-size: 0.72em; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .skill-row.disabled .sk-name { color: var(--muted); }
    .skill-row.disabled .sk-desc { opacity: 0.6; }
    .skill-row.disabled .skill-open { cursor: default; }
    .switch {
      position: relative; width: 34px; height: 20px; flex: 0 0 34px;
    }
    .switch input { opacity: 0; width: 0; height: 0; }
    .switch .track {
      position: absolute; inset: 0;
      background: var(--border-strong);
      border-radius: 20px;
      transition: background 0.18s;
    }
    .switch .knob {
      position: absolute; top: 2px; left: 2px;
      width: 16px; height: 16px; border-radius: 50%;
      background: var(--surface);
      transition: transform 0.18s;
      box-shadow: 0 1px 2px rgba(0,0,0,0.25);
    }
    .switch input:checked + .track { background: var(--accent); }
    .switch input:checked + .track + .knob { transform: translateX(14px); }
    /* Compact switches inside skill rows */
    .skill-row .switch { width: 26px; height: 16px; flex: 0 0 26px; }
    .skill-row .switch .track { border-radius: 16px; }
    .skill-row .switch .knob { top: 2px; left: 2px; width: 12px; height: 12px; }
    .skill-row .switch input:checked + .track + .knob { transform: translateX(10px); }

    /* ─── Profile / tool / workspace rows ─────────────────────── */
    .list-row {
      display: flex; align-items: center; gap: 8px;
      padding: 9px 8px 9px 10px;
      border-radius: var(--radius-md);
      cursor: pointer;
    }
    .list-row:hover { background: var(--surface-2); }
    .list-row.active { background: var(--accent-soft); }
    .list-row .lr-name { flex: 1; min-width: 0; font-size: 0.93em; font-weight: 550; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .list-row .lr-sub { font-size: 0.78em; color: var(--muted); }
    .tool-group { font-size: 0.72em; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; padding: 12px 10px 4px; }

    /* ─── Main content ────────────────────────────────────────── */
    .main-view { flex: 1; display: flex; flex-direction: column; min-height: 0; padding: 22px clamp(20px, 7vw, 88px) 12px; }
    .main-scroll { flex: 1; overflow-y: auto; }
    .main-scroll::-webkit-scrollbar { width: 8px; }
    .main-scroll::-webkit-scrollbar-track { background: transparent; }
    .main-scroll::-webkit-scrollbar-thumb { background: var(--scroll-thumb); border-radius: 4px; }
    .detail-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: 18px 20px;
      box-shadow: var(--shadow);
    }
    .detail-title { font-size: 1.3em; font-weight: 700; margin: 0 0 4px; }
    .detail-sub { color: var(--muted); font-size: 0.9em; margin-bottom: 14px; }
    .detail-body { font-size: 0.95em; line-height: 1.55; color: var(--text); }
    .detail-body p { margin: 0 0 0.7em; }
    .detail-body h1, .detail-body h2, .detail-body h3 { margin: 0.9em 0 0.4em; }
    .detail-body pre, .detail-body code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .detail-body pre {
      background: var(--code-bg); border-radius: var(--radius-sm);
      padding: 10px 12px; overflow-x: auto; font-size: 0.85em;
    }
    .detail-body code { background: var(--code-bg); padding: 1px 5px; border-radius: 4px; font-size: 0.88em; }
    .detail-body pre code { background: none; padding: 0; }
    .detail-body a { color: var(--link); }
    .detail-body blockquote { border-left: 3px solid var(--border-strong); margin: 0.6em 0; padding: 2px 12px; color: var(--muted); }
    .detail-body table { border-collapse: collapse; margin: 0.6em 0; }
    .detail-body th, .detail-body td { border: 1px solid var(--border); padding: 5px 10px; }
    .detail-body ul, .detail-body ol { padding-left: 22px; }
    .kv { display: flex; gap: 8px; padding: 5px 0; font-size: 0.9em; border-bottom: 1px dashed var(--border); }
    .kv:last-child { border-bottom: none; }
    .kv .k { color: var(--muted); flex: 0 0 110px; }
    .kv .v { color: var(--text); word-break: break-word; }

    .form-grid { display: flex; flex-direction: column; gap: 10px; margin: 14px 0; }
    .form-grid label { font-size: 0.8em; color: var(--muted); font-weight: 550; display: block; margin-bottom: 3px; }
    .form-grid input, .form-grid select, .form-grid textarea {
      width: 100%;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      color: var(--text);
      padding: 8px 10px;
      font-size: 0.92em;
      outline: none;
      font-family: inherit;
    }
    .form-grid input:focus, .form-grid select:focus, .form-grid textarea:focus { border-color: var(--accent-border); }
    .form-grid textarea { min-height: 90px; resize: vertical; font-family: ui-monospace, Menlo, monospace; font-size: 0.85em; }
    .primary-btn {
      background: var(--accent);
      color: #fff;
      border: none;
      border-radius: var(--radius-sm);
      padding: 8px 16px;
      font-size: 0.92em;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }
    .primary-btn:hover { background: var(--accent-strong); }
    .ghost-btn {
      background: transparent;
      color: var(--muted);
      border: 1px solid var(--border-strong);
      border-radius: var(--radius-sm);
      padding: 8px 16px;
      font-size: 0.92em;
      cursor: pointer;
    }
    .ghost-btn:hover { color: var(--text); border-color: var(--muted); }
    .danger-btn {
      background: transparent; color: var(--danger);
      border: 1px solid var(--danger); border-radius: var(--radius-sm);
      padding: 8px 16px; font-size: 0.92em; cursor: pointer;
    }
    .danger-btn:hover { background: var(--danger-soft); }
    .accent-btn {
      background: transparent; color: var(--accent-strong);
      border: 1px solid var(--accent-border); border-radius: var(--radius-sm);
      padding: 8px 16px; font-size: 0.92em; cursor: pointer;
    }
    .row-actions-main { display: flex; gap: 8px; margin-top: 12px; }

    /* ─── Settings sections ───────────────────────────────────── */
    .settings-wrap { max-width: 720px; margin: 0 auto; }
    .set-section { margin-bottom: 22px; }
    .set-section > h2 {
      font-size: 1.05em; font-weight: 700; margin: 0 0 10px;
      padding-bottom: 6px; border-bottom: 1px solid var(--border);
    }
    .set-row { display: flex; align-items: center; gap: 14px; padding: 7px 0; }
    .set-row .set-label { flex: 1; font-size: 0.92em; }
    .set-row .set-label small { display: block; color: var(--muted); font-size: 0.8em; margin-top: 1px; }
    .set-row select, .set-row input[type="text"], .set-row input[type="password"] {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-sm); color: var(--text);
      padding: 6px 10px; font-size: 0.9em; outline: none;
    }
    .set-row select:focus, .set-row input:focus { border-color: var(--accent-border); }
    .set-hint { color: var(--muted); font-size: 0.8em; }
    .side-tab-chips { display: flex; flex-wrap: wrap; gap: 8px; }
    .side-tab-chip {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 7px 14px; border-radius: 999px;
      border: 1px solid var(--border-strong);
      color: var(--muted); background: transparent;
      cursor: pointer; font-size: 0.85em; user-select: none;
      transition: border-color 0.15s, color 0.15s, background 0.15s, opacity 0.15s;
      max-width: 100%;
    }
    .side-tab-chip:hover { border-color: var(--border); color: var(--text); }
    .side-tab-chip input { display: none; }
    /* Server renders the .on class from state; no :has() dependency. */
    .side-tab-chip.on {
      color: var(--accent); border-color: var(--accent);
      background: var(--accent-soft);
    }
    .side-tab-chip.drag-src { opacity: 0.55; }
    .side-tab-chip.drag-over { border-color: var(--accent-border); }
    .set-row .aux-right { display: flex; gap: 8px; flex-shrink: 0; }
    .aux-editing { padding: 8px 10px; border: 1px solid var(--border); border-radius: var(--radius-sm); margin: 6px 0; background: var(--surface-2); }
    .aux-fields { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 8px 10px; }
    .aux-field { display: flex; flex-direction: column; gap: 3px; font-size: 0.78em; color: var(--muted); }
    .aux-field input {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-sm); color: var(--text);
      padding: 5px 9px; font-size: 0.92em; outline: none; width: 100%; box-sizing: border-box;
    }
    .aux-field input:focus { border-color: var(--accent-border); }
    .aux-actions { display: flex; gap: 8px; margin-top: 10px; }
    .ins-range-wrap { margin-top: 4px; }
    .ins-range-label { display: block; font-size: 0.78em; color: var(--muted); margin-bottom: 4px; }
    .ins-range-wrap select {
      width: 100%; box-sizing: border-box; background: var(--surface);
      border: 1px solid var(--border); border-radius: var(--radius-sm);
      color: var(--text); padding: 7px 10px; font-size: 0.9em; outline: none;
    }
    .ins-bubbles { display: flex; gap: 12px; margin-bottom: 16px; }
    .ins-bubble {
      flex: 1; border-radius: 16px; padding: 16px 18px;
      background: var(--surface-2); border: 1px solid var(--border);
      display: flex; flex-direction: column; align-items: flex-start;
    }
    .ins-bubble-icon { margin-bottom: 10px; }
    .ins-bubble-icon svg { display: block; }
    .ins-bubble-value { font-size: 1.7em; font-weight: 700; line-height: 1.1; }
    .ins-bubble-label { color: var(--muted); font-size: 0.85em; margin-top: 4px; }
    .ins-table-wrap { overflow-x: auto; }
    .ins-table { width: 100%; border-collapse: collapse; font-size: 0.92em; }
    .ins-table th {
      text-align: left; font-size: 0.78em; text-transform: uppercase;
      letter-spacing: 0.04em; color: var(--muted);
      padding: 8px 10px; border-bottom: 1px solid var(--border);
    }
    .ins-table td { padding: 8px 10px; border-bottom: 1px solid var(--border); }
    .ins-table tr:last-child td { border-bottom: none; }
    .ins-table tbody tr:hover td { background: var(--surface-2); }
    .ins-t-name { font-weight: 600; }
    .ins-stats { display: flex; gap: 12px; }
    .ins-stat-box {
      flex: 1; border-radius: 14px; padding: 16px 18px;
      background: var(--surface-2); border: 1px solid var(--border);
      display: flex; flex-direction: column; align-items: flex-start;
    }
    .ins-stat-icon { margin-bottom: 12px; }
    .ins-stat-icon svg { display: block; }
    .ins-stat-value { font-size: 1.5em; font-weight: 700; line-height: 1.1; }
    .ins-stat-label { color: var(--muted); font-size: 0.85em; margin-top: 4px; }
    .ins-range-hint { color: var(--muted); font-size: 0.72em; font-weight: 400; }
    .ins-chart-wrap { padding-top: 4px; }
    .ins-chart {
      display: flex; align-items: flex-end; gap: 3px; height: 220px;
    }
    .ins-bar {
      flex: 1; min-width: 3px; background: var(--accent);
      border-radius: 4px 4px 0 0; transition: filter 0.15s;
    }
    .ins-bar:hover { filter: brightness(1.25); }
    .ins-xaxis { display: flex; margin-top: 7px; }
    .ins-xlabel { flex: 1; text-align: center; font-size: 0.72em; color: var(--muted); overflow: hidden; }
    .accent-swatches { display: flex; gap: 6px; }
    .swatch {
      width: 26px; height: 26px; border-radius: 50%;
      border: 2px solid var(--border); cursor: pointer;
      padding: 0;
    }
    .swatch.active { border-color: var(--text); box-shadow: 0 0 0 2px var(--surface), 0 0 0 4px var(--accent); }
    /* ─── Text size picker (Hermes-style cards) ─────────────────── */
    .fsz-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(96px, 1fr)); gap: 8px; }
    .font-size-pick-btn {
      border: 1px solid var(--border); border-radius: 10px; padding: 10px 8px;
      text-align: center; cursor: pointer; background: none;
      transition: all .15s; display: flex; flex-direction: column; gap: 6px;
      align-items: center; color: var(--text); font: inherit;
    }
    .font-size-pick-btn:hover { border-color: var(--accent-border); }
    .font-size-pick-btn .fsz-preview {
      height: 40px; width: 100%; border-radius: 6px; background: var(--surface);
      border: 1px solid var(--border); display: flex; align-items: center;
      justify-content: center; font-weight: 600; color: var(--muted);
      line-height: 1;
    }
    .font-size-pick-btn .fsz-label { font-size: 12px; font-weight: 500; }
    .font-size-pick-btn.active {
      border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent);
    }
    .font-size-pick-btn.active .fsz-preview { border-color: var(--accent-border); color: var(--text); }
    /* ─── Theme picker (Hermes-style cards) ────────────────────── */
    .thm-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(96px, 1fr)); gap: 8px; }
    .theme-pick-btn {
      border: 1px solid var(--border); border-radius: 10px; padding: 8px;
      text-align: center; cursor: pointer; background: none;
      transition: all .15s; display: flex; flex-direction: column; gap: 6px;
      align-items: center; color: var(--text); font: inherit;
    }
    .theme-pick-btn:hover { border-color: var(--accent-border); }
    .theme-pick-btn .thm-preview {
      height: 44px; width: 100%; border-radius: 8px; display: flex;
      align-items: center; justify-content: center; color: #A0A6AD;
    }
    .theme-pick-btn .thm-ic { display: inline-flex; filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.3)); }
    .theme-pick-btn .thm-label { font-size: 12px; font-weight: 500; }
    .theme-pick-btn.active {
      border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent);
    }
    .theme-pick-btn.active .thm-label { color: var(--accent); }
    /* ─── Text size scaling: content surfaces only ──────────────── */
    #app[data-size="sm"] .msg-body { font-size: 12.5px; }
    #app[data-size="lg"] .msg-body { font-size: 16px; }
    #app[data-size="xl"] .msg-body { font-size: 18px; }
    #app[data-size="sm"] .sess-title { font-size: 11.5px; }
    #app[data-size="lg"] .sess-title { font-size: 15px; }
    #app[data-size="xl"] .sess-title { font-size: 17px; }
    #app[data-size="sm"] .sess-meta { font-size: 10px; }
    #app[data-size="lg"] .sess-meta { font-size: 12.5px; }
    #app[data-size="xl"] .sess-meta { font-size: 14px; }
    #app[data-size="sm"] .ws-name { font-size: 12.5px; }
    #app[data-size="lg"] .ws-name { font-size: 16px; }
    #app[data-size="xl"] .ws-name { font-size: 18px; }
    #app[data-size="sm"] .ws-path { font-size: 10.5px; }
    #app[data-size="lg"] .ws-path { font-size: 13px; }
    #app[data-size="xl"] .ws-path { font-size: 14.5px; }
    #app[data-size="sm"] .mem-title { font-size: 12.5px; }
    #app[data-size="lg"] .mem-title { font-size: 16px; }
    #app[data-size="xl"] .mem-title { font-size: 18px; }
    #app[data-size="sm"] .mem-sub { font-size: 10.5px; }
    #app[data-size="lg"] .mem-sub { font-size: 13.5px; }
    #app[data-size="xl"] .mem-sub { font-size: 15px; }
    #app[data-size="sm"] .mem-textarea { font-size: 12.5px; }
    #app[data-size="lg"] .mem-textarea { font-size: 15.5px; }
    #app[data-size="xl"] .mem-textarea { font-size: 17.5px; }
    .mc-row {
      display: flex; align-items: center; gap: 8px;
      border: 1px solid var(--border); border-radius: var(--radius-md);
      padding: 8px 10px; margin-bottom: 6px; background: var(--surface);
    }
    .mc-row .mc-name { flex: 1; min-width: 0; font-weight: 600; font-size: 0.93em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mc-row .mc-model { color: var(--muted); font-size: 0.82em; max-width: 40%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mc-badge { font-size: 0.68em; padding: 2px 7px; border-radius: 20px; background: var(--accent-soft); color: var(--accent-strong); font-weight: 600; }

    /* ─── Chat main (Hermes look: centered column, rails, bubbles) ── */
    .chat-main { flex: 1; display: flex; flex-direction: column; min-height: 0; position: relative; }
    .chat-header {
      display: flex; align-items: center; justify-content: space-between;
      padding: 12px 20px;
      border-bottom: 1px solid var(--border);
      background: var(--sidebar);
    }
    .chat-title { font-weight: 600; font-size: 15px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; letter-spacing: 0.01em; }
    .chat-meta { font-size: 12px; color: var(--muted); margin-top: 2px; }

    .chat-scroll-wrap { position: relative; flex: 1; min-height: 0; display: flex; flex-direction: column; }
    .chat-scroll { flex: 1; height: 100%; overflow-y: auto; padding: 0 20px; scrollbar-gutter: stable both-edges; }
    /* Streaming turns re-render #main per token; the gutter must never be
       overridden or lost mid-response (padding is only ever set here). */
    #main .chat-scroll { padding: 0 20px !important; }
    .chat-scroll::-webkit-scrollbar { width: 8px; }
    .chat-scroll::-webkit-scrollbar-track { background: transparent; }
    .chat-scroll::-webkit-scrollbar-thumb { background: var(--scroll-thumb); border-radius: 4px; }

    /* Conversation column: same centered width as the composer box */
    .chat-inner {
      margin: 0 auto; width: 100%;
      max-width: clamp(780px, 60vw, 1100px);
      padding: 20px 0 32px;
      display: flex; flex-direction: column;
    }

    .msg { display: flex; padding: 10px 0; }
    .msg.user { justify-content: flex-end; }
    .msg.assistant { justify-content: flex-start; }
    /* Hermes parity: assistant responses are plain formatted text (no
       bubble card); user messages keep a subtue tinted bubble. */
    .msg-body {
      max-width: 680px;
      width: 100%;
      line-height: 1.75;
      font-size: 14px;
      overflow-wrap: anywhere;
      color: var(--text);
    }
    .msg-body.interim { opacity: 0.85; }
    .msg.user .msg-body { width: fit-content; max-width: 60%; }
    .msg.user .user-bubble {
      width: fit-content;
      max-width: 60%;
      background: var(--user-bubble);
      border: 1px solid var(--accent-border);
      border-radius: 12px;
      padding: 12px 16px;
      white-space: pre-wrap;
    }
    .msg.assistant .msg-body { text-align: left; max-width: 100%; }
    /* Role header: avatar rail + name, Hermes msg-role style */
    .msg-meta {
      font-size: 12px; font-weight: 500; color: var(--muted);
      margin-bottom: 8px; display: flex; align-items: center; gap: 8px;
    }
    .msg.assistant .msg-meta { text-align: left; }
    .role-icon {
      width: 22px; height: 22px; border-radius: 50%;
      display: inline-flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }
    .role-icon.assistant { background: var(--accent-strong); color: #fff; }
    .role-icon svg { width: 11px; height: 11px; }
    /* Hermes-parity chips: TPS pill in the role header, token usage foot */
    .msg-tps-inline {
      display: inline-flex; align-items: center;
      margin-left: 6px; padding: 1px 6px;
      border: 1px solid var(--border);
      border-radius: 999px;
      color: var(--muted);
      background: var(--surface);
      font-size: 10.5px; font-weight: 500;
      vertical-align: 1px; line-height: 1.4;
    }
    .msg-usage-inline {
      font-size: 11px; color: var(--muted); opacity: .7;
      font-variant-numeric: tabular-nums;
    }
    .steer-tag {
      display: inline-block; margin-left: 6px; padding: 0 6px;
      border-radius: 999px; font-size: 9.5px; font-weight: 600;
      letter-spacing: .04em; text-transform: uppercase;
      color: var(--accent); border: 1px solid var(--accent);
      vertical-align: 1px;
    }
    .msg-foot-inline { margin-top: 6px; }

    /* Message body markdown scaling (Hermes msg-body rules) */
    .msg-body p { margin: 0 0 10px; }
    .msg-body p:last-child { margin-bottom: 0; }
    .msg-body ul, .msg-body ol { margin: 6px 0 10px 20px; }
    .msg-body li { margin-bottom: 3px; }
    .msg-body h1, .msg-body h2, .msg-body h3, .msg-body h4, .msg-body h5, .msg-body h6 { font-weight: 700; line-height: 1.3; color: var(--text); }
    .msg-body h1 { font-size: 24px; margin: 24px 0 12px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
    .msg-body h2 { font-size: 20px; margin: 22px 0 10px; border-bottom: 1px solid var(--border); padding-bottom: 4px; }
    .msg-body h3 { font-size: 17px; margin: 20px 0 8px; }
    .msg-body h4 { font-size: 15px; margin: 18px 0 8px; }
    .msg-body h1:first-child, .msg-body h2:first-child, .msg-body h3:first-child, .msg-body h4:first-child { margin-top: 0; }
    .msg-body code { font-family: "SF Mono", "Fira Code", ui-monospace, monospace; font-size: 12.5px; background: var(--code-inline-bg); padding: 1px 5px; border-radius: 4px; color: var(--code-text); }
    .msg-body pre { background: var(--code-bg); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; overflow-x: auto; margin: 10px 0; }
    .msg-body pre code { background: none; padding: 0; border-radius: 0; color: var(--code-text); font-size: 13px; line-height: 1.6; }
    .msg-body table { font-size: 12px; border-collapse: collapse; }
    .msg-body th, .msg-body td { border: 1px solid var(--border); padding: 6px 10px; }

    /* ─── Supporting activity rows (activity display modes) ───── */
    .thinking-row, .tool-card, .worklog-summary {
      display: block;
      max-width: 86%;
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      background: var(--surface-2);
      margin: 8px 0;
    }
    .thinking-row summary, .tool-card summary, .worklog-summary summary {
      cursor: pointer;
      list-style: none;
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      font-size: 0.9em;
      color: var(--muted);
      user-select: none;
    }
    .thinking-row summary::-webkit-details-marker,
    .tool-card summary::-webkit-details-marker,
    .worklog-summary summary::-webkit-details-marker { display: none; }
    .thinking-row summary svg, .tool-card summary svg, .worklog-summary summary svg { flex: 0 0 auto; opacity: 0.8; }
    /* --- Turn dropdown (Hermes parity: "Processed Xm Ys" worklog) --- */
    .assistant-turn { display: block; }
    .assistant-turn > .msg-meta { margin: 14px 0 2px; }
    .turn-worklog {
      /* A plain show/hide control, not a boxed section: the activity rows
         it reveals keep their own (pre-feature) card styling. */
      max-width: 100%;
      margin: 2px 0 8px;
    }
    .turn-worklog > summary {
      cursor: pointer;
      list-style: none;
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 2px 0;
      font-size: 0.9em;
      color: var(--muted);
      user-select: none;
    }
    .turn-worklog > summary::-webkit-details-marker { display: none; }
    .turn-worklog > summary:hover { color: var(--text); }
    .turn-worklog .worklog-summary, .turn-worklog .thinking-row, .turn-worklog .tool-card {
      margin-left: 0;
    }
    .tw-dot {
      flex: 0 0 auto;
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: var(--muted);
      opacity: 0.7;
    }
    .tw-label { flex: 0 1 auto; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .tw-spacer { flex: 1 1 auto; }
    .tw-caret { flex: 0 0 auto; display: inline-flex; opacity: 0.8; transition: transform 0.15s ease; }
    .turn-worklog[open] .tw-caret { transform: rotate(90deg); }
    .tw-body { padding: 0; }
    .turn-worklog .worklog-summary { max-width: 100%; margin: 6px 0; }
    .tw-copy {
      flex: 0 0 auto;
      display: inline-flex;
      align-items: center;
      background: none;
      border: none;
      padding: 2px;
      border-radius: 6px;
      color: var(--muted);
      cursor: pointer;
      opacity: 0.8;
    }
    .tw-copy:hover { color: var(--text); background: var(--surface-1); opacity: 1; }
    .tw-copy.copied { color: var(--text); opacity: 1; }
    .thinking-row .tc-detail, .worklog-summary .wl-detail {
      padding: 4px 14px 10px;
      max-height: 320px;
      overflow: auto;
    }
    .tool-card summary .tc-name { font-weight: 650; color: var(--text); }
    .tool-card summary .tc-arg {
      flex: 1;
      min-width: 0;
      color: var(--muted);
      font-size: 0.85em;
      font-family: var(--font-mono);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .tc-detail {
      padding: 2px 12px 12px;
      font-size: 0.85em;
      color: var(--muted);
      white-space: pre-wrap;
      word-break: break-word;
    }
    .tc-label {
      font-size: 0.72em;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--muted);
      margin: 8px 0 4px;
    }
    .tc-block {
      margin: 0 0 4px;
      padding: 8px 10px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      font-size: 0.82em;
      font-family: var(--font-mono);
      white-space: pre-wrap;
      word-break: break-word;
    }
    .wl-detail { padding: 0 12px 10px; }
    .bubble.interim {
      background: transparent;
      border: none;
      padding: 4px 0;
      margin: 4px 0;
      color: var(--muted);
      max-width: 86%;
    }

    /* ─── Activity display segmented choice (Settings) ────────── */
    .bubble-opts { display: flex; flex-wrap: wrap; gap: 8px; }
    .bubble-opt {
      border: 1.5px solid var(--border);
      background: var(--surface-2);
      color: var(--muted);
      border-radius: 999px;
      padding: 7px 16px;
      font-size: 0.88em;
      cursor: pointer;
      transition: all 0.15s;
    }
    .bubble-opt:hover { border-color: var(--accent-border); color: var(--text); }
    .bubble-opt.active {
      border-color: var(--accent-strong);
      color: var(--accent-strong);
      background: var(--accent-soft);
    }
    .md { font-size: 0.96em; line-height: 1.55; }
    .md p { margin: 0 0 0.7em; }
    .md pre, .md code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .md pre { background: var(--code-bg); border-radius: 8px; padding: 10px 12px; overflow-x: auto; font-size: 0.86em; }
    .md code { background: var(--code-bg); padding: 1px 5px; border-radius: 4px; font-size: 0.88em; }
    .md pre code { background: none; padding: 0; }
    .md a { color: var(--link); }
    .md blockquote { border-left: 3px solid var(--border-strong); margin: 0.6em 0; padding: 2px 12px; color: var(--muted); }
    .md blockquote blockquote { margin: 0.4em 0; }
    .md hr { border: none; border-top: 1px solid var(--border); margin: 1em 0; }
    .md s { opacity: 0.75; }
    .md li > input[type="checkbox"] { margin-right: 7px; vertical-align: middle; accent-color: var(--accent, #e8919b); }
    .md table { border-collapse: collapse; margin: 0.6em 0; font-size: 0.92em; }
    .md th, .md td { border: 1px solid var(--border); padding: 5px 10px; }
    .md thead th { background: var(--bg-subtle, var(--bg)); font-weight: 600; }
    .markdown-table-head { display: inline-flex; align-items: center; gap: 4px; }
    .markdown-table-sort { background: none; border: none; cursor: pointer; color: var(--muted); font-size: 0.8em; padding: 0 2px; }
    .markdown-table-sort:hover { color: var(--text); }
    .markdown-table-filter-row th { background: none; padding: 3px 8px; }
    .markdown-table-filter { width: 100%; box-sizing: border-box; background: var(--bg-subtle, var(--bg)); border: 1px solid var(--border); border-radius: 6px; color: var(--text); padding: 3px 8px; font-size: 0.88em; }
    .md ul, .md ol { padding-left: 22px; margin: 0.4em 0; }
    .md h1, .md h2, .md h3, .md h4 { margin: 0.9em 0 0.4em; }
    .md ul ul, .md ol ul, .md ul ol, .md ol ol { margin: 0.2em 0 0.2em 0; }
    equation-block { display: block; text-align: center; margin: 0.7em 0; overflow-x: auto; }
    equation-inline { display: inline; }

    details.thinking {
      margin: 4px 0 8px;
      border: 1px dashed var(--border-strong);
      border-radius: 8px;
      background: var(--surface-2);
      font-size: 0.88em;
    }
    details.thinking summary {
      cursor: pointer; padding: 6px 10px; color: var(--muted);
      font-size: 0.82em; user-select: none;
    }
    details.thinking .think-body { padding: 4px 12px 10px; color: var(--muted); white-space: pre-wrap; }

    /* ── Message hover footer: produced-at time + copy (Hermes parity) ── */
    .msg-foot { display: flex; align-items: center; gap: 8px; margin-top: 5px; opacity: 0; transition: opacity 0.15s; }
    .msg:hover .msg-foot { opacity: 1; }
    .msg-time { font-size: 0.72em; color: var(--muted); opacity: 0.9; }
    .msg-actions { display: inline-flex; align-items: center; gap: 2px; }
    .msg-action-btn { background: none; border: none; color: var(--muted); cursor: pointer; padding: 2px 5px; border-radius: 5px; display: inline-flex; align-items: center; transition: color 0.12s, background 0.12s; }
    .msg-action-btn:hover { color: var(--text); background: var(--surface-2); }
    .msg-action-btn svg { width: 12px; height: 12px; }
    .tool-chip {
      display: inline-flex; align-items: center; gap: 6px;
      margin: 3px 6px 3px 0;
      padding: 4px 10px;
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 20px;
      font-size: 0.8em;
      color: var(--muted);
      font-family: ui-monospace, Menlo, monospace;
    }
    .tool-chip .tc-name { color: var(--accent-strong); font-weight: 600; }
    .tool-pills { display: flex; flex-wrap: wrap; margin: 6px 0 2px; }
    /* Hermes parity: tool call rows are bubble-like pills. */
    .tool-card {
      display: block; max-width: 100%; margin: 6px 0;
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 12px;
      overflow: hidden;
    }
    .tool-card summary {
      background: transparent;
      border-radius: 12px;
    }
    /* Jump-to-latest circle button (Hermes .scroll-to-bottom-btn mirror). */
    .scroll-to-bottom-btn {
      position: absolute; right: 18px; bottom: 14px;
      width: 32px; height: 32px;
      border-radius: 50%;
      border: 1px solid var(--border);
      background: var(--code-bg);
      color: var(--muted);
      font-size: 15px; line-height: 1;
      cursor: pointer;
      display: flex; align-items: center; justify-content: center;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);
      z-index: 10;
      transition: color .12s, border-color .12s, background .12s, transform .12s;
    }
    .scroll-to-bottom-btn:hover {
      color: var(--text);
      border-color: var(--border-strong);
      background: var(--surface-2);
      transform: translateY(-1px);
    }
    .scroll-to-bottom-btn[hidden] { display: none; }
    .stream-cursor::after {
      content: "▍";
      animation: blink 1s steps(1) infinite;
      color: var(--accent);
    }
    @keyframes blink { 50% { opacity: 0; } }

    .live-status { font-size: 0.78em; color: var(--muted); margin: -8px 0 12px; display: flex; gap: 8px; align-items: center; }

    /* ─── Permission card (Hermes approval) ─────────────────────── */
    .perm-card {
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
      padding: 10px 12px;
      margin: 2px 0 10px;
      max-width: 720px;
    }
    .perm-head { display: flex; align-items: center; gap: 6px; margin-bottom: 6px; }
    .perm-ico { color: var(--warning, #E68A00); font-size: 13px; }
    .perm-title { font-weight: 600; font-size: 12.5px; color: var(--text); }
    .perm-cmd { margin: 4px 0 10px; }
    .perm-cmd code {
      display: block; padding: 6px 8px; border-radius: 6px;
      background: var(--bg); border: 1px solid var(--border);
      font-family: var(--font-mono); font-size: 12px; color: var(--text);
      word-break: break-all;
    }
    .perm-actions { display: flex; gap: 8px; justify-content: flex-end; }
    .perm-btn {
      border: 1px solid var(--border); border-radius: 999px;
      padding: 5px 14px; font-size: 12px; font-weight: 600;
      background: var(--surface); color: var(--text); cursor: pointer;
    }
    .perm-btn.allow { background: var(--accent); border-color: var(--accent); color: #fff; }
    .perm-btn.deny { background: transparent; color: var(--danger); border-color: var(--danger); }

    /* ── Composer flyout: Hermes-parity approval card ── */
    .composer-flyout { width: 100%; }
    .approval-card, .clarify-card { margin-bottom: 10px; animation: flyout-in .28s cubic-bezier(.32,.72,.16,1); }
    @keyframes flyout-in { from { transform: translateY(10px); opacity: 0; } to { transform: none; opacity: 1; } }
    .approval-inner {
      background: var(--surface);
      border: 1px solid var(--accent-border);
      border-radius: 14px;
      padding: 14px 16px;
      box-shadow: var(--shadow);
    }
    .approval-head, .clarify-head {
      display: flex; align-items: center; gap: 8px;
      margin-bottom: 10px;
      font-size: 13px; font-weight: 600;
    }
    .approval-head { color: var(--danger); }
    .clarify-head { color: var(--accent-strong); }
    .approval-ico, .clarify-ico { display: inline-flex; align-items: center; }
    .approval-collapse, .approval-dismiss, .clarify-collapse {
      margin-left: auto; display: inline-flex; align-items: center; justify-content: center;
      width: 24px; height: 24px;
      border: 1px solid var(--border-strong); border-radius: 999px;
      background: var(--surface); color: var(--muted);
      font: inherit; padding: 0; cursor: pointer;
    }
    .approval-collapse, .clarify-collapse { margin-left: 8px; }
    .approval-collapse:hover, .approval-dismiss:hover, .clarify-collapse:hover { color: var(--text); border-color: var(--accent-border); }
    .approval-desc { font-size: 12px; color: var(--muted); margin-bottom: 8px; line-height: 1.5; }
    .approval-cmd {
      background: var(--code-bg); border: 1px solid var(--border);
      border-radius: 8px; padding: 8px 12px;
      font-family: var(--font-mono, ui-monospace, "SF Mono", monospace);
      font-size: 12px; color: var(--text);
      white-space: pre-wrap; word-break: break-all;
      margin-bottom: 12px; max-height: 120px; overflow-y: auto;
    }
    .approval-btns { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
    .approval-btn {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 8px 14px; border-radius: 8px;
      font-size: 12px; font-weight: 600;
      border: 1px solid var(--border-strong);
      background: var(--surface-2); color: var(--text);
      cursor: pointer; transition: all .15s; white-space: nowrap;
    }
    .approval-btn:hover { background: var(--hover-bg); transform: translateY(-1px); }
    .approval-btn.once { border-color: var(--accent); color: var(--accent-strong); background: var(--accent-soft); }
    .approval-btn.once:hover { background: var(--accent-soft); }
    .approval-btn.session { border-color: var(--accent-border); color: var(--accent-strong); }
    .approval-btn.session:hover { background: var(--accent-soft); }
    .approval-btn.always { border-color: var(--border-strong); color: var(--text); }
    .approval-btn.deny { border-color: var(--danger); color: var(--danger); }
    .approval-btn.deny:hover { background: var(--danger-soft); }
    .approval-btn-label { line-height: 1; }
    .approval-yolo-row { margin-top: 10px; }
    .approval-btn.yolo {
      background: rgba(245, 158, 11, 0.12); border-color: rgba(245, 158, 11, 0.35);
      color: #f59e0b; width: 100%; justify-content: center;
    }
    .approval-btn.yolo:hover { background: rgba(245, 158, 11, 0.22); border-color: rgba(245, 158, 11, 0.55); color: #fbbf24; }
    .approval-btn svg, .approval-ico svg, .clarify-ico svg, .clarify-collapse svg, .approval-collapse svg, .approval-dismiss svg,
    .clarify-badge-svg { display: block; }

    /* ── Composer flyout: Hermes-parity clarification card ── */
    .clarify-inner {
      background: var(--surface);
      border: 1px solid var(--accent-border);
      border-radius: 12px;
      padding: 12px 14px;
      box-shadow: var(--shadow);
    }
    .clarify-countdown {
      min-width: 42px; text-align: right;
      color: var(--muted); font-weight: 700;
      font-variant-numeric: tabular-nums; letter-spacing: .01em;
    }
    .clarify-countdown.urgent { color: var(--danger); }
    .clarify-question { font-size: 14px; color: var(--text); line-height: 1.7; white-space: pre-wrap; margin-bottom: 12px; }
    .clarify-choices { display: flex; flex-direction: column; gap: 8px; margin-bottom: 12px; }
    .clarify-choice {
      display: flex; align-items: flex-start; gap: 10px; width: 100%;
      padding: 11px 14px; border-radius: 12px;
      font-size: 13px; font-weight: 600;
      border: 1px solid var(--accent-border);
      background: var(--accent-soft); color: var(--accent-strong);
      cursor: pointer; transition: all .15s;
      white-space: normal; text-align: left;
    }
    .clarify-choice:hover { background: var(--accent-soft); transform: translateY(-1px); }
    .clarify-choice-badge {
      display: inline-flex; align-items: center; justify-content: center;
      min-width: 24px; height: 24px; border-radius: 999px;
      background: var(--accent-soft); border: 1px solid var(--accent-border);
      color: var(--accent-strong); font-size: 11px; font-weight: 800; flex-shrink: 0; line-height: 1;
    }
    .clarify-choice-text { flex: 1; line-height: 1.45; min-width: 0; }
    .clarify-response { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-bottom: 4px; }
    .clarify-pill {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 8px 14px; border-radius: 12px;
      font-size: 12px; font-weight: 600;
      border: 1px solid var(--accent-border);
      background: var(--surface-2); color: var(--accent-strong);
      cursor: pointer;
    }
    .clarify-pill:hover { background: var(--accent-soft); }
    .clarify-free { display: flex; gap: 8px; flex: 1; min-width: 220px; align-items: center; }
    .clarify-input {
      flex: 1; min-width: 180px; padding: 10px 12px;
      border-radius: 8px; border: 1px solid var(--border-strong);
      background: var(--input-bg, var(--surface-2)); color: var(--text);
      font: inherit; outline: none; transition: all .15s;
    }
    .clarify-input:focus { border-color: var(--accent-border); box-shadow: 0 0 0 3px var(--accent-soft); }
    .clarify-submit {
      display: inline-flex; align-items: center; justify-content: center;
      min-width: 80px; padding: 10px 14px; border-radius: 8px;
      border: 1px solid var(--accent-border);
      background: var(--accent-soft); color: var(--accent-strong);
      font-size: 12px; font-weight: 700; cursor: pointer; transition: all .15s; white-space: nowrap;
    }
    .clarify-submit:hover { background: var(--accent-soft); transform: translateY(-1px); }
    .clarify-hint { margin-top: 6px; font-size: 11px; line-height: 1.45; color: var(--muted); }

    /* ── Yolo (skip-all) session pill ── */
    .yolo-pill {
      display: inline-flex; align-items: center; gap: 8px;
      margin-bottom: 10px;
      padding: 7px 12px; border-radius: 999px;
      background: rgba(245, 158, 11, 0.12); border: 1px solid rgba(245, 158, 11, 0.35);
      color: #f59e0b; font-size: 12px; font-weight: 600;
    }
    .yolo-ico { display: inline-flex; align-items: center; }
    .yolo-off {
      margin-left: 4px; padding: 3px 10px; border-radius: 999px;
      border: 1px solid rgba(245, 158, 11, 0.45);
      background: transparent; color: #fbbf24;
      font-size: 11px; font-weight: 700; cursor: pointer;
    }
    .yolo-off:hover { background: rgba(245, 158, 11, 0.2); }

    /* ── Todos: tab switcher (Tasks | Run queue) ── */
    .todo-tabs {
      display: flex; align-items: center; gap: 6px;
      margin-bottom: 14px;
    }
    .todo-tab {
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--muted);
      border-radius: 8px;
      padding: 6px 14px;
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      transition: color 0.15s, border-color 0.15s, background 0.15s;
    }
    .todo-tab:hover { color: var(--text); border-color: var(--border-strong); }
    .todo-tab-active {
      color: var(--accent);
      border-color: var(--accent);
      background: var(--accent-soft);
    }
    .todo-tabs-count {
      margin-left: auto;
      font-size: 12px;
      color: var(--muted);
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 999px;
      padding: 3px 10px;
    }

    /* ── Run queue rows ── */
    .queue-list { display: flex; flex-direction: column; gap: 8px; }
    .queue-row {
      display: flex; align-items: center; gap: 10px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 9px 12px;
      cursor: grab;
      transition: border-color 0.15s, background 0.15s;
    }
    .queue-row:hover { border-color: var(--border-strong); }
    .queue-row.dragging { opacity: 0.45; }
    .queue-row.drop-before { border-top: 2px solid var(--accent); }
    .queue-row.drop-after { border-bottom: 2px solid var(--accent); }
    .queue-row.missing .queue-text { color: var(--danger); opacity: 0.8; }
    .queue-grip { color: var(--muted); display: inline-flex; cursor: grab; }
    .queue-idx {
      min-width: 20px; text-align: center;
      font-size: 12px; font-weight: 700;
      color: var(--muted);
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 2px 0;
    }
    .queue-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .queue-text {
      font-size: 13.5px; color: var(--text);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .queue-meta { font-size: 11.5px; color: var(--muted); }
    .queue-in { color: var(--accent); }
    .queue-link-btn { color: var(--muted); }
    .queue-link-btn:hover { color: var(--accent); }
    .queue-status {
      font-size: 11px; font-weight: 600;
      color: var(--muted);
      min-width: 46px; text-align: center;
    }
    .queue-status.qst-running { color: var(--accent); }
    .queue-status.qst-done { color: var(--success); }
    .queue-status.qst-failed { color: var(--danger); }
    .queue-status.qst-queued { color: var(--warning); }

    /* ── Run queue: header buttons ── */
    .queue-run-btn {
      display: inline-flex; align-items: center; gap: 6px;
      background: var(--surface-2);
      border: 1px solid var(--border);
      color: var(--text);
      border-radius: 8px;
      padding: 6px 12px;
      font-size: 12.5px;
      font-weight: 600;
      cursor: pointer;
    }
    .queue-run-btn:hover { border-color: var(--accent); color: var(--accent); }
    .queue-run-ico { display: inline-flex; }
    .queue-add-btn {
      display: inline-flex; align-items: center; gap: 6px;
      background: transparent;
      border: 1px dashed var(--border-strong);
      color: var(--muted);
      border-radius: 8px;
      padding: 6px 12px;
      font-size: 12.5px;
      font-weight: 600;
      cursor: pointer;
    }
    .queue-add-btn:hover { border-color: var(--accent); color: var(--accent); }
    .queue-running {
      display: inline-flex; align-items: center; gap: 7px;
      color: var(--accent);
      font-size: 12.5px; font-weight: 600;
    }
    .queue-running-dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--accent);
      animation: queuePulse 1s ease-in-out infinite;
    }
    @keyframes queuePulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.25; }
    }
    .queue-hidden-btn {
      position: absolute; width: 0; height: 0;
      border: 0; padding: 0; margin: 0;
      opacity: 0; pointer-events: none; overflow: hidden;
    }

    /* ── Link popup (feed earlier output) ── */
    .queue-link {
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 10px 12px;
      margin: 2px 0 4px 42px;
      display: flex; flex-direction: column; gap: 6px;
    }
    .queue-link-head { font-size: 12px; font-weight: 600; color: var(--text); }
    .queue-link-row {
      display: flex; align-items: center; gap: 8px;
      font-size: 12.5px; color: var(--text);
      cursor: pointer;
    }
    .queue-link-row input { accent-color: var(--accent); cursor: pointer; }
    .queue-link-num {
      font-weight: 700; color: var(--accent);
      background: var(--accent-soft);
      border-radius: 5px; padding: 1px 7px; font-size: 11px;
      white-space: nowrap;
    }
    .queue-link-title {
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      color: var(--muted);
    }
    .queue-link-empty { font-size: 12px; color: var(--muted); }
    .queue-link-actions { display: flex; gap: 8px; margin-top: 4px; }

    /* ── Add-tasks picker ── */
    .queue-picker {
      margin-top: 14px;
      border: 1px solid var(--border);
      border-radius: 12px;
      background: var(--surface);
      overflow: hidden;
    }
    .queue-picker-head {
      display: flex; align-items: center; justify-content: space-between;
      padding: 10px 14px;
      font-size: 12.5px; font-weight: 700; color: var(--text);
      background: var(--surface-2);
      border-bottom: 1px solid var(--border);
    }
    .queue-pick-chat { padding: 8px 14px 4px; }
    .queue-pick-title {
      font-size: 11px; font-weight: 700; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.4px;
      margin-bottom: 6px;
    }
    .queue-pick-row {
      display: flex; align-items: center; gap: 8px;
      font-size: 13px; color: var(--text);
      padding: 3px 0; cursor: pointer;
    }
    .queue-pick-row input { accent-color: var(--accent); cursor: pointer; }
    .queue-pick-text {
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .queue-pick-empty { padding: 14px; font-size: 12.5px; color: var(--muted); }
    .queue-picker-foot {
      display: flex; justify-content: flex-end;
      padding: 10px 14px;
      border-top: 1px solid var(--border);
      background: var(--surface-2);
    }

    /* ── Collapsed state (collapsible approval / clarify cards) ── */
    .approval-card.collapsed .approval-inner,
    .clarify-card.collapsed .clarify-inner { padding: 8px 14px; }
    .approval-card.collapsed .approval-head,
    .clarify-card.collapsed .clarify-head { margin-bottom: 0; }
    .approval-card.collapsed .approval-desc,
    .approval-card.collapsed .approval-cmd,
    .approval-card.collapsed .approval-btns,
    .approval-card.collapsed .approval-yolo-row,
    .clarify-card.collapsed .clarify-question,
    .clarify-card.collapsed .clarify-choices,
    .clarify-card.collapsed .clarify-response,
    .clarify-card.collapsed .clarify-hint { display: none; }
    .approval-card.collapsed .approval-collapse svg,
    .clarify-card.collapsed .clarify-collapse svg { transform: rotate(180deg); }

    /* ─── Terminal-state status card (tool iteration limit) ─────────── */
    .limit-card {
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
      padding: 10px 12px;
      margin: 6px 0 10px;
      max-width: 480px;
    }
    .limit-head { display: flex; align-items: center; gap: 6px; margin-bottom: 4px; }
    .limit-ico { color: var(--warning, #E68A00); font-size: 13px; display: inline-flex; }
    .limit-title { font-weight: 600; font-size: 12.5px; color: var(--text); }
    .limit-sub { font-size: 12px; color: var(--muted); margin: 2px 0 8px; }
    .limit-rows { border-top: 1px solid var(--border); padding-top: 6px; display: flex; flex-direction: column; gap: 3px; }
    .limit-row { display: flex; justify-content: space-between; gap: 12px; font-size: 12px; }
    .limit-k { color: var(--muted); }
    .limit-v { color: var(--text); }

    /* ─── Composer (Hermes composer-box sizing) ────────────────── */
    .composer-wrap { padding: 12px 12px 16px; }
    .composer-bar {
      max-width: 100%;
      margin: 0 auto;
      background: var(--input-bg);
      border: 1px solid var(--border-strong);
      border-radius: 16px;
      padding: 10px 12px 8px;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.28);
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .composer-bar:has(textarea:focus),
    .composer-bar.sel-open {
      border-color: var(--accent);
      box-shadow: 0 0 0 2px rgba(167, 139, 250, 0.22), 0 1px 2px rgba(0, 0, 0, 0.28);
    }
    .composer-bar textarea {
      width: 100%;
      border: none;
      resize: none;
      background: transparent;
      color: var(--text);
      font-family: inherit;
      font-size: 14px;
      outline: none;
      padding: 6px 8px 8px;
      min-height: 24px;
      max-height: 180px;
      line-height: 1.5;
    }
    .composer-toolbar { display: flex; align-items: center; gap: 2px; padding: 2px 2px 0; }
    .tool-btn {
      width: 30px; height: 30px;
      display: flex; align-items: center; justify-content: center;
      border: none; border-radius: 8px;
      background: transparent; color: var(--muted);
      font-size: 16px; cursor: pointer;
    }
    .tool-btn:hover { background: var(--surface-2); color: var(--text); }
    .tool-btn.on { color: var(--accent-strong); background: var(--accent-soft); }
    .composer-toolbar select {
      background: transparent;
      border: none;
      color: var(--muted);
      font-size: 0.82em;
      /* Reserve room for the native caret so long option text truncates
         before it instead of clipping underneath. */
      padding: 6px 26px 6px 6px;
      cursor: pointer;
      outline: none;
      max-width: 165px;
      font-family: inherit;
      text-overflow: ellipsis;
      white-space: nowrap;
      overflow: hidden;
    }
    .composer-toolbar select:hover { color: var(--text); }
    .composer-toolbar .spacer { flex: 1; }
    /* ── Context window indicator (Hermes parity) ── */
    .ctx-indicator-wrap { position: relative; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0; }
    .ctx-indicator { width: 26px; height: 26px; padding: 0; border: none; background: none; color: var(--muted); cursor: pointer; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0; transition: opacity 0.15s, transform 0.15s; }
    .ctx-indicator:hover { opacity: 0.88; transform: translateY(-1px); }
    .ctx-ring { position: relative; display: flex; width: 22px; height: 22px; align-items: center; justify-content: center; }
    .ctx-ring-svg { position: absolute; inset: 0; width: 22px; height: 22px; transform: rotate(-90deg); }
    .ctx-ring-track, .ctx-ring-value { fill: none; stroke-width: 3; }
    .ctx-ring-track { stroke: var(--border); }
    .ctx-ring-value { stroke: var(--muted); stroke-linecap: round; stroke-dasharray: 61.261056745; stroke-dashoffset: 61.261056745; transition: stroke-dashoffset 0.45s ease, stroke 0.25s ease; }
    .ctx-ring-center { position: relative; display: flex; width: 14px; height: 14px; align-items: center; justify-content: center; border-radius: 999px; background: var(--bg); font-size: 7px; font-weight: 600; line-height: 1; color: var(--muted); font-variant-numeric: tabular-nums; }
    .ctx-indicator.ctx-mid .ctx-ring-value { stroke: var(--accent-strong); }
    .ctx-indicator.ctx-high .ctx-ring-value { stroke: var(--danger); }
    .ctx-tooltip { position: absolute; right: 0; bottom: calc(100% + 10px); min-width: 210px; max-width: 250px; padding: 10px 12px; border: 1px solid var(--border); border-radius: 12px; background: var(--surface); box-shadow: 0 12px 30px rgba(0, 0, 0, 0.22); font-size: 11px; line-height: 1.45; color: var(--muted); opacity: 0; transform: translateY(4px); pointer-events: none; transition: opacity 0.14s ease, transform 0.14s ease; z-index: 30; }
    .ctx-tooltip::after { content: ''; position: absolute; right: 10px; top: 100%; border-width: 6px 6px 0 6px; border-style: solid; border-color: var(--surface) transparent transparent transparent; }
    .ctx-indicator-wrap:hover .ctx-tooltip, .ctx-indicator-wrap:focus-within .ctx-tooltip { opacity: 1; transform: translateY(0); pointer-events: auto; }
    .ctx-tooltip-title { font-size: 12px; font-weight: 600; color: var(--text); margin-bottom: 5px; }
    .ctx-tooltip-line + .ctx-tooltip-line { margin-top: 3px; }
    .send-btn {
      width: 34px; height: 34px;
      display: flex; align-items: center; justify-content: center;
      background: var(--accent); color: #fff;
      border: none; border-radius: 50%;
      cursor: pointer;
      transition: background 0.15s, transform 0.1s;
      margin-left: 4px;
      box-shadow: 0 2px 8px rgba(167, 139, 250, 0.28);
      flex-shrink: 0;
    }
    .send-btn svg { width: 16px; height: 16px; }
    .send-btn:hover { background: var(--accent-strong); }
    .send-btn:active { transform: scale(0.94); }
    .send-btn:disabled { opacity: 0.5; cursor: default; }
    .send-btn.stop { background: var(--danger); }
    .send-btn.stop:hover { background: var(--danger); }
    .send-btn.stop svg { display: block; }

    .attach-chips { display: flex; flex-wrap: wrap; gap: 6px; padding: 2px 6px 6px; }
    .chip {
      display: inline-flex; align-items: center; gap: 6px;
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 3px 9px;
      font-size: 0.8em;
      color: var(--text);
      max-width: 260px;
      font-family: ui-monospace, Menlo, monospace;
    }
    .chip .chip-x {
      border: none; background: none; color: var(--muted);
      cursor: pointer; padding: 0; font-size: 0.9em; line-height: 1;
    }
    .chip .chip-x:hover { color: var(--danger); }

    .file-pop {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 12px;
      margin-top: 6px;
      box-shadow: var(--shadow);
      display: flex; flex-direction: column; gap: 8px;
    }
    .file-pop.hidden { display: none; }
    .file-pop .fp-row { display: flex; gap: 6px; }
    .file-pop input {
      flex: 1;
      background: var(--surface-2);
      border: 1px solid var(--border);
      color: var(--text);
      border-radius: 8px;
      padding: 7px 9px;
      font-size: 0.85em;
      outline: none;
      font-family: ui-monospace, Menlo, monospace;
    }
    .file-pop input:focus { border-color: var(--accent-border); }
    .file-pop .fp-recents { font-size: 0.78em; color: var(--muted); }
    .fp-recent {
      display: block; width: 100%; text-align: left;
      background: transparent; border: none; color: var(--link);
      font-size: 0.85em; cursor: pointer; padding: 3px 0;
      font-family: ui-monospace, Menlo, monospace;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .fp-recent:hover { text-decoration: underline; }

    /* ── Composer dropdown selectors (Hermes parity) ─────────────────── */
    .dd { position: relative; display: inline-flex; align-items: center; flex-shrink: 0; min-width: 0; }
    .dd-trigger {
      display: inline-flex; align-items: center; gap: 5px;
      background: transparent; border: none; color: var(--muted);
      font-family: inherit; font-size: 0.82em; cursor: pointer;
      padding: 6px 8px; border-radius: 8px; max-width: 210px; min-width: 0;
      white-space: nowrap; overflow: hidden;
    }
    .dd-trigger:hover { background: var(--surface-2); color: var(--text); }
    .dd-trigger-label { overflow: hidden; text-overflow: ellipsis; }
    .dd-trigger svg { flex-shrink: 0; opacity: 0.85; }
    .dd-pop {
      position: absolute; bottom: calc(100% + 10px); left: 0;
      min-width: 320px; max-width: 380px;
      background: var(--surface); border: 1px solid var(--border);
      border-radius: 12px; box-shadow: 0 12px 30px rgba(0, 0, 0, 0.25);
      padding: 8px; z-index: 60; display: flex; flex-direction: column; gap: 2px;
      max-height: min(60vh, 420px); overflow: hidden;
    }
    .dd-pop.hidden { display: none; }
    .dd-search { position: relative; display: flex; align-items: center; gap: 4px; padding: 2px 2px 8px; }
    .dd-search input {
      flex: 1; min-width: 0; background: var(--surface-2);
      border: 1px solid var(--border); color: var(--text);
      border-radius: 8px; padding: 6px 9px; font-size: 0.8em; outline: none;
    }
    .dd-search input:focus { border-color: var(--accent-border); }
    .dd-clear {
      border: none; background: none; color: var(--muted); cursor: pointer;
      width: 22px; height: 22px; display: inline-flex; align-items: center; justify-content: center;
      border-radius: 50%; flex-shrink: 0; padding: 0;
    }
    .dd-clear:hover { color: var(--text); background: var(--surface-2); }
    .dd-list { overflow-y: auto; min-height: 0; }
    .dd-list::-webkit-scrollbar { width: 8px; }
    .dd-list::-webkit-scrollbar-track { background: transparent; }
    .dd-list::-webkit-scrollbar-thumb { background: var(--scroll-thumb); border-radius: 4px; }
    .dd-row {
      display: flex; flex-direction: column; align-items: flex-start; gap: 2px;
      width: 100%; text-align: left; border: none; background: transparent;
      color: var(--text); cursor: pointer; padding: 8px 10px; border-radius: 8px;
      font-family: inherit;
    }
    .dd-row:hover { background: var(--surface-2); }
    .dd-row-title { font-size: 0.86em; font-weight: 600; color: var(--text); display: inline-flex; align-items: center; gap: 5px; }
    .dd-row-sub { font-size: 0.75em; color: var(--muted); }
    .dd-empty { padding: 10px; font-size: 0.8em; color: var(--muted); }
    .dd-section { font-size: 0.68em; letter-spacing: 0.06em; color: var(--muted); padding: 6px 10px 2px; text-transform: uppercase; }
    .dd-note { font-size: 0.74em; color: var(--muted); padding: 2px 6px 8px; }
    .dd-foot { border-top: 1px solid var(--border); margin-top: 6px; padding-top: 4px; display: flex; flex-direction: column; }
    .dd-foot-row {
      display: flex; align-items: center; gap: 9px; width: 100%;
      background: transparent; border: none; color: var(--text); cursor: pointer;
      padding: 7px 10px; border-radius: 8px; font-family: inherit; text-align: left;
    }
    .dd-foot-row:hover { background: var(--surface-2); }
    .dd-foot-ico { display: inline-flex; color: var(--muted); flex-shrink: 0; }
    .dd-foot-txt { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
    .dd-dot { width: 8px; height: 8px; border-radius: 50%; background: #6b7680; flex-shrink: 0; margin-top: 5px; }
    .dd-dot.on { background: #3fbf5f; }
    .dd-profile-row { flex-direction: row; gap: 10px; align-items: flex-start; }
    .dd-profile-main { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
    .dd-badges { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 3px; max-width: 100%; min-width: 0; }
    .dd-badge {
      font-size: 0.62em; font-weight: 600; letter-spacing: 0.05em;
      color: #7fb3e8; border: 1px solid rgba(127, 179, 232, 0.45);
      padding: 2px 6px; border-radius: 999px; text-transform: uppercase;
      max-width: 100%; overflow-wrap: anywhere; word-break: break-word;
    }
    .dd-badge.sel { color: #e8eef4; border-color: rgba(232, 238, 244, 0.4); }
    .dd-model-main { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; }
    .dd-pop-model .dd-row { align-items: flex-start; }
    .ghost-btn.danger { color: var(--danger); border-color: var(--danger); }
    .ghost-btn.danger:hover { color: var(--danger); border-color: var(--danger); background: var(--danger-soft); }

    /* ── Hermes-style profile card (Profile Box) ─────────────────────── */
    .pl-card { margin: 14px 0 4px; border: 1px solid var(--border); border-radius: 12px; padding: 12px 14px; background: var(--surface); }
    .pl-eyebrow { font-size: 0.66em; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); margin-bottom: 8px; }
    .pl-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 7px 0; border-top: 1px solid var(--border); }
    .pl-row:first-of-type { border-top: none; }
    .pl-k { font-size: 0.84em; color: var(--muted); flex-shrink: 0; }
    .pl-v { display: inline-flex; align-items: center; gap: 6px; font-size: 0.84em; color: var(--text); min-width: 0; }
    .pl-badge {
      display: inline-flex; align-items: center; gap: 5px;
      font-size: 0.68em; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase;
      padding: 2px 8px; border-radius: 999px; border: 1px solid;
    }
    .badge-active { color: #7fb3e8; border-color: rgba(127, 179, 232, 0.55); }
    .badge-inactive { color: var(--muted); border-color: var(--border); }
    .badge-default { color: var(--muted); border-color: var(--border); }
    .badge-green { color: #6fce8f; border-color: rgba(111, 206, 143, 0.5); background: rgba(111, 206, 143, 0.08); text-transform: none; }
    .badge-red { color: var(--danger); border-color: var(--danger); }
    .pl-dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
    .pl-code {
      font-family: ui-monospace, Menlo, monospace; font-size: 0.9em;
      background: var(--code-bg); border: 1px solid var(--border);
      padding: 3px 8px; border-radius: 6px; color: var(--text);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 300px;
    }

    /* ─── Toasts ──────────────────────────────────────────────── */
    #toasts {
      position: fixed;
      top: 50px;
      left: 50%;
      transform: translateX(-50%);
      display: flex; flex-direction: column; gap: 8px;
      z-index: 1000;
      align-items: center;
      pointer-events: none;
    }
    .toast {
      display: flex; align-items: center; gap: 10px;
      background: var(--danger-soft);
      border: 1.5px solid var(--danger);
      border-radius: 999px;
      padding: 8px 14px 8px 16px;
      box-shadow: var(--shadow);
      font-size: 0.88em;
      color: var(--danger);
      max-width: 440px;
      pointer-events: auto;
    }
    .toast .toast-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--danger); flex: 0 0 8px; }
    .toast .toast-x { border: none; background: none; color: var(--danger); opacity: 0.7; cursor: pointer; font-size: 0.95em; }

    /* ─── Chat row menu (⋯) ──────────────────────────────────── */
    .menu-wrap { position: relative; display: flex; align-items: center; }
    .menu-dots {
      width: 28px; height: 28px;
      display: flex; align-items: center; justify-content: center;
      border: none; border-radius: 8px;
      background: transparent; color: var(--muted);
      font-size: 17px; line-height: 1; cursor: pointer;
      padding: 0; margin: 0;
    }
    .menu-dots:hover { background: var(--surface); color: var(--text); }

    /* Row menu: a spinner while that chat is running; the ⋮ dots return on
       hover so the menu stays reachable. */
    .row-spin {
      display: inline-block;
      width: 11px; height: 11px;
      border: 2px solid var(--border-strong);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }
    .row-dots { display: none; }
    .sess-row:hover .row-spin { display: none; }
    .sess-row:hover .row-dots { display: inline; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .chat-menu {
      position: absolute; right: 0; top: calc(100% + 5px);
      min-width: 220px; z-index: 60;
      display: none;
      flex-direction: column;
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 12px;
      box-shadow: var(--shadow);
      padding: 5px;
    }
    .chat-menu.open { display: flex; }
    .chat-menu button {
      display: flex; align-items: center; gap: 9px;
      border: none; background: transparent;
      color: var(--text);
      text-align: left; font-size: 0.87em;
      padding: 8px 10px; border-radius: 8px;
      cursor: pointer; white-space: nowrap;
    }

    /* ── Chat menu: "Set category" hover flyout submenu (Hermes parity) ── */
    .menu-item.has-sub { position: relative; display: flex; }
    /* The submenu is positioned and shown by runtime.js (fixed coordinates so
       it escapes .panel-body's overflow:auto clip) — CSS hover is deliberately
       not used: the JS version also works for keyboard focus. */
    .menu-item-head {
      display: flex; align-items: center; gap: 9px; justify-content: space-between;
      color: var(--text); text-align: left; font-size: 0.87em;
      padding: 8px 10px; border-radius: 8px; cursor: default;
      white-space: nowrap; width: 100%; box-sizing: border-box;
    }
    .menu-item-head:hover { background: var(--hover-bg); }
    .menu-item-head .menu-arrow {
      display: inline-flex; align-items: center; color: var(--muted);
      margin-left: auto; padding-left: 14px;
    }
    .menu-sub {
      position: absolute; left: 100%; top: -6px;
      min-width: 190px; z-index: 70;
      display: none;
      flex-direction: column;
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 12px;
      box-shadow: var(--shadow);
      padding: 5px;
      max-height: 320px; overflow-y: auto;
    }
    .menu-item.has-sub:focus-within .menu-sub { display: flex; }
    .menu-sub button { width: 100%; box-sizing: border-box; }
    .menu-sub button.menu-sel { background: var(--accent-soft); color: var(--accent-strong); }

    /* ── Settings → Color scheme: 3-dot palette tile grid (Hermes Skin) ── */
    .scheme-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(104px, 1fr));
      gap: 10px; width: 100%;
    }
    .scheme-tile {
      display: flex; flex-direction: column; align-items: center; gap: 7px;
      padding: 12px 8px 9px; border-radius: 12px;
      border: 2px solid transparent;
      background: var(--surface-2);
      color: var(--text); cursor: pointer;
      font: inherit; transition: border-color .15s, background .15s;
    }
    .scheme-tile:hover { background: var(--hover-bg); border-color: var(--border-strong); }
    .scheme-tile.active { border-color: var(--sw-accent, var(--accent)); background: var(--accent-soft); }
    .scheme-dots { display: inline-flex; gap: 5px; align-items: center; }
    .scheme-dot {
      width: 11px; height: 11px; border-radius: 999px;
      display: inline-block; border: 1px solid rgba(0,0,0,0.25);
    }
    .scheme-name { font-size: 0.72em; font-weight: 600; white-space: nowrap; }
    .chat-menu button:hover { background: var(--accent-soft); }
    .chat-menu button.danger { color: var(--danger); }
    .chat-menu button.danger:hover { background: var(--danger-soft); }

    .pin-badge { font-size: 0.82em; margin-right: 3px; }
    .sess-row.archived .sess-title { opacity: 0.62; }
    .rename-input {
      flex: 1; min-width: 0;
      box-sizing: border-box;
      width: 100%;
      border: 1px solid var(--accent-border);
      border-radius: var(--radius-md);
      background: var(--surface);
      color: var(--text);
      font: inherit; font-size: 0.93em; font-weight: 550;
      padding: 8px 9px;
      margin: 0;
    }
    .rename-input:focus { outline: none; border-color: var(--accent-strong); }

    /* ─── Centered confirmation modal ────────────────────────── */
    .modal-overlay {
      position: fixed; inset: 0;
      background: rgba(0, 0, 0, 0.45);
      display: flex; align-items: center; justify-content: center;
      z-index: 2000;
    }
    .modal-card {
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 16px;
      box-shadow: var(--shadow);
      width: min(400px, calc(100vw - 48px));
      padding: 22px 24px 20px;
    }
    .modal-card h3 { margin: 0 0 8px; font-size: 1.06em; color: var(--text); }
    .modal-card p { margin: 0 0 18px; color: var(--muted); font-size: 0.9em; line-height: 1.5; }
    .modal-actions { display: flex; justify-content: flex-end; gap: 10px; }
    .ghost-btn, .danger-btn {
      border-radius: 10px; font-size: 0.88em; font-weight: 600;
      padding: 8px 16px; cursor: pointer;
      border: 1px solid var(--border-strong);
      background: transparent; color: var(--text);
    }
    .ghost-btn:hover { background: var(--surface-2); }
    .danger-btn { border-color: var(--danger); color: var(--danger); background: var(--danger-soft); }
    .danger-btn:hover { background: var(--danger); color: var(--surface); }

    /* ─── Kanban ─────────────────────────────────────────────── */
    .kb-pcol { display: flex; align-items: center; gap: 8px; min-width: 0; }
    .kanban-main { overflow: hidden; }
    .kanban-board {
        margin: 12px;
    }
    .code-wrap { position: relative; margin: 10px 0; }
    .code-wrap pre { margin: 0; }
    .copy-code {
        position: absolute; top: 6px; right: 6px; z-index: 2;
        font-size: 11px; padding: 3px 9px; border-radius: 6px;
        border: 1px solid var(--border); background: var(--surface);
        color: var(--muted); cursor: pointer; opacity: .85;
    }
    .copy-code:hover { opacity: 1; }
    #main.todo-panel { flex: 1; height: 100%; overflow-y: auto; display: flex; flex-direction: column; padding: 22px clamp(20px, 7vw, 88px) 12px; box-sizing: border-box; }
    .todo-card {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-md); box-shadow: var(--shadow); overflow: hidden;
      flex: 1 0 auto;
    }
    .todo-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 14px 16px; border-bottom: 1px solid var(--border); }
    .todo-title { font-size: 15px; font-weight: 700; margin: 0; }
    .todo-sub { font-size: 12.5px; color: var(--muted); margin-top: 2px; }
    .todo-head-actions { display: flex; align-items: center; gap: 8px; }
    .todo-pill { font-size: 11.5px; font-weight: 600; padding: 3px 10px; border-radius: 999px; background: var(--accent-soft); color: var(--accent-strong); white-space: nowrap; }
    .todo-row { display: flex; align-items: center; gap: 10px; padding: 10px 16px; border-bottom: 1px solid var(--border); }
    .todo-row:last-child { border-bottom: none; }
    .todo-check {
      width: 20px; height: 20px; flex-shrink: 0; border-radius: 50%;
      border: 1.5px solid var(--border-strong); background: transparent;
      display: flex; align-items: center; justify-content: center;
      cursor: pointer; color: transparent; transition: border-color .15s, background .15s, color .15s;
    }
    .todo-check svg { width: 11px; height: 11px; }
    .todo-check:hover { border-color: var(--accent); }
    .todo-row.done .todo-check { background: var(--accent); border-color: var(--accent); color: #fff; }
    .todo-row.done .todo-check:hover { background: var(--accent-strong); }
    .todo-text { flex: 1; min-width: 0; font-size: 13.5px; line-height: 1.5; }
    .todo-row.done .todo-text { opacity: .45; text-decoration: line-through; }
    .todo-x {
      background: none; border: none; cursor: pointer; color: var(--muted);
      opacity: 0; transition: opacity .15s, color .15s; padding: 4px; display: flex;
    }
    .todo-x svg { width: 11px; height: 11px; }
    .todo-row:hover .todo-x { opacity: 1; }
    .todo-x:hover { color: var(--danger); }
    .todo-run {
      background: none; border: none; cursor: pointer; color: var(--muted);
      opacity: .45; transition: opacity .15s, color .15s; padding: 4px; display: flex;
    }
    .todo-run svg { width: 11px; height: 11px; }
    .todo-row:hover .todo-run { opacity: 1; }
    .todo-run:hover { color: var(--accent); }
    .todo-runall {
      display: inline-flex; align-items: center; gap: 6px;
      background: none; border: 1px solid var(--border); border-radius: 999px;
      color: var(--text); font-size: 11.5px; font-weight: 600; padding: 3px 10px;
      cursor: pointer; white-space: nowrap; transition: border-color .15s, color .15s;
    }
    .todo-runall:hover { border-color: var(--accent); color: var(--accent); }
    .todo-runall-ico { display: flex; }
    .todo-empty { padding: 42px 16px; text-align: center; color: var(--muted); font-size: 13px; }
    .todo-empty-ico { opacity: .4; margin-bottom: 8px; display: flex; justify-content: center; }
    .todo-empty small { display: block; margin-top: 4px; opacity: .7; }
    .todo-foot { padding: 12px 16px; border-top: 1px solid var(--border); background: var(--surface-2); }
    .todo-add { display: flex; gap: 8px; }
    .todo-add input {
      flex: 1; min-width: 0; background: var(--bg); color: var(--text);
      border: 1px solid var(--border); border-radius: 999px; padding: 8px 14px; font-size: 13px;
    }
    .todo-add input:focus { outline: none; border-color: var(--accent); }
    .todo-add button { border-radius: 999px; }
    .cron-panel { padding: 18px; max-width: 720px; margin: 0 auto; }
    .cron-dot { background: none; border: none; cursor: pointer; color: var(--muted); font-size: 13px; }
    .cron-add { display: flex; gap: 8px; margin-top: 14px; }
    .cron-add input {
      flex: 1; background: var(--bg); color: var(--text);
      border: 1px solid var(--border); border-radius: 8px; padding: 7px 10px; min-width: 0;
    }
    .cron-row { display: flex; align-items: center; gap: 10px; padding: 9px 4px; border-bottom: 1px solid var(--border-subtle); }
    .cron-dot.on { color: var(--success); }
    .cron-info { flex: 1; min-width: 0; }
    .cron-name { font-size: 13px; font-weight: 600; }
    .cron-sched { font-weight: 400; opacity: .7; font-size: 12px; margin-left: 6px; }
    .cron-meta { font-size: 12px; opacity: .65; margin-top: 2px; }
    .icon-mini { background: none; border: none; cursor: pointer; color: var(--muted); font-size: 14px; padding: 2px 4px; display: inline-flex; align-items: center; justify-content: center; }
    .icon-mini:hover { color: var(--text); }
    .icon-mini.danger:hover { color: var(--danger); }
    .kanban-board {
      display: flex; gap: 12px; align-items: flex-start;
      height: 100%; overflow-x: auto; overflow-y: hidden;
      padding: 14px;
    }
    .kb-col {
      display: flex; flex-direction: column; gap: 8px;
      width: 260px; min-width: 260px; max-height: 100%;
      background: var(--surface-2); border: 1px solid var(--border);
      border-radius: var(--radius-md); overflow: hidden;
    }
    .kb-col-head {
      display: flex; align-items: center; gap: 8px;
      padding: 10px 12px; border-top: 3px solid var(--colc, var(--accent-strong));
      border-bottom: 1px solid var(--border); background: var(--surface);
    }
    .kb-col-name { flex: 1; font-weight: 650; font-size: 0.92em; color: var(--text); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .kb-col-count {
      font-size: 0.72em; color: var(--muted); background: var(--surface-2);
      border: 1px solid var(--border); border-radius: 999px; padding: 1px 7px;
    }
    .kb-col-actions, .kb-card-actions { display: flex; gap: 2px; align-items: center; }
    .kb-cards { display: flex; flex-direction: column; gap: 7px; padding: 10px 9px; overflow-y: auto; flex: 1; }
    .kb-card {
      display: flex; flex-direction: column; gap: 7px;
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-sm); padding: 8px 9px;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.06);
    }
    .kb-card:hover { border-color: var(--border-strong); }
    .kb-card-title { font-size: 0.88em; color: var(--text); line-height: 1.35; word-break: break-word; }
    .kb-card-actions { justify-content: flex-end; }
    .kb-empty { color: var(--muted); font-size: 0.8em; text-align: center; padding: 10px 0; }
    .kb-addcard {
      border: 1px dashed var(--border-strong); background: transparent;
      color: var(--muted); border-radius: var(--radius-sm);
      padding: 7px 10px; font-size: 0.84em; cursor: pointer; margin: 0 9px 9px;
    }
    .kb-addcard:hover { color: var(--accent-strong); border-color: var(--accent-border); }
    .kb-addcard-form { margin: 0 9px 9px; }
    .kb-addcard-form input[type="text"] {
      width: 100%; background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-sm); color: var(--text);
      padding: 6px 9px; font-size: 0.86em; outline: none;
    }
    .kb-addcard-form input:focus { border-color: var(--accent-border); }

    /* ─── Personal memory ────────────────────────────────────── */
    .mem-box {
      display: flex; align-items: center; gap: 10px;
      width: 100%; padding: 12px; margin-bottom: 8px;
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-md); cursor: pointer; text-align: left;
    }
    .mem-box:hover { background: var(--surface-2); }
    .mem-box.active { border-color: var(--accent-border); background: var(--accent-soft); }
    .mem-glyph { font-size: 1.3em; flex: 0 0 auto; }
    .mem-txt { display: flex; flex-direction: column; flex: 1; min-width: 0; }
    .mem-title { color: var(--text); font-weight: 600; font-size: 0.92em; }
    .mem-sub { color: var(--muted); font-size: 0.76em; }
    .mem-arrow { color: var(--muted); font-size: 1.1em; }
    .mem-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
    .mem-textarea {
      width: 100%; min-height: 300px; margin-top: 12px;
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius-md); color: var(--text);
      padding: 12px; font-size: 0.92em; line-height: 1.55;
      font-family: var(--font-mono, ui-monospace, "SF Mono", Menlo, monospace);
      resize: vertical; outline: none;
    }
    .mem-textarea:focus { border-color: var(--accent-border); }

    /* ─── Workspace panel (right side) ───────────────────────── */
    #ws-dock { position: fixed; right: 6px; top: 50%; transform: translateY(-50%); z-index: 60; }
    .ws-dock-btn {
      width: 38px; height: 38px; border-radius: 50%;
      display: flex; align-items: center; justify-content: center;
      font-size: 1.05em; cursor: pointer;
      background: var(--surface-2); color: var(--text);
      border: 1px solid var(--border-strong);
      box-shadow: 0 2px 10px rgba(0, 0, 0, 0.18);
    }
    .ws-dock-btn:hover { background: var(--accent-soft); color: var(--accent-strong); border-color: var(--accent-border); }
    .ws-panel {
      width: var(--panel-w); flex: 0 0 var(--panel-w);
      border-left: 1px solid var(--border);
      display: flex; flex-direction: column; min-width: 0;
      background: var(--bg);
      transition: transform 0.28s cubic-bezier(0.22, 1, 0.36, 1), opacity 0.28s ease;
    }
    .ws-panel.ws-closing { transform: translateX(70px); opacity: 0; }
    .ws-panel.ws-enter { animation: wsSlideIn 0.3s cubic-bezier(0.22, 1, 0.36, 1); }
    @keyframes wsSlideIn {
      from { transform: translateX(70px); opacity: 0; }
      to { transform: translateX(0); opacity: 1; }
    }
    .ws-panel.hidden { display: none; }
    .ws-tools { display: flex; gap: 3px; align-items: center; }
    .ws-menu-wrap { position: relative; }
    .ws-body { flex: 1; overflow: auto; }
    .ws-path {
      font-size: 0.7em; color: var(--muted); padding: 6px 12px 8px;
      border-bottom: 1px solid var(--border);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .ws-row {
      display: flex; align-items: center; gap: 6px;
      width: 100%; background: transparent; border: none;
      color: var(--text); font-size: 0.86em; text-align: left;
      padding: 5px 12px 5px 12px; cursor: pointer; min-width: 0;
    }
    .ws-row:hover { background: var(--surface-2); }
    .ws-caret { width: 12px; flex: 0 0 12px; color: var(--muted); font-size: 0.8em; }
    .ws-ic { flex: 0 0 auto; font-size: 0.95em; }
    .ws-name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .ws-panel.drag { box-shadow: inset 0 0 0 2px var(--accent-strong); }
    .inline-edit {
      background: var(--surface); border: 1px solid var(--accent-border);
      border-radius: var(--radius-sm); color: var(--text);
      font-size: 0.88em; padding: 3px 7px; outline: none;
    }
    .inline-edit:focus { border-color: var(--accent-strong); }

    /* ─── Colorless line-drawing icons (inline SVG) ──────────── */
    .icon-btn svg { display: block; margin: auto; }
    .big svg { width: 46px; height: 46px; opacity: 0.55; }
    h1 svg, .detail-title svg { vertical-align: -4px; margin-right: 8px; }
    .icon-mini svg, .tool-btn svg, .plus-btn svg, .chip-x svg { display: block; margin: auto; }
    .pin-badge svg, .pin-badge img { width: 12px; height: 12px; vertical-align: -1px; }
    .live-status svg { width: 13px; height: 13px; vertical-align: -2px; margin-right: 4px; }
    .ws-caret svg { width: 11px; height: 11px; vertical-align: -2px; }
    .ws-ic svg { width: 13px; height: 13px; vertical-align: -2px; margin-right: 2px; }
    .chk { display: inline-flex; align-items: center; margin-right: 5px; }
    .chk svg { width: 12px; height: 12px; }
    .mem-glyph svg { width: 20px; height: 20px; }
    .lr-name svg { vertical-align: -3px; margin-right: 5px; }
    .ws-dock-btn svg { width: 17px; height: 17px; }
    .chat-menu button svg, .menu-item svg { vertical-align: -2px; margin-right: 5px; }
    .kb-col-actions svg, .kb-card-actions svg { vertical-align: -2px; }
    .row-actions svg { vertical-align: -3px; }

    /* Blank states */
    .blank {
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      height: 100%; color: var(--muted); gap: 6px;
      padding: 40px;
    }
    .blank .big { font-size: 2.2em; }

    /* ── Slash autocomplete (Hermes commands.js parity) ── */
    .cmd-dropdown { display: none; position: fixed; width: min(560px, calc(100vw - 24px));
      background: var(--bg); border: 1px solid var(--border-strong); border-radius: 10px;
      box-shadow: 0 -8px 24px rgba(0,0,0,.4); z-index: 200; max-height: 240px; overflow-y: auto; }
    .cmd-dropdown.open { display: block; }
    .cmd-item { display: block; width: 100%; text-align: left; padding: 8px 14px; cursor: pointer;
      transition: background .12s; background: transparent; border: 0; color: inherit; font: inherit; }
    .cmd-item:hover { background: rgba(140,140,140,.12); }
    .cmd-item.selected { background: var(--accent-soft); outline: 1px solid var(--accent-strong); }
    .cmd-item-name { font-size: 13px; color: var(--text); font-weight: 500; }
    .cmd-item-arg { color: var(--muted); font-weight: 400; font-style: italic; }
    .cmd-item-desc { font-size: 11px; color: var(--muted); margin-top: 1px; }
    .cmd-item-badge { display: inline-block; margin-left: 6px; font-size: 10px; font-weight: 700;
      letter-spacing: .04em; text-transform: uppercase; padding: 2px 6px; border-radius: 999px;
      border: 1px solid var(--border-strong); color: var(--muted); background: var(--hover-bg); vertical-align: 1px; }
    .cmd-item-badge-skill { color: var(--accent); background: var(--accent-soft); border-color: var(--accent-strong); }

    /* ── Reply with selection (Hermes messages.js parity) ── */
    .selected-text-reply-btn { position: fixed; z-index: 1200; display: inline-flex; align-items: center;
      gap: 6px; padding: 7px 11px; border: 2px solid var(--accent); border-radius: 999px;
      background: var(--bg); color: var(--text);
      box-shadow: 0 8px 24px rgba(0,0,0,.26), 0 0 0 1px var(--bg-subtle);
      font-size: 12px; font-weight: 700; line-height: 1; cursor: pointer; opacity: 0;
      pointer-events: none; transform: translateY(4px);
      transition: opacity .12s ease, transform .12s ease; user-select: none; }
    .selected-text-reply-btn.visible { opacity: 1; pointer-events: auto; transform: translateY(0); }

    /* ── Context chips (Hermes _renderSelectionChips parity) ── */
    .selection-chips-wrap { display: flex; flex-direction: column; gap: 8px; max-width: 100%;
      box-sizing: border-box; margin: 0 auto; padding: 8px 0 0; min-height: 0;
      max-height: min(32vh, 280px); overflow-y: auto; scrollbar-gutter: stable; }
    .selection-chips-wrap:empty { display: none; }
    .selection-context-card { display: flex; gap: 10px; align-items: stretch;
      border: 1px solid var(--border-strong); border-radius: 12px;
      background: linear-gradient(135deg, var(--bg-subtle), rgba(255,255,255,.015));
      box-shadow: 0 1px 0 rgba(255,255,255,.03) inset; color: var(--text); overflow: hidden; }
    .selection-context-accent { width: 3px; flex: 0 0 3px; background: var(--accent); opacity: .82; }
    .selection-context-body { min-width: 0; flex: 1; padding: 9px 10px 9px 0; }
    .selection-context-header { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 5px; }
    .selection-context-name { color: var(--accent); font-size: 11px; font-weight: 700; line-height: 1.2;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .selection-context-remove { display: inline-flex; align-items: center; justify-content: center;
      min-width: 28px; min-height: 28px; background: transparent; border: 1px solid transparent;
      border-radius: 999px; color: var(--muted); cursor: pointer; font-size: 12px; line-height: 1;
      padding: 2px 5px; flex: 0 0 auto; }
    .selection-context-remove:hover { color: var(--text); background: var(--hover-bg); border-color: var(--border); }
    .selection-context-quote { margin: 0; color: var(--muted); font-size: 12.5px; line-height: 1.45;
      white-space: pre-wrap; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; }

    /* ── Queue feed chips (same named-context presentation as the composer) ── */
    .queue-feed-chips { display: flex; flex-wrap: wrap; gap: 4px; max-height: 54px; overflow-y: auto; }
    .queue-feed-chip { display: inline-flex; align-items: center; gap: 4px; border: 1px solid var(--border-strong);
      border-radius: 999px; padding: 1px 8px 1px 4px; font-size: 11px; color: var(--muted); }
    .queue-feed-accent { width: 3px; height: 10px; border-radius: 2px; background: var(--accent); opacity: .8; }
    .queue-feed-label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 220px; }
    """

    /// Palette blocks for every color scheme, appended after `css`. A page
    /// always renders `#app[data-scheme=...]`, and the default (cappuccino)
    /// blocks double as the fallback when the attribute is absent.
    static let schemeCSS: String = ColorScheme.all.map { $0.cssBlocks }.joined(separator: "\n")
}
