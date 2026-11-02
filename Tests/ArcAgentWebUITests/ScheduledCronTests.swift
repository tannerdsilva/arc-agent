import Foundation
import Testing

@testable import ArcWebUI
import ArcAgentCore

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

        // The task list's "next" label (audit 2026-11-01, wave 5): a schedule
        // the parser cannot read renders the same em-dash as a spent one-shot
        // or a deliberately stopped task, so a job that will never run is
        // invisible among the ones that simply have no next run. The label
        // names the dead case and only that case.
        private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

        private func label(_ job: CronJob) -> String {
            cronNextLabel(for: job, format: { _ in "FORMATTED" }, now: fixedNow)
        }

        @Test("an active job whose schedule can never fire says so")
        func deadScheduleSaysSo() {
            var job = CronJob(id: "j-dead", name: "dead", schedule: "every 60", prompt: "x")
            job.isActive = true
            job.nextRunAt = nil
            job.lastRunAt = nil
            job.runCount = 0
            #expect(label(job) == "schedule can't be parsed")
        }

        @Test("a stopped job keeps the plain dash")
        func stoppedJobKeepsDash() {
            var job = CronJob(id: "j-stopped", name: "stopped", schedule: "nonsense", prompt: "x")
            job.isActive = false
            job.nextRunAt = nil
            #expect(label(job) == "—")
        }

        @Test("a spent one-shot keeps the plain dash — it ran, it has no next")
        func spentOneShotKeepsDash() {
            var job = CronJob(id: "j-spent", name: "spent", schedule: "nonsense", prompt: "x")
            job.isActive = true
            job.nextRunAt = nil
            job.lastRunAt = fixedNow
            job.runCount = 1
            #expect(label(job) == "—")
        }

        @Test("a populated next run renders through the formatter")
        func populatedNextRenders() {
            var job = CronJob(id: "j-ok", name: "ok", schedule: "every 15m", prompt: "x")
            job.isActive = true
            job.nextRunAt = fixedNow
            #expect(label(job) == "FORMATTED")
        }

        @Test("an active never-run job with a valid but unstored schedule keeps the dash")
        func validScheduleNeverLies() {
            // The parity fixture's shape: nextRunAt simply not populated; the
            // schedule itself is fine, so the label must NOT claim it's broken.
            var job = CronJob(id: "j-valid", name: "valid", schedule: "every 15m", prompt: "x")
            job.isActive = true
            job.nextRunAt = nil
            job.lastRunAt = nil
            job.runCount = 0
            #expect(label(job) == "—")
        }
    }
}
