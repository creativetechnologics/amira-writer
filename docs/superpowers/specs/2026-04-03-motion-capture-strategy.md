# Motion Capture Integration — Strategy & Implementation Plan

> **For agentic workers:** This is a research-backed strategy document. Use it as the foundation for brainstorming sessions and implementation planning. The document covers feasibility analysis, technology selection, architecture design, and phased implementation roadmap.

**Goal:** Add webcam-based and video-file-based motion capture to Amira Writer's animation pipeline, capturing face expressions, body movement, and lip sync — then blending that data with existing AI-generated motion (HunyuanMotion) on a layered timeline.

**Date:** 2026-04-03

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Feasibility Assessment](#2-feasibility-assessment)
3. [Technology Selection](#3-technology-selection)
4. [Existing Architecture Integration Points](#4-existing-architecture-integration-points)
5. [System Architecture](#5-system-architecture)
6. [Data Model Design](#6-data-model-design)
7. [Motion Layering & Blending Engine](#7-motion-layering--blending-engine)
8. [Capture Pipeline](#8-capture-pipeline)
9. [Retargeting Pipeline](#9-retargeting-pipeline)
10. [Timeline UI Design](#10-timeline-ui-design)
11. [Performance Budget](#11-performance-budget)
12. [Phased Implementation Roadmap](#12-phased-implementation-roadmap)
13. [Risk Assessment](#13-risk-assessment)
14. [Technology Reference](#14-technology-reference)

---

## 1. Executive Summary

**Verdict: Fully feasible on macOS with Apple Silicon, using a hybrid of native Apple frameworks and bridged open-source AI models.**

The core insight is that Apple's Vision framework provides real-time 3D body pose estimation (17 joints) natively in Swift, while Google's MediaPipe provides 52 ARKit-compatible facial blend shape weights from an ordinary RGB webcam — no TrueDepth sensor required. Combined with the existing HunyuanMotion FBX pipeline and SceneKit's SCNMorpher blend shape system already wired into Amira Writer, a complete motion capture solution can be built with:

- **Zero proprietary hardware** — standard MacBook/iMac webcam or any USB camera
- **Real-time face + body tracking** at 30+ FPS on Apple Silicon
- **Direct compatibility** with the existing CharacterPerformanceProfile morph weight system
- **Layered motion mixing** using an NLA-inspired timeline where mocap data can selectively override AI-generated motion per body part

The recommended approach uses a **three-tier capture stack**:
1. **Apple Vision** (native Swift) — 3D body pose, hand pose, real-time, zero dependencies
2. **MediaPipe Face Landmarker** (C++ bridge) — 52 ARKit blend shapes from webcam, real-time
3. **Core ML pose models** (converted RTMPose/DWPose) — higher-fidelity whole-body when needed

All three tiers feed into a unified **MotionClip** format that sits on a new **NLA-style motion timeline**, where clips from any source (live mocap, AI-generated FBX, imported BVH) can be layered, blended, and masked per body region.

---

## 2. Feasibility Assessment

### 2.1 Face Tracking — HIGH Feasibility

| Approach | Landmarks | Blend Shapes | FPS (M1+) | macOS Native | Dependencies |
|----------|-----------|-------------|-----------|-------------|-------------|
| Apple Vision VNDetectFaceLandmarks | 76 2D points | None (raw points only) | 60+ | Yes | None |
| MediaPipe Face Landmarker | 478 3D points | **52 ARKit-compatible** | 30+ | C++ bridge | mediapipe lib |
| DECA/EMOCA (FLAME) | FLAME mesh | Requires conversion | 1-2/sec | Core ML | Model weights |

**Winner: MediaPipe Face Landmarker.** It directly outputs the 52 ARKit blend shape coefficients (browDownLeft, eyeBlinkLeft, jawOpen, mouthSmileLeft, etc.) from an ordinary RGB camera. These map 1:1 to the morph target names that SceneKit's SCNMorpher uses, and directly into Amira Writer's existing `CharacterPerformanceProfile.morphWeights` system.

Apple Vision's face landmarks give only 76 raw 2D points with no blend shape decomposition — you'd need a custom ML model to convert those to blend shapes, which MediaPipe already does better.

### 2.2 Body Tracking — HIGH Feasibility

| Approach | Joints | 3D? | FPS (M1+) | macOS Native | Dependencies |
|----------|--------|-----|-----------|-------------|-------------|
| Apple Vision VNDetectHumanBodyPose3D | 17 | Yes (meters) | 30+ | Yes | None |
| Apple Vision VNDetectHumanBodyPose | 19 | 2D only | 60+ | Yes | None |
| MediaPipe Pose (BlazePose) | 33 | Yes | 15-30 | C++ bridge | mediapipe lib |
| RTMPose (Core ML) | 17-133 | 2D, lift to 3D | 30-90+ | Core ML | Converted model |
| DWPose (Core ML) | 133 (whole-body) | 2D, lift to 3D | 10-20 | Core ML | Converted model |

**Winner: Apple Vision VNDetectHumanBodyPose3DRequest (primary) + RTMPose/DWPose Core ML (enhanced).**

Apple Vision gives 17 calibrated 3D joints in real-world meters with zero dependencies — ideal for the fast path. For productions needing finger tracking or higher fidelity, DWPose provides 133 whole-body keypoints (body + hands + face) that can be lifted to 3D via MotionBERT.

**Joint coverage for Apple Vision 3D body pose (17 joints):**
- Head: top, left/right ear
- Torso: center shoulder, spine, root (hips)
- Arms: left/right shoulder, elbow, wrist
- Legs: left/right hip, knee, ankle

This maps well to the existing `PartType` enum in AnimateModels.swift and to standard humanoid skeleton rigs (Mixamo, SMPL-H) that HunyuanMotion outputs.

### 2.3 Lip Sync from Motion Capture — HIGH Feasibility

Two complementary paths:

1. **Visual lip tracking** — MediaPipe's 52 blend shapes include all mouth shapes: jawOpen, jawForward, mouthFunnel, mouthPucker, mouthLeft, mouthRight, mouthSmileLeft/Right, mouthStretchLeft/Right, mouthClose, etc. These are sufficient for high-quality lip sync from video.

2. **Audio-driven lip sync** — The existing VisemeBlendEngine (Preston Blair 10 visemes) can be extended to output ARKit blend shape weights instead of/in addition to viseme tokens. A lightweight audio-to-viseme Core ML model would be ~1MB and run at 60+ FPS.

Both paths produce the same output format (blend shape weight arrays), so they naturally compose — use audio-driven as the base layer, visual tracking as override for higher fidelity when webcam is available.

### 2.4 Motion Mixing — HIGH Feasibility

The existing codebase already has the foundational pieces:
- `TimelineTrack` with `KeyframeValue` enum supports arbitrary data per frame
- `AnimationEngine` evaluates tracks at a given frame with interpolation
- `FBXMotionClipLoader` already loads HunyuanMotion FBX with SMPL-H and Mixamo joint mapping
- `CharacterPerformanceProfile` applies morph weights to SCNNode morpher targets
- `ScenePreviewRenderer` renders SceneKit scenes with bone transforms and morph weights

What's missing is a **layer-aware evaluation system** (NLA) that can blend multiple motion sources per body region. This is a data model addition, not an architectural rewrite.

### 2.5 ARKit Face Tracking on Mac — NOT Available

ARKit's `ARFaceTrackingConfiguration` requires a TrueDepth camera (Face ID sensor), which exists only on iPhone X+ and iPad Pro. **No Mac has a TrueDepth camera.** ARKit face tracking is not available on macOS.

This is why MediaPipe is the correct choice — it achieves the same 52 blend shape output from an ordinary RGB webcam using a trained neural network rather than structured light depth sensing.

---

## 3. Technology Selection

### 3.1 Final Technology Stack

```
┌─────────────────────────────────────────────────────────────┐
│                    CAPTURE TIER                              │
│                                                              │
│  ┌──────────────┐  ┌──────────────────┐  ┌───────────────┐  │
│  │ Apple Vision │  │ MediaPipe Face   │  │ Core ML Pose  │  │
│  │ Body Pose 3D │  │ Landmarker (C++) │  │ (RTMPose/     │  │
│  │ 17 joints    │  │ 52 blend shapes  │  │  DWPose)      │  │
│  │ Native Swift │  │ 478 face points  │  │ 133 keypoints │  │
│  └──────┬───────┘  └────────┬─────────┘  └───────┬───────┘  │
│         │                   │                     │          │
│         └───────────┬───────┴─────────────────────┘          │
│                     ▼                                        │
│           ┌─────────────────┐                                │
│           │ UnifiedPoseFrame│  ← normalized intermediate     │
│           │ body + face +   │    format, source-agnostic     │
│           │ hands + mouth   │                                │
│           └────────┬────────┘                                │
└────────────────────┼────────────────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                  PROCESSING TIER                             │
│                                                              │
│  ┌──────────────────┐  ┌─────────────────┐                  │
│  │ Motion Retarget  │  │ Temporal Filter │                  │
│  │ IK-based mapping │  │ Kalman/OneEuro  │                  │
│  │ proportion-aware │  │ jitter removal  │                  │
│  └────────┬─────────┘  └────────┬────────┘                  │
│           └─────────┬───────────┘                            │
│                     ▼                                        │
│           ┌─────────────────┐                                │
│           │   MotionClip    │  ← serializable animation     │
│           │ joint rotations │    data, any source            │
│           │ + blend shapes  │                                │
│           │ + metadata      │                                │
│           └────────┬────────┘                                │
└────────────────────┼────────────────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                   TIMELINE TIER                              │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐   │
│  │              NLA Motion Timeline                      │   │
│  │                                                       │   │
│  │  Track 0 (Base): [AI Motion FBX clip ───────────]    │   │
│  │  Track 1 (Face): [MediaPipe face capture ────]       │   │
│  │  Track 2 (Arms): [    Webcam arm override ──]        │   │
│  │  Track 3 (Lips): [Audio viseme ─────────────────]    │   │
│  │                                                       │   │
│  │  Each track: blend mode + body mask + influence       │   │
│  └───────────────────────────────────┬───────────────────┘   │
│                                      ▼                       │
│                        ┌─────────────────────┐               │
│                        │ Blended Pose Output │               │
│                        │ per-frame evaluation│               │
│                        └──────────┬──────────┘               │
└───────────────────────────────────┼──────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────┐
│                   APPLICATION TIER                           │
│                                                              │
│  ┌──────────────────────┐  ┌──────────────────────────────┐  │
│  │ ScenePreviewRenderer │  │ CharacterPerformanceProfile  │  │
│  │ SCNNode bone xforms  │  │ SCNMorpher blend weights     │  │
│  │ (existing)           │  │ (existing)                   │  │
│  └──────────────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Why Not RealityKit?

The motion mixing research strongly recommends RealityKit for new projects (SceneKit is in maintenance mode as of WWDC 2025). However, Amira Writer's 3D preview is already built on SceneKit (`ScenePreviewRenderer`, `CelShadingTechnique`, `SceneAssetPipeline`). A migration to RealityKit is a separate, larger effort. The motion capture system should be designed with a **renderer-agnostic data layer** so it works with SceneKit today and RealityKit in the future.

The `MotionClip` format and NLA timeline evaluate to abstract joint transforms + blend shape weights. The renderer adapter (`Animate3DSceneAdapter`) then applies these to whichever renderer is active.

### 3.3 MediaPipe Integration Strategy

MediaPipe has no Swift API. Three integration options:

| Option | Latency | Complexity | Maintenance |
|--------|---------|------------|-------------|
| **A. C++ bridge via Swift-C++ interop** | <1ms | Medium | Low |
| B. Python subprocess + IPC | 5-15ms | Low | Medium |
| C. Objective-C++ wrapper | <1ms | Medium | Low |

**Recommended: Option A — Swift-C++ interop.** Swift 5.9+ has direct C++ interop. MediaPipe's core is C++. Build MediaPipe as a static library, expose a thin C++ API (`FaceTracker::track(pixelBuffer:) -> BlendShapeResult`), and call it directly from Swift. Zero serialization overhead, sub-millisecond bridge latency.

Fallback: Option C (Objective-C++ wrapper) if Swift-C++ interop causes issues with MediaPipe's Bazel build system.

---

## 4. Existing Architecture Integration Points

### 4.1 Where Mocap Data Enters the Pipeline

The existing data flow is:

```
SceneProductionCompiler → CharacterBlockingPlan → keyPositions/actingBeats/lipsyncBeats
    ↓
CharacterExpressionEngine.evaluate(at: frame) → CharacterExpressionState
CharacterMouthEngine.evaluate(at: frame) → CharacterMouthState
    ↓
Character3DPerformanceProfile.applyMorphWeights() → SCNMorpher targets
FBXMotionClipLoader → SCNAnimationPlayer → bone transforms
```

**Mocap injection points:**

1. **Face expressions:** `CharacterExpressionEngine` already has a "live cue override" path (checked first before falling back to blocking plan). Mocap blend shapes inject here — they become the live cue.

2. **Mouth/lip sync:** `CharacterMouthEngine` also has a "live viseme cue override" path. Mocap mouth blend shapes (jawOpen, mouthFunnel, etc.) inject here.

3. **Body motion:** `FBXMotionClipLoader` loads HunyuanMotion FBX clips. Mocap body motion produces the same format (joint rotations keyed by bone name) and feeds through the same `SCNAnimationPlayer` path — or the new NLA evaluator replaces both.

4. **Timeline data:** `TimelineTrack` with `KeyframeValue` is extensible. New cases for `.motionPose(MotionPoseSnapshot)` and `.blendShapes([String: Double])` would store captured data as keyframes.

### 4.2 Existing Assets That Accelerate This Work

| Existing Component | What It Provides | How Mocap Uses It |
|---|---|---|
| `FBXMotionClipLoader` | SMPL-H + Mixamo joint name mapping, FBX→SCNAnimation | Same retargeting maps for mocap→rig |
| `Character3DPerformanceProfile` | Node names (headNodeName, jawNodeName, etc.) + morphWeights | Direct target for mocap blend shapes |
| `EmotionLibrary` | 30+ expression presets with parametric values | Fallback/blend targets for expression |
| `VisemeBlendEngine` | Co-articulation interpolation, anticipation weights | Smooth lip sync from any source |
| `AnimationEngine` | Track evaluation with easing/interpolation | Foundation for NLA evaluator |
| `Animate3DSceneAdapter` | frameSnapshot() pipeline | Bridge from NLA output to renderer |
| `CADisplayLink` in AnimateStore | Real-time playback tick | Drives live mocap preview |
| `AVFoundation` (VideoExporter) | Video encoding pipeline | Record webcam + export mocap |

### 4.3 File Format Compatibility

HunyuanMotion outputs FBX. Mocap captures produce joint rotations + blend shapes. Both convert to the same `MotionClip` intermediate format:

```
HunyuanMotion FBX → FBXMotionClipLoader → MotionClip
Webcam Mocap → UnifiedPoseFrame → Retargeter → MotionClip
Imported BVH → BVHParser → MotionClip
Imported FBX → FBXMotionClipLoader → MotionClip
```

---

## 5. System Architecture

### 5.1 New Modules

```
Packages/Animate/Sources/AnimateUI/
├── Capture/
│   ├── CaptureSession.swift            — AVCaptureSession + frame distribution
│   ├── VisionBodyTracker.swift          — Apple Vision 3D body pose
│   ├── MediaPipeFaceTracker.swift       — MediaPipe blend shapes (C++ bridge)
│   ├── UnifiedPoseFrame.swift           — Source-agnostic pose snapshot
│   ├── TemporalFilter.swift             — OneEuro/Kalman jitter filter
│   └── CapturePreviewView.swift         — Live webcam + skeleton overlay UI
│
├── Motion/
│   ├── MotionClip.swift                 — Serializable motion data container
│   ├── MotionRetargeter.swift           — IK-based skeleton retargeting
│   ├── MotionRecorder.swift             — Records UnifiedPoseFrames → MotionClip
│   ├── BVHParser.swift                  — BVH file import
│   └── MotionClipExporter.swift         — Export to BVH/FBX/USD
│
├── NLA/
│   ├── NLATimeline.swift                — Track/clip/layer data model
│   ├── NLAEvaluator.swift               — Per-frame blended pose evaluation
│   ├── BodyPartMask.swift               — Joint group masks for per-region override
│   └── NLATimelineView.swift            — Timeline UI with tracks, clips, blend zones
│
├── Bridge/
│   ├── MediaPipeBridge/                 — C++/ObjC++ wrapper for MediaPipe
│   │   ├── FaceTrackerBridge.h
│   │   ├── FaceTrackerBridge.mm
│   │   └── module.modulemap
```

### 5.2 Module Dependencies

```
CaptureSession
    ├── VisionBodyTracker (Apple Vision)
    ├── MediaPipeFaceTracker (MediaPipe C++ bridge)
    └── outputs → UnifiedPoseFrame
                     ↓
              TemporalFilter (smoothing)
                     ↓
              MotionRecorder → MotionClip (saved to disk)
                                    ↓
                              NLATimeline (clips on tracks)
                                    ↓
                              NLAEvaluator (per-frame blend)
                                    ↓
                              Animate3DSceneAdapter (existing)
                                    ↓
                              ScenePreviewRenderer (existing)
```

---

## 6. Data Model Design

### 6.1 UnifiedPoseFrame — Raw Capture Output

```swift
/// A single frame of motion capture data from any source, before retargeting.
struct UnifiedPoseFrame: Codable, Sendable {
    let timestamp: TimeInterval
    let source: CaptureSource
    
    /// Body joint positions in normalized coordinates (0-1 range, hip-centered)
    let bodyJoints: [JointName: SIMD3<Float>]?
    
    /// Body joint confidences (0-1)
    let bodyConfidences: [JointName: Float]?
    
    /// Hand joint positions (21 per hand)
    let leftHandJoints: [HandJointName: SIMD3<Float>]?
    let rightHandJoints: [HandJointName: SIMD3<Float>]?
    
    /// Face blend shape weights (ARKit-compatible 52 shapes)
    let faceBlendShapes: [BlendShapeName: Float]?
    
    /// Face landmark positions (for visualization)
    let faceLandmarks: [SIMD2<Float>]?
    
    enum CaptureSource: String, Codable {
        case appleVision
        case mediaPipe
        case coreMLPose
        case imported
    }
}

/// Standard joint names matching SMPL-H / Apple Vision / Mixamo
enum JointName: String, Codable, CaseIterable {
    case root, hips, spine, chest, neck, head
    case leftShoulder, leftElbow, leftWrist
    case rightShoulder, rightElbow, rightWrist
    case leftHip, leftKnee, leftAnkle
    case rightHip, rightKnee, rightAnkle
    // Extended (from DWPose/MediaPipe when available)
    case leftEar, rightEar, nose
    case leftToe, rightToe
}

/// ARKit-compatible blend shape names
enum BlendShapeName: String, Codable, CaseIterable {
    case browDownLeft, browDownRight, browInnerUp
    case browOuterUpLeft, browOuterUpRight
    case cheekPuff, cheekSquintLeft, cheekSquintRight
    case eyeBlinkLeft, eyeBlinkRight
    case eyeLookDownLeft, eyeLookDownRight
    case eyeLookInLeft, eyeLookInRight
    case eyeLookOutLeft, eyeLookOutRight
    case eyeLookUpLeft, eyeLookUpRight
    case eyeSquintLeft, eyeSquintRight
    case eyeWideLeft, eyeWideRight
    case jawForward, jawLeft, jawOpen, jawRight
    case mouthClose, mouthDimpleLeft, mouthDimpleRight
    case mouthFrownLeft, mouthFrownRight
    case mouthFunnel, mouthLeft, mouthRight
    case mouthLowerDownLeft, mouthLowerDownRight
    case mouthPressLeft, mouthPressRight
    case mouthPucker, mouthRollLower, mouthRollUpper
    case mouthShrugLower, mouthShrugUpper
    case mouthSmileLeft, mouthSmileRight
    case mouthStretchLeft, mouthStretchRight
    case mouthUpperUpLeft, mouthUpperUpRight
    case noseSneerLeft, noseSneerRight
    case tongueOut
}
```

### 6.2 MotionClip — Serializable Animation Data

```swift
/// A recorded or imported motion clip, ready for timeline placement.
/// Source-agnostic — can come from webcam capture, AI generation, or file import.
struct MotionClip: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let source: MotionClipSource
    let fps: Int                            // capture frame rate
    let frameCount: Int
    let duration: TimeInterval
    
    /// Per-frame joint rotations (local space, relative to parent bone)
    /// Keyed by joint name, each value is [quaternion per frame]
    var jointRotations: [String: [SIMD4<Float>]]
    
    /// Per-frame root position (world space translation)
    var rootPositions: [SIMD3<Float>]
    
    /// Per-frame face blend shape weights
    /// Keyed by ARKit blend shape name, each value is [weight per frame]
    var blendShapeWeights: [String: [Float]]
    
    /// Metadata
    var createdAt: Date
    var tags: [String]
    var characterSlug: String?              // which character this was captured for
    
    enum MotionClipSource: Codable {
        case webcamCapture(sessionID: UUID)
        case videoFileCapture(fileURL: String)
        case hunyuanMotion(prompt: String)
        case importedBVH(filePath: String)
        case importedFBX(filePath: String)
        case manual                         // hand-keyed in timeline
    }
}
```

### 6.3 NLA Timeline Data Model

```swift
/// Non-linear animation timeline for motion mixing.
struct NLATimeline: Codable, Sendable {
    var tracks: [NLATrack]
    var duration: TimeInterval              // total timeline length
    var fps: Int                            // evaluation frame rate
}

struct NLATrack: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var blendMode: NLABlendMode
    var bodyMask: BodyPartMask              // which joints this track controls
    var influence: Float                    // 0.0-1.0, global track weight
    var muted: Bool
    var solo: Bool
    var clips: [NLAClip]
    var sortOrder: Int                      // bottom = 0, evaluated first
}

struct NLAClip: Codable, Identifiable, Sendable {
    let id: UUID
    var motionClipID: UUID                  // reference to MotionClip
    var startFrame: Int                     // position on timeline
    var speed: Float                        // playback speed multiplier
    var trimStartFrame: Int                 // clip-local trim
    var trimEndFrame: Int                   // clip-local trim
    var blendInFrames: Int                  // crossfade in duration
    var blendOutFrames: Int                 // crossfade out duration
    var influence: Float                    // per-clip weight (multiplied with track)
}

enum NLABlendMode: String, Codable {
    case replace                            // overrides lower layers
    case additive                           // adds to lower layers
    case override                           // replaces only where mask matches
}

/// Defines which body parts a track controls.
struct BodyPartMask: Codable, OptionSet, Sendable {
    let rawValue: UInt32
    
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
    
    static let fullBody: BodyPartMask = [.head, .neck, .spine, .leftArm, .rightArm,
                                          .leftHand, .rightHand, .hips, .leftLeg,
                                          .rightLeg, .leftFoot, .rightFoot]
    static let upperBody: BodyPartMask = [.head, .neck, .spine, .leftArm, .rightArm,
                                           .leftHand, .rightHand]
    static let lowerBody: BodyPartMask = [.hips, .leftLeg, .rightLeg, .leftFoot, .rightFoot]
    static let faceAndMouth: BodyPartMask = [.face, .mouth]
    static let arms: BodyPartMask = [.leftArm, .rightArm, .leftHand, .rightHand]
    static let everything: BodyPartMask = [.fullBody, .face, .mouth]
}
```

### 6.4 Storage Layout

```
<project>.owp/
├── Animate/
│   ├── motion-clips/
│   │   ├── clip-<uuid>.json           — MotionClip metadata + joint data
│   │   └── clip-<uuid>.bvh            — Optional BVH export
│   ├── motion-timeline.json           — NLATimeline per scene
│   ├── capture-recordings/
│   │   ├── rec-<uuid>.mov             — Raw webcam video (reference)
│   │   └── rec-<uuid>-poses.json      — UnifiedPoseFrame stream
│   └── scenes.json                    — Existing (unchanged)
```

---

## 7. Motion Layering & Blending Engine

### 7.1 Evaluation Algorithm

The NLA evaluator runs once per frame, walking tracks bottom-to-top:

```
Input: NLATimeline, currentFrame: Int
Output: BlendedPose (joint rotations + blend shape weights)

1. Initialize accumulatedPose = restPose (identity rotations, zero blend shapes)
2. For each track in timeline.tracks (sorted by sortOrder ascending):
   a. If track.muted → skip
   b. Find active clip at currentFrame (accounting for clip.startFrame, trim, speed)
   c. If no active clip → skip
   d. Sample the clip's MotionClip at the effective frame
   e. Apply clip.blendIn/blendOut ramps → compute effectiveInfluence
   f. Multiply by track.influence → finalWeight
   g. Filter sampled pose through track.bodyMask (zero out non-masked joints)
   h. Blend into accumulatedPose:
      - Replace: accPose[joint] = lerp(accPose[joint], sample[joint], finalWeight)
      - Additive: accPose[joint] = accPose[joint] + sample[joint] * finalWeight
      - Override: accPose[joint] = sample[joint] where mask matches
   i. For quaternion rotation blending: use slerp, not lerp
   j. For blend shape weights: linear interpolation, clamp 0-1
3. Return accumulatedPose
```

### 7.2 Integration with Existing Engines

The NLA evaluator output replaces/augments the existing evaluation chain:

```
BEFORE (current):
  CharacterBlockingPlan → CharacterExpressionEngine → expressionState
  CharacterBlockingPlan → CharacterMouthEngine → mouthState
  FBXMotionClipLoader → SCNAnimationPlayer → bone transforms

AFTER (with mocap):
  NLAEvaluator.evaluate(at: frame) → BlendedPose
    ├── jointRotations → applied to SCNNode bone hierarchy
    └── blendShapeWeights → applied via CharacterPerformanceProfile.applyMorphWeights()
  
  Fallback: If NLATimeline has no tracks for this character,
            fall back to existing CharacterExpressionEngine/MouthEngine path
```

This is backward-compatible — scenes without motion clips work exactly as before.

### 7.3 Solo and Mute

Standard NLA behavior:
- **Mute:** Track is skipped during evaluation (grayed out in UI)
- **Solo:** Only solo'd tracks are evaluated; all others are implicitly muted. Multiple tracks can be solo'd simultaneously.

---

## 8. Capture Pipeline

### 8.1 AVCaptureSession Setup

```swift
/// Manages webcam capture and distributes frames to trackers.
@MainActor
final class CaptureSession: NSObject, ObservableObject {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.amira.capture", qos: .userInteractive)
    
    @Published var isCapturing = false
    @Published var currentPoseFrame: UnifiedPoseFrame?
    
    var bodyTracker: VisionBodyTracker?
    var faceTracker: MediaPipeFaceTracker?
    
    func startCapture(camera: AVCaptureDevice? = nil) throws {
        let device = camera ?? AVCaptureDevice.default(for: .video)
        // Configure 720p @ 30fps for optimal tracking/performance balance
        // Distribute CMSampleBuffer to body + face trackers in parallel
        // Merge results into UnifiedPoseFrame
    }
    
    func startFileCapture(url: URL) {
        // Use AVAssetReader for video file input
        // Process frames through same tracker pipeline
        // Run at video's native FPS or accelerated for offline processing
    }
}
```

### 8.2 Webcam Recording to Timeline

When the user records from webcam:
1. `CaptureSession` captures video frames via `AVCaptureSession`
2. Simultaneously saves raw video to `.mov` file (for reference playback)
3. Each frame → `VisionBodyTracker` + `MediaPipeFaceTracker` (parallel dispatch)
4. Results merged into `UnifiedPoseFrame` stream
5. `TemporalFilter` smooths jitter (OneEuro filter, configurable smoothing)
6. `MotionRecorder` accumulates frames → `MotionClip` on stop
7. `MotionClip` saved to project `motion-clips/` directory
8. User places clip on NLA timeline (auto-placed at playhead, or drag from library)

### 8.3 Video File Processing

Same pipeline as webcam, but:
- Input from `AVAssetReader` instead of `AVCaptureSession`
- Can process faster than real-time (no camera constraint)
- Progress bar shown during processing
- Option to use higher-quality offline models (DWPose, SMPL-X recovery)

### 8.4 Temporal Filtering

Raw pose estimation is noisy. Apply per-joint **OneEuro filter** (standard in mocap):
- Low-speed smoothing: β₀ = 0.5 (strong smoothing when joint is stationary)
- High-speed preservation: β₁ = 0.007 (minimal smoothing during fast movement)
- Derivative cutoff: d_cutoff = 1.0 Hz
- Each joint filtered independently
- Blend shapes filtered with lighter smoothing (β₀ = 0.3) to preserve quick expressions

---

## 9. Retargeting Pipeline

### 9.1 From Capture to Character Rig

The retargeting challenge: webcam captures a real person's pose, but the character rig has different proportions (shorter arms, bigger head, stylized body).

**Approach: Hybrid Rotation-Copy + IK Correction**

1. **Joint rotation extraction:** Convert 3D joint positions to local rotations using the captured skeleton's bone lengths. This gives rotation-space data that's proportion-independent.

2. **Direct rotation mapping:** Map rotations from capture joints to character rig joints using the existing `FBXMotionClipLoader`'s bone name mapping tables (SMPL-H → Mixamo → custom rig).

3. **IK correction pass:** For end-effectors (hands, feet), run IK to correct for proportion differences. If the character's arms are shorter, IK keeps the hands at physically correct positions rather than floating.

4. **Root motion:** Scale root translation by the ratio of character height to captured person height.

### 9.2 Joint Name Mapping

Already exists in `FBXMotionClipLoader`:
```
SMPL-H joints → Mixamo joints → Character rig joints
(from HunyuanMotion)   (standardized)   (per-character profile)
```

Apple Vision and MediaPipe joints map to SMPL-H with a straightforward lookup table (both use anatomical naming). The existing mapping infrastructure handles the rest.

### 9.3 Blend Shape Retargeting

MediaPipe outputs weights for 52 ARKit blend shapes. Character rigs may have:
- Same 52 shapes (direct pass-through)
- Subset of shapes (pass through what exists, ignore rest)
- Custom shape names (mapping table in `CharacterPerformanceProfile`)

The `CharacterPerformanceProfile` already has `morphWeights: [String: Double]` — extend it with an optional `blendShapeMapping: [String: String]` to map ARKit names to custom rig names when they differ.

---

## 10. Timeline UI Design

### 10.1 New Dock Tab: Motion

Add `motion` case to `AnimateWorkspaceDockTab`. The Motion tab contains:

```
┌─────────────────────────────────────────────────────────────┐
│ MOTION CAPTURE & MIXING                                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ ┌─ Capture ─────────────────────────────────────────────┐   │
│ │ [🎥 Start Webcam] [📂 Import Video] [📦 Import BVH]  │   │
│ │                                                        │   │
│ │ Preview: [Live webcam feed with skeleton overlay]      │   │
│ │          [Record] [Stop] [Discard]                     │   │
│ └────────────────────────────────────────────────────────┘   │
│                                                              │
│ ┌─ Motion Library ──────────────────────────────────────┐   │
│ │ ┌──────────┐ ┌──────────┐ ┌──────────┐               │   │
│ │ │ Webcam   │ │ HunyuanM │ │ Imported │               │   │
│ │ │ Rec #1   │ │ "walk"   │ │ dance.bvh│               │   │
│ │ │ 4.2s     │ │ 3.0s     │ │ 12.1s    │               │   │
│ │ │ Face+Body│ │ Body     │ │ Body     │               │   │
│ │ └──────────┘ └──────────┘ └──────────┘               │   │
│ │ Drag clips to timeline tracks below                    │   │
│ └────────────────────────────────────────────────────────┘   │
│                                                              │
│ ┌─ NLA Timeline ────────────────────────────────────────┐   │
│ │                                                        │   │
│ │ Track 0 [Body:Replace]  [▓▓▓▓▓▓ AI Walk ▓▓▓▓▓▓▓▓▓▓] │   │
│ │ Track 1 [Face:Override] [  ░░░ Webcam Face ░░░░░   ]  │   │
│ │ Track 2 [Arms:Override] [      ▒▒ Arm Fix ▒▒       ] │   │
│ │ Track 3 [Lips:Additive] [░░░░░░ Audio Sync ░░░░░░░░] │   │
│ │                                                        │   │
│ │ ▼ playhead                                             │   │
│ │ [+ Add Track]                                          │   │
│ └────────────────────────────────────────────────────────┘   │
│                                                              │
│ ┌─ Track Inspector ─────────────────────────────────────┐   │
│ │ Selected: Track 1 "Face Override"                      │   │
│ │ Blend Mode: [Override ▼]                               │   │
│ │ Body Mask:  [■Face ■Mouth □Head □Neck □Spine ...]     │   │
│ │ Influence:  [━━━━━━━━━●━] 0.85                        │   │
│ │ [Mute] [Solo] [Delete Track]                           │   │
│ └────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Clip Visualization

Each clip on the timeline shows:
- **Color coding by source:** Orange = webcam, Blue = AI (HunyuanMotion), Green = imported
- **Waveform/curve preview:** Mini motion intensity curve inside the clip rectangle
- **Blend ramps:** Diagonal gradient at clip edges showing crossfade zones
- **Trim handles:** Draggable edges to trim clip start/end
- **Influence badge:** Small number showing clip weight if not 1.0

### 10.3 Interaction Model

- **Drag from library to track:** Places clip at drop position
- **Drag clip edges:** Trim/extend
- **Drag clip body:** Move on timeline
- **Right-click clip:** Split, duplicate, delete, adjust speed
- **Drag between tracks:** Move clip to different body region
- **Shift+drag:** Snap to other clip boundaries
- **Cmd+drag clip edge into another clip:** Create crossfade overlap

---

## 11. Performance Budget

### 11.1 Real-Time Capture (Target: 30 FPS)

| Component | Budget | Measured/Expected |
|-----------|--------|-------------------|
| AVCaptureSession frame delivery | 0ms (async) | Camera-driven |
| Apple Vision body pose 3D | 8-12ms | Per Apple docs |
| MediaPipe face blend shapes | 5-10ms | C++ path on M1 |
| Temporal filtering | <0.1ms | Trivial math |
| Motion retargeting | <0.5ms | Matrix multiplies |
| NLA evaluation (4 tracks) | <0.2ms | Interpolation only |
| SceneKit render | 4-8ms | Existing perf |
| **Total per frame** | **~33ms budget** | **~20-30ms expected** |

Running body + face tracking in parallel on separate threads keeps us within the 33ms budget for 30 FPS.

### 11.2 Memory Budget

| Component | Size |
|-----------|------|
| MotionClip (10s @ 30fps, 17 joints) | ~200KB |
| MotionClip (10s @ 30fps, 52 blend shapes) | ~80KB |
| MediaPipe model weights (in memory) | ~15MB |
| Webcam frame buffer (720p BGRA) | ~3.7MB |
| NLA timeline (10 clips) | <50KB |

Total additional memory: ~20MB — negligible on any Apple Silicon Mac.

---

## 12. Phased Implementation Roadmap

### Phase 1: Foundation — Webcam Capture + Body Tracking (2-3 weeks)

**Deliverables:**
- `CaptureSession` with AVCaptureSession webcam pipeline
- `VisionBodyTracker` using Apple Vision 3D body pose
- `UnifiedPoseFrame` data model
- `TemporalFilter` (OneEuro) for jitter reduction
- `CapturePreviewView` showing live webcam with skeleton overlay
- Record button → saves `UnifiedPoseFrame` stream to disk
- New `motion` dock tab (basic shell)

**Why first:** Gets end-to-end webcam→tracking→preview working with zero external dependencies. Uses only Apple-native frameworks. Proves the capture pipeline.

### Phase 2: Face Tracking — MediaPipe Integration (2-3 weeks)

**Deliverables:**
- MediaPipe C++ bridge (FaceTrackerBridge.h/.mm)
- `MediaPipeFaceTracker` producing 52 ARKit blend shapes
- Face blend shapes → `CharacterPerformanceProfile.applyMorphWeights()`
- Live face preview on 3D character (real-time morph targets)
- Body + face running in parallel on separate threads

**Why second:** Adds the most user-visible wow factor. Seeing your facial expressions on a 3D character in real-time is the compelling demo. MediaPipe C++ integration is the main technical risk — tackle it early.

### Phase 3: MotionClip + Recording Pipeline (1-2 weeks)

**Deliverables:**
- `MotionClip` data model and serialization
- `MotionRecorder` — records capture session → MotionClip
- `MotionRetargeter` — IK-based retargeting to character rig
- Motion clip library UI in the Motion dock tab
- Raw webcam video saved alongside pose data for reference

**Why third:** Converts the real-time capture from Phase 1-2 into reusable, editable animation data.

### Phase 4: NLA Timeline — Motion Mixing (3-4 weeks)

**Deliverables:**
- `NLATimeline`, `NLATrack`, `NLAClip` data models
- `NLAEvaluator` — per-frame blended pose evaluation
- `BodyPartMask` — per-region override control
- `NLATimelineView` — full timeline UI with tracks, clips, drag/drop
- Track inspector (blend mode, mask, influence, mute/solo)
- Integration with existing AnimateStore playback (CADisplayLink)
- Backward compatibility — scenes without NLA tracks use existing engines

**Why fourth:** This is the most complex piece but depends on having MotionClips to work with. The data model is well-defined; the UI is the main effort.

### Phase 5: HunyuanMotion Integration (1 week)

**Deliverables:**
- Convert HunyuanMotion FBX output → MotionClip (via FBXMotionClipLoader)
- Auto-place AI-generated motion on NLA base track
- Mix AI body motion with webcam face capture

**Why fifth:** Bridges the existing AI motion pipeline into the new NLA system. Should be straightforward since FBXMotionClipLoader already parses the data.

### Phase 6: Import/Export + Polish (2 weeks)

**Deliverables:**
- `BVHParser` — import BVH files as MotionClips
- `MotionClipExporter` — export MotionClip to BVH
- Video file import (drag .mov/.mp4 → process through capture pipeline)
- Clip crossfade visualization and interaction
- Keyboard shortcuts for capture workflow
- Per-clip speed adjustment
- Timeline zoom and scroll

### Phase 7: Advanced — Audio Lip Sync + Enhanced Tracking (2-3 weeks)

**Deliverables:**
- Audio-to-viseme Core ML model producing blend shape weights
- Integration with existing VisemeBlendEngine
- Audio lip sync as auto-generated MotionClip on a dedicated mouth track
- Optional: DWPose Core ML model for whole-body (133 keypoints) when higher fidelity needed
- Optional: Hand tracking via Apple Vision VNDetectHumanHandPoseRequest

### Total Estimated Scope: 13-18 weeks

Phases 1-4 form the **minimum viable product** (~9-12 weeks). Phases 5-7 are enhancements.

---

## 13. Risk Assessment

### 13.1 Technical Risks

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| MediaPipe C++ build complexity (Bazel) | Medium | High | Pre-build as static lib; fallback to Python subprocess IPC |
| Apple Vision 3D pose accuracy insufficient | Low | Low | Supplement with RTMPose Core ML; 17 joints covers humanoid well |
| SceneKit morpher limitations (max targets) | Medium | Low | SCNMorpher supports 8+ targets; 52 blend shapes may need batching |
| Temporal filter introduces lag | Low | Medium | OneEuro filter is specifically designed for low latency; tune β params |
| Motion retargeting artifacts (proportion mismatch) | Medium | Medium | IK correction pass; user-adjustable retarget scale per bone |
| NLA evaluation performance with many tracks | Low | Low | Track count rarely exceeds 10; evaluation is trivial math |
| Swift-C++ interop instability | Medium | Medium | Fallback to ObjC++ bridge (proven pattern) |

### 13.2 Product Risks

| Risk | Mitigation |
|------|------------|
| Users don't have external webcam | Built-in FaceTime camera works; also support video file import |
| Mocap quality expectations too high | Clear UI messaging: "Reference capture" not "production mocap" |
| Timeline complexity overwhelms users | Default to simple mode (just record → apply); NLA is power-user feature |
| Feature scope creep | Phased delivery; each phase is independently useful |

---

## 14. Technology Reference

### 14.1 Apple Frameworks Used

| Framework | API | Purpose |
|-----------|-----|---------|
| AVFoundation | AVCaptureSession, AVCaptureVideoDataOutput | Webcam capture |
| AVFoundation | AVAssetReader | Video file frame extraction |
| Vision | VNDetectHumanBodyPose3DRequest | 3D body tracking (17 joints) |
| Vision | VNDetectHumanHandPoseRequest | Hand tracking (21 joints/hand) |
| SceneKit | SCNMorpher | Blend shape application |
| SceneKit | SCNAnimationPlayer | Bone animation playback |
| SceneKit | SCNIKConstraint | IK correction pass |
| Core ML | MLModel | Optional enhanced pose models |
| Metal | MTLComputePipelineState | Optional GPU-accelerated processing |

### 14.2 External Dependencies

| Dependency | License | Purpose | Integration |
|------------|---------|---------|-------------|
| MediaPipe | Apache 2.0 | 52 ARKit face blend shapes | C++ static lib |
| RTMPose (optional) | Apache 2.0 | Enhanced body pose | Core ML conversion |
| DWPose (optional) | Apache 2.0 | Whole-body 133 keypoints | Core ML conversion |

### 14.3 Key Research References

- **MediaPipe Face Landmarker** — 478 landmarks + 52 ARKit blend shapes from RGB camera
- **SMPL-H** — Standard humanoid skeleton (52 joints) used by HunyuanMotion
- **OneEuro Filter** — Low-latency signal filter for mocap jitter (Casiez et al., 2012)
- **Blender NLA** — Reference architecture for non-linear animation mixing
- **Unreal Layered Blend Per Bone** — Reference for per-body-part animation override
- **SceneKit SCNMorpher** — Apple's blend shape system, supports named morph targets

### 14.4 File Format Support

| Format | Import | Export | Use Case |
|--------|--------|--------|----------|
| BVH | Yes | Yes | Standard mocap interchange |
| FBX | Yes (existing) | No | HunyuanMotion clips |
| GLB/USDZ | Yes (existing) | No | Character models |
| MOV/MP4 | Yes (video source) | No | Webcam recordings |
| JSON | Yes | Yes | MotionClip native format |

---

## Appendix A: Glossary

- **Blend shape / Morph target:** Named deformation on a 3D mesh (e.g., "jawOpen" deforms the jaw down). Controlled by a 0-1 weight.
- **ARKit 52 blend shapes:** Apple's standard set of 52 facial blend shape names. MediaPipe outputs these from an RGB camera.
- **NLA (Non-Linear Animation):** A timeline system where animation clips can be placed, trimmed, blended, and layered non-destructively.
- **Body part mask:** A bitmask defining which skeleton joints a track controls, enabling per-region override (e.g., arms only).
- **OneEuro filter:** A low-latency adaptive filter that smooths slowly-moving signals while preserving fast movements.
- **Retargeting:** Transferring motion from one skeleton to another with different proportions.
- **IK (Inverse Kinematics):** Computing joint rotations from a desired end-effector position (e.g., "put the hand here, figure out the elbow and shoulder angles").
- **SMPL-H:** Skinned Multi-Person Linear model with Hands — 52-joint body model used by HunyuanMotion and most academic mocap research.
- **MotionClip:** This project's serializable animation data container — joint rotations + blend shapes + metadata, source-agnostic.
