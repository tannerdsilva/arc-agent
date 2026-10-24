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
	var handler: ToolHandler { { _ in "ok" } }
	var checkFn: ToolRequirementCheck? {
		available ? nil : { @Sendable in false }
	}
}

/// phase 6 goldens: captured from the LEGACY builders before conversion, so
/// every later typed rewrite is held to byte parity with what shipped.
@Suite("render parity — panels and mains")
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
}