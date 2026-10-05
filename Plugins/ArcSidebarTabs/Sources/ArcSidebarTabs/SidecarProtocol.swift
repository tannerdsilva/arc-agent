import Foundation

// MARK: - Sidecar wire protocol
//
// A sidecar plugin is a **separate process** speaking JSON lines over
// stdio (one envelope per line). The plugin binary is built by the
// author from this kit (see `SidecarServer`); the host spawns it, calls
// the RPC methods below, and forwards plugin→host requests back.
//
// Direction: host → plugin: `listTabs`, `install`, `render`,
// `dispatchEvent`, `activate`, `deactivate` (each carried as a request
// with an id; the plugin answers with the same id).
// Direction: plugin → host: `host.workspacePath`, `host.toast`,
// `host.navigate`, `host.refreshTab` (requests; the reasonably named
// "host." prefix marks them).
//
// Everything is small and dependency-free (Foundation + stdlib), so the
// kit — and plugin packages — stay trivially buildable.

/// One JSON value on the sidecar wire.
public enum SidecarValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SidecarValue])
    case object([String: SidecarValue])
    case null

    // MARK: Convenience builders

    public static func obj(_ pairs: [String: SidecarValue]) -> SidecarValue { .object(pairs) }

    public init(_ string: String) { self = .string(string) }
    public init(_ number: Double) { self = .number(number) }
    public init(_ bool: Bool) { self = .bool(bool) }

    // MARK: Accessors

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var object: [String: SidecarValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var array: [SidecarValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public func key(_ name: String) -> SidecarValue? { object?[name] }
}

extension SidecarValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([SidecarValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: SidecarValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "unrecognized SidecarValue"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

/// An RPC error payload.
public struct SidecarError: Codable, Sendable, Equatable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// One line on the wire. A request carries `id`+`method`; the reply
/// carries the same `id` with `result` or `error`. Host→plugin and
/// plugin→host requests are both just envelopes.
public struct SidecarEnvelope: Codable, Sendable, Equatable {
    public var id: Int?
    public var method: String?
    public var params: SidecarValue?
    public var result: SidecarValue?
    public var error: SidecarError?

    public init(
        id: Int? = nil,
        method: String? = nil,
        params: SidecarValue? = nil,
        result: SidecarValue? = nil,
        error: SidecarError? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    /// A request envelope.
    public static func request(id: Int, method: String, params: SidecarValue?) -> SidecarEnvelope {
        SidecarEnvelope(id: id, method: method, params: params)
    }

    /// A successful reply.
    public static func reply(id: Int, result: SidecarValue) -> SidecarEnvelope {
        SidecarEnvelope(id: id, result: result)
    }

    /// A failure reply.
    public static func reply(id: Int, error: SidecarError) -> SidecarEnvelope {
        SidecarEnvelope(id: id, error: error)
    }
}

/// The RPC methods of the sidecar protocol.
public enum SidecarMethod {
    // host → plugin
    public static let listTabs = "listTabs"
    public static let install = "install"
    public static let render = "render"
    public static let dispatchEvent = "dispatchEvent"
    public static let activate = "activate"
    public static let deactivate = "deactivate"

    // plugin → host
    public static let hostWorkspacePath = "host.workspacePath"
    public static let hostToast = "host.toast"
    public static let hostNavigate = "host.navigate"
    public static let hostRefreshTab = "host.refreshTab"
}

/// Tab identity rail data, mirrored over the wire. (The kit's
/// `SidebarTabIcon` enum is not Codable and lives only in-process.)
public struct SidecarTabDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let tooltip: String
    public let iconKind: String   // "named" | "custom" | "emoji"
    public let iconA: String      // catalog name / custom name / glyph
    public let iconB: String      // "" / custom body / ""

    public init(
        id: String,
        title: String,
        tooltip: String,
        iconKind: String,
        iconA: String,
        iconB: String = ""
    ) {
        self.id = id
        self.title = title
        self.tooltip = tooltip
        self.iconKind = iconKind
        self.iconA = iconA
        self.iconB = iconB
    }

    /// Build from an in-process tab (plugin side).
    public static func make(_ tab: any SidebarTab) -> SidecarTabDescriptor {
        let icon = tab.icon
        let (kind, a, b): (String, String, String)
        switch icon {
        case .named(let name): (kind, a, b) = ("named", name, "")
        case .custom(let name, let body): (kind, a, b) = ("custom", name, body)
        case .emoji(let glyph): (kind, a, b) = ("emoji", glyph, "")
        }
        return SidecarTabDescriptor(
            id: tab.id,
            title: tab.title,
            tooltip: tab.tooltip,
            iconKind: kind,
            iconA: a,
            iconB: b
        )
    }
}

// MARK: - Line accumulation
//
// FileHandle's AsyncBytes/`lines` is unreliable on the current toolchain
// (stops after the first re-arm race, observed live in StdioMCPClient).
// `readabilityHandler` runs on Foundation's internal queue and is
// single-threaded per handle, so this accumulator needs no lock — the
// same accepted pattern as `MCPLineAccumulator`.

/// Buffers incoming bytes into complete lines.
public final class SidecarLineAccumulator: @unchecked Sendable {
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    public init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    public func feed(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            let text = String(decoding: line, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                onLine(trimmed)
            }
        }
    }
}
