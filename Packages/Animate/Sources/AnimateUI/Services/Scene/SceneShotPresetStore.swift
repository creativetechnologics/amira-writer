import Foundation

struct SceneShotPresetManifest: Codable, Sendable {
    var schemaVersion: Int
    var presets: [SceneShotPreset]

    init(
        schemaVersion: Int = 1,
        presets: [SceneShotPreset] = []
    ) {
        self.schemaVersion = schemaVersion
        self.presets = presets
    }
}

struct SceneShotPresetStore: Sendable {
    private static let presetsFilename = "shot-presets.json"

    func load(from animateURL: URL) -> SceneShotPresetManifest {
        let fileURL = presetsURL(in: animateURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SceneShotPresetManifest()
        }

        guard let data = try? Data(contentsOf: fileURL),
              let manifest = try? JSONDecoder().decode(SceneShotPresetManifest.self, from: data) else {
            return SceneShotPresetManifest()
        }

        return manifest
    }

    func save(_ manifest: SceneShotPresetManifest, to animateURL: URL) throws {
        let fileURL = presetsURL(in: animateURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: fileURL)
    }

    func presetsURL(in animateURL: URL) -> URL {
        animateURL.appendingPathComponent(Self.presetsFilename)
    }
}
