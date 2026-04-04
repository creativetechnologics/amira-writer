import Foundation
import ProjectKit

enum ProjectDatabaseBridge {
    static let animateMetadataPath = "Animate/animate.json"
    static let animateScenesPath = "Animate/scenes.json"
    static let animatePlacesPath = "Animate/places.json"
    static let characterPackageSelectionsPath = "Animate/character-package-selections.json"
    static let shotPresetsPath = "Animate/shot-presets.json"
    static let animate3DRegistryRootPath = "Animate/3d"
    static let animate3DRegistryIndexPath = "Animate/3d/registry-index.json"

    private static let charactersCandidatePaths = ["Characters/characters.json", "characters.json"]

    struct AnimateProjectLoad {
        var workingProjectURL: URL
        var characters: [OPWCharacter]
        var songs: [OWPSongStub]
        var indexFile: OWPIndexFile?
        var instrumentMappings: [OWPInstrumentMapping]
        var animateMetadata: AnimateMetadata?
        var savedScenes: [String: AnimateSceneData]
    }

    static func loadAnimateProject(url: URL) async throws -> AnimateProjectLoad {
        let projectURL = url
        let diskProject = try await OWPProjectLoader().load(from: projectURL)

        return AnimateProjectLoad(
            workingProjectURL: projectURL,
            characters: diskProject.characters,
            songs: diskProject.songs,
            indexFile: diskProject.indexFile,
            instrumentMappings: diskProject.instrumentMappings,
            animateMetadata: loadAnimateMetadataFromDisk(projectURL: projectURL),
            savedScenes: loadSavedScenesFromDisk(projectURL: projectURL)
        )
    }

    static func isCharactersProjectFilePath(_ path: String) -> Bool {
        charactersCandidatePaths.contains(path)
    }

    static func hydrateSongData(projectURL: URL, relativePath: String) async -> OWSSongData? {
        let songURL = projectURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: songURL.path) else {
            return nil
        }
        let loader = OWPProjectLoader()
        return try? await loader.loadSongData(from: songURL)
    }

    private static func loadAnimateMetadataFromDisk(projectURL: URL) -> AnimateMetadata? {
        let fileURL = projectURL.appendingPathComponent(animateMetadataPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let metadata = try? configuredDecoder().decode(AnimateMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    static func loadSavedScenesFromDisk(projectURL: URL) -> [String: AnimateSceneData] {
        let fileURL = projectURL.appendingPathComponent(animateScenesPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }

        let decoder = configuredDecoder()
        if let array = try? decoder.decode([AnimateSceneData].self, from: data) {
            return Dictionary(uniqueKeysWithValues: array.map { ($0.owsSongPath, $0) })
        }

        if let wrapped = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sceneMap = wrapped["scenes"] as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: sceneMap.compactMap { key, value in
                guard let entry = value as? [String: Any],
                      let entryData = try? JSONSerialization.data(withJSONObject: entry),
                      let sceneData = try? decoder.decode(AnimateSceneData.self, from: entryData) else {
                    return nil
                }
                return (sceneData.owsSongPath.isEmpty ? key : sceneData.owsSongPath, sceneData)
            })
        }

        return [:]
    }

    static func loadCharacterPackageSelectionsFromDisk(projectURL: URL) -> CharacterPackageSelectionManifest? {
        let fileURL = projectURL.appendingPathComponent(characterPackageSelectionsPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let manifest = try? configuredDecoder().decode(CharacterPackageSelectionManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    static func loadShotPresetsFromDisk(projectURL: URL) -> SceneShotPresetManifest? {
        let fileURL = projectURL.appendingPathComponent(shotPresetsPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let manifest = try? configuredDecoder().decode(SceneShotPresetManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    // MARK: - 3D Registry (archived — types moved to _archived_3d, excluded from build)
    // These methods are no longer callable; callers in PlacesPageView have been updated.
    // Kept as stubs to preserve method signatures if 3D pipeline is re-enabled later.

    static func loadDrawThingsPlacesConfigFromDisk(projectURL: URL) -> DrawThingsPlaceConfig? {
        let fileURL = projectURL.appendingPathComponent("animate/drawThingsPlacesConfig.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? configuredDecoder().decode(DrawThingsPlaceConfig.self, from: data)
    }

    static func saveDrawThingsPlacesConfigToDisk(_ config: DrawThingsPlaceConfig, projectURL: URL) throws {
        let fileURL = projectURL.appendingPathComponent("animate/drawThingsPlacesConfig.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try configuredEncoder().encode(config)
        try data.write(to: fileURL)
    }

    private static func ensure3DManifest<T: Encodable>(
        _ manifest: T,
        relativePath: String,
        projectURL: URL
    ) {
        let fileURL = projectURL.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try configuredEncoder().encode(manifest)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        } catch {
            print("[ProjectDatabaseBridge] ⚠️ Failed to save manifest: \(error.localizedDescription)")
        }
    }

    private static func load3DManifest<T: Decodable>(
        _ type: T.Type,
        relativePath: String,
        projectURL: URL
    ) -> T? {
        let fileURL = projectURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let manifest = try? configuredDecoder().decode(type, from: data) else {
            return nil
        }
        return manifest
    }

    private static func save3DManifest<T: Encodable>(
        _ manifest: T,
        relativePath: String,
        projectURL: URL
    ) throws {
        let fileURL = projectURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try configuredEncoder().encode(manifest)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func configuredDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func configuredEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
