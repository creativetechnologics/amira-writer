import Foundation
import NovotroProjectKit

enum ProjectDatabaseBridge {
    static let scoreActorID = NovotroProjectClientIdentity.actorID(for: "novotro-score")
    static let metadataPath = OWPProjectIO.projectMetadataFile
    static let legacyMetadataPath = "project.json"
    static let projectInstrumentsPath = OWPProjectIO.projectInstrumentsFile

    struct ScoreProjectLoad {
        var database: NovotroProjectConnection?
        var workingProjectURL: URL
        var metadata: ProjectMetadata
        var projectInstrumentMappings: [String: InstrumentMapping]
        var stubs: [SongStub]
        var songAssets: [OWSSongAsset]
        var librettoFiles: [ProjectTextFile]
        var hydratedSongPaths: Set<String>
    }

    static func loadScoreProject(url: URL, preferService: Bool? = nil) async throws -> ScoreProjectLoad {
        if url.pathExtension.lowercased() == "ows" {
            let (metadata, stubs, _) = try await OWPProjectIO.loadPhase1(from: url)
            var songAssets: [OWSSongAsset] = []
            var librettoFiles: [ProjectTextFile] = []
            for stub in stubs {
                let asset = try await OWPProjectIO.loadSongAsync(stub: stub)
                songAssets.append(asset)
                if let version = asset.document.activeVersion() {
                    librettoFiles.append(
                        ProjectTextFile(id: UUID(), relativePath: asset.relativePath, content: version.lyrics)
                    )
                }
            }
            return ScoreProjectLoad(
                database: nil,
                workingProjectURL: url,
                metadata: metadata,
                projectInstrumentMappings: [:],
                stubs: stubs,
                songAssets: songAssets,
                librettoFiles: librettoFiles,
                hydratedSongPaths: Set(songAssets.map(\.relativePath))
            )
        }

        let database = try await NovotroProjectConnection.open(projectURL: url, preferService: preferService)
        let workingProjectURL = database.workingProjectURL
        let phase1 = try await OWPProjectIO.loadPhase1(from: workingProjectURL)
        if let summary = try? await database.loadProjectSummary() {
            let metadata = try await loadProjectMetadata(database: database) ?? phase1.metadata
            let projectInstrumentMappings = (try? await loadProjectInstrumentMappings(database: database)) ?? [:]
            let summaryByPath = Dictionary(uniqueKeysWithValues: summary.scenes.map { ($0.relativePath, $0) })
            let stubs = mergedStubs(diskStubs: phase1.stubs, summaryByPath: summaryByPath)
            let songAssets = stubs.map { stub in
                if let scene = summaryByPath[stub.relativePath] {
                    return sceneAsset(from: scene)
                }
                return placeholderSceneAsset(from: stub)
            }
            let librettoFiles = stubs.map { stub in
                ProjectTextFile(
                    id: UUID(),
                    relativePath: stub.relativePath,
                    content: summaryByPath[stub.relativePath]?.activeLyrics ?? ""
                )
            }

            return ScoreProjectLoad(
                database: database,
                workingProjectURL: workingProjectURL,
                metadata: metadata,
                projectInstrumentMappings: projectInstrumentMappings,
                stubs: stubs,
                songAssets: songAssets,
                librettoFiles: librettoFiles,
                hydratedSongPaths: []
            )
        }

        let metadata = phase1.metadata
        let stubs = phase1.stubs
        let songAssets = stubs.map { stub in
            placeholderSceneAsset(from: stub)
        }
        let librettoFiles = stubs.map { stub in
            ProjectTextFile(id: UUID(), relativePath: stub.relativePath, content: "")
        }

        return ScoreProjectLoad(
            database: database,
            workingProjectURL: workingProjectURL,
            metadata: metadata,
            projectInstrumentMappings: [:],
            stubs: stubs,
            songAssets: songAssets,
            librettoFiles: librettoFiles,
            hydratedSongPaths: []
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

    static func loadProjectMetadata(database: NovotroProjectConnection?) async throws -> ProjectMetadata? {
        guard let database else { return nil }
        if let metadataFile = try await database.loadProjectFile(path: metadataPath),
           let metadata = decodeProjectMetadata(from: metadataFile.jsonData) {
            return metadata
        }

        if let legacyMetadataFile = try await database.loadProjectFile(path: legacyMetadataPath),
           let metadata = decodeProjectMetadata(from: legacyMetadataFile.jsonData) {
            return metadata
        }
        return nil
    }

    static func loadProjectInstrumentMappings(database: NovotroProjectConnection?) async throws -> [String: InstrumentMapping]? {
        guard let database else { return nil }
        guard let file = try await database.loadProjectFile(path: projectInstrumentsPath) else {
            return nil
        }
        return decodeProjectInstrumentMappings(from: file.jsonData)
    }

    static func loadSceneAsset(
        database: NovotroProjectConnection?,
        relativePath: String,
        includePlayback: Bool
    ) async throws -> OWSSongAsset? {
        guard let database,
              let scene = try await database.loadScene(relativePath: relativePath) else {
            return nil
        }
        return sceneAsset(from: scene, includePlayback: includePlayback)
    }

    static func hydratePlayback(projectURL: URL, relativePath: String) async -> OWSPlaybackSnapshot? {
        guard projectURL.pathExtension.lowercased() != "ows" else { return nil }
        guard let database = try? await NovotroProjectConnection.open(projectURL: projectURL) else {
            return nil
        }
        guard (try? await database.ensureCurrentIndex()) != nil,
              let scene = try? await database.loadScene(relativePath: relativePath),
              let version = scene.activeVersion,
              let playbackJSON = version.playbackJSON else {
            return nil
        }

        return decodePlayback(playbackJSON, decoder: configuredDecoder())
    }

    static func syncSong(
        database: NovotroProjectConnection?,
        asset: OWSSongAsset,
        playbackOverride: OWSPlaybackSnapshot?,
        actorID: String
    ) async throws {
        guard let database else { return }
        let existingScene = try await database.loadScene(relativePath: asset.relativePath)
        let scene = makeScene(from: asset, existingScene: existingScene, playbackOverride: playbackOverride)
        try await database.upsertScene(scene, actorID: actorID)
    }

    static func upsertProjectState(
        database: NovotroProjectConnection?,
        metadata: ProjectMetadata,
        instrumentMappings: [String: InstrumentMapping],
        actorID: String
    ) async throws {
        guard let database else { return }

        let metadataData = try configuredEncoder().encode(metadata)
        try await database.upsertProjectFile(
            path: metadataPath,
            jsonData: metadataData,
            actorID: actorID
        )

        let normalizedMappings = OWPProjectIO.normalizeProjectInstrumentMappings(instrumentMappings)
        let sortedMappings = normalizedMappings.values.sorted { lhs, rhs in
            let lhsOrder = lhs.effectiveSortOrder
            let rhsOrder = rhs.effectiveSortOrder
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsName = lhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if lhsName != rhsName {
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
            return lhs.channelKey.localizedStandardCompare(rhs.channelKey) == .orderedAscending
        }
        let mappingData = try configuredEncoder().encode(sortedMappings)
        try await database.upsertProjectFile(
            path: projectInstrumentsPath,
            jsonData: mappingData,
            actorID: actorID
        )
    }

    static func resync(projectURL: URL) async {
        guard projectURL.pathExtension.lowercased() != "ows" else { return }
        guard let database = try? await NovotroProjectConnection.open(projectURL: projectURL) else {
            return
        }
        try? await database.ensureCurrentIndex(forceRebuild: true)
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

    private static func sceneAsset(from scene: NPSceneRecord, includePlayback: Bool) -> OWSSongAsset {
        let decoder = configuredDecoder()
        let versions = scene.versions.map { version in
            OWSVersionPayload(
                id: version.id,
                label: version.label,
                createdAt: version.createdAt,
                updatedAt: version.updatedAt,
                lyrics: version.lyrics,
                saveType: VersionSaveType(rawValue: version.saveType) ?? .manual,
                userLabel: version.userLabel,
                isBookmarked: version.isBookmarked,
                playback: includePlayback ? decodePlayback(version.playbackJSON, decoder: decoder) : nil
            )
        }

        let document = OWSSongDocument(
            songID: scene.songID,
            title: scene.title,
            canonicalTitle: scene.canonicalTitle,
            notes: scene.notes,
            updatedAt: scene.updatedAt,
            activeVersionID: scene.activeVersionID,
            versions: versions,
            instrumentMappings: decodeInstrumentMappings(from: scene.rootJSON, decoder: decoder)
        )

        return OWSSongAsset(relativePath: scene.relativePath, document: document)
    }

    private static func sceneAsset(from summary: NPSceneSummary) -> OWSSongAsset {
        let versionID = summary.activeVersionID ?? UUID()
        var document = OWSSongDocument(
            songID: summary.id,
            title: summary.title,
            canonicalTitle: summary.title.lowercased(),
            notes: "",
            updatedAt: summary.updatedAt,
            activeVersionID: versionID,
            versions: [
                OWSVersionPayload(
                    id: versionID,
                    label: "Current Draft",
                    createdAt: summary.updatedAt,
                    updatedAt: summary.updatedAt,
                    lyrics: summary.activeLyrics,
                    saveType: .manual,
                    userLabel: nil,
                    isBookmarked: false,
                    playback: nil
                )
            ],
            instrumentMappings: [:]
        )
        document.normalize()
        return OWSSongAsset(relativePath: summary.relativePath, document: document)
    }

    private static func placeholderSceneAsset(from stub: SongStub) -> OWSSongAsset {
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
                    isBookmarked: false,
                    playback: nil
                )
            ],
            instrumentMappings: [:]
        )
        document.normalize()
        return OWSSongAsset(relativePath: stub.relativePath, document: document)
    }

    private static func makeScene(
        from asset: OWSSongAsset,
        existingScene: NPSceneRecord?,
        playbackOverride: OWSPlaybackSnapshot?
    ) -> NPSceneRecord {
        let encoder = configuredEncoder()
        let playbackOverrideJSON = playbackOverride.flatMap { try? encoder.encode($0) }
        let existingVersionsByID = Dictionary(uniqueKeysWithValues: (existingScene?.versions ?? []).map { ($0.id, $0) })

        let versions = asset.document.versions.enumerated().map { sortIndex, version in
            let existing = existingVersionsByID[version.id]
            let playbackJSON: Data?
            if version.id == asset.document.activeVersionID, let playbackOverrideJSON {
                playbackJSON = playbackOverrideJSON
            } else if let playback = version.playback {
                playbackJSON = try? encoder.encode(playback)
            } else {
                playbackJSON = existing?.playbackJSON
            }

            let noteMetrics = metrics(from: playbackJSON)
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
                versionJSON: patchVersionJSON(existing?.versionJSON, with: version, playbackJSON: playbackJSON),
                playbackJSON: playbackJSON,
                noteCount: noteMetrics.noteCount,
                lengthTicks: noteMetrics.lengthTicks
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
        root["updatedAt"] = isoString(asset.document.updatedAt)
        root["activeVersionID"] = asset.document.activeVersionID?.uuidString as Any
        root.removeValue(forKey: "versions")
        if let mappingsObject = jsonObject(from: OWPProjectIO.normalizeProjectInstrumentMappings(asset.document.instrumentMappings)) {
            root["instrumentMappings"] = mappingsObject
        }
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func patchVersionJSON(
        _ existingData: Data?,
        with version: OWSVersionPayload,
        playbackJSON: Data?
    ) -> Data? {
        var entry = (existingData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        entry["id"] = version.id.uuidString
        entry["label"] = version.label
        entry["createdAt"] = isoString(version.createdAt)
        entry["updatedAt"] = isoString(version.updatedAt)
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

    private static func versionDictionary(from version: OWSVersionPayload, playbackObject: Any?) -> [String: Any] {
        var entry: [String: Any] = [
            "id": version.id.uuidString,
            "label": version.label,
            "createdAt": isoString(version.createdAt),
            "updatedAt": isoString(version.updatedAt),
            "lyrics": version.lyrics,
            "saveType": version.saveType.rawValue,
            "isBookmarked": version.isBookmarked
        ]
        if let userLabel = version.userLabel {
            entry["userLabel"] = userLabel
        }
        if let playbackObject {
            entry["playback"] = playbackObject
            entry["playbackSnapshot"] = playbackObject
        }
        return entry
    }

    private static func decodePlayback(_ data: Data?, decoder: JSONDecoder) -> OWSPlaybackSnapshot? {
        guard let data else { return nil }
        return try? decoder.decode(OWSPlaybackSnapshot.self, from: data)
    }

    private static func decodeInstrumentMappings(from rootJSON: Data?, decoder: JSONDecoder) -> [String: InstrumentMapping] {
        guard let rootJSON,
              let root = try? JSONSerialization.jsonObject(with: rootJSON) as? [String: Any],
              let mappingsObject = root["instrumentMappings"],
              let mappingsData = try? JSONSerialization.data(withJSONObject: mappingsObject),
              let mappings = try? decoder.decode([String: InstrumentMapping].self, from: mappingsData) else {
            return [:]
        }
        return OWPProjectIO.normalizeProjectInstrumentMappings(mappings)
    }

    private static func metrics(from playbackJSON: Data?) -> (noteCount: Int, lengthTicks: Int) {
        guard let playbackJSON,
              let root = try? JSONSerialization.jsonObject(with: playbackJSON) as? [String: Any] else {
            return (0, 0)
        }
        return (
            (root["notes"] as? [[String: Any]])?.count ?? 0,
            root["lengthTicks"] as? Int ?? 0
        )
    }

    private static func defaultMetadata(from project: NPProjectRecord) -> ProjectMetadata {
        ProjectMetadata(
            name: project.name,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            notes: project.notes
        )
    }

    private static func defaultMetadata(from url: URL) -> ProjectMetadata {
        ProjectMetadata(
            name: url.deletingPathExtension().lastPathComponent,
            createdAt: .now,
            updatedAt: .now,
            notes: ""
        )
    }

    private static func decodeProjectMetadata(from project: NPProjectRecord) -> ProjectMetadata? {
        if let metadataFile = project.projectFile(at: metadataPath),
           let metadata = decodeProjectMetadata(from: metadataFile.jsonData) {
            return metadata
        }

        if let legacyMetadataFile = project.projectFile(at: legacyMetadataPath),
           let metadata = decodeProjectMetadata(from: legacyMetadataFile.jsonData) {
            return metadata
        }

        return nil
    }

    private static func decodeProjectMetadata(from data: Data) -> ProjectMetadata? {
        try? configuredDecoder().decode(ProjectMetadata.self, from: data)
    }

    private static func decodeProjectInstrumentMappings(from project: NPProjectRecord) -> [String: InstrumentMapping]? {
        guard let file = project.projectFile(at: projectInstrumentsPath) else { return nil }
        return decodeProjectInstrumentMappings(from: file.jsonData)
    }

    private static func decodeProjectInstrumentMappings(from data: Data) -> [String: InstrumentMapping]? {
        let decoder = configuredDecoder()
        if let decoded = try? decoder.decode([String: InstrumentMapping].self, from: data) {
            return OWPProjectIO.normalizeProjectInstrumentMappings(decoded)
        }
        if let decoded = try? decoder.decode([InstrumentMapping].self, from: data) {
            var keyed: [String: InstrumentMapping] = [:]
            for mapping in decoded {
                let key = mapping.channelKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? mapping.displayName
                    : mapping.channelKey
                keyed[key] = mapping
            }
            return OWPProjectIO.normalizeProjectInstrumentMappings(keyed)
        }
        return nil
    }

    private static func jsonObject<T: Encodable>(from value: T) -> Any? {
        guard let data = try? configuredEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func configuredDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func configuredEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
