import Foundation

// MARK: - Chat Page

/// The main chat interface page for the ARC Agent web UI.
///
/// Composes the header, message list, and input bar into a
/// complete HTML document. This is the primary view served
/// at `GET /ui`.
///
/// ```swift
/// let page = ChatPage(welcomeMessage: "How can I help you?")
/// let html = HTMLDocument(body: page.render()).render()
/// ```
public struct ChatPage: View {
    /// Optional welcome message to display.
    public let welcomeMessage: String

    /// Create the chat page.
    /// - Parameter welcomeMessage: An optional welcome message.
    public init(welcomeMessage: String = "How can I help you today?") {
        self.welcomeMessage = welcomeMessage
    }

    public func render() -> String {
        """
        <div class="vstack" style="height: 100vh;">
        \(HeaderView().render())
        \(MessageList(welcomeMessage: welcomeMessage).render())
        \(InputBar().render())
        </div>
        """
    }
}

// MARK: - Header

/// The top header bar showing the app title and connection status.
public struct HeaderView: View {
    public init() {}

    public func render() -> String {
        """
        <header class="header">
          <h1>⚡ ARC Agent</h1>
          <span id="conn" class="off">Disconnected</span>
        </header>
        """
    }
}

// MARK: - Message List

/// The scrollable message list container.
///
/// In Phase W2, this shows a welcome message. In later phases,
/// it will display conversation history and receive streaming
/// updates from the WebSocket handler.
public struct MessageList: View {
    /// The welcome message to display when there are no messages.
    public let welcomeMessage: String

    /// Create the message list.
    /// - Parameter welcomeMessage: Welcome text shown in the empty state.
    public init(welcomeMessage: String = "") {
        self.welcomeMessage = welcomeMessage
    }

    public func render() -> String {
        var html = """
        <div id="messages" class="message-list">
        """
        if !welcomeMessage.isEmpty {
            html += """
              <div class="message-bubble assistant">
                <div class="markdown">
                  <p>\(htmlEscape(welcomeMessage))</p>
                </div>
              </div>
            """
        }
        html += """
        </div>
        """
        return html
    }
}

// MARK: - Message Bubble

/// A single message bubble with role-based styling.
///
/// Messages are rendered with pre-processed HTML from the server
/// (markdown rendering and syntax highlighting happen in Swift
/// before the message reaches the browser).
public struct MessageBubble: View {
    /// The message role (user or assistant).
    public let role: String
    /// The pre-rendered HTML content of the message.
    public let contentHTML: String

    /// Create a message bubble.
    /// - Parameters:
    ///   - role: `"user"` or `"assistant"`.
    ///   - contentHTML: Pre-rendered HTML content.
    public init(role: String, contentHTML: String) {
        self.role = role
        self.contentHTML = contentHTML
    }

    public func render() -> String {
        """
        <div class="message-bubble \(role)">
          <div class="markdown">
            \(contentHTML)
          </div>
        </div>
        """
    }
}

// MARK: - Input Bar

/// The input bar at the bottom of the chat interface.
///
/// Contains a text input field and a send button. The JavaScript
/// runtime (Phase W3) captures keyboard events and sends messages
/// via WebSocket.
public struct InputBar: View {
    /// The placeholder text for the input field.
    public let placeholder: String
    /// The button label.
    public let buttonLabel: String

    /// Create the input bar.
    /// - Parameters:
    ///   - placeholder: Input placeholder text.
    ///   - buttonLabel: Send button label.
    public init(
        placeholder: String = "Type a message...",
        buttonLabel: String = "Send"
    ) {
        self.placeholder = placeholder
        self.buttonLabel = buttonLabel
    }

    public func render() -> String {
        """
        <div class="input-bar">
          <input
            id="message-input"
            class="input-field"
            type="text"
            placeholder="\(htmlEscape(placeholder))"
            autofocus
          >
          <button id="send-button" class="send-btn">\(htmlEscape(buttonLabel))</button>
        </div>
        """
    }
}
