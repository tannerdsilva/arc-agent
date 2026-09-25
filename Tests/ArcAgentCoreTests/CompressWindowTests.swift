import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - /compress window regression (suffix-negative-length trap)
// =========================================================================
//
// `ArcAgent.compressWindow` backs the interactive `/compress` command. The
// pre-fix code computed `suffix(maxMessages - systemMessages.count)` without
// clamping; when system messages alone exceeded the 20-message window, the
// argument went negative and `Array.suffix(_:)` raised
// `Fatal error: Can't take a suffix of negative length from a collection`
// (SIGTRAP — process death). This suite locks in the clamped behavior.

@Test("compressWindow with system messages under the cap keeps the recent tail")
func compressWindowUnderCap() {
    let system = (0..<2).map { Message(role: .system, content: "sys \($0)") }
    let recent = (0..<10).map { Message(role: .user, content: "msg \($0)") }
    let history = system + recent

    let result = ArcAgent.compressWindow(
        history: history,
        systemMessages: system,
        maxMessages: 20
    )

    // Window = 20 - 2 = 18, which exceeds the 12-element history, so the
    // whole history lands in the tail and system messages appear once more
    // at the head (same shape as the original un-clamped code for this case).
    #expect(result.count == 2 + 12)
    #expect(result.prefix(2).allSatisfy { $0.role == .system })
    // The tail preserves order: last element is the newest message.
    #expect(result[result.count - 1].content == "msg 9")
}

@Test("compressWindow with system messages over the cap does not trap")
func compressWindowSystemOverflow() {
    // 25 system messages alone exceed the 20-message window.
    let system = (0..<25).map { Message(role: .system, content: "sys \($0)") }
    let history = system + [
        Message(role: .user, content: "hello"),
        Message(role: .assistant, content: "hi"),
    ]

    let result = ArcAgent.compressWindow(
        history: history,
        systemMessages: system,
        maxMessages: 20
    )

    // Must NOT crash; degrades to system messages only (keep the head).
    #expect(result.map(\.role) == Array(repeating: Message.Role.system, count: 25))
}

@Test("compressWindow with exactly the cap works")
func compressWindowExactCap() {
    let system = (0..<20).map { Message(role: .system, content: "sys \($0)") }
    let history = system + [Message(role: .user, content: "tail")]

    let result = ArcAgent.compressWindow(
        history: history,
        systemMessages: system,
        maxMessages: 20
    )

    #expect(result.count == 20)
    #expect(result.allSatisfy { $0.role == .system })
}
