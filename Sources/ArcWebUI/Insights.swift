import Foundation
import ArcAgentCore
import WebUI

// MARK: - Insights data model
//
// Durable analytics for the Insights view (persisted to
// ~/.arc-agent-webui/insights.json). Skill usage counters come from the
// in-app tool loop (skill_view / skill_manage) and panel views; daily token
// burn comes from the real `usage` reported by the LLM on streamed turns.

/// Per-skill usage counters.
struct SkillStat: Codable, Equatable {
    /// Skill-related tool invocations (skill_view / skill_manage).
    var uses: Int = 0
    /// Times the skill content was viewed (skill_view calls + panel opens).
    var views: Int = 0
    /// Content changes applied via skill_manage (patch/edit).
    var patches: Int = 0

    init() {}
}

/// The durable analytics store.
struct InsightsData: Codable, Equatable {
    /// Skill name -> counters.
    var skillStats: [String: SkillStat] = [:]
    /// Calendar day (yyyy-MM-dd) -> total tokens reported by the LLM.
    var dailyTokens: [String: Int] = [:]

    init() {}

    // Tolerant decode: unknown shapes fall back to defaults so a missing key
    // (or a future version of the file) never wipes previously stored data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skillStats = try c.decodeIfPresent([String: SkillStat].self, forKey: .skillStats) ?? [:]
        dailyTokens = try c.decodeIfPresent([String: Int].self, forKey: .dailyTokens) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case skillStats, dailyTokens
    }
}

// MARK: - AppState integration

extension AppState {

    static var insightsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc-agent-webui/insights.json")
    }

    static func loadInsights() -> InsightsData {
        guard let data = try? Data(contentsOf: insightsURL) else { return InsightsData() }
        return (try? JSONDecoder().decode(InsightsData.self, from: data)) ?? InsightsData()
    }

    func saveInsights() {
        let url = Self.insightsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(insights) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Recording

    /// Record a skill-related event (bump only the counters passed non-zero).
    func recordSkillEvent(name: String, uses: Int = 0, views: Int = 0, patches: Int = 0) {
        guard !name.isEmpty else { return }
        var stat = insights.skillStats[name] ?? SkillStat()
        stat.uses += uses
        stat.views += views
        stat.patches += patches
        insights.skillStats[name] = stat
        saveInsights()
    }

    /// Record real tokens burned (from the LLM's usage report) for today.
    func recordTokensBurned(_ n: Int) {
        guard n > 0 else { return }
        insights.dailyTokens[Self.dayString(Date()), default: 0] += n
        saveInsights()
    }

    /// Map a skill-related tool invocation onto the usage counters.
    /// Every skill tool call counts as a use; skill_view also counts as a
    /// view; skill_manage patch/edit additionally counts as a patch.
    func recordSkillToolUse(toolName: String, args: [String: Any]) {
        let name = args["name"] as? String ?? ""
        guard !name.isEmpty else { return }
        switch toolName {
        case "skill_view":
            recordSkillEvent(name: name, uses: 1, views: 1)
        case "skill_manage":
            let action = args["action"] as? String ?? ""
            if action == "patch" || action == "edit" {
                recordSkillEvent(name: name, uses: 1, patches: 1)
            } else {
                recordSkillEvent(name: name, uses: 1)
            }
        default:
            break
        }
    }

    /// Change the daily-token graph range (7/30/90/365).
    func setInsightsRange(_ days: Int) {
        let d = [7, 30, 90, 365].contains(days) ? days : 30
        insightsRangeDays = d
        settings.insightsRangeDays = d
        saveSettings()
    }

    // MARK: Helpers

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// "Sep 2" style day label for the graph's x-axis.
    static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// "1,234" style number formatting.
    static func fmtCount(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Insights view (panel)

    /// the insights sidebar: the range selector that drives the daily graph.
    func insightsPanel() -> some WebUI.View {
        let days = [7, 30, 90, 365]
        return Group {
            Div(class: "panel-head") {
                Span(class: "panel-title") { Text("Insights") }
            }
            Div(class: "detail-sub") { Text("Usage analytics") }
                .attribute("style", "padding:4px 2px 10px")
            Div(class: "ins-range-wrap") {
                Label("Daily token range", for: "ins-range", class: "ins-range-label")
                Select(
                    id: "ins-range",
                    options: days.map { SelectOption(value: "\($0)", label: "Last \($0) days") },
                    selected: "\(insightsRangeDays)"
                )
                .wire("ins-range", on: .change)
                .data("no-restore", "")
            }
        }
    }

    // MARK: Insights view (main)

    /// one headline number with its icon. `icon` is the catalogue case, not a
    /// pre-rendered glyph: the helper emits the svg itself, so no call site
    /// hands it markup.
    private func statBubble(label: String, value: String, icon: IconName) -> some WebUI.View {
        Div(class: "ins-bubble") {
            Div(class: "ins-bubble-icon") { WebUIIcon(icon, size: .large) }
            Div(class: "ins-bubble-value") { Text(value) }
            Div(class: "ins-bubble-label") { Text(label) }
        }
    }

    private func statBox(label: String, value: String, icon: IconName) -> some WebUI.View {
        Div(class: "ins-stat-box") {
            Div(class: "ins-stat-icon") { WebUIIcon(icon, size: .large) }
            Div(class: "ins-stat-value") { Text(value) }
            Div(class: "ins-stat-label") { Text(label) }
        }
    }

    func insightsMain() -> some WebUI.View {
        let totalUses = insights.skillStats.values.reduce(0) { $0 + $1.uses }
        // "Skills Used" counts skills that were actually invoked (uses > 0),
        // not merely touched (views/patches). "touched" is a broader metric
        // that includes views and patches — keep the label honest.
        let used = insights.skillStats.values.filter { $0.uses > 0 }.count
        let skillNames = Array(Set(skills.map(\.name)).union(insights.skillStats.keys)).sorted()

        // Top 10 skills by times used (keeps the panel uncluttered).
        let ranked = skillNames.sorted { a, b in
            let sa = insights.skillStats[a] ?? SkillStat()
            let sb = insights.skillStats[b] ?? SkillStat()
            if sa.uses != sb.uses { return sa.uses > sb.uses }
            if sa.views != sb.views { return sa.views > sb.views }
            if sa.patches != sb.patches { return sa.patches > sb.patches }
            return a < b
        }
        let topSkills = Array(ranked.prefix(10))
        var rows: [any View] = topSkills.map { name -> any View in
            let s = insights.skillStats[name] ?? SkillStat()
            let pct = totalUses > 0
                ? String(format: "%.1f%%", Double(s.uses) / Double(totalUses) * 100)
                : "0.0%"
            return El("tr", [], [
                El("td", [("class", "ins-t-name")], [Text(name)]),
                El("td", [], [Text("\(s.uses)")]),
                El("td", [], [Text("\(s.views)")]),
                El("td", [], [Text("\(s.patches)")]),
                El("td", [], [Text(pct)]),
            ])
        }
        if ranked.count > 10 {
            rows.append(El("tr", [("class", "ins-more-row")], [
                El("td", [("colspan", "5")], [Text("… and \(ranked.count - 10) more skills")]),
            ]))
        }
        let heads: [any View] = ["Skill", "Uses", "Views", "Patches", "Usage %"]
            .map { El("th", [], [Text($0)]) }
        let table = El("div", [("class", "ins-table-wrap")], [
            El("table", [("class", "ins-table")], [
                El("thead", [], [El("tr", [], heads)]),
                El("tbody", [], rows),
            ]),
        ])

        // Section 2 — agent activity (all-time totals)
        let totalMessages = sessions.reduce(0) { $0 + ($1.messages.isEmpty ? $1.messageCount : $1.messages.count) }
        let rangeTokens = insights.dailyTokens
            .filter { $0.key >= Self.dayString(graphStart()) && $0.key <= Self.dayString(Date()) }
            .values.reduce(0, +)

        return Div(class: "main-scroll insights-main") {
            Div(class: "detail-card") {
                El("h3", [("style", "margin:0 0 12px")], [
                    Text("Skill Usage "),
                    Span(class: "ins-range-hint") { Text("(top \(min(10, ranked.count)) by uses)") },
                ])
                Div(class: "ins-bubbles") {
                    statBubble(label: "Total Invocations", value: Self.fmtCount(totalUses), icon: .star)
                    statBubble(label: "Skills Used", value: "\(used)/\(skillNames.count)", icon: .book)
                }
                table
            }
            .attribute("style", "margin-bottom:16px")
            Div(class: "detail-card") {
                El("h3", [("style", "margin:0 0 12px")], [Text("Agent Activity")])
                Div(class: "ins-stats") {
                    statBox(label: "Chat Sessions", value: Self.fmtCount(sessions.count), icon: .messageSquare)
                    statBox(label: "Total Messages", value: Self.fmtCount(totalMessages), icon: .fileText)
                    statBox(label: "Tokens Burned", value: Self.fmtCount(rangeTokens), icon: .chartBar)
                }
            }
            .attribute("style", "margin-bottom:16px")
            Div(class: "detail-card") {
                El("h3", [("style", "margin:0 0 12px")], [
                    Text("Daily Tokens "),
                    Span(class: "ins-range-hint") { Text("(last \(insightsRangeDays) days)") },
                ])
                dailyTokensGraph()
            }
        }
        .attribute("style", "padding:18px 22px")
    }

    /// Start-of-range date for the daily graph (inclusive).
    func graphStart() -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -(insightsRangeDays - 1), to: today) ?? today
    }

    func dailyTokensGraph() -> some WebUI.View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var days: [Date] = []
        for offset in (0..<insightsRangeDays).reversed() {
            if let d = cal.date(byAdding: .day, value: -offset, to: today) {
                days.append(d)
            }
        }
        let vals = days.map { insights.dailyTokens[Self.dayString($0)] ?? 0 }
        let maxVal = max(vals.max() ?? 0, 1)

        let bars: [any View] = zip(days, vals).map { day, v -> any View in
            // A zero day is a GAP, not a small bar: the old `3` stub made an
            // empty month look like a month of activity. Empty days now draw a
            // 2px baseline tick in a neutral tone (see `.ins-bar-empty`).
            let pct = v == 0 ? 0 : max(5, Int(Double(v) / Double(maxVal) * 100.0))
            let tip = "\(Self.dayLabel(day)) — \(Self.fmtCount(v)) tokens"
            let cls = v == 0 ? "ins-bar ins-bar-empty" : "ins-bar"
            return Div(class: cls) {}
                .attribute("style", "height:\(pct)%")
                .attribute("title", tip)
        }

        // x-axis: label every day for short ranges, sparse for long ones.
        let step = insightsRangeDays > 90 ? 15 : (insightsRangeDays >= 30 ? 5 : 1)
        let labels: [any View] = days.enumerated().map { idx, day -> any View in
            let dense = idx % step == 0
            return Div(class: "ins-xlabel") { Text(dense ? Self.dayLabel(day) : "") }
                .data("sparse", dense ? "0" : "1")
        }

        // y-axis: ticks at 0/25/50/75/100% of the peak. The rows are absolutely
        // positioned in a 220px column that matches .ins-chart, so each label
        // sits at the height of the bar it quantifies. The 100% label is
        // skipped — the "peak" callout above already prints that number, and
        // two copies of it overlapped (round-3 UX-43).
        let yTicks: [any View] = [0.0, 0.25, 0.5, 0.75, 1.0].map { frac -> any View in
            let v = Int(Double(maxVal) * frac)
            let label = frac >= 1.0 ? "" : Self.fmtCount(v)
            return Div(class: "ins-ytick-row") {
                if !label.isEmpty {
                    Span(class: "ins-ylabel") { Text(label) }
                }
                Span(class: "ins-ytick") {}
            }
            .attribute("style", "bottom:\(frac * 100)%")
        }

        return Div(class: "ins-chart-wrap") {
            Div(class: "ins-scale") { Text("peak \(Self.fmtCount(maxVal))") }
            Div(class: "ins-chart-row") {
                Div(class: "ins-yaxis") { yTicks }
                    .aria(.hidden(.yes))
                Div(class: "ins-chart") { bars }
            }
            Div(class: "ins-xaxis") { labels }
        }
    }
}

/// a bare element: tag, attribute pairs, children.
///
/// `no-webui`'s primitives spell `<div>`, `<span>`, `<table>` and the form
/// controls, but the insights table needs a `<td class="ins-t-name">` (the class
/// sets the weight in the sheet), a colspan cell for the "and N more" tail, and
/// an `<h3>` whose hint is its own span. this is the smallest view that spells
/// those three: the tag is a literal from this file, every attribute value is
/// escaped, and children render through their own `View` conformance.
private struct El: WebUI.View {
    let tag: String
    let attributes: [(String, String)]
    let children: [any View]

    init(_ tag: String, _ attributes: [(String, String)] = [], _ children: [any View] = []) {
        self.tag = tag
        self.attributes = attributes
        self.children = children
    }

    func render(into buffer: inout HTMLBuffer) {
        var attrs = ""
        for (key, value) in attributes {
            attrs += " \(key)=\"\(esc(value))\""
        }
        buffer.beginElement(tag, attrs)
        buffer.endOpenTag()
        for child in children {
            child.render(into: &buffer)
        }
        buffer.endElement()
    }
}
