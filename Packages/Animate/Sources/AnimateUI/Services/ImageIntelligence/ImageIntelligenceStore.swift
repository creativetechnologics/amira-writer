import Foundation
import SQLite3
import ProjectKit

/// Actor-isolated SQLite store for image intelligence data.
/// Separate from ProjectDatabase to isolate schema and migration risk.
@available(macOS 26.0, *)
public actor ImageIntelligenceStore {
    public let projectURL: URL
    public let databaseURL: URL

    private nonisolated(unsafe) var db: OpaquePointer?
    private static let currentSchemaVersion = 2
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(projectURL: URL) {
        self.projectURL = projectURL
        self.databaseURL = ProjectPaths(root: projectURL).imageIntelligenceSQLite
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Lifecycle

    public func open() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try openIfNeeded()
        try createSchema()
        try migrateSchemaIfNeeded()
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        let sql = """
        -- Schema version tracking
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at REAL DEFAULT (unixepoch())
        );

        -- Canonical image assets
        CREATE TABLE IF NOT EXISTS image_assets (
            id TEXT PRIMARY KEY,
            resolved_path TEXT UNIQUE NOT NULL,
            project_relative_path TEXT,
            filename TEXT,
            mime_type TEXT,
            width INTEGER,
            height INTEGER,
            aspect_ratio REAL,
            file_size_bytes INTEGER,
            content_hash_sha256 TEXT,
            perceptual_hash TEXT,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch()),
            last_seen_at REAL DEFAULT (unixepoch()),
            is_missing INTEGER DEFAULT 0,
            generation_prompt TEXT,
            generation_model TEXT,
            generation_aspect_ratio TEXT,
            generation_image_size TEXT,
            generation_source_json TEXT
        );

        -- Links from assets to app domain objects
        CREATE TABLE IF NOT EXISTS image_asset_links (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            link_kind TEXT NOT NULL,
            owner_id TEXT,
            owner_parent_id TEXT,
            moment TEXT,
            workflow TEXT,
            context_json TEXT,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );

        -- Analysis runs per asset
        CREATE TABLE IF NOT EXISTS image_analysis_runs (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            source_content_hash TEXT,
            reason TEXT,
            status TEXT DEFAULT 'pending',
            local_inspection_status TEXT DEFAULT 'pending',
            visual_analysis_status TEXT DEFAULT 'pending',
            image_embedding_status TEXT DEFAULT 'pending',
            semantic_embedding_status TEXT DEFAULT 'pending',
            tag_normalization_status TEXT DEFAULT 'pending',
            visual_model_id TEXT,
            embedding_model_id TEXT,
            embedding_dimension INTEGER,
            analysis_schema_version INTEGER,
            analysis_prompt_version TEXT,
            tag_taxonomy_version TEXT,
            started_at REAL,
            completed_at REAL,
            retry_count INTEGER DEFAULT 0,
            error_code TEXT,
            error_message TEXT,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );

        -- Visual metadata from analysis
        CREATE TABLE IF NOT EXISTS image_visual_metadata (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            analysis_run_id TEXT REFERENCES image_analysis_runs(id) ON DELETE CASCADE,
            schema_version INTEGER,
            summary TEXT,
            short_caption TEXT,
            long_caption TEXT,
            asset_roles_json TEXT,
            entities_json TEXT,
            scene_json TEXT,
            camera_json TEXT,
            style_json TEXT,
            quality_json TEXT,
            retrieval_json TEXT,
            confidence_json TEXT,
            raw_model_json TEXT,
            model_id TEXT,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );

        -- Tag taxonomy
        CREATE TABLE IF NOT EXISTS image_tags (
            id TEXT PRIMARY KEY,
            slug TEXT UNIQUE NOT NULL,
            display_name TEXT,
            category TEXT,
            parent_tag_id TEXT REFERENCES image_tags(id),
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );

        -- Tag assignments to assets
        CREATE TABLE IF NOT EXISTS image_tag_assignments (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL REFERENCES image_tags(id) ON DELETE CASCADE,
            analysis_run_id TEXT REFERENCES image_analysis_runs(id) ON DELETE CASCADE,
            source TEXT,
            confidence REAL,
            is_negative INTEGER DEFAULT 0,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch()),
            UNIQUE(image_asset_id, tag_id, analysis_run_id)
        );

        -- Manual spatial character annotations. Coordinates are normalized
        -- into image space with a top-left origin so they can be reused by
        -- prompt builders, embedding retrieval, and future preview overlays.
        CREATE TABLE IF NOT EXISTS image_character_regions (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            character_id TEXT NOT NULL,
            character_name TEXT,
            geometry_kind TEXT NOT NULL DEFAULT 'point',
            x REAL NOT NULL,
            y REAL NOT NULL,
            width REAL,
            height REAL,
            source TEXT,
            confidence REAL,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );

        -- Vector embeddings
        CREATE TABLE IF NOT EXISTS image_embeddings (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            analysis_run_id TEXT REFERENCES image_analysis_runs(id) ON DELETE CASCADE,
            embedding_kind TEXT NOT NULL,
            model_id TEXT,
            embedding_dimension INTEGER,
            vector_blob BLOB,
            vector_norm REAL,
            content_hash TEXT,
            source_text TEXT,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );

        -- Analysis job queue
        CREATE TABLE IF NOT EXISTS image_analysis_jobs (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            dedupe_key TEXT UNIQUE,
            reason TEXT,
            status TEXT DEFAULT 'pending',
            priority INTEGER DEFAULT 0,
            attempt_count INTEGER DEFAULT 0,
            max_attempts INTEGER DEFAULT 3,
            available_at REAL DEFAULT (unixepoch()),
            started_at REAL,
            finished_at REAL,
            last_error_code TEXT,
            last_error_message TEXT,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );

        -- QC flags
        CREATE TABLE IF NOT EXISTS image_qc_flags (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            analysis_run_id TEXT REFERENCES image_analysis_runs(id) ON DELETE CASCADE,
            flag_type TEXT,
            severity TEXT,
            score REAL,
            reason TEXT,
            related_scene_id TEXT,
            related_shot_id TEXT,
            related_place_id TEXT,
            related_character_id TEXT,
            created_by TEXT,
            created_at REAL DEFAULT (unixepoch()),
            resolved_at REAL
        );

        -- Indexes
        CREATE INDEX IF NOT EXISTS idx_assets_path ON image_assets(resolved_path);
        CREATE INDEX IF NOT EXISTS idx_assets_hash ON image_assets(content_hash_sha256);
        CREATE INDEX IF NOT EXISTS idx_assets_missing ON image_assets(is_missing);
        CREATE INDEX IF NOT EXISTS idx_links_asset ON image_asset_links(image_asset_id);
        CREATE INDEX IF NOT EXISTS idx_links_kind ON image_asset_links(link_kind);
        CREATE INDEX IF NOT EXISTS idx_links_owner ON image_asset_links(owner_id);
        CREATE INDEX IF NOT EXISTS idx_runs_asset ON image_analysis_runs(image_asset_id);
        CREATE INDEX IF NOT EXISTS idx_runs_status ON image_analysis_runs(status);
        CREATE INDEX IF NOT EXISTS idx_jobs_status ON image_analysis_jobs(status);
        CREATE INDEX IF NOT EXISTS idx_jobs_available ON image_analysis_jobs(available_at);
        CREATE INDEX IF NOT EXISTS idx_embeddings_asset ON image_embeddings(image_asset_id);
        CREATE INDEX IF NOT EXISTS idx_embeddings_kind ON image_embeddings(embedding_kind);
        CREATE INDEX IF NOT EXISTS idx_tag_assignments_asset ON image_tag_assignments(image_asset_id);
        CREATE INDEX IF NOT EXISTS idx_character_regions_asset ON image_character_regions(image_asset_id);
        CREATE INDEX IF NOT EXISTS idx_character_regions_character ON image_character_regions(character_id);
        CREATE INDEX IF NOT EXISTS idx_qc_flags_asset ON image_qc_flags(image_asset_id);
        """

        try execRaw(sql)
    }

    private func execRaw(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown exec error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "ImageIntelligenceStore", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func migrateSchemaIfNeeded() throws {
        let version = try currentSchemaVersion()
        guard version < Self.currentSchemaVersion else { return }

        if version < 2 {
            try migrateToV2()
        }

        try exec("INSERT OR REPLACE INTO schema_version (version) VALUES (?)", [Self.currentSchemaVersion])
    }

    private func migrateToV2() throws {
        try execRaw("""
        CREATE TABLE IF NOT EXISTS image_character_regions (
            id TEXT PRIMARY KEY,
            image_asset_id TEXT NOT NULL REFERENCES image_assets(id) ON DELETE CASCADE,
            character_id TEXT NOT NULL,
            character_name TEXT,
            geometry_kind TEXT NOT NULL DEFAULT 'point',
            x REAL NOT NULL,
            y REAL NOT NULL,
            width REAL,
            height REAL,
            source TEXT,
            confidence REAL,
            created_at REAL DEFAULT (unixepoch()),
            updated_at REAL DEFAULT (unixepoch())
        );
        CREATE INDEX IF NOT EXISTS idx_character_regions_asset ON image_character_regions(image_asset_id);
        CREATE INDEX IF NOT EXISTS idx_character_regions_character ON image_character_regions(character_id);
        """)
    }

    private func currentSchemaVersion() throws -> Int {
        try querySingle("SELECT version FROM schema_version ORDER BY version DESC LIMIT 1")?["version"] as? Int ?? 0
    }

    // MARK: - Asset Registration

    /// Register or update an image asset.
    /// Returns the asset ID (new or existing).
    @discardableResult
    public func registerAsset(
        resolvedPath: String,
        projectRelativePath: String? = nil,
        filename: String? = nil,
        mimeType: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fileSizeBytes: Int? = nil,
        contentHashSHA256: String? = nil
    ) throws -> String {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970

        // Check for existing asset by path
        if let existing = try querySingle(
            "SELECT id, content_hash_sha256 FROM image_assets WHERE resolved_path = ?",
            [resolvedPath]
        ) {
            let existingID = existing["id"] as! String
            let existingHash = existing["content_hash_sha256"] as? String

            // Update if hash changed or missing
            if contentHashSHA256 != existingHash || existingHash == nil {
                try exec("""
                    UPDATE image_assets SET
                        project_relative_path = ?,
                        filename = ?,
                        mime_type = ?,
                        width = ?,
                        height = ?,
                        aspect_ratio = ?,
                        file_size_bytes = ?,
                        content_hash_sha256 = ?,
                        updated_at = ?,
                        last_seen_at = ?,
                        is_missing = 0
                    WHERE id = ?
                """, [
                    projectRelativePath, filename, mimeType, width, height,
                    aspectRatio(width: width, height: height),
                    fileSizeBytes, contentHashSHA256, now, now, existingID
                ])
            } else {
                // Just update last_seen_at
                try exec(
                    "UPDATE image_assets SET last_seen_at = ?, is_missing = 0 WHERE id = ?",
                    [now, existingID]
                )
            }
            return existingID
        }

        // Insert new asset
        try exec("""
            INSERT INTO image_assets (
                id, resolved_path, project_relative_path, filename, mime_type,
                width, height, aspect_ratio, file_size_bytes, content_hash_sha256,
                created_at, updated_at, last_seen_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            id, resolvedPath, projectRelativePath, filename, mimeType,
            width, height, aspectRatio(width: width, height: height),
            fileSizeBytes, contentHashSHA256, now, now, now
        ])

        return id
    }

    /// Link an asset to an app domain object.
    public func linkAsset(
        assetID: String,
        kind: ImageAssetLinkKind,
        ownerID: String? = nil,
        ownerParentID: String? = nil,
        moment: String? = nil,
        workflow: String? = nil,
        context: [String: String]? = nil
    ) throws {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let contextJSON = context.flatMap { try? JSONSerialization.data(withJSONObject: $0) }?.base64EncodedString()

        // Check for existing link
        if let existing = try querySingle("""
            SELECT id FROM image_asset_links
            WHERE image_asset_id = ? AND link_kind = ? AND owner_id = ?
        """, [assetID, kind.rawValue, ownerID]) {
            // Update existing link
            try exec("""
                UPDATE image_asset_links SET
                    owner_parent_id = ?,
                    moment = ?,
                    workflow = ?,
                    context_json = ?,
                    updated_at = ?
                WHERE id = ?
            """, [ownerParentID, moment, workflow, contextJSON, now, existing["id"]!])
            return
        }

        // Insert new link
        try exec("""
            INSERT INTO image_asset_links (
                id, image_asset_id, link_kind, owner_id, owner_parent_id,
                moment, workflow, context_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            id, assetID, kind.rawValue, ownerID, ownerParentID,
            moment, workflow, contextJSON, now, now
        ])
    }

    /// Mark assets as missing if they haven't been seen since the given timestamp.
    public func markMissingAssets(notSeenSince: TimeInterval) throws -> Int {
        try exec("""
            UPDATE image_assets SET is_missing = 1
            WHERE last_seen_at < ? AND is_missing = 0
        """, [notSeenSince])
        return changes()
    }

    /// Lookup asset by resolved path.
    public func assetByPath(_ path: String) throws -> ImageAssetRecord? {
        guard let row = try querySingle(
            "SELECT * FROM image_assets WHERE resolved_path = ?",
            [path]
        ) else { return nil }
        return ImageAssetRecord(from: row)
    }

    /// Lookup asset by ID.
    public func assetByID(_ id: String) throws -> ImageAssetRecord? {
        guard let row = try querySingle(
            "SELECT * FROM image_assets WHERE id = ?",
            [id]
        ) else { return nil }
        return ImageAssetRecord(from: row)
    }

    /// Get all links for an asset.
    public func linksForAsset(_ assetID: String) throws -> [ImageAssetLinkRecord] {
        let rows = try query(
            "SELECT * FROM image_asset_links WHERE image_asset_id = ?",
            [assetID]
        )
        return rows.compactMap { ImageAssetLinkRecord(from: $0) }
    }

    public func runsForAsset(_ assetID: String) throws -> [ImageAnalysisRunRecord] {
        let rows = try query(
            "SELECT * FROM image_analysis_runs WHERE image_asset_id = ? ORDER BY created_at DESC",
            [assetID]
        )
        return rows.compactMap { ImageAnalysisRunRecord(from: $0) }
    }

    public func latestVisualMetadataForAsset(_ assetID: String) throws -> ImageVisualMetadataRecord? {
        guard let row = try querySingle(
            "SELECT * FROM image_visual_metadata WHERE image_asset_id = ? ORDER BY created_at DESC LIMIT 1",
            [assetID]
        ) else { return nil }
        return ImageVisualMetadataRecord(from: row)
    }

    func continuityCandidateRows(matchingTerms terms: [String], limit: Int) throws -> [[String: Sendable]] {
        let cleanedTerms = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { $0.count > 3 }))
            .sorted()
            .prefix(12)
        guard !cleanedTerms.isEmpty else { return [] }
        let textExpression = """
            LOWER(
                COALESCE(a.resolved_path, '') || ' ' ||
                COALESCE(a.project_relative_path, '') || ' ' ||
                COALESCE(vm.summary, '') || ' ' ||
                COALESCE(vm.short_caption, '') || ' ' ||
                COALESCE(vm.long_caption, '') || ' ' ||
                COALESCE(vm.retrieval_json, '') || ' ' ||
                COALESCE(vm.entities_json, '') || ' ' ||
                COALESCE(vm.scene_json, '') || ' ' ||
                COALESCE(vm.style_json, '')
            )
            """
        let clauses = cleanedTerms.map { _ in "\(textExpression) LIKE ?" }.joined(separator: " OR ")
        let sql = """
            SELECT
                a.id,
                a.resolved_path,
                a.project_relative_path,
                vm.summary,
                vm.short_caption,
                vm.long_caption,
                vm.retrieval_json,
                vm.entities_json,
                vm.scene_json,
                vm.style_json
            FROM image_assets a
            LEFT JOIN image_visual_metadata vm ON vm.id = (
                SELECT id FROM image_visual_metadata
                WHERE image_asset_id = a.id
                ORDER BY created_at DESC
                LIMIT 1
            )
            WHERE a.is_missing = 0
              AND (\(clauses))
            ORDER BY a.updated_at DESC
            LIMIT ?
        """
        let params: [Any?] = cleanedTerms.map { "%\($0)%" } + [max(1, min(limit, 500))]
        return try query(sql, params)
    }

    public func queuedJobs(limit: Int = 100) throws -> [[String: Sendable]] {
        try query(
            "SELECT * FROM image_analysis_jobs ORDER BY updated_at DESC LIMIT ?",
            [limit]
        )
    }

    // MARK: - Manual Spatial Character Tags

    @discardableResult
    public func addCharacterRegionTag(
        assetID: String,
        characterID: String,
        characterName: String?,
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double? = nil,
        normalizedHeight: Double? = nil,
        source: String = "manual_context_menu",
        confidence: Double? = 1.0
    ) throws -> String {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try exec("""
            INSERT INTO image_character_regions (
                id, image_asset_id, character_id, character_name,
                geometry_kind, x, y, width, height, source, confidence,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            id,
            assetID,
            characterID,
            characterName,
            normalizedWidth == nil || normalizedHeight == nil ? "point" : "rect",
            min(max(normalizedX, 0), 1),
            min(max(normalizedY, 0), 1),
            normalizedWidth.map { min(max($0, 0), 1) },
            normalizedHeight.map { min(max($0, 0), 1) },
            source,
            confidence,
            now,
            now
        ])
        return id
    }

    public func characterRegionTagsForAsset(_ assetID: String) throws -> [ImageCharacterRegionTagRecord] {
        let rows = try query(
            "SELECT * FROM image_character_regions WHERE image_asset_id = ? ORDER BY created_at DESC",
            [assetID]
        )
        return rows.compactMap { ImageCharacterRegionTagRecord(from: $0) }
    }

    public func deleteCharacterRegionTag(_ id: String) throws {
        try exec("DELETE FROM image_character_regions WHERE id = ?", [id])
    }

    // MARK: - Helpers

    private func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let w = width, let h = height, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    private func openIfNeeded() throws {
        guard db == nil else { return }
        let rc = sqlite3_open(databaseURL.path, &db)
        guard rc == SQLITE_OK else {
            throw NSError(domain: "ImageIntelligenceStore", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "Failed to open database"
            ])
        }
        // Enable WAL mode for better concurrency and keep normal UI operations
        // from stalling behind synchronous fsync-heavy writes.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout=2500;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store=MEMORY;", nil, nil, nil)
    }

    func exec(_ sql: String, _ params: [Any?] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }
        try bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError()
        }
    }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [[String: Sendable]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }
        try bind(params, to: stmt)

        var results: [[String: Sendable]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(try rowToDictionary(stmt!))
        }
        return results
    }

    func querySingle(_ sql: String, _ params: [Any?] = []) throws -> [String: Sendable]? {
        let rows = try query(sql, params)
        return rows.first
    }

    private func bind(_ params: [Any?], to stmt: OpaquePointer?) throws {
        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            if let param {
                if let s = param as? String {
                    sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, nil)
                } else if let data = param as? Data {
                    data.withUnsafeBytes { rawBuffer in
                        _ = sqlite3_bind_blob(
                            stmt,
                            idx,
                            rawBuffer.baseAddress,
                            Int32(data.count),
                            Self.sqliteTransient
                        )
                    }
                } else if let i = param as? Int {
                    sqlite3_bind_int64(stmt, idx, Int64(i))
                } else if let i = param as? Int64 {
                    sqlite3_bind_int64(stmt, idx, i)
                } else if let d = param as? Double {
                    sqlite3_bind_double(stmt, idx, d)
                } else if let f = param as? Float {
                    sqlite3_bind_double(stmt, idx, Double(f))
                } else if let b = param as? Bool {
                    sqlite3_bind_int(stmt, idx, b ? 1 : 0)
                } else {
                    let desc = String(describing: param)
                    sqlite3_bind_text(stmt, idx, (desc as NSString).utf8String, -1, nil)
                }
            } else {
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func rowToDictionary(_ stmt: OpaquePointer) throws -> [String: Sendable] {
        var dict: [String: Sendable] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                dict[name] = Int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT:
                dict[name] = sqlite3_column_double(stmt, i)
            case SQLITE_TEXT:
                dict[name] = String(cString: sqlite3_column_text(stmt, i))
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(stmt, i) {
                    let length = sqlite3_column_bytes(stmt, i)
                    dict[name] = Data(bytes: bytes, count: Int(length))
                }
            default:
                break
            }
        }
        return dict
    }

    private func changes() -> Int {
        Int(sqlite3_changes(db))
    }

    private func lastError() -> NSError {
        let message: String
        if let errmsg = sqlite3_errmsg(db) {
            message = String(cString: errmsg)
        } else {
            message = "Unknown error"
        }
        return NSError(domain: "ImageIntelligenceStore", code: Int(sqlite3_errcode(db)), userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

// MARK: - Link Kinds

@available(macOS 26.0, *)
public enum ImageAssetLinkKind: String, CaseIterable, Sendable {
    case placeGenerated = "place_generated"
    case placeReference = "place_reference"
    case placeLandmarkReference = "place_landmark_reference"
    case placeAngleImage = "place_angle_image"
    case placeMasterMap = "place_master_map"
    case map3DCapture = "map3d_capture"
    case characterProfile = "character_profile"
    case characterInspiration = "character_inspiration"
    case characterReference = "character_reference"
    case characterAnimated = "character_animated"
    case characterMasterSource = "character_master_source"
    case characterMasterSheetVariant = "character_master_sheet_variant"
    case characterHeadSheetVariant = "character_head_sheet_variant"
    case characterLookdevVariant = "character_lookdev_variant"
    case characterHeadTurnVariant = "character_head_turn_variant"
    case characterCostumeSheetVariant = "character_costume_sheet_variant"
    case characterCostumeFullbodyVariant = "character_costume_fullbody_variant"
    case characterCostumeAccessoryVariant = "character_costume_accessory_variant"
    case characterCostumeReference = "character_costume_reference"
    case characterCostumeVariation = "character_costume_variation"
    case storyboardFrame = "storyboard_frame"
    case sceneShotImage = "scene_shot_image"
    case canvasGeneration = "canvas_generation"
}

// MARK: - Records

@available(macOS 26.0, *)
public struct ImageAssetRecord: Sendable {
    public let id: String
    public let resolvedPath: String
    public let projectRelativePath: String?
    public let filename: String?
    public let mimeType: String?
    public let width: Int?
    public let height: Int?
    public let aspectRatio: Double?
    public let fileSizeBytes: Int?
    public let contentHashSHA256: String?
    public let isMissing: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let lastSeenAt: Date

    init?(from row: [String: Any]) {
        guard let id = row["id"] as? String,
              let resolvedPath = row["resolved_path"] as? String else { return nil }
        self.id = id
        self.resolvedPath = resolvedPath
        self.projectRelativePath = row["project_relative_path"] as? String
        self.filename = row["filename"] as? String
        self.mimeType = row["mime_type"] as? String
        self.width = row["width"] as? Int
        self.height = row["height"] as? Int
        self.aspectRatio = row["aspect_ratio"] as? Double
        self.fileSizeBytes = row["file_size_bytes"] as? Int
        self.contentHashSHA256 = row["content_hash_sha256"] as? String
        self.isMissing = (row["is_missing"] as? Int) == 1
        self.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        self.updatedAt = Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
        self.lastSeenAt = Date(timeIntervalSince1970: row["last_seen_at"] as? Double ?? 0)
    }
}

@available(macOS 26.0, *)
public struct ImageAssetLinkRecord: Sendable {
    public let id: String
    public let imageAssetID: String
    public let linkKind: ImageAssetLinkKind
    public let ownerID: String?
    public let ownerParentID: String?
    public let moment: String?
    public let workflow: String?
    public let createdAt: Date
    public let updatedAt: Date

    init?(from row: [String: Any]) {
        guard let id = row["id"] as? String,
              let imageAssetID = row["image_asset_id"] as? String,
              let kindRaw = row["link_kind"] as? String,
              let kind = ImageAssetLinkKind(rawValue: kindRaw) else { return nil }
        self.id = id
        self.imageAssetID = imageAssetID
        self.linkKind = kind
        self.ownerID = row["owner_id"] as? String
        self.ownerParentID = row["owner_parent_id"] as? String
        self.moment = row["moment"] as? String
        self.workflow = row["workflow"] as? String
        self.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        self.updatedAt = Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
    }
}

@available(macOS 26.0, *)
public struct ImageCharacterRegionTagRecord: Sendable, Identifiable, Hashable {
    public let id: String
    public let imageAssetID: String
    public let characterID: String
    public let characterName: String?
    public let geometryKind: String
    public let x: Double
    public let y: Double
    public let width: Double?
    public let height: Double?
    public let source: String?
    public let confidence: Double?
    public let createdAt: Date
    public let updatedAt: Date

    init?(from row: [String: Any]) {
        guard let id = row["id"] as? String,
              let imageAssetID = row["image_asset_id"] as? String,
              let characterID = row["character_id"] as? String,
              let geometryKind = row["geometry_kind"] as? String,
              let x = row["x"] as? Double,
              let y = row["y"] as? Double else { return nil }
        self.id = id
        self.imageAssetID = imageAssetID
        self.characterID = characterID
        self.characterName = row["character_name"] as? String
        self.geometryKind = geometryKind
        self.x = x
        self.y = y
        self.width = row["width"] as? Double
        self.height = row["height"] as? Double
        self.source = row["source"] as? String
        self.confidence = row["confidence"] as? Double
        self.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        self.updatedAt = Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
    }
}

@available(macOS 26.0, *)
public struct ImageAnalysisRunRecord: Sendable {
    public let id: String
    public let imageAssetID: String
    public let reason: String?
    public let status: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let errorCode: String?
    public let errorMessage: String?
    public let createdAt: Date
    public let updatedAt: Date

    init?(from row: [String: Any]) {
        guard let id = row["id"] as? String,
              let imageAssetID = row["image_asset_id"] as? String,
              let status = row["status"] as? String else { return nil }
        self.id = id
        self.imageAssetID = imageAssetID
        self.reason = row["reason"] as? String
        self.status = status
        self.startedAt = (row["started_at"] as? Double).map(Date.init(timeIntervalSince1970:))
        self.completedAt = (row["completed_at"] as? Double).map(Date.init(timeIntervalSince1970:))
        self.errorCode = row["error_code"] as? String
        self.errorMessage = row["error_message"] as? String
        self.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        self.updatedAt = Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
    }
}

@available(macOS 26.0, *)
public struct ImageVisualMetadataRecord: Sendable {
    public let id: String
    public let imageAssetID: String
    public let analysisRunID: String?
    public let summary: String?
    public let shortCaption: String?
    public let longCaption: String?
    public let assetRolesJSON: String?
    public let entitiesJSON: String?
    public let sceneJSON: String?
    public let cameraJSON: String?
    public let styleJSON: String?
    public let qualityJSON: String?
    public let retrievalJSON: String?
    public let confidenceJSON: String?
    public let rawModelJSON: String?
    public let modelID: String?
    public let createdAt: Date
    public let updatedAt: Date

    init?(from row: [String: Any]) {
        guard let id = row["id"] as? String,
              let imageAssetID = row["image_asset_id"] as? String else { return nil }
        self.id = id
        self.imageAssetID = imageAssetID
        self.analysisRunID = row["analysis_run_id"] as? String
        self.summary = row["summary"] as? String
        self.shortCaption = row["short_caption"] as? String
        self.longCaption = row["long_caption"] as? String
        self.assetRolesJSON = row["asset_roles_json"] as? String
        self.entitiesJSON = row["entities_json"] as? String
        self.sceneJSON = row["scene_json"] as? String
        self.cameraJSON = row["camera_json"] as? String
        self.styleJSON = row["style_json"] as? String
        self.qualityJSON = row["quality_json"] as? String
        self.retrievalJSON = row["retrieval_json"] as? String
        self.confidenceJSON = row["confidence_json"] as? String
        self.rawModelJSON = row["raw_model_json"] as? String
        self.modelID = row["model_id"] as? String
        self.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        self.updatedAt = Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
    }
}
