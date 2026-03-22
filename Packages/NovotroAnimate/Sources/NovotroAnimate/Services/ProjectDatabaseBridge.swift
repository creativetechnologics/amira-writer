import Foundation
import NovotroProjectKit

enum ProjectDatabaseBridge {
    static let animateActorID = NovotroProjectClientIdentity.actorID(for: "novotro-animate")
    static let animateMetadataPath = "Animate/animate.json"
    static let animateScenesPath = "Animate/scenes.json"
    static let characterPackageSelectionsPath = "Animate/character-package-selections.json"
    static let shotPresetsPath = "Animate/shot-presets.json"

    private static let indexCandidatePaths = ["index.json"]
    private static let charactersCandidatePaths = ["Characters/characters.json", "characters.json"]

    struct AnimateProjectLoad {
        var database: NovotroProjectConnection
        var workingProjectURL: URL
        var characters: [OPWCharacter]
        var songs: [OWPSongStub]
        var indexFile: OWPIndexFile?
        var instrumentMappings: [OWPInstrumentMapping]
        var animateMetadata: AnimateMetadata?
        var savedScenes: [String: AnimateSceneData]
    }

    static func loadAnimateProject(url: URL, preferService: Bool? = nil) async throws -> AnimateProjectLoad {
        let database = try await NovotroProjectConnection.open(projectURL: url, preferService: preferService)
        let workingProjectURL = database.workingProjectURL
        let diskProject = try await OWPProjectLoader().load(from: workingProjectURL)
        if let scenePayloads = try? await database.loadProjectScenes(
            includeVersions: false,
            includeRootJSON: false,
            includeAnimateSceneJSON: true,
            includeVersionJSON: false,
            includePlaybackJSON: false
        ) {
            let decoder = configuredDecoder()
            let scenePayloadsByPath = Dictionary(uniqueKeysWithValues: scenePayloads.map { ($0.relativePath, $0) })
            let characters = (try? await loadCharacters(database: database)) ?? diskProject.characters
            let songs = diskProject.songs.map { stub in
                guard let scene = scenePayloadsByPath[stub.owsPath] else { return stub }
                return OWPSongStub(
                    id: scene.id,
                    title: scene.title,
                    owsPath: stub.owsPath,
                    durationTicks: stub.durationTicks
                )
            }
            let indexFile = try await loadIndexFile(database: database) ?? diskProject.indexFile
            let animateMetadata = try await loadAnimateMetadata(database: database)
            let savedScenes: [String: AnimateSceneData] = Dictionary(
                uniqueKeysWithValues: scenePayloads.compactMap { scene in
                    guard let data = scene.animateSceneJSON,
                          let decoded = try? decoder.decode(AnimateSceneData.self, from: data) else {
                        return nil
                    }
                    return (scene.relativePath, decoded)
                }
            )

            return AnimateProjectLoad(
                database: database,
                workingProjectURL: workingProjectURL,
                characters: characters,
                songs: songs,
                indexFile: indexFile,
                instrumentMappings: indexFile?.instrumentMappings ?? diskProject.instrumentMappings,
                animateMetadata: animateMetadata ?? loadAnimateMetadataFromDisk(projectURL: workingProjectURL),
                savedScenes: savedScenes
            )
        }

        return AnimateProjectLoad(
            database: database,
            workingProjectURL: workingProjectURL,
            characters: diskProject.characters,
            songs: diskProject.songs,
            indexFile: diskProject.indexFile,
            instrumentMappings: diskProject.instrumentMappings,
            animateMetadata: loadAnimateMetadataFromDisk(projectURL: workingProjectURL),
            savedScenes: loadSavedScenesFromDisk(projectURL: workingProjectURL)
        )
    }

    static func currentChangeToken(database: NovotroProjectConnection?) async throws -> Int64 {
        guard let database else { return 0 }
        return try await database.currentChangeToken()
    }

    static func listChanges(database: NovotroProjectConnection?, since changeID: Int64) async throws -> [ChangeEvent] {
        guard let database else { return [] }
        return try await database.listChanges(since: changeID)
    }

    static func isCharactersProjectFilePath(_ path: String) -> Bool {
        charactersCandidatePaths.contains(path)
    }

    static func isIndexProjectFilePath(_ path: String) -> Bool {
        indexCandidatePaths.contains(path)
    }

    static func loadAnimateSceneData(
        database: NovotroProjectConnection?,
        relativePath: String
    ) async throws -> (sceneData: AnimateSceneData?, title: String?)? {
        guard let database,
              let scene = try await database.loadScene(relativePath: relativePath) else {
            return nil
        }

        let decoder = configuredDecoder()
        let decoded = scene.animateSceneJSON.flatMap { try? decoder.decode(AnimateSceneData.self, from: $0) }
        return (decoded, scene.title)
    }

    static func loadAnimateMetadata(database: NovotroProjectConnection?) async throws -> AnimateMetadata? {
        guard let database,
              let file = try await loadProjectFile(database: database, candidatePaths: [animateMetadataPath]) else {
            return nil
        }
        return try? configuredDecoder().decode(AnimateMetadata.self, from: file.jsonData)
    }

    static func loadCharacters(database: NovotroProjectConnection?) async throws -> [OPWCharacter]? {
        guard let database,
              let file = try await loadProjectFile(database: database, candidatePaths: charactersCandidatePaths) else {
            return nil
        }

        return decodeCharacters(from: file.jsonData, decoder: configuredDecoder())
    }

    static func loadIndexFile(database: NovotroProjectConnection?) async throws -> OWPIndexFile? {
        guard let database,
              let file = try await loadProjectFile(database: database, candidatePaths: indexCandidatePaths) else {
            return nil
        }

        return try? configuredDecoder().decode(OWPIndexFile.self, from: file.jsonData)
    }

    static func loadCharacterPackageSelections(
        database: NovotroProjectConnection?
    ) async throws -> CharacterPackageSelectionManifest? {
        guard let database,
              let file = try await loadProjectFile(database: database, candidatePaths: [characterPackageSelectionsPath]) else {
            return nil
        }

        return try? configuredDecoder().decode(CharacterPackageSelectionManifest.self, from: file.jsonData)
    }

    static func loadShotPresets(database: NovotroProjectConnection?) async throws -> SceneShotPresetManifest? {
        guard let database,
              let file = try await loadProjectFile(database: database, candidatePaths: [shotPresetsPath]) else {
            return nil
        }

        return try? configuredDecoder().decode(SceneShotPresetManifest.self, from: file.jsonData)
    }

    static func upsertAnimateMetadata(database: NovotroProjectConnection?, metadata: AnimateMetadata) async throws {
        guard let database else { return }
        let data = try configuredEncoder().encode(metadata)
        try await database.upsertProjectFile(
            path: animateMetadataPath,
            jsonData: data,
            actorID: animateActorID
        )
    }

    static func upsertAnimationScene(
        database: NovotroProjectConnection?,
        sceneData: AnimateSceneData,
        relativePath: String
    ) async throws {
        guard let database else { return }
        let data = try configuredEncoder().encode(sceneData)
        try await database.upsertAnimationScene(
            owsPath: relativePath,
            jsonData: data,
            actorID: animateActorID
        )
    }

    static func upsertAnimateScenesManifest(
        database: NovotroProjectConnection?,
        sceneData: [AnimateSceneData]
    ) async throws {
        guard let database else { return }
        let data = try configuredEncoder().encode(sceneData)
        try await database.upsertProjectFile(
            path: animateScenesPath,
            jsonData: data,
            actorID: animateActorID
        )
    }

    static func upsertCharacterPackageSelections(
        database: NovotroProjectConnection?,
        manifest: CharacterPackageSelectionManifest
    ) async throws {
        guard let database else { return }
        let data = try configuredEncoder().encode(manifest)
        try await database.upsertProjectFile(
            path: characterPackageSelectionsPath,
            jsonData: data,
            actorID: animateActorID
        )
    }

    static func upsertShotPresets(
        database: NovotroProjectConnection?,
        manifest: SceneShotPresetManifest
    ) async throws {
        guard let database else { return }
        let data = try configuredEncoder().encode(manifest)
        try await database.upsertProjectFile(
            path: shotPresetsPath,
            jsonData: data,
            actorID: animateActorID
        )
    }

    static func hydrateSongData(projectURL: URL, relativePath: String) async -> OWSSongData? {
        guard let database = try? await NovotroProjectConnection.open(projectURL: projectURL) else {
            return nil
        }
        return await hydrateSongData(database: database, projectURL: projectURL, relativePath: relativePath)
    }

    static func hydrateSongData(
        database: NovotroProjectConnection?,
        projectURL: URL,
        relativePath: String
    ) async -> OWSSongData? {
        let scene: NPSceneRecord?
        if let database, let loaded = try? await database.loadScene(relativePath: relativePath) {
            scene = loaded
        } else {
            guard let reopened = try? await NovotroProjectConnection.open(projectURL: projectURL),
                  (try? await reopened.ensureCurrentIndex()) != nil,
                  let loaded = try? await reopened.loadScene(relativePath: relativePath) else {
                return nil
            }
            scene = loaded
        }

        guard let scene, let version = scene.activeVersion else {
            return nil
        }

        var songData = OWSSongData()
        songData.title = scene.title
        songData.lyricsText = version.lyrics

        if let playbackJSON = version.playbackJSON,
           let playbackRoot = try? JSONSerialization.jsonObject(with: playbackJSON) as? [String: Any] {
            songData.ticksPerQuarter = playbackRoot["ticksPerQuarter"] as? Int ?? 480
            songData.lengthTicks = playbackRoot["lengthTicks"] as? Int ?? 0

            if let tempoData = try? JSONSerialization.data(withJSONObject: playbackRoot["tempoEvents"] ?? []),
               let tempoEvents = try? configuredDecoder().decode([OWPTempoPoint].self, from: tempoData) {
                songData.tempoEvents = tempoEvents
            }

            if let notesData = try? JSONSerialization.data(withJSONObject: playbackRoot["notes"] ?? []),
               let notes = try? configuredDecoder().decode([OWPNote].self, from: notesData) {
                songData.notes = notes
            }

            if let trackNamesRaw = playbackRoot["trackNames"] as? [String: String] {
                for (key, value) in trackNamesRaw where Int(key) != nil {
                    songData.trackNames[Int(key)!] = value
                }
            }

            if let alignData = try? JSONSerialization.data(withJSONObject: playbackRoot["lyricAlignments"] ?? []),
               let alignments = try? configuredDecoder().decode([OWPLyricAlignment].self, from: alignData) {
                songData.lyricAlignments = alignments
            }
        }

        return songData
    }

    static func resync(projectURL: URL) async {
        guard let database = try? await NovotroProjectConnection.open(projectURL: projectURL) else {
            return
        }
        try? await database.ensureCurrentIndex(forceRebuild: true)
    }

    private static func decodeCharacters(from data: Data, decoder: JSONDecoder) -> [OPWCharacter]? {
        if let file = try? decoder.decode(OPWCharactersFile.self, from: data) {
            return file.characters
        }

        if let characters = try? decoder.decode([OPWCharacter].self, from: data) {
            return characters
        }

        return nil
    }

    private static func loadProjectFile(
        database: NovotroProjectConnection,
        candidatePaths: [String]
    ) async throws -> NPProjectFileRecord? {
        for path in candidatePaths {
            if let file = try await database.loadProjectFile(path: path) {
                return file
            }
        }

        return nil
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
