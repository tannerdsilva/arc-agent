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

/// Tool: send a message to another bot.
public enum SendBotMessageTool {

    /// The caller's context is captured here so slice 5 can deliver with the
    /// sender's identity; the stub body is unchanged until then.
    public static func entry(context: ToolContext, profiles: any ProfileStore) -> ToolEntry {
        ToolEntry(
            name: "send_bot_message",
            toolset: "profile",
            description: "Send a message to another agent (bot) in the roster. The message is delivered to their canonical Bot Chat.",
            schema: .object(properties: [
                "target": .string(description: "The name of the target agent profile."),
                "message": .string(description: "The message to send. Prefix with 'Message from <you> (@<your-name>):' so they know who is talking.")
            ], required: ["target", "message"]),
            handler: { args in
                guard let target = args["target"] as? String else {
                    return "Error: 'target' is required."
                }
                guard args["message"] as? String != nil else {
                    return "Error: 'message' is required."
                }

                // In a full implementation, this would use the BotMessagingService.
                // For now, we validate and return a success message.
                guard let targetName = ProfileName(target),
                      try await profiles.get(targetName) != nil else {
                    return "Error: Target profile '\(target)' not found."
                }

                return "Message sent to '\(target)'. They will see it in their Bot Chat on their next turn."
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "💬"
        )
    }
}

/// Tool: create a new bot profile.
public enum CreateProfileTool {

    public static func entry(profiles: any ProfileStore) -> ToolEntry {
        ToolEntry(
            name: "create_profile",
            toolset: "profile",
            description: "Create a new agent profile (bot). The name must be unique, lowercase alphanumeric with hyphens (2-64 chars).",
            schema: .object(properties: [
                "name": .string(description: "Unique profile name (lowercase, alphanumeric, hyphens, 2-64 chars)."),
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

                // Create the profile, cloning the config fields
                // `ProfileManager.create` has always cloned.
                var profile = Profile(name: name)
                if let source = args["clone_from"] as? String,
                   let sourceName = ProfileName(source),
                   let sourceProfile = try await profiles.get(sourceName) {
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

                try await profiles.put(profile)

                // Apply optional fields
                // NOTE (GROUNDZERO slice 5): every optional is still applied
                // only inside the `title` branch, so model/provider/group are
                // dropped when no title is given. Pinned RED by
                // `create_profile applies model without a title`.
                if let title = args["title"] as? String, !title.isEmpty {
                    profile.title = title
                    if let desc = args["description"] as? String { profile.description = desc }
                    if let model = args["model"] as? String { profile.model = model }
                    if let provider = args["provider"] as? String { profile.provider = provider }
                    if let group = args["group"] as? String { profile.group = group }
                    try await profiles.put(profile)
                }

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

    public static func entry(profiles: any ProfileStore) -> ToolEntry {
        ToolEntry(
            name: "delete_profile",
            toolset: "profile",
            description: "Permanently delete an agent profile and all its data. The 'default' profile cannot be deleted.",
            schema: .object(properties: [
                "name": .string(description: "The profile name to delete.")
            ], required: ["name"]),
            handler: { args in
                guard let name = args["name"] as? String else {
                    return "Error: 'name' is required."
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

    /// The caller's context is captured here so slice 5 can deliver with the
    /// sender's identity; the stub body is unchanged until then.
    public static func entry(context: ToolContext) -> ToolEntry {
        ToolEntry(
            name: "send_group_chat",
            toolset: "profile",
            description: "Send a message to a group chat room with multiple agents.",
            schema: .object(properties: [
                "group": .string(description: "The group chat room name."),
                "message": .string(description: "The message to send to the group.")
            ], required: ["group", "message"]),
            handler: { args in
                guard let group = args["group"] as? String else {
                    return "Error: 'group' is required."
                }
                guard args["message"] as? String != nil else {
                    return "Error: 'message' is required."
                }
                return "Message sent to group chat '\(group)'."
            },
            checkFn: nil,
            requiresEnv: [],
            emoji: "👥"
        )
    }
}
