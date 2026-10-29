import ArcToolKit
import Foundation

// MARK: - Profile Tools
//
// The roster tools are *service-scoped*, not profile-scoped: they act on the
// roster, which belongs to the process, not on the calling profile's
// documents. Each one therefore takes the ``ProfileStore`` its caller already
// owns instead of constructing a `ProfileManager()` per call — before this,
// every roster call built its own manager and its own view of `index.json`.
//
// Validation, duplicate refusal, `notFound` and `cannotDeleteDefault` stay
// here: the store only stores (see ``ProfileStore``), and these are the
// roster rules the tools own.

/// Tool: list all profiles (bots) in the roster.
public enum ListProfilesTool {

    public static func entry(profiles: any ProfileStore) -> ToolEntry {
        ToolEntry(
            name: "list_profiles",
            toolset: "profile",
            description: "List all agent profiles (bots) in the roster with their names, titles, and descriptions.",
            schema: .object(properties: [:], required: []),
            handler: { _ in
                let roster = try await profiles.list()
                let data = try JSONSerialization.data(withJSONObject: roster.map { p in
                    [
                        "name": p.name,
                        "title": p.title,
                        "description": p.description,
                        "model": p.model ?? "",
                        "provider": p.provider ?? "",
                        "group": p.group ?? "",
                        "isPinned": p.isPinned
                    ] as [String: Any]
                }, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "📋"
        )
    }
}

/// Tool: get detailed information about a specific profile.
public enum GetProfileTool {

    public static func entry(profiles: any ProfileStore) -> ToolEntry {
        ToolEntry(
            name: "get_profile",
            toolset: "profile",
            description: "Get detailed information about a specific agent profile by name.",
            schema: .object(properties: [
                "name": .string(description: "The profile name to look up.")
            ], required: ["name"]),
            handler: { args in
                guard let name = args["name"] as? String else {
                    return "Error: 'name' is required."
                }
                // An invalid name can never match a record, so it is "not
                // found" rather than a validation error — the answer the
                // manager shim gives.
                guard let profileName = ProfileName(name),
                      let profile = try await profiles.get(profileName) else {
                    return "Error: Profile '\(name)' not found."
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "name": profile.name,
                    "title": profile.title,
                    "description": profile.description,
                    "model": profile.model ?? "(default)",
                    "provider": profile.provider ?? "(default)",
                    "hasCustomKey": profile.hasCustomKey,
                    "enabledToolsets": profile.enabledToolsets?.sorted() ?? [],
                    "disabledToolsets": profile.disabledToolsets?.sorted() ?? [],
                    "hasCustomSOUL": profile.soulMD != nil,
                    "group": profile.group ?? "",
                    "isPinned": profile.isPinned,
                    "createdAt": ISO8601DateFormatter().string(from: profile.createdAt),
                    "updatedAt": ISO8601DateFormatter().string(from: profile.updatedAt)
                ] as [String: Any], options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "🔍"
        )
    }
}

/// What `send_bot_message` needs from the messaging service.
///
/// `BotMessagingService` is an actor, and an actor cannot be subclassed, so the
/// one call this tool makes is named here: the daemon hands over the real
/// service, and the test target hands over a canned-reply conformer. The
/// requirement is `async` even though the service's own implementation is not,
/// which is what lets the actor-isolated method witness it without giving up
/// isolation.
public protocol BotMessageDelivering: Sendable {
    func sendMessageAndWait(
        _ message: BotMessagingService.BotMessage
    ) async -> AsyncThrowingStream<String, Error>
}

extension BotMessagingService: BotMessageDelivering {}

/// Tool: send a message to another bot and return the peer's reply.
public enum SendBotMessageTool {

    /// How long a turn waits for the peer's reply. A silent peer must never
    /// hold the turn open: past this bound the tool answers with a timeout
    /// string instead of throwing.
    public static let replyTimeout: Duration = .seconds(60)

    /// What the bounded wait produced.
    private enum Delivery: Sendable {
        case reply(String)
        case deliveredNoReply
        case timedOut
        case failed(String)
    }

    public static func entry(
        context: ToolContext,
        profiles: any ProfileStore,
        messaging: any BotMessageDelivering,
        replyTimeout: Duration = SendBotMessageTool.replyTimeout
    ) -> ToolEntry {
        ToolEntry(
            name: "send_bot_message",
            toolset: "profile",
            description: "Send a message to another agent (bot) in the roster and wait for their reply. The message is delivered to their canonical Bot Chat.",
            schema: .object(properties: [
                "target": .string(description: "The name of the target agent profile."),
                "message": .string(description: "The message to send. Prefix with 'Message from <you> (@<your-name>):' so they know who is talking.")
            ], required: ["target", "message"]),
            handler: { args in
                guard let target = args["target"] as? String, !target.isEmpty else {
                    return "Error: 'target' is required."
                }
                guard let body = args["message"] as? String, !body.isEmpty else {
                    return "Error: 'message' is required."
                }
                // The roster is the delivery precondition: the service would
                // throw `notFound` for an unknown recipient, but a tool-level
                // refusal can name the profile the model actually asked for.
                guard let targetName = ProfileName(target),
                      try await profiles.get(targetName) != nil else {
                    return "Error: Target profile '\(target)' not found."
                }

                // The sender's identity is the captured context — never a
                // process-global — and its display name comes from the roster
                // so the recipient sees a name, not a slug.
                let sender = context.profile.rawValue
                let senderDisplay = (try? await profiles.get(context.profile))?.displayName ?? sender
                let message = BotMessagingService.BotMessage(
                    from: sender,
                    fromDisplay: senderDisplay,
                    to: target,
                    body: body
                )

                let stream = await messaging.sendMessageAndWait(message)
                let outcome = await awaitReply(stream, timeout: replyTimeout)

                switch outcome {
                case .reply(let text):
                    return "Reply from '\(target)': \(text)"
                case .deliveredNoReply:
                    return "Message delivered to '\(target)'; no reply came back."
                case .timedOut:
                    return "Timed out after \(render(replyTimeout)) waiting for a reply from '\(target)'. The message may have been delivered — check their Bot Chat."
                case .failed(let reason):
                    return "Error: Could not deliver to '\(target)': \(reason)"
                }
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "💬"
        )
    }

    /// Render a bound for the timeout sentence: seconds when it is a whole
    /// second or more, milliseconds below that (a test can inject a 50ms bound).
    private static func render(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        if seconds >= 1 { return "\(seconds)s" }
        let millis = duration.components.attoseconds / 1_000_000_000_000_000
        return "\(max(millis, 1))ms"
    }

    /// Race the reply stream against `timeout`.
    ///
    /// Whichever finishes first wins; the loser is cancelled, so a peer that
    /// never answers costs the turn `timeout` and nothing more. The result
    /// travels as a value rather than an error: a silent peer is a normal
    /// outcome, not a failed tool call.
    private static func awaitReply(
        _ stream: AsyncThrowingStream<String, Error>,
        timeout: Duration
    ) async -> Delivery {
        await withTaskGroup(of: Delivery.self) { group in
            group.addTask {
                var text = ""
                do {
                    for try await chunk in stream { text += chunk }
                } catch {
                    return .failed(String(describing: error))
                }
                return text.isEmpty ? .deliveredNoReply : .reply(text)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}

/// Tool: create a new bot profile.
public enum CreateProfileTool {

    public static func entry(profiles: any ProfileStore) -> ToolEntry {
        ToolEntry(
            name: "create_profile",
            toolset: "profile",
            description: "Create a new agent profile (bot). The name must be unique: 2-64 characters, lowercase letters, digits, hyphens and underscores, starting with a letter or digit.",
            schema: .object(properties: [
                "name": .string(description: "Unique profile name (2-64 chars: lowercase letters, digits, hyphens, underscores; must start with a letter or digit)."),
                "title": .string(description: "Display title for the roster (optional)."),
                "description": .string(description: "One-line mission description (optional)."),
                "clone_from": .string(description: "Name of an existing profile to clone config from (optional)."),
                "model": .string(description: "Model override (optional)."),
                "provider": .string(description: "Provider override (optional)."),
                "group": .string(description: "Group name for roster organization (optional).")
            ], required: ["name"]),
            handler: { args in
                guard let name = args["name"] as? String else {
                    return "Error: 'name' is required."
                }
                guard validateProfileName(name), let profileName = ProfileName(name) else {
                    throw ProfileError.invalidName(name)
                }
                guard try await profiles.get(profileName) == nil else {
                    throw ProfileError.duplicateName(name)
                }

                // Clone first, then apply the explicit options over it, so a
                // caller that clones and overrides one field gets the override
                // rather than the source's value.
                var profile = Profile(name: name)
                if let source = args["clone_from"] as? String {
                    // A clone that names a profile the roster does not hold is
                    // a caller mistake, not an empty clone: refuse it instead
                    // of creating a silently un-cloned profile (slice 5).
                    guard let sourceName = ProfileName(source),
                          let sourceProfile = try await profiles.get(sourceName) else {
                        throw ProfileError.notFound(source)
                    }
                    profile.title = sourceProfile.title
                    profile.description = sourceProfile.description
                    profile.model = sourceProfile.model
                    profile.provider = sourceProfile.provider
                    profile.baseURL = sourceProfile.baseURL
                    profile.enabledToolsets = sourceProfile.enabledToolsets
                    profile.disabledToolsets = sourceProfile.disabledToolsets
                    profile.soulMD = sourceProfile.soulMD
                    profile.avatar = sourceProfile.avatar
                }

                // Every optional is applied on its own: a model with no title
                // is still a model. Before slice 5 all five lived inside the
                // `title` branch, so four of them were dropped whenever the
                // caller passed no title.
                if let title = args["title"] as? String, !title.isEmpty {
                    profile.title = title
                }
                if let description = args["description"] as? String, !description.isEmpty {
                    profile.description = description
                }
                if let model = args["model"] as? String, !model.isEmpty {
                    profile.model = model
                }
                if let provider = args["provider"] as? String, !provider.isEmpty {
                    profile.provider = provider
                }
                if let group = args["group"] as? String, !group.isEmpty {
                    profile.group = group
                }

                // The profile directory is the profile's document root
                // (`MEMORY.md` / `USER.md` live in it), so it must exist before
                // the first memory write.
                let directory = URL(fileURLWithPath: ProfileManager.profilesDir)
                    .appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: ProfileManager.sessionsDirectory(for: name)),
                    withIntermediateDirectories: true)

                // ONE write: the record is complete before it is stored, so no
                // reader can observe a half-configured profile and a failure
                // cannot leave one (the old create-then-update wrote twice).
                try await profiles.put(profile)

                return "Profile '\(name)' created successfully."
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "➕"
        )
    }
}

/// Tool: delete a bot profile.
public enum DeleteProfileTool {

    public static func entry(context: ToolContext, profiles: any ProfileStore) -> ToolEntry {
        ToolEntry(
            name: "delete_profile",
            toolset: "profile",
            description: "Permanently delete an agent profile and all its data. Requires confirm: true. Neither the 'default' profile nor the profile you are running as can be deleted.",
            schema: .object(properties: [
                "name": .string(description: "The profile name to delete."),
                "confirm": .boolean(description: "Must be true. A delete without explicit confirmation is refused and deletes nothing.")
            ], required: ["name", "confirm"]),
            handler: { args in
                guard let name = args["name"] as? String else {
                    return "Error: 'name' is required."
                }
                // Irreversible, so the confirmation is checked before anything
                // else and a missing one deletes nothing. The schema marks it
                // required; this re-checks it because a model can omit a
                // required field and the cost of being wrong is a lost profile.
                guard args["confirm"] as? Bool == true else {
                    return "Error: Refusing to delete '\(name)' without confirm: true."
                }
                // The caller's own profile is the one identity it cannot
                // destroy: deleting it would remove the documents it is
                // reading and writing as it works.
                guard name != context.profile.rawValue else {
                    return "Error: Refusing to delete '\(name)' — it is the profile this turn is running as."
                }
                guard name != "default" else {
                    throw ProfileError.cannotDeleteDefault
                }
                guard let profileName = ProfileName(name),
                      try await profiles.get(profileName) != nil else {
                    throw ProfileError.notFound(name)
                }
                try await profiles.delete(profileName)
                return "Profile '\(name)' deleted."
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "🗑️"
        )
    }
}

/// Tool: send a message to a group chat room.
public enum SendGroupChatTool {

    public static func entry(
        context: ToolContext,
        profiles: any ProfileStore,
        groupChats: GroupChatManager
    ) -> ToolEntry {
        ToolEntry(
            name: "send_group_chat",
            toolset: "profile",
            description: "Send a message to a group chat room with multiple agents. A room that does not exist yet is created from the roster profiles assigned to that group.",
            schema: .object(properties: [
                "group": .string(description: "The group chat room name."),
                "message": .string(description: "The message to send to the group.")
            ], required: ["group", "message"]),
            handler: { args in
                guard let group = args["group"] as? String, !group.isEmpty else {
                    return "Error: 'group' is required."
                }
                guard let message = args["message"] as? String, !message.isEmpty else {
                    return "Error: 'message' is required."
                }

                // An existing room keeps its membership; a new one is seeded
                // from the roster's group assignment, which is the only
                // membership source this tool has.
                let room: GroupChatRoom
                if let existing = await groupChats.get(name: group) {
                    room = existing
                } else {
                    let members = try await profiles.list()
                        .filter { $0.group == group }
                        .map { GroupChatRoom.Member(name: $0.name, displayName: $0.displayName) }
                    guard !members.isEmpty else {
                        return "Error: No group chat '\(group)' exists and no roster profile is assigned to group '\(group)'."
                    }
                    room = await groupChats.getOrCreate(name: group, members: members)
                }

                // `sendUserMessage` appends to the room log and drives the
                // room's rounds before returning, so by here the message has
                // actually landed where members read it.
                await room.sendUserMessage(message)
                let count = await room.members.count
                let sender = context.profile.rawValue
                return "Message from '@\(sender)' posted to group chat '\(group)' (\(count) member\(count == 1 ? "" : "s"))."
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "👥"
        )
    }
}
