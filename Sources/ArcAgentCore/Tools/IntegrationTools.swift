import Foundation
import CryptoKit

// MARK: - Media tools (Hermes image_gen/tts/transcription/video provider
// registry, HTTP-only providers — no heavyweight SDKs)

/// Generic HTTP media provider configuration, read from environment with
/// per-tool defaults (Hermes provider registry equivalents):
///   MEDIA_BASE_URL / MEDIA_API_KEY / MEDIA_IMAGE_MODEL / MEDIA_TTS_MODEL
///   MEDIA_TRANSCRIPTION_MODEL / MEDIA_VIDEO_MODEL
public struct MediaConfig: Sendable {
    public let baseURL: String
    public let apiKey: String
    public let imageModel: String
    public let ttsModel: String
    public let transcriptionModel: String
    public let videoModel: String

    public static func fromEnvironment() -> MediaConfig {
        let env = ProcessInfo.processInfo.environment
        return MediaConfig(
            baseURL: env["MEDIA_BASE_URL"] ?? "",
            apiKey: env["MEDIA_API_KEY"] ?? "",
            imageModel: env["MEDIA_IMAGE_MODEL"] ?? "gpt-image-1",
            ttsModel: env["MEDIA_TTS_MODEL"] ?? "gpt-4o-mini-tts",
            transcriptionModel: env["MEDIA_TRANSCRIPTION_MODEL"] ?? "whisper-1",
            videoModel: env["MEDIA_VIDEO_MODEL"] ?? "sora-2"
        )
    }

    public var configured: Bool { !baseURL.isEmpty && !apiKey.isEmpty }
}

/// OpenAI-compatible media endpoints (/images/generations, /audio/speech,
/// /audio/transcriptions, /videos). Responses are saved under
/// ~/.arc-agent/outputs/ and the path is returned.
public enum MediaTools {

    static let outputsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc-agent/outputs", isDirectory: true)

    static func save(data: Data, name: String, ext: String) throws -> String {
        try FileManager.default.createDirectory(at: outputsDir, withIntermediateDirectories: true)
        let url = outputsDir.appendingPathComponent("\(name).\(ext)")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    static func postJSON(_ config: MediaConfig, path: String, body: [String: Any]) async throws -> Data {
        guard let base = URL(string: config.baseURL) else { throw MediaError.notConfigured }
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MediaError.apiFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        return data
    }

    public static let imageGenerate = ToolEntry(
        name: "image_generate",
        toolset: "media",
        description: "Generate an image from a text prompt (HTTP provider). Returns the saved file path.",
        schema: .object(properties: [
            "prompt": .string(description: "Description of the image to generate"),
            "size": .string(description: "Size such as 1024x1024"),
            "output_name": .string(description: "Optional base name for the saved file"),
        ], required: ["prompt"]),
        handler: { args in
            let config = MediaConfig.fromEnvironment()
            guard config.configured else { return "Error: Media provider not configured (set MEDIA_BASE_URL and MEDIA_API_KEY)." }
            let prompt: String = try Self.required(args, key: "prompt")
            let body: [String: Any] = [
                "model": config.imageModel,
                "prompt": prompt,
                "size": args["size"] as? String ?? "1024x1024",
            ]
            let data = try await postJSON(config, path: "images/generations", body: body)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["data"] as? [[String: Any]])?.first,
                  let b64 = first["b64_json"] as? String,
                  let imageData = Data(base64Encoded: b64) else {
                return "Error: Provider returned no image data: \(String(data: data, encoding: .utf8) ?? "")"
            }
            let name = args["output_name"] as? String ?? "image-\(Int(Date().timeIntervalSince1970))"
            return try save(data: imageData, name: name, ext: "png")
        },
        emoji: "🎨"
    )

    public static let tts = ToolEntry(
        name: "tts",
        toolset: "media",
        description: "Convert text to speech (HTTP provider). Returns the saved audio file path.",
        schema: .object(properties: [
            "text": .string(description: "Text to speak"),
            "voice": .string(description: "Voice name (provider-specific)"),
            "output_name": .string(description: "Optional base name for the saved file"),
        ], required: ["text"]),
        handler: { args in
            let config = MediaConfig.fromEnvironment()
            guard config.configured else { return "Error: Media provider not configured (set MEDIA_BASE_URL and MEDIA_API_KEY)." }
            let text: String = try Self.required(args, key: "text")
            let body: [String: Any] = [
                "model": config.ttsModel,
                "input": text,
                "voice": args["voice"] as? String ?? "alloy",
                "response_format": "mp3",
            ]
            let data = try await postJSON(config, path: "audio/speech", body: body)
            let name = args["output_name"] as? String ?? "tts-\(Int(Date().timeIntervalSince1970))"
            return try save(data: data, name: name, ext: "mp3")
        },
        emoji: "🔊"
    )

    public static let transcription = ToolEntry(
        name: "transcription",
        toolset: "media",
        description: "Transcribe an audio file (HTTP provider). Returns the transcript text.",
        schema: .object(properties: [
            "path": .string(description: "Path to the audio file (mp3/wav/m4a)"),
        ], required: ["path"]),
        handler: { args in
            let config = MediaConfig.fromEnvironment()
            guard config.configured else { return "Error: Media provider not configured (set MEDIA_BASE_URL and MEDIA_API_KEY)." }
            let path: String = try Self.required(args, key: "path")
            guard FileManager.default.fileExists(atPath: path) else {
                return "Error: Audio file not found: \(path)"
            }
            let audio = try Data(contentsOf: URL(fileURLWithPath: path))
            let url = URL(string: config.baseURL)!.appendingPathComponent("audio/transcriptions")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            let boundary = "arc-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(config.transcriptionModel)\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
            body.append(audio)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                return "Error: Transcription failed: \(String(data: data, encoding: .utf8) ?? "")"
            }
            return text
        },
        emoji: "🎤"
    )

    public static let videoGenerate = ToolEntry(
        name: "video_generate",
        toolset: "media",
        description: "Generate a short video from a text prompt (HTTP provider). Returns the saved file path.",
        schema: .object(properties: [
            "prompt": .string(description: "Description of the video to generate"),
            "output_name": .string(description: "Optional base name for the saved file"),
        ], required: ["prompt"]),
        handler: { args in
            let config = MediaConfig.fromEnvironment()
            guard config.configured else { return "Error: Media provider not configured (set MEDIA_BASE_URL and MEDIA_API_KEY)." }
            let prompt: String = try Self.required(args, key: "prompt")
            let body: [String: Any] = ["model": config.videoModel, "prompt": prompt]
            let data = try await postJSON(config, path: "videos/generations", body: body)
            // Some providers return a URL to poll; we return it as-is.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let videoURL = json["url"] as? String {
                return "Video generation started: \(videoURL)"
            }
            let name = args["output_name"] as? String ?? "video-\(Int(Date().timeIntervalSince1970))"
            return try save(data: data, name: name, ext: "json")
        },
        emoji: "🎬"
    )

    static func required(_ args: [String: Any], key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw MediaError.missingArgument(key)
        }
        return value
    }
}

public enum MediaError: Error, CustomStringConvertible {
    case notConfigured
    case missingArgument(String)
    case apiFailed(String)

    public var description: String {
        switch self {
        case .notConfigured: return "Media provider not configured"
        case .missingArgument(let key): return "Missing required argument: \(key)"
        case .apiFailed(let msg): return "Media API failed: \(msg)"
        }
    }
}

// MARK: - Outbound webhooks (Hermes `outbound_webhooks.py`)

/// Fire-and-forget webhook delivery: HMAC-SHA256 signed POST to configured
/// URLs (env `WEBHOOK_URLS` comma-separated, signature via `WEBHOOK_SECRET`).
public actor WebhookEngine {
    public static let shared = WebhookEngine()

    let urls: [String] = (ProcessInfo.processInfo.environment["WEBHOOK_URLS"] ?? "")
        .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    let secret = ProcessInfo.processInfo.environment["WEBHOOK_SECRET"] ?? ""

    private struct Pending {
        let url: String
        let payload: [String: Any]
    }
    private var queue: [Pending] = []

    public func notify(event: String, payload: [String: Any]) async -> String {
        guard !urls.isEmpty else {
            return "Error: No webhook URLs configured (set WEBHOOK_URLS)."
        }
        var body = payload
        body["event"] = event
        body["sent_at"] = Int(Date().timeIntervalSince1970)
        var results: [String] = []
        for url in urls {
            do {
                try await deliver(url: url, body: body)
                results.append("\(url): OK")
            } catch {
                results.append("\(url): failed (\(error.localizedDescription))")
            }
        }
        return results.joined(separator: "\n")
    }

    private func deliver(url: String, body: [String: Any]) async throws {
        guard let target = URL(string: url) else { throw URLError(.badURL) }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            let signature = WebhookEngine.HMAC_SHA256(key: secret, data: payload)
            request.setValue("sha256=\(signature)", forHTTPHeaderField: "X-Arc-Signature")
        }
        request.httpBody = payload
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    static func HMAC_SHA256(key: String, data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(key.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public enum WebhookTools {
    public static let notify = ToolEntry(
        name: "notify_webhook",
        toolset: "webhooks",
        description: "Send an event notification to all configured webhook URLs (HMAC-SHA256 signed).",
        schema: .object(properties: [
            "event": .string(description: "Event name (e.g. task_complete, deploy, error)"),
            "message": .string(description: "Human-readable message"),
            "data": .string(description: "Optional extra JSON payload string"),
        ], required: ["event", "message"]),
        handler: { args in
            let event: String = try MediaTools.required(args, key: "event")
            let message: String = try MediaTools.required(args, key: "message")
            var payload: [String: Any] = ["message": message]
            if let extra = args["data"] as? String,
               let json = try? JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any] {
                payload.merge(json) { _, new in new }
            }
            return await WebhookEngine.shared.notify(event: event, payload: payload)
        },
        emoji: "📣"
    )
}

// MARK: - Shell hooks (Hermes `shell_hooks.py`)

/// Pre/post command hooks keyed by tool name, loaded from
/// `~/.arc-agent/hooks.json`:
///   { "shell": { "pre": { "terminal": "cmd" }, "post": { "write_file": "cmd" } } }
public actor ShellHooks {
    public static let shared = ShellHooks()

    private var preHooks: [String: String] = [:]
    private var postHooks: [String: String] = [:]

    init() {
        load()
    }

    func load() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc-agent/hooks.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shell = json["shell"] as? [String: Any] else { return }
        preHooks = shell["pre"] as? [String: String] ?? [:]
        postHooks = shell["post"] as? [String: String] ?? [:]
    }

    /// Run the pre-hook for a tool (bounded 15s, output capped).
    public func runPreHook(toolName: String) async -> String? {
        guard let command = preHooks[toolName] else { return nil }
        return await run(command)
    }

    public func runPostHook(toolName: String) async -> String? {
        guard let command = postHooks[toolName] else { return nil }
        return await run(command)
    }

    private func run(_ command: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "hook failed: \(error.localizedDescription)"
        }
        let output = await withTaskGroup(of: String.self) { group in
            group.addTask {
                var data = Data()
                do {
                    for try await byte in pipe.fileHandleForReading.bytes {
                        data.append(byte)
                        if data.count >= 8_000 { break }
                    }
                } catch {}
                return String(data: data, encoding: .utf8) ?? ""
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                process.terminate()
                return ""
            }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Code execution (Hermes `code_execution_tool`)

/// Runs Python (or another interpreter) via `Process` with a hard timeout
/// and output cap. Local execution, no sandbox — the result text says so.
public enum CodeExecutionTool {
    public static let entry = ToolEntry(
        name: "code_execution",
        toolset: "sandbox",
        description: "Execute a short Python program locally (timeout 30s, output cap 100KB). No sandbox isolation.",
        schema: .object(properties: [
            "code": .string(description: "Python source to execute"),
            "timeout_seconds": .integer(description: "Optional timeout (default 30)"),
        ], required: ["code"]),
        handler: { args in
            let code: String = try MediaTools.required(args, key: "code")
            let timeout = args["timeout_seconds"] as? Int ?? 30
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", code]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = await withTaskGroup(of: (String, Int32).self) { group in
                group.addTask {
                    var data = Data()
                    do {
                        for try await byte in pipe.fileHandleForReading.bytes {
                            data.append(byte)
                            if data.count >= 100_000 { break }
                        }
                    } catch {}
                    return (String(data: data, encoding: .utf8) ?? "", -1)
                }
                group.addTask {
                    // Wait for exit with a timeout race.
                    try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                    process.terminate()
                    return ("", -2)
                }
                let first = await group.next() ?? ("", -1)
                group.cancelAll()
                return first
            }
            let (text, _) = output
            return text.isEmpty
                ? "(no output)"
                : "Execution finished (local, no sandbox).\n\(text)"
        },
        emoji: "🐍"
    )
}
