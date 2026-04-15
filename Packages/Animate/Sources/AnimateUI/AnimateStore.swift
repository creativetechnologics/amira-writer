import SwiftUI
import Observation
import Metal
import QuartzCore
import ImageIO
import ProjectKit
import UniformTypeIdentifiers
import CoreMedia
import CryptoKit

@MainActor
private final class AnimateDisplayLinkProxy: NSObject {
    weak var store: AnimateStore?

    init(store: AnimateStore) {
        self.store = store
    }

    @objc func handleDisplayLinkTick(_ displayLink: CADisplayLink) {
        store?.advanceFrame()
    }
}

private struct AnimateExternalFileSnapshot: Equatable, Sendable {
    let modificationDate: Date
    let fileSize: Int64
}

private struct PlaceWorldGenerationBatchResultsSummary: Sendable {
    var rowCount: Int
    var successCount: Int
    var errorCount: Int
    var failures: [PlaceWorldGenerationBatchFailure]
    var decodedImagePaths: [String]
}

private struct GeneratedBackgroundReviewStateRecord: Codable, Sendable {
    var id: UUID = UUID()
    var canonicalPath: String
    var pathAliases: [String] = []
    var contentFingerprint: String?
    var rating: Int?
    var isRejected: Bool = false
    var rejectionNotes: String = ""
    var draftEditNotes: String = ""
    var updatedAt: Date = .now
}

private struct GeneratedBackgroundReviewStateLibrary: Codable, Sendable {
    var recordOverrides: [GeneratedBackgroundReviewStateRecord] = []
}

struct StoredImageGenerationMetadata: Hashable, Sendable {
    let prompt: String
    let model: String
    let aspectRatio: String
    let imageSize: String
    let placeID: UUID?
    let routeID: UUID?
    let worldNodeID: UUID?
    let mapPoint: WorldMapPoint?
    let cameraPose: WorldCameraPose?
    let mapPlacementStatus: GeneratedBackgroundMapPlacementStatus?
    let buildingAnchorNodeID: UUID?
    let orientationState: GeneratedBackgroundOrientationState?
}

enum GeneratedBackgroundFlagFilterMode: String, CaseIterable, Sendable {
    case all
    case unflagged
    case rejected

    var displayName: String {
        switch self {
        case .all: "All"
        case .unflagged: "Unflagged"
        case .rejected: "Rejected"
        }
    }
}

enum GeneratedBackgroundWorkflowFilterMode: String, CaseIterable, Sendable {
    case all = "All"
    case photorealistic = "Photo"
    case animated = "Animate"

    var displayName: String { rawValue }
}

@available(macOS 26.0, *)
@Observable @MainActor
final class AnimateStore {
    // MARK: - OWP Project

    /// When true, the external file watcher is disabled (e.g. in Opera multi-mode shell).
    var disableExternalFileWatch = false
    var owpURL: URL?
    var workingOWPURL: URL?
    var animateMetadata: AnimateMetadata?
    var scenes: [AnimationScene] = []
    var selectedSceneID: UUID? {
        didSet {
            syncSelectedSceneTimeline()
        }
    }
    /// Raw OWP character data (images, colors) — read from characters.json.
    var owpCharacters: [OPWCharacter] = []
    var owpIndexFile: OWPIndexFile?
    var owpInstrumentMappings: [OWPInstrumentMapping] = []

    /// The Animate/ subdirectory inside the OWP package — all writes go here.
    var animateURL: URL? {
        (workingOWPURL ?? owpURL)?.appendingPathComponent("Animate")
    }

    var fileOWPURL: URL? {
        workingOWPURL ?? owpURL
    }

    // MARK: - Characters

    var characters: [AnimationCharacter] = []
    var selectedCharacterID: UUID?
    var activePackageIDsByCharacterSlug: [String: UUID] = [:]
    var shotPresets: [SceneShotPreset] = []

    // MARK: - Motion Capture State

    var mocapIsRunning = false
    var mocapCameraID: String?
    var mocapLatestPoseFrame: UnifiedPoseFrame?
    var mocapFrameCount: Int = 0
    var mocapErrorMessage: String?
    var mocapFilterEnabled = true

    nonisolated(unsafe) var mocapCaptureSession: CaptureSession?
    nonisolated(unsafe) var mocapBodyTracker: VisionBodyTracker?
    nonisolated(unsafe) var mocapDWPoseTracker: DWPoseTracker? = nil
    var mocapTemporalFilter = TemporalFilterManager()
    var mocapTrackingMode: CaptureTrackingMode = .standard

    // MARK: - Canvas Generation

    struct CanvasGeneration: Identifiable, Codable, Hashable, Sendable {
        var id: UUID = UUID()
        var createdAt: Date = Date()
        var prompt: String
        var model: GeminiModel
        var aspectRatio: String
        var imageSize: String
        var imagePath: String   // absolute path to .png on disk
        var referenceCount: Int
    }

    var canvasGenerations: [CanvasGeneration] = []

    // MARK: - Imagine State

    var selectedImaginePage: ImaginePage = .characters
    var imagineSceneGalleries: [UUID: [ImagineSceneShotGallery]] = [:]
    var imagineBulkRunConfig: ImagineBulkRunConfig = .init()
    var imagineBulkRunProgress: ImagineBulkRunProgress = .init()
    var geminiMasterSwitch: Bool = false
    var imagineSelectedShotIndex: Int? = nil
    var imagineSelectedMoment: ImagineShotMoment = .beginning
    var imaginePreviewImagePath: String? = nil

    // MARK: - Mocap Live Override

    var liveMocapBlendShapes: [BlendShapeName: Float]?
    var mocapDirectMorphMode: Bool = true

    func startMocap() {
        guard !mocapIsRunning else { return }
        mocapErrorMessage = nil
        mocapFrameCount = 0
        mocapLatestPoseFrame = nil
        mocapTemporalFilter.reset()

        let capture = CaptureSession()
        let tracker = VisionBodyTracker { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var finalFrame = frame
                if self.mocapFilterEnabled, let joints = frame.bodyJoints {
                    let filtered = self.mocapTemporalFilter.filter(
                        joints: joints,
                        timestamp: frame.timestamp
                    )
                    finalFrame = UnifiedPoseFrame(
                        timestamp: frame.timestamp,
                        source: frame.source,
                        bodyJoints: filtered,
                        bodyConfidences: frame.bodyConfidences,
                        leftHandJoints: frame.leftHandJoints,
                        rightHandJoints: frame.rightHandJoints,
                        faceBlendShapes: frame.faceBlendShapes,
                        faceLandmarks: frame.faceLandmarks
                    )
                }
                self.mocapLatestPoseFrame = finalFrame
                self.mocapFrameCount += 1
            }
        }

        capture.setPixelBufferHandler { [weak tracker] pixelBuffer, presentationTime in
            let seconds = CMTimeGetSeconds(presentationTime)
            tracker?.processFrame(pixelBuffer, timestamp: seconds)
        }

        capture.onStateChange = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .running:
                    self.mocapIsRunning = true
                    self.mocapErrorMessage = nil
                case .failed:
                    self.mocapIsRunning = false
                    self.mocapErrorMessage = "Camera failed to start. Check permissions or camera connection."
                case .stopped:
                    self.mocapIsRunning = false
                default:
                    break
                }
            }
        }

        mocapCaptureSession = capture
        mocapBodyTracker = tracker
        capture.start(cameraID: mocapCameraID)
    }

    func stopMocap() {
        mocapCaptureSession?.stop()
        mocapCaptureSession = nil
        mocapBodyTracker = nil
        mocapIsRunning = false
    }

    // MARK: - Image Crop State

    private let assetManager = AssetManager()
    var pendingCropImagePath: String?
    var pendingCropCharacterID: UUID?
    var showImageCropper: Bool = false

    // MARK: - Variant Crop State

    var pendingVariantCropCharacterID: UUID? = nil
    var pendingVariantCropSlotKey: String? = nil
    var pendingVariantCropVariantID: UUID? = nil
    var pendingVariantCropSourceSheetPath: String? = nil
    var pendingVariantCropInitialRect: CropRect? = nil
    var showVariantCropper: Bool = false

    // MARK: - Image Eraser State

    var pendingEraserImagePath: String? = nil
    var showImageEraser: Bool = false

    func openEraseTool(for imagePath: String) {
        pendingEraserImagePath = imagePath
        showImageEraser = true
    }

    func closeEraseTool() {
        pendingEraserImagePath = nil
        showImageEraser = false
    }

    // MARK: - Motion Clips

    var motionClips: [MotionClip] = []
    var selectedMotionClipID: UUID?

    // Video import state (backing vars used by extension computed properties)
    var _isImportingVideo: Bool = false
    var _videoImportProgress: VideoMotionExtractor.ExtractionProgress? = nil
    var _videoImportCancelled: Bool = false
    // Atomic cancel flag accessible from Sendable closures
    let _videoImportCancelBox = MocapAtomicState(false)

    // Audio lip sync state
    var isRecordingAudioLipSync: Bool = false
    nonisolated(unsafe) var _audioLipSyncRecorder: AudioLipSyncRecorder? = nil

    var selectedMotionClip: MotionClip? {
        motionClips.first { $0.id == selectedMotionClipID }
    }

    // MARK: - Song Data Cache

    /// Cached song data for the currently selected scene.
    var currentSongData: OWSSongData?

    // MARK: - Backgrounds

    var backgrounds: [BackgroundPlate] = []
    var selectedBackgroundID: UUID?
    var scriptPlaceRequirements: [PlacesScriptSceneRequirement] = []
    var isRefreshingPlacesIndex: Bool = false
    var placeGenerationStatusByID: [UUID: String] = [:]
    var generatingPlaceIDs: Set<UUID> = []
    var placesWorkflowLibrary: PlacesWorkflowLibrary = .init()
    var placesWorldMapCanonLibrary: PlacesWorldMapCanonLibrary = .init()
    private var placesWorldMapCanonRawPayload: [String: Any] = [:]
    private var placesGeneratedReviewStateLibrary: GeneratedBackgroundReviewStateLibrary = .init()
    var drawThingsPlaceConfig: DrawThingsPlaceConfig = .init()
    var selectedGeneratedBackgroundRecordID: UUID?
    private var generatedBackgroundFingerprintCache: [String: (snapshot: AnimateExternalFileSnapshot, digest: String)] = [:]

    var selectedPlace: BackgroundPlate? {
        backgrounds.first { $0.id == selectedBackgroundID }
    }

    var selectedGeneratedBackgroundRecord: GeneratedBackgroundLibraryRecord? {
        placesWorkflowLibrary.generatedImageRecords.first { $0.id == selectedGeneratedBackgroundRecordID }
    }

    var hasPendingGeneratedBackgroundEdits: Bool {
        !placesWorkflowLibrary.pendingEditQueue.isEmpty
    }

    var selectedScenePlaceRequirement: PlacesScriptSceneRequirement? {
        guard let selectedSceneID else { return nil }
        return scriptPlaceRequirements.first { $0.sceneID == selectedSceneID }
    }

    var indexedPlaces: [PlacesIndexedEntry] {
        let orderByKey = scriptPlaceRequirements
            .flatMap(\.locations)
            .enumerated()
            .reduce(into: [String: Int]()) { partialResult, entry in
                partialResult[entry.element.normalizedKey] = min(
                    partialResult[entry.element.normalizedKey] ?? .max,
                    entry.offset
                )
            }

        let grouped = Dictionary(grouping: scriptPlaceRequirements.flatMap { requirement in
            requirement.locations.map { location in
                (
                    key: location.normalizedKey,
                    reference: PlacesScriptSceneReference(
                        sceneID: requirement.sceneID,
                        sceneName: requirement.sceneName,
                        songPath: requirement.songPath
                    ),
                    inferredCategory: location.inferredCategory,
                    sourceLine: location.sourceLine
                )
            }
        }, by: \.key)

        return grouped.compactMap { key, values in
            guard let place = backgrounds.first(where: {
                PlacesScriptIndexService.normalizedKey(for: $0.name) == key
            }) else {
                return nil
            }

            let references = Array(Set(values.map(\.reference)))
                .sorted { lhs, rhs in
                    lhs.songPath.localizedStandardCompare(rhs.songPath) == .orderedAscending
                }
            let sourceLines = Array(Set(values.compactMap(\.sourceLine)))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let inferredCategory = values
                .map(\.inferredCategory)
                .first(where: { !$0.isEmpty }) ?? ""

            return PlacesIndexedEntry(
                placeID: place.id,
                displayName: place.name,
                normalizedKey: key,
                inferredCategory: inferredCategory,
                sceneReferences: references,
                sourceLines: sourceLines
            )
        }
        .sorted { lhs, rhs in
            let lhsOrder = orderByKey[lhs.normalizedKey] ?? .max
            let rhsOrder = orderByKey[rhs.normalizedKey] ?? .max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - Timeline

    var currentFrame: Int = 0
    var fps: Int = 24
    var isPlaying: Bool = false
    var totalFrames: Int = 0

    // MARK: - NLA Motion Timeline

    /// The NLA timeline for the currently selected scene.
    var nlaTimeline: NLATimeline?
    /// The most recently evaluated blended pose from NLA evaluation.
    var nlaBlendedPose: BlendedPose?
    /// Cache of loaded motion clip data, keyed by MotionClip UUID.
    @ObservationIgnored private var motionClipDataCache: [UUID: NLAEvaluator.MotionClipData] = [:]

    // MARK: - Gemini

    /// Running total of all Gemini API calls made in this session.
    var geminiAPICallCount: Int = 0
    /// Rolling log of the last 100 Gemini API calls (date, endpoint, source).
    var geminiAPICallLog: [(date: Date, endpoint: String, source: String)] = []

    /// Record a Gemini API call for auditing and display.
    func logGeminiAPICall(endpoint: String, source: String) {
        geminiAPICallCount += 1
        geminiAPICallLog.append((date: Date(), endpoint: endpoint, source: source))
        // Keep only the last 100 entries to bound memory usage.
        if geminiAPICallLog.count > 100 {
            geminiAPICallLog.removeFirst(geminiAPICallLog.count - 100)
        }
        print("[AnimateStore] Gemini API call #\(geminiAPICallCount): \(source) → \(endpoint)")
    }

    var geminiAPIKey: String = "" {
        didSet {
            guard !isHydratingGeminiSettings else { return }
            geminiCredentialStore.saveAPIKey(geminiAPIKey)
        }
    }
    var selectedGeminiModel: GeminiModel = .flash {
        didSet {
            guard !isHydratingGeminiSettings else { return }
            UserDefaults.standard.set(selectedGeminiModel.rawValue, forKey: Self.geminiModelDefaultsKey)
        }
    }

    // MARK: - MiniMax Settings

    var miniMaxAPIKey: String = "" {
        didSet {
            guard !isHydratingMiniMaxSettings else { return }
            miniMaxCredentialStore.saveAPIKey(miniMaxAPIKey)
        }
    }

    // MARK: - Vidu Settings

    var viduAPIKey: String = "" {
        didSet {
            guard !isHydratingViduSettings else { return }
            viduCredentialStore.saveAPIKey(viduAPIKey)
        }
    }

    @ObservationIgnored private var isHydratingRunPodSettings = false
    var runPodAPIKey: String = "" {
        didSet {
            guard !isHydratingRunPodSettings else { return }
            runPodCredentialStore.saveAPIKey(runPodAPIKey)
            runPodAccountSummary = nil
            runPodAccountStatusMessage = nil
        }
    }
    var runPodAccountSummary: RunPodAccountService.AccountSummary?
    var runPodAccountStatusMessage: String?
    var isRefreshingRunPodAccountSummary: Bool = false
    var runPodGPUPriceSummaries: [RunPodAccountService.GPUPriceSummary] = []
    var viduQueue: [ViduBatchQueueItem] = []

    var isGeneratingLLMPlan: Bool = false

    // MARK: - Animate Scene Macro (Item 16)

    var isRunningAnimateMacro: Bool = false
    var animateMacroStatus: String = ""

    // MARK: - Batch Scene Processing (Item 17)

    var batchProcessingQueue: [UUID] = []
    var batchProcessingActive: Bool = false
    var batchProcessingCurrentSceneID: UUID? = nil

    // MARK: - Generation Sheet State

    var showGenerationSheet: Bool = false
    var showRigEditor: Bool = false
    var showExportSheet: Bool = false
    // show3DExportSheet removed — 3D workspace archived; use standard export sheet
    var generationTargetPartID: UUID?
    var generationTargetAngle: AngleView?

    // MARK: - Gemini Generation Queue

    struct GeminiBatchQueueItem: Identifiable, Sendable {
        var id: UUID = UUID()
        var characterID: UUID?
        var characterName: String
        var characterSlug: String?
        var draftTitle: String
        var draft: GeminiGenerationDraft
        var outputRootRelativePath: String?
        var dateQueued: Date = Date()

        var groupingKey: String {
            if let characterID { return "character:\(characterID.uuidString)" }
            if let outputRootRelativePath,
               !outputRootRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "pipeline:\(outputRootRelativePath)"
            }
            return "pipeline:\(characterName)"
        }
    }

    var geminiQueue: [GeminiBatchQueueItem] = []

    func addToGeminiQueue(
        characterID: UUID?,
        characterName: String,
        draftTitle: String,
        draft: GeminiGenerationDraft,
        characterSlug: String? = nil,
        outputRootRelativePath: String? = nil
    ) {
        geminiQueue.append(GeminiBatchQueueItem(
            characterID: characterID,
            characterName: characterName,
            characterSlug: characterSlug,
            draftTitle: draftTitle,
            draft: draft,
            outputRootRelativePath: outputRootRelativePath
        ))
    }

    func removeGeminiQueueItem(_ id: UUID) { geminiQueue.removeAll { $0.id == id } }
    func clearGeminiQueue() { geminiQueue.removeAll() }

    // MARK: - Scene Tracks (from direction compiler or manual editing)

    var sceneTracks: [String: TimelineTrack] = [:]
    var cameraTrack: TimelineTrack?

    // MARK: - Playback Engine

    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var displayLinkRunning = false
    @ObservationIgnored private var displayLinkProxy: AnimateDisplayLinkProxy?
    @ObservationIgnored private var isHydratingGeminiSettings = false
    @ObservationIgnored private var isHydratingMiniMaxSettings = false
    @ObservationIgnored private var isHydratingViduSettings = false
    @ObservationIgnored private var isHydratingDrawThingsPlacesConfig = false
    @ObservationIgnored private var isHydratingPlacesWorkflowLibrary = false

    // MARK: - Track Resolution Cache
    // Caches the result of timelineTrack(for:role:) and related lookups so
    // that per-frame snapshot evaluation does not rescan allTimelineTracks()
    // for every property of every character.  Invalidated on scene or track
    // changes via invalidateTrackCache().
    @ObservationIgnored private var characterTrackCache: [CharacterTrackCacheKey: TimelineTrack?] = [:]
    @ObservationIgnored private var objectTrackCache: [ObjectTrackCacheKey: TimelineTrack?] = [:]
    @ObservationIgnored private var trackCacheSceneID: UUID?
    @ObservationIgnored private var trackCacheSceneTrackCount: Int = 0
    private let characterPackageSelectionStore = CharacterPackageSelectionStore()
    private let sceneShotPresetStore = SceneShotPresetStore()
    private let geminiCredentialStore = GeminiCredentialStore()
    private let miniMaxCredentialStore = MiniMaxCredentialStore()
    private let viduCredentialStore = ViduCredentialStore()
    private let runPodCredentialStore = RunPodCredentialStore()
    private let runPodAccountService = RunPodAccountService()
    private let sceneAutomationPlanner = SceneAutomationPlanner()
    let audioPlayer = AnimationAudioPlayer()
    private var backgroundIndexRefreshTask: Task<Void, Never>?
    private var fileWatchTask: Task<Void, Never>?
    private var lastKnownExternalSnapshots: [String: AnimateExternalFileSnapshot] = [:]
    @ObservationIgnored private var lastSavedPersistenceFingerprint: String?
    @ObservationIgnored private var isReconcilingPersistenceState = false
    private static let externalWatchInterval: TimeInterval = 0.55
    var externalChangeTimes: [String: Date] = [:]
    var isAgentSyncInProgress: Bool = false
    var hasPendingAgentChanges: Bool = false
    var showsRecentAgentUpdate: Bool = false

    var collaborationBadgeLabel: String? {
        if isAgentSyncInProgress {
            return "Agent Syncing"
        }
        if hasPendingAgentChanges {
            return "Agent Changes Waiting"
        }
        if showsRecentAgentUpdate {
            return "Agent Updated"
        }
        return nil
    }

    var collaborationBadgeSystemImage: String {
        if hasPendingAgentChanges {
            return "exclamationmark.arrow.triangle.2.circlepath"
        }
        return showsRecentAgentUpdate ? "sparkles" : "arrow.triangle.2.circlepath"
    }

    private static let geminiModelDefaultsKey = "novotro.animate.gemini.model"

    init() {
        AppLog.rollIfLarge()
        AppLog.log("STARTUP", "AnimateStore init — log file at \(AppLog.logFileURL.path)")
        observePersistedSaveState()
        hydrateGeminiSettings()
        hydrateMiniMaxSettings()
        hydrateViduSettings()
        hydrateRunPodSettings()
    }

    func setGeminiAPIKey(_ apiKey: String) {
        geminiAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearGeminiAPIKey() {
        geminiAPIKey = ""
    }

    private func hydrateGeminiSettings() {
        isHydratingGeminiSettings = true
        geminiAPIKey = geminiCredentialStore.loadAPIKey()
        if let rawModel = UserDefaults.standard.string(forKey: Self.geminiModelDefaultsKey),
           let model = GeminiModel(rawValue: rawModel) {
            selectedGeminiModel = model
        } else {
            selectedGeminiModel = .flash
        }
        isHydratingGeminiSettings = false
    }

    private func hydrateMiniMaxSettings() {
        isHydratingMiniMaxSettings = true
        miniMaxAPIKey = miniMaxCredentialStore.loadAPIKey()
        isHydratingMiniMaxSettings = false
    }

    private func hydrateRunPodSettings() {
        isHydratingRunPodSettings = true
        runPodAPIKey = runPodCredentialStore.loadAPIKey()
        isHydratingRunPodSettings = false
    }

    func setMiniMaxAPIKey(_ apiKey: String) {
        miniMaxAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearMiniMaxAPIKey() {
        miniMaxAPIKey = ""
    }

    @MainActor
    func refreshRunPodAccountSummary(using overrideAPIKey: String? = nil) async {
        let apiKey = (overrideAPIKey ?? runPodAPIKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            runPodAccountSummary = nil
            runPodAccountStatusMessage = "RunPod API key not set."
            return
        }

        isRefreshingRunPodAccountSummary = true
        defer { isRefreshingRunPodAccountSummary = false }

        do {
            async let summaryTask = runPodAccountService.fetchAccountSummary(apiKey: apiKey)
            async let gpuPricesTask = runPodAccountService.fetchGPUPrices(apiKey: apiKey)
            let summary = try await summaryTask
            let gpuPrices = try await gpuPricesTask
            runPodAccountSummary = summary
            runPodGPUPriceSummaries = gpuPrices
            if summary.underBalance {
                runPodAccountStatusMessage = "RunPod reports the account is under the minimum balance threshold."
            } else {
                runPodAccountStatusMessage = nil
            }
        } catch {
            runPodAccountSummary = nil
            runPodGPUPriceSummaries = []
            runPodAccountStatusMessage = error.localizedDescription
        }
    }

    func runPodGPUPriceSummary(for displayName: String) -> RunPodAccountService.GPUPriceSummary? {
        runPodGPUPriceSummaries.first { $0.displayName == displayName }
    }

    private func hydrateViduSettings() {
        isHydratingViduSettings = true
        viduAPIKey = viduCredentialStore.loadAPIKey()
        isHydratingViduSettings = false
    }

    func setViduAPIKey(_ apiKey: String) {
        viduAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearViduAPIKey() {
        viduAPIKey = ""
    }

    private func normalizedDrawThingsPlacesConfig(_ config: DrawThingsPlaceConfig) -> DrawThingsPlaceConfig {
        var normalized = config
        normalized.steps = max(4, min(normalized.steps, 8))
        return normalized
    }

    private func hydrateDrawThingsPlacesConfig(_ config: DrawThingsPlaceConfig) {
        isHydratingDrawThingsPlacesConfig = true
        drawThingsPlaceConfig = normalizedDrawThingsPlacesConfig(config)
        isHydratingDrawThingsPlacesConfig = false
    }

    func updateDrawThingsPlacesConfig(_ config: DrawThingsPlaceConfig) {
        let normalized = normalizedDrawThingsPlacesConfig(config)
        guard drawThingsPlaceConfig != normalized else { return }
        drawThingsPlaceConfig = normalized
        save(writePlaces: true)
    }

    func sceneRequirement(for sceneID: UUID?) -> PlacesScriptSceneRequirement? {
        guard let sceneID else { return nil }
        return scriptPlaceRequirements.first { $0.sceneID == sceneID }
    }

    func sceneLocationNames(for sceneID: UUID?) -> [String] {
        sceneRequirement(for: sceneID)?.locations.map(\.displayName) ?? []
    }

    func sceneReferences(for placeID: UUID) -> [PlacesScriptSceneReference] {
        indexedPlaces.first(where: { $0.placeID == placeID })?.sceneReferences ?? []
    }

    func sourceLines(for placeID: UUID) -> [String] {
        indexedPlaces.first(where: { $0.placeID == placeID })?.sourceLines ?? []
    }

    func isGeneratingPlaceImage(_ placeID: UUID) -> Bool {
        generatingPlaceIDs.contains(placeID)
    }

    func placeGenerationStatus(for placeID: UUID) -> String? {
        placeGenerationStatusByID[placeID]
    }

    func workflowConfig(for mode: PlaceWorkflowMode) -> PlaceWorkflowRenderConfig {
        switch mode {
        case .photorealistic:
            placesWorkflowLibrary.photorealConfig
        case .animated:
            placesWorkflowLibrary.animatedConfig
        }
    }

    func selectPlacesScene(_ sceneID: UUID) {
        selectedSceneID = sceneID
        if let primaryKey = sceneRequirement(for: sceneID)?.primaryLocation?.normalizedKey,
           let place = backgrounds.first(where: {
               PlacesScriptIndexService.normalizedKey(for: $0.name) == primaryKey
           }) {
            selectedBackgroundID = place.id
        }
        if let scene = scenes.first(where: { $0.id == sceneID }) {
            Task { await loadSongData(for: scene) }
        }
    }

    func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true
        statusMessage = "Playing"

        if displayLink == nil {
            if displayLinkProxy == nil {
                displayLinkProxy = AnimateDisplayLinkProxy(store: self)
            }
            if let displayLinkProxy {
                displayLink = (NSScreen.main ?? NSScreen.screens.first)?.displayLink(
                    target: displayLinkProxy,
                    selector: #selector(AnimateDisplayLinkProxy.handleDisplayLinkTick(_:))
                )
            }
            displayLink?.add(to: .main, forMode: .common)
        }

        if let displayLink {
            displayLink.isPaused = false
            displayLinkRunning = true
        }
    }

    func stopPlayback() {
        guard isPlaying else { return }
        if let displayLink, displayLinkRunning {
            displayLink.isPaused = true
            displayLinkRunning = false
        }
        isPlaying = false
        statusMessage = "Paused at frame \(currentFrame)"
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private var frameAccumulator: Double = 0
    private var lastFrameTime: CFTimeInterval = 0

    fileprivate func advanceFrame() {
        guard isPlaying else { return }

        let now = CACurrentMediaTime()
        if lastFrameTime == 0 {
            lastFrameTime = now
            return
        }

        let elapsed = now - lastFrameTime
        lastFrameTime = now

        frameAccumulator += elapsed * Double(fps)
        let framesToAdvance = Int(frameAccumulator)
        if framesToAdvance > 0 {
            frameAccumulator -= Double(framesToAdvance)
            currentFrame += framesToAdvance

            if totalFrames > 0, currentFrame >= totalFrames {
                currentFrame = 0 // Loop
            }

            // Evaluate NLA timeline at the new frame
            evaluateNLAAtCurrentFrame()
        }
    }

    // MARK: - NLA Evaluation

    /// Evaluate the NLA timeline at the current frame and update the blended pose.
    func evaluateNLAAtCurrentFrame() {
        guard let timeline = nlaTimeline, !timeline.tracks.isEmpty else {
            nlaBlendedPose = nil
            return
        }
        nlaBlendedPose = NLAEvaluator.evaluate(
            timeline: timeline,
            frame: currentFrame,
            resolveClip: { [motionClipDataCache] clipID in
                motionClipDataCache[clipID]
            }
        )
    }

    /// Register a motion clip's data in the evaluator cache.
    func registerMotionClipData(id: UUID, data: NLAEvaluator.MotionClipData) {
        motionClipDataCache[id] = data
    }

    /// Remove a motion clip from the evaluator cache.
    func unregisterMotionClipData(id: UUID) {
        motionClipDataCache.removeValue(forKey: id)
    }

    /// Clear the entire motion clip cache.
    func clearMotionClipDataCache() {
        motionClipDataCache.removeAll()
    }

    /// Save the current NLA timeline to disk immediately.
    func saveNLATimeline() {
        guard let sceneID = selectedSceneID,
              let animateDir = animateURL,
              let timeline = nlaTimeline else { return }
        do {
            try NLATimelinePersistence.save(
                timeline: timeline, animateDir: animateDir, sceneID: sceneID
            )
        } catch {
            print("[AnimateStore] Failed to save NLA timeline: \(error)")
        }
    }

    // MARK: - Status

    var statusMessage: String = "Ready"
    var loadErrorMessage: String?
    private(set) var isLoadingProject: Bool = false
    var saveIndicator: SaveIndicatorState = .idle

    private static let cameraTrackName = "camera"
    private static let cameraShotTrackName = "camera:shot"
    private static let cameraDefaultShotTrackName = "camera:default-shot"
    private static let cameraFocusTrackName = "camera:focus"
    private static let cameraIntentTrackName = "camera:intent"
    private static let cameraBeatTrackName = "camera:beat"
    private static let cameraNotesTrackName = "camera:notes"

    // MARK: - Computed

    var selectedScene: AnimationScene? {
        scenes.first { $0.id == selectedSceneID }
    }

    var selectedCharacter: AnimationCharacter? {
        characters.first { $0.id == selectedCharacterID }
    }

    func suggestedExportAudioURL(for scene: AnimationScene? = nil) -> URL? {
        let scene = scene ?? selectedScene
        return normalizedMediaPath(scene?.defaultAudioPath).flatMap(resolvedMediaURL(for:))
    }

    func missingAssetRequests(for plan: LLMAnimationPlan) -> [AnimationAssetRequest] {
        AnimationAssetRequestPlanner().missingRequests(for: plan, characters: characters)
    }

    func timelineTrack(named name: String) -> TimelineTrack? {
        if name == Self.cameraTrackName {
            return cameraTrack ?? selectedScene?.tracks[Self.cameraTrackName]
        }

        if let track = sceneTracks[name] {
            return track
        }

        return selectedScene?.tracks[name]
    }

    func timelineTrack(
        for characterID: UUID,
        role: TimelineTrackRole
    ) -> TimelineTrack? {
        let preferredName = preferredTrackName(for: characterID, role: role)
        let preferredTrack = timelineTrack(named: preferredName)
        let preferredScore = preferredTrack.map { scoreForTrack($0, characterID: characterID, role: role) }

        let candidate = allTimelineTracks()
            .map { normalizeTimelineTrack($0) }
            .filter { track in
                track.targetCharacterID == characterID &&
                    resolvedTrackRole(for: track) == role
            }
            .min { lhs, rhs in
                scoreForTrack(lhs, characterID: characterID, role: role) <
                    scoreForTrack(rhs, characterID: characterID, role: role)
            }

        if let candidate {
            if let preferredScore {
                return preferredScore <= scoreForTrack(candidate, characterID: characterID, role: role)
                    ? normalizeTimelineTrack(preferredTrack!)
                    : candidate
            }

            return candidate
        }

        return preferredTrack.map { normalizeTimelineTrack($0) }
    }

    func timelineTrack(
        forObjectNamed objectName: String,
        role: TimelineTrackRole
    ) -> TimelineTrack? {
        let trimmedName = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let preferredName = preferredObjectTrackName(for: trimmedName, role: role)
        let preferredTrack = timelineTrack(named: preferredName)
        let preferredScore = preferredTrack.map { scoreForObjectTrack($0, objectName: trimmedName, role: role) }

        let candidate = allTimelineTracks()
            .map { normalizeTimelineTrack($0) }
            .filter { track in
                guard let address = parsedTrackAddress(for: track.name) else { return false }
                guard case let .object(candidateName, suffix) = address else { return false }
                return candidateName.caseInsensitiveCompare(trimmedName) == .orderedSame &&
                    TimelineTrackRole(trackSuffix: suffix) == role
            }
            .min { lhs, rhs in
                scoreForObjectTrack(lhs, objectName: trimmedName, role: role) <
                    scoreForObjectTrack(rhs, objectName: trimmedName, role: role)
            }

        if let candidate {
            if let preferredScore {
                return preferredScore <= scoreForObjectTrack(candidate, objectName: trimmedName, role: role)
                    ? normalizeTimelineTrack(preferredTrack!)
                    : candidate
            }

            return candidate
        }

        return preferredTrack.map { normalizeTimelineTrack($0) }
    }

    func objectSetup(
        named objectName: String,
        in scene: AnimationScene? = nil
    ) -> ObjectSetup? {
        let trimmedName = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let scene = scene ?? selectedScene
        return scene?.objectSetups.first(where: {
            $0.objectName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmedName) == .orderedSame
        })
    }

    func displayName(
        for track: TimelineTrack,
        in scene: AnimationScene? = nil
    ) -> String {
        let normalizedTrack = normalizeTimelineTrack(track, scene: scene)
        let role = resolvedTrackRole(for: normalizedTrack) ?? .custom

        guard let address = parsedTrackAddress(for: normalizedTrack.name) else {
            if let characterID = normalizedTrack.targetCharacterID,
               let character = characters.first(where: { $0.id == characterID }) {
                return "\(character.name):\(role.displayLabel)"
            }
            return normalizedTrack.name
        }

        switch address {
        case .camera(let cameraRole):
            switch cameraRole {
            case .camera: return "Camera"
            case .cameraShot: return "Camera:Shot"
            case .cameraDefaultShot: return "Camera:Default Shot"
            case .cameraFocus: return "Camera:Focus"
            case .cameraIntent: return "Camera:Intent"
            case .cameraBeat: return "Camera:Beat"
            case .cameraNotes: return "Camera:Notes"
            default: return "Camera"
            }
        case .character(let characterName, _):
            if let characterID = normalizedTrack.targetCharacterID,
               let character = characters.first(where: { $0.id == characterID }) {
                return "\(character.name):\(role.displayLabel)"
            }
            return "\(characterName):\(role.displayLabel)"
        case .object(let objectName, _):
            return "Object:\(objectName):\(role.displayLabel)"
        }
    }

    func evaluatedTransform(
        for characterName: String,
        at frame: Int? = nil
    ) -> CharacterTransform? {
        if let character = resolveCharacter(named: characterName) {
            return evaluatedTransform(for: character.id, at: frame)
        }

        guard let track = timelineTrack(named: "\(characterName):transform"),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .transform(let transform) = value
        else {
            return nil
        }

        return transform
    }

    func evaluatedTransform(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> CharacterTransform? {
        guard let track = cachedTimelineTrack(for: characterID, role: .transform),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .transform(let transform) = value
        else {
            return nil
        }

        return transform
    }

    func evaluatedVisibility(
        for characterName: String,
        at frame: Int? = nil
    ) -> (opacity: Double, visible: Bool)? {
        if let character = resolveCharacter(named: characterName) {
            return evaluatedVisibility(for: character.id, at: frame)
        }

        guard let track = timelineTrack(named: "\(characterName):visibility"),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .visibility(let opacity, let visible) = value
        else {
            return nil
        }

        return (opacity, visible)
    }

    func evaluatedVisibility(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> (opacity: Double, visible: Bool)? {
        guard let track = cachedTimelineTrack(for: characterID, role: .visibility),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .visibility(let opacity, let visible) = value
        else {
            return nil
        }

        return (opacity, visible)
    }

    func evaluatedObjectTransform(
        for objectName: String,
        at frame: Int? = nil
    ) -> CharacterTransform? {
        guard let track = cachedTimelineTrack(forObjectNamed: objectName, role: .transform),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .transform(let transform) = value
        else {
            return nil
        }

        return transform
    }

    func evaluatedObjectVisibility(
        for objectName: String,
        at frame: Int? = nil
    ) -> (opacity: Double, visible: Bool)? {
        guard let track = cachedTimelineTrack(forObjectNamed: objectName, role: .visibility),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .visibility(let opacity, let visible) = value
        else {
            return nil
        }

        return (opacity, visible)
    }

    func evaluatedCue(
        for characterName: String,
        trackSuffix: String,
        at frame: Int? = nil
    ) -> String? {
        if let character = resolveCharacter(named: characterName) {
            return evaluatedCue(
                for: character.id,
                role: TimelineTrackRole(trackSuffix: trackSuffix),
                at: frame
            )
        }

        guard let track = timelineTrack(named: "\(characterName):\(trackSuffix)"),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .expression(let name) = value
        else {
            return nil
        }

        return name
    }

    func evaluatedObjectCue(
        for objectName: String,
        role: TimelineTrackRole,
        at frame: Int? = nil
    ) -> String? {
        guard let track = cachedTimelineTrack(forObjectNamed: objectName, role: role),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .expression(let name) = value
        else {
            return nil
        }

        return name
    }

    func evaluatedCue(
        for characterID: UUID,
        role: TimelineTrackRole,
        at frame: Int? = nil
    ) -> String? {
        guard let track = cachedTimelineTrack(for: characterID, role: role),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .expression(let name) = value
        else {
            return nil
        }

        return name
    }

    func evaluatedExpression(
        for characterName: String,
        at frame: Int? = nil
    ) -> String? {
        evaluatedCue(for: characterName, trackSuffix: "expression", at: frame)
    }

    func evaluatedExpression(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> String? {
        evaluatedCue(for: characterID, role: .expression, at: frame)
    }

    func evaluatedAction(
        for characterName: String,
        at frame: Int? = nil
    ) -> String? {
        evaluatedCue(for: characterName, trackSuffix: "action", at: frame)
    }

    func evaluatedAction(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> String? {
        evaluatedCue(for: characterID, role: .action, at: frame)
    }

    func evaluatedMouthCue(
        for characterName: String,
        at frame: Int? = nil
    ) -> String? {
        evaluatedCue(for: characterName, trackSuffix: "mouth", at: frame)
    }

    func evaluatedMouthCue(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> String? {
        evaluatedCue(for: characterID, role: .mouth, at: frame)
    }

    func evaluatedShadowStyle(
        for characterName: String,
        at frame: Int? = nil
    ) -> ShadowStyle? {
        guard let cue = evaluatedCue(for: characterName, trackSuffix: "shadow-style", at: frame) else {
            return nil
        }

        return ShadowStyle(rawValue: cue)
    }

    func evaluatedShadowStyle(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> ShadowStyle? {
        guard let cue = evaluatedCue(for: characterID, role: .shadowStyle, at: frame) else {
            return nil
        }

        return ShadowStyle(rawValue: cue)
    }

    func evaluatedShadowOpacity(
        for characterName: String,
        at frame: Int? = nil
    ) -> Double? {
        guard let cue = evaluatedCue(for: characterName, trackSuffix: "shadow-opacity", at: frame) else {
            return nil
        }

        return Double(cue)
    }

    func evaluatedShadowOpacity(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> Double? {
        guard let cue = evaluatedCue(for: characterID, role: .shadowOpacity, at: frame) else {
            return nil
        }

        return Double(cue)
    }

    func evaluatedPose(
        for characterName: String,
        at frame: Int? = nil
    ) -> CharacterPackagePose? {
        guard let cue = evaluatedCue(for: characterName, trackSuffix: "pose", at: frame) else {
            return nil
        }

        return CharacterPackagePose(rawValue: cue)
    }

    func evaluatedPose(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> CharacterPackagePose? {
        guard let cue = evaluatedCue(for: characterID, role: .pose, at: frame) else {
            return nil
        }

        return CharacterPackagePose(rawValue: cue)
    }

    func evaluatedViewAngle(
        for characterName: String,
        at frame: Int? = nil
    ) -> AngleView? {
        guard let cue = evaluatedCue(for: characterName, trackSuffix: "view", at: frame) else {
            return nil
        }

        return AngleView(rawValue: cue)
    }

    func evaluatedViewAngle(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> AngleView? {
        guard let cue = evaluatedCue(for: characterID, role: .view, at: frame) else {
            return nil
        }

        return AngleView(rawValue: cue)
    }

    func evaluatedFacingDirection(
        for characterName: String,
        at frame: Int? = nil
    ) -> FacingDirection? {
        guard let cue = evaluatedCue(for: characterName, trackSuffix: "facing", at: frame) else {
            return nil
        }

        return FacingDirection(rawValue: cue)
    }

    func evaluatedFacingDirection(
        for characterID: UUID,
        at frame: Int? = nil
    ) -> FacingDirection? {
        guard let cue = evaluatedCue(for: characterID, role: .facing, at: frame) else {
            return nil
        }

        return FacingDirection(rawValue: cue)
    }

    func evaluatedCameraShot(
        at frame: Int? = nil
    ) -> CameraShot? {
        guard let track = timelineTrack(named: Self.cameraShotTrackName),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .expression(let name) = value
        else {
            return nil
        }

        return CameraShot(rawValue: name)
    }

    func evaluatedCameraDefaultShot(
        at frame: Int? = nil
    ) -> CameraShot? {
        guard let name = evaluatedSceneFramingCue(trackName: Self.cameraDefaultShotTrackName, at: frame) else {
            return selectedScene?.directionTemplate?.defaultCameraShot
        }

        return CameraShot(rawValue: name) ?? selectedScene?.directionTemplate?.defaultCameraShot
    }

    func evaluatedCameraFocusCharacterID(
        at frame: Int? = nil
    ) -> UUID? {
        if let slug = evaluatedSceneFramingCue(trackName: Self.cameraFocusTrackName, at: frame),
           let characterID = characters.first(where: { $0.owpSlug == slug })?.id {
            return characterID
        }

        return selectedScene?.directionTemplate?.focusCharacterID
    }

    func evaluatedCameraBeatLabel(
        at frame: Int? = nil
    ) -> String? {
        evaluatedSceneFramingCue(trackName: Self.cameraBeatTrackName, at: frame)
    }

    func evaluatedCameraShotIntent(
        at frame: Int? = nil
    ) -> ShotIntent? {
        guard let name = evaluatedSceneFramingCue(trackName: Self.cameraIntentTrackName, at: frame) else {
            return nil
        }

        return ShotIntent(rawValue: name)
    }

    func recommendedCameraShotFromIntent(
        at frame: Int? = nil
    ) -> CameraShot? {
        evaluatedCameraShotIntent(at: frame)?.recommendedCameraShot
    }

    func recommendedCameraMovementFromIntent(
        at frame: Int? = nil
    ) -> CameraMovement? {
        evaluatedCameraShotIntent(at: frame)?.recommendedCameraMovement
    }

    func evaluatedEffectiveCameraShot(
        at frame: Int? = nil
    ) -> CameraShot? {
        evaluatedCameraShot(at: frame)
            ?? evaluatedCameraDefaultShot(at: frame)
            ?? recommendedCameraShotFromIntent(at: frame)
    }

    func evaluatedCameraBeatNotes(
        at frame: Int? = nil
    ) -> String? {
        if let notes = evaluatedSceneFramingCue(trackName: Self.cameraNotesTrackName, at: frame),
           !notes.isEmpty {
            return notes
        }

        let fallbackNotes = selectedScene?.directionTemplate?.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fallbackNotes?.isEmpty == false) ? fallbackNotes : nil
    }

    func orderedTimelineTracks(
        for scene: AnimationScene? = nil
    ) -> [TimelineTrack] {
        guard let scene = scene ?? selectedScene else { return [] }

        var tracks = sceneTracks
        if let cameraTrack {
            tracks[Self.cameraTrackName] = cameraTrack
        }

        let characterOrder = Dictionary(
            uniqueKeysWithValues: scene.characterIDs.enumerated().map { offset, id in
                (id, offset)
            }
        )

        return tracks.values
            .map { normalizeTimelineTrack($0, scene: scene) }
            .sorted { lhs, rhs in
            timelineSortKey(
                for: lhs,
                scene: scene,
                characterOrder: characterOrder
            ) < timelineSortKey(
                for: rhs,
                scene: scene,
                characterOrder: characterOrder
            )
        }
    }

    func resolvedAutomationProfile(
        for scene: AnimationScene? = nil
    ) -> SceneAutomationProfile? {
        guard let scene = scene ?? selectedScene else { return nil }
        return normalizedSceneAutomationProfile(scene.automationProfile, scene: scene)
    }

    func selectedSceneAutomationPlan() -> SceneAutomationPlan? {
        guard let scene = selectedScene else { return nil }
        let profile = normalizedSceneAutomationProfile(scene.automationProfile, scene: scene)
        return sceneAutomationPlanner.makePlan(
            scene: scene,
            profile: profile,
            characters: characters,
            animateURL: animateURL,
            activePackageIDsByCharacterSlug: activePackageIDsByCharacterSlug,
            liveTracks: liveTimelineTrackMap(scene: scene)
        )
    }

    func updateSelectedSceneAutomationProfile(
        _ update: (inout SceneAutomationProfile) -> Void
    ) {
        guard let sceneID = selectedSceneID,
              let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID })
        else {
            return
        }

        var profile = normalizedSceneAutomationProfile(
            scenes[sceneIndex].automationProfile,
            scene: scenes[sceneIndex]
        )
        update(&profile)
        profile.sync(with: scenes[sceneIndex], characters: characters)
        scenes[sceneIndex].automationProfile = profile
        save()
    }

    func setSelectedSceneExecutionMode(_ mode: SceneExecutionMode) {
        updateSelectedSceneAutomationProfile { $0.executionMode = mode }
    }

    func setSelectedSceneActingIntensity(_ intensity: AutomationIntensity) {
        updateSelectedSceneAutomationProfile { $0.actingIntensity = intensity }
    }

    func setSelectedSceneCameraAutomationStyle(_ style: CameraAutomationStyle) {
        updateSelectedSceneAutomationProfile { $0.cameraStyle = style }
    }

    func setSelectedSceneLipSyncAssistMode(_ mode: LipSyncAssistMode) {
        updateSelectedSceneAutomationProfile { $0.lipSyncAssistMode = mode }
    }

    func setSelectedSceneAutomationPass(
        _ pass: SceneAutomationPass,
        isEnabled: Bool
    ) {
        updateSelectedSceneAutomationProfile { profile in
            if isEnabled {
                profile.enabledPasses.insert(pass)
            } else {
                profile.enabledPasses.remove(pass)
            }
        }
    }

    func setSelectedSceneAllowGenerativeVideoAssist(_ allow: Bool) {
        updateSelectedSceneAutomationProfile { $0.allowGenerativeVideoAssist = allow }
    }

    func setSelectedSceneAutomationNotes(_ notes: String) {
        updateSelectedSceneAutomationProfile { $0.notes = notes }
    }

    func setSelectedSceneCharacterAutomationStrategy(
        _ strategy: CharacterAutomationStrategy,
        for characterID: UUID
    ) {
        updateSelectedSceneAutomationProfile { profile in
            guard let profileIndex = profile.characterProfiles.firstIndex(where: {
                $0.characterID == characterID
            }) else { return }
            profile.characterProfiles[profileIndex].strategy = strategy
        }
    }

    func setSelectedSceneCharacterPreferredCostumeSet(
        _ costumeSetID: UUID?,
        for characterID: UUID
    ) {
        updateSelectedSceneAutomationProfile { profile in
            guard let profileIndex = profile.characterProfiles.firstIndex(where: {
                $0.characterID == characterID
            }) else { return }

            profile.characterProfiles[profileIndex].preferredCostumeSetID = costumeSetID

            if let costumeSetID,
               let character = characters.first(where: { $0.id == characterID }),
               let costume = character.costumeReferenceSets.first(where: { $0.id == costumeSetID }) {
                profile.characterProfiles[profileIndex].preferredCostumeName = costume.name
            } else {
                profile.characterProfiles[profileIndex].preferredCostumeName = nil
            }
        }
    }

    func updateSelectedSceneShots(
        _ update: (inout [AnimationSceneShot]) -> Void
    ) {
        guard let sceneID = selectedSceneID,
              let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID })
        else {
            return
        }

        var shots = scenes[sceneIndex].shots
        update(&shots)
        scenes[sceneIndex].shots = normalizedSceneShots(shots)
        statusMessage = scenes[sceneIndex].shots.isEmpty
            ? "Cleared scene shots"
            : "Updated scene shots"
    }

    func replaceSelectedSceneShots(_ shots: [AnimationSceneShot]) {
        updateSelectedSceneShots { current in
            current = shots
        }
    }

    /// Seed shots ONLY for scenes that have NO shots at all.
    /// Scenes that already have shots (whether authored, manual, or previously seeded)
    /// are never overwritten — their data loaded from Animate/scenes.json is preserved.
    func seedShotsForAllScenes() async {
        guard let owpURL = fileOWPURL else { return }
        let shotService = AnimateSceneShotSeedingService(store: self)
        var seededCount = 0

        for index in scenes.indices {
            // ONLY seed scenes with completely empty shots — never overwrite existing data
            guard scenes[index].shots.isEmpty else { continue }

            let scene = scenes[index]
            guard let songData = await ProjectDatabaseBridge.hydrateSongData(
                projectURL: owpURL,
                relativePath: scene.owpSongPath
            ) else { continue }

            let lyrics = songData.extractLyrics().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyrics.isEmpty else { continue }

            let parseResult = SceneDirectionParser.parse(lyrics)
            let seeded = shotService.seededShots(
                for: scene,
                songData: songData,
                parseResult: parseResult
            )
            guard !seeded.isEmpty else { continue }

            scenes[index].shots = normalizedSceneShots(seeded)
            seededCount += 1
        }

        if seededCount > 0 {
            NSLog("[Animate] seedShots: seeded %d empty scenes from lyrics", seededCount)
        }
    }

    /// Reload scene data from Animate/scenes.json on disk, preserving authored shot data.
    func reloadScenesFromDisk() {
        guard let projectURL = fileOWPURL else { return }
        let savedScenes = ProjectDatabaseBridge.loadSavedScenesFromDisk(projectURL: projectURL)
        var reloadedCount = 0

        for index in scenes.indices {
            guard let savedScene = savedScenes[scenes[index].owpSongPath] else { continue }
            applySceneData(savedScene, to: &scenes[index])
            reloadedCount += 1
        }

        syncSelectedSceneTimeline()
        if reloadedCount > 0 {
            save()
            statusMessage = "Reloaded \(reloadedCount) scenes from disk"
            NSLog("[Animate] reloadScenesFromDisk: refreshed %d scenes", reloadedCount)
        }
    }

    func setExpressionCue(
        _ expression: String?,
        for characterName: String,
        at frame: Int? = nil
    ) {
        setSemanticCue(expression, trackSuffix: "expression", for: characterName, at: frame)
    }

    func setExpressionCue(
        _ expression: String?,
        for characterID: UUID,
        at frame: Int? = nil
    ) {
        guard let character = characters.first(where: { $0.id == characterID }) else { return }
        setSemanticCue(expression, trackSuffix: "expression", for: character.name, characterID: characterID, at: frame)
    }

    func setActionCue(
        _ action: String?,
        for characterName: String,
        at frame: Int? = nil
    ) {
        setSemanticCue(action, trackSuffix: "action", for: characterName, at: frame)
    }

    func setActionCue(
        _ action: String?,
        for characterID: UUID,
        at frame: Int? = nil
    ) {
        guard let character = characters.first(where: { $0.id == characterID }) else { return }
        setSemanticCue(action, trackSuffix: "action", for: character.name, characterID: characterID, at: frame)
    }

    func setShadowStyleCue(
        _ style: ShadowStyle?,
        for characterName: String,
        at frame: Int? = nil
    ) {
        setSemanticCue(style?.rawValue, trackSuffix: "shadow-style", for: characterName, at: frame)
    }

    func setShadowStyleCue(
        _ style: ShadowStyle?,
        for characterID: UUID,
        at frame: Int? = nil
    ) {
        guard let character = characters.first(where: { $0.id == characterID }) else { return }
        setSemanticCue(style?.rawValue, trackSuffix: "shadow-style", for: character.name, characterID: characterID, at: frame)
    }

    func setShadowOpacityCue(
        _ opacity: Double?,
        for characterName: String,
        at frame: Int? = nil
    ) {
        let value = opacity.map { String($0) }
        setSemanticCue(value, trackSuffix: "shadow-opacity", for: characterName, at: frame)
    }

    func setShadowOpacityCue(
        _ opacity: Double?,
        for characterID: UUID,
        at frame: Int? = nil
    ) {
        guard let character = characters.first(where: { $0.id == characterID }) else { return }
        let value = opacity.map { String($0) }
        setSemanticCue(value, trackSuffix: "shadow-opacity", for: character.name, characterID: characterID, at: frame)
    }

    func setPoseCue(
        _ pose: CharacterPackagePose?,
        for characterName: String,
        at frame: Int? = nil
    ) {
        setSemanticCue(pose?.rawValue, trackSuffix: "pose", for: characterName, at: frame)
    }

    func setPoseCue(
        _ pose: CharacterPackagePose?,
        for characterID: UUID,
        at frame: Int? = nil
    ) {
        guard let character = characters.first(where: { $0.id == characterID }) else { return }
        setSemanticCue(pose?.rawValue, trackSuffix: "pose", for: character.name, characterID: characterID, at: frame)
    }

    func setViewAngleCue(
        _ angle: AngleView?,
        for characterName: String,
        at frame: Int? = nil
    ) {
        setSemanticCue(angle?.rawValue, trackSuffix: "view", for: characterName, at: frame)
    }

    func setViewAngleCue(
        _ angle: AngleView?,
        for characterID: UUID,
        at frame: Int? = nil
    ) {
        guard let character = characters.first(where: { $0.id == characterID }) else { return }
        setSemanticCue(angle?.rawValue, trackSuffix: "view", for: character.name, characterID: characterID, at: frame)
    }

    func setFacingCue(
        _ facing: FacingDirection?,
        for characterName: String,
        at frame: Int? = nil
    ) {
        setSemanticCue(facing?.rawValue, trackSuffix: "facing", for: characterName, at: frame)
    }

    func setFacingCue(
        _ facing: FacingDirection?,
        for characterID: UUID,
        at frame: Int? = nil
    ) {
        guard let character = characters.first(where: { $0.id == characterID }) else { return }
        setSemanticCue(facing?.rawValue, trackSuffix: "facing", for: character.name, characterID: characterID, at: frame)
    }

    func setCameraShotCue(
        _ shot: CameraShot?,
        at frame: Int? = nil
    ) {
        guard !scenes.isEmpty else {
            statusMessage = "Open a project before editing camera cues."
            return
        }

        let resolvedFrame = frame ?? currentFrame
        let trackName = Self.cameraShotTrackName
        var track = timelineTrack(named: trackName)
            ?? TimelineTrack(name: trackName, keyframes: [], role: .cameraShot)
        track.name = trackName
        track.targetCharacterID = nil
        track.role = .cameraShot
        track.keyframes.removeAll { keyframe in
            keyframe.frame == resolvedFrame && keyframe.kind == .expression
        }

        if let shot {
            track.keyframes.append(
                TimelineKeyframe(
                    frame: resolvedFrame,
                    kind: .expression,
                    easing: .stepped,
                    value: .expression(name: shot.rawValue)
                )
            )
            track.keyframes.sort { $0.frame < $1.frame }
            sceneTracks[trackName] = track
            totalFrames = max(totalFrames, resolvedFrame + 1)
            statusMessage = "Set camera shot cue at frame \(resolvedFrame)"
        } else {
            if track.keyframes.isEmpty {
                sceneTracks.removeValue(forKey: trackName)
            } else {
                sceneTracks[trackName] = track
            }
            statusMessage = "Cleared camera shot cue at frame \(resolvedFrame)"
        }

        persistSelectedSceneTracks()
    }

    func setCameraDefaultShotCue(
        _ shot: CameraShot?,
        at frame: Int? = nil
    ) {
        setSceneFramingCue(
            shot?.rawValue,
            trackName: Self.cameraDefaultShotTrackName,
            role: .cameraDefaultShot,
            at: frame,
            setStatus: { frame in
                shot == nil
                    ? "Cleared camera default shot cue at frame \(frame)"
                    : "Set camera default shot cue at frame \(frame)"
            }
        )
    }

    func setCameraFocusCue(
        _ characterID: UUID?,
        at frame: Int? = nil
    ) {
        let slug = characterID.flatMap { id in
            characters.first(where: { $0.id == id })?.owpSlug
        }
        setSceneFramingCue(
            slug,
            trackName: Self.cameraFocusTrackName,
            role: .cameraFocus,
            at: frame,
            setStatus: { frame in
                slug == nil
                    ? "Cleared camera focus cue at frame \(frame)"
                    : "Set camera focus cue at frame \(frame)"
            }
        )
    }

    func setCameraBeatLabelCue(
        _ label: String?,
        at frame: Int? = nil
    ) {
        setSceneFramingCue(
            label,
            trackName: Self.cameraBeatTrackName,
            role: .cameraBeat,
            at: frame,
            setStatus: { frame in
                let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (normalized?.isEmpty == false)
                    ? "Set camera beat cue at frame \(frame)"
                    : "Cleared camera beat cue at frame \(frame)"
            }
        )
    }

    func setCameraShotIntentCue(
        _ intent: ShotIntent?,
        at frame: Int? = nil
    ) {
        setSceneFramingCue(
            intent?.rawValue,
            trackName: Self.cameraIntentTrackName,
            role: .cameraIntent,
            at: frame,
            setStatus: { frame in
                intent == nil
                    ? "Cleared camera intent cue at frame \(frame)"
                    : "Set camera intent cue at frame \(frame)"
            }
        )
    }

    func setCameraBeatNotesCue(
        _ notes: String?,
        at frame: Int? = nil
    ) {
        setSceneFramingCue(
            notes,
            trackName: Self.cameraNotesTrackName,
            role: .cameraNotes,
            at: frame,
            setStatus: { frame in
                let normalized = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (normalized?.isEmpty == false)
                    ? "Set camera notes cue at frame \(frame)"
                    : "Cleared camera notes cue at frame \(frame)"
            }
        )
    }

    func updateSelectedSceneDirectionTemplate(
        defaultCameraShot: CameraShot?,
        focusCharacterID: UUID?,
        notes: String
    ) {
        guard let sceneID = selectedSceneID,
              let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID })
        else {
            return
        }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = SceneDirectionTemplate(
            defaultCameraShot: defaultCameraShot,
            focusCharacterID: focusCharacterID,
            focusCharacterSlug: focusCharacterID.flatMap { id in
                characters.first(where: { $0.id == id })?.owpSlug
            },
            notes: trimmedNotes
        )
        scenes[sceneIndex].directionTemplate = template.isEmpty ? nil : template
        statusMessage = template.isEmpty
            ? "Cleared scene direction template"
            : "Updated scene direction template"
    }

    private func evaluatedSceneFramingCue(
        trackName: String,
        at frame: Int? = nil
    ) -> String? {
        guard let track = timelineTrack(named: trackName),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .expression(let name) = value
        else {
            return nil
        }

        return name
    }

    private func setSceneFramingCue(
        _ rawValue: String?,
        trackName: String,
        role: TimelineTrackRole,
        at frame: Int? = nil,
        setStatus: (Int) -> String
    ) {
        guard !scenes.isEmpty else {
            statusMessage = "Open a project before editing camera cues."
            return
        }

        let resolvedFrame = frame ?? currentFrame
        let normalizedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var track = timelineTrack(named: trackName)
            ?? TimelineTrack(name: trackName, keyframes: [], role: role)
        track.name = trackName
        track.targetCharacterID = nil
        track.role = role
        track.keyframes.removeAll { keyframe in
            keyframe.frame == resolvedFrame && keyframe.kind == .expression
        }

        if let normalizedValue, !normalizedValue.isEmpty {
            track.keyframes.append(
                TimelineKeyframe(
                    frame: resolvedFrame,
                    kind: .expression,
                    easing: .stepped,
                    value: .expression(name: normalizedValue)
                )
            )
            track.keyframes.sort { $0.frame < $1.frame }
            sceneTracks[trackName] = track
            totalFrames = max(totalFrames, resolvedFrame + 1)
        } else if track.keyframes.isEmpty {
            sceneTracks.removeValue(forKey: trackName)
        } else {
            sceneTracks[trackName] = track
        }

        statusMessage = setStatus(resolvedFrame)
        persistSelectedSceneTracks()
    }

    func shotPreset(id: UUID) -> SceneShotPreset? {
        shotPresets.first(where: { $0.id == id })
    }

    func shotPreset(named name: String) -> SceneShotPreset? {
        let matches = matchingShotPresets(named: name)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func suggestedShotPresets(
        for intent: ShotIntent?,
        focusCharacterID: UUID? = nil,
        limit: Int = 3
    ) -> [SceneShotPreset] {
        guard let intent else { return [] }
        let focusSlug = focusCharacterID.flatMap { id in
            characters.first(where: { $0.id == id })?.owpSlug
        }

        return shotPresets
            .compactMap { preset -> (SceneShotPreset, Int)? in
                guard preset.shotIntent == intent else { return nil }
                var score = 0
                if let focusSlug, preset.focusCharacterSlug == focusSlug {
                    score += 2
                }
                if preset.cameraShot == intent.recommendedCameraShot {
                    score += 1
                }
                if preset.defaultCameraShot == intent.recommendedCameraShot {
                    score += 1
                }
                return (preset, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                if lhs.0.updatedAt != rhs.0.updatedAt {
                    return lhs.0.updatedAt > rhs.0.updatedAt
                }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .prefix(max(limit, 0))
            .map(\.0)
    }

    func captureShotPreset(
        named name: String,
        notes: String,
        overwritePresetID: UUID? = nil,
        frame: Int? = nil
    ) {
        guard let scene = selectedScene else {
            statusMessage = "Select a scene before saving a shot preset."
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Shot preset name cannot be empty."
            return
        }

        let resolvedFrame = frame ?? currentFrame
        let template = scene.directionTemplate
        let now = Date()
        let existing = overwritePresetID.flatMap(shotPreset(id:))

        let cues: [SceneShotPresetCharacterCue] = scene.characterIDs.compactMap { characterID in
            guard let character = characters.first(where: { $0.id == characterID }) else {
                return nil
            }

            return SceneShotPresetCharacterCue(
                characterSlug: character.owpSlug,
                facing: evaluatedFacingDirection(for: characterID, at: resolvedFrame),
                viewAngle: evaluatedViewAngle(for: characterID, at: resolvedFrame),
                pose: evaluatedPose(for: characterID, at: resolvedFrame),
                expression: evaluatedExpression(for: characterID, at: resolvedFrame),
                action: evaluatedAction(for: characterID, at: resolvedFrame)
            )
        }

        let preset = SceneShotPreset(
            id: existing?.id ?? overwritePresetID ?? UUID(),
            name: trimmedName,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            shotIntent: evaluatedCameraShotIntent(at: resolvedFrame),
            cameraShot: evaluatedCameraShot(at: resolvedFrame),
            defaultCameraShot: evaluatedCameraDefaultShot(at: resolvedFrame) ?? template?.defaultCameraShot,
            focusCharacterSlug: evaluatedCameraFocusCharacterID(at: resolvedFrame).flatMap { id in
                characters.first(where: { $0.id == id })?.owpSlug
            } ?? template?.focusCharacterSlug ?? template?.focusCharacterID.flatMap { id in
                characters.first(where: { $0.id == id })?.owpSlug
            },
            characterCues: cues,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        upsertShotPreset(preset)
        persistShotPresets()
        statusMessage = existing == nil
            ? "Saved shot preset: \(trimmedName)"
            : "Updated shot preset: \(trimmedName)"
    }

    func applyShotPreset(
        _ preset: SceneShotPreset,
        frame: Int? = nil
    ) {
        guard selectedScene != nil else {
            statusMessage = "Select a scene before applying a shot preset."
            return
        }

        let resolvedFrame = frame ?? currentFrame
        setCameraShotCue(preset.cameraShot, at: resolvedFrame)

        for cue in preset.characterCues {
            guard let character = characters.first(where: { $0.owpSlug == cue.characterSlug }) else {
                continue
            }

            setFacingCue(cue.facing, for: character.id, at: resolvedFrame)
            setViewAngleCue(cue.viewAngle, for: character.id, at: resolvedFrame)
            setPoseCue(cue.pose, for: character.id, at: resolvedFrame)
            setExpressionCue(cue.expression, for: character.id, at: resolvedFrame)
            setActionCue(cue.action, for: character.id, at: resolvedFrame)
        }

        setCameraDefaultShotCue(preset.defaultCameraShot, at: resolvedFrame)
        setCameraFocusCue(
            preset.focusCharacterSlug.flatMap { slug in
                characters.first(where: { $0.owpSlug == slug })?.id
            },
            at: resolvedFrame
        )
        setCameraShotIntentCue(preset.shotIntent, at: resolvedFrame)
        setCameraBeatLabelCue(preset.name, at: resolvedFrame)
        setCameraBeatNotesCue(preset.notes, at: resolvedFrame)
        statusMessage = "Applied shot preset: \(preset.name)"
    }

    func deleteShotPreset(id: UUID) {
        guard let existing = shotPresets.first(where: { $0.id == id }) else { return }
        shotPresets.removeAll { $0.id == id }
        persistShotPresets()
        statusMessage = "Deleted shot preset: \(existing.name)"
    }

    func evaluatedCameraTransform(at frame: Int? = nil) -> CharacterTransform? {
        guard let track = timelineTrack(named: Self.cameraTrackName),
              let value = AnimationEngine.evaluate(track: track, at: frame ?? currentFrame),
              case .transform(let transform) = value
        else {
            return nil
        }

        return transform
    }

    @discardableResult
    func applyLLMAnimationPlan(_ plan: LLMAnimationPlan) -> LLMAnimationValidationReport {
        let compiler = LLMAnimationPlanCompiler()
        let resolvedPlanAndIssues: (plan: LLMAnimationPlan, issues: [LLMAnimationValidationIssue])
        if let scene = selectedScene {
            resolvedPlanAndIssues = AnimatePlanShotAnchorResolver(store: self).resolve(plan, for: scene)
        } else {
            resolvedPlanAndIssues = (plan, [])
        }
        let resolvedPlan = resolvedPlanAndIssues.plan
        var issues = resolvedPlanAndIssues.issues + compiler.validate(resolvedPlan).issues

        if scenes.isEmpty {
            issues.append(.init(
                severity: .error,
                code: .noSceneAvailable,
                message: "Open a project before applying an animation plan."
            ))
        }

        let placementNames = resolvedPlan.characterPlacements.map(\.characterName)
        let motionNames = resolvedPlan.motions.map(\.characterName)
        let expressionNames = resolvedPlan.expressions.map(\.characterName)
        let dialogueNames = resolvedPlan.dialogueBeats.map(\.characterName)
        let shadowNames = resolvedPlan.shadowCues.map(\.characterName)
        let presetFocusNames = resolvedPlan.shotPresetApplications.compactMap(\.focusCharacterName)
        let presetOverrideNames = resolvedPlan.shotPresetApplications.flatMap { application in
            application.characterOverrides.map(\.characterName)
        }
        let referencedNames = placementNames + motionNames + expressionNames + dialogueNames + shadowNames + presetFocusNames + presetOverrideNames
        let referencedCharacterNames = Set(
            referencedNames.map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased() }
        )

        let knownCharacterNames = Set(
            characters.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        for missingName in referencedCharacterNames.subtracting(knownCharacterNames).sorted() {
            issues.append(.init(
                severity: .error,
                code: .unknownCharacter,
                message: "Animation plan references unknown character '\(missingName)'."
            ))
        }

        let resolvedPresetApplications = resolvedPlan.shotPresetApplications.map { application in
            (application, matchingShotPresets(named: application.presetName))
        }

        for (application, matches) in resolvedPresetApplications {
            let trimmedName = application.presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            if matches.isEmpty {
                issues.append(.init(
                    severity: .error,
                    code: .unknownShotPreset,
                    message: "Animation plan references unknown shot preset '\(trimmedName)'."
                ))
            } else if matches.count > 1 {
                issues.append(.init(
                    severity: .error,
                    code: .ambiguousShotPreset,
                    message: "Animation plan references shot preset '\(trimmedName)', but multiple presets share that name."
                ))
            }
        }

        let report = LLMAnimationValidationReport(issues: issues)
        guard report.isValid else {
            statusMessage = issues
                .filter { $0.severity == .error }
                .prefix(2)
                .map(\.message)
                .joined(separator: " ")
            return report
        }

        var compiled = compiler.compile(resolvedPlan, fps: fps)
        let presetApplications = resolvedPresetApplications
            .compactMap { application, matches in
                matches.first.map { (application, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.0.frame == rhs.0.frame {
                    return normalizedShotPresetName(lhs.1.name) < normalizedShotPresetName(rhs.1.name)
                }
                return lhs.0.frame < rhs.0.frame
            }

        applyShotPresetApplications(presetApplications, to: &compiled)
        applyCompiledScene(compiled)
        if let sceneAudioPath = normalizedMediaPath(resolvedPlan.sceneAudioPath) {
            setSelectedSceneDefaultAudioPath(sceneAudioPath)
        }
        statusMessage = "Applied LLM animation plan: \(resolvedPlan.sceneName)"
        return report
    }

    @discardableResult
    func applyLLMAnimationPlanJSON(_ json: String) -> LLMAnimationValidationReport {
        let compiler = LLMAnimationPlanCompiler()

        do {
            let plan = try compiler.parse(json: json)
            return applyLLMAnimationPlan(plan)
        } catch {
            let report = LLMAnimationValidationReport(issues: [
                .init(
                    severity: .error,
                    code: .invalidJSON,
                    message: "LLM animation plan JSON could not be decoded: \(error.localizedDescription)"
                )
            ])
            statusMessage = report.issues[0].message
            return report
        }
    }

    @discardableResult
    func applyLLMAnimationPlanIncludingGeneratedDialogue(
        _ plan: LLMAnimationPlan,
        visemeAnalyzer: @escaping @Sendable (URL, Int, String?) async throws -> [LipSyncEngine.VisemeKeyframe] = { url, fps, transcript in
            try await RhubarbLipSync().analyzeToVisemes(
                audioURL: url,
                fps: fps,
                dialogueText: transcript
            )
        }
    ) async -> LLMAnimationValidationReport {
        let baseReport = applyLLMAnimationPlan(plan)
        guard baseReport.isValid else { return baseReport }

        var issues = baseReport.issues
        let resolvedPlan: LLMAnimationPlan
        if let scene = selectedScene {
            resolvedPlan = AnimatePlanShotAnchorResolver(store: self).resolve(plan, for: scene).plan
        } else {
            resolvedPlan = plan
        }

        for beat in resolvedPlan.dialogueBeats.sorted(by: { $0.startFrame < $1.startFrame }) {
            guard let audioPath = normalizedMediaPath(beat.audioPath),
                  let audioURL = resolvedMediaURL(for: audioPath),
                  FileManager.default.fileExists(atPath: audioURL.path)
            else {
                issues.append(.init(
                    severity: .error,
                    code: .missingAudioFile,
                    message: "Dialogue beat for \(beat.characterName) references missing audio '\(beat.audioPath)'."
                ))
                continue
            }

            do {
                let visemes = try await visemeAnalyzer(audioURL, fps, beat.transcript)
                applyLipSyncVisemes(
                    visemes,
                    for: beat.characterName,
                    frameOffset: beat.startFrame
                )
            } catch {
                issues.append(.init(
                    severity: .error,
                    code: .missingAudioFile,
                    message: "Lip sync generation failed for \(beat.characterName): \(error.localizedDescription)"
                ))
            }
        }

        let report = LLMAnimationValidationReport(issues: issues)
        if report.isValid {
            statusMessage = "Applied LLM animation plan with generated dialogue: \(resolvedPlan.sceneName)"
        } else {
            statusMessage = issues
                .filter { $0.severity == .error }
                .prefix(2)
                .map(\.message)
                .joined(separator: " ")
        }

        return report
    }

    @discardableResult
    func applyLLMAnimationPlanJSONIncludingGeneratedDialogue(
        _ json: String,
        visemeAnalyzer: @escaping @Sendable (URL, Int, String?) async throws -> [LipSyncEngine.VisemeKeyframe] = { url, fps, transcript in
            try await RhubarbLipSync().analyzeToVisemes(
                audioURL: url,
                fps: fps,
                dialogueText: transcript
            )
        }
    ) async -> LLMAnimationValidationReport {
        let compiler = LLMAnimationPlanCompiler()

        do {
            let plan = try compiler.parse(json: json)
            return await applyLLMAnimationPlanIncludingGeneratedDialogue(
                plan,
                visemeAnalyzer: visemeAnalyzer
            )
        } catch {
            let report = LLMAnimationValidationReport(issues: [
                .init(
                    severity: .error,
                    code: .invalidJSON,
                    message: "LLM animation plan JSON could not be decoded: \(error.localizedDescription)"
                )
            ])
            statusMessage = report.issues[0].message
            return report
        }
    }

    private func syncSelectedSceneTimeline() {
        guard let scene = selectedScene else {
            sceneTracks = [:]
            cameraTrack = nil
            nlaTimeline = nil
            nlaBlendedPose = nil
            return
        }

        var tracks = scene.tracks.mapValues { normalizeTimelineTrack($0, scene: scene) }
        cameraTrack = tracks.removeValue(forKey: Self.cameraTrackName)
            .map { normalizeTimelineTrack($0, scene: scene) }
        sceneTracks = tracks

        // Load NLA timeline for the newly selected scene
        if let sceneID = selectedSceneID, let animateDir = animateURL {
            do {
                nlaTimeline = try NLATimelinePersistence.load(
                    animateDir: animateDir, sceneID: sceneID
                )
            } catch {
                print("[AnimateStore] Failed to load NLA timeline for scene \(sceneID): \(error)")
                nlaTimeline = nil
            }
        } else {
            nlaTimeline = nil
        }
        nlaBlendedPose = nil
    }

    private func matchingShotPresets(named name: String) -> [SceneShotPreset] {
        let normalizedName = normalizedShotPresetName(name)
        guard !normalizedName.isEmpty else { return [] }
        return shotPresets.filter { normalizedShotPresetName($0.name) == normalizedName }
    }

    private func normalizedShotPresetName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func resolvedCharacter(named name: String) -> AnimationCharacter? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty else { return nil }
        return characters.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }
    }

    private func normalizedMediaPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    func resolvedCharacterAssetURL(for path: String?) -> URL? {
        guard let trimmed = normalizedMediaPath(path) else {
            return nil
        }

        let fileManager = FileManager.default
        if !trimmed.hasPrefix("/"),
           let projectURL = fileOWPURL {
            let projectRelativeURL = projectURL.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: projectRelativeURL.path) {
                return projectRelativeURL
            }
        }

        if !trimmed.hasPrefix("/"),
           let animateURL,
           trimmed.hasPrefix("Animate/") {
            let animateRelativeURL = animateURL
                .deletingLastPathComponent()
                .appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: animateRelativeURL.path) {
                return animateRelativeURL
            }
        }

        if !trimmed.hasPrefix("/"),
           let animateURL,
           (trimmed.hasPrefix("characters/") || trimmed.hasPrefix("backgrounds/")) {
            let animateRelativeURL = animateURL.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: animateRelativeURL.path) {
                return animateRelativeURL
            }
        }

        if let projectURL = fileOWPURL,
           let projectRelativePath = projectRelativeCharacterAssetPath(from: trimmed) {
            let remappedURL = projectURL.appendingPathComponent(projectRelativePath)
            if fileManager.fileExists(atPath: remappedURL.path) {
                return remappedURL
            }
        }

        let candidateURL = URL(fileURLWithPath: trimmed)
        if trimmed.hasPrefix("/"), fileManager.fileExists(atPath: candidateURL.path) {
            return candidateURL
        }

        return nil
    }

    func thumbnailImage(
        for path: String?,
        maxSize: CGFloat = 120
    ) -> NSImage? {
        guard let url = resolvedCharacterAssetURL(for: path) else {
            return nil
        }

        return assetManager.thumbnail(for: url, maxSize: maxSize)
    }

    func thumbnailImageAsync(
        for path: String?,
        maxSize: CGFloat = 120
    ) async -> NSImage? {
        guard let url = resolvedCharacterAssetURL(for: path) else {
            return nil
        }

        return await assetManager.thumbnailAsync(for: url, maxSize: maxSize)
    }

    /// Invalidate cached thumbnails for a file that was overwritten (e.g., after cropping).
    func invalidateThumbnail(for path: String?) {
        guard let url = resolvedCharacterAssetURL(for: path) else { return }
        assetManager.invalidateThumbnail(for: url)
    }

    private func normalizedCharacterAssetPath(_ path: String?) -> String? {
        guard let trimmed = normalizedMediaPath(path) else {
            return nil
        }

        if let projectRelativePath = projectRelativeCharacterAssetPath(from: trimmed) {
            return projectRelativePath
        }

        if let resolvedURL = resolvedCharacterAssetURL(for: trimmed),
           let projectRelativePath = projectRelativePath(for: resolvedURL, projectURL: fileOWPURL) {
            return projectRelativePath
        }

        return trimmed.hasPrefix("/") ? nil : trimmed
    }

    private func normalizedCharacterAssetPaths(_ paths: [String]) -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []

        for path in paths {
            guard let repaired = normalizedCharacterAssetPath(path),
                  seen.insert(repaired).inserted else {
                continue
            }
            normalized.append(repaired)
        }

        return normalized
    }

    private func normalizedLandmarkImagePath(_ path: String?) -> String? {
        guard let trimmed = normalizedMediaPath(path) else {
            return nil
        }
        return normalizedCharacterAssetPath(trimmed) ?? trimmed
    }

    private func normalizedLandmarkImagePaths(_ paths: [String]) -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []

        for path in paths {
            guard let repaired = normalizedLandmarkImagePath(path),
                  seen.insert(repaired).inserted else {
                continue
            }
            normalized.append(repaired)
        }

        return normalized
    }

    private func characterAssetExists(at path: String?) -> Bool {
        guard let normalizedPath = normalizedCharacterAssetPath(path) else { return false }
        if resolvedCharacterAssetURL(for: normalizedPath) != nil {
            return true
        }
        if normalizedPath.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: normalizedPath)
        }
        return false
    }

    private func normalizedLookDevelopmentSlots(_ slots: [CharacterLookDevelopmentSlot]) -> [CharacterLookDevelopmentSlot] {
        slots.map { slot in
            var updated = slot
            updated.variants = normalizedCharacterVariants(slot.variants)
            if let approvedVariantID = updated.approvedVariantID,
               !updated.variants.contains(where: { $0.id == approvedVariantID }) {
                updated.approvedVariantID = updated.variants.last?.id
            }
            return updated
        }
    }

    private func normalizedCharacterVariants(
        _ variants: [CharacterLookDevelopmentVariant]
    ) -> [CharacterLookDevelopmentVariant] {
        variants.compactMap { variant in
            guard let normalizedPath = normalizedCharacterAssetPath(variant.imagePath) else {
                return nil
            }
            var updatedVariant = variant
            updatedVariant.imagePath = normalizedPath
            return updatedVariant
        }
    }

    private func normalizedInspirationBatchJobs(
        _ jobs: [CharacterInspirationBatchJob]
    ) -> [CharacterInspirationBatchJob] {
        jobs.map { job in
            var updatedJob = job
            updatedJob.metadataPath = normalizedCharacterAssetPath(job.metadataPath) ?? job.metadataPath
            updatedJob.outputRootPath = normalizedCharacterAssetPath(job.outputRootPath) ?? job.outputRootPath
            updatedJob.downloadedImagePaths = normalizedCharacterAssetPaths(job.downloadedImagePaths)
            updatedJob.autoImportedImagePaths = normalizedCharacterAssetPaths(job.autoImportedImagePaths)
            return updatedJob
        }
    }

    private func inspirationBatchJobKey(_ job: CharacterInspirationBatchJob) -> String {
        let batchName = job.batchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !batchName.isEmpty {
            return "batch:\(batchName)"
        }
        let metadataPath = (normalizedCharacterAssetPath(job.metadataPath) ?? job.metadataPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !metadataPath.isEmpty {
            return "metadata:\(metadataPath)"
        }
        return "id:\(job.id.uuidString)"
    }

    private func dismissedInspirationBatchJobKeys(for character: AnimationCharacter) -> Set<String> {
        guard let animateURL else { return [] }
        return ImagineGallerySelectionState.load(
            animateURL: animateURL,
            characterSlug: character.assetFolderSlug
        ).dismissedBatchJobKeys
    }

    private func persistDismissedInspirationBatchJobKeys(
        _ keys: Set<String>,
        for character: AnimationCharacter
    ) {
        guard let animateURL else { return }
        var state = ImagineGallerySelectionState.load(
            animateURL: animateURL,
            characterSlug: character.assetFolderSlug
        )
        state.dismissedBatchJobKeys = keys
        state.save(animateURL: animateURL, characterSlug: character.assetFolderSlug)
    }

    private func mergeInspirationBatchJobs(
        existing: [CharacterInspirationBatchJob],
        discovered: [CharacterInspirationBatchJob]
    ) -> [CharacterInspirationBatchJob] {
        var mergedByKey: [String: CharacterInspirationBatchJob] = [:]
        var insertionOrder: [String] = []

        func merge(_ job: CharacterInspirationBatchJob) {
            let key = inspirationBatchJobKey(job)
            if mergedByKey[key] == nil {
                insertionOrder.append(key)
                mergedByKey[key] = job
                return
            }

            var updated = mergedByKey[key] ?? job
            if !job.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.title = job.title
            }
            if !job.batchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.batchName = job.batchName
            }
            if !job.metadataPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.metadataPath = job.metadataPath
            }
            if !job.outputRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.outputRootPath = job.outputRootPath
            }
            if job.kind == .loraCandidate {
                updated.kind = .loraCandidate
            }
            updated.state = job.state
            if updated.promptCount == 0, job.promptCount > 0 {
                updated.promptCount = job.promptCount
            }
            if let lastCheckedAt = job.lastCheckedAt {
                updated.lastCheckedAt = lastCheckedAt
            }
            if let remoteUpdatedAt = job.remoteUpdatedAt {
                updated.remoteUpdatedAt = remoteUpdatedAt
            }
            if let remoteStartedAt = job.remoteStartedAt {
                updated.remoteStartedAt = remoteStartedAt
            }
            if let remoteFinishedAt = job.remoteFinishedAt {
                updated.remoteFinishedAt = remoteFinishedAt
            }
            if let remoteSuccessfulCount = job.remoteSuccessfulCount {
                updated.remoteSuccessfulCount = remoteSuccessfulCount
            }
            if let lastErrorMessage = job.lastErrorMessage,
               !lastErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.lastErrorMessage = lastErrorMessage
            }
            updated.downloadedImagePaths = normalizedCharacterAssetPaths(
                updated.downloadedImagePaths + job.downloadedImagePaths
            )
            updated.autoImportedImagePaths = normalizedCharacterAssetPaths(
                updated.autoImportedImagePaths + job.autoImportedImagePaths
            )
            mergedByKey[key] = updated
        }

        existing.forEach(merge)
        discovered.forEach(merge)

        return insertionOrder.compactMap { mergedByKey[$0] }
            .sorted { lhs, rhs in
                if lhs.submittedAt == rhs.submittedAt {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.submittedAt < rhs.submittedAt
            }
    }

    private func discoveredInspirationBatchJobsOnDisk(for character: AnimationCharacter) -> [CharacterInspirationBatchJob] {
        guard let animateURL else { return [] }
        let batchesRoot = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(character.assetFolderSlug)
            .appendingPathComponent("inspiration-batches")
        guard let enumerator = FileManager.default.enumerator(
            at: batchesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var discovered: [CharacterInspirationBatchJob] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "batch_submission.json",
                  let relativeMetadataPath = projectRelativePath(for: fileURL, projectURL: fileOWPURL),
                  let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let latestStatus = json["latest_status"] as? [String: Any]
            let state = (latestStatus?["state"] as? String)
                ?? (json["batch_state"] as? String)
                ?? "JOB_STATE_PENDING"
            let displayName = (json["display_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let folderName = fileURL.deletingLastPathComponent().lastPathComponent
            let title = (displayName?.isEmpty == false ? displayName : nil) ?? folderName
            let batchName = (json["batch_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let promptCount = json["prompt_count"] as? Int ?? 0
            let submittedAt = batchStatusDate(json["submitted_at"])
                ?? batchStatusDate(json["last_status_check"])
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            let outputRootRelativePath = projectRelativePath(
                for: fileURL.deletingLastPathComponent(),
                projectURL: fileOWPURL
            ) ?? relativeMetadataPath
            let decodedPaths = normalizedCharacterAssetPaths(
                latestStatus?["decoded_images"] as? [String] ?? []
            )
            let kind: CharacterInspirationBatchJob.Kind = {
                let haystacks = [folderName, title, batchName].map { $0.lowercased() }
                return haystacks.contains(where: { $0.contains("lora-candidate") || $0.contains("lora_candidate") })
                    ? .loraCandidate
                    : .inspiration
            }()
            let remoteSuccessfulCount = ((latestStatus?["completion_stats"] as? [String: Any])?["successful_count"] as? Int)
            let lastErrorMessage: String? = {
                guard let error = latestStatus?["error"] as? [String: Any] else { return nil }
                return (error["message"] as? String) ?? (error["details"] as? String)
            }()

            discovered.append(
                CharacterInspirationBatchJob(
                    kind: kind,
                    title: title,
                    batchName: batchName,
                    metadataPath: relativeMetadataPath,
                    outputRootPath: outputRootRelativePath,
                    state: state,
                    promptCount: promptCount,
                    submittedAt: submittedAt,
                    lastCheckedAt: batchStatusDate(json["last_status_check"]),
                    remoteUpdatedAt: batchStatusDate(latestStatus?["update_time"]),
                    remoteStartedAt: batchStatusDate(latestStatus?["start_time"]),
                    remoteFinishedAt: batchStatusDate(latestStatus?["end_time"]),
                    remoteSuccessfulCount: remoteSuccessfulCount,
                    downloadedImagePaths: decodedPaths,
                    autoImportedImagePaths: [],
                    lastErrorMessage: lastErrorMessage
                )
            )
        }

        return discovered
    }

    private func characterSlugForRigRelativePath(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 4 else { return nil }
        guard components[0] == "Animate",
              components[1] == "characters",
              components.last == "rig.json" else {
            return nil
        }
        return components[2]
    }

    private func isCharacterBatchMetadataRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 6 else { return false }
        return components[0] == "Animate"
            && components[1] == "characters"
            && components[3] == "inspiration-batches"
            && components.last == "batch_submission.json"
    }

    private func isPlaceWorldBatchMetadataRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 6 else { return false }
        return components[0] == "Animate"
            && components[1] == "backgrounds"
            && components[2] == "place-batches"
            && components.last == "batch_submission.json"
    }

    private func isPlaceWorldBatchResultsRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 6 else { return false }
        return components[0] == "Animate"
            && components[1] == "backgrounds"
            && components[2] == "place-batches"
            && components.last == "batch_results.jsonl"
    }

    private func normalizedPoseSlots(_ slots: [CharacterPoseSlot]) -> [CharacterPoseSlot] {
        slots.map { slot in
            var updated = slot
            updated.variants = normalizedCharacterVariants(slot.variants)
            if let approvedVariantID = updated.approvedVariantID,
               !updated.variants.contains(where: { $0.id == approvedVariantID }) {
                updated.approvedVariantID = updated.variants.last?.id
            }
            return updated
        }
    }

    private func normalizedAccessorySlots(_ slots: [CharacterAccessorySlot]) -> [CharacterAccessorySlot] {
        slots.map { slot in
            var updated = slot
            updated.variants = normalizedCharacterVariants(slot.variants)
            if let approvedVariantID = updated.approvedVariantID,
               !updated.variants.contains(where: { $0.id == approvedVariantID }) {
                updated.approvedVariantID = updated.variants.last?.id
            }
            return updated
        }
    }

    private func normalizedCostumeReferenceSets(
        _ sets: [CharacterCostumeReferenceSet]
    ) -> [CharacterCostumeReferenceSet] {
        sets.map { set in
            var updated = set
            updated.sheetVariants = normalizedCharacterVariants(set.sheetVariants)
            if let approvedSheetVariantID = updated.approvedSheetVariantID,
               !updated.sheetVariants.contains(where: { $0.id == approvedSheetVariantID }) {
                updated.approvedSheetVariantID = updated.sheetVariants.last?.id
            }
            updated.fullBodySlots = normalizedPoseSlots(set.fullBodySlots)
            updated.accessorySlots = normalizedAccessorySlots(set.accessorySlots)
            return updated
        }
    }

    private func projectRelativeCharacterAssetPath(from path: String) -> String? {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }

        if !normalizedPath.hasPrefix("/") {
            if normalizedPath.hasPrefix("Animate/") {
                return normalizedPath
            }
            if normalizedPath.hasPrefix("characters/") || normalizedPath.hasPrefix("backgrounds/") {
                return "Animate/" + normalizedPath
            }
            return normalizedPath
        }

        let standardizedAbsoluteURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
        if let projectRelativePath = projectRelativePath(for: standardizedAbsoluteURL, projectURL: fileOWPURL) {
            return projectRelativePath
        }

        let standardizedAbsolutePath = standardizedAbsoluteURL.path
        if let animateRange = standardizedAbsolutePath.range(of: "/Animate/") {
            return "Animate/" + standardizedAbsolutePath[animateRange.upperBound...]
        }

        return nil
    }

    private func projectRelativePath(for url: URL, projectURL: URL?) -> String? {
        guard let projectURL else { return nil }

        let absolutePath = url.standardizedFileURL.path
        let projectPath = projectURL.standardizedFileURL.path
        guard absolutePath == projectPath || absolutePath.hasPrefix(projectPath + "/") else {
            return nil
        }

        let suffix = absolutePath.dropFirst(projectPath.count)
        let trimmed = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistedCharacter(_ character: AnimationCharacter) -> AnimationCharacter {
        let normalizedMasterVariants = normalizedCharacterVariants(character.masterReferenceSheetVariants)
        let normalizedHeadSheetVariants = normalizedCharacterVariants(character.headTurnaroundSheetVariants)
        return AnimationCharacter(
            schemaVersion: AnimationCharacter.currentSchemaVersion,
            id: character.id,
            sortOrder: character.sortOrder,
            name: character.name,
            description: character.description,
            owpSlug: character.owpSlug,
            storageSlug: normalizedStorageSlug(for: character),
            renderMode: character.renderMode,
            preferredViewAngle: character.preferredViewAngle,
            parts: character.parts,
            profileImagePath: normalizedCharacterAssetPath(character.profileImagePath),
            backstory: character.backstory,
            personality: character.personality,
            notes: character.notes,
            activeLORAFilename: trimmedOrNil(character.activeLORAFilename),
            activeLORATriggerWord: trimmedOrNil(character.activeLORATriggerWord),
            activeLORAWeight: character.activeLORAWeight > 0 ? character.activeLORAWeight : 1.0,
            defaultWardrobeType: character.defaultWardrobeType,
            genderType: character.genderType,
            age: character.age,
            inspirationImagePaths: normalizedCharacterAssetPaths(character.inspirationImagePaths),
            curatedInspirationImagePaths: normalizedCharacterAssetPaths(character.curatedInspirationImagePaths),
            inspirationReferenceImagePath: normalizedCharacterAssetPath(character.inspirationReferenceImagePath),
            inspirationBatchJobs: normalizedInspirationBatchJobs(character.inspirationBatchJobs),
            referenceImagePaths: normalizedCharacterAssetPaths(character.referenceImagePaths),
            animatedImagePaths: normalizedCharacterAssetPaths(character.animatedImagePaths),
            lookDevelopmentSlots: normalizedLookDevelopmentSlots(character.lookDevelopmentSlots),
            masterReferenceSheetPrompt: character.masterReferenceSheetPrompt,
            masterReferenceSourceImagePaths: normalizedCharacterAssetPaths(character.masterReferenceSourceImagePaths),
            masterReferenceSheetVariants: normalizedMasterVariants,
            approvedMasterReferenceSheetVariantID: normalizedMasterVariants
                .contains(where: { $0.id == character.approvedMasterReferenceSheetVariantID })
                ? character.approvedMasterReferenceSheetVariantID
                : normalizedMasterVariants.last?.id,
            headTurnaroundSheetPrompt: character.headTurnaroundSheetPrompt,
            headTurnaroundSheetVariants: normalizedHeadSheetVariants,
            approvedHeadTurnaroundSheetVariantID: normalizedHeadSheetVariants
                .contains(where: { $0.id == character.approvedHeadTurnaroundSheetVariantID })
                ? character.approvedHeadTurnaroundSheetVariantID
                : normalizedHeadSheetVariants.last?.id,
            headTurnaroundSlots: normalizedPoseSlots(character.headTurnaroundSlots),
            costumeReferenceSets: normalizedCostumeReferenceSets(character.costumeReferenceSets),
            models3D: character.models3D
        )
    }

    private func normalizedStorageSlug(for character: AnimationCharacter) -> String {
        normalizedStorageSlug(
            forName: character.name,
            fallback: character.storageSlug ?? character.owpSlug
        )
    }

    private func normalizedStorageSlug(forName name: String, fallback: String) -> String {
        let candidate = CharacterReferenceWorkflowCatalog.slug(from: name)
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? trimmedFallback : candidate
    }

    private func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedPersistedCharacterState(
        _ character: AnimationCharacter,
        fallbackSlug: String
    ) -> AnimationCharacter {
        var updated = persistedCharacter(character)
        let resolvedName = updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackSlug.replacingOccurrences(of: "-", with: " ").capitalized
            : updated.name
        let defaultCostumeSetsByName = Dictionary(
            uniqueKeysWithValues: CharacterReferenceWorkflowCatalog
                .defaultCostumeSets(for: resolvedName)
                .map { ($0.name, $0) }
        )

        updated.schemaVersion = AnimationCharacter.currentSchemaVersion
        updated.name = resolvedName
        updated.owpSlug = updated.owpSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackSlug
            : updated.owpSlug
        updated.storageSlug = normalizedStorageSlug(forName: resolvedName, fallback: updated.storageSlug ?? fallbackSlug)
        updated.activeLORAFilename = trimmedOrNil(updated.activeLORAFilename)
        updated.activeLORATriggerWord = trimmedOrNil(updated.activeLORATriggerWord)
        if updated.activeLORAFilename == nil {
            updated.activeLORATriggerWord = nil
        }
        if updated.activeLORAWeight <= 0 {
            updated.activeLORAWeight = 1.0
        }
        updated.masterReferenceSheetPrompt = updated.masterReferenceSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(for: resolvedName, gender: updated.genderType)
            : updated.masterReferenceSheetPrompt
        if updated.masterReferenceSourceImagePaths.isEmpty {
            updated.masterReferenceSourceImagePaths = defaultMasterReferenceSourcePaths(for: updated)
        }
        updated.headTurnaroundSheetPrompt = updated.headTurnaroundSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(for: resolvedName)
            : updated.headTurnaroundSheetPrompt
        updated.headTurnaroundSlots = updated.headTurnaroundSlots.isEmpty
            ? CharacterReferenceWorkflowCatalog.defaultHeadSlots(for: resolvedName)
            : normalizedPoseSlots(updated.headTurnaroundSlots)
        updated.costumeReferenceSets = updated.costumeReferenceSets.isEmpty
            ? CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: resolvedName)
            : normalizedCostumeReferenceSets(updated.costumeReferenceSets).map { set in
                guard let defaultSet = defaultCostumeSetsByName[set.name] else { return set }
                var revisedSet = set
                if revisedSet.sheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    revisedSet.sheetPrompt = defaultSet.sheetPrompt
                }
                if revisedSet.fullBodySlots.isEmpty {
                    revisedSet.fullBodySlots = defaultSet.fullBodySlots
                }
                if revisedSet.accessorySlots.isEmpty {
                    revisedSet.accessorySlots = defaultSet.accessorySlots
                }
                return revisedSet
            }
        return updated
    }

    private func resolvedMediaURL(for path: String) -> URL? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        if let projectRoot = fileOWPURL?.deletingLastPathComponent() {
            let projectRelative = projectRoot.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: projectRelative.path) {
                return projectRelative
            }
        }

        if let animateURL {
            let animateRelative = animateURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: animateRelative.path) {
                return animateRelative
            }
        }

        return URL(fileURLWithPath: path)
    }

    private func setSelectedSceneDefaultAudioPath(_ path: String?) {
        guard let selectedSceneID,
              let sceneIndex = scenes.firstIndex(where: { $0.id == selectedSceneID })
        else {
            return
        }

        scenes[sceneIndex].defaultAudioPath = normalizedMediaPath(path)
        persistSelectedSceneTracks()
    }

    /// Public API to set (or clear) the default audio path for any scene by ID.
    func setDefaultAudioPath(_ path: String?, for sceneID: UUID) {
        guard let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        scenes[sceneIndex].defaultAudioPath = normalizedMediaPath(path)
        if selectedSceneID == sceneID {
            persistSelectedSceneTracks()
        }
    }

    private func applyShotPresetApplications(
        _ applications: [(LLMShotPresetApplication, SceneShotPreset)],
        to compiled: inout CompiledScene
    ) {
        var generatedCueKeys: Set<String> = []

        for (application, preset) in applications {
            let frame = application.frame
            let overridesByCharacterName = Dictionary(
                application.characterOverrides.map { override in
                    (
                        override.characterName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        override
                    )
                },
                uniquingKeysWith: { _, latest in latest }
            )
            var appliedOverrideCharacterNames: Set<String> = []

            if let cameraShot = application.cameraShot ?? preset.cameraShot {
                mergePresetExpressionCue(
                    expression: cameraShot.rawValue,
                    into: Self.cameraShotTrackName,
                    at: frame,
                    compiled: &compiled,
                    generatedCueKeys: &generatedCueKeys
                )
            }

            if let defaultCameraShot = preset.defaultCameraShot {
                mergePresetExpressionCue(
                    expression: defaultCameraShot.rawValue,
                    into: Self.cameraDefaultShotTrackName,
                    at: frame,
                    compiled: &compiled,
                    generatedCueKeys: &generatedCueKeys
                )
            }

            if let focusCharacter = application.focusCharacterName.flatMap({ resolvedCharacter(named: $0) }) ?? preset.focusCharacterSlug.flatMap({ slug in
                characters.first(where: { $0.owpSlug == slug })
            }) {
                mergePresetExpressionCue(
                    expression: focusCharacter.owpSlug,
                    into: Self.cameraFocusTrackName,
                    at: frame,
                    compiled: &compiled,
                    generatedCueKeys: &generatedCueKeys
                )
            }

            if let shotIntent = application.shotIntent ?? preset.shotIntent {
                mergePresetExpressionCue(
                    expression: shotIntent.rawValue,
                    into: Self.cameraIntentTrackName,
                    at: frame,
                    compiled: &compiled,
                    generatedCueKeys: &generatedCueKeys
                )
            }

            let beatLabel = trimmedMetadataOverride(application.beatLabel) ?? preset.name
            if !beatLabel.isEmpty {
                mergePresetExpressionCue(
                    expression: beatLabel,
                    into: Self.cameraBeatTrackName,
                    at: frame,
                    compiled: &compiled,
                    generatedCueKeys: &generatedCueKeys
                )
            }

            if let beatNotes = trimmedMetadataOverride(application.beatNotes) ?? trimmedMetadataOverride(preset.notes),
               !beatNotes.isEmpty {
                mergePresetExpressionCue(
                    expression: beatNotes,
                    into: Self.cameraNotesTrackName,
                    at: frame,
                    compiled: &compiled,
                    generatedCueKeys: &generatedCueKeys
                )
            }

            for cue in preset.characterCues {
                guard let character = characters.first(where: { $0.owpSlug == cue.characterSlug }) else {
                    continue
                }

                let characterNameKey = character.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let override = overridesByCharacterName[characterNameKey]
                if override != nil {
                    appliedOverrideCharacterNames.insert(characterNameKey)
                }

                if let facing = override?.facing ?? cue.facing {
                    mergePresetExpressionCue(
                        expression: facing.rawValue,
                        into: "\(character.name):facing",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let viewAngle = override?.viewAngle ?? cue.viewAngle {
                    mergePresetExpressionCue(
                        expression: viewAngle.rawValue,
                        into: "\(character.name):view",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let pose = override?.pose ?? cue.pose {
                    mergePresetExpressionCue(
                        expression: pose.rawValue,
                        into: "\(character.name):pose",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let expression = (override?.expression ?? cue.expression)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !expression.isEmpty {
                    mergePresetExpressionCue(
                        expression: expression,
                        into: "\(character.name):expression",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let action = (override?.action ?? cue.action)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !action.isEmpty {
                    mergePresetExpressionCue(
                        expression: action,
                        into: "\(character.name):action",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }
            }

            for override in application.characterOverrides {
                let normalizedCharacterName = override.characterName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !appliedOverrideCharacterNames.contains(normalizedCharacterName),
                      let character = resolvedCharacter(named: override.characterName)
                else {
                    continue
                }

                if let facing = override.facing {
                    mergePresetExpressionCue(
                        expression: facing.rawValue,
                        into: "\(character.name):facing",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let viewAngle = override.viewAngle {
                    mergePresetExpressionCue(
                        expression: viewAngle.rawValue,
                        into: "\(character.name):view",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let pose = override.pose {
                    mergePresetExpressionCue(
                        expression: pose.rawValue,
                        into: "\(character.name):pose",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let expression = override.expression?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !expression.isEmpty {
                    mergePresetExpressionCue(
                        expression: expression,
                        into: "\(character.name):expression",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }

                if let action = override.action?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !action.isEmpty {
                    mergePresetExpressionCue(
                        expression: action,
                        into: "\(character.name):action",
                        at: frame,
                        compiled: &compiled,
                        generatedCueKeys: &generatedCueKeys
                    )
                }
            }

            compiled.totalFrames = max(compiled.totalFrames, frame == 0 ? 1 : frame)
        }
    }

    private func mergePresetExpressionCue(
        expression: String,
        into trackName: String,
        at frame: Int,
        compiled: inout CompiledScene,
        generatedCueKeys: inout Set<String>
    ) {
        let cueKey = "\(trackName)|\(frame)"
        let keyframe = AnimationEngine.generateExpressionChange(expression: expression, at: frame)

        if let existingIndex = compiled.tracks[trackName]?.firstIndex(where: { $0.frame == frame && $0.kind == .expression }) {
            guard generatedCueKeys.contains(cueKey) else {
                return
            }
            compiled.tracks[trackName]?[existingIndex] = keyframe
        } else {
            compiled.tracks[trackName, default: []].append(keyframe)
        }

        compiled.tracks[trackName]?.sort { $0.frame < $1.frame }
        generatedCueKeys.insert(cueKey)
    }

    private func trimmedMetadataOverride(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistSelectedSceneTracks() {
        guard let sceneID = selectedSceneID,
              let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID })
        else {
            return
        }

        let scene = scenes[sceneIndex]
        var tracks = sceneTracks.mapValues { normalizeTimelineTrack($0, scene: scene) }
        if let cameraTrack {
            tracks[Self.cameraTrackName] = normalizeTimelineTrack(cameraTrack, scene: scene)
        } else {
            tracks.removeValue(forKey: Self.cameraTrackName)
        }

        scenes[sceneIndex].tracks = tracks
    }

    private func makeSceneData(from scene: AnimationScene) -> AnimateSceneData {
        let characterSlugs = scene.characterIDs.compactMap { characterID in
            characters.first(where: { $0.id == characterID })?.owpSlug
        }

        return AnimateSceneData(
            owsSongPath: scene.owpSongPath,
            backgroundID: scene.backgroundID,
            characterIDs: scene.characterIDs,
            characterSlugs: characterSlugs,
            objectSetups: normalizedSceneObjectSetups(scene.objectSetups, tracks: scene.tracks),
            keyframes: scene.keyframes,
            defaultAudioPath: scene.defaultAudioPath,
            tracks: scene.tracks,
            directionTemplate: normalizedDirectionTemplateForPersistence(scene.directionTemplate),
            automationProfile: normalizedSceneAutomationProfileForPersistence(scene.automationProfile, scene: scene),
            shots: normalizedSceneShots(scene.shots)
        )
    }

    private func applySceneData(_ sceneData: AnimateSceneData, to scene: inout AnimationScene) {
        scene.backgroundID = sceneData.backgroundID
        scene.keyframes = sceneData.keyframes
        scene.defaultAudioPath = sceneData.defaultAudioPath
        scene.tracks = sceneData.tracks
        scene.objectSetups = normalizedSceneObjectSetups(sceneData.objectSetups, tracks: sceneData.tracks)
        scene.directionTemplate = sceneData.directionTemplate
        scene.automationProfile = sceneData.automationProfile
        scene.shots = normalizedSceneShots(sceneData.shots)

        scene.characterSlugs = sceneData.characterSlugs
        if !sceneData.characterSlugs.isEmpty {
            scene.characterIDs = sceneData.characterSlugs.compactMap { slug in
                characters.first(where: { $0.owpSlug == slug })?.id
            }
        } else {
            scene.characterIDs = sceneData.characterIDs
        }

        if var template = scene.directionTemplate {
            if let focusCharacterSlug = template.focusCharacterSlug {
                template.focusCharacterID = characters.first(where: { $0.owpSlug == focusCharacterSlug })?.id
            } else if let focusCharacterID = template.focusCharacterID {
                template.focusCharacterSlug = characters.first(where: { $0.id == focusCharacterID })?.owpSlug
            }
            scene.directionTemplate = template.isEmpty ? nil : template
        }

        if var automationProfile = scene.automationProfile {
            automationProfile.sync(with: scene, characters: characters)
            scene.automationProfile = automationProfile
        }

        scene.shots = normalizedSceneShots(scene.shots)
    }

    private func normalizedSceneShots(_ shots: [AnimationSceneShot]) -> [AnimationSceneShot] {
        shots
            .map { shot in
                var shot = shot
                let trimmedName = shot.name.trimmingCharacters(in: .whitespacesAndNewlines)
                shot.name = trimmedName
                shot.startFrame = max(0, shot.startFrame)
                shot.endFrame = max(shot.startFrame, shot.endFrame)
                shot.notes = shot.notes.trimmingCharacters(in: .whitespacesAndNewlines)

                if let focusSlug = shot.focusCharacterSlug,
                   let characterID = characters.first(where: { $0.owpSlug == focusSlug })?.id {
                    shot.focusCharacterID = characterID
                } else if let focusID = shot.focusCharacterID {
                    shot.focusCharacterSlug = characters.first(where: { $0.id == focusID })?.owpSlug
                }

                return shot
            }
            .sorted {
                if $0.startFrame == $1.startFrame {
                    if $0.endFrame == $1.endFrame {
                        return $0.name < $1.name
                    }
                    return $0.endFrame < $1.endFrame
                }
                return $0.startFrame < $1.startFrame
            }
    }

    private func normalizedSceneObjectSetups(
        _ objectSetups: [ObjectSetup],
        tracks: [String: TimelineTrack]
    ) -> [ObjectSetup] {
        let inferredByName = Dictionary(
            uniqueKeysWithValues: inferredSceneObjectSetups(from: tracks).map {
                ($0.objectName.lowercased(), $0)
            }
        )

        var deduped: [String: ObjectSetup] = [:]
        for setup in objectSetups {
            let normalizedName = setup.objectName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { continue }

            var normalized = setup
            normalized.objectName = normalizedName
            normalized.enterFrame = max(0, normalized.enterFrame)
            if let exitFrame = normalized.exitFrame {
                normalized.exitFrame = max(normalized.enterFrame, exitFrame)
            }
            normalized.imagePaths = normalized.imagePaths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            normalized.approvedImagePath = normalized.approvedImagePath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.approvedImagePath?.isEmpty == true {
                normalized.approvedImagePath = nil
            }
            normalized.notes = normalized.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.stateImagePaths = Dictionary(
                uniqueKeysWithValues: normalized.stateImagePaths.compactMap { key, value in
                    let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else { return nil }
                    return (trimmedKey, trimmedValue)
                }
            )

            if let inferred = inferredByName[normalizedName.lowercased()] {
                normalized.enterFrame = min(normalized.enterFrame, inferred.enterFrame)
                if normalized.exitFrame == nil {
                    normalized.exitFrame = inferred.exitFrame
                }
                if normalized.approvedImagePath == nil {
                    normalized.approvedImagePath = inferred.approvedImagePath
                }
                if normalized.imagePaths.isEmpty {
                    normalized.imagePaths = inferred.imagePaths
                }
                if normalized.stateImagePaths.isEmpty {
                    normalized.stateImagePaths = inferred.stateImagePaths
                }
                if normalized.attachmentTarget == nil {
                    normalized.attachmentTarget = inferred.attachmentTarget
                }
            }

            deduped[normalizedName.lowercased()] = normalized
        }

        for inferred in inferredByName.values where deduped[inferred.objectName.lowercased()] == nil {
            deduped[inferred.objectName.lowercased()] = inferred
        }

        return deduped.values.sorted { lhs, rhs in
            if lhs.enterFrame == rhs.enterFrame {
                return lhs.objectName.localizedCaseInsensitiveCompare(rhs.objectName) == .orderedAscending
            }
            return lhs.enterFrame < rhs.enterFrame
        }
    }

    private func inferredSceneObjectSetups(
        from tracks: [String: TimelineTrack]
    ) -> [ObjectSetup] {
        var groupedTracks: [String: [String: TimelineTrack]] = [:]

        for (name, track) in tracks {
            guard let address = parsedTrackAddress(for: name),
                  case let .object(objectName, suffix) = address else {
                continue
            }
            groupedTracks[objectName.lowercased(), default: [:]][suffix] = track
        }

        return groupedTracks.values.compactMap { tracksBySuffix in
            guard let objectName = tracksBySuffix.values.first.flatMap({
                if case let .object(name, _) = parsedTrackAddress(for: $0.name) {
                    return name
                }
                return nil
            }) else {
                return nil
            }

            let initialFrame = tracksBySuffix.values
                .flatMap(\.keyframes)
                .map(\.frame)
                .min() ?? 0

            let initialTransform = tracksBySuffix["transform"]
                .flatMap { AnimationEngine.evaluate(track: $0, at: initialFrame) }
            let initialVisibility = tracksBySuffix["visibility"]
                .flatMap { AnimationEngine.evaluate(track: $0, at: initialFrame) }
            let initialDrawing = tracksBySuffix["drawing"]
                .flatMap { AnimationEngine.evaluate(track: $0, at: initialFrame) }
            let initialAction = tracksBySuffix["action"]
                .flatMap { AnimationEngine.evaluate(track: $0, at: initialFrame) }

            let resolvedTransform: CharacterTransform
            if case .transform(let transform) = initialTransform {
                resolvedTransform = transform
            } else {
                resolvedTransform = CharacterTransform(
                    x: 0.5,
                    y: 0.62,
                    rotation: 0,
                    scaleX: 1,
                    scaleY: 1,
                    opacity: 1,
                    zOrder: 0
                )
            }

            let resolvedVisibility: (Double, Bool)
            if case .visibility(let opacity, let visible) = initialVisibility {
                resolvedVisibility = (opacity, visible)
            } else {
                resolvedVisibility = (1, true)
            }

            let initialState: String
            if case .expression(let stateName) = initialDrawing {
                initialState = stateName
            } else {
                initialState = "default"
            }

            let attachmentTarget: String?
            if case .expression(let actionName) = initialAction,
               actionName.lowercased().hasPrefix("attach:") {
                let rawAttachment = String(actionName.dropFirst("attach:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                attachmentTarget = ObjectAttachmentReference.isClearDirective(rawAttachment)
                    ? nil
                    : rawAttachment
            } else {
                attachmentTarget = nil
            }

            return ObjectSetup(
                objectName: objectName,
                initialX: resolvedTransform.x,
                initialY: resolvedTransform.y,
                initialState: initialState,
                enterFrame: max(0, initialFrame),
                zOrder: resolvedTransform.zOrder,
                opacity: resolvedVisibility.0,
                visible: resolvedVisibility.1,
                attachmentTarget: attachmentTarget
            )
        }
    }

    private func beginAgentSync() {
        isAgentSyncInProgress = true
        hasPendingAgentChanges = false
    }

    private func markAgentUpdated(paths: [String] = []) {
        isAgentSyncInProgress = false
        hasPendingAgentChanges = false
        showsRecentAgentUpdate = true
        let marker = Date()

        for path in paths where !path.isEmpty {
            externalChangeTimes[path] = marker
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                guard let self else { return }
                if self.externalChangeTimes[path] == marker {
                    self.externalChangeTimes.removeValue(forKey: path)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            if self.showsRecentAgentUpdate {
                self.showsRecentAgentUpdate = false
            }
        }
    }

    private func startExternalFileWatch() {
        stopExternalFileWatch()
        guard fileOWPURL != nil else { return }

        fileWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.checkForExternalProjectChanges()
                try? await Task.sleep(for: .seconds(Self.externalWatchInterval))
            }
        }
    }

    private func stopExternalFileWatch() {
        fileWatchTask?.cancel()
        fileWatchTask = nil
        // Note: intentionally NOT clearing lastKnownExternalSnapshots here.
        // Clearing them causes the next startExternalFileWatch() to detect
        // ALL files as "changed", spawning massive concurrent reload Tasks.
    }

    private func recordExternalFileSnapshots() {
        guard let projectURL = fileOWPURL else { return }
        lastKnownExternalSnapshots = monitoredExternalFileSnapshots(for: projectURL)
    }

    private func monitoredExternalFileSnapshots(for projectURL: URL) -> [String: AnimateExternalFileSnapshot] {
        var snapshots: [String: AnimateExternalFileSnapshot] = [:]

        let enumerator = FileManager.default.enumerator(
            at: projectURL.appendingPathComponent("Songs"),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "ows",
                  let snapshot = fileSnapshot(for: fileURL) else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: projectURL.path + "/", with: "")
            snapshots[relativePath] = snapshot
        }

        for path in [
            "index.json",
            "Characters/characters.json",
            "characters.json",
            ProjectDatabaseBridge.animateMetadataPath,
            ProjectDatabaseBridge.animateScenesPath,
            ProjectDatabaseBridge.animatePlacesPath,
            ProjectDatabaseBridge.characterPackageSelectionsPath,
            ProjectDatabaseBridge.shotPresetsPath
        ] {
            let fileURL = projectURL.appendingPathComponent(path)
            if let snapshot = fileSnapshot(for: fileURL) {
                snapshots[path] = snapshot
            }
        }

        for rigURL in persistedCharacterRigURLsOnDisk() {
            guard let snapshot = fileSnapshot(for: rigURL),
                  let relativePath = projectRelativePath(for: rigURL, projectURL: projectURL) else {
                continue
            }
            snapshots[relativePath] = snapshot
        }

        let batchEnumerator = FileManager.default.enumerator(
            at: projectURL.appendingPathComponent("Animate/characters"),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = batchEnumerator?.nextObject() as? URL {
            guard fileURL.lastPathComponent == "batch_submission.json",
                  let snapshot = fileSnapshot(for: fileURL) else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: projectURL.path + "/", with: "")
            snapshots[relativePath] = snapshot
        }

        let placeBatchEnumerator = FileManager.default.enumerator(
            at: projectURL.appendingPathComponent("Animate/backgrounds/place-batches"),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = placeBatchEnumerator?.nextObject() as? URL {
            let filename = fileURL.lastPathComponent
            guard filename == "batch_submission.json" || filename == "batch_results.jsonl",
                  let snapshot = fileSnapshot(for: fileURL) else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: projectURL.path + "/", with: "")
            snapshots[relativePath] = snapshot
        }

        return snapshots
    }

    private func fileSnapshot(for fileURL: URL) -> AnimateExternalFileSnapshot? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate else {
            return nil
        }

        return AnimateExternalFileSnapshot(
            modificationDate: modificationDate,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    private func checkForExternalProjectChanges() {
        guard let projectURL = fileOWPURL, !isLoadingProject else { return }

        let currentSnapshots = monitoredExternalFileSnapshots(for: projectURL)
        let changedPaths = Set(currentSnapshots.keys).union(lastKnownExternalSnapshots.keys)
            .filter { currentSnapshots[$0] != lastKnownExternalSnapshots[$0] }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !changedPaths.isEmpty else { return }
        lastKnownExternalSnapshots = currentSnapshots

        let currentSongPaths = Set(currentSnapshots.keys.filter { $0.hasSuffix(".ows") })
        let knownSongPaths = Set(scenes.map(\.owpSongPath))
        if currentSongPaths != knownSongPaths {
            handleExternalProjectRescan(projectURL: projectURL, changedPaths: changedPaths)
            return
        }

        for path in changedPaths {
            if path.hasSuffix(".ows") {
                handleExternalSongChange(relativePath: path)
            } else {
                handleExternalProjectFileChange(path: path, projectURL: projectURL)
            }
        }
    }

    private func handleExternalProjectRescan(projectURL: URL, changedPaths: [String]) {
        beginAgentSync()
        Task { [weak self] in
            guard let self else { return }
            await self.openOWP(url: projectURL, skipBackgroundRefresh: true)
            await MainActor.run {
                self.markAgentUpdated(paths: changedPaths.filter { $0.hasSuffix(".ows") })
                self.statusMessage = "Reloaded external project changes"
            }
        }
    }

    private func handleExternalSongChange(relativePath: String) {
        guard let scene = scenes.first(where: { $0.owpSongPath == relativePath }) else { return }
        beginAgentSync()

        Task { [weak self, scene] in
            guard let self else { return }
            await self.loadSongData(for: scene)
            // Only seed shots if the scene currently has NONE — never overwrite authored data
            if let sceneIndex = self.scenes.firstIndex(where: { $0.owpSongPath == relativePath }),
               self.scenes[sceneIndex].shots.isEmpty,
               let owpURL = self.fileOWPURL,
               let songData = await ProjectDatabaseBridge.hydrateSongData(
                   projectURL: owpURL, relativePath: relativePath
               ) {
                let lyrics = songData.extractLyrics().trimmingCharacters(in: .whitespacesAndNewlines)
                if !lyrics.isEmpty {
                    let parseResult = SceneDirectionParser.parse(lyrics)
                    let shotService = AnimateSceneShotSeedingService(store: self)
                    let seeded = shotService.seededShots(for: self.scenes[sceneIndex], songData: songData, parseResult: parseResult)
                    if !seeded.isEmpty {
                        self.scenes[sceneIndex].shots = self.normalizedSceneShots(seeded)
                    }
                }
            }
            _ = await self.refreshPlacesFromScript()
            await MainActor.run {
                self.markAgentUpdated(paths: [relativePath])
                self.save()
                self.statusMessage = "Reloaded external song data"
            }
        }
    }

    private func handleExternalProjectFileChange(path: String, projectURL: URL) {
        beginAgentSync()
        Task { [weak self] in
            guard let self else { return }

            switch path {
            case ProjectDatabaseBridge.animateMetadataPath:
                let fileURL = projectURL.appendingPathComponent(path)
                let decoded = (try? Data(contentsOf: fileURL))
                    .flatMap { try? JSONDecoder().decode(AnimateMetadata.self, from: $0) }
                await MainActor.run {
                    if let decoded {
                        self.animateMetadata = decoded
                        self.fps = decoded.fps
                    }
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"
                }
            case ProjectDatabaseBridge.animateScenesPath:
                let savedScenes = ProjectDatabaseBridge.loadSavedScenesFromDisk(projectURL: projectURL)
                await MainActor.run {
                    for index in self.scenes.indices {
                        guard let savedScene = savedScenes[self.scenes[index].owpSongPath] else { continue }
                        self.applySceneData(savedScene, to: &self.scenes[index])
                    }

                    let selectedScene = self.selectedScene
                    if let animateDir = self.animateURL {
                        let backgroundDir = animateDir.appendingPathComponent("backgrounds")
                        self.backgrounds = (try? self.loadPlaces(from: animateDir, backgroundDirectoryURL: backgroundDir)) ?? []
                        self.placesWorkflowLibrary = self.hydratedPlacesWorkflowLibrary(
                            self.loadPlacesWorkflowLibrary(from: animateDir)
                        )
                    }
                    self.syncSelectedSceneTimeline()
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"

                    if let selectedScene {
                        Task { await self.loadSongData(for: selectedScene) }
                    }
                    Task { _ = await self.refreshPlacesFromScript() }
                }
            case ProjectDatabaseBridge.animatePlacesPath, ProjectDatabaseBridge.animatePlacesWorkflowPath:
                await MainActor.run {
                    guard let animateDir = self.animateURL else { return }
                    let backgroundDir = animateDir.appendingPathComponent("backgrounds")
                    self.backgrounds = (try? self.loadPlaces(from: animateDir, backgroundDirectoryURL: backgroundDir)) ?? []
                    self.placesWorkflowLibrary = self.hydratedPlacesWorkflowLibrary(
                        self.loadPlacesWorkflowLibrary(from: animateDir)
                    )
                    self.refreshPlaceWorldGenerationBatches()
                    _ = self.applyScriptPlaceRequirements(self.scriptPlaceRequirements, persistChanges: false)
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"
                }
            case ProjectDatabaseBridge.characterPackageSelectionsPath:
                let manifest = characterPackageSelectionStore
                    .load(from: projectURL.appendingPathComponent("Animate"))
                await MainActor.run {
                    self.activePackageIDsByCharacterSlug = manifest.activePackageIDsByCharacterSlug
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"
                }
            case ProjectDatabaseBridge.shotPresetsPath:
                let manifest = sceneShotPresetStore.load(from: projectURL.appendingPathComponent("Animate"))
                await MainActor.run {
                    self.shotPresets = self.sortedShotPresets(manifest.presets)
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"
                }
            case "Characters/characters.json", "characters.json":
                let loaded = try? await OWPProjectLoader().load(from: projectURL)
                await MainActor.run {
                    if let loaded {
                        self.owpCharacters = loaded.characters
                        self.syncCharactersFromOWP(loaded.characters)
                        if self.migrateAllCharacterStorageSlugsIfNeeded() {
                            self.save()
                        }
                        self.refreshInspirationBatchJobs()
                    }
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"
                }
            case "index.json":
                let loaded = try? await OWPProjectLoader().load(from: projectURL)
                await MainActor.run {
                    if let loaded {
                        self.owpIndexFile = loaded.indexFile
                        self.owpInstrumentMappings = loaded.instrumentMappings
                    }
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"
                }
            default:
                await MainActor.run {
                    if let slug = self.characterSlugForRigRelativePath(path),
                       let persisted = self.loadPersistedCharacterState(for: slug),
                       let index = self.characters.firstIndex(where: {
                           $0.assetFolderSlug == slug || $0.storageSlug == slug || $0.owpSlug == slug
                       }) {
                        self.characters[index] = persisted
                        self.refreshInspirationBatchJobs()
                        self.markAgentUpdated(paths: [path])
                        self.statusMessage = "Reloaded character rig changes"
                        return
                    }

                    if self.isCharacterBatchMetadataRelativePath(path) {
                        self.refreshInspirationBatchJobs()
                        self.markAgentUpdated(paths: [path])
                        self.statusMessage = "Reloaded inspiration batch results"
                        return
                    }

                    if self.isPlaceWorldBatchMetadataRelativePath(path) || self.isPlaceWorldBatchResultsRelativePath(path) {
                        self.refreshPlaceWorldGenerationBatches()
                        self.markAgentUpdated(paths: [path])
                        self.statusMessage = "Reloaded place batch results"
                        return
                    }

                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"
                }
            }
        }
    }

    func suspendBackgroundWork() {
        stopExternalFileWatch()
        backgroundIndexRefreshTask?.cancel()
        backgroundIndexRefreshTask = nil
    }

    func resumeBackgroundWork() {
        if !disableExternalFileWatch {
            startExternalFileWatch()
        }
    }

    private func observePersistedSaveState() {
        withObservationTracking {
            _ = animateURL
            _ = animateMetadata
            _ = scenes
            _ = characters
            _ = activePackageIDsByCharacterSlug
            _ = shotPresets
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reevaluatePersistedSaveState()
                self.observePersistedSaveState()
            }
        }

        reevaluatePersistedSaveState()
    }

    private func reevaluatePersistedSaveState() {
        guard !isReconcilingPersistenceState else { return }
        guard animateURL != nil else {
            lastSavedPersistenceFingerprint = nil
            saveIndicator = .idle
            return
        }
        guard saveIndicator != .saving else { return }
        guard let fingerprint = persistenceFingerprint() else {
            saveIndicator = .idle
            return
        }
        if let lastSavedPersistenceFingerprint {
            saveIndicator = fingerprint == lastSavedPersistenceFingerprint ? .saved : .unsavedChanges
        } else {
            saveIndicator = .saved
        }
    }

    private func markCurrentStateAsSaved() {
        lastSavedPersistenceFingerprint = persistenceFingerprint()
        saveIndicator = animateURL == nil ? .idle : .saved
    }

    private func persistenceFingerprint() -> String? {
        guard animateURL != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sceneData: [AnimateSceneData] = scenes.map { scene in
            let characterSlugs = scene.characterIDs.compactMap { characterID in
                characters.first(where: { $0.id == characterID })?.owpSlug
            }
            let directionTemplate = normalizedDirectionTemplateForPersistence(scene.directionTemplate)
            return AnimateSceneData(
                owsSongPath: scene.owpSongPath,
                backgroundID: scene.backgroundID,
                characterIDs: scene.characterIDs,
                characterSlugs: characterSlugs,
                objectSetups: normalizedSceneObjectSetups(scene.objectSetups, tracks: scene.tracks),
                keyframes: scene.keyframes,
                defaultAudioPath: scene.defaultAudioPath,
                tracks: scene.tracks,
                directionTemplate: directionTemplate,
                automationProfile: normalizedSceneAutomationProfileForPersistence(scene.automationProfile, scene: scene),
                shots: normalizedSceneShots(scene.shots)
            )
        }

        struct PersistedState: Encodable {
            var metadata: AnimateMetadata?
            var scenes: [AnimateSceneData]
            var characters: [AnimationCharacter]
            var packageSelections: CharacterPackageSelectionManifest
            var shotPresets: SceneShotPresetManifest
        }

        let payload = PersistedState(
            metadata: animateMetadata,
            scenes: sceneData,
            characters: characters,
            packageSelections: CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: activePackageIDsByCharacterSlug
            ),
            shotPresets: SceneShotPresetManifest(presets: shotPresets)
        )

        guard let data = try? encoder.encode(payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func timelineSortKey(
        for track: TimelineTrack,
        scene: AnimationScene,
        characterOrder: [UUID: Int]
    ) -> (Int, Int, String, String) {
        let normalizedTrack = normalizeTimelineTrack(track, scene: scene)
        let role = resolvedTrackRole(for: normalizedTrack)

        if role == .camera || normalizedTrack.name == Self.cameraTrackName {
            return (1_000, 0, "camera", normalizedTrack.name)
        }

        if role == .cameraShot || normalizedTrack.name == Self.cameraShotTrackName {
            return (999, 0, "camera", normalizedTrack.name)
        }

        if role == .cameraDefaultShot || normalizedTrack.name == Self.cameraDefaultShotTrackName {
            return (998, 0, "camera", normalizedTrack.name)
        }

        if role == .cameraFocus || normalizedTrack.name == Self.cameraFocusTrackName {
            return (997, 0, "camera", normalizedTrack.name)
        }

        if role == .cameraIntent || normalizedTrack.name == Self.cameraIntentTrackName {
            return (996, 0, "camera", normalizedTrack.name)
        }

        if role == .cameraBeat || normalizedTrack.name == Self.cameraBeatTrackName {
            return (995, 0, "camera", normalizedTrack.name)
        }

        if role == .cameraNotes || normalizedTrack.name == Self.cameraNotesTrackName {
            return (994, 0, "camera", normalizedTrack.name)
        }

        if let characterID = normalizedTrack.targetCharacterID {
            let characterName = characters.first(where: { $0.id == characterID })?.name ?? normalizedTrack.name
            return (
                characterOrder[characterID] ?? 800,
                trackSuffixOrder(role?.trackSuffix ?? normalizedTrack.name),
                characterName.lowercased(),
                role?.trackSuffix ?? normalizedTrack.name
            )
        }

        if let address = parsedTrackAddress(for: normalizedTrack.name) {
            switch address {
            case .character(let characterName, let suffix):
                let characterIndex = scene.characterIDs.enumerated().first { _, id in
                    guard let character = characters.first(where: { $0.id == id }) else { return false }
                    return character.name.caseInsensitiveCompare(characterName) == .orderedSame
                }?.offset ?? 800
                return (characterIndex, trackSuffixOrder(suffix), characterName.lowercased(), suffix)
            case .object(let objectName, let suffix):
                let objectOrder = Dictionary(
                    uniqueKeysWithValues: scene.objectSetups.enumerated().map { offset, object in
                        (object.objectName.lowercased(), offset)
                    }
                )
                return (
                    850 + (objectOrder[objectName.lowercased()] ?? 0),
                    trackSuffixOrder(suffix),
                    objectName.lowercased(),
                    suffix
                )
            case .camera:
                break
            }
        }

        return (
            900,
            trackSuffixOrder(role?.trackSuffix ?? normalizedTrack.name),
            normalizedTrack.name,
            normalizedTrack.name
        )
    }

    private func allTimelineTracks() -> [TimelineTrack] {
        var tracks = Array(sceneTracks.values)

        guard let selectedScene else {
            if let cameraTrack {
                tracks.append(cameraTrack)
            }
            return tracks
        }

        for (name, track) in selectedScene.tracks {
            if name == Self.cameraTrackName {
                if cameraTrack == nil {
                    tracks.append(track)
                }
                continue
            }

            if sceneTracks[name] == nil {
                tracks.append(track)
            }
        }

        if let cameraTrack {
            tracks.append(cameraTrack)
        }

        return tracks
    }

    private func resolveCharacter(named name: String) -> AnimationCharacter? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return characters.first { candidate in
            candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private func normalizedDirectionTemplateForPersistence(
        _ template: SceneDirectionTemplate?
    ) -> SceneDirectionTemplate? {
        guard var template else { return nil }

        if template.focusCharacterSlug == nil,
           let focusCharacterID = template.focusCharacterID {
            template.focusCharacterSlug = characters.first(where: {
                $0.id == focusCharacterID
            })?.owpSlug
        }

        return template.isEmpty ? nil : template
    }

    private func normalizedSceneAutomationProfile(
        _ profile: SceneAutomationProfile?,
        scene: AnimationScene
    ) -> SceneAutomationProfile {
        var resolved = profile ?? SceneAutomationProfile.defaultProfile(
            for: scene,
            characters: characters
        )
        resolved.sync(with: scene, characters: characters)
        return resolved
    }

    private func normalizedSceneAutomationProfileForPersistence(
        _ profile: SceneAutomationProfile?,
        scene: AnimationScene
    ) -> SceneAutomationProfile? {
        guard let profile else { return nil }
        return normalizedSceneAutomationProfile(profile, scene: scene)
    }

    private func liveTimelineTrackMap(
        scene: AnimationScene
    ) -> [String: TimelineTrack] {
        if scene.id == selectedSceneID {
            var tracks = sceneTracks
            if let cameraTrack {
                tracks[Self.cameraTrackName] = cameraTrack
            }
            return tracks
        }

        var tracks = scene.tracks
        if let cameraTrack = scene.tracks[Self.cameraTrackName] {
            tracks[Self.cameraTrackName] = cameraTrack
        }
        return tracks
    }

    private func upsertShotPreset(_ preset: SceneShotPreset) {
        if let index = shotPresets.firstIndex(where: { $0.id == preset.id }) {
            shotPresets[index] = preset
        } else {
            shotPresets.append(preset)
        }

        shotPresets.sort {
            let lhs = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rhs = $1.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lhs == rhs {
                return $0.updatedAt > $1.updatedAt
            }
            return lhs < rhs
        }
    }

    private enum TimelineTrackAddress {
        case camera(TimelineTrackRole)
        case character(name: String, suffix: String)
        case object(name: String, suffix: String)
    }

    private func parsedTrackAddress(for name: String) -> TimelineTrackAddress? {
        if name == Self.cameraTrackName {
            return .camera(.camera)
        }

        if name == Self.cameraShotTrackName {
            return .camera(.cameraShot)
        }

        if name == Self.cameraDefaultShotTrackName {
            return .camera(.cameraDefaultShot)
        }

        if name == Self.cameraFocusTrackName {
            return .camera(.cameraFocus)
        }

        if name == Self.cameraIntentTrackName {
            return .camera(.cameraIntent)
        }

        if name == Self.cameraBeatTrackName {
            return .camera(.cameraBeat)
        }

        if name == Self.cameraNotesTrackName {
            return .camera(.cameraNotes)
        }

        if name.hasPrefix("object:") {
            let components = name.split(separator: ":").map(String.init)
            guard components.count >= 3 else { return nil }
            let suffix = components.last ?? ""
            let objectName = components.dropFirst().dropLast().joined(separator: ":")
            guard !objectName.isEmpty else { return nil }
            return .object(name: objectName, suffix: suffix)
        }

        let components = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        return .character(name: components[0], suffix: components[1])
    }

    private func resolvedTrackRole(for track: TimelineTrack) -> TimelineTrackRole? {
        if let role = track.role {
            return role
        }

        guard let address = parsedTrackAddress(for: track.name) else {
            return nil
        }

        switch address {
        case .camera(let role):
            return role
        case .character(_, let suffix), .object(_, let suffix):
            return TimelineTrackRole(trackSuffix: suffix)
        }
    }

    private func normalizeTimelineTrack(
        _ track: TimelineTrack,
        scene: AnimationScene? = nil
    ) -> TimelineTrack {
        var normalizedTrack = track
        if normalizedTrack.role == nil {
            normalizedTrack.role = resolvedTrackRole(for: normalizedTrack)
        }

        guard normalizedTrack.targetCharacterID == nil,
              let scene,
              let address = parsedTrackAddress(for: normalizedTrack.name)
        else {
            return normalizedTrack
        }

        guard case let .character(characterName, _) = address else {
            return normalizedTrack
        }

        normalizedTrack.targetCharacterID = scene.characterIDs.first { id in
            guard let character = characters.first(where: { $0.id == id }) else { return false }
            return character.name.caseInsensitiveCompare(characterName) == .orderedSame
        }
        return normalizedTrack
    }

    private func inferredTrackMetadata(
        for trackName: String,
        scene: AnimationScene? = nil
    ) -> (targetCharacterID: UUID?, role: TimelineTrackRole?) {
        guard let address = parsedTrackAddress(for: trackName) else {
            return (nil, nil)
        }

        switch address {
        case .camera(let role):
            return (nil, role)
        case .object(_, let suffix):
            return (nil, TimelineTrackRole(trackSuffix: suffix))
        case .character(let characterName, let suffix):
            let role = TimelineTrackRole(trackSuffix: suffix)
            let characterPool = (scene?.characterIDs ?? characters.map(\.id)).compactMap { id in
                characters.first(where: { $0.id == id })
            }
            let matchedCharacter = characterPool.first { character in
                character.name.caseInsensitiveCompare(characterName) == .orderedSame
            }
            return (matchedCharacter?.id, role)
        }
    }

    private func preferredObjectTrackName(
        for objectName: String,
        role: TimelineTrackRole
    ) -> String {
        let trimmedName = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "object:\(trimmedName):\(role.trackSuffix)"
    }

    private func scoreForObjectTrack(
        _ track: TimelineTrack,
        objectName: String,
        role: TimelineTrackRole
    ) -> Int {
        let normalizedTrack = normalizeTimelineTrack(track)
        let preferredName = preferredObjectTrackName(for: objectName, role: role)
        var score = normalizedTrack.name == preferredName ? 0 : 100
        if resolvedTrackRole(for: normalizedTrack) != role {
            score += 1_000
        }

        if let address = parsedTrackAddress(for: normalizedTrack.name),
           case let .object(candidateName, _) = address,
           candidateName.caseInsensitiveCompare(objectName) == .orderedSame {
            return score
        }

        return score + 500
    }

    private func preferredTrackName(
        for characterID: UUID?,
        fallbackCharacterName: String? = nil,
        role: TimelineTrackRole
    ) -> String {
        if role == .camera {
            return Self.cameraTrackName
        }

        if role == .cameraShot {
            return Self.cameraShotTrackName
        }

        if role == .cameraDefaultShot {
            return Self.cameraDefaultShotTrackName
        }

        if role == .cameraFocus {
            return Self.cameraFocusTrackName
        }

        if role == .cameraIntent {
            return Self.cameraIntentTrackName
        }

        if role == .cameraBeat {
            return Self.cameraBeatTrackName
        }

        if role == .cameraNotes {
            return Self.cameraNotesTrackName
        }

        let characterName = characterID
            .flatMap { id in characters.first(where: { $0.id == id })?.name }
            ?? fallbackCharacterName
            ?? "Character"
        return "\(characterName):\(role.trackSuffix)"
    }

    private func preferredTrackName(
        for characterID: UUID,
        role: TimelineTrackRole
    ) -> String {
        preferredTrackName(for: Optional(characterID), role: role)
    }

    private func scoreForTrack(
        _ track: TimelineTrack,
        characterID: UUID,
        role: TimelineTrackRole
    ) -> Int {
        let normalizedTrack = normalizeTimelineTrack(track)
        let preferredName = preferredTrackName(for: characterID, role: role)

        if normalizedTrack.targetCharacterID == characterID && normalizedTrack.name == preferredName {
            return 0
        }
        if normalizedTrack.targetCharacterID == characterID {
            return 1
        }
        if normalizedTrack.name == preferredName {
            return 2
        }
        return 10
    }

    private func removeSceneTracks(
        for characterID: UUID?,
        role: TimelineTrackRole,
        preserving preservedName: String
    ) {
        sceneTracks = sceneTracks.filter { name, track in
            if name == preservedName {
                return true
            }

            let normalizedTrack = normalizeTimelineTrack(track)
            if let characterID, normalizedTrack.targetCharacterID == characterID {
                return resolvedTrackRole(for: normalizedTrack) != role
            }

            return true
        }
    }

    private func trackSuffixOrder(_ suffix: String) -> Int {
        switch suffix.lowercased() {
        case "transform": return 0
        case "visibility": return 1
        case "facing": return 2
        case "view": return 3
        case "pose": return 4
        case "expression": return 5
        case "action": return 6
        case "mouth": return 7
        case "shadow-style": return 8
        case "shadow-opacity": return 9
        case "drawing": return 10
        case "shot": return 11
        case "default-shot": return 12
        case "focus": return 13
        case "beat": return 14
        case "notes": return 15
        default: return 100
        }
    }

    private func setSemanticCue(
        _ rawValue: String?,
        trackSuffix: String,
        for characterName: String,
        characterID: UUID? = nil,
        at frame: Int? = nil
    ) {
        guard !scenes.isEmpty else {
            statusMessage = "Open a project before editing timeline cues."
            return
        }

        let frame = frame ?? currentFrame
        let normalizedValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCharacter = characterID.flatMap { id in
            characters.first(where: { $0.id == id })
        } ?? resolveCharacter(named: characterName)
        let resolvedRole = TimelineTrackRole(trackSuffix: trackSuffix)
        let trackName = preferredTrackName(
            for: resolvedCharacter?.id,
            fallbackCharacterName: resolvedCharacter?.name ?? characterName,
            role: resolvedRole
        )

        removeSceneTracks(for: resolvedCharacter?.id, role: resolvedRole, preserving: trackName)

        let existingTrack: TimelineTrack?
        if let resolvedCharacterID = resolvedCharacter?.id {
            existingTrack = timelineTrack(for: resolvedCharacterID, role: resolvedRole)
        } else {
            existingTrack = nil
        }
        var track = existingTrack
            ?? timelineTrack(named: trackName)
            ?? TimelineTrack(name: trackName, keyframes: [])
        track.name = trackName
        track.targetCharacterID = resolvedCharacter?.id
        track.role = resolvedRole
        let targetFrame = frame
        track.keyframes.removeAll { keyframe in
            keyframe.frame == targetFrame && keyframe.kind == .expression
        }

        if let normalizedValue, !normalizedValue.isEmpty {
            track.keyframes.append(
                TimelineKeyframe(
                    frame: frame,
                    kind: .expression,
                    easing: .stepped,
                    value: .expression(name: normalizedValue)
                )
            )
            track.keyframes.sort { $0.frame < $1.frame }
            sceneTracks[trackName] = track
            totalFrames = max(totalFrames, frame + 1)
            statusMessage = "Set \(trackSuffix) cue for \(characterName) at frame \(frame)"
        } else {
            if track.keyframes.isEmpty {
                sceneTracks.removeValue(forKey: trackName)
            } else {
                sceneTracks[trackName] = track
            }
            statusMessage = "Cleared \(trackSuffix) cue for \(characterName) at frame \(frame)"
        }

        persistSelectedSceneTracks()
    }

    // MARK: - OWP Open (replaces loadProject + importOWP)

    func openOWP(url: URL, skipBackgroundRefresh: Bool = false) async {
        guard !isLoadingProject else { return }

        let previousOWPURL = owpURL
        isLoadingProject = true
        isReconcilingPersistenceState = true
        loadErrorMessage = nil
        owpURL = url
        workingOWPURL = url
        statusMessage = "Opening project..."
        saveIndicator = .idle
        backgroundIndexRefreshTask?.cancel()
        stopExternalFileWatch()
        externalChangeTimes.removeAll()
        isAgentSyncInProgress = false
        hasPendingAgentChanges = false
        showsRecentAgentUpdate = false

        let fm = FileManager.default

        if let previousOWPURL, previousOWPURL != url {
            characters = []
            selectedCharacterID = nil
        }

        defer {
            isLoadingProject = false
            isReconcilingPersistenceState = false
            reevaluatePersistedSaveState()
        }

        do {
            // 1. Load OWP data from disk
            let result = try await ProjectDatabaseBridge.loadAnimateProject(url: url)
            let effectiveProjectURL = result.workingProjectURL
            let hasLocalMirror = fm.fileExists(atPath: effectiveProjectURL.path)
            workingOWPURL = effectiveProjectURL
            owpCharacters = result.characters
            owpIndexFile = result.indexFile
            owpInstrumentMappings = result.instrumentMappings

            // 2. Ensure Animate/ directory exists
            let animateDir = effectiveProjectURL.appendingPathComponent("Animate")
            if hasLocalMirror, !fm.fileExists(atPath: animateDir.path) {
                try fm.createDirectory(at: animateDir, withIntermediateDirectories: true)
            }

            // 3. Load or create animate.json metadata
            animateMetadata = result.animateMetadata ?? AnimateMetadata(
                createdDate: Date(),
                fps: 24,
                resolution: .init(width: 1920, height: 1080)
            )

            fps = animateMetadata?.fps ?? 24

            // Load character package selections from disk
            if let manifest = ProjectDatabaseBridge.loadCharacterPackageSelectionsFromDisk(projectURL: effectiveProjectURL) {
                activePackageIDsByCharacterSlug = manifest.activePackageIDsByCharacterSlug
            } else {
                activePackageIDsByCharacterSlug = characterPackageSelectionStore
                    .load(from: animateDir)
                    .activePackageIDsByCharacterSlug
            }

            // Load shot presets from disk
            if let manifest = ProjectDatabaseBridge.loadShotPresetsFromDisk(projectURL: effectiveProjectURL) {
                shotPresets = sortedShotPresets(manifest.presets)
            } else {
                shotPresets = sortedShotPresets(sceneShotPresetStore.load(from: animateDir).presets)
            }

            hydrateDrawThingsPlacesConfig(
                ProjectDatabaseBridge.loadDrawThingsPlacesConfigFromDisk(projectURL: effectiveProjectURL) ?? .init()
            )

            // 4. Load saved scene data from disk
            let savedScenesBySongPath = result.savedScenes
            NSLog("[Animate] openOWP: %d saved scenes loaded, %d songs discovered",
                  savedScenesBySongPath.count, result.songs.count)

            // 5. Sync scenes with OWP songs
            var newScenes: [AnimationScene] = []
            for song in result.songs {
                if let saved = savedScenesBySongPath[song.owsPath] {
                    // Restore saved animation data for this song
                    newScenes.append(AnimationScene(
                        id: song.id,
                        name: song.title,
                        backgroundID: saved.backgroundID,
                        characterIDs: saved.characterIDs,
                        characterSlugs: saved.characterSlugs,
                        objectSetups: normalizedSceneObjectSetups(saved.objectSetups, tracks: saved.tracks),
                        keyframes: saved.keyframes,
                        owpSongPath: saved.owsSongPath,
                        defaultAudioPath: saved.defaultAudioPath,
                        tracks: saved.tracks,
                        directionTemplate: saved.directionTemplate,
                        automationProfile: saved.automationProfile,
                        shots: normalizedSceneShots(saved.shots)
                    ))
                } else {
                    // New song discovered — create fresh scene
                    newScenes.append(AnimationScene(
                        id: song.id,
                        name: song.title,
                        backgroundID: nil,
                        characterIDs: [],
                        objectSetups: [],
                        keyframes: [],
                        owpSongPath: song.owsPath,
                        shots: []
                    ))
                }
            }
            scenes = newScenes
            selectedSceneID = scenes.first?.id

            let matchedCount = newScenes.filter { !$0.shots.isEmpty }.count
            let totalShots = newScenes.reduce(0) { $0 + $1.shots.count }
            NSLog("[Animate] openOWP: built %d scenes, %d have shots (%d total shots)",
                  newScenes.count, matchedCount, totalShots)
            for scene in newScenes where scene.owpSongPath.contains("1.36") || scene.owpSongPath.contains("1.15") || scene.owpSongPath.contains("2.14") {
                NSLog("[Animate] openOWP:   %@ = %d shots", scene.owpSongPath, scene.shots.count)
            }

            // 6. Sync characters with OWP characters.json
            syncCharactersFromOWP(result.characters)
            let didMigrateCharacterStorage = migrateAllCharacterStorageSlugsIfNeeded()
            refreshInspirationBatchJobs()

            for index in scenes.indices {
                guard let savedScene = savedScenesBySongPath[scenes[index].owpSongPath] else {
                    continue
                }

                if !savedScene.characterSlugs.isEmpty {
                    scenes[index].characterIDs = savedScene.characterSlugs.compactMap { slug in
                        characters.first(where: { $0.owpSlug == slug })?.id
                    }
                }

                if var template = scenes[index].directionTemplate {
                    if template.focusCharacterSlug == nil,
                       let focusCharacterID = template.focusCharacterID,
                       let focusIndex = savedScene.characterIDs.firstIndex(of: focusCharacterID),
                       savedScene.characterSlugs.indices.contains(focusIndex) {
                        template.focusCharacterSlug = savedScene.characterSlugs[focusIndex]
                    }

                    if let focusCharacterSlug = template.focusCharacterSlug {
                        template.focusCharacterID = characters.first(where: {
                            $0.owpSlug == focusCharacterSlug
                        })?.id
                    }

                    scenes[index].directionTemplate = template.isEmpty ? nil : template
                }

                if var automationProfile = scenes[index].automationProfile {
                    automationProfile.sync(with: scenes[index], characters: characters)
                    scenes[index].automationProfile = automationProfile
                }

                scenes[index].shots = normalizedSceneShots(scenes[index].shots)
            }

            // 7. Load backgrounds from Animate/backgrounds/
            let bgDir = animateDir.appendingPathComponent("backgrounds")
            if hasLocalMirror, fm.fileExists(atPath: bgDir.path) {
                backgrounds = try loadPlaces(from: animateDir, backgroundDirectoryURL: bgDir)
            } else {
                backgrounds = []
            }
            placesWorkflowLibrary = hydratedPlacesWorkflowLibrary(loadPlacesWorkflowLibrary(from: animateDir))
            syncGeneratedBackgroundLibrary()
            refreshPlaceWorldGenerationBatches()
            refreshPlaceEditBatchJobs()

            let didRefreshPlaces = await refreshPlacesFromScript(persistChanges: false)

            // 8. Load motion clips
            motionClips = (try? MotionClipPersistence.loadAll(animateURL: animateDir)) ?? []

            let projectName = url.deletingPathExtension().lastPathComponent
            if didMigrateCharacterStorage || didRefreshPlaces {
                save()
            }
            statusMessage = "Opened: \(projectName) (\(scenes.count) songs, \(characters.count) characters)"
            loadErrorMessage = nil
            geminiMasterSwitch = ProjectDatabaseBridge.loadGeminiMasterSwitch(projectURL: effectiveProjectURL) ?? false
            loadImagineGalleries()
            loadCanvasGenerations()
            UserDefaults.standard.set(url.path, forKey: "lastProjectPath")
            markCurrentStateAsSaved()
            if !disableExternalFileWatch {
                recordExternalFileSnapshots()
                startExternalFileWatch()
            }
        } catch {
            loadErrorMessage = error.localizedDescription
            statusMessage = "Error opening project: \(error.localizedDescription)"
        }
    }

    func restoreLastProject() {
        guard let path = UserDefaults.standard.string(forKey: "lastProjectPath") else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Task { await openOWP(url: url) }
    }

    // MARK: - Debounced Save (for text editing — avoids cursor jump from per-keystroke save)

    private var debouncedSaveTask: Task<Void, Never>?

    /// Schedules a save after a short delay. Calling again resets the timer.
    /// Use this for text field/editor bindings to avoid saving (and re-rendering) on every keystroke.
    func scheduleDebouncedSave(writePlaces: Bool = false) {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save(writePlaces: writePlaces)
        }
    }

    // MARK: - Save (writes only to Animate/ subdirectory; places sidecars are explicit-only)

    func save(writePlaces: Bool = false) {
        let saveStart = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(saveStart) * 1000)
            AppLog.log("STORE", "save(writePlaces: \(writePlaces)) — \(characters.count) chars, \(ms) ms")
        }
        let wasSyncingBeforeCheck = isAgentSyncInProgress
        checkForExternalProjectChanges()
        guard !wasSyncingBeforeCheck, !hasPendingAgentChanges else {
            statusMessage = "Detected newer agent changes. Reloading them before saving."
            return
        }
        guard let animateDir = animateURL else { return }
        saveIndicator = .saving

        do {
            let fm = FileManager.default
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            // Ensure Animate/ exists
            try fm.createDirectory(at: animateDir, withIntermediateDirectories: true)

            // Write animate.json
            if let metadata = animateMetadata {
                let data = try encoder.encode(metadata)
                try data.write(to: animateDir.appendingPathComponent("animate.json"))
            }

            // Write scenes.json — convert AnimationScene → AnimateSceneData
            let sceneData: [AnimateSceneData] = scenes.map { scene in
                let characterSlugs = scene.characterIDs.compactMap { characterID in
                    characters.first(where: { $0.id == characterID })?.owpSlug
                }
                let directionTemplate = normalizedDirectionTemplateForPersistence(scene.directionTemplate)
                return AnimateSceneData(
                    owsSongPath: scene.owpSongPath,
                    backgroundID: scene.backgroundID,
                    characterIDs: scene.characterIDs,
                    characterSlugs: characterSlugs,
                    objectSetups: normalizedSceneObjectSetups(scene.objectSetups, tracks: scene.tracks),
                    keyframes: scene.keyframes,
                    defaultAudioPath: scene.defaultAudioPath,
                    tracks: scene.tracks,
                    directionTemplate: directionTemplate,
                    automationProfile: normalizedSceneAutomationProfileForPersistence(scene.automationProfile, scene: scene),
                    shots: normalizedSceneShots(scene.shots)
                )
            }
            let scenesJSON = try encoder.encode(sceneData)
            try scenesJSON.write(to: animateDir.appendingPathComponent("scenes.json"))

            // Save each character state to Animate/characters/{slug}/rig.json
            for character in characters {
                let persisted = persistedCharacter(character)
                let charDir = animateDir
                    .appendingPathComponent("characters")
                    .appendingPathComponent(character.assetFolderSlug)
                try fm.createDirectory(at: charDir, withIntermediateDirectories: true)
                let rigData = try encoder.encode(persistedCharacter(character))
                try rigData.write(to: charDir.appendingPathComponent("rig.json"))
            }

            try characterPackageSelectionStore.save(
                CharacterPackageSelectionManifest(
                    activePackageIDsByCharacterSlug: activePackageIDsByCharacterSlug
                ),
                to: animateDir
            )

            try sceneShotPresetStore.save(
                SceneShotPresetManifest(presets: shotPresets),
                to: animateDir
            )

            let effectiveProjectURL = workingOWPURL ?? owpURL ?? animateDir.deletingLastPathComponent()
            if writePlaces {
                let placesData = try encoder.encode(backgrounds.map(persistedBackgroundPlate))
                try writeProtectedData(placesData, to: animateDir.appendingPathComponent("places.json"))
                let placesWorkflowData = try encoder.encode(persistedPlacesWorkflowLibrary(placesWorkflowLibrary))
                try writeProtectedData(placesWorkflowData, to: animateDir.appendingPathComponent("places-workflow.json"))
                let reviewStateLibrary = rebuiltGeneratedBackgroundReviewStateLibrary(
                    from: placesWorkflowLibrary.generatedImageRecords,
                    existing: self.placesGeneratedReviewStateLibrary
                )
                let normalizedReviewStateLibrary = persistedGeneratedBackgroundReviewStateLibrary(reviewStateLibrary)
                let reviewStateURL = placesGeneratedReviewStateURL(in: animateDir)
                let reviewStateData = try encoder.encode(normalizedReviewStateLibrary)
                try writeProtectedData(reviewStateData, to: reviewStateURL)
                let worldMapCanonLibrary = rebuiltPlacesWorldMapCanonLibrary(
                    from: placesWorkflowLibrary.generatedImageRecords,
                    existing: self.placesWorldMapCanonLibrary
                )
                let normalizedCanonLibrary = persistedPlacesWorldMapCanonLibrary(worldMapCanonLibrary)
                var canonPayload = placesWorldMapCanonRawPayload
                canonPayload["schemaVersion"] = 1
                canonPayload["updatedAt"] = ISO8601DateFormatter().string(from: Date())

                var generatedRecordsPayload: [String: [String: Any]] = [:]
                for override in normalizedCanonLibrary.recordOverrides {
                    guard let key = stableWorldMapCanonKey(for: override.canonicalPath) else { continue }
                    var entry: [String: Any] = [
                        "stablePath": override.canonicalPath,
                        "filenameStem": URL(fileURLWithPath: override.canonicalPath).deletingPathExtension().lastPathComponent,
                        "updatedAt": ISO8601DateFormatter().string(from: override.updatedAt),
                    ]
                    if let fingerprint = trimmedOrNil(override.contentFingerprint) {
                        entry["contentFingerprint"] = fingerprint
                    }
                    if let linkedPlaceID = override.linkedPlaceID {
                        entry["linkedPlaceID"] = linkedPlaceID.uuidString.uppercased()
                    }
                    if let worldNodeID = override.worldNodeID {
                        entry["worldNodeID"] = worldNodeID.uuidString.uppercased()
                    }
                    if let routeID = override.routeID {
                        entry["routeID"] = routeID.uuidString.uppercased()
                    }
                    if let cameraPose = override.cameraPose {
                        entry["cameraPose"] = [
                            "yawDegrees": cameraPose.yawDegrees,
                            "pitchDegrees": cameraPose.pitchDegrees,
                            "rollDegrees": cameraPose.rollDegrees,
                            "focalLengthMM": cameraPose.focalLengthMM,
                            "horizontalFOVDegrees": cameraPose.horizontalFOVDegrees as Any,
                            "verticalFOVDegrees": cameraPose.verticalFOVDegrees as Any,
                        ].compactMapValues { $0 }
                    }
                    if let mapPoint = override.mapPoint?.clamped() {
                        entry["mapPoint"] = ["x": mapPoint.x, "y": mapPoint.y]
                    }
                    if let status = override.mapPlacementStatus?.rawValue {
                        entry["mapPlacementStatus"] = status
                    }
                    if let confirmedAt = override.mapPlacementConfirmedAt {
                        entry["mapPlacementConfirmedAt"] = ISO8601DateFormatter().string(from: confirmedAt)
                    }
                    if let buildingAnchorNodeID = override.buildingAnchorNodeID {
                        entry["buildingAnchorNodeID"] = buildingAnchorNodeID.uuidString.uppercased()
                    }
                    if let orientationState = override.orientationState?.rawValue {
                        entry["orientationState"] = orientationState
                    }
                    generatedRecordsPayload[key] = entry
                    generatedRecordsPayload[stableWorldMapCanonStemKey(for: override.canonicalPath)] = entry
                }
                canonPayload["generatedRecords"] = generatedRecordsPayload
                if canonPayload["placeAnchors"] == nil {
                    canonPayload["placeAnchors"] = [:]
                }
                let worldMapCanonData = try JSONSerialization.data(
                    withJSONObject: canonPayload,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try writeProtectedData(worldMapCanonData, to: placesWorldMapCanonURL(in: animateDir))
                self.placesWorldMapCanonRawPayload = canonPayload
                self.placesWorldMapCanonLibrary = worldMapCanonLibrary
                self.placesGeneratedReviewStateLibrary = reviewStateLibrary
                try ProjectDatabaseBridge.saveDrawThingsPlacesConfigToDisk(
                    drawThingsPlaceConfig,
                    projectURL: effectiveProjectURL
                )
            }
            try? ProjectDatabaseBridge.saveGeminiMasterSwitch(geminiMasterSwitch, projectURL: effectiveProjectURL)
            saveImagineGalleries()

            // Write motion clips
            if !motionClips.isEmpty {
                try MotionClipPersistence.saveAll(motionClips, animateURL: animateDir)
            }

            // Save NLA timelines
            for scene in scenes {
                if let timeline = (scene.id == selectedSceneID ? nlaTimeline : nil) {
                    try NLATimelinePersistence.save(
                        timeline: timeline, animateDir: animateDir, sceneID: scene.id
                    )
                }
            }

            recordExternalFileSnapshots()
            markCurrentStateAsSaved()
        } catch {
            statusMessage = "Save error: \(error.localizedDescription)"
            reevaluatePersistedSaveState()
        }
    }

    // MARK: - Song Data Loading

    /// Load song data from the OWS file for the given scene.
    func loadSongData(for scene: AnimationScene) async {
        guard let owpURL = fileOWPURL else { return }

        do {
            if let songData = await ProjectDatabaseBridge.hydrateSongData(
                projectURL: owpURL,
                relativePath: scene.owpSongPath
            ) {
                currentSongData = songData
            } else {
                currentSongData = nil
            }
        } catch {
            currentSongData = nil
            statusMessage = "Could not load song: \(error.localizedDescription)"
        }
    }

    /// URL for an OWP character's image directory.
    func owpCharacterImageDirectory(for character: OPWCharacter) -> URL? {
        fileOWPURL?.appendingPathComponent("Characters").appendingPathComponent(character.directoryName)
    }

    /// Find the OWP character data that corresponds to an AnimationCharacter.
    func owpCharacter(for animChar: AnimationCharacter) -> OPWCharacter? {
        owpCharacters.first { $0.directoryName == animChar.owpSlug }
    }

    // MARK: - Rig Editing

    func addRigPart(to characterID: UUID, name: String, type: PartType, parentID: UUID?) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }

        let maxZ = characters[index].parts.map(\.zOrder).max() ?? -1
        let part = RigPart(
            name: name,
            partType: type,
            parentID: parentID,
            zOrder: maxZ + 1
        )

        characters[index].parts.append(part)

        // Register as child of parent
        if let parentID,
           let parentIndex = characters[index].parts.firstIndex(where: { $0.id == parentID }) {
            characters[index].parts[parentIndex].children.append(part.id)
        }

        statusMessage = "Added part: \(name)"
    }

    func deleteRigPart(from characterID: UUID, partID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }

        // Remove from parent's children array
        if let part = characters[charIndex].parts.first(where: { $0.id == partID }),
           let parentID = part.parentID,
           let parentIndex = characters[charIndex].parts.firstIndex(where: { $0.id == parentID }) {
            characters[charIndex].parts[parentIndex].children.removeAll { $0 == partID }
        }

        // Re-parent children to this part's parent
        let deletedPart = characters[charIndex].parts.first { $0.id == partID }
        for i in characters[charIndex].parts.indices {
            if characters[charIndex].parts[i].parentID == partID {
                characters[charIndex].parts[i].parentID = deletedPart?.parentID
            }
        }

        characters[charIndex].parts.removeAll { $0.id == partID }
        statusMessage = "Removed part"
    }

    func createDefaultRig(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard characters[index].parts.isEmpty else { return }

        let rootID = UUID()
        let hipsID = UUID()
        let torsoID = UUID()
        let chestID = UUID()
        let neckID = UUID()
        let headID = UUID()

        var parts: [RigPart] = []

        // Build the hierarchy
        parts.append(RigPart(id: rootID, name: "Root", partType: .root, zOrder: 0, children: [hipsID]))
        parts.append(RigPart(id: hipsID, name: "Hips", partType: .hips, parentID: rootID, zOrder: 1, children: [torsoID]))
        parts.append(RigPart(id: torsoID, name: "Torso", partType: .torso, parentID: hipsID, zOrder: 2, children: [chestID]))
        parts.append(RigPart(id: chestID, name: "Chest", partType: .chest, parentID: torsoID, zOrder: 3, children: [neckID]))
        parts.append(RigPart(id: neckID, name: "Neck", partType: .neck, parentID: chestID, zOrder: 4, children: [headID]))
        parts.append(RigPart(id: headID, name: "Head", partType: .head, parentID: neckID, zOrder: 5))

        // Arms
        let shoulderLID = UUID(), shoulderRID = UUID()
        let upperArmLID = UUID(), upperArmRID = UUID()
        let lowerArmLID = UUID(), lowerArmRID = UUID()
        let handLID = UUID(), handRID = UUID()

        parts.append(RigPart(id: shoulderLID, name: "Shoulder L", partType: .shoulderLeft, parentID: chestID, zOrder: 6, children: [upperArmLID]))
        parts.append(RigPart(id: upperArmLID, name: "Upper Arm L", partType: .upperArmLeft, parentID: shoulderLID, zOrder: 7, children: [lowerArmLID]))
        parts.append(RigPart(id: lowerArmLID, name: "Lower Arm L", partType: .lowerArmLeft, parentID: upperArmLID, zOrder: 8, children: [handLID]))
        parts.append(RigPart(id: handLID, name: "Hand L", partType: .handLeft, parentID: lowerArmLID, zOrder: 9))

        parts.append(RigPart(id: shoulderRID, name: "Shoulder R", partType: .shoulderRight, parentID: chestID, zOrder: 10, children: [upperArmRID]))
        parts.append(RigPart(id: upperArmRID, name: "Upper Arm R", partType: .upperArmRight, parentID: shoulderRID, zOrder: 11, children: [lowerArmRID]))
        parts.append(RigPart(id: lowerArmRID, name: "Lower Arm R", partType: .lowerArmRight, parentID: upperArmRID, zOrder: 12, children: [handRID]))
        parts.append(RigPart(id: handRID, name: "Hand R", partType: .handRight, parentID: lowerArmRID, zOrder: 13))

        // Update chest children
        if let chestIdx = parts.firstIndex(where: { $0.id == chestID }) {
            parts[chestIdx].children.append(contentsOf: [shoulderLID, shoulderRID])
        }

        // Legs
        let upperLegLID = UUID(), upperLegRID = UUID()
        let lowerLegLID = UUID(), lowerLegRID = UUID()
        let footLID = UUID(), footRID = UUID()

        parts.append(RigPart(id: upperLegLID, name: "Upper Leg L", partType: .upperLegLeft, parentID: hipsID, zOrder: 14, children: [lowerLegLID]))
        parts.append(RigPart(id: lowerLegLID, name: "Lower Leg L", partType: .lowerLegLeft, parentID: upperLegLID, zOrder: 15, children: [footLID]))
        parts.append(RigPart(id: footLID, name: "Foot L", partType: .footLeft, parentID: lowerLegLID, zOrder: 16))

        parts.append(RigPart(id: upperLegRID, name: "Upper Leg R", partType: .upperLegRight, parentID: hipsID, zOrder: 17, children: [lowerLegRID]))
        parts.append(RigPart(id: lowerLegRID, name: "Lower Leg R", partType: .lowerLegRight, parentID: upperLegRID, zOrder: 18, children: [footRID]))
        parts.append(RigPart(id: footRID, name: "Foot R", partType: .footRight, parentID: lowerLegRID, zOrder: 19))

        // Update hips children
        if let hipsIdx = parts.firstIndex(where: { $0.id == hipsID }) {
            parts[hipsIdx].children.append(contentsOf: [upperLegLID, upperLegRID])
        }

        // Face parts
        let faceID = UUID()
        let mouthID = UUID()
        parts.append(RigPart(id: faceID, name: "Face", partType: .face, parentID: headID, zOrder: 20, children: [mouthID]))
        parts.append(RigPart(id: mouthID, name: "Mouth", partType: .mouth, parentID: faceID, zOrder: 21))

        // Update head children
        if let headIdx = parts.firstIndex(where: { $0.id == headID }) {
            parts[headIdx].children.append(faceID)
        }

        characters[index].parts = parts
        statusMessage = "Created default rig with \(parts.count) parts"
    }

    @discardableResult
    func syncCharacterPackageToRig(
        for characterID: UUID,
        packageID: UUID?
    ) -> CharacterPackageRigSyncReport? {
        guard let animateURL,
              let charIndex = characters.firstIndex(where: { $0.id == characterID })
        else {
            statusMessage = "Open a project before syncing a character package."
            return nil
        }

        let characterSlug = characters[charIndex].assetFolderSlug
        let packages = CharacterPackageLibrary().installedPackages(for: characterSlug, in: animateURL)

        guard !packages.isEmpty else {
            statusMessage = "No imported character packages found for \(characters[charIndex].name)."
            return nil
        }

        let selectedPackage = packageID.flatMap { id in
            packages.first(where: { $0.id == id })
        } ?? packages.first

        guard let selectedPackage else {
            statusMessage = "Could not resolve the selected character package."
            return nil
        }

        var createdDefaultRig = false
        if characters[charIndex].parts.isEmpty {
            createDefaultRig(for: characterID)
            createdDefaultRig = true
        }

        let currentCharacter = characters[charIndex]

        do {
            let result = try CharacterPackageRigSyncService().sync(
                character: currentCharacter,
                package: selectedPackage,
                animateURL: animateURL,
                createdDefaultRig: createdDefaultRig
            )
            characters[charIndex].parts = result.parts
            saveCharacterRig(characterID)

            let missingCount = result.report.missingRigPartTypes.count
            statusMessage = "Synced \(result.report.importedVariants) package drawings from \(result.report.packageDisplayName) (\(missingCount) unmatched part types)."
            return result.report
        } catch {
            statusMessage = "Package sync error: \(error.localizedDescription)"
            return nil
        }
    }

    func importDrawing(for characterID: UUID, partID: UUID, angle: AngleView, from url: URL) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let partIndex = characters[charIndex].parts.firstIndex(where: { $0.id == partID })
        else { return }

        // Copy file into Animate/characters/{slug}/parts/
        if let animateDir = animateURL {
            let character = characters[charIndex]
            let partsDir = animateDir
                .appendingPathComponent("characters")
                .appendingPathComponent(character.assetFolderSlug)
                .appendingPathComponent("parts")

            do {
                try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
                let dest = partsDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                statusMessage = "Failed to save drawing: \(error.localizedDescription)"
            }
        }

        let variant = DrawingVariant(
            name: url.deletingPathExtension().lastPathComponent,
            filename: url.lastPathComponent,
            sourceURL: url
        )

        if characters[charIndex].parts[partIndex].drawingSets[angle] != nil {
            characters[charIndex].parts[partIndex].drawingSets[angle]!.variants.append(variant)
            characters[charIndex].parts[partIndex].drawingSets[angle]!.activeVariantID = variant.id
        } else {
            characters[charIndex].parts[partIndex].drawingSets[angle] = DrawingSet(
                angle: angle,
                activeVariantID: variant.id,
                variants: [variant]
            )
        }

        saveCharacterRig(characterID)
        statusMessage = "Imported drawing: \(variant.name)"
    }

    func saveCharacterRig(_ characterID: UUID) {
        guard let animateDir = animateURL,
              let character = characters.first(where: { $0.id == characterID })
        else { return }

        let charDir = animateDir.appendingPathComponent("characters").appendingPathComponent(character.assetFolderSlug)

        do {
            try FileManager.default.createDirectory(at: charDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persistedCharacter(character))
            try data.write(to: charDir.appendingPathComponent("rig.json"))
            statusMessage = "Saved rig for \(character.name)"
        } catch {
            statusMessage = "Error saving rig: \(error.localizedDescription)"
        }
    }

    func setCharacterRenderMode(_ renderMode: CharacterCanvasRenderMode, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[charIndex].renderMode = renderMode
        saveCharacterRig(characterID)
        statusMessage = "\(characters[charIndex].name) render mode: \(renderMode.displayName)"
    }

    func setCharacterPreferredViewAngle(_ angle: AngleView?, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[charIndex].preferredViewAngle = angle
        saveCharacterRig(characterID)
        if let angle {
            statusMessage = "\(characters[charIndex].name) preferred angle: \(angle.rawValue)"
        } else {
            statusMessage = "\(characters[charIndex].name) preferred angle: automatic"
        }
    }

    func setActiveDrawingVariant(
        for characterID: UUID,
        partID: UUID,
        angle: AngleView,
        variantID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let partIndex = characters[charIndex].parts.firstIndex(where: { $0.id == partID }),
              var drawingSet = characters[charIndex].parts[partIndex].drawingSets[angle],
              drawingSet.variants.contains(where: { $0.id == variantID })
        else {
            return
        }

        drawingSet.activeVariantID = variantID
        characters[charIndex].parts[partIndex].drawingSets[angle] = drawingSet
        saveCharacterRig(characterID)

        if let activeVariant = drawingSet.variants.first(where: { $0.id == variantID }) {
            statusMessage = "Active drawing set to \(activeVariant.name)"
        }
    }

    func activePackageID(for characterSlug: String) -> UUID? {
        activePackageIDsByCharacterSlug[characterSlug]
    }

    func setActivePackage(_ packageID: UUID?, for characterSlug: String) {
        if let packageID {
            activePackageIDsByCharacterSlug[characterSlug] = packageID
        } else {
            activePackageIDsByCharacterSlug.removeValue(forKey: characterSlug)
        }

        persistCharacterPackageSelections()
    }

    // MARK: - Character Profile Management

    func setCharacterProfileImage(_ imagePath: String?, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else {
            statusMessage = "Character not found"
            return
        }
        characters[index].profileImagePath = normalizedCharacterAssetPath(imagePath)
        statusMessage = "Profile image updated"
        save()
    }

    func setCharacterProfileImageFromPicker(for characterID: UUID) {
        guard characters.first(where: { $0.id == characterID }) != nil else {
            statusMessage = "Character not found"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Select Profile Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg]

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.pendingCropImagePath = url.path
                self?.pendingCropCharacterID = characterID
                self?.showImageCropper = true
            }
        }
    }

    func cropAndSetProfileImage(cropRect: CGRect, for characterID: UUID) {
        guard let imagePath = pendingCropImagePath,
              let image = NSImage(contentsOfFile: imagePath),
              let index = characters.firstIndex(where: { $0.id == characterID }) else {
            statusMessage = "No image to crop"
            return
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusMessage = "Failed to get image data"
            return
        }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let cropPixelRect = CGRect(
            x: cropRect.origin.x * pixelWidth,
            y: cropRect.origin.y * pixelHeight,
            width: cropRect.width * pixelWidth,
            height: cropRect.height * pixelHeight
        ).integral

        guard let croppedCGImage = cgImage.cropping(to: cropPixelRect) else {
            statusMessage = "Failed to crop image"
            return
        }

        let croppedImage = NSImage(cgImage: croppedCGImage, size: cropPixelRect.size)

        guard let tiffData = croppedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            statusMessage = "Failed to save cropped image"
            return
        }

        do {
            let storedURL = try assetManager.writeCharacterImageData(
                pngData,
                suggestedFilename: "profile-cropped.png",
                characterSlug: characters[index].assetFolderSlug,
                category: "profile",
                animateURL: try requireAnimateURL()
            )
            invalidateThumbnail(for: characters[index].profileImagePath)
            setCharacterProfileImage(storedURL.path, for: characterID)
            invalidateThumbnail(for: storedURL.path)
            pendingCropImagePath = nil
            pendingCropCharacterID = nil
            showImageCropper = false
        } catch {
            statusMessage = "Failed to save cropped image: \(error.localizedDescription)"
        }
    }

    func cancelImageCrop() {
        pendingCropImagePath = nil
        pendingCropCharacterID = nil
        showImageCropper = false
    }

    /// Prepare a source image for use as a character's profile picture.
    /// Duplicates the image into the character's `profile-staging/` folder,
    /// then arms the image cropper so the next view showing the cropper sheet
    /// will present it. The source file is never modified.
    func prepareProfilePicCrop(from path: String, for characterID: UUID) {
        guard let sourceURL = resolvedCharacterAssetURL(for: path) ?? (URL(fileURLWithPath: path) as URL?),
              FileManager.default.fileExists(atPath: sourceURL.path),
              let animateURL else {
            NSLog("[prepareProfilePicCrop] source not found or no animate URL: \(path)")
            return
        }

        let character = characters.first { $0.id == characterID }
        let slug = character?.assetFolderSlug ?? "unknown"
        let stagingDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("profile-staging")

        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[prepareProfilePicCrop] failed to create staging dir: \(error.localizedDescription)")
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let dupURL = stagingDir.appendingPathComponent("profile_\(timestamp).\(ext)")

        do {
            try FileManager.default.copyItem(at: sourceURL, to: dupURL)
        } catch {
            NSLog("[prepareProfilePicCrop] failed to copy to staging: \(error.localizedDescription)")
            return
        }

        pendingCropImagePath = dupURL.path
        pendingCropCharacterID = characterID
        showImageCropper = true
    }

    // MARK: - Variant Crop

    func openVariantCropTool(
        characterID: UUID,
        slotKey: String,
        variantID: UUID,
        sourceSheetPath: String?,
        initialCropRect: CropRect?
    ) {
        pendingVariantCropCharacterID = characterID
        pendingVariantCropSlotKey = slotKey
        pendingVariantCropVariantID = variantID
        pendingVariantCropSourceSheetPath = sourceSheetPath
        pendingVariantCropInitialRect = initialCropRect
        showVariantCropper = true
    }

    func cancelVariantCrop() {
        pendingVariantCropCharacterID = nil
        pendingVariantCropSlotKey = nil
        pendingVariantCropVariantID = nil
        pendingVariantCropSourceSheetPath = nil
        pendingVariantCropInitialRect = nil
        showVariantCropper = false
    }

    func applyCropToVariant(
        cropRect: CGRect,
        characterID: UUID,
        slotKey: String,
        variantID: UUID,
        sourceSheetPath: String
    ) throws {
        guard let url = resolvedCharacterAssetURL(for: sourceSheetPath),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusMessage = "Cannot load source image for crop"
            return
        }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: cropRect.origin.x * pixelWidth,
            y: cropRect.origin.y * pixelHeight,
            width: cropRect.width * pixelWidth,
            height: cropRect.height * pixelHeight
        ).integral

        guard let croppedCG = cgImage.cropping(to: pixelRect) else {
            statusMessage = "Failed to crop image"
            return
        }

        let croppedImage = NSImage(cgImage: croppedCG, size: pixelRect.size)
        guard let tiffData = croppedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            statusMessage = "Failed to encode cropped image"
            return
        }

        // Find the variant's existing imagePath and overwrite it
        var targetImagePath: String? = nil

        // Search head turnaround slots
        if let charIdx = characters.firstIndex(where: { $0.id == characterID }) {
            for slotIdx in characters[charIdx].headTurnaroundSlots.indices {
                let slot = characters[charIdx].headTurnaroundSlots[slotIdx]
                if slot.key == slotKey,
                   let variantIdx = slot.variants.firstIndex(where: { $0.id == variantID }) {
                    targetImagePath = slot.variants[variantIdx].imagePath
                    if let path = targetImagePath,
                       let existingURL = resolvedCharacterAssetURL(for: path) {
                        try pngData.write(to: existingURL)
                        invalidateThumbnail(for: path)
                    }
                    characters[charIdx].headTurnaroundSlots[slotIdx].variants[variantIdx].sourceCropRect = CropRect.from(cropRect)
                    characters[charIdx].headTurnaroundSlots[slotIdx].variants[variantIdx].sourceSheetPath = sourceSheetPath
                    save()
                    return
                }
            }

            // Search costume full-body slots
            for costumeIdx in characters[charIdx].costumeReferenceSets.indices {
                for slotIdx in characters[charIdx].costumeReferenceSets[costumeIdx].fullBodySlots.indices {
                    let slot = characters[charIdx].costumeReferenceSets[costumeIdx].fullBodySlots[slotIdx]
                    if slot.key == slotKey,
                       let variantIdx = slot.variants.firstIndex(where: { $0.id == variantID }) {
                        targetImagePath = slot.variants[variantIdx].imagePath
                        if let path = targetImagePath,
                           let existingURL = resolvedCharacterAssetURL(for: path) {
                            try pngData.write(to: existingURL)
                            invalidateThumbnail(for: path)
                        }
                        characters[charIdx].costumeReferenceSets[costumeIdx].fullBodySlots[slotIdx].variants[variantIdx].sourceCropRect = CropRect.from(cropRect)
                        characters[charIdx].costumeReferenceSets[costumeIdx].fullBodySlots[slotIdx].variants[variantIdx].sourceSheetPath = sourceSheetPath
                        save()
                        return
                    }
                }
            }
        }

        statusMessage = "Variant not found for crop"
    }

    // MARK: - Character Text Fields

    func addCharacter(named preferredName: String? = nil) {
        guard animateURL != nil else {
            statusMessage = "Open a project before adding a character."
            return
        }

        let baseName = preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? preferredName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "New Character"

        let existingNames = Set(characters.map(\.name))
        let existingSlugs = Set(
            characters.flatMap { character in
                [character.owpSlug, character.assetFolderSlug]
            }
        )

        var candidateName = baseName
        var candidateIndex = 2
        var candidateSlug = CharacterReferenceWorkflowCatalog.slug(from: candidateName)
        if candidateSlug.isEmpty {
            candidateSlug = "character"
        }

        while existingNames.contains(candidateName) || existingSlugs.contains(candidateSlug) {
            candidateName = "\(baseName) \(candidateIndex)"
            candidateSlug = CharacterReferenceWorkflowCatalog.slug(from: candidateName)
            if candidateSlug.isEmpty {
                candidateSlug = "character-\(candidateIndex)"
            }
            candidateIndex += 1
        }

        let character = AnimationCharacter(
            id: UUID(),
            sortOrder: characters.count,
            name: candidateName,
            description: "",
            owpSlug: candidateSlug,
            storageSlug: candidateSlug,
            parts: [],
            lookDevelopmentSlots: CharacterLookDevelopmentCatalog.defaultSlots(for: candidateName),
            masterReferenceSheetPrompt: CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(for: candidateName),
            masterReferenceSourceImagePaths: [],
            masterReferenceSheetVariants: [],
            approvedMasterReferenceSheetVariantID: nil,
            headTurnaroundSheetPrompt: CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(for: candidateName),
            headTurnaroundSheetVariants: [],
            approvedHeadTurnaroundSheetVariantID: nil,
            headTurnaroundSlots: CharacterReferenceWorkflowCatalog.defaultHeadSlots(for: candidateName),
            costumeReferenceSets: CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: candidateName)
        )

        characters.append(character)
        updateCharacterSortOrders()
        selectedCharacterID = character.id
        statusMessage = "Added \(candidateName)"
        save()
    }

    func renameCharacter(_ name: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let oldName = characters[index].name
        guard oldName != trimmedName else { return }

        var updatedCharacter = characters[index]
        updatedCharacter.name = trimmedName
        if let migratedCharacter = migrateCharacterStorageSlugIfNeeded(updatedCharacter, at: index) {
            updatedCharacter = migratedCharacter
        }

        characters[index] = updatedCharacter
        renameCharacterTracks(characterID: characterID, oldName: oldName, newName: trimmedName)
        save()
    }

    func updateCharacterBackstory(_ text: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              characters[index].backstory != text else { return }
        characters[index].backstory = text
        scheduleDebouncedSave()
    }

    private func migrateCharacterStorageSlugIfNeeded(
        _ character: AnimationCharacter,
        at index: Int
    ) -> AnimationCharacter? {
        let oldSlug = character.assetFolderSlug
        let candidateSlug = normalizedStorageSlug(forName: character.name, fallback: oldSlug)
        let reservedSlugs = Set(
            characters.enumerated().compactMap { offset, item in
                offset == index ? nil : item.assetFolderSlug
            }
        )
        let newSlug = uniqueCharacterSlug(startingWith: candidateSlug, reserved: reservedSlugs)
        guard newSlug != oldSlug else { return nil }

        var updated = character
        updated.storageSlug = newSlug
        updated = rewrittenCharacterPaths(in: updated, fromSlug: oldSlug, toSlug: newSlug)
        migrateCharacterDirectoryIfNeeded(fromSlug: oldSlug, toSlug: newSlug)
        return updated
    }

    private func uniqueCharacterSlug(startingWith base: String, reserved: Set<String>) -> String {
        guard reserved.contains(base) else { return base }
        var suffix = 2
        while reserved.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private func migrateCharacterDirectoryIfNeeded(fromSlug oldSlug: String, toSlug newSlug: String) {
        guard let animateDir = animateURL else { return }
        let fileManager = FileManager.default
        let oldDirectory = animateDir.appendingPathComponent("characters").appendingPathComponent(oldSlug)
        let newDirectory = animateDir.appendingPathComponent("characters").appendingPathComponent(newSlug)
        guard fileManager.fileExists(atPath: oldDirectory.path),
              !fileManager.fileExists(atPath: newDirectory.path) else {
            return
        }

        do {
            try fileManager.moveItem(at: oldDirectory, to: newDirectory)
        } catch {
            statusMessage = "Renamed character, but could not rename the Animate folder: \(error.localizedDescription)"
        }
    }

    private func rewrittenCharacterPaths(
        in character: AnimationCharacter,
        fromSlug oldSlug: String,
        toSlug newSlug: String
    ) -> AnimationCharacter {
        var updated = character
        updated.profileImagePath = rewrittenCharacterAssetPath(updated.profileImagePath, fromSlug: oldSlug, toSlug: newSlug)
        updated.inspirationImagePaths = updated.inspirationImagePaths.map { rewrittenCharacterAssetPath($0, fromSlug: oldSlug, toSlug: newSlug) ?? $0 }
        updated.curatedInspirationImagePaths = updated.curatedInspirationImagePaths.map { rewrittenCharacterAssetPath($0, fromSlug: oldSlug, toSlug: newSlug) ?? $0 }
        updated.inspirationReferenceImagePath = rewrittenCharacterAssetPath(updated.inspirationReferenceImagePath, fromSlug: oldSlug, toSlug: newSlug)
        updated.inspirationBatchJobs = updated.inspirationBatchJobs.map { job in
            var rewritten = job
            rewritten.metadataPath = rewrittenCharacterAssetPath(job.metadataPath, fromSlug: oldSlug, toSlug: newSlug) ?? job.metadataPath
            rewritten.outputRootPath = rewrittenCharacterAssetPath(job.outputRootPath, fromSlug: oldSlug, toSlug: newSlug) ?? job.outputRootPath
            rewritten.downloadedImagePaths = job.downloadedImagePaths.map { rewrittenCharacterAssetPath($0, fromSlug: oldSlug, toSlug: newSlug) ?? $0 }
            rewritten.autoImportedImagePaths = job.autoImportedImagePaths.map { rewrittenCharacterAssetPath($0, fromSlug: oldSlug, toSlug: newSlug) ?? $0 }
            return rewritten
        }
        updated.referenceImagePaths = updated.referenceImagePaths.map { rewrittenCharacterAssetPath($0, fromSlug: oldSlug, toSlug: newSlug) ?? $0 }
        updated.animatedImagePaths = updated.animatedImagePaths.map { rewrittenCharacterAssetPath($0, fromSlug: oldSlug, toSlug: newSlug) ?? $0 }
        updated.masterReferenceSourceImagePaths = updated.masterReferenceSourceImagePaths.map { rewrittenCharacterAssetPath($0, fromSlug: oldSlug, toSlug: newSlug) ?? $0 }
        updated.lookDevelopmentSlots = updated.lookDevelopmentSlots.map { slot in
            var rewritten = slot
            rewritten.variants = slot.variants.map { variant in
                var v = variant
                v.imagePath = rewrittenCharacterAssetPath(variant.imagePath, fromSlug: oldSlug, toSlug: newSlug) ?? variant.imagePath
                return v
            }
            return rewritten
        }
        updated.masterReferenceSheetVariants = updated.masterReferenceSheetVariants.map { variant in
            var rewritten = variant
            rewritten.imagePath = rewrittenCharacterAssetPath(variant.imagePath, fromSlug: oldSlug, toSlug: newSlug) ?? variant.imagePath
            return rewritten
        }
        updated.headTurnaroundSheetVariants = updated.headTurnaroundSheetVariants.map { variant in
            var rewritten = variant
            rewritten.imagePath = rewrittenCharacterAssetPath(variant.imagePath, fromSlug: oldSlug, toSlug: newSlug) ?? variant.imagePath
            return rewritten
        }
        updated.headTurnaroundSlots = updated.headTurnaroundSlots.map { slot in
            var rewritten = slot
            rewritten.variants = slot.variants.map { variant in
                var v = variant
                v.imagePath = rewrittenCharacterAssetPath(variant.imagePath, fromSlug: oldSlug, toSlug: newSlug) ?? variant.imagePath
                return v
            }
            return rewritten
        }
        updated.costumeReferenceSets = updated.costumeReferenceSets.map { set in
            var rewritten = set
            rewritten.sheetVariants = set.sheetVariants.map { variant in
                var v = variant
                v.imagePath = rewrittenCharacterAssetPath(variant.imagePath, fromSlug: oldSlug, toSlug: newSlug) ?? variant.imagePath
                return v
            }
            rewritten.fullBodySlots = set.fullBodySlots.map { slot in
                var slotCopy = slot
                slotCopy.variants = slot.variants.map { variant in
                    var v = variant
                    v.imagePath = rewrittenCharacterAssetPath(variant.imagePath, fromSlug: oldSlug, toSlug: newSlug) ?? variant.imagePath
                    return v
                }
                return slotCopy
            }
            rewritten.accessorySlots = set.accessorySlots.map { slot in
                var slotCopy = slot
                slotCopy.variants = slot.variants.map { variant in
                    var v = variant
                    v.imagePath = rewrittenCharacterAssetPath(variant.imagePath, fromSlug: oldSlug, toSlug: newSlug) ?? variant.imagePath
                    return v
                }
                return slotCopy
            }
            return rewritten
        }
        return updated
    }

    private func rewrittenCharacterAssetPath(
        _ path: String?,
        fromSlug oldSlug: String,
        toSlug newSlug: String
    ) -> String? {
        guard let path else { return nil }
        let relativePrefix = "Animate/characters/\(oldSlug)/"
        let relativeReplacement = "Animate/characters/\(newSlug)/"
        if path.hasPrefix(relativePrefix) {
            return relativeReplacement + path.dropFirst(relativePrefix.count)
        }

        if let animateDir = animateURL {
            let oldAbsolutePrefix = animateDir
                .appendingPathComponent("characters")
                .appendingPathComponent(oldSlug)
                .path + "/"
            if path.hasPrefix(oldAbsolutePrefix) {
                let newAbsolutePrefix = animateDir
                    .appendingPathComponent("characters")
                    .appendingPathComponent(newSlug)
                    .path + "/"
                return newAbsolutePrefix + path.dropFirst(oldAbsolutePrefix.count)
            }
        }

        return path
    }

    func updateCharacterPersonality(_ text: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              characters[index].personality != text else { return }
        characters[index].personality = text
        scheduleDebouncedSave()
    }

    func updateCharacterNotes(_ text: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              characters[index].notes != text else { return }
        characters[index].notes = text
        scheduleDebouncedSave()
    }

    func updateCharacterDefaultWardrobeType(_ wardrobeType: CharacterWardrobeType, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].defaultWardrobeType = wardrobeType
        save()
    }

    func updateCharacterGenderType(_ genderType: CharacterGenderType, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].genderType = genderType
        save()
    }

    func updateCharacterAge(_ age: Int?, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].age = age
        save()
    }

    func setCharacterActiveLORA(
        filename: String?,
        triggerWord: String?,
        weight: Double? = nil,
        for characterID: UUID
    ) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let normalizedFilename = trimmedOrNil(filename)
        characters[index].activeLORAFilename = normalizedFilename
        characters[index].activeLORATriggerWord = normalizedFilename == nil
            ? nil
            : trimmedOrNil(triggerWord)
        if let weight {
            characters[index].activeLORAWeight = max(0.05, weight)
        } else if characters[index].activeLORAWeight <= 0 {
            characters[index].activeLORAWeight = 1.0
        }
        save()
    }

    func updateCharacterActiveLORATriggerWord(_ triggerWord: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              characters[index].activeLORAFilename != nil else { return }
        characters[index].activeLORATriggerWord = trimmedOrNil(triggerWord)
        save()
    }

    func updateCharacterActiveLORAWeight(_ weight: Double, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              characters[index].activeLORAFilename != nil else { return }
        characters[index].activeLORAWeight = max(0.05, weight)
        save()
    }

    func characterLoRADirectoryURL(
        for characterID: UUID,
        createIfNeeded: Bool = false
    ) -> URL? {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              let animateURL else {
            return nil
        }

        let directory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(characters[index].assetFolderSlug)
            .appendingPathComponent("lora")

        if createIfNeeded {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                statusMessage = "Failed to create LoRA folder"
                return nil
            }
        }

        return directory
    }

    func importCharacterLoRA(
        from sourceURL: URL,
        for characterID: UUID
    ) throws -> URL {
        guard let destinationDirectory = characterLoRADirectoryURL(
            for: characterID,
            createIfNeeded: true
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "safetensors" else {
            throw CocoaError(.fileReadUnknown)
        }

        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let fileManager = FileManager.default

        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return destinationURL
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    // MARK: - Inspiration Images

    func addInspirationImage(_ imagePath: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard let normalizedPath = projectRelativeCharacterAssetPath(from: imagePath)
                ?? normalizedCharacterAssetPath(imagePath)
                ?? (FileManager.default.fileExists(atPath: imagePath) ? imagePath : nil)
        else {
            statusMessage = "Image file not found: \(URL(fileURLWithPath: imagePath).lastPathComponent)"
            return
        }
        guard characterAssetExists(at: normalizedPath) || FileManager.default.fileExists(atPath: imagePath) else {
            statusMessage = "Image file not found: \(URL(fileURLWithPath: imagePath).lastPathComponent)"
            return
        }
        guard !characters[index].inspirationImagePaths.contains(normalizedPath) else {
            statusMessage = "Image already added"
            return
        }
        var updatedCharacter = characters[index]
        updatedCharacter.inspirationImagePaths.append(normalizedPath)
        characters[index] = updatedCharacter
        save()
    }

    func removeInspirationImage(at indexToRemove: Int, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard characters[charIndex].inspirationImagePaths.indices.contains(indexToRemove) else { return }
        let removedPath = characters[charIndex].inspirationImagePaths[indexToRemove]
        characters[charIndex].inspirationImagePaths.remove(at: indexToRemove)
        if characters[charIndex].inspirationReferenceImagePath == removedPath {
            characters[charIndex].inspirationReferenceImagePath = nil
        }
        characters[charIndex].curatedInspirationImagePaths.removeAll(where: { $0 == removedPath })
        save()
    }

    func removeInspirationImages(at indices: IndexSet, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let removedPaths = Set(indices.compactMap { characters[charIndex].inspirationImagePaths.indices.contains($0) ? characters[charIndex].inspirationImagePaths[$0] : nil })
        characters[charIndex].inspirationImagePaths.remove(atOffsets: indices)
        if let refPath = characters[charIndex].inspirationReferenceImagePath, removedPaths.contains(refPath) {
            characters[charIndex].inspirationReferenceImagePath = nil
        }
        characters[charIndex].curatedInspirationImagePaths.removeAll(where: { removedPaths.contains($0) })
        save()
    }

    /// Mark an inspiration image as reviewed so the "new" green dot in the
    /// gallery goes away. Idempotent.
    func markInspirationImageReviewed(path: String, for characterID: UUID) {
        guard let idx = characters.firstIndex(where: { $0.id == characterID }) else { return }
        if characters[idx].reviewedInspirationImagePaths.contains(path) { return }
        characters[idx].reviewedInspirationImagePaths.insert(path)
        save()
    }

    /// Mark EVERY inspiration image on a character as reviewed at once.
    /// Useful for a "Mark all reviewed" bulk action.
    func markAllInspirationImagesReviewed(for characterID: UUID) {
        guard let idx = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let all = Set(characters[idx].inspirationImagePaths)
        if characters[idx].reviewedInspirationImagePaths == all { return }
        characters[idx].reviewedInspirationImagePaths = all
        save()
    }

    /// Remove an inspiration image by path and move the underlying file to the
    /// macOS Trash. Used by right-click Delete in the Imagine gallery.
    /// Returns `true` on success. If the file is missing, still removes the
    /// path from the character's lists and returns `true`.
    @discardableResult
    func deleteInspirationImageToTrash(path: String, for characterID: UUID) -> Bool {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return false }
        // Resolve the on-disk location before mutating state in case something
        // downstream needs it (e.g. subsequent undo plumbing).
        let absoluteURL = resolvedCharacterAssetURL(for: path)

        // Scrub the path from every list it might appear in.
        characters[charIndex].inspirationImagePaths.removeAll(where: { $0 == path })
        if characters[charIndex].inspirationReferenceImagePath == path {
            characters[charIndex].inspirationReferenceImagePath = nil
        }
        characters[charIndex].curatedInspirationImagePaths.removeAll(where: { $0 == path })
        save()

        // Move the underlying file to Trash. If it's already gone, that's fine.
        if let url = absoluteURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                var resultingURL: NSURL? = nil
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                print("[AnimateStore] trashItem failed for \(url.path): \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    func toggleCuratedInspirationImage(_ path: String, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        if let index = characters[charIndex].curatedInspirationImagePaths.firstIndex(of: path) {
            characters[charIndex].curatedInspirationImagePaths.remove(at: index)
        } else {
            characters[charIndex].curatedInspirationImagePaths.append(path)
        }
        save()
    }

    func importInspirationImages(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Inspiration Images"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg]

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                guard let index = self.characters.firstIndex(where: { $0.id == characterID }) else { return }
                let slug = self.characters[index].assetFolderSlug
                let animateURL = self.animateURL
                var importedCount = 0
                for url in panel.urls {
                    do {
                        guard let animateURL else { continue }
                        let storedURL = try self.assetManager.importCharacterImageURL(
                            from: url,
                            characterSlug: slug,
                            category: "inspiration",
                            animateURL: animateURL
                        )
                        self.addInspirationImage(storedURL.path, for: characterID)
                        importedCount += 1
                    } catch {
                        self.statusMessage = "Failed to import inspiration image: \(url.lastPathComponent)"
                    }
                }
                if importedCount > 0 {
                    self.statusMessage = "Imported \(importedCount) inspiration images"
                }
            }
        }
    }

    func importInspirationImages(from urls: [URL], for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              let animateURL else { return }
        let slug = characters[index].assetFolderSlug
        var importedCount = 0
        for url in urls {
            do {
                let storedURL = try assetManager.importCharacterImageURL(
                    from: url,
                    characterSlug: slug,
                    category: "inspiration",
                    animateURL: animateURL
                )
                addInspirationImage(storedURL.path, for: characterID)
                importedCount += 1
            } catch {
                statusMessage = "Failed to import inspiration image: \(url.lastPathComponent)"
            }
        }
        if importedCount > 0 {
            statusMessage = "Imported \(importedCount) inspiration image\(importedCount == 1 ? "" : "s")"
        }
    }

    @discardableResult
    func storeGeneratedInspirationImage(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        filenameStem: String,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String,
        recommendedLORACaption: String? = nil,
        autoSelectForLoRA: Bool = false
    ) throws -> String {
        let animateURL = try requireAnimateURL()
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return "" }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let filename = "\(filenameStem)-\(timestamp).png"
        let storedURL = try assetManager.writeCharacterImageData(
            data,
            suggestedFilename: filename,
            characterSlug: characters[charIndex].assetFolderSlug,
            category: "inspiration",
            animateURL: animateURL
        )

        try writeGenerationMetadata(
            prompt: prompt,
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            recommendedLORACaption: recommendedLORACaption,
            to: storedURL
        )
        let storedPath = projectRelativeCharacterAssetPath(from: storedURL.path)
            ?? normalizedCharacterAssetPath(storedURL.path)
            ?? storedURL.path
        guard !characters[charIndex].inspirationImagePaths.contains(storedPath) else { return storedPath }
        var updatedCharacter = characters[charIndex]
        updatedCharacter.inspirationImagePaths.append(storedPath)
        characters[charIndex] = updatedCharacter
        save()
        if autoSelectForLoRA {
            markInspirationImagesForLORATraining([storedPath], for: characterID)
        }
        return storedPath
    }

    func storeGeneratedPlaceImage(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        filenameStem: String,
        for placeID: UUID,
        workflow: PlaceWorkflowMode,
        aspectRatio: String,
        imageSize: String,
        routeID: UUID? = nil,
        worldNodeID: UUID? = nil,
        mapPoint: WorldMapPoint? = nil,
        cameraPose: WorldCameraPose? = nil
    ) throws -> String {
        let animateURL = try requireAnimateURL()
        guard let placeIndex = backgrounds.firstIndex(where: { $0.id == placeID }) else { return "" }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let filename = "\(filenameStem)-\(timestamp).png"
        let placeSlug = PlacesScriptIndexService.fileStem(for: backgrounds[placeIndex].name)
        let category = workflow == .photorealistic ? "photoreal" : "animated"
        let directory = animateURL
            .appendingPathComponent("backgrounds")
            .appendingPathComponent("places")
            .appendingPathComponent(placeSlug)
            .appendingPathComponent(category)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storedURL = directory.appendingPathComponent(filename)
        try data.write(to: storedURL)

        try writeGenerationMetadata(
            prompt: prompt,
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            placeID: placeID,
            routeID: routeID,
            worldNodeID: worldNodeID,
            mapPoint: mapPoint,
            cameraPose: cameraPose,
            to: storedURL
        )

        let storedPath = projectRelativeCharacterAssetPath(from: storedURL.path)
            ?? normalizedCharacterAssetPath(storedURL.path)
            ?? storedURL.path
        appendPlaceImagePath(storedPath, to: &backgrounds[placeIndex], workflow: workflow)
        syncGeneratedBackgroundLibrary()
        if let recordID = generatedBackgroundRecord(for: storedPath)?.id {
            attachGeneratedBackgroundRecord(
                recordID,
                toWorldNodeID: worldNodeID,
                routeID: routeID,
                placeID: placeID,
                pose: cameraPose,
                mapPoint: mapPoint,
                canonStatus: .candidate
            )
        }
        save(writePlaces: true)
        return storedPath
    }

    func registerInspirationBatchJob(_ job: CharacterInspirationBatchJob, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let normalizedMetadataPath = normalizedCharacterAssetPath(job.metadataPath) ?? job.metadataPath
        let dismissedKeys = dismissedInspirationBatchJobKeys(for: characters[charIndex])
        let candidateKey = inspirationBatchJobKey(
            CharacterInspirationBatchJob(
                kind: job.kind,
                title: job.title,
                batchName: job.batchName,
                metadataPath: normalizedMetadataPath,
                outputRootPath: job.outputRootPath,
                state: job.state,
                promptCount: job.promptCount,
                submittedAt: job.submittedAt
            )
        )
        guard !dismissedKeys.contains(candidateKey) else { return }
        guard !characters[charIndex].inspirationBatchJobs.contains(where: { $0.metadataPath == normalizedMetadataPath || $0.batchName == job.batchName }) else {
            return
        }

        var updatedJob = job
        updatedJob.metadataPath = normalizedMetadataPath
        updatedJob.outputRootPath = normalizedCharacterAssetPath(job.outputRootPath) ?? job.outputRootPath
        characters[charIndex].inspirationBatchJobs.append(updatedJob)
        save()
    }

    func removeInspirationBatchJob(_ jobID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[charIndex].inspirationBatchJobs.removeAll(where: { $0.id == jobID })
        save()
    }

    func dismissInspirationBatchJob(_ job: CharacterInspirationBatchJob, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let key = inspirationBatchJobKey(job)
        var dismissedKeys = dismissedInspirationBatchJobKeys(for: characters[charIndex])
        dismissedKeys.insert(key)
        persistDismissedInspirationBatchJobKeys(dismissedKeys, for: characters[charIndex])
        characters[charIndex].inspirationBatchJobs.removeAll { inspirationBatchJobKey($0) == key }
        save()
    }

    func refreshInspirationBatchJobs() {
        var didChange = false

        for charIndex in characters.indices {
            let dismissedKeys = dismissedInspirationBatchJobKeys(for: characters[charIndex])
            var jobs = mergeInspirationBatchJobs(
                existing: normalizedInspirationBatchJobs(characters[charIndex].inspirationBatchJobs),
                discovered: discoveredInspirationBatchJobsOnDisk(for: characters[charIndex])
            )
            if !dismissedKeys.isEmpty {
                jobs.removeAll { dismissedKeys.contains(inspirationBatchJobKey($0)) }
            }
            if characters[charIndex].inspirationBatchJobs != jobs {
                didChange = true
            }
            guard !jobs.isEmpty else { continue }

            for jobIndex in jobs.indices {
                guard let metadataURL = resolvedCharacterAssetURL(for: jobs[jobIndex].metadataPath)
                    ?? (jobs[jobIndex].metadataPath.hasPrefix("/") ? URL(fileURLWithPath: jobs[jobIndex].metadataPath) : nil),
                      let data = try? Data(contentsOf: metadataURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let latestStatus = json["latest_status"] as? [String: Any]
                let state = (latestStatus?["state"] as? String)
                    ?? (json["batch_state"] as? String)
                    ?? jobs[jobIndex].state
                if jobs[jobIndex].state != state {
                    jobs[jobIndex].state = state
                    didChange = true
                }

                jobs[jobIndex].lastCheckedAt = Date()

                let remoteUpdatedAt = batchStatusDate(latestStatus?["update_time"])
                if jobs[jobIndex].remoteUpdatedAt != remoteUpdatedAt {
                    jobs[jobIndex].remoteUpdatedAt = remoteUpdatedAt
                    didChange = true
                }

                let remoteStartedAt = batchStatusDate(latestStatus?["start_time"])
                if jobs[jobIndex].remoteStartedAt != remoteStartedAt {
                    jobs[jobIndex].remoteStartedAt = remoteStartedAt
                    didChange = true
                }

                let remoteFinishedAt = batchStatusDate(latestStatus?["end_time"])
                if jobs[jobIndex].remoteFinishedAt != remoteFinishedAt {
                    jobs[jobIndex].remoteFinishedAt = remoteFinishedAt
                    didChange = true
                }

                let remoteSuccessfulCount = ((latestStatus?["completion_stats"] as? [String: Any])?["successful_count"] as? Int)
                if jobs[jobIndex].remoteSuccessfulCount != remoteSuccessfulCount {
                    jobs[jobIndex].remoteSuccessfulCount = remoteSuccessfulCount
                    didChange = true
                }

                if let error = latestStatus?["error"] as? [String: Any] {
                    let message = (error["message"] as? String)
                        ?? (error["details"] as? String)
                    if jobs[jobIndex].lastErrorMessage != message {
                        jobs[jobIndex].lastErrorMessage = message
                        didChange = true
                    }
                }

                let decodedPaths = (latestStatus?["decoded_images"] as? [String] ?? [])
                    .compactMap { normalizedCharacterAssetPath($0) ?? $0 }
                if jobs[jobIndex].downloadedImagePaths != decodedPaths {
                    jobs[jobIndex].downloadedImagePaths = normalizedCharacterAssetPaths(decodedPaths)
                    didChange = true
                }

                for path in jobs[jobIndex].downloadedImagePaths {
                    guard characterAssetExists(at: path) else { continue }
                    // Only auto-import paths that haven't been imported before.
                    // Once a path is in autoImportedImagePaths, the user may have
                    // deliberately removed it — don't re-add it.
                    guard !jobs[jobIndex].autoImportedImagePaths.contains(path) else { continue }
                    jobs[jobIndex].autoImportedImagePaths.append(path)
                    didChange = true
                    if !characters[charIndex].inspirationImagePaths.contains(path) {
                        characters[charIndex].inspirationImagePaths.append(path)
                    }
                    if jobs[jobIndex].kind.autoSelectForLoRA {
                        markInspirationImagesForLORATraining([path], for: characters[charIndex].id)
                    }
                }
            }

            characters[charIndex].inspirationBatchJobs = jobs
        }

        if didChange {
            save()
        }
    }

    private func batchStatusDate(_ rawValue: Any?) -> Date? {
        guard let string = rawValue as? String,
              !string.isEmpty
        else {
            return nil
        }

        if let date = batchStatusFractionalDateFormatter.date(from: string) {
            return date
        }
        return batchStatusDateFormatter.date(from: string)
    }

    private var batchStatusFractionalDateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private var batchStatusDateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    // MARK: - Inspiration Reference Image

    func setInspirationReferenceImage(_ imagePath: String?, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].inspirationReferenceImagePath = normalizedCharacterAssetPath(imagePath)
        save()
    }

    func markInspirationImagesForLORATraining(_ paths: [String], for characterID: UUID) {
        guard let animateURL,
              let character = characters.first(where: { $0.id == characterID }) else { return }

        let normalizedPaths = normalizedCharacterAssetPaths(paths)
        guard !normalizedPaths.isEmpty else { return }

        var state = ImagineGallerySelectionState.load(
            animateURL: animateURL,
            characterSlug: character.assetFolderSlug
        )

        var changed = false
        for path in normalizedPaths {
            if state.loraSelectedPaths.insert(path).inserted {
                changed = true
            }
            if state.hiddenPaths.remove(path) != nil {
                changed = true
            }
        }

        if changed {
            state.save(animateURL: animateURL, characterSlug: character.assetFolderSlug)
        }
    }

    func setInspirationReferenceImageFromPicker(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }

        let panel = NSOpenPanel()
        panel.title = "Select Inspiration Reference Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg]

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, let animateURL = self.animateURL else { return }
                do {
                    let storedURL = try self.assetManager.importCharacterImageURL(
                        from: url,
                        characterSlug: self.characters[index].assetFolderSlug,
                        category: "reference",
                        animateURL: animateURL
                    )
                    self.setInspirationReferenceImage(storedURL.path, for: characterID)
                } catch {
                    self.statusMessage = "Failed to import reference image"
                }
            }
        }
    }

    func setInspirationReferenceImage(from sourceURL: URL, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              let animateURL else { return }
        do {
            let storedURL = try assetManager.importCharacterImageURL(
                from: sourceURL,
                characterSlug: characters[index].assetFolderSlug,
                category: "reference",
                animateURL: animateURL
            )
            setInspirationReferenceImage(storedURL.path, for: characterID)
            statusMessage = "Updated main reference image"
        } catch {
            statusMessage = "Failed to import reference image"
        }
    }

    // MARK: - Reference Images Gallery

    func addReferenceImage(_ imagePath: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard let normalizedPath = normalizedCharacterAssetPath(imagePath),
              characterAssetExists(at: normalizedPath) else {
            statusMessage = "Image file not found: \(URL(fileURLWithPath: imagePath).lastPathComponent)"
            return
        }
        guard !characters[index].referenceImagePaths.contains(normalizedPath) else {
            statusMessage = "Image already added"
            return
        }
        characters[index].referenceImagePaths.append(normalizedPath)
        save()
    }

    func removeReferenceImage(at indexToRemove: Int, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard characters[charIndex].referenceImagePaths.indices.contains(indexToRemove) else { return }
        characters[charIndex].referenceImagePaths.remove(at: indexToRemove)
        save()
    }

    func importReferenceImages(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Reference Images"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg]

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self, let animateURL = self.animateURL else { return }
                guard let index = self.characters.firstIndex(where: { $0.id == characterID }) else { return }
                let slug = self.characters[index].assetFolderSlug
                for url in panel.urls {
                    do {
                        let storedURL = try self.assetManager.importCharacterImageURL(
                            from: url,
                            characterSlug: slug,
                            category: "reference",
                            animateURL: animateURL
                        )
                        self.addReferenceImage(storedURL.path, for: characterID)
                    } catch {
                        self.statusMessage = "Failed to import image: \(url.lastPathComponent)"
                    }
                }
            }
        }
    }

    func importReferenceImages(from urls: [URL], for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              let animateURL else { return }
        for url in urls {
            do {
                let storedURL = try assetManager.importCharacterImageURL(
                    from: url,
                    characterSlug: characters[index].assetFolderSlug,
                    category: "reference",
                    animateURL: animateURL
                )
                addReferenceImage(storedURL.path, for: characterID)
            } catch {
                statusMessage = "Failed to import image: \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Character Ordering

    func moveCharacter(from source: IndexSet, to destination: Int) {
        characters.move(fromOffsets: source, toOffset: destination)
        updateCharacterSortOrders()
        save()
    }

    func moveCharacterToEnd(characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let character = characters.remove(at: index)
        characters.append(character)
        updateCharacterSortOrders()
        save()
    }

    // MARK: - Animated Images

    func addAnimatedImage(_ imagePath: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard let normalizedPath = normalizedCharacterAssetPath(imagePath),
              characterAssetExists(at: normalizedPath) else {
            statusMessage = "Image file not found: \(URL(fileURLWithPath: imagePath).lastPathComponent)"
            return
        }
        guard !characters[index].animatedImagePaths.contains(normalizedPath) else {
            statusMessage = "Image already added"
            return
        }
        characters[index].animatedImagePaths.append(normalizedPath)
        save()
    }

    func removeAnimatedImage(at indexToRemove: Int, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard characters[charIndex].animatedImagePaths.indices.contains(indexToRemove) else { return }
        characters[charIndex].animatedImagePaths.remove(at: indexToRemove)
        save()
    }

    func removeAnimatedImages(at indices: IndexSet, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[charIndex].animatedImagePaths.remove(atOffsets: indices)
        save()
    }

    func importAnimatedImages(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Animated Character Images"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg]

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                let slug = self.characters[index].assetFolderSlug
                let animateURL = self.animateURL
                var importedCount = 0
                for url in panel.urls {
                    do {
                        guard let animateURL else { continue }
                        let storedURL = try self.assetManager.importCharacterImageURL(
                            from: url,
                            characterSlug: slug,
                            category: "animated",
                            animateURL: animateURL
                        )
                        self.addAnimatedImage(storedURL.path, for: characterID)
                        importedCount += 1
                    } catch {
                        self.statusMessage = "Failed to import animated image: \(url.lastPathComponent)"
                    }
                }
                if importedCount > 0 {
                    self.statusMessage = "Imported \(importedCount) animated images"
                }
            }
        }
    }

    func importAnimatedImages(from urls: [URL], for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              let animateURL else { return }
        let slug = characters[index].assetFolderSlug
        var importedCount = 0
        for url in urls {
            do {
                let storedURL = try assetManager.importCharacterImageURL(
                    from: url,
                    characterSlug: slug,
                    category: "animated",
                    animateURL: animateURL
                )
                addAnimatedImage(storedURL.path, for: characterID)
                importedCount += 1
            } catch {
                statusMessage = "Failed to import animated image: \(url.lastPathComponent)"
            }
        }
        if importedCount > 0 {
            statusMessage = "Imported \(importedCount) animated image\(importedCount == 1 ? "" : "s")"
        }
    }

    // MARK: - Character Reference Workflow

    func seedCharacterReferenceWorkflowIfNeeded(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }

        var didMutate = false

        if characters[index].masterReferenceSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[index].masterReferenceSheetPrompt = CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(
                for: characters[index].name
            )
            didMutate = true
        }

        if characters[index].masterReferenceSourceImagePaths.isEmpty {
            characters[index].masterReferenceSourceImagePaths = defaultMasterReferenceSourcePaths(for: characters[index])
            didMutate = true
        }

        if characters[index].headTurnaroundSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[index].headTurnaroundSheetPrompt = CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(
                for: characters[index].name
            )
            didMutate = true
        }

        if characters[index].headTurnaroundSlots.isEmpty {
            characters[index].headTurnaroundSlots = CharacterReferenceWorkflowCatalog.defaultHeadSlots(
                for: characters[index].name
            )
            didMutate = true
        }

        if characters[index].costumeReferenceSets.isEmpty {
            characters[index].costumeReferenceSets = CharacterReferenceWorkflowCatalog.defaultCostumeSets(
                for: characters[index].name
            )
            didMutate = true
        }

        for costumeIndex in characters[index].costumeReferenceSets.indices {
            if characters[index].costumeReferenceSets[costumeIndex].sheetPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                let costume = characters[index].costumeReferenceSets[costumeIndex]
                characters[index].costumeReferenceSets[costumeIndex].sheetPrompt =
                    CharacterReferenceWorkflowCatalog.fullBodySheetPrompt(
                        characterName: characters[index].name,
                        costumeName: costume.name,
                        costumeNotes: costume.notes
                    )
                didMutate = true
            }
        }

        if didMutate { save() }
    }

    func resetCharacterReferenceWorkflow(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].masterReferenceSheetPrompt = CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(
            for: characters[index].name
        )
        characters[index].masterReferenceSourceImagePaths = defaultMasterReferenceSourcePaths(for: characters[index])
        characters[index].masterReferenceSheetVariants = []
        characters[index].approvedMasterReferenceSheetVariantID = nil
        characters[index].headTurnaroundSheetPrompt = CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(
            for: characters[index].name
        )
        characters[index].headTurnaroundSheetVariants = []
        characters[index].approvedHeadTurnaroundSheetVariantID = nil
        characters[index].headTurnaroundSlots = CharacterReferenceWorkflowCatalog.defaultHeadSlots(
            for: characters[index].name
        )
        characters[index].costumeReferenceSets = CharacterReferenceWorkflowCatalog.defaultCostumeSets(
            for: characters[index].name
        )
        save()
    }

    /// Explicitly save any in-memory prompt/text edits to disk.
    /// Call this on generate, navigate away, or other explicit user actions — NOT on keystroke.
    func saveCharacterPromptEdits() {
        save()
    }

    func updateMasterReferenceSheetPrompt(_ prompt: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              characters[index].masterReferenceSheetPrompt != prompt else { return }
        characters[index].masterReferenceSheetPrompt = prompt
        // No autosave — prompts save on generate/navigate, not on keystroke
    }

    func setMasterReferenceSourceInclusion(_ included: Bool, path: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              let normalizedPath = normalizedCharacterAssetPath(path) else {
            return
        }

        if included {
            if !characters[index].masterReferenceSourceImagePaths.contains(normalizedPath) {
                characters[index].masterReferenceSourceImagePaths.append(normalizedPath)
            }
        } else {
            characters[index].masterReferenceSourceImagePaths.removeAll { $0 == normalizedPath }
        }
        save()
    }

    func importMasterReferenceSheetVariant(from sourceURL: URL, for characterID: UUID) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let metadata = masterReferenceImportMetadata(for: sourceURL)
        let variant = try persistImportedReferenceWorkflowVariant(
            from: sourceURL,
            prompt: metadata.prompt ?? characters[charIndex].masterReferenceSheetPrompt,
            model: metadata.model ?? selectedGeminiModel,
            characterIndex: charIndex,
            category: "reference-workflow/master-sheet",
            aspectRatio: metadata.aspectRatio ?? CharacterReferenceWorkflowCatalog.defaultMasterSheetAspectRatio,
            imageSize: metadata.imageSize ?? CharacterReferenceWorkflowCatalog.defaultMasterSheetImageSize
        )
        characters[charIndex].masterReferenceSheetVariants.append(variant)
        characters[charIndex].approvedMasterReferenceSheetVariantID = variant.id
        if let prompt = metadata.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[charIndex].masterReferenceSheetPrompt = prompt
        }
        save()
    }

    func setApprovedMasterReferenceSheetVariant(_ variantID: UUID?, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].approvedMasterReferenceSheetVariantID = variantID
        save()
    }

    func removeMasterReferenceSheetVariant(_ variantID: UUID, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].masterReferenceSheetVariants.removeAll { $0.id == variantID }
        if characters[index].approvedMasterReferenceSheetVariantID == variantID {
            characters[index].approvedMasterReferenceSheetVariantID = characters[index].masterReferenceSheetVariants.last?.id
        }
        save()
    }

    func storeMasterReferenceSheetVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let variant = try persistReferenceWorkflowVariant(
            data,
            prompt: prompt,
            model: model,
            characterIndex: charIndex,
            category: "reference-workflow/master-sheet",
            filenameStem: "master-sheet",
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )
        characters[charIndex].masterReferenceSheetVariants.append(variant)
        characters[charIndex].approvedMasterReferenceSheetVariantID = variant.id
        save()
    }

    func updateHeadTurnaroundSheetPrompt(_ prompt: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              characters[index].headTurnaroundSheetPrompt != prompt else { return }
        characters[index].headTurnaroundSheetPrompt = prompt
        // No autosave — prompts save on generate/navigate, not on keystroke
    }

    func setApprovedHeadTurnaroundSheetVariant(_ variantID: UUID?, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].approvedHeadTurnaroundSheetVariantID = variantID
        save()
        if variantID != nil {
            do {
                try cropApprovedHeadTurnaroundSheet(for: characterID)
            } catch {
                statusMessage = "Failed to auto-crop head sheet: \(error.localizedDescription)"
            }
        }
    }

    func removeHeadTurnaroundSheetVariant(_ variantID: UUID, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].headTurnaroundSheetVariants.removeAll { $0.id == variantID }
        if characters[index].approvedHeadTurnaroundSheetVariantID == variantID {
            characters[index].approvedHeadTurnaroundSheetVariantID = characters[index].headTurnaroundSheetVariants.last?.id
        }
        save()
    }

    func storeHeadTurnaroundSheetVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let variant = try persistReferenceWorkflowVariant(
            data,
            prompt: prompt,
            model: model,
            characterIndex: charIndex,
            category: "reference-workflow/head-sheet",
            filenameStem: "head-sheet",
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )
        characters[charIndex].headTurnaroundSheetVariants.append(variant)
        characters[charIndex].approvedHeadTurnaroundSheetVariantID = variant.id
        save()
        try cropApprovedHeadTurnaroundSheet(for: characterID)
    }

    func importHeadTurnaroundSheetVariant(from sourceURL: URL, for characterID: UUID) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let metadata = masterReferenceImportMetadata(for: sourceURL)
        let variant = try persistImportedReferenceWorkflowVariant(
            from: sourceURL,
            prompt: metadata.prompt ?? characters[charIndex].headTurnaroundSheetPrompt,
            model: metadata.model ?? selectedGeminiModel,
            characterIndex: charIndex,
            category: "reference-workflow/head-sheet",
            aspectRatio: metadata.aspectRatio ?? CharacterReferenceWorkflowCatalog.sectionSheetAspectRatio,
            imageSize: metadata.imageSize ?? CharacterReferenceWorkflowCatalog.sectionSheetImageSize
        )
        characters[charIndex].headTurnaroundSheetVariants.append(variant)
        characters[charIndex].approvedHeadTurnaroundSheetVariantID = variant.id
        if let prompt = metadata.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[charIndex].headTurnaroundSheetPrompt = prompt
        }
        save()
        try cropApprovedHeadTurnaroundSheet(for: characterID)
    }

    func updateHeadTurnaroundPrompt(_ prompt: String, slotID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].headTurnaroundSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        characters[charIndex].headTurnaroundSlots[slotIndex].prompt = prompt
        save()
    }

    func setApprovedHeadTurnaroundVariant(_ variantID: UUID?, slotID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].headTurnaroundSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        characters[charIndex].headTurnaroundSlots[slotIndex].approvedVariantID = variantID
        save()
    }

    func removeHeadTurnaroundVariant(_ variantID: UUID, slotID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].headTurnaroundSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        characters[charIndex].headTurnaroundSlots[slotIndex].variants.removeAll { $0.id == variantID }
        if characters[charIndex].headTurnaroundSlots[slotIndex].approvedVariantID == variantID {
            characters[charIndex].headTurnaroundSlots[slotIndex].approvedVariantID =
                characters[charIndex].headTurnaroundSlots[slotIndex].variants.last?.id
        }
        save()
    }

    func storeHeadTurnaroundVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        slotID: UUID,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].headTurnaroundSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        let slot = characters[charIndex].headTurnaroundSlots[slotIndex]
        let variant = try persistReferenceWorkflowVariant(
            data,
            prompt: prompt,
            model: model,
            characterIndex: charIndex,
            category: "reference-workflow/head-turnaround",
            filenameStem: slot.key,
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )
        characters[charIndex].headTurnaroundSlots[slotIndex].variants.append(variant)
        characters[charIndex].headTurnaroundSlots[slotIndex].approvedVariantID = variant.id
        save()
    }

    func importHeadTurnaroundVariant(
        from sourceURL: URL,
        slotID: UUID,
        for characterID: UUID
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].headTurnaroundSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }

        let slot = characters[charIndex].headTurnaroundSlots[slotIndex]
        let metadata = masterReferenceImportMetadata(for: sourceURL)
        let variant = try persistImportedReferenceWorkflowVariant(
            from: sourceURL,
            prompt: metadata.prompt ?? slot.prompt,
            model: metadata.model ?? selectedGeminiModel,
            characterIndex: charIndex,
            category: "reference-workflow/head-turnaround",
            aspectRatio: metadata.aspectRatio ?? slot.recommendedAspectRatio,
            imageSize: metadata.imageSize ?? slot.recommendedImageSize
        )
        characters[charIndex].headTurnaroundSlots[slotIndex].variants.append(variant)
        characters[charIndex].headTurnaroundSlots[slotIndex].approvedVariantID = variant.id
        if let prompt = metadata.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[charIndex].headTurnaroundSlots[slotIndex].prompt = prompt
        }
        save()
    }

    func addCostumeReferenceSet(for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let existingNames = Set(characters[charIndex].costumeReferenceSets.map(\.name))
        var candidateIndex = characters[charIndex].costumeReferenceSets.count + 1
        var candidateName = "Costume \(candidateIndex)"
        while existingNames.contains(candidateName) {
            candidateIndex += 1
            candidateName = "Costume \(candidateIndex)"
        }

        let set = CharacterReferenceWorkflowCatalog.makeCostumeSet(
            characterName: characters[charIndex].name,
            name: candidateName,
            notes: "Describe the approved costume, silhouette, palette, and accessories for this wardrobe."
        )
        characters[charIndex].costumeReferenceSets.append(set)
        save()
    }

    func updateCostumeReferenceSetName(_ name: String, costumeID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let oldSet = characters[charIndex].costumeReferenceSets[costumeIndex]
        characters[charIndex].costumeReferenceSets[costumeIndex] = CharacterCostumeReferenceSet(
            id: oldSet.id,
            name: trimmedName,
            notes: oldSet.notes,
            sheetPrompt: oldSet.sheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? CharacterReferenceWorkflowCatalog.fullBodySheetPrompt(
                    characterName: characters[charIndex].name,
                    costumeName: trimmedName,
                    costumeNotes: oldSet.notes
                )
                : oldSet.sheetPrompt,
            sheetVariants: oldSet.sheetVariants,
            approvedSheetVariantID: oldSet.approvedSheetVariantID,
            fullBodySlots: CharacterReferencePose.allCases.map { pose in
                let existing = oldSet.fullBodySlots.first(where: { $0.pose == pose })
                return CharacterPoseSlot(
                    id: existing?.id ?? UUID(),
                    key: "\(CharacterReferenceWorkflowCatalog.slug(from: trimmedName))-fullbody-\(pose.rawValue)",
                    title: pose.title,
                    pose: pose,
                    prompt: existing?.prompt ?? CharacterReferenceWorkflowCatalog.fullBodyPrompt(
                        for: pose,
                        characterName: characters[charIndex].name,
                        costumeNotes: oldSet.notes
                    ),
                    notes: existing?.notes ?? "\(trimmedName) full-body turnaround pose.",
                    recommendedAspectRatio: existing?.recommendedAspectRatio ?? "1:1",
                    recommendedImageSize: existing?.recommendedImageSize ?? "4K",
                    variants: existing?.variants ?? [],
                    approvedVariantID: existing?.approvedVariantID
                )
            },
            accessorySlots: oldSet.accessorySlots.map { slot in
                CharacterAccessorySlot(
                    id: slot.id,
                    key: "\(CharacterReferenceWorkflowCatalog.slug(from: trimmedName))-accessory-\(String(slot.id.uuidString.prefix(8)).lowercased())",
                    title: slot.title,
                    prompt: slot.prompt,
                    notes: slot.notes,
                    recommendedAspectRatio: slot.recommendedAspectRatio,
                    recommendedImageSize: slot.recommendedImageSize,
                    variants: slot.variants,
                    approvedVariantID: slot.approvedVariantID
                )
            }
        )
        // No autosave — costume data saves on generate/navigate, not on keystroke
    }

    func updateCostumeReferenceSetNotes(_ notes: String, costumeID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              characters[charIndex].costumeReferenceSets[costumeIndex].notes != notes else {
            return
        }

        characters[charIndex].costumeReferenceSets[costumeIndex].notes = notes
        characters[charIndex].costumeReferenceSets[costumeIndex].sheetPrompt =
            CharacterReferenceWorkflowCatalog.fullBodySheetPrompt(
                characterName: characters[charIndex].name,
                costumeName: characters[charIndex].costumeReferenceSets[costumeIndex].name,
                costumeNotes: notes
            )
        for poseIndex in characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots.indices {
            let pose = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[poseIndex].pose
            characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[poseIndex].prompt =
                CharacterReferenceWorkflowCatalog.fullBodyPrompt(
                    for: pose,
                    characterName: characters[charIndex].name,
                    costumeNotes: notes
                )
        }
        for accessoryIndex in characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots.indices {
            let title = characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].title
            let costumeName = characters[charIndex].costumeReferenceSets[costumeIndex].name
            characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].prompt =
                CharacterReferenceWorkflowCatalog.accessoryPrompt(
                    title: title.lowercased(),
                    characterName: characters[charIndex].name,
                    costumeName: costumeName,
                    costumeNotes: notes
                )
        }
        // No autosave — costume data saves on generate/navigate, not on keystroke
    }

    func updateCostumeSheetPrompt(_ prompt: String, costumeID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              characters[charIndex].costumeReferenceSets[costumeIndex].sheetPrompt != prompt else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].sheetPrompt = prompt
        // No autosave — prompts save on generate/navigate, not on keystroke
    }

    func setApprovedCostumeSheetVariant(_ variantID: UUID?, costumeID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].approvedSheetVariantID = variantID
        save()
        if variantID != nil {
            do {
                try cropApprovedCostumeSheet(for: characterID, costumeID: costumeID)
            } catch {
                statusMessage = "Failed to auto-crop costume sheet: \(error.localizedDescription)"
            }
        }
    }

    func removeCostumeSheetVariant(_ variantID: UUID, costumeID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].sheetVariants.removeAll { $0.id == variantID }
        if characters[charIndex].costumeReferenceSets[costumeIndex].approvedSheetVariantID == variantID {
            characters[charIndex].costumeReferenceSets[costumeIndex].approvedSheetVariantID =
                characters[charIndex].costumeReferenceSets[costumeIndex].sheetVariants.last?.id
        }
        save()
    }

    func storeCostumeSheetVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        costumeID: UUID,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }) else {
            return
        }
        let costume = characters[charIndex].costumeReferenceSets[costumeIndex]
        let variant = try persistReferenceWorkflowVariant(
            data,
            prompt: prompt,
            model: model,
            characterIndex: charIndex,
            category: "reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/sheet",
            filenameStem: "\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))-sheet",
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )
        characters[charIndex].costumeReferenceSets[costumeIndex].sheetVariants.append(variant)
        characters[charIndex].costumeReferenceSets[costumeIndex].approvedSheetVariantID = variant.id
        save()
        try cropApprovedCostumeSheet(for: characterID, costumeID: costumeID)
    }

    func importCostumeSheetVariant(
        from sourceURL: URL,
        costumeID: UUID,
        for characterID: UUID
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }) else {
            return
        }
        let costume = characters[charIndex].costumeReferenceSets[costumeIndex]
        let metadata = masterReferenceImportMetadata(for: sourceURL)
        let variant = try persistImportedReferenceWorkflowVariant(
            from: sourceURL,
            prompt: metadata.prompt ?? costume.sheetPrompt,
            model: metadata.model ?? selectedGeminiModel,
            characterIndex: charIndex,
            category: "reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/sheet",
            aspectRatio: metadata.aspectRatio ?? CharacterReferenceWorkflowCatalog.sectionSheetAspectRatio,
            imageSize: metadata.imageSize ?? CharacterReferenceWorkflowCatalog.sectionSheetImageSize
        )
        characters[charIndex].costumeReferenceSets[costumeIndex].sheetVariants.append(variant)
        characters[charIndex].costumeReferenceSets[costumeIndex].approvedSheetVariantID = variant.id
        if let prompt = metadata.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[charIndex].costumeReferenceSets[costumeIndex].sheetPrompt = prompt
        }
        save()
        try cropApprovedCostumeSheet(for: characterID, costumeID: costumeID)
    }

    func removeCostumeReferenceSet(_ costumeID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[charIndex].costumeReferenceSets.removeAll { $0.id == costumeID }
        save()
    }

    func updateCostumePosePrompt(_ prompt: String, costumeID: UUID, slotID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let slotIndex = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].prompt = prompt
        save()
    }

    func setApprovedCostumePoseVariant(
        _ variantID: UUID?,
        costumeID: UUID,
        slotID: UUID,
        for characterID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let slotIndex = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].approvedVariantID = variantID
        save()
    }

    func removeCostumePoseVariant(
        _ variantID: UUID,
        costumeID: UUID,
        slotID: UUID,
        for characterID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let slotIndex = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].variants.removeAll { $0.id == variantID }
        if characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].approvedVariantID == variantID {
            characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].approvedVariantID =
                characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].variants.last?.id
        }
        save()
    }

    func storeCostumePoseVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        costumeID: UUID,
        slotID: UUID,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let slotIndex = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }
        let costume = characters[charIndex].costumeReferenceSets[costumeIndex]
        let slot = costume.fullBodySlots[slotIndex]
        let variant = try persistReferenceWorkflowVariant(
            data,
            prompt: prompt,
            model: model,
            characterIndex: charIndex,
            category: "reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/fullbody",
            filenameStem: slot.key,
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )
        characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].variants.append(variant)
        characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].approvedVariantID = variant.id
        save()
    }

    func importCostumePoseVariant(
        from sourceURL: URL,
        costumeID: UUID,
        slotID: UUID,
        for characterID: UUID
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let slotIndex = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }

        let costume = characters[charIndex].costumeReferenceSets[costumeIndex]
        let slot = costume.fullBodySlots[slotIndex]
        let metadata = masterReferenceImportMetadata(for: sourceURL)
        let variant = try persistImportedReferenceWorkflowVariant(
            from: sourceURL,
            prompt: metadata.prompt ?? slot.prompt,
            model: metadata.model ?? selectedGeminiModel,
            characterIndex: charIndex,
            category: "reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/fullbody",
            aspectRatio: metadata.aspectRatio ?? slot.recommendedAspectRatio,
            imageSize: metadata.imageSize ?? slot.recommendedImageSize
        )
        characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].variants.append(variant)
        characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].approvedVariantID = variant.id
        if let prompt = metadata.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].prompt = prompt
        }
        save()
    }

    func updateAccessoryPrompt(_ prompt: String, costumeID: UUID, accessoryID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let accessoryIndex = characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots.firstIndex(where: { $0.id == accessoryID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].prompt = prompt
        save()
    }

    func setApprovedAccessoryVariant(
        _ variantID: UUID?,
        costumeID: UUID,
        accessoryID: UUID,
        for characterID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let accessoryIndex = characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots.firstIndex(where: { $0.id == accessoryID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].approvedVariantID = variantID
        save()
    }

    func removeAccessoryVariant(
        _ variantID: UUID,
        costumeID: UUID,
        accessoryID: UUID,
        for characterID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let accessoryIndex = characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots.firstIndex(where: { $0.id == accessoryID }) else {
            return
        }
        characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].variants.removeAll { $0.id == variantID }
        if characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].approvedVariantID == variantID {
            characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].approvedVariantID =
                characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].variants.last?.id
        }
        save()
    }

    func storeAccessoryVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        costumeID: UUID,
        accessoryID: UUID,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let accessoryIndex = characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots.firstIndex(where: { $0.id == accessoryID }) else {
            return
        }
        let costume = characters[charIndex].costumeReferenceSets[costumeIndex]
        let slot = costume.accessorySlots[accessoryIndex]
        let variant = try persistReferenceWorkflowVariant(
            data,
            prompt: prompt,
            model: model,
            characterIndex: charIndex,
            category: "reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/accessories",
            filenameStem: slot.key,
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )
        characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].variants.append(variant)
        characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].approvedVariantID = variant.id
        save()
    }

    func importAccessoryVariant(
        from sourceURL: URL,
        costumeID: UUID,
        accessoryID: UUID,
        for characterID: UUID
    ) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let accessoryIndex = characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots.firstIndex(where: { $0.id == accessoryID }) else {
            return
        }

        let costume = characters[charIndex].costumeReferenceSets[costumeIndex]
        let slot = costume.accessorySlots[accessoryIndex]
        let metadata = masterReferenceImportMetadata(for: sourceURL)
        let variant = try persistImportedReferenceWorkflowVariant(
            from: sourceURL,
            prompt: metadata.prompt ?? slot.prompt,
            model: metadata.model ?? selectedGeminiModel,
            characterIndex: charIndex,
            category: "reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/accessories",
            aspectRatio: metadata.aspectRatio ?? slot.recommendedAspectRatio,
            imageSize: metadata.imageSize ?? slot.recommendedImageSize
        )
        characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].variants.append(variant)
        characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].approvedVariantID = variant.id
        if let prompt = metadata.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            characters[charIndex].costumeReferenceSets[costumeIndex].accessorySlots[accessoryIndex].prompt = prompt
        }
        save()
    }

    func masterReferenceSheetReferencePaths(for characterID: UUID, limit: Int = 8) -> [String] {
        guard let character = characters.first(where: { $0.id == characterID }) else { return [] }
        var ordered = preferredInspirationReferencePaths(for: character)
        if !character.masterReferenceSourceImagePaths.isEmpty {
            ordered.append(contentsOf: character.masterReferenceSourceImagePaths.compactMap { normalizedCharacterAssetPath($0) })
        }
        return Array(ordered.prefix(limit))
    }

    func normalizedMasterSheetPath(for characterID: UUID) -> String? {
        guard let character = characters.first(where: { $0.id == characterID }) else { return nil }
        return normalizedCharacterAssetPath(character.approvedMasterReferenceSheetVariant?.imagePath)
    }

    func headReferencePaths(for characterID: UUID, limit: Int = 8) -> [String] {
        guard let character = characters.first(where: { $0.id == characterID }) else { return [] }

        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        // Master sheet first — strongest identity anchor for head pose generation
        append(character.approvedMasterReferenceSheetVariant?.imagePath)
        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }
        character.headTurnaroundSlots.forEach { append($0.approvedVariant?.imagePath) }

        return Array(ordered.prefix(limit))
    }

    func headSheetReferencePaths(for characterID: UUID, limit: Int = 8) -> [String] {
        guard let character = characters.first(where: { $0.id == characterID }) else {
            print("[headSheetReferencePaths] Character \(characterID) not found")
            return []
        }

        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ path: String?, label: String = "") {
            guard let rawPath = path else {
                print("[headSheetReferencePaths] \(label): nil input")
                return
            }
            guard let normalized = normalizedCharacterAssetPath(rawPath) else {
                print("[headSheetReferencePaths] \(label): normalizedCharacterAssetPath returned nil for '\(rawPath)'")
                return
            }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
            }
        }

        // Master sheet first — most of the time the only reference needed for head close-up generation
        let masterVariant = character.approvedMasterReferenceSheetVariant
        print("[headSheetReferencePaths] \(character.name): approvedMasterReferenceSheetVariant = \(masterVariant?.id.uuidString ?? "nil"), imagePath = \(masterVariant?.imagePath ?? "nil")")
        print("[headSheetReferencePaths] \(character.name): masterReferenceSheetVariants count = \(character.masterReferenceSheetVariants.count), approvedID = \(character.approvedMasterReferenceSheetVariantID?.uuidString ?? "nil")")
        append(masterVariant?.imagePath, label: "masterSheet")
        append(character.inspirationReferenceImagePath, label: "inspirationRef")
        character.curatedInspirationImagePaths.forEach { append($0, label: "curated") }
        print("[headSheetReferencePaths] \(character.name): returning \(ordered.count) paths: \(ordered)")
        return Array(ordered.prefix(limit))
    }

    func fullBodyReferencePaths(for characterID: UUID, costumeID: UUID, limit: Int = 8) -> [String] {
        guard let character = characters.first(where: { $0.id == characterID }),
              let costume = character.costumeReferenceSets.first(where: { $0.id == costumeID }) else {
            return []
        }

        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        // Master sheet first for strongest identity preservation
        append(character.approvedMasterReferenceSheetVariant?.imagePath)
        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }
        character.headTurnaroundSlots.forEach { append($0.approvedVariant?.imagePath) }
        costume.fullBodySlots.forEach { append($0.approvedVariant?.imagePath) }

        return Array(ordered.prefix(limit))
    }

    func fullBodySheetReferencePaths(for characterID: UUID, costumeID: UUID, limit: Int = 8) -> [String] {
        guard let character = characters.first(where: { $0.id == characterID }),
              let costume = character.costumeReferenceSets.first(where: { $0.id == costumeID }) else {
            return []
        }

        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        // Master sheet first — it's the strongest identity anchor for costume generation
        append(character.approvedMasterReferenceSheetVariant?.imagePath)
        append(character.approvedHeadTurnaroundSheetVariant?.imagePath)
        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }
        character.headTurnaroundSlots.forEach { append($0.approvedVariant?.imagePath) }
        costume.fullBodySlots.forEach { append($0.approvedVariant?.imagePath) }
        return Array(ordered.prefix(limit))
    }

    func accessoryReferencePaths(for characterID: UUID, costumeID: UUID, limit: Int = 8) -> [String] {
        guard let character = characters.first(where: { $0.id == characterID }),
              let costume = character.costumeReferenceSets.first(where: { $0.id == costumeID }) else {
            return []
        }

        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        // Master sheet first for strongest identity preservation
        append(character.approvedMasterReferenceSheetVariant?.imagePath)
        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }
        character.headTurnaroundSlots.forEach { append($0.approvedVariant?.imagePath) }
        costume.fullBodySlots.forEach { append($0.approvedVariant?.imagePath) }
        costume.accessorySlots.forEach { append($0.approvedVariant?.imagePath) }

        return Array(ordered.prefix(limit))
    }

    private func persistReferenceWorkflowVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        characterIndex: Int,
        category: String,
        filenameStem: String,
        aspectRatio: String,
        imageSize: String
    ) throws -> CharacterLookDevelopmentVariant {
        let animateURL = try requireAnimateURL()

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let filename = "\(filenameStem)-\(timestamp).png"
        let storedURL = try assetManager.writeCharacterImageData(
            data,
            suggestedFilename: filename,
            characterSlug: characters[characterIndex].assetFolderSlug,
            category: category,
            animateURL: animateURL
        )

        return CharacterLookDevelopmentVariant(
            imagePath: storedURL.path,
            prompt: prompt,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            model: model.rawValue
        )
    }

    private func persistImportedReferenceWorkflowVariant(
        from sourceURL: URL,
        prompt: String,
        model: GeminiModel,
        characterIndex: Int,
        category: String,
        aspectRatio: String,
        imageSize: String
    ) throws -> CharacterLookDevelopmentVariant {
        let animateURL = try requireAnimateURL()
        let storedURL = try assetManager.importCharacterImageURL(
            from: sourceURL,
            characterSlug: characters[characterIndex].assetFolderSlug,
            category: category,
            animateURL: animateURL
        )
        return CharacterLookDevelopmentVariant(
            imagePath: storedURL.path,
            prompt: prompt,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            model: model.rawValue
        )
    }

    private func writeGenerationMetadata(
        prompt: String,
        model: GeminiModel,
        aspectRatio: String,
        imageSize: String,
        recommendedLORACaption: String? = nil,
        placeID: UUID? = nil,
        routeID: UUID? = nil,
        worldNodeID: UUID? = nil,
        mapPoint: WorldMapPoint? = nil,
        cameraPose: WorldCameraPose? = nil,
        mapPlacementStatus: GeneratedBackgroundMapPlacementStatus? = nil,
        buildingAnchorNodeID: UUID? = nil,
        orientationState: GeneratedBackgroundOrientationState? = nil,
        to imageURL: URL
    ) throws {
        var requestPayload: [String: Any] = [
            "prompt": prompt,
            "model_alias": model.displayName,
            "model": model.rawValue,
            "image_size": imageSize,
            "aspect_ratio": aspectRatio,
        ]
        if let recommendedLORACaption,
           !recommendedLORACaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestPayload["recommended_lora_caption"] = recommendedLORACaption
        }
        if let placeID {
            requestPayload["place_id"] = placeID.uuidString
        }
        if let routeID {
            requestPayload["route_id"] = routeID.uuidString
        }
        if let worldNodeID {
            requestPayload["world_node_id"] = worldNodeID.uuidString
        }
        if let mapPoint {
            let clampedMapPoint = mapPoint.clamped()
            requestPayload["map_point"] = [
                "x": clampedMapPoint.x,
                "y": clampedMapPoint.y,
            ]
        }
        if let cameraPose {
            var posePayload: [String: Any] = [
                "yaw_degrees": cameraPose.yawDegrees,
                "pitch_degrees": cameraPose.pitchDegrees,
                "roll_degrees": cameraPose.rollDegrees,
                "focal_length_mm": cameraPose.focalLengthMM,
            ]
            if let horizontalFOVDegrees = cameraPose.horizontalFOVDegrees {
                posePayload["horizontal_fov_degrees"] = horizontalFOVDegrees
            }
            if let verticalFOVDegrees = cameraPose.verticalFOVDegrees {
                posePayload["vertical_fov_degrees"] = verticalFOVDegrees
            }
            requestPayload["camera_pose"] = posePayload
        }
        if let mapPlacementStatus {
            requestPayload["map_placement_status"] = mapPlacementStatus.rawValue
        }
        if let buildingAnchorNodeID {
            requestPayload["building_anchor_node_id"] = buildingAnchorNodeID.uuidString
        }
        if let orientationState {
            requestPayload["orientation_state"] = orientationState.rawValue
        }
        let payload: [String: Any] = ["request": requestPayload]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: imageURL.deletingPathExtension().appendingPathExtension("json"))
    }

    func cropApprovedHeadTurnaroundSheet(for characterID: UUID) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let sheet = characters[charIndex].approvedHeadTurnaroundSheetVariant,
              let url = resolvedCharacterAssetURL(for: sheet.imagePath),
              let image = NSImage(contentsOf: url) else { return }

        let cropService = ReferenceSheetCropService()
        let smartResults = cropService.cropSheet(image: image, kind: .head)

        for pose in CharacterReferencePose.allCases {
            guard let slotIndex = characters[charIndex].headTurnaroundSlots.firstIndex(where: { $0.pose == pose }) else { continue }

            let smartResult = smartResults.first(where: { $0.pose == pose })
            let pngData: Data
            let cropRect: CropRect
            if let result = smartResult, result.confidence >= 0.3 {
                pngData = result.imageData
                cropRect = result.cropRect
            } else {
                guard let gridData = cropReferenceSheetImageData(image: image, pose: pose, kind: .head) else { continue }
                pngData = gridData
                cropRect = normalizedCropRect(for: pose, kind: .head)
            }

            var variant = try persistReferenceWorkflowVariant(
                pngData,
                prompt: "[Auto-cropped from approved head sheet]\n\(sheet.prompt)",
                model: GeminiModel(rawValue: sheet.model) ?? selectedGeminiModel,
                characterIndex: charIndex,
                category: "reference-workflow/head-turnaround",
                filenameStem: characters[charIndex].headTurnaroundSlots[slotIndex].key,
                aspectRatio: "1:1",
                imageSize: sheet.imageSize
            )
            variant.sourceSheetPath = sheet.imagePath
            variant.sourceCropRect = cropRect
            characters[charIndex].headTurnaroundSlots[slotIndex].variants.append(variant)
            characters[charIndex].headTurnaroundSlots[slotIndex].approvedVariantID = variant.id
        }

        save()
    }

    func cropApprovedCostumeSheet(for characterID: UUID, costumeID: UUID) throws {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let costumeIndex = characters[charIndex].costumeReferenceSets.firstIndex(where: { $0.id == costumeID }),
              let sheet = characters[charIndex].costumeReferenceSets[costumeIndex].approvedSheetVariant,
              let url = resolvedCharacterAssetURL(for: sheet.imagePath),
              let image = NSImage(contentsOf: url) else { return }

        let cropService = ReferenceSheetCropService()
        let smartResults = cropService.cropSheet(image: image, kind: .fullBody)

        for pose in CharacterReferencePose.allCases {
            guard let slotIndex = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots.firstIndex(where: { $0.pose == pose }) else { continue }

            let smartResult = smartResults.first(where: { $0.pose == pose })
            let pngData: Data
            let cropRect: CropRect
            if let result = smartResult, result.confidence >= 0.3 {
                pngData = result.imageData
                cropRect = result.cropRect
            } else {
                guard let gridData = cropReferenceSheetImageData(image: image, pose: pose, kind: .fullBody) else { continue }
                pngData = gridData
                cropRect = normalizedCropRect(for: pose, kind: .fullBody)
            }

            let slot = characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex]
            var variant = try persistReferenceWorkflowVariant(
                pngData,
                prompt: "[Auto-cropped from approved costume sheet]\n\(sheet.prompt)",
                model: GeminiModel(rawValue: sheet.model) ?? selectedGeminiModel,
                characterIndex: charIndex,
                category: "reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: characters[charIndex].costumeReferenceSets[costumeIndex].name))/fullbody",
                filenameStem: slot.key,
                aspectRatio: "1:1",
                imageSize: sheet.imageSize
            )
            variant.sourceSheetPath = sheet.imagePath
            variant.sourceCropRect = cropRect
            characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].variants.append(variant)
            characters[charIndex].costumeReferenceSets[costumeIndex].fullBodySlots[slotIndex].approvedVariantID = variant.id
        }

        save()
    }

    private enum ReferenceSheetCropKind {
        case head
        case fullBody
    }

    private func normalizedCropRect(for pose: CharacterReferencePose, kind: ReferenceSheetCropKind) -> CropRect {
        let cols = 3.0
        let rows = 2.0
        let (row, col): (Double, Double) = switch pose {
        case .frontNeutral: (0, 0)
        case .quarterLeft: (0, 1)
        case .quarterRight: (0, 2)
        case .back: (1, 0)
        case .leftProfile: (1, 1)
        case .rightProfile: (1, 2)
        }
        let insetX = (kind == .head ? 0.02 : 0.02) / cols
        let insetY = (kind == .head ? 0.02 : 0.02) / rows
        return CropRect(
            x: col / cols + insetX,
            y: row / rows + insetY,
            width: 1.0 / cols - insetX * 2,
            height: 1.0 / rows - insetY * 2
        )
    }

    private func cropReferenceSheetImageData(
        image: NSImage,
        pose: CharacterReferencePose,
        kind: ReferenceSheetCropKind
    ) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cellWidth = width / 3
        let cellHeight = height / 2

        let (row, column): (CGFloat, CGFloat) = switch pose {
        case .frontNeutral: (0, 0)
        case .quarterLeft: (0, 1)
        case .quarterRight: (0, 2)
        case .back: (1, 0)
        case .leftProfile: (1, 1)
        case .rightProfile: (1, 2)
        }

        let insetXFactor: CGFloat = kind == .head ? 0.02 : 0.02
        let insetYFactor: CGFloat = kind == .head ? 0.02 : 0.02
        let rect = CGRect(
            x: column * cellWidth + cellWidth * insetXFactor,
            y: row * cellHeight + cellHeight * insetYFactor,
            width: cellWidth * (1 - (insetXFactor * 2)),
            height: cellHeight * (1 - (insetYFactor * 2))
        ).integral

        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        let croppedImage = NSImage(cgImage: cropped, size: rect.size)
        guard let tiffData = croppedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }

    private func defaultMasterReferenceSourcePaths(for character: AnimationCharacter) -> [String] {
        Array(preferredInspirationReferencePaths(for: character).prefix(8))
    }

    func preferredInspirationReferencePaths(for character: AnimationCharacter) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        latestInspirationBatchImagePaths(for: character).forEach { append($0) }
        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }
        character.inspirationImagePaths.forEach { append($0) }
        return ordered
    }

    private func latestInspirationBatchImagePaths(for character: AnimationCharacter) -> [String] {
        let inspirationJobs = character.inspirationBatchJobs
            .filter { $0.kind == .inspiration }
            .sorted { lhs, rhs in
                if lhs.submittedAt != rhs.submittedAt {
                    return lhs.submittedAt > rhs.submittedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        let jobs = inspirationJobs.isEmpty
            ? character.inspirationBatchJobs.sorted { lhs, rhs in
                if lhs.submittedAt != rhs.submittedAt {
                    return lhs.submittedAt > rhs.submittedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            : inspirationJobs

        guard let job = jobs.first(where: { !$0.downloadedImagePaths.isEmpty || !$0.autoImportedImagePaths.isEmpty }) else {
            return []
        }

        let candidatePaths = job.downloadedImagePaths.isEmpty ? job.autoImportedImagePaths : job.downloadedImagePaths
        return normalizedCharacterAssetPaths(candidatePaths)
    }

    private func masterReferenceImportMetadata(
        for imageURL: URL
    ) -> (prompt: String?, model: GeminiModel?, aspectRatio: String?, imageSize: String?) {
        let metadataURL = imageURL.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = json["request"] as? [String: Any] else {
            return (nil, nil, nil, nil)
        }

        let prompt = request["prompt"] as? String
        let modelRaw = request["model"] as? String
        let model = modelRaw.flatMap(GeminiModel.init(rawValue:))
        let aspectRatio = request["aspect_ratio"] as? String
        let imageSize = request["image_size"] as? String
        return (prompt, model, aspectRatio, imageSize)
    }

    func generationMetadata(for imagePath: String) -> StoredImageGenerationMetadata? {
        let resolvedURL = resolvedCharacterAssetURL(for: imagePath)
            ?? (imagePath.hasPrefix("/") ? URL(fileURLWithPath: imagePath) : nil)
        guard let imageURL = resolvedURL else { return nil }
        let metadataURL = imageURL.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let request = (json["request"] as? [String: Any]) ?? json
        guard let prompt = request["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let model = (request["model"] as? String)
            ?? (request["model_alias"] as? String)
            ?? GeminiModel.flash.rawValue
        let aspectRatio = (request["aspect_ratio"] as? String)
            ?? (request["aspectRatio"] as? String)
            ?? "1:1"
        let imageSize = (request["image_size"] as? String)
            ?? (request["imageSize"] as? String)
            ?? "1K"
        let placeID = (request["place_id"] as? String).flatMap(UUID.init(uuidString:))
        let routeID = (request["route_id"] as? String).flatMap(UUID.init(uuidString:))
        let worldNodeID = (request["world_node_id"] as? String).flatMap(UUID.init(uuidString:))
        let mapPoint: WorldMapPoint? = {
            guard let payload = request["map_point"] as? [String: Any],
                  let x = payload["x"] as? Double,
                  let y = payload["y"] as? Double else {
                return nil
            }
            return WorldMapPoint(x: x, y: y).clamped()
        }()
        let cameraPose: WorldCameraPose? = {
            guard let payload = request["camera_pose"] as? [String: Any] else { return nil }
            let yaw = payload["yaw_degrees"] as? Double ?? 0
            let pitch = payload["pitch_degrees"] as? Double ?? 0
            let roll = payload["roll_degrees"] as? Double ?? 0
            let focal = payload["focal_length_mm"] as? Double ?? 35
            let horizontalFOVDegrees = payload["horizontal_fov_degrees"] as? Double
            let verticalFOVDegrees = payload["vertical_fov_degrees"] as? Double
            return WorldCameraPose(
                yawDegrees: yaw,
                pitchDegrees: pitch,
                rollDegrees: roll,
                focalLengthMM: focal,
                horizontalFOVDegrees: horizontalFOVDegrees,
                verticalFOVDegrees: verticalFOVDegrees
            )
        }()
        let mapPlacementStatus = (request["map_placement_status"] as? String)
            .flatMap(GeneratedBackgroundMapPlacementStatus.init(rawValue:))
        let buildingAnchorNodeID = (request["building_anchor_node_id"] as? String).flatMap(UUID.init(uuidString:))
        let orientationState = (request["orientation_state"] as? String)
            .flatMap(GeneratedBackgroundOrientationState.init(rawValue:))

        return StoredImageGenerationMetadata(
            prompt: prompt,
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            placeID: placeID,
            routeID: routeID,
            worldNodeID: worldNodeID,
            mapPoint: mapPoint,
            cameraPose: cameraPose,
            mapPlacementStatus: mapPlacementStatus,
            buildingAnchorNodeID: buildingAnchorNodeID,
            orientationState: orientationState
        )
    }

    func imageResolutionDescription(for imagePath: String) -> String? {
        let resolvedURL = resolvedCharacterAssetURL(for: imagePath)
            ?? (imagePath.hasPrefix("/") ? URL(fileURLWithPath: imagePath) : nil)
        guard let imageURL = resolvedURL else { return nil }

        if let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           pixelWidth > 0,
           pixelHeight > 0 {
            return "\(pixelWidth) × \(pixelHeight) px"
        }

        guard let image = NSImage(contentsOf: imageURL) else { return nil }
        if let bitmapRep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }) {
            return "\(bitmapRep.pixelsWide) × \(bitmapRep.pixelsHigh) px"
        }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return "\(cgImage.width) × \(cgImage.height) px"
        }

        return nil
    }

    // MARK: - Look Development Board

    func seedLookDevelopmentSlotsIfNeeded(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard characters[index].lookDevelopmentSlots.isEmpty else { return }
        characters[index].lookDevelopmentSlots = CharacterLookDevelopmentCatalog.defaultSlots(
            for: characters[index].name
        )
        save()
    }

    func resetLookDevelopmentSlots(for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].lookDevelopmentSlots = CharacterLookDevelopmentCatalog.defaultSlots(
            for: characters[index].name
        )
        save()
    }

    func setLookDevelopmentApprovedVariant(
        _ variantID: UUID?,
        slotID: UUID,
        for characterID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].lookDevelopmentSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }

        characters[charIndex].lookDevelopmentSlots[slotIndex].approvedVariantID = variantID
        save()
    }

    func setLookDevelopmentReferenceInclusion(
        _ includeApprovedVariant: Bool,
        slotID: UUID,
        for characterID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].lookDevelopmentSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }

        characters[charIndex].lookDevelopmentSlots[slotIndex].includeApprovedVariantInReferencePack = includeApprovedVariant
        save()
    }

    func removeLookDevelopmentVariant(
        _ variantID: UUID,
        slotID: UUID,
        for characterID: UUID
    ) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].lookDevelopmentSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }

        characters[charIndex].lookDevelopmentSlots[slotIndex].variants.removeAll { $0.id == variantID }
        if characters[charIndex].lookDevelopmentSlots[slotIndex].approvedVariantID == variantID {
            characters[charIndex].lookDevelopmentSlots[slotIndex].approvedVariantID =
                characters[charIndex].lookDevelopmentSlots[slotIndex].variants.last?.id
        }
        save()
    }

    func storeLookDevelopmentVariant(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        slotID: UUID,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        guard let animateURL,
              let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let slotIndex = characters[charIndex].lookDevelopmentSlots.firstIndex(where: { $0.id == slotID }) else {
            return
        }

        let slot = characters[charIndex].lookDevelopmentSlots[slotIndex]
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let filename = "\(slot.key)-\(timestamp).png"
        let storedURL = try assetManager.writeCharacterImageData(
            data,
            suggestedFilename: filename,
            characterSlug: characters[charIndex].assetFolderSlug,
            category: "lookdev",
            animateURL: animateURL
        )

        let variant = CharacterLookDevelopmentVariant(
            imagePath: storedURL.path,
            prompt: prompt,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            model: model.rawValue
        )

        characters[charIndex].lookDevelopmentSlots[slotIndex].variants.append(variant)
        characters[charIndex].lookDevelopmentSlots[slotIndex].approvedVariantID = variant.id
        save()
    }

    func curatedLookDevelopmentReferencePaths(
        for characterID: UUID,
        preferredCostume: CharacterLookDevelopmentCostume? = nil,
        limit: Int = 8
    ) -> [String] {
        guard let character = characters.first(where: { $0.id == characterID }) else { return [] }

        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }
        append(character.approvedMasterReferenceSheetVariant?.imagePath)

        for slot in character.headTurnaroundSlots {
            append(slot.approvedVariant?.imagePath)
        }

        for slot in character.lookDevelopmentSlots where slot.includeApprovedVariantInReferencePack && slot.costume == .identity {
            append(slot.approvedVariant?.imagePath)
        }

        for costumeSet in character.costumeReferenceSets {
            for slot in costumeSet.fullBodySlots {
                append(slot.approvedVariant?.imagePath)
            }
            for slot in costumeSet.accessorySlots {
                append(slot.approvedVariant?.imagePath)
            }
        }

        if let preferredCostume {
            for slot in character.lookDevelopmentSlots where slot.includeApprovedVariantInReferencePack && slot.costume == preferredCostume {
                append(slot.approvedVariant?.imagePath)
            }
        }

        for path in character.referenceImagePaths {
            append(path)
        }

        if preferredCostume == nil {
            for slot in character.lookDevelopmentSlots where slot.includeApprovedVariantInReferencePack {
                append(slot.approvedVariant?.imagePath)
            }
        }

        return Array(ordered.prefix(limit))
    }

    // MARK: - Background Management

    @discardableResult
    func refreshPlacesFromScript(persistChanges: Bool = false) async -> Bool {
        guard let projectURL = fileOWPURL else {
            scriptPlaceRequirements = []
            return false
        }

        isRefreshingPlacesIndex = true
        defer { isRefreshingPlacesIndex = false }

        let requirements = await PlacesScriptIndexService.buildRequirements(
            projectURL: projectURL,
            scenes: scenes
        )
        scriptPlaceRequirements = requirements
        return applyScriptPlaceRequirements(requirements, persistChanges: persistChanges)
    }

    private func applyScriptPlaceRequirements(
        _ requirements: [PlacesScriptSceneRequirement],
        persistChanges: Bool
    ) -> Bool {
        let legacyPlaceholderKeys = Set(
            BackgroundPlaceholderService.amiraLocations.map {
                PlacesScriptIndexService.normalizedKey(for: $0.name)
            }
        )

        var didMutate = false
        let requiredLocations = requirements.flatMap(\.locations)
        let requiredKeys = Set(requiredLocations.map(\.normalizedKey))
        let requiredByKey = requiredLocations.reduce(into: [String: PlacesScriptLocationRequirement]()) { partialResult, location in
            partialResult[location.normalizedKey] = partialResult[location.normalizedKey] ?? location
        }
        let sceneNamesByKey = Dictionary(
            grouping: requirements.flatMap { requirement in
                requirement.locations.map { ($0.normalizedKey, requirement.sceneName) }
            },
            by: \.0
        ).mapValues { values in
            Array(Set(values.map(\.1))).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        }

        let removedLegacyIDs = Set(backgrounds.compactMap { place -> UUID? in
            let key = PlacesScriptIndexService.normalizedKey(for: place.name)
            guard legacyPlaceholderKeys.contains(key),
                  !requiredKeys.contains(key),
                  place.imagePaths.isEmpty,
                  place.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return place.id
        })
        if !removedLegacyIDs.isEmpty {
            backgrounds.removeAll { removedLegacyIDs.contains($0.id) }
            for index in scenes.indices where scenes[index].backgroundID.map(removedLegacyIDs.contains) == true {
                scenes[index].backgroundID = nil
            }
            didMutate = true
        }

        for index in backgrounds.indices {
            let key = PlacesScriptIndexService.normalizedKey(for: backgrounds[index].name)
            guard requiredKeys.contains(key) else { continue }
            let usage = sceneNamesByKey[key] ?? []
            if backgrounds[index].sceneUsage != usage {
                backgrounds[index].sceneUsage = usage
                didMutate = true
            }
            if backgrounds[index].locationCategory.isEmpty,
               let inferredCategory = requiredByKey[key]?.inferredCategory,
               !inferredCategory.isEmpty {
                backgrounds[index].locationCategory = inferredCategory
                didMutate = true
            }
        }

        for requirement in requirements {
            guard let sceneIndex = scenes.firstIndex(where: { $0.id == requirement.sceneID }),
                  let primary = requirement.primaryLocation else { continue }

            let matchingPlaceID = backgrounds.first(where: {
                PlacesScriptIndexService.normalizedKey(for: $0.name) == primary.normalizedKey
            })?.id

            if let matchingPlaceID {
                if scenes[sceneIndex].backgroundID != matchingPlaceID {
                    scenes[sceneIndex].backgroundID = matchingPlaceID
                    didMutate = true
                }
                continue
            }

            let inferredCategory = primary.inferredCategory
            let newPlace = BackgroundPlate(
                name: primary.displayName,
                filename: "\(PlacesScriptIndexService.fileStem(for: primary.displayName)).png",
                notes: "",
                imagePaths: [],
                approvedImagePath: nil,
                sourceURL: nil,
                angleImages: [],
                locationCategory: inferredCategory,
                sceneUsage: sceneNamesByKey[primary.normalizedKey] ?? []
            )
            backgrounds.append(newPlace)
            scenes[sceneIndex].backgroundID = newPlace.id
            didMutate = true
        }

        backgrounds.sort { lhs, rhs in
            let lhsKey = PlacesScriptIndexService.normalizedKey(for: lhs.name)
            let rhsKey = PlacesScriptIndexService.normalizedKey(for: rhs.name)
            let lhsIndex = requiredLocations.firstIndex(where: { $0.normalizedKey == lhsKey }) ?? .max
            let rhsIndex = requiredLocations.firstIndex(where: { $0.normalizedKey == rhsKey }) ?? .max
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        if let selectedSceneID,
           let primaryKey = sceneRequirement(for: selectedSceneID)?.primaryLocation?.normalizedKey,
           let selectedPlace = backgrounds.first(where: {
               PlacesScriptIndexService.normalizedKey(for: $0.name) == primaryKey
           }) {
            selectedBackgroundID = selectedPlace.id
        } else if selectedBackgroundID == nil || !backgrounds.contains(where: { $0.id == selectedBackgroundID }) {
            selectedBackgroundID = backgrounds.first?.id
        }

        if didMutate && persistChanges {
            save(writePlaces: true)
        }

        return didMutate
    }

    func importBackground(from url: URL) {
        guard let animateDir = animateURL else { return }
        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            let imagePath = normalizedCharacterAssetPath(storedURL.path) ?? storedURL.path
            let place = BackgroundPlate(
                name: url.deletingPathExtension().lastPathComponent,
                filename: storedURL.lastPathComponent,
                imagePaths: [imagePath],
                approvedImagePath: imagePath,
                sourceURL: storedURL
            )
            backgrounds.append(place)
            selectedBackgroundID = place.id
            save(writePlaces: true)
        } catch {
            statusMessage = "Failed to import place image: \(error.localizedDescription)"
        }
    }

    func importPlacesFromPicker() {
        let panel = NSOpenPanel()
        panel.title = "Import Place Images"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    self.importBackground(from: url)
                }
            }
        }
    }

    func updatePlaceName(_ name: String, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        backgrounds[index].name = trimmed
        save(writePlaces: true)
    }

    func updatePlaceNotes(_ notes: String, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              backgrounds[index].notes != notes else { return }
        backgrounds[index].notes = notes
        save(writePlaces: true)
    }

    func updatePlaceWorkflowPromptNotes(_ notes: String, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              backgrounds[index].workflowPromptNotes != notes else { return }
        backgrounds[index].workflowPromptNotes = notes
        save(writePlaces: true)
    }

    func addImagesToPlaceFromPicker(placeID: UUID) {
        addImagesToPlaceFromPicker(placeID: placeID, workflow: .photorealistic)
    }

    func addImagesToPlaceFromPicker(placeID: UUID, workflow: PlaceWorkflowMode) {
        let panel = NSOpenPanel()
        panel.title = "Add Images To Place"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    self.addImageToPlace(from: url, placeID: placeID, workflow: workflow)
                }
            }
        }
    }

    func addImageToPlace(from url: URL, placeID: UUID) {
        addImageToPlace(from: url, placeID: placeID, workflow: .photorealistic)
    }

    func addImageToPlace(from url: URL, placeID: UUID, workflow: PlaceWorkflowMode) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              let animateDir = animateURL else { return }

        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            let imagePath = normalizedCharacterAssetPath(storedURL.path) ?? storedURL.path
            appendPlaceImagePath(imagePath, to: &backgrounds[index], workflow: workflow)
            syncGeneratedBackgroundLibrary()
            save(writePlaces: true)
        } catch {
            statusMessage = "Failed to add place image: \(error.localizedDescription)"
        }
    }

    func allBackgroundHierarchyImagePaths() -> [String] {
        if placesWorkflowLibrary.generatedImageRecords.isEmpty {
            syncGeneratedBackgroundLibrary()
        }
        let visible = visibleGeneratedBackgroundLibraryRecords()
        if !visible.isEmpty {
            return visible.map(\.activePath)
        }
        return scannedGeneratedBackgroundPaths()
    }

    func visibleGeneratedBackgroundLibraryRecords() -> [GeneratedBackgroundLibraryRecord] {
        placesWorkflowLibrary.generatedImageRecords.sorted { lhs, rhs in
            let lhsRank = generatedBackgroundLibrarySortRank(for: lhs.activePath)
            let rhsRank = generatedBackgroundLibrarySortRank(for: rhs.activePath)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.activePath.localizedCaseInsensitiveCompare(rhs.activePath) == .orderedAscending
        }
    }

    func generatedBackgroundRecords(
        flagFilter: GeneratedBackgroundFlagFilterMode = .all,
        minimumRating: Int? = nil,
        workflowFilter: GeneratedBackgroundWorkflowFilterMode = .all,
        searchText: String = ""
    ) -> [GeneratedBackgroundLibraryRecord] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return visibleGeneratedBackgroundLibraryRecords().filter { record in
            switch workflowFilter {
            case .all:
                break
            case .photorealistic where record.workflow != .photorealistic:
                return false
            case .animated where record.workflow != .animated:
                return false
            default:
                break
            }

            switch flagFilter {
            case .all:
                break
            case .unflagged:
                guard !record.isRejected else { return false }
            case .rejected:
                guard record.isRejected else { return false }
            }

            if let minimumRating {
                guard (record.rating ?? 0) >= minimumRating else { return false }
            }

            guard !trimmedSearch.isEmpty else { return true }
            let haystack = [
                record.activePath,
                record.summary,
                record.sourcePrompt ?? "",
                record.keywords.joined(separator: " ")
            ]
            .joined(separator: " ")
            .lowercased()
            return haystack.contains(trimmedSearch)
        }
    }

    func generatedBackgroundReferencePriority(for path: String) -> Int {
        guard let record = generatedBackgroundRecord(for: path) else { return 0 }
        if record.isRejected { return -100 }
        return (record.rating ?? 0) * 10 + max(0, 5 - min(record.duplicatePaths.count, 5))
    }

    func preferredPlaceContinuityImagePath(for place: BackgroundPlate, workflow: PlaceWorkflowMode) -> String? {
        let nodeCanon = worldNodes(placeID: place.id)
            .compactMap { $0.approvedImagePath(for: workflow) }
            .first
        if let nodeCanon {
            return nodeCanon
        }

        let approved = place.approvedImagePath(for: workflow)
        let candidates = place.imagePaths(for: workflow)
        let ranked = candidates.sorted { lhs, rhs in
            let lhsPriority = generatedBackgroundReferencePriority(for: lhs)
            let rhsPriority = generatedBackgroundReferencePriority(for: rhs)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        if let approved,
           generatedBackgroundReferencePriority(for: approved) >= 0 {
            return approved
        }

        if let preferred = ranked.first(where: { generatedBackgroundReferencePriority(for: $0) >= 0 }) {
            return preferred
        }

        return approved ?? ranked.first
    }

    func worldRoutes(for placeID: UUID? = nil) -> [PlaceWorldRoute] {
        placesWorkflowLibrary.worldGraph.routes
            .filter { placeID == nil || $0.placeID == placeID }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func worldRoute(for routeID: UUID?) -> PlaceWorldRoute? {
        guard let routeID else { return nil }
        return placesWorkflowLibrary.worldGraph.routes.first { $0.id == routeID }
    }

    func worldNodes(routeID: UUID? = nil, placeID: UUID? = nil) -> [PlaceWorldNode] {
        placesWorkflowLibrary.worldGraph.nodes
            .filter { node in
                (routeID == nil || node.routeID == routeID) &&
                (placeID == nil || node.placeID == placeID)
            }
            .sorted { lhs, rhs in
                if lhs.sequenceIndex != rhs.sequenceIndex {
                    return lhs.sequenceIndex < rhs.sequenceIndex
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func worldNode(for nodeID: UUID?) -> PlaceWorldNode? {
        guard let nodeID else { return nil }
        return placesWorkflowLibrary.worldGraph.nodes.first { $0.id == nodeID }
    }

    func placeWorldNodeCount(_ placeID: UUID) -> Int {
        worldNodes(placeID: placeID).count
    }

    func placePendingReviewCount(_ placeID: UUID) -> Int {
        pendingContinuityReviews()
            .filter { review in worldNode(for: review.nodeID)?.placeID == placeID }
            .count
    }

    func routeWorldNodeCount(_ routeID: UUID) -> Int {
        worldNodes(routeID: routeID).count
    }

    func routePendingReviewCount(_ routeID: UUID, workflow: PlaceWorkflowMode? = nil) -> Int {
        pendingContinuityReviews(routeID: routeID, workflow: workflow).count
    }

    func worldGenerationBatches(
        routeID: UUID? = nil,
        workflow: PlaceWorkflowMode? = nil,
        placeID: UUID? = nil
    ) -> [PlaceWorldGenerationBatch] {
        placesWorkflowLibrary.worldGenerationBatches
            .filter { batch in
                (routeID == nil || batch.routeID == routeID) &&
                (workflow == nil || batch.workflow == workflow) &&
                (placeID == nil || batch.placeID == placeID)
            }
            .sorted { lhs, rhs in
                if lhs.submittedAt != rhs.submittedAt {
                    return lhs.submittedAt > rhs.submittedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func latestWorldGenerationBatch(
        routeID: UUID? = nil,
        workflow: PlaceWorkflowMode? = nil,
        placeID: UUID? = nil
    ) -> PlaceWorldGenerationBatch? {
        worldGenerationBatches(routeID: routeID, workflow: workflow, placeID: placeID).first
    }

    func activeWorldGenerationBatchCount(
        routeID: UUID? = nil,
        workflow: PlaceWorkflowMode? = nil,
        placeID: UUID? = nil
    ) -> Int {
        worldGenerationBatches(routeID: routeID, workflow: workflow, placeID: placeID)
            .filter { !$0.state.uppercased().contains("SUCCEEDED") && !$0.state.uppercased().contains("FAILED") && !$0.state.uppercased().contains("CANCELLED") }
            .count
    }

    func placeName(for placeID: UUID?) -> String {
        guard let placeID else { return "Unassigned" }
        return backgrounds.first(where: { $0.id == placeID })?.name ?? "Unknown Place"
    }

    func continuityReviews(
        routeID: UUID? = nil,
        workflow: PlaceWorkflowMode? = nil
    ) -> [PlaceContinuityReview] {
        placesWorkflowLibrary.continuityReviews
            .filter { review in
                (routeID == nil || review.routeID == routeID) &&
                (workflow == nil || review.workflow == workflow)
            }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status { return lhs.status.rawValue < rhs.status.rawValue }
                if lhs.overallScore != rhs.overallScore { return lhs.overallScore < rhs.overallScore }
                return lhs.analyzedAt > rhs.analyzedAt
            }
    }

    func pendingContinuityReviews(
        routeID: UUID? = nil,
        workflow: PlaceWorkflowMode? = nil
    ) -> [PlaceContinuityReview] {
        continuityReviews(routeID: routeID, workflow: workflow)
            .filter { $0.status == .pending && !$0.flags.isEmpty }
    }

    func latestContinuityReview(
        for nodeID: UUID,
        workflow: PlaceWorkflowMode
    ) -> PlaceContinuityReview? {
        continuityReviews(workflow: workflow)
            .filter { $0.nodeID == nodeID }
            .sorted { $0.analyzedAt > $1.analyzedAt }
            .first
    }

    func generatedBackgroundRecords(
        linkedToWorldNode nodeID: UUID,
        workflow: PlaceWorkflowMode? = nil
    ) -> [GeneratedBackgroundLibraryRecord] {
        visibleGeneratedBackgroundLibraryRecords()
            .filter { record in
                record.worldNodeID == nodeID && (workflow == nil || record.workflow == workflow)
            }
            .sorted { lhs, rhs in
                if lhs.canonStatus != rhs.canonStatus {
                    return lhs.canonStatus.rawValue > rhs.canonStatus.rawValue
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func preferredWorldNodeImagePath(
        nodeID: UUID,
        workflow: PlaceWorkflowMode
    ) -> String? {
        if let approved = worldNode(for: nodeID)?.approvedImagePath(for: workflow) {
            return approved
        }
        return generatedBackgroundRecords(linkedToWorldNode: nodeID, workflow: workflow).first?.activePath
    }

    @discardableResult
    func addWorldRoute(name: String? = nil, placeID: UUID? = nil) -> UUID {
        let route = PlaceWorldRoute(
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : "Route \(placesWorkflowLibrary.worldGraph.routes.count + 1)",
            placeID: placeID
        )
        placesWorkflowLibrary.worldGraph.routes.append(route)
        save(writePlaces: true)
        return route.id
    }

    func updateWorldRouteName(_ name: String, routeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.routes.firstIndex(where: { $0.id == routeID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        placesWorkflowLibrary.worldGraph.routes[index].name = trimmed
        save(writePlaces: true)
    }

    func updateWorldRouteNotes(_ notes: String, routeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.routes.firstIndex(where: { $0.id == routeID }) else { return }
        placesWorkflowLibrary.worldGraph.routes[index].notes = notes
        save(writePlaces: true)
    }

    func updateWorldRouteColor(_ colorHex: String, routeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.routes.firstIndex(where: { $0.id == routeID }) else { return }
        placesWorkflowLibrary.worldGraph.routes[index].colorHex = colorHex
        save(writePlaces: true)
    }

    func deleteWorldRoute(_ routeID: UUID) {
        let nodeIDs = Set(worldNodes(routeID: routeID).map(\.id))
        placesWorkflowLibrary.worldGraph.routes.removeAll { $0.id == routeID }
        placesWorkflowLibrary.worldGraph.nodes.removeAll { nodeIDs.contains($0.id) }
        placesWorkflowLibrary.continuityReviews.removeAll { nodeIDs.contains($0.nodeID) || $0.routeID == routeID }
        for index in placesWorkflowLibrary.generatedImageRecords.indices where nodeIDs.contains(placesWorkflowLibrary.generatedImageRecords[index].worldNodeID ?? UUID()) || placesWorkflowLibrary.generatedImageRecords[index].routeID == routeID {
            placesWorkflowLibrary.generatedImageRecords[index].worldNodeID = nil
            placesWorkflowLibrary.generatedImageRecords[index].routeID = nil
            placesWorkflowLibrary.generatedImageRecords[index].continuityReviewIDs.removeAll()
            placesWorkflowLibrary.generatedImageRecords[index].qaFlags.removeAll()
            if placesWorkflowLibrary.generatedImageRecords[index].canonStatus == .canon {
                placesWorkflowLibrary.generatedImageRecords[index].canonStatus = .candidate
            }
        }
        save(writePlaces: true)
    }

    @discardableResult
    func addWorldNode(
        routeID: UUID? = nil,
        placeID: UUID? = nil,
        title: String? = nil,
        mapPoint: WorldMapPoint = .init(),
        role: PlaceWorldNodeRole = .traverse
    ) -> UUID {
        let nextSequenceIndex = (worldNodes(routeID: routeID).map(\.sequenceIndex).max() ?? -1) + 1
        let node = PlaceWorldNode(
            routeID: routeID,
            placeID: placeID,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : "Node \(nextSequenceIndex + 1)",
            sequenceIndex: nextSequenceIndex,
            role: role,
            mapPoint: mapPoint
        )
        placesWorkflowLibrary.worldGraph.nodes.append(node)
        save(writePlaces: true)
        return node.id
    }

    func deleteWorldNode(_ nodeID: UUID) {
        placesWorkflowLibrary.worldGraph.nodes.removeAll { $0.id == nodeID }
        placesWorkflowLibrary.continuityReviews.removeAll { $0.nodeID == nodeID }
        for index in placesWorkflowLibrary.generatedImageRecords.indices where placesWorkflowLibrary.generatedImageRecords[index].worldNodeID == nodeID {
            placesWorkflowLibrary.generatedImageRecords[index].worldNodeID = nil
            placesWorkflowLibrary.generatedImageRecords[index].continuityReviewIDs.removeAll()
            placesWorkflowLibrary.generatedImageRecords[index].qaFlags.removeAll()
            if placesWorkflowLibrary.generatedImageRecords[index].canonStatus == .canon {
                placesWorkflowLibrary.generatedImageRecords[index].canonStatus = .candidate
            }
        }
        for index in placesWorkflowLibrary.worldGraph.nodes.indices {
            placesWorkflowLibrary.worldGraph.nodes[index].linkedNodeIDs.removeAll { $0 == nodeID }
        }
        save(writePlaces: true)
    }

    func updateWorldNodeTitle(_ title: String, nodeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].title = trimmed
        save(writePlaces: true)
    }

    func updateWorldNodeNotes(_ notes: String, nodeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].notes = notes
        save(writePlaces: true)
    }

    func updateWorldNodeRole(_ role: PlaceWorldNodeRole, nodeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].role = role
        save(writePlaces: true)
    }

    func updateWorldNodeMapPoint(_ mapPoint: WorldMapPoint, nodeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].mapPoint = mapPoint
        save(writePlaces: true)
    }

    func updateWorldNodeCameraPose(_ pose: WorldCameraPose, nodeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].cameraPose = pose
        save(writePlaces: true)
    }

    func updateWorldNodeLandmarkExpectations(
        expectedTitles: [String],
        forbiddenTitles: [String],
        nodeID: UUID
    ) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].expectedLandmarkTitles = expectedTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        placesWorkflowLibrary.worldGraph.nodes[index].forbiddenLandmarkTitles = forbiddenTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        save(writePlaces: true)
    }

    func updateWorldNodePlace(_ placeID: UUID?, nodeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].placeID = placeID
        save(writePlaces: true)
    }

    @discardableResult
    func upsertWorldPlaceAnchor(
        placeID: UUID,
        title: String,
        mapPoint: WorldMapPoint,
        role: PlaceWorldNodeRole = .landmark,
        shouldSave: Bool = true
    ) -> UUID {
        if let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: {
            $0.placeID == placeID && $0.routeID == nil && $0.role == .landmark
        }) {
            placesWorkflowLibrary.worldGraph.nodes[index].title = title
            placesWorkflowLibrary.worldGraph.nodes[index].mapPoint = mapPoint
            let nodeID = placesWorkflowLibrary.worldGraph.nodes[index].id
            adoptGeneratedBackgroundRecords(for: placeID, nodeID: nodeID)
            if shouldSave {
                save(writePlaces: true)
            }
            return nodeID
        }

        let node = PlaceWorldNode(
            routeID: nil,
            placeID: placeID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Anchor" : title,
            sequenceIndex: 0,
            role: role,
            mapPoint: mapPoint
        )
        placesWorkflowLibrary.worldGraph.nodes.append(node)
        adoptGeneratedBackgroundRecords(for: placeID, nodeID: node.id)
        if shouldSave {
            save(writePlaces: true)
        }
        return node.id
    }

    func updateWorldNodeSequenceIndex(_ sequenceIndex: Int, nodeID: UUID) {
        guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        placesWorkflowLibrary.worldGraph.nodes[index].sequenceIndex = max(0, sequenceIndex)
        save(writePlaces: true)
    }

    private func adoptGeneratedBackgroundRecords(for placeID: UUID, nodeID: UUID) {
        for index in placesWorkflowLibrary.generatedImageRecords.indices where placesWorkflowLibrary.generatedImageRecords[index].linkedPlaceID == placeID {
            if placesWorkflowLibrary.generatedImageRecords[index].worldNodeID == nil {
                placesWorkflowLibrary.generatedImageRecords[index].worldNodeID = nodeID
            }
        }
    }

    func setPlaceInteriorLink(
        _ placeID: UUID,
        linkedExteriorPlaceID: UUID?,
        buildingAnchorNodeID: UUID?,
        shouldSave: Bool = true
    ) {
        guard let placeIndex = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        backgrounds[placeIndex].linkedExteriorPlaceID = linkedExteriorPlaceID
        backgrounds[placeIndex].buildingAnchorNodeID = buildingAnchorNodeID
        if let buildingAnchorNodeID {
            for recordIndex in placesWorkflowLibrary.generatedImageRecords.indices
            where placesWorkflowLibrary.generatedImageRecords[recordIndex].linkedPlaceID == placeID
                && placesWorkflowLibrary.generatedImageRecords[recordIndex].buildingAnchorNodeID == nil {
                placesWorkflowLibrary.generatedImageRecords[recordIndex].buildingAnchorNodeID = buildingAnchorNodeID
            }
        }
        if shouldSave {
            save(writePlaces: true)
        }
    }

    func linkWorldNodes(_ nodeIDs: [UUID]) {
        let uniqueIDs = Array(Set(nodeIDs))
        guard uniqueIDs.count >= 2 else { return }
        for nodeID in uniqueIDs {
            guard let index = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            let others = uniqueIDs.filter { $0 != nodeID }
            placesWorkflowLibrary.worldGraph.nodes[index].linkedNodeIDs = Array(Set(placesWorkflowLibrary.worldGraph.nodes[index].linkedNodeIDs + others))
        }
        save(writePlaces: true)
    }

    func attachGeneratedBackgroundRecord(
        _ recordID: UUID,
        toWorldNodeID nodeID: UUID?,
        routeID: UUID?,
        placeID: UUID?,
        pose: WorldCameraPose?,
        mapPoint: WorldMapPoint?,
        canonStatus: WorldCanonStatus = .candidate,
        placementStatus: GeneratedBackgroundMapPlacementStatus? = nil,
        buildingAnchorNodeID: UUID? = nil
    ) {
        guard let recordIndex = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        placesWorkflowLibrary.generatedImageRecords[recordIndex].worldNodeID = nodeID
        placesWorkflowLibrary.generatedImageRecords[recordIndex].routeID = routeID
        placesWorkflowLibrary.generatedImageRecords[recordIndex].linkedPlaceID = placeID
        if let pose {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].cameraPose = pose
        }
        if let mapPoint {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPoint = mapPoint.clamped()
        }
        if let buildingAnchorNodeID {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].buildingAnchorNodeID = buildingAnchorNodeID
        }
        if let placementStatus {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPlacementStatus = placementStatus
            placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPlacementConfirmedAt = placementStatus == .confirmed ? Date() : nil
        } else if mapPoint != nil || pose != nil,
                  placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPlacementStatus == .unplaced {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPlacementStatus = .inferred
        }
        placesWorkflowLibrary.generatedImageRecords[recordIndex].canonStatus = canonStatus
        placesWorkflowLibrary.generatedImageRecords[recordIndex].updatedAt = Date()
        save(writePlaces: true)
    }

    func updateGeneratedBackgroundPlacement(
        _ recordID: UUID,
        mapPoint: WorldMapPoint?,
        pose: WorldCameraPose? = nil,
        worldNodeID: UUID? = nil,
        routeID: UUID? = nil,
        placeID: UUID? = nil,
        buildingAnchorNodeID: UUID? = nil,
        status: GeneratedBackgroundMapPlacementStatus = .confirmed
    ) {
        guard let recordIndex = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        if let worldNodeID {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].worldNodeID = worldNodeID
        }
        if let routeID {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].routeID = routeID
        }
        if let placeID {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].linkedPlaceID = placeID
        }
        if let pose {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].cameraPose = pose
        }
        if let mapPoint {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPoint = mapPoint.clamped()
        } else if status == .unplaced {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPoint = nil
            if pose == nil {
                placesWorkflowLibrary.generatedImageRecords[recordIndex].cameraPose = nil
            }
        }
        if let buildingAnchorNodeID {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].buildingAnchorNodeID = buildingAnchorNodeID
        }
        placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPlacementStatus = status
        placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPlacementConfirmedAt = status == .confirmed ? Date() : nil
        placesWorkflowLibrary.generatedImageRecords[recordIndex].updatedAt = Date()
        save(writePlaces: true)
    }

    func confirmGeneratedBackgroundPlacement(
        _ recordID: UUID,
        mapPoint: WorldMapPoint,
        pose: WorldCameraPose? = nil,
        worldNodeID: UUID? = nil,
        routeID: UUID? = nil,
        placeID: UUID? = nil,
        buildingAnchorNodeID: UUID? = nil
    ) {
        updateGeneratedBackgroundPlacement(
            recordID,
            mapPoint: mapPoint,
            pose: pose,
            worldNodeID: worldNodeID,
            routeID: routeID,
            placeID: placeID,
            buildingAnchorNodeID: buildingAnchorNodeID,
            status: .confirmed
        )
    }

    func setGeneratedBackgroundOrientation(
        _ orientationState: GeneratedBackgroundOrientationState,
        for recordID: UUID
    ) {
        guard let recordIndex = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        placesWorkflowLibrary.generatedImageRecords[recordIndex].orientationState = orientationState
        placesWorkflowLibrary.generatedImageRecords[recordIndex].updatedAt = Date()
        save(writePlaces: true)
    }

    func linkGeneratedBackgroundRecord(
        _ recordID: UUID,
        toBuildingAnchorNodeID buildingAnchorNodeID: UUID?,
        placeID: UUID? = nil
    ) {
        guard let recordIndex = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        placesWorkflowLibrary.generatedImageRecords[recordIndex].buildingAnchorNodeID = buildingAnchorNodeID
        if let placeID {
            placesWorkflowLibrary.generatedImageRecords[recordIndex].linkedPlaceID = placeID
        }
        placesWorkflowLibrary.generatedImageRecords[recordIndex].updatedAt = Date()
        save(writePlaces: true)
    }

    func generatedBackgroundPlacementCoverage(
        placeID: UUID? = nil
    ) -> (total: Int, placed: Int, confirmed: Int, anchored: Int, mirrored: Int) {
        let records = placesWorkflowLibrary.generatedImageRecords.filter { record in
            guard let placeID else { return true }
            return record.linkedPlaceID == placeID
        }
        return (
            total: records.count,
            placed: records.count(where: { $0.mapPoint != nil }),
            confirmed: records.count(where: { $0.mapPlacementStatus == .confirmed }),
            anchored: records.count(where: { $0.buildingAnchorNodeID != nil }),
            mirrored: records.count(where: { $0.orientationState == .mirrored })
        )
    }

    func setCanonWorldNodeImage(
        _ path: String,
        nodeID: UUID,
        workflow: PlaceWorkflowMode
    ) {
        guard let nodeIndex = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let normalizedPath = normalizedCharacterAssetPath(path) ?? path
        switch workflow {
        case .photorealistic:
            placesWorkflowLibrary.worldGraph.nodes[nodeIndex].approvedPhotorealImagePath = normalizedPath
        case .animated:
            placesWorkflowLibrary.worldGraph.nodes[nodeIndex].approvedAnimatedImagePath = normalizedPath
        }

        for index in placesWorkflowLibrary.generatedImageRecords.indices where placesWorkflowLibrary.generatedImageRecords[index].worldNodeID == nodeID && placesWorkflowLibrary.generatedImageRecords[index].workflow == workflow {
            placesWorkflowLibrary.generatedImageRecords[index].canonStatus = placesWorkflowLibrary.generatedImageRecords[index].activePath == normalizedPath ? .canon : .candidate
        }
        save(writePlaces: true)
    }

    func updateContinuityReviewStatus(
        _ status: PlaceContinuityReviewStatus,
        reviewID: UUID
    ) {
        guard let reviewIndex = placesWorkflowLibrary.continuityReviews.firstIndex(where: { $0.id == reviewID }) else { return }
        placesWorkflowLibrary.continuityReviews[reviewIndex].status = status
        save(writePlaces: true)
    }

    func registerWorldGenerationBatch(_ batch: PlaceWorldGenerationBatch) {
        let normalized = normalizePlaceWorldGenerationBatch(batch)
        if let index = matchingWorldGenerationBatchIndex(for: normalized, in: placesWorkflowLibrary.worldGenerationBatches) {
            placesWorkflowLibrary.worldGenerationBatches[index] = mergedPlaceWorldGenerationBatch(
                existing: placesWorkflowLibrary.worldGenerationBatches[index],
                incoming: normalized
            )
        } else {
            placesWorkflowLibrary.worldGenerationBatches.append(normalized)
        }
        save(writePlaces: true)
    }

    func refreshPlaceWorldGenerationBatches() {
        let existing = placesWorkflowLibrary.worldGenerationBatches.map(normalizePlaceWorldGenerationBatch)
        var batches = mergePlaceWorldGenerationBatches(
            existing: existing,
            discovered: discoveredPlaceWorldGenerationBatchesOnDisk()
        )

        var didChange = batches != existing
        var shouldResyncGeneratedLibrary = false

        for index in batches.indices {
            guard let metadataPath = batches[index].metadataPath,
                  let metadataURL = resolvedCharacterAssetURL(for: metadataPath)
                    ?? (metadataPath.hasPrefix("/") ? URL(fileURLWithPath: metadataPath) : nil),
                  let data = try? Data(contentsOf: metadataURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let latestStatus = json["latest_status"] as? [String: Any]
            let resultsSummary = placeWorldGenerationBatchResultsSummary(
                from: json,
                batch: batches[index]
            )

            let state = (latestStatus?["state"] as? String)
                ?? (json["batch_state"] as? String)
                ?? batches[index].state
            if batches[index].state != state {
                batches[index].state = state
                didChange = true
            }

            let batchName = trimmedOrNil((latestStatus?["batch_name"] as? String) ?? (json["batch_name"] as? String))
            if batches[index].batchName != batchName {
                batches[index].batchName = batchName
                didChange = true
            }

            let submittedAt = batchStatusDate(json["submitted_at"])
                ?? batchStatusDate(json["last_status_check"])
                ?? batches[index].submittedAt
            if batches[index].submittedAt != submittedAt {
                batches[index].submittedAt = submittedAt
                didChange = true
            }

            let lastCheckedAt = batchStatusDate(json["last_status_check"]) ?? Date()
            if batches[index].lastCheckedAt != lastCheckedAt {
                batches[index].lastCheckedAt = lastCheckedAt
                didChange = true
            }

            let remoteUpdatedAt = batchStatusDate(latestStatus?["update_time"])
            if batches[index].remoteUpdatedAt != remoteUpdatedAt {
                batches[index].remoteUpdatedAt = remoteUpdatedAt
                didChange = true
            }

            let remoteStartedAt = batchStatusDate(latestStatus?["start_time"])
            if batches[index].remoteStartedAt != remoteStartedAt {
                batches[index].remoteStartedAt = remoteStartedAt
                didChange = true
            }

            let remoteFinishedAt = batchStatusDate(latestStatus?["end_time"])
            if batches[index].remoteFinishedAt != remoteFinishedAt {
                batches[index].remoteFinishedAt = remoteFinishedAt
                didChange = true
            }

            let promptCount = (json["prompt_count"] as? Int) ?? resultsSummary.rowCount
            if batches[index].promptCount != promptCount {
                batches[index].promptCount = promptCount
                didChange = true
            }

            let imageSize = (json["image_size"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? batches[index].imageSize
            if batches[index].imageSize != imageSize {
                batches[index].imageSize = imageSize
                didChange = true
            }

            let aspectRatio = trimmedOrNil(json["aspect_ratio"] as? String)
            if batches[index].aspectRatio != aspectRatio {
                batches[index].aspectRatio = aspectRatio
                didChange = true
            }

            if let rawModel = (json["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let model = GeminiModel(rawValue: rawModel),
               batches[index].model != model {
                batches[index].model = model
                didChange = true
            }

            let displayName = trimmedOrNil((latestStatus?["display_name"] as? String) ?? (json["display_name"] as? String))
            if let displayName, !displayName.isEmpty, batches[index].title != displayName {
                batches[index].title = displayName
                didChange = true
            }

            let generatedImagePaths = normalizedCharacterAssetPaths(resultsSummary.decodedImagePaths)
            if batches[index].generatedImagePaths != generatedImagePaths {
                batches[index].generatedImagePaths = generatedImagePaths
                didChange = true
                shouldResyncGeneratedLibrary = true
            }

            if batches[index].successCount != resultsSummary.successCount {
                batches[index].successCount = resultsSummary.successCount
                didChange = true
            }

            if batches[index].failureCount != resultsSummary.errorCount {
                batches[index].failureCount = resultsSummary.errorCount
                didChange = true
            }

            if batches[index].failures != resultsSummary.failures {
                batches[index].failures = resultsSummary.failures
                didChange = true
            }

            let lastErrorMessage = trimmedOrNil(
                ((latestStatus?["error"] as? [String: Any])?["message"] as? String)
                ?? ((latestStatus?["error"] as? [String: Any])?["details"] as? String)
                ?? resultsSummary.failures.first?.message
            )
            if batches[index].lastErrorMessage != lastErrorMessage {
                batches[index].lastErrorMessage = lastErrorMessage
                didChange = true
            }

            if batches[index].placeID == nil {
                let inferredPlaceID = batches[index].routeID.flatMap { worldRoute(for: $0)?.placeID }
                    ?? batches[index].nodeIDs.compactMap { worldNode(for: $0)?.placeID }.first
                if batches[index].placeID != inferredPlaceID {
                    batches[index].placeID = inferredPlaceID
                    didChange = true
                }
            }
        }

        if batches != placesWorkflowLibrary.worldGenerationBatches {
            placesWorkflowLibrary.worldGenerationBatches = batches
        }

        if shouldResyncGeneratedLibrary {
            syncGeneratedBackgroundLibrary()
        }

        let linkageChanged = reconcilePlaceWorldBatchGeneratedImageLinkage()
        if didChange || linkageChanged {
            save(writePlaces: true)
        }
    }

    func analyzeWorldContinuity(
        routeID: UUID,
        workflow: PlaceWorkflowMode
    ) async {
        let nodes = worldNodes(routeID: routeID)
        guard !nodes.isEmpty else { return }

        let analyzer = PlaceWorldContinuityAnalyzer()
        var newReviews: [PlaceContinuityReview] = []

        for node in nodes {
            guard let candidatePath = preferredWorldNodeImagePath(nodeID: node.id, workflow: workflow),
                  let candidateURL = resolvedCharacterAssetURL(for: candidatePath)
                    ?? (candidatePath.hasPrefix("/") ? URL(fileURLWithPath: candidatePath) : nil) else {
                continue
            }

            let routeNeighbors = nodes.filter { other in
                other.id != node.id && abs(other.sequenceIndex - node.sequenceIndex) <= 1
            }
            let linkedNeighbors = node.linkedNodeIDs.compactMap { linkedID in
                worldNode(for: linkedID)
            }
            let neighbors = Array(Dictionary(uniqueKeysWithValues: (routeNeighbors + linkedNeighbors).map { ($0.id, $0) }).values)
                .sorted { $0.sequenceIndex < $1.sequenceIndex }

            let neighborInputs: [PlaceWorldContinuityAnalyzer.NeighborInput] = neighbors.compactMap { neighbor in
                guard let path = preferredWorldNodeImagePath(nodeID: neighbor.id, workflow: workflow),
                      let url = resolvedCharacterAssetURL(for: path)
                        ?? (path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil) else {
                    return nil
                }
                return .init(
                    nodeID: neighbor.id,
                    imagePath: path,
                    imageURL: url,
                    pose: neighbor.cameraPose,
                    mapPoint: neighbor.mapPoint
                )
            }

            let analysis = await analyzer.analyze(
                candidateURL: candidateURL,
                candidatePath: candidatePath,
                candidatePose: node.cameraPose,
                candidatePoint: node.mapPoint,
                expectedLandmarkTitles: node.expectedLandmarkTitles,
                forbiddenLandmarkTitles: node.forbiddenLandmarkTitles,
                neighbors: neighborInputs
            )

            let recordID = generatedBackgroundRecord(for: candidatePath)?.id
            let review = PlaceContinuityReview(
                nodeID: node.id,
                routeID: routeID,
                workflow: workflow,
                candidateRecordID: recordID,
                candidateImagePath: candidatePath,
                comparedNodeIDs: analysis.comparedNodeIDs,
                comparedImagePaths: analysis.comparedImagePaths,
                similarityScore: analysis.similarityScore,
                histogramScore: analysis.histogramScore,
                metadataScore: analysis.metadataScore,
                overallScore: analysis.overallScore,
                flags: analysis.flags,
                status: analysis.flags.isEmpty ? .approved : .pending,
                analyzedAt: Date()
            )
            newReviews.append(review)
        }

        placesWorkflowLibrary.continuityReviews.removeAll { $0.routeID == routeID && $0.workflow == workflow }
        placesWorkflowLibrary.continuityReviews.append(contentsOf: newReviews)

        for review in newReviews {
            if let nodeIndex = placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == review.nodeID }) {
                placesWorkflowLibrary.worldGraph.nodes[nodeIndex].lastReviewID = review.id
            }
            if let recordID = review.candidateRecordID,
               let recordIndex = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) {
                placesWorkflowLibrary.generatedImageRecords[recordIndex].qaFlags = review.flags
                placesWorkflowLibrary.generatedImageRecords[recordIndex].continuityReviewIDs = [review.id]
                if !review.flags.isEmpty, placesWorkflowLibrary.generatedImageRecords[recordIndex].canonStatus == .canon {
                    placesWorkflowLibrary.generatedImageRecords[recordIndex].canonStatus = .candidate
                }
            }
        }
        save(writePlaces: true)
    }

    func generatedBackgroundRecord(for path: String) -> GeneratedBackgroundLibraryRecord? {
        let normalized = normalizedCharacterAssetPath(path)
            ?? projectRelativeCharacterAssetPath(from: path)
            ?? path
        return placesWorkflowLibrary.generatedImageRecords.first {
            $0.activePath == normalized || $0.duplicatePaths.contains(normalized) || $0.priorVersions.contains(where: { $0.path == normalized })
        }
    }

    func selectGeneratedBackgroundRecord(for path: String?) {
        guard let path else {
            selectedGeneratedBackgroundRecordID = nil
            return
        }
        if let record = generatedBackgroundRecord(for: path) {
            selectedGeneratedBackgroundRecordID = record.id
        }
    }

    func syncGeneratedBackgroundLibrary() {
        let discoveredPaths = scannedGeneratedBackgroundPaths()
        guard !discoveredPaths.isEmpty else {
            if !placesWorkflowLibrary.generatedImageRecords.isEmpty {
                statusMessage = "Generated background scan found no files, so existing review state was preserved instead of being cleared."
            }
            return
        }

        var records = placesWorkflowLibrary.generatedImageRecords
        let discoveredSet = Set(discoveredPaths)
        let discoveredFingerprints = Set(discoveredPaths.compactMap { generatedBackgroundFingerprint(for: $0) })
        var changed = false

        for index in records.indices {
            let normalizedActive = normalizedCharacterAssetPath(records[index].activePath) ?? records[index].activePath
            if records[index].activePath != normalizedActive {
                records[index].activePath = normalizedActive
                changed = true
            }
            let dedupedDuplicates = Array(Set(records[index].duplicatePaths.compactMap { normalizedCharacterAssetPath($0) ?? $0 }))
                .filter { $0 != records[index].activePath && discoveredSet.contains($0) }
            if dedupedDuplicates.sorted() != records[index].duplicatePaths.sorted() {
                records[index].duplicatePaths = dedupedDuplicates.sorted()
                changed = true
            }
            let normalizedHistory = records[index].priorVersions.map { version -> GeneratedBackgroundVersionRecord in
                var updated = version
                updated.path = normalizedCharacterAssetPath(version.path) ?? version.path
                return updated
            }
            if normalizedHistory != records[index].priorVersions {
                records[index].priorVersions = normalizedHistory
                changed = true
            }
            let fingerprint = generatedBackgroundFingerprint(for: records[index].activePath)
            if records[index].contentFingerprint != fingerprint {
                records[index].contentFingerprint = fingerprint
                changed = true
            }
        }

        let survivingRecords = records.filter { record in
            if discoveredSet.contains(record.activePath) { return true }
            if record.duplicatePaths.contains(where: { discoveredSet.contains($0) }) { return true }
            if record.priorVersions.contains(where: { discoveredSet.contains($0.path) }) { return true }
            if let fingerprint = record.contentFingerprint, discoveredFingerprints.contains(fingerprint) { return true }
            if shouldPersistGeneratedBackgroundReviewStateRecord(record) { return true }
            if shouldPersistPlacesWorldMapCanonRecord(record) { return true }
            return false
        }
        if survivingRecords.count != records.count {
            records = survivingRecords
            changed = true
        }

        let mergedRecords = mergeGeneratedBackgroundRecords(records, discoveredSet: discoveredSet)
        if mergedRecords != records {
            records = mergedRecords
            changed = true
        }

        for path in discoveredPaths {
            if records.contains(where: { $0.activePath == path || $0.duplicatePaths.contains(path) || $0.priorVersions.contains(where: { $0.path == path }) }) {
                continue
            }

            let fingerprint = generatedBackgroundFingerprint(for: path)
            if let matchIndex = records.firstIndex(where: { $0.contentFingerprint != nil && $0.contentFingerprint == fingerprint }) {
                let preferred = preferredGeneratedBackgroundPath(records[matchIndex].activePath, path)
                if preferred == path && records[matchIndex].activePath != path {
                    if !records[matchIndex].duplicatePaths.contains(records[matchIndex].activePath) {
                        records[matchIndex].duplicatePaths.append(records[matchIndex].activePath)
                    }
                    records[matchIndex].duplicatePaths.removeAll { $0 == path }
                    records[matchIndex].activePath = path
                } else if !records[matchIndex].duplicatePaths.contains(path) {
                    records[matchIndex].duplicatePaths.append(path)
                }
                records[matchIndex].updatedAt = Date()
                changed = true
                continue
            }

            let metadata = derivedGeneratedBackgroundMetadata(for: path)
            let generationMetadata = generationMetadata(for: path)
            records.append(
                GeneratedBackgroundLibraryRecord(
                    activePath: path,
                    workflow: inferredGeneratedBackgroundWorkflow(for: path),
                    duplicatePaths: [],
                    priorVersions: [],
                    contentFingerprint: fingerprint,
                    rating: nil,
                    isRejected: false,
                    draftEditNotes: "",
                    editHistory: [],
                    summary: metadata.summary,
                    keywords: metadata.keywords,
                    sourcePrompt: metadata.prompt,
                    linkedPlaceID: generationMetadata?.placeID,
                    worldNodeID: generationMetadata?.worldNodeID,
                    routeID: generationMetadata?.routeID,
                    cameraPose: generationMetadata?.cameraPose,
                    mapPoint: generationMetadata?.mapPoint,
                    mapPlacementStatus: generationMetadata?.mapPlacementStatus
                        ?? ((generationMetadata?.mapPoint != nil || generationMetadata?.cameraPose != nil) ? .inferred : .unplaced),
                    buildingAnchorNodeID: generationMetadata?.buildingAnchorNodeID,
                    orientationState: generationMetadata?.orientationState ?? .unknown,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            )
            changed = true
        }

        if hydrateGeneratedBackgroundSpatialMetadata(&records) {
            changed = true
        }
        if applyGeneratedBackgroundReviewStateOverrides(placesGeneratedReviewStateLibrary, to: &records) {
            changed = true
        }
        if applyPlacesWorldMapCanonOverrides(placesWorldMapCanonLibrary, to: &records) {
            changed = true
        }

        if changed {
            placesWorkflowLibrary.generatedImageRecords = records
            placesGeneratedReviewStateLibrary = rebuiltGeneratedBackgroundReviewStateLibrary(
                from: records,
                existing: placesGeneratedReviewStateLibrary
            )
            placesWorldMapCanonLibrary = rebuiltPlacesWorldMapCanonLibrary(
                from: records,
                existing: placesWorldMapCanonLibrary
            )
            if let selectedGeneratedBackgroundRecordID,
               !records.contains(where: { $0.id == selectedGeneratedBackgroundRecordID }) {
                self.selectedGeneratedBackgroundRecordID = nil
            }
            save(writePlaces: true)
        }
    }

    func setGeneratedBackgroundRating(_ rating: Int?, for recordID: UUID) {
        guard let index = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let clamped = rating.map { min(max($0, 1), 5) }
        placesWorkflowLibrary.generatedImageRecords[index].rating = clamped
        placesWorkflowLibrary.generatedImageRecords[index].updatedAt = Date()
        persistGeneratedBackgroundReviewStateNow()
        appendGeneratedBackgroundReviewEvent(action: "set_rating", record: placesWorkflowLibrary.generatedImageRecords[index])
        save(writePlaces: true)
    }

    func toggleGeneratedBackgroundRejected(_ recordID: UUID) {
        guard let index = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        placesWorkflowLibrary.generatedImageRecords[index].isRejected.toggle()
        placesWorkflowLibrary.generatedImageRecords[index].canonStatus = placesWorkflowLibrary.generatedImageRecords[index].isRejected ? .rejected : .candidate
        placesWorkflowLibrary.generatedImageRecords[index].updatedAt = Date()
        persistGeneratedBackgroundReviewStateNow()
        appendGeneratedBackgroundReviewEvent(action: "toggle_rejected", record: placesWorkflowLibrary.generatedImageRecords[index])
        save(writePlaces: true)
    }

    func updateGeneratedBackgroundRejectionNotes(_ notes: String, for recordID: UUID) {
        guard let index = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        guard placesWorkflowLibrary.generatedImageRecords[index].rejectionNotes != notes else { return }
        placesWorkflowLibrary.generatedImageRecords[index].rejectionNotes = notes
        placesWorkflowLibrary.generatedImageRecords[index].updatedAt = Date()
        persistGeneratedBackgroundReviewStateNow()
        appendGeneratedBackgroundReviewEvent(action: "set_rejection_notes", record: placesWorkflowLibrary.generatedImageRecords[index])
        scheduleDebouncedSave(writePlaces: true)
    }

    func updateGeneratedBackgroundEditNotes(_ notes: String, for recordID: UUID) {
        guard let index = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        guard placesWorkflowLibrary.generatedImageRecords[index].draftEditNotes != notes else { return }
        placesWorkflowLibrary.generatedImageRecords[index].draftEditNotes = notes
        placesWorkflowLibrary.generatedImageRecords[index].updatedAt = Date()
        persistGeneratedBackgroundReviewStateNow()
        appendGeneratedBackgroundReviewEvent(action: "set_edit_notes", record: placesWorkflowLibrary.generatedImageRecords[index])
        scheduleDebouncedSave(writePlaces: true)
    }

    func queueGeneratedBackgroundEdit(recordID: UUID, workflow: PlaceWorkflowMode) {
        guard let record = placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == recordID }) else { return }
        let instructions = record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return }

        if let queueIndex = placesWorkflowLibrary.pendingEditQueue.firstIndex(where: { $0.imageRecordID == recordID }) {
            placesWorkflowLibrary.pendingEditQueue[queueIndex].instructions = instructions
            placesWorkflowLibrary.pendingEditQueue[queueIndex].workflow = workflow
            placesWorkflowLibrary.pendingEditQueue[queueIndex].sourcePath = record.activePath
            placesWorkflowLibrary.pendingEditQueue[queueIndex].state = .queued
            placesWorkflowLibrary.pendingEditQueue[queueIndex].lastErrorMessage = nil
            placesWorkflowLibrary.pendingEditQueue[queueIndex].lastBatchJobID = nil
        } else {
            placesWorkflowLibrary.pendingEditQueue.append(
                PlaceImageEditQueueItem(
                    imageRecordID: recordID,
                    sourcePath: record.activePath,
                    workflow: workflow,
                    instructions: instructions
                )
            )
        }
        save(writePlaces: true)
    }

    func removeGeneratedBackgroundEditQueueItem(_ itemID: UUID) {
        placesWorkflowLibrary.pendingEditQueue.removeAll { $0.id == itemID }
        save(writePlaces: true)
    }

    func pendingGeneratedBackgroundEditQueueItem(for recordID: UUID) -> PlaceImageEditQueueItem? {
        placesWorkflowLibrary.pendingEditQueue.first { $0.imageRecordID == recordID }
    }

    func registerPlaceEditBatchJob(_ job: PlaceImageEditBatchJob) {
        if !placesWorkflowLibrary.editBatchJobs.contains(where: { $0.metadataPath == job.metadataPath || $0.batchName == job.batchName }) {
            placesWorkflowLibrary.editBatchJobs.append(job)
            for queueID in job.queueItemIDs {
                guard let queueIndex = placesWorkflowLibrary.pendingEditQueue.firstIndex(where: { $0.id == queueID }) else { continue }
                placesWorkflowLibrary.pendingEditQueue[queueIndex].state = .submitted
                placesWorkflowLibrary.pendingEditQueue[queueIndex].lastSubmittedAt = job.submittedAt
                placesWorkflowLibrary.pendingEditQueue[queueIndex].lastBatchJobID = job.id
                placesWorkflowLibrary.pendingEditQueue[queueIndex].lastErrorMessage = nil
            }
            save(writePlaces: true)
        }
    }

    func dismissPlaceEditBatchJob(_ jobID: UUID) {
        placesWorkflowLibrary.editBatchJobs.removeAll { $0.id == jobID }
        save(writePlaces: true)
    }

    func refreshPlaceEditBatchJobs() {
        var didChange = false
        var jobs = placesWorkflowLibrary.editBatchJobs

        for jobIndex in jobs.indices {
            guard let metadataURL = resolvedCharacterAssetURL(for: jobs[jobIndex].metadataPath)
                ?? (jobs[jobIndex].metadataPath.hasPrefix("/") ? URL(fileURLWithPath: jobs[jobIndex].metadataPath) : nil),
                  let data = try? Data(contentsOf: metadataURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let latestStatus = json["latest_status"] as? [String: Any]
            let state = (latestStatus?["state"] as? String)
                ?? (json["batch_state"] as? String)
                ?? jobs[jobIndex].state
            if jobs[jobIndex].state != state {
                jobs[jobIndex].state = state
                didChange = true
            }

            jobs[jobIndex].lastCheckedAt = Date()
            let remoteUpdatedAt = batchStatusDate(latestStatus?["update_time"])
            if jobs[jobIndex].remoteUpdatedAt != remoteUpdatedAt {
                jobs[jobIndex].remoteUpdatedAt = remoteUpdatedAt
                didChange = true
            }
            let remoteStartedAt = batchStatusDate(latestStatus?["start_time"])
            if jobs[jobIndex].remoteStartedAt != remoteStartedAt {
                jobs[jobIndex].remoteStartedAt = remoteStartedAt
                didChange = true
            }
            let remoteFinishedAt = batchStatusDate(latestStatus?["end_time"])
            if jobs[jobIndex].remoteFinishedAt != remoteFinishedAt {
                jobs[jobIndex].remoteFinishedAt = remoteFinishedAt
                didChange = true
            }

            let remoteSuccessfulCount = ((latestStatus?["completion_stats"] as? [String: Any])?["successful_count"] as? Int)
            if jobs[jobIndex].remoteSuccessfulCount != remoteSuccessfulCount {
                jobs[jobIndex].remoteSuccessfulCount = remoteSuccessfulCount
                didChange = true
            }

            if let error = latestStatus?["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? (error["details"] as? String)
                if jobs[jobIndex].lastErrorMessage != message {
                    jobs[jobIndex].lastErrorMessage = message
                    didChange = true
                }
                for queueID in jobs[jobIndex].queueItemIDs {
                    guard let queueIndex = placesWorkflowLibrary.pendingEditQueue.firstIndex(where: { $0.id == queueID }) else { continue }
                    placesWorkflowLibrary.pendingEditQueue[queueIndex].state = .failed
                    placesWorkflowLibrary.pendingEditQueue[queueIndex].lastErrorMessage = message
                    didChange = true
                }
            }

            let decodedPaths = (latestStatus?["decoded_images"] as? [String] ?? [])
                .compactMap { normalizedCharacterAssetPath($0) ?? $0 }
            if jobs[jobIndex].downloadedImagePaths != decodedPaths {
                jobs[jobIndex].downloadedImagePaths = normalizedCharacterAssetPaths(decodedPaths)
                didChange = true
            }

            for path in jobs[jobIndex].downloadedImagePaths {
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                guard let queueID = UUID(uuidString: stem),
                      let queueIndex = placesWorkflowLibrary.pendingEditQueue.firstIndex(where: { $0.id == queueID }),
                      let recordIndex = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == placesWorkflowLibrary.pendingEditQueue[queueIndex].imageRecordID }) else { continue }
                let item = placesWorkflowLibrary.pendingEditQueue[queueIndex]
                if item.state == .succeeded { continue }
                let metadata = generationMetadata(for: path)
                applyEditedGeneratedBackgroundPath(
                    path,
                    prompt: metadata?.prompt,
                    instructions: item.instructions,
                    to: placesWorkflowLibrary.generatedImageRecords[recordIndex].id,
                    clearQueueItemID: queueID
                )
                didChange = true
            }
        }

        if didChange {
            placesWorkflowLibrary.editBatchJobs = jobs
            save(writePlaces: true)
        }
    }

    func storeGeneratedBackgroundEditImage(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        filenameStem: String,
        recordID: UUID,
        workflow: PlaceWorkflowMode,
        aspectRatio: String,
        imageSize: String
    ) throws -> String {
        let animateURL = try requireAnimateURL()
        let directory = animateURL
            .appendingPathComponent("backgrounds")
            .appendingPathComponent("library-edits")
            .appendingPathComponent(recordID.uuidString.lowercased())
            .appendingPathComponent(workflow.rawValue)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let storedURL = directory.appendingPathComponent("\(filenameStem)-\(timestamp).png")
        try data.write(to: storedURL)
        try writeGenerationMetadata(
            prompt: prompt,
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            to: storedURL
        )
        let storedPath = projectRelativeCharacterAssetPath(from: storedURL.path)
            ?? normalizedCharacterAssetPath(storedURL.path)
            ?? storedURL.path
        syncGeneratedBackgroundLibrary()
        return storedPath
    }

    func submitGeneratedBackgroundEditImmediately(
        recordID: UUID,
        workflow: PlaceWorkflowMode? = nil
    ) async throws {
        guard isGeminiAllowed() else {
            throw GeminiImageService.ServiceError.masterSwitchOff
        }
        guard let record = placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == recordID }) else {
            return
        }
        let effectiveWorkflow = workflow ?? record.workflow
        let instructions = record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return }
        guard let sourceURL = resolvedCharacterAssetURL(for: record.activePath)
            ?? (record.activePath.hasPrefix("/") ? URL(fileURLWithPath: record.activePath) : nil),
              let reference = GeminiImageService.referenceImage(from: sourceURL) else {
            throw GeminiImageService.ServiceError.invalidResponse
        }

        let prompt = generatedBackgroundEditPrompt(
            for: record,
            workflow: effectiveWorkflow,
            instructions: instructions,
            useBatchLanguage: false
        )
        let aspectRatio = generationMetadata(for: record.activePath)?.aspectRatio ?? workflowConfig(for: effectiveWorkflow).aspectRatio
        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: prompt,
            referenceImages: [reference],
            model: .flash,
            aspectRatio: aspectRatio,
            imageSize: "2K"
        )
        logGeminiAPICall(endpoint: "image-edit", source: "AnimateStore.submitGeneratedBackgroundEditImmediately()")
        let result = try await service.generate(request: request, apiKey: geminiAPIKey)
        let storedPath = try storeGeneratedBackgroundEditImage(
            result.imageData,
            prompt: prompt,
            model: .flash,
            filenameStem: "edit-\(recordID.uuidString.lowercased())",
            recordID: recordID,
            workflow: effectiveWorkflow,
            aspectRatio: aspectRatio,
            imageSize: "2K"
        )
        applyEditedGeneratedBackgroundPath(
            storedPath,
            prompt: prompt,
            instructions: instructions,
            to: recordID
        )
    }

    func submitQueuedGeneratedBackgroundEditBatch(
        workflow: PlaceWorkflowMode
    ) async throws -> PlaceImageEditBatchJob {
        guard isGeminiAllowed() else {
            throw GeminiImageService.ServiceError.masterSwitchOff
        }

        let items = placesWorkflowLibrary.pendingEditQueue
            .filter { $0.workflow == workflow && ($0.state == .queued || $0.state == .failed) }
            .sorted { $0.queuedAt < $1.queuedAt }
        guard !items.isEmpty else {
            throw GeminiBatchService.BatchError.processFailed("No queued \(workflow.displayName.lowercased()) edits to submit.")
        }

        let animateURL = try requireAnimateURL()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let outputRoot = animateURL
            .appendingPathComponent("backgrounds")
            .appendingPathComponent("library-edits")
            .appendingPathComponent("batches")
            .appendingPathComponent("\(timestamp)-\(workflow.rawValue)-edits", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let prompts = try items.map { item -> GeminiBatchSubmissionPlan.PromptRequest in
            guard let record = placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == item.imageRecordID }) else {
                throw GeminiBatchService.BatchError.processFailed("Queued image record is missing.")
            }
            guard let sourceURL = resolvedCharacterAssetURL(for: record.activePath)
                ?? (record.activePath.hasPrefix("/") ? URL(fileURLWithPath: record.activePath) : nil) else {
                throw GeminiBatchService.BatchError.processFailed("Missing source image for queued edit.")
            }
            let sourcePath = projectRelativeCharacterAssetPath(from: sourceURL.path)
                ?? normalizedCharacterAssetPath(sourceURL.path)
                ?? sourceURL.path
            return GeminiBatchSubmissionPlan.PromptRequest(
                id: item.id.uuidString.lowercased(),
                title: URL(fileURLWithPath: record.activePath).deletingPathExtension().lastPathComponent,
                prompt: generatedBackgroundEditPrompt(
                    for: record,
                    workflow: workflow,
                    instructions: item.instructions,
                    useBatchLanguage: true
                ),
                referencePaths: [sourcePath]
            )
        }

        let submissionPlan = GeminiBatchSubmissionPlan(
            characterName: "Places Library",
            characterSlug: "places-library",
            displayName: "Places Library Edits (\(workflow.displayName))",
            model: .flash,
            aspectRatio: workflowConfig(for: workflow).aspectRatio,
            imageSize: "2K",
            outputRoot: outputRoot,
            prompts: prompts
        )

        let service = GeminiBatchService()
        let submission = try await service.submit(plan: submissionPlan, apiKey: geminiAPIKey)
        try service.launchWatchdog(metadataPath: submission.metadataPath, apiKey: geminiAPIKey)

        let metadataPath = projectRelativeCharacterAssetPath(from: submission.metadataPath.path)
            ?? normalizedCharacterAssetPath(submission.metadataPath.path)
            ?? submission.metadataPath.path
        let outputRootPath = projectRelativeCharacterAssetPath(from: submission.outputRoot.path)
            ?? normalizedCharacterAssetPath(submission.outputRoot.path)
            ?? submission.outputRoot.path

        let job = PlaceImageEditBatchJob(
            title: "Places Library Edits (\(workflow.displayName))",
            batchName: submission.batchName,
            metadataPath: metadataPath,
            outputRootPath: outputRootPath,
            state: submission.state,
            workflow: workflow,
            promptCount: submission.promptCount,
            submittedAt: submission.submittedAt,
            queueItemIDs: items.map(\.id)
        )
        registerPlaceEditBatchJob(job)
        refreshPlaceEditBatchJobs()
        return job
    }

    func applyEditedGeneratedBackgroundPath(
        _ newPath: String,
        prompt: String?,
        instructions: String,
        to recordID: UUID,
        clearQueueItemID: UUID? = nil
    ) {
        guard let recordIndex = placesWorkflowLibrary.generatedImageRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let normalizedNewPath = normalizedCharacterAssetPath(newPath)
            ?? projectRelativeCharacterAssetPath(from: newPath)
            ?? newPath
        let oldPath = placesWorkflowLibrary.generatedImageRecords[recordIndex].activePath
        guard oldPath != normalizedNewPath else { return }

        placesWorkflowLibrary.generatedImageRecords[recordIndex].priorVersions.insert(
            GeneratedBackgroundVersionRecord(path: oldPath),
            at: 0
        )
        placesWorkflowLibrary.generatedImageRecords[recordIndex].activePath = normalizedNewPath
        placesWorkflowLibrary.generatedImageRecords[recordIndex].workflow = inferredGeneratedBackgroundWorkflow(for: normalizedNewPath)
        placesWorkflowLibrary.generatedImageRecords[recordIndex].updatedAt = Date()
        placesWorkflowLibrary.generatedImageRecords[recordIndex].editHistory.insert(
            GeneratedBackgroundEditHistoryEntry(
                instructions: instructions,
                sourcePath: oldPath,
                resultPath: normalizedNewPath,
                prompt: prompt
            ),
            at: 0
        )
        if let prompt {
            let metadata = derivedGeneratedBackgroundMetadata(for: normalizedNewPath, fallbackPrompt: prompt)
            placesWorkflowLibrary.generatedImageRecords[recordIndex].summary = metadata.summary
            placesWorkflowLibrary.generatedImageRecords[recordIndex].keywords = metadata.keywords
            placesWorkflowLibrary.generatedImageRecords[recordIndex].sourcePrompt = prompt
        }
        placesWorkflowLibrary.generatedImageRecords[recordIndex].draftEditNotes = ""
        placesWorkflowLibrary.generatedImageRecords[recordIndex].contentFingerprint = generatedBackgroundFingerprint(for: normalizedNewPath)

        replaceBackgroundReferences(from: oldPath, to: normalizedNewPath)

        if let queueID = clearQueueItemID {
            placesWorkflowLibrary.pendingEditQueue.removeAll { $0.id == queueID }
        }

        selectedGeneratedBackgroundRecordID = recordID
        save(writePlaces: true)
    }

    private func scannedGeneratedBackgroundPaths() -> [String] {
        guard let animateURL else { return [] }
        let backgroundsRoot = animateURL.appendingPathComponent("backgrounds")
        guard FileManager.default.fileExists(atPath: backgroundsRoot.path) else { return [] }

        let urls = assetManager.listImages(in: backgroundsRoot)
        var seen: Set<String> = []
        var results: [String] = []

        for url in urls {
            let normalized = normalizedCharacterAssetPath(url.path)
                ?? projectRelativeCharacterAssetPath(from: url.path)
                ?? url.path
            guard shouldIncludeInGeneratedBackgroundLibrary(normalized) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            results.append(normalized)
        }

        return results.sorted { lhs, rhs in
            let lhsRank = generatedBackgroundLibrarySortRank(for: lhs)
            let rhsRank = generatedBackgroundLibrarySortRank(for: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func inferredGeneratedBackgroundWorkflow(for path: String) -> PlaceWorkflowMode {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        if normalized.contains("/animated/") || normalized.contains("-animated-") {
            return .animated
        }
        return .photorealistic
    }

    private func preferredGeneratedBackgroundPath(_ lhs: String, _ rhs: String) -> String {
        let lhsRank = generatedBackgroundLibrarySortRank(for: lhs)
        let rhsRank = generatedBackgroundLibrarySortRank(for: rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank ? lhs : rhs
        }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending ? lhs : rhs
    }

    private func generatedBackgroundFingerprint(for path: String) -> String? {
        guard let resolvedURL = resolvedCharacterAssetURL(for: path)
            ?? (path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil),
              let snapshot = fileSnapshot(for: resolvedURL),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        if let cached = generatedBackgroundFingerprintCache[resolvedURL.path],
           cached.snapshot == snapshot {
            return cached.digest
        }

        guard let data = try? Data(contentsOf: resolvedURL) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        generatedBackgroundFingerprintCache[resolvedURL.path] = (snapshot, digest)
        return digest
    }

    private func derivedGeneratedBackgroundMetadata(
        for path: String,
        fallbackPrompt: String? = nil
    ) -> (summary: String, keywords: [String], prompt: String?) {
        let metadata = generationMetadata(for: path)
        let prompt = fallbackPrompt ?? metadata?.prompt
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

        let summary: String
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            summary = String(trimmed.prefix(220))
        } else {
            summary = filename.replacingOccurrences(of: "-", with: " ")
        }

        let rawText = [filename, prompt ?? ""].joined(separator: " ").lowercased()
        let stopWords: Set<String> = [
            "the","and","with","from","that","this","into","there","their","about","after","before","while",
            "photo","image","cinematic","still","frame","shot","create","make","show","realistic","animated",
            "background","place","town","village","scene","view","using","preserve","same","look"
        ]
        let keywords = Array(
            Set(
                rawText
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 && !stopWords.contains($0) }
            )
        )
        .sorted()
        .prefix(16)

        return (summary, Array(keywords), prompt)
    }

    private func replaceBackgroundReferences(from oldPath: String, to newPath: String) {
        let normalizedOld = normalizedCharacterAssetPath(oldPath) ?? oldPath
        let normalizedNew = normalizedCharacterAssetPath(newPath) ?? newPath

        if placesWorkflowLibrary.masterMapImagePath == normalizedOld {
            placesWorkflowLibrary.masterMapImagePath = normalizedNew
        }
        for index in placesWorkflowLibrary.landmarkReferences.indices where placesWorkflowLibrary.landmarkReferences[index].imagePath == normalizedOld {
            placesWorkflowLibrary.landmarkReferences[index].imagePath = normalizedNew
        }

        for index in backgrounds.indices {
            backgrounds[index].imagePaths = backgrounds[index].imagePaths.map { $0 == normalizedOld ? normalizedNew : $0 }
            backgrounds[index].animatedImagePaths = backgrounds[index].animatedImagePaths.map { $0 == normalizedOld ? normalizedNew : $0 }
            if backgrounds[index].approvedImagePath == normalizedOld {
                backgrounds[index].approvedImagePath = normalizedNew
            }
            if backgrounds[index].animatedApprovedImagePath == normalizedOld {
                backgrounds[index].animatedApprovedImagePath = normalizedNew
            }
            for refIndex in backgrounds[index].referenceImages.indices where backgrounds[index].referenceImages[refIndex].imagePath == normalizedOld {
                backgrounds[index].referenceImages[refIndex].imagePath = normalizedNew
            }
            for angleIndex in backgrounds[index].angleImages.indices where backgrounds[index].angleImages[angleIndex].imagePath == normalizedOld {
                backgrounds[index].angleImages[angleIndex].imagePath = normalizedNew
            }
        }

        for index in placesWorkflowLibrary.worldGraph.nodes.indices {
            if placesWorkflowLibrary.worldGraph.nodes[index].approvedPhotorealImagePath == normalizedOld {
                placesWorkflowLibrary.worldGraph.nodes[index].approvedPhotorealImagePath = normalizedNew
            }
            if placesWorkflowLibrary.worldGraph.nodes[index].approvedAnimatedImagePath == normalizedOld {
                placesWorkflowLibrary.worldGraph.nodes[index].approvedAnimatedImagePath = normalizedNew
            }
        }

        for index in placesWorkflowLibrary.continuityReviews.indices {
            if placesWorkflowLibrary.continuityReviews[index].candidateImagePath == normalizedOld {
                placesWorkflowLibrary.continuityReviews[index].candidateImagePath = normalizedNew
            }
            placesWorkflowLibrary.continuityReviews[index].comparedImagePaths = placesWorkflowLibrary.continuityReviews[index].comparedImagePaths.map {
                $0 == normalizedOld ? normalizedNew : $0
            }
        }

        for index in placesWorkflowLibrary.worldGenerationBatches.indices {
            if placesWorkflowLibrary.worldGenerationBatches[index].metadataPath == normalizedOld {
                placesWorkflowLibrary.worldGenerationBatches[index].metadataPath = normalizedNew
            }
            if placesWorkflowLibrary.worldGenerationBatches[index].outputRootPath == normalizedOld {
                placesWorkflowLibrary.worldGenerationBatches[index].outputRootPath = normalizedNew
            }
            placesWorkflowLibrary.worldGenerationBatches[index].generatedImagePaths = placesWorkflowLibrary.worldGenerationBatches[index].generatedImagePaths.map {
                $0 == normalizedOld ? normalizedNew : $0
            }
        }

        for index in placesWorkflowLibrary.generatedImageRecords.indices {
            if placesWorkflowLibrary.generatedImageRecords[index].activePath == normalizedOld {
                placesWorkflowLibrary.generatedImageRecords[index].activePath = normalizedNew
            }
            placesWorkflowLibrary.generatedImageRecords[index].duplicatePaths = placesWorkflowLibrary.generatedImageRecords[index].duplicatePaths.map {
                $0 == normalizedOld ? normalizedNew : $0
            }
            placesWorkflowLibrary.generatedImageRecords[index].priorVersions = placesWorkflowLibrary.generatedImageRecords[index].priorVersions.map { version in
                var updated = version
                if updated.path == normalizedOld {
                    updated.path = normalizedNew
                }
                return updated
            }
        }
    }

    private func generatedBackgroundEditPrompt(
        for record: GeneratedBackgroundLibraryRecord,
        workflow: PlaceWorkflowMode,
        instructions: String,
        useBatchLanguage: Bool
    ) -> String {
        let config = workflowConfig(for: workflow)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = record.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = record.keywords.prefix(12).joined(separator: ", ")
        let bridgeConstraint = generatedBackgroundBridgeConstraint(for: record)

        let workflowLead: String
        switch workflow {
        case .photorealistic:
            workflowLead = "Edit this photoreal cinematic background image. Keep it looking like a real full-frame production still, not a matte painting, illustration, or fantasy concept image."
        case .animated:
            workflowLead = "Edit this animated background frame. Preserve the same location continuity and staging while keeping the Amira animated look."
        }

        return [
            useBatchLanguage ? "Create an edited replacement for the supplied image." : "Edit the supplied image.",
            workflowLead,
            "Preserve the same location, scale, geography, architectural layout, and overall composition unless the notes explicitly request a change.",
            config.lensDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            summary.isEmpty ? "" : "Current image summary: \(summary).",
            keywords.isEmpty ? "" : "Keywords: \(keywords).",
            bridgeConstraint,
            "Apply only these requested edits: \(trimmedInstructions)",
            "Keep human/building/bridge scale believable. Do not introduce mirrored geography, duplicate settlements, or extra structures on the wrong side of the river.",
            "Return a single final edited image."
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " ")
    }

    private func generatedBackgroundBridgeConstraint(for record: GeneratedBackgroundLibraryRecord) -> String {
        let emphasis = [
            record.activePath,
            record.summary,
            record.sourcePrompt ?? "",
            record.keywords.joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()

        guard emphasis.contains("bridge") else { return "" }
        return "Bridge continuity requirement: keep the entire top of the bridge completely flat and open. Remove any raised side stones, parapets, railings, curbs, guard edges, or protective walls from the bridge deck."
    }

    private func mergeGeneratedBackgroundRecords(
        _ records: [GeneratedBackgroundLibraryRecord],
        discoveredSet: Set<String>
    ) -> [GeneratedBackgroundLibraryRecord] {
        var merged: [GeneratedBackgroundLibraryRecord] = []
        var indexByKey: [String: Int] = [:]

        func preferredPlacementStatus(
            _ lhs: GeneratedBackgroundMapPlacementStatus,
            _ rhs: GeneratedBackgroundMapPlacementStatus
        ) -> GeneratedBackgroundMapPlacementStatus {
            let rank: [GeneratedBackgroundMapPlacementStatus: Int] = [
                .unplaced: 0,
                .inferred: 1,
                .confirmed: 2,
            ]
            return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
        }

        func merge(_ incoming: GeneratedBackgroundLibraryRecord, into existing: inout GeneratedBackgroundLibraryRecord) {
            let preferredPath = preferredGeneratedBackgroundPath(existing.activePath, incoming.activePath)
            if preferredPath != existing.activePath {
                var combinedDuplicates = existing.duplicatePaths
                combinedDuplicates.append(existing.activePath)
                combinedDuplicates.append(contentsOf: incoming.duplicatePaths)
                combinedDuplicates.append(incoming.activePath)
                existing.activePath = preferredPath
                existing.duplicatePaths = Array(Set(combinedDuplicates))
            } else {
                existing.duplicatePaths = Array(Set(existing.duplicatePaths + incoming.duplicatePaths + [incoming.activePath]))
            }

            existing.duplicatePaths.removeAll { $0 == existing.activePath || !discoveredSet.contains($0) }
            if existing.rating == nil || (incoming.updatedAt >= existing.updatedAt && incoming.rating != nil) {
                existing.rating = incoming.rating
            }
            if incoming.updatedAt >= existing.updatedAt {
                existing.isRejected = incoming.isRejected
            }
            if incoming.updatedAt >= existing.updatedAt {
                existing.rejectionNotes = incoming.rejectionNotes
                existing.draftEditNotes = incoming.draftEditNotes
            } else {
                if existing.rejectionNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !incoming.rejectionNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    existing.rejectionNotes = incoming.rejectionNotes
                }
                if existing.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !incoming.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    existing.draftEditNotes = incoming.draftEditNotes
                }
            }
            if incoming.updatedAt > existing.updatedAt {
                if !incoming.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    existing.summary = incoming.summary
                }
                if !incoming.keywords.isEmpty {
                    existing.keywords = incoming.keywords
                }
                if let prompt = incoming.sourcePrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    existing.sourcePrompt = prompt
                }
            }
            let mergedPriorVersions = Dictionary(
                (existing.priorVersions + incoming.priorVersions).map { ($0.path, $0) },
                uniquingKeysWith: { lhs, rhs in
                    lhs.supersededAt > rhs.supersededAt ? lhs : rhs
                }
            )
            existing.priorVersions = Array(mergedPriorVersions.values)
                .sorted { $0.supersededAt > $1.supersededAt }

            var mergedEditHistory: [String: GeneratedBackgroundEditHistoryEntry] = [:]
            for entry in existing.editHistory {
                mergedEditHistory[(entry.resultPath ?? "") + "|" + entry.instructions] = entry
            }
            for entry in incoming.editHistory {
                let key = (entry.resultPath ?? "") + "|" + entry.instructions
                if let current = mergedEditHistory[key] {
                    mergedEditHistory[key] = current.createdAt > entry.createdAt ? current : entry
                } else {
                    mergedEditHistory[key] = entry
                }
            }
            existing.editHistory = Array(mergedEditHistory.values).sorted { $0.createdAt > $1.createdAt }
            existing.keywords = Array(Set(existing.keywords + incoming.keywords)).sorted()
            existing.updatedAt = max(existing.updatedAt, incoming.updatedAt)
            existing.createdAt = min(existing.createdAt, incoming.createdAt)
            existing.workflow = inferredGeneratedBackgroundWorkflow(for: existing.activePath)
            existing.contentFingerprint = existing.contentFingerprint ?? incoming.contentFingerprint
            existing.linkedPlaceID = existing.linkedPlaceID ?? incoming.linkedPlaceID
            existing.worldNodeID = existing.worldNodeID ?? incoming.worldNodeID
            existing.routeID = existing.routeID ?? incoming.routeID
            let winningPlacementStatus = preferredPlacementStatus(existing.mapPlacementStatus, incoming.mapPlacementStatus)
            if winningPlacementStatus != existing.mapPlacementStatus {
                existing.mapPlacementStatus = winningPlacementStatus
            }
            if winningPlacementStatus == incoming.mapPlacementStatus {
                existing.cameraPose = incoming.cameraPose ?? existing.cameraPose
                existing.mapPoint = incoming.mapPoint?.clamped() ?? existing.mapPoint?.clamped()
                existing.mapPlacementConfirmedAt = incoming.mapPlacementConfirmedAt ?? existing.mapPlacementConfirmedAt
            } else {
                existing.cameraPose = existing.cameraPose ?? incoming.cameraPose
                existing.mapPoint = existing.mapPoint?.clamped() ?? incoming.mapPoint?.clamped()
                existing.mapPlacementConfirmedAt = existing.mapPlacementConfirmedAt ?? incoming.mapPlacementConfirmedAt
            }
            existing.buildingAnchorNodeID = existing.buildingAnchorNodeID ?? incoming.buildingAnchorNodeID
            if incoming.orientationState != .unknown,
               (existing.orientationState == .unknown || incoming.updatedAt >= existing.updatedAt) {
                existing.orientationState = incoming.orientationState
            }
            existing.qaFlags = Array(Set(existing.qaFlags + incoming.qaFlags))
            existing.continuityReviewIDs = Array(Set(existing.continuityReviewIDs + incoming.continuityReviewIDs))
            let statuses = [existing.canonStatus, incoming.canonStatus]
            if statuses.contains(.canon) {
                existing.canonStatus = .canon
            } else if statuses.contains(.candidate) {
                existing.canonStatus = .candidate
            } else if statuses.contains(.rejected) {
                existing.canonStatus = .rejected
            } else {
                existing.canonStatus = .unreviewed
            }
        }

        for record in records {
            let mergeKey = record.contentFingerprint ?? generatedBackgroundFingerprint(for: record.activePath) ?? record.activePath
            if let existingIndex = indexByKey[mergeKey] {
                var existing = merged[existingIndex]
                merge(record, into: &existing)
                merged[existingIndex] = existing
            } else {
                var normalized = record
                normalized.duplicatePaths = normalized.duplicatePaths.filter { $0 != normalized.activePath && discoveredSet.contains($0) }
                normalized.workflow = inferredGeneratedBackgroundWorkflow(for: normalized.activePath)
                if normalized.contentFingerprint == nil {
                    normalized.contentFingerprint = generatedBackgroundFingerprint(for: normalized.activePath)
                }
                merged.append(normalized)
                indexByKey[mergeKey] = merged.count - 1
            }
        }

        return merged
    }

    private func shouldIncludeInGeneratedBackgroundLibrary(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard normalized.contains("/backgrounds/") else { return false }

        if normalized.contains("/backgrounds/inspiration/") {
            return false
        }
        if normalized.contains("/backgrounds/continuity-pack/") {
            return false
        }
        if normalized.contains("/backgrounds/pipeline/catalog/") ||
            normalized.contains("/backgrounds/pipeline/catalog-snapshots/") ||
            normalized.contains("/backgrounds/pipeline/matrix/") ||
            normalized.contains("/backgrounds/pipeline/refs/") {
            return false
        }

        if normalized.contains("/backgrounds/places/") ||
            normalized.contains("/backgrounds/place-batches/") ||
            normalized.contains("/backgrounds/chosen-references/") ||
            normalized.contains("/backgrounds/pipeline/tests/") ||
            normalized.contains("/backgrounds/pipeline/batches/") {
            return !isCharacterCentricGeneratedBackgroundPath(normalized)
        }

        return false
    }

    private func isCharacterCentricGeneratedBackgroundPath(_ normalizedPath: String) -> Bool {
        let searchable = normalizedPath
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        let explicitCharacterMarkers = [
            "character-test",
            "character-study",
            "character-studies",
            "costume-test",
            "costume-study",
            "portrait",
            "headshot",
            "close-up",
            "closeup",
            "waist-up",
            "waistup",
            "full-body",
            "fullbody"
        ]
        if explicitCharacterMarkers.contains(where: searchable.contains) {
            return true
        }

        let actionMarkers = [
            "enters",
            "walks",
            "walking",
            "runs",
            "running",
            "stands",
            "standing",
            "falls",
            "falling",
            "scene",
            "continuity-test",
            "character"
        ]
        let characterTerms = knownGeneratedBackgroundCharacterTerms()
        guard !characterTerms.isEmpty else { return false }
        guard characterTerms.contains(where: { searchable.contains($0) }) else { return false }
        return actionMarkers.contains(where: searchable.contains)
    }

    private func knownGeneratedBackgroundCharacterTerms() -> [String] {
        let rawTerms = characters.flatMap { [$0.name, $0.owpSlug, $0.assetFolderSlug] }
        let cleaned = rawTerms
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "_", with: "-")
                    .replacingOccurrences(of: " ", with: "-")
            }
            .filter { !$0.isEmpty }
        return Array(Set(cleaned)).sorted()
    }

    private func hydrateGeneratedBackgroundSpatialMetadata(_ records: inout [GeneratedBackgroundLibraryRecord]) -> Bool {
        var didChange = false

        for index in records.indices {
            let inferred = inferredGeneratedBackgroundSpatialContext(for: records[index])

            if records[index].linkedPlaceID == nil, let placeID = inferred.placeID {
                records[index].linkedPlaceID = placeID
                didChange = true
            }
            if records[index].worldNodeID == nil, let worldNodeID = inferred.worldNodeID {
                records[index].worldNodeID = worldNodeID
                didChange = true
            }
            if records[index].routeID == nil, let routeID = inferred.routeID {
                records[index].routeID = routeID
                didChange = true
            }
            if records[index].cameraPose == nil, let cameraPose = inferred.cameraPose {
                records[index].cameraPose = cameraPose
                didChange = true
            }
            if records[index].mapPoint == nil, let mapPoint = inferred.mapPoint {
                records[index].mapPoint = mapPoint.clamped()
                if records[index].mapPlacementStatus == .unplaced {
                    records[index].mapPlacementStatus = .inferred
                }
                didChange = true
            } else if records[index].mapPoint != nil, records[index].mapPlacementStatus == .unplaced {
                records[index].mapPlacementStatus = .inferred
                didChange = true
            }
            if records[index].buildingAnchorNodeID == nil, let buildingAnchorNodeID = inferred.buildingAnchorNodeID {
                records[index].buildingAnchorNodeID = buildingAnchorNodeID
                didChange = true
            }
        }

        return didChange
    }

    private func inferredGeneratedBackgroundSpatialContext(
        for record: GeneratedBackgroundLibraryRecord
    ) -> (
        placeID: UUID?,
        worldNodeID: UUID?,
        routeID: UUID?,
        cameraPose: WorldCameraPose?,
        mapPoint: WorldMapPoint?,
        buildingAnchorNodeID: UUID?
    ) {
        let candidatePaths = Array(
            Set(
                [record.activePath]
                + record.duplicatePaths
                + record.priorVersions.map(\.path)
            )
        )
        .compactMap { normalizedCharacterAssetPath($0) ?? projectRelativeCharacterAssetPath(from: $0) ?? $0 }
        let candidatePathSet = Set(candidatePaths)

        let preferredPlaces: [BackgroundPlate]
        if let linkedPlaceID = record.linkedPlaceID,
           let place = backgrounds.first(where: { $0.id == linkedPlaceID }) {
            preferredPlaces = [place] + backgrounds.filter { $0.id != linkedPlaceID }
        } else {
            preferredPlaces = backgrounds
        }

        for place in preferredPlaces {
            if let angleImage = place.angleImages.first(where: { angleImage in
                let normalized = normalizedCharacterAssetPath(angleImage.imagePath)
                    ?? projectRelativeCharacterAssetPath(from: angleImage.imagePath)
                    ?? angleImage.imagePath
                return candidatePaths.contains(normalized)
            }) {
                let node = worldNode(for: angleImage.worldNodeID)
                return (
                    place.id,
                    angleImage.worldNodeID ?? node?.id,
                    angleImage.routeID ?? node?.routeID,
                    angleImage.cameraPose ?? node?.cameraPose,
                    angleImage.mapPoint ?? node?.mapPoint,
                    place.buildingAnchorNodeID
                        ?? place.linkedExteriorPlaceID.flatMap { exteriorID in
                            backgrounds.first(where: { $0.id == exteriorID })?.buildingAnchorNodeID
                        }
                )
            }

            let placePaths = Set(
                (
                    place.imagePaths
                    + place.animatedImagePaths
                    + [place.approvedImagePath, place.animatedApprovedImagePath].compactMap { $0 }
                )
                .compactMap { normalizedCharacterAssetPath($0) ?? projectRelativeCharacterAssetPath(from: $0) ?? $0 }
            )

            guard !candidatePathSet.isDisjoint(with: placePaths) else { continue }
            let node = worldNodes(placeID: place.id)
                .sorted { $0.sequenceIndex < $1.sequenceIndex }
                .first
            return (
                place.id,
                node?.id,
                node?.routeID,
                node?.cameraPose,
                node?.mapPoint,
                place.buildingAnchorNodeID
                    ?? place.linkedExteriorPlaceID.flatMap { exteriorID in
                        backgrounds.first(where: { $0.id == exteriorID })?.buildingAnchorNodeID
                    }
            )
        }

        let semanticKind = semanticGeneratedBackgroundSceneKind(for: record)
        if semanticKind != .mapReference,
           let matchedPlace = semanticGeneratedBackgroundPlaceMatch(
                for: record,
                preferredPlaces: preferredPlaces,
                sceneKind: semanticKind
           ) {
            let buildingAnchorNodeID = matchedPlace.buildingAnchorNodeID
                ?? matchedPlace.linkedExteriorPlaceID.flatMap { exteriorID in
                    backgrounds.first(where: { $0.id == exteriorID })?.buildingAnchorNodeID
                }
            let buildingAnchorNode = worldNode(for: buildingAnchorNodeID)
            let placeNodes = worldNodes(placeID: matchedPlace.id)
            let uniquePlaceNode = placeNodes.count == 1 ? placeNodes.first : nil
            let spatialNode = semanticKind == .interior ? buildingAnchorNode : (uniquePlaceNode ?? buildingAnchorNode)

            return (
                matchedPlace.id,
                semanticKind == .interior ? nil : spatialNode?.id,
                semanticKind == .interior ? nil : spatialNode?.routeID,
                spatialNode?.cameraPose,
                spatialNode?.mapPoint,
                buildingAnchorNodeID
            )
        }

        let fallbackAnchorNodeID: UUID? = {
            if let linkedPlaceID = record.linkedPlaceID,
               let place = backgrounds.first(where: { $0.id == linkedPlaceID }) {
                return place.buildingAnchorNodeID
                    ?? place.linkedExteriorPlaceID.flatMap { exteriorID in
                        backgrounds.first(where: { $0.id == exteriorID })?.buildingAnchorNodeID
                    }
            }
            return record.buildingAnchorNodeID
        }()

        return (
            record.linkedPlaceID,
            record.worldNodeID,
            record.routeID,
            record.cameraPose,
            record.mapPoint,
            fallbackAnchorNodeID
        )
    }

    private enum GeneratedBackgroundSemanticSceneKind {
        case exterior
        case interior
        case mapReference
        case designStudy
        case ambiguous
    }

    private func semanticGeneratedBackgroundSceneKind(
        for record: GeneratedBackgroundLibraryRecord
    ) -> GeneratedBackgroundSemanticSceneKind {
        let text = semanticGeneratedBackgroundText(for: record)
        let mapTerms = [
            "master map",
            "world map",
            "topdown",
            "top-down",
            "bird's-eye",
            "birds-eye",
            "satellite view",
            "orthographic"
        ]
        if mapTerms.contains(where: text.contains) {
            return .mapReference
        }

        let interiorTerms = [
            "interior",
            "room",
            "back room",
            "inside",
            "entryway",
            "threshold",
            "home",
            "clinic treatment",
            "treatment area",
            "operations tent",
            "comms tent",
            "briefing room",
            "bunk",
            "quiet moment"
        ]
        if interiorTerms.contains(where: text.contains) {
            return .interior
        }

        let designTerms = [
            "design",
            "study",
            "geometry",
            "profile",
            "documentary",
            "hero wide"
        ]
        if designTerms.contains(where: text.contains) {
            return .designStudy
        }

        return .exterior
    }

    private func semanticGeneratedBackgroundPlaceMatch(
        for record: GeneratedBackgroundLibraryRecord,
        preferredPlaces: [BackgroundPlate],
        sceneKind: GeneratedBackgroundSemanticSceneKind
    ) -> BackgroundPlate? {
        let text = semanticGeneratedBackgroundText(for: record)
        let stem = URL(fileURLWithPath: record.activePath)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        let scored = preferredPlaces.compactMap { place -> (BackgroundPlate, Double)? in
            let aliases = semanticGeneratedBackgroundPlaceAliases(for: place)
            let overlapScore = aliases.reduce(0.0) { partial, alias in
                guard !alias.isEmpty else { return partial }
                guard text.contains(alias) || stem.contains(alias) else { return partial }
                return partial + (alias.contains(" ") ? 1.2 : 0.45)
            }

            var score = overlapScore
            if sceneKind == .interior, !place.isExteriorLike {
                score += 0.8
            } else if sceneKind != .interior, place.isExteriorLike {
                score += 0.35
            }

            let loweredPlaceName = place.name.lowercased()
            if loweredPlaceName.contains("clinic"), text.contains("clinic") { score += 1.0 }
            if loweredPlaceName.contains("bridge"), text.contains("bridge") { score += 1.0 }
            if loweredPlaceName.contains("amira"), text.contains("amira") { score += 1.0 }
            if loweredPlaceName.contains("gathering"), text.contains("gathering") { score += 1.0 }
            if loweredPlaceName.contains("photo shop") || loweredPlaceName.contains("film shop"),
               text.contains("photo shop") || text.contains("film shop") || text.contains("photo lab") {
                score += 1.0
            }

            return score > 0 ? (place, score) : nil
        }
        .sorted { $0.1 > $1.1 }

        guard let best = scored.first else { return nil }
        let second = scored.dropFirst().first?.1 ?? 0
        guard best.1 >= 1.2, best.1 >= second + 0.35 else { return nil }
        return best.0
    }

    private func semanticGeneratedBackgroundPlaceAliases(for place: BackgroundPlate) -> [String] {
        var rawValues = [
            place.name,
            place.filename,
            place.notes,
            place.workflowPromptNotes,
            place.locationCategory
        ]
        rawValues.append(contentsOf: place.referenceImages.map(\.title))
        rawValues.append(contentsOf: place.referenceImages.map(\.notes))

        let specialAliases = semanticGeneratedBackgroundSpecialAliases(for: place.name)
        rawValues.append(contentsOf: specialAliases)

        return Array(
            Set(
                rawValues
                    .flatMap { value in
                        semanticGeneratedBackgroundAliasVariants(for: value)
                    }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }

    private func semanticGeneratedBackgroundSpecialAliases(for placeName: String) -> [String] {
        let lowered = placeName.lowercased()
        var aliases: [String] = []
        if lowered.contains("amira") && lowered.contains("home") {
            aliases.append(contentsOf: ["amira home", "amira's home", "home", "quiet moment"])
        }
        if lowered.contains("gathering") || lowered.contains("community center") || lowered.contains("mosque") {
            aliases.append(contentsOf: ["gathering space", "community center", "mosque", "courtyard"])
        }
        if lowered.contains("clinic") {
            aliases.append(contentsOf: ["clinic", "treatment area", "back room", "clinic doorway"])
        }
        if lowered.contains("photo shop") || lowered.contains("film shop") {
            aliases.append(contentsOf: ["photo shop", "film shop", "developing room", "photo lab"])
        }
        if lowered.contains("bridge") {
            aliases.append(contentsOf: ["bridge", "stone bridge", "midspan", "bridge ahead"])
        }
        if lowered.contains("shepherd") || lowered.contains("hut") {
            aliases.append(contentsOf: ["shepherd", "huts", "hillside"])
        }
        return aliases
    }

    private func semanticGeneratedBackgroundAliasVariants(for raw: String) -> [String] {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard !normalized.isEmpty else { return [] }

        var variants: Set<String> = [normalized]
        if normalized.contains("amira s") {
            variants.insert(normalized.replacingOccurrences(of: "amira s", with: "amira's"))
        }
        variants.formUnion(
            normalized
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 4 }
        )
        return Array(variants)
    }

    private func semanticGeneratedBackgroundText(for record: GeneratedBackgroundLibraryRecord) -> String {
        [
            record.activePath,
            URL(fileURLWithPath: record.activePath).deletingPathExtension().lastPathComponent,
            record.summary,
            record.sourcePrompt ?? "",
            record.keywords.joined(separator: " "),
            record.rejectionNotes,
            record.draftEditNotes
        ]
        .joined(separator: " ")
        .lowercased()
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
    }

    private func generatedBackgroundLibrarySortRank(for path: String) -> Int {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        if normalized.contains("/backgrounds/chosen-references/") { return 0 }
        if normalized.contains("/backgrounds/places/") { return 1 }
        if normalized.contains("/backgrounds/place-batches/") { return 2 }
        if normalized.contains("/backgrounds/pipeline/batches/") { return 3 }
        if normalized.contains("/backgrounds/pipeline/tests/") { return 4 }
        return 5
    }

    @discardableResult
    func attachExistingImageToPlace(
        path: String,
        placeID: UUID,
        workflow: PlaceWorkflowMode = .photorealistic
    ) -> Bool {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return false }
        let normalizedPath = normalizedCharacterAssetPath(path)
            ?? projectRelativeCharacterAssetPath(from: path)
            ?? path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return false }

        appendPlaceImagePath(normalizedPath, to: &backgrounds[index], workflow: workflow)
        syncGeneratedBackgroundLibrary()
        save(writePlaces: true)
        return true
    }

    @discardableResult
    func attachDroppedImagesToPlace(
        urls: [URL],
        placeID: UUID,
        workflow: PlaceWorkflowMode = .photorealistic
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        var attachedAny = false
        for url in urls {
            let standardized = url.standardizedFileURL
            if let normalized = normalizedCharacterAssetPath(standardized.path)
                ?? projectRelativeCharacterAssetPath(from: standardized.path),
               resolvedCharacterAssetURL(for: normalized) != nil {
                if attachExistingImageToPlace(path: normalized, placeID: placeID, workflow: workflow) {
                    attachedAny = true
                }
            } else {
                addImageToPlace(from: standardized, placeID: placeID, workflow: workflow)
                attachedAny = true
            }
        }
        return attachedAny
    }

    func setApprovedPlaceImage(_ imagePath: String, placeID: UUID) {
        setApprovedPlaceImage(imagePath, placeID: placeID, workflow: .photorealistic)
    }

    func setApprovedPlaceImage(_ imagePath: String, placeID: UUID, workflow: PlaceWorkflowMode) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              let normalizedPath = normalizedCharacterAssetPath(imagePath) else { return }
        switch workflow {
        case .photorealistic:
            backgrounds[index].approvedImagePath = normalizedPath
            backgrounds[index].filename = URL(fileURLWithPath: normalizedPath).lastPathComponent
            backgrounds[index].sourceURL = resolvedCharacterAssetURL(for: normalizedPath)
        case .animated:
            backgrounds[index].animatedApprovedImagePath = normalizedPath
        }
        save(writePlaces: true)
    }

    func removePlaceImage(at imageIndex: Int, placeID: UUID) {
        removePlaceImage(at: imageIndex, placeID: placeID, workflow: .photorealistic)
    }

    func removePlaceImage(at imageIndex: Int, placeID: UUID, workflow: PlaceWorkflowMode) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        switch workflow {
        case .photorealistic:
            guard backgrounds[index].imagePaths.indices.contains(imageIndex) else { return }
            let removedPath = backgrounds[index].imagePaths.remove(at: imageIndex)
            if backgrounds[index].approvedImagePath == removedPath {
                backgrounds[index].approvedImagePath = backgrounds[index].imagePaths.first
            }
            if let approvedPath = backgrounds[index].approvedImagePath {
                backgrounds[index].filename = URL(fileURLWithPath: approvedPath).lastPathComponent
                backgrounds[index].sourceURL = resolvedCharacterAssetURL(for: approvedPath)
            } else {
                backgrounds[index].filename = ""
                backgrounds[index].sourceURL = nil
            }
        case .animated:
            guard backgrounds[index].animatedImagePaths.indices.contains(imageIndex) else { return }
            let removedPath = backgrounds[index].animatedImagePaths.remove(at: imageIndex)
            if backgrounds[index].animatedApprovedImagePath == removedPath {
                backgrounds[index].animatedApprovedImagePath = backgrounds[index].animatedImagePaths.first
            }
        }
        save(writePlaces: true)
    }

    // MARK: - Gemini Activity Queue
    //
    // Global, cross-workspace tracker for in-flight Gemini image generations.
    // Surfaces in the title-bar GeminiStatusBadge; callers register an entry
    // before firing the API call and update it when complete or failed.

    /// A single registered Gemini generation (immediate or batch-submitted).
    struct GeminiActivityEntry: Identifiable, Sendable, Hashable {
        enum Kind: String, Codable, Sendable { case immediate, batch }
        enum Status: String, Codable, Sendable { case queued, running, completed, failed }

        let id: UUID
        var kind: Kind
        var title: String          // user-facing (e.g. "Hero Establishing")
        var source: String         // e.g. "Places • Valley Town" or "Imagine • Luke Hart"
        var status: Status
        var startedAt: Date
        var completedAt: Date?
        var errorMessage: String?
        var outputFilename: String?
    }

    /// Most-recent-first capped log (keeps last N entries including completed).
    var geminiActivityLog: [GeminiActivityEntry] = []
    private let geminiActivityLogMaxEntries = 60

    /// Number of entries still queued or running.
    var geminiActivityActiveCount: Int {
        geminiActivityLog.reduce(0) { $0 + (($1.status == .queued || $1.status == .running) ? 1 : 0) }
    }

    @discardableResult
    func registerGeminiActivity(kind: GeminiActivityEntry.Kind, title: String, source: String) -> UUID {
        let id = UUID()
        let entry = GeminiActivityEntry(
            id: id,
            kind: kind,
            title: title,
            source: source,
            status: .running,
            startedAt: Date()
        )
        geminiActivityLog.insert(entry, at: 0)
        if geminiActivityLog.count > geminiActivityLogMaxEntries {
            geminiActivityLog = Array(geminiActivityLog.prefix(geminiActivityLogMaxEntries))
        }
        AppLog.log("GEMINI", "register \(kind.rawValue) — \(source) — \(title)")
        return id
    }

    func updateGeminiActivity(
        _ id: UUID,
        status: GeminiActivityEntry.Status,
        outputFilename: String? = nil,
        errorMessage: String? = nil
    ) {
        guard let idx = geminiActivityLog.firstIndex(where: { $0.id == id }) else { return }
        geminiActivityLog[idx].status = status
        if let outputFilename { geminiActivityLog[idx].outputFilename = outputFilename }
        if let errorMessage { geminiActivityLog[idx].errorMessage = errorMessage }
        if status == .completed || status == .failed {
            geminiActivityLog[idx].completedAt = Date()
        }
        let title = geminiActivityLog[idx].title
        AppLog.log("GEMINI", "update \(status.rawValue) — \(title)\(errorMessage.map { " (err: \($0))" } ?? "")")
    }

    func clearCompletedGeminiActivity() {
        geminiActivityLog.removeAll { $0.status == .completed || $0.status == .failed }
    }

    /// Get the star rating (0-5) for a specific place image. 0 = unrated.
    func placeImageRating(path: String, placeID: UUID) -> Int {
        guard let idx = backgrounds.firstIndex(where: { $0.id == placeID }) else { return 0 }
        return backgrounds[idx].imageRatings[path] ?? 0
    }

    /// Set the star rating (0-5) for a place image. 0 clears the rating.
    func setPlaceImageRating(path: String, rating: Int, placeID: UUID) {
        guard let idx = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        let clamped = max(0, min(5, rating))
        if clamped == 0 {
            backgrounds[idx].imageRatings.removeValue(forKey: path)
        } else {
            backgrounds[idx].imageRatings[path] = clamped
        }
        save(writePlaces: true)
    }

    /// Remove a place image by path AND move the underlying file to macOS
    /// Trash (recoverable). Used by right-click Move File to Trash in the
    /// Places photorealistic / animated gallery.
    @discardableResult
    func movePlaceImageToTrash(path: String, placeID: UUID, workflow: PlaceWorkflowMode) -> Bool {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return false }
        let absoluteURL = resolvedCharacterAssetURL(for: path)
        switch workflow {
        case .photorealistic:
            backgrounds[index].imagePaths.removeAll(where: { $0 == path })
            if backgrounds[index].approvedImagePath == path {
                backgrounds[index].approvedImagePath = backgrounds[index].imagePaths.first
            }
            if let approvedPath = backgrounds[index].approvedImagePath {
                backgrounds[index].filename = URL(fileURLWithPath: approvedPath).lastPathComponent
                backgrounds[index].sourceURL = resolvedCharacterAssetURL(for: approvedPath)
            } else {
                backgrounds[index].filename = ""
                backgrounds[index].sourceURL = nil
            }
        case .animated:
            backgrounds[index].animatedImagePaths.removeAll(where: { $0 == path })
            if backgrounds[index].animatedApprovedImagePath == path {
                backgrounds[index].animatedApprovedImagePath = backgrounds[index].animatedImagePaths.first
            }
        }
        save(writePlaces: true)

        if let url = absoluteURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                var resultingURL: NSURL? = nil
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                AppLog.log("STORE", "trashItem failed for place image \(url.path): \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    func deletePlace(_ placeID: UUID) {
        backgrounds.removeAll { $0.id == placeID }
        for sceneIndex in scenes.indices where scenes[sceneIndex].backgroundID == placeID {
            scenes[sceneIndex].backgroundID = nil
        }
        let orphanedRouteIDs = Set(placesWorkflowLibrary.worldGraph.routes.filter { $0.placeID == placeID }.map(\.id))
        let orphanedNodeIDs = Set(placesWorkflowLibrary.worldGraph.nodes.filter { $0.placeID == placeID || orphanedRouteIDs.contains($0.routeID ?? UUID()) }.map(\.id))
        placesWorkflowLibrary.worldGraph.routes.removeAll { orphanedRouteIDs.contains($0.id) }
        placesWorkflowLibrary.worldGraph.nodes.removeAll { orphanedNodeIDs.contains($0.id) }
        placesWorkflowLibrary.continuityReviews.removeAll { orphanedNodeIDs.contains($0.nodeID) }
        for index in placesWorkflowLibrary.generatedImageRecords.indices where placesWorkflowLibrary.generatedImageRecords[index].linkedPlaceID == placeID {
            placesWorkflowLibrary.generatedImageRecords[index].linkedPlaceID = nil
            if orphanedNodeIDs.contains(placesWorkflowLibrary.generatedImageRecords[index].worldNodeID ?? UUID()) {
                placesWorkflowLibrary.generatedImageRecords[index].worldNodeID = nil
                placesWorkflowLibrary.generatedImageRecords[index].routeID = nil
                placesWorkflowLibrary.generatedImageRecords[index].continuityReviewIDs.removeAll()
            }
        }
        if selectedBackgroundID == placeID {
            selectedBackgroundID = backgrounds.first?.id
        }
        save(writePlaces: true)
    }

    // MARK: - Place Angle Images

    func addAngleImageToPlace(from url: URL, placeID: UUID, cameraShot: String? = nil, angle: String? = nil, timeOfDay: String? = nil) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              let animateDir = animateURL else { return }

        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            let imagePath = normalizedCharacterAssetPath(storedURL.path) ?? storedURL.path

            // Also add to imagePaths for backward compatibility
            if !backgrounds[index].imagePaths.contains(imagePath) {
                backgrounds[index].imagePaths.append(imagePath)
            }

            let angleImage = PlaceAngleImage(
                imagePath: imagePath,
                cameraShot: cameraShot,
                angle: angle,
                timeOfDay: timeOfDay
            )
            backgrounds[index].angleImages.append(angleImage)

            if backgrounds[index].approvedImagePath == nil {
                backgrounds[index].approvedImagePath = imagePath
                backgrounds[index].filename = URL(fileURLWithPath: imagePath).lastPathComponent
                backgrounds[index].sourceURL = resolvedCharacterAssetURL(for: imagePath)
            }
            save(writePlaces: true)
        } catch {
            statusMessage = "Failed to add angle image: \(error.localizedDescription)"
        }
    }

    func addAngleImagesToPlaceFromPicker(placeID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add Angle Images To Place"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    self.addAngleImageToPlace(from: url, placeID: placeID)
                }
            }
        }
    }

    func updateAngleImage(_ angleImageID: UUID, placeID: UUID, cameraShot: String?, angle: String?, timeOfDay: String?, notes: String) {
        guard let placeIndex = backgrounds.firstIndex(where: { $0.id == placeID }),
              let angleIndex = backgrounds[placeIndex].angleImages.firstIndex(where: { $0.id == angleImageID }) else { return }

        backgrounds[placeIndex].angleImages[angleIndex].cameraShot = cameraShot
        backgrounds[placeIndex].angleImages[angleIndex].angle = angle
        backgrounds[placeIndex].angleImages[angleIndex].timeOfDay = timeOfDay
        backgrounds[placeIndex].angleImages[angleIndex].notes = notes
        save(writePlaces: true)
    }

    func removeAngleImage(_ angleImageID: UUID, placeID: UUID) {
        guard let placeIndex = backgrounds.firstIndex(where: { $0.id == placeID }),
              let angleIndex = backgrounds[placeIndex].angleImages.firstIndex(where: { $0.id == angleImageID }) else { return }

        backgrounds[placeIndex].angleImages.remove(at: angleIndex)
        save(writePlaces: true)
    }

    func updatePlaceCategory(_ category: String, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        backgrounds[index].locationCategory = category
        save(writePlaces: true)
    }

    func updatePlaceSceneUsage(_ usage: [String], placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        backgrounds[index].sceneUsage = usage
        save(writePlaces: true)
    }

    func addPlaceReferenceImagesFromPicker(placeID: UUID, category: PlaceReferenceImage.Category = .misc) {
        let panel = NSOpenPanel()
        panel.title = "Add Place Reference Images"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    self.addPlaceReferenceImage(from: url, placeID: placeID, category: category)
                }
            }
        }
    }

    func addPlaceReferenceImage(from url: URL, placeID: UUID, category: PlaceReferenceImage.Category = .misc) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              let animateDir = animateURL else { return }
        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            let imagePath = normalizedCharacterAssetPath(storedURL.path) ?? storedURL.path
            let title = url.deletingPathExtension().lastPathComponent
            let item = PlaceReferenceImage(title: title, imagePath: imagePath, category: category)
            if !backgrounds[index].referenceImages.contains(where: { $0.imagePath == imagePath }) {
                backgrounds[index].referenceImages.append(item)
            }
            save(writePlaces: true)
        } catch {
            statusMessage = "Failed to add place reference: \(error.localizedDescription)"
        }
    }

    func removePlaceReferenceImage(_ referenceID: UUID, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        backgrounds[index].referenceImages.removeAll { $0.id == referenceID }
        save(writePlaces: true)
    }

    func setMasterPlaceMapFromPicker() {
        let panel = NSOpenPanel()
        panel.title = "Select Master Place Map"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP, .pdf]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.urls.first else { return }
            Task { @MainActor in
                self?.setMasterPlaceMap(from: url)
            }
        }
    }

    func setMasterPlaceMap(from url: URL) {
        guard let animateDir = animateURL else { return }
        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            placesWorkflowLibrary.masterMapImagePath = normalizedCharacterAssetPath(storedURL.path) ?? storedURL.path
            save(writePlaces: true)
        } catch {
            statusMessage = "Failed to set master map: \(error.localizedDescription)"
        }
    }

    func clearMasterPlaceMap() {
        placesWorkflowLibrary.masterMapImagePath = nil
        save(writePlaces: true)
    }

    @MainActor
    private func canonicalPlacesMasterMapPath() -> String? {
        let candidate = "Animate/backgrounds/chosen-references/map/01-master_valley_topdown_map_4k_v5.png"
        if let normalized = normalizedCharacterAssetPath(candidate),
           resolvedCharacterAssetURL(for: normalized) != nil {
            return normalized
        }
        return nil
    }

    @MainActor
    func effectivePlacesMasterMapPath() -> String? {
        if let explicit = normalizedCharacterAssetPath(placesWorkflowLibrary.masterMapImagePath) {
            return explicit
        }
        if let canonical = canonicalPlacesMasterMapPath() {
            return canonical
        }
        return inferredPlacesMasterMapRecord()?.activePath
    }

    @MainActor
    func inferredPlacesMasterMapRecord() -> GeneratedBackgroundLibraryRecord? {
        placesWorkflowLibrary.generatedImageRecords
            .filter { !$0.isRejected }
            .sorted { lhs, rhs in
                let lhsScore = inferredPlacesMasterMapScore(lhs)
                let rhsScore = inferredPlacesMasterMapScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                if (lhs.rating ?? 0) != (rhs.rating ?? 0) {
                    return (lhs.rating ?? 0) > (rhs.rating ?? 0)
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first(where: { inferredPlacesMasterMapScore($0) > 0 })
    }

    @MainActor
    func useGeneratedImageAsMasterPlaceMap(_ path: String) {
        let normalized = normalizedCharacterAssetPath(path) ?? path
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        placesWorkflowLibrary.masterMapImagePath = normalized
        save(writePlaces: true)
    }

    @MainActor
    private func inferredPlacesMasterMapScore(_ record: GeneratedBackgroundLibraryRecord) -> Int {
        let path = record.activePath.lowercased()
        let summary = record.summary.lowercased()
        let prompt = (record.sourcePrompt ?? "").lowercased()
        let keywords = Set(record.keywords.map { $0.lowercased() })

        var score = 0
        if path.contains("/backgrounds/chosen-references/map/") { score += 200 }
        if path.contains("master_valley_topdown") || path.contains("topdown_map") { score += 120 }
        if keywords.contains("map") { score += 80 }
        if keywords.contains("master") { score += 40 }
        if keywords.contains("topdown") { score += 35 }
        if summary.contains("map") { score += 25 }
        if summary.contains("master") { score += 20 }
        if prompt.contains("topdown") || prompt.contains("master map") { score += 20 }
        if path.contains("angled") || summary.contains("angled") { score -= 40 }
        if path.contains("ultrawide") || summary.contains("ultrawide") { score -= 30 }
        return score
    }


    func addGlobalPlaceReferenceImagesFromPicker(category: PlaceReferenceImage.Category = .landmark) {
        let panel = NSOpenPanel()
        panel.title = "Add Global Place References"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    self.addGlobalPlaceReferenceImage(from: url, category: category)
                }
            }
        }
    }

    func addGlobalPlaceReferenceImage(from url: URL, category: PlaceReferenceImage.Category = .landmark) {
        guard let animateDir = animateURL else { return }
        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            let imagePath = normalizedCharacterAssetPath(storedURL.path) ?? storedURL.path
            let item = PlaceReferenceImage(
                title: url.deletingPathExtension().lastPathComponent,
                imagePath: imagePath,
                category: category
            )
            if !placesWorkflowLibrary.landmarkReferences.contains(where: { $0.imagePath == imagePath }) {
                placesWorkflowLibrary.landmarkReferences.append(item)
            }
            save(writePlaces: true)
        } catch {
            statusMessage = "Failed to add global place reference: \(error.localizedDescription)"
        }
    }

    func removeGlobalPlaceReference(_ referenceID: UUID) {
        placesWorkflowLibrary.landmarkReferences.removeAll { $0.id == referenceID }
        save(writePlaces: true)
    }

    @MainActor
    func refreshSuggestedLandmarkProfiles() {
        var profiles = placesWorkflowLibrary.landmarkProfiles.map(normalizePlaceLandmarkProfile)
        var changed = false

        for kind in PlaceLandmarkProfile.Kind.allCases where kind != .custom {
            let relatedPlaces = landmarkCandidatePlaces(for: kind)
            let relatedRecords = landmarkCandidateRecords(for: kind)
            guard !relatedPlaces.isEmpty || !relatedRecords.isEmpty else { continue }

            let profileIndex: Int
            if let existingIndex = profiles.firstIndex(where: { $0.kind == kind }) {
                profileIndex = existingIndex
            } else {
                profiles.append(
                    PlaceLandmarkProfile(
                        title: kind.displayName,
                        kind: kind
                    )
                )
                profileIndex = profiles.count - 1
                changed = true
            }

            var profile = profiles[profileIndex]
            if profile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.title = kind.displayName
                changed = true
            }

            if profile.exteriorPlaceID == nil,
               let suggestedExterior = bestExteriorPlace(for: kind)?.id {
                profile.exteriorPlaceID = suggestedExterior
                changed = true
            }

            if profile.exteriorImagePath == nil || profile.exteriorImagePath?.isEmpty == true,
               let exteriorPath = suggestedExteriorImagePath(for: kind, placeID: profile.exteriorPlaceID) {
                profile.exteriorImagePath = exteriorPath
                changed = true
            }

            if profile.interiorPlaceID == nil,
               let suggestedInterior = bestInteriorPlace(for: kind)?.id {
                profile.interiorPlaceID = suggestedInterior
                changed = true
            }

            if profile.interiorImagePath == nil || profile.interiorImagePath?.isEmpty == true,
               let interiorPath = suggestedInteriorImagePath(for: kind, preferredPlaceID: profile.interiorPlaceID) {
                profile.interiorImagePath = interiorPath
                changed = true
            }

            let suggestedGalleryPaths = suggestedLandmarkGalleryImagePaths(for: kind, profile: profile)
            if profile.galleryImagePaths.isEmpty, !suggestedGalleryPaths.isEmpty {
                profile.galleryImagePaths = suggestedGalleryPaths
                changed = true
            } else {
                let mergedGalleryPaths = normalizedLandmarkImagePaths(
                    profile.galleryImagePaths
                    + [profile.primaryImagePath, profile.exteriorImagePath, profile.interiorImagePath].compactMap { $0 }
                )
                if mergedGalleryPaths != profile.galleryImagePaths {
                    profile.galleryImagePaths = mergedGalleryPaths
                    changed = true
                }
            }

            if (profile.primaryImagePath == nil || profile.primaryImagePath?.isEmpty == true),
               let suggestedPrimary = profile.exteriorImagePath ?? profile.galleryImagePaths.first {
                profile.primaryImagePath = suggestedPrimary
                changed = true
            }

            if (profile.exteriorImagePath == nil || profile.exteriorImagePath?.isEmpty == true),
               let fallbackExterior = profile.primaryImagePath ?? profile.galleryImagePaths.first {
                profile.exteriorImagePath = fallbackExterior
                changed = true
            }

            if (profile.mapPoint == nil || profile.anchorNodeID == nil),
               let anchorPoint = suggestedLandmarkMapPoint(for: kind, profile: profile) {
                if profile.mapPoint != anchorPoint {
                    profile.mapPoint = anchorPoint
                    changed = true
                }
                if let exteriorPlaceID = profile.exteriorPlaceID {
                    let nodeID = upsertWorldPlaceAnchor(
                        placeID: exteriorPlaceID,
                        title: profile.title,
                        mapPoint: anchorPoint,
                        shouldSave: false
                    )
                    if profile.anchorNodeID != nodeID {
                        profile.anchorNodeID = nodeID
                        changed = true
                    }
                }
            }

            if let exteriorPlaceID = profile.exteriorPlaceID,
               let anchorNodeID = profile.anchorNodeID {
                for interiorPlace in relatedPlaces where isInteriorLandmarkPlace(interiorPlace, for: kind) {
                    if interiorPlace.linkedExteriorPlaceID != exteriorPlaceID || interiorPlace.buildingAnchorNodeID != anchorNodeID {
                        setPlaceInteriorLink(
                            interiorPlace.id,
                            linkedExteriorPlaceID: exteriorPlaceID,
                            buildingAnchorNodeID: anchorNodeID,
                            shouldSave: false
                        )
                        changed = true
                    }
                }
            }

            profiles[profileIndex] = normalizePlaceLandmarkProfile(profile)
        }

        if changed {
            placesWorkflowLibrary.landmarkProfiles = profiles
            save(writePlaces: true)
        }
    }

    @MainActor
    func addImagesToLandmarkFromPicker(landmarkID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add Images To Landmark"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    self.addImageToLandmark(from: url, landmarkID: landmarkID)
                }
            }
        }
    }

    @MainActor
    func addImageToLandmark(from url: URL, landmarkID: UUID) {
        guard let animateDir = animateURL else { return }

        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            let imagePath = normalizedLandmarkImagePath(storedURL.path) ?? storedURL.path
            appendLandmarkImagePath(imagePath, landmarkID: landmarkID)
        } catch {
            statusMessage = "Failed to add landmark image: \(error.localizedDescription)"
        }
    }

    @MainActor
    func attachDroppedImagesToLandmark(urls: [URL], landmarkID: UUID) -> Bool {
        guard !urls.isEmpty else { return false }
        var attachedAny = false

        for url in urls {
            let standardized = url.standardizedFileURL
            if let normalized = normalizedCharacterAssetPath(standardized.path)
                ?? projectRelativeCharacterAssetPath(from: standardized.path)
                ?? (FileManager.default.fileExists(atPath: standardized.path) ? standardized.path : nil) {
                appendLandmarkImagePath(normalized, landmarkID: landmarkID)
                attachedAny = true
            } else {
                addImageToLandmark(from: standardized, landmarkID: landmarkID)
                attachedAny = true
            }
        }

        return attachedAny
    }

    @MainActor
    func updateLandmarkProfileNotes(_ notes: String, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }
        placesWorkflowLibrary.landmarkProfiles[index].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        save(writePlaces: true)
    }

    @MainActor
    func setLandmarkProfileExteriorPlace(_ placeID: UUID?, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }
        placesWorkflowLibrary.landmarkProfiles[index].exteriorPlaceID = placeID
        if let placeID,
           let place = backgrounds.first(where: { $0.id == placeID }),
           let approvedPath = place.approvedImagePath(for: .photorealistic) ?? place.approvedImagePath {
            placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath = approvedPath
            let currentPrimary = placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath
            placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths = normalizedLandmarkImagePaths(
                [approvedPath] + placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths
            )
            if currentPrimary == nil || currentPrimary?.isEmpty == true {
                placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = approvedPath
            }
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        refreshSuggestedLandmarkProfiles()
    }

    @MainActor
    func setLandmarkProfileInteriorPlace(_ placeID: UUID?, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }
        placesWorkflowLibrary.landmarkProfiles[index].interiorPlaceID = placeID
        if let placeID,
           let place = backgrounds.first(where: { $0.id == placeID }),
           let approvedPath = place.approvedImagePath(for: .photorealistic) ?? place.approvedImagePath {
            placesWorkflowLibrary.landmarkProfiles[index].interiorImagePath = approvedPath
            placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths = normalizedLandmarkImagePaths(
                [approvedPath] + placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths
            )
            if placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath == nil {
                placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = approvedPath
            }
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        refreshSuggestedLandmarkProfiles()
    }

    @MainActor
    func setLandmarkProfileExteriorImagePath(_ imagePath: String?, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }
        let normalizedPath = normalizedLandmarkImagePath(imagePath)
        placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath = normalizedPath
        if let normalizedPath {
            placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths = normalizedLandmarkImagePaths(
                [normalizedPath] + placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths
            )
            if placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath == nil {
                placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = normalizedPath
            }
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        refreshSuggestedLandmarkProfiles()
    }

    @MainActor
    func setLandmarkProfileInteriorImagePath(_ imagePath: String?, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }
        let normalizedPath = normalizedLandmarkImagePath(imagePath)
        placesWorkflowLibrary.landmarkProfiles[index].interiorImagePath = normalizedPath
        if let normalizedPath {
            placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths = normalizedLandmarkImagePaths(
                [normalizedPath] + placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths
            )
            if placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath == nil {
                placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = normalizedPath
            }
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        refreshSuggestedLandmarkProfiles()
    }

    @MainActor
    func setLandmarkProfilePrimaryImagePath(_ imagePath: String?, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }
        let normalizedPath = normalizedLandmarkImagePath(imagePath)
        if let normalizedPath {
            placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths = normalizedLandmarkImagePaths(
                [normalizedPath] + placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths
            )
        }
        placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = normalizedPath
        if normalizedPath != nil {
            placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath = normalizedPath
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        refreshSuggestedLandmarkProfiles()
    }

    @MainActor
    func appendLandmarkImagePath(_ imagePath: String, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }
        let normalizedPath = normalizedLandmarkImagePath(imagePath) ?? imagePath
        placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths = normalizedLandmarkImagePaths(
            [normalizedPath] + placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths
        )
        if placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath == nil
            || placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath?.isEmpty == true {
            placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = normalizedPath
            placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath = normalizedPath
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        save(writePlaces: true)
    }

    @MainActor
    func removeLandmarkImage(at imageIndex: Int, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }),
              placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths.indices.contains(imageIndex) else { return }

        let removedPath = placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths.remove(at: imageIndex)
        if placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath == removedPath {
            placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths.first
        }
        if placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath == removedPath {
            placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath = placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath
        }
        if placesWorkflowLibrary.landmarkProfiles[index].interiorImagePath == removedPath {
            placesWorkflowLibrary.landmarkProfiles[index].interiorImagePath = nil
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        save(writePlaces: true)
    }

    @MainActor
    func removeLandmarkImages(at offsets: IndexSet, landmarkID: UUID) {
        guard let index = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else { return }

        let removedPaths = offsets.compactMap { offset in
            placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths.indices.contains(offset)
                ? placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths[offset]
                : nil
        }
        placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths.remove(atOffsets: offsets)
        if let primary = placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath,
           removedPaths.contains(primary) {
            placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath = placesWorkflowLibrary.landmarkProfiles[index].galleryImagePaths.first
        }
        if let exterior = placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath,
           removedPaths.contains(exterior) {
            placesWorkflowLibrary.landmarkProfiles[index].exteriorImagePath = placesWorkflowLibrary.landmarkProfiles[index].primaryImagePath
        }
        if let interior = placesWorkflowLibrary.landmarkProfiles[index].interiorImagePath,
           removedPaths.contains(interior) {
            placesWorkflowLibrary.landmarkProfiles[index].interiorImagePath = nil
        }
        placesWorkflowLibrary.landmarkProfiles[index].updatedAt = Date()
        save(writePlaces: true)
    }

    @MainActor
    private func landmarkCandidatePlaces(for kind: PlaceLandmarkProfile.Kind) -> [BackgroundPlate] {
        backgrounds.filter { place in
            landmarkKind(for: place.name) == kind
        }
    }

    @MainActor
    private func landmarkCandidateRecords(for kind: PlaceLandmarkProfile.Kind) -> [GeneratedBackgroundLibraryRecord] {
        placesWorkflowLibrary.generatedImageRecords.filter { record in
            landmarkKind(forRecord: record) == kind
        }
    }

    private func landmarkKind(for placeName: String) -> PlaceLandmarkProfile.Kind? {
        let lower = placeName.lowercased()
        if lower.contains("amira") { return .amiraHome }
        if lower.contains("clinic") { return .clinic }
        if lower.contains("gathering") { return .gatheringSpace }
        if lower.contains("bridge") { return .bridge }
        if lower.contains("market") { return .marketplace }
        if lower.contains("grave") || lower.contains("memorial") || lower.contains("riverbank") { return .memorial }
        if lower.contains("riverside") || lower.contains("river road") { return .riverside }
        if lower.contains("ridge") || lower.contains("mountain valley") { return .ridge }
        return nil
    }

    private func landmarkKind(forRecord record: GeneratedBackgroundLibraryRecord) -> PlaceLandmarkProfile.Kind? {
        let haystack = ([record.activePath, record.summary, record.sourcePrompt] + record.keywords)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("amira") || haystack.contains("home") { return .amiraHome }
        if haystack.contains("clinic") { return .clinic }
        if haystack.contains("gathering") { return .gatheringSpace }
        if haystack.contains("bridge") { return .bridge }
        if haystack.contains("market") { return .marketplace }
        if haystack.contains("grave") || haystack.contains("memorial") || haystack.contains("riverbank") { return .memorial }
        if haystack.contains("riverside") || haystack.contains("river road") { return .riverside }
        if haystack.contains("ridge") || haystack.contains("mountain valley") { return .ridge }
        return nil
    }

    private func placeNameHasExteriorCue(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["street", "road", "bridge", "riverside", "courtyard", "doorway", "market", "overlook", "lane", "edge", "outside", "village to", "valley", "ridge"]
            .contains { lower.contains($0) }
    }

    private func placeNameHasInteriorCue(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["room", "back room", "tent", "bunk", "night", "later that same night", "quiet moment", "inside", "interior", "pre-dawn", "home", "clinic back room"]
            .contains { lower.contains($0) }
    }

    @MainActor
    private func isInteriorLandmarkPlace(_ place: BackgroundPlate, for kind: PlaceLandmarkProfile.Kind) -> Bool {
        if placeNameHasInteriorCue(place.name) && !placeNameHasExteriorCue(place.name) {
            return true
        }
        switch kind {
        case .amiraHome:
            return !placeNameHasExteriorCue(place.name)
        case .clinic:
            return !placeNameHasExteriorCue(place.name)
        case .gatheringSpace:
            return place.name.lowercased().contains("evening") || place.name.lowercased().contains("back alleys")
        default:
            return false
        }
    }

    @MainActor
    private func bestExteriorPlace(for kind: PlaceLandmarkProfile.Kind) -> BackgroundPlate? {
        landmarkCandidatePlaces(for: kind)
            .sorted { lhs, rhs in
                landmarkExteriorPlaceScore(lhs) > landmarkExteriorPlaceScore(rhs)
            }
            .first
    }

    private func landmarkExteriorPlaceScore(_ place: BackgroundPlate) -> Int {
        var score = 0
        if place.approvedImagePath(for: .photorealistic) != nil || place.approvedImagePath != nil { score += 100 }
        if placeNameHasExteriorCue(place.name) { score += 40 }
        if placeNameHasInteriorCue(place.name) { score -= 60 }
        return score
    }

    @MainActor
    private func bestInteriorPlace(for kind: PlaceLandmarkProfile.Kind) -> BackgroundPlate? {
        landmarkCandidatePlaces(for: kind)
            .filter { isInteriorLandmarkPlace($0, for: kind) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    @MainActor
    private func suggestedExteriorImagePath(
        for kind: PlaceLandmarkProfile.Kind,
        placeID: UUID?
    ) -> String? {
        if let placeID,
           let place = backgrounds.first(where: { $0.id == placeID }),
           let approved = place.approvedImagePath(for: .photorealistic) ?? place.approvedImagePath {
            return approved
        }
        return landmarkCandidateRecords(for: kind)
            .sorted { lhs, rhs in landmarkRecordScore(lhs, preferredInterior: false) > landmarkRecordScore(rhs, preferredInterior: false) }
            .first?.activePath
    }

    @MainActor
    private func suggestedInteriorImagePath(
        for kind: PlaceLandmarkProfile.Kind,
        preferredPlaceID: UUID?
    ) -> String? {
        let candidates = landmarkCandidateRecords(for: kind)
            .sorted { lhs, rhs in landmarkRecordScore(lhs, preferredInterior: true, preferredPlaceID: preferredPlaceID) > landmarkRecordScore(rhs, preferredInterior: true, preferredPlaceID: preferredPlaceID) }
        return candidates.first?.activePath
    }

    @MainActor
    private func suggestedLandmarkGalleryImagePaths(
        for kind: PlaceLandmarkProfile.Kind,
        profile: PlaceLandmarkProfile
    ) -> [String] {
        let rankedRecords = landmarkCandidateRecords(for: kind)
            .sorted { lhs, rhs in
                landmarkRecordScore(lhs, preferredInterior: false, preferredPlaceID: profile.exteriorPlaceID)
                > landmarkRecordScore(rhs, preferredInterior: false, preferredPlaceID: profile.exteriorPlaceID)
            }
            .prefix(8)
            .map(\.activePath)

        return normalizedLandmarkImagePaths(
            [profile.primaryImagePath, profile.exteriorImagePath, profile.interiorImagePath].compactMap { $0 }
            + rankedRecords
        )
    }

    private func landmarkRecordScore(
        _ record: GeneratedBackgroundLibraryRecord,
        preferredInterior: Bool,
        preferredPlaceID: UUID? = nil
    ) -> Int {
        let lower = ([record.activePath, record.summary, record.sourcePrompt] + record.keywords)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        var score = 0
        if !record.isRejected { score += 80 }
        score += (record.rating ?? 0) * 20
        if record.mapPlacementStatus == .confirmed { score += 60 }
        if preferredPlaceID != nil && record.linkedPlaceID == preferredPlaceID { score += 35 }
        let interiorCue = ["room", "back room", "lamplight", "treatment_room", "inside", "interior", "tent", "bunk"].contains { lower.contains($0) }
        if preferredInterior {
            score += interiorCue ? 50 : -20
        } else {
            score += interiorCue ? -40 : 20
        }
        return score
    }

    @MainActor
    private func suggestedLandmarkMapPoint(
        for kind: PlaceLandmarkProfile.Kind,
        profile: PlaceLandmarkProfile
    ) -> WorldMapPoint? {
        if let exteriorImagePath = profile.exteriorImagePath,
           let record = generatedBackgroundRecord(for: exteriorImagePath),
           let point = record.mapPoint,
           record.mapPlacementStatus == .confirmed {
            return point
        }

        if let exteriorPlaceID = profile.exteriorPlaceID,
           let place = backgrounds.first(where: { $0.id == exteriorPlaceID }),
           let approved = place.approvedImagePath(for: .photorealistic) ?? place.approvedImagePath,
           let record = generatedBackgroundRecord(for: approved),
           let point = record.mapPoint,
           record.mapPlacementStatus == .confirmed {
            return point
        }

        return landmarkCandidateRecords(for: kind)
            .filter { $0.mapPlacementStatus == .confirmed && $0.mapPoint != nil }
            .sorted { lhs, rhs in landmarkRecordScore(lhs, preferredInterior: false) > landmarkRecordScore(rhs, preferredInterior: false) }
            .first?.mapPoint
    }

    func updatePlaceWorkflowConfig(_ config: PlaceWorkflowRenderConfig, for workflow: PlaceWorkflowMode) {
        switch workflow {
        case .photorealistic:
            placesWorkflowLibrary.photorealConfig = config
        case .animated:
            placesWorkflowLibrary.animatedConfig = config
        }
        save(writePlaces: true)
    }

    func generateDrawThingsPlaceImage(for placeID: UUID) {
        guard !generatingPlaceIDs.contains(placeID),
              let place = backgrounds.first(where: { $0.id == placeID }) else {
            return
        }

        let sceneNames = sceneReferences(for: placeID).map(\.sceneName)
        let notes = place.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptSegments = [
            drawThingsPlaceConfig.promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            "Cinematic environment concept art for the Amira opera location \(place.name).",
            place.locationCategory.isEmpty ? "" : "\(place.locationCategory) location.",
            sceneNames.isEmpty ? "" : "Used in scenes: \(sceneNames.joined(separator: ", ")).",
            notes.isEmpty ? "" : "Production notes: \(notes).",
            "No characters, no text, no lettering, focus on the location only.",
            drawThingsPlaceConfig.promptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let service = DrawThingsPlaceGenerationService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(PlacesScriptIndexService.fileStem(for: place.name))-\(UUID().uuidString).png")

        generatingPlaceIDs.insert(placeID)
        placeGenerationStatusByID[placeID] = "Generating…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.generatingPlaceIDs.remove(placeID) }

            do {
                try await service.generateImage(
                    prompt: promptSegments,
                    config: self.drawThingsPlaceConfig,
                    outputURL: tempURL
                )
                self.addImageToPlace(from: tempURL, placeID: placeID)
                self.placeGenerationStatusByID[placeID] = "Generated \(tempURL.lastPathComponent)"
                self.statusMessage = "Generated image for \(place.name)"
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                self.placeGenerationStatusByID[placeID] = error.localizedDescription
                self.statusMessage = "Place generation failed for \(place.name): \(error.localizedDescription)"
            }
        }
    }

    /// Returns camera shot types required for a given place based on scenes that use it.
    func requiredCameraShots(for placeID: UUID) -> Set<String> {
        var required = Set<String>()
        for scene in scenes where scene.backgroundID == placeID {
            for shot in scene.shots {
                if let cameraShot = shot.cameraShot {
                    required.insert(cameraShot.displayName.lowercased())
                }
            }
        }
        return required
    }

    // MARK: - Private Helpers

    private func appendPlaceImagePath(
        _ imagePath: String,
        to place: inout BackgroundPlate,
        workflow: PlaceWorkflowMode
    ) {
        switch workflow {
        case .photorealistic:
            if !place.imagePaths.contains(imagePath) {
                place.imagePaths.append(imagePath)
            }
            if place.approvedImagePath == nil {
                place.approvedImagePath = imagePath
            }
            let effectivePath = place.approvedImagePath ?? imagePath
            place.filename = URL(fileURLWithPath: effectivePath).lastPathComponent
            place.sourceURL = resolvedCharacterAssetURL(for: effectivePath)
        case .animated:
            if !place.animatedImagePaths.contains(imagePath) {
                place.animatedImagePaths.append(imagePath)
            }
            if place.animatedApprovedImagePath == nil {
                place.animatedApprovedImagePath = imagePath
            }
        }
    }

    private func loadBackgrounds(from directoryURL: URL) throws -> [BackgroundPlate] {
        let fm = FileManager.default
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "webp"]
        let contents = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        var result: [BackgroundPlate] = []

        for item in contents {
            guard imageExtensions.contains(item.pathExtension.lowercased()) else { continue }
            result.append(BackgroundPlate(
                id: UUID(),
                name: item.deletingPathExtension().lastPathComponent,
                filename: item.lastPathComponent,
                imagePaths: [projectRelativeCharacterAssetPath(from: item.path) ?? item.path],
                approvedImagePath: projectRelativeCharacterAssetPath(from: item.path) ?? item.path,
                sourceURL: item
            ))
        }

        return result
    }

    private func loadPlaces(
        from animateDir: URL,
        backgroundDirectoryURL: URL
    ) throws -> [BackgroundPlate] {
        let synthesized = try loadBackgrounds(from: backgroundDirectoryURL)
        let manifestURL = animateDir.appendingPathComponent("places.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([BackgroundPlate].self, from: data) else {
            return synthesized.map(hydratedBackgroundPlate)
        }

        let diskItemsByFilename = Dictionary(uniqueKeysWithValues: synthesized.map { ($0.filename, $0) })
        return decoded.map { place in
            var updated = place
            updated.imagePaths = normalizedCharacterAssetPaths(place.imagePaths)
            updated.approvedImagePath = normalizedCharacterAssetPath(place.approvedImagePath)
            if updated.imagePaths.isEmpty, let fallback = diskItemsByFilename[place.filename]?.resolvedApprovedImagePath {
                updated.imagePaths = [fallback]
            }
            if updated.approvedImagePath == nil {
                updated.approvedImagePath = updated.imagePaths.first
            }
            if updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.name = URL(fileURLWithPath: updated.filename).deletingPathExtension().lastPathComponent
            }
            return hydratedBackgroundPlate(updated)
        }
    }

    private func loadPlacesWorkflowLibrary(from animateDir: URL) -> PlacesWorkflowLibrary {
        let libraryURL = animateDir.appendingPathComponent("places-workflow.json")
        placesWorldMapCanonLibrary = loadPlacesWorldMapCanonLibrary(from: animateDir)
        placesGeneratedReviewStateLibrary = loadGeneratedBackgroundReviewStateLibrary(from: animateDir)
        guard FileManager.default.fileExists(atPath: libraryURL.path),
              let data = try? Data(contentsOf: libraryURL),
              var decoded = try? JSONDecoder().decode(PlacesWorkflowLibrary.self, from: data) else {
            return .init()
        }

        decoded.masterMapImagePath = normalizedCharacterAssetPath(decoded.masterMapImagePath)
        decoded.landmarkReferences = decoded.landmarkReferences.map { reference in
            var updated = reference
            updated.imagePath = normalizedCharacterAssetPath(reference.imagePath) ?? reference.imagePath
            return updated
        }
        decoded.landmarkProfiles = decoded.landmarkProfiles.map(normalizePlaceLandmarkProfile)
        decoded.worldGraph = normalizePlaceWorldGraph(decoded.worldGraph)
        decoded.continuityReviews = decoded.continuityReviews.map(normalizePlaceContinuityReview)
        decoded.worldGenerationBatches = decoded.worldGenerationBatches.map(normalizePlaceWorldGenerationBatch)
        decoded.generatedImageRecords = decoded.generatedImageRecords.map { normalizeGeneratedBackgroundRecord($0) }
        _ = applyGeneratedBackgroundReviewStateOverrides(placesGeneratedReviewStateLibrary, to: &decoded.generatedImageRecords)
        _ = applyPlacesWorldMapCanonOverrides(placesWorldMapCanonLibrary, to: &decoded.generatedImageRecords)
        decoded.pendingEditQueue = decoded.pendingEditQueue.map { normalizePlaceEditQueueItem($0) }
        decoded.editBatchJobs = decoded.editBatchJobs.map { normalizePlaceEditBatchJob($0) }
        return decoded
    }

    private func hydratedPlacesWorkflowLibrary(_ library: PlacesWorkflowLibrary) -> PlacesWorkflowLibrary {
        var updated = library
        updated.masterMapImagePath = normalizedCharacterAssetPath(library.masterMapImagePath)
        updated.landmarkReferences = library.landmarkReferences.map { reference in
            var item = reference
            item.imagePath = normalizedCharacterAssetPath(reference.imagePath) ?? reference.imagePath
            return item
        }
        updated.landmarkProfiles = library.landmarkProfiles.map(normalizePlaceLandmarkProfile)
        updated.worldGraph = normalizePlaceWorldGraph(library.worldGraph)
        updated.continuityReviews = library.continuityReviews.map(normalizePlaceContinuityReview)
        updated.worldGenerationBatches = library.worldGenerationBatches.map(normalizePlaceWorldGenerationBatch)
        updated.generatedImageRecords = library.generatedImageRecords.map(normalizeGeneratedBackgroundRecord)
        _ = applyGeneratedBackgroundReviewStateOverrides(placesGeneratedReviewStateLibrary, to: &updated.generatedImageRecords)
        _ = applyPlacesWorldMapCanonOverrides(placesWorldMapCanonLibrary, to: &updated.generatedImageRecords)
        updated.pendingEditQueue = library.pendingEditQueue.map(normalizePlaceEditQueueItem)
        updated.editBatchJobs = library.editBatchJobs.map(normalizePlaceEditBatchJob)
        return updated
    }

    private func persistedPlacesWorkflowLibrary(_ library: PlacesWorkflowLibrary) -> PlacesWorkflowLibrary {
        var updated = library
        updated.masterMapImagePath = normalizedCharacterAssetPath(library.masterMapImagePath)
        updated.landmarkReferences = library.landmarkReferences.map { reference in
            var item = reference
            item.imagePath = normalizedCharacterAssetPath(reference.imagePath) ?? reference.imagePath
            return item
        }
        updated.landmarkProfiles = library.landmarkProfiles.map(normalizePlaceLandmarkProfile)
        updated.worldGraph = normalizePlaceWorldGraph(library.worldGraph)
        updated.continuityReviews = library.continuityReviews.map(normalizePlaceContinuityReview)
        updated.worldGenerationBatches = library.worldGenerationBatches.map(normalizePlaceWorldGenerationBatch)
        updated.generatedImageRecords = library.generatedImageRecords.map(normalizeGeneratedBackgroundRecord)
        updated.pendingEditQueue = library.pendingEditQueue.map(normalizePlaceEditQueueItem)
        updated.editBatchJobs = library.editBatchJobs.map(normalizePlaceEditBatchJob)
        return updated
    }

    private func placesGeneratedReviewStateURL(in animateDir: URL) -> URL {
        animateDir.appendingPathComponent("places-generated-review-state.json")
    }

    private func normalizePlaceLandmarkProfile(_ profile: PlaceLandmarkProfile) -> PlaceLandmarkProfile {
        var updated = profile
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = updated.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.exteriorImagePath = normalizedLandmarkImagePath(updated.exteriorImagePath) ?? updated.exteriorImagePath
        updated.interiorImagePath = normalizedLandmarkImagePath(updated.interiorImagePath) ?? updated.interiorImagePath
        updated.primaryImagePath = normalizedLandmarkImagePath(updated.primaryImagePath) ?? updated.primaryImagePath
        updated.galleryImagePaths = normalizedLandmarkImagePaths(
            updated.galleryImagePaths
            + [updated.primaryImagePath, updated.exteriorImagePath, updated.interiorImagePath].compactMap { $0 }
        )
        if (updated.primaryImagePath == nil || updated.primaryImagePath?.isEmpty == true) {
            updated.primaryImagePath = updated.exteriorImagePath ?? updated.galleryImagePaths.first
        }
        if (updated.exteriorImagePath == nil || updated.exteriorImagePath?.isEmpty == true) {
            updated.exteriorImagePath = updated.primaryImagePath ?? updated.galleryImagePaths.first
        }
        updated.mapPoint = updated.mapPoint?.clamped()
        return updated
    }

    private func placesGeneratedReviewEventsURL(in animateDir: URL) -> URL {
        animateDir.appendingPathComponent("places-generated-review-events.jsonl")
    }

    private func siblingPreviousJSONURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let filename = ext.isEmpty ? "\(stem).previous" : "\(stem).previous.\(ext)"
        return directory.appendingPathComponent(filename)
    }

    private func writeProtectedData(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let previousURL = siblingPreviousJSONURL(for: url)
            try? fm.removeItem(at: previousURL)
            try? fm.copyItem(at: url, to: previousURL)
        }
        try data.write(to: url, options: .atomic)
    }

    private func loadGeneratedBackgroundReviewStateLibrary(from animateDir: URL) -> GeneratedBackgroundReviewStateLibrary {
        let url = placesGeneratedReviewStateURL(in: animateDir)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GeneratedBackgroundReviewStateLibrary.self, from: data) else {
            return .init()
        }
        return hydratedGeneratedBackgroundReviewStateLibrary(decoded)
    }

    private func hydratedGeneratedBackgroundReviewStateLibrary(
        _ library: GeneratedBackgroundReviewStateLibrary
    ) -> GeneratedBackgroundReviewStateLibrary {
        GeneratedBackgroundReviewStateLibrary(
            recordOverrides: library.recordOverrides.map(normalizeGeneratedBackgroundReviewStateRecord)
        )
    }

    private func persistedGeneratedBackgroundReviewStateLibrary(
        _ library: GeneratedBackgroundReviewStateLibrary
    ) -> GeneratedBackgroundReviewStateLibrary {
        GeneratedBackgroundReviewStateLibrary(
            recordOverrides: library.recordOverrides.map(normalizeGeneratedBackgroundReviewStateRecord)
        )
    }

    private func placesWorldMapCanonURL(in animateDir: URL) -> URL {
        animateDir.appendingPathComponent("places-world-map-canon.json")
    }

    private func loadPlacesWorldMapCanonLibrary(from animateDir: URL) -> PlacesWorldMapCanonLibrary {
        let canonURL = placesWorldMapCanonURL(in: animateDir)
        guard FileManager.default.fileExists(atPath: canonURL.path),
              let data = try? Data(contentsOf: canonURL) else {
            placesWorldMapCanonRawPayload = [:]
            return .init()
        }
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            placesWorldMapCanonRawPayload = raw
            if let generatedRecords = raw["generatedRecords"] as? [String: Any] {
                let overrides = generatedRecords.compactMap { _, value -> GeneratedBackgroundWorldMapCanonRecord? in
                    guard let entry = value as? [String: Any],
                          let canonicalPath = trimmedOrNil(entry["stablePath"] as? String)
                            ?? trimmedOrNil(entry["canonicalPath"] as? String) else {
                        return nil
                    }
                    return GeneratedBackgroundWorldMapCanonRecord(
                        canonicalPath: canonicalPath,
                        pathAliases: [],
                        contentFingerprint: trimmedOrNil(entry["contentFingerprint"] as? String),
                        linkedPlaceID: uuid(from: entry["linkedPlaceID"]),
                        worldNodeID: uuid(from: entry["worldNodeID"]),
                        routeID: uuid(from: entry["routeID"]),
                        cameraPose: worldCameraPose(from: entry["cameraPose"]),
                        mapPoint: worldMapPoint(from: entry["mapPoint"]),
                        mapPlacementStatus: GeneratedBackgroundMapPlacementStatus(
                            rawValue: trimmedOrNil(entry["mapPlacementStatus"] as? String) ?? ""
                        ),
                        mapPlacementConfirmedAt: isoDate(from: entry["mapPlacementConfirmedAt"]),
                        buildingAnchorNodeID: uuid(from: entry["buildingAnchorNodeID"]),
                        orientationState: GeneratedBackgroundOrientationState(
                            rawValue: trimmedOrNil(entry["orientationState"] as? String) ?? ""
                        ),
                        updatedAt: isoDate(from: entry["updatedAt"]) ?? Date()
                    )
                }
                let deduped = overrides.reduce(into: [String: GeneratedBackgroundWorldMapCanonRecord]()) { partial, item in
                    let key = item.contentFingerprint?.lowercased() ?? item.canonicalPath.lowercased()
                    if let existing = partial[key] {
                        partial[key] = item.updatedAt > existing.updatedAt ? item : existing
                    } else {
                        partial[key] = item
                    }
                }.map(\.value)
                return hydratedPlacesWorldMapCanonLibrary(
                    PlacesWorldMapCanonLibrary(recordOverrides: deduped)
                )
            }
        }
        if let decoded = try? JSONDecoder().decode(PlacesWorldMapCanonLibrary.self, from: data) {
            placesWorldMapCanonRawPayload = [:]
            return hydratedPlacesWorldMapCanonLibrary(decoded)
        }
        placesWorldMapCanonRawPayload = [:]
        return .init()
    }

    private func hydratedPlacesWorldMapCanonLibrary(_ library: PlacesWorldMapCanonLibrary) -> PlacesWorldMapCanonLibrary {
        PlacesWorldMapCanonLibrary(
            recordOverrides: library.recordOverrides.map(normalizeGeneratedBackgroundWorldMapCanonRecord)
        )
    }

    private func persistedPlacesWorldMapCanonLibrary(_ library: PlacesWorldMapCanonLibrary) -> PlacesWorldMapCanonLibrary {
        PlacesWorldMapCanonLibrary(
            recordOverrides: library.recordOverrides.map(normalizeGeneratedBackgroundWorldMapCanonRecord)
        )
    }

    private func uuid(from value: Any?) -> UUID? {
        guard let string = trimmedOrNil(value as? String) else { return nil }
        return UUID(uuidString: string)
    }

    private func isoDate(from value: Any?) -> Date? {
        guard let string = trimmedOrNil(value as? String) else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private func worldMapPoint(from value: Any?) -> WorldMapPoint? {
        guard let payload = value as? [String: Any],
              let x = payload["x"] as? Double ?? (payload["x"] as? NSNumber)?.doubleValue,
              let y = payload["y"] as? Double ?? (payload["y"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return WorldMapPoint(x: x, y: y).clamped()
    }

    private func worldCameraPose(from value: Any?) -> WorldCameraPose? {
        guard let payload = value as? [String: Any] else { return nil }
        let yaw = payload["yawDegrees"] as? Double ?? (payload["yawDegrees"] as? NSNumber)?.doubleValue ?? 0
        let pitch = payload["pitchDegrees"] as? Double ?? (payload["pitchDegrees"] as? NSNumber)?.doubleValue ?? 0
        let roll = payload["rollDegrees"] as? Double ?? (payload["rollDegrees"] as? NSNumber)?.doubleValue ?? 0
        let focal = payload["focalLengthMM"] as? Double ?? (payload["focalLengthMM"] as? NSNumber)?.doubleValue ?? 35
        let horizontalFOV = payload["horizontalFOVDegrees"] as? Double ?? (payload["horizontalFOVDegrees"] as? NSNumber)?.doubleValue
        let verticalFOV = payload["verticalFOVDegrees"] as? Double ?? (payload["verticalFOVDegrees"] as? NSNumber)?.doubleValue
        return WorldCameraPose(
            yawDegrees: yaw,
            pitchDegrees: pitch,
            rollDegrees: roll,
            focalLengthMM: focal,
            horizontalFOVDegrees: horizontalFOV,
            verticalFOVDegrees: verticalFOV
        )
    }

    private func stableWorldMapCanonKey(for path: String) -> String? {
        guard let relativePath = projectRelativeCharacterAssetPath(from: path) ?? normalizedCharacterAssetPath(path) else {
            return nil
        }
        let normalized = relativePath.lowercased()
        let digest = Insecure.SHA1.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        return "path::\(normalized)#\(digest)"
    }

    private func stableWorldMapCanonStemKey(for path: String) -> String {
        "stem::\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased())"
    }

    private func normalizeGeneratedBackgroundReviewStateRecord(
        _ record: GeneratedBackgroundReviewStateRecord
    ) -> GeneratedBackgroundReviewStateRecord {
        var updated = record
        updated.canonicalPath = normalizedCharacterAssetPath(record.canonicalPath) ?? record.canonicalPath
        updated.pathAliases = Array(
            Set(
                record.pathAliases.compactMap { normalizedCharacterAssetPath($0) ?? $0 }
                    .filter { !$0.isEmpty && $0 != updated.canonicalPath }
            )
        ).sorted()
        updated.rejectionNotes = record.rejectionNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.draftEditNotes = record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rating = updated.rating {
            updated.rating = min(max(rating, 1), 5)
        }
        return updated
    }

    private func normalizeGeneratedBackgroundWorldMapCanonRecord(
        _ record: GeneratedBackgroundWorldMapCanonRecord
    ) -> GeneratedBackgroundWorldMapCanonRecord {
        var updated = record
        updated.canonicalPath = normalizedCharacterAssetPath(record.canonicalPath) ?? record.canonicalPath
        updated.pathAliases = Array(
            Set(
                record.pathAliases.compactMap { normalizedCharacterAssetPath($0) ?? $0 }
                    .filter { !$0.isEmpty && $0 != updated.canonicalPath }
            )
        ).sorted()
        updated.mapPoint = record.mapPoint?.clamped()
        if updated.mapPlacementStatus == .confirmed, updated.mapPlacementConfirmedAt == nil {
            updated.mapPlacementConfirmedAt = updated.updatedAt
        }
        return updated
    }

    private func generatedBackgroundRecordPaths(_ record: GeneratedBackgroundLibraryRecord) -> [String] {
        Array(
            Set(
                [record.activePath]
                    + record.duplicatePaths
                    + record.priorVersions.map(\.path)
            )
        )
        .compactMap { normalizedCharacterAssetPath($0) ?? $0 }
        .filter { !$0.isEmpty }
        .sorted()
    }

    private func matchingGeneratedBackgroundReviewStateOverrideIndex(
        for record: GeneratedBackgroundLibraryRecord,
        in overrides: [GeneratedBackgroundReviewStateRecord]
    ) -> Int? {
        let recordFingerprint = record.contentFingerprint ?? generatedBackgroundFingerprint(for: record.activePath)
        let recordPaths = Set(generatedBackgroundRecordPaths(record))
        var bestIndex: Int?
        var bestScore = Int.min
        var bestUpdatedAt = Date.distantPast

        for (index, override) in overrides.enumerated() {
            let overrideFingerprint = override.contentFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
            let overridePaths = Set([override.canonicalPath] + override.pathAliases)
            let pathMatches = !recordPaths.isEmpty && !recordPaths.isDisjoint(with: overridePaths)
            let fingerprintMatches = overrideFingerprint != nil
                && recordFingerprint != nil
                && overrideFingerprint == recordFingerprint

            if pathMatches,
               let overrideFingerprint,
               let recordFingerprint,
               overrideFingerprint != recordFingerprint {
                continue
            }

            let score: Int
            if fingerprintMatches {
                score = pathMatches ? 30 : 20
            } else if pathMatches {
                score = 10
            } else {
                continue
            }

            if score > bestScore || (score == bestScore && override.updatedAt > bestUpdatedAt) {
                bestIndex = index
                bestScore = score
                bestUpdatedAt = override.updatedAt
            }
        }

        return bestIndex
    }

    @discardableResult
    private func applyGeneratedBackgroundReviewStateOverrides(
        _ library: GeneratedBackgroundReviewStateLibrary,
        to records: inout [GeneratedBackgroundLibraryRecord]
    ) -> Bool {
        guard !library.recordOverrides.isEmpty, !records.isEmpty else { return false }
        var didChange = false

        for index in records.indices {
            guard let overrideIndex = matchingGeneratedBackgroundReviewStateOverrideIndex(
                for: records[index],
                in: library.recordOverrides
            ) else { continue }
            let override = library.recordOverrides[overrideIndex]
            let recordHasReviewState = shouldPersistGeneratedBackgroundReviewStateRecord(records[index])
            let shouldApplyReviewOverride = !recordHasReviewState || override.updatedAt >= records[index].updatedAt

            if records[index].contentFingerprint == nil, let fingerprint = override.contentFingerprint {
                records[index].contentFingerprint = fingerprint
                didChange = true
            }
            if shouldApplyReviewOverride, records[index].rating != override.rating {
                records[index].rating = override.rating
                didChange = true
            }
            if shouldApplyReviewOverride, records[index].isRejected != override.isRejected {
                records[index].isRejected = override.isRejected
                didChange = true
            }
            if shouldApplyReviewOverride, records[index].rejectionNotes != override.rejectionNotes {
                records[index].rejectionNotes = override.rejectionNotes
                didChange = true
            }
            if shouldApplyReviewOverride, records[index].draftEditNotes != override.draftEditNotes {
                records[index].draftEditNotes = override.draftEditNotes
                didChange = true
            }
            if shouldApplyReviewOverride, override.updatedAt > records[index].updatedAt {
                records[index].updatedAt = override.updatedAt
                didChange = true
            }
        }

        return didChange
    }

    private func shouldPersistGeneratedBackgroundReviewStateRecord(
        _ record: GeneratedBackgroundLibraryRecord
    ) -> Bool {
        record.rating != nil
            || record.isRejected
            || !record.rejectionNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldPersistGeneratedBackgroundReviewStateOverride(
        _ record: GeneratedBackgroundReviewStateRecord
    ) -> Bool {
        record.rating != nil
            || record.isRejected
            || !record.rejectionNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rebuiltGeneratedBackgroundReviewStateLibrary(
        from records: [GeneratedBackgroundLibraryRecord],
        existing: GeneratedBackgroundReviewStateLibrary
    ) -> GeneratedBackgroundReviewStateLibrary {
        let existingOverrides = existing.recordOverrides.map(normalizeGeneratedBackgroundReviewStateRecord)
        var persisted: [GeneratedBackgroundReviewStateRecord] = []
        var matchedOverrideIndices = Set<Int>()

        for record in records {
            if let match = matchingGeneratedBackgroundReviewStateOverrideIndex(
                for: record,
                in: existingOverrides
            ) {
                matchedOverrideIndices.insert(match)
            }
        }

        for record in records where shouldPersistGeneratedBackgroundReviewStateRecord(record) {
            let existingOverride = matchingGeneratedBackgroundReviewStateOverrideIndex(
                for: record,
                in: existingOverrides
            ).map { existingOverrides[$0] }

            let allPaths = Array(
                Set(
                    generatedBackgroundRecordPaths(record)
                        + (existingOverride.map { [$0.canonicalPath] + $0.pathAliases } ?? [])
                )
            ).sorted()
            let canonicalPath = allPaths.first(where: { $0 == record.activePath }) ?? record.activePath
            let aliases = allPaths.filter { $0 != canonicalPath }

            persisted.append(
                GeneratedBackgroundReviewStateRecord(
                    id: existingOverride?.id ?? UUID(),
                    canonicalPath: canonicalPath,
                    pathAliases: aliases,
                    contentFingerprint: record.contentFingerprint ?? existingOverride?.contentFingerprint,
                    rating: record.rating,
                    isRejected: record.isRejected,
                    rejectionNotes: record.rejectionNotes,
                    draftEditNotes: record.draftEditNotes,
                    updatedAt: record.updatedAt
                )
            )
        }

        for (index, override) in existingOverrides.enumerated()
        where !matchedOverrideIndices.contains(index) && shouldPersistGeneratedBackgroundReviewStateOverride(override) {
            persisted.append(override)
        }

        return GeneratedBackgroundReviewStateLibrary(
            recordOverrides: persisted.map(normalizeGeneratedBackgroundReviewStateRecord)
        )
    }

    private func persistGeneratedBackgroundReviewStateNow() {
        guard let animateDir = animateURL else { return }
        let reviewStateLibrary = rebuiltGeneratedBackgroundReviewStateLibrary(
            from: placesWorkflowLibrary.generatedImageRecords,
            existing: placesGeneratedReviewStateLibrary
        )
        let normalizedReviewStateLibrary = persistedGeneratedBackgroundReviewStateLibrary(reviewStateLibrary)
        guard let data = try? JSONEncoder().encode(normalizedReviewStateLibrary) else { return }
        do {
            try writeProtectedData(data, to: placesGeneratedReviewStateURL(in: animateDir))
            placesGeneratedReviewStateLibrary = reviewStateLibrary
        } catch {
            statusMessage = "Failed to persist generated review state: \(error.localizedDescription)"
        }
    }

    private func appendGeneratedBackgroundReviewEvent(
        action: String,
        record: GeneratedBackgroundLibraryRecord
    ) {
        guard let animateDir = animateURL else { return }
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "action": action,
            "recordID": record.id.uuidString.uppercased(),
            "activePath": record.activePath,
            "contentFingerprint": record.contentFingerprint as Any,
            "rating": record.rating as Any,
            "isRejected": record.isRejected,
            "rejectionNotes": record.rejectionNotes,
            "draftEditNotes": record.draftEditNotes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let url = placesGeneratedReviewEventsURL(in: animateDir)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }

    private func matchingWorldMapCanonOverrideIndex(
        for record: GeneratedBackgroundLibraryRecord,
        in overrides: [GeneratedBackgroundWorldMapCanonRecord]
    ) -> Int? {
        let recordFingerprint = record.contentFingerprint ?? generatedBackgroundFingerprint(for: record.activePath)
        let recordPaths = Set(generatedBackgroundRecordPaths(record))
        var bestIndex: Int?
        var bestScore = Int.min
        var bestUpdatedAt = Date.distantPast

        for (index, override) in overrides.enumerated() {
            let overrideFingerprint = override.contentFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
            let overridePaths = Set([override.canonicalPath] + override.pathAliases)
            let pathMatches = !recordPaths.isEmpty && !recordPaths.isDisjoint(with: overridePaths)
            let fingerprintMatches = overrideFingerprint != nil
                && recordFingerprint != nil
                && overrideFingerprint == recordFingerprint

            if pathMatches,
               let overrideFingerprint,
               let recordFingerprint,
               overrideFingerprint != recordFingerprint {
                continue
            }

            let score: Int
            if fingerprintMatches {
                score = pathMatches ? 30 : 20
            } else if pathMatches {
                score = 10
            } else {
                continue
            }

            if score > bestScore || (score == bestScore && override.updatedAt > bestUpdatedAt) {
                bestIndex = index
                bestScore = score
                bestUpdatedAt = override.updatedAt
            }
        }

        return bestIndex
    }

    @discardableResult
    private func applyPlacesWorldMapCanonOverrides(
        _ library: PlacesWorldMapCanonLibrary,
        to records: inout [GeneratedBackgroundLibraryRecord]
    ) -> Bool {
        guard !library.recordOverrides.isEmpty, !records.isEmpty else { return false }
        var didChange = false

        for index in records.indices {
            guard let overrideIndex = matchingWorldMapCanonOverrideIndex(
                for: records[index],
                in: library.recordOverrides
            ) else { continue }
            let override = library.recordOverrides[overrideIndex]

            if records[index].contentFingerprint == nil, let fingerprint = override.contentFingerprint {
                records[index].contentFingerprint = fingerprint
                didChange = true
            }

            if let linkedPlaceID = override.linkedPlaceID, records[index].linkedPlaceID != linkedPlaceID {
                records[index].linkedPlaceID = linkedPlaceID
                didChange = true
            }
            if let worldNodeID = override.worldNodeID, records[index].worldNodeID != worldNodeID {
                records[index].worldNodeID = worldNodeID
                didChange = true
            }
            if let routeID = override.routeID, records[index].routeID != routeID {
                records[index].routeID = routeID
                didChange = true
            }
            if let cameraPose = override.cameraPose, records[index].cameraPose != cameraPose {
                records[index].cameraPose = cameraPose
                didChange = true
            }
            if let mapPoint = override.mapPoint?.clamped(), records[index].mapPoint != mapPoint {
                records[index].mapPoint = mapPoint
                didChange = true
            }
            if let status = override.mapPlacementStatus, records[index].mapPlacementStatus != status {
                records[index].mapPlacementStatus = status
                didChange = true
            }
            if let confirmedAt = override.mapPlacementConfirmedAt,
               records[index].mapPlacementConfirmedAt != confirmedAt {
                records[index].mapPlacementConfirmedAt = confirmedAt
                didChange = true
            }
            if let buildingAnchorNodeID = override.buildingAnchorNodeID,
               records[index].buildingAnchorNodeID != buildingAnchorNodeID {
                records[index].buildingAnchorNodeID = buildingAnchorNodeID
                didChange = true
            }
            if let orientationState = override.orientationState,
               records[index].orientationState != orientationState {
                records[index].orientationState = orientationState
                didChange = true
            }
            if override.updatedAt > records[index].updatedAt {
                records[index].updatedAt = override.updatedAt
                didChange = true
            }
        }

        return didChange
    }

    private func shouldPersistPlacesWorldMapCanonRecord(
        _ record: GeneratedBackgroundLibraryRecord
    ) -> Bool {
        record.mapPlacementStatus == .confirmed
            || record.mapPlacementConfirmedAt != nil
            || record.orientationState != .unknown
            || record.buildingAnchorNodeID != nil
            || record.linkedPlaceID != nil
            || record.worldNodeID != nil
            || record.routeID != nil
    }

    private func rebuiltPlacesWorldMapCanonLibrary(
        from records: [GeneratedBackgroundLibraryRecord],
        existing: PlacesWorldMapCanonLibrary
    ) -> PlacesWorldMapCanonLibrary {
        let existingOverrides = existing.recordOverrides.map(normalizeGeneratedBackgroundWorldMapCanonRecord)
        var persisted: [GeneratedBackgroundWorldMapCanonRecord] = []

        for record in records where shouldPersistPlacesWorldMapCanonRecord(record) {
            let existingOverride = matchingWorldMapCanonOverrideIndex(
                for: record,
                in: existingOverrides
            ).map { existingOverrides[$0] }

            let allPaths = Array(
                Set(
                    generatedBackgroundRecordPaths(record)
                        + (existingOverride.map { [$0.canonicalPath] + $0.pathAliases } ?? [])
                )
            ).sorted()
            let canonicalPath = allPaths.first(where: { $0 == record.activePath }) ?? record.activePath
            let aliases = allPaths.filter { $0 != canonicalPath }

            persisted.append(
                GeneratedBackgroundWorldMapCanonRecord(
                    id: existingOverride?.id ?? UUID(),
                    canonicalPath: canonicalPath,
                    pathAliases: aliases,
                    contentFingerprint: record.contentFingerprint ?? existingOverride?.contentFingerprint,
                    linkedPlaceID: record.linkedPlaceID ?? existingOverride?.linkedPlaceID,
                    worldNodeID: record.worldNodeID ?? existingOverride?.worldNodeID,
                    routeID: record.routeID ?? existingOverride?.routeID,
                    cameraPose: record.cameraPose ?? existingOverride?.cameraPose,
                    mapPoint: record.mapPoint ?? existingOverride?.mapPoint,
                    mapPlacementStatus: record.mapPlacementStatus == .unplaced
                        ? existingOverride?.mapPlacementStatus
                        : record.mapPlacementStatus,
                    mapPlacementConfirmedAt: record.mapPlacementConfirmedAt ?? existingOverride?.mapPlacementConfirmedAt,
                    buildingAnchorNodeID: record.buildingAnchorNodeID ?? existingOverride?.buildingAnchorNodeID,
                    orientationState: record.orientationState == .unknown
                        ? existingOverride?.orientationState
                        : record.orientationState,
                    updatedAt: record.updatedAt
                )
            )
        }

        return PlacesWorldMapCanonLibrary(recordOverrides: persisted.map(normalizeGeneratedBackgroundWorldMapCanonRecord))
    }

    private func normalizePlaceWorldGraph(_ graph: PlaceWorldGraph) -> PlaceWorldGraph {
        var updated = graph
        updated.nodes = graph.nodes.map { node in
            var item = node
            item.approvedPhotorealImagePath = normalizedCharacterAssetPath(node.approvedPhotorealImagePath)
                ?? node.approvedPhotorealImagePath
            item.approvedAnimatedImagePath = normalizedCharacterAssetPath(node.approvedAnimatedImagePath)
                ?? node.approvedAnimatedImagePath
            return item
        }
        return updated
    }

    private func matchingWorldGenerationBatchIndex(
        for batch: PlaceWorldGenerationBatch,
        in batches: [PlaceWorldGenerationBatch]
    ) -> Int? {
        if let idMatch = batches.firstIndex(where: { $0.id == batch.id }) {
            return idMatch
        }

        let incomingKey = placeWorldGenerationBatchMergeKey(batch)
        return batches.firstIndex { placeWorldGenerationBatchMergeKey($0) == incomingKey }
    }

    private func placeWorldGenerationBatchMergeKey(_ batch: PlaceWorldGenerationBatch) -> String {
        if let metadataPath = trimmedOrNil(batch.metadataPath) {
            return "meta:\(normalizedCharacterAssetPath(metadataPath) ?? metadataPath)"
        }
        if let outputRootPath = trimmedOrNil(batch.outputRootPath) {
            return "root:\(normalizedCharacterAssetPath(outputRootPath) ?? outputRootPath)"
        }
        if let batchName = trimmedOrNil(batch.batchName) {
            return "batch:\(batchName.lowercased())"
        }
        return "title:\(batch.routeID?.uuidString ?? "nil")|\(batch.placeID?.uuidString ?? "nil")|\(batch.workflow.rawValue)|\(batch.title.lowercased())|\(Int(batch.submittedAt.timeIntervalSince1970))"
    }

    private func mergedPlaceWorldGenerationBatch(
        existing: PlaceWorldGenerationBatch,
        incoming: PlaceWorldGenerationBatch
    ) -> PlaceWorldGenerationBatch {
        var updated = existing
        updated.routeID = incoming.routeID ?? existing.routeID
        updated.placeID = incoming.placeID ?? existing.placeID
        updated.workflow = incoming.workflow
        if !incoming.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.title = incoming.title
        }
        if !incoming.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.state = incoming.state
        }
        if let batchName = trimmedOrNil(incoming.batchName) {
            updated.batchName = batchName
        }
        if !incoming.nodeIDs.isEmpty {
            updated.nodeIDs = incoming.nodeIDs
        }
        if incoming.promptCount > 0 || updated.promptCount == 0 {
            updated.promptCount = incoming.promptCount
        }
        if !incoming.imageSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.imageSize = incoming.imageSize
        }
        updated.aspectRatio = trimmedOrNil(incoming.aspectRatio) ?? updated.aspectRatio
        updated.model = incoming.model
        updated.submittedAt = min(existing.submittedAt, incoming.submittedAt)
        updated.lastCheckedAt = incoming.lastCheckedAt ?? updated.lastCheckedAt
        updated.remoteUpdatedAt = incoming.remoteUpdatedAt ?? updated.remoteUpdatedAt
        updated.remoteStartedAt = incoming.remoteStartedAt ?? updated.remoteStartedAt
        updated.remoteFinishedAt = incoming.remoteFinishedAt ?? updated.remoteFinishedAt
        updated.successCount = max(existing.successCount, incoming.successCount)
        updated.failureCount = max(existing.failureCount, incoming.failureCount)
        if let lastErrorMessage = trimmedOrNil(incoming.lastErrorMessage) {
            updated.lastErrorMessage = lastErrorMessage
        }
        if !incoming.failures.isEmpty {
            updated.failures = incoming.failures
        }
        if let metadataPath = trimmedOrNil(incoming.metadataPath) {
            updated.metadataPath = metadataPath
        }
        if let outputRootPath = trimmedOrNil(incoming.outputRootPath) {
            updated.outputRootPath = outputRootPath
        }
        updated.generatedImagePaths = normalizedCharacterAssetPaths(
            existing.generatedImagePaths + incoming.generatedImagePaths
        )
        return normalizePlaceWorldGenerationBatch(updated)
    }

    private func mergePlaceWorldGenerationBatches(
        existing: [PlaceWorldGenerationBatch],
        discovered: [PlaceWorldGenerationBatch]
    ) -> [PlaceWorldGenerationBatch] {
        var mergedByKey: [String: PlaceWorldGenerationBatch] = [:]
        var insertionOrder: [String] = []

        func merge(_ batch: PlaceWorldGenerationBatch) {
            let key = placeWorldGenerationBatchMergeKey(batch)
            guard let current = mergedByKey[key] else {
                insertionOrder.append(key)
                mergedByKey[key] = normalizePlaceWorldGenerationBatch(batch)
                return
            }
            mergedByKey[key] = mergedPlaceWorldGenerationBatch(existing: current, incoming: batch)
        }

        existing.forEach(merge)
        discovered.forEach(merge)

        return insertionOrder.compactMap { mergedByKey[$0] }
            .sorted { lhs, rhs in
                if lhs.submittedAt != rhs.submittedAt {
                    return lhs.submittedAt > rhs.submittedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func discoveredPlaceWorldGenerationBatchesOnDisk() -> [PlaceWorldGenerationBatch] {
        guard let animateURL else { return [] }
        let batchesRoot = animateURL
            .appendingPathComponent("backgrounds")
            .appendingPathComponent("place-batches")
        guard let enumerator = FileManager.default.enumerator(
            at: batchesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var discovered: [PlaceWorldGenerationBatch] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "batch_submission.json",
                  let relativeMetadataPath = projectRelativePath(for: fileURL, projectURL: fileOWPURL),
                  let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let latestStatus = json["latest_status"] as? [String: Any]
            let displayName = trimmedOrNil((latestStatus?["display_name"] as? String) ?? (json["display_name"] as? String))
            let title = displayName ?? fileURL.deletingLastPathComponent().lastPathComponent
            let routeID = uuidValue(from: json["route_id"] ?? json["routeID"])
            let placeID = uuidValue(from: json["place_id"] ?? json["placeID"])
            let nodeIDs = uuidValues(from: json["node_ids"] ?? json["nodeIDs"])
            let outputRootPath = projectRelativePath(
                for: fileURL.deletingLastPathComponent(),
                projectURL: fileOWPURL
            ) ?? relativeMetadataPath
            let model = GeminiModel(rawValue: (json["model"] as? String) ?? "") ?? .flash
            let workflow = inferredPlaceWorldBatchWorkflow(from: fileURL, json: json)
            let resultsSummary = placeWorldGenerationBatchResultsSummary(
                from: json,
                batch: PlaceWorldGenerationBatch(
                    routeID: routeID,
                    placeID: placeID,
                    workflow: workflow,
                    title: title,
                    metadataPath: relativeMetadataPath,
                    outputRootPath: outputRootPath
                )
            )

            discovered.append(
                PlaceWorldGenerationBatch(
                    routeID: routeID,
                    placeID: placeID,
                    workflow: workflow,
                    title: title,
                    state: (latestStatus?["state"] as? String) ?? (json["batch_state"] as? String) ?? "JOB_STATE_PENDING",
                    batchName: trimmedOrNil((latestStatus?["batch_name"] as? String) ?? (json["batch_name"] as? String)),
                    nodeIDs: nodeIDs,
                    promptCount: (json["prompt_count"] as? Int) ?? resultsSummary.rowCount,
                    imageSize: (json["image_size"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1K",
                    aspectRatio: trimmedOrNil(json["aspect_ratio"] as? String),
                    model: model,
                    submittedAt: batchStatusDate(json["submitted_at"])
                        ?? batchStatusDate(json["last_status_check"])
                        ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? Date(),
                    lastCheckedAt: batchStatusDate(json["last_status_check"]),
                    remoteUpdatedAt: batchStatusDate(latestStatus?["update_time"]),
                    remoteStartedAt: batchStatusDate(latestStatus?["start_time"]),
                    remoteFinishedAt: batchStatusDate(latestStatus?["end_time"]),
                    successCount: resultsSummary.successCount,
                    failureCount: resultsSummary.errorCount,
                    lastErrorMessage: trimmedOrNil(
                        ((latestStatus?["error"] as? [String: Any])?["message"] as? String)
                        ?? ((latestStatus?["error"] as? [String: Any])?["details"] as? String)
                        ?? resultsSummary.failures.first?.message
                    ),
                    failures: resultsSummary.failures,
                    metadataPath: relativeMetadataPath,
                    outputRootPath: outputRootPath,
                    generatedImagePaths: resultsSummary.decodedImagePaths
                )
            )
        }

        return discovered
    }

    private func inferredPlaceWorldBatchWorkflow(
        from metadataURL: URL,
        json: [String: Any]
    ) -> PlaceWorkflowMode {
        if let rawWorkflow = trimmedOrNil((json["workflow"] as? String) ?? (json["workflow_mode"] as? String)),
           let workflow = PlaceWorkflowMode(rawValue: rawWorkflow) {
            return workflow
        }

        let components = metadataURL.deletingLastPathComponent().pathComponents.map { $0.lowercased() }
        if components.contains("animated") || components.contains("animation") {
            return .animated
        }
        return .photorealistic
    }

    private func uuidValue(from rawValue: Any?) -> UUID? {
        switch rawValue {
        case let uuid as UUID:
            return uuid
        case let string as String:
            return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func uuidValues(from rawValue: Any?) -> [UUID] {
        guard let values = rawValue as? [Any] else { return [] }
        return values.compactMap { uuidValue(from: $0) }
    }

    private func placeWorldGenerationBatchResultsSummary(
        from json: [String: Any],
        batch: PlaceWorldGenerationBatch
    ) -> PlaceWorldGenerationBatchResultsSummary {
        let latestStatus = json["latest_status"] as? [String: Any]
        let downloadedResultsFile = trimmedOrNil(latestStatus?["downloaded_results_file"] as? String)
        let resultsURL = downloadedResultsFile.flatMap { path in
            resolvedCharacterAssetURL(for: path) ?? (path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil)
        }
        let parsedResultsFile = resultsURL.flatMap { parsedPlaceWorldGenerationBatchResultsFile(at: $0, batch: batch) }

        let summary = latestStatus?["result_summary"] as? [String: Any]
        let metadataFailures: [PlaceWorldGenerationBatchFailure] = (summary?["errors"] as? [[String: Any]] ?? []).map { item in
            PlaceWorldGenerationBatchFailure(
                key: (item["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "row",
                message: (item["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown batch error",
                code: item["code"] as? Int
            )
        }

        let decodedPaths = normalizedCharacterAssetPaths(
            (latestStatus?["decoded_images"] as? [String] ?? [])
                .compactMap { normalizedCharacterAssetPath($0) ?? $0 }
        )

        let successCount = (summary?["success_count"] as? Int)
            ?? ((latestStatus?["completion_stats"] as? [String: Any])?["successful_count"] as? Int)
            ?? parsedResultsFile?.successCount
            ?? decodedPaths.count
        let errorCount = (summary?["error_count"] as? Int)
            ?? parsedResultsFile?.errorCount
            ?? metadataFailures.count
        let failures = metadataFailures.isEmpty ? (parsedResultsFile?.failures ?? []) : metadataFailures
        let imagePaths = decodedPaths.isEmpty ? (parsedResultsFile?.decodedImagePaths ?? []) : decodedPaths
        let rowCount = (summary?["row_count"] as? Int)
            ?? parsedResultsFile?.rowCount
            ?? max(batch.promptCount, successCount + errorCount)

        return PlaceWorldGenerationBatchResultsSummary(
            rowCount: rowCount,
            successCount: successCount,
            errorCount: errorCount,
            failures: failures,
            decodedImagePaths: imagePaths
        )
    }

    private func parsedPlaceWorldGenerationBatchResultsFile(
        at resultsURL: URL,
        batch: PlaceWorldGenerationBatch
    ) -> PlaceWorldGenerationBatchResultsSummary? {
        guard let contents = try? String(contentsOf: resultsURL, encoding: .utf8) else {
            return nil
        }

        let outputRootURL: URL? = {
            guard let outputRootPath = batch.outputRootPath else { return nil }
            return resolvedCharacterAssetURL(for: outputRootPath)
                ?? (outputRootPath.hasPrefix("/") ? URL(fileURLWithPath: outputRootPath) : nil)
        }()

        var rowCount = 0
        var successCount = 0
        var failures: [PlaceWorldGenerationBatchFailure] = []
        var decodedImagePaths: [String] = []

        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            rowCount += 1
            let rowKey = ((json["key"] as? String) ?? "row")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let error = json["error"] as? [String: Any] {
                failures.append(
                    PlaceWorldGenerationBatchFailure(
                        key: rowKey,
                        message: (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? (error["details"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? "Unknown batch error",
                        code: error["code"] as? Int
                    )
                )
                continue
            }

            guard json["response"] != nil else { continue }
            successCount += 1

            guard let outputRootURL else { continue }
            let fileExtension = placeWorldGenerationBatchResultFileExtension(from: json)
            let fileURL = outputRootURL
                .appendingPathComponent("results")
                .appendingPathComponent(rowKey)
                .appendingPathExtension(fileExtension)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            decodedImagePaths.append(projectRelativeCharacterAssetPath(from: fileURL.path) ?? fileURL.path)
        }

        return PlaceWorldGenerationBatchResultsSummary(
            rowCount: rowCount,
            successCount: successCount,
            errorCount: failures.count,
            failures: failures,
            decodedImagePaths: normalizedCharacterAssetPaths(decodedImagePaths)
        )
    }

    private func placeWorldGenerationBatchResultFileExtension(from row: [String: Any]) -> String {
        let response = row["response"] as? [String: Any]
        let candidates = response?["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let mimeType = (parts?.first(where: { $0["inlineData"] != nil })?["inlineData"] as? [String: Any])?["mimeType"] as? String
        let normalizedMimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedMimeType {
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        default:
            return "jpg"
        }
    }

    private func reconcilePlaceWorldBatchGeneratedImageLinkage() -> Bool {
        var changed = false

        for batch in placesWorkflowLibrary.worldGenerationBatches {
            guard !batch.generatedImagePaths.isEmpty else { continue }
            let promptKeyToNodeID = placeWorldBatchPromptKeyNodeLookup(for: batch)
            let fallbackPlaceID = batch.placeID
                ?? batch.routeID.flatMap { worldRoute(for: $0)?.placeID }
                ?? batch.nodeIDs.compactMap { worldNode(for: $0)?.placeID }.first

            for path in batch.generatedImagePaths {
                guard let recordIndex = generatedBackgroundRecordIndex(for: path) else { continue }
                let resultKey = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let nodeID = promptKeyToNodeID[resultKey] ?? (batch.nodeIDs.count == 1 ? batch.nodeIDs[0] : nil)
                let placeID = nodeID.flatMap { worldNode(for: $0)?.placeID } ?? fallbackPlaceID

                if placesWorkflowLibrary.generatedImageRecords[recordIndex].routeID != batch.routeID {
                    placesWorkflowLibrary.generatedImageRecords[recordIndex].routeID = batch.routeID
                    changed = true
                }
                if placesWorkflowLibrary.generatedImageRecords[recordIndex].linkedPlaceID != placeID {
                    placesWorkflowLibrary.generatedImageRecords[recordIndex].linkedPlaceID = placeID
                    changed = true
                }
                if placesWorkflowLibrary.generatedImageRecords[recordIndex].worldNodeID != nodeID {
                    placesWorkflowLibrary.generatedImageRecords[recordIndex].worldNodeID = nodeID
                    changed = true
                }
                if let nodeID,
                   let node = worldNode(for: nodeID) {
                    if placesWorkflowLibrary.generatedImageRecords[recordIndex].cameraPose == nil {
                        placesWorkflowLibrary.generatedImageRecords[recordIndex].cameraPose = node.cameraPose
                        changed = true
                    }
                    if placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPoint == nil {
                        placesWorkflowLibrary.generatedImageRecords[recordIndex].mapPoint = node.mapPoint
                        changed = true
                    }
                }
            }
        }

        return changed
    }

    private func placeWorldBatchPromptKeyNodeLookup(for batch: PlaceWorldGenerationBatch) -> [String: UUID] {
        guard !batch.nodeIDs.isEmpty,
              let metadataPath = batch.metadataPath,
              let metadataURL = resolvedCharacterAssetURL(for: metadataPath)
                ?? (metadataPath.hasPrefix("/") ? URL(fileURLWithPath: metadataPath) : nil),
              let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let promptManifest = json["prompt_manifest"] as? [[String: Any]],
              promptManifest.count == batch.nodeIDs.count else {
            return [:]
        }

        var lookup: [String: UUID] = [:]
        for (index, item) in promptManifest.enumerated() {
            guard let key = trimmedOrNil(item["id"] as? String) else { continue }
            lookup[key.lowercased()] = batch.nodeIDs[index]
        }
        return lookup
    }

    private func generatedBackgroundRecordIndex(for path: String) -> Int? {
        let normalized = normalizedCharacterAssetPath(path)
            ?? projectRelativeCharacterAssetPath(from: path)
            ?? path
        return placesWorkflowLibrary.generatedImageRecords.firstIndex {
            $0.activePath == normalized
            || $0.duplicatePaths.contains(normalized)
            || $0.priorVersions.contains(where: { $0.path == normalized })
        }
    }

    private func normalizePlaceContinuityReview(_ review: PlaceContinuityReview) -> PlaceContinuityReview {
        var updated = review
        updated.candidateImagePath = normalizedCharacterAssetPath(review.candidateImagePath) ?? review.candidateImagePath
        updated.comparedImagePaths = normalizedCharacterAssetPaths(review.comparedImagePaths)
        return updated
    }

    private func normalizePlaceWorldGenerationBatch(_ batch: PlaceWorldGenerationBatch) -> PlaceWorldGenerationBatch {
        var updated = batch
        updated.metadataPath = normalizedCharacterAssetPath(batch.metadataPath) ?? batch.metadataPath
        updated.outputRootPath = normalizedCharacterAssetPath(batch.outputRootPath) ?? batch.outputRootPath
        updated.generatedImagePaths = normalizedCharacterAssetPaths(batch.generatedImagePaths)
        return updated
    }

    private func normalizeGeneratedBackgroundRecord(_ record: GeneratedBackgroundLibraryRecord) -> GeneratedBackgroundLibraryRecord {
        var updated = record
        updated.activePath = normalizedCharacterAssetPath(record.activePath) ?? record.activePath
        updated.duplicatePaths = record.duplicatePaths.compactMap { normalizedCharacterAssetPath($0) ?? $0 }
        updated.priorVersions = record.priorVersions.map { version in
            var item = version
            item.path = normalizedCharacterAssetPath(version.path) ?? version.path
            return item
        }
        updated.editHistory = record.editHistory.map { entry in
            var item = entry
            item.sourcePath = normalizedCharacterAssetPath(entry.sourcePath) ?? entry.sourcePath
            if let resultPath = entry.resultPath {
                item.resultPath = normalizedCharacterAssetPath(resultPath) ?? resultPath
            }
            return item
        }
        updated.mapPoint = record.mapPoint?.clamped()
        if updated.mapPlacementStatus == .unplaced, updated.mapPoint != nil || updated.cameraPose != nil {
            updated.mapPlacementStatus = .inferred
        }
        if updated.mapPlacementStatus == .confirmed, updated.mapPlacementConfirmedAt == nil {
            updated.mapPlacementConfirmedAt = updated.updatedAt
        }
        updated.canonStatus = record.canonStatus
        return updated
    }

    private func normalizePlaceEditQueueItem(_ item: PlaceImageEditQueueItem) -> PlaceImageEditQueueItem {
        var updated = item
        updated.sourcePath = normalizedCharacterAssetPath(item.sourcePath) ?? item.sourcePath
        return updated
    }

    private func normalizePlaceEditBatchJob(_ job: PlaceImageEditBatchJob) -> PlaceImageEditBatchJob {
        var updated = job
        updated.metadataPath = normalizedCharacterAssetPath(job.metadataPath) ?? job.metadataPath
        updated.outputRootPath = normalizedCharacterAssetPath(job.outputRootPath) ?? job.outputRootPath
        updated.downloadedImagePaths = normalizedCharacterAssetPaths(job.downloadedImagePaths)
        return updated
    }

    private func hydratedBackgroundPlate(_ background: BackgroundPlate) -> BackgroundPlate {
        var updated = background
        updated.imagePaths = normalizedCharacterAssetPaths(background.imagePaths)
        updated.approvedImagePath = normalizedCharacterAssetPath(background.approvedImagePath)
            ?? updated.imagePaths.first
        updated.animatedImagePaths = normalizedCharacterAssetPaths(background.animatedImagePaths)
        updated.animatedApprovedImagePath = normalizedCharacterAssetPath(background.animatedApprovedImagePath)
            ?? updated.animatedImagePaths.first
        updated.referenceImages = background.referenceImages.map { reference in
            var item = reference
            item.imagePath = normalizedCharacterAssetPath(reference.imagePath) ?? reference.imagePath
            return item
        }
        updated.angleImages = background.angleImages.map { angleImage in
            var item = angleImage
            item.imagePath = normalizedCharacterAssetPath(angleImage.imagePath) ?? angleImage.imagePath
            return item
        }
        if updated.filename.isEmpty, let approvedPath = updated.approvedImagePath {
            updated.filename = URL(fileURLWithPath: approvedPath).lastPathComponent
        }
        updated.sourceURL = resolvedCharacterAssetURL(for: updated.approvedImagePath ?? updated.filename)
        return updated
    }

    private func persistedBackgroundPlate(_ background: BackgroundPlate) -> BackgroundPlate {
        var updated = background
        updated.imagePaths = normalizedCharacterAssetPaths(background.imagePaths)
        updated.approvedImagePath = normalizedCharacterAssetPath(background.approvedImagePath)
            ?? updated.imagePaths.first
        updated.animatedImagePaths = normalizedCharacterAssetPaths(background.animatedImagePaths)
        updated.animatedApprovedImagePath = normalizedCharacterAssetPath(background.animatedApprovedImagePath)
            ?? updated.animatedImagePaths.first
        updated.referenceImages = background.referenceImages.map { reference in
            var item = reference
            item.imagePath = normalizedCharacterAssetPath(reference.imagePath) ?? reference.imagePath
            return item
        }
        updated.angleImages = background.angleImages.map { angleImage in
            var item = angleImage
            item.imagePath = normalizedCharacterAssetPath(angleImage.imagePath) ?? angleImage.imagePath
            return item
        }
        if let approvedPath = updated.approvedImagePath {
            updated.filename = URL(fileURLWithPath: approvedPath).lastPathComponent
        }
        updated.sourceURL = nil
        return updated
    }

    private func renameCharacterTracks(characterID: UUID, oldName: String, newName: String) {
        func renamedTrack(_ track: TimelineTrack) -> TimelineTrack {
            var updated = track
            if updated.targetCharacterID == characterID,
               let role = resolvedTrackRole(for: updated) {
                updated.name = "\(newName):\(role.displayLabel)"
                return updated
            }

            let components = updated.name.split(separator: ":", maxSplits: 1).map(String.init)
            if components.count == 2,
               components[0].caseInsensitiveCompare(oldName) == .orderedSame {
                updated.name = "\(newName):\(components[1])"
            }
            return updated
        }

        for sceneIndex in scenes.indices {
            var renamedTracks: [String: TimelineTrack] = [:]
            for track in scenes[sceneIndex].tracks.values {
                let updated = renamedTrack(track)
                renamedTracks[updated.name] = updated
            }
            scenes[sceneIndex].tracks = renamedTracks
        }

        var renamedSceneTracks: [String: TimelineTrack] = [:]
        for track in sceneTracks.values {
            let updated = renamedTrack(track)
            renamedSceneTracks[updated.name] = updated
        }
        sceneTracks = renamedSceneTracks
    }

    private func sortedShotPresets(_ presets: [SceneShotPreset]) -> [SceneShotPreset] {
        presets.sorted {
            let lhs = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rhs = $1.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lhs == rhs {
                return $0.updatedAt > $1.updatedAt
            }
            return lhs < rhs
        }
    }

    private func persistedCharacterRigURLsOnDisk() -> [URL] {
        guard let animateURL else { return [] }
        let charactersDirectory = animateURL.appendingPathComponent("characters")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: charactersDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return items.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let rigURL = url.appendingPathComponent("rig.json")
            return FileManager.default.fileExists(atPath: rigURL.path) ? rigURL : nil
        }
        .sorted { $0.deletingLastPathComponent().lastPathComponent < $1.deletingLastPathComponent().lastPathComponent }
    }

    private func characterRigURL(for slug: String) -> URL? {
        var directURL: URL?
        if let animateURL {
            let candidate = animateURL
                .appendingPathComponent("characters")
                .appendingPathComponent(slug)
                .appendingPathComponent("rig.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                directURL = candidate
            }
        }

        var matchedOWPRigURL: URL?
        var fallbackRigURL: URL?

        for rigURL in persistedCharacterRigURLsOnDisk() {
            guard let data = try? Data(contentsOf: rigURL),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            let rawOWPSlug = (payload["owpSlug"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawStorageSlug = (payload["storageSlug"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if rawOWPSlug == slug {
                if !rawStorageSlug.isEmpty,
                   rigURL.deletingLastPathComponent().lastPathComponent == rawStorageSlug {
                    return rigURL
                }
                matchedOWPRigURL = matchedOWPRigURL ?? rigURL
                continue
            }

            if rawStorageSlug == slug || rigURL.deletingLastPathComponent().lastPathComponent == slug {
                fallbackRigURL = fallbackRigURL ?? rigURL
            }
        }

        return matchedOWPRigURL ?? fallbackRigURL ?? directURL
    }

    private func schemaVersionForCharacterRigData(_ data: Data) -> Int {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVersion = payload["schemaVersion"] else {
            return 0
        }
        if let intVersion = rawVersion as? Int {
            return intVersion
        }
        if let numberVersion = rawVersion as? NSNumber {
            return numberVersion.intValue
        }
        return 0
    }

    @discardableResult
    private func backupCharacterRigBeforeMigration(
        rigURL: URL,
        originalData: Data,
        originalSchemaVersion: Int
    ) throws -> URL {
        let backupsURL = rigURL.deletingLastPathComponent().appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let versionLabel = max(originalSchemaVersion, 0)
        let backupURL = backupsURL.appendingPathComponent("rig.pre-migration.v\(versionLabel).\(timestamp).json")
        try originalData.write(to: backupURL, options: .atomic)

        let latestBackupURL = backupsURL.appendingPathComponent("latest-pre-migration-rig.json")
        if FileManager.default.fileExists(atPath: latestBackupURL.path) {
            try? FileManager.default.removeItem(at: latestBackupURL)
        }
        try FileManager.default.copyItem(at: backupURL, to: latestBackupURL)
        return backupURL
    }

    private func writeMigratedCharacterRig(_ character: AnimationCharacter, to rigURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persistedCharacter(character))
        try data.write(to: rigURL, options: .atomic)
    }

    private func loadPersistedCharacterState(for slug: String) -> AnimationCharacter? {
        guard let rigURL = characterRigURL(for: slug) else { return nil }
        guard FileManager.default.fileExists(atPath: rigURL.path) else {
            return nil
        }

        guard let rigData = try? Data(contentsOf: rigURL) else {
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(AnimationCharacter.self, from: rigData)
            let normalized = normalizedPersistedCharacterState(decoded, fallbackSlug: slug)
            let originalSchemaVersion = schemaVersionForCharacterRigData(rigData)

            if originalSchemaVersion < AnimationCharacter.currentSchemaVersion {
                do {
                    let backupURL = try backupCharacterRigBeforeMigration(
                        rigURL: rigURL,
                        originalData: rigData,
                        originalSchemaVersion: originalSchemaVersion
                    )
                    try writeMigratedCharacterRig(normalized, to: rigURL)
                    print("AnimateStore: migrated character rig at \(rigURL.path) to schema v\(AnimationCharacter.currentSchemaVersion); backup: \(backupURL.path)")
                } catch {
                    print("AnimateStore: failed to migrate character rig at \(rigURL.path): \(error)")
                }
            }

            return normalized
        } catch {
            print("AnimateStore: failed to decode character rig at \(rigURL.path): \(error)")
            return nil
        }
    }

    private func persistedCharacterSlugsOnDisk() -> [String] {
        let slugs = persistedCharacterRigURLsOnDisk().compactMap { rigURL in
            guard let data = try? Data(contentsOf: rigURL),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return rigURL.deletingLastPathComponent().lastPathComponent
            }

            let owpSlug = (payload["owpSlug"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !owpSlug.isEmpty {
                return owpSlug
            }

            return rigURL.deletingLastPathComponent().lastPathComponent
        }
        return Array(Set(slugs)).sorted()
    }

    @discardableResult
    private func migrateAllCharacterStorageSlugsIfNeeded() -> Bool {
        guard !characters.isEmpty else { return false }

        var updatedCharacters = characters
        var reservedSlugs = Set<String>()
        var didChange = false

        for index in updatedCharacters.indices {
            let oldSlug = updatedCharacters[index].assetFolderSlug
            let candidateSlug = normalizedStorageSlug(
                forName: updatedCharacters[index].name,
                fallback: updatedCharacters[index].storageSlug ?? updatedCharacters[index].owpSlug
            )
            let newSlug = uniqueCharacterSlug(startingWith: candidateSlug, reserved: reservedSlugs)
            reservedSlugs.insert(newSlug)

            if updatedCharacters[index].storageSlug != newSlug {
                updatedCharacters[index].storageSlug = newSlug
                didChange = true
            }

            guard newSlug != oldSlug else { continue }
            updatedCharacters[index] = rewrittenCharacterPaths(
                in: updatedCharacters[index],
                fromSlug: oldSlug,
                toSlug: newSlug
            )
            migrateCharacterDirectoryIfNeeded(fromSlug: oldSlug, toSlug: newSlug)
            didChange = true
        }

        if didChange {
            characters = updatedCharacters
        }

        return didChange
    }

    private func syncCharactersFromOWP(_ sourceCharacters: [OPWCharacter]) {
        owpCharacters = sourceCharacters

        let existingBySlug = Dictionary(uniqueKeysWithValues: characters.map { ($0.owpSlug, $0) })
        var updatedCharacters: [AnimationCharacter] = []
        var seenSlugs: Set<String> = []

        for sourceCharacter in sourceCharacters {
            let slug = sourceCharacter.directoryName
            seenSlugs.insert(slug)
            let sourceName = sourceCharacter.name.trimmingCharacters(in: .whitespacesAndNewlines)

            if var existing = existingBySlug[slug] {
                let persistedName = existing.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedName = persistedName.isEmpty ? sourceName : persistedName
                let defaultCostumeSetsByName = Dictionary(
                    uniqueKeysWithValues: CharacterReferenceWorkflowCatalog
                        .defaultCostumeSets(for: resolvedName)
                        .map { ($0.name, $0) }
                )
                existing.name = resolvedName
                existing.description = sourceCharacter.description ?? ""
                existing.owpSlug = slug
                existing.storageSlug = normalizedStorageSlug(
                    forName: resolvedName,
                    fallback: existing.storageSlug ?? existing.owpSlug
                )
                existing.profileImagePath = normalizedCharacterAssetPath(existing.profileImagePath)
                existing.inspirationImagePaths = normalizedCharacterAssetPaths(existing.inspirationImagePaths)
                existing.curatedInspirationImagePaths = normalizedCharacterAssetPaths(existing.curatedInspirationImagePaths)
                existing.inspirationReferenceImagePath = normalizedCharacterAssetPath(existing.inspirationReferenceImagePath)
                existing.inspirationBatchJobs = normalizedInspirationBatchJobs(existing.inspirationBatchJobs)
                existing.referenceImagePaths = normalizedCharacterAssetPaths(existing.referenceImagePaths)
                existing.animatedImagePaths = normalizedCharacterAssetPaths(existing.animatedImagePaths)
                existing.lookDevelopmentSlots = normalizedLookDevelopmentSlots(existing.lookDevelopmentSlots)
                let legacyPrompt = CharacterReferenceWorkflowCatalog.legacyDefaultMasterSheetPrompt(for: resolvedName)
                existing.masterReferenceSheetPrompt = existing.masterReferenceSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || existing.masterReferenceSheetPrompt == legacyPrompt
                    ? CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(for: resolvedName, gender: existing.genderType)
                    : existing.masterReferenceSheetPrompt
                existing.masterReferenceSourceImagePaths = normalizedCharacterAssetPaths(existing.masterReferenceSourceImagePaths)
                if existing.masterReferenceSourceImagePaths.isEmpty {
                    existing.masterReferenceSourceImagePaths = defaultMasterReferenceSourcePaths(for: existing)
                }
                existing.masterReferenceSheetVariants = normalizedCharacterVariants(existing.masterReferenceSheetVariants)
                if let approvedMasterReferenceSheetVariantID = existing.approvedMasterReferenceSheetVariantID,
                   !existing.masterReferenceSheetVariants.contains(where: { $0.id == approvedMasterReferenceSheetVariantID }) {
                    existing.approvedMasterReferenceSheetVariantID = existing.masterReferenceSheetVariants.last?.id
                }
                existing.headTurnaroundSheetPrompt = existing.headTurnaroundSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(for: resolvedName)
                    : existing.headTurnaroundSheetPrompt
                existing.headTurnaroundSheetVariants = normalizedCharacterVariants(existing.headTurnaroundSheetVariants)
                if let approvedHeadTurnaroundSheetVariantID = existing.approvedHeadTurnaroundSheetVariantID,
                   !existing.headTurnaroundSheetVariants.contains(where: { $0.id == approvedHeadTurnaroundSheetVariantID }) {
                    existing.approvedHeadTurnaroundSheetVariantID = existing.headTurnaroundSheetVariants.last?.id
                }
                existing.headTurnaroundSlots = existing.headTurnaroundSlots.isEmpty
                    ? CharacterReferenceWorkflowCatalog.defaultHeadSlots(for: resolvedName)
                    : normalizedPoseSlots(existing.headTurnaroundSlots)
                existing.costumeReferenceSets = existing.costumeReferenceSets.isEmpty
                    ? CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: resolvedName)
                    : normalizedCostumeReferenceSets(existing.costumeReferenceSets)
                existing.costumeReferenceSets = existing.costumeReferenceSets.map { set in
                    guard let defaultSet = defaultCostumeSetsByName[set.name] else { return set }
                    var updatedSet = set
                    if updatedSet.sheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        updatedSet.sheetPrompt = defaultSet.sheetPrompt
                    }
                    if updatedSet.fullBodySlots.isEmpty {
                        updatedSet.fullBodySlots = defaultSet.fullBodySlots
                    }
                    if updatedSet.accessorySlots.isEmpty {
                        updatedSet.accessorySlots = defaultSet.accessorySlots
                    }
                    return updatedSet
                }
                updatedCharacters.append(existing)
                continue
            }

            let persistedCharacter = loadPersistedCharacterState(for: slug)
            let persistedName = persistedCharacter?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedName = persistedName.isEmpty ? sourceName : persistedName
            let defaultCostumeSetsByName = Dictionary(
                uniqueKeysWithValues: CharacterReferenceWorkflowCatalog
                    .defaultCostumeSets(for: resolvedName)
                    .map { ($0.name, $0) }
            )
            updatedCharacters.append(
                AnimationCharacter(
                    id: persistedCharacter?.id ?? UUID(),
                    sortOrder: persistedCharacter?.sortOrder ?? updatedCharacters.count,
                    name: resolvedName,
                    description: sourceCharacter.description ?? "",
                    owpSlug: slug,
                    storageSlug: normalizedStorageSlug(
                        forName: resolvedName,
                        fallback: persistedCharacter?.storageSlug ?? slug
                    ),
                    renderMode: persistedCharacter?.renderMode,
                    preferredViewAngle: persistedCharacter?.preferredViewAngle,
                    parts: persistedCharacter?.parts ?? [],
                    profileImagePath: normalizedCharacterAssetPath(persistedCharacter?.profileImagePath),
                    backstory: persistedCharacter?.backstory ?? "",
                    personality: persistedCharacter?.personality ?? "",
                    notes: persistedCharacter?.notes ?? "",
                    activeLORAFilename: persistedCharacter?.activeLORAFilename,
                    activeLORATriggerWord: persistedCharacter?.activeLORATriggerWord,
                    activeLORAWeight: persistedCharacter?.activeLORAWeight ?? 1.0,
                    defaultWardrobeType: persistedCharacter?.defaultWardrobeType ?? .soldier,
                    genderType: persistedCharacter?.genderType ?? .person,
                    age: persistedCharacter?.age,
                    inspirationImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.inspirationImagePaths ?? []),
                    curatedInspirationImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.curatedInspirationImagePaths ?? []),
                    inspirationReferenceImagePath: normalizedCharacterAssetPath(persistedCharacter?.inspirationReferenceImagePath),
                    inspirationBatchJobs: normalizedInspirationBatchJobs(persistedCharacter?.inspirationBatchJobs ?? []),
                    referenceImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.referenceImagePaths ?? []),
                    animatedImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.animatedImagePaths ?? []),
                    lookDevelopmentSlots: normalizedLookDevelopmentSlots(persistedCharacter?.lookDevelopmentSlots ?? []),
                    masterReferenceSheetPrompt: persistedCharacter?.masterReferenceSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? persistedCharacter?.masterReferenceSheetPrompt ?? ""
                        : CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(for: resolvedName, gender: persistedCharacter?.genderType ?? .person),
                    masterReferenceSourceImagePaths: {
                        let seededCharacter = AnimationCharacter(
                            id: persistedCharacter?.id ?? UUID(),
                            sortOrder: persistedCharacter?.sortOrder ?? updatedCharacters.count,
                            name: resolvedName,
                            description: sourceCharacter.description ?? "",
                            owpSlug: slug,
                            renderMode: persistedCharacter?.renderMode,
                            preferredViewAngle: persistedCharacter?.preferredViewAngle,
                            parts: persistedCharacter?.parts ?? [],
                            profileImagePath: normalizedCharacterAssetPath(persistedCharacter?.profileImagePath),
                            backstory: persistedCharacter?.backstory ?? "",
                            personality: persistedCharacter?.personality ?? "",
                            notes: persistedCharacter?.notes ?? "",
                            activeLORAFilename: persistedCharacter?.activeLORAFilename,
                            activeLORATriggerWord: persistedCharacter?.activeLORATriggerWord,
                            activeLORAWeight: persistedCharacter?.activeLORAWeight ?? 1.0,
                            defaultWardrobeType: persistedCharacter?.defaultWardrobeType ?? .soldier,
                            genderType: persistedCharacter?.genderType ?? .person,
                            age: persistedCharacter?.age,
                            inspirationImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.inspirationImagePaths ?? []),
                            curatedInspirationImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.curatedInspirationImagePaths ?? []),
                            inspirationReferenceImagePath: normalizedCharacterAssetPath(persistedCharacter?.inspirationReferenceImagePath),
                            inspirationBatchJobs: normalizedInspirationBatchJobs(persistedCharacter?.inspirationBatchJobs ?? []),
                            referenceImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.referenceImagePaths ?? []),
                            animatedImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.animatedImagePaths ?? []),
                            lookDevelopmentSlots: normalizedLookDevelopmentSlots(persistedCharacter?.lookDevelopmentSlots ?? []),
                            masterReferenceSheetPrompt: persistedCharacter?.masterReferenceSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                ? persistedCharacter?.masterReferenceSheetPrompt ?? ""
                                : CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(for: resolvedName, gender: persistedCharacter?.genderType ?? .person),
                            masterReferenceSourceImagePaths: normalizedCharacterAssetPaths(persistedCharacter?.masterReferenceSourceImagePaths ?? []),
                            masterReferenceSheetVariants: normalizedCharacterVariants(persistedCharacter?.masterReferenceSheetVariants ?? []),
                            approvedMasterReferenceSheetVariantID: persistedCharacter?.approvedMasterReferenceSheetVariantID,
                            headTurnaroundSheetPrompt: persistedCharacter?.headTurnaroundSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                ? persistedCharacter?.headTurnaroundSheetPrompt ?? ""
                                : CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(for: resolvedName),
                            headTurnaroundSheetVariants: normalizedCharacterVariants(persistedCharacter?.headTurnaroundSheetVariants ?? []),
                            approvedHeadTurnaroundSheetVariantID: persistedCharacter?.approvedHeadTurnaroundSheetVariantID,
                            headTurnaroundSlots: persistedCharacter?.headTurnaroundSlots.isEmpty == false
                                ? normalizedPoseSlots(persistedCharacter?.headTurnaroundSlots ?? [])
                                : CharacterReferenceWorkflowCatalog.defaultHeadSlots(for: resolvedName),
                            costumeReferenceSets: persistedCharacter?.costumeReferenceSets.isEmpty == false
                                ? normalizedCostumeReferenceSets(persistedCharacter?.costumeReferenceSets ?? [])
                                : CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: resolvedName)
                        )
                        let explicit = seededCharacter.masterReferenceSourceImagePaths
                        return explicit.isEmpty ? defaultMasterReferenceSourcePaths(for: seededCharacter) : explicit
                    }(),
                    masterReferenceSheetVariants: normalizedCharacterVariants(persistedCharacter?.masterReferenceSheetVariants ?? []),
                    approvedMasterReferenceSheetVariantID: persistedCharacter?.approvedMasterReferenceSheetVariantID,
                    headTurnaroundSheetPrompt: persistedCharacter?.headTurnaroundSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? persistedCharacter?.headTurnaroundSheetPrompt ?? ""
                        : CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(for: resolvedName),
                    headTurnaroundSheetVariants: normalizedCharacterVariants(persistedCharacter?.headTurnaroundSheetVariants ?? []),
                    approvedHeadTurnaroundSheetVariantID: persistedCharacter?.approvedHeadTurnaroundSheetVariantID,
                    headTurnaroundSlots: persistedCharacter?.headTurnaroundSlots.isEmpty == false
                        ? normalizedPoseSlots(persistedCharacter?.headTurnaroundSlots ?? [])
                        : CharacterReferenceWorkflowCatalog.defaultHeadSlots(for: resolvedName),
                    costumeReferenceSets: persistedCharacter?.costumeReferenceSets.isEmpty == false
                        ? normalizedCostumeReferenceSets(persistedCharacter?.costumeReferenceSets ?? []).map { set in
                            guard let defaultSet = defaultCostumeSetsByName[set.name] else { return set }
                            var updatedSet = set
                            if updatedSet.sheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                updatedSet.sheetPrompt = defaultSet.sheetPrompt
                            }
                            if updatedSet.fullBodySlots.isEmpty {
                                updatedSet.fullBodySlots = defaultSet.fullBodySlots
                            }
                            if updatedSet.accessorySlots.isEmpty {
                                updatedSet.accessorySlots = defaultSet.accessorySlots
                            }
                            return updatedSet
                        }
                        : CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: resolvedName)
                )
            )
        }

        for slug in persistedCharacterSlugsOnDisk() where !seenSlugs.contains(slug) {
            guard var persistedCharacter = loadPersistedCharacterState(for: slug) else { continue }
            seenSlugs.insert(slug)

            let resolvedName = persistedCharacter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? slug.replacingOccurrences(of: "-", with: " ").capitalized
                : persistedCharacter.name
            let defaultCostumeSetsByName = Dictionary(
                uniqueKeysWithValues: CharacterReferenceWorkflowCatalog
                    .defaultCostumeSets(for: resolvedName)
                    .map { ($0.name, $0) }
            )

            persistedCharacter.name = resolvedName
            persistedCharacter.storageSlug = normalizedStorageSlug(
                forName: resolvedName,
                fallback: persistedCharacter.storageSlug ?? persistedCharacter.owpSlug
            )
            persistedCharacter.profileImagePath = normalizedCharacterAssetPath(persistedCharacter.profileImagePath)
            persistedCharacter.inspirationImagePaths = normalizedCharacterAssetPaths(persistedCharacter.inspirationImagePaths)
            persistedCharacter.curatedInspirationImagePaths = normalizedCharacterAssetPaths(persistedCharacter.curatedInspirationImagePaths)
            persistedCharacter.inspirationReferenceImagePath = normalizedCharacterAssetPath(persistedCharacter.inspirationReferenceImagePath)
            persistedCharacter.inspirationBatchJobs = normalizedInspirationBatchJobs(persistedCharacter.inspirationBatchJobs)
            persistedCharacter.referenceImagePaths = normalizedCharacterAssetPaths(persistedCharacter.referenceImagePaths)
            persistedCharacter.animatedImagePaths = normalizedCharacterAssetPaths(persistedCharacter.animatedImagePaths)
            persistedCharacter.lookDevelopmentSlots = normalizedLookDevelopmentSlots(persistedCharacter.lookDevelopmentSlots)
            persistedCharacter.masterReferenceSheetPrompt = persistedCharacter.masterReferenceSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? CharacterReferenceWorkflowCatalog.defaultMasterSheetPrompt(for: resolvedName, gender: persistedCharacter.genderType)
                : persistedCharacter.masterReferenceSheetPrompt
            persistedCharacter.masterReferenceSourceImagePaths = normalizedCharacterAssetPaths(persistedCharacter.masterReferenceSourceImagePaths)
            if persistedCharacter.masterReferenceSourceImagePaths.isEmpty {
                persistedCharacter.masterReferenceSourceImagePaths = defaultMasterReferenceSourcePaths(for: persistedCharacter)
            }
            persistedCharacter.masterReferenceSheetVariants = normalizedCharacterVariants(persistedCharacter.masterReferenceSheetVariants)
            if let approvedMasterReferenceSheetVariantID = persistedCharacter.approvedMasterReferenceSheetVariantID,
               !persistedCharacter.masterReferenceSheetVariants.contains(where: { $0.id == approvedMasterReferenceSheetVariantID }) {
                persistedCharacter.approvedMasterReferenceSheetVariantID = persistedCharacter.masterReferenceSheetVariants.last?.id
            }
            persistedCharacter.headTurnaroundSheetPrompt = persistedCharacter.headTurnaroundSheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? CharacterReferenceWorkflowCatalog.defaultHeadSheetPrompt(for: resolvedName)
                : persistedCharacter.headTurnaroundSheetPrompt
            persistedCharacter.headTurnaroundSheetVariants = normalizedCharacterVariants(persistedCharacter.headTurnaroundSheetVariants)
            if let approvedHeadTurnaroundSheetVariantID = persistedCharacter.approvedHeadTurnaroundSheetVariantID,
               !persistedCharacter.headTurnaroundSheetVariants.contains(where: { $0.id == approvedHeadTurnaroundSheetVariantID }) {
                persistedCharacter.approvedHeadTurnaroundSheetVariantID = persistedCharacter.headTurnaroundSheetVariants.last?.id
            }
            persistedCharacter.headTurnaroundSlots = persistedCharacter.headTurnaroundSlots.isEmpty
                ? CharacterReferenceWorkflowCatalog.defaultHeadSlots(for: resolvedName)
                : normalizedPoseSlots(persistedCharacter.headTurnaroundSlots)
            persistedCharacter.costumeReferenceSets = persistedCharacter.costumeReferenceSets.isEmpty
                ? CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: resolvedName)
                : normalizedCostumeReferenceSets(persistedCharacter.costumeReferenceSets).map { set in
                    guard let defaultSet = defaultCostumeSetsByName[set.name] else { return set }
                    var updatedSet = set
                    if updatedSet.sheetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        updatedSet.sheetPrompt = defaultSet.sheetPrompt
                    }
                    if updatedSet.fullBodySlots.isEmpty {
                        updatedSet.fullBodySlots = defaultSet.fullBodySlots
                    }
                    if updatedSet.accessorySlots.isEmpty {
                        updatedSet.accessorySlots = defaultSet.accessorySlots
                    }
                    return updatedSet
                }
            updatedCharacters.append(persistedCharacter)
        }

        // Keep unknown local characters so external manifest edits never destroy local in-memory work.
        for existing in characters where !seenSlugs.contains(existing.owpSlug) {
            updatedCharacters.append(existing)
        }

        characters = updatedCharacters.sorted {
            ($0.sortOrder ?? .max, $0.name) < ($1.sortOrder ?? .max, $1.name)
        }
        updateCharacterSortOrders()
    }

    private func requireAnimateURL() throws -> URL {
        guard let animateURL else {
            throw NSError(domain: "AnimateStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open a project before importing images."])
        }
        return animateURL
    }

    private func updateCharacterSortOrders() {
        for index in characters.indices {
            characters[index].sortOrder = index
        }
    }

    private func persistCharacterPackageSelections() {
        guard let animateURL else { return }

        do {
            let manifest = CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: activePackageIDsByCharacterSlug
            )
            try FileManager.default.createDirectory(at: animateURL, withIntermediateDirectories: true)
            try characterPackageSelectionStore.save(manifest, to: animateURL)
        } catch {
            statusMessage = "Could not save package selections: \(error.localizedDescription)"
        }
    }

    private func persistShotPresets() {
        guard let animateURL else { return }

        do {
            let manifest = SceneShotPresetManifest(presets: shotPresets)
            try FileManager.default.createDirectory(at: animateURL, withIntermediateDirectories: true)
            try sceneShotPresetStore.save(manifest, to: animateURL)
        } catch {
            statusMessage = "Could not save shot presets: \(error.localizedDescription)"
        }
    }

    // MARK: - Scene Direction Integration

    /// Apply a compiled scene's keyframes to the current scene/timeline.
    func applyCompiledScene(_ compiled: CompiledScene) {
        // Create or select a scene
        let scene: AnimationScene
        if let existingID = selectedSceneID,
           let idx = scenes.firstIndex(where: { $0.id == existingID }) {
            scenes[idx].name = compiled.name.isEmpty ? scenes[idx].name : compiled.name
            scene = scenes[idx]
        } else {
            guard let first = scenes.first else {
                statusMessage = "No scenes available — open a project first"
                return
            }
            selectedSceneID = first.id
            scene = first
        }

        // Match background by name
        if let bgName = compiled.backgroundName {
            if let bg = backgrounds.first(where: {
                $0.name.lowercased() == bgName.lowercased()
            }) {
                if let idx = scenes.firstIndex(where: { $0.id == scene.id }) {
                    scenes[idx].backgroundID = bg.id
                }
            }
        }

        // Ensure characters exist in scene
        for setup in compiled.characterSetups {
            if let char = characters.first(where: { $0.name.lowercased() == setup.characterName.lowercased() }),
               let sceneIdx = scenes.firstIndex(where: { $0.id == scene.id }),
               !scenes[sceneIdx].characterIDs.contains(char.id) {
                scenes[sceneIdx].characterIDs.append(char.id)
            }
        }

        if let sceneIdx = scenes.firstIndex(where: { $0.id == scene.id }) {
            let existingObjects = scenes[sceneIdx].objectSetups
            let compiledTrackMap = compiled.tracks.reduce(into: [String: TimelineTrack]()) { partialResult, entry in
                let metadata = inferredTrackMetadata(
                    for: entry.key,
                    scene: scenes.first(where: { $0.id == scene.id })
                )
                partialResult[entry.key] = TimelineTrack(
                    name: entry.key,
                    keyframes: entry.value,
                    targetCharacterID: metadata.targetCharacterID,
                    role: metadata.role
                )
            }
            let mergedObjects = compiled.objectSetups.map { incoming -> ObjectSetup in
                guard let existing = existingObjects.first(where: {
                    $0.objectName.caseInsensitiveCompare(incoming.objectName) == .orderedSame
                }) else {
                    return incoming
                }

                var merged = incoming
                merged.id = existing.id
                merged.imagePaths = existing.imagePaths
                merged.approvedImagePath = existing.approvedImagePath
                merged.stateImagePaths = existing.stateImagePaths
                merged.notes = existing.notes
                return merged
            }
            scenes[sceneIdx].objectSetups = normalizedSceneObjectSetups(mergedObjects, tracks: compiledTrackMap)
        }

        // Convert compiled tracks to TimelineTracks
        var tracks: [String: TimelineTrack] = [:]
        for (name, keyframes) in compiled.tracks {
            let metadata = inferredTrackMetadata(
                for: name,
                scene: scenes.first(where: { $0.id == scene.id })
            )
            tracks[name] = TimelineTrack(
                name: name,
                keyframes: keyframes,
                targetCharacterID: metadata.targetCharacterID,
                role: metadata.role
            )
        }
        sceneTracks = tracks
        cameraTrack = compiled.cameraKeyframes.isEmpty
            ? nil
            : TimelineTrack(
                name: Self.cameraTrackName,
                keyframes: compiled.cameraKeyframes,
                role: .camera
            )
        persistSelectedSceneTracks()

        // Update total frames
        totalFrames = compiled.totalFrames
        currentFrame = 0

        statusMessage = "Applied scene: \(compiled.name) (\(compiled.totalFrames) frames)"
    }

    // MARK: - Video Export

    /// Export the current scene to video using the given settings and exporter.
    func exportVideo(settings: VideoExporter.ExportSettings, exporter: VideoExporter) async throws {
        guard let renderer = AnimationRenderer.shared else {
            throw VideoExporter.ExportError.noMetalDevice
        }
        guard let scene = selectedScene else {
            statusMessage = "Select a scene before exporting video."
            return
        }
        statusMessage = "Exporting video..."

        let composer = SceneFrameRenderComposer()
        var textureCache: [String: MTLTexture] = [:]

        try await exporter.export(
            settings: settings,
            renderer: renderer
        ) { frame -> [AnimationRenderer.DrawItem] in
            let viewportSize = CGSize(
                width: settings.resolution.size.width,
                height: settings.resolution.size.height
            )
            let textureProvider: (URL) -> MTLTexture? = { url in
                if let cached = textureCache[url.path] {
                    return cached
                }

                let texture = renderer.loadTexture(from: url)
                if let texture {
                    textureCache[url.path] = texture
                }
                return texture
            }

            composer.applyCamera(
                renderer: renderer,
                store: self,
                scene: scene,
                frame: frame,
                viewportSize: viewportSize
            )
            renderer.setBackgroundTexture(
                composer.backgroundTexture(
                    store: self,
                    scene: scene,
                    textureProvider: textureProvider
                )
            )

            return composer.composeDrawItems(
                store: self,
                scene: scene,
                viewportSize: viewportSize,
                frame: frame,
                textureProvider: textureProvider
            )
        }
    }

    // MARK: - Lip Sync Generation

    private func applyLipSyncVisemes(
        _ visemeKeyframes: [LipSyncEngine.VisemeKeyframe],
        for characterName: String,
        frameOffset: Int = 0
    ) {
        let trackName = "\(characterName):mouth"
        let characterID = resolveCharacter(named: characterName)?.id
        var track = characterID.flatMap { timelineTrack(for: $0, role: .mouth) }
            ?? sceneTracks[trackName]
            ?? TimelineTrack(
                name: trackName,
                keyframes: [],
                targetCharacterID: characterID,
                role: .mouth
            )
        let timelineKFs = LipSyncEngine
            .visemesToTimelineKeyframes(visemeKeyframes)
            .map { keyframe in
                var adjusted = keyframe
                adjusted.frame += frameOffset
                return adjusted
            }
        track.name = preferredTrackName(for: characterID, fallbackCharacterName: characterName, role: .mouth)
        track.targetCharacterID = characterID
        track.role = .mouth
        track.keyframes.append(contentsOf: timelineKFs)
        track.keyframes.sort { $0.frame < $1.frame }

        sceneTracks[track.name] = track
        persistSelectedSceneTracks()
    }

    /// Generate lip sync keyframes from OWP song data for a character.
    func generateLipSyncFromOWP(for characterName: String, songPath: String) {
        guard let owpURL = fileOWPURL else {
            statusMessage = "No project loaded"
            return
        }

        statusMessage = "Generating lip sync for \(characterName)..."

        let songURL = owpURL.appendingPathComponent(songPath)
        guard let data = try? Data(contentsOf: songURL),
              let songData = try? JSONDecoder().decode(OWSSongData.self, from: data)
        else {
            statusMessage = "Could not load song data from \(songPath)"
            return
        }

        // Find matching lyric alignment for this character's vocal track
        guard let alignment = songData.lyricAlignments.first else {
            statusMessage = "No lyric alignment found in \(songPath)"
            return
        }

        let visemeKeyframes = LipSyncEngine.generateFromOWPAlignment(
            alignment: alignment,
            notes: songData.notes,
            songData: songData,
            fps: fps
        )

        applyLipSyncVisemes(visemeKeyframes, for: characterName)
        statusMessage = "Generated \(visemeKeyframes.count) lip sync keyframes for \(characterName)"
    }

    /// Generate lip sync keyframes from audio using Rhubarb (if available) or syllable heuristic fallback.
    func generateLipSyncFromAudio(
        for characterName: String,
        audioURL: URL,
        dialogueText: String? = nil
    ) async {
        statusMessage = "Generating lip sync from audio for \(characterName)..."

        do {
            let result = try await AutoLipSyncService.generateFromAudio(
                audioURL: audioURL,
                dialogueText: dialogueText,
                fps: fps
            )
            applyLipSyncVisemes(result.visemeKeyframes, for: characterName)
            statusMessage = "Generated \(result.visemeKeyframes.count) lip sync keyframes via \(result.source.rawValue) for \(characterName)"
        } catch {
            statusMessage = "Lip sync generation failed for \(characterName): \(error.localizedDescription)"
        }
    }

    // MARK: - Audio Playback

    /// Load the scene's default audio file into the audio player.
    func loadSceneAudio() {
        guard let audioURL = suggestedExportAudioURL() else {
            audioPlayer.unload()
            return
        }
        audioPlayer.load(url: audioURL)
    }

    /// Sync audio player to the current animation frame (call from display link).
    func syncAudioToCurrentFrame() {
        audioPlayer.syncToFrame(currentFrame)
    }

    // MARK: - Camera Choreography

    /// Generate camera choreography from blocking plans and apply as camera shot cues.
    func generateCameraChoreography(from blockingPlans: [CharacterBlockingPlan]) {
        guard !scenes.isEmpty else {
            statusMessage = "Open a project before generating camera choreography"
            return
        }

        let instructions = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: blockingPlans,
            sceneDurationFrames: totalFrames,
            fps: fps
        )

        guard !instructions.isEmpty else {
            statusMessage = "No camera instructions generated from blocking data"
            return
        }

        // Apply each instruction as a camera shot cue on the timeline
        for instruction in instructions {
            setCameraShotCue(instruction.shotType, at: instruction.frame)
        }

        statusMessage = "Generated \(instructions.count) camera cues — \(DirectionTemplateCompiler.summary(for: instructions))"
    }

    // MARK: - Lipsync Direction Tag Processing

    /// Parse [lipsync: "character" | mode=speech/singing | bars=N-M] tags from
    /// the selected scene's lyrics and trigger AutoLipSyncService for each.
    func applyLipSyncDirectionTags() async {
        guard let scene = selectedScene else {
            statusMessage = "No scene selected for lipsync"
            return
        }

        let lyrics = currentSongData?.extractLyrics() ?? ""
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "No scene lyrics available for lipsync"
            return
        }

        let parseResult = SceneDirectionParser.parse(lyrics)
        let lipSyncDirections = parseResult.directions.filter { $0.tag == .lipsync }

        guard !lipSyncDirections.isEmpty else {
            statusMessage = "No [lipsync:] tags found in scene directions"
            return
        }

        guard let audioURL = suggestedExportAudioURL(for: scene) else {
            statusMessage = "No audio file found for scene '\(scene.name)'"
            return
        }

        var successCount = 0
        for direction in lipSyncDirections {
            let characterName = direction.primaryValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard let character = characters.first(where: {
                $0.name.caseInsensitiveCompare(characterName) == .orderedSame ||
                $0.assetFolderSlug.caseInsensitiveCompare(characterName) == .orderedSame
            }) else { continue }

            let mode = direction.parameters["mode"] ?? "speech"
            let dialogueText = lyrics

            do {
                let result = try await AutoLipSyncService.generateFromAudio(
                    audioURL: audioURL,
                    dialogueText: dialogueText,
                    fps: fps,
                    startFrame: 0
                )
                applyLipSyncVisemes(result.visemeKeyframes, for: character.name)
                successCount += 1
            } catch {
                // Continue to next character
            }
        }

        statusMessage = successCount > 0
            ? "Applied lipsync for \(successCount) character\(successCount == 1 ? "" : "s")"
            : "Lipsync generation failed — check audio file and API setup"
    }

    // MARK: - LLM Animation Plan Generation

    /// Generate an animation plan for the selected scene using Gemini LLM.
    /// Calls LLMAnimationPlanGenerator.generate(), then applies the JSON plan.
    func generateAnimationPlanFromLLM() async {
        guard let scene = selectedScene else {
            statusMessage = "Select a scene before generating a plan"
            return
        }
        guard !geminiAPIKey.isEmpty else {
            statusMessage = "No Gemini API key configured — open Settings to add one"
            return
        }

        let lyrics = currentSongData?.extractLyrics() ?? ""
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Scene has no lyrics/script text — load song data first"
            return
        }

        isGeneratingLLMPlan = true
        statusMessage = "Generating animation plan with Gemini..."

        do {
            let characterInfos = characters.map {
                LLMAnimationPlanGenerator.SceneContext.CharacterInfo(
                    name: $0.name,
                    slug: $0.assetFolderSlug,
                    description: $0.description.isEmpty ? $0.name : $0.description
                )
            }
            let context = LLMAnimationPlanGenerator.SceneContext(
                sceneText: lyrics,
                characters: characterInfos,
                sceneName: scene.name,
                durationBars: nil,
                fps: fps,
                stageWidth: 10.0,
                stageDepth: 10.0
            )
            logGeminiAPICall(endpoint: "text-generation", source: "generateAnimationPlanFromLLM")
            let result = try await LLMAnimationPlanGenerator.generate(
                context: context,
                apiKey: geminiAPIKey
            )
            let report = applyLLMAnimationPlanJSON(result.rawJSON)
            let errorCount = report.issues.filter { $0.severity == .error }.count
            let warnCount = report.issues.filter { $0.severity == .warning }.count
            if errorCount > 0 {
                statusMessage = "Plan applied with \(errorCount) errors, \(warnCount) warnings"
            } else {
                statusMessage = "Plan applied — \(warnCount > 0 ? "\(warnCount) warnings" : "success")"
            }
        } catch {
            statusMessage = "Plan generation failed: \(error.localizedDescription)"
        }

        isGeneratingLLMPlan = false
    }

    // MARK: - Track Resolution Cache Types & Helpers

    private struct CharacterTrackCacheKey: Hashable {
        let characterID: UUID
        let role: TimelineTrackRole
    }

    private struct ObjectTrackCacheKey: Hashable {
        let objectName: String
        let role: TimelineTrackRole
    }

    func invalidateTrackCache() {
        characterTrackCache.removeAll(keepingCapacity: true)
        objectTrackCache.removeAll(keepingCapacity: true)
        trackCacheSceneID = nil
        trackCacheSceneTrackCount = 0
    }

    /// Ensures the track cache is still valid for the current scene/track state.
    /// Call at the start of any batch evaluation (e.g. per-frame snapshot).
    private func ensureTrackCacheValid() {
        let currentSceneID = selectedSceneID
        let currentTrackCount = sceneTracks.count + (selectedScene?.tracks.count ?? 0)
        if trackCacheSceneID != currentSceneID || trackCacheSceneTrackCount != currentTrackCount {
            characterTrackCache.removeAll(keepingCapacity: true)
            objectTrackCache.removeAll(keepingCapacity: true)
            trackCacheSceneID = currentSceneID
            trackCacheSceneTrackCount = currentTrackCount
        }
    }

    /// Cached version of timelineTrack(for:role:) -- avoids rescanning
    /// allTimelineTracks() on every property lookup within a single frame.
    func cachedTimelineTrack(
        for characterID: UUID,
        role: TimelineTrackRole
    ) -> TimelineTrack? {
        ensureTrackCacheValid()
        let key = CharacterTrackCacheKey(characterID: characterID, role: role)
        if let cached = characterTrackCache[key] {
            return cached
        }
        let resolved = timelineTrack(for: characterID, role: role)
        characterTrackCache[key] = resolved
        return resolved
    }

    /// Cached version of timelineTrack(forObjectNamed:role:).
    func cachedTimelineTrack(
        forObjectNamed objectName: String,
        role: TimelineTrackRole
    ) -> TimelineTrack? {
        ensureTrackCacheValid()
        let key = ObjectTrackCacheKey(objectName: objectName, role: role)
        if let cached = objectTrackCache[key] {
            return cached
        }
        let resolved = timelineTrack(forObjectNamed: objectName, role: role)
        objectTrackCache[key] = resolved
        return resolved
    }


    // MARK: - Animate Scene Macro (Item 16)

    /// One-click "Animate Scene" macro: chains LLM plan generation, choreography,
    /// TTS dialogue audio, and lip sync in sequence for the given scene.
    func runAnimateSceneMacro(for scene: AnimationScene) async {
        guard !geminiAPIKey.isEmpty else {
            animateMacroStatus = "No Gemini API key — cannot generate plan"
            isRunningAnimateMacro = false
            return
        }

        isRunningAnimateMacro = true
        animateMacroStatus = ""

        // Temporarily select the scene so existing methods that rely on
        // `selectedScene` operate on the correct scene.
        let previousSelectedID = selectedSceneID
        selectedSceneID = scene.id

        // Step 1 — Generate animation plan
        logGeminiAPICall(endpoint: "text-generation", source: "runAnimateSceneMacro")
        animateMacroStatus = "Generating animation plan..."
        await generateAnimationPlanFromLLM()

        // Step 2 — Compile choreography (notify observers so dependent views
        // pick up the refreshed production state).
        animateMacroStatus = "Compiling choreography..."
        // @Observable stores don't expose objectWillChange — mutations to
        // @Published-equivalent properties already propagate automatically.
        // Touching a tracked property is sufficient to trigger a refresh.
        _ = scenes.count  // read-touch to satisfy @Observable change tracking

        // Step 3 — Generate dialogue audio via TTS
        animateMacroStatus = "Generating dialogue audio..."
        if let audioBaseDir = animateURL?.appendingPathComponent("dialogue-audio/\(scene.name)") {
            let lyrics = currentSongData?.extractLyrics() ?? ""
            let bpm = currentSongData?.tempoEvents.sorted(by: { $0.tick < $1.tick }).first?.bpm ?? 120
            let totalBeats: Int = {
                guard let songData = currentSongData else { return 16 }
                return max(4, Int(ceil(Double(songData.lengthTicks) / Double(max(songData.ticksPerQuarter, 1)))))
            }()
            let characterCast = scene.characterIDs.compactMap { id -> SceneProductionCharacterInput? in
                guard let character = characters.first(where: { $0.id == id }) else { return nil }
                return SceneProductionCharacterInput(
                    name: character.name,
                    slug: character.assetFolderSlug,
                    preferredCostumeName: character.costumeReferenceSets.first?.name
                )
            }
            let characterSlugs = scene.characterIDs.compactMap { id in
                characters.first(where: { $0.id == id })?.assetFolderSlug
            }
            let productionInput = SceneProductionInput(
                sceneName: scene.name,
                sceneID: scene.id,
                lyrics: lyrics,
                directions: (lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : SceneDirectionParser.parse(lyrics))?.directions ?? [],
                shots: scene.shots,
                characterSlugs: characterSlugs,
                characterCast: characterCast,
                objectSetups: scene.objectSetups,
                backgroundName: scene.backgroundID.flatMap { id in
                    backgrounds.first(where: { $0.id == id })?.name
                },
                baseFPS: max(fps, 1),
                totalBeats: totalBeats,
                bpm: bpm
            )
            let plan = SceneProductionCompiler.compile(productionInput)
            try? FileManager.default.createDirectory(at: audioBaseDir, withIntermediateDirectories: true)
            for blocking in plan.characterBlocking {
                let charAudioDir = audioBaseDir.appendingPathComponent(blocking.characterSlug)
                _ = await TTSService.generateDialogueAudio(
                    blockingPlan: blocking,
                    outputDirectory: charAudioDir
                )
            }
        }

        // Step 4 — Apply lip sync
        animateMacroStatus = "Applying lip sync..."
        await applyLipSyncDirectionTags()

        animateMacroStatus = "Done."
        isRunningAnimateMacro = false

        // Restore the previously selected scene (if different).
        if previousSelectedID != scene.id {
            selectedSceneID = previousSelectedID
        }
    }

    // MARK: - Batch Scene Processing (Item 17)

    /// Enqueue scene IDs for batch processing (duplicates are ignored).
    func enqueueScenesForBatchProcessing(_ sceneIDs: [UUID]) {
        let existing = Set(batchProcessingQueue)
        for id in sceneIDs where !existing.contains(id) {
            batchProcessingQueue.append(id)
        }
    }

    /// Start processing every scene in the batch queue sequentially.
    func startBatchProcessing() async {
        guard !batchProcessingActive else { return }
        batchProcessingActive = true

        for sceneID in batchProcessingQueue {
            guard !Task.isCancelled else { break }

            batchProcessingCurrentSceneID = sceneID

            guard let scene = scenes.first(where: { $0.id == sceneID }) else { continue }
            await runAnimateSceneMacro(for: scene)
        }

        batchProcessingActive = false
        batchProcessingCurrentSceneID = nil
        batchProcessingQueue.removeAll()
    }

    /// Cancel an in-progress batch run at the next scene boundary.
    func cancelBatchProcessing() {
        // Clearing the queue causes startBatchProcessing to finish after the
        // current scene completes (cooperative cancellation).
        batchProcessingQueue.removeAll()
        batchProcessingActive = false
        batchProcessingCurrentSceneID = nil
    }
}

// MARK: - Motion Clip Management (Phase 3)
extension AnimateStore {
    func addMotionClip(_ clip: MotionClip) {
        motionClips.append(clip)
    }

    // MARK: - NLA Motion Clip Placement

    /// Place a MotionClip on the NLA base (first) track.
    /// Appends at the end of existing clips. Creates the timeline/track if needed.
    func addMotionClipToTimeline(_ clip: MotionClip) {
        // Ensure the clip is in the library
        if !motionClips.contains(where: { $0.id == clip.id }) {
            motionClips.append(clip)
        }

        // Ensure timeline exists
        if nlaTimeline == nil {
            nlaTimeline = NLATimeline(fps: fps)
        }

        // Ensure at least one track exists
        if nlaTimeline!.tracks.isEmpty {
            let baseTrack = NLATrack(name: "Base", colorTag: .imported)
            nlaTimeline!.addTrack(baseTrack)
        }

        // Find the first track (sortOrder 0)
        guard let trackIdx = nlaTimeline!.tracks.indices.first else { return }

        // Append after the last clip on this track
        let lastEnd = nlaTimeline!.tracks[trackIdx].clips
            .map { $0.startFrame + $0.timelineDuration(motionClipFrameCount: clip.frameCount) }
            .max() ?? 0

        let entry = NLAClip(
            motionClipID: clip.id,
            startFrame: lastEnd,
            speed: 1.0,
            blendInFrames: 0,
            blendOutFrames: 0
        )

        nlaTimeline!.tracks[trackIdx].clips.append(entry)

        // Extend timeline duration if needed
        let clipEndTime = Double(lastEnd + clip.frameCount) / Double(max(fps, 1))
        nlaTimeline!.duration = max(nlaTimeline!.duration, clipEndTime)

        saveNLATimeline()
        evaluateNLAAtCurrentFrame()
    }

    /// Place a lip sync MotionClip on the dedicated "Lip Sync" track (.mouth body mask).
    func addMotionClipToLipSyncTrack(_ clip: MotionClip) {
        if !motionClips.contains(where: { $0.id == clip.id }) {
            motionClips.append(clip)
        }

        if nlaTimeline == nil {
            nlaTimeline = NLATimeline(fps: fps)
        }

        // Find or create the lip sync track
        let lipSyncTrackIdx: Int
        if let idx = nlaTimeline!.tracks.firstIndex(where: { $0.name == "Lip Sync" }) {
            lipSyncTrackIdx = idx
        } else {
            var track = NLATrack(
                name: "Lip Sync",
                bodyMask: .mouth,
                colorTag: .webcam
            )
            track.sortOrder = (nlaTimeline!.tracks.map(\.sortOrder).max() ?? -1) + 1
            nlaTimeline!.tracks.append(track)
            lipSyncTrackIdx = nlaTimeline!.tracks.count - 1
        }

        let lastEnd = nlaTimeline!.tracks[lipSyncTrackIdx].clips
            .map { $0.startFrame + $0.timelineDuration(motionClipFrameCount: clip.frameCount) }
            .max() ?? 0

        let entry = NLAClip(
            motionClipID: clip.id,
            startFrame: lastEnd,
            speed: 1.0,
            blendInFrames: Int((Double(fps) * 0.05).rounded()),
            blendOutFrames: Int((Double(fps) * 0.05).rounded())
        )

        nlaTimeline!.tracks[lipSyncTrackIdx].clips.append(entry)

        let clipEndTime = Double(lastEnd + clip.frameCount) / Double(max(fps, 1))
        nlaTimeline!.duration = max(nlaTimeline!.duration, clipEndTime)

        saveNLATimeline()
        evaluateNLAAtCurrentFrame()
    }

    // MARK: - Playback Helpers (Phase 6 additions)

    /// Step the playhead by `delta` frames (only when not playing).
    func stepFrame(delta: Int) {
        guard !isPlaying else { return }
        currentFrame = max(0, min(totalFrames - 1, currentFrame + delta))
        evaluateNLAAtCurrentFrame()
    }

    // MARK: - BVH Export

    func exportClipAsBVH(clipID: UUID) {
        guard let clip = motionClips.first(where: { $0.id == clipID }) else { return }

        let panel = NSSavePanel()
        if let bvhType = UTType(filenameExtension: "bvh") {
            panel.allowedContentTypes = [bvhType]
        }
        panel.nameFieldStringValue = "\(clip.name).bvh"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try BVHExporter.exportToFile(clip, url: url)
        } catch {
            print("[BVHExport] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Clip Speed

    func setClipSpeed(clipID: UUID, speed: Float) {
        guard var timeline = nlaTimeline else { return }
        for trackIdx in timeline.tracks.indices {
            if let clipIdx = timeline.tracks[trackIdx].clips.firstIndex(where: { $0.id == clipID }) {
                timeline.tracks[trackIdx].clips[clipIdx].speed = max(0.1, min(4.0, speed))
            }
        }
        nlaTimeline = timeline
        evaluateNLAAtCurrentFrame()
    }

    // MARK: - Video Import

    var isImportingVideo: Bool {
        get { _isImportingVideo }
        set { _isImportingVideo = newValue }
    }

    var videoImportProgress: VideoMotionExtractor.ExtractionProgress? {
        get { _videoImportProgress }
        set { _videoImportProgress = newValue }
    }

    var videoImportCancelled: Bool {
        get { _videoImportCancelled }
        set { _videoImportCancelled = newValue }
    }

    func importVideoToTimeline(url: URL) async {
        _isImportingVideo = true
        _videoImportProgress = nil
        _videoImportCancelled = false
        _videoImportCancelBox.value = false

        let cancelBox = _videoImportCancelBox

        do {
            let bodyTracker = VisionBodyTracker { _ in }
            let faceTracker = VisionFaceTracker()

            let clip = try await VideoMotionExtractor.extract(
                from: url,
                bodyTracker: bodyTracker,
                faceTracker: faceTracker,
                fps: 30,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?._videoImportProgress = progress
                    }
                },
                cancellation: {
                    // Reads from the atomic box — safe from any context
                    cancelBox.value
                }
            )

            addMotionClipToTimeline(clip)
        } catch {
            print("[VideoImport] Error: \(error.localizedDescription)")
        }

        _isImportingVideo = false
        _videoImportProgress = nil
    }

    func cancelVideoImport() {
        _videoImportCancelled = true
        _videoImportCancelBox.value = true
    }

    // MARK: - Audio Lip Sync Recording

    func startAudioLipSyncRecording() {
        guard !isRecordingAudioLipSync else { return }
        let recorder = AudioLipSyncRecorder()
        do {
            try recorder.startRecording()
            _audioLipSyncRecorder = recorder
            isRecordingAudioLipSync = true
        } catch {
            print("[AudioLipSync] Failed to start: \(error.localizedDescription)")
        }
    }

    func stopAudioLipSyncRecording() {
        guard isRecordingAudioLipSync, let recorder = _audioLipSyncRecorder else { return }
        let clip = recorder.stopRecording()
        _audioLipSyncRecorder = nil
        isRecordingAudioLipSync = false
        addMotionClipToLipSyncTrack(clip)
    }

    // MARK: - Enhanced Tracking Mode (Phase 7)

    /// Switch between standard Vision and enhanced DWPose tracking.
    /// Enhanced mode loads the DWPose Core ML model on first use.
    func setTrackingMode(_ mode: CaptureTrackingMode) throws {
        mocapTrackingMode = mode
        if mode == .enhanced && mocapDWPoseTracker == nil {
            mocapDWPoseTracker = try DWPoseTracker()
        }
    }

    func deleteMotionClip(id: UUID) {
        motionClips.removeAll { $0.id == id }
        if selectedMotionClipID == id {
            selectedMotionClipID = nil
        }
        if let animateDir = animateURL {
            try? MotionClipPersistence.delete(clipID: id, animateURL: animateDir)
        }
    }

    func renameMotionClip(id: UUID, newName: String) {
        guard let index = motionClips.firstIndex(where: { $0.id == id }) else { return }
        motionClips[index].name = newName
    }

    func importBVHFile(url: URL) throws {
        let clip = try BVHParser.parse(url: url)
        addMotionClip(clip)
    }

    // MARK: - Imagine Gallery Management

    func loadImagineGalleries() {
        guard let owpURL = fileOWPURL else { return }
        let stored = ImagineProjectStorage.loadGalleries(owpURL: owpURL)
        var byScene: [UUID: [ImagineSceneShotGallery]] = [:]
        for gallery in stored {
            byScene[gallery.sceneID, default: []].append(gallery)
        }
        imagineSceneGalleries = byScene
    }

    func saveImagineGalleries() {
        guard let owpURL = fileOWPURL else { return }
        let all = imagineSceneGalleries.values.flatMap { $0 }
        try? ImagineProjectStorage.saveGalleries(Array(all), owpURL: owpURL)
    }

    func refreshImagineGalleryFromDisk(sceneID: UUID) {
        guard let owpURL = fileOWPURL,
              let scene = scenes.first(where: { $0.id == sceneID }) else { return }
        let sceneSlug = scene.name.lowercased().replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        var galleries: [ImagineSceneShotGallery] = []
        for (index, shot) in scene.shots.enumerated() {
            let gallery = ImagineProjectStorage.scanShotGallery(
                owpURL: owpURL,
                sceneSlug: sceneSlug,
                shotIndex: index,
                shotID: shot.id,
                sceneID: sceneID
            )
            galleries.append(gallery)
        }
        imagineSceneGalleries[sceneID] = galleries
    }

    func ensureImagineDirectories(for sceneID: UUID) {
        guard let owpURL = fileOWPURL,
              let scene = scenes.first(where: { $0.id == sceneID }) else { return }
        let sceneSlug = scene.name.lowercased().replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        try? ImagineProjectStorage.ensureDirectories(owpURL: owpURL, sceneSlug: sceneSlug, shotCount: scene.shots.count)
    }

    func imagineGallery(for sceneID: UUID, shotIndex: Int) -> ImagineSceneShotGallery? {
        guard let galleries = imagineSceneGalleries[sceneID],
              shotIndex < galleries.count else { return nil }
        return galleries[shotIndex]
    }

    func isGeminiAllowed() -> Bool {
        geminiMasterSwitch
    }

    // MARK: - Canvas Persistence

    private var canvasDir: URL? {
        animateURL?.appendingPathComponent("debug/canvas")
    }

    private var canvasIndexURL: URL? {
        canvasDir?.appendingPathComponent("_index.json")
    }

    /// Reads `_index.json` from the canvas directory and populates `canvasGenerations`.
    /// Called during project load. Silently skips if the file does not exist yet.
    func loadCanvasGenerations() {
        guard let indexURL = canvasIndexURL,
              FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL) else {
            canvasGenerations = []
            return
        }
        canvasGenerations = (try? JSONDecoder().decode([CanvasGeneration].self, from: data)) ?? []
    }

    /// Appends a new generation record and rewrites `_index.json`.
    func appendCanvasGeneration(_ gen: CanvasGeneration) {
        canvasGenerations.append(gen)
        persistCanvasIndex()
    }

    /// Removes a generation record by id, deletes the image file, and rewrites `_index.json`.
    func deleteCanvasGeneration(_ id: UUID) {
        guard let idx = canvasGenerations.firstIndex(where: { $0.id == id }) else { return }
        let gen = canvasGenerations[idx]
        canvasGenerations.remove(at: idx)
        let fm = FileManager.default
        if fm.fileExists(atPath: gen.imagePath) {
            try? fm.removeItem(atPath: gen.imagePath)
        }
        persistCanvasIndex()
    }

    private func persistCanvasIndex() {
        guard let dir = canvasDir, let indexURL = canvasIndexURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(canvasGenerations) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
