import Foundation
import CryptoKit

actor ProjectMirrorSession {
    let sourceProjectURL: URL
    let workingProjectURL: URL
    let database: ProjectDatabase

    private let remoteClient: ProjectRemoteClient
    private let clientID: String
    private let legacySyncActorID: String
    private let syncActorID: String

    private var lastRemoteChangeToken: Int64 = 0
    private var lastRemoteAssets: [String: NPProjectAssetRecord] = [:]
    private var lastLocalAssets: [String: NPProjectAssetRecord] = [:]
    private var syncTask: Task<Void, Never>?
    private var isSyncing = false
    private var syncQueued = false

    deinit {
        syncTask?.cancel()
    }

    static func open(
        sourceProjectURL: URL,
        remoteClient: ProjectRemoteClient
    ) async throws -> ProjectMirrorSession {
        let workingProjectURL = ProjectClientIdentity.mirrorProjectURL(
            for: sourceProjectURL
        )
        let session = ProjectMirrorSession(
            sourceProjectURL: sourceProjectURL,
            workingProjectURL: workingProjectURL,
            remoteClient: remoteClient
        )
        try await session.bootstrap()
        await session.startBackgroundSync()
        return session
    }

    init(
        sourceProjectURL: URL,
        workingProjectURL: URL,
        remoteClient: ProjectRemoteClient
    ) {
        self.sourceProjectURL = sourceProjectURL.resolvingSymlinksInPath().standardizedFileURL
        self.workingProjectURL = workingProjectURL.resolvingSymlinksInPath().standardizedFileURL
        self.remoteClient = remoteClient
        self.clientID = ProjectClientIdentity.sharedClientID()
        self.legacySyncActorID = ProjectClientIdentity.actorID(for: "novotro-sync")
        self.syncActorID = ProjectClientIdentity.actorID(for: "sync")
        self.database = ProjectDatabase(
            projectURL: self.workingProjectURL,
            databaseDirectoryURL: ProjectClientIdentity.projectDatabaseDirectoryURL(for: sourceProjectURL)
        )
    }

    func ensureCurrentIndex(forceRebuild: Bool = false) async throws {
        if forceRebuild {
            try await database.ensureCurrentIndex(forceRebuild: true)
            lastLocalAssets = try scanLocalAssets()
            return
        }
        try await database.ensureCurrentIndex()
    }

    func syncNow() async throws {
        try await performSyncCycle()
    }

    func stopBackgroundSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    func exportLegacy() async throws {
        try await database.exportLegacy()
        lastLocalAssets = try scanLocalAssets()
        try await remoteClient.exportLegacy()
        lastRemoteAssets = try await remoteAssetMap()
        lastRemoteChangeToken = try await remoteClient.currentChangeToken()
    }

    func upsertProjectFile(path: String, jsonData: Data, actorID: String) async throws {
        try await performDatabaseMutation(
            localMutation: { database in
                try await database.upsertProjectFile(path: path, jsonData: jsonData, actorID: actorID)
            },
            remoteMutation: { client in
                try await client.upsertProjectFile(path: path, jsonData: jsonData, actorID: actorID)
            }
        )
    }

    func updateSongText(relativePath: String, lyrics: String, versionID: UUID?, actorID: String) async throws {
        try await performDatabaseMutation(
            localMutation: { database in
                try await database.updateSongText(
                    relativePath: relativePath,
                    lyrics: lyrics,
                    versionID: versionID,
                    actorID: actorID
                )
            },
            remoteMutation: { client in
                try await client.updateSongText(
                    relativePath: relativePath,
                    lyrics: lyrics,
                    versionID: versionID,
                    actorID: actorID
                )
            }
        )
    }

    func updateSongPlayback(relativePath: String, versionID: UUID?, playbackJSON: Data?, actorID: String) async throws {
        try await performDatabaseMutation(
            localMutation: { database in
                try await database.updateSongPlayback(
                    relativePath: relativePath,
                    versionID: versionID,
                    playbackJSON: playbackJSON,
                    actorID: actorID
                )
            },
            remoteMutation: { client in
                try await client.updateSongPlayback(
                    relativePath: relativePath,
                    versionID: versionID,
                    playbackJSON: playbackJSON,
                    actorID: actorID
                )
            }
        )
    }

    func upsertAnimationScene(owsPath: String, jsonData: Data, actorID: String) async throws {
        try await performDatabaseMutation(
            localMutation: { database in
                try await database.upsertAnimationScene(owsPath: owsPath, jsonData: jsonData, actorID: actorID)
            },
            remoteMutation: { client in
                try await client.upsertAnimationScene(owsPath: owsPath, jsonData: jsonData, actorID: actorID)
            }
        )
    }

    func upsertScene(_ scene: NPSceneRecord, actorID: String) async throws {
        try await performDatabaseMutation(
            localMutation: { database in
                try await database.upsertScene(scene, actorID: actorID)
            },
            remoteMutation: { client in
                try await client.upsertScene(scene, actorID: actorID)
            }
        )
    }

    private func bootstrap() async throws {
        await reportProgress(
            phaseTitle: "Preparing Local Mirror",
            detail: "Checking the existing project cache on this Mac."
        )
        try FileManager.default.createDirectory(at: workingProjectURL, withIntermediateDirectories: true)

        let localAssets = try scanLocalAssets()
        
        await reportProgress(
            phaseTitle: "Sizing First Sync",
            detail: "Asking the server how large this project is before downloading it."
        )
        let summary = try await remoteClient.summarizeProjectAssets()

        // Fix 1: Detect an incomplete or empty mirror.
        // If localAssets has much fewer entries than the server summary, trigger a full download.
        if localAssets.isEmpty || localAssets.count < summary.assetCount / 2 {
            await reportProgress(
                phaseTitle: "Scanning Server Files",
                detail: serverInventoryMessage(summary: summary),
                totalUnitCount: summary.assetCount,
                totalBytes: summary.totalBytes
            )
            try await downloadFullMirror(summary: summary)
        } else {
            lastLocalAssets = localAssets
            await reportProgress(
                phaseTitle: "Checking Local Mirror",
                detail: "Found \(localAssets.count) cached files. Verifying the local index before opening.",
                totalUnitCount: summary.assetCount,
                totalBytes: summary.totalBytes
            )
            try await database.ensureCurrentIndex()
        }

        await reportProgress(
            phaseTitle: "Comparing Server Files",
            detail: "Fetching latest file checksums from the server. This can take a moment for large projects.",
            totalUnitCount: summary.assetCount,
            totalBytes: summary.totalBytes
        )

        lastRemoteAssets = try await remoteAssetMap()
        lastRemoteChangeToken = try await remoteClient.currentChangeToken()

        if localAssets.isEmpty == false {
            await reportProgress(
                phaseTitle: "Checking For Changes",
                detail: "Comparing the local mirror against the latest server changes.",
                totalUnitCount: summary.assetCount,
                totalBytes: summary.totalBytes
            )
            try await performSyncCycle()
        }
    }

    private func startBackgroundSync() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                do {
                    try await self.performSyncCycle()
                } catch {
                    if Self.shouldIgnoreBackgroundSyncError(error) {
                        return
                    }
                    print("[ProjectMirrorSync] Background sync error: \(error)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func performSyncCycle() async throws {
        if isSyncing {
            syncQueued = true
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
        }

        try await syncLocalAssetChanges()
        try await syncRemoteDatabaseChanges()
        try await syncRemoteAssetChanges()

        if syncQueued {
            syncQueued = false
            try await performSyncCycle()
        }
    }

    private func performDatabaseMutation(
        localMutation: @Sendable (ProjectDatabase) async throws -> Void,
        remoteMutation: @Sendable (ProjectRemoteClient) async throws -> Void
    ) async throws {
        try await localMutation(database)
        try await database.exportLegacy()
        lastLocalAssets = try scanLocalAssets()

        try await remoteMutation(remoteClient)
        try await remoteClient.exportLegacy()

        lastRemoteChangeToken = try await remoteClient.currentChangeToken()
        lastRemoteAssets = try await remoteAssetMap()
    }

    private func downloadFullMirror(summary: NPProjectAssetSummary) async throws {
        let remoteAssets = try await remoteClient.listProjectAssets()
        let remoteMap = Dictionary(uniqueKeysWithValues: remoteAssets.map { ($0.path, $0) })
        let localPaths = Set(try scanLocalAssets().keys)
        let remotePaths = Set(remoteMap.keys)
        let totalAssets = remoteAssets.count
        let totalBytes = summary.totalBytes > 0
            ? summary.totalBytes
            : remoteAssets.reduce(Int64.zero) { $0 + $1.fileSize }

        for relativePath in localPaths.subtracting(remotePaths) {
            try deleteLocalFile(relativePath: relativePath)
        }

        var completedAssets = 0
        var completedBytes: Int64 = 0
        if totalAssets > 0 {
            await reportProgress(
                phaseTitle: "Downloading Project Files",
                detail: "Copying the first project mirror to this Mac.",
                completedUnitCount: completedAssets,
                totalUnitCount: totalAssets,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
        }

        for asset in remoteAssets {
            await reportProgress(
                phaseTitle: "Downloading Project Files",
                detail: "Copying \(asset.path) to the local mirror.",
                completedUnitCount: completedAssets,
                totalUnitCount: totalAssets,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                currentItemPath: asset.path
            )
            guard let data = try await remoteClient.downloadProjectAsset(path: asset.path) else { continue }
            try writeLocalFile(relativePath: asset.path, data: data)
            completedAssets += 1
            completedBytes += asset.fileSize
            await reportProgress(
                phaseTitle: "Downloading Project Files",
                detail: "Copied \(asset.path) to the local mirror.",
                completedUnitCount: completedAssets,
                totalUnitCount: totalAssets,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                currentItemPath: asset.path
            )
        }

        await reportProgress(
            phaseTitle: "Building Local Index",
            detail: "Creating the searchable project database on this Mac."
        )
        try await database.ensureCurrentIndex(forceRebuild: true)
        lastRemoteAssets = remoteMap
        lastLocalAssets = try scanLocalAssets()
    }

    private func syncLocalAssetChanges() async throws {
        let currentLocalAssets = try scanLocalAssets()
        let changedPaths = currentLocalAssets.keys.filter { path in
            currentLocalAssets[path]?.contentHash != lastLocalAssets[path]?.contentHash
        }.sorted()
        let deletedPaths = Set(lastLocalAssets.keys).subtracting(currentLocalAssets.keys).sorted()

        guard changedPaths.isEmpty == false || deletedPaths.isEmpty == false else { return }

        for relativePath in deletedPaths {
            try await remoteClient.deleteProjectAsset(path: relativePath)
        }

        for relativePath in changedPaths {
            let fileURL = projectFileURL(for: relativePath)
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            try await remoteClient.uploadProjectAsset(path: relativePath, data: data)
        }

        let touchedPaths = changedPaths + deletedPaths
        if touchedPaths.contains(where: Self.requiresDatabaseRebuild(for:)) {
            try await database.ensureCurrentIndex(forceRebuild: true)
            try await recordMirrorChanges(changedPaths: changedPaths, deletedPaths: deletedPaths)
        }

        lastLocalAssets = try scanLocalAssets()
        lastRemoteAssets = try await remoteAssetMap()
        lastRemoteChangeToken = try await remoteClient.currentChangeToken()
    }

    private func syncRemoteDatabaseChanges() async throws {
        let remoteToken = try await remoteClient.currentChangeToken()
        guard remoteToken > lastRemoteChangeToken else { return }

        let changes = try await remoteClient.listChanges(since: lastRemoteChangeToken)
        guard changes.isEmpty == false else {
            lastRemoteChangeToken = remoteToken
            return
        }

        var appliedChanges = false
        for change in changes {
            lastRemoteChangeToken = max(lastRemoteChangeToken, change.changeID)
            guard shouldApplyRemoteChange(actorID: change.actorID) else { continue }

            switch change.entityType {
            case "scene":
                guard let scene = try await remoteClient.loadScene(relativePath: change.entityKey) else { continue }
                try await database.upsertScene(scene, actorID: syncActorID)
                appliedChanges = true

            case "project_file":
                guard let file = try await remoteClient.loadProjectFile(path: change.entityKey) else { continue }
                try await database.upsertProjectFile(path: file.path, jsonData: file.jsonData, actorID: syncActorID)
                appliedChanges = true

            default:
                break
            }
        }

        if appliedChanges {
            try await database.exportLegacy()
            lastLocalAssets = try scanLocalAssets()
            lastRemoteAssets = try await remoteAssetMap()
        }

        lastRemoteChangeToken = max(lastRemoteChangeToken, remoteToken)
    }

    private func syncRemoteAssetChanges() async throws {
        let remoteAssets = try await remoteAssetMap()
        let currentLocalAssets = try scanLocalAssets()

        // Fix 2: Compare server assets against LOCAL assets, not just previous server snapshots.
        // This ensures missing local files are detected and downloaded.
        let changedPaths = remoteAssets.keys.filter { path in
            currentLocalAssets[path]?.contentHash != remoteAssets[path]?.contentHash
        }.sorted()
        let deletedPaths = Set(currentLocalAssets.keys).subtracting(remoteAssets.keys).sorted()

        guard changedPaths.isEmpty == false || deletedPaths.isEmpty == false else {
            lastRemoteAssets = remoteAssets
            return
        }

        for relativePath in deletedPaths {
            try deleteLocalFile(relativePath: relativePath)
        }

        // Feature 4: Progress reporting for the delta sync.
        let totalToDownload = changedPaths.reduce(Int64(0)) { $0 + (remoteAssets[$1]?.fileSize ?? 0) }
        var completedFiles = 0
        var completedBytes: Int64 = 0

        for relativePath in changedPaths {
            await reportProgress(
                phaseTitle: "Syncing Project Files",
                detail: "Downloading \(relativePath)",
                completedUnitCount: completedFiles,
                totalUnitCount: changedPaths.count,
                completedBytes: completedBytes,
                totalBytes: totalToDownload,
                currentItemPath: relativePath
            )
            
            guard let data = try await remoteClient.downloadProjectAsset(path: relativePath) else { continue }
            try writeLocalFile(relativePath: relativePath, data: data)
            
            completedFiles += 1
            completedBytes += remoteAssets[relativePath]?.fileSize ?? Int64(data.count)
        }

        if changedPaths.isEmpty == false {
            await reportProgress(
                phaseTitle: "Syncing Project Files",
                detail: "All files up to date.",
                completedUnitCount: changedPaths.count,
                totalUnitCount: changedPaths.count,
                completedBytes: totalToDownload,
                totalBytes: totalToDownload
            )
        }

        lastRemoteAssets = remoteAssets
        lastLocalAssets = try scanLocalAssets()

        let touchedPaths = changedPaths + deletedPaths
        if touchedPaths.contains(where: Self.requiresDatabaseRebuild(for:)) {
            try await database.ensureCurrentIndex(forceRebuild: true)
            try await recordMirrorChanges(changedPaths: changedPaths, deletedPaths: deletedPaths)
            lastLocalAssets = try scanLocalAssets()
        }
    }

    private func shouldApplyRemoteChange(actorID: String?) -> Bool {
        guard let actorID else { return true }
        if actorID == syncActorID || actorID == legacySyncActorID {
            return false
        }
        return actorID.hasSuffix("@\(clientID)") == false
    }

    private func recordMirrorChanges(changedPaths: [String], deletedPaths: [String]) async throws {
        let changedSet = Set(changedPaths)
        let deletedSet = Set(deletedPaths)
        let relevantPaths = changedSet.union(deletedSet).sorted()

        for path in relevantPaths where Self.requiresDatabaseRebuild(for: path) {
            let scope = Self.changeScope(for: path)
            let kind = deletedSet.contains(path) ? "delete" : "upsert"
            try await database.recordChange(scope: scope, entityID: path, kind: kind, actorID: syncActorID)
        }
    }

    private func remoteAssetMap() async throws -> [String: NPProjectAssetRecord] {
        Dictionary(uniqueKeysWithValues: try await remoteClient.listProjectAssets().map { ($0.path, $0) })
    }

    private func scanLocalAssets() throws -> [String: NPProjectAssetRecord] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: workingProjectURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var assets: [String: NPProjectAssetRecord] = [:]
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.hasDirectoryPath == false else { continue }
            let relativePath = relativePath(for: fileURL)
            guard relativePath.hasPrefix(".novotro/") == false else { continue }

            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fileSize = Int64(values.fileSize ?? 0)
            assets[relativePath] = NPProjectAssetRecord(
                path: relativePath,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                contentHash: Self.assetSignature(fileSize: fileSize, modifiedAt: modifiedAt)
            )
        }

        return assets
    }

    private func writeLocalFile(relativePath: String, data: Data) throws {
        let fileManager = FileManager.default
        let fileURL = projectFileURL(for: relativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func deleteLocalFile(relativePath: String) throws {
        let fileManager = FileManager.default
        let fileURL = projectFileURL(for: relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
        try pruneEmptyDirectories(startingAt: fileURL.deletingLastPathComponent())
    }

    private func pruneEmptyDirectories(startingAt directoryURL: URL) throws {
        let fileManager = FileManager.default
        var currentURL = directoryURL
        while currentURL.path.hasPrefix(workingProjectURL.path), currentURL.path != workingProjectURL.path {
            let contents = try fileManager.contentsOfDirectory(atPath: currentURL.path)
            guard contents.isEmpty else { return }
            try fileManager.removeItem(at: currentURL)
            currentURL = currentURL.deletingLastPathComponent()
        }
    }

    private func projectFileURL(for relativePath: String) -> URL {
        workingProjectURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    private func relativePath(for fileURL: URL) -> String {
        let basePath = workingProjectURL.path.hasSuffix("/") ? workingProjectURL.path : workingProjectURL.path + "/"
        let filePath = fileURL.path
        if filePath.hasPrefix(basePath) {
            return String(filePath.dropFirst(basePath.count))
        }

        let normalizedRoot = workingProjectURL.resolvingSymlinksInPath().standardizedFileURL
        let normalizedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = normalizedRoot.pathComponents
        let fileComponents = normalizedFile.pathComponents

        if fileComponents.starts(with: rootComponents) {
            return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }

        let normBasePath = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        return normalizedFile.path.replacingOccurrences(of: normBasePath, with: "")
    }

    private static func assetSignature(fileSize: Int64, modifiedAt: Date) -> String {
        let payload = "\(fileSize)|\(modifiedAt.timeIntervalSince1970)".data(using: .utf8) ?? Data()
        return Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func changeScope(for relativePath: String) -> String {
        if relativePath.hasPrefix("Songs/") && relativePath.hasSuffix(".ows") {
            return "scene"
        }
        return "project_file"
    }

    private static func requiresDatabaseRebuild(for relativePath: String) -> Bool {
        if relativePath.hasPrefix("Songs/") && relativePath.hasSuffix(".ows") {
            return true
        }
        if relativePath == "index.json" || relativePath == "Instruments.json" {
            return true
        }
        let managedPrefixes = [
            "Metadata/",
            "Characters/",
            "Animate/",
            "Scenes/",    // Wave D
            "Places/",    // Wave D
            "Settings/",  // Wave D
        ]
        return managedPrefixes.contains { relativePath.hasPrefix($0) }
    }

    private func reportProgress(
        phaseTitle: String,
        detail: String,
        completedUnitCount: Int? = nil,
        totalUnitCount: Int? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        currentItemPath: String? = nil
    ) async {
        await MainActor.run {
            ProjectOpenProgressCenter.shared.update(
                projectURL: sourceProjectURL,
                phaseTitle: phaseTitle,
                detail: detail,
                completedUnitCount: completedUnitCount,
                totalUnitCount: totalUnitCount,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                currentItemPath: currentItemPath
            )
        }
    }

    private func serverInventoryMessage(summary: NPProjectAssetSummary) -> String {
        if summary.assetCount == 0 {
            return "Preparing checksums for the server project. No client-visible files were found yet."
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.isAdaptive = true
        let sizeString = formatter.string(fromByteCount: summary.totalBytes)
        return "Preparing checksums for \(summary.assetCount) files (\(sizeString)) on the server. Large audio and SoundFont assets can make this step take a while."
    }

    private static func shouldIgnoreBackgroundSyncError(_ error: Error) -> Bool {
        if let remoteError = error as? ProjectRemoteClientError {
            switch remoteError {
            case .connectionCancelled:
                return true
            case let .invalidResponse(message):
                return message == "Connection closed before response completed"
            default:
                return false
            }
        }
        return false
    }
}

typealias NovotroProjectMirrorSession = ProjectMirrorSession
