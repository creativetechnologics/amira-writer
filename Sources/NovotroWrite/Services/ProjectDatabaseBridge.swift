import Foundation
import NovotroProjectKit

@available(macOS 26.0, *)
enum ProjectDatabaseBridge {
    static let writeActorID = NovotroProjectClientIdentity.actorID(for: "novotro-write")
    static let metadataPaths = ["Metadata/project.json", "project.json"]
    static let charactersPaths = ["Characters/characters.json", "characters.json"]
    static let synopsisPath = "Synopsis/synopsis.txt"
    static let scratchpadPath = "Write/libretto-scratchpad.txt"

    static func loadWriterProject(url: URL, preferService: Bool? = nil) async throws -> ProjectLoadResult {
        let database = try await NovotroProjectConnection.open(projectURL: url, preferService: preferService)
        let workingProjectURL = database.workingProjectURL
        let phase1 = try await OWPProjectIO.loadPhase1(from: workingProjectURL)
        if let summary = try? await database.loadProjectSummary() {
            let metadata = try await loadMetadata(from: database, projectURL: workingProjectURL)
            let characters = (try? await loadCharacters(from: database)) ?? []
            let summaryByPath = Dictionary(uniqueKeysWithValues: summary.scenes.map { ($0.relativePath, $0) })
            let stubs = mergedStubs(diskStubs: phase1.stubs, summaryByPath: summaryByPath)
            let assets = stubs.map { stub in
                if let scene = summaryByPath[stub.relativePath] {
                    return OWSSongAsset(relativePath: scene.relativePath, document: makeLightweightDocument(from: scene))
                }
                return OWSSongAsset(relativePath: stub.relativePath, document: makePlaceholderDocument(from: stub))
            }
            let librettoFiles = stubs.map { stub in
                ProjectTextFile(
                    id: UUID(),
                    relativePath: stub.relativePath,
                    content: summaryByPath[stub.relativePath]?.activeLyrics ?? ""
                )
            }

            return ProjectLoadResult(
                database: database,
                workingProjectURL: workingProjectURL,
                metadata: metadata,
                stubs: stubs,
                assets: assets,
                librettoFiles: librettoFiles,
                characters: characters,
                hydratedScenePaths: []
            )
        }

        let stubs = phase1.stubs
        let metadata = phase1.metadata
        let characters = (try? await OWPProjectIO.loadCharacterManifestAsync(from: workingProjectURL)) ?? []
        let assets = stubs.map { stub in
            OWSSongAsset(relativePath: stub.relativePath, document: makePlaceholderDocument(from: stub))
        }
        let librettoFiles = stubs.map { stub in
            ProjectTextFile(id: UUID(), relativePath: stub.relativePath, content: "")
        }

        return ProjectLoadResult(
            database: database,
            workingProjectURL: workingProjectURL,
            metadata: metadata,
            stubs: stubs,
            assets: assets,
            librettoFiles: librettoFiles,
            characters: characters,
            hydratedScenePaths: []
        )
    }

    private static func mergedStubs(
        diskStubs: [SongStub],
        summaryByPath: [String: NPSceneSummary]
    ) -> [SongStub] {
        diskStubs.map { stub in
            guard let scene = summaryByPath[stub.relativePath] else {
                return stub
            }

            return SongStub(
                id: scene.id,
                fileURL: stub.fileURL,
                relativePath: stub.relativePath,
                fileSize: stub.fileSize
            )
        }
    }

    static func syncSong(
        asset: OWSSongAsset,
        database: NovotroProjectConnection,
        actorID: String
    ) async throws {
        let existingScene = try await database.loadScene(relativePath: asset.relativePath)
        let scene = makeScene(
            from: asset,
            existingScene: existingScene
        )
        try await database.upsertScene(scene, actorID: actorID)
    }

    static func syncSongTitle(
        asset: OWSSongAsset,
        database: NovotroProjectConnection,
        actorID: String
    ) async throws {
        guard var scene = try await database.loadScene(relativePath: asset.relativePath) else {
            try await syncSong(asset: asset, database: database, actorID: actorID)
            return
        }

        scene.title = asset.document.title
        scene.canonicalTitle = asset.document.canonicalTitle
        scene.updatedAt = asset.document.updatedAt
        scene.rootJSON = patchTitleJSON(scene.rootJSON, asset: asset)
        try await database.upsertScene(scene, actorID: actorID)
    }

    static func decodeCharacters(from artifactData: Data?) throws -> [OPWCharacter] {
        guard let artifactData else { return [] }
        let decoded = try OWPProjectIO.configuredDecoder().decode(OPWCharactersFile.self, from: artifactData)
        return decoded.characters
    }

    static func loadCharactersFile(from database: NovotroProjectConnection) async throws -> Data? {
        for path in charactersPaths {
            if let file = try await database.loadProjectFile(path: path) {
                return file.jsonData
            }
        }
        return nil
    }

    static func loadProjectFile(from database: NovotroProjectConnection, candidatePaths: [String]) async throws -> Data? {
        for path in candidatePaths {
            if let file = try await database.loadProjectFile(path: path) {
                return file.jsonData
            }
        }
        return nil
    }

    static func loadCharacters(from database: NovotroProjectConnection) async throws -> [OPWCharacter] {
        if let artifactData = try await loadCharactersFile(from: database) {
            return try decodeCharacters(from: artifactData)
        }

        let decoder = OWPProjectIO.configuredDecoder()
        return try await database.loadCharacters().compactMap { try? decoder.decode(OPWCharacter.self, from: $0.jsonData) }
    }

    static func makeDocument(from scene: NPSceneRecord) -> OWSSongDocument {
        var document = OWSSongDocument(
            songID: scene.songID,
            title: scene.title,
            canonicalTitle: scene.canonicalTitle,
            notes: scene.notes,
            updatedAt: scene.updatedAt,
            activeVersionID: scene.activeVersionID,
            versions: scene.versions.map { version in
                OWSVersionPayload(
                    id: version.id,
                    label: version.label,
                    createdAt: version.createdAt,
                    updatedAt: version.updatedAt,
                    lyrics: version.lyrics,
                    saveType: VersionSaveType(rawValue: version.saveType) ?? .manual,
                    userLabel: version.userLabel,
                    isBookmarked: version.isBookmarked
                )
            }
        )
        document.normalize()
        return document
    }

    static func makeLightweightDocument(from summary: NPSceneSummary) -> OWSSongDocument {
        let now = summary.updatedAt
        let versionID = summary.activeVersionID ?? UUID()
        var document = OWSSongDocument(
            songID: summary.id,
            title: summary.title,
            canonicalTitle: summary.title.lowercased(),
            notes: "",
            updatedAt: now,
            activeVersionID: versionID,
            versions: [
                OWSVersionPayload(
                    id: versionID,
                    label: "Current Draft",
                    createdAt: now,
                    updatedAt: now,
                    lyrics: summary.activeLyrics,
                    saveType: .manual,
                    userLabel: nil,
                    isBookmarked: false
                )
            ]
        )
        document.normalize()
        return document
    }

    static func makePlaceholderDocument(from stub: SongStub) -> OWSSongDocument {
        let now = Date()
        let versionID = UUID()
        var document = OWSSongDocument(
            songID: stub.id,
            title: stub.displayName.toTitleCase(),
            canonicalTitle: stub.displayName.lowercased(),
            notes: "",
            updatedAt: now,
            activeVersionID: versionID,
            versions: [
                OWSVersionPayload(
                    id: versionID,
                    label: "Current Draft",
                    createdAt: now,
                    updatedAt: now,
                    lyrics: "",
                    saveType: .manual,
                    userLabel: nil,
                    isBookmarked: false
                )
            ]
        )
        document.normalize()
        return document
    }

    private static func loadMetadata(
        from database: NovotroProjectConnection,
        projectURL: URL
    ) async throws -> ProjectMetadata {
        if let data = try await loadProjectFile(from: database, candidatePaths: metadataPaths),
           let decoded = try? OWPProjectIO.configuredDecoder().decode(ProjectMetadata.self, from: data) {
            return decoded
        }
        return ProjectMetadata(
            name: projectURL.deletingPathExtension().lastPathComponent
        )
    }

    private static func makeScene(from asset: OWSSongAsset, existingScene: NPSceneRecord?) -> NPSceneRecord {
        let existingVersionsByID = Dictionary(uniqueKeysWithValues: (existingScene?.versions ?? []).map { ($0.id, $0) })
        let versions = asset.document.versions.enumerated().map { sortIndex, version in
            let existing = existingVersionsByID[version.id]
            return NPSceneVersionRecord(
                id: version.id,
                sortIndex: existing?.sortIndex ?? sortIndex,
                label: version.label,
                saveType: version.saveType.rawValue,
                userLabel: version.userLabel,
                isBookmarked: version.isBookmarked,
                createdAt: existing?.createdAt ?? version.createdAt,
                updatedAt: version.updatedAt,
                lyrics: version.lyrics,
                versionJSON: patchVersionJSON(existing?.versionJSON, with: version),
                playbackJSON: existing?.playbackJSON,
                noteCount: existing?.noteCount ?? 0,
                lengthTicks: existing?.lengthTicks ?? 0
            )
        }

        return NPSceneRecord(
            id: existingScene?.id ?? asset.document.songID,
            songID: asset.document.songID,
            relativePath: asset.relativePath,
            title: asset.document.title,
            canonicalTitle: asset.document.canonicalTitle,
            notes: asset.document.notes,
            updatedAt: asset.document.updatedAt,
            activeVersionID: asset.document.activeVersionID,
            orderIndex: existingScene?.orderIndex ?? 0,
            rootJSON: patchRootJSON(existingScene?.rootJSON, asset: asset),
            animateSceneJSON: existingScene?.animateSceneJSON,
            animateTrackCount: existingScene?.animateTrackCount ?? 0,
            animateKeyframeCount: existingScene?.animateKeyframeCount ?? 0,
            versions: versions
        )
    }

    private static func patchRootJSON(_ existingData: Data?, asset: OWSSongAsset) -> Data? {
        var root = (existingData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        root["songID"] = asset.document.songID.uuidString
        root["title"] = asset.document.title
        root["canonicalTitle"] = asset.document.canonicalTitle
        root["notes"] = asset.document.notes
        root["updatedAt"] = OWSSongDocument.isoFormatter.string(from: asset.document.updatedAt)
        root["activeVersionID"] = asset.document.activeVersionID?.uuidString as Any
        root.removeValue(forKey: "versions")
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func patchTitleJSON(_ existingData: Data?, asset: OWSSongAsset) -> Data? {
        var root = (existingData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        root["title"] = asset.document.title
        root["canonicalTitle"] = asset.document.canonicalTitle
        root["updatedAt"] = OWSSongDocument.isoFormatter.string(from: asset.document.updatedAt)
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func patchVersionJSON(_ existingData: Data?, with version: OWSVersionPayload) -> Data? {
        var entry = (existingData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        entry["id"] = version.id.uuidString
        entry["label"] = version.label
        entry["createdAt"] = OWSSongDocument.isoFormatter.string(from: version.createdAt)
        entry["updatedAt"] = OWSSongDocument.isoFormatter.string(from: version.updatedAt)
        entry["saveType"] = version.saveType.rawValue
        entry["isBookmarked"] = version.isBookmarked
        if let userLabel = version.userLabel {
            entry["userLabel"] = userLabel
        } else {
            entry.removeValue(forKey: "userLabel")
        }
        entry.removeValue(forKey: "lyrics")
        entry.removeValue(forKey: "playback")
        entry.removeValue(forKey: "playbackSnapshot")
        return try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])
    }

    private static func versionDictionary(from version: OWSVersionPayload) -> [String: Any] {
        var entry: [String: Any] = [
            "id": version.id.uuidString,
            "label": version.label,
            "createdAt": OWSSongDocument.isoFormatter.string(from: version.createdAt),
            "updatedAt": OWSSongDocument.isoFormatter.string(from: version.updatedAt),
            "lyrics": version.lyrics,
            "saveType": version.saveType.rawValue,
            "isBookmarked": version.isBookmarked
        ]
        if let userLabel = version.userLabel {
            entry["userLabel"] = userLabel
        }
        return entry
    }
}

@available(macOS 26.0, *)
struct ProjectLoadResult {
    let database: NovotroProjectConnection
    let workingProjectURL: URL
    let metadata: ProjectMetadata
    let stubs: [SongStub]
    let assets: [OWSSongAsset]
    let librettoFiles: [ProjectTextFile]
    let characters: [OPWCharacter]
    let hydratedScenePaths: Set<String>
}
