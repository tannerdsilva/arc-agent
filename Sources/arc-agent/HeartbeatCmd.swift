import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Heartbeat CLI (Hermes `/heartbeat`, `features/heartbeat.md`)

/// `arc heartbeat` — manage per-session recurring instructions that fire as
/// user turns while the session is idle.
struct HeartbeatCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "heartbeat",
        abstract: "Set, inspect, pause, resume, or clear a session heartbeat.",
        subcommands: [HeartbeatSet.self, HeartbeatStatus.self, HeartbeatPause.self,
                      HeartbeatResume.self, HeartbeatClear.self]
    )
}

struct HeartbeatSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set (or replace) the session heartbeat. Interval e.g. 90s, 10m, 2h, 1d (min 60s)."
    )

    @Argument(help: "Session ID.")
    var session: String

    @Option(name: .long, help: "How often to fire (e.g. 10m). Minimum 60s.")
    var every: String

    @Option(name: .long, help: "The recurring instruction to fire.")
    var prompt: String

    func run() async throws {
        guard let seconds = HeartbeatInterval.parse(every) else {
            throw ValidationError("invalid interval '\(every)' — use forms like 90s, 10m, 2h, 1d (minimum 60s).")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--prompt is required.")
        }
        let store = try HeartbeatStore()
        try await store.set(
            sessionID: session,
            intervalSeconds: seconds,
            prompt: prompt,
            chat: ChatTarget(platform: "", chatID: "", threadID: "")
        )
        try await store.save()
        print("♥ Heartbeat set (every \(HeartbeatInterval.format(seconds))): \(prompt)")
        print("  Session: \(session) — fires between turns while idle.")
    }
}

struct HeartbeatStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the heartbeat (interval, prompt, paused, time to next fire)."
    )

    @Argument(help: "Session ID (omit to list all).")
    var session: String?

    func run() async throws {
        let store = try HeartbeatStore()
        if let session {
            guard let hb = await store.status(sessionID: session) else {
                print("No heartbeat set for session \(session).")
                return
            }
            let remaining = max(0, Int(hb.nextFireAt.timeIntervalSinceNow))
            print("Session: \(session)")
            print("  Every:  \(HeartbeatInterval.format(hb.intervalSeconds))")
            print("  Prompt: \(hb.prompt)")
            print("  Paused: \(hb.paused ? "yes" : "no")")
            print("  Next:   \(hb.paused ? "paused" : "in \(remaining)s")")
            print("  Target: \(hb.chat.platform.isEmpty ? "unset (adopted by gateway on first message)" : "\(hb.chat.platform):\(hb.chat.chatID)")")
        } else {
            let known = await store.all()
            if known.isEmpty {
                print("No heartbeats set.")
                return
            }
            for key in known.keys.sorted() {
                if let hb = known[key] {
                    print("\(key)  every \(HeartbeatInterval.format(hb.intervalSeconds))  paused=\(hb.paused ? "y" : "n")  \(hb.prompt.prefix(40))")
                }
            }
        }
    }
}

struct HeartbeatPause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause", abstract: "Pause the session heartbeat without clearing it."
    )
    @Argument var session: String
    func run() async throws {
        let store = try HeartbeatStore()
        guard await store.status(sessionID: session) != nil else {
            print("No heartbeat set for session \(session).")
            return
        }
        await store.pause(sessionID: session)
        try await store.save()
        print("♥ Heartbeat paused for \(session). Use `arc heartbeat resume`.")
    }
}

struct HeartbeatResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume", abstract: "Resume the session heartbeat (re-anchors the timer)."
    )
    @Argument var session: String
    func run() async throws {
        let store = try HeartbeatStore()
        guard await store.status(sessionID: session) != nil else {
            print("No heartbeat set for session \(session).")
            return
        }
        await store.resume(sessionID: session)
        try await store.save()
        print("♥ Heartbeat resumed for \(session).")
    }
}

struct HeartbeatClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Remove the session heartbeat."
    )
    @Argument var session: String
    func run() async throws {
        let store = try HeartbeatStore()
        await store.clear(sessionID: session)
        try await store.save()
        print("♥ Heartbeat cleared for \(session).")
    }
}
