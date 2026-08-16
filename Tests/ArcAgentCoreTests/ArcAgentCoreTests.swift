import Testing
import ArcAgentCore

@Test("core library greets correctly")
func coreGreeting() {
    let core = ArcAgentCore()
    #expect(core.greet().contains("0.0.0"))
}
