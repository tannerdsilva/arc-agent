import Foundation
import NIO
import NIOSSL
import NIOCore

/// Minimal SMTP client (RFC 5321 subset) used by the email gateway adapter.
///
/// Supports: EHLO, AUTH PLAIN, MAIL FROM, RCPT TO, DATA (dot-stuffed),
/// QUIT — over implicit TLS (465) or plain + STARTTLS (587).
public final class SMTPSender: @unchecked Sendable {

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

    private var channel: Channel? = nil
    private var continuation: CheckedContinuation<String, Error>? = nil
    private var buffer = ""

    private func tlsContext() throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = .fullVerification
        return try NIOSSLContext(configuration: config)
    }

    /// Connect and authenticate.
    public func connect() async throws {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let addCodec = channel.pipeline.addHandler(LineCodec())
                if self.useTLS {
                    return addCodec.flatMap {
                        channel.pipeline.addHandler(
                            try! NIOSSLClientHandler(context: try! self.tlsContext(), serverHostname: self.host),
                            position: .first
                        )
                    }
                }
                return addCodec
            }
        let channel = try await bootstrap.connect(host: host, port: port).get()
        self.channel = channel
        let codec = try await channel.pipeline.handler(type: LineCodec.self).get()
        codec.onLine = { [weak self] line in self?.receive(line) }
        codec.onError = { [weak self] err in
            guard let self, let cont = self.continuation else { return }
            self.continuation = nil
            cont.resume(throwing: err)
        }

        _ = try await exchange(nil) // greeting (no command)
        if startTLS && !useTLS {
            _ = try await exchange("EHLO \(host)")
            _ = try await exchange("STARTTLS")
            try await channel.pipeline.addHandler(
                NIOSSLClientHandler(context: tlsContext(), serverHostname: host),
                position: .first
            ).get()
            _ = try await exchange("EHLO \(host)")
        } else {
            _ = try await exchange("EHLO \(host)")
        }

        // AUTH PLAIN: base64("\0user\0pass").
        let auth = Data([0] + username.utf8 + [0] + password.utf8).base64EncodedString()
        _ = try await exchange("AUTH PLAIN \(auth)")
    }

    private func receive(_ line: String) {
        buffer += line + "\n"
        guard let cont = continuation else { return }
        // SMTP response ends on the first line with a space after the code;
        // `<code>-` lines continue the (multi-line) reply.
        let fourth = line.count > 3 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
        if fourth != "-" {
            self.continuation = nil
            let reply = buffer
            buffer = ""
            cont.resume(returning: reply)
        }
    }

    /// If a complete response is already buffered (e.g. the 220 greeting
    /// arrived before `exchange` was awaited), consume and return it.
    private func takeCompleteResponse() -> String? {
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var consumed: [String] = []
        for line in lines where !line.isEmpty {
            consumed.append(line)
            let fourth = line.count > 3 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
            if fourth != "-" {
                buffer = ""
                return consumed.joined(separator: "\n") + "\n"
            }
        }
        return nil
    }

    /// Send `command` (nil for the greeting) and await the response.
    /// Throws on 4xx/5xx responses.
    @discardableResult
    private func exchange(_ command: String?) async throws -> String {
        guard let channel else { throw MailError.notConnected }
        if let ready = takeCompleteResponse() {
            return try validated(ready)
        }
        buffer = ""
        let text: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.continuation = cont
                    guard let command else { return } // greeting: just await
                    channel.writeAndFlush(ByteBuffer(string: command + "\r\n")).whenFailure { err in
                        if let c = self.continuation {
                            self.continuation = nil
                            c.resume(throwing: err)
                        }
                    }
                }
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(15))
                throw MailError.timeout("\(command ?? "<greeting>")")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        return try validated(text)
    }

    /// Check the SMTP status code of a full response; return it or throw.
    private func validated(_ text: String) throws -> String {
        let code = Int(text.prefix(3)) ?? 0
        guard (200...399).contains(code) else {
            throw MailError.badResponse(text.trimmingCharacters(in: .newlines))
        }
        return text
    }

    /// Send a full message (headers + body, CRLF line endings, no terminator).
    public func sendMail(from: String, to: String, message: String) async throws {
        _ = try await exchange("MAIL FROM:<\(from)>")
        _ = try await exchange("RCPT TO:<\(to)>")
        _ = try await exchange("DATA")

        let body = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let line = String(line)
                return line.hasPrefix(".") ? "." + line : line
            }
            .joined(separator: "\r\n")
        let payload = body + "\r\n.\r\n"
        buffer = ""
        let text: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            guard let channel = self.channel else {
                cont.resume(throwing: MailError.notConnected)
                return
            }
            channel.writeAndFlush(ByteBuffer(string: payload)).whenFailure { err in
                if let c = self.continuation {
                    self.continuation = nil
                    c.resume(throwing: err)
                }
            }
        }
        let code = Int(text.prefix(3)) ?? 0
        guard (200...399).contains(code) else {
            throw MailError.badResponse(text.trimmingCharacters(in: .newlines))
        }
    }

    public func quit() async throws {
        _ = try? await exchange("QUIT")
        try? await channel?.close().get()
    }
}
