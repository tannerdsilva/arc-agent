import NIOCore
import NIOWebSocket

/// maps a session's token hash to the live WebSocket channels bound to it.
/// logout closes every channel here so revocation tears the connection down
/// immediately — the per-event liveness check is the backstop, not the
/// primary mechanism. channels self-unregister when the connection ends.
actor AuthConnectionRegistry {

	private var nextID = 0
	private var channels: [[UInt8]: [Int: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>]] = [:]

	/// register `channel` under its session; returns a handle for unregister.
	func register(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, tokenHash: [UInt8]) -> Int {
		nextID += 1
		channels[tokenHash, default: [:]][nextID] = channel
		return nextID
	}

	func unregister(_ id: Int, tokenHash: [UInt8]) {
		guard var byID = channels[tokenHash] else { return }
		byID.removeValue(forKey: id)
		if byID.isEmpty {
			channels.removeValue(forKey: tokenHash)
		} else {
			channels[tokenHash] = byID
		}
	}

	/// close every socket bound to `tokenHash` (fire-and-forget).
	func closeAll(forTokenHash tokenHash: [UInt8]) {
		guard let byID = channels.removeValue(forKey: tokenHash) else { return }
		for channel in byID.values {
			_ = channel.channel.close()
		}
	}
}
