import Foundation

// MARK: - Canonical OWP Model Types
//
// These types were previously duplicated across WriteUI, ScoreUI, and AnimateUI.
// They are now unified here in ProjectKit as the single source of truth.
// All packages should import ProjectKit and use these types directly.

// MARK: - Characters

public struct OPWCharacterImage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var filename: String
    public var category: String

    public init(id: UUID = UUID(), filename: String, category: String) {
        self.id = id
        self.filename = filename
        self.category = category
    }
}

public struct OPWCharacter: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String?
    public var associatedChannelKeys: [String]
    public var galleryCategories: [String]
    public var images: [OPWCharacterImage]
    public var colorHex: String?
    public var loraFilename: String?
    public var loraWeight: Double?
    public var loraTriggerWord: String?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        associatedChannelKeys: [String] = [],
        galleryCategories: [String] = [],
        images: [OPWCharacterImage] = [],
        colorHex: String? = nil,
        loraFilename: String? = nil,
        loraWeight: Double? = nil,
        loraTriggerWord: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.associatedChannelKeys = associatedChannelKeys
        self.galleryCategories = galleryCategories
        self.images = images
        self.colorHex = colorHex
        self.loraFilename = loraFilename
        self.loraWeight = loraWeight
        self.loraTriggerWord = loraTriggerWord
    }

    public var directoryName: String {
        let safe = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? id.uuidString : safe
    }
}

public struct OPWCharactersFile: Codable, Sendable {
    public var version: Int
    public var characters: [OPWCharacter]

    public init(version: Int = 1, characters: [OPWCharacter] = []) {
        self.version = version
        self.characters = characters
    }
}

// MARK: - Song Stub (lightweight placeholder for progressive loading)

public struct SongStub: Identifiable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let relativePath: String
    public let fileSize: Int64
    public let title: String?
    public let canonicalTitle: String?

    public init(
        id: UUID,
        fileURL: URL,
        relativePath: String,
        fileSize: Int64,
        title: String? = nil,
        canonicalTitle: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.title = title
        self.canonicalTitle = canonicalTitle
    }

    public var displayName: String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        return withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
    }
}

// MARK: - Project Metadata

public struct ProjectMetadata: Codable, Sendable {
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var notes: String
    public var projectVersions: [ProjectVersionEntry]

    private enum CodingKeys: String, CodingKey {
        case name, createdAt, updatedAt, notes, projectVersions
    }

    public init(name: String = "Untitled", createdAt: Date = Date(), updatedAt: Date = Date(), notes: String = "", projectVersions: [ProjectVersionEntry] = []) {
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notes = notes
        self.projectVersions = projectVersions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        projectVersions = try container.decodeIfPresent([ProjectVersionEntry].self, forKey: .projectVersions) ?? []
    }

    public static func fresh(named name: String) -> ProjectMetadata {
        .init(name: name, createdAt: Date(), updatedAt: Date(), notes: "")
    }
}

// MARK: - Project-Level Version History

public struct ProjectVersionEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var userLabel: String?
    public var saveType: VersionSaveType
    public var isBookmarked: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var songVersionMap: [String: UUID]

    private enum CodingKeys: String, CodingKey {
        case id, label, userLabel, saveType, isBookmarked, createdAt, updatedAt, songVersionMap
    }

    public init(
        id: UUID = UUID(),
        label: String = "Version",
        userLabel: String? = nil,
        saveType: VersionSaveType = .manual,
        isBookmarked: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        songVersionMap: [String: UUID] = [:]
    ) {
        self.id = id
        self.label = label
        self.userLabel = userLabel
        self.saveType = saveType
        self.isBookmarked = isBookmarked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.songVersionMap = songVersionMap
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? "Version"
        userLabel = try container.decodeIfPresent(String.self, forKey: .userLabel)
        saveType = try container.decodeIfPresent(VersionSaveType.self, forKey: .saveType) ?? .manual
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
        songVersionMap = try container.decodeIfPresent([String: UUID].self, forKey: .songVersionMap) ?? [:]
    }

    public var displayName: String {
        userLabel ?? label
    }
}

public enum VersionSaveType: String, Codable, Sendable {
    case manual
    case autosave
    case snapshot
    case imported
}

// MARK: - Text File

public struct ProjectTextFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var relativePath: String
    public var content: String

    public init(id: UUID = UUID(), relativePath: String, content: String = "") {
        self.id = id
        self.relativePath = relativePath
        self.content = content
    }

    public var displayName: String {
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        return withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
    }
}

// MARK: - MIDI Asset

public struct MidiAsset: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var relativePath: String
    public var data: Data
    public var title: String?

    public init(id: UUID = UUID(), relativePath: String, data: Data = Data(), title: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.data = data
        self.title = title
    }

    public var displayName: String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        let name = withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
        return name.toTitleCase()
    }
}

// MARK: - String Helpers

extension String {
    /// Converts an ALL-CAPS or mixed-case string to Title Case,
    /// preserving numeric prefixes and uppercase acronyms/Roman numerals.
    public func toTitleCase() -> String {
        let words = self.split(separator: " ")
        return words.map { word in
            let s = String(word)
            if s.allSatisfy(\.isNumber) { return s }
            // Preserve all-uppercase words (Roman numerals, acronyms like II, III, ACT)
            if s.count > 1 && s == s.uppercased() && s.allSatisfy(\.isLetter) { return s }
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
