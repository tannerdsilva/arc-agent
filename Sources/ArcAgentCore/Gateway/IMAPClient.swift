import Foundation
import NIO
@preconcurrency import NIOSSL
import NIOCore

/// Minimal IMAP4 client (RFC 3501 subset) for the email gateway adapter.
///
/// Supports: LOGIN, SELECT INBOX, SEARCH UNSEEN, FETCH (full message),
/// STORE \Seen, LOGOUT — with implicit TLS (993) or plain + STARTTLS.
/// Literal `{N}` payloads are captured by the line codec and returned
/// alongside the response text, so `BODY.PEEK[]` extraction is exact.
public final class IMAPClient: @unchecked Sendable {

    /// Untagged messages plus any literal payloads captured during the
    /// command (in order). `literals[0]` of a FETCH is the raw message.
    public struct CommandResponse: Sendable {
        public let text: String
        public let literals: [Data]

        public init(text: String, literals: [Data] = []) {
            self.text = text
            self.literals = literals
        }
    }

    public init(
        host: String,
        port: Int,
        username: String,
        password: String,
        useTLS: Bool = true,
        startTLS: Bool = false,
        eventLoopGroup: EventLoopGroup? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useTLS = useTLS
        self.startTLS = startTLS
        self.group = eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton
    }

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let useTLS: Bool
    private let startTLS: Bool
    private let group: EventLoopGroup

    private final class Connection: @unchecked Sendable {
        var channel: Channel? = nil
        var continuation: CheckedContinuation<CommandResponse, Error>? = nil
        var currentTag = ""
        var textBuffer = ""
        var literals: [Data] = []
        var error: Error? = nil
    }

    private var conn: Connection? = nil
    private var tagCounter = 0

    private func tlsContext() throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = .fullVerification
        return try NIOSSLContext(configuration: config)
    }

    /// Open the connection, optionally STARTTLS, and authenticate.
    public func connect() async throws {
        let conn = Connection()
        self.conn = conn

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(LineCodec())
                    if self.useTLS {
                        try channel.pipeline.syncOperations.addHandler(
                            try NIOSSLClientHandler(context: try self.tlsContext(), serverHostname: self.host),
                            position: .first
                        )
                    }
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()
        conn.channel = channel
        let codec = try await channel.pipeline.handler(type: LineCodec.self).get()
        codec.onLine = { [weak conn] line in self.receive(line: line, into: conn) }
        codec.onLiteral = { [weak conn] data in conn?.literals.append(data) }
        codec.onError = { [weak conn] err in
            guard let c = conn else { return }
            if let cont = c.continuation {
                c.continuation = nil
                cont.resume(throwing: err)
            } else {
                c.error = err
            }
        }

        // Consume the greeting (* OK).
        _ = try await commandExpectingTag(required: nil)
        _ = conn.literals; conn.literals = []

        if startTLS && !useTLS {
            _ = try await command("STARTTLS")
            // Wrap TLS around the existing pipeline: inbound decrypts first.
            try await channel.eventLoop.submit { [host, self] in
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: self.tlsContext(), serverHostname: host),
                    position: .first
                )
            }.get()
        }

        _ = try await command("LOGIN \(quote(username)) \(quote(password))")
    }

    /// Run a command and return its response.
    public func command(_ rawCommand: String) async throws -> CommandResponse {
        guard let conn = self.conn, let channel = conn.channel else { throw MailError.notConnected }
        tagCounter += 1
        let tag = "A\(tagCounter)"
        conn.currentTag = tag
        conn.textBuffer = ""
        conn.literals = []
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResponse, Error>) in
            conn.continuation = cont
            channel.writeAndFlush(ByteBuffer(string: "\(tag) \(rawCommand)\r\n")).whenFailure { error in
                conn.continuation?.resume(throwing: error)
                conn.continuation = nil
            }
        }
    }

    /// Wait for a response without issuing a command (greeting).
    private func commandExpectingTag(required: String?) async throws -> CommandResponse {
        guard let conn = self.conn else { throw MailError.notConnected }
        conn.currentTag = ""
        conn.textBuffer = ""
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResponse, Error>) in
            conn.continuation = cont
        }
    }

    private func receive(line rawLine: String, into conn: Connection?) {
        guard let conn = conn else { return }
        let line = rawLine.trimmingCharacters(in: .newlines)
        conn.textBuffer += line + "\n"

        // Greeting phase (no tag issued yet).
        if conn.currentTag.isEmpty {
            let upper = line.uppercased()
            if upper.hasPrefix("* OK") || upper.hasPrefix("* PREAUTH") {
                if let cont = conn.continuation {
                    conn.continuation = nil
                    cont.resume(returning: CommandResponse(text: conn.textBuffer, literals: conn.literals))
                }
            } else if upper.contains(" BYE") {
                if let cont = conn.continuation {
                    conn.continuation = nil
                    cont.resume(throwing: MailError.badResponse(line))
                }
            }
            return
        }

        // Tagged completion: "<tag> OK|NO|BAD ...".
        let upper = line.uppercased()
        if line.hasPrefix(conn.currentTag + " "),
           upper.hasSuffix(" OK") || upper.hasSuffix(" NO") || upper.hasSuffix(" BAD") {
            let response = CommandResponse(text: conn.textBuffer, literals: conn.literals)
            if let cont = conn.continuation {
                conn.continuation = nil
                if upper.hasSuffix(" OK") {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: MailError.badResponse(line))
                }
            }
        }
    }

    private func quote(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    // MARK: - High-level operations

    /// Select INBOX and return the numbers of unread messages.
    public func searchUnseen() async throws -> [Int] {
        _ = try await command("SELECT INBOX")
        let searchResp = try await command("SEARCH UNSEEN")
        var nums = parseSearchNumbers(searchResp.text)
        if nums.isEmpty {
            nums = parseSearchNumbers(try await command("SEARCH ALL").text)
        }
        return nums
    }

    private func parseSearchNumbers(_ text: String) -> [Int] {
        var nums: [Int] = []
        for line in text.split(separator: "\n") {
            let l = String(line)
            if l.hasPrefix("* SEARCH") {
                nums = l.dropFirst("* SEARCH".count)
                    .split(separator: " ")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
        }
        return nums
    }

    /// Fetch the full raw message (headers + body) for `number`.
    public func fetchMessage(_ number: Int) async throws -> Data {
        let resp = try await command("FETCH \(number) (BODY.PEEK[])")
        if let literal = resp.literals.first, !literal.isEmpty {
            return literal
        }
        // Server without literals (shouldn't happen): fall back to text parse.
        guard let firstBrace = resp.text.firstIndex(of: "{") else {
            throw MailError.badResponse("FETCH produced no body")
        }
        var content = String(resp.text[firstBrace...])
        content = String(content.drop(while: { $0 != "\n" }))
        if let close = content.range(of: "\n)") {
            content = String(content[..<close.lowerBound])
        }
        return Data(content.utf8)
    }

    /// Mark a message as seen (\Seen) so it is not picked up again.
    public func markSeen(_ number: Int) async throws {
        _ = try await command("STORE \(number) +FLAGS (\\Seen)")
    }

    public func logout() async throws {
        _ = try? await command("LOGOUT")
        try? await conn?.channel?.close().get()
    }
}

public enum MailError: Error, CustomStringConvertible {
    case notConnected
    case loginFailed(String)
    case badResponse(String)
    case timeout(String)

    public var description: String {
        switch self {
        case .notConnected: return "Mail transport not connected"
        case .loginFailed(let s): return "Mail login failed: \(s)"
        case .badResponse(let s): return "Mail bad response: \(s)"
        case .timeout(let cmd): return "Mail timeout awaiting reply to: \(cmd)"
        }
    }
}

/// Line-oriented codec used by the mail transports.
///
/// Delivers CRLF-terminated lines without the terminator and captures IMAP
/// literal payloads (`{N}` markers) as raw `Data` chunks in order.
/// Line-delimited framing codec. Confined to one channel pipeline; only ever
/// touched from that channel's event loop, so sharing is safe.
final class LineCodec: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    var onLine: ((String) -> Void)? = nil {
        didSet {
            guard let onLine else { return }
            let lines = bufferedLines
            bufferedLines.removeAll()
            for line in lines { onLine(line) }
        }
    }
    var onLiteral: ((Data) -> Void)? = nil
    var onError: ((Error) -> Void)? = nil
    /// Lines that arrived before `onLine` was installed (e.g. a server
    /// greeting racing the client's connect) — delivered on install.
    private var bufferedLines: [String] = []

    private enum State {
        case lines
        case literal(remaining: Int, data: Data)
    }
    private var state: State = .lines

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        while buffer.readableBytes > 0 {
            switch state {
            case .literal(let remaining, var acc):
                let take = min(remaining, buffer.readableBytes)
                if take > 0 {
                    acc.append(contentsOf: buffer.readBytes(length: take)!)
                }
                if acc.count >= remaining {
                    state = .lines
                    onLiteral?(acc)
                    continue // keep consuming subsequent lines
                }
                state = .literal(remaining: remaining - take, data: acc)
            case .lines:
                guard let nl = firstLineEnd(in: buffer) else { return }
                var line = String(decoding: buffer.readableBytesView[buffer.readerIndex..<nl].dropLast(1), as: UTF8.self)
                buffer.moveReaderIndex(forwardBy: nl - buffer.readerIndex)
                if line.hasSuffix("\r") { line.removeLast() }
                if let onLine {
                    onLine(line)
                } else {
                    bufferedLines.append(line)
                }
                // IMAP literal marker at end-of-line: `... {N}`.
                if let marker = literalLength(of: line) {
                    state = .literal(remaining: marker, data: Data())
                }
            }
        }
    }

    private func firstLineEnd(in buffer: ByteBuffer) -> Int? {
        buffer.readableBytesView.firstIndex(of: 0x0A).map { $0 + 1 }
    }

    private func literalLength(of line: String) -> Int? {
        guard let open = line.lastIndex(of: "{"),
              line.hasSuffix("}"),
              line.index(after: open) < line.index(before: line.endIndex) else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(digits)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError?(error)
        context.close(promise: nil)
    }
}
