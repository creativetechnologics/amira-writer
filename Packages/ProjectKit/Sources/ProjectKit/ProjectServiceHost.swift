import Foundation
import Network
import CryptoKit

public final class ProjectServiceHost: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.opera.project.service", qos: .userInitiated)
    private let registry: ProjectServerRegistry
    private let resolver: ProjectPathResolver
    private let cache: ProjectServiceDatabaseCache
    private let replayGuard = ProjectRequestReplayGuard()
    private let requiredAuthToken: String
    private let startedAt: Date
    private let serviceName = "Project Service"

    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    public var stateHandler: (@Sendable (NWListener.State) -> Void)?
    public var connectionCountHandler: (@Sendable (Int) -> Void)?

    public private(set) var port: UInt16

    public init(
        port: UInt16 = ProjectServiceConfiguration.defaultPort,
        authToken: String? = ProjectServiceConfiguration.loadAuthToken(),
        allowedProjectRoots: [URL] = ProjectServiceConfiguration.allowedProjectRoots(),
        registry: ProjectServerRegistry = ProjectServerRegistry()
    ) throws {
        guard let authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authToken.isEmpty else {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Missing Project Service access token."]
            )
        }

        self.requiredAuthToken = authToken
        self.registry = registry
        self.resolver = ProjectPathResolver(allowedProjectRoots: allowedProjectRoots, registry: registry)
        self.cache = ProjectServiceDatabaseCache()
        self.port = port
        self.startedAt = Date()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"]
            )
        }
        self.listener = try NWListener(using: params, on: nwPort)
        self.listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Project Service",
            type: ProjectRemoteClient.bonjourServiceType
        )
    }

    deinit {
        stop()
    }

    public func start() {
        listener.stateUpdateHandler = { [service = self] state in
            if case .ready = state, let port = service.listener.port?.rawValue {
                service.port = port
            }
            service.stateHandler?(state)
        }

        listener.newConnectionHandler = { [service = self] connection in
            service.handle(connection)
        }

        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.activeConnections.values {
                connection.cancel()
            }
            self.activeConnections.removeAll()
            self.connectionCountHandler?(0)
        }
    }

    private func handle(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        activeConnections[identifier] = connection
        connectionCountHandler?(activeConnections.count)

        connection.stateUpdateHandler = { [service = self] state in
            switch state {
            case .failed, .cancelled:
                service.activeConnections.removeValue(forKey: identifier)
                service.connectionCountHandler?(service.activeConnections.count)
            default:
                break
            }
        }

        connection.start(queue: queue)
        Task { [weak self] in
            guard let self else { return }
            do {
                let envelopeData = try await self.receiveMessage(over: connection)
                let envelope = try ProjectServiceCodec.decoder.decode(ProjectServiceEnvelope.self, from: envelopeData)
                let requestData = try ProjectTransportSecurity.open(envelope, authToken: self.requiredAuthToken)
                let request = try ProjectServiceCodec.decoder.decode(ProjectServiceRequest.self, from: requestData)
                let response = try await self.process(request)
                let responseData = try ProjectServiceCodec.encoder.encode(response)
                let responseEnvelope = try ProjectTransportSecurity.seal(responseData, authToken: self.requiredAuthToken)
                let encodedEnvelope = try ProjectServiceCodec.encoder.encode(responseEnvelope)
                try await self.sendMessage(encodedEnvelope, over: connection)
            } catch {
                let response = ProjectServiceResponse(
                    success: false,
                    errorMessage: error.localizedDescription
                )
                if let data = try? ProjectServiceCodec.encoder.encode(response),
                   let envelope = try? ProjectTransportSecurity.seal(data, authToken: self.requiredAuthToken),
                   let encodedEnvelope = try? ProjectServiceCodec.encoder.encode(envelope) {
                    try? await self.sendMessage(encodedEnvelope, over: connection)
                }
            }

            connection.cancel()
        }
    }

    private func process(_ request: ProjectServiceRequest) async throws -> ProjectServiceResponse {
        try authenticate(request)
        try await validateTransportMetadata(request)

        if request.operation == .ping {
            return ProjectServiceResponse(message: "pong")
        }
        if request.operation == .serviceInfo {
            return ProjectServiceResponse(serviceInfo: currentServiceInfo())
        }
        if request.operation == .mcpTools {
            return ProjectServiceResponse(mcpTools: defaultMCPCapabilities())
        }

        switch request.operation {
        case .listServerProjects:
            try registry.ensureStorageDirectories()
            return ProjectServiceResponse(
                serverProjects: try registry.listProjects()
            )

        case .createServerProject:
            let displayName = request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !displayName.isEmpty else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 15,
                    userInfo: [NSLocalizedDescriptionKey: "Project name cannot be empty."]
                )
            }

            try registry.ensureStorageDirectories()
            let registration = try registry.createProject(named: displayName)
            let database = await cache.database(for: registration.managedProjectURL)
            try await database.ensureCurrentIndex(forceRebuild: true)
            try await seedDefaultProjectFiles(in: database, displayName: registration.displayName)
            try await database.exportLegacy()
            return ProjectServiceResponse(serverProject: registration)

        case .renameServerProject:
            guard let projectID = request.projectID else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 16,
                    userInfo: [NSLocalizedDescriptionKey: "Missing project identifier."]
                )
            }
            let displayName = request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !displayName.isEmpty else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 17,
                    userInfo: [NSLocalizedDescriptionKey: "Project name cannot be empty."]
                )
            }

            let registration = try registry.renameProject(id: projectID, to: displayName)
            let database = await cache.database(for: registration.managedProjectURL)
            try await database.ensureCurrentIndex(forceRebuild: true)
            try await seedDefaultProjectFiles(in: database, displayName: registration.displayName)
            try await database.exportLegacy()
            return ProjectServiceResponse(serverProject: registration)

        case .removeServerProject:
            guard let projectID = request.projectID else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 18,
                    userInfo: [NSLocalizedDescriptionKey: "Missing project identifier."]
                )
            }

            try registry.removeProject(id: projectID, deleteManagedProject: request.deleteManagedProject ?? true)
            return ProjectServiceResponse(message: "Removed project from Project Service.")

        default:
            break
        }

        let resolvedProject = try await resolver.resolve(clientProjectPath: request.projectPath)
        let resolvedURL = resolvedProject.url
        let database = await cache.database(for: resolvedURL)

        switch request.operation {
        case .listServerProjects, .createServerProject, .renameServerProject, .removeServerProject:
            throw NSError(
                domain: "ProjectServiceHost",
                code: 19,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected server operation routing."]
            )
        case .serviceInfo, .mcpTools, .ping:
            throw NSError(
                domain: "ProjectServiceHost",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected server operation routing."]
            )

        case .ensureCurrentIndex:
            try await database.ensureCurrentIndex(forceRebuild: request.forceRebuild ?? false)
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .loadProjectSummary:
            try await database.ensureCurrentIndex()
            return ProjectServiceResponse(
                projectSummary: try await database.loadProjectSummary(),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .loadProject:
            try await database.ensureCurrentIndex()
            var project = try await database.loadProject()
            project.projectFiles = project.projectFiles.filter { Self.isClientVisibleProjectFile($0.path) }
            return ProjectServiceResponse(
                project: project,
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .loadProjectScenes:
            try await database.ensureCurrentIndex()
            return ProjectServiceResponse(
                scenes: try await database.loadProjectScenes(
                    includeVersions: request.includeVersions ?? true,
                    includeRootJSON: request.includeRootJSON ?? true,
                    includeAnimateSceneJSON: request.includeAnimateSceneJSON ?? true,
                    includeVersionJSON: request.includeVersionJSON ?? true,
                    includePlaybackJSON: request.includePlaybackJSON ?? true
                ),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .loadCharacters:
            try await database.ensureCurrentIndex()
            return ProjectServiceResponse(
                characters: try await database.loadCharacters(),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .loadScene:
            try await database.ensureCurrentIndex()
            guard let relativePath = request.relativePath else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing relativePath"]
                )
            }
            return ProjectServiceResponse(
                scene: try await database.loadScene(relativePath: relativePath),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .currentChangeToken:
            try await database.ensureCurrentIndex()
            return ProjectServiceResponse(
                changeToken: try await database.currentChangeToken(),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .listChanges:
            try await database.ensureCurrentIndex()
            return ProjectServiceResponse(
                changes: try await database.listChanges(since: request.changeID ?? 0),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .loadProjectFile:
            try await database.ensureCurrentIndex()
            guard let filePath = request.filePath else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing filePath"]
                )
            }
            return ProjectServiceResponse(
                projectFile: try await database.loadProjectFile(path: filePath),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .summarizeProjectAssets:
            try await database.ensureCurrentIndex()
            try await database.exportLegacy()
            let summary = try Self.summarizeProjectAssets(at: resolvedURL)
            return ProjectServiceResponse(
                projectAssetSummary: summary,
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .listProjectAssets:
            try await database.ensureCurrentIndex()
            try await database.exportLegacy()
            return ProjectServiceResponse(
                projectAssets: try Self.listProjectAssets(at: resolvedURL),
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .downloadProjectAsset:
            try await database.ensureCurrentIndex()
            try await database.exportLegacy()
            guard let filePath = request.filePath else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Missing filePath"]
                )
            }
            let assetURL = try Self.projectAssetURL(for: filePath, in: resolvedURL)
            let data = FileManager.default.fileExists(atPath: assetURL.path)
                ? try Data(contentsOf: assetURL, options: .mappedIfSafe)
                : nil
            return ProjectServiceResponse(
                fileData: data,
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .uploadProjectAsset:
            guard let filePath = request.filePath else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 21,
                    userInfo: [NSLocalizedDescriptionKey: "Missing filePath"]
                )
            }
            let assetURL = try Self.projectAssetURL(for: filePath, in: resolvedURL)
            try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (request.jsonData ?? Data()).write(to: assetURL, options: .atomic)
            if Self.shouldRebuildProjectIndex(for: filePath) {
                try await database.ensureCurrentIndex(forceRebuild: true)
            }
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .deleteProjectAsset:
            guard let filePath = request.filePath else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "Missing filePath"]
                )
            }
            let assetURL = try Self.projectAssetURL(for: filePath, in: resolvedURL)
            if FileManager.default.fileExists(atPath: assetURL.path) {
                try FileManager.default.removeItem(at: assetURL)
                try Self.pruneEmptyDirectories(startingAt: assetURL.deletingLastPathComponent(), rootURL: resolvedURL)
            }
            if Self.shouldRebuildProjectIndex(for: filePath) {
                try await database.ensureCurrentIndex(forceRebuild: true)
            }
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .upsertProjectFile:
            try await database.ensureCurrentIndex()
            guard let filePath = request.filePath else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Missing filePath"]
                )
            }
            try await database.upsertProjectFile(
                path: filePath,
                jsonData: request.jsonData ?? Data(),
                actorID: request.actorID ?? "remote-service"
            )
            try await database.exportLegacy()
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .updateSongText:
            try await database.ensureCurrentIndex()
            guard let relativePath = request.relativePath,
                  let lyrics = request.lyrics else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Missing song text payload"]
                )
            }
            try await database.updateSongText(
                relativePath: relativePath,
                lyrics: lyrics,
                versionID: request.versionID,
                actorID: request.actorID ?? "remote-service"
            )
            try await database.exportLegacy()
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .updateSongPlayback:
            try await database.ensureCurrentIndex()
            guard let relativePath = request.relativePath else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Missing relativePath"]
                )
            }
            try await database.updateSongPlayback(
                relativePath: relativePath,
                versionID: request.versionID,
                playbackJSON: request.jsonData,
                actorID: request.actorID ?? "remote-service"
            )
            try await database.exportLegacy()
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .upsertAnimationScene:
            try await database.ensureCurrentIndex()
            guard let relativePath = request.relativePath,
                  let jsonData = request.jsonData else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Missing animation scene payload"]
                )
            }
            try await database.upsertAnimationScene(
                owsPath: relativePath,
                jsonData: jsonData,
                actorID: request.actorID ?? "remote-service"
            )
            try await database.exportLegacy()
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .upsertScene:
            try await database.ensureCurrentIndex()
            guard let scene = request.scene else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Missing scene payload"]
                )
            }
            try await database.upsertScene(scene, actorID: request.actorID ?? "remote-service")
            try await database.exportLegacy()
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )

        case .exportLegacy:
            try await database.ensureCurrentIndex()
            try await database.exportLegacy()
            return ProjectServiceResponse(
                resolvedProjectPath: resolvedURL.path,
                acceptedProjectSignatures: resolvedProject.acceptedSignatures
            )
        }
    }

    private func currentServiceInfo() -> ProjectServiceInfo {
        ProjectServiceInfo(
            serviceName: serviceName,
            serviceVersion: Self.serviceVersion,
            protocolVersion: ProjectTransportSecurity.currentVersion,
            hostName: Host.current().localizedName ?? "unknown",
            port: port,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            supportedOperations: ProjectServiceOperation.allCases,
            supportsManagedProjects: true,
            supportsProjectOperations: true
        )
    }

    private static var serviceVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return version
        }
        return "0.0.0"
    }

    private func defaultMCPCapabilities() -> [ProjectServiceMCPCapability] {
        [
            ProjectServiceMCPCapability(
                name: "service_ping",
                description: "Verify transport and auth connectivity using the same TCP protocol as clients."
            ),
            ProjectServiceMCPCapability(
                name: "service_info",
                description: "Return service metadata and supported operation names."
            ),
            ProjectServiceMCPCapability(
                name: "service_mcp_tools",
                description: "Return this bridge’s MCP tool inventory."
            ),
            ProjectServiceMCPCapability(
                name: "service_endpoints",
                description: "List candidate service endpoints visible to this bridge."
            ),
            ProjectServiceMCPCapability(
                name: "service_list_projects",
                description: "List managed server projects."
            ),
        ]
    }

    private func authenticate(_ request: ProjectServiceRequest) throws {
        let providedToken = request.authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providedToken == requiredAuthToken else {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Unauthorized Project Service request."]
            )
        }
    }

    private func validateTransportMetadata(_ request: ProjectServiceRequest) async throws {
        guard let requestID = request.requestID,
              let issuedAt = request.issuedAt else {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 102,
                userInfo: [NSLocalizedDescriptionKey: "Missing Project Service transport metadata."]
            )
        }

        let now = Date()
        if issuedAt > now.addingTimeInterval(30) || issuedAt < now.addingTimeInterval(-300) {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 103,
                userInfo: [NSLocalizedDescriptionKey: "Rejected stale Project Service request."]
            )
        }

        try await replayGuard.register(requestID: requestID, issuedAt: issuedAt)
    }

    private static func isClientVisibleProjectFile(_ path: String) -> Bool {
        if path == "index.json" || path == "Instruments.json" || path == "project.json" || path == "characters.json" {
            return true
        }
        let prefixes = [
            "Metadata/",
            "Characters/",
            "Synopsis/",
            "Animate/",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    private func seedDefaultProjectFiles(
        in database: ProjectDatabase,
        displayName: String
    ) async throws {
        let now = ProjectServiceCodec.iso8601Timestamp(from: Date())
        let metadata = """
        {"createdAt":"\(now)","name":"\(Self.jsonEscaped(displayName))","notes":"","projectVersions":[],"updatedAt":"\(now)"}
        """
        let characters = #"{"characters":[],"version":1}"#
        let synopsis = ""
        let index = #"{"cueMappings":[],"instrumentMappings":[],"version":2}"#
        let instruments = #"[]"#
        let animateMetadata = """
        {"createdDate":"\(now)","fps":24,"resolution":{"height":1080,"width":1920}}
        """
        let emptyScenes = #"[]"#
        let packageSelections = #"{"activePackageIDsByCharacterSlug":{},"schemaVersion":1}"#
        let shotPresets = #"{"presets":[],"schemaVersion":1}"#

        try await database.upsertProjectFile(
            path: "Metadata/project.json",
            jsonData: Data(metadata.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "Characters/characters.json",
            jsonData: Data(characters.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "Synopsis/synopsis.txt",
            jsonData: Data(synopsis.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "index.json",
            jsonData: Data(index.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "Instruments.json",
            jsonData: Data(instruments.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "Animate/animate.json",
            jsonData: Data(animateMetadata.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "Animate/scenes.json",
            jsonData: Data(emptyScenes.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "Animate/character-package-selections.json",
            jsonData: Data(packageSelections.utf8),
            actorID: "project-service"
        )
        try await database.upsertProjectFile(
            path: "Animate/shot-presets.json",
            jsonData: Data(shotPresets.utf8),
            actorID: "project-service"
        )
    }

    private static func jsonEscaped(_ string: String) -> String {
        var escaped = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                escaped.append("\\\"")
            case "\\":
                escaped.append("\\\\")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "\t":
                escaped.append("\\t")
            default:
                escaped.append(String(scalar))
            }
        }
        return escaped
    }

    private static func listProjectAssets(at projectURL: URL) throws -> [NPProjectAssetRecord] {
        let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var assets: [NPProjectAssetRecord] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.hasDirectoryPath == false else { continue }
            let relativePath = relativePath(for: fileURL, rootURL: projectURL)
            guard relativePath.hasPrefix(".novotro/") == false else { continue }
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fileSize = Int64(values.fileSize ?? 0)
            assets.append(
                NPProjectAssetRecord(
                    path: relativePath,
                    fileSize: fileSize,
                    modifiedAt: modifiedAt,
                    contentHash: assetSignature(fileSize: fileSize, modifiedAt: modifiedAt)
                )
            )
        }

        return assets.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func summarizeProjectAssets(at projectURL: URL) throws -> NPProjectAssetSummary {
        let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var assetCount = 0
        var totalBytes: Int64 = 0

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.hasDirectoryPath == false else { continue }
            let relativePath = relativePath(for: fileURL, rootURL: projectURL)
            guard relativePath.hasPrefix(".novotro/") == false else { continue }

            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            assetCount += 1
            totalBytes += Int64(values.fileSize ?? 0)
        }

        return NPProjectAssetSummary(assetCount: assetCount, totalBytes: totalBytes)
    }

    private static func projectAssetURL(for relativePath: String, in projectURL: URL) throws -> URL {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard normalized.isEmpty == false,
              normalized.hasPrefix("/") == false,
              normalized.contains("..") == false else {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 23,
                userInfo: [NSLocalizedDescriptionKey: "Invalid project asset path \(relativePath)."]
            )
        }
        return projectURL.appendingPathComponent(normalized, isDirectory: false)
    }

    private static func pruneEmptyDirectories(startingAt directoryURL: URL, rootURL: URL) throws {
        var currentURL = directoryURL
        while currentURL.path.hasPrefix(rootURL.path), currentURL.path != rootURL.path {
            let contents = try FileManager.default.contentsOfDirectory(atPath: currentURL.path)
            guard contents.isEmpty else { return }
            try FileManager.default.removeItem(at: currentURL)
            currentURL = currentURL.deletingLastPathComponent()
        }
    }

    private static func shouldRebuildProjectIndex(for relativePath: String) -> Bool {
        if relativePath.hasPrefix("Songs/") && relativePath.hasSuffix(".ows") {
            return true
        }
        if relativePath == "index.json" || relativePath == "Instruments.json" {
            return true
        }
        let prefixes = [
            "Metadata/",
            "Characters/",
            "Synopsis/",
            "Animate/",
        ]
        return prefixes.contains { relativePath.hasPrefix($0) }
    }

    private static func assetSignature(fileSize: Int64, modifiedAt: Date) -> String {
        let payload = "\(fileSize)|\(modifiedAt.timeIntervalSince1970)".data(using: .utf8) ?? Data()
        return Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let basePath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let filePath = fileURL.path
        if filePath.hasPrefix(basePath) {
            return String(filePath.dropFirst(basePath.count))
        }

        let normalizedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let normalizedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = normalizedRoot.pathComponents
        let fileComponents = normalizedFile.pathComponents

        if fileComponents.starts(with: rootComponents) {
            return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }

        let normBasePath = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        return normalizedFile.path.replacingOccurrences(of: normBasePath, with: "")
    }

    private func sendMessage(_ data: Data, over connection: NWConnection) async throws {
        var length = UInt64(data.count).bigEndian
        let prefix = Data(bytes: &length, count: MemoryLayout<UInt64>.size)
        try await send(prefix + data, over: connection)
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
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
            throw NSError(
                domain: "ProjectServiceHost",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Incoming request too large: \(length) bytes"]
            )
        }
        return try await receiveExactly(count: Int(length), over: connection)
    }

    private func receiveExactly(count: Int, over connection: NWConnection) async throws -> Data {
        var remaining = count
        var data = Data()
        while remaining > 0 {
            let chunk = try await receiveChunk(maximumLength: remaining, over: connection)
            guard !chunk.isEmpty else {
                throw NSError(
                    domain: "ProjectServiceHost",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Connection closed before request completed"]
                )
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
}

private actor ProjectRequestReplayGuard {
    private let requestLifetime: TimeInterval = 300
    private var recentRequestDates: [UUID: Date] = [:]

    func register(requestID: UUID, issuedAt: Date) throws {
        purgeExpired(relativeTo: Date())
        if recentRequestDates[requestID] != nil {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 104,
                userInfo: [NSLocalizedDescriptionKey: "Rejected replayed Project Service request."]
            )
        }
        recentRequestDates[requestID] = issuedAt
    }

    private func purgeExpired(relativeTo now: Date) {
        recentRequestDates = recentRequestDates.filter { _, issuedAt in
            issuedAt >= now.addingTimeInterval(-requestLifetime)
        }
    }
}

private struct ProjectResolvedProject: Sendable {
    let url: URL
    let acceptedSignatures: [String]
}

private actor ProjectPathResolver {
    private let allowedProjectRoots: [URL]
    private let registry: ProjectServerRegistry
    private var cachedPaths: [String: ProjectResolvedProject] = [:]

    init(allowedProjectRoots: [URL], registry: ProjectServerRegistry) {
        self.allowedProjectRoots = allowedProjectRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.registry = registry
    }

    func resolve(clientProjectPath: String) throws -> ProjectResolvedProject {
        if let cached = cachedPaths[clientProjectPath],
           FileManager.default.fileExists(atPath: cached.url.path) {
            return cached
        }

        let normalizedClientURL = ProjectPathIdentity.normalizedProjectURL(from: clientProjectPath)
        if let registration = try registry.registration(forProjectURL: normalizedClientURL) {
            let resolved = try validateProjectURL(registration.managedProjectURL)
            let project = ProjectResolvedProject(
                url: resolved,
                acceptedSignatures: acceptedSignatures(
                    from: registration,
                    requestedProjectURL: normalizedClientURL,
                    resolvedProjectURL: resolved
                )
            )
            cachedPaths[clientProjectPath] = project
            return project
        }

        let normalized = normalizedClientURL
        if FileManager.default.fileExists(atPath: normalized.path) {
            let resolved = try validateProjectURL(normalized)
            let project = ProjectResolvedProject(
                url: resolved,
                acceptedSignatures: [ProjectPathIdentity.signature(for: resolved)]
            )
            cachedPaths[clientProjectPath] = project
            return project
        }

        let components = normalized.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            let shareName = components[2]
            let trailing = components.dropFirst(3)
            let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            let volumes = (try? FileManager.default.contentsOfDirectory(
                at: volumesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for volume in volumes {
                let shareRoot = volume.appendingPathComponent(shareName, isDirectory: true)
                var candidate = shareRoot
                for component in trailing {
                    candidate.appendPathComponent(component, isDirectory: false)
                }
                if FileManager.default.fileExists(atPath: candidate.path) {
                    let resolved = try validateProjectURL(candidate)
                    let project = ProjectResolvedProject(
                        url: resolved,
                        acceptedSignatures: [ProjectPathIdentity.signature(for: normalized),
                                             ProjectPathIdentity.signature(for: resolved)]
                    )
                    cachedPaths[clientProjectPath] = project
                    return project
                }
            }
        }

        throw NSError(
            domain: "ProjectServiceHost",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Could not resolve project path \(clientProjectPath) on the server."]
        )
    }

    private func validateProjectURL(_ candidate: URL) throws -> URL {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension.lowercased() == "owp" else {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to open non-project path \(resolved.path)."]
            )
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Resolved project path \(resolved.path) does not exist."]
            )
        }

        if !allowedProjectRoots.isEmpty,
           !allowedProjectRoots.contains(where: { ProjectServiceConfiguration.isDescendant(resolved, of: $0) }) {
            throw NSError(
                domain: "ProjectServiceHost",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Project path \(resolved.path) is outside the allowed project roots."]
            )
        }

        return resolved
    }

    private func acceptedSignatures(
        from registration: ProjectServerRegistration,
        requestedProjectURL: URL,
        resolvedProjectURL: URL
    ) -> [String] {
        var signatures = Set(registration.pathAliases)
        signatures.insert(ProjectPathIdentity.signature(for: requestedProjectURL))
        signatures.insert(ProjectPathIdentity.signature(for: resolvedProjectURL))
        signatures.insert(ProjectPathIdentity.signature(for: registration.managedProjectURL))
        if let sourceProjectURL = registration.sourceProjectURL {
            signatures.insert(ProjectPathIdentity.signature(for: sourceProjectURL))
        }
        return signatures.sorted()
    }
}

    private actor ProjectServiceDatabaseCache {
        private var databases: [String: ProjectDatabase] = [:]

        func database(for projectURL: URL) -> ProjectDatabase {
            let key = projectURL.path
            if let database = databases[key] {
                return database
            }
            let database = ProjectDatabase(
                projectURL: projectURL,
                databaseDirectoryURL: ProjectClientIdentity.projectDatabaseDirectoryURL(for: projectURL)
            )
            databases[key] = database
            return database
        }
    }

enum ProjectServiceCodec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

typealias NovotroProjectServiceHost = ProjectServiceHost
typealias NovotroProjectServiceCodec = ProjectServiceCodec
