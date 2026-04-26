import Foundation

struct PlacesScriptLocationRequirement: Codable, Hashable, Sendable {
    var displayName: String
    var normalizedKey: String
    var inferredCategory: String
    var sourceLine: String?
    var isFallback: Bool = false
}

struct PlacesScriptSceneRequirement: Codable, Identifiable, Hashable, Sendable {
    var sceneID: UUID
    var sceneName: String
    var songPath: String
    var locations: [PlacesScriptLocationRequirement]

    var id: UUID { sceneID }
    var primaryLocation: PlacesScriptLocationRequirement? { locations.first }
}

struct PlacesScriptSceneReference: Identifiable, Hashable, Sendable {
    var sceneID: UUID
    var sceneName: String
    var songPath: String

    var id: UUID { sceneID }
}

struct PlacesIndexedEntry: Identifiable, Hashable, Sendable {
    var placeID: UUID
    var displayName: String
    var normalizedKey: String
    var inferredCategory: String
    var sceneReferences: [PlacesScriptSceneReference]
    var sourceLines: [String]

    var id: UUID { placeID }
}

