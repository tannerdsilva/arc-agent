// MARK: - Type sizes

/// The user-facing text-size axis. The stylesheet that consumes it (`--font-size`) lives in
/// the `ArcTheme` target, next to the scheme catalog, so the asset tool can render and
/// compress the whole sheet at build time.
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
    /// "Aa" preview size inside the picker card (mirrors arc agent webui).
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
