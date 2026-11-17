import Testing
@testable import ArcAgentCore

// MARK: - The browser provider registers on first demand (T5b)

extension ArcCoreTestRoot {
    /// `buildRegistry` used to spawn an unstructured `Task` to register the CDP
    /// provider — once per agent, with no completion — so the first browser call
    /// could outrun it. The provider is now created by the read that needs it,
    /// and registration is by name, which is what makes that idempotent.
    @Suite("Browser provider", .serialized)
    struct BrowserProviderTests {

        @Test("a fresh registry holds nothing until a provider is asked for")
        func firstReadRegistersCDP() async {
            let registry = BrowserRegistry()
            let empty = await registry.available()
            #expect(empty.isEmpty)

            let provider = await registry.active()
            #expect(provider != nil)
            #expect(provider?.name == "cdp")

            let names = await registry.available()
            #expect(names == ["cdp"])
        }

        @Test("a second read returns the same provider, not a second registration")
        func secondReadIsIdentity() async {
            let registry = BrowserRegistry()
            let first = await registry.active()
            let second = await registry.active()

            guard let first, let second else {
                Issue.record("active() returned no provider for the default name")
                return
            }
            // identity, not count: `register` is keyed by name, so a provider
            // re-created per read would replace the entry and still leave one
            // key. `===` is the assertion that the read reused the instance.
            #expect((first as AnyObject) === (second as AnyObject))

            let names = await registry.available()
            #expect(names == ["cdp"])
        }

        @Test("a configured provider nobody registered is absent, not substituted")
        func unregisteredProviderIsAbsent() async {
            let registry = BrowserRegistry()
            // the name is a parameter rather than an environment read so this
            // case needs no `setenv`: an in-process environment mutation is
            // observed by every suite running concurrently, and the browser
            // tools read `BROWSER_PROVIDER` too.
            let provider = await registry.active(named: "not-installed")
            #expect(provider == nil)

            // and the refused read installed nothing — not even `cdp`.
            let names = await registry.available()
            #expect(names.isEmpty)
        }
    }
}
