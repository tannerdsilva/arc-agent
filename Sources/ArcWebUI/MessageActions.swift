import ArcAgentCore
import ArcTheme
import WebUI
import WebUIDesignSystem

/// one action offered in a message's hover footer.
///
/// the surface is closed by the product — copy the message, regenerate the
/// answer it received, or fork the conversation at this point into a new
/// session — so the type is an enum rather than an open protocol: rendering
/// stays exhaustive, and an action can never exist that no wire handler
/// answers.
enum MessageAction: Equatable, Sendable {

    /// copy the message's visible text. client-only: the overlay owns the
    /// `[data-copy]` delegate, so this action carries no server identity.
    case copy(text: String)

    /// ask the prompt that produced this reply again as a new turn. the reply
    /// is not rewritten: session transcripts are append-only on the Tessera
    /// backend, so regeneration appends the fresh attempt instead of erasing
    /// history the store cannot remove.
    case regenerate(sessionID: String, messageIndex: Int)

    /// fork the transcript through this message into a new session.
    case fork(sessionID: String, messageIndex: Int)

    /// the visible button text.
    var label: String {
        switch self {
        case .copy: "Copy"
        case .regenerate: "Regenerate"
        case .fork: "Fork here"
        }
    }

    /// the tooltip and the accessible name. regenerate states what actually
    /// happens (a new attempt), not an in-place rewrite the store cannot do.
    var title: String {
        switch self {
        case .copy: "Copy message"
        case .regenerate: "Ask this prompt again as a new turn"
        case .fork: "Start a new chat from this message"
        }
    }

    var icon: IconName {
        switch self {
        case .copy: .copy
        case .regenerate: .refreshCw
        case .fork: .gitBranch
        }
    }

    /// the id the engine reports as `targetId` for this action. nil when the
    /// action never reaches the server.
    var wireID: String? {
        switch self {
        case .copy: nil
        case .regenerate(let sessionID, let messageIndex):
            "regen-\(enc(sessionID)).\(messageIndex)"
        case .fork(let sessionID, let messageIndex):
            "fork-\(enc(sessionID)).\(messageIndex)"
        }
    }

    static func forkTarget(in wireID: String) -> (sessionID: String, messageIndex: Int)? {
        target(in: wireID, prefix: "fork-")
    }

    static func regenerateTarget(in wireID: String) -> (sessionID: String, messageIndex: Int)? {
        target(in: wireID, prefix: "regen-")
    }

    /// Decode `<kind>-<session>.<index>` back to its two fields.
    ///
    /// `enc` is base64url, whose alphabet is `A-Z a-z 0-9 - _`; `.` cannot
    /// occur inside it, so the first dot is the field boundary and the session
    /// id never needs escaping a second time.
    private static func target(
        in wireID: String, prefix: String
    ) -> (sessionID: String, messageIndex: Int)? {
        guard wireID.hasPrefix(prefix) else { return nil }
        let parts = wireID.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let sessionID = dec(parts[0]),
              !sessionID.isEmpty,
              let messageIndex = Int(parts[1]),
              messageIndex >= 0 else { return nil }
        return (sessionID, messageIndex)
    }
}

// MARK: - rendering

extension AppState {

    /// The actions a user message offers: copy always; fork only when the
    /// message belongs to a known session and has a stable transcript index.
    ///
    /// A task thread passes no session id on purpose: forking there would swap
    /// the active chat behind a panel that never shows it.
    func userMessageActions(for message: Message, rawIdx: Int, sessionID: String?) -> [MessageAction] {
        var actions: [MessageAction] = [.copy(text: userVisibleText(for: message))]
        if let sessionID, !sessionID.isEmpty, rawIdx >= 0 {
            actions.append(.fork(sessionID: sessionID, messageIndex: rawIdx))
        }
        return actions
    }

    /// The text a reader sees for a user message: the display text when set,
    /// otherwise the stored content with attachment marker plumbing stripped
    /// (the same view `messageHTML` renders).
    func userVisibleText(for message: Message) -> String {
        if let display = message.displayText { return display }
        let content = message.content ?? ""
        guard content.contains("[attachment: ") else { return content }
        return userAttachmentPills(content).visible
    }

    /// The actions an assistant reply offers: copy always; regenerate and
    /// fork only for a final reply that belongs to a known session.
    ///
    /// Intermediate tool-call rows are not replies: regenerating one would ask
    /// the prompt again and fork at it would cut a turn in half.
    func assistantMessageActions(for message: Message, rawIdx: Int, sessionID: String?) -> [MessageAction] {
        var actions: [MessageAction] = [.copy(text: message.content ?? "")]
        let isFinalReply = (message.toolCalls ?? []).isEmpty
        if let sessionID, !sessionID.isEmpty, rawIdx >= 0, isFinalReply {
            actions.append(.regenerate(sessionID: sessionID, messageIndex: rawIdx))
            actions.append(.fork(sessionID: sessionID, messageIndex: rawIdx))
        }
        return actions
    }

    /// The hover footer under a message.
    ///
    /// The row is one event boundary (`msg-actions`); each id-bearing control
    /// inside it reports itself as the engine's `targetId`, which is the shape
    /// `ClickIdentityContractTests` requires (the boundary must be an ancestor,
    /// never the control itself). A row with no server action carries no
    /// boundary at all, so a transcript without a session (a task thread) does
    /// not route its copy button into a wire that cannot act.
    func messageActionsHTML(_ actions: [MessageAction]) -> some WebUI.View {
        let controls: [any WebUI.View] = actions.map { actionButtonHTML($0) }
        let row = Div(class: .msgFoot) {
            Span(class: .msgActions) {
                controls
            }
        }
        return Group {
            if actions.contains(where: { $0.wireID != nil }) {
                row.wire("msg-actions")
            } else {
                row
            }
        }
    }

    /// One footer control. Copy is a client delegate (`data-copy`); fork is a
    /// server action whose id encodes the session and cut point.
    private func actionButtonHTML(_ action: MessageAction) -> some WebUI.View {
        Group {
            switch action {
            case .copy(let text):
                ArcButton(id: nil, component: nil, class: .msgActionBtn) {
                    WebUIIcon(action.icon, size: .small)
                    // the marker lets the overlay replace the LABEL with
                    // "Copied" instead of the whole button with "✓" — a
                    // labelled control must not collapse its own width.
                    Span { Text(action.label) }
                        .data("copy-label", "")
                }
                .data("copy", text)
                .title(action.title)
                .aria(.label(action.title))
            case .regenerate, .fork:
                ArcButton(id: action.wireID, component: nil, class: .msgActionBtn) {
                    WebUIIcon(action.icon, size: .small)
                    Span { Text(action.label) }
                }
                .title(action.title)
                .aria(.label(action.title))
            }
        }
    }
}
