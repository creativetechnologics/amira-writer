import Foundation
import ProjectKit

enum ProjectDatabaseBridge {
    static let animateMetadataPath = "Animate/animate.json"
    /// Wave D: moved from Animate/scenes.json to Scenes/scenes.json.
    static let animateScenesPath = "Scenes/scenes.json"
    /// Wave D: moved from Animate/places.json to Places/places.json.
    static let animatePlacesPath = "Places/places.json"
    /// Wave D: moved from Animate/places-workflow.json to Places/places-workflow.json.
    static let animatePlacesWorkflowPath = "Places/places-workflow.json"
    static let characterPackageSelectionsPath = "Animate/character-package-selections.json"
    static let shotPresetsPath = "Animate/shot-presets.json"
    static let animatedLookPromptPath = "Settings/animated-look-prompt.json"
    /// Wave D: archived — Animate/3d/ moved to _Archive/Animate-3d/.
    static let animate3DRegistryRootPath = "_Archive/Animate-3d"
    static let animate3DRegistryIndexPath = "_Archive/Animate-3d/registry-index.json"

    private static let charactersCandidatePaths = ["Characters/characters.json", "characters.json"]
    private static let sceneAnimationFileName = "animation.json"

    struct AnimateProjectLoad: Sendable {
        var workingProjectURL: URL
        var characters: [OPWCharacter]
        var songs: [OWPSongStub]
        var indexFile: OWPIndexFile?
        var instrumentMappings: [OWPInstrumentMapping]
        var animateMetadata: AnimateMetadata?
        var savedScenes: [String: AnimateSceneData]
    }

    static func loadAnimateProject(url: URL) async throws -> AnimateProjectLoad {
        try await Task.detached(priority: .utility) { @Sendable in
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
        }.value
    }

    static func isCharactersProjectFilePath(_ path: String) -> Bool {
        charactersCandidatePaths.contains(path)
    }

    static func hydrateSongData(projectURL: URL, relativePath: String) async -> OWSSongData? {
        let songURL = projectURL.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: songURL.path) {
            return try? await Task.detached(priority: .utility) { @Sendable in
                try await OWPProjectLoader().loadSongData(from: songURL)
            }.value
        }

        guard let sceneJSONURL = ScenePackageStore.sceneJSONURL(forProjectRelativePath: relativePath, in: projectURL),
              let data = try? ScenePackageStore.makeWorkspaceSceneDocumentData(sceneJSONURL: sceneJSONURL) else {
            return nil
        }
        return try? await Task.detached(priority: .utility) { @Sendable in
            try await OWPProjectLoader().loadSongData(from: data, displayName: relativePath)
        }.value
    }

    private static func loadAnimateMetadataFromDisk(projectURL: URL) -> AnimateMetadata? {
        let fileURL = projectURL.appendingPathComponent(animateMetadataPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let metadata = try? JSONCoders.makeDecoder().decode(AnimateMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    nonisolated(unsafe) private static let debugLogFormatter: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private static func debugLog(_ message: String) {
        NSLog("%@", message)
        #if DEBUG
        let line = "[\(debugLogFormatter.string(from: Date()))] \(message)\n"
        let logURL = URL(fileURLWithPath: "/tmp/animate-debug.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
        #endif
    }

    static func loadSavedScenesFromDisk(projectURL: URL) -> [String: AnimateSceneData] {
        loadSavedScenesFromScenePackages(projectURL: projectURL)
    }

    private static func loadSavedScenesFromScenePackages(projectURL: URL) -> [String: AnimateSceneData] {
        var result: [String: AnimateSceneData] = [:]
        for descriptor in ScenePackageStore.discover(in: projectURL) {
            let activeVersionDirectory = ScenePackageStore.activeVersionDirectory(sceneJSONURL: descriptor.sceneJSONURL)
            let shots = activeVersionDirectory.map(loadScenePackageShots(in:)) ?? []
            var sceneData = loadScenePackageAnimationData(
                in: descriptor.sceneDirectoryURL,
                fallbackPath: descriptor.projectRelativePath
            ) ?? AnimateSceneData(
                owsSongPath: descriptor.projectRelativePath,
                backgroundID: nil,
                characterIDs: [],
                keyframes: [],
                tracks: [:],
                shots: shots
            )
            sceneData.owsSongPath = descriptor.projectRelativePath
            if !shots.isEmpty {
                sceneData.shots = shots
            }
            result[descriptor.projectRelativePath] = sceneData
        }
        if !result.isEmpty {
            debugLog("[Animate] loadSavedScenes: recovered \(result.count) canonical scene packages, total shots=\(result.values.reduce(0) { $0 + $1.shots.count })")
        }
        return result
    }

    private static func loadScenePackageAnimationData(
        in sceneDirectoryURL: URL,
        fallbackPath: String
    ) -> AnimateSceneData? {
        let fileURL = sceneDirectoryURL.appendingPathComponent(sceneAnimationFileName)
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode(AnimateSceneData.self, from: data) else {
            return nil
        }
        decoded.owsSongPath = decoded.owsSongPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackPath
            : decoded.owsSongPath
        return decoded
    }

    private static func loadScenePackageShots(in versionDirectoryURL: URL) -> [AnimationSceneShot] {
        let fileURL = versionDirectoryURL.appendingPathComponent("shots.json")
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawShots = root["shots"] as? [[String: Any]] else {
            return []
        }
        return rawShots.enumerated().map { index, raw in
            let camera = raw["camera"] as? [String: Any]
            let timing = raw["timing"] as? [String: Any]
            let legacy = raw["legacy"] as? [String: Any]
            let lyricAnchor = legacy?["lyricAnchor"] as? [String: Any]
            let startFrame = int(timing?["startFrame"]) ?? (index * 120)
            let endFrame = int(timing?["endFrame"]) ?? max(startFrame, ((index + 1) * 120) - 1)
            let name = string(raw["name"])
                ?? string(raw["label"])
                ?? string(camera?["label"])
                ?? "Shot \(index + 1)"
            let notes = string(raw["notes"])
                ?? string(camera?["notes"])
                ?? string(raw["direction"])
                ?? string(raw["action"])
                ?? ""
            let cameraShot = string(camera?["shotSize"])
                .flatMap(CameraShot.init(rawValue:))
                ?? string(camera?["toShotSize"]).flatMap(CameraShot.init(rawValue:))
                ?? string(camera?["fromShotSize"]).flatMap(CameraShot.init(rawValue:))
            let intent = string(camera?["intent"])
                .flatMap(ShotIntent.init(rawValue:))
                ?? string(raw["shotIntent"]).flatMap(ShotIntent.init(rawValue:))
            return AnimationSceneShot(
                id: uuid(raw["id"]) ?? UUID(),
                name: name,
                startFrame: startFrame,
                endFrame: endFrame,
                cameraShot: cameraShot,
                shotIntent: intent,
                notes: notes,
                source: .scriptSync,
                lockedBoundaries: false,
                sourceDirectionTags: [],
                sourceLineNumber: int(lyricAnchor?["startLine"]),
                sourceLyricExcerpt: string(lyricAnchor?["excerpt"])
            )
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as UUID:
            return value.uuidString
        default:
            return nil
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let raw = string(value) else { return nil }
        return UUID(uuidString: raw)
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    static func loadCharacterPackageSelectionsFromDisk(projectURL: URL) -> CharacterPackageSelectionManifest? {
        let fileURL = projectURL.appendingPathComponent(characterPackageSelectionsPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let manifest = try? JSONCoders.makeDecoder().decode(CharacterPackageSelectionManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    static func loadShotPresetsFromDisk(projectURL: URL) -> SceneShotPresetManifest? {
        let fileURL = projectURL.appendingPathComponent(shotPresetsPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let manifest = try? JSONCoders.makeDecoder().decode(SceneShotPresetManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    static func loadAnimatedLookPromptFromDisk(projectURL: URL) -> String? {
        struct Payload: Codable {
            var prompt: String
        }

        let fileURL = ProjectPaths(root: projectURL).animatedLookPromptJSON
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONCoders.makeDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let trimmed = payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveAnimatedLookPromptToDisk(_ prompt: String, projectURL: URL) throws {
        struct Payload: Codable {
            var prompt: String
        }

        let fileURL = ProjectPaths(root: projectURL).animatedLookPromptJSON
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONCoders.makeEncoder().encode(Payload(prompt: trimmed))
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
            let data = try JSONCoders.makeEncoder().encode(manifest)
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
              let manifest = try? JSONCoders.makeDecoder().decode(type, from: data) else {
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
        let data = try JSONCoders.makeEncoder().encode(manifest)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Gemini Master Switch

    static func saveGeminiMasterSwitch(_ enabled: Bool, projectURL: URL) throws {
        let url = ProjectPaths(root: projectURL).animateGeminiSwitchJSON
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(["enabled": enabled])
        try data.write(to: url, options: .atomic)
    }

    static func loadGeminiMasterSwitch(projectURL: URL) -> Bool? {
        let url = ProjectPaths(root: projectURL).animateGeminiSwitchJSON
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return nil }
        return dict["enabled"]
    }
}
