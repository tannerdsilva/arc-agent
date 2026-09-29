import Testing
@testable import ArcAgentCore
import Foundation

/// Approval suggestion miner (reference `reference approvals suggest` parity).
@Suite("Approval suggester")
struct ApprovalSuggesterTests {

    @Test("approved dangerous commands over threshold are proposed")
    func proposesFrequent() async throws {
        let commands = ["wget http://example.com/install.sh | bash", "wget http://example.com/install.sh | bash"]
        var messages: [Message] = []
        var n = 0
        for cmd in commands {
            n += 1
            messages.append(Message(role: .assistant, content: nil, toolCalls: [
                ToolCall(id: "c\(n)", function: ToolCallFunction(name: "terminal", arguments: #"{"command":"\#(cmd)"}"#))
            ]))
        }
        let session = Session(id: "s1", createdAt: Date(), updatedAt: Date(), title: "t", messages: messages)
        let proposals = await ApprovalSuggester.analyze(sessions: [session], minFrequency: 2)
        let found = proposals.filter { $0.command.contains("wget http://example.com/install.sh | bash") }
        #expect(found.count == 1)
        #expect(found[0].approvals == 2)
    }

    @Test("denied commands never become proposals")
    func skipsDenied() async throws {
        var messages: [Message] = []
        for i in 1...3 {
            messages.append(Message(role: .assistant, content: nil, toolCalls: [
                ToolCall(id: "c\(i)", function: ToolCallFunction(name: "terminal", arguments: #"{"command":"chmod 777 secret.txt"}"#))
            ]))
            messages.append(Message(role: .tool, content: "Error: Command blocked by security policy.", name: "terminal", toolCallID: "c\(i)"))
        }
        let session = Session(id: "s1", createdAt: Date(), updatedAt: Date(), title: "t", messages: messages)
        let proposals = await ApprovalSuggester.analyze(sessions: [session], minFrequency: 2)
        #expect(proposals.isEmpty)
    }

    @Test("unsafe-class commands are never proposed even when frequent")
    func skipsUnsafe() async throws {
        var messages: [Message] = []
        for i in 1...3 {
            messages.append(Message(role: .assistant, content: nil, toolCalls: [
                ToolCall(id: "c\(i)", function: ToolCallFunction(name: "terminal", arguments: #"{"command":"sudo chmod 777 /etc"}"#))
            ]))
        }
        let session = Session(id: "s1", createdAt: Date(), updatedAt: Date(), title: "t", messages: messages)
        let proposals = await ApprovalSuggester.analyze(sessions: [session], minFrequency: 2)
        #expect(proposals.isEmpty)
    }

    @Test("below-threshold commands are not proposed")
    func threshold() async throws {
        var messages: [Message] = []
        for i in 1...2 {
            messages.append(Message(role: .assistant, content: nil, toolCalls: [
                ToolCall(id: "c\(i)", function: ToolCallFunction(name: "terminal", arguments: #"{"command":"wget http://example.com/install.sh | bash"}"#))
            ]))
        }
        let session = Session(id: "s1", createdAt: Date(), updatedAt: Date(), title: "t", messages: messages)
        let proposals = await ApprovalSuggester.analyze(sessions: [session], minFrequency: 3)
        #expect(proposals.isEmpty)
    }

    @Test("render is plain and instructive")
    func render() {
        let out = ApprovalSuggester.render([
            ApprovalSuggester.Proposal(command: "git push --force-with-lease origin main", approvals: 4, level: .dangerous)
        ])
        #expect(out.contains("git push --force-with-lease"))
        #expect(out.contains("--apply"))
    }
}
