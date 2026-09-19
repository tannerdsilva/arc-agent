import Foundation
import NIOCore
import NIOWebSocket
import WebUI

/// one message in a chat thread. `id` is the stable dom fragment id the
/// runtime patches against, so it must never repeat within a thread.
public struct ChatMessage: Sendable, Equatable {
	public enum Role: String, Sendable {
		case user
		case assistant
		case status
	}

	public let id: String
	public let role: Role
	public let text: String
	public let streaming: Bool

	public init(id: String, role: Role, text: String, streaming: Bool = false) {
		self.id = id
		self.role = role
		self.text = text
		self.streaming = streaming
	}
}

/// a per-connection websocket sink. a ws handler attaches its outbound
/// writer when the connection opens and detaches on close; turn tasks push
/// fragments through it so the browser repaints without a request.
public actor OutboundRelay {
	private var writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>?

	public init() {}

	public func attach(_ writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>) {
		self.writer = writer
	}

	public func detach() {
		self.writer = nil
	}

	public var isAttached: Bool {
		writer != nil
	}

	/// write a ws message, dropping silently when no writer is attached (the
	/// connection may have closed mid-turn; the page can reload).
	public func send(_ message: WSOutgoing) async {
		guard let writer else { return }
		var buffer = ByteBuffer()
		buffer.writeBytes(message.jsonBytes)
		do {
			try await writer.write(WebSocketFrame(fin: true, opcode: .text, data: buffer))
		} catch {
			self.writer = nil
		}
	}
}

/// per-session chat state: message threads, inflight turns, and the set of
/// attached relays that every fragment update is fanned out to (all tabs of
/// one session see streaming turns).
public actor ChatCoordinator {

	private struct Session {
		var profile: String
		var messages: [ChatMessage]
		var inflight: Bool = false
	}

	/// the maximum number of messages retained per thread; older messages are
	/// dropped so a long conversation cannot grow a page without bound.
	public static let maxThreadLength = 200

	private var sessions: [String: Session] = [:]
	private var relays: [String: [UUID: OutboundRelay]] = [:]
	private var nextSequence = 0

	public init() {}

	// MARK: - message thread

	/// the default chat surface targets the default profile's session.
	public static func defaultTarget() -> (sessionID: String, profile: String) {
		("default", "default")
	}

	/// the current thread snapshot for a session.
	public func messages(for sessionID: String) -> [ChatMessage] {
		sessions[sessionID]?.messages ?? []
	}

	/// whether a turn is currently running for a session.
	public func isInflight(_ sessionID: String) -> Bool {
		sessions[sessionID]?.inflight ?? false
	}

	/// mint a never-repeating message id.
	public func nextMessageID() -> String {
		defer { nextSequence += 1 }
		return "msg-\(nextSequence)"
	}

	/// append messages to a thread and broadcast the fresh thread fragment.
	public func append(sessionID: String, profile: String, messages: [ChatMessage]) async {
		var session = sessions[sessionID] ?? Session(profile: profile, messages: [])
		session.profile = profile
		session.messages.append(contentsOf: messages)
		if session.messages.count > Self.maxThreadLength {
			session.messages.removeFirst(session.messages.count - Self.maxThreadLength)
		}
		sessions[sessionID] = session
		await broadcastThread(sessionID)
	}

	/// replace a message in place (e.g. swap a `status` bubble for the final
	/// assistant message) and broadcast the fresh thread fragment.
	public func replace(sessionID: String, profile: String, messageID: String, with replacement: ChatMessage) async {
		guard var session = sessions[sessionID],
			  let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
		session.messages[index] = replacement
		sessions[sessionID] = session
		await broadcastThread(sessionID)
	}

	/// toggle the inflight (thinking) indicator and broadcast.
	public func setInflight(sessionID: String, profile: String, _ inflight: Bool) async {
		var session = sessions[sessionID] ?? Session(profile: profile, messages: [])
		session.inflight = inflight
		sessions[sessionID] = session
		await broadcastThread(sessionID)
	}

	// MARK: - relays / broadcast

	/// attach a connection's relay to a session and return the handle used to
	/// detach it later.
	public func attach(sessionID: String, relay: OutboundRelay) -> UUID {
		let id = UUID()
		relays[sessionID, default: [:]][id] = relay
		return id
	}

	public func detach(sessionID: String, id: UUID) {
		relays[sessionID]?.removeValue(forKey: id)
		if relays[sessionID]?.isEmpty == true {
			relays.removeValue(forKey: sessionID)
		}
	}

	/// fan out a ws message to every attached relay of a session.
	public func broadcast(sessionID: String, _ message: WSOutgoing) async {
		guard let session = relays[sessionID] else { return }
		for relay in session.values {
			await relay.send(message)
		}
	}

	/// re-render and push the thread fragment for a session to all relays.
	private func broadcastThread(_ sessionID: String) async {
		guard let session = sessions[sessionID] else { return }
		await broadcast(sessionID: sessionID, WSOutgoing.update(fragments: [
			FragmentUpdate(id: "chat-thread", html: ChatConnection.renderThread(messages: session.messages))
		]))
	}
}
