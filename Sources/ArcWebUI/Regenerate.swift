import ArcAgentCore
import Foundation
import WebUI

/// The prompt that produced an assistant reply — the exact input a
/// "regenerate" must ask again.
///
/// A pure lookup so the rule is testable with no store or turn: the reply must
/// be a final answer (not a tool-call row), and it must have a non-empty user
/// message before it. The original `displayText` rides along so a re-asked
/// slash-skill prompt still renders the line the reader typed.
struct ReplyPrompt: Equatable, Sendable {

    /// the index of the user message that produced the reply.
    let userMessageIndex: Int

    /// the model-facing text of that user message.
    let content: String

    /// the line the reader saw, when a slash command rewrote the content.
    let displayText: String?

    init?(messages: [Message], assistantIndex: Int) {
        guard messages.indices.contains(assistantIndex) else { return nil }
        let reply = messages[assistantIndex]
        guard reply.role == .assistant, (reply.toolCalls ?? []).isEmpty else { return nil }
        guard let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user })
        else { return nil }
        let prompt = messages[userIndex]
        guard let content = prompt.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.userMessageIndex = userIndex
        self.content = content
        self.displayText = prompt.displayText
    }
}

// MARK: - AppState

extension AppState {

    /// The prompt behind `assistantIndex`, after materializing the session's
    /// messages (they may have been evicted from the lazy cache).
    func regenerationPrompt(sessionID: String, assistantIndex: Int) async -> ReplyPrompt? {
        await ensureSessionMessages(sessionID)
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return nil }
        return ReplyPrompt(messages: session.messages, assistantIndex: assistantIndex)
    }

    /// Run the re-asked prompt as a new turn.
    ///
    /// Append-only by design: a session transcript is not rewritable on the
    /// Tessera backend (its `update` only publishes messages it has not seen),
    /// so regeneration appends a fresh attempt rather than erasing the old
    /// reply. The original exchange stays in the transcript; the new turn is
    /// the visible result.
    ///
    /// The wire spawns this as a task so the click returns immediately; tests
    /// and headless callers await the whole turn.
    func startRegeneration(
        sessionID: String,
        prompt: ReplyPrompt,
        pusher: @escaping @Sendable ([FragmentUpdate]) async -> Void
    ) async {
        // the new attempt lands at the end of the transcript; a reader who
        // clicked an older reply is scrolled up and must see it arrive.
        armScrollToBottom()
        await runTurn(
            userText: prompt.content,
            pusher: pusher,
            sessionID: sessionID,
            displayText: prompt.displayText,
            consumesDraft: false,
            usePendingAttachments: false
        )
    }
}
