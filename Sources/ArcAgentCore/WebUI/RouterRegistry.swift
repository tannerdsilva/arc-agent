import Synchronization
import WebUI

/// maps a session's token hash to the routers (+ chat connections) of its
/// recent full renders, keyed by the per-render websocket token minted into
/// each page. replaced as pages re-render. keeping the recent N render
/// tokens per session lets several tabs of the same session route events
/// while a stale page from a *different* session can never present a valid
/// token for this one (cross-session replay); logout removes the whole
/// session entry.
public final class RouterRegistry: Sendable {

	public struct Entry: Sendable {
		public let router: EventRouter
		public let connection: ChatConnection

		public init(router: EventRouter, connection: ChatConnection) {
			self.router = router
			self.connection = connection
		}
	}

	private struct Values {
		var entries: [[UInt8]: [String: Entry]] = [:]
		var order: [[UInt8]: [String]] = [:]
	}

	private let values = Mutex(Values())
	private let maxRendersPerSession: Int

	public init(maxRendersPerSession: Int = 8) {
		self.maxRendersPerSession = maxRendersPerSession
	}

	/// resolve a page's presented token to its router + connection. a hit
	/// re-promotes the token in the lru so an actively-used page is not
	/// evicted mid-flight; unknown/foreign tokens return nil.
	public func resolve(forTokenHash hash: [UInt8], renderToken: String) -> Entry? {
		values.withLock { values in
			guard let entry = values.entries[hash]?[renderToken] else { return nil }
			if let idx = values.order[hash]?.firstIndex(of: renderToken) {
				values.order[hash]!.remove(at: idx)
				values.order[hash]!.append(renderToken)
			}
			return entry
		}
	}

	public func set(_ entry: Entry, forTokenHash hash: [UInt8], renderToken: String) {
		values.withLock { values in
			if values.entries[hash] == nil {
				values.entries[hash] = [:]
				values.order[hash] = []
			}
			if let seen = values.order[hash]!.firstIndex(of: renderToken) {
				values.order[hash]!.remove(at: seen)
			}
			values.entries[hash]![renderToken] = entry
			values.order[hash]!.append(renderToken)
			while values.order[hash]!.count > maxRendersPerSession {
				let evicted = values.order[hash]!.removeFirst()
				values.entries[hash]!.removeValue(forKey: evicted)
			}
		}
	}

	public func remove(forTokenHash hash: [UInt8]) {
		values.withLock { values in
			values.entries.removeValue(forKey: hash)
			values.order.removeValue(forKey: hash)
		}
	}

	/// snapshot of every session token hash that has live router entries —
	/// used by the maintenance sweep to drop entries whose session expired.
	public func allTokenHashes() -> [[UInt8]] {
		values.withLock { Array($0.entries.keys) }
	}
}
