import Foundation

struct PlacesScriptLocationRequirement: Hashable, Sendable {
    var displayName: String
    var normalizedKey: String
    var inferredCategory: String
    var sourceLine: String?
    var isFallback: Bool = false
}

struct PlacesScriptSceneRequirement: Identifiable, Hashable, Sendable {
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

@available(macOS 26.0, *)
struct DrawThingsResolutionPreset: Codable, Sendable, Hashable {
    let name: String
    let width: Int
    let height: Int
    static let presets: [DrawThingsResolutionPreset] = [
        .init(name: "1536×864 (16:9 HQ)", width: 1536, height: 864),
        .init(name: "1920×1080 (Full HD)", width: 1920, height: 1080),
        .init(name: "1024×576 (16:9 Fast)", width: 1024, height: 576),
    ]
}

struct DrawThingsPlaceConfig: Codable, Hashable, Sendable {
    var apiHost: String
    var apiPort: Int
    var imageWidth: Int
    var imageHeight: Int
    var steps: Int
    var cfgScale: Double
    var seed: Int?
    var negativePrompt: String
    var promptPrefix: String
    var promptSuffix: String

    init(
        apiHost: String = "http://127.0.0.1",
        apiPort: Int = 7860,
        imageWidth: Int = 1536,
        imageHeight: Int = 864,
        steps: Int = 28,
        cfgScale: Double = 7.5,
        seed: Int? = nil,
        negativePrompt: String = "",
        promptPrefix: String = "",
        promptSuffix: String = ""
    ) {
        self.apiHost = apiHost
        self.apiPort = apiPort
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.steps = steps
        self.cfgScale = cfgScale
        self.seed = seed
        self.negativePrompt = negativePrompt
        self.promptPrefix = promptPrefix
        self.promptSuffix = promptSuffix
    }
}
