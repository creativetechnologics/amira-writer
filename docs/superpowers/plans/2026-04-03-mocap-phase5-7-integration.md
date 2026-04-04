# Motion Capture Phases 5-7: HunyuanMotion, Import/Export, Audio Lip Sync

**Date:** 2026-04-03
**Project:** Amira Writer — Animate Package
**Base path:** `Packages/Animate/Sources/AnimateUI/`
**Availability:** `@available(macOS 26.0, *)`
**Concurrency:** Swift 6 strict concurrency — all UI-bound types `@MainActor`, data types `Sendable`

---

## Prerequisites (from Phases 1-4, assumed complete)

| File | Purpose |
|------|---------|
| `Capture/CaptureSession.swift` | AVCaptureSession webcam pipeline |
| `Capture/UnifiedPoseFrame.swift` | Pose data model |
| `Capture/VisionBodyTracker.swift` | Apple Vision 3D body pose |
| `Capture/VisionFaceTracker.swift` | Vision-based face tracking |
| `Capture/TemporalFilter.swift` | OneEuro filter |
| `Capture/CapturePreviewView.swift` | Webcam preview UI |
| `Motion/MotionClip.swift` | Serializable motion clip |
| `Motion/MotionRecorder.swift` | Records captures to clips |
| `Motion/MotionRetargeter.swift` | IK-based retargeting |
| `Motion/BVHParser.swift` | BVH import |
| `NLA/NLATimeline.swift` | Timeline data model |
| `NLA/NLAEvaluator.swift` | Per-frame blended pose |
| `NLA/BodyPartMask.swift` | Body region masks |
| `NLA/NLATimelineView.swift` | Timeline UI |

### Key existing files referenced in this plan

| File | Role |
|------|------|
| `Services/HunyuanMotionService.swift` | Gradio API client — `generate()`, `generateAndDownload()` returning FBX URL |
| `Services/FBXMotionClipLoader.swift` | Loads FBX via SCNScene, samples at 30 fps, exposes `MotionFrame` with `jointRotations: [String: simd_quatf]`. Has `jointNameMapping` (SMPL-H <-> Mixamo/SceneKit) and `buildRetargetMap()` |
| `Models/VisemeBlendEngine.swift` | Co-articulation smoothing. `MouthSnapshot` with jawOpen/mouthWidth/mouthHeight/pucker/smileBlend. `blendedState(at:keyframes:)` |
| `Engine/CharacterMouthEngine.swift` | `state(for:blocking:frame:liveCue:baseFPS:profile:)` with `liveCue` override path |
| `Services/LipSyncEngine.swift` | `VisemeKeyframe`, `phonemeToViseme()`, `syllableToViseme()`, `generateFromPhonemes()`, `rhubarbShapeToViseme()` |
| `AnimateStore.swift` | `@Observable @MainActor` central store |

---

# Phase 5: HunyuanMotion -> MotionClip (1 week)

## Step 5.1 — Add MotionClip source enum case for HunyuanMotion (2 min)

**File:** `Motion/MotionClip.swift`

Add a new case to the `MotionClipSource` enum (assumed from Phase 2):

```swift
// In MotionClipSource enum, add:
case hunyuanMotion(prompt: String)
```

Ensure the `Codable` conformance handles the associated value. The enum should already have cases like `.webcamCapture` and `.bvhImport`.

**Build verify:** `xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"`

---

## Step 5.2 — FBXMotionClipLoader.toMotionClip() bridge method (5 min)

**File:** `Services/FBXMotionClipLoader.swift`

Add a method that converts `FBXMotionClipLoader.MotionClip` (the internal struct with `MotionFrame` arrays) into the Phase 2 `Motion/MotionClip` (the serializable NLA clip).

```swift
// MARK: - Conversion to NLA MotionClip

/// Convert an FBX-loaded motion clip into the NLA-compatible MotionClip format.
/// Reuses the SMPL-H joint name mapping to normalize all joint names to the
/// standard skeleton used by the NLA pipeline.
static func toNLAMotionClip(
    from fbxClip: MotionClip,
    source: MotionClipSource
) -> Motion.MotionClip {
    // Build reverse mapping: any FBX joint name -> canonical SMPL-H name
    var fbxToCanonical: [String: String] = [:]
    for (canonical, variants) in jointNameMapping {
        for variant in variants {
            fbxToCanonical[variant] = canonical
            fbxToCanonical[variant.lowercased()] = canonical
        }
        // The canonical name also maps to itself
        fbxToCanonical[canonical] = canonical
    }

    // Convert each FBXMotionClipLoader.MotionFrame -> Motion.PoseFrame
    var poseFrames: [Motion.PoseFrame] = []
    poseFrames.reserveCapacity(fbxClip.frameCount)

    for fbxFrame in fbxClip.frames {
        var canonicalJoints: [String: simd_quatf] = [:]
        for (jointName, rotation) in fbxFrame.jointRotations {
            let canonical = fbxToCanonical[jointName]
                ?? fbxToCanonical[jointName.lowercased()]
                ?? jointName
            canonicalJoints[canonical] = rotation
        }

        let pose = Motion.PoseFrame(
            timestamp: Double(fbxFrame.frame) / fbxClip.fps,
            rootPosition: fbxFrame.rootPosition,
            rootRotation: fbxFrame.rootRotation,
            jointRotations: canonicalJoints,
            blendShapes: [:]  // FBX body motion has no blend shapes
        )
        poseFrames.append(pose)
    }

    return Motion.MotionClip(
        id: UUID(),
        name: fbxClip.name,
        source: source,
        fps: fbxClip.fps,
        duration: fbxClip.duration,
        frames: poseFrames,
        jointNames: smplhJointNames,
        createdAt: Date()
    )
}
```

**Key detail:** The `fbxToCanonical` map is built from the existing `jointNameMapping` dictionary (lines 74-97 of FBXMotionClipLoader.swift), so Mixamo names like `mixamorig:LeftArm` and SMPL-H names like `left_shoulder` both resolve to `L_Shoulder`.

**Build verify.**

---

## Step 5.3 — HunyuanMotionService.generateToTimeline() convenience (5 min)

**File:** `Services/HunyuanMotionService.swift`

Add a method that chains `generateAndDownload()` -> `FBXMotionClipLoader.load()` -> `FBXMotionClipLoader.toNLAMotionClip()`:

```swift
/// Generate a HunyuanMotion clip and return it as an NLA-ready MotionClip.
/// Does NOT place it on the timeline — the caller does that via AnimateStore.
func generateMotionClip(
    request: MotionRequest,
    destinationDirectory: URL,
    onProgress: @Sendable (String) -> Void
) async throws -> Motion.MotionClip {
    let fbxURL = try await generateAndDownload(
        request: request,
        destinationDirectory: destinationDirectory,
        onProgress: onProgress
    )

    onProgress("Loading FBX animation data...")
    let fbxClip = try FBXMotionClipLoader.load(from: fbxURL)

    onProgress("Converting to timeline clip...")
    let nlaClip = FBXMotionClipLoader.toNLAMotionClip(
        from: fbxClip,
        source: .hunyuanMotion(prompt: request.prompt)
    )

    onProgress("Ready — \(nlaClip.frames.count) frames at \(Int(nlaClip.fps)) fps")
    return nlaClip
}
```

**Build verify.**

---

## Step 5.4 — AnimateStore: addMotionClipToTimeline() (3 min)

**File:** `AnimateStore.swift`

Add a method that places a `MotionClip` on the NLA base track at the current playhead or at the end of existing clips:

```swift
// MARK: - NLA Motion Clip Placement

/// Place a MotionClip on the NLA base track.
/// Inserts at `atTime` if given, otherwise appends after the last clip on the base track.
func addMotionClipToTimeline(_ clip: Motion.MotionClip, atTime: Double? = nil) {
    guard var timeline = currentNLATimeline else { return }

    let insertTime: Double
    if let requested = atTime {
        insertTime = requested
    } else {
        // Append after last clip on base track
        let baseTrack = timeline.tracks.first { $0.isBaseTrack }
        let lastEnd = baseTrack?.clips.map { $0.startTime + $0.duration }.max() ?? 0
        insertTime = lastEnd
    }

    let entry = NLAClipEntry(
        id: UUID(),
        clipID: clip.id,
        startTime: insertTime,
        duration: clip.duration,
        speed: 1.0,
        bodyMask: .fullBody,
        blendIn: 0,
        blendOut: 0
    )

    // Ensure base track exists
    if timeline.tracks.isEmpty || !timeline.tracks.contains(where: { $0.isBaseTrack }) {
        let baseTrack = NLATrack(id: UUID(), name: "Base", isBaseTrack: true, clips: [])
        timeline.tracks.insert(baseTrack, at: 0)
    }

    if let idx = timeline.tracks.firstIndex(where: { $0.isBaseTrack }) {
        timeline.tracks[idx].clips.append(entry)
    }

    // Store the clip data and update the timeline
    motionClipLibrary[clip.id] = clip
    currentNLATimeline = timeline
}
```

This assumes `currentNLATimeline`, `motionClipLibrary`, `NLAClipEntry`, and `NLATrack` are defined in the Phase 2-4 types.

**Build verify.**

---

## Step 5.5 — "Send to Timeline" button in MotionGenerationPane (5 min)

**File:** `Views/MotionGenerationPane.swift` (new file, or extend existing HunyuanMotion UI)

Add a SwiftUI view that wraps the existing HunyuanMotion generation flow and adds a "Send to Timeline" action:

```swift
import SwiftUI

@available(macOS 26.0, *)
struct MotionGenerationPane: View {
    @Environment(AnimateStore.self) private var store
    @State private var prompt = ""
    @State private var durationSeconds: Double = 4.0
    @State private var isGenerating = false
    @State private var progressMessage = ""
    @State private var generatedClip: Motion.MotionClip?
    @State private var errorMessage: String?

    private let service = HunyuanMotionService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Motion Generation")
                .font(.headline)

            TextField("Describe the motion...", text: $prompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Duration:")
                Slider(value: $durationSeconds, in: 1...12, step: 0.5)
                Text("\(durationSeconds, specifier: "%.1f")s")
                    .monospacedDigit()
                    .frame(width: 40)
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressMessage)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Generate") {
                    Task { await generate() }
                }
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)

                if let clip = generatedClip {
                    Button("Send to Timeline") {
                        store.addMotionClipToTimeline(clip)
                        generatedClip = nil
                    }
                    .buttonStyle(.borderedProminent)

                    Text("\(clip.frames.count) frames, \(String(format: "%.1f", clip.duration))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private func generate() async {
        guard let destinationDir = store.animateURL?
            .appendingPathComponent("Characters")
            .appendingPathComponent("_shared")
            .appendingPathComponent("motions") else { return }

        isGenerating = true
        errorMessage = nil
        generatedClip = nil

        do {
            let request = HunyuanMotionService.MotionRequest(
                prompt: prompt,
                durationSeconds: durationSeconds
            )
            let clip = try await service.generateMotionClip(
                request: request,
                destinationDirectory: destinationDir,
                onProgress: { msg in
                    Task { @MainActor in progressMessage = msg }
                }
            )
            generatedClip = clip
        } catch {
            errorMessage = error.localizedDescription
        }

        isGenerating = false
    }
}
```

**Build verify. Commit: "Phase 5: HunyuanMotion FBX -> MotionClip bridge + Send to Timeline"**

---

# Phase 6: Import/Export + Polish (2 weeks)

## Step 6.1 — VideoMotionExtractor: AVAssetReader frame extraction (5 min)

**File:** `Capture/VideoMotionExtractor.swift` (new)

```swift
import AVFoundation
import CoreImage

/// Extracts video frames from a file and processes them through the
/// body + face tracking pipeline to produce a MotionClip.
@available(macOS 26.0, *)
final class VideoMotionExtractor: Sendable {

    enum ExtractionError: LocalizedError {
        case cannotOpenAsset
        case noVideoTrack
        case readerFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotOpenAsset: "Cannot open video file."
            case .noVideoTrack: "No video track found in file."
            case .readerFailed(let msg): "Video reader failed: \(msg)"
            case .cancelled: "Extraction was cancelled."
            }
        }
    }

    struct ExtractionProgress: Sendable {
        let framesProcessed: Int
        let totalFrames: Int
        let currentTime: Double
        let totalDuration: Double

        var fraction: Double {
            totalFrames > 0 ? Double(framesProcessed) / Double(totalFrames) : 0
        }
    }

    /// Extract motion from a video file.
    /// Runs body and face tracking on every frame, producing a MotionClip.
    static func extract(
        from videoURL: URL,
        bodyTracker: VisionBodyTracker,
        faceTracker: VisionFaceTracker,
        fps: Double = 30,
        onProgress: @Sendable (ExtractionProgress) -> Void,
        cancellation: @Sendable () -> Bool = { false }
    ) async throws -> Motion.MotionClip {
        let asset = AVURLAsset(url: videoURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExtractionError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        let totalFrames = Int(ceil(totalSeconds * fps))

        // Configure reader for RGB output
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw ExtractionError.readerFailed(reader.error?.localizedDescription ?? "Unknown")
        }

        // Process frames at target fps using time-based sampling
        let frameDuration = 1.0 / fps
        var poseFrames: [Motion.PoseFrame] = []
        poseFrames.reserveCapacity(totalFrames)

        var nextTargetTime: Double = 0
        var framesProcessed = 0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if cancellation() { throw ExtractionError.cancelled }

            let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

            // Skip frames until we reach our target time (downsample to target fps)
            guard presentationTime >= nextTargetTime else { continue }
            nextTargetTime = presentationTime + frameDuration

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // Run body tracking
            let bodyPose = try await bodyTracker.detect(in: pixelBuffer, at: presentationTime)

            // Run face tracking
            let facePose = try await faceTracker.detect(in: pixelBuffer, at: presentationTime)

            // Merge into UnifiedPoseFrame
            let unified = UnifiedPoseFrame.merge(body: bodyPose, face: facePose, timestamp: presentationTime)

            // Convert to PoseFrame for MotionClip
            let poseFrame = Motion.PoseFrame(
                timestamp: presentationTime,
                rootPosition: unified.rootPosition,
                rootRotation: unified.rootRotation,
                jointRotations: unified.jointRotations,
                blendShapes: unified.blendShapes
            )
            poseFrames.append(poseFrame)

            framesProcessed += 1
            onProgress(ExtractionProgress(
                framesProcessed: framesProcessed,
                totalFrames: totalFrames,
                currentTime: presentationTime,
                totalDuration: totalSeconds
            ))
        }

        if reader.status == .failed {
            throw ExtractionError.readerFailed(reader.error?.localizedDescription ?? "Unknown")
        }

        // Collect joint names from all frames
        var allJointNames: Set<String> = []
        for frame in poseFrames {
            allJointNames.formUnion(frame.jointRotations.keys)
        }

        return Motion.MotionClip(
            id: UUID(),
            name: videoURL.deletingPathExtension().lastPathComponent,
            source: .videoImport(url: videoURL),
            fps: fps,
            duration: totalSeconds,
            frames: poseFrames,
            jointNames: Array(allJointNames).sorted(),
            createdAt: Date()
        )
    }
}
```

**Build verify.**

---

## Step 6.2 — MotionClipSource: add videoImport case (2 min)

**File:** `Motion/MotionClip.swift`

```swift
// In MotionClipSource enum, add:
case videoImport(url: URL)
```

**Build verify.**

---

## Step 6.3 — AnimateStore: video import action (4 min)

**File:** `AnimateStore.swift`

Add properties and a method for video import:

```swift
// MARK: - Video Import

var isImportingVideo = false
var videoImportProgress: VideoMotionExtractor.ExtractionProgress?
var videoImportCancelled = false

func importVideoToTimeline(url: URL) async {
    isImportingVideo = true
    videoImportProgress = nil
    videoImportCancelled = false

    do {
        let bodyTracker = VisionBodyTracker()
        let faceTracker = VisionFaceTracker()

        let clip = try await VideoMotionExtractor.extract(
            from: url,
            bodyTracker: bodyTracker,
            faceTracker: faceTracker,
            fps: 30,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.videoImportProgress = progress
                }
            },
            cancellation: { [weak self] in
                // Access from nonisolated context — read the flag
                // via a local capture set before the closure was formed.
                // In practice, cancellation is checked on the extraction
                // actor so we capture a reference and read atomically.
                return self?.videoImportCancelled ?? true
            }
        )

        addMotionClipToTimeline(clip)
    } catch {
        print("[VideoImport] Error: \(error.localizedDescription)")
    }

    isImportingVideo = false
    videoImportProgress = nil
}

func cancelVideoImport() {
    videoImportCancelled = true
}
```

**Build verify.**

---

## Step 6.4 — Video import drop handler in NLATimelineView (4 min)

**File:** `NLA/NLATimelineView.swift`

Add a `.onDrop` modifier to accept `.mov` and `.mp4` files:

```swift
import UniformTypeIdentifiers

// Inside NLATimelineView body, add to the outermost container:
.onDrop(of: [.movie, .mpeg4Movie], isTargeted: nil) { providers in
    guard let provider = providers.first else { return false }
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in
            await store.importVideoToTimeline(url: url)
        }
    }
    return true
}
```

Also add a video import progress overlay inside the view:

```swift
// Inside NLATimelineView body:
if store.isImportingVideo, let progress = store.videoImportProgress {
    VStack(spacing: 8) {
        ProgressView(value: progress.fraction) {
            Text("Processing video...")
        }
        Text("Frame \(progress.framesProcessed) / \(progress.totalFrames)")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Cancel") {
            store.cancelVideoImport()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .frame(maxWidth: 300)
}
```

**Build verify. Commit: "Phase 6.1: Video file import via drag-and-drop to NLA timeline"**

---

## Step 6.5 — BVHExporter: MotionClip -> BVH file (5 min)

**File:** `Motion/BVHExporter.swift` (new)

```swift
import Foundation
import simd

/// Exports a MotionClip to BVH (Biovision Hierarchy) format.
@available(macOS 26.0, *)
struct BVHExporter: Sendable {

    /// Standard BVH skeleton hierarchy.
    /// Each entry: (joint name, parent index (-1 for root), offset x/y/z)
    static let hierarchy: [(name: String, parentIndex: Int, offset: SIMD3<Float>)] = [
        ("Pelvis",     -1, SIMD3<Float>(0, 0, 0)),
        ("Spine1",      0, SIMD3<Float>(0, 0.1, 0)),
        ("Spine2",      1, SIMD3<Float>(0, 0.1, 0)),
        ("Spine3",      2, SIMD3<Float>(0, 0.1, 0)),
        ("Neck",        3, SIMD3<Float>(0, 0.08, 0)),
        ("Head",        4, SIMD3<Float>(0, 0.08, 0)),
        ("L_Collar",    3, SIMD3<Float>(0.02, 0.06, 0)),
        ("L_Shoulder",  6, SIMD3<Float>(0.12, 0, 0)),
        ("L_Elbow",     7, SIMD3<Float>(0.25, 0, 0)),
        ("L_Wrist",     8, SIMD3<Float>(0.22, 0, 0)),
        ("R_Collar",    3, SIMD3<Float>(-0.02, 0.06, 0)),
        ("R_Shoulder", 10, SIMD3<Float>(-0.12, 0, 0)),
        ("R_Elbow",    11, SIMD3<Float>(-0.25, 0, 0)),
        ("R_Wrist",    12, SIMD3<Float>(-0.22, 0, 0)),
        ("L_Hip",       0, SIMD3<Float>(0.1, 0, 0)),
        ("L_Knee",     14, SIMD3<Float>(0, -0.4, 0)),
        ("L_Ankle",    15, SIMD3<Float>(0, -0.4, 0)),
        ("L_Foot",     16, SIMD3<Float>(0, -0.04, 0.08)),
        ("R_Hip",       0, SIMD3<Float>(-0.1, 0, 0)),
        ("R_Knee",     18, SIMD3<Float>(0, -0.4, 0)),
        ("R_Ankle",    19, SIMD3<Float>(0, -0.4, 0)),
        ("R_Foot",     20, SIMD3<Float>(0, -0.04, 0.08)),
    ]

    /// Convert a quaternion to ZXY Euler angles in degrees (BVH convention).
    static func quaternionToEulerDegrees(_ q: simd_quatf) -> SIMD3<Float> {
        // Extract rotation matrix
        let m = simd_float3x3(q)
        // ZXY decomposition
        let x = asin(max(-1, min(1, m[2][1])))
        let y: Float
        let z: Float
        if abs(m[2][1]) < 0.9999 {
            y = atan2(-m[2][0], m[2][2])
            z = atan2(-m[0][1], m[1][1])
        } else {
            y = atan2(m[0][2], m[0][0])
            z = 0
        }
        let toDeg: Float = 180.0 / .pi
        return SIMD3<Float>(x * toDeg, y * toDeg, z * toDeg)
    }

    /// Export a MotionClip to BVH string.
    static func export(_ clip: Motion.MotionClip) -> String {
        var lines: [String] = []

        // --- HIERARCHY section ---
        lines.append("HIERARCHY")
        var indentStack: [Int] = []

        func indent() -> String { String(repeating: "\t", count: indentStack.count) }

        for (i, joint) in hierarchy.enumerated() {
            // Close braces for siblings at same depth
            while let parentIdx = indentStack.last, parentIdx != joint.parentIndex && !indentStack.isEmpty {
                indentStack.removeLast()
                lines.append("\(indent())}")
            }

            let prefix = indent()
            if joint.parentIndex == -1 {
                lines.append("\(prefix)ROOT \(joint.name)")
            } else {
                lines.append("\(prefix)JOINT \(joint.name)")
            }
            lines.append("\(prefix){")
            indentStack.append(i)

            let off = joint.offset
            lines.append("\(prefix)\tOFFSET \(String(format: "%.4f %.4f %.4f", off.x, off.y, off.z))")

            if joint.parentIndex == -1 {
                lines.append("\(prefix)\tCHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation")
            } else {
                lines.append("\(prefix)\tCHANNELS 3 Zrotation Xrotation Yrotation")
            }

            // Check if this joint has children
            let hasChildren = hierarchy.dropFirst(i + 1).contains { $0.parentIndex == i }
            if !hasChildren {
                lines.append("\(prefix)\tEnd Site")
                lines.append("\(prefix)\t{")
                lines.append("\(prefix)\t\tOFFSET 0.0000 0.0200 0.0000")
                lines.append("\(prefix)\t}")
            }
        }

        // Close remaining braces
        while !indentStack.isEmpty {
            indentStack.removeLast()
            lines.append("\(indent())}")
        }

        // --- MOTION section ---
        let frameCount = clip.frames.count
        let frameTime = clip.fps > 0 ? 1.0 / clip.fps : 1.0 / 30.0

        lines.append("MOTION")
        lines.append("Frames: \(frameCount)")
        lines.append("Frame Time: \(String(format: "%.6f", frameTime))")

        for frame in clip.frames {
            var values: [String] = []

            for (i, joint) in hierarchy.enumerated() {
                let rotation = frame.jointRotations[joint.name] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                let euler = quaternionToEulerDegrees(rotation)

                if i == 0 {
                    // Root: position + rotation
                    let pos = frame.rootPosition
                    values.append(String(format: "%.4f", pos.x))
                    values.append(String(format: "%.4f", pos.y))
                    values.append(String(format: "%.4f", pos.z))
                }

                // ZXY order
                values.append(String(format: "%.4f", euler.z))
                values.append(String(format: "%.4f", euler.x))
                values.append(String(format: "%.4f", euler.y))
            }

            lines.append(values.joined(separator: " "))
        }

        return lines.joined(separator: "\n")
    }

    /// Export and write to a file URL.
    static func exportToFile(_ clip: Motion.MotionClip, url: URL) throws {
        let bvhString = export(clip)
        try bvhString.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

**Build verify.**

---

## Step 6.6 — AnimateStore: BVH export action (3 min)

**File:** `AnimateStore.swift`

```swift
// MARK: - BVH Export

func exportClipAsBVH(clipID: UUID) {
    guard let clip = motionClipLibrary[clipID] else { return }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "bvh") ?? .data]
    panel.nameFieldStringValue = "\(clip.name).bvh"
    panel.canCreateDirectories = true

    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
        try BVHExporter.exportToFile(clip, url: url)
    } catch {
        print("[BVHExport] Error: \(error.localizedDescription)")
    }
}
```

**Build verify. Commit: "Phase 6.2: BVH export from MotionClip"**

---

## Step 6.7 — Crossfade visualization in NLATimelineView (5 min)

**File:** `NLA/NLATimelineView.swift`

Add a helper view that renders the blend zone where two clips overlap on the same track:

```swift
/// Renders a diagonal gradient crossfade indicator in clip overlap zones.
struct CrossfadeOverlayView: View {
    let overlapStartX: CGFloat
    let overlapWidth: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        if overlapWidth > 0 {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.3),
                            Color.orange.opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: overlapWidth, height: trackHeight)
                .offset(x: overlapStartX)
                .allowsHitTesting(false)
        }
    }
}
```

In the track rendering loop inside `NLATimelineView`, detect overlaps between consecutive clips and insert `CrossfadeOverlayView`:

```swift
// Inside the ForEach over track.clips (sorted by startTime):
// After rendering each clip rectangle, check for overlap with the next clip.
private func crossfadeOverlays(
    for track: NLATrack,
    pixelsPerSecond: CGFloat,
    trackHeight: CGFloat
) -> some View {
    let sorted = track.clips.sorted { $0.startTime < $1.startTime }
    return ForEach(Array(sorted.enumerated()), id: \.element.id) { index, clip in
        if index + 1 < sorted.count {
            let next = sorted[index + 1]
            let clipEnd = clip.startTime + clip.duration
            let overlap = clipEnd - next.startTime
            if overlap > 0 {
                CrossfadeOverlayView(
                    overlapStartX: CGFloat(next.startTime) * pixelsPerSecond,
                    overlapWidth: CGFloat(overlap) * pixelsPerSecond,
                    trackHeight: trackHeight
                )
            }
        }
    }
}
```

**Build verify.**

---

## Step 6.8 — Keyboard shortcuts for timeline playback (4 min)

**File:** `NLA/NLATimelineView.swift`

Add keyboard handling at the top level of the timeline view. Use `.onKeyPress` on a focusable wrapper (NOT on a TextEditor container per the project convention in `feedback_keyboard_focus_scope.md`):

```swift
// Wrap the timeline content (not any TextEditor) in a focusable container:
.focusable()
.onKeyPress(.space) {
    store.togglePlayback()
    return .handled
}
.onKeyPress(.leftArrow) {
    store.stepFrame(delta: -1)
    return .handled
}
.onKeyPress(.rightArrow) {
    store.stepFrame(delta: 1)
    return .handled
}
.onKeyPress(.leftArrow, modifiers: .shift) {
    store.stepFrame(delta: -10)
    return .handled
}
.onKeyPress(.rightArrow, modifiers: .shift) {
    store.stepFrame(delta: 10)
    return .handled
}
```

Add corresponding methods to AnimateStore if not already present:

```swift
// In AnimateStore:
func togglePlayback() {
    isPlaying.toggle()
}

func stepFrame(delta: Int) {
    guard !isPlaying else { return }
    currentFrame = max(0, currentFrame + delta)
}
```

**Build verify.**

---

## Step 6.9 — Per-clip speed adjustment (4 min)

**File:** `NLA/NLATimelineView.swift`

Add a context menu to clip rectangles in the timeline:

```swift
// On each clip rectangle view:
.contextMenu {
    Menu("Speed") {
        Button("0.25x") { setClipSpeed(clipID: entry.id, speed: 0.25) }
        Button("0.5x") { setClipSpeed(clipID: entry.id, speed: 0.5) }
        Button("1x") { setClipSpeed(clipID: entry.id, speed: 1.0) }
        Button("2x") { setClipSpeed(clipID: entry.id, speed: 2.0) }
        Divider()
        Button("Custom...") { showCustomSpeedPopover(clipID: entry.id) }
    }

    Divider()

    Button("Export as BVH...") {
        store.exportClipAsBVH(clipID: entry.clipID)
    }

    Button("Remove from Track") {
        removeClipFromTrack(entry: entry)
    }
}
```

Speed adjustment helper in AnimateStore:

```swift
// In AnimateStore:
func setClipSpeed(entryID: UUID, speed: Double) {
    guard var timeline = currentNLATimeline else { return }
    for trackIdx in timeline.tracks.indices {
        if let clipIdx = timeline.tracks[trackIdx].clips.firstIndex(where: { $0.id == entryID }) {
            timeline.tracks[trackIdx].clips[clipIdx].speed = max(0.1, min(4.0, speed))
        }
    }
    currentNLATimeline = timeline
}
```

The `NLAEvaluator` (Phase 4) must already account for `NLAClipEntry.speed` when sampling — verify that it divides the local time by `entry.speed` to get the clip-space time.

**Build verify.**

---

## Step 6.10 — Timeline zoom and scroll (5 min)

**File:** `NLA/NLATimelineView.swift`

Add zoom and scroll state and gesture handling:

```swift
// State in NLATimelineView:
@State private var pixelsPerSecond: CGFloat = 100
@State private var scrollOffset: CGFloat = 0

// Zoom: Cmd + scroll wheel or pinch gesture
.onScrollGesture(axes: .horizontal) { phase, delta in
    // Pan
    scrollOffset -= delta.width
    scrollOffset = max(0, scrollOffset)
}
// For zoom, use magnification gesture:
.gesture(
    MagnifyGesture()
        .onChanged { value in
            let newPPS = pixelsPerSecond * value.magnification
            pixelsPerSecond = max(20, min(500, newPPS))
        }
)
// Also support Cmd+scroll for zoom:
.onKeyPress(.equal, modifiers: .command) {
    pixelsPerSecond = min(500, pixelsPerSecond * 1.25)
    return .handled
}
.onKeyPress(.minus, modifiers: .command) {
    pixelsPerSecond = max(20, pixelsPerSecond / 1.25)
    return .handled
}
```

Use `pixelsPerSecond` throughout the timeline for positioning:
- Clip X position = `(entry.startTime * pixelsPerSecond) - scrollOffset`
- Clip width = `entry.duration * pixelsPerSecond`
- Playhead X = `(Double(currentFrame) / fps * pixelsPerSecond) - scrollOffset`
- Ruler tick marks spaced by `pixelsPerSecond` (1 second intervals), subdividing when zoomed in

```swift
// Timeline ruler at top:
struct TimelineRuler: View {
    let pixelsPerSecond: CGFloat
    let scrollOffset: CGFloat
    let visibleWidth: CGFloat
    let totalDuration: Double

    var body: some View {
        Canvas { context, size in
            let startSecond = Int(scrollOffset / pixelsPerSecond)
            let endSecond = Int((scrollOffset + visibleWidth) / pixelsPerSecond) + 1

            for sec in startSecond...min(endSecond, Int(totalDuration) + 1) {
                let x = CGFloat(sec) * pixelsPerSecond - scrollOffset
                // Major tick
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(.secondary.opacity(0.5)),
                    lineWidth: 1
                )
                // Label
                context.draw(
                    Text("\(sec)s").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: x + 4, y: 6),
                    anchor: .topLeading
                )
            }
        }
        .frame(height: 20)
    }
}
```

**Build verify. Commit: "Phase 6.3: Crossfade viz, keyboard shortcuts, speed, zoom/scroll"**

---

# Phase 7: Audio Lip Sync + Enhanced Tracking (2-3 weeks)

## Step 7.1 — AudioVisemeClassifier: real-time audio to viseme weights (5 min)

**File:** `Capture/AudioVisemeClassifier.swift` (new)

This lightweight classifier maps audio spectral features to viseme probability weights. It uses AVAudioEngine for real-time capture and vDSP for FFT analysis.

```swift
import AVFoundation
import Accelerate

/// Real-time audio analysis that produces per-frame viseme blend weights.
/// Uses spectral energy bands to approximate mouth shapes without a neural model.
@available(macOS 26.0, *)
final class AudioVisemeClassifier: @unchecked Sendable {

    struct VisemeWeights: Sendable {
        let timestamp: Double
        let weights: [PrestonBlairViseme: Float]

        /// The dominant viseme (highest weight).
        var dominant: PrestonBlairViseme {
            weights.max(by: { $0.value < $1.value })?.key ?? .rest
        }
    }

    private let audioEngine = AVAudioEngine()
    private let fftSize = 1024
    private nonisolated(unsafe) var isRunning = false

    // Callback for each analysis frame
    private let onVisemeWeights: @Sendable (VisemeWeights) -> Void
    private let sampleRate: Double

    init(
        sampleRate: Double = 44100,
        onVisemeWeights: @Sendable @escaping (VisemeWeights) -> Void
    ) {
        self.sampleRate = sampleRate
        self.onVisemeWeights = onVisemeWeights
    }

    /// Start capturing and analyzing microphone audio.
    func start() throws {
        guard !isRunning else { return }

        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        // Install a tap to receive audio buffers
        inputNode.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] buffer, time in
            guard let self else { return }
            let timestamp = Double(time.sampleTime) / format.sampleRate
            let weights = self.analyzeBuffer(buffer)
            self.onVisemeWeights(VisemeWeights(timestamp: timestamp, weights: weights))
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }

    /// Analyze a single audio buffer and return viseme weights.
    ///
    /// Frequency band mapping (approximate vocal formants):
    /// - 200-500 Hz: F1 region (jaw opening) -> ai, o
    /// - 500-1500 Hz: F2 region (tongue position) -> e, u
    /// - 1500-3000 Hz: F3 region (lip rounding) -> o, u, wq
    /// - 3000-6000 Hz: sibilants -> consonant, fv
    /// - Overall energy: voice activity detection
    private func analyzeBuffer(_ buffer: AVAudioPCMBuffer) -> [PrestonBlairViseme: Float] {
        guard let channelData = buffer.floatChannelData?[0] else {
            return [.rest: 1.0]
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return [.rest: 1.0] }

        // Compute power spectrum using vDSP
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        // Use vDSP FFT
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [.rest: 1.0]
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Prepare split complex
        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)

        // Apply Hanning window
        var windowed = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Convert to split complex
        windowed.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Compute energy in frequency bands
        let binHz = Float(sampleRate) / Float(fftSize)
        func bandEnergy(lowHz: Float, highHz: Float) -> Float {
            let lowBin = max(0, Int(lowHz / binHz))
            let highBin = min(magnitudes.count - 1, Int(highHz / binHz))
            guard lowBin <= highBin else { return 0 }
            var sum: Float = 0
            vDSP_sve(Array(magnitudes[lowBin...highBin]), 1, &sum, vDSP_Length(highBin - lowBin + 1))
            return sum / Float(highBin - lowBin + 1)
        }

        let totalEnergy = bandEnergy(lowHz: 80, highHz: 8000)
        let f1 = bandEnergy(lowHz: 200, highHz: 500)   // jaw opening
        let f2 = bandEnergy(lowHz: 500, highHz: 1500)   // tongue front/back
        let f3 = bandEnergy(lowHz: 1500, highHz: 3000)  // lip rounding
        let highFreq = bandEnergy(lowHz: 3000, highHz: 6000) // sibilants

        // Silence threshold
        let silenceThreshold: Float = 0.01
        guard totalEnergy > silenceThreshold else {
            return [.rest: 1.0]
        }

        // Normalize energies
        let norm = max(totalEnergy, 0.001)
        let f1n = f1 / norm
        let f2n = f2 / norm
        let f3n = f3 / norm
        let hn = highFreq / norm

        // Map to viseme weights
        var weights: [PrestonBlairViseme: Float] = [:]
        weights[.ai] = f1n * 0.6 + f2n * 0.2                // open + front
        weights[.e] = f2n * 0.5 + f1n * 0.2                  // mid-open + front
        weights[.o] = f1n * 0.4 + f3n * 0.4                  // open + rounded
        weights[.u] = f3n * 0.5 + f2n * 0.1                  // rounded + back
        weights[.consonant] = hn * 0.5 + f2n * 0.2           // high frequency
        weights[.fv] = hn * 0.4 + f3n * 0.2                  // fricatives
        weights[.mbp] = max(0, 0.3 - totalEnergy * 5)        // energy dip = closure
        weights[.l] = f2n * 0.3 + f1n * 0.15                 // lateral
        weights[.wq] = f3n * 0.4 + (1 - f1n) * 0.2          // rounded + closed
        weights[.rest] = max(0, silenceThreshold * 2 - totalEnergy) // near-silence

        // Normalize weights to sum to 1
        let total = weights.values.reduce(0, +)
        if total > 0 {
            for key in weights.keys {
                weights[key]! /= total
            }
        }

        return weights
    }
}
```

**Build verify.**

---

## Step 7.2 — ARKit blend shape mapping from Preston Blair visemes (3 min)

**File:** `Capture/VisemeToBlendShapeMapper.swift` (new)

```swift
import ARKit

/// Maps Preston Blair visemes to ARKit face blend shape coefficients.
/// Used to drive 3D character face rigs that support ARKit blend shapes.
@available(macOS 26.0, *)
struct VisemeToBlendShapeMapper: Sendable {

    /// ARKit blend shape weights for each Preston Blair viseme.
    static let mapping: [PrestonBlairViseme: [ARFaceAnchor.BlendShapeLocation: Float]] = [
        .rest: [:],

        .ai: [
            .jawOpen: 0.6,
            .mouthStretchLeft: 0.3,
            .mouthStretchRight: 0.3,
        ],

        .e: [
            .jawOpen: 0.3,
            .mouthSmileLeft: 0.5,
            .mouthSmileRight: 0.5,
        ],

        .o: [
            .jawOpen: 0.5,
            .mouthFunnel: 0.6,
        ],

        .u: [
            .jawOpen: 0.2,
            .mouthPucker: 0.7,
        ],

        .mbp: [
            .jawOpen: 0.0,
            .mouthClose: 0.8,
        ],

        .fv: [
            .jawOpen: 0.1,
            .mouthLowerDownLeft: 0.3,
            .mouthLowerDownRight: 0.3,
        ],

        .l: [
            .jawOpen: 0.3,
            .tongueOut: 0.2,
        ],

        .consonant: [
            .jawOpen: 0.2,
        ],

        .wq: [
            .jawOpen: 0.2,
            .mouthPucker: 0.5,
        ],
    ]

    /// Convert viseme weights to a blended set of ARKit blend shapes.
    /// Takes multiple viseme weights (summing to ~1) and produces a single
    /// set of blend shape values.
    static func blendShapes(
        from visemeWeights: [PrestonBlairViseme: Float]
    ) -> [ARFaceAnchor.BlendShapeLocation: Float] {
        var result: [ARFaceAnchor.BlendShapeLocation: Float] = [:]

        for (viseme, weight) in visemeWeights where weight > 0.01 {
            guard let shapes = mapping[viseme] else { continue }
            for (location, value) in shapes {
                result[location, default: 0] += value * weight
            }
        }

        // Clamp all values to [0, 1]
        for key in result.keys {
            result[key] = max(0, min(1, result[key]!))
        }

        return result
    }

    /// Convert a single dominant viseme to blend shapes (convenience).
    static func blendShapes(for viseme: PrestonBlairViseme) -> [ARFaceAnchor.BlendShapeLocation: Float] {
        mapping[viseme] ?? [:]
    }
}
```

**Build verify.**

---

## Step 7.3 — AudioLipSyncRecorder: capture audio to MotionClip (5 min)

**File:** `Capture/AudioLipSyncRecorder.swift` (new)

Records audio viseme analysis into a MotionClip with only blend shape data (no body joints), suitable for the NLA lip sync track.

```swift
import Foundation
import simd

/// Records real-time audio viseme analysis into a MotionClip.
/// The resulting clip contains only blend shape data (no body joints)
/// and is intended for the dedicated "Lip Sync" NLA track.
@available(macOS 26.0, *)
@MainActor
final class AudioLipSyncRecorder {

    private var classifier: AudioVisemeClassifier?
    private var recordedFrames: [Motion.PoseFrame] = []
    private var startTime: Date?
    private var isRecording = false
    private let fps: Double = 30

    // Accumulator for audio frames that arrive faster than our target fps
    private var pendingWeights: [AudioVisemeClassifier.VisemeWeights] = []
    private var lastFrameTimestamp: Double = 0

    /// Start recording audio lip sync.
    func startRecording() throws {
        recordedFrames = []
        pendingWeights = []
        lastFrameTimestamp = 0
        startTime = Date()
        isRecording = true

        classifier = AudioVisemeClassifier { [weak self] weights in
            Task { @MainActor [weak self] in
                self?.handleVisemeWeights(weights)
            }
        }
        try classifier?.start()
    }

    /// Stop recording and return the resulting MotionClip.
    func stopRecording() -> Motion.MotionClip {
        isRecording = false
        classifier?.stop()
        classifier = nil

        // Flush any remaining pending weights
        flushPendingWeights()

        let duration = recordedFrames.last?.timestamp ?? 0

        return Motion.MotionClip(
            id: UUID(),
            name: "Lip Sync \(ISO8601DateFormatter().string(from: startTime ?? Date()))",
            source: .audioLipSync,
            fps: fps,
            duration: duration,
            frames: recordedFrames,
            jointNames: [],  // No body joints — blend shapes only
            createdAt: Date()
        )
    }

    private func handleVisemeWeights(_ weights: AudioVisemeClassifier.VisemeWeights) {
        guard isRecording else { return }
        pendingWeights.append(weights)

        // Output at target fps
        let frameDuration = 1.0 / fps
        if weights.timestamp - lastFrameTimestamp >= frameDuration {
            flushPendingWeights()
        }
    }

    private func flushPendingWeights() {
        guard !pendingWeights.isEmpty else { return }

        // Average the accumulated weights
        var avgWeights: [PrestonBlairViseme: Float] = [:]
        let count = Float(pendingWeights.count)

        for pw in pendingWeights {
            for (viseme, weight) in pw.weights {
                avgWeights[viseme, default: 0] += weight / count
            }
        }

        let timestamp = pendingWeights.last?.timestamp ?? lastFrameTimestamp
        lastFrameTimestamp = timestamp

        // Convert viseme weights to ARKit blend shapes
        let blendShapes = VisemeToBlendShapeMapper.blendShapes(from: avgWeights)

        // Convert ARKit blend shape locations to string keys
        var blendShapeStrings: [String: Float] = [:]
        for (location, value) in blendShapes {
            blendShapeStrings[location.rawValue.description] = value
        }

        let frame = Motion.PoseFrame(
            timestamp: timestamp,
            rootPosition: .zero,
            rootRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            jointRotations: [:],
            blendShapes: blendShapeStrings
        )
        recordedFrames.append(frame)

        pendingWeights = []
    }
}
```

**Build verify.**

---

## Step 7.4 — MotionClipSource: add audioLipSync case (2 min)

**File:** `Motion/MotionClip.swift`

```swift
// In MotionClipSource enum, add:
case audioLipSync
```

**Build verify.**

---

## Step 7.5 — AnimateStore: audio lip sync recording integration (4 min)

**File:** `AnimateStore.swift`

```swift
// MARK: - Audio Lip Sync Recording

private var audioLipSyncRecorder: AudioLipSyncRecorder?
var isRecordingAudioLipSync = false

func startAudioLipSyncRecording() {
    guard !isRecordingAudioLipSync else { return }
    let recorder = AudioLipSyncRecorder()
    do {
        try recorder.startRecording()
        audioLipSyncRecorder = recorder
        isRecordingAudioLipSync = true
    } catch {
        print("[AudioLipSync] Failed to start: \(error.localizedDescription)")
    }
}

func stopAudioLipSyncRecording() {
    guard isRecordingAudioLipSync, let recorder = audioLipSyncRecorder else { return }
    let clip = recorder.stopRecording()
    audioLipSyncRecorder = nil
    isRecordingAudioLipSync = false

    // Place on a dedicated Lip Sync track with .mouth body mask
    addMotionClipToLipSyncTrack(clip)
}

/// Place a lip sync clip on the dedicated "Lip Sync" track.
/// Creates the track if it doesn't exist. Uses `.mouth` body mask
/// so it only affects facial blend shapes.
func addMotionClipToLipSyncTrack(_ clip: Motion.MotionClip) {
    guard var timeline = currentNLATimeline else { return }

    // Find or create the lip sync track
    let lipSyncTrackIndex: Int
    if let idx = timeline.tracks.firstIndex(where: { $0.name == "Lip Sync" }) {
        lipSyncTrackIndex = idx
    } else {
        let track = NLATrack(
            id: UUID(),
            name: "Lip Sync",
            isBaseTrack: false,
            clips: []
        )
        timeline.tracks.append(track)
        lipSyncTrackIndex = timeline.tracks.count - 1
    }

    // Append after existing lip sync clips
    let lastEnd = timeline.tracks[lipSyncTrackIndex].clips
        .map { $0.startTime + $0.duration }.max() ?? 0

    let entry = NLAClipEntry(
        id: UUID(),
        clipID: clip.id,
        startTime: lastEnd,
        duration: clip.duration,
        speed: 1.0,
        bodyMask: .mouth,
        blendIn: 0.05,
        blendOut: 0.05
    )

    timeline.tracks[lipSyncTrackIndex].clips.append(entry)
    motionClipLibrary[clip.id] = clip
    currentNLATimeline = timeline
}
```

**Build verify. Commit: "Phase 7.1: Audio viseme classifier + lip sync recorder + timeline placement"**

---

## Step 7.6 — CharacterMouthEngine: NLA lip sync clip integration (4 min)

**File:** `Engine/CharacterMouthEngine.swift`

The existing `CharacterMouthEngine.state()` method has a `liveCue` override path (line 63-65). Add a second priority path that checks the NLA evaluator for active lip sync blend shapes before falling back to synthetic visemes:

```swift
// In CharacterMouthEngine.state(), after the liveCue check but before the lipsyncBeats check:

// Check NLA lip sync track for audio-driven blend shapes
if let nlaBlendShapes = nlaLipSyncBlendShapes(at: frame, baseFPS: baseFPS) {
    // Convert ARKit blend shapes back to MouthSnapshot
    let snapshot = mouthSnapshotFromBlendShapes(nlaBlendShapes)
    let viseme = dominantViseme(from: snapshot)
    return canonicalized(
        state: mouthState(from: snapshot, viseme: viseme),
        profile: profile
    )
}
```

Add the helper methods in the private extension:

```swift
/// Query the NLA evaluator for active lip sync blend shapes at the given frame.
/// Returns nil if no lip sync clip is active.
func nlaLipSyncBlendShapes(at frame: Int, baseFPS: Int) -> [String: Float]? {
    // This will be called by the evaluator providing blend shapes
    // from any active NLA clip on the "Lip Sync" track.
    // The NLAEvaluator (Phase 4) resolves this by evaluating clips
    // with .mouth body mask and returning their blend shape data.
    // For now, return nil — the actual wiring happens via a closure
    // or protocol injection from the animation loop.
    return nil
}

/// Approximate a MouthSnapshot from ARKit blend shape values.
func mouthSnapshotFromBlendShapes(_ shapes: [String: Float]) -> VisemeBlendEngine.MouthSnapshot {
    VisemeBlendEngine.MouthSnapshot(
        jawOpen: Double(shapes["jawOpen"] ?? 0),
        mouthWidth: Double(
            (shapes["mouthStretchLeft"] ?? 0) +
            (shapes["mouthStretchRight"] ?? 0) +
            (shapes["mouthSmileLeft"] ?? 0) +
            (shapes["mouthSmileRight"] ?? 0)
        ) / 2.0 * 0.8 + 0.3, // Scale to 0.3-0.7 range
        mouthHeight: Double(shapes["jawOpen"] ?? 0) * 0.9,
        pucker: Double(
            (shapes["mouthPucker"] ?? 0) * 0.7 +
            (shapes["mouthFunnel"] ?? 0) * 0.5
        ),
        smileBlend: Double(
            ((shapes["mouthSmileLeft"] ?? 0) +
             (shapes["mouthSmileRight"] ?? 0)) / 2.0
        )
    )
}

/// Determine the closest Preston Blair viseme for a mouth snapshot.
func dominantViseme(from snapshot: VisemeBlendEngine.MouthSnapshot) -> PrestonBlairViseme {
    var bestViseme: PrestonBlairViseme = .rest
    var bestScore: Double = .infinity

    for (viseme, ref) in VisemeBlendEngine.visemeSnapshots {
        let dist = abs(snapshot.jawOpen - ref.jawOpen)
            + abs(snapshot.mouthWidth - ref.mouthWidth)
            + abs(snapshot.pucker - ref.pucker)
        if dist < bestScore {
            bestScore = dist
            bestViseme = viseme
        }
    }
    return bestViseme
}
```

The key integration point: when the animation loop in the `NLAEvaluator` evaluates each frame, it passes the resolved blend shapes from lip sync clips to `CharacterMouthEngine` via a parameter or closure. The `nlaLipSyncBlendShapes` method will be replaced with a direct parameter in the `state()` signature:

```swift
// Updated signature:
func state(
    for characterName: String,
    blocking: CharacterBlockingPlan,
    frame: Int,
    liveCue: String?,
    nlaBlendShapes: [String: Float]?,  // NEW: from NLA lip sync track
    baseFPS: Int,
    profile: Character3DPerformanceProfile? = nil
) -> CharacterMouthState
```

**Build verify.**

---

## Step 7.7 — LipSyncEngine: audio analysis mode (4 min)

**File:** `Services/LipSyncEngine.swift`

Add a method that converts `AudioVisemeClassifier.VisemeWeights` sequences into `VisemeKeyframe` arrays, integrating with the existing engine:

```swift
// MARK: - Audio Analysis Mode

/// Generate viseme keyframes from a sequence of audio viseme weight snapshots.
/// Selects the dominant viseme at each time step and deduplicates consecutive same-visemes.
static func generateFromAudioWeights(
    _ weightSequence: [(timestamp: Double, weights: [PrestonBlairViseme: Float])],
    fps: Int
) -> [VisemeKeyframe] {
    var result: [VisemeKeyframe] = []
    var lastViseme: PrestonBlairViseme?

    for entry in weightSequence {
        let dominant = entry.weights
            .max(by: { $0.value < $1.value })?.key ?? .rest
        let frame = Int((entry.timestamp * Double(fps)).rounded())

        // Skip if same viseme as last keyframe (reduce redundancy)
        if dominant == lastViseme { continue }

        // Set duration to hold until next keyframe (will be adjusted)
        let duration = max(1, Int(Double(fps) / 15.0))  // ~2 frames at 30fps

        result.append(VisemeKeyframe(
            frame: frame,
            viseme: dominant,
            duration: duration
        ))
        lastViseme = dominant
    }

    // Fix up durations: each keyframe lasts until the next one starts
    for i in 0..<result.count - 1 {
        result[i] = VisemeKeyframe(
            frame: result[i].frame,
            viseme: result[i].viseme,
            duration: result[i + 1].frame - result[i].frame
        )
    }

    return result
}
```

**Build verify. Commit: "Phase 7.2: CharacterMouthEngine NLA blend shape integration + LipSyncEngine audio mode"**

---

## Step 7.8 — DWPose Core ML model wrapper (5 min)

**File:** `Capture/DWPoseTracker.swift` (new)

```swift
import CoreML
import Vision
import CoreImage

/// Optional high-fidelity whole-body pose tracker using DWPose Core ML model.
/// Produces 133 keypoints: 17 body + 6 foot + 68 face + 42 hand.
/// Toggle: "Enhanced Tracking (slower)" in capture settings.
@available(macOS 26.0, *)
final class DWPoseTracker: Sendable {

    enum TrackerError: LocalizedError {
        case modelNotFound
        case predictionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound: "DWPose Core ML model not found in bundle."
            case .predictionFailed(let msg): "DWPose prediction failed: \(msg)"
            }
        }
    }

    /// 133 keypoint indices grouped by body region.
    struct KeypointLayout {
        static let bodyRange = 0..<17
        static let footRange = 17..<23
        static let faceRange = 23..<91
        static let leftHandRange = 91..<112
        static let rightHandRange = 112..<133
        static let totalKeypoints = 133
    }

    /// A single detected keypoint.
    struct Keypoint: Sendable {
        let x: Float       // normalized 0-1
        let y: Float       // normalized 0-1
        let confidence: Float
    }

    /// Full detection result for one frame.
    struct Detection: Sendable {
        let keypoints: [Keypoint]  // 133 keypoints
        let timestamp: Double

        /// Extract body keypoints only.
        var bodyKeypoints: ArraySlice<Keypoint> {
            keypoints[KeypointLayout.bodyRange]
        }

        /// Extract face keypoints only.
        var faceKeypoints: ArraySlice<Keypoint> {
            keypoints[KeypointLayout.faceRange]
        }

        /// Extract left hand keypoints.
        var leftHandKeypoints: ArraySlice<Keypoint> {
            keypoints[KeypointLayout.leftHandRange]
        }

        /// Extract right hand keypoints.
        var rightHandKeypoints: ArraySlice<Keypoint> {
            keypoints[KeypointLayout.rightHandRange]
        }
    }

    /// Body keypoint names (COCO 17 format).
    static let bodyKeypointNames: [String] = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "left_hip", "right_hip",
        "left_knee", "right_knee", "left_ankle", "right_ankle"
    ]

    private let model: VNCoreMLModel

    init() throws {
        // The .mlmodelc should be added to the app bundle.
        // Model conversion: python3 -m coremltools.converters.convert dwpose.onnx
        guard let modelURL = Bundle.main.url(forResource: "DWPose", withExtension: "mlmodelc") else {
            throw TrackerError.modelNotFound
        }
        let mlModel = try MLModel(contentsOf: modelURL)
        self.model = try VNCoreMLModel(for: mlModel)
    }

    /// Detect keypoints in a pixel buffer.
    func detect(in pixelBuffer: CVPixelBuffer, at timestamp: Double) async throws -> Detection {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let multiArray = results.first?.featureValue.multiArrayValue else {
            throw TrackerError.predictionFailed("No results from model")
        }

        // Parse the output: expected shape [1, 133, 3] (x, y, confidence)
        var keypoints: [Keypoint] = []
        keypoints.reserveCapacity(KeypointLayout.totalKeypoints)

        for i in 0..<KeypointLayout.totalKeypoints {
            let x = multiArray[[0, i, 0] as [NSNumber]].floatValue
            let y = multiArray[[0, i, 1] as [NSNumber]].floatValue
            let conf = multiArray[[0, i, 2] as [NSNumber]].floatValue
            keypoints.append(Keypoint(x: x, y: y, confidence: conf))
        }

        return Detection(keypoints: keypoints, timestamp: timestamp)
    }
}
```

**Build verify.**

---

## Step 7.9 — DWPose to UnifiedPoseFrame converter (4 min)

**File:** `Capture/DWPoseConverter.swift` (new)

```swift
import simd

/// Converts DWPose 2D keypoint detections to the UnifiedPoseFrame format
/// used by the motion capture pipeline. Uses joint triangulation to
/// estimate 3D rotations from 2D positions.
@available(macOS 26.0, *)
struct DWPoseConverter: Sendable {

    /// Convert a DWPose detection to a UnifiedPoseFrame.
    /// 2D keypoints are lifted to approximate 3D using limb length priors
    /// and simple depth estimation from joint proportions.
    static func convert(_ detection: DWPoseTracker.Detection) -> UnifiedPoseFrame {
        let kps = detection.keypoints

        // Estimate root position from hip midpoint
        let leftHip = kps[11]
        let rightHip = kps[12]
        let rootX = (leftHip.x + rightHip.x) / 2
        let rootY = (leftHip.y + rightHip.y) / 2
        let rootPosition = SIMD3<Float>(rootX, rootY, 0)

        // Estimate joint rotations from limb vectors
        var jointRotations: [String: simd_quatf] = [:]

        // Spine: hip midpoint -> shoulder midpoint
        let leftShoulder = kps[5]
        let rightShoulder = kps[6]
        let shoulderMid = SIMD3<Float>(
            (leftShoulder.x + rightShoulder.x) / 2,
            (leftShoulder.y + rightShoulder.y) / 2,
            0
        )
        let hipMid = SIMD3<Float>(rootX, rootY, 0)
        jointRotations["Pelvis"] = rotationFromLimbVector(from: hipMid, to: shoulderMid, restDirection: SIMD3(0, -1, 0))

        // Left arm chain
        let lElbow = kps[7]
        let lWrist = kps[9]
        jointRotations["L_Shoulder"] = rotationBetweenKeypoints(leftShoulder, lElbow, restDir: SIMD3(1, 0, 0))
        jointRotations["L_Elbow"] = rotationBetweenKeypoints(lElbow, lWrist, restDir: SIMD3(1, 0, 0))

        // Right arm chain
        let rElbow = kps[8]
        let rWrist = kps[10]
        jointRotations["R_Shoulder"] = rotationBetweenKeypoints(rightShoulder, rElbow, restDir: SIMD3(-1, 0, 0))
        jointRotations["R_Elbow"] = rotationBetweenKeypoints(rElbow, rWrist, restDir: SIMD3(-1, 0, 0))

        // Left leg chain
        let lKnee = kps[13]
        let lAnkle = kps[15]
        jointRotations["L_Hip"] = rotationBetweenKeypoints(leftHip, lKnee, restDir: SIMD3(0, 1, 0))
        jointRotations["L_Knee"] = rotationBetweenKeypoints(lKnee, lAnkle, restDir: SIMD3(0, 1, 0))

        // Right leg chain
        let rKnee = kps[14]
        let rAnkle = kps[16]
        jointRotations["R_Hip"] = rotationBetweenKeypoints(rightHip, rKnee, restDir: SIMD3(0, 1, 0))
        jointRotations["R_Knee"] = rotationBetweenKeypoints(rKnee, rAnkle, restDir: SIMD3(0, 1, 0))

        // Head: nose relative to shoulder midpoint
        let nose = kps[0]
        jointRotations["Head"] = rotationBetweenKeypoints(
            DWPoseTracker.Keypoint(x: shoulderMid.x, y: shoulderMid.y, confidence: 1),
            nose,
            restDir: SIMD3(0, -1, 0)
        )

        // Extract face blend shapes from face keypoints (simplified)
        var blendShapes: [String: Float] = [:]
        if detection.faceKeypoints.count >= 68 {
            blendShapes = estimateFaceBlendShapes(from: Array(detection.faceKeypoints))
        }

        return UnifiedPoseFrame(
            timestamp: detection.timestamp,
            rootPosition: rootPosition,
            rootRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            jointRotations: jointRotations,
            blendShapes: blendShapes
        )
    }

    /// Compute a rotation quaternion from one keypoint to another.
    private static func rotationBetweenKeypoints(
        _ from: DWPoseTracker.Keypoint,
        _ to: DWPoseTracker.Keypoint,
        restDir: SIMD3<Float>
    ) -> simd_quatf {
        let limbDir = SIMD3<Float>(to.x - from.x, to.y - from.y, 0)
        return rotationFromLimbVector(from: .zero, to: limbDir, restDirection: restDir)
    }

    /// Compute the rotation that transforms `restDirection` to point along `to - from`.
    private static func rotationFromLimbVector(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        restDirection: SIMD3<Float>
    ) -> simd_quatf {
        let dir = to - from
        let len = simd_length(dir)
        guard len > 0.001 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let normalizedDir = dir / len
        let normalizedRest = simd_normalize(restDirection)

        let dot = simd_dot(normalizedRest, normalizedDir)
        if dot > 0.9999 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        if dot < -0.9999 {
            // 180 degree rotation — pick an arbitrary perpendicular axis
            let perp = abs(normalizedRest.x) < 0.9
                ? simd_normalize(simd_cross(normalizedRest, SIMD3(1, 0, 0)))
                : simd_normalize(simd_cross(normalizedRest, SIMD3(0, 1, 0)))
            return simd_quatf(angle: .pi, axis: perp)
        }

        let axis = simd_normalize(simd_cross(normalizedRest, normalizedDir))
        let angle = acos(max(-1, min(1, dot)))
        return simd_quatf(angle: angle, axis: axis)
    }

    /// Estimate basic face blend shapes from 68 face landmark keypoints.
    /// Uses distances between landmarks to approximate mouth open, smile, etc.
    private static func estimateFaceBlendShapes(
        from landmarks: [DWPoseTracker.Keypoint]
    ) -> [String: Float] {
        var shapes: [String: Float] = [:]

        // Mouth landmarks (indices from 68-point face model):
        // 48-59: outer lip, 60-67: inner lip
        guard landmarks.count >= 68 else { return shapes }

        // Adjust indices for 0-based within face region (face starts at kp 23)
        // Standard 68-point: mouth outer = 48-59, inner = 60-67

        // Jaw open: distance between upper and lower inner lip
        let upperLip = landmarks[62]  // top of inner upper lip
        let lowerLip = landmarks[66]  // bottom of inner lower lip
        let mouthOpen = abs(lowerLip.y - upperLip.y)

        // Mouth width: distance between mouth corners
        let leftCorner = landmarks[48]
        let rightCorner = landmarks[54]
        let mouthWidth = abs(rightCorner.x - leftCorner.x)

        // Face width for normalization (outer eye corners)
        let leftEye = landmarks[36]
        let rightEye = landmarks[45]
        let faceWidth = max(0.01, abs(rightEye.x - leftEye.x))

        shapes["jawOpen"] = min(1, mouthOpen / faceWidth * 3)
        shapes["mouthStretchLeft"] = min(1, mouthWidth / faceWidth * 1.2)
        shapes["mouthStretchRight"] = min(1, mouthWidth / faceWidth * 1.2)

        return shapes
    }
}
```

**Build verify.**

---

## Step 7.10 — CaptureSession: DWPose tracker toggle (4 min)

**File:** `Capture/CaptureSession.swift`

Add support for swapping between the default Vision body tracker and the optional DWPose tracker:

```swift
// Add a tracking mode enum:
enum TrackingMode: String, Sendable {
    case standard   // Apple Vision framework (fast, 3D)
    case enhanced   // DWPose Core ML (slower, 133 keypoints)
}

// Add property to CaptureSession:
var trackingMode: TrackingMode = .standard

/// The active DWPose tracker (lazy-loaded, nil if not in enhanced mode).
private var dwPoseTracker: DWPoseTracker?

/// Switch tracking mode. Enhanced mode loads the DWPose model on first use.
func setTrackingMode(_ mode: TrackingMode) throws {
    trackingMode = mode
    if mode == .enhanced && dwPoseTracker == nil {
        dwPoseTracker = try DWPoseTracker()
    }
}
```

In the frame processing loop (where `VisionBodyTracker.detect()` is called), add a branch:

```swift
// In the per-frame processing method:
let poseFrame: UnifiedPoseFrame
switch trackingMode {
case .standard:
    let bodyPose = try await bodyTracker.detect(in: pixelBuffer, at: timestamp)
    let facePose = try await faceTracker.detect(in: pixelBuffer, at: timestamp)
    poseFrame = UnifiedPoseFrame.merge(body: bodyPose, face: facePose, timestamp: timestamp)

case .enhanced:
    guard let dwPose = dwPoseTracker else {
        // Fallback to standard
        let bodyPose = try await bodyTracker.detect(in: pixelBuffer, at: timestamp)
        let facePose = try await faceTracker.detect(in: pixelBuffer, at: timestamp)
        poseFrame = UnifiedPoseFrame.merge(body: bodyPose, face: facePose, timestamp: timestamp)
        break
    }
    let detection = try await dwPose.detect(in: pixelBuffer, at: timestamp)
    poseFrame = DWPoseConverter.convert(detection)
}
```

**Build verify.**

---

## Step 7.11 — Capture settings UI: Enhanced Tracking toggle (3 min)

**File:** `Capture/CaptureSettingsView.swift` (new or add to existing capture UI)

```swift
import SwiftUI

@available(macOS 26.0, *)
struct CaptureSettingsView: View {
    @Environment(AnimateStore.self) private var store
    @State private var useEnhancedTracking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Settings")
                .font(.headline)

            Toggle("Enhanced Tracking (slower)", isOn: $useEnhancedTracking)
                .help("Uses DWPose model for 133-keypoint whole-body tracking including hands and face. Requires DWPose.mlmodelc in the app bundle.")
                .onChange(of: useEnhancedTracking) { _, newValue in
                    do {
                        let mode: CaptureSession.TrackingMode = newValue ? .enhanced : .standard
                        try store.captureSession?.setTrackingMode(mode)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                        useEnhancedTracking = false
                    }
                }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if useEnhancedTracking {
                Text("133 keypoints: body + hands + face")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Standard: Apple Vision 3D body + face tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
```

**Build verify. Commit: "Phase 7.3: DWPose Core ML tracker + enhanced tracking toggle"**

---

## Step 7.12 — DWPose Core ML model conversion script (3 min)

**File:** `Scripts/convert_dwpose_coreml.py` (new, utility script, not Swift)

```python
#!/usr/bin/env python3
"""
Convert DWPose ONNX model to Core ML format.

Prerequisites:
    pip install coremltools onnx

Usage:
    python3 convert_dwpose_coreml.py path/to/dwpose.onnx

Outputs DWPose.mlpackage in the current directory.
The .mlpackage should then be added to the Xcode project
and will compile to DWPose.mlmodelc at build time.
"""

import sys
import coremltools as ct

def convert(onnx_path: str):
    model = ct.converters.convert(
        onnx_path,
        source="onnx",
        inputs=[ct.ImageType(name="image", shape=(1, 3, 384, 288), scale=1/255.0)],
        minimum_deployment_target=ct.target.macOS15,
    )

    # Set metadata
    model.author = "Amira Writer"
    model.short_description = "DWPose whole-body keypoint detector (133 keypoints)"
    model.input_description["image"] = "Input image (384x288 RGB)"

    output_path = "DWPose.mlpackage"
    model.save(output_path)
    print(f"Saved Core ML model to {output_path}")
    print("Add this to your Xcode project. It will compile to DWPose.mlmodelc.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path-to-dwpose.onnx>")
        sys.exit(1)
    convert(sys.argv[1])
```

**Build verify (Swift only). Final commit: "Phase 7.4: DWPose Core ML conversion script"**

---

## Summary of All New/Modified Files

### Phase 5 (HunyuanMotion -> MotionClip)
| File | Action |
|------|--------|
| `Motion/MotionClip.swift` | Add `.hunyuanMotion(prompt:)` source case |
| `Services/FBXMotionClipLoader.swift` | Add `toNLAMotionClip()` bridge method |
| `Services/HunyuanMotionService.swift` | Add `generateMotionClip()` convenience |
| `AnimateStore.swift` | Add `addMotionClipToTimeline()` |
| `Views/MotionGenerationPane.swift` | New — "Send to Timeline" button UI |

### Phase 6 (Import/Export + Polish)
| File | Action |
|------|--------|
| `Motion/MotionClip.swift` | Add `.videoImport(url:)` source case |
| `Capture/VideoMotionExtractor.swift` | New — AVAssetReader frame extraction + tracking |
| `AnimateStore.swift` | Add `importVideoToTimeline()`, `exportClipAsBVH()`, `setClipSpeed()` |
| `NLA/NLATimelineView.swift` | Add `.onDrop`, crossfade overlay, keyboard shortcuts, context menu, zoom/scroll |
| `Motion/BVHExporter.swift` | New — MotionClip -> BVH file export |

### Phase 7 (Audio Lip Sync + Enhanced Tracking)
| File | Action |
|------|--------|
| `Motion/MotionClip.swift` | Add `.audioLipSync` source case |
| `Capture/AudioVisemeClassifier.swift` | New — real-time spectral audio -> viseme weights |
| `Capture/VisemeToBlendShapeMapper.swift` | New — Preston Blair -> ARKit blend shapes |
| `Capture/AudioLipSyncRecorder.swift` | New — records audio visemes to MotionClip |
| `AnimateStore.swift` | Add audio lip sync recording + lip sync track placement |
| `Engine/CharacterMouthEngine.swift` | Add NLA blend shape integration path, `nlaBlendShapes` param |
| `Services/LipSyncEngine.swift` | Add `generateFromAudioWeights()` |
| `Capture/DWPoseTracker.swift` | New — Core ML DWPose 133-keypoint detection |
| `Capture/DWPoseConverter.swift` | New — DWPose keypoints -> UnifiedPoseFrame |
| `Capture/CaptureSession.swift` | Add `TrackingMode` enum + DWPose toggle |
| `Capture/CaptureSettingsView.swift` | New — enhanced tracking toggle UI |
| `Scripts/convert_dwpose_coreml.py` | New — ONNX -> Core ML conversion utility |

### Commit Sequence
1. **Phase 5:** "Phase 5: HunyuanMotion FBX -> MotionClip bridge + Send to Timeline"
2. **Phase 6.1:** "Phase 6.1: Video file import via drag-and-drop to NLA timeline"
3. **Phase 6.2:** "Phase 6.2: BVH export from MotionClip"
4. **Phase 6.3:** "Phase 6.3: Crossfade viz, keyboard shortcuts, speed, zoom/scroll"
5. **Phase 7.1:** "Phase 7.1: Audio viseme classifier + lip sync recorder + timeline placement"
6. **Phase 7.2:** "Phase 7.2: CharacterMouthEngine NLA blend shape integration + LipSyncEngine audio mode"
7. **Phase 7.3:** "Phase 7.3: DWPose Core ML tracker + enhanced tracking toggle"
8. **Phase 7.4:** "Phase 7.4: DWPose Core ML conversion script"
