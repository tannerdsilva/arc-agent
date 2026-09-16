import Foundation
import ArcAgentCore

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

    func insightsPanel() -> String {
        let days = [7, 30, 90, 365]
        let opts = days.map { d -> String in
            let sel = d == insightsRangeDays ? " selected" : ""
            return "<option value=\"\(d)\"\(sel)>Last \(d) days</option>"
        }.joined()
        return """
        <div class="panel-head">
          <span class="panel-title">Insights</span>
        </div>
        <div class="detail-sub" style="padding:4px 2px 10px">Usage analytics</div>
        <div class="ins-range-wrap">
          <label class="ins-range-label" for="ins-range">Daily token range</label>
          <select id="ins-range" data-component-id="ins-range" data-event="change" data-no-restore>\(opts)</select>
        </div>
        """
    }

    // MARK: Insights view (main)

    private func statBubble(label: String, value: String, icon: String) -> String {
        """
        <div class="ins-bubble">
          <div class="ins-bubble-icon">\(icon)</div>
          <div class="ins-bubble-value">\(esc(value))</div>
          <div class="ins-bubble-label">\(esc(label))</div>
        </div>
        """
    }

    private func statBox(label: String, value: String, icon: String) -> String {
        """
        <div class="ins-stat-box">
          <div class="ins-stat-icon">\(icon)</div>
          <div class="ins-stat-value">\(esc(value))</div>
          <div class="ins-stat-label">\(esc(label))</div>
        </div>
        """
    }

    func insightsMain() -> String {
        let totalUses = insights.skillStats.values.reduce(0) { $0 + $1.uses }
        let touched = insights.skillStats.values.filter { $0.uses > 0 || $0.views > 0 || $0.patches > 0 }.count
        let skillNames = Array(Set(skills.map(\.name)).union(insights.skillStats.keys)).sorted()

        // Section 1 — skill usage
        let bubbles = """
        <div class="ins-bubbles">
          \(statBubble(label: "Total Invocations", value: Self.fmtCount(totalUses), icon: svgIcon("sparkle", 18)))
          \(statBubble(label: "Skills Used", value: "\(touched)/\(skillNames.count)", icon: svgIcon("book", 18)))
        </div>
        """
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
        let tableRows = topSkills.map { name -> String in
            let s = insights.skillStats[name] ?? SkillStat()
            let pct = totalUses > 0
                ? String(format: "%.1f%%", Double(s.uses) / Double(totalUses) * 100)
                : "0.0%"
            return """
            <tr>
              <td class="ins-t-name">\(esc(name))</td>
              <td>\(s.uses)</td><td>\(s.views)</td><td>\(s.patches)</td>
              <td>\(pct)</td>
            </tr>
            """
        }.joined() + (ranked.count > 10 ? "<tr class=\"ins-more-row\"><td colspan=\"5\">… and \(ranked.count - 10) more skills</td></tr>" : "")
        let table = """
        <div class="ins-table-wrap">
          <table class="ins-table">
            <thead><tr><th>Skill</th><th>Uses</th><th>Views</th><th>Patches</th><th>Usage %</th></tr></thead>
            <tbody>\(tableRows)</tbody>
          </table>
        </div>
        """

        // Section 2 — agent activity (all-time totals)
        let totalMessages = sessions.reduce(0) { $0 + $1.messages.count }
        let rangeTokens = insights.dailyTokens
            .filter { $0.key >= Self.dayString(graphStart()) && $0.key <= Self.dayString(Date()) }
            .values.reduce(0, +)
        let stats = """
        <div class="ins-stats">
          \(statBox(label: "Chat Sessions", value: Self.fmtCount(sessions.count), icon: svgIcon("chat", 18)))
          \(statBox(label: "Total Messages", value: Self.fmtCount(totalMessages), icon: svgIcon("note", 18)))
          \(statBox(label: "Tokens Burned", value: Self.fmtCount(rangeTokens), icon: svgIcon("chart", 18)))
        </div>
        """

        // Section 3 — daily tokens graph
        let graph = dailyTokensGraph()

        return """
        <div class="main-scroll insights-main" style="padding:18px 22px">
          <div class="detail-card" style="margin-bottom:16px">
            <h3 style="margin:0 0 12px">Skill Usage <span class="ins-range-hint">(top \(min(10, ranked.count)) by uses)</span></h3>
            \(bubbles)
            \(table)
          </div>
          <div class="detail-card" style="margin-bottom:16px">
            <h3 style="margin:0 0 12px">Agent Activity</h3>
            \(stats)
          </div>
          <div class="detail-card">
            <h3 style="margin:0 0 12px">Daily Tokens <span class="ins-range-hint">(last \(insightsRangeDays) days)</span></h3>
            \(graph)
          </div>
        </div>
        """
    }

    /// Start-of-range date for the daily graph (inclusive).
    func graphStart() -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -(insightsRangeDays - 1), to: today) ?? today
    }

    func dailyTokensGraph() -> String {
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

        let bars = zip(days, vals).map { (day, v) -> String in
            let pct = v == 0 ? 3 : max(5, Int(Double(v) / Double(maxVal) * 100.0))
            let tip = "\(Self.dayLabel(day)) — \(Self.fmtCount(v)) tokens"
            return "<div class=\"ins-bar\" style=\"height:\(pct)%\" title=\"\(esc(tip))\"></div>"
        }.joined()

        // x-axis: label every day for short ranges, sparse for long ones.
        let step = insightsRangeDays > 90 ? 15 : (insightsRangeDays > 30 ? 5 : 1)
        let labels = days.enumerated().map { (idx, day) -> String in
            let text = idx % step == 0 ? Self.dayLabel(day) : ""
            return "<div class=\"ins-xlabel\" data-sparse=\"\(idx % step == 0 ? "0" : "1")\">\(text)</div>"
        }.joined()

        return """
        <div class="ins-chart-wrap">
          <div class="ins-chart">\(bars)</div>
          <div class="ins-xaxis">\(labels)</div>
        </div>
        """
    }
}
