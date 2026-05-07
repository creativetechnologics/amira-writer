import Foundation
import CryptoKit

public struct ProjectServiceInfo: Codable, Sendable {
    public var serviceName: String
    public var serviceVersion: String
    public var protocolVersion: Int
    public var hostName: String
    public var port: UInt16
    public var processIdentifier: Int32
    public var startedAt: Date
    public var supportedOperations: [ProjectServiceOperation]
    public var supportsManagedProjects: Bool
    public var supportsProjectOperations: Bool

    public init(
        serviceName: String,
        serviceVersion: String,
        protocolVersion: Int,
        hostName: String,
        port: UInt16,
        processIdentifier: Int32,
        startedAt: Date,
        supportedOperations: [ProjectServiceOperation],
        supportsManagedProjects: Bool,
        supportsProjectOperations: Bool
    ) {
        self.serviceName = serviceName
        self.serviceVersion = serviceVersion
        self.protocolVersion = protocolVersion
        self.hostName = hostName
        self.port = port
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.supportedOperations = supportedOperations
        self.supportsManagedProjects = supportsManagedProjects
        self.supportsProjectOperations = supportsProjectOperations
    }
}

public struct ProjectServiceMCPCapability: Codable, Sendable, Hashable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum ProjectServiceOperation: String, Codable, Sendable, CaseIterable {
    case ping
    case serviceInfo
    case mcpTools
    case listServerProjects
    case createServerProject
    case renameServerProject
    case removeServerProject
    case ensureCurrentIndex
    case loadProjectSummary
    case loadProject
    case loadProjectScenes
    case loadCharacters
    case loadScene
    case currentChangeToken
    case listChanges
    case loadProjectFile
    case summarizeProjectAssets
    case listProjectAssets
    case downloadProjectAsset
    case uploadProjectAsset
    case deleteProjectAsset
    case upsertProjectFile
    case updateSongText
    case updateSongPlayback
    case upsertAnimationScene
    case upsertScene
    case exportLegacy
}

public struct NPProjectAssetRecord: Codable, Sendable, Hashable {
    public var path: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var contentHash: String

    public init(path: String, fileSize: Int64, modifiedAt: Date, contentHash: String) {
        self.path = path
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
    }
}

public struct ProjectServiceRequest: Codable, Sendable {
    public var operation: ProjectServiceOperation
    public var projectPath: String
    public var relativePath: String?
    public var filePath: String?
    public var authToken: String?
    public var actorID: String?
    public var changeID: Int64?
    public var forceRebuild: Bool?
    public var lyrics: String?
    public var versionID: UUID?
    public var jsonData: Data?
    public var scene: NPSceneRecord?
    public var projectID: UUID?
    public var displayName: String?
    public var deleteManagedProject: Bool?
    public var includeVersions: Bool?
    public var includeRootJSON: Bool?
    public var includeAnimateSceneJSON: Bool?
    public var includeVersionJSON: Bool?
    public var includePlaybackJSON: Bool?
    public var requestID: UUID?
    public var issuedAt: Date?

    public init(
        operation: ProjectServiceOperation,
        projectPath: String,
        relativePath: String? = nil,
        filePath: String? = nil,
        authToken: String? = nil,
        actorID: String? = nil,
        changeID: Int64? = nil,
        forceRebuild: Bool? = nil,
        lyrics: String? = nil,
        versionID: UUID? = nil,
        jsonData: Data? = nil,
        scene: NPSceneRecord? = nil,
        projectID: UUID? = nil,
        displayName: String? = nil,
        deleteManagedProject: Bool? = nil,
        includeVersions: Bool? = nil,
        includeRootJSON: Bool? = nil,
        includeAnimateSceneJSON: Bool? = nil,
        includeVersionJSON: Bool? = nil,
        includePlaybackJSON: Bool? = nil,
        requestID: UUID? = nil,
        issuedAt: Date? = nil
    ) {
        self.operation = operation
        self.projectPath = projectPath
        self.relativePath = relativePath
        self.filePath = filePath
        self.authToken = authToken
        self.actorID = actorID
        self.changeID = changeID
        self.forceRebuild = forceRebuild
        self.lyrics = lyrics
        self.versionID = versionID
        self.jsonData = jsonData
        self.scene = scene
        self.projectID = projectID
        self.displayName = displayName
        self.deleteManagedProject = deleteManagedProject
        self.includeVersions = includeVersions
        self.includeRootJSON = includeRootJSON
        self.includeAnimateSceneJSON = includeAnimateSceneJSON
        self.includeVersionJSON = includeVersionJSON
        self.includePlaybackJSON = includePlaybackJSON
        self.requestID = requestID
        self.issuedAt = issuedAt
    }
}

public struct ProjectServiceResponse: Codable, Sendable {
    public var success: Bool
    public var errorMessage: String?
    public var serviceInfo: ProjectServiceInfo?
    public var mcpTools: [ProjectServiceMCPCapability]?
    public var projectSummary: NPProjectSummary?
    public var project: NPProjectRecord?
    public var scenes: [NPSceneRecord]?
    public var scene: NPSceneRecord?
    public var projectFile: NPProjectFileRecord?
    public var characters: [NPCharacterRecord]?
    public var serverProject: NPProjectServerRegistration?
    public var serverProjects: [NPProjectServerRegistration]?
    public var changeToken: Int64?
    public var changes: [ChangeEvent]?
    public var projectAssets: [NPProjectAssetRecord]?
    public var projectAssetSummary: NPProjectAssetSummary?
    public var fileData: Data?
    public var resolvedProjectPath: String?
    public var acceptedProjectSignatures: [String]?
    public var message: String?

    public init(
        success: Bool = true,
        errorMessage: String? = nil,
        serviceInfo: ProjectServiceInfo? = nil,
        mcpTools: [ProjectServiceMCPCapability]? = nil,
        projectSummary: NPProjectSummary? = nil,
        project: NPProjectRecord? = nil,
        scenes: [NPSceneRecord]? = nil,
        scene: NPSceneRecord? = nil,
        projectFile: NPProjectFileRecord? = nil,
        characters: [NPCharacterRecord]? = nil,
        serverProject: NPProjectServerRegistration? = nil,
        serverProjects: [NPProjectServerRegistration]? = nil,
        changeToken: Int64? = nil,
        changes: [ChangeEvent]? = nil,
        projectAssets: [NPProjectAssetRecord]? = nil,
        projectAssetSummary: NPProjectAssetSummary? = nil,
        fileData: Data? = nil,
        resolvedProjectPath: String? = nil,
        acceptedProjectSignatures: [String]? = nil,
        message: String? = nil
    ) {
        self.success = success
        self.errorMessage = errorMessage
        self.serviceInfo = serviceInfo
        self.mcpTools = mcpTools
        self.projectSummary = projectSummary
        self.project = project
        self.scenes = scenes
        self.scene = scene
        self.projectFile = projectFile
        self.characters = characters
        self.serverProject = serverProject
        self.serverProjects = serverProjects
        self.changeToken = changeToken
        self.changes = changes
        self.projectAssets = projectAssets
        self.projectAssetSummary = projectAssetSummary
        self.fileData = fileData
        self.resolvedProjectPath = resolvedProjectPath
        self.acceptedProjectSignatures = acceptedProjectSignatures
        self.message = message
    }
}

struct ProjectServiceEnvelope: Codable, Sendable {
    var version: Int
    var sealedPayload: Data

    init(version: Int = ProjectTransportSecurity.currentVersion, sealedPayload: Data) {
        self.version = version
        self.sealedPayload = sealedPayload
    }
}

enum ProjectTransportSecurity {
    static let currentVersion = 1
    private static let salt = Data("NovotroProjectServerTransport/v1".utf8)

    static func seal(_ payload: Data, authToken: String) throws -> ProjectServiceEnvelope {
        let key = deriveKey(authToken: authToken)
        let sealedBox = try ChaChaPoly.seal(payload, using: key)
        return ProjectServiceEnvelope(sealedPayload: sealedBox.combined)
    }

    static func open(_ envelope: ProjectServiceEnvelope, authToken: String) throws -> Data {
        guard envelope.version == currentVersion else {
            throw NSError(
                domain: "ProjectTransportSecurity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported Project Service transport version \(envelope.version)."]
            )
        }

        let key = deriveKey(authToken: authToken)
        let sealedBox = try ChaChaPoly.SealedBox(combined: envelope.sealedPayload)
        return try ChaChaPoly.open(sealedBox, using: key)
    }

    private static func deriveKey(authToken: String) -> SymmetricKey {
        let input = SymmetricKey(data: Data(authToken.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt,
            info: Data(),
            outputByteCount: 32
        )
    }
}

public enum ProjectServiceConnectionMode: String, Codable, Sendable {
    case local
    case remoteService
}

final class ProjectOneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    private func takeContinuation() -> CheckedContinuation<T, Error>? {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return nil
        }
        self.continuation = nil
        lock.unlock()
        return continuation
    }

    func succeed(_ value: T) {
        guard let continuation = takeContinuation() else { return }
        continuation.resume(returning: value)
    }

    func fail(_ error: Error) {
        guard let continuation = takeContinuation() else { return }
        continuation.resume(throwing: error)
    }
}
