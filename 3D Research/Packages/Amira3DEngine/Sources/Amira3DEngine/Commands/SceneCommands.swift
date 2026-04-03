import Foundation

public enum SceneCommandFamily: String, Codable, Hashable, Sendable {
    case world
    case asset
    case character
    case face
    case expression
    case mouth
    case camera
    case style
    case light
    case atmosphere
    case dialogue
}

public struct CommandTiming: Hashable, Codable, Sendable {
    public var shotID: ShotID?
    public var startSeconds: Double?
    public var durationSeconds: Double?
    public var frameOffset: Int?

    public init(
        shotID: ShotID? = nil,
        startSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        frameOffset: Int? = nil
    ) {
        self.shotID = shotID
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.frameOffset = frameOffset
    }
}

public struct SceneCommand: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var family: SceneCommandFamily
    public var target: String
    public var action: String
    public var timing: CommandTiming?
    public var parameters: [String: JSONValue]
    public var notes: String?

    public init(
        id: String,
        family: SceneCommandFamily,
        target: String,
        action: String,
        timing: CommandTiming? = nil,
        parameters: [String: JSONValue] = [:],
        notes: String? = nil
    ) {
        self.id = id
        self.family = family
        self.target = target
        self.action = action
        self.timing = timing
        self.parameters = parameters
        self.notes = notes
    }
}
