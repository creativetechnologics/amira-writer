import Foundation

// MARK: - Provider Types

public enum LLMProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimax = "minimax"
    case opencode = "opencode"
    case claude = "claude"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimax: return "MiniMax"
        case .opencode: return "OpenCode Go"
        case .claude: return "Claude"
        }
    }

    public var baseURL: URL {
        switch self {
        case .minimax: return URL(string: "https://api.minimax.io/v1/chat/completions")!
        case .opencode: return URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!
        case .claude: return URL(string: "https://localhost")! // not used -- spawns CLI
        }
    }

    public var defaultModel: String {
        switch self {
        case .minimax: return "MiniMax-M2.7"
        case .opencode: return "minimax-m2.7"
        case .claude: return "sonnet"
        }
    }

    /// Whether this provider uses the Claude CLI instead of an HTTP API.
    public var usesCLI: Bool { self == .claude }

    /// Whether this provider needs an API key (Claude uses subscription auth via CLI).
    public var needsAPIKey: Bool { self != .claude }

    /// Known models for this provider.
    public var knownModels: [LLMModelInfo] {
        switch self {
        case .minimax:
            return [
                LLMModelInfo(id: "MiniMax-M2.7", name: "MiniMax M2.7", contextLength: 204800, promptPricing: nil, completionPricing: nil),
                LLMModelInfo(id: "MiniMax-M2.5", name: "MiniMax M2.5", contextLength: 204800, promptPricing: nil, completionPricing: nil),
            ]
        case .opencode:
            return [
                LLMModelInfo(id: "minimax-m2.7", name: "MiniMax M2.7", contextLength: 204800, promptPricing: nil, completionPricing: nil),
                LLMModelInfo(id: "minimax-m2.5", name: "MiniMax M2.5", contextLength: 204800, promptPricing: nil, completionPricing: nil),
                LLMModelInfo(id: "glm-5", name: "GLM-5", contextLength: 128000, promptPricing: nil, completionPricing: nil),
                LLMModelInfo(id: "kimi-k2.5", name: "Kimi K2.5", contextLength: 131072, promptPricing: nil, completionPricing: nil),
            ]
        case .claude:
            return [
                LLMModelInfo(id: "sonnet", name: "Claude Sonnet", contextLength: 200000, promptPricing: nil, completionPricing: nil),
                LLMModelInfo(id: "opus", name: "Claude Opus", contextLength: 1000000, promptPricing: nil, completionPricing: nil),
                LLMModelInfo(id: "haiku", name: "Claude Haiku", contextLength: 200000, promptPricing: nil, completionPricing: nil),
            ]
        }
    }
}

// MARK: - Model Info

public struct LLMModelInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int?
    public let promptPricing: String?
    public let completionPricing: String?

    public init(id: String, name: String, contextLength: Int?, promptPricing: String?, completionPricing: String?) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.promptPricing = promptPricing
        self.completionPricing = completionPricing
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: LLMModelInfo, rhs: LLMModelInfo) -> Bool { lhs.id == rhs.id }
}

// MARK: - Provider Configuration (persisted to UserDefaults)

@available(macOS 14.0, *)
@MainActor
@Observable
public final class LLMProviderConfig {
    public static let shared = LLMProviderConfig()

    private init() {
        // Load stored model ID for the active provider
        let key = "llm.\(activeProvider.rawValue).activeModel"
        activeModelID = UserDefaults.standard.string(forKey: key) ?? activeProvider.defaultModel
    }

    // MARK: - Active Provider & Model

    public var activeProvider: LLMProviderType = {
        LLMProviderType(rawValue: UserDefaults.standard.string(forKey: "llm.activeProvider") ?? "") ?? .minimax
    }() {
        didSet {
            UserDefaults.standard.set(activeProvider.rawValue, forKey: "llm.activeProvider")
            // Reload the model ID for the new provider
            let key = "llm.\(activeProvider.rawValue).activeModel"
            activeModelID = UserDefaults.standard.string(forKey: key) ?? activeProvider.defaultModel
        }
    }

    public var activeModelID: String = "" {
        didSet { UserDefaults.standard.set(activeModelID, forKey: "llm.\(activeProvider.rawValue).activeModel") }
    }

    // MARK: - API Keys

    public func apiKey(for provider: LLMProviderType) -> String {
        UserDefaults.standard.string(forKey: "llm.\(provider.rawValue).apiKey") ?? defaultKey(for: provider)
    }

    /// Get the model ID for a specific provider (not necessarily the active one).
    public func modelID(for provider: LLMProviderType) -> String {
        if provider == activeProvider { return activeModelID }
        let key = "llm.\(provider.rawValue).activeModel"
        return UserDefaults.standard.string(forKey: key) ?? provider.defaultModel
    }

    /// Set the model ID for a specific provider.
    public func setModelID(_ model: String, for provider: LLMProviderType) {
        if provider == activeProvider {
            activeModelID = model
        } else {
            let key = "llm.\(provider.rawValue).activeModel"
            UserDefaults.standard.set(model, forKey: key)
        }
    }

    public func setAPIKey(_ key: String, for provider: LLMProviderType) {
        UserDefaults.standard.set(key, forKey: "llm.\(provider.rawValue).apiKey")
    }

    private func defaultKey(for provider: LLMProviderType) -> String {
        switch provider {
        case .minimax: return "sk-cp-xepY5kt4tB-vUIs2Px9b1y_b2heeUfeFTR7NFQjD0elajPaHusqtuImNpLFSRJMPdSct3Sd_8H53PRfVbuoO-8J5_A7QQ1y83-SNs1d55TktWVdlqQS9oME"
        case .opencode: return "sk-Ei0YBhstxFaZmeqJIxjLdrSKRlsCgSRlSN2j6g2klvPjDpxOztgemX8CXPfNmF1C"
        case .claude: return ""  // Uses CLI auth, no API key needed
        }
    }

    // MARK: - Favorite Models

    public var favoriteModelIDs: Set<String> {
        get {
            let key = "llm.\(activeProvider.rawValue).favorites"
            let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
            return Set(arr)
        }
        set {
            let key = "llm.\(activeProvider.rawValue).favorites"
            UserDefaults.standard.set(Array(newValue), forKey: key)
        }
    }

    public func toggleFavorite(_ modelID: String) {
        var favs = favoriteModelIDs
        if favs.contains(modelID) { favs.remove(modelID) } else { favs.insert(modelID) }
        favoriteModelIDs = favs
    }

    // MARK: - Available Models

    public var availableModels: [LLMModelInfo] {
        activeProvider.knownModels
    }

    // MARK: - Claude CLI

    /// Resolve the path to the `claude` binary.
    public var claudeCLIPath: String? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isClaudeCLIAvailable: Bool { claudeCLIPath != nil }

    // MARK: - Convenience

    public var currentEndpoint: URL { activeProvider.baseURL }
    public var currentAPIKey: String { apiKey(for: activeProvider) }
    public var currentModelID: String { activeModelID }
    public var usesCLI: Bool { activeProvider.usesCLI }

    /// Display name for the active model.
    public var activeModelDisplayName: String {
        if let info = availableModels.first(where: { $0.id == activeModelID }) {
            return info.name
        }
        if let slash = activeModelID.lastIndex(of: "/") {
            return String(activeModelID[activeModelID.index(after: slash)...])
        }
        return activeModelID
    }
}
