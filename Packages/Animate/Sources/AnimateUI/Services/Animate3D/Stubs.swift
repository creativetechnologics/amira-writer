import Foundation
import CoreGraphics
import SceneKit
import simd

@available(macOS 26.0, *)
public struct MeshyMultiImageRequest: Codable, Sendable {
    public var imageURLs: [String]
    public var aiModel: String
    public var topology: String
    public var targetPolycount: Int
    public var shouldRemesh: Bool
    public var shouldTexture: Bool
    public var enablePBR: Bool
    public var removeLighting: Bool
    public var textureImageURL: String?
    public var targetFormats: [String]
    public var symmetryMode: String

    public var estimatedCredits: Int {
        if shouldTexture { return aiModel == "meshy-5" ? 15 : 30 }
        return aiModel == "meshy-5" ? 10 : 20
    }

    public init(
        imageURLs: [String],
        aiModel: String = "latest",
        topology: String = "triangle",
        targetPolycount: Int = 100_000,
        shouldRemesh: Bool = true,
        shouldTexture: Bool = true,
        enablePBR: Bool = true,
        removeLighting: Bool = true,
        textureImageURL: String? = nil,
        targetFormats: [String] = ["glb"],
        symmetryMode: String = "auto"
    ) {
        self.imageURLs = imageURLs
        self.aiModel = aiModel
        self.topology = topology
        self.targetPolycount = targetPolycount
        self.shouldRemesh = shouldRemesh
        self.shouldTexture = shouldTexture
        self.enablePBR = enablePBR
        self.removeLighting = removeLighting
        self.textureImageURL = textureImageURL
        self.targetFormats = targetFormats
        self.symmetryMode = symmetryMode
    }
}

@available(macOS 26.0, *)
public struct MeshyImageRequest: Codable, Sendable {
    public var imageURL: String
    public var aiModel: String
    public var topology: String
    public var targetPolycount: Int
    public var shouldRemesh: Bool
    public var shouldTexture: Bool
    public var enablePBR: Bool
    public var removeLighting: Bool
    public var targetFormats: [String]

    public init(
        imageURL: String,
        aiModel: String = "latest",
        topology: String = "triangle",
        targetPolycount: Int = 100_000,
        shouldRemesh: Bool = true,
        shouldTexture: Bool = true,
        enablePBR: Bool = true,
        removeLighting: Bool = true,
        targetFormats: [String] = ["glb"]
    ) {
        self.imageURL = imageURL
        self.aiModel = aiModel
        self.topology = topology
        self.targetPolycount = targetPolycount
        self.shouldRemesh = shouldRemesh
        self.shouldTexture = shouldTexture
        self.enablePBR = enablePBR
        self.removeLighting = removeLighting
        self.targetFormats = targetFormats
    }
}

@available(macOS 26.0, *)
public struct MeshyTaskResponse: Codable, Sendable {
    public var id: String
    public var status: MeshyTaskStatus
    public var progress: Int
    public var modelURLs: [String: String]?
    public var thumbnailURL: String?
    public var textureURLs: [MeshyTextureSet]?
    public var taskError: MeshyTaskError?
    public var createdAt: Int
    public var finishedAt: Int

    public init(
        id: String,
        status: MeshyTaskStatus,
        progress: Int,
        modelURLs: [String: String]? = nil,
        thumbnailURL: String? = nil,
        textureURLs: [MeshyTextureSet]? = nil,
        taskError: MeshyTaskError? = nil,
        createdAt: Int = 0,
        finishedAt: Int = 0
    ) {
        self.id = id
        self.status = status
        self.progress = progress
        self.modelURLs = modelURLs
        self.thumbnailURL = thumbnailURL
        self.textureURLs = textureURLs
        self.taskError = taskError
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

@available(macOS 26.0, *)
public enum MeshyTaskStatus: String, Codable, Sendable {
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case pending = "PENDING"
    case inProgress = "IN_PROGRESS"
}

@available(macOS 26.0, *)
public struct MeshyTextureSet: Codable, Sendable {
    public var baseColor: String?
    public var metallic: String?
    public var normal: String?
    public var roughness: String?
}

@available(macOS 26.0, *)
public struct MeshyTaskError: Codable, Sendable {
    public var message: String
}

@available(macOS 26.0, *)
public final class MeshyCredentialStore: Sendable {
    public init() {}
    public func saveAPIKey(_ key: String) {}
    public func loadAPIKey() -> String { "" }
    public func clearAPIKey() {}
}

@available(macOS 26.0, *)
public final class MeshyService: Sendable {
    public init(apiKey: String) {}
    public func buildCreateTaskRequest<T: Encodable>(endpoint: String, body: T) throws -> URLRequest { URLRequest(url: URL(string: "https://api.meshy.ai")!) }
    public func buildGetTaskRequest(endpoint: String, taskID: String) -> URLRequest { URLRequest(url: URL(string: "https://api.meshy.ai")!) }
    public func buildBalanceRequest() -> URLRequest { URLRequest(url: URL(string: "https://api.meshy.ai")!) }
}

@available(macOS 26.0, *)
public struct MeshyBridgeService {
    public static func needsMeshyConversion(_ kind: String) -> Bool {
        kind == "bodyModel"
    }
    public struct BridgeJob: Sendable {
        public var characterID: UUID
        public var characterSlug: String
        public var costumeName: String
        public var sourceImagePaths: [String]
        public var meshyConfig: MeshyMultiImageRequest
    }
}

@available(macOS 26.0, *)
public enum MeshyAssetValidationService {
    public struct MeshValidationReport: Sendable {
        public var fileSize: Int64
        public var format: String
        public var hasTextures: Bool
        public var thumbnailExists: Bool
        public var metadataExists: Bool
    }
    public enum ValidationResult: Sendable {
        case valid(MeshValidationReport)
        case invalid(String)
    }
    public static func validate(assetDirectory: URL) -> [String: ValidationResult] { [:] }
    public static func summary(for results: [String: ValidationResult]) -> String { "" }
}

@available(macOS 26.0, *)
public struct Animate3DCharacterAssetInventory {
    public func files(for category: Animate3DAssetCategory) -> [String] { [] }
    public var totalFileCount: Int { 0 }
}

@available(macOS 26.0, *)
public enum Animate3DAssetCategory: String, Codable, Sendable {
    case models
    case faceRigs
    case mouthProfiles
    case expressions
    case motions
    case materials
}

@available(macOS 26.0, *)
public final class Animate3DCharacterAssetService {
    public init() {}
    public func inventory(for characterSlug: String, in animateURL: URL) -> Animate3DCharacterAssetInventory {
        Animate3DCharacterAssetInventory()
    }
    public func importFiles(for characterSlug: String, category: Animate3DAssetCategory, from sourceURLs: [URL], in animateURL: URL) throws -> [URL] { [] }
    public func removeFile(for characterSlug: String, category: Animate3DAssetCategory, relativePath: String, in animateURL: URL) throws {}
}

@available(macOS 26.0, *)
public enum Animate3DGenerationOverridePersistence {
    public struct PersistedOverrideState: Codable, Sendable, Equatable {
        public var pinnedKeys: [String]
        public var skippedKeys: [String]
        public var draftOverrides: [String: Animate3DGenerationDraftOverride]
        public static let empty = PersistedOverrideState(pinnedKeys: [], skippedKeys: [], draftOverrides: [:])
    }
    public static func save(_ state: PersistedOverrideState, animateURL: URL) {}
    public static func load(animateURL: URL) -> PersistedOverrideState { .empty }
    public static func clear(animateURL: URL) {}
}

@available(macOS 26.0, *)
public struct Animate3DGenerationDraftOverride: Codable, Sendable, Equatable {
    public var providerHintOverride: String?
    public var promptAppendix: String?
    public var isLocked: Bool = false
}

@available(macOS 26.0, *)
public final class ScenePreviewRenderer: @unchecked Sendable {
    public var sceneKitScene: SCNScene
    public var characterPerformanceStatuses: [Animate3DCharacterPerformanceStatus] { [] }
    init(store: AnimateStore) { sceneKitScene = SCNScene() }
    func loadPlan(_ plan: SceneProductionPlan) async {}
    public func renderFrame(_ frame: Int) {}
}



@available(macOS 26.0, *)
public struct Animate3DWorldCatalog: Codable, Sendable, Equatable {
    public var chunks: [Animate3DWorldChunkDescriptor]
    public init(chunks: [Animate3DWorldChunkDescriptor] = []) { self.chunks = chunks }
}

@available(macOS 26.0, *)
public struct Animate3DWorldChunkDescriptor: Codable, Sendable, Equatable {
    public var worldID: String
    public var zoneID: String
    public var title: String
    public var placeNames: [String]
    public var meshPath: String
    public var depthMapPath: String?
    public var previewImagePath: String?
    public var styleProfileID: String?
    public var atmospherePresetID: String?
    public var lightRigID: String?
}

@available(macOS 26.0, *)
public struct Animate3DStyleProfileManifest: Codable, Sendable, Equatable {
    public var profiles: [Animate3DStyleProfileDescriptor]
    public init(profiles: [Animate3DStyleProfileDescriptor] = []) { self.profiles = profiles }
}

@available(macOS 26.0, *)
public struct Animate3DStyleProfileDescriptor: Codable, Sendable, Equatable {
    public var profileID: String
    public var title: String
    public var notes: String?
    public var celBands: Int
    public var outlineWidth: Double
}

@available(macOS 26.0, *)
public struct Animate3DCameraPresetManifest: Codable, Sendable, Equatable {
    public var presets: [Animate3DCameraPresetDescriptor]
    public init(presets: [Animate3DCameraPresetDescriptor] = []) { self.presets = presets }
}

@available(macOS 26.0, *)
public struct Animate3DCameraPresetDescriptor: Codable, Sendable, Equatable {
    public var presetID: String
    public var title: String
    public var shotName: String
    public var focalLength: Double
    public var notes: String?
}

@available(macOS 26.0, *)
public struct Animate3DLightRigManifest: Codable, Sendable, Equatable {
    public var rigs: [Animate3DLightRigDescriptor]
    public init(rigs: [Animate3DLightRigDescriptor] = []) { self.rigs = rigs }
}

@available(macOS 26.0, *)
public struct Animate3DLightRigDescriptor: Codable, Sendable, Equatable {
    public var rigID: String
    public var title: String
    public var keyIntensity: Double
    public var fillIntensity: Double
    public var rimIntensity: Double
    public var notes: String?
}

@available(macOS 26.0, *)
public struct Animate3DAtmospherePresetManifest: Codable, Sendable, Equatable {
    public var presets: [Animate3DAtmospherePresetDescriptor]
    public init(presets: [Animate3DAtmospherePresetDescriptor] = []) { self.presets = presets }
}

@available(macOS 26.0, *)
public struct Animate3DAtmospherePresetDescriptor: Codable, Sendable, Equatable {
    public var presetID: String
    public var title: String
    public var fogDensity: Double
    public var haze: Double
    public var colorHex: String
    public var notes: String?
}



@available(macOS 26.0, *)
public struct Animate3DProductionStatus: Sendable {
    public var sceneName: String = ""
    public var backgroundName: String = ""
    public var worldChunkTitle: String?
    public var generationQueueItems: [Animate3DGenerationQueueItem] = []
    public var modelBackedCharacterCount: Int { 0 }
    public var bundleReadiness: [Animate3DCharacterBundleReadinessStatus] { [] }
    public var runtimeCharacters: [Animate3DRuntimeCharacterStatus] { [] }
    public static let empty = Animate3DProductionStatus()
}

@available(macOS 26.0, *)
public struct Animate3DRuntimeCharacterStatus: Sendable {
    public var characterName: String
    public var modelSourcePath: String?
    public var sourceExpressionCue: String?
    public var expressionBehaviorCue: String?
    public var activeExpressionCue: String?
    public var expressionCueProvenance: String?
    public var sourceVisemeCue: String?
    public var activeVisemeCue: String?
    public var visemeCueProvenance: String?
    public var sourceActionCue: String?
    public var resolvedMotionID: String?
    public var resolvedMotionTitle: String?
    public var motionProvenance: String?
    public var resolvedHoldMultiplier: Int = 1
    public var holdProvenance: String?
    public var motionHintSummary: String?
}

@available(macOS 26.0, *)
public struct Animate3DCharacterBundleReadinessStatus: Sendable {
    public var resolvedBundleSourcePath: String
    public var resolvedBundleAssetPaths: [String] { [] }
}

@available(macOS 26.0, *)
public enum Animate3DGenerationQueueItemKind: String, Codable, Sendable {
    case bodyModel, faceRig, mouthProfile, expressionLibrary, motionSet, materialProfile
    case worldChunk, worldMesh, worldPreviewImage
    case styleProfile, cameraPresetLibrary, lightRig, atmospherePreset
}

@available(macOS 26.0, *)
public enum ManifestKind: String, Codable, Sendable {
    case worldCatalog, characterRegistry, motionRegistry, styleProfiles, cameraPresets, lightRigs, atmospherePresets
}

@available(macOS 26.0, *)
public struct Animate3DGenerationQueueItem: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var kind: Animate3DGenerationQueueItemKind
    public var title: String
    public var detail: String
    public var destinationPath: String
    public var providerHint: String
    public var prompt: String
    public var contextSummary: String?
    public var characterSlug: String?
    public var characterName: String?
    public var manifestKind: ManifestKind?
    public var stableKey: String { "\(kind.rawValue)|\(characterSlug ?? "world")" }
    public var destinationDescription: String { destinationPath }
    public var draftAspectRatio: String { "1:1" }
}

@available(macOS 26.0, *)
public final class Animate3DAssetGapQueueService: @unchecked Sendable {
    init(store: AnimateStore) {}
    func queueMissingDrafts(scene: AnimationScene, status: Animate3DProductionStatus) -> Int { 0 }
}



@available(macOS 26.0, *)
public final class Animate3DProductionCoordinator: @unchecked Sendable {
    public var status: Animate3DProductionStatus { Animate3DProductionStatus() }
    init(store: AnimateStore) {}
    func refresh(scene: AnimationScene, lyrics: String, scenario: Animate3DScenarioMode, forceReload: Bool) async {}
}

@available(macOS 26.0, *)
public enum Animate3DScenarioMode {
    case selectedScene, fixture
}





@available(macOS 26.0, *)
public struct Animate3DScenario: Sendable {
    public var sourceKind: Animate3DScenarioSourceKind = .fixture
    public var validation: Animate3DScenarioValidation = Animate3DScenarioValidation()
    public var castNames: [String] = []
    public var shotMarkers: [Animate3DShotMarker] = []
    public var diagnostics: Animate3DScenarioDiagnostics = Animate3DScenarioDiagnostics()
    var compiledScene: AnimationScene?
    public var parsedDirectionCount: Int = 0
}

@available(macOS 26.0, *)
public enum Animate3DScenarioSourceKind: String, Codable, Sendable {
    case fixture, selectedScene, parsedDirections, selectedTimeline
}

@available(macOS 26.0, *)
public struct Animate3DScenarioValidation: Sendable {
    public var ready: Bool = false
    public var warnings: [String] = []
}

@available(macOS 26.0, *)
public struct Animate3DScenarioDiagnostics: Sendable {
    public var attachmentCount: Int = 0
    public var cameraTrackCount: Int = 0
    public var shotSegmentCount: Int = 0
}

@available(macOS 26.0, *)
public struct Animate3DShotMarker: Sendable {
    public var title: String
    public var frame: Int
    var cameraShot: CameraShot
}

@available(macOS 26.0, *)
public struct Animate3DMotionTrail: Sendable {
    public var kind: Animate3DMotionTrailKind
    public var points: [SIMD3<Double>]
}

@available(macOS 26.0, *)
public enum Animate3DMotionTrailKind: String, Sendable {
    case character, prop, camera
}

@available(macOS 26.0, *)
public struct Animate3DCharacterSnapshot: Codable, Sendable {
    public var id: String
    public var name: String
    public var worldPosition: SIMD3<Double>
    public var yawDegrees: Double
    public var opacity: Double
    public var visible: Bool
    public var pose: String?
    public var expression: String?
    public var action: String?
    public var colorIndex: Int
}

@available(macOS 26.0, *)
public struct Animate3DPlaceholderPoseProfile: Sendable {
    public var primaryTag: String
    public var tags: [String]
    public static func evaluate(_ snapshot: Animate3DCharacterSnapshot) -> Animate3DPlaceholderPoseProfile {
        if snapshot.pose != nil || snapshot.expression != nil || snapshot.action != nil {
            return Animate3DPlaceholderPoseProfile(primaryTag: "neutral", tags: ["neutral"])
        }
        return Animate3DPlaceholderPoseProfile(primaryTag: "neutral", tags: ["neutral"])
    }
}



@available(macOS 26.0, *)
public struct Animate3DResolvedBundleInfo: Sendable {
    public var sourceManifestPath: String
    public var resolvedAssetPaths: [String] { [] }
}

@available(macOS 26.0, *)
public enum Animate3DGenerationProviderRoute: String, Codable, Sendable, Equatable {
    case meshy, geminiOnly, externalImport, inAppConfig, manual
    public static func defaultRoute(for kind: String) -> Animate3DGenerationProviderRoute {
        switch kind {
        case "bodyModel": return .meshy
        case "faceRig", "mouthProfile", "expressionLibrary", "motionSet", "materialProfile", "worldPreviewImage": return .geminiOnly
        case "worldChunk", "worldMesh": return .externalImport
        case "styleProfile", "cameraPresetLibrary", "lightRig", "atmospherePreset": return .inAppConfig
        default: return .manual
        }
    }
    public var isAutomatable: Bool {
        switch self { case .meshy, .geminiOnly: return true; default: return false }
    }
    public var estimatedMeshyCredits: Int? {
        if self == .meshy { return 30 }
        return nil
    }
}

@available(macOS 26.0, *)
public enum Animate3DGenerationQueueActionSupport {
    public struct PreflightOwner {
        public var characterID: UUID?
        public var characterSlug: String?
        public var outputRootRelativePath: String?
        init(item: Animate3DGenerationQueueItem, store: AnimateStore) {
            characterSlug = item.characterSlug
            outputRootRelativePath = item.kind == .worldPreviewImage ? "3d/world-catalog/batch-queue-batches" : nil
        }
    }
    static func queuePreflightDrafts(_ drafts: [GeminiGenerationDraft], owner: PreflightOwner, store: AnimateStore) -> Int { 0 }
    static func queuePreflightDrafts(_ drafts: [GeminiGenerationDraft], ownersByDraftID: [UUID: PreflightOwner], store: AnimateStore) -> Int { 0 }
    static func isQueued(item: Animate3DGenerationQueueItem, store: AnimateStore) -> Bool { false }
    static func manifestEditorContext(for item: Animate3DGenerationQueueItem, projectURL: URL) -> ManifestEditorContext? { nil }
    static func prioritizedItems(from items: [Animate3DGenerationQueueItem], pinnedKeys: [String], skippedKeys: [String]) -> [Animate3DGenerationQueueItem] { items }
    static func applyOverrides(to draft: GeminiGenerationDraft, item: Animate3DGenerationQueueItem, overridesByStableKey: [String: Animate3DGenerationDraftOverride]) -> GeminiGenerationDraft { draft }
    static func queue(items: [Animate3DGenerationQueueItem], scene: AnimationScene, status: Animate3DProductionStatus, store: AnimateStore) -> Int { 0 }
}

@available(macOS 26.0, *)
public struct ManifestEditorContext: Sendable {
    public var kind: ManifestKind
    public var relativePath: String
}

@available(macOS 26.0, *)
public final class Animate3DGenerationQueuePlanner {
    init(store: AnimateStore) {}
}

@available(macOS 26.0, *)
public final class Animate3DTestHarnessState {
    private var providerHintOverrides: [String: String] = [:]
    private var promptAppendices: [String: String] = [:]
    public func setProviderHintOverride(_ hint: String, for key: String) { providerHintOverrides[key] = hint }
    public func setPromptAppendix(_ appendix: String, for key: String) { promptAppendices[key] = appendix }
    public func generationDraftOverride(for key: String) -> Animate3DGenerationDraftOverride {
        Animate3DGenerationDraftOverride(
            providerHintOverride: providerHintOverrides[key],
            promptAppendix: promptAppendices[key],
            isLocked: false
        )
    }
    public func clearGenerationDraftOverride(for key: String) {
        providerHintOverrides.removeValue(forKey: key)
        promptAppendices.removeValue(forKey: key)
    }
    public func clearGenerationDraftOverrides(for keys: [String]) {
        for key in keys { clearGenerationDraftOverride(for: key) }
    }
}

@available(macOS 26.0, *)
public struct Animate3DRegistryIndex {
    public var worldCatalogPath: String { "Animate/3d/world-catalog/world-catalog.json" }
}

@available(macOS 26.0, *)
public final class SceneAssetPipeline {
    init(store: AnimateStore) {}
    public func characterModelFileName(slug: String) -> String { "\(slug).glb" }
    public func characterPerformanceProfileSourceRelativePath(slug: String) -> String? { nil }
    func loadCharacterPerformanceProfile(slug: String) -> Character3DPerformanceProfile? { nil }
}



@available(macOS 26.0, *)
public enum Viseme: String, Codable, Sendable {
    case mbp, rest, AI, E, O, U, CDGKLNRSThYZF, MBP
}

@available(macOS 26.0, *)
public struct Animate3DCharacterPerformanceStatus: Sendable {
    public var characterName: String = ""
    public var profileSourceCount: Int = 0
    public var expressionPresetCount: Int = 0
    public var visemePresetCount: Int = 0
    public var activeExpressionCue: String?
    public var resolvedExpressionPresetCue: String?
    public var expressionCueProvenance: String?
    public var usingExpressionPreset: Bool { false }
    public var activeVisemeCue: String?
    public var resolvedVisemePresetCue: String?
    public var visemeCueProvenance: String?
    public var usingVisemePreset: Bool { false }
    public var sourceActionCue: String?
    public var resolvedMotionTitle: String?
    public var motionProvenance: String?
    public var resolvedHoldMultiplier: Int = 1
    public var holdProvenance: String?
    public var profileSourcePaths: [String] = []
}

@available(macOS 26.0, *)
public final class Animate3DPackageCutoutService {
    public init() {}
}

@available(macOS 26.0, *)
public final class Animate3DAssetBridgeService {
    public init() {}
}
