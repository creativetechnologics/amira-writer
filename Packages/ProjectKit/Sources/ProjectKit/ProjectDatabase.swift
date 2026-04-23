import Foundation
import SQLite3

public actor ProjectDatabase {
    private static let storageFormatVersion = "2"
    public let projectURL: URL
    public let databaseURL: URL
    private let databaseDirectoryURL: URL

    private nonisolated(unsafe) var db: OpaquePointer?

    public init(projectURL: URL, databaseDirectoryURL: URL? = nil) {
        self.projectURL = projectURL
        self.databaseDirectoryURL = databaseDirectoryURL ?? ProjectPaths(root: projectURL).novotroDir
        self.databaseURL = self.databaseDirectoryURL.appendingPathComponent("project.sqlite")
    }


    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func ensureCurrentIndex(forceRebuild: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: databaseDirectoryURL,
            withIntermediateDirectories: true
        )
        try pruneLegacyIndexCache()
        try openIfNeeded()
        try createSchema()
        try migrateSchemaIfNeeded()

        if forceRebuild {
            let imported = try importLegacyProject()
            try replaceAll(with: imported)
        } else if try needsRebuild() {
            let imported = try importLegacyProject()
            try replaceAll(with: imported)
        }
        try trimWAL()
    }

    public func loadProjectSummary() throws -> NPProjectSummary {
        try openIfNeeded()

        guard let projectRow = try querySingle(
            "SELECT project_id, name, notes, created_at, updated_at, project_url FROM projects LIMIT 1"
        ) else {
            throw NSError(domain: "ProjectDatabase", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Project database is empty."
            ])
        }

        let scenes = try query(
            """
            SELECT
                s.scene_id,
                s.relative_path,
                s.title,
                s.order_index,
                s.updated_at,
                s.active_version_id,
                COALESCE(
                    (
                        SELECT v_active.lyrics
                        FROM scene_versions v_active
                        WHERE v_active.version_id = s.active_version_id
                        LIMIT 1
                    ),
                    (
                        SELECT v_latest.lyrics
                        FROM scene_versions v_latest
                        WHERE v_latest.scene_id = s.scene_id
                        ORDER BY v_latest.updated_at DESC, v_latest.created_at DESC, v_latest.sort_index ASC, v_latest.version_id ASC
                        LIMIT 1
                    ),
                    ''
                ),
                COALESCE(
                    (
                        SELECT v_active.note_count
                        FROM scene_versions v_active
                        WHERE v_active.version_id = s.active_version_id
                        LIMIT 1
                    ),
                    (
                        SELECT v_latest.note_count
                        FROM scene_versions v_latest
                        WHERE v_latest.scene_id = s.scene_id
                        ORDER BY v_latest.updated_at DESC, v_latest.created_at DESC, v_latest.sort_index ASC, v_latest.version_id ASC
                        LIMIT 1
                    ),
                    0
                ),
                COALESCE(
                    (
                        SELECT v_active.length_ticks
                        FROM scene_versions v_active
                        WHERE v_active.version_id = s.active_version_id
                        LIMIT 1
                    ),
                    (
                        SELECT v_latest.length_ticks
                        FROM scene_versions v_latest
                        WHERE v_latest.scene_id = s.scene_id
                        ORDER BY v_latest.updated_at DESC, v_latest.created_at DESC, v_latest.sort_index ASC, v_latest.version_id ASC
                        LIMIT 1
                    ),
                    0
                ),
                COALESCE(s.animate_track_count, 0),
                COALESCE(s.animate_keyframe_count, 0)
            FROM scenes s
            ORDER BY s.order_index ASC, s.relative_path ASC
            """
        ).map { row in
            NPSceneSummary(
                id: parseUUID(row[0]) ?? UUID(),
                relativePath: row[1] ?? "",
                title: row[2] ?? "",
                orderIndex: parseInt(row[3]),
                updatedAt: parseDate(row[4]),
                activeVersionID: parseUUID(row[5]),
                activeLyrics: row[6] ?? "",
                noteCount: parseInt(row[7]),
                lengthTicks: parseInt(row[8]),
                animateTrackCount: parseInt(row[9]),
                animateKeyframeCount: parseInt(row[10])
            )
        }

        return NPProjectSummary(
            id: parseUUID(projectRow[0]) ?? UUID(),
            name: projectRow[1] ?? projectURL.deletingPathExtension().lastPathComponent,
            notes: projectRow[2] ?? "",
            createdAt: parseDate(projectRow[3]),
            updatedAt: parseDate(projectRow[4]),
            projectURL: URL(fileURLWithPath: projectRow[5] ?? projectURL.path),
            scenes: scenes
        )
    }

    public func loadProject() throws -> NPProjectRecord {
        try openIfNeeded()

        guard let projectRow = try querySingle(
            "SELECT project_id, name, notes, created_at, updated_at, project_url FROM projects LIMIT 1"
        ) else {
            throw NSError(domain: "ProjectDatabase", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Project database is empty."
            ])
        }

        let projectFiles = try loadAllProjectFiles()
        let characters = try loadCharacters()
        let scenes = try loadProjectScenes()

        return NPProjectRecord(
            id: parseUUID(projectRow[0]) ?? UUID(),
            name: projectRow[1] ?? projectURL.deletingPathExtension().lastPathComponent,
            notes: projectRow[2] ?? "",
            createdAt: parseDate(projectRow[3]),
            updatedAt: parseDate(projectRow[4]),
            projectURL: URL(fileURLWithPath: projectRow[5] ?? projectURL.path),
            projectFiles: projectFiles,
            characters: characters,
            scenes: scenes
        )
    }

    public func loadCharacters() throws -> [NPCharacterRecord] {
        try openIfNeeded()
        return try query(
            "SELECT character_id, name, json_blob, updated_at FROM characters ORDER BY name ASC"
        ).map { row in
            NPCharacterRecord(
                id: parseUUID(row[0]) ?? UUID(),
                name: row[1] ?? "Character",
                jsonData: blobValue(row[2]),
                updatedAt: parseDate(row[3])
            )
        }
    }

    public func loadProjectScenes(
        includeVersions: Bool = true,
        includeRootJSON: Bool = true,
        includeAnimateSceneJSON: Bool = true,
        includeVersionJSON: Bool = true,
        includePlaybackJSON: Bool = true
    ) throws -> [NPSceneRecord] {
        try openIfNeeded()

        let rootColumn = includeRootJSON ? "root_json" : "NULL AS root_json"
        let animateColumn = includeAnimateSceneJSON ? "animate_scene_json" : "NULL AS animate_scene_json"

        let rows = try query(
            """
            SELECT
                scene_id,
                song_id,
                relative_path,
                title,
                canonical_title,
                notes,
                updated_at,
                active_version_id,
                order_index,
                \(rootColumn),
                \(animateColumn),
                animate_track_count,
                animate_keyframe_count
            FROM scenes
            ORDER BY order_index ASC, relative_path ASC
            """,
        )

        return try rows.map { row in
            let sceneID = parseUUID(row[0]) ?? UUID()
            return NPSceneRecord(
                id: sceneID,
                songID: parseUUID(row[1]) ?? sceneID,
                relativePath: row[2] ?? "",
                title: row[3] ?? "",
                canonicalTitle: row[4] ?? "",
                notes: row[5] ?? "",
                updatedAt: parseDate(row[6]),
                activeVersionID: parseUUID(row[7]),
                orderIndex: parseInt(row[8]),
                rootJSON: optionalBlobValue(row[9]),
                animateSceneJSON: optionalBlobValue(row[10]),
                animateTrackCount: parseInt(row[11]),
                animateKeyframeCount: parseInt(row[12]),
                versions: includeVersions
                    ? try loadSceneVersions(
                        sceneID: sceneID,
                        includeVersionJSON: includeVersionJSON,
                        includePlaybackJSON: includePlaybackJSON
                    )
                    : []
            )
        }
    }

    public func loadScene(
        relativePath: String,
        includeVersions: Bool = true,
        includeRootJSON: Bool = true,
        includeAnimateSceneJSON: Bool = true,
        includeVersionJSON: Bool = true,
        includePlaybackJSON: Bool = true
    ) throws -> NPSceneRecord? {
        try openIfNeeded()

        let rootColumn = includeRootJSON ? "root_json" : "NULL AS root_json"
        let animateColumn = includeAnimateSceneJSON ? "animate_scene_json" : "NULL AS animate_scene_json"

        guard let row = try querySingle(
            """
            SELECT
                scene_id,
                song_id,
                relative_path,
                title,
                canonical_title,
                notes,
                updated_at,
                active_version_id,
                order_index,
                \(rootColumn),
                \(animateColumn),
                animate_track_count,
                animate_keyframe_count
            FROM scenes
            WHERE relative_path = ?
            LIMIT 1
            """,
            binds: [.text(relativePath)]
        ) else {
            return nil
        }

        let sceneID = parseUUID(row[0]) ?? UUID()
        return NPSceneRecord(
            id: sceneID,
            songID: parseUUID(row[1]) ?? sceneID,
            relativePath: row[2] ?? "",
            title: row[3] ?? "",
            canonicalTitle: row[4] ?? "",
            notes: row[5] ?? "",
            updatedAt: parseDate(row[6]),
            activeVersionID: parseUUID(row[7]),
            orderIndex: parseInt(row[8]),
            rootJSON: optionalBlobValue(row[9]),
            animateSceneJSON: optionalBlobValue(row[10]),
            animateTrackCount: parseInt(row[11]),
            animateKeyframeCount: parseInt(row[12]),
            versions: includeVersions
                ? try loadSceneVersions(
                    sceneID: sceneID,
                    includeVersionJSON: includeVersionJSON,
                    includePlaybackJSON: includePlaybackJSON
                )
                : []
        )
    }

    public func currentChangeToken() throws -> Int64 {
        try openIfNeeded()
        guard let row = try querySingle("SELECT COALESCE(MAX(change_id), 0) FROM change_log") else {
            return 0
        }
        return Int64(parseInt(row[0]))
    }

    public func listChanges(since changeID: Int64) throws -> [ChangeEvent] {
        try openIfNeeded()
        return try query(
            """
            SELECT change_id, scope, entity_id, kind, actor_id, created_at
            FROM change_log
            WHERE change_id > ?
            ORDER BY change_id ASC
            """,
            binds: [.int(Int(changeID))]
        ).compactMap { row in
            guard let createdAt = Self.parseDate(row[5]) else { return nil }
            return ChangeEvent(
                changeID: Int64(parseInt(row[0])),
                entityType: row[1] ?? "",
                entityKey: row[2] ?? "",
                eventType: row[3] ?? "",
                actorID: row[4],
                createdAt: createdAt
            )
        }
    }

    public func exportLegacy() throws {
        let project = try loadProject()
        try exportProject(project)
    }

    public func refreshLegacyFingerprint() throws {
        try openIfNeeded()
        let fingerprint = try legacyFingerprint()
        try execute(
            """
            INSERT INTO metadata(key, value)
            VALUES ('legacy_fingerprint', ?)
            ON CONFLICT(key)
            DO UPDATE SET value = excluded.value
            """,
            binds: [.text(fingerprint)]
        )
        try execute(
            """
            INSERT INTO metadata(key, value)
            VALUES ('storage_format_version', ?)
            ON CONFLICT(key)
            DO UPDATE SET value = excluded.value
            """,
            binds: [.text(Self.storageFormatVersion)]
        )
    }

    public func loadProjectFile(path: String) throws -> NPProjectFileRecord? {
        try openIfNeeded()
        guard let row = try querySingle(
            "SELECT path, json_blob FROM project_files WHERE path = ? LIMIT 1",
            binds: [.text(path)]
        ) else {
            guard let fileURL = projectFileURL(for: path),
                  FileManager.default.fileExists(atPath: fileURL.path),
                  fileURL.hasDirectoryPath == false else {
                return nil
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            return NPProjectFileRecord(path: path, jsonData: data)
        }

        return NPProjectFileRecord(
            path: row[0] ?? path,
            jsonData: blobValue(row[1])
        )
    }

    private func loadAllProjectFiles() throws -> [NPProjectFileRecord] {
        try query(
            "SELECT path, json_blob FROM project_files ORDER BY path ASC"
        ).map { row in
            NPProjectFileRecord(
                path: row[0] ?? "",
                jsonData: blobValue(row[1])
            )
        }
    }

    private func loadSceneVersions(
        sceneID: UUID,
        includeVersionJSON: Bool,
        includePlaybackJSON: Bool
    ) throws -> [NPSceneVersionRecord] {
        let versionColumn = includeVersionJSON ? "version_json" : "NULL AS version_json"
        let playbackColumn = includePlaybackJSON ? "playback_json" : "NULL AS playback_json"

        return try query(
            """
            SELECT
                version_id,
                sort_index,
                label,
                save_type,
                user_label,
                is_bookmarked,
                created_at,
                updated_at,
                lyrics,
                \(versionColumn),
                \(playbackColumn),
                note_count,
                length_ticks
            FROM scene_versions
            WHERE scene_id = ?
            ORDER BY sort_index ASC, updated_at DESC, created_at DESC, version_id ASC
            """,
            binds: [.text(sceneID.uuidString)]
        ).map { row in
            NPSceneVersionRecord(
                id: parseUUID(row[0]) ?? UUID(),
                sortIndex: parseInt(row[1]),
                label: row[2] ?? "Version",
                saveType: row[3] ?? "manual",
                userLabel: row[4],
                isBookmarked: parseInt(row[5]) != 0,
                createdAt: parseDate(row[6]),
                updatedAt: parseDate(row[7]),
                lyrics: row[8] ?? "",
                versionJSON: optionalBlobValue(row[9]),
                playbackJSON: optionalBlobValue(row[10]),
                noteCount: parseInt(row[11]),
                lengthTicks: parseInt(row[12])
            )
        }
    }

    public func upsertProjectFile(path: String, jsonData: Data, actorID: String = "system") throws {
        try openIfNeeded()
        try execute(
            """
            INSERT INTO project_files(path, json_blob)
            VALUES(?, ?)
            ON CONFLICT(path)
            DO UPDATE SET json_blob = excluded.json_blob
            """,
            binds: [.text(path), .blob(jsonData)]
        )
        try syncProjectRowIfNeeded(forProjectFilePath: path, jsonData: jsonData)
        try syncCharactersIfNeeded(forProjectFilePath: path, jsonData: jsonData)
        try recordChange(scope: "project_file", entityID: path, kind: "upsert", actorID: actorID)
    }

    public func updateSongText(
        relativePath: String,
        lyrics: String,
        versionID: UUID? = nil,
        actorID: String = "system"
    ) throws {
        try openIfNeeded()
        guard var scene = try loadScene(relativePath: relativePath) else {
            throw missingSceneError(relativePath: relativePath)
        }
        let now = Date()

        let targetVersionID = versionID ?? scene.activeVersionID
        if let targetVersionID,
           let index = scene.versions.firstIndex(where: { $0.id == targetVersionID }) {
            scene.activeVersionID = targetVersionID
            scene.versions[index].lyrics = lyrics
            scene.versions[index].updatedAt = now
        } else if let index = scene.versions.indices.first {
            scene.activeVersionID = scene.versions[index].id
            scene.versions[index].lyrics = lyrics
            scene.versions[index].updatedAt = now
        }

        scene.updatedAt = now
        try upsertScene(scene, actorID: actorID)
    }

    public func updateSongPlayback(
        relativePath: String,
        versionID: UUID? = nil,
        playbackJSON: Data?,
        actorID: String = "system"
    ) throws {
        try openIfNeeded()
        guard var scene = try loadScene(relativePath: relativePath) else {
            throw missingSceneError(relativePath: relativePath)
        }
        let targetVersionID = versionID ?? scene.activeVersionID ?? scene.versions.first?.id
        guard let targetVersionID,
              let index = scene.versions.firstIndex(where: { $0.id == targetVersionID }) else {
            return
        }

        let metrics = summarizePlaybackJSON(playbackJSON)
        scene.versions[index].playbackJSON = playbackJSON
        scene.versions[index].noteCount = metrics.noteCount
        scene.versions[index].lengthTicks = metrics.lengthTicks
        scene.versions[index].updatedAt = Date()
        scene.updatedAt = scene.versions[index].updatedAt
        try upsertScene(scene, actorID: actorID)
    }

    public func upsertAnimationScene(owsPath: String, jsonData: Data, actorID: String = "system") throws {
        try openIfNeeded()
        guard var scene = try loadScene(relativePath: owsPath) else {
            throw missingSceneError(relativePath: owsPath)
        }
        let counts = summarizeAnimateScene(jsonData)
        scene.animateSceneJSON = jsonData
        scene.animateTrackCount = counts.0
        scene.animateKeyframeCount = counts.1
        scene.updatedAt = Date()
        try upsertScene(scene, actorID: actorID)
    }

    public func upsertScene(_ scene: NPSceneRecord, actorID: String = "system") throws {
        try openIfNeeded()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute(
                """
                INSERT INTO scenes(
                    scene_id, song_id, relative_path, title, canonical_title, notes, updated_at,
                    active_version_id, order_index, root_json, animate_scene_json,
                    animate_track_count, animate_keyframe_count
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(relative_path)
                DO UPDATE SET
                    scene_id = excluded.scene_id,
                    song_id = excluded.song_id,
                    title = excluded.title,
                    canonical_title = excluded.canonical_title,
                    notes = excluded.notes,
                    updated_at = excluded.updated_at,
                    active_version_id = excluded.active_version_id,
                    order_index = excluded.order_index,
                    root_json = excluded.root_json,
                    animate_scene_json = excluded.animate_scene_json,
                    animate_track_count = excluded.animate_track_count,
                    animate_keyframe_count = excluded.animate_keyframe_count
                """,
                binds: [
                    .text(scene.id.uuidString),
                    .text(scene.songID.uuidString),
                    .text(scene.relativePath),
                    .text(scene.title),
                    .text(scene.canonicalTitle),
                    .text(scene.notes),
                    .text(Self.isoFormatter.string(from: scene.updatedAt)),
                    bindUUID(scene.activeVersionID),
                    .int(scene.orderIndex),
                    bindBlob(scene.rootJSON),
                    bindBlob(scene.animateSceneJSON),
                    .int(scene.animateTrackCount),
                    .int(scene.animateKeyframeCount),
                ]
            )

            try execute("DELETE FROM scene_versions WHERE scene_id = ?", binds: [.text(scene.id.uuidString)])

            for version in scene.versions {
                try execute(
                    """
                    INSERT INTO scene_versions(
                        version_id, scene_id, label, save_type, user_label, is_bookmarked,
                        sort_index, created_at, updated_at, lyrics, version_json, playback_json, note_count, length_ticks
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    binds: [
                        .text(version.id.uuidString),
                        .text(scene.id.uuidString),
                        .text(version.label),
                        .text(version.saveType),
                        bindText(version.userLabel),
                        .int(version.isBookmarked ? 1 : 0),
                        .int(version.sortIndex),
                        .text(Self.isoFormatter.string(from: version.createdAt)),
                        .text(Self.isoFormatter.string(from: version.updatedAt)),
                        .text(version.lyrics),
                        bindBlob(version.versionJSON),
                        bindBlob(version.playbackJSON),
                        .int(version.noteCount),
                        .int(version.lengthTicks),
                    ]
                )
            }

            try recordChange(scope: "scene", entityID: scene.relativePath, kind: "upsert", actorID: actorID)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func missingSceneError(relativePath: String) -> NSError {
        NSError(
            domain: "ProjectDatabase",
            code: 30,
            userInfo: [NSLocalizedDescriptionKey: "Could not find scene for \(relativePath)."]
        )
    }

    public func recordChange(scope: String, entityID: String, kind: String, actorID: String = "system") throws {
        try openIfNeeded()
        try execute(
            """
            INSERT INTO change_log(scope, entity_id, kind, actor_id, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            binds: [
                .text(scope),
                .text(entityID),
                .text(kind),
                .text(actorID),
                .text(Self.isoFormatter.string(from: Date()))
            ]
        )
    }

    // MARK: - Schema

    private func createSchema() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA wal_autocheckpoint = 1000")
        try execute("PRAGMA foreign_keys = ON")

        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS projects(
                project_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                notes TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                project_url TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS project_files(
                path TEXT PRIMARY KEY,
                json_blob BLOB NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS characters(
                character_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                json_blob BLOB NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS scenes(
                scene_id TEXT PRIMARY KEY,
                song_id TEXT NOT NULL,
                relative_path TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                canonical_title TEXT NOT NULL,
                notes TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                active_version_id TEXT,
                order_index INTEGER NOT NULL,
                root_json BLOB,
                animate_scene_json BLOB,
                animate_track_count INTEGER NOT NULL DEFAULT 0,
                animate_keyframe_count INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS scene_versions(
                version_id TEXT PRIMARY KEY,
                scene_id TEXT NOT NULL,
                label TEXT NOT NULL,
                save_type TEXT NOT NULL,
                user_label TEXT,
                is_bookmarked INTEGER NOT NULL DEFAULT 0,
                sort_index INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                lyrics TEXT NOT NULL,
                version_json BLOB,
                playback_json BLOB,
                note_count INTEGER NOT NULL DEFAULT 0,
                length_ticks INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY(scene_id) REFERENCES scenes(scene_id) ON DELETE CASCADE
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS change_log(
                change_id INTEGER PRIMARY KEY AUTOINCREMENT,
                scope TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                actor_id TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_scene_versions_scene_id ON scene_versions(scene_id)")
    }

    private func migrateSchemaIfNeeded() throws {
        if try columnExists(table: "scene_versions", column: "sort_index") == false {
            try execute("ALTER TABLE scene_versions ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0")
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_scene_versions_scene_sort ON scene_versions(scene_id, sort_index)")
    }

    // MARK: - Import

    private func needsRebuild() throws -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return true }
        let storedFormatVersion = try querySingle(
            "SELECT value FROM metadata WHERE key = 'storage_format_version'"
        )?[0]
        guard storedFormatVersion == Self.storageFormatVersion else { return true }

        let currentFingerprint = try legacyFingerprint()
        let stored = try querySingle("SELECT value FROM metadata WHERE key = 'legacy_fingerprint'")?[0]
        return stored != currentFingerprint
    }

    private func importLegacyProject() throws -> NPProjectRecord {
        let fm = FileManager.default
        let projectID = UUID()
        let defaultName = projectURL.deletingPathExtension().lastPathComponent
        let now = Date()

        var name = defaultName
        var notes = ""
        var createdAt = now
        var updatedAt = now
        var projectFiles: [NPProjectFileRecord] = []
        var characters: [NPCharacterRecord] = []
        var scenes: [NPSceneRecord] = []

        let candidateProjectFiles = try enumerateAuxiliaryProjectFiles()

        var animateSceneMap: [String: Data] = [:]

        for relative in candidateProjectFiles {
            let fileURL = projectURL.appendingPathComponent(relative)
            guard fm.fileExists(atPath: fileURL.path) else { continue }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            projectFiles.append(.init(path: relative, jsonData: data))

            if isMetadataProjectFile(relative),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                name = root["name"] as? String ?? name
                notes = root["notes"] as? String ?? notes
                createdAt = Self.parseDate(root["createdAt"]) ?? createdAt
                updatedAt = Self.parseDate(root["updatedAt"]) ?? updatedAt
            }

            if isCharactersProjectFile(relative),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let charArray = root["characters"] as? [[String: Any]] {
                for entry in charArray {
                    let id = Self.parseUUID(entry["id"]) ?? UUID()
                    let charData = try jsonData(from: entry)
                    let charName = entry["name"] as? String ?? id.uuidString
                    characters.append(
                        NPCharacterRecord(
                            id: id,
                            name: charName,
                            jsonData: charData,
                            updatedAt: updatedAt
                        )
                    )
                }
            }

            if relative == Self.animateScenesPath,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sceneMap = root["scenes"] as? [String: Any] {
                for (key, value) in sceneMap {
                    if let dict = value as? [String: Any], let sceneData = try? jsonData(from: dict) {
                        let path = dict["owpSongPath"] as? String ?? dict["owsSongPath"] as? String ?? key
                        animateSceneMap[path] = sceneData
                    }
                }
            } else if relative == Self.animateScenesPath,
                      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for entry in array {
                    let path = entry["owpSongPath"] as? String ?? entry["owsSongPath"] as? String ?? UUID().uuidString
                    if let sceneData = try? jsonData(from: entry) {
                        animateSceneMap[path] = sceneData
                    }
                }
            }
        }

        let songsRoot = ProjectPaths(root: projectURL).songs
        let songURLs = try enumerateSongFiles(in: songsRoot)
        for (index, songURL) in songURLs.enumerated() {
            let relativePath = relativePath(for: songURL)
            let data = try Data(contentsOf: songURL, options: .mappedIfSafe)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let songID = Self.parseUUID(root["songID"]) ?? UUID()
            let sceneID = songID
            let title = root["title"] as? String ?? songURL.deletingPathExtension().lastPathComponent
            let canonicalTitle = root["canonicalTitle"] as? String ?? title.lowercased()
            let sceneNotes = root["notes"] as? String ?? ""
            let sceneUpdatedAt = Self.parseDate(root["updatedAt"]) ?? updatedAt
            let activeVersionID = Self.parseUUID(root["activeVersionID"])
            var compactRoot = root
            let versionArray = compactRoot["versions"] as? [[String: Any]]
            compactRoot.removeValue(forKey: "versions")
            let rootJSON = try? jsonData(from: compactRoot)
            let animateJSON = animateSceneMap[relativePath]

            let (animateTrackCount, animateKeyframeCount) = summarizeAnimateScene(animateJSON)

            var versions: [NPSceneVersionRecord] = []
            if let versionArray {
                for (versionIndex, entry) in versionArray.enumerated() {
                    var compactEntry = entry
                    let versionID = Self.parseUUID(compactEntry["id"]) ?? UUID()
                    let label = compactEntry["label"] as? String ?? "Version"
                    let saveType = compactEntry["saveType"] as? String ?? "manual"
                    let userLabel = compactEntry["userLabel"] as? String
                    let isBookmarked = compactEntry["isBookmarked"] as? Bool ?? false
                    let createdAt = Self.parseDate(compactEntry["createdAt"]) ?? sceneUpdatedAt
                    let updatedAt = Self.parseDate(compactEntry["updatedAt"]) ?? sceneUpdatedAt
                    let lyrics = compactEntry["lyrics"] as? String ?? ""
                    let playbackObject = (compactEntry["playback"] as? [String: Any])
                        ?? (compactEntry["playbackSnapshot"] as? [String: Any])
                    compactEntry.removeValue(forKey: "lyrics")
                    compactEntry.removeValue(forKey: "playback")
                    compactEntry.removeValue(forKey: "playbackSnapshot")
                    let versionJSON = try? jsonData(from: compactEntry)
                    let playbackJSON = playbackObject.flatMap { try? jsonData(from: $0) }
                    let (noteCount, lengthTicks) = summarizePlayback(playbackObject)

                    versions.append(
                        NPSceneVersionRecord(
                            id: versionID,
                            sortIndex: versionIndex,
                            label: label,
                            saveType: saveType,
                            userLabel: userLabel,
                            isBookmarked: isBookmarked,
                            createdAt: createdAt,
                            updatedAt: updatedAt,
                            lyrics: lyrics,
                            versionJSON: versionJSON,
                            playbackJSON: playbackJSON,
                            noteCount: noteCount,
                            lengthTicks: lengthTicks
                        )
                    )
                }
            }

            scenes.append(
                NPSceneRecord(
                    id: sceneID,
                    songID: songID,
                    relativePath: relativePath,
                    title: title,
                    canonicalTitle: canonicalTitle,
                    notes: sceneNotes,
                    updatedAt: sceneUpdatedAt,
                    activeVersionID: activeVersionID,
                    orderIndex: index,
                    rootJSON: rootJSON,
                    animateSceneJSON: animateJSON,
                    animateTrackCount: animateTrackCount,
                    animateKeyframeCount: animateKeyframeCount,
                    versions: versions
                )
            )
        }

        return NPProjectRecord(
            id: projectID,
            name: name,
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            projectURL: projectURL,
            projectFiles: projectFiles,
            characters: characters,
            scenes: scenes
        )
    }

    private func replaceAll(with project: NPProjectRecord) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM change_log")
            try execute("DELETE FROM scene_versions")
            try execute("DELETE FROM scenes")
            try execute("DELETE FROM characters")
            try execute("DELETE FROM project_files")
            try execute("DELETE FROM projects")
            try execute("DELETE FROM metadata")

            try execute(
                """
                INSERT INTO projects(project_id, name, notes, created_at, updated_at, project_url)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                binds: [
                    .text(project.id.uuidString),
                    .text(project.name),
                    .text(project.notes),
                    .text(Self.isoFormatter.string(from: project.createdAt)),
                    .text(Self.isoFormatter.string(from: project.updatedAt)),
                    .text(project.projectURL.path)
                ]
            )

            let fingerprint = try legacyFingerprint()
            try execute(
                "INSERT INTO metadata(key, value) VALUES ('legacy_fingerprint', ?)",
                binds: [.text(fingerprint)]
            )
            try execute(
                "INSERT INTO metadata(key, value) VALUES ('schema_version', '1')"
            )
            try execute(
                "INSERT INTO metadata(key, value) VALUES ('storage_format_version', ?)",
                binds: [.text(Self.storageFormatVersion)]
            )

            for file in project.projectFiles {
                try execute(
                    "INSERT INTO project_files(path, json_blob) VALUES (?, ?)",
                    binds: [.text(file.path), .blob(file.jsonData)]
                )
            }

            for character in project.characters {
                try execute(
                    """
                    INSERT INTO characters(character_id, name, json_blob, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    binds: [
                        .text(character.id.uuidString),
                        .text(character.name),
                        .blob(character.jsonData),
                        .text(Self.isoFormatter.string(from: character.updatedAt))
                    ]
                )
            }

            for scene in project.scenes {
                try execute(
                    """
                    INSERT INTO scenes(
                        scene_id, song_id, relative_path, title, canonical_title, notes, updated_at,
                        active_version_id, order_index, root_json, animate_scene_json,
                        animate_track_count, animate_keyframe_count
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    binds: [
                        .text(scene.id.uuidString),
                        .text(scene.songID.uuidString),
                        .text(scene.relativePath),
                        .text(scene.title),
                        .text(scene.canonicalTitle),
                        .text(scene.notes),
                        .text(Self.isoFormatter.string(from: scene.updatedAt)),
                        bindUUID(scene.activeVersionID),
                        .int(scene.orderIndex),
                        bindBlob(scene.rootJSON),
                        bindBlob(scene.animateSceneJSON),
                        .int(scene.animateTrackCount),
                        .int(scene.animateKeyframeCount)
                    ]
                )

                for version in scene.versions {
                    try execute(
                    """
                    INSERT INTO scene_versions(
                        version_id, scene_id, label, save_type, user_label, is_bookmarked,
                        sort_index, created_at, updated_at, lyrics, version_json, playback_json, note_count, length_ticks
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    binds: [
                        .text(version.id.uuidString),
                        .text(scene.id.uuidString),
                        .text(version.label),
                        .text(version.saveType),
                        bindText(version.userLabel),
                        .int(version.isBookmarked ? 1 : 0),
                        .int(version.sortIndex),
                        .text(Self.isoFormatter.string(from: version.createdAt)),
                        .text(Self.isoFormatter.string(from: version.updatedAt)),
                        .text(version.lyrics),
                            bindBlob(version.versionJSON),
                            bindBlob(version.playbackJSON),
                            .int(version.noteCount),
                            .int(version.lengthTicks)
                        ]
                    )
                }
            }

            try recordChange(scope: "project", entityID: project.id.uuidString, kind: "rebuild-index")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Export

    private func exportProject(_ project: NPProjectRecord) throws {
        let fm = FileManager.default
        for file in project.projectFiles where file.path != "Scenes/scenes.json" && file.path != "Animate/scenes.json" {
            let destination = project.projectURL.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.jsonData.write(to: destination, options: .atomic)
        }

        for scene in project.scenes {
            let destination = project.projectURL.appendingPathComponent(scene.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let patched = try exportedSceneJSON(scene)
            try patched.write(to: destination, options: .atomic)
        }

        if let charactersFile = project.projectFile(at: "Characters/characters.json") ?? project.projectFile(at: "characters.json") {
            let destination = project.projectURL.appendingPathComponent(charactersFile.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try charactersFile.jsonData.write(to: destination, options: .atomic)
        }

        let animatedSceneData = project.scenes.compactMap { scene -> [String: Any]? in
            guard let animateSceneJSON = scene.animateSceneJSON,
                  let object = try? JSONSerialization.jsonObject(with: animateSceneJSON) as? [String: Any] else {
                return nil
            }
            return object
        }

        if !animatedSceneData.isEmpty {
            let destination = ProjectPaths(root: project.projectURL).animateScenesJSON
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: animatedSceneData, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic)
        } else if let animateScenesFile = project.projectFile(at: "Scenes/scenes.json") ?? project.projectFile(at: "Animate/scenes.json") {
            let destination = project.projectURL.appendingPathComponent(animateScenesFile.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try animateScenesFile.jsonData.write(to: destination, options: .atomic)
        }
    }

    private func exportedSceneJSON(_ scene: NPSceneRecord) throws -> Data {
        var root = (scene.rootJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        root["songID"] = scene.songID.uuidString
        root["title"] = scene.title
        root["canonicalTitle"] = scene.canonicalTitle
        root["notes"] = scene.notes
        root["updatedAt"] = Self.isoFormatter.string(from: scene.updatedAt)
        root["activeVersionID"] = scene.activeVersionID?.uuidString

        let sortedVersions = scene.versions.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var versionObjects: [[String: Any]] = []
        for version in sortedVersions {
            var entry = (version.versionJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            entry["id"] = version.id.uuidString
            entry["label"] = version.label
            entry["createdAt"] = Self.isoFormatter.string(from: version.createdAt)
            entry["updatedAt"] = Self.isoFormatter.string(from: version.updatedAt)
            entry["lyrics"] = version.lyrics
            entry["saveType"] = version.saveType
            entry["isBookmarked"] = version.isBookmarked
            if let userLabel = version.userLabel {
                entry["userLabel"] = userLabel
            } else {
                entry.removeValue(forKey: "userLabel")
            }

            if let playbackJSON = version.playbackJSON,
               let playbackObject = try JSONSerialization.jsonObject(with: playbackJSON) as? [String: Any] {
                entry["playback"] = playbackObject
                entry["playbackSnapshot"] = playbackObject
            }

            versionObjects.append(entry)
        }

        root["versions"] = versionObjects
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - SQLite

    private func openIfNeeded() throws {
        guard db == nil else { return }
        var pointer: OpaquePointer?
        if sqlite3_open(databaseURL.path, &pointer) != SQLITE_OK {
            let message = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let pointer {
                sqlite3_close(pointer)
            }
            throw NSError(domain: "ProjectDatabase", code: 2, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        sqlite3_busy_timeout(pointer, 5000)
        db = pointer
    }

    private enum SQLiteBind {
        case text(String)
        case int(Int)
        case blob(Data)
        case null
    }

    private func execute(_ sql: String, binds: [SQLiteBind] = []) throws {
        guard let db else { throw databaseClosedError() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw sqliteError(db)
        }
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        try query("PRAGMA table_info(\(table))").contains { row in
            row.indices.contains(1) && row[1] == column
        }
    }

    private func query(_ sql: String, binds: [SQLiteBind] = []) throws -> [[String?]] {
        guard let db else { throw databaseClosedError() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)

        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = Int(sqlite3_column_count(statement))
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let type = sqlite3_column_type(statement, Int32(index))
                switch type {
                case SQLITE_NULL:
                    row.append(nil)
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(statement, Int32(index))
                    let length = Int(sqlite3_column_bytes(statement, Int32(index)))
                    if let bytes, length > 0 {
                        let data = Data(bytes: bytes, count: length)
                        row.append(data.base64EncodedString())
                    } else {
                        row.append(Data().base64EncodedString())
                    }
                default:
                    row.append(String(cString: sqlite3_column_text(statement, Int32(index))))
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func querySingle(_ sql: String, binds: [SQLiteBind] = []) throws -> [String?]? {
        try query(sql, binds: binds).first
    }

    private func bind(_ binds: [SQLiteBind], to statement: OpaquePointer?) throws {
        for (index, bind) in binds.enumerated() {
            let position = Int32(index + 1)
            switch bind {
            case let .text(value):
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case let .int(value):
                sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case let .blob(data):
                data.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
    }

    private func sqliteError(_ db: OpaquePointer) -> NSError {
        NSError(domain: "ProjectDatabase", code: 3, userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))
        ])
    }

    private func databaseClosedError() -> NSError {
        NSError(domain: "ProjectDatabase", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Database is not open."
        ])
    }

    // MARK: - Helpers

    private func legacyFingerprint() throws -> String {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var parts: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let relative = relativePath(for: fileURL)
            if relative.hasPrefix(".novotro/") { continue }
            guard fileURL.hasDirectoryPath == false else { continue }
            guard isPrimarySongPath(relative) || isCanonicalProjectFile(relative) else { continue }
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values.fileSize ?? 0
            let date = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            parts.append("\(relative)|\(size)|\(date)")
        }
        return parts.sorted().joined(separator: "\n")
    }

    private func enumerateSongFiles(in songsRoot: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: songsRoot.path) else { return [] }
        let enumerator = fm.enumerator(at: songsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension.lowercased() == "ows" {
                files.append(fileURL)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func enumerateAuxiliaryProjectFiles() throws -> [String] {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: projectURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var files: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.hasDirectoryPath == false else { continue }
            let relative = relativePath(for: fileURL)
            guard relative.hasPrefix(".novotro/") == false else { continue }
            guard isPrimarySongPath(relative) == false else { continue }
            guard isCanonicalProjectFile(relative) else { continue }
            files.append(relative)
        }

        return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func summarizePlayback(_ object: [String: Any]?) -> (Int, Int) {
        guard let object else { return (0, 0) }
        let noteCount = (object["notes"] as? [[String: Any]])?.count ?? 0
        let lengthTicks = object["lengthTicks"] as? Int ?? 0
        return (noteCount, lengthTicks)
    }

    private func summarizePlaybackJSON(_ data: Data?) -> (noteCount: Int, lengthTicks: Int) {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0)
        }
        return summarizePlayback(object)
    }

    private func summarizeAnimateScene(_ data: Data?) -> (Int, Int) {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0)
        }

        if let tracks = root["tracks"] as? [String: Any] {
            let keyframeCount = tracks.values.reduce(0) { partial, value in
                guard let track = value as? [String: Any],
                      let keyframes = track["keyframes"] as? [[String: Any]] else {
                    return partial
                }
                return partial + keyframes.count
            }
            return (tracks.count, keyframeCount)
        }

        return (0, 0)
    }

    private func syncProjectRowIfNeeded(forProjectFilePath path: String, jsonData: Data) throws {
        guard isMetadataProjectFile(path),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let row = try querySingle("SELECT project_id, project_url FROM projects LIMIT 1") else {
            return
        }

        let projectID = row[0] ?? UUID().uuidString
        let projectPath = row[1] ?? projectURL.path
        let name = (root["name"] as? String) ?? projectURL.deletingPathExtension().lastPathComponent
        let notes = (root["notes"] as? String) ?? ""
        let createdAt = Self.parseDate(root["createdAt"]) ?? Date()
        let updatedAt = Self.parseDate(root["updatedAt"]) ?? Date()

        try execute(
            """
            UPDATE projects
            SET name = ?, notes = ?, created_at = ?, updated_at = ?, project_url = ?
            WHERE project_id = ?
            """,
            binds: [
                .text(name),
                .text(notes),
                .text(Self.isoFormatter.string(from: createdAt)),
                .text(Self.isoFormatter.string(from: updatedAt)),
                .text(projectPath),
                .text(projectID),
            ]
        )
    }

    private func syncCharactersIfNeeded(forProjectFilePath path: String, jsonData data: Data) throws {
        guard isCharactersProjectFile(path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let charArray = root["characters"] as? [[String: Any]] else {
            return
        }

        let updatedAt = Self.parseDate(root["updatedAt"]) ?? Date()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM characters")
            for entry in charArray {
                let id = Self.parseUUID(entry["id"]) ?? UUID()
                let charData = try jsonData(from: entry)
                let charName = entry["name"] as? String ?? id.uuidString
                try execute(
                    """
                    INSERT INTO characters(character_id, name, json_blob, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    binds: [
                        .text(id.uuidString),
                        .text(charName),
                        .blob(charData),
                        .text(Self.isoFormatter.string(from: updatedAt)),
                    ]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func isPrimarySongPath(_ relativePath: String) -> Bool {
        relativePath.hasPrefix("Songs/") && relativePath.hasSuffix(".ows")
    }

    private func isCanonicalProjectFile(_ relativePath: String) -> Bool {
        // Legacy root-level Instruments.json kept for back-compat; canonical post-Wave-D is Settings/instruments.json.
        if relativePath == "index.json" || relativePath == "Instruments.json" {
            return true
        }
        if isMetadataProjectFile(relativePath) || isCharactersProjectFile(relativePath) {
            return true
        }
        let managedPrefixes = [
            "Metadata/",
            "Characters/",
            "Animate/",
            "Scenes/",    // Wave D
            "Places/",    // Wave D
            "Settings/",  // Wave D (includes instruments.json, api-credentials.json, project-settings.json)
        ]
        return managedPrefixes.contains { relativePath.hasPrefix($0) }
    }

    private func isMetadataProjectFile(_ relativePath: String) -> Bool {
        relativePath == "Metadata/project.json" || relativePath == "project.json"
    }

    private func isCharactersProjectFile(_ relativePath: String) -> Bool {
        relativePath == "Characters/characters.json" || relativePath == "characters.json"
    }

    /// Wave D: canonical scenes.json moved from Animate/ to Scenes/.
    private static let animateScenesPath = "Scenes/scenes.json"

    private func pruneLegacyIndexCache() throws {
        let legacyDirectory = projectURL.appendingPathComponent(".novtro", isDirectory: true)
        let legacyPath = legacyDirectory.standardizedFileURL.path
        let activePath = databaseDirectoryURL.standardizedFileURL.path
        guard legacyPath != activePath else { return }
        guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { return }
        try? FileManager.default.removeItem(at: legacyDirectory)
    }

    private func trimWAL() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func projectFileURL(for relativePath: String) -> URL? {
        let safePath = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard safePath.isEmpty == false,
              safePath.hasPrefix("/") == false,
              safePath.contains("..") == false else {
            return nil
        }
        return projectURL.appendingPathComponent(safePath, isDirectory: false)
    }

    private func jsonData(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func relativePath(for fileURL: URL) -> String {
        let basePath = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
        let filePath = fileURL.path
        if filePath.hasPrefix(basePath) {
            return String(filePath.dropFirst(basePath.count))
        }

        let baseURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let targetURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let baseComponents = baseURL.pathComponents
        let targetComponents = targetURL.pathComponents

        if targetComponents.starts(with: baseComponents) {
            return targetComponents.dropFirst(baseComponents.count).joined(separator: "/")
        }

        let normBasePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        return targetURL.path.replacingOccurrences(of: normBasePath, with: "")
    }

    private func parseUUID(_ value: String?) -> UUID? {
        guard let value else { return nil }
        return UUID(uuidString: value)
    }

    private func parseDate(_ value: String?) -> Date {
        Self.parseDate(value) ?? .distantPast
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return isoFormatter.date(from: string) ?? isoFormatterBasic.date(from: string)
    }

    private static func parseUUID(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    private func parseInt(_ value: String?) -> Int {
        Int(value ?? "") ?? 0
    }

    private func blobValue(_ value: String?) -> Data {
        Data(base64Encoded: value ?? "") ?? Data()
    }

    private func optionalBlobValue(_ value: String?) -> Data? {
        guard let value else { return nil }
        return Data(base64Encoded: value)
    }

    private func bindUUID(_ value: UUID?) -> SQLiteBind {
        if let value {
            return .text(value.uuidString)
        }
        return .null
    }

    private func bindText(_ value: String?) -> SQLiteBind {
        if let value {
            return .text(value)
        }
        return .null
    }

    private func bindBlob(_ value: Data?) -> SQLiteBind {
        if let value {
            return .blob(value)
        }
        return .null
    }

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoFormatterBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public typealias NovotroProjectDatabase = ProjectDatabase
