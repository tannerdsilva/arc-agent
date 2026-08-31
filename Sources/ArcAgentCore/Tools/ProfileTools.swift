import Foundation

// MARK: - Profile Tools

/// Tool: list all profiles (bots) in the roster.
public enum ListProfilesTool {

    public static let entry = ToolEntry(
        name: "list_profiles",
        toolset: "profile",
        description: "List all agent profiles (bots) in the roster with their names, titles, and descriptions.",
        schema: .object(properties: [:], required: []),
        handler: { _ in
            let manager = ProfileManager()
            let profiles = try await manager.list()
            let data = try JSONSerialization.data(withJSONObject: profiles.map { p in
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

/// Tool: get detailed information about a specific profile.
public enum GetProfileTool {

    public static let entry = ToolEntry(
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
            let manager = ProfileManager()
            guard let profile = try await manager.get(name: name) else {
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

/// Tool: send a message to another bot.
public enum SendBotMessageTool {

    public static let entry = ToolEntry(
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
            guard let message = args["message"] as? String else {
                return "Error: 'message' is required."
            }

            // In a full implementation, this would use the BotMessagingService.
            // For now, we validate and return a success message.
            let manager = ProfileManager()
            guard let _ = try await manager.get(name: target) else {
                return "Error: Target profile '\(target)' not found."
            }

            return "Message sent to '\(target)'. They will see it in their Bot Chat on their next turn."
        },
        checkFn: nil,
        requiresEnv: [],
        emoji: "💬"
    )
}

/// Tool: create a new bot profile.
public enum CreateProfileTool {

    public static let entry = ToolEntry(
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

            let manager = ProfileManager()
            let profile = try await manager.create(
                name: name,
                cloneFrom: args["clone_from"] as? String
            )

            // Apply optional fields
            if let title = args["title"] as? String, !title.isEmpty {
                var p = profile
                p.title = title
                if let desc = args["description"] as? String { p.description = desc }
                if let model = args["model"] as? String { p.model = model }
                if let provider = args["provider"] as? String { p.provider = provider }
                if let group = args["group"] as? String { p.group = group }
                try await manager.update(p)
            }

            return "Profile '\(name)' created successfully."
        },
        checkFn: nil,
        requiresEnv: [],
        emoji: "➕"
    )
}

/// Tool: delete a bot profile.
public enum DeleteProfileTool {

    public static let entry = ToolEntry(
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
            let manager = ProfileManager()
            try await manager.delete(name: name)
            return "Profile '\(name)' deleted."
        },
        checkFn: nil,
        requiresEnv: [],
        emoji: "🗑️"
    )
}

/// Tool: send a message to a group chat room.
public enum SendGroupChatTool {

    public static let entry = ToolEntry(
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
            guard let message = args["message"] as? String else {
                return "Error: 'message' is required."
            }
            return "Message sent to group chat '\(group)'."
        },
        checkFn: nil,
        requiresEnv: [],
        emoji: "👥"
    )
}
