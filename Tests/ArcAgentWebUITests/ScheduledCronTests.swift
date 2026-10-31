import Foundation
import Testing

@testable import ArcWebUI

// the scheduled-task schedule parser is a pure function with a user-visible
// contract: a 5-field expression names the day it fires on. two defects made
// it lie without ever throwing:
//
//   * cron numbers weekdays 0/7=Sunday, 1=Monday; `Calendar` numbers them
//     1=Sunday, 2=Monday. the old code assigned the cron number straight into
//     `DateComponents.weekday`, so "0 9 * * 1" fired on Sunday.
//   * a field the parser could not read (`*/15`, `1-5`, `0,30`) became `nil`,
//     which `Calendar` reads as "any value" — so a 15-minute step silently ran
//     every minute. an unsupported shape must be refused, not widened.
//
// both are pinned here; the happy path is pinned beside them so a fix cannot
// trade one for the other.
extension ArcWebUITestRoot {
    @Suite("Scheduled cron parsing")
    struct ScheduledCronTests {

        /// a fixed local noon; every expectation is derived from `Calendar`
        /// rather than a literal date string, so the suite is timezone-neutral.
        private func localDate(
            _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int
        ) throws -> Date {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            return try #require(Calendar.current.date(from: comps))
        }

        @Test("cron weekday 1 is Monday, not Calendar's Sunday")
        func cronWeekdayIsMonday() throws {
            // Friday 2026-10-30 12:00 local.
            let from = try localDate(2026, 10, 30, 12, 0)
            let next = try #require(CronNext(expression: "0 9 * * 1", from: from))
            let parts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: next)
            #expect(parts.weekday == 2,
                    "cron 1 is Monday (Calendar weekday 2); got weekday \(parts.weekday ?? -1) on \(next)")
            #expect(parts.hour == 9)
            #expect(parts.minute == 0)
        }

        @Test("cron weekday 7 is Sunday")
        func cronWeekdaySevenIsSunday() throws {
            let from = try localDate(2026, 10, 30, 12, 0)
            let next = try #require(CronNext(expression: "0 9 * * 7", from: from))
            #expect(Calendar.current.component(.weekday, from: next) == 1,
                    "cron 7 is Sunday (Calendar weekday 1)")
        }

        @Test("an unsupported step expression is refused, not widened to every minute")
        func cronRejectsStepSyntax() {
            #expect(CronNext(expression: "*/15 * * * *", from: Date()) == nil,
                    "*/15 must not be read as 'any minute'")
        }

        @Test("an unsupported range expression is refused")
        func cronRejectsRangeSyntax() {
            #expect(CronNext(expression: "0 9 * * 1-5", from: Date()) == nil,
                    "a weekday range must not be read as 'any weekday'")
        }

        @Test("out-of-range field values are refused")
        func cronRejectsOutOfRangeFields() {
            #expect(CronNext(expression: "99 * * * *", from: Date()) == nil)
            #expect(CronNext(expression: "0 24 * * *", from: Date()) == nil)
            #expect(CronNext(expression: "0 9 0 * *", from: Date()) == nil)
            #expect(CronNext(expression: "0 9 * 13 *", from: Date()) == nil)
            #expect(CronNext(expression: "0 9 * * 8", from: Date()) == nil)
        }

        @Test("a plain daily cron still resolves to 09:00")
        func cronDailyStillWorks() throws {
            let from = try localDate(2026, 10, 30, 12, 0)
            let next = try #require(CronNext(expression: "0 9 * * *", from: from))
            let parts = Calendar.current.dateComponents([.hour, .minute], from: next)
            #expect(parts.hour == 9)
            #expect(parts.minute == 0)
            #expect(next > from)
        }
    }
}
