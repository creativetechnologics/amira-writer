import Foundation

/// Coordinates backfill of existing images into the image intelligence system.
@available(macOS 26.0, *)
public actor ImageAnalysisBackfillService {

    public struct BackfillReport: Sendable {
        public let totalDiscovered: Int
        public let alreadyRegistered: Int
        public let newlyRegistered: Int
        public let missingAssets: Int
        public let queuedForAnalysis: Int
        public let errors: [String]
        public let isDryRun: Bool

        public var summary: String {
            """
            Backfill Report (dryRun: \(isDryRun))
            - Total discovered: \(totalDiscovered)
            - Already registered: \(alreadyRegistered)
            - Newly registered: \(newlyRegistered)
            - Missing assets: \(missingAssets)
            - Queued for analysis: \(queuedForAnalysis)
            - Errors: \(errors.count)
            """
        }
    }

    public struct BackfillOptions: Sendable {
        public let dryRun: Bool
        public let maxBatchSize: Int?
        public let forceReanalysis: Bool
        public let linkKinds: [ImageAssetLinkKind]?
        public let enqueueExistingWithoutRuns: Bool
        public let enqueueExistingMissingAnalysis: Bool
        public let markMissingAssets: Bool

        public init(
            dryRun: Bool = false,
            maxBatchSize: Int? = nil,
            forceReanalysis: Bool = false,
            linkKinds: [ImageAssetLinkKind]? = nil,
            enqueueExistingWithoutRuns: Bool = false,
            enqueueExistingMissingAnalysis: Bool = false,
            markMissingAssets: Bool = true
        ) {
            self.dryRun = dryRun
            self.maxBatchSize = maxBatchSize
            self.forceReanalysis = forceReanalysis
            self.linkKinds = linkKinds
            self.enqueueExistingWithoutRuns = enqueueExistingWithoutRuns
            self.enqueueExistingMissingAnalysis = enqueueExistingMissingAnalysis
            self.markMissingAssets = markMissingAssets
        }
    }

    private let store: ImageIntelligenceStore
    private let discoveryService: ImageAssetDiscoveryService
    private let coordinator: ImageAnalysisCoordinator?

    public init(
        store: ImageIntelligenceStore,
        discoveryService: ImageAssetDiscoveryService,
        coordinator: ImageAnalysisCoordinator? = nil
    ) {
        self.store = store
        self.discoveryService = discoveryService
        self.coordinator = coordinator
    }

    /// Run backfill and return a report.
    public func backfill(options: BackfillOptions = BackfillOptions()) async -> BackfillReport {
        var errors: [String] = []
        var alreadyRegistered = 0
        var newlyRegistered = 0
        var queuedForAnalysis = 0

        // Snapshot time before processing so we don't immediately mark freshly
        // touched assets as missing at the end of the same backfill run.
        let startedAt = Date().timeIntervalSince1970

        // Discover all assets
        let discovery = await discoveryService.discoverAll()
        let assets = options.linkKinds.map { kinds in
            discovery.assets.filter { kinds.contains($0.linkKind) }
        } ?? discovery.assets

        let batchAssets = options.maxBatchSize.map { Array(assets.prefix($0)) } ?? assets

        for asset in batchAssets {
            do {
                // Check if already registered
                let existing = try await store.assetByPath(asset.resolvedPath)

                if let existing {
                    alreadyRegistered += 1

                    // Update links even for existing assets
                    if !options.dryRun {
                        try await store.linkAsset(
                            assetID: existing.id,
                            kind: asset.linkKind,
                            ownerID: asset.ownerID,
                            ownerParentID: asset.ownerParentID,
                            moment: asset.moment,
                            workflow: asset.workflow,
                            context: asset.context
                        )
                    }

                    let shouldQueueExisting = try await shouldQueueExistingAsset(
                        existing.id,
                        options: options
                    )
                    if !options.dryRun && shouldQueueExisting {
                        try await coordinator?.enqueue(
                            assetID: existing.id,
                            reason: options.forceReanalysis ? "backfill" : "backfill_missing_analysis"
                        )
                        queuedForAnalysis += 1
                    }

                    // Skip if not forcing reanalysis
                    if !options.forceReanalysis {
                        continue
                    }
                } else if !options.dryRun {
                    // Register new asset
                    let inspection = ImageAssetInspector.inspect(path: asset.resolvedPath)

                    let assetID = try await store.registerAsset(
                        resolvedPath: asset.resolvedPath,
                        projectRelativePath: asset.projectRelativePath,
                        filename: URL(fileURLWithPath: asset.resolvedPath).lastPathComponent,
                        mimeType: inspection.mimeType,
                        width: inspection.width,
                        height: inspection.height,
                        fileSizeBytes: inspection.fileSizeBytes,
                        contentHashSHA256: inspection.contentHashSHA256
                    )

                    // Link to domain object
                    try await store.linkAsset(
                        assetID: assetID,
                        kind: asset.linkKind,
                        ownerID: asset.ownerID,
                        ownerParentID: asset.ownerParentID,
                        moment: asset.moment,
                        workflow: asset.workflow,
                        context: asset.context
                    )

                    newlyRegistered += 1
                    try await coordinator?.enqueue(assetID: assetID, reason: "backfill")
                    queuedForAnalysis += 1
                } else {
                    newlyRegistered += 1
                }
            } catch {
                errors.append("Failed to process \(asset.resolvedPath): \(error.localizedDescription)")
            }
        }

        // Mark missing assets
        let missingCount: Int
        if !options.dryRun && options.markMissingAssets && options.linkKinds == nil {
            missingCount = (try? await store.markMissingAssets(notSeenSince: startedAt)) ?? 0
        } else {
            missingCount = 0
        }

        return BackfillReport(
            totalDiscovered: discovery.totalCount,
            alreadyRegistered: alreadyRegistered,
            newlyRegistered: newlyRegistered,
            missingAssets: missingCount,
            queuedForAnalysis: queuedForAnalysis,
            errors: errors,
            isDryRun: options.dryRun
        )
    }

    /// Quick report without modifying anything.
    public func dryRunReport(linkKinds: [ImageAssetLinkKind]? = nil) async -> BackfillReport {
        await backfill(options: BackfillOptions(dryRun: true, linkKinds: linkKinds))
    }

    private func shouldQueueExistingAsset(
        _ assetID: String,
        options: BackfillOptions
    ) async throws -> Bool {
        guard options.forceReanalysis || options.enqueueExistingWithoutRuns || options.enqueueExistingMissingAnalysis else {
            return false
        }
        if options.forceReanalysis {
            return true
        }

        if options.enqueueExistingMissingAnalysis {
            let latestMetadata = try await store.latestVisualMetadataForAsset(assetID)
            let embeddingCount = (try await store.querySingle("""
                SELECT COUNT(*) AS count
                FROM image_embeddings
                WHERE image_asset_id = ?
            """, [assetID])?["count"] as? Int) ?? 0
            if latestMetadata != nil && embeddingCount > 0 {
                return false
            }

            let jobs = try await coordinator?.jobsForAsset(assetID) ?? []
            return !jobs.contains { job in
                job.status == .pending || job.status == .running
            }
        }

        guard let coordinator else {
            return false
        }

        let runs = try await store.runsForAsset(assetID)
        if !runs.isEmpty {
            return false
        }

        let jobs = try await coordinator.jobsForAsset(assetID)
        return !jobs.contains { job in
            job.status == .pending || job.status == .running
        }
    }
}
