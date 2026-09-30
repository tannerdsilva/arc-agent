import WebUI
import WebUIDesignSystem

// MARK: - arc's theme catalog

// the 27 schemes as no-webui providers — what the framework's picker and the engine read.
// `ArcThemeCatalog.entries` is the list the settings grid renders, and `stylesheet()` is
// the sheet that carries every scheme for client-side switching.
//
// two structural facts before the data:
//
//  * `ArcBaseTheme` holds the value each property takes in the *majority* of schemes, so a
//    scheme states only what makes it that scheme: 2089 palette entries become 1691. the
//    emitted css is identical either way — this is source hygiene, and it is exactly what
//    `@Theme(base:)` is for. (the no-webui plan guessed a consumer port would shrink by
//    more than half; measured, arc's schemes are distinct palettes rather than eleven-token
//    overrides, and the honest figure is 19%.)
//  * the 14 properties that mean a framework token are not stated at all: they are
//    **aliases** (`--bg: var(--color-bg)`) declared once on the base, so every scheme and
//    both modes inherit them, and a mistyped token is a missing enum case instead of a
//    colour that silently never changes. the rest — `--accent-soft`, `--shadow`,
//    `--user-bubble`, the code/hover/input greys — have no token equivalent and stay
//    literal: a token invented to cover them would be a name that lies. `--warning` is
//    literal for a sharper reason: no-webui emits every alias into every block, and its
//    token is not defined in every scheme, so the indirection would resolve to nothing
//    where the property used to inherit the base sheet's orange.

/// arc's own property vocabulary, declared against no-webui's tokens.
///
/// an alias emits an *indirection*, not a value: the scheme still states the token, and
/// every arc property that means that token follows it, in both modes and every scheme.
enum ArcThemeAliases {
	static let all: [TokenAlias] = [
		TokenAlias("--bg", .colorBg),
		TokenAlias("--surface", .colorBgRaised),
		TokenAlias("--surface-2", .colorBgInset),
		TokenAlias("--sidebar", .colorBgSubtle),
		TokenAlias("--border", .colorBorder),
		TokenAlias("--border-strong", .colorBorderStrong),
		TokenAlias("--text", .colorText),
		TokenAlias("--muted", .colorTextMuted),
		TokenAlias("--accent", .colorPrimarySolid),
		TokenAlias("--accent-strong", .colorPrimarySolidHover),
		TokenAlias("--danger", .colorDanger),
		TokenAlias("--danger-soft", .colorDangerSoft),
		TokenAlias("--success", .colorSuccess),
		TokenAlias("--scroll-thumb", .scrollbarThumb),
	]
}

/// The palette every arc scheme layers over: the majority value per property, per mode.
///
/// taken from the sheet arc actually shipped, not restated by hand — so a scheme can only
/// ever *deviate* from what the product painted, never drift from it.
@Theme
struct ArcBaseTheme {
	static let aliases = ArcThemeAliases.all

	static let palette = ThemePalette(
				tokens: [.colorBg: "#FFFFFF", .colorBgInset: "#F7F7F7", .colorBgRaised: "#FFFFFF",
					.colorBgSubtle: "#F3F3F3", .colorBorder: "#E2E2E2", .colorBorderStrong: "#CFCFCF",
					.colorDanger: "#C43C3C", .colorDangerSoft: "rgba(196, 60, 60, 0.10)",
					.colorPrimarySolid: "#D97757", .colorPrimarySolidHover: "#6D28D9", .colorSuccess: "#3D8B52",
					.colorText: "#1D1D24", .colorTextMuted: "#71717A", .scrollbarThumb: "#D4D4DC",
				],
				customTokens: ["--accent-border": "rgba(217,119,87,0.18)",
					"--accent-soft": "rgba(184, 134, 11, 0.10)", "--code-bg": "#F0F0F4", "--link": "#0288A8",
					"--shadow": "0 2px 12px rgba(30, 30, 40, 0.08)", "--user-bubble": "#EFEFEF",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#151614", .colorBgInset: "#20211F", .colorBgRaised: "#1B1C1A",
					.colorBgSubtle: "#242624", .colorBorder: "#343631", .colorBorderStrong: "#4B4D47",
					.colorDanger: "#E5484D", .colorDangerSoft: "rgba(229, 72, 77, 0.14)",
					.colorPrimarySolid: "#D9A441", .colorPrimarySolidHover: "#E3B45C", .colorSuccess: "#46A758",
					.colorText: "#E6E6EC", .colorTextMuted: "#9A9AA5", .scrollbarThumb: "#33333E",
				],
				customTokens: ["--accent-border": "rgba(217, 164, 65, 0.5)",
					"--accent-soft": "rgba(217, 164, 65, 0.14)", "--code-bg": "#23232C", "--link": "#C9C8C0",
					"--shadow": "0 2px 14px rgba(0, 0, 0, 0.35)", "--user-bubble": "#2E302D",
				],
			)
}

/// Default.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct ArcDefaultTheme {
	static let themeID = "default"
	static let themeLabel = "Default"
	static let themeSwatch = ["#B8860B", "#D9A441", "#B8860B", "#8A5A2B",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#FDFBF7", .colorBgInset: "#F7F3EA", .colorBgSubtle: "#FAF7F0",
					.colorBorder: "#EAE2D3", .colorBorderStrong: "#D5CEBE", .colorDanger: "#B34141",
					.colorDangerSoft: "rgba(179, 65, 65, 0.10)", .colorPrimarySolid: "#B8860B",
					.colorPrimarySolidHover: "#9A6F09", .colorSuccess: "#4E7C3A", .colorText: "#2A2723",
					.colorTextMuted: "#8A8271", .scrollbarThumb: "#D8D0BE",
				],
				customTokens: ["--accent-border": "rgba(184, 134, 11, 0.45)", "--code-bg": "#F4EFE3",
					"--shadow": "0 2px 12px rgba(60, 50, 30, 0.08)", "--user-bubble": "rgba(184, 134, 11, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#17171B", .colorBgInset: "#26262C", .colorBgRaised: "#1F1F24",
					.colorBgSubtle: "#1B1B20", .colorBorder: "#2E2E36", .colorBorderStrong: "#3C3C46",
					.colorDanger: "#E06C6C", .colorDangerSoft: "rgba(224, 108, 108, 0.14)",
					.colorSuccess: "#7FB069", .colorText: "#E8E6E1", .colorTextMuted: "#9A9486",
					.scrollbarThumb: "#3A3A44",
				],
				customTokens: ["--code-bg": "#2A2A31", "--link": "#58B7D6",
					"--user-bubble": "rgba(217, 164, 65, 0.13)",
				],
			)
}

/// Ares.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct AresTheme {
	static let themeID = "ares"
	static let themeLabel = "Ares"
	static let themeSwatch = ["#E5484D", "#E5484D", "#F06A75", "#F8A5AE",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F6EBED", .colorBgInset: "#EEDEE2", .colorBgRaised: "#FEF6F6",
					.colorBgSubtle: "#F1E8EB", .colorBorder: "#E2CCD2", .colorBorderStrong: "#D3BAC2",
					.colorPrimarySolid: "#E5484D", .colorPrimarySolidHover: "#C6373C", .scrollbarThumb: "#D8B1B8",
				],
				customTokens: ["--accent-border": "rgba(229, 72, 77, 0.45)",
					"--accent-soft": "rgba(229, 72, 77, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#C6373C",
					"--user-bubble": "rgba(229, 72, 77, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#22171C", .colorBgInset: "#36272F", .colorBgRaised: "#251D24",
					.colorBgSubtle: "#231A20", .colorBorder: "#463039", .colorBorderStrong: "#553C47",
					.colorPrimarySolid: "#E5484D", .colorPrimarySolidHover: "#C6373C", .scrollbarThumb: "#603842",
				],
				customTokens: ["--accent-border": "rgba(229, 72, 77, 0.50)",
					"--accent-soft": "rgba(229, 72, 77, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#C6373C", "--user-bubble": "rgba(229, 72, 77, 0.13)",
				],
			)
}

/// Mono.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct MonoTheme {
	static let themeID = "mono"
	static let themeLabel = "Mono"
	static let themeSwatch = ["#8B8B93", "#C8C8CD", "#8B8B93", "#4A4A52",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#EFEFF2", .colorBgInset: "#E5E5E9", .colorBgRaised: "#F9F9FA",
					.colorBgSubtle: "#ECECEF", .colorBorder: "#D6D6DC", .colorBorderStrong: "#C5C5CD",
					.colorPrimarySolid: "#8B8B93", .colorPrimarySolidHover: "#6E6E76", .scrollbarThumb: "#C2C2CA",
				],
				customTokens: ["--accent-border": "rgba(139, 139, 147, 0.45)",
					"--accent-soft": "rgba(139, 139, 147, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#6E6E76",
					"--user-bubble": "rgba(139, 139, 147, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#1B1B21", .colorBgInset: "#2D2D36", .colorBgRaised: "#212128",
					.colorBgSubtle: "#1E1E24", .colorBorder: "#393943", .colorBorderStrong: "#474752",
					.colorPrimarySolid: "#8B8B93", .colorPrimarySolidHover: "#6E6E76", .scrollbarThumb: "#494953",
				],
				customTokens: ["--accent-border": "rgba(139, 139, 147, 0.50)",
					"--accent-soft": "rgba(139, 139, 147, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#6E6E76", "--user-bubble": "rgba(139, 139, 147, 0.13)",
				],
			)
}

/// Graphite.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct GraphiteTheme {
	static let themeID = "graphite"
	static let themeLabel = "Graphite"
	static let themeSwatch = ["#303030", "#FFFFFF", "#B8B8C0", "#3A3A42",]

	static let palette = ThemePalette(
				tokens: [.colorDanger: "#D44D4D", .colorPrimarySolid: "#303030",
					.colorPrimarySolidHover: "#303030", .colorSuccess: "#0F8F70", .colorText: "#242424",
					.colorTextMuted: "#707070", .colorWarning: "#B87916",
				],
				customTokens: ["--accent-border": "rgba(0,0,0,0.13)", "--accent-soft": "rgba(0,0,0,0.07)",
					"--border-subtle": "#E8E8E8", "--code-bg": "#F1F1F1", "--code-inline-bg": "rgba(0,0,0,0.06)",
					"--code-text": "#242424", "--hover-bg": "rgba(0,0,0,0.05)", "--input-bg": "#FFFFFF",
					"--link": "#5F5F5F", "--warning": "#B87916",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorDanger: "#FF6B6B", .colorPrimarySolid: "#D7D6CE",
					.colorPrimarySolidHover: "#D7D6CE", .colorSuccess: "#10A37F", .colorText: "#ECEBE4",
					.colorTextMuted: "#A7A79D", .colorWarning: "#E6B15C",
				],
				customTokens: ["--accent-border": "rgba(255,255,255,0.14)",
					"--accent-soft": "rgba(255,255,255,0.08)", "--border-subtle": "#2A2C28", "--code-bg": "#111210",
					"--code-inline-bg": "rgba(255,255,255,0.08)", "--code-text": "#F1F0EA",
					"--hover-bg": "rgba(255,255,255,0.06)", "--input-bg": "#1E1F1D", "--warning": "#E6B15C",
				],
			)
}

/// GitHub.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct GithubTheme {
	static let themeID = "github"
	static let themeLabel = "GitHub"
	static let themeSwatch = ["#0969DA", "#0969DA", "#1F883D", "#30363D",]

	static let palette = ThemePalette(
				tokens: [.colorDanger: "#D1242F", .colorPrimarySolid: "#0969DA",
					.colorPrimarySolidHover: "#0969DA", .colorSuccess: "#1A7F37", .colorText: "#242424",
					.colorTextMuted: "#707070", .colorWarning: "#9A6700",
				],
				customTokens: ["--accent-border": "rgba(9,105,218,0.18)", "--accent-soft": "#DDF4FF",
					"--border-subtle": "#E8E8E8", "--code-bg": "#F1F1F1", "--code-inline-bg": "rgba(0,0,0,0.06)",
					"--code-text": "#242424", "--hover-bg": "rgba(0,0,0,0.05)", "--input-bg": "#FFFFFF",
					"--link": "#0969DA", "--warning": "#9A6700",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorDanger: "#FF7B72", .colorPrimarySolid: "#4493F8",
					.colorPrimarySolidHover: "#58A6FF", .colorSuccess: "#3FB950", .colorText: "#ECEBE4",
					.colorTextMuted: "#A7A79D", .colorWarning: "#D29922",
				],
				customTokens: ["--accent-border": "rgba(31,111,235,0.24)",
					"--accent-soft": "rgba(56,139,253,0.10)", "--border-subtle": "#2A2C28", "--code-bg": "#111210",
					"--code-inline-bg": "rgba(255,255,255,0.08)", "--code-text": "#F1F0EA",
					"--hover-bg": "rgba(255,255,255,0.06)", "--input-bg": "#1E1F1D", "--link": "#58A6FF",
					"--warning": "#D29922",
				],
			)
}

/// Codex.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct CodexTheme {
	static let themeID = "codex"
	static let themeLabel = "Codex"
	static let themeSwatch = ["#72B39A", "#10A37F", "#E8E8E8", "#333333",]

	static let palette = ThemePalette(
				tokens: [.colorBgInset: "#F1F1F1", .colorBorder: "#E0E0E0", .colorBorderStrong: "#C8C8C8",
					.colorDanger: "#D92D20", .colorPrimarySolid: "#2E7A60", .colorPrimarySolidHover: "#1D6850",
					.colorSuccess: "#2E7A60", .colorText: "#252523", .colorTextMuted: "#6A6A68",
					.colorWarning: "#B87916",
				],
				customTokens: ["--accent-border": "rgba(46,122,96,0.16)",
					"--accent-soft": "rgba(46,122,96,0.08)", "--border-subtle": "#E8E8E8", "--code-bg": "#F3F3F3",
					"--code-inline-bg": "rgba(0,0,0,0.06)", "--code-text": "#252523",
					"--hover-bg": "rgba(0,0,0,0.04)", "--input-bg": "#FFFFFF", "--link": "#4D8DFF",
					"--user-bubble": "#EBEBEB", "--warning": "#B87916",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorDanger: "#FF6B6B", .colorPrimarySolid: "#72B39A",
					.colorPrimarySolidHover: "#84BEA8", .colorSuccess: "#72B39A", .colorText: "#ECEBE4",
					.colorTextMuted: "#A7A79D", .colorWarning: "#E6B15C",
				],
				customTokens: ["--accent-border": "rgba(114,179,154,0.18)",
					"--accent-soft": "rgba(114,179,154,0.10)", "--border-subtle": "#2A2C28", "--code-bg": "#111210",
					"--code-inline-bg": "rgba(255,255,255,0.08)", "--code-text": "#F1F0EA",
					"--hover-bg": "rgba(255,255,255,0.06)", "--input-bg": "#1E1F1D", "--warning": "#E6B15C",
				],
			)
}

/// Terracotta.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct TerracottaTheme {
	static let themeID = "terracotta"
	static let themeLabel = "Terracotta"
	static let themeSwatch = ["#C0785A", "#C08A6D", "#E8E8E8", "#3A3A42",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#FAF9F5", .colorBgInset: "#F7F4EC", .colorBgRaised: "#FFFEFA",
					.colorBgSubtle: "#F0EEE6", .colorBorder: "#E8E6DC", .colorBorderStrong: "#D7D2C4",
					.colorDanger: "#C15F3C", .colorPrimarySolidHover: "#A94F35", .colorSuccess: "#6EA100",
					.colorText: "#30302E", .colorTextMuted: "#87867F", .colorWarning: "#B87916",
				],
				customTokens: ["--accent-soft": "rgba(217,119,87,0.10)", "--border-subtle": "#F0EDE4",
					"--code-bg": "#F0EEE6", "--code-inline-bg": "rgba(48,48,46,0.065)", "--code-text": "#30302E",
					"--hover-bg": "rgba(48,48,46,0.05)", "--input-bg": "#FFFEFA", "--link": "#6396D6",
					"--user-bubble": "#F0EEE6", "--warning": "#B87916",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#141413", .colorBgInset: "#20201D", .colorBgRaised: "#191917",
					.colorBgSubtle: "#1E1D1A", .colorBorder: "#34332E", .colorBorderStrong: "#4A473F",
					.colorDanger: "#F08A6F", .colorPrimarySolid: "#D97757", .colorPrimarySolidHover: "#E69072",
					.colorSuccess: "#9BCB5A", .colorText: "#EDEAE0", .colorTextMuted: "#B0AEA5",
					.colorWarning: "#E6B15C",
				],
				customTokens: ["--accent-border": "rgba(217,119,87,0.20)",
					"--accent-soft": "rgba(217,119,87,0.11)", "--border-subtle": "#292824", "--code-bg": "#10100F",
					"--code-inline-bg": "rgba(237,234,224,0.08)", "--code-text": "#F0EEE6",
					"--hover-bg": "rgba(237,234,224,0.055)", "--input-bg": "#191917", "--link": "#7BA7DE",
					"--user-bubble": "#282620", "--warning": "#E6B15C",
				],
			)
}

/// Slate.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct SlateTheme {
	static let themeID = "slate"
	static let themeLabel = "Slate"
	static let themeSwatch = ["#4E7C99", "#7DA7C4", "#4E7C99", "#2A3F4C",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#EBEEF2", .colorBgInset: "#DFE4EA", .colorBgRaised: "#F6F8FA",
					.colorBgSubtle: "#E8EBEF", .colorBorder: "#CDD4DD", .colorBorderStrong: "#BBC3CE",
					.colorPrimarySolid: "#4E7C99", .colorPrimarySolidHover: "#3D647D", .scrollbarThumb: "#B2BECB",
				],
				customTokens: ["--accent-border": "rgba(78, 124, 153, 0.45)",
					"--accent-soft": "rgba(78, 124, 153, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#3D647D",
					"--user-bubble": "rgba(78, 124, 153, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#171A21", .colorBgInset: "#272C37", .colorBgRaised: "#1E2028",
					.colorBgSubtle: "#1A1D24", .colorBorder: "#313744", .colorBorderStrong: "#3D4553",
					.colorPrimarySolid: "#4E7C99", .colorPrimarySolidHover: "#3D647D", .scrollbarThumb: "#3A4555",
				],
				customTokens: ["--accent-border": "rgba(78, 124, 153, 0.50)",
					"--accent-soft": "rgba(78, 124, 153, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#3D647D", "--user-bubble": "rgba(78, 124, 153, 0.13)",
				],
			)
}

/// Poseidon.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct PoseidonTheme {
	static let themeID = "poseidon"
	static let themeLabel = "Poseidon"
	static let themeSwatch = ["#0E7C9B", "#4FC3E8", "#0E7C9B", "#0B4E63",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F4FAFC", .colorBgInset: "#EAF3F6", .colorBgSubtle: "#F0F7F9",
					.colorBorder: "#D8E7EC", .colorBorderStrong: "#C0D6DE", .colorDanger: "#C04040",
					.colorDangerSoft: "rgba(192, 64, 64, 0.10)", .colorPrimarySolid: "#0E7C9B",
					.colorPrimarySolidHover: "#0A6580", .colorSuccess: "#2E7D5B", .colorText: "#17313A",
					.colorTextMuted: "#5F7A84", .scrollbarThumb: "#C4DCE4",
				],
				customTokens: ["--accent-border": "rgba(14, 124, 155, 0.42)",
					"--accent-soft": "rgba(14, 124, 155, 0.10)", "--code-bg": "#E8F2F5", "--link": "#0E7C9B",
					"--shadow": "0 2px 12px rgba(20, 90, 110, 0.08)", "--user-bubble": "rgba(14, 124, 155, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#0E1B22", .colorBgInset: "#1B2D38", .colorBgRaised: "#14242D",
					.colorBgSubtle: "#101E25", .colorBorder: "#24404B", .colorBorderStrong: "#315463",
					.colorDanger: "#EF7A7A", .colorDangerSoft: "rgba(239, 122, 122, 0.14)",
					.colorPrimarySolid: "#4FC3E8", .colorPrimarySolidHover: "#6BD3F2", .colorSuccess: "#63D0A0",
					.colorText: "#DBE9EF", .colorTextMuted: "#7E9AA6", .scrollbarThumb: "#2E4961",
				],
				customTokens: ["--accent-border": "rgba(79, 195, 232, 0.5)",
					"--accent-soft": "rgba(79, 195, 232, 0.14)", "--code-bg": "#1C3140", "--link": "#4FC3E8",
					"--shadow": "0 2px 14px rgba(0, 0, 0, 0.4)", "--user-bubble": "rgba(79, 195, 232, 0.13)",
				],
			)
}

/// Sisyphus.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct SisyphusTheme {
	static let themeID = "sisyphus"
	static let themeLabel = "Sisyphus"
	static let themeSwatch = ["#A78BFA", "#C4B5FD", "#8B5CF6", "#5B21B6",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#FEFCF7", .colorBgInset: "#F3EEE3", .colorBgSubtle: "#FAF7F0",
					.colorBorder: "#E0D8C8", .colorBorderStrong: "#D0C8B8", .colorDanger: "#C62828",
					.colorDangerSoft: "rgba(198, 40, 40, 0.10)", .colorPrimarySolid: "#7C3AED",
					.colorSuccess: "#3D8B40", .colorText: "#1A1610", .colorTextMuted: "#5C5344",
					.scrollbarThumb: "#D8D0BE",
				],
				customTokens: ["--accent-border": "rgba(124, 58, 237, 0.40)",
					"--accent-soft": "rgba(124, 58, 237, 0.08)", "--code-bg": "#F5F0E5", "--link": "#6D28D9",
					"--shadow": "0 2px 12px rgba(60, 50, 30, 0.08)", "--user-bubble": "rgba(124, 58, 237, 0.08)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#0D0D1A", .colorBgInset: "#20203A", .colorBgRaised: "#1A1A2E",
					.colorBgSubtle: "#141425", .colorBorder: "#2A2A45", .colorBorderStrong: "#3A3A5C",
					.colorDanger: "#EF5350", .colorDangerSoft: "rgba(239, 83, 80, 0.14)",
					.colorPrimarySolid: "#A78BFA", .colorPrimarySolidHover: "#8B5CF6", .colorSuccess: "#4CAF50",
					.colorText: "#FFF8DC", .colorTextMuted: "#C0C0C0", .scrollbarThumb: "#2A2A45",
				],
				customTokens: ["--accent-border": "rgba(167, 139, 250, 0.35)",
					"--accent-soft": "rgba(167, 139, 250, 0.08)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-bg": "#1A1A2E", "--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E2E8F0",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#A78BFA", "--shadow": "0 2px 14px rgba(0, 0, 0, 0.4)",
					"--user-bubble": "rgba(167, 139, 250, 0.08)",
				],
			)
}

/// Charizard.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct CharizardTheme {
	static let themeID = "charizard"
	static let themeLabel = "Charizard"
	static let themeSwatch = ["#F97316", "#F9A03F", "#F97316", "#C2410C",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F7EEE9", .colorBgInset: "#F0E3DD", .colorBgRaised: "#FFF8F3",
					.colorBgSubtle: "#F2EAE8", .colorBorder: "#E5D2CB", .colorBorderStrong: "#D7C1B9",
					.colorPrimarySolid: "#F97316", .colorPrimarySolidHover: "#C2410C", .scrollbarThumb: "#DDBCAA",
				],
				customTokens: ["--accent-border": "rgba(249, 115, 22, 0.45)",
					"--accent-soft": "rgba(249, 115, 22, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#C2410C",
					"--user-bubble": "rgba(249, 115, 22, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#231A18", .colorBgInset: "#382B2A", .colorBgRaised: "#261F21",
					.colorBgSubtle: "#251D1D", .colorBorder: "#493632", .colorBorderStrong: "#59433E",
					.colorPrimarySolid: "#F97316", .colorPrimarySolidHover: "#C2410C", .scrollbarThumb: "#644334",
				],
				customTokens: ["--accent-border": "rgba(249, 115, 22, 0.50)",
					"--accent-soft": "rgba(249, 115, 22, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#C2410C", "--user-bubble": "rgba(249, 115, 22, 0.13)",
				],
			)
}

/// Sienna.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct SiennaTheme {
	static let themeID = "sienna"
	static let themeLabel = "Sienna"
	static let themeSwatch = ["#A9714B", "#D2A17E", "#A9714B", "#6B4632",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#FAF9F5", .colorBgInset: "#EFEFF3", .colorBgSubtle: "#F0EEE6",
					.colorBorder: "#E7E4DB", .colorBorderStrong: "#D7D3C7", .colorPrimarySolidHover: "#A55237",
					.colorText: "#1F1E1C", .colorTextMuted: "#6B6A63",
				],
				customTokens: ["--accent-soft": "rgba(217,119,87,0.09)",
					"--border-subtle": "rgba(0, 0, 0, 0.08)", "--code-bg": "#F5F3EC",
					"--code-inline-bg": "rgba(20,19,17,0.06)", "--code-text": "#8A3E1A",
					"--hover-bg": "rgba(20,19,17,0.05)", "--input-bg": "rgba(20,19,17,0.035)", "--link": "#2E6F9E",
					"--user-bubble": "#ECE9DF",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#1F1E1C", .colorBgInset: "#23232C", .colorBgRaised: "#2C2B28",
					.colorBgSubtle: "#262522", .colorBorder: "#3A3935", .colorBorderStrong: "#4A4843",
					.colorPrimarySolid: "#E0896D", .colorPrimarySolidHover: "#E6A88A", .colorText: "#EDEBE3",
					.colorTextMuted: "#A3A197",
				],
				customTokens: ["--accent-border": "rgba(224,137,109,0.22)",
					"--accent-soft": "rgba(224,137,109,0.12)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-bg": "#2A2926", "--code-inline-bg": "rgba(255,255,255,0.07)", "--code-text": "#F0B593",
					"--hover-bg": "rgba(255,255,255,0.07)", "--input-bg": "rgba(255,255,255,0.045)",
					"--link": "#8BB8D6", "--user-bubble": "#34322E",
				],
			)
}

/// Catppuccin.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct CatppuccinTheme {
	static let themeID = "catppuccin"
	static let themeLabel = "Catppuccin"
	static let themeSwatch = ["#CBA6F7", "#CDD6F4", "#C6A0F6", "#7C6FA8",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#EFF1F5", .colorBgInset: "#EFEFF3", .colorBgSubtle: "#E6E9EF",
					.colorBorder: "#CCD0DA", .colorBorderStrong: "#BCC0CC", .colorPrimarySolid: "#8839EF",
					.colorPrimarySolidHover: "#8839EF", .colorText: "#4C4F69", .colorTextMuted: "#7C7F93",
				],
				customTokens: ["--accent-border": "rgba(136,57,239,0.18)",
					"--accent-soft": "rgba(136,57,239,0.09)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-bg": "#E6E9EF", "--code-inline-bg": "rgba(30,30,46,0.06)", "--code-text": "#8839EF",
					"--hover-bg": "rgba(30,30,46,0.05)", "--input-bg": "rgba(30,30,46,0.035)", "--link": "#1E66F5",
					"--user-bubble": "#E6E9EF",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#1E1E2E", .colorBgInset: "#23232C", .colorBgRaised: "#313244",
					.colorBgSubtle: "#181825", .colorBorder: "#45475A", .colorBorderStrong: "#585B70",
					.colorPrimarySolid: "#CBA6F7", .colorPrimarySolidHover: "#CBA6F7", .colorText: "#CDD6F4",
					.colorTextMuted: "#A6ADC8",
				],
				customTokens: ["--accent-border": "rgba(203,166,247,0.22)",
					"--accent-soft": "rgba(203,166,247,0.12)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-bg": "#181825", "--code-inline-bg": "rgba(255,255,255,0.07)", "--code-text": "#CBA6F7",
					"--hover-bg": "rgba(255,255,255,0.07)", "--input-bg": "rgba(255,255,255,0.045)",
					"--link": "#89B4FA", "--user-bubble": "#313244",
				],
			)
}

/// Hepburn.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct HepburnTheme {
	static let themeID = "hepburn"
	static let themeLabel = "Hepburn"
	static let themeSwatch = ["#F278AD", "#F472B6", "#F9A8D4", "#FBCFE8",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#fff3f7", .colorBgInset: "rgba(242,120,173,0.04)", .colorBgRaised: "#fff9fb",
					.colorBgSubtle: "#fbe4ed", .colorBorder: "#ecc8d5",
					.colorBorderStrong: "rgba(242,120,173,0.18)", .colorDanger: "#c0392b",
					.colorPrimarySolid: "#d44a7a", .colorPrimarySolidHover: "#c6246a", .colorSuccess: "#3d8b40",
					.colorText: "#3d1a28", .colorTextMuted: "#906270", .colorWarning: "#e67e22",
				],
				customTokens: ["--accent-border": "rgba(242,120,173,0.20)",
					"--accent-soft": "rgba(242,120,173,0.10)", "--border-subtle": "rgba(242,120,173,0.10)",
					"--code-bg": "#fbe6ef", "--code-inline-bg": "rgba(242,120,173,0.12)", "--code-text": "#d44a7a",
					"--hover-bg": "rgba(242,120,173,0.08)", "--input-bg": "rgba(242,120,173,0.06)",
					"--link": "#8671e5", "--user-bubble": "rgba(242, 120, 173, 0.10)", "--warning": "#e67e22",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#110a0f", .colorBgInset: "rgba(242,120,173,0.05)", .colorBgRaised: "#241420",
					.colorBgSubtle: "#1e0f19", .colorBorder: "#311a28",
					.colorBorderStrong: "rgba(242,120,173,0.20)", .colorDanger: "#ff5c5c",
					.colorPrimarySolid: "#f278ad", .colorPrimarySolidHover: "#f278ad", .colorSuccess: "#6cd4a5",
					.colorText: "#f2e4ee", .colorTextMuted: "#c8a4b8", .colorWarning: "#f2b370",
				],
				customTokens: ["--accent-border": "rgba(242,120,173,0.25)",
					"--accent-soft": "rgba(242,120,173,0.14)", "--border-subtle": "rgba(242,120,173,0.12)",
					"--code-bg": "#1e0f19", "--code-inline-bg": "rgba(242,120,173,0.22)", "--code-text": "#f5a0c5",
					"--hover-bg": "rgba(242,120,173,0.12)", "--input-bg": "rgba(242,120,173,0.08)",
					"--link": "#8671e5", "--user-bubble": "rgba(242, 120, 173, 0.13)", "--warning": "#f2b370",
				],
			)
}

/// Nous.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct NousTheme {
	static let themeID = "nous"
	static let themeLabel = "Nous"
	static let themeSwatch = ["#4682B4", "#93C5FD", "#4682B4", "#1E3A8A",]

	static let palette = ThemePalette(
				tokens: [.colorBgInset: "rgba(0,0,0,.025)", .colorBgSubtle: "#F5F5F5", .colorBorder: "#D0D8E0",
					.colorBorderStrong: "rgba(0,0,0,0.15)", .colorDanger: "#C62828", .colorPrimarySolid: "#4682B4",
					.colorPrimarySolidHover: "#2C5F88", .colorSuccess: "#3D8B40", .colorText: "#1A2A3A",
					.colorTextMuted: "#6B7B8B", .colorWarning: "#E68A00",
				],
				customTokens: ["--accent-border": "rgba(70,130,180,0.12)",
					"--accent-soft": "rgba(70,130,180,0.06)", "--border-subtle": "rgba(0,0,0,.08)",
					"--code-bg": "#F0F2F5", "--code-inline-bg": "rgba(70,130,180,.08)", "--code-text": "#2C5F88",
					"--hover-bg": "rgba(0,0,0,.05)", "--input-bg": "rgba(0,0,0,.03)", "--link": "#4682B4",
					"--user-bubble": "rgba(70, 130, 180, 0.10)", "--warning": "#E68A00",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#0A0E14", .colorBgInset: "rgba(255,255,255,.025)", .colorBgRaised: "#111820",
					.colorBgSubtle: "#0F1419", .colorBorder: "#1E2A3A",
					.colorBorderStrong: "rgba(255,255,255,0.14)", .colorDanger: "#EF5350",
					.colorPrimarySolid: "#4682B4", .colorPrimarySolidHover: "#7EB6E0", .colorSuccess: "#4CAF50",
					.colorText: "#C8D6E5", .colorTextMuted: "#5A6A7A", .colorWarning: "#FFA726",
				],
				customTokens: ["--accent-border": "rgba(70,130,180,0.2)",
					"--accent-soft": "rgba(70,130,180,0.1)", "--border-subtle": "rgba(255,255,255,.075)",
					"--code-bg": "#111820", "--code-inline-bg": "rgba(70,130,180,.12)", "--code-text": "#7EB6E0",
					"--hover-bg": "rgba(255,255,255,.06)", "--input-bg": "rgba(255,255,255,.04)",
					"--link": "#4682B4", "--user-bubble": "rgba(70, 130, 180, 0.13)", "--warning": "#FFA726",
				],
			)
}

/// Neon.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct NeonTheme {
	static let themeID = "neon"
	static let themeLabel = "Neon"
	static let themeSwatch = ["#00B8FF", "#A855F7", "#00B8FF", "#22D3EE",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F7F9FB", .colorBgInset: "#ECF0F4", .colorBgSubtle: "#F1F4F7",
					.colorBorder: "#D9E0E8", .colorBorderStrong: "#BFCAD6", .colorDanger: "#E6386E",
					.colorDangerSoft: "rgba(230, 56, 110, 0.10)", .colorPrimarySolid: "#0896C2",
					.colorPrimarySolidHover: "#067A9F", .colorSuccess: "#00A97F", .colorText: "#1B2230",
					.colorTextMuted: "#68788C", .scrollbarThumb: "#CAD5E0",
				],
				customTokens: ["--accent-border": "rgba(0, 152, 214, 0.42)",
					"--accent-soft": "rgba(0, 184, 255, 0.09)", "--code-bg": "#E9EFF5", "--link": "#7B61FF",
					"--shadow": "0 2px 12px rgba(0, 80, 140, 0.08)", "--user-bubble": "rgba(0, 184, 255, 0.09)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#0B0D12", .colorBgInset: "#1A1E28", .colorBgRaised: "#12151C",
					.colorBgSubtle: "#0E1116", .colorBorder: "#252B38", .colorBorderStrong: "#333B4C",
					.colorDanger: "#FF3D71", .colorDangerSoft: "rgba(255, 61, 113, 0.14)",
					.colorPrimarySolid: "#00E5FF", .colorPrimarySolidHover: "#33EBFF", .colorSuccess: "#00F0A0",
					.colorText: "#E9EEF7", .colorTextMuted: "#7E8AA0", .scrollbarThumb: "#2E3546",
				],
				customTokens: ["--accent-border": "rgba(0, 229, 255, 0.5)",
					"--accent-soft": "rgba(0, 229, 255, 0.14)", "--code-bg": "#1A1E28", "--link": "#7B61FF",
					"--shadow": "0 2px 14px rgba(0, 0, 0, 0.45)", "--user-bubble": "rgba(0, 229, 255, 0.12)",
				],
			)
}

/// Neon Soft.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct NeonSoftTheme {
	static let themeID = "neon-soft"
	static let themeLabel = "Neon Soft"
	static let themeSwatch = ["#C084FC", "#C084FC", "#67E8F9", "#BAE6FD",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F8F7FC", .colorBgInset: "rgba(147,51,234,.025)", .colorBgSubtle: "#F0EEF8",
					.colorBorder: "#D8D4EC", .colorBorderStrong: "rgba(0,0,0,0.12)", .colorDanger: "#DC2626",
					.colorPrimarySolid: "#9333EA", .colorSuccess: "#059669", .colorText: "#1E1B2E",
					.colorTextMuted: "#6E6888", .colorWarning: "#D97706",
				],
				customTokens: ["--accent-border": "rgba(147,51,234,0.12)",
					"--accent-soft": "rgba(147,51,234,0.06)", "--border-subtle": "rgba(147,51,234,.08)",
					"--code-bg": "#F0EDF8", "--code-inline-bg": "rgba(147,51,234,.08)", "--code-text": "#6D28D9",
					"--hover-bg": "rgba(147,51,234,.05)", "--input-bg": "rgba(147,51,234,.03)", "--link": "#7C3AED",
					"--user-bubble": "rgba(192, 132, 252, 0.10)", "--warning": "#D97706",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#181428", .colorBgInset: "rgba(179,71,255,.03)", .colorBgRaised: "#1c1732",
					.colorBgSubtle: "#141024", .colorBorder: "#2a2448", .colorBorderStrong: "rgba(179,71,255,0.15)",
					.colorDanger: "#ff4466", .colorPrimarySolid: "#b347ff", .colorPrimarySolidHover: "#c8a0ff",
					.colorSuccess: "#00dd88", .colorText: "#e8e6f8", .colorTextMuted: "#8a85aa",
					.colorWarning: "#ffaa33",
				],
				customTokens: ["--accent-border": "rgba(179,71,255,0.20)",
					"--accent-soft": "rgba(179,71,255,0.10)", "--border-subtle": "rgba(179,71,255,.08)",
					"--code-bg": "#121020", "--code-inline-bg": "rgba(179,71,255,.10)", "--code-text": "#c8c0f0",
					"--hover-bg": "rgba(179,71,255,.06)", "--input-bg": "rgba(179,71,255,.04)", "--link": "#a78bfa",
					"--user-bubble": "rgba(192, 132, 252, 0.13)", "--warning": "#ffaa33",
				],
			)
}

/// Neon Paint.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct NeonPaintTheme {
	static let themeID = "neon-paint"
	static let themeLabel = "Neon Paint"
	static let themeSwatch = ["#EC4899", "#EC4899", "#22D3EE", "#FDE047",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F5F0FF", .colorBgInset: "rgba(255,45,149,.025)", .colorBgSubtle: "#EDE6F8",
					.colorBorder: "#D4C8EE", .colorBorderStrong: "rgba(0,0,0,0.12)", .colorDanger: "#FF1744",
					.colorPrimarySolid: "#FF2D95", .colorPrimarySolidHover: "#C2185B", .colorSuccess: "#00E676",
					.colorText: "#1A1028", .colorTextMuted: "#6E5A88", .colorWarning: "#FFB300",
				],
				customTokens: ["--accent-border": "rgba(255,45,149,0.12)",
					"--accent-soft": "rgba(255,45,149,0.06)", "--border-subtle": "rgba(255,45,149,.08)",
					"--code-bg": "#EDE6F8", "--code-inline-bg": "rgba(255,45,149,.08)", "--code-text": "#D81B60",
					"--hover-bg": "rgba(255,45,149,.05)", "--input-bg": "rgba(255,45,149,.03)", "--link": "#00E5FF",
					"--user-bubble": "rgba(236, 72, 153, 0.10)", "--warning": "#FFB300",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#0D0A16", .colorBgInset: "rgba(255,45,149,.03)", .colorBgRaised: "#12101e",
					.colorBgSubtle: "#0A0712", .colorBorder: "#2a1f40", .colorBorderStrong: "rgba(255,45,149,0.15)",
					.colorDanger: "#FF1744", .colorPrimarySolid: "#FF2D95", .colorPrimarySolidHover: "#FF80BF",
					.colorSuccess: "#00E676", .colorText: "#f0e8ff", .colorTextMuted: "#9a8ab8",
					.colorWarning: "#FFB300",
				],
				customTokens: ["--accent-border": "rgba(255,45,149,0.20)",
					"--accent-soft": "rgba(255,45,149,0.10)", "--border-subtle": "rgba(255,45,149,.08)",
					"--code-bg": "#080510", "--code-inline-bg": "rgba(255,45,149,.12)", "--code-text": "#f0c0e8",
					"--hover-bg": "rgba(255,45,149,.06)", "--input-bg": "rgba(255,45,149,.04)", "--link": "#00E5FF",
					"--user-bubble": "rgba(236, 72, 153, 0.13)", "--warning": "#FFB300",
				],
			)
}

/// Geist Contrast.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct GeistContrastTheme {
	static let themeID = "geist-contrast"
	static let themeLabel = "Geist Contrast"
	static let themeSwatch = ["#FFF175", "#000000", "#FFFFFF", "#FFF175",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#ffffff", .colorBgInset: "#fafafa", .colorBgRaised: "#ffffff",
					.colorBgSubtle: "#fafafa", .colorBorder: "#eaeaea", .colorBorderStrong: "#d4d4d4",
					.colorDanger: "#e5484d", .colorPrimarySolid: "#0070f3", .colorPrimarySolidHover: "#005bd1",
					.colorSuccess: "#007a45", .colorText: "#111111", .colorTextMuted: "#666666",
					.colorWarning: "#b45309",
				],
				customTokens: ["--accent-border": "rgba(0,112,243,.16)", "--accent-soft": "rgba(0,112,243,.075)",
					"--border-subtle": "#ededed", "--code-bg": "#fafafa", "--code-inline-bg": "#f5f5f5",
					"--code-text": "#111111", "--hover-bg": "#f5f5f5", "--input-bg": "#ffffff", "--link": "#0070f3",
					"--user-bubble": "rgba(255, 241, 117, 0.10)", "--warning": "#b45309",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#000000", .colorBgInset: "#111111", .colorBgRaised: "#0a0a0a",
					.colorBgSubtle: "#050505", .colorBorder: "#262626", .colorBorderStrong: "#3f3f3f",
					.colorDanger: "#ff6369", .colorPrimarySolid: "#FFF175", .colorPrimarySolidHover: "#f5e65f",
					.colorSuccess: "#3dd68c", .colorText: "#ededed", .colorTextMuted: "#a1a1a1",
					.colorWarning: "#f5a524",
				],
				customTokens: ["--accent-border": "rgba(255,241,117,.14)",
					"--accent-soft": "rgba(255,241,117,.075)", "--border-subtle": "#171717", "--code-bg": "#0a0a0a",
					"--code-inline-bg": "#171717", "--code-text": "#f5f5f5", "--hover-bg": "#111111",
					"--input-bg": "#0a0a0a", "--link": "#FFF175", "--user-bubble": "rgba(255, 241, 117, 0.13)",
					"--warning": "#f5a524",
				],
			)
}

/// Zeus.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct ZeusTheme {
	static let themeID = "zeus"
	static let themeLabel = "Zeus"
	static let themeSwatch = ["#E5B75D", "#E5B75D", "#C9A227", "#365314",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F6F3EE", .colorBgInset: "#EEE9E4", .colorBgRaised: "#FEFBF7",
					.colorBgSubtle: "#F1EEEC", .colorBorder: "#E2DCD5", .colorBorderStrong: "#D3CCC4",
					.colorPrimarySolid: "#E5B75D", .colorPrimarySolidHover: "#C9A227", .scrollbarThumb: "#D8CDBC",
				],
				customTokens: ["--accent-border": "rgba(229, 183, 93, 0.45)",
					"--accent-soft": "rgba(229, 183, 93, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#C9A227",
					"--user-bubble": "rgba(229, 183, 93, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#0F0F0F", .colorBgInset: "rgba(255,255,255,.03)", .colorBgRaised: "#181818",
					.colorBgSubtle: "#111111", .colorBorder: "#2A2A1E", .colorBorderStrong: "rgba(255,215,0,0.18)",
					.colorPrimarySolid: "#E5B75D", .colorPrimarySolidHover: "#C9A227",
				],
				customTokens: ["--accent-border": "rgba(229, 183, 93, 0.50)",
					"--accent-soft": "rgba(229, 183, 93, 0.15)", "--border-subtle": "rgba(255,215,0,.08)",
					"--code-bg": "#181818", "--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255,215,0,.06)", "--input-bg": "rgba(255,255,255,.04)", "--link": "#C9A227",
					"--user-bubble": "rgba(229, 183, 93, 0.13)",
				],
			)
}

/// Verdigris.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct VerdigrisTheme {
	static let themeID = "verdigris"
	static let themeLabel = "Verdigris"
	static let themeSwatch = ["#2F5D50", "#C0A080", "#2F5D50", "#3A3A42",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#E9ECED", .colorBgInset: "#DCE0E3", .colorBgRaised: "#F5F7F6",
					.colorBgSubtle: "#E6E9EB", .colorBorder: "#C9CFD3", .colorBorderStrong: "#B6BEC2",
					.colorPrimarySolid: "#2F5D50", .colorPrimarySolidHover: "#24493F", .scrollbarThumb: "#ABB6B9",
				],
				customTokens: ["--accent-border": "rgba(47, 93, 80, 0.45)",
					"--accent-soft": "rgba(47, 93, 80, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#24493F",
					"--user-bubble": "rgba(47, 93, 80, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#0F1714", .colorBgInset: "rgba(255,255,255,.02)", .colorBgRaised: "#16211C",
					.colorBgSubtle: "#121D18", .colorBorder: "#22342C", .colorBorderStrong: "rgba(200,154,90,0.10)",
					.colorDanger: "#D26A6A", .colorPrimarySolid: "#C89A5A", .colorPrimarySolidHover: "#E4C28D",
					.colorSuccess: "#719A68", .colorText: "#F3ECDD", .colorTextMuted: "#A8B4A5",
					.colorWarning: "#D1A45C",
				],
				customTokens: ["--accent-border": "rgba(47, 93, 80, 0.50)",
					"--accent-soft": "rgba(47, 93, 80, 0.15)", "--border-subtle": "rgba(255,255,255,.06)",
					"--code-bg": "#111B17", "--code-inline-bg": "rgba(200,154,90,.08)", "--code-text": "#D6AE74",
					"--hover-bg": "rgba(255,255,255,.045)", "--input-bg": "rgba(255,255,255,.025)",
					"--link": "#C89A5A", "--user-bubble": "rgba(47, 93, 80, 0.13)", "--warning": "#D1A45C",
				],
			)
}

/// Dracula.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct DraculaTheme {
	static let themeID = "dracula"
	static let themeLabel = "Dracula"
	static let themeSwatch = ["#BD93F9", "#BD93F9", "#FF79C6", "#50FA7B",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#F8F7FC", .colorBgInset: "#EFEDF7", .colorBgSubtle: "#F4F2FA",
					.colorBorder: "#DDD9EC", .colorBorderStrong: "#C6C0DC", .colorDanger: "#C94A5E",
					.colorDangerSoft: "rgba(201, 74, 94, 0.10)", .colorPrimarySolid: "#6C4FA1",
					.colorPrimarySolidHover: "#58408A", .colorSuccess: "#3B8C5A", .colorText: "#282433",
					.colorTextMuted: "#7D7792", .scrollbarThumb: "#C9C4DD",
				],
				customTokens: ["--accent-border": "rgba(108, 79, 161, 0.42)",
					"--accent-soft": "rgba(108, 79, 161, 0.10)", "--code-bg": "#ECEAF4", "--link": "#4E7CE0",
					"--shadow": "0 2px 12px rgba(60, 50, 100, 0.08)", "--user-bubble": "rgba(108, 79, 161, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#282A36", .colorBgInset: "#383A4A", .colorBgRaised: "#2F3240",
					.colorBgSubtle: "#2B2D3B", .colorBorder: "#44475A", .colorBorderStrong: "#565975",
					.colorDanger: "#FF5555", .colorDangerSoft: "rgba(255, 85, 85, 0.15)",
					.colorPrimarySolid: "#BD93F9", .colorPrimarySolidHover: "#CBA3FA", .colorSuccess: "#50FA7B",
					.colorText: "#F8F8F2", .colorTextMuted: "#8C90A6", .scrollbarThumb: "#4B4E61",
				],
				customTokens: ["--accent-border": "rgba(189, 147, 249, 0.5)",
					"--accent-soft": "rgba(189, 147, 249, 0.15)", "--code-bg": "#383A4A", "--link": "#8BE9FD",
					"--shadow": "0 2px 14px rgba(0, 0, 0, 0.45)", "--user-bubble": "rgba(189, 147, 249, 0.13)",
				],
			)
}

/// Gruvbox.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct GruvboxTheme {
	static let themeID = "gruvbox"
	static let themeLabel = "Gruvbox"
	static let themeSwatch = ["#D79921", "#D79921", "#FE8019", "#B8BB26",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#FBF1C7", .colorBgInset: "#EBDBB2", .colorBgRaised: "#FFFDF5",
					.colorBgSubtle: "#F2E5BC", .colorBorder: "#D5C4A1", .colorBorderStrong: "#BDAE8B",
					.colorPrimarySolid: "#D79921", .colorPrimarySolidHover: "#B07E15", .colorText: "#3C3836",
					.colorTextMuted: "#7C6F64", .scrollbarThumb: "#D5C4A1",
				],
				customTokens: ["--accent-border": "rgba(215, 153, 33, 0.45)",
					"--accent-soft": "rgba(215, 153, 33, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#B07E15",
					"--user-bubble": "rgba(215, 153, 33, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#282828", .colorBgInset: "#45403D", .colorBgRaised: "#3C3836",
					.colorBgSubtle: "#32302F", .colorBorder: "#504945", .colorBorderStrong: "#665C54",
					.colorPrimarySolid: "#D79921", .colorPrimarySolidHover: "#B07E15", .colorText: "#EBDBB2",
					.colorTextMuted: "#A89984", .scrollbarThumb: "#504945",
				],
				customTokens: ["--accent-border": "rgba(215, 153, 33, 0.50)",
					"--accent-soft": "rgba(215, 153, 33, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#B07E15", "--user-bubble": "rgba(215, 153, 33, 0.15)",
				],
			)
}

/// One Dark.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct OneDarkTheme {
	static let themeID = "one-dark"
	static let themeLabel = "One Dark"
	static let themeSwatch = ["#61AFEF", "#61AFEF", "#C678DD", "#98C379",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#ECF2F8", .colorBgInset: "#E1E9F3", .colorBgRaised: "#F7FBFE",
					.colorBgSubtle: "#E9EEF5", .colorBorder: "#D0DBE9", .colorBorderStrong: "#BECBDC",
					.colorPrimarySolid: "#61AFEF", .colorPrimarySolidHover: "#4A93CC", .scrollbarThumb: "#B7CBE1",
				],
				customTokens: ["--accent-border": "rgba(97, 175, 239, 0.45)",
					"--accent-soft": "rgba(97, 175, 239, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#4A93CC",
					"--user-bubble": "rgba(97, 175, 239, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#181E27", .colorBgInset: "#293140", .colorBgRaised: "#1E222C",
					.colorBgSubtle: "#1B202A", .colorBorder: "#333E50", .colorBorderStrong: "#404D61",
					.colorPrimarySolid: "#61AFEF", .colorPrimarySolidHover: "#4A93CC", .scrollbarThumb: "#3E526A",
				],
				customTokens: ["--accent-border": "rgba(97, 175, 239, 0.50)",
					"--accent-soft": "rgba(97, 175, 239, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#4A93CC", "--user-bubble": "rgba(97, 175, 239, 0.13)",
				],
			)
}

/// Tokyo Night.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct TokyoNightTheme {
	static let themeID = "tokyo-night"
	static let themeLabel = "Tokyo Night"
	static let themeSwatch = ["#7AA2F7", "#7AA2F7", "#BB9AF7", "#9ECE6A",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#EEF1F9", .colorBgInset: "#E3E7F3", .colorBgRaised: "#F8FAFF",
					.colorBgSubtle: "#EBEDF5", .colorBorder: "#D3D9EA", .colorBorderStrong: "#C2C9DD",
					.colorPrimarySolid: "#7AA2F7", .colorPrimarySolidHover: "#5E88E8", .scrollbarThumb: "#BEC8E3",
				],
				customTokens: ["--accent-border": "rgba(122, 162, 247, 0.45)",
					"--accent-soft": "rgba(122, 162, 247, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#5E88E8",
					"--user-bubble": "rgba(122, 162, 247, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#1A1D28", .colorBgInset: "#2C3040", .colorBgRaised: "#20222D",
					.colorBgSubtle: "#1D1F2A", .colorBorder: "#373D51", .colorBorderStrong: "#444B62",
					.colorPrimarySolid: "#7AA2F7", .colorPrimarySolidHover: "#5E88E8", .scrollbarThumb: "#454F6C",
				],
				customTokens: ["--accent-border": "rgba(122, 162, 247, 0.50)",
					"--accent-soft": "rgba(122, 162, 247, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#5E88E8", "--user-bubble": "rgba(122, 162, 247, 0.13)",
				],
			)
}

/// Rosé Pine.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct RosepineTheme {
	static let themeID = "rosepine"
	static let themeLabel = "Rosé Pine"
	static let themeSwatch = ["#B4637A", "#E0DEF4", "#B4637A", "#8A7AB5",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#FAF4F4", .colorBgInset: "#F3E9E9", .colorBgRaised: "#FFFBFB",
					.colorBgSubtle: "#F7EEEE", .colorBorder: "#E4D6D6", .colorBorderStrong: "#D0BABA",
					.colorDanger: "#C04C4C", .colorDangerSoft: "rgba(192, 76, 76, 0.10)",
					.colorPrimarySolid: "#B4637A", .colorPrimarySolidHover: "#9C4D63", .colorSuccess: "#6F9F5C",
					.colorText: "#32211F", .colorTextMuted: "#8F7777", .scrollbarThumb: "#DCC7C6",
				],
				customTokens: ["--accent-border": "rgba(180, 99, 122, 0.42)",
					"--accent-soft": "rgba(180, 99, 122, 0.10)", "--code-bg": "#F2E7E7", "--link": "#9A7ED9",
					"--shadow": "0 2px 12px rgba(120, 60, 70, 0.08)", "--user-bubble": "rgba(180, 99, 122, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#191724", .colorBgInset: "#26233A", .colorBgRaised: "#1F1D2E",
					.colorBgSubtle: "#1B1926", .colorBorder: "#322F4A", .colorBorderStrong: "#403E5C",
					.colorDanger: "#EB6F92", .colorDangerSoft: "rgba(235, 111, 146, 0.14)",
					.colorPrimarySolid: "#EBBCBA", .colorPrimarySolidHover: "#F0C6C4", .colorSuccess: "#9CCFD8",
					.colorText: "#E0DEF4", .colorTextMuted: "#908CAA", .scrollbarThumb: "#3C3955",
				],
				customTokens: ["--accent-border": "rgba(235, 188, 186, 0.5)",
					"--accent-soft": "rgba(235, 188, 186, 0.14)", "--code-bg": "#26233A", "--link": "#9CCFD8",
					"--shadow": "0 2px 14px rgba(0, 0, 0, 0.4)", "--user-bubble": "rgba(235, 188, 186, 0.13)",
				],
			)
}

/// Solarized Dark.
///
/// `themeSwatch` is `[accent, dot, dot, dot]`: arc's own shape (the accent is the tile's
/// selection border, the three dots its preview), which predates the provider contract.
@Theme(base: ArcBaseTheme.self)
struct SolarizedDarkTheme {
	static let themeID = "solarized-dark"
	static let themeLabel = "Solarized Dark"
	static let themeSwatch = ["#268BD2", "#268BD2", "#2AA198", "#859900",]

	static let palette = ThemePalette(
				tokens: [.colorBg: "#E8EFF6", .colorBgInset: "#DBE5F0", .colorBgRaised: "#F4F9FD",
					.colorBgSubtle: "#E6ECF3", .colorBorder: "#C8D6E5", .colorBorderStrong: "#B5C5D7",
					.colorPrimarySolid: "#268BD2", .colorPrimarySolidHover: "#1B6FA8", .scrollbarThumb: "#A8C2DA",
				],
				customTokens: ["--accent-border": "rgba(38, 139, 210, 0.45)",
					"--accent-soft": "rgba(38, 139, 210, 0.10)", "--border-subtle": "rgba(0, 0, 0, 0.08)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.05)", "--code-text": "#1D1D24",
					"--hover-bg": "rgba(0, 0, 0, 0.04)", "--input-bg": "rgba(0, 0, 0, 0.02)", "--link": "#1B6FA8",
					"--user-bubble": "rgba(38, 139, 210, 0.10)",
				],
			)

	static let dark = ThemePalette(
				tokens: [.colorBg: "#141B25", .colorBgInset: "#232D3D", .colorBgRaised: "#1C212B",
					.colorBgSubtle: "#181E28", .colorBorder: "#2B394C", .colorBorderStrong: "#37475C",
					.colorPrimarySolid: "#268BD2", .colorPrimarySolidHover: "#1B6FA8", .scrollbarThumb: "#304963",
				],
				customTokens: ["--accent-border": "rgba(38, 139, 210, 0.50)",
					"--accent-soft": "rgba(38, 139, 210, 0.15)", "--border-subtle": "rgba(255, 255, 255, 0.075)",
					"--code-inline-bg": "rgba(0, 0, 0, 0.35)", "--code-text": "#E6E6EC",
					"--hover-bg": "rgba(255, 255, 255, 0.06)", "--input-bg": "rgba(255, 255, 255, 0.04)",
					"--link": "#1B6FA8", "--user-bubble": "rgba(38, 139, 210, 0.13)",
				],
			)
}

/// arc's 27 schemes, in the order the settings grid shows them.
///
/// `all` is computed, not stored: an existential metatype array is not `Sendable`, and
/// Swift 6 rejects a stored one as global mutable state.
enum ArcThemeCatalog: ThemeCatalog {
	static var all: [any WebUIThemeProvider.Type] {
		[
			ArcDefaultTheme.self,
			AresTheme.self,
			MonoTheme.self,
			GraphiteTheme.self,
			GithubTheme.self,
			CodexTheme.self,
			TerracottaTheme.self,
			SlateTheme.self,
			PoseidonTheme.self,
			SisyphusTheme.self,
			CharizardTheme.self,
			SiennaTheme.self,
			CatppuccinTheme.self,
			HepburnTheme.self,
			NousTheme.self,
			NeonTheme.self,
			NeonSoftTheme.self,
			NeonPaintTheme.self,
			GeistContrastTheme.self,
			ZeusTheme.self,
			VerdigrisTheme.self,
			DraculaTheme.self,
			GruvboxTheme.self,
			OneDarkTheme.self,
			TokyoNightTheme.self,
			RosepineTheme.self,
			SolarizedDarkTheme.self,
		]
	}

	static var defaultTheme: any WebUIThemeProvider.Type { ArcDefaultTheme.self }
}
