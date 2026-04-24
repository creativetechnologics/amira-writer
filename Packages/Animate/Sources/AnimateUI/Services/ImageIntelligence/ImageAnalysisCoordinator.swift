import Foundation

/// Coordinates image analysis jobs, manages the worker loop, and persists state.
@available(macOS 26.0, *)
public actor ImageAnalysisCoordinator {

    public struct LogEntry: Sendable {
        public let timestamp: Date
        public let message: String
    }

    public enum JobStatus: String, Sendable {
        case pending
        case running
        case completed
        case failed
        case cancelled
    }

    public struct JobRecord: Sendable {
        public let id: String
        public let imageAssetID: String
        public let status: JobStatus
        public let reason: String
        public let attemptCount: Int
        public let maxAttempts: Int
        public let lastError: String?
        public let createdAt: Date
        public let updatedAt: Date
    }

    public struct WorkerStats: Sendable {
        public let totalJobs: Int
        public let pendingJobs: Int
        public let runningJobs: Int
        public let completedJobs: Int
        public let failedJobs: Int
        public let isRunning: Bool
    }

    private let store: ImageIntelligenceStore
    private var backend: ImageAnalysisBackend = .aiStudio
    private var geminiService: GeminiImageAnalysisService?
    private var vertexService: VertexImageAnalysisClient?
    private var workerTask: Task<Void, Never>?
    private var isRunning = false
    private let concurrencyLimit = 1
    private var logs: [LogEntry] = []

    public init(store: ImageIntelligenceStore) {
        self.store = store
    }

    // MARK: - Configuration

    public func configure(apiKey: String) {
        backend = ImageAnalysisBackendStore.currentBackend()
        switch backend {
        case .aiStudio:
            let config = GeminiImageAnalysisService.AnalysisConfig(apiKey: apiKey)
            geminiService = GeminiImageAnalysisService(config: config)
            vertexService = nil
            log("Configured image analysis backend: AI Studio")
        case .vertex:
            if let config = ImageAnalysisBackendStore.vertexConfig() {
                vertexService = VertexImageAnalysisClient(config: config)
                geminiService = nil
                log("Configured image analysis backend: Vertex AI (\(config.projectID)/\(config.region))")
            } else {
                vertexService = nil
                geminiService = nil
                log("Vertex AI selected for image analysis, but project/region are not configured")
            }
        }
    }

    // MARK: - Job Management

    /// Enqueue an image for analysis.
    public func enqueue(assetID: String, reason: String = "manual") async throws {
        let dedupeKey = "\(assetID)|v1|gemini-3-flash-preview|gemini-embedding-2|3072"
        let now = Date().timeIntervalSince1970

        // Check if already queued
        if let existing = try await store.querySingle(
            "SELECT id FROM image_analysis_jobs WHERE dedupe_key = ? AND status IN ('pending', 'running')",
            [dedupeKey]
        ) {
            print("[ImageAnalysisCoordinator] Job already exists: \(existing["id"] as? String ?? "unknown")")
            return
        }

        let jobID = UUID().uuidString
        try await store.exec("""
            INSERT INTO image_analysis_jobs (
                id, image_asset_id, dedupe_key, reason, status,
                attempt_count, max_attempts, available_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            jobID, assetID, dedupeKey, reason, JobStatus.pending.rawValue,
            0, 3, now, now, now
        ])

        log("Enqueued job \(jobID) for asset \(assetID)")
    }

    /// Get all jobs for an asset.
    public func jobsForAsset(_ assetID: String) async throws -> [JobRecord] {
        let rows = try await store.query(
            "SELECT * FROM image_analysis_jobs WHERE image_asset_id = ? ORDER BY created_at DESC",
            [assetID]
        )
        return rows.compactMap { parseJobRecord($0) }
    }

    /// Get worker statistics.
    public func stats() async throws -> WorkerStats {
        let counts = try await store.query("""
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) as pending,
                SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) as running,
                SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed
            FROM image_analysis_jobs
        """)

        guard let row = counts.first else {
            return WorkerStats(totalJobs: 0, pendingJobs: 0, runningJobs: 0, completedJobs: 0, failedJobs: 0, isRunning: isRunning)
        }

        return WorkerStats(
            totalJobs: row["total"] as? Int ?? 0,
            pendingJobs: row["pending"] as? Int ?? 0,
            runningJobs: row["running"] as? Int ?? 0,
            completedJobs: row["completed"] as? Int ?? 0,
            failedJobs: row["failed"] as? Int ?? 0,
            isRunning: isRunning
        )
    }

    public func recentLogs(limit: Int = 100) -> [LogEntry] {
        Array(logs.suffix(limit))
    }

    public func queueSnapshot(limit: Int = 100) async throws -> [JobRecord] {
        let rows = try await store.queuedJobs(limit: limit)
        return rows.compactMap { parseJobRecord($0) }
    }

    // MARK: - Worker

    public func startWorker() {
        guard !isRunning else { return }
        isRunning = true

        workerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    let processed = try await self.processNextBatch()
                    if processed == 0 {
                        // No jobs available, wait before checking again
                        try? await Task.sleep(for: .seconds(5))
                    }
                } catch {
                    await self.log("Worker error: \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            await self?.stopWorker()
        }

        log("Worker started")
    }

    public func stopWorker() {
        isRunning = false
        workerTask?.cancel()
        workerTask = nil
        log("Worker stopped")
    }

    // MARK: - Processing

    private func processNextBatch() async throws -> Int {
        guard geminiService != nil || vertexService != nil else {
            log("No image analysis service configured")
            return 0
        }

        let now = Date().timeIntervalSince1970

        // Get next available job
        let jobs = try await store.query("""
            SELECT * FROM image_analysis_jobs
            WHERE status = 'pending' AND available_at <= ?
            ORDER BY priority DESC, created_at ASC
            LIMIT ?
        """, [now, concurrencyLimit])

        guard !jobs.isEmpty else { return 0 }

        for jobRow in jobs {
            let jobID = jobRow["id"] as! String
            let assetID = jobRow["image_asset_id"] as! String
            let attemptCount = (jobRow["attempt_count"] as? Int) ?? 0

            // Mark as running
            try await store.exec(
                "UPDATE image_analysis_jobs SET status = ?, attempt_count = ?, started_at = ?, updated_at = ? WHERE id = ?",
                [JobStatus.running.rawValue, attemptCount + 1, now, now, jobID]
            )

            do {
                switch backend {
                case .aiStudio:
                    guard let geminiService else {
                        throw GeminiImageAnalysisService.AnalysisError.noAPIKey
                    }
                    try await processJob(jobID: jobID, assetID: assetID, geminiService: geminiService)
                case .vertex:
                    guard let vertexService else {
                        throw VertexImageAnalysisClient.VertexAnalysisError.missingConfig("project ID / region not configured")
                    }
                    try await processJob(jobID: jobID, assetID: assetID, vertexService: vertexService)
                }

                // Mark as completed
                try await store.exec(
                    "UPDATE image_analysis_jobs SET status = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                    [JobStatus.completed.rawValue, now, now, jobID]
                )
            } catch {
                // Handle failure
                let errorMessage = error.localizedDescription
                let shouldRetry = attemptCount < 2 // max 3 attempts (0, 1, 2)

                if shouldRetry {
                    let backoffSeconds = pow(2.0, Double(attemptCount)) * 5 // 5s, 10s, 20s
                    let nextAvailable = now + backoffSeconds

                    try await store.exec(
                        "UPDATE image_analysis_jobs SET status = ?, last_error_message = ?, available_at = ?, updated_at = ? WHERE id = ?",
                        [JobStatus.pending.rawValue, errorMessage, nextAvailable, now, jobID]
                    )
                } else {
                    try await store.exec(
                        "UPDATE image_analysis_jobs SET status = ?, last_error_message = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                        [JobStatus.failed.rawValue, errorMessage, now, now, jobID]
                    )
                }
            }
        }

        return jobs.count
    }

    private func processJob(jobID: String, assetID: String, vertexService: VertexImageAnalysisClient) async throws {
        guard let asset = try await store.assetByID(assetID) else {
            throw GeminiImageAnalysisService.AnalysisError.invalidImage
        }

        guard FileManager.default.fileExists(atPath: asset.resolvedPath) else {
            throw GeminiImageAnalysisService.AnalysisError.invalidImage
        }

        let imageData = try Data(contentsOf: URL(fileURLWithPath: asset.resolvedPath))
        let runID = UUID().uuidString
        let now = Date().timeIntervalSince1970

        try await store.exec("""
            INSERT INTO image_analysis_runs (
                id, image_asset_id, source_content_hash, reason, status,
                visual_model_id, embedding_model_id, embedding_dimension,
                started_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            runID, assetID, asset.contentHashSHA256, "automatic", "running",
            "gemini-3-flash-preview", "gemini-embedding-2", 3072,
            now, now, now
        ])

        let analysisResult = try await vertexService.analyzeImage(imageData: imageData)

        try await store.exec("""
            INSERT INTO image_visual_metadata (
                id, image_asset_id, analysis_run_id, schema_version,
                summary, short_caption, long_caption,
                asset_roles_json, entities_json, scene_json, camera_json,
                style_json, quality_json, retrieval_json, confidence_json,
                raw_model_json, model_id, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            UUID().uuidString, assetID, runID, 1,
            analysisResult.summary,
            analysisResult.shortCaption,
            analysisResult.longCaption,
            encodeJSON(analysisResult.assetRoles),
            encodeJSON(entitiesJSONObject(analysisResult.entities)),
            encodeJSON(sceneJSONObject(analysisResult.scene)),
            encodeJSON(cameraJSONObject(analysisResult.camera)),
            encodeJSON(styleJSONObject(analysisResult.style)),
            encodeJSON(qualityJSONObject(analysisResult.quality)),
            encodeJSON(analysisResult.retrievalTags),
            encodeJSON(confidenceJSONObject(analysisResult.confidence)),
            analysisResult.rawJSON,
            "gemini-3-flash-preview",
            now, now
        ])

        let imageEmbedding = try await vertexService.embedImage(imageData: imageData)
        let imageVectorData = imageEmbedding.vector.withUnsafeBufferPointer { Data(buffer: $0) }

        try await store.exec("""
            INSERT INTO image_embeddings (
                id, image_asset_id, analysis_run_id, embedding_kind,
                model_id, embedding_dimension, vector_blob, vector_norm,
                content_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            UUID().uuidString, assetID, runID, "image_visual",
            imageEmbedding.modelID, imageEmbedding.dimension,
            imageVectorData, computeNorm(imageEmbedding.vector),
            asset.contentHashSHA256,
            now, now
        ])

        let semanticText = "\(analysisResult.shortCaption) \(analysisResult.retrievalTags.joined(separator: " "))"
        let semanticEmbedding = try await vertexService.embedText(semanticText)
        let semanticVectorData = semanticEmbedding.vector.withUnsafeBufferPointer { Data(buffer: $0) }

        try await store.exec("""
            INSERT INTO image_embeddings (
                id, image_asset_id, analysis_run_id, embedding_kind,
                model_id, embedding_dimension, vector_blob, vector_norm,
                source_text, content_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            UUID().uuidString, assetID, runID, "semantic_metadata",
            semanticEmbedding.modelID, semanticEmbedding.dimension,
            semanticVectorData, computeNorm(semanticEmbedding.vector),
            semanticText,
            asset.contentHashSHA256,
            now, now
        ])

        try await store.exec(
            "UPDATE image_analysis_runs SET status = ?, completed_at = ?, updated_at = ? WHERE id = ?",
            ["completed", now, now, runID]
        )

        log("Completed job \(jobID) for asset \(assetID) via Vertex AI")
    }

    private func processJob(jobID: String, assetID: String, geminiService: GeminiImageAnalysisService) async throws {
        // Get asset
        guard let asset = try await store.assetByID(assetID) else {
            throw GeminiImageAnalysisService.AnalysisError.invalidImage
        }

        // Check file exists
        guard FileManager.default.fileExists(atPath: asset.resolvedPath) else {
            throw GeminiImageAnalysisService.AnalysisError.invalidImage
        }

        // Read image data
        let imageData = try Data(contentsOf: URL(fileURLWithPath: asset.resolvedPath))

        // Create analysis run record
        let runID = UUID().uuidString
        let now = Date().timeIntervalSince1970

        try await store.exec("""
            INSERT INTO image_analysis_runs (
                id, image_asset_id, source_content_hash, reason, status,
                visual_model_id, embedding_model_id, embedding_dimension,
                started_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            runID, assetID, asset.contentHashSHA256, "automatic", "running",
            "gemini-3-flash-preview", "gemini-embedding-2", 3072,
            now, now, now
        ])

        // Perform visual analysis
        let analysisResult = try await geminiService.analyzeImage(imageData: imageData)

        // Store visual metadata
        try await store.exec("""
            INSERT INTO image_visual_metadata (
                id, image_asset_id, analysis_run_id, schema_version,
                summary, short_caption, long_caption,
                asset_roles_json, entities_json, scene_json, camera_json,
                style_json, quality_json, retrieval_json, confidence_json,
                raw_model_json, model_id, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            UUID().uuidString, assetID, runID, 1,
            analysisResult.summary,
            analysisResult.shortCaption,
            analysisResult.longCaption,
            encodeJSON(analysisResult.assetRoles),
            encodeJSON(entitiesJSONObject(analysisResult.entities)),
            encodeJSON(sceneJSONObject(analysisResult.scene)),
            encodeJSON(cameraJSONObject(analysisResult.camera)),
            encodeJSON(styleJSONObject(analysisResult.style)),
            encodeJSON(qualityJSONObject(analysisResult.quality)),
            encodeJSON(analysisResult.retrievalTags),
            encodeJSON(confidenceJSONObject(analysisResult.confidence)),
            analysisResult.rawJSON,
            "gemini-3-flash-preview",
            now, now
        ])

        // Generate image embedding
        let imageEmbedding = try await geminiService.embedImage(imageData: imageData)
        let imageVectorData = imageEmbedding.vector.withUnsafeBufferPointer {
            Data(buffer: $0)
        }

        try await store.exec("""
            INSERT INTO image_embeddings (
                id, image_asset_id, analysis_run_id, embedding_kind,
                model_id, embedding_dimension, vector_blob, vector_norm,
                content_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            UUID().uuidString, assetID, runID, "image_visual",
            imageEmbedding.modelID, imageEmbedding.dimension,
            imageVectorData, computeNorm(imageEmbedding.vector),
            asset.contentHashSHA256,
            now, now
        ])

        // Generate semantic embedding from caption
        let semanticText = "\(analysisResult.shortCaption) \(analysisResult.retrievalTags.joined(separator: " "))"
        let semanticEmbedding = try await geminiService.embedText(semanticText)
        let semanticVectorData = semanticEmbedding.vector.withUnsafeBufferPointer {
            Data(buffer: $0)
        }

        try await store.exec("""
            INSERT INTO image_embeddings (
                id, image_asset_id, analysis_run_id, embedding_kind,
                model_id, embedding_dimension, vector_blob, vector_norm,
                source_text, content_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            UUID().uuidString, assetID, runID, "semantic_metadata",
            semanticEmbedding.modelID, semanticEmbedding.dimension,
            semanticVectorData, computeNorm(semanticEmbedding.vector),
            semanticText,
            asset.contentHashSHA256,
            now, now
        ])

        // Mark run as complete
        try await store.exec(
            "UPDATE image_analysis_runs SET status = ?, completed_at = ?, updated_at = ? WHERE id = ?",
            ["completed", now, now, runID]
        )

        log("Completed job \(jobID) for asset \(assetID)")
    }

    // MARK: - Helpers

    private func parseJobRecord(_ row: [String: Any]) -> JobRecord? {
        guard let id = row["id"] as? String,
              let assetID = row["image_asset_id"] as? String,
              let statusRaw = row["status"] as? String,
              let status = JobStatus(rawValue: statusRaw) else { return nil }

        return JobRecord(
            id: id,
            imageAssetID: assetID,
            status: status,
            reason: row["reason"] as? String ?? "",
            attemptCount: row["attempt_count"] as? Int ?? 0,
            maxAttempts: row["max_attempts"] as? Int ?? 3,
            lastError: row["last_error_message"] as? String,
            createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
        )
    }

    private func log(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)
        logs.append(entry)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
        print("[ImageAnalysisCoordinator] \(message)")
    }

    private func encodeJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func entitiesJSONObject(_ entities: [GeminiImageAnalysisService.VisualAnalysisResult.Entity]) -> [[String: Any]] {
        entities.map { entity in
            var object: [String: Any] = [
                "type": entity.type,
                "description": entity.description
            ]
            if let count = entity.count {
                object["count"] = count
            }
            return object
        }
    }

    private func sceneJSONObject(_ scene: GeminiImageAnalysisService.VisualAnalysisResult.SceneInfo) -> [String: Any] {
        [
            "setting": scene.setting,
            "topography": scene.topography,
            "terrain": scene.terrain,
            "foliage": scene.foliage,
            "architecture": scene.architecture,
            "weather": scene.weather,
            "season": scene.season,
            "time_of_day": scene.timeOfDay,
            "lighting": scene.lighting
        ].compactMapValues { $0 }
    }

    private func cameraJSONObject(_ camera: GeminiImageAnalysisService.VisualAnalysisResult.CameraInfo) -> [String: Any] {
        [
            "angle": camera.angle,
            "distance": camera.distance,
            "composition": camera.composition,
            "movement": camera.movement
        ].compactMapValues { $0 }
    }

    private func styleJSONObject(_ style: GeminiImageAnalysisService.VisualAnalysisResult.StyleInfo) -> [String: Any] {
        [
            "palette": style.palette,
            "mood": style.mood,
            "genre": style.genre,
            "artistic_style": style.artisticStyle
        ].compactMapValues { $0 }
    }

    private func qualityJSONObject(_ quality: GeminiImageAnalysisService.VisualAnalysisResult.QualityInfo) -> [String: Any] {
        var object: [String: Any] = [
            "artifacts": quality.artifacts
        ]
        if let overall = quality.overall { object["overall"] = overall }
        if let sharpness = quality.sharpness { object["sharpness"] = sharpness }
        if let exposure = quality.exposure { object["exposure"] = exposure }
        if let colorAccuracy = quality.colorAccuracy { object["color_accuracy"] = colorAccuracy }
        return object
    }

    private func confidenceJSONObject(_ confidence: GeminiImageAnalysisService.VisualAnalysisResult.ConfidenceInfo) -> [String: Any] {
        [
            "overall": confidence.overall,
            "uncertain_fields": confidence.uncertainFields
        ]
    }

    private func computeNorm(_ vector: [Float]) -> Float {
        let sumOfSquares = vector.reduce(0.0) { $0 + $1 * $1 }
        return sqrt(sumOfSquares)
    }
}
