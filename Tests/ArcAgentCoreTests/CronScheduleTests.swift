import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Unified schedule engine (CronSchedule)
//
// One parser, one place: full 5-field cron (ranges, lists, steps,
// day-of-week names), timezones, DST-correct iteration, misfire grace,
// human intervals, and ISO one-shots. Pure function of
// (expression, after, timeZone) — never ambient local time.

@Suite("Cron Schedule Engine", .serialized)
struct CronScheduleTests {

    // MARK: 5-field cron

    @Test("Daily at 9am in the schedule's timezone")
    func dailyAtNine() {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        // 2026-06-01 22:00Z == 2026-06-02 00:00 Berlin — already past 9am,
        // so the next 09:00 Berlin time is June 2.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let after = date("2026-06-01T22:00:00Z")!
        let next = CronSchedule.next("0 9 * * *", after: after, timeZone: tz)
        let expected = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 2, hour: 9, minute: 0))
        #expect(next == expected)
        // And it must actually be 09:00 *in Berlin*, not in local time.
        let comps = cal.dateComponents([.hour, .minute], from: next!)
        #expect(comps.hour == 9)
        #expect(comps.minute == 0)
    }

    @Test("Step field: every 15 minutes")
    func stepField() {
        let tz = TimeZone(identifier: "UTC")!
        let after = date("2026-06-01T09:07:00Z")!
        let next = CronSchedule.next("*/15 * * * *", after: after, timeZone: tz)
        #expect(next == date("2026-06-01T09:15:00Z"))
    }

    @Test("Range field: weekdays only")
    func rangeField() {
        let tz = TimeZone(identifier: "UTC")!
        // 2026-06-06 is a Saturday; 2026-06-07 a Sunday. Next 9am should be
        // Monday 2026-06-08.
        let after = date("2026-06-06T10:00:00Z")!
        let next = CronSchedule.next("0 9 * * 1-5", after: after, timeZone: tz)
        #expect(next == date("2026-06-08T09:00:00Z"))
    }

    @Test("List field: midnight and noon")
    func listField() {
        let tz = TimeZone(identifier: "UTC")!
        let after = date("2026-06-01T00:30:00Z")!
        let next = CronSchedule.next("0 0,12 * * *", after: after, timeZone: tz)
        #expect(next == date("2026-06-01T12:00:00Z"))
    }

    @Test("Day-of-week names")
    func dayOfWeekNames() {
        let tz = TimeZone(identifier: "UTC")!
        // Monday 2026-06-08.
        let after = date("2026-06-06T10:00:00Z")!
        let next = CronSchedule.next("0 9 * * mon", after: after, timeZone: tz)
        #expect(next == date("2026-06-08T09:00:00Z"))
    }

    @Test("after is exclusive — a matching minute does not repeat")
    func afterIsExclusive() {
        let tz = TimeZone(identifier: "UTC")!
        let after = date("2026-06-01T09:00:00Z")!
        let next = CronSchedule.next("0 9 * * *", after: after, timeZone: tz)
        #expect(next == date("2026-06-02T09:00:00Z"))
    }

    // MARK: Human intervals

    @Test("Human intervals: 30m, every 2h, 1d, daily")
    func humanIntervals() {
        let tz = TimeZone(identifier: "UTC")!
        let after = date("2026-06-01T09:00:00Z")!
        #expect(CronSchedule.next("30m", after: after, timeZone: tz) == after.addingTimeInterval(30 * 60))
        #expect(CronSchedule.next("every 2h", after: after, timeZone: tz) == after.addingTimeInterval(2 * 3600))
        #expect(CronSchedule.next("1d", after: after, timeZone: tz) == after.addingTimeInterval(86400))
        #expect(CronSchedule.next("daily", after: after, timeZone: tz) == after.addingTimeInterval(86400))
    }

    // MARK: ISO one-shots

    @Test("ISO one-shot in the future fires; in the past returns nil")
    func isoOneShots() {
        let tz = TimeZone(identifier: "UTC")!
        let after = date("2026-06-01T09:00:00Z")!
        #expect(CronSchedule.next("2026-06-01T10:00:00Z", after: after, timeZone: tz)
                == date("2026-06-01T10:00:00Z"))
        #expect(CronSchedule.next("2026-06-01T08:00:00Z", after: after, timeZone: tz) == nil)
    }

    // MARK: Invalid input

    @Test("Invalid expressions return nil")
    func invalidExpressions() {
        let tz = TimeZone(identifier: "UTC")!
        let after = date("2026-06-01T09:00:00Z")!
        #expect(CronSchedule.next("garbage", after: after, timeZone: tz) == nil)
        #expect(CronSchedule.next("0 9 * *", after: after, timeZone: tz) == nil)
        #expect(CronSchedule.next("61 * * * *", after: after, timeZone: tz) == nil)
        #expect(CronSchedule.next("", after: after, timeZone: tz) == nil)
        #expect(!CronSchedule.isValid("garbage"))
        #expect(!CronSchedule.isValid("0 9 * *"))
        #expect(CronSchedule.isValid("0 9 * * *"))
        #expect(CronSchedule.isValid("30m"))
    }

    // MARK: Misfire grace

    @Test("A stale lastRun yields the next future occurrence, not a burst")
    func misfireGrace() {
        let tz = TimeZone(identifier: "UTC")!
        // lastRun 3 intervals stale (06-01 09:00, now 06-01 12:30): the next
        // fire is 13:00, not a replay of 09:15/09:30/.../12:30.
        let now = date("2026-06-01T12:30:00Z")!
        let last = date("2026-06-01T09:00:00Z")!
        let next = CronSchedule.next("*/15 * * * *", after: max(now, last), timeZone: tz)
        #expect(next == date("2026-06-01T12:45:00Z"))
    }

    // MARK: DST correctness

    @Test("DST transition: 9am stays 9am across the wall-clock shift")
    func dstTransition() {
        let tz = TimeZone(identifier: "America/New_York")!
        let cal = Calendar(identifier: .gregorian)
        // US DST ended 2026-11-01. After Oct 31's 9am EDT (13:00Z), the next
        // 9am is Nov 1 — 9am *local* despite the UTC offset changing
        // (EDT -4 → EST -5, so 14:00Z).
        let after = date("2026-10-31T13:00:00Z")!
        var next = CronSchedule.next("0 9 * * *", after: after, timeZone: tz)
        var comps = cal.dateComponents(in: tz, from: next!)
        #expect(comps.hour == 9)
        #expect(comps.day == 1)
        next = CronSchedule.next("0 9 * * *", after: next!.addingTimeInterval(60), timeZone: tz)
        comps = cal.dateComponents(in: tz, from: next!)
        #expect(comps.hour == 9)
        #expect(comps.day == 2)
    }

    // MARK: Helpers

    private func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }
}
