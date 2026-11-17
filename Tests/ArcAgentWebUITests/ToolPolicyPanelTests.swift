import Foundation
import Testing
import ArcAgentCore
import WebUI
import WebUICore

@testable import ArcWebUI

// Settings → Tool policy (T8): the first surface `ToolPolicy` has ever had.
//
// the suite keeps the two halves apart on purpose:
//
//  - the WRITE path: three rules go through the action layer and land in
//    `security.toolPolicy` in the file, in the order they were written; a
//    second, independent read of the bytes proves the order survived, and
//    `ToolPolicy.decide` reads that order back as the policy it is (last wins).
//  - the READ path: the panel renders the rows in array order and prints
//    `ToolPolicy.describe(config:)` byte for byte — an exact comparison, since a
//    containment test on text that quotes its own subject proves nothing.
extension ArcWebUITestRoot {
    @Suite("tool policy panel", .serialized)
    struct ToolPolicyPanelTests {

        // MARK: - harness

        /// A config file at a scratch path holding exactly `json`.
        private func scratchConfig(_ json: String = "{}\n") throws -> (url: URL, store: ConfigurationStore) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-tool-policy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            try Data(json.utf8).write(to: url)
            return (url, ConfigurationStore(url: url, environment: [:]))
        }

        /// The three rules every test below shares. Their order is the point:
        /// `*` allows, an exact toolset-scoped deny refuses, and a glob
        /// denyWithHint after it overrides both.
        private static let threeRules: [ToolPolicyRule] = [
            ToolPolicyRule(match: "*", toolset: nil, action: .allow, reason: nil),
            ToolPolicyRule(match: "mcp_tool", toolset: "mcp", action: .deny,
                           reason: "the MCP bridge is off limits"),
            ToolPolicyRule(match: "run_*", toolset: "terminal", action: .denyWithHint,
                           reason: "shell access needs a human"),
        ]

        private func render(_ app: AppState, router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await app.toolPolicySettingsHTML().markup.html
            }
        }

        private static func count(of needle: String, in html: String) -> Int {
            html.components(separatedBy: needle).count - 1
        }

        /// the text between two markers, exactly as rendered.
        private static func text(between open: String, and close: String, in html: String) -> String? {
            guard let start = html.range(of: open)?.upperBound,
                  let end = html.range(of: close, range: start..<html.endIndex)?.lowerBound
            else { return nil }
            return String(html[start..<end])
        }

        // MARK: - write path

        @Test("three rules written through the action layer reload in order and decide as documented")
        func roundTripPreservesOrderAndVerdicts() async throws {
            let (url, store) = try scratchConfig()
            let app = AppState(renderFixture: .init(), configurationStore: store)

            await app.setToolPolicyEnabled(true)
            for rule in Self.threeRules {
                let wrote = await app.appendToolPolicyRule(
                    match: rule.match, toolset: rule.toolset ?? "",
                    action: rule.action, reason: rule.reason ?? "")
                #expect(wrote, "a rule with a non-empty match must be accepted")
            }

            // reload: a fresh decode of the bytes — nothing in the authoring
            // process is consulted.
            let reloaded = try ConfigurationStore.readDeclared(url)
            #expect(reloaded.security.toolPolicy.enabled, "the flag reaches the file")
            #expect(reloaded.security.toolPolicy.rules == Self.threeRules,
                    "the file must carry the three rules in the order they were written")

            let policy = reloaded.security.toolPolicy
            #expect(ToolPolicy.decide(toolName: "read_file", toolset: "file", config: policy).action == .allow,
                    "the leading `*` allows what nothing else mentions")
            #expect(ToolPolicy.decide(toolName: "mcp_tool", toolset: "mcp", config: policy).action == .deny)

            // last wins: `*` allowed it, the exact `deny` refused it, and the
            // `run_*` denyWithHint below both of them has the final say.
            let shell = ToolPolicy.decide(toolName: "run_command", toolset: "terminal", config: policy)
            #expect(shell.action == .denyWithHint, "the last matching rule decides")
            #expect(shell.reason == "shell access needs a human")

            // the toolset is part of the match: outside `terminal`, run_command
            // only meets the `*` allow.
            #expect(ToolPolicy.decide(toolName: "run_command", toolset: "file", config: policy).action == .allow)
        }

        @Test("a rule whose match is blank is refused and writes nothing")
        func blankMatchWritesNothing() async throws {
            let (url, store) = try scratchConfig()
            var fixture = AppState.RenderFixture()
            fixture.arcConfig = try ConfigurationStore.readDeclared(url)
            let app = AppState(renderFixture: fixture, configurationStore: store)

            let wrote = await app.appendToolPolicyRule(
                match: "   ", toolset: "", action: .deny, reason: "")

            #expect(!wrote)
            let onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.security.toolPolicy.rules == [],
                    "a refused rule must leave the config list exactly as it was")
        }

        // MARK: - read path

        @Test("the summary is describe(config:) verbatim and the rows render in list order")
        func rendersDescribeVerbatimInOrder() async throws {
            let policy = ToolPolicyConfig(enabled: true, rules: Self.threeRules)
            var fixture = AppState.RenderFixture()
            fixture.arcConfig.security.toolPolicy = policy
            let app = AppState(renderFixture: fixture)
            let html = await render(app, router: EventRouter())

            // exactly one <pre> on this surface, so the extraction is unambiguous.
            #expect(Self.count(of: "<pre>", in: html) == 1)
            let summary = try #require(Self.text(between: "<pre>", and: "</pre>", in: html))
            #expect(summary == ToolPolicy.describe(config: policy),
                    "the summary must be describe()'s own bytes — re-wording it here would let the panel and the agent disagree")
            #expect(Self.count(of: ToolPolicy.describe(config: policy), in: html) == 1,
                    "the summary appears once, verbatim, and no second copy paraphrases it")

            // the rows appear in array order — three labels at increasing offsets.
            let first = try #require(html.range(of: "1. allow  *"))
            let second = try #require(html.range(of: "2. deny  mcp_tool"))
            let third = try #require(html.range(of: "3. denyWithHint  run_*"))
            #expect(first.lowerBound < second.lowerBound, "row 1 precedes row 2")
            #expect(second.lowerBound < third.lowerBound, "row 2 precedes row 3")

            // the edges are inert rather than absent: two live up arrows (rows
            // 2 and 3) and two live down arrows (rows 1 and 2).
            #expect(Self.count(of: "data-component-id=\"tp-up-", in: html) == 2)
            #expect(Self.count(of: "data-component-id=\"tp-down-", in: html) == 2)
            // the toolset column says "any" where a rule has none.
            #expect(Self.count(of: "any toolset", in: html) == 1)
            #expect(Self.count(of: "toolset: mcp", in: html) == 1)
            #expect(Self.count(of: "toolset: terminal", in: html) == 1)
        }

        // MARK: - the controls write

        @Test("moving a rule up rewrites the list in that order and flips the verdict it decides")
        func movingARuleIsPolicy() async throws {
            // two of these match run_command in `terminal`, which is what makes
            // their ORDER the verdict: the later of the two decides.
            let rules = [
                ToolPolicyRule(match: "*", toolset: nil, action: .allow, reason: nil),
                ToolPolicyRule(match: "run_*", toolset: "terminal", action: .denyWithHint,
                               reason: "shell access needs a human"),
                ToolPolicyRule(match: "run_command", toolset: "terminal", action: .deny,
                               reason: "never the shell"),
            ]
            let (url, store) = try scratchConfig()
            _ = try await store.mutate {
                $0.security.toolPolicy = ToolPolicyConfig(enabled: true, rules: rules)
            }
            var fixture = AppState.RenderFixture()
            fixture.arcConfig = try ConfigurationStore.readDeclared(url)
            let app = AppState(renderFixture: fixture, configurationStore: store)
            let router = EventRouter()
            let html = await render(app, router: router)
            #expect(Self.count(of: "data-component-id=\"tp-up-2\"", in: html) == 1,
                    "the third row's up arrow is a live control — only the first row's is inert")

            // before the move the exact-match deny is last, so it decides.
            #expect(ToolPolicy.decide(toolName: "run_command", toolset: "terminal",
                                      config: try ConfigurationStore.readDeclared(url).security.toolPolicy).action == .deny)

            let outcome = await router.dispatch(
                EventData(component: ComponentID("tp-up-2"), event: .click))
            #expect(outcome.isRefresh, "one move is one structural re-render")
            #expect(await app.arcConfig.security.toolPolicy.rules.map(\.match)
                    == ["*", "run_command", "run_*"])

            let onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.security.toolPolicy.rules.map(\.match) == ["*", "run_command", "run_*"],
                    "an order change reaches the file as shown — the list is never re-sorted")

            // order IS the semantics: the denyWithHint is last now, so it decides.
            #expect(ToolPolicy.decide(toolName: "run_command", toolset: "terminal",
                                      config: onDisk.security.toolPolicy).action == .denyWithHint,
                    "moving the denyWithHint below the deny changes the verdict it used to decide")
        }

        @Test("the form appends at the end and a submission keeps the fields it was typed with")
        func formAppendAndRestore() async throws {
            let (url, store) = try scratchConfig()
            let seed = ToolPolicyRule(match: "mcp_tool", toolset: "mcp", action: .deny, reason: "off limits")
            _ = try await store.mutate {
                $0.security.toolPolicy = ToolPolicyConfig(enabled: true, rules: [seed])
            }
            var fixture = AppState.RenderFixture()
            fixture.arcConfig = try ConfigurationStore.readDeclared(url)
            fixture.toolPolicyEditor = .adding
            let app = AppState(renderFixture: fixture, configurationStore: store)
            let router = EventRouter()
            let html = await render(app, router: router)
            #expect(Self.count(of: "data-component-id=\"tp-rule-form\" data-event=\"submit\"", in: html) == 1,
                    "the form itself carries the submit routing pair — no boot wiring answers it")

            // a blank match is refused through the form too: the list is untouched.
            _ = await router.dispatch(EventData(
                component: ComponentID("tp-rule-form"), event: .submit,
                data: ["tp-match-input": .string("  "),
                       "tp-action-input": .string(ToolPolicyAction.allow.rawValue)]))
            var onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.security.toolPolicy.rules == [seed],
                    "a refused submit must leave exactly the rule that was already there")
            #expect(await app.toolPolicyEditor == .adding, "the form stays open on a refusal")
            #expect(await app.formValues["tp-match-input"] == "  ",
                    "the refused submission is restored into the field it was typed in")

            // a valid submission is appended at the END — the strongest position.
            _ = await router.dispatch(EventData(
                component: ComponentID("tp-rule-form"), event: .submit,
                data: ["tp-match-input": .string("run_*"),
                       "tp-toolset-input": .string("terminal"),
                       "tp-action-input": .string(ToolPolicyAction.denyWithHint.rawValue),
                       "tp-reason-input": .string("shell access needs a human")]))
            onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.security.toolPolicy.rules == [
                seed,
                ToolPolicyRule(match: "run_*", toolset: "terminal", action: .denyWithHint,
                               reason: "shell access needs a human"),
            ], "a new rule lands last, normalized (empty toolset/reason absent, not blank)")
            #expect(await app.toolPolicyEditor == nil, "a saved form closes")
        }

        @Test("editing a rule replaces it in place and removing one keeps the rest in order")
        func editInPlaceAndRemove() async throws {
            let (url, store) = try scratchConfig()
            _ = try await store.mutate {
                $0.security.toolPolicy = ToolPolicyConfig(enabled: true, rules: Self.threeRules)
            }
            var fixture = AppState.RenderFixture()
            fixture.arcConfig = try ConfigurationStore.readDeclared(url)
            let app = AppState(renderFixture: fixture, configurationStore: store)
            let router = EventRouter()
            _ = await render(app, router: router)

            // Edit on row 2 opens the form on that POSITION …
            _ = await router.dispatch(EventData(component: ComponentID("tp-edit-1"), event: .click))
            #expect(await app.toolPolicyEditor == .editing(1))
            // … seeded from the rule itself, not from an empty draft.
            let form = await render(app, router: router)
            #expect(form.contains("value=\"mcp_tool\""),
                    "the edit form must render the rule's own match into the field")
            #expect(form.contains("value=\"the MCP bridge is off limits\""))

            // saving replaces position 1 in place — it does not move to the end.
            _ = await router.dispatch(EventData(
                component: ComponentID("tp-rule-form"), event: .submit,
                data: ["tp-match-input": .string("mcp_tool"),
                       "tp-toolset-input": .string("mcp"),
                       "tp-action-input": .string(ToolPolicyAction.denyWithHint.rawValue),
                       "tp-reason-input": .string("changed in place")]))
            let edited = ToolPolicyRule(match: "mcp_tool", toolset: "mcp", action: .denyWithHint,
                                        reason: "changed in place")
            var onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.security.toolPolicy.rules == [Self.threeRules[0], edited, Self.threeRules[2]],
                    "an edit keeps the rule's position, because the position is its precedence")
            #expect(await app.toolPolicyEditor == nil)

            // removing the first rule leaves the remaining two in order.
            _ = await router.dispatch(EventData(component: ComponentID("tp-del-0"), event: .click))
            onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.security.toolPolicy.rules == [edited, Self.threeRules[2]],
                    "a removal shifts the rest up without re-ordering them")
        }

        @Test("the enable switch writes the flag and leaves every rule in place")
        func toggleWritesOnlyTheFlag() async throws {
            let (url, store) = try scratchConfig()
            _ = try await store.mutate {
                $0.security.toolPolicy = ToolPolicyConfig(enabled: false, rules: Self.threeRules)
            }
            var fixture = AppState.RenderFixture()
            fixture.arcConfig = try ConfigurationStore.readDeclared(url)
            let app = AppState(renderFixture: fixture, configurationStore: store)
            let router = EventRouter()
            _ = await render(app, router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("tool-policy-enabled"), event: .change,
                data: ["checked": .bool(true)]))

            #expect(outcome.isRefresh)
            let onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.security.toolPolicy.enabled, "the switch writes the flag")
            #expect(onDisk.security.toolPolicy.rules == Self.threeRules,
                    "turning the policy on must not touch a single rule")
            #expect(ToolPolicy.decide(toolName: "run_command", toolset: "terminal",
                                      config: onDisk.security.toolPolicy).action == .denyWithHint,
                    "and the enabled policy is the one decide applies")
        }
    }
}
