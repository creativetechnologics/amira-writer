import Foundation
import Observation
import simd

@available(macOS 26.0, *)
enum Animate3DScenarioMode: String, CaseIterable, Identifiable {
    case auto
    case selectedScene = "selected_scene"
    case fixture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .selectedScene: "Scene"
        case .fixture: "Fixture"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: "Prefer live scene data, then libretto, then fallback fixture."
        case .selectedScene: "Use the currently selected project scene as the source."
        case .fixture: "Use a built-in translation test scene with placeholder cast."
        }
    }
}

@available(macOS 26.0, *)
enum Animate3DPlaybackStyle: String, CaseIterable, Identifiable {
    case onOnes = "on_ones"
    case onTwos = "on_twos"
    case onThrees = "on_threes"
    case onFours = "on_fours"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onOnes: "1s"
        case .onTwos: "2s"
        case .onThrees: "3s"
        case .onFours: "4s"
        }
    }

    var targetVisualFPS: Int {
        switch self {
        case .onOnes: 24
        case .onTwos: 12
        case .onThrees: 8
        case .onFours: 6
        }
    }

    var recommendation: String {
        switch self {
        case .onOnes:
            "Use for fast action, whip pans, or dense camera choreography."
        case .onTwos:
            "Best default for anime-style blocking and most dialogue scenes."
        case .onThrees:
            "Good for holds, restrained acting, or economical staging."
        case .onFours:
            "Use sparingly for highly graphic holds or very stylized restraint."
        }
    }

    func quantizedFrame(_ frame: Int, baseFPS: Int) -> Int {
        let hold = max(1, Int(round(Double(max(baseFPS, 1)) / Double(targetVisualFPS))))
        return max(0, (frame / hold) * hold)
    }
}

@available(macOS 26.0, *)
enum Animate3DRendererMode: String, CaseIterable, Identifiable {
    case productionEngine = "production_engine"
    case translationHarness = "translation_harness"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .productionEngine: "Engine"
        case .translationHarness: "Harness"
        }
    }

    var subtitle: String {
        switch self {
        case .productionEngine:
            "Compile libretto + scene data into the cel-shaded 3D production engine."
        case .translationHarness:
            "Keep the older debug harness for placeholder translation and guide inspection."
        }
    }
}

@available(macOS 26.0, *)
struct Animate3DGenerationDraftOverride: Hashable, Sendable {
    var providerHintOverride: String = ""
    var promptAppendix: String = ""
    var isLocked: Bool = false

    var hasVisibleChanges: Bool {
        !providerHintOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !promptAppendix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        isLocked
    }
}

@available(macOS 26.0, *)
@Observable @MainActor
final class Animate3DTestHarnessState {
    var scenarioMode: Animate3DScenarioMode = .auto
    var rendererMode: Animate3DRendererMode = .productionEngine
    var playbackStyle: Animate3DPlaybackStyle = .onTwos
    var previewFrame: Int = 0
    var isPlaying = false
    var showsGrid = true
    var showsFrustum = true
    var showsCameraPath = true
    var debugOrbitEnabled = false
    var debugOrbitAutoRecenter = true
    var showsRigLabels = true
    var showsFocusMarker = true
    var showsAttachmentGuides = true
    var showsMotionPaths = true
    var showsShotLabels = true
    var showsPackageCutouts = true
    var autoResetOnScenarioChange = true
    var pinnedGenerationQueueItemKeys: Set<String> = []
    var skippedGenerationQueueItemKeys: Set<String> = []
    var generationDraftOverridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]

    @ObservationIgnored private var timer: Timer?

    func reset() {
        previewFrame = 0
    }

    func togglePinnedGenerationQueueItem(_ key: String) {
        if pinnedGenerationQueueItemKeys.contains(key) {
            pinnedGenerationQueueItemKeys.remove(key)
        } else {
            pinnedGenerationQueueItemKeys.insert(key)
            skippedGenerationQueueItemKeys.remove(key)
        }
    }

    func toggleSkippedGenerationQueueItem(_ key: String) {
        if skippedGenerationQueueItemKeys.contains(key) {
            skippedGenerationQueueItemKeys.remove(key)
        } else {
            skippedGenerationQueueItemKeys.insert(key)
            pinnedGenerationQueueItemKeys.remove(key)
        }
    }

    func restoreSkippedGenerationQueueItems() {
        skippedGenerationQueueItemKeys.removeAll()
    }

    func generationDraftOverride(for key: String) -> Animate3DGenerationDraftOverride {
        generationDraftOverridesByStableKey[key] ?? Animate3DGenerationDraftOverride()
    }

    func setProviderHintOverride(_ value: String, for key: String) {
        var override = generationDraftOverride(for: key)
        override.providerHintOverride = value
        storeGenerationDraftOverride(override, for: key)
    }

    func setPromptAppendix(_ value: String, for key: String) {
        var override = generationDraftOverride(for: key)
        override.promptAppendix = value
        storeGenerationDraftOverride(override, for: key)
    }

    func setGenerationDraftLocked(_ locked: Bool, for key: String) {
        var override = generationDraftOverride(for: key)
        override.isLocked = locked
        storeGenerationDraftOverride(override, for: key)
    }

    func clearGenerationDraftOverride(for key: String) {
        generationDraftOverridesByStableKey.removeValue(forKey: key)
    }

    func clearGenerationDraftOverrides(for keys: some Sequence<String>) {
        for key in keys {
            generationDraftOverridesByStableKey.removeValue(forKey: key)
        }
    }

    private func storeGenerationDraftOverride(_ override: Animate3DGenerationDraftOverride, for key: String) {
        if override.hasVisibleChanges {
            generationDraftOverridesByStableKey[key] = override
        } else {
            generationDraftOverridesByStableKey.removeValue(forKey: key)
        }
    }

    func clamp(to scenario: Animate3DPreviewScenario) {
        previewFrame = min(max(0, previewFrame), max(0, scenario.totalFrames - 1))
    }

    func prepareTransport(
        in store: AnimateStore,
        scenario: Animate3DPreviewScenario,
        resetFrame: Bool = false
    ) {
        let maxFrame = max(0, scenario.totalFrames - 1)
        if resetFrame {
            store.currentFrame = 0
        } else {
            store.currentFrame = min(max(0, store.currentFrame), maxFrame)
        }
        previewFrame = store.currentFrame
        isPlaying = store.isPlaying
    }

    func seek(
        to frame: Int,
        scenario: Animate3DPreviewScenario,
        store: AnimateStore
    ) {
        let clamped = min(max(0, frame), max(0, scenario.totalFrames - 1))
        store.currentFrame = clamped
        previewFrame = clamped
    }

    func step(by delta: Int, scenario: Animate3DPreviewScenario) {
        guard scenario.totalFrames > 0 else {
            previewFrame = 0
            return
        }
        let maxFrame = max(0, scenario.totalFrames - 1)
        previewFrame = min(max(0, previewFrame + delta), maxFrame)
    }

    func step(
        by delta: Int,
        scenario: Animate3DPreviewScenario,
        store: AnimateStore
    ) {
        stopPlayback(syncing: store)
        guard scenario.totalFrames > 0 else {
            seek(to: 0, scenario: scenario, store: store)
            return
        }

        seek(to: store.currentFrame + delta, scenario: scenario, store: store)
    }

    func togglePlayback(for scenario: Animate3DPreviewScenario) {
        isPlaying ? stopPlayback() : startPlayback(for: scenario)
    }

    func togglePlayback(
        for scenario: Animate3DPreviewScenario,
        store: AnimateStore
    ) {
        store.isPlaying ? stopPlayback(syncing: store) : startPlayback(for: scenario, store: store)
    }

    func startPlayback(for scenario: Animate3DPreviewScenario) {
        stopPlayback()
        guard scenario.totalFrames > 1 else {
            previewFrame = 0
            return
        }

        let interval = 1.0 / Double(max(1, min(scenario.baseFPS, 24)))
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.advanceFrame(for: scenario)
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func startPlayback(
        for scenario: Animate3DPreviewScenario,
        store: AnimateStore
    ) {
        stopPlayback(syncing: store)
        prepareTransport(in: store, scenario: scenario)
        guard scenario.totalFrames > 1 else {
            seek(to: 0, scenario: scenario, store: store)
            return
        }

        let interval = 1.0 / Double(max(1, min(scenario.baseFPS, 24)))
        isPlaying = true
        store.isPlaying = true
        store.statusMessage = "3D preview playing"
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.advanceTransportFrame(for: scenario, store: store)
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopPlayback() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func stopPlayback(syncing store: AnimateStore) {
        timer?.invalidate()
        timer = nil
        isPlaying = false
        if store.isPlaying {
            store.stopPlayback()
        }
        previewFrame = store.currentFrame
    }

    private func advanceFrame(for scenario: Animate3DPreviewScenario) {
        guard scenario.totalFrames > 1 else {
            previewFrame = 0
            stopPlayback()
            return
        }
        previewFrame += 1
        if previewFrame >= scenario.totalFrames {
            previewFrame = 0
        }
    }

    private func advanceTransportFrame(
        for scenario: Animate3DPreviewScenario,
        store: AnimateStore
    ) {
        guard scenario.totalFrames > 1 else {
            seek(to: 0, scenario: scenario, store: store)
            stopPlayback(syncing: store)
            return
        }

        let nextFrame = store.currentFrame + 1
        if nextFrame >= scenario.totalFrames {
            seek(to: 0, scenario: scenario, store: store)
        } else {
            seek(to: nextFrame, scenario: scenario, store: store)
        }
    }
}

@available(macOS 26.0, *)
struct Animate3DValidationCheck: Identifiable, Hashable, Sendable {
    enum Severity: String, Hashable, Sendable {
        case info
        case warning
        case error
    }

    var id: String { title + ":" + detail }
    var title: String
    var passed: Bool
    var severity: Severity
    var detail: String
}

@available(macOS 26.0, *)
struct Animate3DValidationReport: Hashable, Sendable {
    var ready: Bool
    var summary: String
    var checks: [Animate3DValidationCheck]
    var warnings: [String]
}

@available(macOS 26.0, *)
struct Animate3DTranslationDiagnostics: Hashable, Sendable {
    var characterTrackCount: Int
    var objectTrackCount: Int
    var cameraTrackCount: Int
    var shotSegmentCount: Int
    var focusCueCount: Int
    var beatCueCount: Int
    var noteCueCount: Int
    var attachmentCount: Int
    var unsupportedTrackNames: [String]

    static let empty = Animate3DTranslationDiagnostics(
        characterTrackCount: 0,
        objectTrackCount: 0,
        cameraTrackCount: 0,
        shotSegmentCount: 0,
        focusCueCount: 0,
        beatCueCount: 0,
        noteCueCount: 0,
        attachmentCount: 0,
        unsupportedTrackNames: []
    )
}

@available(macOS 26.0, *)
struct Animate3DShotMarker: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String
    var startFrame: Int
    var endFrame: Int
    var cameraShot: CameraShot?
    var shotIntent: String?
    var provenance: String

    func contains(frame: Int) -> Bool {
        frame >= startFrame && frame <= endFrame
    }
}

@available(macOS 26.0, *)
struct Animate3DShotAnchor: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var startFrame: Int
    var endFrame: Int
    var cameraShot: CameraShot?
    var worldPosition: SIMD3<Double>
    var focusPosition: SIMD3<Double>

    func isActive(frame: Int) -> Bool {
        frame >= startFrame && frame <= endFrame
    }
}

@available(macOS 26.0, *)
struct Animate3DPreviewScenario: Identifiable, Hashable, Sendable {
    enum SourceKind: String, Hashable, Sendable {
        case selectedTimeline = "selected_timeline"
        case parsedDirections = "parsed_directions"
        case fixture

        var title: String {
            switch self {
            case .selectedTimeline: "Live Scene"
            case .parsedDirections: "Parsed Directions"
            case .fixture: "Fixture"
            }
        }
    }

    var id: String
    var sceneID: UUID?
    var sceneName: String
    var sourceKind: SourceKind
    var sourceSummary: String
    var backgroundName: String?
    var baseFPS: Int
    var totalFrames: Int
    var castNames: [String]
    var objectNames: [String]
    var defaultShot: CameraShot?
    var focusCharacterName: String?
    var shotMarkers: [Animate3DShotMarker]
    var parsedDirectionCount: Int
    var parseErrorCount: Int
    var validation: Animate3DValidationReport
    var diagnostics: Animate3DTranslationDiagnostics
    var compiledScene: CompiledScene?
    var syncPacket: AnimateSceneSyncPacket?

    static var empty: Animate3DPreviewScenario {
        Animate3DPreviewScenario(
            id: "animate3d-empty",
            sceneID: nil,
            sceneName: "3D Translation Test",
            sourceKind: .fixture,
            sourceSummary: "Select a scene or use the fallback fixture.",
            backgroundName: nil,
            baseFPS: 24,
            totalFrames: 96,
            castNames: [],
            objectNames: [],
            defaultShot: .medium,
            focusCharacterName: nil,
            shotMarkers: [],
            parsedDirectionCount: 0,
            parseErrorCount: 0,
            validation: .init(
                ready: false,
                summary: "No 3D test scenario is loaded yet.",
                checks: [],
                warnings: []
            ),
            diagnostics: .empty,
            compiledScene: nil,
            syncPacket: nil
        )
    }

    static func == (lhs: Animate3DPreviewScenario, rhs: Animate3DPreviewScenario) -> Bool {
        lhs.id == rhs.id &&
            lhs.sceneID == rhs.sceneID &&
            lhs.sceneName == rhs.sceneName &&
            lhs.sourceKind == rhs.sourceKind &&
            lhs.sourceSummary == rhs.sourceSummary &&
            lhs.backgroundName == rhs.backgroundName &&
            lhs.baseFPS == rhs.baseFPS &&
            lhs.totalFrames == rhs.totalFrames &&
            lhs.castNames == rhs.castNames &&
            lhs.objectNames == rhs.objectNames &&
            lhs.defaultShot == rhs.defaultShot &&
            lhs.focusCharacterName == rhs.focusCharacterName &&
            lhs.shotMarkers == rhs.shotMarkers &&
            lhs.parsedDirectionCount == rhs.parsedDirectionCount &&
            lhs.parseErrorCount == rhs.parseErrorCount &&
            lhs.validation == rhs.validation &&
            lhs.diagnostics == rhs.diagnostics
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(sceneID)
        hasher.combine(sceneName)
        hasher.combine(sourceKind)
        hasher.combine(sourceSummary)
        hasher.combine(backgroundName)
        hasher.combine(baseFPS)
        hasher.combine(totalFrames)
        hasher.combine(castNames)
        hasher.combine(objectNames)
        hasher.combine(defaultShot)
        hasher.combine(focusCharacterName)
        hasher.combine(shotMarkers)
        hasher.combine(parsedDirectionCount)
        hasher.combine(parseErrorCount)
        hasher.combine(validation)
        hasher.combine(diagnostics)
    }
}

@available(macOS 26.0, *)
struct Animate3DCameraSnapshot: Hashable, Sendable {
    var position: SIMD3<Double>
    var lookAt: SIMD3<Double>
    var fieldOfView: Double
    var shot: CameraShot?
    var shotLabel: String
    var shotIntent: String?
    var beatLabel: String?
    var focusCharacterName: String?
    var beatNotes: String?

    // MARK: - Camera Smoothing Metadata

    /// Normalized blend progress (0...1) during a shot-type transition, 1.0 when fully settled.
    var shotTransitionProgress: Double = 1.0

    /// Subtle procedural camera drift offset to prevent static-looking locked shots.
    var driftOffset: SIMD3<Double> = .zero
}

@available(macOS 26.0, *)
struct Animate3DMotionTrail: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case character
        case object
    }

    var id: String
    var label: String
    var kind: Kind
    var colorIndex: Int
    var points: [SIMD3<Double>]
}

@available(macOS 26.0, *)
struct Animate3DCharacterSnapshot: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var worldPosition: SIMD3<Double>
    var yawDegrees: Double
    var opacity: Double
    var visible: Bool
    var pose: String?
    var expression: String?
    var action: String?
    var colorIndex: Int
    var characterUUID: UUID? = nil
    var assetFolderSlug: String? = nil
    var packageSelectionSlug: String? = nil
    var preferredAngle: AngleView? = nil
    var preferredPose: CharacterPackagePose? = nil
    var mouthCue: String? = nil

    // MARK: - Secondary Motion Metadata

    /// Speed of movement in world units per frame (0 = stationary).
    var movementSpeed: Double = 0

    /// True when the character is actively translating between keyframes.
    var isMoving: Bool = false

    /// Hint string derived from pose/action/expression for procedural animation (e.g. "walk", "point").
    var actionHint: String? = nil

    /// Vertical offset applied by secondary motion (anticipation / follow-through).
    var secondaryBobOffset: Double = 0

    /// Lateral head-lag offset in world units (head trails the body during movement).
    var headLagOffset: Double = 0
}

@available(macOS 26.0, *)
enum Animate3DPackageCutoutAnchor: String, Hashable, Sendable {
    case root
    case head
    case torso
    case leftArm
    case rightArm
    case leftLeg
    case rightLeg
}

@available(macOS 26.0, *)
struct Animate3DPackageCutoutLayer: Identifiable, Hashable, Sendable {
    var id: String
    var anchor: Animate3DPackageCutoutAnchor
    var assetURL: URL
    var planeSize: SIMD2<Double>
    var localPosition: SIMD3<Double>
    var opacity: Double
}

@available(macOS 26.0, *)
struct Animate3DCharacterPackageCutoutPlan: Identifiable, Hashable, Sendable {
    enum Mode: String, Hashable, Sendable {
        case rigLayers = "rig_layers"
        case layeredParts = "layered_parts"
        case wholeCharacter = "whole_character"
    }

    var id: String
    var characterID: String
    var characterName: String
    var packageName: String
    var mode: Mode
    var layers: [Animate3DPackageCutoutLayer]
}

@available(macOS 26.0, *)
struct Animate3DPlaceholderPoseProfile: Hashable, Sendable {
    var primaryTag: String
    var tags: [String]
    var cueText: String

    var shortSummary: String {
        tags.joined(separator: " · ")
    }

    static func evaluate(_ snapshot: Animate3DCharacterSnapshot) -> Animate3DPlaceholderPoseProfile {
        let cueText = cueText(for: snapshot)

        let isWalking = containsAny(cueText, ["walk", "move", "run", "stride", "cross"])
        let isPointing = containsAny(cueText, ["point", "indicate"])
        let isPresenting = containsAny(cueText, ["present", "offer", "show", "gesture", "explain"])
        let isListening = containsAny(cueText, ["listen", "hear", "consider", "wait", "watch"])
        let isTriumphant = containsAny(cueText, ["celebrate", "victory", "triumph", "excited", "joy"])
        let isSad = containsAny(cueText, ["sad", "worried", "afraid", "tired", "defeated", "shy"])
        let isIntense = containsAny(cueText, ["angry", "determined", "intense", "command", "order", "threat"])
        let isSurprised = containsAny(cueText, ["surprise", "shocked", "shock", "startled"])
        let isSpeaking = containsAny(cueText, ["speak", "talk", "sing", "call", "say", "shout"])
        let isCurious = containsAny(cueText, ["curious", "question", "wonder"])

        var tags: [String] = []
        if isWalking { tags.append("walk") }
        if isPointing { tags.append("point") }
        if isPresenting { tags.append("present") }
        if isListening { tags.append("listen") }
        if isTriumphant { tags.append("triumph") }
        if isSurprised { tags.append("surprise") }
        if isSad { tags.append("sad") }
        if isIntense { tags.append("intense") }
        if isSpeaking { tags.append("speaking") }
        if isCurious { tags.append("curious") }

        if tags.isEmpty {
            tags.append("neutral")
        }

        let primaryTag = tags.first ?? "neutral"
        return Animate3DPlaceholderPoseProfile(
            primaryTag: primaryTag,
            tags: tags,
            cueText: cueText
        )
    }

    private static func cueText(for snapshot: Animate3DCharacterSnapshot) -> String {
        [
            snapshot.pose,
            snapshot.expression,
            snapshot.action
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .joined(separator: " ")
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

enum Animate3DDebugGuideKind: String, Hashable, Sendable {
    case motionTrail = "motion_trail"
    case cameraPath = "camera_path"
    case focusPath = "focus_path"
    case cameraRay = "camera_ray"

    var title: String {
        switch self {
        case .motionTrail: "Motion Trail"
        case .cameraPath: "Camera Path"
        case .focusPath: "Focus Path"
        case .cameraRay: "Camera Ray"
        }
    }
}

@available(macOS 26.0, *)
struct Animate3DDebugGuideSelection: Identifiable, Hashable, Sendable {
    var id: String
    var kind: Animate3DDebugGuideKind
    var title: String
    var detailLines: [String]
}

@available(macOS 26.0, *)
struct Animate3DObjectSnapshot: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var worldPosition: SIMD3<Double>
    var yawDegrees: Double
    var scale: Double
    var opacity: Double
    var visible: Bool
    var attachmentTarget: String?
}

@available(macOS 26.0, *)
struct Animate3DFrameSnapshot: Hashable, Sendable {
    var rawFrame: Int
    var displayFrame: Int
    var totalFrames: Int
    var activeShotTitle: String?
    var camera: Animate3DCameraSnapshot
    var characters: [Animate3DCharacterSnapshot]
    var objects: [Animate3DObjectSnapshot]

    static let empty = Animate3DFrameSnapshot(
        rawFrame: 0,
        displayFrame: 0,
        totalFrames: 1,
        activeShotTitle: nil,
        camera: Animate3DCameraSnapshot(
            position: .zero,
            lookAt: SIMD3<Double>(0, 1, 0),
            fieldOfView: 45,
            shot: nil,
            shotLabel: "Preview",
            shotIntent: nil,
            beatLabel: nil,
            focusCharacterName: nil,
            beatNotes: nil
        ),
        characters: [],
        objects: []
    )
}

// MARK: - Override Persistence

@available(macOS 26.0, *)
extension Animate3DTestHarnessState {
    /// Save current override state to disk
    func saveOverrides(animateURL: URL) {
        var draftOverrides: [String: Animate3DGenerationOverridePersistence.PersistedDraftOverride] = [:]
        for (key, override) in generationDraftOverridesByStableKey {
            draftOverrides[key] = .init(
                providerHintOverride: override.providerHintOverride,
                promptAppendix: override.promptAppendix,
                isLocked: override.isLocked
            )
        }

        let state = Animate3DGenerationOverridePersistence.PersistedOverrideState(
            pinnedKeys: pinnedGenerationQueueItemKeys,
            skippedKeys: skippedGenerationQueueItemKeys,
            draftOverrides: draftOverrides
        )

        Animate3DGenerationOverridePersistence.save(state, animateURL: animateURL)
    }

    /// Load override state from disk
    func loadOverrides(animateURL: URL) {
        let persisted = Animate3DGenerationOverridePersistence.load(animateURL: animateURL)
        pinnedGenerationQueueItemKeys = persisted.pinnedKeys
        skippedGenerationQueueItemKeys = persisted.skippedKeys

        generationDraftOverridesByStableKey = [:]
        for (key, override) in persisted.draftOverrides {
            generationDraftOverridesByStableKey[key] = Animate3DGenerationDraftOverride(
                providerHintOverride: override.providerHintOverride,
                promptAppendix: override.promptAppendix,
                isLocked: override.isLocked
            )
        }
    }
}
