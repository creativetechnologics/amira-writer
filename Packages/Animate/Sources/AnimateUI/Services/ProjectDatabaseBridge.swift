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

        guard let sceneJSONURL = ScenePackageReader.sceneJSONURL(forLegacySongPath: relativePath, in: projectURL),
              let data = try? ScenePackageReader.makeLegacyOWSData(sceneJSONURL: sceneJSONURL) else {
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
        let fileURL = projectURL.appendingPathComponent(animateScenesPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            debugLog("[Animate] loadSavedScenes: \(animateScenesPath) not found")
            return loadSavedScenesFromScenePackages(projectURL: projectURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            debugLog("[Animate] loadSavedScenes: failed to read file: \(error.localizedDescription)")
            return [:]
        }

        debugLog("[Animate] loadSavedScenes: read \(data.count) bytes from \(animateScenesPath)")

        let decoder = JSONCoders.makeDecoder()

        // Try full-array decode first
        do {
            let array = try decoder.decode([AnimateSceneData].self, from: data)
            debugLog("[Animate] loadSavedScenes: decoded \(array.count) scenes (full array), total shots=\(array.reduce(0) { $0 + $1.shots.count })")
            let result = Dictionary(uniqueKeysWithValues: array.map { ($0.owsSongPath, $0) })
            if result.isEmpty {
                let fallback = loadSavedScenesFromScenePackages(projectURL: projectURL)
                if !fallback.isEmpty {
                    debugLog("[Animate] loadSavedScenes: \(animateScenesPath) is empty; recovered \(fallback.count) scenes from scene packages")
                    return fallback
                }
            }
            for check in ["Songs/1.36.0 - The Window.ows", "Songs/1.15.0 - Scene - After The Incident.ows", "Songs/2.14.0 - Ancient Waters.ows"] {
                if let s = result[check] {
                    debugLog("[Animate] loadSavedScenes:   \(check) = \(s.shots.count) shots")
                }
            }
            return result
        } catch {
            debugLog("[Animate] loadSavedScenes: full-array decode FAILED: \(error)")
        }

        // Full-array decode failed — try per-scene decode to salvage what we can
        debugLog("[Animate] loadSavedScenes: falling back to per-scene decode")
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            debugLog("[Animate] loadSavedScenes: not a JSON array, trying dict wrapper")
            if let wrapped = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sceneMap = wrapped["scenes"] as? [String: Any] {
                let pairs: [(String, AnimateSceneData)] = sceneMap.compactMap { key, value in
                    guard let entry = value as? [String: Any],
                          let entryData = try? JSONSerialization.data(withJSONObject: entry),
                          let sceneData = try? decoder.decode(AnimateSceneData.self, from: entryData) else {
                        return nil
                    }
                    return (sceneData.owsSongPath.isEmpty ? key : sceneData.owsSongPath, sceneData)
                }
                let result = Dictionary(uniqueKeysWithValues: pairs)
                if result.isEmpty {
                    return loadSavedScenesFromScenePackages(projectURL: projectURL)
                }
                return result
            }
            return loadSavedScenesFromScenePackages(projectURL: projectURL)
        }

        // Decode each scene individually — one bad scene won't kill the rest
        var result: [String: AnimateSceneData] = [:]
        for (i, sceneDict) in rawArray.enumerated() {
            let path = sceneDict["owsSongPath"] as? String ?? "idx_\(i)"
            do {
                let sceneData = try JSONSerialization.data(withJSONObject: sceneDict)
                let scene = try decoder.decode(AnimateSceneData.self, from: sceneData)
                result[scene.owsSongPath] = scene
            } catch {
                debugLog("[Animate] loadSavedScenes: scene \(i) (\(path)) decode FAILED: \(error)")
            }
        }

        debugLog("[Animate] loadSavedScenes: per-scene fallback decoded \(result.count)/\(rawArray.count) scenes, total shots=\(result.values.reduce(0) { $0 + $1.shots.count })")
        if result.isEmpty {
            let fallback = loadSavedScenesFromScenePackages(projectURL: projectURL)
            if !fallback.isEmpty {
                debugLog("[Animate] loadSavedScenes: recovered \(fallback.count) scenes from scene packages after empty per-scene fallback")
                return fallback
            }
        }
        return result
    }

    private static func loadSavedScenesFromScenePackages(projectURL: URL) -> [String: AnimateSceneData] {
        var result: [String: AnimateSceneData] = [:]
        for descriptor in ScenePackageReader.discover(in: projectURL) {
            let activeVersionDirectory = ScenePackageReader.activeVersionDirectory(sceneJSONURL: descriptor.sceneJSONURL)
            let shots = activeVersionDirectory.map(loadScenePackageShots(in:)) ?? []
            result[descriptor.legacySongPath] = AnimateSceneData(
                owsSongPath: descriptor.legacySongPath,
                backgroundID: nil,
                characterIDs: [],
                keyframes: [],
                tracks: [:],
                shots: shots
            )
        }
        if !result.isEmpty {
            debugLog("[Animate] loadSavedScenes: recovered \(result.count) canonical scene packages, total shots=\(result.values.reduce(0) { $0 + $1.shots.count })")
        }
        return result
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
