import Testing
import Foundation
@testable import ArcWebUI
import ArcAgentCore

/// a tool that exists only to fill a toolset in a fixture. `checkFn` returning
/// false is what makes the panel print its "needs env" badge.
struct StubTool: AgentTool {
	let name: String
	let toolset: String
	var description: String = "A stub tool."
	var emoji: String = "🔧"
	var available: Bool = true
	var schema: JSONSchema { .object(properties: [:]) }
	var handler: ToolHandler = { _ in "ok" }
	var checkFn: ToolRequirementCheck? {
		available ? nil : { @Sendable in false }
	}
}

/// phase 6 goldens: captured from the LEGACY builders before conversion, so
/// every later typed rewrite is held to byte parity with what shipped.
///
/// `.serialized`: the log goldens read the process-wide `LogCollector`, so two
/// of these tests clearing and appending it at once is a flake, not a signal
/// (measured: 1 failure in 3 runs before the trait).

extension ArcWebUITestRoot {
	@Suite("render parity — panels and mains", .serialized)
	struct RenderParityPanels {

		private func app(_ configure: (inout AppState.RenderFixture) -> Void = { _ in }) -> AppState {
			var fixture = AppState.RenderFixture()
			fixture.settings.theme = "light"
			configure(&fixture)
			return AppState(renderFixture: fixture)
		}

		private func skill(_ name: String, _ desc: String, category: String? = nil) -> Skill {
			Skill(name: name, description: desc,
			      content: "---\nname: \(name)\ncategory: \(category ?? "General")\n---\n\n# \(name)\n\nbody",
			      tags: [], category: category,
			      path: URL(fileURLWithPath: "/tmp/skills/\(name)"))
		}

		private func profile(_ name: String, _ title: String, _ model: String?,
		                     skills: [String]? = nil) -> Profile {
			Profile(name: name, title: title, description: "\(title) profile.",
			        model: model, contextSkills: skills)
		}

		// MARK: - panels

		@Test("skills panel, empty library, matches golden")
		func skillsPanelEmptyGolden() async {
			let html = await app().skillsPanel().markup.html
			Parity.capture(html, as: "skills-panel-empty")
			Parity.expect(html, matches: "skills-panel-empty")
		}

		@Test("skills panel, two categories with one disabled skill, matches golden")
		func skillsPanelGroupedGolden() async {
			let html = await app {
				$0.skills = [
					self.skill("deploy", "Ship the current build to production", category: "ops"),
					self.skill("rollback", "Undo the last deploy", category: "ops"),
					self.skill("migrate", "Run pending database migrations", category: "data"),
				]
				$0.settings.disabledSkills = ["rollback"]
				$0.selectedSkill = "migrate"
			}.skillsPanel().markup.html
			Parity.capture(html, as: "skills-panel-grouped")
			Parity.expect(html, matches: "skills-panel-grouped")
		}

		@Test("skills panel, filter with no match, matches golden")
		func skillsPanelNoMatchGolden() async {
			let html = await app {
				$0.skills = [self.skill("deploy", "Ship the build")]
				$0.skillFilter = "zzz"
			}.skillsPanel().markup.html
			Parity.capture(html, as: "skills-panel-no-match")
			Parity.expect(html, matches: "skills-panel-no-match")
		}

		@Test("profiles panel matches golden")
		func profilesPanelGolden() async {
			let html = await app {
				$0.profiles = [
					self.profile("fast", "Fast", "gpt-5-mini"),
					self.profile("deep", "Deep", "claude-sonnet-4"),
				]
				$0.selectedProfile = "deep"
			}.profilesPanel().markup.html
			Parity.capture(html, as: "profiles-panel")
			Parity.expect(html, matches: "profiles-panel")
		}

		@Test("tools panel with two toolsets, one disabled tool, matches golden")
		func toolsPanelGolden() async {
			let html = await app {
				$0.toolsets = [
					("file", [
						StubTool(name: "read_file", toolset: "file", emoji: "📄"),
						StubTool(name: "write_file", toolset: "file", emoji: "✍️"),
					]),
					("terminal", [
						StubTool(name: "run_command", toolset: "terminal", emoji: "⌨️", available: false),
					]),
				]
				$0.settings.disabledToolsets = ["terminal"]
				$0.selectedTool = "read_file"
			}.toolsPanel().markup.html
			Parity.capture(html, as: "tools-panel")
			Parity.expect(html, matches: "tools-panel")
		}

		@Test("tools panel, filter with no match, matches golden")
		func toolsPanelFilteredEmptyGolden() async {
			let html = await app {
				$0.toolsets = [("file", [StubTool(name: "read_file", toolset: "file")])]
				$0.toolFilter = "zzz"
			}.toolsPanel().markup.html
			Parity.capture(html, as: "tools-panel-filtered-empty")
			Parity.expect(html, matches: "tools-panel-filtered-empty")
		}

		@Test("workspaces panel matches golden")
		func workspacesPanelGolden() async {
			let html = await app {
				$0.settings.workspaces = [
					WorkspaceEntry(name: "main", path: "/Users/you/main"),
					WorkspaceEntry(name: "research", path: "/Users/you/research"),
				]
				$0.settings.activeWorkspace = "research"
			}.workspacesPanel().markup.html
			Parity.capture(html, as: "workspaces-panel")
			Parity.expect(html, matches: "workspaces-panel")
		}

		// MARK: - skills main

		@Test("skills main with nothing selected matches golden")
		func skillsMainEmptyGolden() async {
			let html = await app { $0.skills = [self.skill("deploy", "Ship the build")] }.skillsMain().markup.html
			Parity.capture(html, as: "skills-main-empty")
			Parity.expect(html, matches: "skills-main-empty")
		}

		@Test("skills main with a selected skill matches golden")
		func skillsMainDetailGolden() async {
			let html = await app {
				$0.skills = [self.skill("deploy", "Ship the build"), self.skill("rollback", "Undo it")]
				$0.selectedSkill = "deploy"
			}.skillsMain().markup.html
			Parity.capture(html, as: "skills-main-detail")
			Parity.expect(html, matches: "skills-main-detail")
		}

		@Test("skill create form matches golden")
		func skillCreateFormGolden() async {
			let html = await app().skillCreateForm().markup.html
			Parity.capture(html, as: "skill-create-form")
			Parity.expect(html, matches: "skill-create-form")
		}

		@Test("skill edit form matches golden")
		func skillEditFormGolden() async {
			let s = skill("deploy", "Ship the build")
			let html = await app().skillEditForm(s).markup.html
			Parity.capture(html, as: "skill-edit-form")
			Parity.expect(html, matches: "skill-edit-form")
		}

		@Test("skill metadata box matches golden")
		func skillMetadataGolden() async {
			let s = skill("deploy", "Ship the build")
			let html = await app().skillMetadataHTML(s).markup.html
			Parity.capture(html, as: "skill-metadata")
			Parity.expect(html, matches: "skill-metadata")
		}

		// MARK: - profiles main

		@Test("profiles main with three profiles matches golden")
		func profilesMainGolden() async {
			let html = await app {
				$0.profiles = [
					self.profile("fast", "Fast", "gpt-5-mini"),
					self.profile("deep", "Deep", "claude-sonnet-4"),
					self.profile("local", "Local", nil),
				]
				$0.selectedProfile = "deep"
			}.profilesMain().markup.html
			Parity.capture(html, as: "profiles-main")
			Parity.expect(html, matches: "profiles-main")
		}

		@Test("profiles main without a selection falls back to the first profile")
		func profilesMainFallbackGolden() async {
			let html = await app {
				$0.profiles = [self.profile("fast", "Fast", "gpt-5-mini")]
			}.profilesMain().markup.html
			Parity.capture(html, as: "profiles-main-fallback")
			Parity.expect(html, matches: "profiles-main-fallback")
		}

		@Test("profile detail with pinned context skills matches golden")
		func profileDetailGolden() async {
			let html = await app {
				$0.skills = [self.skill("deploy", "Ship the build"), self.skill("rollback", "Undo it")]
				$0.profiles = [self.profile("deep", "Deep", "claude-sonnet-4",
				                            skills: ["deploy", "rollback"])]
				$0.selectedProfile = "deep"
				$0.profileSkillsDraft = ["deploy", "rollback"]
			}.profilesMain().markup.html
			Parity.capture(html, as: "profile-detail")
			Parity.expect(html, matches: "profile-detail")
		}

		@Test("profile create form matches golden")
		func profileCreateFormGolden() async {
			let html = await app { $0.createProfile = true }.profilesMain().markup.html
			Parity.capture(html, as: "profile-create-form")
			Parity.expect(html, matches: "profile-create-form")
		}

		@Test("profile edit form matches golden")
		func profileEditFormGolden() async {
			let html = await app {
				$0.profiles = [self.profile("fast", "Fast", "gpt-5-mini"),
				               self.profile("deep", "Deep", "gpt-5")]
				$0.editingProfile = "fast"
			}.profilesMain().markup.html
			Parity.capture(html, as: "profile-edit-form")
			Parity.expect(html, matches: "profile-edit-form")
		}

		@Test("profile card, active profile, matches golden")
		func profileCardActiveGolden() async {
			let html = await app().profileCardHTML(
				profile("fast", "Fast", "gpt-5-mini")).markup.html
			Parity.capture(html, as: "profile-card-inactive")
			Parity.expect(html, matches: "profile-card-inactive")
		}

		// MARK: - tools main

		@Test("tools main with a selected tool matches golden")
		func toolsMainDetailGolden() async {
			let html = await app {
				$0.registryTools = [StubTool(name: "read_file", toolset: "file", emoji: "📄")]
				$0.selectedTool = "read_file"
			}.toolsMain().markup.html
			Parity.capture(html, as: "tools-main-detail")
			Parity.expect(html, matches: "tools-main-detail")
		}

		@Test("tools main with nothing selected shows the blank state")
		func toolsMainBlankGolden() async {
			let html = await app {
				$0.registryTools = [StubTool(name: "read_file", toolset: "file")]
			}.toolsMain().markup.html
			Parity.capture(html, as: "tools-main-blank")
			Parity.expect(html, matches: "tools-main-blank")
		}

		// MARK: - workspaces main

		@Test("workspaces main matches golden")
		func workspacesMainGolden() async {
			let html = await app {
				$0.settings.workspaces = [
					WorkspaceEntry(name: "main", path: "/Users/you/main"),
					WorkspaceEntry(name: "research", path: "/Users/you/research"),
				]
				$0.settings.activeWorkspace = "research"
			}.workspacesMain().markup.html
			Parity.capture(html, as: "workspaces-main")
			Parity.expect(html, matches: "workspaces-main")
		}

		@Test("workspaces create form keeps a rejected path, matches golden")
		func workspacesMainInvalidPathGolden() async {
			let html = await app {
				$0.createWorkspace = true
				$0.formValues = ["ws-path-input": "relative/not/absolute"]
			}.workspacesMain().markup.html
			Parity.capture(html, as: "workspaces-main-invalid-path")
			Parity.expect(html, matches: "workspaces-main-invalid-path")
		}

		@Test("workspaces main with no sessions matches golden")
		func workspacesEmptyGolden() async {
			let html = await app().workspacesMain().markup.html
			Parity.capture(html, as: "workspaces-empty")
			Parity.expect(html, matches: "workspaces-empty")
		}

		// MARK: - phase 7: kanban

		@Test("kanban panel, two columns, matches golden")
		func kanbanPanelGolden() async {
			let html = await app {
				$0.kanbanColumns = [
					KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C"),
					KBColumn(id: "col-2", name: "Done", color: "#2F9EB7"),
				]
				$0.kanbanCards = [
					KBCard(id: "card-1", columnID: "col-1", title: "Write the parser"),
					KBCard(id: "card-2", columnID: "col-1", title: "Ship the build"),
				]
			}.kanbanPanel().markup.html
			Parity.capture(html, as: "kanban-panel")
			Parity.expect(html, matches: "kanban-panel")
		}

		@Test("kanban panel, add column form open, matches golden")
		func kanbanPanelAddColGolden() async {
			let html = await app {
				$0.addingColumn = true
			}.kanbanPanel().markup.html
			Parity.capture(html, as: "kanban-panel-addcol")
			Parity.expect(html, matches: "kanban-panel-addcol")
		}

		@Test("kanban main, three columns four cards, matches golden")
		func kanbanMainGolden() async {
			let html = await app {
				$0.kanbanColumns = [
					KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C"),
					KBColumn(id: "col-2", name: "In progress", color: "#2F9EB7"),
					KBColumn(id: "col-3", name: "Done", color: "#E1914B"),
				]
				$0.kanbanCards = [
					KBCard(id: "card-1", columnID: "col-1", title: "Write the parser"),
					KBCard(id: "card-2", columnID: "col-1", title: "Ship the build"),
					KBCard(id: "card-3", columnID: "col-2", title: "Review the diff"),
					KBCard(id: "card-4", columnID: "col-3", title: "Close the sprint"),
				]
			}.kanbanMain().markup.html
			Parity.capture(html, as: "kanban-main")
			Parity.expect(html, matches: "kanban-main")
		}

		@Test("kanban card armed, matches golden")
		func kanbanCardArmedGolden() async {
			let col = KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C")
			let html = await app {
				$0.kanbanColumns = [col]
				$0.kanbanCards = [KBCard(id: "card-1", columnID: "col-1", title: "Write the parser")]
				$0.confirmCard = "card-1"
			}.kanbanColumnHTML(col).markup.html
			Parity.capture(html, as: "kanban-card-armed")
			Parity.expect(html, matches: "kanban-card-armed")
		}

		@Test("kanban card unarmed, matches golden")
		func kanbanCardUnarmedColumnGolden() async {
			let col = KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C")
			let html = await app {
				$0.kanbanColumns = [col]
				$0.kanbanCards = [KBCard(id: "card-1", columnID: "col-1", title: "Write the parser")]
			}.kanbanColumnHTML(col).markup.html
			Parity.capture(html, as: "kanban-card-unarmed")
			Parity.expect(html, matches: "kanban-card-unarmed")
		}

		// MARK: - phase 7: memory

		@Test("memory panel, four docs, matches golden")
		func memoryPanelGolden() async {
			let html = await app {
				$0.memoryDoc = "memory"
			}.memoryPanel().markup.html
			Parity.capture(html, as: "memory-panel")
			Parity.expect(html, matches: "memory-panel")
		}

		@Test("memory main, document loaded, matches golden")
		func memoryMainGolden() async {
			let html = await app {
				$0.memoryDoc = "memory"
				$0.memoryContent = "# My Notes\n\nThis is a note."
			}.memoryMain().markup.html
			Parity.capture(html, as: "memory-main")
			Parity.expect(html, matches: "memory-main")
		}

		@Test("memory main, empty document, matches golden")
		func memoryMainEmptyGolden() async {
			let html = await app {
				$0.memoryDoc = "memory"
				$0.memoryContent = ""
			}.memoryMain().markup.html
			Parity.capture(html, as: "memory-main-empty")
			Parity.expect(html, matches: "memory-main-empty")
		}

		// MARK: - phase 7: logs

		@Test("logs panel, one line per level, matches golden")
		func logsPanelGolden() async {
			LogCollector.shared.clear()
			LogCollector.shared.append(level: .info, text: "server started")
			LogCollector.shared.append(level: .warning, text: "slow query")
			LogCollector.shared.append(level: .error, text: "connection failed")
			LogCollector.shared.append(level: .critical, text: "out of memory")
			let html = await app().logsPanel().markup.html
			Parity.capture(html, as: "logs-panel")
			Parity.expect(html, matches: "logs-panel")
		}

		@Test("log line, info level, matches golden")
		func logLineInfoGolden() async {
			let line = LogLine(seq: 1, time: Date(timeIntervalSince1970: 1_700_000_000), level: .info, text: "server started")
			let html = await app().logLineHTML(line).markup.html
			Parity.capture(html, as: "log-line-info")
			Parity.expect(html, matches: "log-line-info")
		}

		@Test("log line, warning level, matches golden")
		func logLineWarnGolden() async {
			let line = LogLine(seq: 2, time: Date(timeIntervalSince1970: 1_700_000_001), level: .warning, text: "slow query")
			let html = await app().logLineHTML(line).markup.html
			Parity.capture(html, as: "log-line-warn")
			Parity.expect(html, matches: "log-line-warn")
		}

		@Test("log line, error level, matches golden")
		func logLineErrorGolden() async {
			let line = LogLine(seq: 3, time: Date(timeIntervalSince1970: 1_700_000_002), level: .error, text: "connection failed")
			let html = await app().logLineHTML(line).markup.html
			Parity.capture(html, as: "log-line-error")
			Parity.expect(html, matches: "log-line-error")
		}

		@Test("log line, critical level, matches golden")
		func logLineCriticalGolden() async {
			let line = LogLine(seq: 4, time: Date(timeIntervalSince1970: 1_700_000_003), level: .critical, text: "out of memory")
			let html = await app().logLineHTML(line).markup.html
			Parity.capture(html, as: "log-line-critical")
			Parity.expect(html, matches: "log-line-critical")
		}

		@Test("log lines empty, matches golden")
		func logLinesEmptyGolden() async {
			LogCollector.shared.clear()
			let html = await app().logLinesHTML().markup.html
			Parity.capture(html, as: "log-lines-empty")
			Parity.expect(html, matches: "log-lines-empty")
		}

		/// wall-clock log stamps are not reproducible across runs, so the golden
		/// carries a placeholder instead of the render's `hh:mm:ss`.
		private func scrubLogTimes(_ html: String) -> String {
			html.replacing(/\d{2}:\d{2}:\d{2}/, with: "TIME")
		}

		/// the live push target: the payload must be the `#log-lines` element
		/// itself, because a fragment replaces the element it names.
		@Test("log lines box keeps the fragment element shape, matches golden")
		func logLinesBoxGolden() async {
			LogCollector.shared.clear()
			LogCollector.shared.append(level: .info, text: "server started")
			let html = scrubLogTimes(await app().logLinesBox().markup.html)
			Parity.capture(html, as: "log-lines-box")
			Parity.expect(html, matches: "log-lines-box")
		}

		@Test("logs main, with lines, matches golden")
		func logsMainGolden() async {
			LogCollector.shared.clear()
			LogCollector.shared.append(level: .info, text: "server started")
			LogCollector.shared.append(level: .warning, text: "slow query")
			let html = scrubLogTimes(await app().logsMain().markup.html)
			Parity.capture(html, as: "logs-main")
			Parity.expect(html, matches: "logs-main")
		}

		// MARK: - phase 7.5: insights

		/// the graph draws a window that ends today, so its day labels and tooltips
		/// carry the render's wall clock and a golden captured as-is would go stale
		/// overnight. every seeded day's label is replaced by its index into the
		/// window instead, which is what the golden actually pins: the bars, the zero
		/// day's gap, the tick column and the sparse x labels. longest label first, so
		/// `10/1` cannot eat the front of `10/19`.
		private func scrubDays(_ html: String, rangeDays: Int) -> String {
			let cal = Calendar.current
			let today = cal.startOfDay(for: Date())
			var pairs: [(label: String, token: String)] = []
			for offset in 0..<rangeDays {
				guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
				pairs.append((AppState.dayLabel(day), "DAY\(rangeDays - 1 - offset)"))
			}
			var out = html
			for pair in pairs.sorted(by: { $0.label.count > $1.label.count }) {
				out = out.replacingOccurrences(of: pair.label, with: pair.token)
			}
			return out
		}

		/// a daily-token window ending today, with the given day offsets left at zero.
		/// seeded relative to the clock so the bar heights — not the dates — are what
		/// the golden holds.
		private static func dailyTokens(over days: Int, zeroAt: Set<Int> = [],
		                                scale: Int = 500) -> [String: Int] {
			let cal = Calendar.current
			let today = cal.startOfDay(for: Date())
			var out: [String: Int] = [:]
			for offset in 0..<days {
				guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
				out[AppState.dayString(day)] = zeroAt.contains(offset) ? 0 : (offset + 1) * scale
			}
			return out
		}

		@Test("insights panel, range selector, matches golden")
		func insightsPanelGolden() async {
			let html = await app {
				$0.insightsRangeDays = 30
			}.insightsPanel().markup.html
			Parity.capture(html, as: "insights-panel")
			Parity.expect(html, matches: "insights-panel")
		}

		@Test("insights main, skill stats and daily graph, matches golden")
		func insightsMainGolden() async {
			let html = await app {
				$0.skills = [
					self.skill("deploy", "Ship the current build", category: "ops"),
					self.skill("rollback", "Undo the last deploy", category: "ops"),
				]
				var deploy = SkillStat()
				deploy.uses = 5
				deploy.views = 3
				deploy.patches = 1
				var rollback = SkillStat()
				rollback.uses = 2
				rollback.views = 1
				$0.insights.skillStats = ["deploy": deploy, "rollback": rollback]
				$0.insights.dailyTokens = Self.dailyTokens(over: 3, zeroAt: [0])
				$0.insightsRangeDays = 3
			}.insightsMain().markup.html
			let scrubbed = scrubDays(html, rangeDays: 3)
			Parity.capture(scrubbed, as: "insights-main")
			Parity.expect(scrubbed, matches: "insights-main")
		}

		@Test("insights graph, seven days with one zero day, matches golden")
		func insightsGraphGolden() async {
			let html = await app {
				$0.insights.dailyTokens = Self.dailyTokens(over: 7, zeroAt: [3])
				$0.insightsRangeDays = 7
			}.dailyTokensGraph().markup.html
			let scrubbed = scrubDays(html, rangeDays: 7)
			Parity.capture(scrubbed, as: "insights-graph")
			Parity.expect(scrubbed, matches: "insights-graph")
		}

		// MARK: - phase 7: workspace dock / panel / body / tree

		/// the panel's folder is a fixed path that does not exist: the tree scan then
		/// renders the empty hint, so the goldens carry no machine-specific path and
		/// no developer's home directory is walked.
		private static let wsFixturePath = "/arc/parity/workspace"

		private func workspaceApp(open: Bool = true,
		                          wsNewMode: String = "",
		                          previewPath: String? = nil,
		                          previewContent: String? = nil,
		                          previewNote: String? = nil) -> AppState {
			app {
				$0.settings.workspaces = [WorkspaceEntry(name: "parity", path: Self.wsFixturePath)]
				$0.settings.activeWorkspace = "parity"
				$0.workspaceOpen = open
				$0.wsNewMode = wsNewMode
				$0.previewPath = previewPath
				$0.previewContent = previewContent
				$0.previewNote = previewNote
			}
		}

		/// a temp workspace with a known layout. the tree rows carry only relative
		/// names and base64 ids, so a random root path never reaches the bytes.
		private func makeTreeWorkspace(_ files: [String]) throws -> URL {
			let dir = FileManager.default.temporaryDirectory
				.appendingPathComponent("arc-parity-ws-\(UUID().uuidString)", isDirectory: true)
			let fm = FileManager.default
			try fm.createDirectory(at: dir, withIntermediateDirectories: true)
			for f in files {
				let url = dir.appendingPathComponent(f)
				try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				try Data("x".utf8).write(to: url)
			}
			return dir
		}

		@Test("workspace dock, panel collapsed, matches golden")
		func wsDockCollapsedGolden() async {
			let html = await workspaceApp(open: false).workspaceDockHTML().markup.html
			Parity.capture(html, as: "ws-dock-collapsed")
			Parity.expect(html, matches: "ws-dock-collapsed")
		}

		@Test("workspace dock, panel open, matches golden")
		func wsDockOpenGolden() async {
			let html = await workspaceApp(open: true).workspaceDockHTML().markup.html
			Parity.capture(html, as: "ws-dock-open")
			Parity.expect(html, matches: "ws-dock-open")
		}

		@Test("workspace panel, open with the new-file form, matches golden")
		func wsPanelGolden() async {
			let html = await workspaceApp(open: true, wsNewMode: "file").workspacePanelHTML().markup.html
			Parity.capture(html, as: "ws-panel")
			Parity.expect(html, matches: "ws-panel")
		}

		@Test("workspace panel, no workspace open, matches golden")
		func wsPanelNoWorkspaceGolden() async {
			let html = await workspaceApp(open: false).workspacePanelHTML().markup.html
			Parity.capture(html, as: "ws-panel-no-workspace")
			Parity.expect(html, matches: "ws-panel-no-workspace")
		}

		@Test("workspace body, markdown preview open, matches golden")
		func wsBodyPreviewGolden() async {
			let html = await workspaceApp(open: true, previewPath: "notes.md",
			                              previewContent: "# Notes\n\nA line of prose.\n").workspaceBodyHTML().markup.html
			Parity.capture(html, as: "ws-body-preview")
			Parity.expect(html, matches: "ws-body-preview")
		}

		@Test("workspace body, unreadable preview keeps its reason, matches golden")
		func wsBodyNoPreviewGolden() async {
			let html = await workspaceApp(open: true, previewPath: "app.log",
			                              previewNote: "Binary file — no preview.").workspaceBodyHTML().markup.html
			Parity.capture(html, as: "ws-body-no-preview")
			Parity.expect(html, matches: "ws-body-no-preview")
		}

		@Test("workspace tree, folders first with one expanded, matches golden")
		func wsTreeGolden() async throws {
			let ws = try makeTreeWorkspace(["z.txt", "b.txt", "a-folder/nested.txt", "m-folder/x.txt", ".secret"])
			defer { try? FileManager.default.removeItem(at: ws) }
			let html = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: ["a-folder"]).markup.html
			Parity.capture(html, as: "ws-tree")
			Parity.expect(html, matches: "ws-tree")
		}

		@Test("workspace tree, empty workspace, matches golden")
		func wsTreeEmptyGolden() async throws {
			let ws = try makeTreeWorkspace([])
			defer { try? FileManager.default.removeItem(at: ws) }
			let html = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: []).markup.html
			Parity.capture(html, as: "ws-tree-empty")
			Parity.expect(html, matches: "ws-tree-empty")
		}

		@Test("workspace tree, hidden files shown, matches golden")
		func wsTreeHiddenGolden() async throws {
			let ws = try makeTreeWorkspace([".secret", "visible.txt"])
			defer { try? FileManager.default.removeItem(at: ws) }
			let html = AppState.renderWorkspaceTree(root: ws, showHidden: true, expanded: []).markup.html
			Parity.capture(html, as: "ws-tree-hidden")
			Parity.expect(html, matches: "ws-tree-hidden")
		}

	// MARK: - phase 7.6a: queue

		@Test("queue tabs, tasks selected, matches golden")
		func todosTabsHTMLGolden() async {
			let html = await app { $0.todosTab = .tasks }.todosTabsHTML().markup.html
			Parity.capture(html, as: "todos-tabs")
			Parity.expect(html, matches: "todos-tabs")
		}

		@Test("queue row, pending entry, matches golden")
		func queueRowHTMLGolden() async {
			let e = QueueEntry(id: "entry-1", chatID: "chat-1", todoID: "todo-1")
			let html = await app {
				$0.settings.queuePlan = [e]
				$0.settings.todos = ["chat-1": [TodoItem(id: "todo-1", text: "Write the parser", done: false)]]
			}.queueRowHTML(e, index: 0, plan: [e]).markup.html
			Parity.capture(html, as: "queue-row")
			Parity.expect(html, matches: "queue-row")
		}

		@Test("queue link popup, one earlier task checked, matches golden")
		func queueLinkPopupHTMLGolden() async {
			let first = QueueEntry(id: "entry-1", chatID: "chat-1", todoID: "todo-1")
			let second = QueueEntry(id: "entry-2", chatID: "chat-1", todoID: "todo-2")
			let plan = [first, second]
			let html = await app {
				$0.settings.queuePlan = plan
				$0.settings.todos = ["chat-1": [
					TodoItem(id: "todo-1", text: "Write the parser", done: false),
					TodoItem(id: "todo-2", text: "Run the full test suite", done: false),
				]]
				$0.queueLinksOpen = "entry-2"
				$0.queueLinkSel = ["entry-1"]
			}.queueLinkPopupHTML(second, plan: plan).markup.html
			Parity.capture(html, as: "queue-link-popup")
			Parity.expect(html, matches: "queue-link-popup")
		}

		@Test("queue picker, one chat with an open todo, matches golden")
		func queuePickerHTMLGolden() async {
			let html = await app {
				$0.sessions = [
					Session(id: "chat-1",
					        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
					        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
					        title: "Chat One", messages: []),
				]
				$0.settings.todos = ["chat-1": [TodoItem(id: "todo-1", text: "Write the parser", done: false)]]
				$0.queuePickerOpen = true
			}.queuePickerHTML().markup.html
			Parity.capture(html, as: "queue-picker")
			Parity.expect(html, matches: "queue-picker")
		}

		@Test("queue panel, empty plan, matches golden")
		func queuePanelHTMLGolden() async {
			let html = await app().queuePanelHTML().markup.html
			Parity.capture(html, as: "queue-panel")
			Parity.expect(html, matches: "queue-panel")
		}

	// MARK: - phase 7.6b: tasks / todos

		/// a scheduled job with no run timestamps on purpose: `fmtRel` formats in the
		/// machine's time zone, so a golden carrying a date is a golden that fails in
		/// another zone — and the date text is `fmtRel`, not this card's shape.
		private func job(_ id: String, _ name: String, _ schedule: String,
		                 active: Bool = true, runs: Int = 0) -> CronJob {
			var j = CronJob(id: id, name: name, schedule: schedule,
			                prompt: "Summarise the inbox and send the digest.",
			                isActive: active)
			j.runCount = runs
			j.lastOutput = runs > 0 ? "Sent 3 summaries." : nil
			return j
		}

		private func session(_ id: String, _ title: String) -> Session {
			Session(id: id,
			        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
			        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
			        title: title, messages: [])
		}

		private func todosApp() -> AppState {
			app {
				$0.activeSessionID = "chat-1"
				$0.sessions = [self.session("chat-1", "Chat One")]
				$0.settings.todos = ["chat-1": [
					TodoItem(id: "todo-1", text: "Write the parser", done: false),
					TodoItem(id: "todo-2", text: "Run the full test suite", done: true),
				]]
				$0.todosTab = .tasks
			}
		}

		private func tasksApp(selected: String? = "job-1") -> AppState {
			app {
				$0.settings.scheduledJobs = [
					self.job("job-1", "Morning digest", "every 15m", runs: 3),
					self.job("job-2", "Nightly sweep", "0 3 * * *", active: false),
				]
				$0.tasksSelectedID = selected
				$0.sessions = [self.session("Cron-job-1", "Morning digest")]
			}
		}

		@Test("todos panel, tasks tab, one open and one done todo, matches golden")
		func todosPanelGolden() async {
			let html = await todosApp().todosPanelHTML().markup.html
			Parity.capture(html, as: "todos-panel")
			Parity.expect(html, matches: "todos-panel")
		}

		@Test("todos tasks tab body, one open and one done todo, matches golden")
		func todosTasksHTMLGolden() async {
			let html = await todosApp().todosTasksHTML().markup.html
			Parity.capture(html, as: "todos-tasks")
			Parity.expect(html, matches: "todos-tasks")
		}

		@Test("tasks panel, one active and one stopped job, matches golden")
		func tasksPanelGolden() async {
			let html = await tasksApp().tasksPanel().markup.html
			Parity.capture(html, as: "tasks-panel")
			Parity.expect(html, matches: "tasks-panel")
		}

		@Test("tasks main, one job selected, matches golden")
		func tasksMainGolden() async {
			let html = await tasksApp().tasksMain().markup.html
			Parity.capture(html, as: "tasks-main")
			Parity.expect(html, matches: "tasks-main")
		}

		@Test("tasks main, nothing selected, matches golden")
		func tasksMainEmptyGolden() async {
			let html = await tasksApp(selected: nil).tasksMain().markup.html
			Parity.capture(html, as: "tasks-empty")
			Parity.expect(html, matches: "tasks-empty")
		}

		@Test("task row, selected job, matches golden")
		func taskRowHTMLGolden() async {
			let job = self.job("job-1", "Morning digest", "every 15m", runs: 3)
			let html = await tasksApp(selected: "job-1").taskRowHTML(job).markup.html
			Parity.capture(html, as: "task-row")
			Parity.expect(html, matches: "task-row")
		}

		@Test("task form, matches golden")
		func taskFormHTMLGolden() async {
			let html = await tasksApp().taskFormHTML().markup.html
			Parity.capture(html, as: "task-form")
			Parity.expect(html, matches: "task-form")
		}
	}
}
