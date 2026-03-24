import SwiftUI
import Observation
import Metal
import QuartzCore
import NovotroProjectKit

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

    // MARK: - Image Crop State

    private let assetManager = AssetManager()
    var pendingCropImagePath: String?
    var pendingCropCharacterID: UUID?
    var showImageCropper: Bool = false

    // MARK: - Song Data Cache

    /// Cached song data for the currently selected scene.
    var currentSongData: OWSSongData?

    // MARK: - Backgrounds

    var backgrounds: [BackgroundPlate] = []
    var selectedBackgroundID: UUID?

    // MARK: - Timeline

    var currentFrame: Int = 0
    var fps: Int = 24
    var isPlaying: Bool = false
    var totalFrames: Int = 0

    // MARK: - Gemini

    var geminiAPIKey: String = ""
    var selectedGeminiModel: GeminiModel = .flash

    // MARK: - Generation Sheet State

    var showGenerationSheet: Bool = false
    var showRigEditor: Bool = false
    var showExportSheet: Bool = false
    var generationTargetPartID: UUID?
    var generationTargetAngle: AngleView?

    // MARK: - Scene Tracks (from direction compiler or manual editing)

    var sceneTracks: [String: TimelineTrack] = [:]
    var cameraTrack: TimelineTrack?

    // MARK: - Playback Engine

    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var displayLinkRunning = false
    @ObservationIgnored private var displayLinkProxy: AnimateDisplayLinkProxy?
    private let characterPackageSelectionStore = CharacterPackageSelectionStore()
    private let sceneShotPresetStore = SceneShotPresetStore()
    private var projectDatabase: NovotroProjectConnection?
    private var databaseWatchWorkItem: DispatchWorkItem?
    private var databaseChangeToken: Int64 = 0
    private var pendingSceneDatabaseSyncs: [String: DispatchWorkItem] = [:]
    private var suppressSceneDatabasePaths: Set<String> = []
    private var backgroundIndexRefreshTask: Task<Void, Never>?
    private var externalFileWatchWorkItem: DispatchWorkItem?
    private var lastKnownExternalSnapshots: [String: AnimateExternalFileSnapshot] = [:]
    private static let databaseWatchInterval: TimeInterval = 0.45
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

    func displayName(
        for track: TimelineTrack,
        in scene: AnimationScene? = nil
    ) -> String {
        let normalizedTrack = normalizeTimelineTrack(track, scene: scene)
        let role = resolvedTrackRole(for: normalizedTrack)

        if role == .camera || normalizedTrack.name == Self.cameraTrackName {
            return "Camera"
        }

        if role == .cameraShot || normalizedTrack.name == Self.cameraShotTrackName {
            return "Camera:Shot"
        }

        if role == .cameraDefaultShot || normalizedTrack.name == Self.cameraDefaultShotTrackName {
            return "Camera:Default Shot"
        }

        if role == .cameraFocus || normalizedTrack.name == Self.cameraFocusTrackName {
            return "Camera:Focus"
        }

        if role == .cameraIntent || normalizedTrack.name == Self.cameraIntentTrackName {
            return "Camera:Intent"
        }

        if role == .cameraBeat || normalizedTrack.name == Self.cameraBeatTrackName {
            return "Camera:Beat"
        }

        if role == .cameraNotes || normalizedTrack.name == Self.cameraNotesTrackName {
            return "Camera:Notes"
        }

        if let characterID = normalizedTrack.targetCharacterID,
           let character = characters.first(where: { $0.id == characterID }),
           let role {
            return "\(character.name):\(role.displayLabel)"
        }

        return normalizedTrack.name
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
        guard let track = timelineTrack(for: characterID, role: .transform),
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
        guard let track = timelineTrack(for: characterID, role: .visibility),
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

    func evaluatedCue(
        for characterID: UUID,
        role: TimelineTrackRole,
        at frame: Int? = nil
    ) -> String? {
        guard let track = timelineTrack(for: characterID, role: role),
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

        return tracks.values.sorted { lhs, rhs in
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
        var issues = compiler.validate(plan).issues

        if scenes.isEmpty {
            issues.append(.init(
                severity: .error,
                code: .noSceneAvailable,
                message: "Open a project before applying an animation plan."
            ))
        }

        let placementNames = plan.characterPlacements.map(\.characterName)
        let motionNames = plan.motions.map(\.characterName)
        let expressionNames = plan.expressions.map(\.characterName)
        let dialogueNames = plan.dialogueBeats.map(\.characterName)
        let shadowNames = plan.shadowCues.map(\.characterName)
        let presetFocusNames = plan.shotPresetApplications.compactMap(\.focusCharacterName)
        let presetOverrideNames = plan.shotPresetApplications.flatMap { application in
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

        let resolvedPresetApplications = plan.shotPresetApplications.map { application in
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

        var compiled = compiler.compile(plan, fps: fps)
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
        if let sceneAudioPath = normalizedMediaPath(plan.sceneAudioPath) {
            setSelectedSceneDefaultAudioPath(sceneAudioPath)
        }
        statusMessage = "Applied LLM animation plan: \(plan.sceneName)"
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

        for beat in plan.dialogueBeats.sorted(by: { $0.startFrame < $1.startFrame }) {
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
            statusMessage = "Applied LLM animation plan with generated dialogue: \(plan.sceneName)"
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
            return
        }

        var tracks = scene.tracks.mapValues { normalizeTimelineTrack($0, scene: scene) }
        cameraTrack = tracks.removeValue(forKey: Self.cameraTrackName)
            .map { normalizeTimelineTrack($0, scene: scene) }
        sceneTracks = tracks
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
        scheduleSceneDatabaseSync(for: scenes[sceneIndex].owpSongPath)
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
            keyframes: scene.keyframes,
            defaultAudioPath: scene.defaultAudioPath,
            tracks: scene.tracks,
            directionTemplate: normalizedDirectionTemplateForPersistence(scene.directionTemplate)
        )
    }

    private func applySceneData(_ sceneData: AnimateSceneData, to scene: inout AnimationScene) {
        scene.backgroundID = sceneData.backgroundID
        scene.keyframes = sceneData.keyframes
        scene.defaultAudioPath = sceneData.defaultAudioPath
        scene.tracks = sceneData.tracks
        scene.directionTemplate = sceneData.directionTemplate

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
    }

    private func scheduleSceneDatabaseSync(for relativePath: String, delay: TimeInterval = 0.28) {
        guard projectDatabase != nil,
              let scene = scenes.first(where: { $0.owpSongPath == relativePath }) else {
            return
        }

        pendingSceneDatabaseSyncs[relativePath]?.cancel()
        suppressSceneDatabasePaths.insert(relativePath)
        let payload = makeSceneData(from: scene)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task {
                try? await ProjectDatabaseBridge.upsertAnimationScene(
                    database: self.projectDatabase,
                    sceneData: payload,
                    relativePath: relativePath
                )
                await MainActor.run {
                    self.pendingSceneDatabaseSyncs.removeValue(forKey: relativePath)
                    self.suppressSceneDatabasePaths.remove(relativePath)
                }
            }
        }

        pendingSceneDatabaseSyncs[relativePath] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.checkForExternalProjectChanges()
            self.startExternalFileWatch()
        }
        externalFileWatchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalWatchInterval, execute: workItem)
    }

    private func stopExternalFileWatch() {
        externalFileWatchWorkItem?.cancel()
        externalFileWatchWorkItem = nil
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
        guard pendingSceneDatabaseSyncs.isEmpty else {
            hasPendingAgentChanges = true
            statusMessage = "Newer agent changes are waiting to reload."
            return
        }

        beginAgentSync()
        Task { [weak self] in
            guard let self else { return }
            if let database = self.projectDatabase {
                try? await database.ensureCurrentIndex(forceRebuild: true)
            }
            await self.openOWP(url: projectURL, preferService: false, skipBackgroundRefresh: true)
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
            await MainActor.run {
                self.markAgentUpdated(paths: [relativePath])
                self.statusMessage = "Reloaded external song data"
            }
        }
    }

    private func handleExternalProjectFileChange(path: String, projectURL: URL) {
        if (path == ProjectDatabaseBridge.animateScenesPath || path == ProjectDatabaseBridge.animateMetadataPath),
           !pendingSceneDatabaseSyncs.isEmpty {
            hasPendingAgentChanges = true
            statusMessage = "Newer agent changes are waiting to reload."
            return
        }

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
                    self.syncSelectedSceneTimeline()
                    self.markAgentUpdated()
                    self.statusMessage = "Reloaded external project changes"

                    if let selectedScene {
                        Task { await self.loadSongData(for: selectedScene) }
                    }
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

    private func startDatabaseWatch() {
        stopDatabaseWatch()
        guard projectDatabase != nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pollDatabaseChanges()
            self.startDatabaseWatch()
        }
        databaseWatchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.databaseWatchInterval, execute: workItem)
    }

    private func stopDatabaseWatch() {
        databaseWatchWorkItem?.cancel()
        databaseWatchWorkItem = nil
        for workItem in pendingSceneDatabaseSyncs.values {
            workItem.cancel()
        }
        pendingSceneDatabaseSyncs.removeAll()
        suppressSceneDatabasePaths.removeAll()
        backgroundIndexRefreshTask?.cancel()
        backgroundIndexRefreshTask = nil
    }

    func suspendBackgroundWork() {
        stopDatabaseWatch()
        stopExternalFileWatch()
    }

    func resumeBackgroundWork() {
        startDatabaseWatch()
        startExternalFileWatch()
    }

    private func pollDatabaseChanges() {
        let database = projectDatabase
        let currentToken = databaseChangeToken
        Task { [weak self, database, currentToken] in
            guard let self else { return }
            do {
                let changes = try await ProjectDatabaseBridge.listChanges(
                    database: database,
                    since: currentToken
                )
                guard !changes.isEmpty else { return }
                await MainActor.run {
                    self.databaseChangeToken = changes.last?.changeID ?? self.databaseChangeToken
                    for change in changes {
                        self.applyDatabaseChange(change)
                    }
                }
            } catch {
                NSLog("[AnimateStore] Database poll error: %@", error.localizedDescription)
            }
        }
    }

    private func applyDatabaseChange(_ change: ChangeEvent) {
        guard change.actorID != ProjectDatabaseBridge.animateActorID else { return }

        switch change.entityType {
        case "scene":
            let relativePath = change.entityKey
            guard !suppressSceneDatabasePaths.contains(relativePath) else { return }

            Task {
                do {
                    guard let update = try await ProjectDatabaseBridge.loadAnimateSceneData(
                        database: projectDatabase,
                        relativePath: relativePath
                    ) else {
                        return
                    }

                    await MainActor.run {
                        guard let sceneIndex = self.scenes.firstIndex(where: { $0.owpSongPath == relativePath }) else {
                            return
                        }

                        if let title = update.title, !title.isEmpty {
                            self.scenes[sceneIndex].name = title
                        }
                        if let sceneData = update.sceneData {
                            self.applySceneData(sceneData, to: &self.scenes[sceneIndex])
                        }

                        if self.selectedSceneID == self.scenes[sceneIndex].id {
                            self.syncSelectedSceneTimeline()
                            let scene = self.scenes[sceneIndex]
                            Task { await self.loadSongData(for: scene) }
                        }

                        self.markAgentUpdated(paths: [relativePath])
                    }
                } catch {
                    NSLog("[AnimateStore] Scene load error: %@", error.localizedDescription)
                }
            }
        case "project_file" where change.entityKey == ProjectDatabaseBridge.animateMetadataPath:
            Task {
                do {
                    let metadata = try await ProjectDatabaseBridge.loadAnimateMetadata(database: projectDatabase)
                    await MainActor.run {
                        if let metadata {
                            self.animateMetadata = metadata
                            self.fps = metadata.fps
                        }
                        self.markAgentUpdated()
                    }
                } catch {
                    NSLog("[AnimateStore] Animate metadata load error: %@", error.localizedDescription)
                }
            }
        case "project_file" where ProjectDatabaseBridge.isCharactersProjectFilePath(change.entityKey):
            Task {
                do {
                    let loadedCharacters = try await ProjectDatabaseBridge.loadCharacters(database: projectDatabase)
                    await MainActor.run {
                        if let loadedCharacters {
                            self.syncCharactersFromOWP(loadedCharacters)
                        }
                        self.markAgentUpdated()
                    }
                } catch {
                    NSLog("[AnimateStore] Characters load error: %@", error.localizedDescription)
                }
            }
        case "project_file" where ProjectDatabaseBridge.isIndexProjectFilePath(change.entityKey):
            Task {
                do {
                    let indexFile = try await ProjectDatabaseBridge.loadIndexFile(database: projectDatabase)
                    await MainActor.run {
                        self.owpIndexFile = indexFile
                        self.owpInstrumentMappings = indexFile?.instrumentMappings ?? []
                        self.markAgentUpdated()
                    }
                } catch {
                    NSLog("[AnimateStore] Index file load error: %@", error.localizedDescription)
                }
            }
        case "project_file" where change.entityKey == ProjectDatabaseBridge.characterPackageSelectionsPath:
            Task {
                do {
                    let manifest = try await ProjectDatabaseBridge.loadCharacterPackageSelections(database: projectDatabase)
                    await MainActor.run {
                        if let manifest {
                            self.activePackageIDsByCharacterSlug = manifest.activePackageIDsByCharacterSlug
                        }
                        self.markAgentUpdated()
                    }
                } catch {
                    NSLog("[AnimateStore] Character package selections load error: %@", error.localizedDescription)
                }
            }
        case "project_file" where change.entityKey == ProjectDatabaseBridge.shotPresetsPath:
            Task {
                do {
                    let manifest = try await ProjectDatabaseBridge.loadShotPresets(database: projectDatabase)
                    await MainActor.run {
                        if let manifest {
                            self.shotPresets = self.sortedShotPresets(manifest.presets)
                        }
                        self.markAgentUpdated()
                    }
                } catch {
                    NSLog("[AnimateStore] Shot presets load error: %@", error.localizedDescription)
                }
            }
        default:
            break
        }
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

        let components = normalizedTrack.name.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return (
                900,
                trackSuffixOrder(role?.trackSuffix ?? normalizedTrack.name),
                normalizedTrack.name,
                normalizedTrack.name
            )
        }

        let characterName = components[0]
        let suffix = components[1]
        let characterIndex = scene.characterIDs.enumerated().first { offset, id in
            guard let character = characters.first(where: { $0.id == id }) else { return false }
            return character.name.caseInsensitiveCompare(characterName) == .orderedSame
        }?.offset ?? 800

        return (characterIndex, trackSuffixOrder(suffix), characterName.lowercased(), suffix)
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

    private func resolvedTrackRole(for track: TimelineTrack) -> TimelineTrackRole? {
        if let role = track.role {
            return role
        }

        if track.name == Self.cameraTrackName {
            return .camera
        }

        if track.name == Self.cameraShotTrackName {
            return .cameraShot
        }

        if track.name == Self.cameraDefaultShotTrackName {
            return .cameraDefaultShot
        }

        if track.name == Self.cameraFocusTrackName {
            return .cameraFocus
        }

        if track.name == Self.cameraIntentTrackName {
            return .cameraIntent
        }

        if track.name == Self.cameraBeatTrackName {
            return .cameraBeat
        }

        if track.name == Self.cameraNotesTrackName {
            return .cameraNotes
        }

        let components = track.name.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return nil
        }

        return TimelineTrackRole(trackSuffix: components[1])
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
              normalizedTrack.name != Self.cameraTrackName,
              normalizedTrack.name != Self.cameraShotTrackName,
              normalizedTrack.name != Self.cameraDefaultShotTrackName,
              normalizedTrack.name != Self.cameraFocusTrackName,
              normalizedTrack.name != Self.cameraIntentTrackName,
              normalizedTrack.name != Self.cameraBeatTrackName,
              normalizedTrack.name != Self.cameraNotesTrackName
        else {
            return normalizedTrack
        }

        let components = normalizedTrack.name.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return normalizedTrack
        }

        let characterName = components[0]
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
        if trackName == Self.cameraTrackName {
            return (nil, .camera)
        }

        if trackName == Self.cameraShotTrackName {
            return (nil, .cameraShot)
        }

        if trackName == Self.cameraDefaultShotTrackName {
            return (nil, .cameraDefaultShot)
        }

        if trackName == Self.cameraFocusTrackName {
            return (nil, .cameraFocus)
        }

        if trackName == Self.cameraIntentTrackName {
            return (nil, .cameraIntent)
        }

        if trackName == Self.cameraBeatTrackName {
            return (nil, .cameraBeat)
        }

        if trackName == Self.cameraNotesTrackName {
            return (nil, .cameraNotes)
        }

        let components = trackName.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return (nil, nil)
        }

        let role = TimelineTrackRole(trackSuffix: components[1])
        let characterPool = (scene?.characterIDs ?? characters.map(\.id)).compactMap { id in
            characters.first(where: { $0.id == id })
        }
        let matchedCharacter = characterPool.first { character in
            character.name.caseInsensitiveCompare(components[0]) == .orderedSame
        }
        return (matchedCharacter?.id, role)
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

    func openOWP(url: URL, preferService: Bool? = nil, skipBackgroundRefresh: Bool = false) async {
        guard !isLoadingProject else { return }

        let previousOWPURL = owpURL
        isLoadingProject = true
        loadErrorMessage = nil
        owpURL = url
        workingOWPURL = url
        statusMessage = "Opening project..."
        backgroundIndexRefreshTask?.cancel()
        stopExternalFileWatch()
        externalChangeTimes.removeAll()
        isAgentSyncInProgress = false
        hasPendingAgentChanges = false
        showsRecentAgentUpdate = false

        let fm = FileManager.default
        stopDatabaseWatch()
        projectDatabase = nil
        databaseChangeToken = 0

        if let previousOWPURL, previousOWPURL != url {
            characters = []
            selectedCharacterID = nil
        }

        defer {
            isLoadingProject = false
        }

        do {
            // 1. Load OWP data from the shared project database
            let result = try await ProjectDatabaseBridge.loadAnimateProject(url: url, preferService: preferService)
            let effectiveProjectURL = result.workingProjectURL
            let hasLocalMirror = fm.fileExists(atPath: effectiveProjectURL.path)
            projectDatabase = result.database
            databaseChangeToken = (try? await ProjectDatabaseBridge.currentChangeToken(database: result.database)) ?? 0
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
            if let manifest = try await ProjectDatabaseBridge.loadCharacterPackageSelections(database: result.database) {
                activePackageIDsByCharacterSlug = manifest.activePackageIDsByCharacterSlug
            } else {
                activePackageIDsByCharacterSlug = characterPackageSelectionStore
                    .load(from: animateDir)
                    .activePackageIDsByCharacterSlug
            }

            if let manifest = try await ProjectDatabaseBridge.loadShotPresets(database: result.database) {
                shotPresets = sortedShotPresets(manifest.presets)
            } else {
                shotPresets = sortedShotPresets(sceneShotPresetStore.load(from: animateDir).presets)
            }

            // 4. Load saved scene data from the database-backed scene payloads
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
                        keyframes: saved.keyframes,
                        owpSongPath: saved.owsSongPath,
                        defaultAudioPath: saved.defaultAudioPath,
                        tracks: saved.tracks,
                        directionTemplate: saved.directionTemplate
                    ))
                } else {
                    // New song discovered — create fresh scene
                    newScenes.append(AnimationScene(
                        id: song.id,
                        name: song.title,
                        backgroundID: nil,
                        characterIDs: [],
                        keyframes: [],
                        owpSongPath: song.owsPath
                    ))
                }
            }
            scenes = newScenes
            selectedSceneID = scenes.first?.id

            // 6. Sync characters with OWP characters.json
            syncCharactersFromOWP(result.characters)

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
            }

            // 7. Load backgrounds from Animate/backgrounds/
            let bgDir = animateDir.appendingPathComponent("backgrounds")
            if hasLocalMirror, fm.fileExists(atPath: bgDir.path) {
                backgrounds = try loadBackgrounds(from: bgDir)
            } else {
                backgrounds = []
            }

            let projectName = url.deletingPathExtension().lastPathComponent
            statusMessage = "Opened: \(projectName) (\(scenes.count) songs, \(characters.count) characters)"
            loadErrorMessage = nil
            UserDefaults.standard.set(url.path, forKey: "lastProjectPath")
            startDatabaseWatch()
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
        Task { await openOWP(url: url, preferService: false) }
    }

    // MARK: - Save (writes only to Animate/ subdirectory)

    func save() {
        checkForExternalProjectChanges()
        guard !isAgentSyncInProgress, !hasPendingAgentChanges else {
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
                    keyframes: scene.keyframes,
                    defaultAudioPath: scene.defaultAudioPath,
                    tracks: scene.tracks,
                    directionTemplate: directionTemplate
                )
            }
            let scenesJSON = try encoder.encode(sceneData)
            try scenesJSON.write(to: animateDir.appendingPathComponent("scenes.json"))

            // Save each character state to Animate/characters/{slug}/rig.json
            for character in characters {
                let charDir = animateDir
                    .appendingPathComponent("characters")
                    .appendingPathComponent(character.owpSlug)
                try fm.createDirectory(at: charDir, withIntermediateDirectories: true)
                let rigData = try encoder.encode(character)
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

            let metadata = animateMetadata
            let packageSelectionManifest = CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: activePackageIDsByCharacterSlug
            )
            let shotPresetManifest = SceneShotPresetManifest(presets: shotPresets)
            Task {
                if let metadata {
                    try? await ProjectDatabaseBridge.upsertAnimateMetadata(
                        database: self.projectDatabase,
                        metadata: metadata
                    )
                }

                try? await ProjectDatabaseBridge.upsertAnimateScenesManifest(
                    database: self.projectDatabase,
                    sceneData: sceneData
                )
                try? await ProjectDatabaseBridge.upsertCharacterPackageSelections(
                    database: self.projectDatabase,
                    manifest: packageSelectionManifest
                )
                try? await ProjectDatabaseBridge.upsertShotPresets(
                    database: self.projectDatabase,
                    manifest: shotPresetManifest
                )

                for payload in sceneData {
                    try? await ProjectDatabaseBridge.upsertAnimationScene(
                        database: self.projectDatabase,
                        sceneData: payload,
                        relativePath: payload.owsSongPath
                    )
                }
            }
            recordExternalFileSnapshots()
            statusMessage = "Saved"
            saveIndicator = .saved
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.saveIndicator == .saved {
                    self?.saveIndicator = .idle
                }
            }
        } catch {
            statusMessage = "Save error: \(error.localizedDescription)"
            saveIndicator = .idle
        }
    }

    // MARK: - Song Data Loading

    /// Load song data from the OWS file for the given scene.
    func loadSongData(for scene: AnimationScene) async {
        guard let owpURL = fileOWPURL else { return }

        do {
            if let songData = await ProjectDatabaseBridge.hydrateSongData(
                database: projectDatabase,
                projectURL: owpURL,
                relativePath: scene.owpSongPath
            ) {
                currentSongData = songData
            } else {
                let songURL = owpURL.appendingPathComponent(scene.owpSongPath)
                guard FileManager.default.fileExists(atPath: songURL.path) else {
                    currentSongData = nil
                    return
                }
                let loader = OWPProjectLoader()
                let songData = try await loader.loadSongData(from: songURL)
                currentSongData = songData
            }
        } catch {
            currentSongData = nil
            statusMessage = "Could not load song: \(error.localizedDescription)"
        }
    }

    private func startBackgroundIndexRefresh(projectURL: URL, database: NovotroProjectConnection) {
        backgroundIndexRefreshTask?.cancel()
        backgroundIndexRefreshTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else { return }
                let previousToken = (try? await database.currentChangeToken()) ?? 0
                guard !Task.isCancelled else { return }
                try await database.ensureCurrentIndex()
                guard !Task.isCancelled else { return }
                let refreshedToken = (try? await database.currentChangeToken()) ?? previousToken
                guard refreshedToken != previousToken else { return }
                guard let self else { return }
                guard self.pendingSceneDatabaseSyncs.isEmpty else {
                    await MainActor.run {
                        self.hasPendingAgentChanges = true
                    }
                    return
                }
                NSLog("[AnimateStore] Background index refresh: token changed %lld→%lld, reloading project", previousToken, refreshedToken)
                await self.openOWP(url: projectURL, preferService: false, skipBackgroundRefresh: true)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.markAgentUpdated()
                    self.statusMessage = "Loaded latest disk changes"
                }
            } catch {
                await MainActor.run {
                    guard let self, self.owpURL == projectURL else { return }
                    if self.statusMessage.isEmpty {
                        self.statusMessage = "Background index refresh failed"
                    }
                }
            }
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

        let characterSlug = characters[charIndex].owpSlug
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
                .appendingPathComponent(character.owpSlug)
                .appendingPathComponent("parts")

            try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
            let dest = partsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: dest)
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

        let charDir = animateDir.appendingPathComponent("characters").appendingPathComponent(character.owpSlug)

        do {
            try FileManager.default.createDirectory(at: charDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(character)
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
        characters[index].profileImagePath = imagePath
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
                characterSlug: characters[index].owpSlug,
                category: "profile",
                animateURL: try requireAnimateURL()
            )
            setCharacterProfileImage(storedURL.path, for: characterID)
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

    // MARK: - Character Text Fields

    func updateCharacterBackstory(_ text: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].backstory = text
        save()
    }

    func updateCharacterPersonality(_ text: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].personality = text
        save()
    }

    func updateCharacterNotes(_ text: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].notes = text
        save()
    }

    // MARK: - Inspiration Images

    func addInspirationImage(_ imagePath: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard FileManager.default.fileExists(atPath: imagePath) else {
            statusMessage = "Image file not found: \(URL(fileURLWithPath: imagePath).lastPathComponent)"
            return
        }
        guard !characters[index].inspirationImagePaths.contains(imagePath) else {
            statusMessage = "Image already added"
            return
        }
        characters[index].inspirationImagePaths.append(imagePath)
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
                let slug = self.characters[index].owpSlug
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

    // MARK: - Inspiration Reference Image

    func setInspirationReferenceImage(_ imagePath: String?, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].inspirationReferenceImagePath = imagePath
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
                        characterSlug: self.characters[index].owpSlug,
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

    // MARK: - Reference Images Gallery

    func addReferenceImage(_ imagePath: String, for characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard FileManager.default.fileExists(atPath: imagePath) else {
            statusMessage = "Image file not found: \(URL(fileURLWithPath: imagePath).lastPathComponent)"
            return
        }
        guard !characters[index].referenceImagePaths.contains(imagePath) else {
            statusMessage = "Image already added"
            return
        }
        characters[index].referenceImagePaths.append(imagePath)
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
                for url in panel.urls {
                    do {
                        let storedURL = try self.assetManager.importCharacterImageURL(
                            from: url,
                            characterSlug: self.characters[index].owpSlug,
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
        guard FileManager.default.fileExists(atPath: imagePath) else {
            statusMessage = "Image file not found: \(URL(fileURLWithPath: imagePath).lastPathComponent)"
            return
        }
        guard !characters[index].animatedImagePaths.contains(imagePath) else {
            statusMessage = "Image already added"
            return
        }
        characters[index].animatedImagePaths.append(imagePath)
        save()
    }

    func removeAnimatedImage(at indexToRemove: Int, for characterID: UUID) {
        guard let charIndex = characters.firstIndex(where: { $0.id == characterID }) else { return }
        guard characters[charIndex].animatedImagePaths.indices.contains(indexToRemove) else { return }
        characters[charIndex].animatedImagePaths.remove(at: indexToRemove)
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
                let slug = self.characters[index].owpSlug
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

    // MARK: - Background Management

    func importBackground(from url: URL) {
        let bg = BackgroundPlate(
            id: UUID(),
            name: url.deletingPathExtension().lastPathComponent,
            filename: url.lastPathComponent,
            sourceURL: url
        )
        backgrounds.append(bg)

        // Copy file into Animate/backgrounds/
        if let animateDir = animateURL {
            let bgDir = animateDir.appendingPathComponent("backgrounds")
            try? FileManager.default.createDirectory(at: bgDir, withIntermediateDirectories: true)
            let dest = bgDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
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
                sourceURL: item
            ))
        }

        return result
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

    private func loadPersistedCharacterState(for slug: String) -> AnimationCharacter? {
        guard let animateURL else { return nil }

        let rigURL = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("rig.json")
        guard FileManager.default.fileExists(atPath: rigURL.path),
              let rigData = try? Data(contentsOf: rigURL),
              let savedChar = try? JSONDecoder().decode(AnimationCharacter.self, from: rigData) else {
            return nil
        }

        return savedChar
    }

    private func syncCharactersFromOWP(_ sourceCharacters: [OPWCharacter]) {
        owpCharacters = sourceCharacters

        let existingBySlug = Dictionary(uniqueKeysWithValues: characters.map { ($0.owpSlug, $0) })
        var updatedCharacters: [AnimationCharacter] = []
        var seenSlugs: Set<String> = []

        for sourceCharacter in sourceCharacters {
            let slug = sourceCharacter.directoryName
            seenSlugs.insert(slug)

            if var existing = existingBySlug[slug] {
                existing.name = sourceCharacter.name
                existing.description = sourceCharacter.description ?? ""
                existing.owpSlug = slug
                updatedCharacters.append(existing)
                continue
            }

            let persistedCharacter = loadPersistedCharacterState(for: slug)
            updatedCharacters.append(
                AnimationCharacter(
                    id: persistedCharacter?.id ?? UUID(),
                    sortOrder: persistedCharacter?.sortOrder ?? updatedCharacters.count,
                    name: sourceCharacter.name,
                    description: sourceCharacter.description ?? "",
                    owpSlug: slug,
                    renderMode: persistedCharacter?.renderMode,
                    preferredViewAngle: persistedCharacter?.preferredViewAngle,
                    parts: persistedCharacter?.parts ?? [],
                    profileImagePath: persistedCharacter?.profileImagePath,
                    backstory: persistedCharacter?.backstory ?? "",
                    personality: persistedCharacter?.personality ?? "",
                    notes: persistedCharacter?.notes ?? "",
                    inspirationImagePaths: persistedCharacter?.inspirationImagePaths ?? [],
                    inspirationReferenceImagePath: persistedCharacter?.inspirationReferenceImagePath,
                    referenceImagePaths: persistedCharacter?.referenceImagePaths ?? [],
                    animatedImagePaths: persistedCharacter?.animatedImagePaths ?? []
                )
            )
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
            Task {
                try? await ProjectDatabaseBridge.upsertCharacterPackageSelections(
                    database: self.projectDatabase,
                    manifest: manifest
                )
            }
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
            Task {
                try? await ProjectDatabaseBridge.upsertShotPresets(
                    database: self.projectDatabase,
                    manifest: manifest
                )
            }
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

    /// Generate lip sync keyframes from a dialogue or vocal audio file using Rhubarb.
    func generateLipSyncFromAudio(
        for characterName: String,
        audioURL: URL,
        dialogueText: String? = nil
    ) async {
        statusMessage = "Generating lip sync from audio for \(characterName)..."

        do {
            let visemeKeyframes = try await RhubarbLipSync().analyzeToVisemes(
                audioURL: audioURL,
                fps: fps,
                dialogueText: dialogueText
            )
            applyLipSyncVisemes(visemeKeyframes, for: characterName)
            statusMessage = "Generated \(visemeKeyframes.count) audio lip sync keyframes for \(characterName)"
        } catch {
            statusMessage = "Lip sync generation failed for \(characterName): \(error.localizedDescription)"
        }
    }
}
