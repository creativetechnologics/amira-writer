import Foundation

// MARK: - LLM Message

/// A single message in an LLM conversation (system, user, or assistant).
public struct LLMMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var role: String   // "system", "user", "assistant"
    public var content: String
    public var timestamp: Date

    public init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.role = try c.decode(String.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
    }
}

/// Backward-compatibility alias so existing code using `MiniMaxMessage` continues to compile.
public typealias MiniMaxMessage = LLMMessage

// MARK: - Chat Session

/// A persisted chat session with metadata.
public struct LLMChatSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var messages: [LLMMessage]
    /// Opaque storage for module-specific data (e.g. suggestions serialized as JSON).
    public var additionalJSON: Data?
    public var createdAt: Date
    public var updatedAt: Date

    public init(title: String, messages: [LLMMessage] = [], additionalJSON: Data? = nil) {
        self.id = UUID()
        self.title = title
        self.messages = messages
        self.additionalJSON = additionalJSON
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // Custom decoder to handle files saved with the old `suggestions` field gracefully.
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, additionalJSON, suggestions, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.messages = try c.decode([LLMMessage].self, forKey: .messages)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)

        // Prefer `additionalJSON` if present; fall back to re-encoding the old `suggestions` key.
        if let data = try? c.decode(Data.self, forKey: .additionalJSON) {
            self.additionalJSON = data
        } else if let rawSuggestions = try? c.decode(AnyCodable.self, forKey: .suggestions) {
            self.additionalJSON = try? JSONEncoder().encode(rawSuggestions)
        } else {
            self.additionalJSON = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(additionalJSON, forKey: .additionalJSON)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// A type-erased Codable wrapper used only for migration of the old `suggestions` field.
private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = Optional<Any>.none as Any
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // For migration purposes we just write the raw JSON data through; this is only used
        // when re-encoding old `suggestions` into `additionalJSON` (a Data blob).
        // We rely on the fact that JSONEncoder will call this, producing valid JSON.
        if let arr = value as? [Any] {
            try container.encode(arr.map { AnyCodable(wrapping: $0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable(wrapping: $0) })
        } else if let str = value as? String {
            try container.encode(str)
        } else if let num = value as? Double {
            try container.encode(num)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else {
            try container.encodeNil()
        }
    }

    fileprivate init(wrapping value: Any) {
        self.value = value
    }
}

// MARK: - Chat Persistence

/// Manages persisting chat sessions to disk inside the project bundle.
@available(macOS 14.0, *)
public enum LLMChatPersistence {
    private static func chatDirectory(projectURL: URL) -> URL {
        projectURL.appendingPathComponent("ChatHistory", isDirectory: true)
    }

    private static func sessionFile(projectURL: URL, key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return chatDirectory(projectURL: projectURL)
            .appendingPathComponent("\(safe).json")
    }

    private static func archiveDirectory(projectURL: URL) -> URL {
        chatDirectory(projectURL: projectURL)
            .appendingPathComponent("Archive", isDirectory: true)
    }

    /// Load the active session for a given key ("__show__" or a scene relative path).
    public static func loadSession(projectURL: URL, key: String) -> LLMChatSession? {
        let url = sessionFile(projectURL: projectURL, key: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LLMChatSession.self, from: data)
    }

    /// Save the active session for a given key.
    public static func saveSession(_ session: LLMChatSession, projectURL: URL, key: String) {
        let dir = chatDirectory(projectURL: projectURL)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = sessionFile(projectURL: projectURL, key: key)
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Archive the current session and return a fresh one.
    public static func archiveSession(projectURL: URL, key: String) -> LLMChatSession {
        if let existing = loadSession(projectURL: projectURL, key: key), !existing.messages.isEmpty {
            let archiveDir = archiveDirectory(projectURL: projectURL)
            try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let safe = key.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let archiveFile = archiveDir.appendingPathComponent("\(safe)_\(formatter.string(from: Date())).json")
            if let data = try? JSONEncoder().encode(existing) {
                try? data.write(to: archiveFile, options: .atomic)
            }
        }
        let fresh = LLMChatSession(title: key == "__show__" ? "Show Chat" : key)
        saveSession(fresh, projectURL: projectURL, key: key)
        return fresh
    }

    /// List archived sessions for a given key, newest first.
    public static func listArchives(projectURL: URL, key: String) -> [(name: String, url: URL)] {
        let archiveDir = archiveDirectory(projectURL: projectURL)
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: archiveDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent.hasPrefix(safe) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }

    /// Load an archived session by URL.
    public static func loadArchive(at url: URL) -> LLMChatSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LLMChatSession.self, from: data)
    }
}
