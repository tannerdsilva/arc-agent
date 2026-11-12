import Foundation

// MARK: - Schedule parsing (Protocols First: pure functions, no ambient state)

/// An unparseable schedule expression. ``CronSchedule`` itself returns `nil`
/// for invalid input; this error exists for callers that want to *name* the
/// problem (the CLI's `create`/`edit`, the agent tool).
public enum ScheduleError: Error, Equatable {
    case invalid(String)
}

/// Computes next-run dates for cron expressions, human intervals, and ISO
/// one-shots.
///
/// This is the **single** schedule engine: the daemon's ``CronScheduler``, the
/// CLI, the agent tool, and the web UI all read schedules through it. There is
/// deliberately no second parser — the last attempt at one (`CronNext` in the
/// web UI) silently disagreed with the daemon's (`computeNextRun`) about which
/// expressions were valid, so a job the UI showed as scheduled never fired.
///
/// ## Formats
///
/// - 5-field cron: `"0 9 * * *"` — minute, hour, day-of-month, month,
///   day-of-week. Each field supports `*`, `*/n`, `n`, `a-b`, `a-b/n`, and
///   comma lists; day-of-week also accepts `mon`–`sun` names. Cron's
///   day-of-month/day-of-week OR rule is honored when both are restricted.
/// - Human intervals: `"30m"`, `"30min"`, `"2h"`, `"every 2h"`, `"1d"`,
///   `"daily"`, `"90s"`.
/// - ISO 8601 timestamps — one-shots; a past date yields `nil`.
///
/// ## Misfire grace
///
/// `next` is a pure function of `(expression, after, timeZone)`. A caller whose
/// `lastRun` is several intervals stale passes `max(now, lastRun)` as `after`
/// and receives the *next future* occurrence — never a burst of missed ones.
///
/// ## DST correctness
///
/// Iteration builds each candidate instant with real `Calendar` arithmetic in
/// the schedule's own timezone (never a fixed `TimeInterval` walk), so a
/// `"0 9 * * *"` job stays at 9:00 *wall-clock* across daylight-saving shifts.
public enum CronSchedule {

    /// Parse-and-advance. `after` is exclusive: a matching instant equal to
    /// `after` is skipped. Returns `nil` for one-shots in the past and for
    /// unparseable expressions.
    public static func next(
        _ expression: String,
        after date: Date,
        timeZone: TimeZone = .current
    ) -> Date? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        // ISO 8601 one-shot. Checked before intervals: the "T" marker cannot
        // collide with any interval suffix, and the formatter is
        // case-sensitive so it reads the *original* casing.
        if trimmed.contains("T") || lowered.contains("t") {
            return nextISO(trimmed, after: date, timeZone: timeZone)
        }

        if let interval = intervalSeconds(lowered) {
            return date.addingTimeInterval(interval)
        }

        guard let fields = parseCron(lowered) else { return nil }
        return nextCron(fields, after: date, timeZone: timeZone)
    }

    /// True when the expression fires REPEATEDLY (cron/interval). An ISO
    /// one-shot instant, or an empty schedule (manual-only job), is not
    /// recurring. Used to enforce "a one-shot cannot be recurring".
    public static func isRecurring(_ expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if trimmed.contains("T") || lowered.contains("t") {
            return false  // ISO instant — fires at most once
        }
        return true
    }

    /// True when the expression parses at all (CLI/UI/tool validation).
    ///
    /// Deliberately independent of the current date: a valid one-shot in the
    /// past is still a *valid* schedule (the caller decides whether to warn).
    public static func isValid(_ expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if trimmed.contains("T") || lowered.contains("t") {
            return parseISO(trimmed, in: .current) != nil
        }
        if intervalSeconds(lowered) != nil { return true }
        return parseCron(lowered) != nil
    }

    // MARK: - Intervals

    /// Seconds in a human interval, or nil when the expression is not one.
    private static func intervalSeconds(_ lowered: String) -> TimeInterval? {
        var s = lowered
        if s.hasPrefix("every ") { s = String(s.dropFirst("every ".count)) }
        if s == "daily" { s = "1d" }
        // longest suffix first so "30min" isn't read as "30m" + junk
        let units: [(String, TimeInterval)] = [
            ("min", 60), ("m", 60), ("hr", 3600), ("h", 3600),
            ("d", 86400), ("s", 1),
        ]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            let num = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let v = Double(num), v > 0 else { return nil }
            return v * mult
        }
        return nil
    }

    // MARK: - ISO one-shots

    private static func nextISO(_ trimmed: String, after date: Date, timeZone: TimeZone) -> Date? {
        guard let iso = parseISO(trimmed, in: timeZone) else { return nil }
        return iso > date ? iso : nil
    }

    private static func parseISO(_ trimmed: String, in timeZone: TimeZone) -> Date? {
        // With an explicit offset ("…Z" / "+02:00"): the formatter's own
        // timeZone is overridden by the string.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: trimmed) { return d }
        // Without an offset ("2026-06-01T09:00:00"): interpret in the
        // schedule's timezone.
        let parts = trimmed.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let timeParts = parts[1].split(separator: ":")
        guard timeParts.count >= 2,
              let year = Int(parts[0].split(separator: "-")[0]),
              let month = Int(parts[0].split(separator: "-")[1]),
              let day = Int(parts[0].split(separator: "-")[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1])
        else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = timeParts.count > 2 ? (Int(timeParts[2]) ?? 0) : 0
        return cal.date(from: comps)
    }

    // MARK: - Cron

    /// One parsed 5-field cron expression.
    private struct CronFields {
        var minutes: Set<Int>      // 0...59
        var hours: Set<Int>        // 0...23
        var daysOfMonth: Set<Int>? // nil = wildcard
        var months: Set<Int>?      // nil = wildcard
        var daysOfWeek: Set<Int>?  // nil = wildcard; cron numbering, 0 = Sunday
    }

    private static func parseCron(_ lowered: String) -> CronFields? {
        let parts = lowered.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5 else { return nil }
        // A bare `*` is *unrestricted* (nil), not "every value" — the
        // dom/dow OR rule depends on knowing which fields were actually
        // constrained. A full set would make `1,31`-style semantics leak
        // into `*` and re-widen every schedule. An INVALID field, though,
        // must reject the whole expression — a nil here from a failed
        // parse would silently become a wildcard ("0 9 0 * *" firing
        // every day at 9am is a lie, not a lenient read).
        guard let minutes = parseField(parts[0], in: 0...59),
              let hours = parseField(parts[1], in: 0...23)
        else { return nil }
        guard parts[2] == "*" || parseField(parts[2], in: 1...31) != nil,
              parts[3] == "*" || parseField(parts[3], in: 1...12) != nil,
              parts[4] == "*" || parseDayOfWeek(parts[4]) != nil
        else { return nil }
        let daysOfMonth = parts[2] == "*" ? nil : parseField(parts[2], in: 1...31)
        let months = parts[3] == "*" ? nil : parseField(parts[3], in: 1...12)
        let daysOfWeek = parts[4] == "*" ? nil : parseDayOfWeek(parts[4])
        return CronFields(
            minutes: minutes,
            hours: hours,
            daysOfMonth: daysOfMonth,
            months: months,
            daysOfWeek: daysOfWeek
        )
    }

    /// Expand one cron field (`*`, `*/n`, `n`, `a-b`, `a-b/n`, `a,b,c`) into
    /// its set of allowed values, or nil when the field is malformed.
    private static func parseField(_ raw: String, in range: ClosedRange<Int>) -> Set<Int>? {
        var allowed = Set<Int>()
        for part in raw.split(separator: ",") {
            let piece = String(part)
            var base: ClosedRange<Int>
            var step = 1
            if piece.contains("/") {
                let halves = piece.split(separator: "/")
                guard halves.count == 2, let stepValue = Int(halves[1]), stepValue > 0
                else { return nil }
                step = stepValue
                if halves[0] == "*" {
                    base = range
                } else if let bounds = parseBounds(String(halves[0]), range) {
                    base = bounds
                } else {
                    return nil
                }
            } else if piece == "*" {
                base = range
            } else if let bounds = parseBounds(piece, range) {
                base = bounds
            } else {
                return nil
            }
            var v = base.lowerBound
            // step through the *range*, cron-style: 5-59/15 hits 5, 20, 35, 50
            while v <= base.upperBound {
                allowed.insert(v)
                v += step
            }
        }
        return allowed.isEmpty ? nil : allowed
    }

    private static func parseBounds(_ raw: String, _ range: ClosedRange<Int>) -> ClosedRange<Int>? {
        if raw.contains("-") {
            let bounds = raw.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2,
                  let lo = Int(bounds[0]), let hi = Int(bounds[1]),
                  range.contains(lo), range.contains(hi), lo <= hi
            else { return nil }
            return lo...hi
        }
        guard let value = Int(raw), range.contains(value) else { return nil }
        return value...value
    }

    /// Day-of-week: names or numbers, cron numbering (0 and 7 = Sunday).
    private static func parseDayOfWeek(_ raw: String) -> Set<Int>? {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var normalized = raw
        for (index, name) in names.enumerated() {
            normalized = normalized.replacingOccurrences(of: name, with: String(index))
        }
        // `sun` replaced to "0" but cron also allows 7 for Sunday — accept
        // the full 0...7 range here and mod at match time.
        guard let set = parseField(normalized, in: 0...7) else { return nil }
        return Set(set.map { $0 % 7 })
    }

    /// Walk forward day by day (capped at 366), and on each day whose month
    /// and dom/dow constraints match, take the earliest hour/minute instant
    /// strictly after `date`. `Calendar` builds each instant in the schedule's
    /// timezone, so DST gaps (a nonexistent 02:30) are skipped, not shifted.
    private static func nextCron(_ fields: CronFields, after date: Date, timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let sortedHours = fields.hours.sorted()
        let sortedMinutes = fields.minutes.sorted()
        let start = cal.startOfDay(for: date)

        for dayOffset in 0...366 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: start) else { break }
            let comps = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let month = comps.month, let dayOfMonth = comps.day, let weekday = comps.weekday
            else { continue }

            if let months = fields.months, !months.contains(month) { continue }

            // cron ORs day-of-month and day-of-week when both are restricted
            // (Calendar can only AND them — see the deleted CronNext for the
            // lie that produced).
            let domRestricted = fields.daysOfMonth != nil
            let dowRestricted = fields.daysOfWeek != nil
            if domRestricted || dowRestricted {
                let domMatches = fields.daysOfMonth.map { $0.contains(dayOfMonth) } ?? false
                // Calendar: 1 = Sunday … 7 = Saturday → cron: 0 = Sunday … 6
                let cronWeekday = (weekday - 1) % 7
                let dowMatches = fields.daysOfWeek.map { $0.contains(cronWeekday) } ?? false
                switch (domRestricted, dowRestricted) {
                case (true, false) where !domMatches: continue
                case (false, true) where !dowMatches: continue
                case (true, true) where !(domMatches || dowMatches): continue
                default: break
                }
            }

            var dayComps = DateComponents()
            dayComps.year = comps.year
            dayComps.month = month
            dayComps.day = dayOfMonth
            for hour in sortedHours {
                for minute in sortedMinutes {
                    dayComps.hour = hour
                    dayComps.minute = minute
                    dayComps.second = 0
                    // nil during a DST gap (spring-forward) — skip the instant
                    guard let instant = cal.date(from: dayComps) else { continue }
                    if instant > date { return instant }
                }
            }
        }
        return nil
    }
}
