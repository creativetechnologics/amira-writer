import Foundation

public struct NPProjectFileRecord: Sendable, Hashable, Codable {
    public var path: String
    public var jsonData: Data

    public init(path: String, jsonData: Data) {
        self.path = path
        self.jsonData = jsonData
    }
}

public struct NPCharacterRecord: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var jsonData: Data
    public var updatedAt: Date

    public init(id: UUID, name: String, jsonData: Data, updatedAt: Date) {
        self.id = id
        self.name = name
        self.jsonData = jsonData
        self.updatedAt = updatedAt
    }
}

public struct NPSceneVersionRecord: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var sortIndex: Int
    public var label: String
    public var saveType: String
    public var userLabel: String?
    public var isBookmarked: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lyrics: String
    public var versionJSON: Data?
    public var playbackJSON: Data?
    public var noteCount: Int
    public var lengthTicks: Int

    public init(
        id: UUID,
        sortIndex: Int,
        label: String,
        saveType: String,
        userLabel: String?,
        isBookmarked: Bool,
        createdAt: Date,
        updatedAt: Date,
        lyrics: String,
        versionJSON: Data?,
        playbackJSON: Data?,
        noteCount: Int,
        lengthTicks: Int
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.label = label
        self.saveType = saveType
        self.userLabel = userLabel
        self.isBookmarked = isBookmarked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lyrics = lyrics
        self.versionJSON = versionJSON
        self.playbackJSON = playbackJSON
        self.noteCount = noteCount
        self.lengthTicks = lengthTicks
    }
}

public struct NPSceneRecord: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var songID: UUID
    public var relativePath: String
    public var title: String
    public var canonicalTitle: String
    public var notes: String
    public var updatedAt: Date
    public var activeVersionID: UUID?
    public var orderIndex: Int
    public var rootJSON: Data?
    public var animateSceneJSON: Data?
    public var animateTrackCount: Int
    public var animateKeyframeCount: Int
    public var versions: [NPSceneVersionRecord]

    public init(
        id: UUID,
        songID: UUID,
        relativePath: String,
        title: String,
        canonicalTitle: String,
        notes: String,
        updatedAt: Date,
        activeVersionID: UUID?,
        orderIndex: Int,
        rootJSON: Data?,
        animateSceneJSON: Data?,
        animateTrackCount: Int,
        animateKeyframeCount: Int,
        versions: [NPSceneVersionRecord]
    ) {
        self.id = id
        self.songID = songID
        self.relativePath = relativePath
        self.title = title
        self.canonicalTitle = canonicalTitle
        self.notes = notes
        self.updatedAt = updatedAt
        self.activeVersionID = activeVersionID
        self.orderIndex = orderIndex
        self.rootJSON = rootJSON
        self.animateSceneJSON = animateSceneJSON
        self.animateTrackCount = animateTrackCount
        self.animateKeyframeCount = animateKeyframeCount
        self.versions = versions
    }

    public var activeVersion: NPSceneVersionRecord? {
        if let activeVersionID, let match = versions.first(where: { $0.id == activeVersionID }) {
            return match
        }
        return versions.max(by: { $0.updatedAt < $1.updatedAt })
    }
}

public struct NPProjectRecord: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var projectURL: URL
    public var projectFiles: [NPProjectFileRecord]
    public var characters: [NPCharacterRecord]
    public var scenes: [NPSceneRecord]

    public init(
        id: UUID,
        name: String,
        notes: String,
        createdAt: Date,
        updatedAt: Date,
        projectURL: URL,
        projectFiles: [NPProjectFileRecord],
        characters: [NPCharacterRecord],
        scenes: [NPSceneRecord]
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectURL = projectURL
        self.projectFiles = projectFiles
        self.characters = characters
        self.scenes = scenes
    }

    public func projectFile(at path: String) -> NPProjectFileRecord? {
        projectFiles.first(where: { $0.path == path })
    }
}

public struct NPSceneSummary: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var relativePath: String
    public var title: String
    public var orderIndex: Int
    public var updatedAt: Date
    public var activeVersionID: UUID?
    public var activeLyrics: String
    public var noteCount: Int
    public var lengthTicks: Int
    public var animateTrackCount: Int
    public var animateKeyframeCount: Int

    public init(
        id: UUID,
        relativePath: String,
        title: String,
        orderIndex: Int,
        updatedAt: Date,
        activeVersionID: UUID?,
        activeLyrics: String,
        noteCount: Int,
        lengthTicks: Int,
        animateTrackCount: Int,
        animateKeyframeCount: Int
    ) {
        self.id = id
        self.relativePath = relativePath
        self.title = title
        self.orderIndex = orderIndex
        self.updatedAt = updatedAt
        self.activeVersionID = activeVersionID
        self.activeLyrics = activeLyrics
        self.noteCount = noteCount
        self.lengthTicks = lengthTicks
        self.animateTrackCount = animateTrackCount
        self.animateKeyframeCount = animateKeyframeCount
    }
}

public struct NPProjectSummary: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var projectURL: URL
    public var scenes: [NPSceneSummary]

    public init(
        id: UUID,
        name: String,
        notes: String,
        createdAt: Date,
        updatedAt: Date,
        projectURL: URL,
        scenes: [NPSceneSummary]
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectURL = projectURL
        self.scenes = scenes
    }
}
