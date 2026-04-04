import SwiftUI
import Observation
import Metal
import QuartzCore
import ProjectKit
import UniformTypeIdentifiers
import CoreMedia

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

struct StoredImageGenerationMetadata: Hashable, Sendable {
    let prompt: String
    let model: String
    let aspectRatio: String
    let imageSize: String
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

    private var fileOWPURL: URL? {
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
    var drawThingsPlaceConfig: DrawThingsPlaceConfig = .init() {
        didSet {
            guard !isHydratingDrawThingsPlacesConfig,
                  drawThingsPlaceConfig != oldValue else { return }
            scheduleDebouncedSave()
        }
    }

    var selectedPlace: BackgroundPlate? {
        backgrounds.first { $0.id == selectedBackgroundID }
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
    var viduQueue: [ViduBatchQueueItem] = []

    // MARK: - Meshy Settings

    var meshyAPIKey: String = "" {
        didSet {
            guard !isHydratingMeshySettings else { return }
            meshyCredentialStore.saveAPIKey(meshyAPIKey)
        }
    }

    var meshyBalance: Int?
    var meshyGenerationTaskID: String?
    var meshyGenerationStatus: MeshyTaskStatus?
    var meshyGenerationProgress: Int = 0
    var meshyGenerationError: String?
    var isGeneratingMeshy3D: Bool = false
    var meshyGeneratingCharacterID: UUID?
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
    var show3DExportSheet: Bool = false
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

    struct MeshyBatchQueueItem: Identifiable, Sendable {
        var id: UUID = UUID()
        var characterID: UUID
        var characterName: String
        var costumeName: String
        var dateQueued: Date = Date()
    }

    var geminiQueue: [GeminiBatchQueueItem] = []
    var meshyQueue: [MeshyBatchQueueItem] = []

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

    func addToMeshyQueue(characterID: UUID, characterName: String, costumeName: String) {
        meshyQueue.append(MeshyBatchQueueItem(characterID: characterID, characterName: characterName, costumeName: costumeName))
    }

    func removeGeminiQueueItem(_ id: UUID) { geminiQueue.removeAll { $0.id == id } }
    func removeMeshyQueueItem(_ id: UUID) { meshyQueue.removeAll { $0.id == id } }
    func clearGeminiQueue() { geminiQueue.removeAll() }
    func clearMeshyQueue() { meshyQueue.removeAll() }

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
    @ObservationIgnored private var isHydratingMeshySettings = false
    @ObservationIgnored private var isHydratingDrawThingsPlacesConfig = false

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
    private let meshyCredentialStore = MeshyCredentialStore()
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
        observePersistedSaveState()
        hydrateGeminiSettings()
        hydrateMiniMaxSettings()
        hydrateViduSettings()
        hydrateMeshySettings()
    }

    func setGeminiAPIKey(_ apiKey: String) {
        geminiAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearGeminiAPIKey() {
        geminiAPIKey = ""
    }

    func setMeshyAPIKey(_ apiKey: String) {
        meshyAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearMeshyAPIKey() {
        meshyAPIKey = ""
        meshyBalance = nil
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

    func setMiniMaxAPIKey(_ apiKey: String) {
        miniMaxAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearMiniMaxAPIKey() {
        miniMaxAPIKey = ""
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

    private func hydrateMeshySettings() {
        isHydratingMeshySettings = true
        meshyAPIKey = meshyCredentialStore.loadAPIKey()
        isHydratingMeshySettings = false
    }

    private func hydrateDrawThingsPlacesConfig(_ config: DrawThingsPlaceConfig) {
        isHydratingDrawThingsPlacesConfig = true
        drawThingsPlaceConfig = config
        isHydratingDrawThingsPlacesConfig = false
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
            _ = await self.refreshPlacesFromScript()
            await MainActor.run {
                self.markAgentUpdated(paths: [relativePath])
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
                    }
                    self.syncSelectedSceneTimeline()
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"

                    if let selectedScene {
                        Task { await self.loadSongData(for: selectedScene) }
                    }
                    Task { _ = await self.refreshPlacesFromScript() }
                }
            case ProjectDatabaseBridge.animatePlacesPath:
                await MainActor.run {
                    guard let animateDir = self.animateURL else { return }
                    let backgroundDir = animateDir.appendingPathComponent("backgrounds")
                    self.backgrounds = (try? self.loadPlaces(from: animateDir, backgroundDirectoryURL: backgroundDir)) ?? []
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

            let didRefreshPlaces = await refreshPlacesFromScript(persistChanges: false)

            // 8. Load motion clips
            motionClips = (try? MotionClipPersistence.loadAll(animateURL: animateDir)) ?? []

            let projectName = url.deletingPathExtension().lastPathComponent
            if didMigrateCharacterStorage || didRefreshPlaces {
                save()
            }
            statusMessage = "Opened: \(projectName) (\(scenes.count) songs, \(characters.count) characters)"
            loadErrorMessage = nil
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
    func scheduleDebouncedSave() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: - Save (writes only to Animate/ subdirectory)

    func save() {
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

            let placesData = try encoder.encode(backgrounds.map(persistedBackgroundPlate))
            try placesData.write(to: animateDir.appendingPathComponent("places.json"))
            try ProjectDatabaseBridge.saveDrawThingsPlacesConfigToDisk(
                drawThingsPlaceConfig,
                projectURL: workingOWPURL ?? owpURL ?? animateDir.deletingLastPathComponent()
            )

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

    func storeGeneratedInspirationImage(
        _ data: Data,
        prompt: String,
        model: GeminiModel,
        filenameStem: String,
        for characterID: UUID,
        aspectRatio: String,
        imageSize: String
    ) throws {
        let animateURL = try requireAnimateURL()
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }

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
            to: storedURL
        )
        let storedPath = projectRelativeCharacterAssetPath(from: storedURL.path)
            ?? normalizedCharacterAssetPath(storedURL.path)
            ?? storedURL.path
        guard !characters[charIndex].inspirationImagePaths.contains(storedPath) else { return }
        var updatedCharacter = characters[charIndex]
        updatedCharacter.inspirationImagePaths.append(storedPath)
        characters[charIndex] = updatedCharacter
        save()
    }

    func registerInspirationBatchJob(_ job: CharacterInspirationBatchJob, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let normalizedMetadataPath = normalizedCharacterAssetPath(job.metadataPath) ?? job.metadataPath
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

    func refreshInspirationBatchJobs() {
        var didChange = false

        for charIndex in characters.indices {
            var jobs = normalizedInspirationBatchJobs(characters[charIndex].inspirationBatchJobs)
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
                }
            }

            characters[charIndex].inspirationBatchJobs = jobs
        }

        if didChange {
            save()
        }
    }

    // MARK: - Inspiration Reference Image

    func setInspirationReferenceImage(_ imagePath: String?, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].inspirationReferenceImagePath = normalizedCharacterAssetPath(imagePath)
        save()
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

    // MARK: - Character 3D Models

    func import3DModel(for characterID: UUID, costumeName: String) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }),
              let animateURL else { return }

        let panel = NSOpenPanel()
        panel.title = "Import 3D Model for \(costumeName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "glb")!,
            .init(filenameExtension: "usdz")!,
            .init(filenameExtension: "obj")!,
        ]

        panel.begin { [weak self] response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                guard let index = self.characters.firstIndex(where: { $0.id == characterID }) else { return }
                let slug = self.characters[index].assetFolderSlug
                let modelsDir = animateURL
                    .appendingPathComponent("characters")
                    .appendingPathComponent(slug)
                    .appendingPathComponent("models")

                do {
                    try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
                    let destURL = modelsDir.appendingPathComponent(sourceURL.lastPathComponent)
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)

                    let ext = sourceURL.pathExtension.lowercased()
                    let model = Character3DModel(
                        costumeName: costumeName,
                        modelFileName: sourceURL.lastPathComponent,
                        modelFormat: ext
                    )

                    // Remove any existing model for this costume, then add the new one
                    self.characters[index].models3D.removeAll(where: { $0.costumeName == costumeName })
                    self.characters[index].models3D.append(model)
                    self.save()
                    self.statusMessage = "Imported 3D model: \(sourceURL.lastPathComponent)"
                } catch {
                    self.statusMessage = "Failed to import 3D model: \(error.localizedDescription)"
                }
            }
        }
    }

    func remove3DModel(_ modelID: UUID, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let modelIndex = characters[charIndex].models3D.firstIndex(where: { $0.id == modelID })
        else { return }

        let model = characters[charIndex].models3D[modelIndex]

        // Remove the file from disk if possible
        if let animateURL {
            let slug = characters[charIndex].assetFolderSlug
            let modelFile = animateURL
                .appendingPathComponent("characters")
                .appendingPathComponent(slug)
                .appendingPathComponent("models")
                .appendingPathComponent(model.modelFileName)
            try? FileManager.default.removeItem(at: modelFile)
        }

        characters[charIndex].models3D.remove(at: modelIndex)
        save()
        statusMessage = "Removed 3D model: \(model.modelFileName)"
    }

    func update3DModelNotes(_ modelID: UUID, notes: String, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }),
              let modelIndex = characters[charIndex].models3D.firstIndex(where: { $0.id == modelID })
        else { return }
        characters[charIndex].models3D[modelIndex].notes = notes
        save()
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

        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        // Curated picks always come first — they're the user's hand-selected references
        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }

        if character.masterReferenceSourceImagePaths.isEmpty {
            character.inspirationImagePaths.prefix(3).forEach { append($0) }
        } else {
            character.masterReferenceSourceImagePaths.forEach { append($0) }
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
        to imageURL: URL
    ) throws {
        let payload: [String: Any] = [
            "request": [
                "prompt": prompt,
                "model_alias": model.displayName,
                "model": model.rawValue,
                "image_size": imageSize,
                "aspect_ratio": aspectRatio,
            ]
        ]
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
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ path: String?) {
            guard let path = normalizedCharacterAssetPath(path),
                  seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        append(character.inspirationReferenceImagePath)
        character.curatedInspirationImagePaths.forEach { append($0) }
        character.inspirationImagePaths.prefix(3).forEach { append($0) }
        return ordered
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

        return StoredImageGenerationMetadata(
            prompt: prompt,
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )
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
    func refreshPlacesFromScript(persistChanges: Bool = true) async -> Bool {
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
            save()
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
            save()
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
        save()
    }

    func updatePlaceNotes(_ notes: String, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              backgrounds[index].notes != notes else { return }
        backgrounds[index].notes = notes
        scheduleDebouncedSave()
    }

    func addImagesToPlaceFromPicker(placeID: UUID) {
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
                    self.addImageToPlace(from: url, placeID: placeID)
                }
            }
        }
    }

    func addImageToPlace(from url: URL, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              let animateDir = animateURL else { return }

        do {
            let storedURL = try assetManager.importBackgroundImage(from: url, animateURL: animateDir)
            let imagePath = normalizedCharacterAssetPath(storedURL.path) ?? storedURL.path
            if !backgrounds[index].imagePaths.contains(imagePath) {
                backgrounds[index].imagePaths.append(imagePath)
            }
            if backgrounds[index].approvedImagePath == nil {
                backgrounds[index].approvedImagePath = imagePath
            }
            backgrounds[index].filename = URL(fileURLWithPath: backgrounds[index].approvedImagePath ?? imagePath).lastPathComponent
            backgrounds[index].sourceURL = resolvedCharacterAssetURL(for: backgrounds[index].approvedImagePath ?? imagePath)
            save()
        } catch {
            statusMessage = "Failed to add place image: \(error.localizedDescription)"
        }
    }

    func setApprovedPlaceImage(_ imagePath: String, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              let normalizedPath = normalizedCharacterAssetPath(imagePath) else { return }
        backgrounds[index].approvedImagePath = normalizedPath
        backgrounds[index].filename = URL(fileURLWithPath: normalizedPath).lastPathComponent
        backgrounds[index].sourceURL = resolvedCharacterAssetURL(for: normalizedPath)
        save()
    }

    func removePlaceImage(at imageIndex: Int, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }),
              backgrounds[index].imagePaths.indices.contains(imageIndex) else { return }

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
        save()
    }

    func deletePlace(_ placeID: UUID) {
        backgrounds.removeAll { $0.id == placeID }
        for sceneIndex in scenes.indices where scenes[sceneIndex].backgroundID == placeID {
            scenes[sceneIndex].backgroundID = nil
        }
        if selectedBackgroundID == placeID {
            selectedBackgroundID = backgrounds.first?.id
        }
        save()
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
            save()
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
        save()
    }

    func removeAngleImage(_ angleImageID: UUID, placeID: UUID) {
        guard let placeIndex = backgrounds.firstIndex(where: { $0.id == placeID }),
              let angleIndex = backgrounds[placeIndex].angleImages.firstIndex(where: { $0.id == angleImageID }) else { return }

        backgrounds[placeIndex].angleImages.remove(at: angleIndex)
        save()
    }

    func updatePlaceCategory(_ category: String, placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        backgrounds[index].locationCategory = category
        save()
    }

    func updatePlaceSceneUsage(_ usage: [String], placeID: UUID) {
        guard let index = backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        backgrounds[index].sceneUsage = usage
        save()
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

    private func hydratedBackgroundPlate(_ background: BackgroundPlate) -> BackgroundPlate {
        var updated = background
        updated.imagePaths = normalizedCharacterAssetPaths(background.imagePaths)
        updated.approvedImagePath = normalizedCharacterAssetPath(background.approvedImagePath)
            ?? updated.imagePaths.first
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

    // MARK: - Meshy 3D Generation

    func generateMeshy3DModel(
        for characterID: UUID,
        imageURLs: [String],
        textureImageURL: String?,
        config: MeshyMultiImageRequest
    ) async {
        guard !meshyAPIKey.isEmpty else {
            meshyGenerationError = "No Meshy API key configured. Open Settings to add one."
            return
        }
        guard !isGeneratingMeshy3D else { return }
        guard !imageURLs.isEmpty else { meshyGenerationError = "No reference images available."; isGeneratingMeshy3D = false; return }

        isGeneratingMeshy3D = true
        meshyGeneratingCharacterID = characterID
        meshyGenerationError = nil
        meshyGenerationProgress = 0
        meshyGenerationStatus = .pending

        do {
            let service = MeshyService(apiKey: meshyAPIKey)
            var request = config
            request.imageURLs = imageURLs
            if let textureURL = textureImageURL {
                request.textureImageURL = textureURL
            }

            let endpoint: String
            let taskID: String
            if imageURLs.count > 1 {
                taskID = try await service.createMultiImageTo3D(request)
                endpoint = "multi-image-to-3d"
            } else {
                let singleRequest = MeshyImageRequest(
                    imageURL: imageURLs[0],
                    aiModel: request.aiModel,
                    topology: request.topology,
                    targetPolycount: request.targetPolycount,
                    shouldRemesh: request.shouldRemesh,
                    shouldTexture: request.shouldTexture,
                    enablePBR: request.enablePBR,
                    removeLighting: request.removeLighting,
                    textureImageURL: request.textureImageURL,
                    targetFormats: request.targetFormats
                )
                taskID = try await service.createImageTo3D(singleRequest)
                endpoint = "image-to-3d"
            }

            meshyGenerationTaskID = taskID

            let result = try await service.pollUntilComplete(
                endpoint: endpoint,
                taskID: taskID
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.meshyGenerationStatus = progress.status
                    self?.meshyGenerationProgress = progress.progress
                }
            }

            guard let modelURLs = result.modelURLs else {
                throw MeshyService.ServiceError.invalidResponse
            }

            try await downloadMeshyAssets(
                service: service,
                characterID: characterID,
                taskID: taskID,
                modelURLs: modelURLs,
                thumbnailURL: result.thumbnailURL
            )

            meshyGenerationStatus = .succeeded
            meshyGeneratingCharacterID = nil

        } catch {
            meshyGenerationError = error.localizedDescription
            meshyGenerationStatus = .failed
            meshyGeneratingCharacterID = nil
        }

        isGeneratingMeshy3D = false
    }

    private func downloadMeshyAssets(
        service: MeshyService,
        characterID: UUID,
        taskID: String,
        modelURLs: [String: String],
        thumbnailURL: String?
    ) async throws {
        guard let character = characters.first(where: { $0.id == characterID }),
              let animateURL = animateURL else { return }

        let slug = character.assetFolderSlug
        let assetDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("3d-models")
            .appendingPathComponent(taskID)

        try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)

        for (format, urlString) in modelURLs {
            guard let remoteURL = URL(string: urlString) else { continue }
            if format.hasPrefix("pre_remeshed") || format == "mtl" { continue }
            let destination = assetDir.appendingPathComponent("model.\(format)")
            try await service.downloadAsset(from: remoteURL, to: destination)

            let model3D = Character3DModel(
                costumeName: "meshy-\(taskID.prefix(8))",
                modelFileName: "model.\(format)",
                modelFormat: format,
                notes: "Generated via Meshy.ai (\(taskID))"
            )
            addModel3D(model3D, to: characterID)
        }

        if let thumbURLString = thumbnailURL, let thumbURL = URL(string: thumbURLString) {
            let thumbDest = assetDir.appendingPathComponent("thumbnail.png")
            try? await service.downloadAsset(from: thumbURL, to: thumbDest)
        }

        let metadataURL = assetDir.appendingPathComponent("metadata.json")
        let metadata: [String: Any] = [
            "taskID": taskID,
            "modelURLs": modelURLs,
            "downloadedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            try metadataData.write(to: metadataURL)
        } catch {
            statusMessage = "Failed to save model metadata: \(error.localizedDescription)"
        }
    }

    private func addModel3D(_ model: Character3DModel, to characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].models3D.append(model)
        save()
    }

    // MARK: - Meshy Bridge (auto-trigger from batch completion)

    /// Called when a Gemini batch item completes that may need 3D conversion.
    /// Checks the provider route and, if it's a Meshy route, triggers the bridge.
    func handleBatchItemCompletion(
        kind: String,
        characterID: UUID?,
        characterSlug: String?,
        costumeName: String?,
        generatedImagePaths: [String]
    ) async {
        guard !isGeneratingMeshy3D else { statusMessage = "Meshy generation in progress — queued."; return }
        let route = Animate3DGenerationProviderRoute.defaultRoute(for: kind)
        guard route == .meshy,
              !meshyAPIKey.isEmpty,
              let characterID,
              let characterSlug,
              let animateURL,
              !generatedImagePaths.isEmpty
        else { return }

        let job = MeshyBridgeService.BridgeJob(
            characterID: characterID,
            characterSlug: characterSlug,
            costumeName: costumeName ?? "default",
            sourceImagePaths: generatedImagePaths,
            meshyConfig: MeshyMultiImageRequest(
                imageURLs: [],
                targetPolycount: 100_000,
                targetFormats: ["glb", "usdz"]
            )
        )

        isGeneratingMeshy3D = true
        meshyGeneratingCharacterID = characterID
        meshyGenerationError = nil
        meshyGenerationProgress = 0
        meshyGenerationStatus = .pending

        do {
            let result = try await MeshyBridgeService.execute(
                job: job,
                apiKey: meshyAPIKey,
                animateURL: animateURL
            ) { [weak self] status, progress in
                Task { @MainActor in
                    self?.meshyGenerationStatus = status
                    self?.meshyGenerationProgress = progress
                }
            }

            // Register downloaded models on the character
            for model in result.models {
                addModel3D(model, to: characterID)
            }

            meshyGenerationStatus = .succeeded
        } catch {
            meshyGenerationError = error.localizedDescription
            meshyGenerationStatus = .failed
        }

        isGeneratingMeshy3D = false
    }

    func fetchMeshyBalance() async {
        guard !meshyAPIKey.isEmpty else {
            meshyBalance = nil
            return
        }
        let service = MeshyService(apiKey: meshyAPIKey)
        meshyBalance = try? await service.checkBalance()
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
}
