import Foundation

// MARK: - Avatar Configuration

/// Visual configuration for a bot's avatar.
public struct AvatarConfig: Codable, Sendable, Equatable {
    /// Shape name: circle, squircle, pill, triangle, hexagon, cloud, drop, blob
    public var shape: String
    /// Hex color string (e.g. "#8b5cf6")
    public var color: String
    /// Optional uploaded/generated image data URL
    public var imageDataURL: String?
    /// Pet companion identifier (optional)
    public var pet: String?

    public init(
        shape: String = "circle",
        color: String = "#8b5cf6",
        imageDataURL: String? = nil,
        pet: String? = nil
    ) {
        self.shape = shape
        self.color = color
        self.imageDataURL = imageDataURL
        self.pet = pet
    }
}

// MARK: - Profile

/// A named, isolated agent configuration — the core primitive of Bot Mode.
///
/// A profile represents one "bot" in the roster. Each profile has its own
/// config overrides, memory, session store, and SOUL.md personality.
///
/// ## Design
///
/// - `Profile` is a value type (`Codable` + `Sendable`).
/// - The profile index lives in Tessera as kind-3004 events
///   (`arc/p/<name>/<seq>`) when tessera is configured, or in
///   `~/.arc/profiles/index.json` otherwise.
/// - Each profile has a filesystem directory under `~/.arc/profiles/<name>/`
///   (e.g. its canonical bot-chat id in `canonical_chat.txt`).
/// - The `"default"` profile is the backward-compatible primary agent.
/// Per-profile model context parameters (Hermes per-profile config parity).
/// Every field is optional: `nil` inherits the session's model config or the
/// provider default, so a profile can override just the window size.
public struct ProfileContextConfig: Codable, Sendable, Equatable {
    /// Model context window in tokens (Hermes `context_length`).
    public var contextLength: Int?
    /// Explicit generation budget (Hermes `max_tokens` override).
    public var maxOutputTokens: Int?
    /// Reasoning effort: "minimal"/"low"/"medium"/"high"/"max".
    public var reasoningEffort: String?
    /// Sampling temperature (0.0 - 2.0).
    public var temperature: Double?
    /// Nucleus sampling threshold (0.0 - 1.0).
    public var topP: Double?
    /// Auto-compress threshold in tokens: when the estimated context exceeds
    /// this, older history is summarized (nil = the default budget).
    public var compressionBudget: Int?

    public init(
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEffort: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        compressionBudget: Int? = nil
    ) {
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.temperature = temperature
        self.topP = topP
        self.compressionBudget = compressionBudget
    }

    /// True when no override is set (the profile inherits everything).
    public var isEmpty: Bool {
        contextLength == nil && maxOutputTokens == nil && reasoningEffort == nil
            && temperature == nil && topP == nil && compressionBudget == nil
    }
}

public struct Profile: Codable, Sendable, Identifiable, Equatable {
    /// Unique profile name (lowercase, alphanumeric + hyphens).
    /// Also serves as the `id` for `Identifiable` conformance.
    public let name: String

    /// Display title shown in the roster (e.g. "Research Analyst").
    public var title: String

    /// One-line mission description.
    public var description: String

    /// Model override (nil = inherit the default from config).
    public var model: String?

    /// Provider override (nil = inherit the default from config).
    public var provider: String?

    /// Base URL override (nil = inherit the default from config).
    public var baseURL: String?

    /// API key override (nil = inherit the default from config).
    /// Stored in the profile's .env, not in the profile JSON.
    public var hasCustomKey: Bool

    /// Enabled toolsets (nil = inherit defaults).
    public var enabledToolsets: Set<String>?

    /// Disabled toolsets (nil = inherit defaults).
    public var disabledToolsets: Set<String>?

    /// Custom SOUL.md content (personality + instructions).
    /// When nil, a default SOUL is generated from title + description.
    public var soulMD: String?

    /// Per-profile model context parameters (window size, generation budget,
    /// sampling). Nil fields inherit the session's model config or defaults.
    public var context: ProfileContextConfig?

    /// Visual avatar configuration.
    public var avatar: AvatarConfig?

    /// Group name for roster organization (optional).
    public var group: String?

    /// Whether this profile is pinned to the top of the roster.
    public var isPinned: Bool

    /// When the profile was created.
    public var createdAt: Date

    /// When the profile was last updated.
    public var updatedAt: Date

    /// Identifiable conformance.
    public var id: String { name }

    public init(
        name: String,
        title: String = "",
        description: String = "",
        model: String? = nil,
        provider: String? = nil,
        baseURL: String? = nil,
        hasCustomKey: Bool = false,
        enabledToolsets: Set<String>? = nil,
        disabledToolsets: Set<String>? = nil,
        soulMD: String? = nil,
        context: ProfileContextConfig? = nil,
        avatar: AvatarConfig? = nil,
        group: String? = nil,
        isPinned: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.hasCustomKey = hasCustomKey
        self.enabledToolsets = enabledToolsets
        self.disabledToolsets = disabledToolsets
        self.soulMD = soulMD
        self.context = context
        self.avatar = avatar
        self.group = group
        self.isPinned = isPinned
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// The display name for this profile (title ?? name).
    public var displayName: String {
        title.isEmpty ? name : title
    }

    /// The handle for @-mentions.
    public var handle: String {
        name.lowercased()
    }
}

// MARK: - Profile Validation

/// Errors that can occur during profile operations.
public enum ProfileError: Error, Sendable, CustomStringConvertible {
    case invalidName(String)
    case duplicateName(String)
    case notFound(String)
    case cannotDeleteDefault
    case storageError(String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            return "Invalid profile name '\(name)'. Use lowercase alphanumeric, hyphens, underscores (2-64 chars)."
        case .duplicateName(let name):
            return "A profile named '\(name)' already exists."
        case .notFound(let name):
            return "Profile '\(name)' not found."
        case .cannotDeleteDefault:
            return "The default profile cannot be deleted."
        case .storageError(let message):
            return "Profile storage error: \(message)"
        }
    }
}

/// Validate a profile name.
/// Rules: 2-64 chars, lowercase alphanumeric, hyphens, underscores.
public func validateProfileName(_ name: String) -> Bool {
    guard name.count >= 2 && name.count <= 64 else { return false }
    let pattern = "^[a-z0-9][a-z0-9_-]+$"
    return name.range(of: pattern, options: .regularExpression) != nil
}
