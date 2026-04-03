import Foundation

public struct ScenePlan: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var project: String
    public var sceneID: SceneID
    public var source: String?
    public var commands: [SceneCommand]

    public init(
        schemaVersion: String = "0.1",
        project: String = "Amira",
        sceneID: SceneID,
        source: String? = nil,
        commands: [SceneCommand]
    ) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.sceneID = sceneID
        self.source = source
        self.commands = commands
    }
}
