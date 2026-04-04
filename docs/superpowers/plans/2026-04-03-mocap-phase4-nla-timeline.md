# Phase 4: NLA (Non-Linear Animation) Timeline System

**Date:** 2026-04-03
**Goal:** Build the NLA timeline system for motion mixing — layer, blend, and override motion data from different sources (webcam mocap, AI-generated HunyuanMotion, imported BVH) with per-body-part control.

**Prerequisites:** Phases 1-3 complete (CaptureSession, UnifiedPoseFrame, MotionClip, MotionRecorder, MotionRetargeter all exist under `Packages/Animate/Sources/AnimateUI/`).

---

## Step 1: BodyPartMask OptionSet

**File:** `Packages/Animate/Sources/AnimateUI/Motion/BodyPartMask.swift`
**Time:** 2 min
**Why:** Foundation type used by every subsequent model and the evaluator.

```swift
import Foundation

/// Bitmask selecting which body-part joints a motion track controls.
/// Each bit corresponds to a joint group; presets combine common sets.
@available(macOS 26.0, *)
struct BodyPartMask: OptionSet, Codable, Sendable, Hashable {
    let rawValue: UInt32

    // Individual joint groups
    static let head         = BodyPartMask(rawValue: 1 << 0)
    static let face         = BodyPartMask(rawValue: 1 << 1)
    static let mouth        = BodyPartMask(rawValue: 1 << 2)
    static let neck         = BodyPartMask(rawValue: 1 << 3)
    static let spine        = BodyPartMask(rawValue: 1 << 4)
    static let leftArm      = BodyPartMask(rawValue: 1 << 5)
    static let rightArm     = BodyPartMask(rawValue: 1 << 6)
    static let leftHand     = BodyPartMask(rawValue: 1 << 7)
    static let rightHand    = BodyPartMask(rawValue: 1 << 8)
    static let hips         = BodyPartMask(rawValue: 1 << 9)
    static let leftLeg      = BodyPartMask(rawValue: 1 << 10)
    static let rightLeg     = BodyPartMask(rawValue: 1 << 11)
    static let leftFoot     = BodyPartMask(rawValue: 1 << 12)
    static let rightFoot    = BodyPartMask(rawValue: 1 << 13)

    // Presets
    static let fullBody: BodyPartMask = [
        .head, .face, .mouth, .neck, .spine,
        .leftArm, .rightArm, .leftHand, .rightHand,
        .hips, .leftLeg, .rightLeg, .leftFoot, .rightFoot
    ]
    static let upperBody: BodyPartMask = [
        .head, .face, .mouth, .neck, .spine,
        .leftArm, .rightArm, .leftHand, .rightHand
    ]
    static let lowerBody: BodyPartMask = [
        .hips, .leftLeg, .rightLeg, .leftFoot, .rightFoot
    ]
    static let faceAndMouth: BodyPartMask = [.face, .mouth]
    static let arms: BodyPartMask = [.leftArm, .rightArm, .leftHand, .rightHand]
    static let everything = fullBody

    /// All defined individual mask bits, paired with display labels.
    static let allParts: [(mask: BodyPartMask, label: String)] = [
        (.head, "Head"), (.face, "Face"), (.mouth, "Mouth"), (.neck, "Neck"),
        (.spine, "Spine"), (.leftArm, "Left Arm"), (.rightArm, "Right Arm"),
        (.leftHand, "Left Hand"), (.rightHand, "Right Hand"), (.hips, "Hips"),
        (.leftLeg, "Left Leg"), (.rightLeg, "Right Leg"),
        (.leftFoot, "Left Foot"), (.rightFoot, "Right Foot"),
    ]

    /// Named presets for the UI picker.
    static let presets: [(mask: BodyPartMask, label: String)] = [
        (.everything, "Everything"),
        (.fullBody, "Full Body"),
        (.upperBody, "Upper Body"),
        (.lowerBody, "Lower Body"),
        (.faceAndMouth, "Face & Mouth"),
        (.arms, "Arms"),
    ]

    /// Map a joint name string (from MotionClip joint keys) to its body-part bit.
    /// Returns nil for unknown joints (they pass through unmasked).
    static func partForJoint(_ jointName: String) -> BodyPartMask? {
        switch jointName {
        case "head", "Head":                    return .head
        case "jaw", "Jaw":                      return .mouth
        case "leftEye", "rightEye",
             "LeftEye", "RightEye":             return .face
        case "neck_01", "Neck":                 return .neck
        case "spine_01", "spine_02", "spine_03",
             "Spine", "Spine1", "Spine2":       return .spine
        case "leftShoulder", "leftUpperArm", "leftLowerArm",
             "LeftArm", "LeftForeArm",
             "LeftShoulder":                    return .leftArm
        case "rightShoulder", "rightUpperArm", "rightLowerArm",
             "RightArm", "RightForeArm",
             "RightShoulder":                   return .rightArm
        case "leftHand", "LeftHand",
             _ where jointName.hasPrefix("leftFinger"),
             _ where jointName.hasPrefix("LeftHand"):
                                                return .leftHand
        case "rightHand", "RightHand",
             _ where jointName.hasPrefix("rightFinger"),
             _ where jointName.hasPrefix("RightHand"):
                                                return .rightHand
        case "hips", "Hips":                    return .hips
        case "leftUpperLeg", "leftLowerLeg",
             "LeftUpLeg", "LeftLeg":            return .leftLeg
        case "rightUpperLeg", "rightLowerLeg",
             "RightUpLeg", "RightLeg":          return .rightLeg
        case "leftFoot", "leftToeBase",
             "LeftFoot", "LeftToeBase":         return .leftFoot
        case "rightFoot", "rightToeBase",
             "RightFoot", "RightToeBase":       return .rightFoot
        default:                                return nil
        }
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add BodyPartMask OptionSet for per-body-part motion control`

---

## Step 2: NLA Data Models (NLATimeline, NLATrack, NLAClip, NLABlendMode)

**File:** `Packages/Animate/Sources/AnimateUI/Motion/NLATimeline.swift`
**Time:** 3 min
**Why:** The full data model for timelines, tracks, and clips. These are pure value types with no UI dependencies.

```swift
import Foundation

/// Blend mode for an NLA track. Determines how the track's sampled pose
/// combines with the accumulated pose from lower tracks.
@available(macOS 26.0, *)
enum NLABlendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Lerp with accumulated lower layers based on influence weight.
    case replace
    /// Adds delta rotations/values on top of accumulated pose.
    case additive
    /// Replaces accumulated values entirely where body mask matches.
    case override_

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replace: "Replace"
        case .additive: "Additive"
        case .override_: "Override"
        }
    }

    // Use "override" in JSON but avoid Swift keyword collision.
    enum CodingKeys: String, CodingKey {
        case replace
        case additive
        case override_ = "override"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "replace": self = .replace
        case "additive": self = .additive
        case "override": self = .override_
        default: throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unknown NLABlendMode: \(raw)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .replace: try container.encode("replace")
        case .additive: try container.encode("additive")
        case .override_: try container.encode("override")
        }
    }
}

/// A reference to a motion clip placed on an NLA track, with timing and trim info.
@available(macOS 26.0, *)
struct NLAClip: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    /// UUID of the MotionClip in the motion library.
    var motionClipID: UUID
    /// Frame on the NLA timeline where this clip begins playing.
    var startFrame: Int
    /// Playback speed multiplier (1.0 = normal).
    var speed: Float
    /// How many frames to skip at the beginning of the source clip.
    var trimStartFrame: Int
    /// How many frames to skip at the end of the source clip.
    var trimEndFrame: Int
    /// Cross-fade frames at the clip's start.
    var blendInFrames: Int
    /// Cross-fade frames at the clip's end.
    var blendOutFrames: Int
    /// Per-clip influence (multiplied with track influence).
    var influence: Float

    init(
        id: UUID = UUID(),
        motionClipID: UUID,
        startFrame: Int = 0,
        speed: Float = 1.0,
        trimStartFrame: Int = 0,
        trimEndFrame: Int = 0,
        blendInFrames: Int = 0,
        blendOutFrames: Int = 0,
        influence: Float = 1.0
    ) {
        self.id = id
        self.motionClipID = motionClipID
        self.startFrame = startFrame
        self.speed = speed
        self.trimStartFrame = trimStartFrame
        self.trimEndFrame = trimEndFrame
        self.blendInFrames = blendInFrames
        self.blendOutFrames = blendOutFrames
        self.influence = influence
    }

    /// The effective number of source frames this clip plays (after trim, before speed).
    func effectiveSourceFrames(motionClipFrameCount: Int) -> Int {
        max(0, motionClipFrameCount - trimStartFrame - trimEndFrame)
    }

    /// How many NLA timeline frames this clip occupies, accounting for speed.
    func timelineDuration(motionClipFrameCount: Int) -> Int {
        let sourceFrames = effectiveSourceFrames(motionClipFrameCount: motionClipFrameCount)
        guard speed > 0 else { return sourceFrames }
        return Int(ceil(Float(sourceFrames) / speed))
    }

    /// The last NLA timeline frame this clip occupies (exclusive).
    func endFrame(motionClipFrameCount: Int) -> Int {
        startFrame + timelineDuration(motionClipFrameCount: motionClipFrameCount)
    }
}

/// A single NLA track lane. Tracks stack bottom-to-top; higher sortOrder tracks
/// blend on top of lower ones.
@available(macOS 26.0, *)
struct NLATrack: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var blendMode: NLABlendMode
    var bodyMask: BodyPartMask
    /// Track-level influence weight (0.0-1.0). Multiplied with per-clip influence.
    var influence: Float
    var muted: Bool
    var solo: Bool
    var clips: [NLAClip]
    /// Display order; lower values render at the bottom of the track stack.
    var sortOrder: Int
    /// Color tag for clip rectangles. Computed from source type at creation time.
    var colorTag: NLATrackColorTag

    init(
        id: UUID = UUID(),
        name: String = "Track",
        blendMode: NLABlendMode = .replace,
        bodyMask: BodyPartMask = .everything,
        influence: Float = 1.0,
        muted: Bool = false,
        solo: Bool = false,
        clips: [NLAClip] = [],
        sortOrder: Int = 0,
        colorTag: NLATrackColorTag = .webcam
    ) {
        self.id = id
        self.name = name
        self.blendMode = blendMode
        self.bodyMask = bodyMask
        self.influence = influence
        self.muted = muted
        self.solo = solo
        self.clips = clips
        self.sortOrder = sortOrder
        self.colorTag = colorTag
    }
}

/// Color tags for NLA track clip rectangles, derived from the motion source type.
@available(macOS 26.0, *)
enum NLATrackColorTag: String, Codable, Sendable, CaseIterable {
    case webcam     // orange
    case ai         // blue (HunyuanMotion)
    case imported   // green (BVH)
    case manual     // gray

    var displayName: String {
        switch self {
        case .webcam: "Webcam"
        case .ai: "AI Generated"
        case .imported: "Imported"
        case .manual: "Manual"
        }
    }
}

/// Top-level NLA timeline for a scene. Contains an ordered list of tracks.
@available(macOS 26.0, *)
struct NLATimeline: Codable, Sendable {
    var tracks: [NLATrack]
    var duration: TimeInterval
    var fps: Int

    init(tracks: [NLATrack] = [], duration: TimeInterval = 0, fps: Int = 24) {
        self.tracks = tracks
        self.duration = duration
        self.fps = fps
    }

    /// Total frame count derived from duration and fps.
    var totalFrames: Int {
        max(1, Int(ceil(duration * Double(fps))))
    }

    /// All tracks sorted by sortOrder (bottom-to-top evaluation order).
    var sortedTracks: [NLATrack] {
        tracks.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Add a new track at the top of the stack.
    mutating func addTrack(_ track: NLATrack) {
        var t = track
        t.sortOrder = (tracks.map(\.sortOrder).max() ?? -1) + 1
        tracks.append(t)
    }

    /// Remove a track by ID.
    mutating func removeTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
    }

    /// Find the track index for a given ID.
    func trackIndex(for id: UUID) -> Int? {
        tracks.firstIndex { $0.id == id }
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add NLATimeline, NLATrack, NLAClip, NLABlendMode data models`

---

## Step 3: BlendedPose and NLAEvaluator

**File:** `Packages/Animate/Sources/AnimateUI/Motion/NLAEvaluator.swift`
**Time:** 5 min
**Why:** The core algorithm that walks tracks bottom-to-top and produces blended per-frame poses. This is the computational heart of the NLA system.

```swift
import Foundation
import simd

/// A blended pose output from NLA evaluation. Holds joint rotations as quaternions
/// and blend shape weights as floats, keyed by joint/blend-shape name strings.
@available(macOS 26.0, *)
struct BlendedPose: Sendable {
    /// Joint rotations keyed by joint name (e.g. "leftUpperArm").
    var jointRotations: [String: simd_quatf]
    /// Blend shape weights keyed by morph target name (e.g. "mouthSmileLeft").
    var blendShapeWeights: [String: Float]
    /// Root position offset (hips translation).
    var rootPosition: SIMD3<Float>

    /// A rest pose with identity rotations, zero blend shapes, zero root position.
    static func rest() -> BlendedPose {
        BlendedPose(
            jointRotations: [:],
            blendShapeWeights: [:],
            rootPosition: .zero
        )
    }

    /// Blend another pose sample into this accumulated pose.
    ///
    /// - Parameters:
    ///   - sample: The incoming pose sample from a motion clip.
    ///   - weight: Combined influence (track * clip * blend-in/out curve), 0.0-1.0.
    ///   - mode: How to combine with the existing accumulated pose.
    ///   - mask: Which body parts this blend affects.
    mutating func blend(
        with sample: BlendedPose,
        weight: Float,
        mode: NLABlendMode,
        mask: BodyPartMask
    ) {
        guard weight > 0.001 else { return }

        // Blend joint rotations
        for (jointName, sampleQuat) in sample.jointRotations {
            // Check body mask: if we know which part this joint belongs to,
            // only blend if the mask includes it.
            if let part = BodyPartMask.partForJoint(jointName),
               !mask.contains(part) {
                continue
            }

            let current = jointRotations[jointName] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

            switch mode {
            case .replace:
                // Slerp between current and sample
                jointRotations[jointName] = simd_slerp(current, sampleQuat, weight)

            case .additive:
                // Convert sample to a delta from identity, scale it, then apply
                let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                let delta = simd_slerp(identity, sampleQuat, weight)
                jointRotations[jointName] = simd_mul(current, delta)

            case .override_:
                // Full replacement where mask matches — slerp at full weight
                jointRotations[jointName] = simd_slerp(current, sampleQuat, weight)
            }
        }

        // Blend blend-shape weights (linear interpolation, clamped 0-1)
        for (shapeName, sampleValue) in sample.blendShapeWeights {
            // Blend shapes are always face/mouth region; check mask
            if !mask.contains(.face) && !mask.contains(.mouth) {
                continue
            }

            let current = blendShapeWeights[shapeName] ?? 0.0

            switch mode {
            case .replace:
                blendShapeWeights[shapeName] = clampUnit(current + (sampleValue - current) * weight)

            case .additive:
                blendShapeWeights[shapeName] = clampUnit(current + sampleValue * weight)

            case .override_:
                blendShapeWeights[shapeName] = clampUnit(current + (sampleValue - current) * weight)
            }
        }

        // Blend root position
        if mask.contains(.hips) {
            switch mode {
            case .replace:
                rootPosition = rootPosition + (sample.rootPosition - rootPosition) * weight

            case .additive:
                rootPosition = rootPosition + sample.rootPosition * weight

            case .override_:
                rootPosition = rootPosition + (sample.rootPosition - rootPosition) * weight
            }
        }
    }

    private func clampUnit(_ v: Float) -> Float {
        max(0, min(1, v))
    }
}

/// Evaluates an NLATimeline at a given frame by walking tracks bottom-to-top,
/// sampling the active clip on each track, and blending into an accumulated pose.
///
/// Follows the same static-method pattern as `AnimationEngine`.
@available(macOS 26.0, *)
struct NLAEvaluator: Sendable {

    /// A closure type that resolves a MotionClip UUID to its data.
    /// The caller provides this — typically from the motion clip library cache on AnimateStore.
    typealias MotionClipResolver = @Sendable (UUID) -> MotionClipData?

    /// Minimal protocol-free struct representing the data NLAEvaluator needs from a MotionClip.
    struct MotionClipData: Sendable {
        var frameCount: Int
        /// Sample the clip at a given frame index, returning joint rotations and blend shapes.
        var sample: @Sendable (Int) -> BlendedPose
    }

    // MARK: - Evaluate

    /// Evaluate the full NLA timeline at a given frame.
    ///
    /// - Parameters:
    ///   - timeline: The NLA timeline to evaluate.
    ///   - frame: The current frame on the NLA timeline.
    ///   - resolveClip: Closure to look up MotionClipData by UUID.
    /// - Returns: The blended pose for the frame, or rest pose if no tracks are active.
    static func evaluate(
        timeline: NLATimeline,
        frame: Int,
        resolveClip: MotionClipResolver
    ) -> BlendedPose {
        var accumulated = BlendedPose.rest()
        let activeTracks = timeline.sortedTracks
        let hasSolo = activeTracks.contains { $0.solo }

        for track in activeTracks {
            if track.muted { continue }
            if hasSolo && !track.solo { continue }

            guard let (clip, clipData) = activeClipAndData(
                in: track, at: frame, resolveClip: resolveClip
            ) else { continue }

            let effectiveFrame = clipLocalFrame(clip: clip, clipData: clipData, timelineFrame: frame)
            let sample = clipData.sample(effectiveFrame)
            let weight = clipWeight(clip: clip, clipData: clipData, timelineFrame: frame) * track.influence

            accumulated.blend(
                with: sample,
                weight: weight,
                mode: track.blendMode,
                mask: track.bodyMask
            )
        }

        return accumulated
    }

    // MARK: - Clip Lookup

    /// Find the active clip in a track at a given timeline frame, plus its resolved data.
    private static func activeClipAndData(
        in track: NLATrack,
        at frame: Int,
        resolveClip: MotionClipResolver
    ) -> (NLAClip, MotionClipData)? {
        for clip in track.clips {
            guard let clipData = resolveClip(clip.motionClipID) else { continue }
            let endFrame = clip.endFrame(motionClipFrameCount: clipData.frameCount)
            if frame >= clip.startFrame && frame < endFrame {
                return (clip, clipData)
            }
        }
        return nil
    }

    // MARK: - Frame Mapping

    /// Map an NLA timeline frame to a local frame index within the source motion clip.
    /// Accounts for trim and speed.
    private static func clipLocalFrame(
        clip: NLAClip,
        clipData: MotionClipData,
        timelineFrame: Int
    ) -> Int {
        let offsetFromStart = timelineFrame - clip.startFrame
        let speedAdjusted = Float(offsetFromStart) * clip.speed
        let sourceFrame = clip.trimStartFrame + Int(speedAdjusted)
        let maxFrame = clipData.frameCount - 1 - clip.trimEndFrame
        return max(clip.trimStartFrame, min(sourceFrame, maxFrame))
    }

    // MARK: - Blend Weight

    /// Compute the effective blend weight for a clip at a timeline frame,
    /// including blend-in/blend-out cross-fade ramps and per-clip influence.
    private static func clipWeight(
        clip: NLAClip,
        clipData: MotionClipData,
        timelineFrame: Int
    ) -> Float {
        let offsetFromStart = timelineFrame - clip.startFrame
        let clipTimelineDuration = clip.timelineDuration(motionClipFrameCount: clipData.frameCount)
        let offsetFromEnd = clipTimelineDuration - offsetFromStart

        var weight: Float = clip.influence

        // Blend-in ramp
        if clip.blendInFrames > 0 && offsetFromStart < clip.blendInFrames {
            weight *= Float(offsetFromStart) / Float(clip.blendInFrames)
        }

        // Blend-out ramp
        if clip.blendOutFrames > 0 && offsetFromEnd < clip.blendOutFrames {
            weight *= Float(offsetFromEnd) / Float(clip.blendOutFrames)
        }

        return max(0, min(1, weight))
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add BlendedPose model and NLAEvaluator with track blending algorithm`

---

## Step 4: NLA Persistence (save/load per scene)

**File:** `Packages/Animate/Sources/AnimateUI/Motion/NLATimelinePersistence.swift`
**Time:** 3 min
**Why:** NLA timelines must round-trip to disk. Follows the existing pattern where AnimateStore reads/writes JSON files inside `<project>.owp/Animate/`.

```swift
import Foundation

/// Handles reading and writing NLATimeline JSON files.
/// Storage path: `<project>.owp/Animate/motion-timeline-<sceneID>.json`
@available(macOS 26.0, *)
struct NLATimelinePersistence: Sendable {

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private static let decoder = JSONDecoder()

    /// Build the file URL for a scene's NLA timeline.
    static func fileURL(animateDir: URL, sceneID: UUID) -> URL {
        animateDir.appendingPathComponent("motion-timeline-\(sceneID.uuidString).json")
    }

    /// Load an NLA timeline from disk. Returns nil if the file does not exist.
    static func load(animateDir: URL, sceneID: UUID) throws -> NLATimeline? {
        let url = fileURL(animateDir: animateDir, sceneID: sceneID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(NLATimeline.self, from: data)
    }

    /// Save an NLA timeline to disk. Creates the file if it does not exist.
    static func save(timeline: NLATimeline, animateDir: URL, sceneID: UUID) throws {
        let url = fileURL(animateDir: animateDir, sceneID: sceneID)
        let data = try encoder.encode(timeline)
        try data.write(to: url, options: .atomic)
    }

    /// Delete the NLA timeline file for a scene.
    static func delete(animateDir: URL, sceneID: UUID) throws {
        let url = fileURL(animateDir: animateDir, sceneID: sceneID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add NLATimelinePersistence for per-scene timeline save/load`

---

## Step 5: AnimateStore NLA Integration

**File:** `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` (edit existing)
**Time:** 4 min
**Why:** AnimateStore is the central state object. It needs to own the NLATimeline for the active scene, load/save it alongside the existing scene data, and hook the evaluator into `advanceFrame()` so NLA output drives the CADisplayLink playback loop.

### 5a. Add NLA state properties

Add after the existing `// MARK: - Timeline` section (around line 121):

```swift
    // MARK: - NLA Motion Timeline

    /// The NLA timeline for the currently selected scene.
    var nlaTimeline: NLATimeline?
    /// The most recently evaluated blended pose from NLA evaluation.
    var nlaBlendedPose: BlendedPose?
    /// Cache of loaded motion clip data, keyed by MotionClip UUID.
    @ObservationIgnored private var motionClipDataCache: [UUID: NLAEvaluator.MotionClipData] = [:]
```

### 5b. Add NLA evaluation call inside advanceFrame()

Inside the existing `advanceFrame()` method, after `currentFrame += framesToAdvance` and the loop-back check (around line 425), add:

```swift
            // Evaluate NLA timeline at the new frame
            evaluateNLAAtCurrentFrame()
```

### 5c. Add NLA helper methods

Add a new MARK section after the existing `advanceFrame()` / playback methods:

```swift
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
```

### 5d. Hook NLA load into scene selection

Inside `syncSelectedSceneTimeline()` (called from `selectedSceneID.didSet`), add at the end:

```swift
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
```

### 5e. Hook NLA save into save()

Inside the existing `save()` method, after the scene data is written but before the method returns, add:

```swift
            // Save NLA timelines
            for scene in scenes {
                if let timeline = (scene.id == selectedSceneID ? nlaTimeline : nil) {
                    try NLATimelinePersistence.save(
                        timeline: timeline, animateDir: animateDir, sceneID: scene.id
                    )
                }
            }
```

### 5f. Add convenience save for NLA timeline

```swift
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
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): integrate NLATimeline into AnimateStore — evaluation in playback loop, load/save per scene`

---

## Step 6: Add "Motion" Dock Tab

**File:** `Packages/Animate/Sources/AnimateUI/Models/AnimateWorkspaceModels.swift` (edit existing)
**Time:** 2 min
**Why:** The NLA timeline view lives in a new dock tab. Follow the existing pattern of `AnimateWorkspaceDockTab`.

Add `case motion` to the enum, before or after `graph`:

```swift
    case motion
```

Add to the `title` computed property:

```swift
        case .motion: "Motion"
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add Motion dock tab to AnimateWorkspaceDockTab`

---

## Step 7: NLATrackHeaderView (track lane header)

**File:** `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATrackHeaderView.swift`
**Time:** 4 min
**Why:** Each track lane has a header on the left with the track name, mute/solo buttons, blend mode badge, and influence. This is a reusable component used by the timeline view.

```swift
import SwiftUI

/// Header for a single NLA track lane. Sits to the left of the clip area.
/// Shows: track name (editable), mute/solo toggles, blend mode badge, influence.
@available(macOS 26.0, *)
struct NLATrackHeaderView: View {
    @Binding var track: NLATrack
    var isSelected: Bool
    var onDelete: () -> Void

    @State private var isEditingName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Track name
                if isEditingName {
                    TextField("Track Name", text: $track.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .onSubmit { isEditingName = false }
                } else {
                    Text(track.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { isEditingName = true }
                }

                Spacer()

                // Blend mode badge
                Text(track.blendMode.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(blendModeBadgeColor.opacity(0.25))
                    )
                    .foregroundStyle(blendModeBadgeColor)
            }

            HStack(spacing: 8) {
                // Mute button
                Button {
                    track.muted.toggle()
                } label: {
                    Text("M")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(track.muted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(track.muted ? "Unmute track" : "Mute track")

                // Solo button
                Button {
                    track.solo.toggle()
                } label: {
                    Text("S")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(track.solo ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(track.solo ? "Unsolo track" : "Solo track")

                // Influence slider (compact)
                Slider(value: $track.influence, in: 0...1)
                    .controlSize(.mini)
                    .frame(maxWidth: 60)

                Text("\(Int(track.influence * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                Spacer()

                // Delete
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete track")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 200, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private var blendModeBadgeColor: Color {
        switch track.blendMode {
        case .replace: .blue
        case .additive: .green
        case .override_: .orange
        }
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add NLATrackHeaderView with mute/solo/influence controls`

---

## Step 8: NLAClipRectangleView (clip visualization)

**File:** `Packages/Animate/Sources/AnimateUI/Views/Motion/NLAClipRectangleView.swift`
**Time:** 3 min
**Why:** Each clip on the timeline is drawn as a colored rectangle. This view handles rendering, drag-to-move, and edge-drag-to-trim.

```swift
import SwiftUI

/// A single clip rectangle on an NLA track lane.
/// Color is determined by the track's colorTag. Shows the motion clip name inside.
@available(macOS 26.0, *)
struct NLAClipRectangleView: View {
    let clip: NLAClip
    let clipName: String
    let colorTag: NLATrackColorTag
    let pixelsPerFrame: CGFloat
    let totalTimelineFrames: Int
    let motionClipFrameCount: Int

    var onMove: ((_ clipID: UUID, _ newStartFrame: Int) -> Void)?
    var onTrimStart: ((_ clipID: UUID, _ newTrimStart: Int) -> Void)?
    var onTrimEnd: ((_ clipID: UUID, _ newTrimEnd: Int) -> Void)?

    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0

    private var clipDuration: Int {
        clip.timelineDuration(motionClipFrameCount: motionClipFrameCount)
    }

    private var clipWidth: CGFloat {
        CGFloat(clipDuration) * pixelsPerFrame
    }

    private var clipXOffset: CGFloat {
        CGFloat(clip.startFrame) * pixelsPerFrame
    }

    var body: some View {
        ZStack {
            // Clip body
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor.opacity(isDragging ? 0.7 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(fillColor.opacity(0.8), lineWidth: 1)
                )

            // Blend-in/out fade indicators
            HStack(spacing: 0) {
                if clip.blendInFrames > 0 {
                    LinearGradient(
                        colors: [.clear, fillColor.opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: CGFloat(clip.blendInFrames) * pixelsPerFrame)
                }
                Spacer(minLength: 0)
                if clip.blendOutFrames > 0 {
                    LinearGradient(
                        colors: [fillColor.opacity(0.3), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: CGFloat(clip.blendOutFrames) * pixelsPerFrame)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Label
            Text(clipName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .frame(width: max(clipWidth, 4), height: 32)
        .offset(x: clipXOffset + dragOffset)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    isDragging = false
                    let frameDelta = Int(round(value.translation.width / pixelsPerFrame))
                    let newStart = max(0, min(clip.startFrame + frameDelta, totalTimelineFrames - clipDuration))
                    dragOffset = 0
                    onMove?(clip.id, newStart)
                }
        )
        .contextMenu {
            Button("Split at Playhead") { /* implemented in parent */ }
            Button("Duplicate") { /* implemented in parent */ }
            Divider()
            Button("Delete", role: .destructive) { /* implemented in parent */ }
        }
    }

    private var fillColor: Color {
        switch colorTag {
        case .webcam:   .orange
        case .ai:       .blue
        case .imported: .green
        case .manual:   .gray
        }
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add NLAClipRectangleView with drag-to-move and color tags`

---

## Step 9: NLATimeRulerView (time ruler)

**File:** `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATimeRulerView.swift`
**Time:** 3 min
**Why:** The horizontal ruler at the top of the NLA timeline showing frame numbers and time markers. Also draws the playhead.

```swift
import SwiftUI

/// Horizontal time ruler for the NLA timeline. Shows frame/time markers
/// and the current playhead position as a vertical red line.
@available(macOS 26.0, *)
struct NLATimeRulerView: View {
    let totalFrames: Int
    let fps: Int
    let currentFrame: Int
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat

    var onSeek: ((_ frame: Int) -> Void)?

    private var rulerWidth: CGFloat {
        CGFloat(totalFrames) * pixelsPerFrame
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))

            // Frame markers
            Canvas { context, size in
                let visibleStartFrame = max(0, Int(-scrollOffset / pixelsPerFrame) - 1)
                let visibleEndFrame = min(totalFrames, visibleStartFrame + Int(size.width / pixelsPerFrame) + 2)

                // Determine tick spacing based on zoom level
                let majorInterval = majorTickInterval
                let minorInterval = max(1, majorInterval / 5)

                for frame in stride(from: (visibleStartFrame / minorInterval) * minorInterval,
                                     through: visibleEndFrame,
                                     by: minorInterval) {
                    let x = CGFloat(frame) * pixelsPerFrame + scrollOffset
                    guard x >= 0 && x <= size.width else { continue }

                    let isMajor = frame % majorInterval == 0
                    let tickHeight: CGFloat = isMajor ? 12 : 6

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                    context.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.6 : 0.3)), lineWidth: 0.5)

                    if isMajor {
                        let label = frameLabel(frame)
                        let text = Text(label).font(.system(size: 9, design: .monospaced))
                        context.draw(text, at: CGPoint(x: x, y: 4), anchor: .top)
                    }
                }
            }
            .frame(height: 24)

            // Playhead
            let playheadX = CGFloat(currentFrame) * pixelsPerFrame + scrollOffset
            if playheadX >= 0 {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: 24)
                    .offset(x: playheadX)

                // Playhead triangle
                Path { path in
                    path.move(to: CGPoint(x: playheadX - 5, y: 0))
                    path.addLine(to: CGPoint(x: playheadX + 5, y: 0))
                    path.addLine(to: CGPoint(x: playheadX, y: 7))
                    path.closeSubpath()
                }
                .fill(Color.red)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { location in
            let frame = Int((location.x - scrollOffset) / pixelsPerFrame)
            let clamped = max(0, min(frame, totalFrames - 1))
            onSeek?(clamped)
        }
    }

    private var majorTickInterval: Int {
        // Adaptive: at ~4px/frame show every 24 frames (1sec at 24fps),
        // at wider zoom show fewer, at narrow zoom show more.
        let approxPixelsPerMajor: CGFloat = 80
        let rawInterval = Int(approxPixelsPerMajor / max(pixelsPerFrame, 0.1))
        // Snap to nice intervals
        let niceIntervals = [1, 2, 5, 10, 24, 30, 48, 60, 120, 240, 300, 600]
        return niceIntervals.first { $0 >= rawInterval } ?? rawInterval
    }

    private func frameLabel(_ frame: Int) -> String {
        guard fps > 0 else { return "\(frame)" }
        let seconds = frame / fps
        let remainingFrames = frame % fps
        if seconds >= 60 {
            let min = seconds / 60
            let sec = seconds % 60
            return String(format: "%d:%02d:%02d", min, sec, remainingFrames)
        }
        return String(format: "%d:%02d", seconds, remainingFrames)
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add NLATimeRulerView with adaptive tick spacing and playhead`

---

## Step 10: NLATrackInspectorView (track inspector panel)

**File:** `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATrackInspectorView.swift`
**Time:** 4 min
**Why:** When a track is selected, the inspector shows detailed controls: blend mode picker, body mask checkboxes, influence slider, mute/solo, and clip list.

```swift
import SwiftUI

/// Inspector panel for a selected NLA track. Shows blend mode, body mask,
/// influence, and per-clip settings.
@available(macOS 26.0, *)
struct NLATrackInspectorView: View {
    @Binding var track: NLATrack
    let clipNames: [UUID: String]  // motionClipID -> display name

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Track name
                Section {
                    TextField("Track Name", text: $track.name)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("NAME").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Blend Mode
                Section {
                    Picker("Blend Mode", selection: $track.blendMode) {
                        ForEach(NLABlendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("BLEND MODE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Influence
                Section {
                    HStack {
                        Slider(value: $track.influence, in: 0...1, step: 0.01)
                        Text("\(Int(track.influence * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                    }
                } header: {
                    Text("INFLUENCE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Mute / Solo
                Section {
                    HStack(spacing: 16) {
                        Toggle("Muted", isOn: $track.muted)
                        Toggle("Solo", isOn: $track.solo)
                    }
                    .toggleStyle(.checkbox)
                } header: {
                    Text("STATE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Body Mask
                Section {
                    bodyMaskSection
                } header: {
                    Text("BODY MASK").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Color Tag
                Section {
                    Picker("Source Type", selection: $track.colorTag) {
                        ForEach(NLATrackColorTag.allCases, id: \.self) { tag in
                            Text(tag.displayName).tag(tag)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("COLOR TAG").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                if !track.clips.isEmpty {
                    Divider()

                    // Clips list
                    Section {
                        ForEach(Array(track.clips.enumerated()), id: \.element.id) { index, clip in
                            clipRow(index: index, clip: clip)
                        }
                    } header: {
                        Text("CLIPS (\(track.clips.count))").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var bodyMaskSection: some View {
        // Preset picker
        HStack {
            Text("Preset:")
                .font(.system(size: 11))
            Picker("", selection: Binding(
                get: {
                    BodyPartMask.presets.first { $0.mask == track.bodyMask }?.label ?? "Custom"
                },
                set: { newLabel in
                    if let preset = BodyPartMask.presets.first(where: { $0.label == newLabel }) {
                        track.bodyMask = preset.mask
                    }
                }
            )) {
                ForEach(BodyPartMask.presets, id: \.label) { preset in
                    Text(preset.label).tag(preset.label)
                }
                Text("Custom").tag("Custom")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)
        }

        // Individual checkboxes in a 2-column grid
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 4),
            GridItem(.flexible(), spacing: 4),
        ], alignment: .leading, spacing: 4) {
            ForEach(BodyPartMask.allParts, id: \.label) { part in
                Toggle(part.label, isOn: Binding(
                    get: { track.bodyMask.contains(part.mask) },
                    set: { isOn in
                        if isOn {
                            track.bodyMask.insert(part.mask)
                        } else {
                            track.bodyMask.remove(part.mask)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
            }
        }
    }

    @ViewBuilder
    private func clipRow(index: Int, clip: NLAClip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(clipNames[clip.motionClipID] ?? "Unknown Clip")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("Frame \(clip.startFrame)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("Speed \(String(format: "%.1fx", clip.speed))", systemImage: "speedometer")
                Label("In \(clip.blendInFrames)f", systemImage: "arrow.right")
                Label("Out \(clip.blendOutFrames)f", systemImage: "arrow.left")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add NLATrackInspectorView with blend mode, body mask, and clip settings`

---

## Step 11: NLATimelineView (main timeline UI)

**File:** `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATimelineView.swift`
**Time:** 5 min
**Why:** The main NLA timeline view that assembles the ruler, track headers, clip lanes, and playhead into a scrollable, interactive timeline. This is the primary UI the user interacts with.

```swift
import SwiftUI

/// Main NLA timeline view. Lives in the Motion dock tab.
/// Vertical stack of track lanes with horizontal scrolling time ruler.
@available(macOS 26.0, *)
struct NLATimelineView: View {
    @Bindable var store: AnimateStore
    @State private var selectedTrackID: UUID?
    @State private var pixelsPerFrame: CGFloat = 4.0
    @State private var scrollOffset: CGFloat = 0
    @State private var showTrackInspector = false

    /// Map of motion clip UUID to display name, provided by parent.
    var clipNames: [UUID: String] = [:]

    private var timeline: NLATimeline {
        store.nlaTimeline ?? NLATimeline()
    }

    private var totalFrames: Int {
        max(timeline.totalFrames, store.totalFrames, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            if timeline.tracks.isEmpty {
                emptyState
            } else {
                HSplitView {
                    // Timeline area
                    timelineArea
                        .frame(minWidth: 300)

                    // Track inspector (when a track is selected)
                    if showTrackInspector, let trackID = selectedTrackID,
                       let trackIndex = timeline.trackIndex(for: trackID) {
                        trackInspector(trackIndex: trackIndex)
                            .frame(width: 260)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            // Add track button
            Menu {
                Button("Webcam Track") { addTrack(colorTag: .webcam) }
                Button("AI Motion Track") { addTrack(colorTag: .ai) }
                Button("Imported BVH Track") { addTrack(colorTag: .imported) }
                Button("Manual Track") { addTrack(colorTag: .manual) }
            } label: {
                Label("Add Track", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 16)

            // Zoom controls
            HStack(spacing: 4) {
                Button {
                    pixelsPerFrame = max(1, pixelsPerFrame / 1.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)

                Text("\(Int(pixelsPerFrame))px/f")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 40)

                Button {
                    pixelsPerFrame = min(20, pixelsPerFrame * 1.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            // Track inspector toggle
            Toggle(isOn: $showTrackInspector) {
                Label("Inspector", systemImage: "sidebar.right")
                    .font(.system(size: 11))
            }
            .toggleStyle(.button)
            .disabled(selectedTrackID == nil)

            Spacer()

            // Track count
            Text("\(timeline.tracks.count) tracks")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Timeline Area

    @ViewBuilder
    private var timelineArea: some View {
        VStack(spacing: 0) {
            // Time ruler
            NLATimeRulerView(
                totalFrames: totalFrames,
                fps: timeline.fps > 0 ? timeline.fps : store.fps,
                currentFrame: store.currentFrame,
                pixelsPerFrame: pixelsPerFrame,
                scrollOffset: scrollOffset,
                onSeek: { frame in
                    store.currentFrame = frame
                    store.evaluateNLAAtCurrentFrame()
                }
            )

            Divider()

            // Track lanes (scrollable)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Track lane backgrounds + clip rectangles
                    VStack(spacing: 0) {
                        ForEach(timeline.sortedTracks) { track in
                            trackLane(track: track)
                        }
                    }

                    // Playhead line (spans full height)
                    let playheadX = CGFloat(store.currentFrame) * pixelsPerFrame
                    Rectangle()
                        .fill(Color.red.opacity(0.6))
                        .frame(width: 1)
                        .offset(x: 200 + playheadX)  // 200 = header width
                }
            }
            .onAppear {
                scrollOffset = 0
            }
        }
    }

    // MARK: - Track Lane

    @ViewBuilder
    private func trackLane(track: NLATrack) -> some View {
        let isSelected = selectedTrackID == track.id

        HStack(spacing: 0) {
            // Track header
            NLATrackHeaderView(
                track: binding(for: track.id),
                isSelected: isSelected,
                onDelete: { deleteTrack(id: track.id) }
            )
            .onTapGesture {
                selectedTrackID = track.id
            }

            // Clip area
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.04)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.3))

                // Clips
                ForEach(track.clips) { clip in
                    NLAClipRectangleView(
                        clip: clip,
                        clipName: clipNames[clip.motionClipID] ?? "Clip",
                        colorTag: track.colorTag,
                        pixelsPerFrame: pixelsPerFrame,
                        totalTimelineFrames: totalFrames,
                        motionClipFrameCount: motionClipFrameCount(for: clip.motionClipID),
                        onMove: { clipID, newStart in
                            moveClip(trackID: track.id, clipID: clipID, newStartFrame: newStart)
                        }
                    )
                }
            }
            .frame(width: CGFloat(totalFrames) * pixelsPerFrame, height: 40)
        }
        .frame(height: 40)
        .background(
            Rectangle()
                .stroke(Color.separator.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Track Inspector

    @ViewBuilder
    private func trackInspector(trackIndex: Int) -> some View {
        NLATrackInspectorView(
            track: Binding(
                get: { store.nlaTimeline?.tracks[trackIndex] ?? NLATrack() },
                set: { newTrack in
                    store.nlaTimeline?.tracks[trackIndex] = newTrack
                    store.evaluateNLAAtCurrentFrame()
                }
            ),
            clipNames: clipNames
        )
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Motion Tracks")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Add a track and drag motion clips from the library to start building your animation.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Add Track") { addTrack(colorTag: .webcam) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func addTrack(colorTag: NLATrackColorTag) {
        if store.nlaTimeline == nil {
            store.nlaTimeline = NLATimeline(fps: store.fps)
        }
        let trackNumber = (store.nlaTimeline?.tracks.count ?? 0) + 1
        let track = NLATrack(
            name: "\(colorTag.displayName) \(trackNumber)",
            colorTag: colorTag
        )
        store.nlaTimeline?.addTrack(track)
        selectedTrackID = track.id
        store.saveNLATimeline()
    }

    private func deleteTrack(id: UUID) {
        store.nlaTimeline?.removeTrack(id: id)
        if selectedTrackID == id {
            selectedTrackID = nil
        }
        store.evaluateNLAAtCurrentFrame()
        store.saveNLATimeline()
    }

    private func moveClip(trackID: UUID, clipID: UUID, newStartFrame: Int) {
        guard let trackIndex = store.nlaTimeline?.trackIndex(for: trackID),
              let clipIndex = store.nlaTimeline?.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else { return }
        store.nlaTimeline?.tracks[trackIndex].clips[clipIndex].startFrame = newStartFrame
        store.evaluateNLAAtCurrentFrame()
        store.saveNLATimeline()
    }

    // MARK: - Helpers

    private func binding(for trackID: UUID) -> Binding<NLATrack> {
        Binding(
            get: {
                store.nlaTimeline?.tracks.first { $0.id == trackID } ?? NLATrack()
            },
            set: { newTrack in
                if let index = store.nlaTimeline?.trackIndex(for: trackID) {
                    store.nlaTimeline?.tracks[index] = newTrack
                    store.evaluateNLAAtCurrentFrame()
                }
            }
        )
    }

    private func motionClipFrameCount(for clipID: UUID) -> Int {
        // TODO: resolve from MotionClip library via AnimateStore
        // For now return a default; Phase 3's MotionClip has frameCount.
        240
    }
}
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): add NLATimelineView with track lanes, clip rectangles, and playhead`

---

## Step 12: Wire NLATimelineView into the Motion Dock Tab

**File:** `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift` (edit existing)
**Time:** 3 min
**Why:** The NLA timeline must appear when the user selects the Motion dock tab.

### 12a. Find the dock tab switch/case

Search for where dock tabs are routed to views (likely a `switch workspaceState.selectedDockTab` or a `Group`/`TabView` that dispatches to different views). Add the `.motion` case:

```swift
            case .motion:
                NLATimelineView(store: store)
```

If the dock tab routing is in a helper method, the exact insertion point depends on the existing pattern. Look for the switch that handles `.plan`, `.review`, `.assets`, etc. and add `.motion` alongside them.

### 12b. Add Motion tab to the dock tab bar

If the dock tab bar iterates over `AnimateWorkspaceDockTab.allCases`, the `.motion` case will automatically appear once it's added to the enum. If tabs are listed explicitly, add:

```swift
            dockTabButton(.motion, icon: "waveform.path.ecg")
```

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): wire NLATimelineView into Motion dock tab`

---

## Step 13: Animate3DSceneAdapter NLA Output Bridge

**File:** `Packages/Animate/Sources/AnimateUI/Animate3DSceneAdapter.swift` (edit existing)
**Time:** 4 min
**Why:** The 3D renderer reads `Animate3DFrameSnapshot` to position characters. When an NLA blended pose is available, the frame snapshot must include NLA-driven joint rotations and blend shapes so the 3D model reflects the mixed motion.

### 13a. Add NLA pose to Animate3DFrameSnapshot

Find the `Animate3DFrameSnapshot` struct (either in this file or a related models file) and add:

```swift
    /// NLA-blended joint rotations, if NLA evaluation produced a pose this frame.
    var nlaJointRotations: [String: simd_quatf]?
    /// NLA-blended blend shape weights.
    var nlaBlendShapeWeights: [String: Float]?
    /// NLA root position offset.
    var nlaRootPosition: SIMD3<Float>?
```

### 13b. Populate NLA data in frameSnapshot()

Inside the `frameSnapshot(for:store:rawFrame:playbackStyle:)` method, after the snapshot is built but before it's returned, add:

```swift
        // Overlay NLA blended pose if available
        if let nlaPose = store.nlaBlendedPose {
            snapshot.nlaJointRotations = nlaPose.jointRotations.isEmpty ? nil : nlaPose.jointRotations
            snapshot.nlaBlendShapeWeights = nlaPose.blendShapeWeights.isEmpty ? nil : nlaPose.blendShapeWeights
            snapshot.nlaRootPosition = nlaPose.rootPosition == .zero ? nil : nlaPose.rootPosition
        }
```

This requires changing `var snapshot` from `let` to `var` if it isn't already mutable.

**Build verify:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

**Commit:** `feat(mocap): bridge NLA blended pose into Animate3DFrameSnapshot for 3D rendering`

---

## Step 14: Build, Deploy, Verify

**Time:** 3 min
**Why:** Final verification build and deploy to `!Applications`.

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

If the build succeeds, deploy:

```bash
cp -R "/Volumes/Storage VIII/Programming/Amira Writer/build/Build/Products/Release/Opera.app" "/Volumes/Storage VIII/Programming/!Applications/"
```

**Commit:** `feat(mocap): Phase 4 NLA timeline system complete`

---

## File Summary

| # | File | Type | Purpose |
|---|------|------|---------|
| 1 | `Packages/Animate/Sources/AnimateUI/Motion/BodyPartMask.swift` | NEW | OptionSet for per-body-part joint masking |
| 2 | `Packages/Animate/Sources/AnimateUI/Motion/NLATimeline.swift` | NEW | NLATimeline, NLATrack, NLAClip, NLABlendMode, NLATrackColorTag |
| 3 | `Packages/Animate/Sources/AnimateUI/Motion/NLAEvaluator.swift` | NEW | BlendedPose, NLAEvaluator — per-frame blended pose computation |
| 4 | `Packages/Animate/Sources/AnimateUI/Motion/NLATimelinePersistence.swift` | NEW | JSON save/load for NLATimeline per scene |
| 5 | `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` | EDIT | NLA state, evaluation hook in advanceFrame(), load/save |
| 6 | `Packages/Animate/Sources/AnimateUI/Models/AnimateWorkspaceModels.swift` | EDIT | Add `.motion` dock tab |
| 7 | `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATrackHeaderView.swift` | NEW | Track header with mute/solo/influence |
| 8 | `Packages/Animate/Sources/AnimateUI/Views/Motion/NLAClipRectangleView.swift` | NEW | Clip rectangle with drag and color coding |
| 9 | `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATimeRulerView.swift` | NEW | Time ruler with adaptive ticks and playhead |
| 10 | `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATrackInspectorView.swift` | NEW | Track inspector with body mask, blend mode, clip list |
| 11 | `Packages/Animate/Sources/AnimateUI/Views/Motion/NLATimelineView.swift` | NEW | Main NLA timeline composition view |
| 12 | `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift` | EDIT | Route `.motion` dock tab to NLATimelineView |
| 13 | `Packages/Animate/Sources/AnimateUI/Animate3DSceneAdapter.swift` | EDIT | Bridge NLA pose into 3D frame snapshot |

## Dependency Order

```
Step 1 (BodyPartMask) ─────┐
                            ├── Step 3 (NLAEvaluator + BlendedPose)
Step 2 (NLA data models) ──┘       │
                                   │
Step 4 (Persistence) ──────────────┤
                                   │
Step 5 (AnimateStore integration) ─┤
                                   │
Step 6 (Dock tab enum) ────────────┤
                                   │
Step 7 (TrackHeaderView) ──┐       │
Step 8 (ClipRectangleView) ├── Step 11 (NLATimelineView)
Step 9 (TimeRulerView) ────┘       │
                                   │
Step 10 (TrackInspectorView) ──────┤
                                   │
Step 12 (Wire dock tab) ───────────┤
Step 13 (3D adapter bridge) ───────┘
                                   │
Step 14 (Build + Deploy) ──────────┘
```

## Architecture Notes

- **Evaluation order:** Tracks evaluate bottom-to-top (ascending `sortOrder`). The first track blends from rest pose; subsequent tracks layer on top.
- **Solo logic:** If any track has `solo = true`, only solo tracks are evaluated. Muted tracks are always skipped.
- **Quaternion blending:** Uses `simd_slerp` for smooth rotation interpolation. Additive mode applies a scaled delta quaternion via multiplication.
- **Blend shapes:** Linear interpolation clamped to 0-1. Additive mode adds the incoming value scaled by weight.
- **Thread safety:** All NLA types are `Sendable`. The evaluator is a pure static function. AnimateStore access is `@MainActor`.
- **Persistence:** One JSON file per scene (`motion-timeline-<sceneID>.json`), saved alongside existing scene data in `Animate/`.
- **The NLA system does NOT replace the existing keyframe timeline.** It's a parallel system specifically for motion capture data. The existing `TimelineTrack`/`AnimationEngine` system continues to handle 2D character transforms, expressions, visibility, etc.
