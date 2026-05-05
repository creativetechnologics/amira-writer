import Foundation
import Network

public typealias ProjectConnectionMode = ProjectServiceConnectionMode

public actor ProjectConnection {
    private enum Backend: Sendable {
        case local(ProjectDatabase)
        case mirrored(ProjectMirrorSession)
        case remote(ProjectRemoteClient)
    }

    public nonisolated let projectURL: URL
    public nonisolated let workingProjectURL: URL
    public nonisolated let mode: ProjectConnectionMode

    private let backend: Backend

    private init(projectURL: URL, workingProjectURL: URL, mode: ProjectConnectionMode, backend: Backend) {
        self.projectURL = projectURL
        self.workingProjectURL = workingProjectURL
        self.mode = mode
        self.backend = backend
    }

    deinit {
        guard case let .mirrored(session) = backend else { return }
        Task {
            await session.stopBackgroundSync()
        }
    }

    public static func open(projectURL: URL, preferService: Bool? = nil) async throws -> ProjectConnection {
        let normalizedURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let shouldUseService = preferService ?? shouldPreferRemoteService(for: normalizedURL)
        if shouldUseService {
            await MainActor.run {
                ProjectOpenProgressCenter.shared.start(
                    projectURL: normalizedURL,
                phaseTitle: "Connecting To Project Service",
                    detail: "Checking the remote project service and preparing the local mirror."
                )
            }
            let client = try await ProjectRemoteClient.discover(projectURL: normalizedURL)
            await MainActor.run {
                ProjectOpenProgressCenter.shared.update(
                    projectURL: normalizedURL,
                    phaseTitle: "Preparing Local Mirror",
                    detail: "Inspecting any project files already cached on this Mac."
                )
            }
            let session = try await ProjectMirrorSession.open(
                sourceProjectURL: normalizedURL,
                remoteClient: client
            )
            return ProjectConnection(
                projectURL: normalizedURL,
                workingProjectURL: session.workingProjectURL,
                mode: .remoteService,
                backend: .mirrored(session)
            )
        }

        let database = ProjectDatabase(
            projectURL: normalizedURL,
            databaseDirectoryURL: ProjectClientIdentity.projectDatabaseDirectoryURL(for: normalizedURL)
        )
        return ProjectConnection(
            projectURL: normalizedURL,
            workingProjectURL: normalizedURL,
            mode: .local,
            backend: .local(database)
        )
    }

    public func ensureCurrentIndex(forceRebuild: Bool = false) async throws {
        switch backend {
        case let .local(database):
            try await database.ensureCurrentIndex(forceRebuild: forceRebuild)
        case let .mirrored(session):
            try await session.ensureCurrentIndex(forceRebuild: forceRebuild)
        case let .remote(client):
            try await client.ensureCurrentIndex(forceRebuild: forceRebuild)
        }
    }

    public func loadProjectSummary() async throws -> NPProjectSummary {
        switch backend {
        case let .local(database):
            return try await database.loadProjectSummary()
        case let .mirrored(session):
            return try await session.database.loadProjectSummary()
        case let .remote(client):
            return try await client.loadProjectSummary()
        }
    }

    public func loadProject() async throws -> NPProjectRecord {
        switch backend {
        case let .local(database):
            return try await database.loadProject()
        case let .mirrored(session):
            var project = try await session.database.loadProject()
            project.projectFiles = project.projectFiles.filter { Self.isClientVisibleProjectFile($0.path) }
            return project
        case let .remote(client):
            return try await client.loadProject()
        }
    }

    public func loadProjectScenes(
        includeVersions: Bool = true,
        includeRootJSON: Bool = true,
        includeAnimateSceneJSON: Bool = true,
        includeVersionJSON: Bool = true,
        includePlaybackJSON: Bool = true
    ) async throws -> [NPSceneRecord] {
        switch backend {
        case let .local(database):
            return try await database.loadProjectScenes(
                includeVersions: includeVersions,
                includeRootJSON: includeRootJSON,
                includeAnimateSceneJSON: includeAnimateSceneJSON,
                includeVersionJSON: includeVersionJSON,
                includePlaybackJSON: includePlaybackJSON
            )
        case let .mirrored(session):
            return try await session.database.loadProjectScenes(
                includeVersions: includeVersions,
                includeRootJSON: includeRootJSON,
                includeAnimateSceneJSON: includeAnimateSceneJSON,
                includeVersionJSON: includeVersionJSON,
                includePlaybackJSON: includePlaybackJSON
            )
        case let .remote(client):
            return try await client.loadProjectScenes(
                includeVersions: includeVersions,
                includeRootJSON: includeRootJSON,
                includeAnimateSceneJSON: includeAnimateSceneJSON,
                includeVersionJSON: includeVersionJSON,
                includePlaybackJSON: includePlaybackJSON
            )
        }
    }

    public func loadCharacters() async throws -> [NPCharacterRecord] {
        switch backend {
        case let .local(database):
            return try await database.loadCharacters()
        case let .mirrored(session):
            return try await session.database.loadCharacters()
        case let .remote(client):
            return try await client.loadCharacters()
        }
    }

    public func loadScene(relativePath: String) async throws -> NPSceneRecord? {
        switch backend {
        case let .local(database):
            return try await database.loadScene(relativePath: relativePath)
        case let .mirrored(session):
            return try await session.database.loadScene(relativePath: relativePath)
        case let .remote(client):
            return try await client.loadScene(relativePath: relativePath)
        }
    }

    public func currentChangeToken() async throws -> Int64 {
        switch backend {
        case let .local(database):
            return try await database.currentChangeToken()
        case let .mirrored(session):
            return try await session.database.currentChangeToken()
        case let .remote(client):
            return try await client.currentChangeToken()
        }
    }

    public func listChanges(since changeID: Int64) async throws -> [ChangeEvent] {
        switch backend {
        case let .local(database):
            return try await database.listChanges(since: changeID)
        case let .mirrored(session):
            return try await session.database.listChanges(since: changeID)
        case let .remote(client):
            return try await client.listChanges(since: changeID)
        }
    }

    public func exportLegacy() async throws {
        switch backend {
        case let .local(database):
            try await database.exportLegacy()
        case let .mirrored(session):
            try await session.exportLegacy()
        case let .remote(client):
            try await client.exportLegacy()
        }
    }

    public func refreshLegacyFingerprint() async throws {
        switch backend {
        case let .local(database):
            try await database.refreshLegacyFingerprint()
        case let .mirrored(session):
            try await session.database.refreshLegacyFingerprint()
        case .remote:
            break
        }
    }

    public func loadProjectFile(path: String) async throws -> NPProjectFileRecord? {
        switch backend {
        case let .local(database):
            return try await database.loadProjectFile(path: path)
        case let .mirrored(session):
            return try await session.database.loadProjectFile(path: path)
        case let .remote(client):
            return try await client.loadProjectFile(path: path)
        }
    }

    public func upsertProjectFile(path: String, jsonData: Data, actorID: String = "system") async throws {
        switch backend {
        case let .local(database):
            try await database.upsertProjectFile(path: path, jsonData: jsonData, actorID: actorID)
        case let .mirrored(session):
            try await session.upsertProjectFile(path: path, jsonData: jsonData, actorID: actorID)
        case let .remote(client):
            try await client.upsertProjectFile(path: path, jsonData: jsonData, actorID: actorID)
        }
    }

    public func updateSongText(
        relativePath: String,
        lyrics: String,
        versionID: UUID? = nil,
        actorID: String = "system"
    ) async throws {
        switch backend {
        case let .local(database):
            try await database.updateSongText(relativePath: relativePath, lyrics: lyrics, versionID: versionID, actorID: actorID)
        case let .mirrored(session):
            try await session.updateSongText(relativePath: relativePath, lyrics: lyrics, versionID: versionID, actorID: actorID)
        case let .remote(client):
            try await client.updateSongText(relativePath: relativePath, lyrics: lyrics, versionID: versionID, actorID: actorID)
        }
    }

    public func updateSongPlayback(
        relativePath: String,
        versionID: UUID? = nil,
        playbackJSON: Data?,
        actorID: String = "system"
    ) async throws {
        switch backend {
        case let .local(database):
            try await database.updateSongPlayback(
                relativePath: relativePath,
                versionID: versionID,
                playbackJSON: playbackJSON,
                actorID: actorID
            )
        case let .mirrored(session):
            try await session.updateSongPlayback(
                relativePath: relativePath,
                versionID: versionID,
                playbackJSON: playbackJSON,
                actorID: actorID
            )
        case let .remote(client):
            try await client.updateSongPlayback(
                relativePath: relativePath,
                versionID: versionID,
                playbackJSON: playbackJSON,
                actorID: actorID
            )
        }
    }

    public func upsertAnimationScene(
        owsPath: String,
        jsonData: Data,
        actorID: String = "system"
    ) async throws {
        switch backend {
        case let .local(database):
            try await database.upsertAnimationScene(owsPath: owsPath, jsonData: jsonData, actorID: actorID)
        case let .mirrored(session):
            try await session.upsertAnimationScene(owsPath: owsPath, jsonData: jsonData, actorID: actorID)
        case let .remote(client):
            try await client.upsertAnimationScene(owsPath: owsPath, jsonData: jsonData, actorID: actorID)
        }
    }

    public func upsertScene(_ scene: NPSceneRecord, actorID: String = "system") async throws {
        switch backend {
        case let .local(database):
            try await database.upsertScene(scene, actorID: actorID)
        case let .mirrored(session):
            try await session.upsertScene(scene, actorID: actorID)
        case let .remote(client):
            try await client.upsertScene(scene, actorID: actorID)
        }
    }

    public nonisolated static func shouldPreferRemoteService(for projectURL: URL) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["PROJECT_SERVICE_DISABLE"] == "1" || environment["AMIRA_DISABLE_PROJECT_SERVICE"] == "1" || environment["NOVOTRO_DISABLE_PROJECT_SERVICE"] == "1" {
            return false
        }
        if environment["PROJECT_SERVICE_FORCE"] == "1" || environment["AMIRA_FORCE_PROJECT_SERVICE"] == "1" || environment["NOVOTRO_FORCE_PROJECT_SERVICE"] == "1" {
            return true
        }
        guard projectURL.pathExtension.lowercased() == "owp" else { return false }
        let registry = ProjectServerRegistry()
        if let managedProjectURL = try? registry.managedProjectURL(forProjectURL: projectURL),
           managedProjectURL.resolvingSymlinksInPath().standardizedFileURL.path != projectURL.resolvingSymlinksInPath().standardizedFileURL.path {
            return true
        }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey]
        let values = try? projectURL.resourceValues(forKeys: keys)
        if values?.volumeIsLocal == false {
            return true
        }
        return false
    }

    private nonisolated static func isClientVisibleProjectFile(_ path: String) -> Bool {
        if path == "index.json" || path == "Instruments.json" || path == "project.json" || path == "characters.json" {
            return true
        }
        let prefixes = [
            "Metadata/",
            "Characters/",
            "Animate/",
            "Scenes/",    // Wave D
            "Places/",    // Wave D
            "Settings/",  // Wave D
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }
}

public actor ProjectRemoteClient {
    public static let bonjourServiceType = "_amira-project._tcp"

    private let endpoint: NWEndpoint
    private let projectURL: URL
    private let authToken: String

    private init(endpoint: NWEndpoint, projectURL: URL, authToken: String) {
        self.endpoint = endpoint
        self.projectURL = projectURL
        self.authToken = authToken
    }

    public static func discover(projectURL: URL) async throws -> ProjectRemoteClient {
        guard let authToken = ProjectServiceConfiguration.loadAuthToken(),
              !authToken.isEmpty else {
            throw ProjectRemoteClientError.missingAuthToken
        }

        var lastError: Error?

        for endpoint in ProjectServiceEndpointDiscovery.candidateEndpoints() {
            let client = ProjectRemoteClient(endpoint: endpoint, projectURL: projectURL, authToken: authToken)
            do {
                try await ProjectAsyncTimeout.withTimeout(
                    seconds: 2.5,
                    description: "connecting to \(endpointDescription(endpoint))"
                ) {
                    try await client.pingServer()
                }
                try await client.confirmProjectAccess()
                ProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(endpoint)
                return client
            } catch {
                lastError = error
            }
        }

        if let bonjourEndpoints = try? await discoverBonjourEndpoints() {
            for endpoint in bonjourEndpoints {
                let client = ProjectRemoteClient(endpoint: endpoint, projectURL: projectURL, authToken: authToken)
                do {
                    try await ProjectAsyncTimeout.withTimeout(
                        seconds: 2.5,
                        description: "connecting to \(endpointDescription(endpoint))"
                    ) {
                        try await client.pingServer()
                    }
                    try await client.confirmProjectAccess()
                    ProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(endpoint)
                    return client
                } catch {
                    lastError = error
                }
            }
        }

        throw lastError ?? ProjectRemoteClientError.noCompatibleServiceFound(projectURL.lastPathComponent)
    }

    public static func connect(endpoint: NWEndpoint, projectURL: URL, authToken: String) -> ProjectRemoteClient {
        ProjectRemoteClient(endpoint: endpoint, projectURL: projectURL, authToken: authToken)
    }

    public func ensureCurrentIndex(forceRebuild: Bool = false) async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .ensureCurrentIndex,
                projectPath: projectURL.path,
                forceRebuild: forceRebuild
            )
        )
    }

    public func loadProjectSummary() async throws -> NPProjectSummary {
        let response = try await send(
            ProjectServiceRequest(
                operation: .loadProjectSummary,
                projectPath: projectURL.path
            )
        )
        guard let summary = response.projectSummary else {
            throw ProjectRemoteClientError.invalidResponse("Missing project summary")
        }
        return summary
    }

    public func loadProject() async throws -> NPProjectRecord {
        let response = try await send(
            ProjectServiceRequest(
                operation: .loadProject,
                projectPath: projectURL.path
            )
        )
        guard let project = response.project else {
            throw ProjectRemoteClientError.invalidResponse("Missing project record")
        }
        return project
    }

    public func loadProjectScenes(
        includeVersions: Bool = true,
        includeRootJSON: Bool = true,
        includeAnimateSceneJSON: Bool = true,
        includeVersionJSON: Bool = true,
        includePlaybackJSON: Bool = true
    ) async throws -> [NPSceneRecord] {
        let response = try await send(
            ProjectServiceRequest(
                operation: .loadProjectScenes,
                projectPath: projectURL.path,
                includeVersions: includeVersions,
                includeRootJSON: includeRootJSON,
                includeAnimateSceneJSON: includeAnimateSceneJSON,
                includeVersionJSON: includeVersionJSON,
                includePlaybackJSON: includePlaybackJSON
            )
        )
        return response.scenes ?? []
    }

    public func loadCharacters() async throws -> [NPCharacterRecord] {
        let response = try await send(
            ProjectServiceRequest(
                operation: .loadCharacters,
                projectPath: projectURL.path
            )
        )
        return response.characters ?? []
    }

    public func loadScene(relativePath: String) async throws -> NPSceneRecord? {
        let response = try await send(
            ProjectServiceRequest(
                operation: .loadScene,
                projectPath: projectURL.path,
                relativePath: relativePath
            )
        )
        return response.scene
    }

    public func currentChangeToken() async throws -> Int64 {
        let response = try await send(
            ProjectServiceRequest(
                operation: .currentChangeToken,
                projectPath: projectURL.path
            )
        )
        return response.changeToken ?? 0
    }

    public func listChanges(since changeID: Int64) async throws -> [ChangeEvent] {
        let response = try await send(
            ProjectServiceRequest(
                operation: .listChanges,
                projectPath: projectURL.path,
                changeID: changeID
            )
        )
        return response.changes ?? []
    }

    public func exportLegacy() async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .exportLegacy,
                projectPath: projectURL.path
            )
        )
    }

    public func loadProjectFile(path: String) async throws -> NPProjectFileRecord? {
        let response = try await send(
            ProjectServiceRequest(
                operation: .loadProjectFile,
                projectPath: projectURL.path,
                filePath: path
            )
        )
        return response.projectFile
    }

    public func listProjectAssets() async throws -> [NPProjectAssetRecord] {
        let response = try await send(
            ProjectServiceRequest(
                operation: .listProjectAssets,
                projectPath: projectURL.path
            )
        )
        return response.projectAssets ?? []
    }

    public func summarizeProjectAssets() async throws -> NPProjectAssetSummary {
        let response = try await send(
            ProjectServiceRequest(
                operation: .summarizeProjectAssets,
                projectPath: projectURL.path
            )
        )
        guard let summary = response.projectAssetSummary else {
            throw ProjectRemoteClientError.invalidResponse("Missing project asset summary")
        }
        return summary
    }

    public func downloadProjectAsset(path: String) async throws -> Data? {
        let response = try await send(
            ProjectServiceRequest(
                operation: .downloadProjectAsset,
                projectPath: projectURL.path,
                filePath: path
            )
        )
        return response.fileData
    }

    public func uploadProjectAsset(path: String, data: Data) async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .uploadProjectAsset,
                projectPath: projectURL.path,
                filePath: path,
                jsonData: data
            )
        )
    }

    public func deleteProjectAsset(path: String) async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .deleteProjectAsset,
                projectPath: projectURL.path,
                filePath: path
            )
        )
    }

    public func upsertProjectFile(path: String, jsonData: Data, actorID: String = "system") async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .upsertProjectFile,
                projectPath: projectURL.path,
                filePath: path,
                actorID: actorID,
                jsonData: jsonData
            )
        )
    }

    public func updateSongText(
        relativePath: String,
        lyrics: String,
        versionID: UUID? = nil,
        actorID: String = "system"
    ) async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .updateSongText,
                projectPath: projectURL.path,
                relativePath: relativePath,
                actorID: actorID,
                lyrics: lyrics,
                versionID: versionID
            )
        )
    }

    public func updateSongPlayback(
        relativePath: String,
        versionID: UUID? = nil,
        playbackJSON: Data?,
        actorID: String = "system"
    ) async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .updateSongPlayback,
                projectPath: projectURL.path,
                relativePath: relativePath,
                actorID: actorID,
                versionID: versionID,
                jsonData: playbackJSON
            )
        )
    }

    public func upsertAnimationScene(
        owsPath: String,
        jsonData: Data,
        actorID: String = "system"
    ) async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .upsertAnimationScene,
                projectPath: projectURL.path,
                relativePath: owsPath,
                actorID: actorID,
                jsonData: jsonData
            )
        )
    }

    public func upsertScene(_ scene: NPSceneRecord, actorID: String = "system") async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .upsertScene,
                projectPath: projectURL.path,
                actorID: actorID,
                scene: scene
            )
        )
    }

    public func pingServer() async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .ping,
                projectPath: projectURL.path
            )
        )
    }

    private func confirmProjectAccess() async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .ensureCurrentIndex,
                projectPath: projectURL.path
            )
        )
    }

    private func send(_ request: ProjectServiceRequest) async throws -> ProjectServiceResponse {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.amira.project.remote-client.\(UUID().uuidString)")
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
            try await Self.waitUntilReady(connection, queue: queue)
            var request = request
            request.authToken = authToken
            request.requestID = request.requestID ?? UUID()
            request.issuedAt = request.issuedAt ?? Date()
            let payload = try Self.encoder.encode(request)
            let envelope = try ProjectTransportSecurity.seal(payload, authToken: authToken)
            let envelopeData = try Self.encoder.encode(envelope)
            try await sendMessage(envelopeData, over: connection)
            let responseEnvelopeData = try await receiveMessage(over: connection)
            let responseEnvelope: ProjectServiceEnvelope
            do {
                responseEnvelope = try Self.decoder.decode(ProjectServiceEnvelope.self, from: responseEnvelopeData)
            } catch {
                throw ProjectRemoteClientError.invalidResponse(
                    "Failed to decode response envelope for \(request.operation.rawValue): \(error.localizedDescription). Payload preview: \(Self.payloadPreview(for: responseEnvelopeData))"
                )
            }
            let responseData = try ProjectTransportSecurity.open(responseEnvelope, authToken: authToken)
            let response: ProjectServiceResponse
            do {
                response = try Self.decoder.decode(ProjectServiceResponse.self, from: responseData)
            } catch {
                throw ProjectRemoteClientError.invalidResponse(
                    "Failed to decode response for \(request.operation.rawValue): \(error.localizedDescription). Payload preview: \(Self.payloadPreview(for: responseData))"
                )
            }
            if response.success == false {
                throw ProjectRemoteClientError.remote(response.errorMessage ?? "Remote request failed")
            }
            try Self.validateResolvedProjectPath(in: response, for: projectURL, operation: request.operation)
            return response
        } onCancel: {
            connection.cancel()
        }
    }

    private static func discoverBonjourEndpoints(timeout: TimeInterval = 2.5) async throws -> [NWEndpoint] {
        let browser = NWBrowser(
            for: .bonjour(type: bonjourServiceType, domain: nil),
            using: .tcp
        )
        let queue = DispatchQueue(label: "com.amira.project.discovery")

        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NWEndpoint], Error>) in
                let box = ProjectOneShotContinuation(continuation)
                let discovered = ProjectEndpointAccumulator()
                browser.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        browser.cancel()
                        box.fail(error)
                    } else if case .cancelled = state {
                        box.fail(ProjectRemoteClientError.connectionCancelled)
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        discovered.record(result.endpoint)
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    browser.cancel()
                    let endpoints = discovered.snapshot()
                    if endpoints.isEmpty {
                        box.fail(ProjectRemoteClientError.discoveryTimedOut)
                    } else {
                        box.succeed(endpoints)
                    }
                }

                browser.start(queue: queue)
            }
        } onCancel: {
            browser.cancel()
        }
    }

    private static func endpointDescription(_ endpoint: NWEndpoint) -> String {
        ProjectServiceEndpointDiscovery.serializedEndpointString(endpoint)
            ?? String(describing: endpoint)
    }

    static func pathsReferToSameProject(requestedProjectURL: URL, resolvedProjectPath: String) -> Bool {
        ProjectPathIdentity.matches(
            requestedProjectURL: requestedProjectURL,
            resolvedProjectURL: ProjectPathIdentity.normalizedProjectURL(from: resolvedProjectPath)
        )
    }

    static func responseAcceptsProjectIdentity(
        requestedProjectURL: URL,
        resolvedProjectPath: String,
        acceptedProjectSignatures: [String]?
    ) -> Bool {
        if pathsReferToSameProject(requestedProjectURL: requestedProjectURL, resolvedProjectPath: resolvedProjectPath) {
            return true
        }

        guard let acceptedProjectSignatures, !acceptedProjectSignatures.isEmpty else {
            return false
        }

        let requestedSignature = ProjectPathIdentity.signature(
            for: requestedProjectURL.resolvingSymlinksInPath().standardizedFileURL
        )
        return acceptedProjectSignatures.contains(requestedSignature)
    }

    private static func validateResolvedProjectPath(
        in response: ProjectServiceResponse,
        for projectURL: URL,
        operation: ProjectServiceOperation
    ) throws {
        guard operation != .ping else { return }
        guard let resolvedProjectPath = response.resolvedProjectPath else {
            throw ProjectRemoteClientError.invalidResponse("Remote service did not return a resolved project path.")
        }
        guard responseAcceptsProjectIdentity(
            requestedProjectURL: projectURL,
            resolvedProjectPath: resolvedProjectPath,
            acceptedProjectSignatures: response.acceptedProjectSignatures
        ) else {
            throw ProjectRemoteClientError.projectResolutionMismatch(
                requested: projectURL.path,
                resolved: resolvedProjectPath
            )
        }
    }

    private static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ProjectOneShotContinuation(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.succeed(())
                case let .failed(error):
                    box.fail(error)
                case .cancelled:
                    box.fail(ProjectRemoteClientError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func sendMessage(_ data: Data, over connection: NWConnection) async throws {
        var length = UInt64(data.count).bigEndian
        let prefix = Data(bytes: &length, count: MemoryLayout<UInt64>.size)
        try await sendData(prefix + data, over: connection)
    }

    private func sendData(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func receiveMessage(over connection: NWConnection) async throws -> Data {
        let prefix = try await receiveExactly(count: MemoryLayout<UInt64>.size, over: connection)
        let length = prefix.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        guard length <= 256 * 1024 * 1024 else {
            throw ProjectRemoteClientError.invalidResponse("Response too large: \(length) bytes")
        }
        return try await receiveExactly(count: Int(length), over: connection)
    }

    private func receiveExactly(count: Int, over connection: NWConnection) async throws -> Data {
        var remaining = count
        var data = Data()
        while remaining > 0 {
            let chunk = try await receiveChunk(maximumLength: remaining, over: connection)
            guard !chunk.isEmpty else {
                throw ProjectRemoteClientError.invalidResponse("Connection closed before response completed")
            }
            data.append(chunk)
            remaining -= chunk.count
        }
        return data
    }

    private func receiveChunk(maximumLength: Int, over connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximumLength)) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func payloadPreview(for data: Data, limit: Int = 320) -> String {
        if let string = String(data: data.prefix(limit), encoding: .utf8) {
            return string.replacingOccurrences(of: "\n", with: "\\n")
        }
        return data.prefix(limit).map { String(format: "%02x", $0) }.joined()
    }
}

private final class ProjectEndpointAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [String: NWEndpoint] = [:]

    func record(_ endpoint: NWEndpoint) {
        lock.lock()
        endpoints[String(describing: endpoint)] = endpoint
        lock.unlock()
    }

    func snapshot() -> [NWEndpoint] {
        lock.lock()
        let snapshot = Array(endpoints.values)
        lock.unlock()
        return snapshot
    }
}

public enum ProjectRemoteClientError: LocalizedError {
    case discoveryTimedOut
    case invalidResponse(String)
    case remote(String)
    case connectionCancelled
    case missingAuthToken
    case noCompatibleServiceFound(String)
    case operationTimedOut(String)
    case projectResolutionMismatch(requested: String, resolved: String)

    public var errorDescription: String? {
        switch self {
        case .discoveryTimedOut:
            return "Could not find Project Service on the local network."
        case let .invalidResponse(message):
            return message
        case let .remote(message):
            return message
        case .connectionCancelled:
            return "The connection to Project Service was cancelled."
        case .missingAuthToken:
            return "Project Service requires an access token, but no token is configured on this machine."
        case let .noCompatibleServiceFound(projectName):
            return "Found Project Service on the network, but none of the discovered servers matched \(projectName)."
        case let .operationTimedOut(description):
            return "Timed out while \(description)."
        case let .projectResolutionMismatch(requested, resolved):
            return "Project Service resolved \(requested) to a different project path: \(resolved)"
        }
    }
}
