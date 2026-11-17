import ArcToolKit
import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Tool availability (T4: one value, two members' worth of meaning)

extension ArcCoreTestRoot {
    @Suite("ToolAvailabilityTests")
    struct ToolAvailabilityTests {

        /// A tool whose only interesting property is the availability it
        /// declares. `.core` is an eager toolset, so nothing but availability
        /// can keep it out of the prompt array.
        private static func gatedTool(_ availability: ToolAvailability) -> ToolEntry {
            ToolEntry(
                name: "gated",
                toolset: .core,
                description: "a tool whose advertisement depends on its availability",
                schema: .object(properties: [:]),
                handler: { _ in "ok" },
                availability: availability
            )
        }

        /// The names the model would actually be offered.
        ///
        /// Assertions are by name, never by array emptiness: the disclosure
        /// bridge trio (`tool_search`/`tool_describe`/`tool_call`) would mask
        /// an "is the array empty" check the moment anything deferred.
        private static func advertisedNames(
            _ registry: any ToolRegistry
        ) -> [String] {
            ToolSchemaRenderer.promptSchemas(
                registry: registry,
                disabled: [],
                config: ToolSearchConfig(),
                contextLength: 200_000
            ).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }

        @Test("an unmet requirement hides the tool from the prompt array")
        func unmetRequirementHidesTool() {
            // RED-FIRST: before T4 this tool was advertised, because
            // `requiresEnv` was inert — no schema path consulted it (F5).
            let tool = Self.gatedTool(.requiresEnv(["ARC_T4_NOT_SET"]))
            let registry = CompileTimeToolRegistry().replacing([tool])
            let names = Self.advertisedNames(registry)
            #expect(names.contains("gated") == false,
                "an unmet requirement must not reach the schema array; got \(names)")
        }

        @Test("a met requirement advertises the tool")
        func metRequirementAdvertisesTool() {
            // the other half of the pair: the same declaration with nothing
            // outstanding is present. A filter that has never been green and
            // red in the same suite is unverified.
            let tool = Self.gatedTool(.always)
            let registry = CompileTimeToolRegistry().replacing([tool])
            let names = Self.advertisedNames(registry)
            #expect(names.contains("gated"),
                "an always-available tool must reach the schema array; got \(names)")

            // and `.requiresEnv` is green when the environment supplies the
            // variables — proven against an injected environment so the answer
            // cannot depend on the machine running the suite.
            let gated = Self.gatedTool(.requiresEnv(["ARC_T4_SET"]))
            let (visible, deferred) = DeferredToolPolicy.plan(
                entries: [gated],
                config: ToolSearchConfig(),
                env: ["ARC_T4_SET": "1"])
            #expect(visible.map(\.name) == ["gated"])
            #expect(deferred.isEmpty)
            let unmet = DeferredToolPolicy.plan(
                entries: [gated],
                config: ToolSearchConfig(),
                env: ["ARC_T4_SET": ""])
            #expect(unmet.visible.isEmpty)
            #expect(unmet.deferred.isEmpty)
        }

        @Test("the reason names every missing variable, and empty counts as missing")
        func unavailableReasonNamesTheMissingVariable() {
            let availability = ToolAvailability.requiresEnv(["ARC_ALPHA", "ARC_BETA"])

            let none = availability.unavailableReason(env: [:])
            #expect(none?.contains("ARC_ALPHA") == true)
            #expect(none?.contains("ARC_BETA") == true)

            // an empty credential is not a credential: A is present, B is set
            // to the empty string, and only B is named.
            let partial = availability.unavailableReason(env: ["ARC_ALPHA": "1", "ARC_BETA": ""])
            #expect(partial?.contains("ARC_BETA") == true)
            #expect(partial?.contains("ARC_ALPHA") == false)

            #expect(availability.unavailableReason(env: ["ARC_ALPHA": "1", "ARC_BETA": "2"]) == nil)
            #expect(availability.requiredEnvNames == ["ARC_ALPHA", "ARC_BETA"])

            #expect(ToolAvailability.always.unavailableReason(env: [:]) == nil)
            #expect(ToolAvailability.always.requiredEnvNames.isEmpty)
        }
    }
}
