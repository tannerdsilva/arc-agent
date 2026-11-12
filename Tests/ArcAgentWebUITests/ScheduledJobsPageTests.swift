import Foundation
import Testing
import WebUICore

@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - scheduled jobs page
//
// The redesigned Scheduled Jobs page: an exclusive three-way lifecycle
// partition (active / pending / completed), a live search over name + prompt,
// a schedule editor whose draft builds the exact expression that is saved,
// and a topbar whose five buttons cover run / pause / edit / duplicate /
// delete. These pin the state logic and the rendered contract.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("scheduled jobs page", .serialized)
    struct ScheduledJobsPageTests {

        /// Build the fixture through the RenderFixture seam — AppState is an
        /// actor, so all state arrives via the init, never mutated after.
        private func makeApp(_ configure: (inout AppState.RenderFixture) -> Void = { _ in })
            -> AppState {
            var f = AppState.RenderFixture()
            f.settings.scheduledJobs = [
                job("j-active", "Morning digest", "every 15m", isActive: true, runs: 3,
                    next: Date(timeIntervalSince1970: 1_800_000_000)),
                job("j-pending", "Fresh idea", "0 9 * * *", isActive: true, runs: 0),
                job("j-idle", "Ad-hoc probe", "", isActive: true, runs: 0),
                job("j-idle-ran", "Manual summary", "", isActive: true, runs: 3, next: nil),
                job("j-paused", "Nightly sweep", "0 3 * * *", isActive: false, runs: 5,
                    next: Date(timeIntervalSince1970: 1_800_000_000), paused: true),
                job("j-failed", "Broken fetch", "0 4 * * *", isActive: true, runs: 1,
                    next: nil, lastStatus: "error"),
                job("j-failed-recurring", "Flaky nightly", "0 4 * * *", isActive: true, runs: 2,
                    next: Date(timeIntervalSince1970: 1_800_000_000), lastStatus: "error"),
                job("j-spent", "One-shot", "0 9 1 1 *", isActive: true, runs: 1, next: nil),
            ]
            configure(&f)
            return AppState(renderFixture: f)
        }

        private func job(_ id: String, _ name: String, _ schedule: String,
                         isActive: Bool, runs: Int,
                         next: Date? = nil, paused: Bool = false,
                         lastStatus: String? = nil) -> CronJob {
            var j = CronJob(id: id, name: name, schedule: schedule,
                            prompt: "Summarise the inbox.", isActive: isActive)
            j.runCount = runs
            j.nextRunAt = next
            j.pausedAt = paused ? Date() : nil
            j.lastStatus = lastStatus
            return j
        }

        // MARK: category partition

        @Test("jobs partition into the five exclusive lifecycle categories")
        func categoryPartition() async {
            let app = makeApp()
            let jobs = await app.settings.scheduledJobs
            var byCat: [AppState.TaskCategory: [String]] = [:]
            for j in jobs {
                let cat = await app.taskCategory(for: j)
                byCat[cat, default: []].append(j.id)
            }
            #expect(byCat[.activePending] == ["j-active", "j-pending"], "scheduled (once or recurring) = active/pending: \(byCat)")
            #expect(byCat[.idle] == ["j-idle", "j-idle-ran"],
                    "no schedule = idle, whether it has run or not: \(byCat)")
            #expect(byCat[.paused] == ["j-paused"], "paused by the user = paused: \(byCat)")
            #expect(byCat[.failed] == ["j-failed", "j-failed-recurring"],
                    "last attempt errored = failed, recurring or not: \(byCat)")
            #expect(byCat[.completed] == ["j-spent"],
                    "fired with no next fire (not paused, not failed) = completed: \(byCat)")
        }

        // MARK: verb gating

        @Test("priority: failed and completed beat paused; paused only catches would-be Active/Pending")
        func priorityOrder() async {
            let app = makeApp()
            // A paused job whose last run errored → Failed (failed first).
            var pausedFailed = job("j-pf", "Paused but broken", "0 5 * * *", isActive: false,
                                   runs: 2, next: Date(timeIntervalSince1970: 1_800_000_000),
                                   paused: true, lastStatus: "error")
            pausedFailed.pausedAt = Date()
            // A paused spent one-shot → Completed (fully exhausted).
            var pausedSpent = job("j-ps", "Paused spent", "2026-01-01T09:00:00", isActive: false,
                                  runs: 1, paused: true)
            pausedSpent.runBudget = 1
            pausedSpent.runsRemaining = 0
            let cats = await app.taskCategory(for: pausedFailed)
            #expect(cats == .failed, "failed outranks paused")
            #expect(await app.taskCategory(for: pausedSpent) == .completed,
                    "fully exhausted outranks paused")
            #expect(await app.taskCategory(for: pausedFailed) == .failed)
        }

        @Test("a running job carries the task-running class and no running tag")
        func runningBorderNotTag() async {
            var f = AppState.RenderFixture()
            var j = job("j-run", "In flight", "0 9 * * *", isActive: true, runs: 1,
                        next: Date(timeIntervalSince1970: 1_800_000_000))
            f.settings.scheduledJobs = [j]
            f.runningCronJobs = ["j-run"]
            let html = await AppState(renderFixture: f).tasksPanel().markup.html
            #expect(html.contains("task-row task-running"), "the row card gets the loading border")
            #expect(!html.contains(">running<"), "there is no running tag")
            #expect(html.contains(">active<"), "the tag mirrors the category")
        }

        @Test("the per-category verb matrix disables terminal/unavailable verbs")
        func verbMatrix() async {
            func allowed(_ verb: String, _ id: String) async -> Bool {
                let app = makeApp()
                return await app.cronVerbAllowed(verb, id)
            }
            func denied(_ verb: String, _ id: String) async -> Bool {
                return !(await allowed(verb, id))
            }
            // completed & failed: no run/pause/edit — dup/delete only
            #expect(await denied("run", "j-spent"))
            #expect(await denied("toggle", "j-spent"))
            #expect(await denied("edit", "j-spent"))
            #expect(await denied("run", "j-failed"))
            #expect(await denied("toggle", "j-failed"))
            #expect(await denied("edit", "j-failed"))
            #expect(await denied("run", "j-failed-recurring"), "failed is failed, recurring or not")
            // paused: no run, but toggle (resume) + edit live here
            #expect(await denied("run", "j-paused"))
            #expect(await allowed("toggle", "j-paused"))
            #expect(await allowed("edit", "j-paused"))
            // pending/idle: runnable + editable, no pause (nothing in flight)
            #expect(await allowed("run", "j-pending"))
            #expect(await allowed("toggle", "j-pending"), "a pending recurring job is pausable")
            #expect(await allowed("run", "j-idle"))
            #expect(await denied("toggle", "j-idle"))
            // active: everything
            #expect(await allowed("run", "j-active"))
            #expect(await allowed("toggle", "j-active"))
            #expect(await allowed("edit", "j-active"))
            // unknown job: every verb refused
            #expect(await denied("run", "j-ghost"))
            #expect(await denied("edit", "j-ghost"))
            #expect(await denied("delete", "j-ghost"))
        }

        // MARK: search

        @Test("the search draft filters on name and prompt, case-insensitively")
        func searchFiltersJobs() async {
            // The search narrows every group at once; pin matches by id.
            func matches(_ q: String) async -> [String] {
                let query = q.trimmingCharacters(in: .whitespaces).lowercased()
                let app = makeApp { $0.tasksSearchDraft = q }
                let jobs = await app.settings.scheduledJobs
                return jobs.filter { app.taskSearchMatches($0, query: query) }.map(\.id)
            }
            #expect(await matches("DIGEST") == ["j-active"],
                    "name match is case-insensitive")
            #expect(await matches("summarise").count == 8,
                    "prompt match reaches every job in every group")
            #expect(await matches("zzz-nothing").isEmpty)
            #expect(await matches("   ").count == 8, "a blank draft shows everything")
        }

        @Test("jobs appear under their own collapsible group; unknown groups fall back")
        func categoryNarrowsSidebar() async {
            func ids(_ cat: String) async -> [String] {
                let app = makeApp { $0.tasksCategory = AppState.TaskCategory(rawValue: cat) }
                let selected = await app.tasksCategory
                let jobs = await app.settings.scheduledJobs
                return jobs.filter { app.taskCategory(for: $0) == selected }.map(\.id)
            }
            #expect(await ids("activePending") == ["j-active", "j-pending"])
            #expect(await ids("idle") == ["j-idle", "j-idle-ran"])
            #expect(await ids("failed") == ["j-failed", "j-failed-recurring"])
            #expect(await ids("paused") == ["j-paused"])
            #expect(await ids("completed") == ["j-spent"])
            #expect(await ids("nonsense").sorted() == ["j-active", "j-pending"],
                    "an unknown rawValue nils out to the default (active) tab")
        }

        // MARK: schedule draft

        @Test("the schedule draft builds the exact expression that is saved")
        func scheduleDraftBuildsExpression() async {
            func expr(_ configure: (inout AppState.RenderFixture) -> Void) async -> String {
                await makeApp(configure).taskScheduleExpression()
            }
            #expect(await expr { $0.taskSchedPreset = "every"
                $0.taskSchedEvery = "45"; $0.taskSchedUnit = "h" } == "every 45h")
            #expect(await expr { $0.taskSchedPreset = "daily"
                $0.taskSchedTime = "08:30" } == "30 8 * * *")
            let weekly = await expr { $0.taskSchedPreset = "weekly"
                $0.taskSchedTime = "08:30"; $0.taskSchedDow = "5" }
            #expect(weekly == "30 8 * * 5", "weekly build: got '\(weekly)'")
            #expect(await expr { $0.taskSchedPreset = "custom"
                $0.taskSchedCustom = "*/10 * * * *" } == "*/10 * * * *")
            #expect(await expr { $0.taskSchedPreset = "every"
                $0.taskSchedEvery = "not-a-number" } == "every 15m",
                "a non-numeric count falls back to the default 15")
        }

        // MARK: rendered contract

        @Test("the sidebar renders collapsible category groups, a search field, and rows")
        func sidebarRendersTabsAndSearch() async {
            let html = await makeApp().tasksPanel().markup.html
            #expect(html.contains("task-grp-activePending"))
            #expect(html.contains("task-grp-idle"))
            #expect(html.contains("task-grp-paused"))
            #expect(html.contains("task-grp-failed"))
            #expect(html.contains("task-grp-completed"))
            #expect(html.contains("ACTIVE/PENDING (2)"), "group heads carry counts")
            #expect(html.contains(#"id="task-search""#))
            #expect(html.contains("task-refresh"))
            #expect(html.contains("task-open-j-active"))
            #expect(html.contains("task-open-j-paused"),
                    "groups render per category — a completed job is listed under its own group")
            #expect(html.contains("task-grp-activePending"), "groups are collapsible")
            #expect(html.contains(#"data-component-id="tasks""#),
                    "the panel boundary must report the control ids")
        }

        @Test("an empty category says None, not a paragraph")
        func emptyCategorySaysNone() async {
            func htmlFor(jobs: [CronJob]) async -> String {
                var f = AppState.RenderFixture()
                f.settings.scheduledJobs = jobs
                return await AppState(renderFixture: f).tasksPanel().markup.html
            }
            let html = await htmlFor(jobs: [])
            #expect(html.contains("task-grp-paused"), "all six groups render")
            #expect(!html.contains(">None<"), "empty groups render no filler text")
            #expect(!html.contains("No jobs here yet"), "the old paragraph is gone")
        }

        @Test("a one-shot hides Pause and disables Run now when spent")
        func oneShotControlsMirrorTheOps() async {
            var f = AppState.RenderFixture()
            var spent = job("j-once", "One attempt", "2026-01-01T09:00:00", isActive: false, runs: 1, next: nil)
            spent.runBudget = 1
            spent.runsRemaining = 0
            f.settings.scheduledJobs = [spent]
            f.tasksSelectedID = "j-once"
            let html = await AppState(renderFixture: f).tasksMain().markup.html
            #expect(!html.contains("task-toggle-j-once"), "a one-shot has no pause control")
            #expect(html.contains("ghost-btn disabled"), "a spent budget disables Run now")
            #expect(html.contains("Completed — nothing to run"))
            #expect(html.contains("1 of 1"), "the runs line shows the budget")
            var retry = spent
            retry.lastStatus = "error"
            f.settings.scheduledJobs = [retry]
            let html2 = await AppState(renderFixture: f).tasksMain().markup.html
            #expect(html2.contains("task-now-j-once") && html2.contains("ghost-btn disabled"),
                    "a failed job cannot run — fix or delete it")
            #expect(!html2.contains("task-edit-j-once"), "failed hides Edit")
        }

        @Test("the form offers the three job kinds and a one-shot instant field")
        func formOffersJobKinds() async {
            let app = makeApp { $0.tasksMode = .add
                $0.taskJobKind = "oneshot"
                $0.taskSchedWhen = "2026-06-01T09:00:00"
            }
            let html = await app.taskFormPage(title: "New scheduled job",
                                              submitLabel: "Schedule job", job: nil).markup.html
            #expect(html.contains("task-kind"))
            #expect(html.contains("One-shot (runs once)"))
            #expect(html.contains("task-when"))
            #expect(html.contains(#"value="2026-06-01T09:00:00""#))
            #expect(!html.contains("task-sched-preset"), "a one-shot has no recurring presets")
            let manual = await makeApp { $0.tasksMode = .add
                $0.taskJobKind = "manual"
            }
            let html2 = await manual.taskFormPage(title: "New scheduled job",
                                                  submitLabel: "Schedule job", job: nil).markup.html
            #expect(html2.contains("Run anytime (no schedule)"))
            #expect(!html2.contains("task-sched-preset"))
            let expr = await app.taskScheduleExpression()
            #expect(expr == "2026-06-01T09:00:00", "the one-shot draft builds the ISO instant")
            let empty = await manual.taskScheduleExpression()
            #expect(empty == "", "a manual job builds an empty schedule")
        }

        @Test("the main pane topbar carries the job name and the five controls")
        func topbarRendersFiveControls() async {
            let html = await makeApp { $0.tasksSelectedID = "j-active" }
                .tasksMain().markup.html
            #expect(html.contains("Morning digest"))
            #expect(html.contains("task-now-j-active"))
            #expect(html.contains("task-toggle-j-active"))
            #expect(html.contains("task-edit-j-active"))
            #expect(html.contains("task-dup-j-active"))
            #expect(html.contains("task-del-j-active"))
            #expect(html.contains("task-banner"), "the prompt banner renders")
            #expect(html.contains("Status"), "the status row renders")
        }

        @Test("the add form renders the schedule editor with a live preview")
        func addFormRendersScheduleEditor() async {
            let app = makeApp { $0.tasksMode = .add
                $0.taskSchedPreset = "daily"
                $0.taskSchedTime = "09:15"
            }
            let html = await app.taskFormPage(title: "New scheduled job",
                                              submitLabel: "Schedule job", job: nil).markup.html
            #expect(html.contains(#"id="task-form""#))
            #expect(html.contains(#"id="task-name""#))
            #expect(html.contains(#"id="task-prompt""#))
            #expect(html.contains("task-sched-preset"))
            #expect(html.contains("task-sched-time"))
            #expect(html.contains("15 9 * * *"), "the preview shows the built expression: \(html)")
            #expect(html.contains("Time is server time; cron runs server-side."),
                    "the preview carries the server-time note")
            #expect(html.contains("task-preview"), "the live schedule preview renders")
            #expect(html.contains("task-submit"), "the topbar check submits")
            #expect(html.contains("task-deliver-preset"), "the deliver preset select renders")
        }

        @Test("the edit form prefills the job's values and switches the preset")
        func editFormPrefills() async {
            let app = makeApp { $0.tasksMode = .edit }
            let jobs = await app.settings.scheduledJobs
            let html = await app.taskFormPage(title: "Edit job", submitLabel: "Save changes",
                                              job: jobs[0]).markup.html
            #expect(html.contains(#"value="Morning digest""#), "name prefilled: \(html)")
            #expect(html.contains("task-sched-every"),
                    "an interval schedule selects the every preset: \(html)")
            #expect(html.contains("task-submit"), "the topbar check submits")
            #expect(html.contains("task-cancel"))
        }
    }
}
