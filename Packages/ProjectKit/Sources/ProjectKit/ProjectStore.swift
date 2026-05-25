import Foundation
import SQLite3

public enum ProjectArtifactKind: String, CaseIterable, Sendable {
    case metadata
    case instruments
    case charactersFile
    case index
    case animateMetadata
}

public struct ProjectInfo: Sendable {
    public let projectID: UUID
    public let projectURL: URL
    public let databaseURL: URL
    public let name: String
    public let importedAt: Date
    public let updatedAt: Date
}

public struct ImportStats: Sendable {
    public let projectID: UUID
    public let songsImported: Int
    public let versionsImported: Int
    public let animationScenesImported: Int
    public let charactersImported: Int
    public let importedAt: Date
}

public struct SongVersionRecord: Sendable {
    public let versionID: UUID
    public let label: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lyrics: String
    public let saveType: String
    public let userLabel: String?
    public let isBookmarked: Bool
    public let playbackJSON: Data?
    public let legacyVersionJSON: Data?
    public let noteCount: Int
    public let trackCount: Int
    public let lengthTicks: Int
}

public struct SongVersionInput: Sendable {
    public let versionID: UUID
    public let label: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lyrics: String
    public let saveType: String
    public let userLabel: String?
    public let isBookmarked: Bool
    public let playbackJSON: Data?
    public let legacyVersionJSON: Data?

    public init(
        versionID: UUID,
        label: String,
        createdAt: Date,
        updatedAt: Date,
        lyrics: String,
        saveType: String,
        userLabel: String?,
        isBookmarked: Bool,
        playbackJSON: Data?,
        legacyVersionJSON: Data?
    ) {
        self.versionID = versionID
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lyrics = lyrics
        self.saveType = saveType
        self.userLabel = userLabel
        self.isBookmarked = isBookmarked
        self.playbackJSON = playbackJSON
        self.legacyVersionJSON = legacyVersionJSON
    }
}

public struct SongInput: Sendable {
    public let songID: UUID
    public let relativePath: String
    public let title: String
    public let canonicalTitle: String
    public let notes: String
    public let activeVersionID: UUID?
    public let updatedAt: Date
    public let legacySongJSON: Data
    public let topLevelInstrumentMappingsJSON: Data?
    public let versions: [SongVersionInput]

    public init(
        songID: UUID,
        relativePath: String,
        title: String,
        canonicalTitle: String,
        notes: String,
        activeVersionID: UUID?,
        updatedAt: Date,
        legacySongJSON: Data,
        topLevelInstrumentMappingsJSON: Data?,
        versions: [SongVersionInput]
    ) {
        self.songID = songID
        self.relativePath = relativePath
        self.title = title
        self.canonicalTitle = canonicalTitle
        self.notes = notes
        self.activeVersionID = activeVersionID
        self.updatedAt = updatedAt
        self.legacySongJSON = legacySongJSON
        self.topLevelInstrumentMappingsJSON = topLevelInstrumentMappingsJSON
        self.versions = versions
    }
}

public struct SongSummary: Sendable {
    public let songID: UUID
    public let relativePath: String
    public let title: String
    public let canonicalTitle: String
    public let notes: String
    public let currentLyrics: String
    public let activeVersionID: UUID?
    public let updatedAt: Date
    public let versionCount: Int
    public let noteCount: Int
    public let trackCount: Int
    public let lengthTicks: Int
}

public struct SongRecord: Sendable {
    public let summary: SongSummary
    public let legacySongJSON: Data
    public let topLevelInstrumentMappingsJSON: Data?
    public let versions: [SongVersionRecord]
}

public struct AnimationSceneSummary: Sendable {
    public let owsPath: String
    public let updatedAt: Date
}

public struct AnimationSceneRecord: Sendable {
    public let owsPath: String
    public let updatedAt: Date
    public let dataJSON: Data
}

public struct CharacterRecord: Sendable {
    public let characterID: UUID
    public let name: String
    public let directoryName: String
    public let updatedAt: Date
    public let dataJSON: Data
}

public struct ChangeEvent: Sendable, Hashable, Codable {
    public let changeID: Int64
    public let entityType: String
    public let entityKey: String
    public let eventType: String
    public let actorID: String?
    public let createdAt: Date
}

public actor ProjectStore {
    private let projectURL: URL
    private let databaseURL: URL
    private let projectID: UUID
    private nonisolated(unsafe) var db: OpaquePointer?

    private static let schemaVersion = 1

    public static func databaseDirectory(for projectURL: URL) -> URL {
        ProjectPaths(root: projectURL).amiraDir
    }

    public static func databaseURL(for projectURL: URL) -> URL {
        databaseDirectory(for: projectURL).appendingPathComponent("project.sqlite")
    }

    public init(projectURL: URL) throws {
        self.projectURL = projectURL
        self.databaseURL = Self.databaseURL(for: projectURL)
        try FileManager.default.createDirectory(
            at: Self.databaseDirectory(for: projectURL),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        if sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "sqlite open failed"
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }

        self.db = handle
        try Self.configureDatabase(db: handle)

        if let existing = try Self.selectProjectID(db: handle) {
            self.projectID = existing
        } else {
            self.projectID = UUID()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func ensureImported(force: Bool = false) throws -> ImportStats {
        if !force, let existing = try loadProjectInfo() {
            return ImportStats(
                projectID: existing.projectID,
                songsImported: try count(table: "songs"),
                versionsImported: try count(table: "song_versions"),
                animationScenesImported: try count(table: "animation_scenes"),
                charactersImported: try count(table: "characters"),
                importedAt: existing.importedAt
            )
        }

        try clearImportedData()
        let importedAt = Date()

        let projectName = try importProjectArtifacts(importedAt: importedAt)
        let (songsImported, versionsImported) = try importSongs(importedAt: importedAt)
        let animationScenesImported = try importAnimationScenes(importedAt: importedAt)
        let charactersImported = try importCharacters(importedAt: importedAt)

        try upsertProjectRow(name: projectName, importedAt: importedAt, updatedAt: importedAt)
        try appendChange(entityType: "project", entityKey: projectID.uuidString, eventType: "import", actorID: "system")

        return ImportStats(
            projectID: projectID,
            songsImported: songsImported,
            versionsImported: versionsImported,
            animationScenesImported: animationScenesImported,
            charactersImported: charactersImported,
            importedAt: importedAt
        )
    }

    public func loadProjectInfo() throws -> ProjectInfo? {
        guard let row = try querySingle(
            """
            SELECT name, imported_at, updated_at
            FROM projects
            WHERE project_id = ?
            """,
            bind: [projectID.uuidString]
        ) else {
            return nil
        }

        return ProjectInfo(
            projectID: projectID,
            projectURL: projectURL,
            databaseURL: databaseURL,
            name: row.string(at: 0) ?? projectURL.deletingPathExtension().lastPathComponent,
            importedAt: row.date(at: 1) ?? Date(),
            updatedAt: row.date(at: 2) ?? Date()
        )
    }

    public func loadArtifact(_ kind: ProjectArtifactKind) throws -> Data? {
        let row = try querySingle(
            """
            SELECT data_json
            FROM project_artifacts
            WHERE project_id = ? AND kind = ?
            """,
            bind: [projectID.uuidString, kind.rawValue]
        )
        return row?.data(at: 0)
    }

    public func upsertArtifact(_ kind: ProjectArtifactKind, dataJSON: Data?, actorID: String?) throws {
        let now = Date()
        try execute(
            """
            INSERT INTO project_artifacts (project_id, kind, data_json, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(project_id, kind)
            DO UPDATE SET data_json = excluded.data_json, updated_at = excluded.updated_at
            """,
            bind: [projectID.uuidString, kind.rawValue, dataJSON, now]
        )
        try appendChange(entityType: "artifact", entityKey: kind.rawValue, eventType: "upsert", actorID: actorID)
        try touchProject(updatedAt: now)
    }

    public func listSongSummaries() throws -> [SongSummary] {
        let rows = try queryRows(
            """
            SELECT
                s.song_id,
                s.relative_path,
                s.title,
                s.canonical_title,
                s.notes,
                COALESCE(v.lyrics, ''),
                s.active_version_id,
                s.updated_at,
                (SELECT COUNT(*) FROM song_versions sv WHERE sv.song_id = s.song_id),
                COALESCE(v.note_count, 0),
                COALESCE(v.track_count, 0),
                COALESCE(v.length_ticks, 0)
            FROM songs s
            LEFT JOIN song_versions v ON v.version_id = s.active_version_id
            WHERE s.project_id = ?
            ORDER BY s.relative_path ASC
            """,
            bind: [projectID.uuidString]
        )

        return rows.compactMap { row in
            guard let songIDString = row.string(at: 0),
                  let songID = UUID(uuidString: songIDString),
                  let relativePath = row.string(at: 1),
                  let title = row.string(at: 2),
                  let canonicalTitle = row.string(at: 3),
                  let notes = row.string(at: 4),
                  let currentLyrics = row.string(at: 5),
                  let updatedAt = row.date(at: 7) else {
                return nil
            }

            return SongSummary(
                songID: songID,
                relativePath: relativePath,
                title: title,
                canonicalTitle: canonicalTitle,
                notes: notes,
                currentLyrics: currentLyrics,
                activeVersionID: row.string(at: 6).flatMap(UUID.init(uuidString:)),
                updatedAt: updatedAt,
                versionCount: row.int(at: 8),
                noteCount: row.int(at: 9),
                trackCount: row.int(at: 10),
                lengthTicks: row.int(at: 11)
            )
        }
    }

    public func loadSong(relativePath: String) throws -> SongRecord? {
        guard let songRow = try querySingle(
            """
            SELECT song_id, relative_path, title, canonical_title, notes, active_version_id, updated_at, legacy_song_json, top_level_instrument_mappings_json
            FROM songs
            WHERE project_id = ? AND relative_path = ?
            """,
            bind: [projectID.uuidString, relativePath]
        ) else {
            return nil
        }

        guard let songIDString = songRow.string(at: 0),
              let songID = UUID(uuidString: songIDString),
              let path = songRow.string(at: 1),
              let title = songRow.string(at: 2),
              let canonicalTitle = songRow.string(at: 3),
              let notes = songRow.string(at: 4),
              let updatedAt = songRow.date(at: 6),
              let legacySongJSON = songRow.data(at: 7) else {
            return nil
        }

        let versionRows = try queryRows(
            """
            SELECT version_id, label, created_at, updated_at, lyrics, save_type, user_label, is_bookmarked, playback_json, legacy_version_json, note_count, track_count, length_ticks
            FROM song_versions
            WHERE song_id = ?
            ORDER BY updated_at DESC, label ASC
            """,
            bind: [songID.uuidString]
        )

        let versions = versionRows.compactMap { row -> SongVersionRecord? in
            guard let versionIDString = row.string(at: 0),
                  let versionID = UUID(uuidString: versionIDString),
                  let label = row.string(at: 1),
                  let createdAt = row.date(at: 2),
                  let versionUpdatedAt = row.date(at: 3),
                  let lyrics = row.string(at: 4),
                  let saveType = row.string(at: 5) else {
                return nil
            }

            return SongVersionRecord(
                versionID: versionID,
                label: label,
                createdAt: createdAt,
                updatedAt: versionUpdatedAt,
                lyrics: lyrics,
                saveType: saveType,
                userLabel: row.string(at: 6),
                isBookmarked: row.int(at: 7) != 0,
                playbackJSON: row.data(at: 8),
                legacyVersionJSON: row.data(at: 9),
                noteCount: row.int(at: 10),
                trackCount: row.int(at: 11),
                lengthTicks: row.int(at: 12)
            )
        }

        let activeVersionID = songRow.string(at: 5).flatMap(UUID.init(uuidString:))
        let currentVersion = versions.first(where: { $0.versionID == activeVersionID }) ?? versions.first
        let summary = SongSummary(
            songID: songID,
            relativePath: path,
            title: title,
            canonicalTitle: canonicalTitle,
            notes: notes,
            currentLyrics: currentVersion?.lyrics ?? "",
            activeVersionID: activeVersionID,
            updatedAt: updatedAt,
            versionCount: versions.count,
            noteCount: currentVersion?.noteCount ?? 0,
            trackCount: currentVersion?.trackCount ?? 0,
            lengthTicks: currentVersion?.lengthTicks ?? 0
        )

        return SongRecord(
            summary: summary,
            legacySongJSON: legacySongJSON,
            topLevelInstrumentMappingsJSON: songRow.data(at: 8),
            versions: versions
        )
    }

    public func updateSongText(relativePath: String, lyrics: String, actorID: String?) throws {
        guard let song = try loadSong(relativePath: relativePath),
              let activeVersionID = song.summary.activeVersionID else { return }
        let now = Date()
        try execute(
            """
            UPDATE song_versions
            SET lyrics = ?, updated_at = ?
            WHERE version_id = ?
            """,
            bind: [lyrics, now, activeVersionID.uuidString]
        )
        try execute(
            """
            UPDATE songs
            SET updated_at = ?
            WHERE song_id = ?
            """,
            bind: [now, song.summary.songID.uuidString]
        )
        try appendChange(entityType: "song_text", entityKey: relativePath, eventType: "update", actorID: actorID)
        try touchProject(updatedAt: now)
    }

    public func updateSongPlayback(relativePath: String, versionID: UUID?, playbackJSON: Data?, actorID: String?) throws {
        guard let song = try loadSong(relativePath: relativePath) else { return }
        let resolvedVersionID = versionID ?? song.summary.activeVersionID
        guard let resolvedVersionID else { return }
        let now = Date()
        let metrics = Self.extractPlaybackMetrics(from: playbackJSON)
        try execute(
            """
            UPDATE song_versions
            SET playback_json = ?, updated_at = ?, note_count = ?, track_count = ?, length_ticks = ?
            WHERE version_id = ?
            """,
            bind: [playbackJSON, now, metrics.noteCount, metrics.trackCount, metrics.lengthTicks, resolvedVersionID.uuidString]
        )
        try execute(
            """
            UPDATE songs
            SET updated_at = ?
            WHERE song_id = ?
            """,
            bind: [now, song.summary.songID.uuidString]
        )
        try appendChange(entityType: "song_playback", entityKey: relativePath, eventType: "update", actorID: actorID)
        try touchProject(updatedAt: now)
    }

    public func replaceSong(_ song: SongInput, actorID: String?) throws {
        let now = Date()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute(
                """
                INSERT INTO songs (
                    song_id, project_id, relative_path, title, canonical_title, notes,
                    active_version_id, updated_at, legacy_song_json, top_level_instrument_mappings_json
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(relative_path)
                DO UPDATE SET
                    song_id = excluded.song_id,
                    title = excluded.title,
                    canonical_title = excluded.canonical_title,
                    notes = excluded.notes,
                    active_version_id = excluded.active_version_id,
                    updated_at = excluded.updated_at,
                    legacy_song_json = excluded.legacy_song_json,
                    top_level_instrument_mappings_json = excluded.top_level_instrument_mappings_json
                """,
                bind: [
                    song.songID.uuidString,
                    projectID.uuidString,
                    song.relativePath,
                    song.title,
                    song.canonicalTitle,
                    song.notes,
                    song.activeVersionID?.uuidString,
                    song.updatedAt,
                    song.legacySongJSON,
                    song.topLevelInstrumentMappingsJSON
                ]
            )

            try execute("DELETE FROM song_versions WHERE song_id = ?", bind: [song.songID.uuidString])
            for version in song.versions {
                let metrics = Self.extractPlaybackMetrics(from: version.playbackJSON)
                try execute(
                    """
                    INSERT INTO song_versions (
                        version_id, song_id, label, created_at, updated_at, lyrics, save_type,
                        user_label, is_bookmarked, playback_json, legacy_version_json,
                        note_count, track_count, length_ticks
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bind: [
                        version.versionID.uuidString,
                        song.songID.uuidString,
                        version.label,
                        version.createdAt,
                        version.updatedAt,
                        version.lyrics,
                        version.saveType,
                        version.userLabel,
                        version.isBookmarked ? 1 : 0,
                        version.playbackJSON,
                        version.legacyVersionJSON,
                        metrics.noteCount,
                        metrics.trackCount,
                        metrics.lengthTicks
                    ]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        try appendChange(entityType: "song", entityKey: song.relativePath, eventType: "replace", actorID: actorID)
        try touchProject(updatedAt: now)
    }

    public func listAnimationSceneSummaries() throws -> [AnimationSceneSummary] {
        let rows = try queryRows(
            """
            SELECT ows_path, updated_at
            FROM animation_scenes
            WHERE project_id = ?
            ORDER BY ows_path ASC
            """,
            bind: [projectID.uuidString]
        )

        return rows.compactMap { row in
            guard let owsPath = row.string(at: 0),
                  let updatedAt = row.date(at: 1) else {
                return nil
            }
            return AnimationSceneSummary(owsPath: owsPath, updatedAt: updatedAt)
        }
    }

    public func loadAnimationScene(owsPath: String) throws -> AnimationSceneRecord? {
        guard let row = try querySingle(
            """
            SELECT ows_path, updated_at, data_json
            FROM animation_scenes
            WHERE project_id = ? AND ows_path = ?
            """,
            bind: [projectID.uuidString, owsPath]
        ) else {
            return nil
        }

        guard let path = row.string(at: 0),
              let updatedAt = row.date(at: 1),
              let dataJSON = row.data(at: 2) else {
            return nil
        }

        return AnimationSceneRecord(owsPath: path, updatedAt: updatedAt, dataJSON: dataJSON)
    }

    public func upsertAnimationScene(owsPath: String, dataJSON: Data, actorID: String?) throws {
        let now = Date()
        try execute(
            """
            INSERT INTO animation_scenes (animation_scene_id, project_id, ows_path, data_json, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(ows_path)
            DO UPDATE SET data_json = excluded.data_json, updated_at = excluded.updated_at
            """,
            bind: [UUID().uuidString, projectID.uuidString, owsPath, dataJSON, now]
        )
        try appendChange(entityType: "animation_scene", entityKey: owsPath, eventType: "upsert", actorID: actorID)
        try touchProject(updatedAt: now)
    }

    public func listCharacters() throws -> [CharacterRecord] {
        let rows = try queryRows(
            """
            SELECT character_id, name, directory_name, updated_at, data_json
            FROM characters
            WHERE project_id = ?
            ORDER BY name ASC
            """,
            bind: [projectID.uuidString]
        )

        return rows.compactMap { row in
            guard let characterIDString = row.string(at: 0),
                  let characterID = UUID(uuidString: characterIDString),
                  let name = row.string(at: 1),
                  let directoryName = row.string(at: 2),
                  let updatedAt = row.date(at: 3),
                  let dataJSON = row.data(at: 4) else {
                return nil
            }

            return CharacterRecord(
                characterID: characterID,
                name: name,
                directoryName: directoryName,
                updatedAt: updatedAt,
                dataJSON: dataJSON
            )
        }
    }

    public func listChanges(since changeID: Int64) throws -> [ChangeEvent] {
        let rows = try queryRows(
            """
            SELECT change_id, entity_type, entity_key, event_type, actor_id, created_at
            FROM change_events
            WHERE project_id = ? AND change_id > ?
            ORDER BY change_id ASC
            """,
            bind: [projectID.uuidString, changeID]
        )

        return rows.compactMap { row in
            guard let entityType = row.string(at: 1),
                  let entityKey = row.string(at: 2),
                  let eventType = row.string(at: 3),
                  let createdAt = row.date(at: 5) else {
                return nil
            }

            return ChangeEvent(
                changeID: row.int64(at: 0),
                entityType: entityType,
                entityKey: entityKey,
                eventType: eventType,
                actorID: row.string(at: 4),
                createdAt: createdAt
            )
        }
    }

    public func latestChangeID() throws -> Int64 {
        let row = try querySingle(
            """
            SELECT COALESCE(MAX(change_id), 0)
            FROM change_events
            WHERE project_id = ?
            """,
            bind: [projectID.uuidString]
        )
        return row?.int64(at: 0) ?? 0
    }

    private static func configureDatabase(db: OpaquePointer?) throws {
        try execute("PRAGMA journal_mode = WAL", db: db)
        try execute("PRAGMA foreign_keys = ON", db: db)

        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_info (
                version INTEGER NOT NULL
            )
            """,
            db: db
        )

        let currentVersion = try querySingle("SELECT version FROM schema_info LIMIT 1", db: db)?.int(at: 0) ?? 0
        if currentVersion == 0 {
            try execute("DELETE FROM schema_info", db: db)
            try execute("INSERT INTO schema_info (version) VALUES (?)", bind: [Self.schemaVersion], db: db)
            try createTables(db: db)
        } else if currentVersion != Self.schemaVersion {
            throw StoreError.sqlite("Unsupported schema version \(currentVersion)")
        } else {
            try createTables(db: db)
        }
    }

    private static func createTables(db: OpaquePointer?) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                project_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                imported_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            db: db
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS project_artifacts (
                project_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                data_json BLOB,
                updated_at REAL NOT NULL,
                PRIMARY KEY (project_id, kind)
            )
            """,
            db: db
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS songs (
                song_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                relative_path TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                canonical_title TEXT NOT NULL,
                notes TEXT NOT NULL,
                active_version_id TEXT,
                updated_at REAL NOT NULL,
                legacy_song_json BLOB NOT NULL,
                top_level_instrument_mappings_json BLOB
            )
            """,
            db: db
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS song_versions (
                version_id TEXT PRIMARY KEY,
                song_id TEXT NOT NULL,
                label TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                lyrics TEXT NOT NULL,
                save_type TEXT NOT NULL,
                user_label TEXT,
                is_bookmarked INTEGER NOT NULL DEFAULT 0,
                playback_json BLOB,
                legacy_version_json BLOB,
                note_count INTEGER NOT NULL DEFAULT 0,
                track_count INTEGER NOT NULL DEFAULT 0,
                length_ticks INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY(song_id) REFERENCES songs(song_id) ON DELETE CASCADE
            )
            """,
            db: db
        )

        try execute("CREATE INDEX IF NOT EXISTS idx_song_versions_song_id ON song_versions(song_id)", db: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_songs_project_path ON songs(project_id, relative_path)", db: db)

        try execute(
            """
            CREATE TABLE IF NOT EXISTS animation_scenes (
                animation_scene_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                ows_path TEXT NOT NULL UNIQUE,
                data_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            db: db
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS characters (
                character_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                name TEXT NOT NULL,
                directory_name TEXT NOT NULL,
                data_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            db: db
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS change_events (
                change_id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_key TEXT NOT NULL,
                event_type TEXT NOT NULL,
                actor_id TEXT,
                created_at REAL NOT NULL
            )
            """,
            db: db
        )
    }

    private func clearImportedData() throws {
        try execute("DELETE FROM project_artifacts")
        try execute("DELETE FROM song_versions")
        try execute("DELETE FROM songs")
        try execute("DELETE FROM animation_scenes")
        try execute("DELETE FROM characters")
        try execute("DELETE FROM change_events")
        try execute("DELETE FROM projects")
    }

    private func importProjectArtifacts(importedAt: Date) throws -> String {
        let paths = ProjectPaths(root: projectURL)
        let metadataURL = paths.projectJSON
        let instrumentsURL = paths.instrumentsJSON
        let writeCharactersURL = paths.charactersJSON
        let animateCharactersURL = paths.legacyCharactersJSON
        let indexURL = paths.indexJSON
        let animateMetadataURL = paths.animateJSON

        let metadataData = try? Data(contentsOf: metadataURL)
        let instrumentsData = try? Data(contentsOf: instrumentsURL)
        let charactersData = (try? Data(contentsOf: writeCharactersURL)) ?? (try? Data(contentsOf: animateCharactersURL))
        let indexData = try? Data(contentsOf: indexURL)
        let animateMetadataData = try? Data(contentsOf: animateMetadataURL)

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try upsertProjectArtifactRow(kind: .metadata, dataJSON: metadataData, updatedAt: importedAt)
            try upsertProjectArtifactRow(kind: .instruments, dataJSON: instrumentsData, updatedAt: importedAt)
            try upsertProjectArtifactRow(kind: .charactersFile, dataJSON: charactersData, updatedAt: importedAt)
            try upsertProjectArtifactRow(kind: .index, dataJSON: indexData, updatedAt: importedAt)
            try upsertProjectArtifactRow(kind: .animateMetadata, dataJSON: animateMetadataData, updatedAt: importedAt)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        if let metadataData,
           let root = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
           let name = root["name"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        return projectURL.deletingPathExtension().lastPathComponent
    }

    private func importSongs(importedAt: Date) throws -> (songs: Int, versions: Int) {
        let songURLs = try discoverSongURLs()
        var totalVersions = 0

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for songURL in songURLs {
                let data = try Data(contentsOf: songURL, options: .mappedIfSafe)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let songID = Self.parseUUID(root["songID"]) ?? UUID()
                let title = (root["title"] as? String) ?? songURL.deletingPathExtension().lastPathComponent
                let canonicalTitle = (root["canonicalTitle"] as? String) ?? title.lowercased()
                let notes = (root["notes"] as? String) ?? ""
                let updatedAt = Self.parseDate(root["updatedAt"]) ?? importedAt
                let activeVersionID = Self.parseUUID(root["activeVersionID"])
                let relativePath = songURL.path.replacingOccurrences(of: projectURL.path + "/", with: "")

                let topLevelInstrumentMappingsJSON = (root["instrumentMappings"]).flatMap(Self.jsonData)

                try execute(
                    """
                    INSERT INTO songs (
                        song_id, project_id, relative_path, title, canonical_title, notes,
                        active_version_id, updated_at, legacy_song_json, top_level_instrument_mappings_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bind: [
                        songID.uuidString,
                        projectID.uuidString,
                        relativePath,
                        title,
                        canonicalTitle,
                        notes,
                        activeVersionID?.uuidString,
                        updatedAt,
                        data,
                        topLevelInstrumentMappingsJSON
                    ]
                )

                let versions = (root["versions"] as? [[String: Any]]) ?? []
                totalVersions += versions.count
                for version in versions {
                    let versionID = Self.parseUUID(version["id"]) ?? UUID()
                    let label = (version["label"] as? String) ?? "Version"
                    let createdAt = Self.parseDate(version["createdAt"]) ?? updatedAt
                    let versionUpdatedAt = Self.parseDate(version["updatedAt"]) ?? updatedAt
                    let lyrics = (version["lyrics"] as? String) ?? ""
                    let saveType = (version["saveType"] as? String) ?? "manual"
                    let userLabel = version["userLabel"] as? String
                    let isBookmarked = (version["isBookmarked"] as? Bool) ?? false
                    let playbackJSON = version["playback"].flatMap(Self.jsonData) ?? version["playbackSnapshot"].flatMap(Self.jsonData)
                    let legacyVersionJSON = Self.jsonData(version)
                    let metrics = Self.extractPlaybackMetrics(from: playbackJSON)

                    try execute(
                        """
                        INSERT INTO song_versions (
                            version_id, song_id, label, created_at, updated_at, lyrics, save_type,
                            user_label, is_bookmarked, playback_json, legacy_version_json,
                            note_count, track_count, length_ticks
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bind: [
                            versionID.uuidString,
                            songID.uuidString,
                            label,
                            createdAt,
                            versionUpdatedAt,
                            lyrics,
                            saveType,
                            userLabel,
                            isBookmarked ? 1 : 0,
                            playbackJSON,
                            legacyVersionJSON,
                            metrics.noteCount,
                            metrics.trackCount,
                            metrics.lengthTicks
                        ]
                    )
                }

                if activeVersionID == nil,
                   let fallbackVersionID = versions.compactMap({ Self.parseUUID($0["id"]) }).first {
                    try execute(
                        """
                        UPDATE songs
                        SET active_version_id = ?
                        WHERE song_id = ?
                        """,
                        bind: [fallbackVersionID.uuidString, songID.uuidString]
                    )
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        return (songURLs.count, totalVersions)
    }

    private func importAnimationScenes(importedAt: Date) throws -> Int {
        let scenesURL = ProjectPaths(root: projectURL).animateScenesJSON
        guard FileManager.default.fileExists(atPath: scenesURL.path),
              let data = try? Data(contentsOf: scenesURL),
              let sceneArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for scene in sceneArray {
                let owsPath = (scene["owsSongPath"] as? String) ?? ""
                guard !owsPath.isEmpty else { continue }
                try execute(
                    """
                    INSERT INTO animation_scenes (animation_scene_id, project_id, ows_path, data_json, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    bind: [UUID().uuidString, projectID.uuidString, owsPath, Self.jsonData(scene), importedAt]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        return sceneArray.count
    }

    private func importCharacters(importedAt: Date) throws -> Int {
        let charactersData = try loadArtifact(.charactersFile)
        guard let charactersData,
              let root = try? JSONSerialization.jsonObject(with: charactersData) as? [String: Any],
              let characters = root["characters"] as? [[String: Any]] else {
            return 0
        }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for character in characters {
                let characterID = Self.parseUUID(character["id"]) ?? UUID()
                let name = (character["name"] as? String) ?? characterID.uuidString
                let directoryName = Self.directoryName(for: name, fallback: characterID.uuidString)
                try execute(
                    """
                    INSERT INTO characters (character_id, project_id, name, directory_name, data_json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bind: [characterID.uuidString, projectID.uuidString, name, directoryName, Self.jsonData(character), importedAt]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        return characters.count
    }

    private func discoverSongURLs() throws -> [URL] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var songURLs: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "ows" else { continue }
            songURLs.append(fileURL)
        }
        return songURLs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func upsertProjectRow(name: String, importedAt: Date, updatedAt: Date) throws {
        try execute(
            """
            INSERT INTO projects (project_id, name, imported_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(project_id)
            DO UPDATE SET name = excluded.name, imported_at = excluded.imported_at, updated_at = excluded.updated_at
            """,
            bind: [projectID.uuidString, name, importedAt, updatedAt]
        )
    }

    private func upsertProjectArtifactRow(kind: ProjectArtifactKind, dataJSON: Data?, updatedAt: Date) throws {
        try execute(
            """
            INSERT INTO project_artifacts (project_id, kind, data_json, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(project_id, kind)
            DO UPDATE SET data_json = excluded.data_json, updated_at = excluded.updated_at
            """,
            bind: [projectID.uuidString, kind.rawValue, dataJSON, updatedAt]
        )
    }

    private func appendChange(entityType: String, entityKey: String, eventType: String, actorID: String?) throws {
        try execute(
            """
            INSERT INTO change_events (project_id, entity_type, entity_key, event_type, actor_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bind: [projectID.uuidString, entityType, entityKey, eventType, actorID, Date()]
        )
    }

    private func touchProject(updatedAt: Date) throws {
        try execute(
            """
            UPDATE projects
            SET updated_at = ?
            WHERE project_id = ?
            """,
            bind: [updatedAt, projectID.uuidString]
        )
    }

    private static func selectProjectID(db: OpaquePointer?) throws -> UUID? {
        let row = try querySingle("SELECT project_id FROM projects LIMIT 1", db: db)
        guard let idString = row?.string(at: 0) else { return nil }
        return UUID(uuidString: idString)
    }

    private func count(table: String) throws -> Int {
        let row = try querySingle("SELECT COUNT(*) FROM \(table)")
        return row?.int(at: 0) ?? 0
    }

    private func execute(_ sql: String, bind: [Any?] = []) throws {
        try Self.execute(sql, bind: bind, db: db)
    }

    private static func execute(_ sql: String, bind: [Any?] = [], db: OpaquePointer?) throws {
        guard let db else { throw StoreError.sqlite("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastErrorMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        try bindValues(bind, to: statement)

        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw StoreError.sqlite(lastErrorMessage(db: db))
        }
    }

    private func querySingle(_ sql: String, bind: [Any?] = []) throws -> SQLiteRow? {
        try Self.querySingle(sql, bind: bind, db: db)
    }

    private func queryRows(_ sql: String, bind: [Any?] = []) throws -> [SQLiteRow] {
        try Self.queryRows(sql, bind: bind, db: db)
    }

    private static func querySingle(_ sql: String, bind: [Any?] = [], db: OpaquePointer?) throws -> SQLiteRow? {
        try queryRows(sql, bind: bind, db: db).first
    }

    private static func queryRows(_ sql: String, bind: [Any?] = [], db: OpaquePointer?) throws -> [SQLiteRow] {
        guard let db else { throw StoreError.sqlite("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastErrorMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        try bindValues(bind, to: statement)

        var rows: [SQLiteRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                rows.append(SQLiteRow(statement: statement))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw StoreError.sqlite(lastErrorMessage(db: db))
            }
        }
        return rows
    }

    private static func bindValues(_ bind: [Any?], to statement: OpaquePointer?) throws {
        for (index, value) in bind.enumerated() {
            let sqliteIndex = Int32(index + 1)
            switch value {
            case nil:
                sqlite3_bind_null(statement, sqliteIndex)
            case let string as String:
                sqlite3_bind_text(statement, sqliteIndex, string, -1, SQLITE_TRANSIENT)
            case let int as Int:
                sqlite3_bind_int64(statement, sqliteIndex, sqlite3_int64(int))
            case let int64 as Int64:
                sqlite3_bind_int64(statement, sqliteIndex, sqlite3_int64(int64))
            case let double as Double:
                sqlite3_bind_double(statement, sqliteIndex, double)
            case let bool as Bool:
                sqlite3_bind_int(statement, sqliteIndex, bool ? 1 : 0)
            case let date as Date:
                sqlite3_bind_double(statement, sqliteIndex, date.timeIntervalSince1970)
            case let data as Data:
                data.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        sqlite3_bind_blob(statement, sqliteIndex, nil, 0, SQLITE_TRANSIENT)
                        return
                    }
                    sqlite3_bind_blob(statement, sqliteIndex, baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            default:
                throw StoreError.sqlite("Unsupported SQLite bind value: \(String(describing: value))")
            }
        }
    }

    private static func lastErrorMessage(db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown sqlite error" }
        return String(cString: message)
    }

    private static func parseUUID(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return AmiraDateFormatter.parse(string) ?? AmiraDateFormatter.iso8601.date(from: string)
    }

    private static func jsonData(_ object: Any?) -> Data? {
        guard let object else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func directoryName(for name: String, fallback: String) -> String {
        let safe = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? fallback : safe
    }

    private static func extractPlaybackMetrics(from playbackJSON: Data?) -> (noteCount: Int, trackCount: Int, lengthTicks: Int) {
        guard let playbackJSON,
              let root = try? JSONSerialization.jsonObject(with: playbackJSON) as? [String: Any] else {
            return (0, 0, 0)
        }

        let notes = (root["notes"] as? [[String: Any]]) ?? []
        let noteCount = notes.count
        let trackIndices = Set(notes.compactMap { $0["trackIndex"] as? Int })
        let trackCount = trackIndices.count
        let lengthTicks = (root["lengthTicks"] as? Int) ?? notes.compactMap { note -> Int? in
            guard let startTick = note["startTick"] as? Int,
                  let duration = note["duration"] as? Int else { return nil }
            return startTick + duration
        }.max() ?? 0

        return (noteCount, trackCount, lengthTicks)
    }
}

private enum StoreError: Error, LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return message
        }
    }
}

private struct SQLiteRow {
    private let values: [SQLiteValue]

    init(statement: OpaquePointer?) {
        let count = Int(sqlite3_column_count(statement))
        var values: [SQLiteValue] = []
        values.reserveCapacity(count)

        for index in 0..<count {
            let type = sqlite3_column_type(statement, Int32(index))
            switch type {
            case SQLITE_INTEGER:
                values.append(.int64(sqlite3_column_int64(statement, Int32(index))))
            case SQLITE_FLOAT:
                values.append(.double(sqlite3_column_double(statement, Int32(index))))
            case SQLITE_TEXT:
                if let pointer = sqlite3_column_text(statement, Int32(index)) {
                    values.append(.string(String(cString: pointer)))
                } else {
                    values.append(.null)
                }
            case SQLITE_BLOB:
                let bytes = sqlite3_column_blob(statement, Int32(index))
                let length = Int(sqlite3_column_bytes(statement, Int32(index)))
                if let bytes, length > 0 {
                    values.append(.data(Data(bytes: bytes, count: length)))
                } else {
                    values.append(.data(Data()))
                }
            default:
                values.append(.null)
            }
        }

        self.values = values
    }

    func string(at index: Int) -> String? {
        guard index < values.count else { return nil }
        switch values[index] {
        case .string(let value): return value
        case .int64(let value): return String(value)
        case .double(let value): return String(value)
        case .null, .data: return nil
        }
    }

    func int(at index: Int) -> Int {
        Int(int64(at: index))
    }

    func int64(at index: Int) -> Int64 {
        guard index < values.count else { return 0 }
        switch values[index] {
        case .int64(let value): return value
        case .double(let value): return Int64(value)
        case .string(let value): return Int64(value) ?? 0
        case .null, .data: return 0
        }
    }

    func data(at index: Int) -> Data? {
        guard index < values.count else { return nil }
        switch values[index] {
        case .data(let value): return value
        case .null, .string, .int64, .double: return nil
        }
    }

    func date(at index: Int) -> Date? {
        guard index < values.count else { return nil }
        switch values[index] {
        case .double(let value): return Date(timeIntervalSince1970: value)
        case .int64(let value): return Date(timeIntervalSince1970: TimeInterval(value))
        case .string(let value):
            if let interval = Double(value) { return Date(timeIntervalSince1970: interval) }
            return nil
        case .null, .data:
            return nil
        }
    }
}

private enum SQLiteValue {
    case string(String)
    case int64(Int64)
    case double(Double)
    case data(Data)
    case null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
