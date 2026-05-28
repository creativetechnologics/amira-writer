import Foundation

// MARK: - Scene Index Entry

public struct SceneIndexEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var order: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: UUID,
        title: String,
        order: Int,
        createdAt: String = AmiraDateFormatter.iso8601.string(from: Date()),
        updatedAt: String = AmiraDateFormatter.iso8601.string(from: Date())
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Scene Index Root

private struct SceneIndexRoot: Codable {
    let schemaVersion: Int
    var scenes: [SceneIndexEntry]

    static let currentSchemaVersion = 1
}

// MARK: - SceneIndexStore

public enum SceneIndexStore {
    public static let fileName = "scene-index.json"

    /// `<project>/scene-index.json`
    public static func url(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(fileName)
    }

    /// Read the scene index from disk. Returns empty array if file doesn't exist.
    public static func load(from projectURL: URL) throws -> [SceneIndexEntry] {
        let url = self.url(in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode(SceneIndexRoot.self, from: data)
        return root.scenes
    }

    /// Write the scene index to disk.
    public static func save(_ scenes: [SceneIndexEntry], to projectURL: URL) throws {
        let root = SceneIndexRoot(
            schemaVersion: SceneIndexRoot.currentSchemaVersion,
            scenes: scenes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(root)
        try data.write(to: url(in: projectURL), options: .atomic)
    }

    /// Look up a scene by ID.
    public static func scene(with id: UUID, in scenes: [SceneIndexEntry]) -> SceneIndexEntry? {
        scenes.first { $0.id == id }
    }

    /// Update a scene entry in the array (replaces by ID).
    public static func updating(
        _ entry: SceneIndexEntry,
        in scenes: [SceneIndexEntry]
    ) -> [SceneIndexEntry] {
        scenes.map { $0.id == entry.id ? entry : $0 }
    }

    /// Remove a scene entry by ID.
    public static func removing(id: UUID, from scenes: [SceneIndexEntry]) -> [SceneIndexEntry] {
        scenes.filter { $0.id != id }
    }
}
