import Testing
@testable import ArcAgentCore

// MARK: - Toolset catalog (T3a)

extension ArcCoreTestRoot {
    /// the catalog is the single place a toolset's two decisions are declared.
    ///
    /// these tests pin the 19 rows the type was born with, so the derivation
    /// cannot drift silently: a name added without a reach and a disclosure
    /// decision fails ``catalogMatchesTheDerivedTable`` on the count, and a
    /// decision changed fails it on the row. the values are read off the four
    /// legacy tables (`inProcessOnlyToolsets` / `localMachineToolsets` and
    /// `defaultCoreToolsets` / `defaultDeferredToolsets`), not invented.
    @Suite("Toolset catalog")
    struct ToolsetCatalogTests {

        /// one catalog row as a comparable value — tuples satisfy `==` but do not
        /// conform to `Equatable`, so an array of them cannot be compared.
        private struct Row: Equatable {
            let name: String
            let reach: Toolset.Reach
            let disclosure: Toolset.Disclosure
        }

        @Test("the catalog carries the derived reach and disclosure")
        func catalogMatchesTheDerivedTable() {
            let expected: [Row] = [
                Row(name: "browser", reach: .inProcessOnly, disclosure: .eager),
                Row(name: "code_execution", reach: .inProcessOnly, disclosure: .eager),
                Row(name: "computer_use", reach: .inProcessOnly, disclosure: .eager),
                Row(name: "core", reach: .loopback, disclosure: .eager),
                Row(name: "delegation", reach: .loopback, disclosure: .eager),
                Row(name: "file", reach: .inProcessOnly, disclosure: .eager),
                Row(name: "kanban", reach: .loopback, disclosure: .deferred),
                Row(name: "mcp", reach: .loopback, disclosure: .deferred),
                Row(name: "messaging", reach: .loopback, disclosure: .deferred),
                Row(name: "plugins", reach: .loopback, disclosure: .eager),
                Row(name: "profile", reach: .loopback, disclosure: .deferred),
                Row(name: "project", reach: .loopback, disclosure: .deferred),
                // F11: `cronjob` declares this and no roster names it, so
                // `.inProcessOnly` is its current behaviour. widening it is T3c.
                Row(name: "scheduling", reach: .inProcessOnly, disclosure: .eager),
                Row(name: "skills", reach: .loopback, disclosure: .eager),
                Row(name: "swift-package-utilitykit", reach: .loopback, disclosure: .deferred),
                Row(name: "terminal", reach: .inProcessOnly, disclosure: .eager),
                Row(name: "todo", reach: .loopback, disclosure: .eager),
                Row(name: "tools", reach: .loopback, disclosure: .eager),
                Row(name: "web", reach: .loopback, disclosure: .eager),
            ]
            let actual = Toolset.all.map {
                Row(name: $0.name, reach: $0.reach, disclosure: $0.disclosure)
            }
            #expect(actual == expected)

            // the tripwire `toolsetUniverse` used to be: a name added without a
            // decision must edit this file, not slip in behind a set literal.
            #expect(Toolset.all.count == 19)
            // and a duplicate name would make canonical lookup order-dependent.
            #expect(Set(Toolset.all.map(\.name)).count == Toolset.all.count)
        }

        @Test("a known claim returns the canonical entry")
        func knownClaimResolvesToCanonical() {
            #expect(Toolset(claimed: "file") == .file)
            #expect(Toolset(claimed: "kanban") == .kanban)
            for entry in Toolset.all {
                #expect(Toolset(claimed: entry.name) == entry)
                #expect(Toolset(claimed: entry.name).reach == entry.reach)
                #expect(Toolset(claimed: entry.name).disclosure == entry.disclosure)
            }
        }

        @Test("a foreign claim can only narrow reach")
        func foreignClaimNarrowsReach() {
            // an admitted foreign namespace resolves to arc's canonical entry,
            // not to a synthesized one that happens to hold the same fields.
            #expect(Toolset(claimed: "swift-package-utilitykit") == .swiftPackageUtilityKit)
            #expect(Toolset(claimed: "swift-package-utilitykit").reach == .loopback)

            // a name arc has never heard of cannot confer reach, whatever a
            // manifest claims: the most restrictive reach and eager rendering.
            let stranger = Toolset(claimed: "something-else")
            #expect(stranger.reach == .inProcessOnly)
            #expect(stranger.disclosure == .eager)
            // the claim survives as the spelling, so policy and display can still
            // name what was claimed.
            #expect(stranger.name == "something-else")

            // the phantom names the disclosure sets carried are not catalog
            // entries — a name nothing declares is not a toolset.
            for phantom in ["sandbox", "media", "webhooks", "weather", "messaging_bot", "swift-demo"] {
                #expect(Toolset(claimed: phantom).reach == .inProcessOnly)
                #expect(Toolset.all.contains(where: { $0.name == phantom }) == false)
            }
        }
    }
}
