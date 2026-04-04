# Phase 2: Face Tracking via Apple Vision Landmarks

**Date:** 2026-04-03
**Status:** Planned
**Depends on:** Phase 1 (Capture Session + Body Tracking)
**Estimated steps:** 12

---

## Overview

Add real-time facial blend shape estimation from a standard RGB webcam using Apple Vision framework face landmarks. Produces 52 ARKit-compatible blend shape weights that drive SceneKit morph targets on 3D characters. Designed with a `FaceTracker` protocol so MediaPipe can be swapped in later without changing consumers.

## Architecture

```
CaptureSession (Phase 1, exists)
    ↓ CMSampleBuffer
VisionFaceTracker (new, implements FaceTracker protocol)
    ↓ [BlendShapeName: Float]
UnifiedPoseFrame.faceBlendShapes (Phase 1, exists)
    ↓ via AnimateStore live cue override
CharacterPerformanceDriver.applyMorphWeights() (exists)
    ↓ SCNMorpher
SceneKit 3D character nodes (exists)
```

## Key Existing Code

- **`CharacterPerformanceDriver`** (`Packages/Animate/Sources/AnimateUI/Engine/CharacterPerformanceProfile.swift`): Has `applyMorphWeights(_ weights: [String: Double])` at line ~615 that iterates `rootNode.enumerateChildNodes`, finds `node.morpher.targets` by name, and calls `morpher.setWeight()`. This is the final application point.
- **`CharacterExpressionEngine`** (`Engine/CharacterExpressionEngine.swift`): `state(for:blocking:frame:liveCue:profile:)` checks `liveCue` first via `normalizedCue(liveCue)`. The mocap system injects face data as a live cue override.
- **`CharacterMouthEngine`** (`Engine/CharacterMouthEngine.swift`): `state(for:blocking:frame:liveCue:baseFPS:profile:)` checks `resolveLiveViseme(liveCue)` first. Mocap mouth shapes inject here.
- **`ScenePreviewRenderer`** (`Engine/ScenePreviewRenderer.swift`): Calls `store?.evaluatedExpression()` and `store?.evaluatedMouthCue()` which resolve to `AnimateStore.evaluatedCue()` reading from timeline tracks. The mocap system needs a parallel injection path.
- **`AnimateStore`** (`AnimateStore.swift`): `evaluatedCue(for:trackSuffix:at:)` at line ~687 resolves live cues from timeline tracks. Mocap blend shapes bypass this entirely — they go direct to `CharacterPerformanceDriver`.

## Conventions

- All files: `@available(macOS 26.0, *)`
- Swift 6 strict concurrency: all shared state must be `Sendable`, use `@MainActor` for UI/SceneKit, actors for background processing
- All new files go under `Packages/Animate/Sources/AnimateUI/`
- Build command: `cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"`

---

## Step 1: Create BlendShapeName enum

**File:** `Packages/Animate/Sources/AnimateUI/Capture/BlendShapeName.swift` (NEW)

**Why:** Strongly-typed ARKit-compatible blend shape names used throughout the face tracking pipeline. Must match ARKit's 52 blend shapes exactly so morph target names on imported 3D models map directly.

```swift
import Foundation

/// The 52 ARKit-compatible facial blend shape names.
/// Raw values match ARKit's `ARFaceAnchor.BlendShapeLocation` string keys
/// and standard morph target names on imported FBX/glTF characters.
@available(macOS 26.0, *)
enum BlendShapeName: String, Codable, Sendable, CaseIterable, Hashable {
    case browDownLeft
    case browDownRight
    case browInnerUp
    case browOuterUpLeft
    case browOuterUpRight
    case cheekPuff
    case cheekSquintLeft
    case cheekSquintRight
    case eyeBlinkLeft
    case eyeBlinkRight
    case eyeLookDownLeft
    case eyeLookDownRight
    case eyeLookInLeft
    case eyeLookInRight
    case eyeLookOutLeft
    case eyeLookOutRight
    case eyeLookUpLeft
    case eyeLookUpRight
    case eyeSquintLeft
    case eyeSquintRight
    case eyeWideLeft
    case eyeWideRight
    case jawForward
    case jawLeft
    case jawOpen
    case jawRight
    case mouthClose
    case mouthDimpleLeft
    case mouthDimpleRight
    case mouthFrownLeft
    case mouthFrownRight
    case mouthFunnel
    case mouthLeft
    case mouthRight
    case mouthLowerDownLeft
    case mouthLowerDownRight
    case mouthPressLeft
    case mouthPressRight
    case mouthPucker
    case mouthRollLower
    case mouthRollUpper
    case mouthShrugLower
    case mouthShrugUpper
    case mouthSmileLeft
    case mouthSmileRight
    case mouthStretchLeft
    case mouthStretchRight
    case mouthUpperUpLeft
    case mouthUpperUpRight
    case noseSneerLeft
    case noseSneerRight
    case tongueOut
}
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 2: Create FaceTracker protocol

**File:** `Packages/Animate/Sources/AnimateUI/Capture/FaceTracker.swift` (NEW)

**Why:** Abstraction layer so VisionFaceTracker (Apple Vision) and a future MediaPipeFaceTracker can be swapped without changing any consumer code.

```swift
import CoreVideo
import Foundation

/// Result from a single frame of face tracking.
@available(macOS 26.0, *)
struct FaceTrackingResult: Sendable {
    /// Blend shape weights, keyed by ARKit-compatible name. Values in 0...1 range.
    let blendShapes: [BlendShapeName: Float]

    /// Confidence of the face detection, 0...1. Below ~0.3 means no reliable face found.
    let confidence: Float

    /// Timestamp of the source frame.
    let timestamp: Double

    /// Whether a face was detected at all.
    var faceDetected: Bool { confidence > 0.1 }
}

/// Protocol for face tracking backends.
/// Implementations receive a pixel buffer from the capture session and return
/// estimated blend shape weights.
///
/// Conforming types:
/// - `VisionFaceTracker` (Apple Vision landmarks → approximate blend shapes)
/// - Future: `MediaPipeFaceTracker` (MediaPipe Face Landmarker → 52 blend shapes)
@available(macOS 26.0, *)
protocol FaceTracker: Sendable {
    /// Process a single video frame and return face blend shape weights.
    /// Returns nil if no face is detected or tracking fails.
    func track(pixelBuffer: CVPixelBuffer, timestamp: Double) async -> FaceTrackingResult?

    /// Reset internal state (e.g., temporal filters).
    func reset() async
}
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 3: Create VisionFaceLandmarkExtractor

**File:** `Packages/Animate/Sources/AnimateUI/Capture/VisionFaceLandmarkExtractor.swift` (NEW)

**Why:** Wraps Apple Vision's `VNDetectFaceLandmarksRequest` to extract the 76 face landmark points from a pixel buffer. Separated from blend shape computation so the Vision API call is isolated and testable.

```swift
import CoreVideo
import Foundation
import Vision

/// Raw face landmark data extracted from Apple Vision.
@available(macOS 26.0, *)
struct VisionFaceLandmarks: Sendable {
    /// All landmark regions from Vision. Points are in normalized image coordinates (0...1).
    let faceContour: [SIMD2<Float>]
    let leftEye: [SIMD2<Float>]
    let rightEye: [SIMD2<Float>]
    let leftEyebrow: [SIMD2<Float>]
    let rightEyebrow: [SIMD2<Float>]
    let nose: [SIMD2<Float>]
    let noseCrest: [SIMD2<Float>]
    let medianLine: [SIMD2<Float>]
    let outerLips: [SIMD2<Float>]
    let innerLips: [SIMD2<Float>]
    let leftPupil: [SIMD2<Float>]
    let rightPupil: [SIMD2<Float>]

    /// Face bounding box in normalized image coordinates.
    let boundingBox: CGRect

    /// Detection confidence from Vision (0...1).
    let confidence: Float
}

/// Extracts face landmarks from a pixel buffer using Apple Vision framework.
@available(macOS 26.0, *)
final class VisionFaceLandmarkExtractor: Sendable {

    /// Extract face landmarks from the given pixel buffer.
    /// Runs the Vision request on a background thread.
    /// Returns nil if no face is detected.
    func extract(from pixelBuffer: CVPixelBuffer) async -> VisionFaceLandmarks? {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceLandmarksRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNFaceObservation],
                      let face = results.first,
                      let landmarks = face.landmarks
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let result = VisionFaceLandmarks(
                    faceContour: Self.points(from: landmarks.faceContour),
                    leftEye: Self.points(from: landmarks.leftEye),
                    rightEye: Self.points(from: landmarks.rightEye),
                    leftEyebrow: Self.points(from: landmarks.leftEyebrow),
                    rightEyebrow: Self.points(from: landmarks.rightEyebrow),
                    nose: Self.points(from: landmarks.nose),
                    noseCrest: Self.points(from: landmarks.noseCrest),
                    medianLine: Self.points(from: landmarks.medianLine),
                    outerLips: Self.points(from: landmarks.outerLips),
                    innerLips: Self.points(from: landmarks.innerLips),
                    leftPupil: Self.points(from: landmarks.leftPupil),
                    rightPupil: Self.points(from: landmarks.rightPupil),
                    boundingBox: face.boundingBox,
                    confidence: face.confidence
                )
                continuation.resume(returning: result)
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Convert a VNFaceLandmarkRegion2D to an array of SIMD2<Float> points.
    private static func points(from region: VNFaceLandmarkRegion2D?) -> [SIMD2<Float>] {
        guard let region else { return [] }
        let pointCount = region.pointCount
        guard pointCount > 0 else { return [] }
        // VNFaceLandmarkRegion2D.normalizedPoints is a pointer to CGPoint values
        let buffer = region.normalizedPoints
        return (0..<pointCount).map { i in
            let p = buffer[i]
            return SIMD2<Float>(Float(p.x), Float(p.y))
        }
    }
}
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 4: Create BlendShapeEstimator — landmark geometry to blend shape weights

**File:** `Packages/Animate/Sources/AnimateUI/Capture/BlendShapeEstimator.swift` (NEW)

**Why:** Converts raw Vision face landmark positions into approximate ARKit blend shape weights using geometric heuristics. This is the core estimation logic. Each blend shape is computed from distances/angles between specific landmark points, normalized to 0...1.

```swift
import Foundation

/// Estimates ARKit-compatible blend shape weights from Vision face landmark geometry.
///
/// Uses geometric heuristics — distances between landmark points, aspect ratios,
/// and relative positions — to approximate the 52 blend shapes. Not as accurate
/// as MediaPipe's ML-based approach but requires zero external dependencies.
@available(macOS 26.0, *)
struct BlendShapeEstimator: Sendable {

    /// Estimate blend shape weights from extracted Vision face landmarks.
    func estimate(from landmarks: VisionFaceLandmarks) -> [BlendShapeName: Float] {
        var weights: [BlendShapeName: Float] = [:]

        // --- Jaw ---
        let jawOpenValue = estimateJawOpen(landmarks: landmarks)
        weights[.jawOpen] = jawOpenValue
        weights[.jawForward] = 0 // Cannot reliably estimate from 2D
        weights[.jawLeft] = 0
        weights[.jawRight] = 0

        // --- Mouth ---
        let mouthSmile = estimateMouthSmile(landmarks: landmarks)
        weights[.mouthSmileLeft] = mouthSmile.left
        weights[.mouthSmileRight] = mouthSmile.right

        let mouthFrown = estimateMouthFrown(landmarks: landmarks)
        weights[.mouthFrownLeft] = mouthFrown.left
        weights[.mouthFrownRight] = mouthFrown.right

        let puckerValue = estimateMouthPucker(landmarks: landmarks)
        weights[.mouthPucker] = puckerValue
        weights[.mouthFunnel] = estimateMouthFunnel(landmarks: landmarks)

        weights[.mouthClose] = max(0, 1.0 - jawOpenValue * 3.0)
        weights[.mouthLeft] = 0
        weights[.mouthRight] = 0
        weights[.mouthDimpleLeft] = mouthSmile.left * 0.5
        weights[.mouthDimpleRight] = mouthSmile.right * 0.5
        weights[.mouthStretchLeft] = max(0, mouthSmile.left - 0.3) * 0.5
        weights[.mouthStretchRight] = max(0, mouthSmile.right - 0.3) * 0.5
        weights[.mouthRollLower] = 0
        weights[.mouthRollUpper] = 0
        weights[.mouthShrugLower] = jawOpenValue * 0.3
        weights[.mouthShrugUpper] = jawOpenValue * 0.2
        weights[.mouthPressLeft] = max(0, 1.0 - jawOpenValue * 2.0) * 0.5
        weights[.mouthPressRight] = max(0, 1.0 - jawOpenValue * 2.0) * 0.5

        let mouthVertical = estimateMouthVertical(landmarks: landmarks)
        weights[.mouthUpperUpLeft] = mouthVertical.upperUp * jawOpenValue
        weights[.mouthUpperUpRight] = mouthVertical.upperUp * jawOpenValue
        weights[.mouthLowerDownLeft] = mouthVertical.lowerDown * jawOpenValue
        weights[.mouthLowerDownRight] = mouthVertical.lowerDown * jawOpenValue

        // --- Eyes ---
        let eyeBlink = estimateEyeBlink(landmarks: landmarks)
        weights[.eyeBlinkLeft] = eyeBlink.left
        weights[.eyeBlinkRight] = eyeBlink.right

        let eyeWide = estimateEyeWide(landmarks: landmarks)
        weights[.eyeWideLeft] = eyeWide.left
        weights[.eyeWideRight] = eyeWide.right

        let eyeSquint = estimateEyeSquint(landmarks: landmarks)
        weights[.eyeSquintLeft] = eyeSquint.left
        weights[.eyeSquintRight] = eyeSquint.right

        // Eye look directions - cannot reliably estimate from 2D landmarks alone
        weights[.eyeLookUpLeft] = 0
        weights[.eyeLookUpRight] = 0
        weights[.eyeLookDownLeft] = 0
        weights[.eyeLookDownRight] = 0
        weights[.eyeLookInLeft] = 0
        weights[.eyeLookInRight] = 0
        weights[.eyeLookOutLeft] = 0
        weights[.eyeLookOutRight] = 0

        // --- Brows ---
        let browDown = estimateBrowDown(landmarks: landmarks)
        weights[.browDownLeft] = browDown.left
        weights[.browDownRight] = browDown.right

        let browInnerUp = estimateBrowInnerUp(landmarks: landmarks)
        weights[.browInnerUp] = browInnerUp

        let browOuterUp = estimateBrowOuterUp(landmarks: landmarks)
        weights[.browOuterUpLeft] = browOuterUp.left
        weights[.browOuterUpRight] = browOuterUp.right

        // --- Cheeks ---
        weights[.cheekPuff] = 0 // Cannot estimate from 2D
        weights[.cheekSquintLeft] = eyeSquint.left * 0.7
        weights[.cheekSquintRight] = eyeSquint.right * 0.7

        // --- Nose ---
        let noseSneer = estimateNoseSneer(landmarks: landmarks)
        weights[.noseSneerLeft] = noseSneer.left
        weights[.noseSneerRight] = noseSneer.right

        // --- Tongue ---
        weights[.tongueOut] = 0 // Cannot estimate from 2D landmarks

        return weights
    }

    // MARK: - Estimation Helpers

    /// Jaw open: normalized distance between inner lip top center and inner lip bottom center.
    private func estimateJawOpen(landmarks: VisionFaceLandmarks) -> Float {
        let innerLips = landmarks.innerLips
        guard innerLips.count >= 6 else { return 0 }
        // Inner lips: top center is typically index 0 or 3, bottom center is opposite
        // Vision inner lip points go around the inner mouth opening
        let topCenter = innerLips[0]
        let bottomCenter = innerLips[innerLips.count / 2]
        let mouthGap = distance(topCenter, bottomCenter)

        // Normalize by face bounding box height
        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return 0 }
        let normalized = mouthGap / faceHeight
        // Map: 0.0 (closed) to ~0.15 (wide open) → 0...1
        return clamp01(normalized / 0.15)
    }

    /// Mouth smile: corner Y position relative to mouth center.
    /// Higher corners = smile, lower = frown.
    private func estimateMouthSmile(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let outerLips = landmarks.outerLips
        guard outerLips.count >= 6 else { return (0, 0) }
        // Outer lips: leftmost point and rightmost point are the corners
        // Points go clockwise; index 0 = left corner, count/2 = right corner (approx)
        let leftCorner = outerLips[0]
        let rightCorner = outerLips[outerLips.count / 2]
        let topCenter = outerLips[outerLips.count / 4]
        let bottomCenter = outerLips[3 * outerLips.count / 4]
        let mouthCenterY = (topCenter.y + bottomCenter.y) / 2

        let leftSmile = (leftCorner.y - mouthCenterY) / Float(landmarks.boundingBox.height)
        let rightSmile = (rightCorner.y - mouthCenterY) / Float(landmarks.boundingBox.height)

        // Positive = corner above center = smile
        return (
            left: clamp01(leftSmile * 15.0),
            right: clamp01(rightSmile * 15.0)
        )
    }

    /// Mouth frown: inverse of smile (corners below center).
    private func estimateMouthFrown(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let smile = estimateMouthSmile(landmarks: landmarks)
        return (
            left: clamp01(-smile.left + 0.1),
            right: clamp01(-smile.right + 0.1)
        )
    }

    /// Mouth pucker: inner lip width (narrow = high pucker).
    private func estimateMouthPucker(landmarks: VisionFaceLandmarks) -> Float {
        let innerLips = landmarks.innerLips
        guard innerLips.count >= 4 else { return 0 }
        let leftCorner = innerLips[0]
        let rightCorner = innerLips[innerLips.count / 2]
        let innerWidth = abs(rightCorner.x - leftCorner.x)
        let faceWidth = Float(landmarks.boundingBox.width)
        guard faceWidth > 0 else { return 0 }
        let normalizedWidth = innerWidth / faceWidth
        // Wider = less pucker. Typical range: 0.05 (puckered) to 0.3 (wide)
        return clamp01(1.0 - normalizedWidth / 0.25)
    }

    /// Mouth funnel: outer lip roundness (both lips pushed forward into O shape).
    private func estimateMouthFunnel(landmarks: VisionFaceLandmarks) -> Float {
        let outerLips = landmarks.outerLips
        let innerLips = landmarks.innerLips
        guard outerLips.count >= 4, innerLips.count >= 4 else { return 0 }
        // Funnel: mouth is open AND pursed. Combination of jaw open + pucker.
        let jawOpen = estimateJawOpen(landmarks: landmarks)
        let pucker = estimateMouthPucker(landmarks: landmarks)
        return clamp01(jawOpen * pucker * 2.0)
    }

    /// Mouth vertical components for upper/lower lip movement.
    private func estimateMouthVertical(landmarks: VisionFaceLandmarks) -> (upperUp: Float, lowerDown: Float) {
        let innerLips = landmarks.innerLips
        guard innerLips.count >= 6 else { return (0, 0) }
        let topCenter = innerLips[0]
        let bottomCenter = innerLips[innerLips.count / 2]
        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return (0, 0) }
        let gap = bottomCenter.y - topCenter.y // Positive when open (bottom below top in image coords)
        let normalizedGap = abs(gap) / faceHeight
        return (
            upperUp: clamp01(normalizedGap * 5.0),
            lowerDown: clamp01(normalizedGap * 6.0)
        )
    }

    /// Eye blink: aspect ratio of eye (height/width), inverted.
    /// Closed eye = very low aspect ratio = high blink value.
    private func estimateEyeBlink(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftBlink = eyeAspectRatioToBlink(landmarks.leftEye)
        let rightBlink = eyeAspectRatioToBlink(landmarks.rightEye)
        return (left: leftBlink, right: rightBlink)
    }

    /// Eye wide: high aspect ratio = wide open.
    private func estimateEyeWide(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftAR = eyeAspectRatio(landmarks.leftEye)
        let rightAR = eyeAspectRatio(landmarks.rightEye)
        // Wide when aspect ratio is notably higher than normal (~0.25)
        return (
            left: clamp01((leftAR - 0.28) * 5.0),
            right: clamp01((rightAR - 0.28) * 5.0)
        )
    }

    /// Eye squint: moderate closure, between blink and normal.
    private func estimateEyeSquint(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftAR = eyeAspectRatio(landmarks.leftEye)
        let rightAR = eyeAspectRatio(landmarks.rightEye)
        // Squint when aspect ratio is slightly below normal
        return (
            left: clamp01((0.22 - leftAR) * 6.0),
            right: clamp01((0.22 - rightAR) * 6.0)
        )
    }

    /// Brow down: low brow position relative to eye center.
    private func estimateBrowDown(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftDist = browToEyeDistance(brow: landmarks.leftEyebrow, eye: landmarks.leftEye)
        let rightDist = browToEyeDistance(brow: landmarks.rightEyebrow, eye: landmarks.rightEye)
        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return (0, 0) }
        // Lower distance = brow is down. Typical neutral distance: ~0.06 of face height
        let leftNorm = leftDist / faceHeight
        let rightNorm = rightDist / faceHeight
        return (
            left: clamp01((0.06 - leftNorm) * 20.0),
            right: clamp01((0.06 - rightNorm) * 20.0)
        )
    }

    /// Brow inner up: inner brow points above their neutral position.
    private func estimateBrowInnerUp(landmarks: VisionFaceLandmarks) -> Float {
        let leftBrow = landmarks.leftEyebrow
        let rightBrow = landmarks.rightEyebrow
        guard !leftBrow.isEmpty, !rightBrow.isEmpty else { return 0 }
        // Inner brow points are the ones closest to center
        // leftBrow last point and rightBrow first point are inner
        let leftInner = leftBrow.last ?? leftBrow[0]
        let rightInner = rightBrow.first ?? rightBrow[0]
        let leftEyeCenter = centroid(landmarks.leftEye)
        let rightEyeCenter = centroid(landmarks.rightEye)

        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return 0 }
        let leftOffset = (leftInner.y - leftEyeCenter.y) / faceHeight
        let rightOffset = (rightInner.y - rightEyeCenter.y) / faceHeight
        let avgOffset = (leftOffset + rightOffset) / 2
        // Higher offset = brow is higher = browInnerUp
        return clamp01((avgOffset - 0.05) * 15.0)
    }

    /// Brow outer up: outer brow points above their neutral position.
    private func estimateBrowOuterUp(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftBrow = landmarks.leftEyebrow
        let rightBrow = landmarks.rightEyebrow
        guard !leftBrow.isEmpty, !rightBrow.isEmpty else { return (0, 0) }
        let leftOuter = leftBrow.first ?? leftBrow[0]
        let rightOuter = rightBrow.last ?? rightBrow[0]
        let leftEyeCenter = centroid(landmarks.leftEye)
        let rightEyeCenter = centroid(landmarks.rightEye)

        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return (0, 0) }
        let leftOffset = (leftOuter.y - leftEyeCenter.y) / faceHeight
        let rightOffset = (rightOuter.y - rightEyeCenter.y) / faceHeight
        return (
            left: clamp01((leftOffset - 0.05) * 12.0),
            right: clamp01((rightOffset - 0.05) * 12.0)
        )
    }

    /// Nose sneer: nostril area widening (approximated from nose landmark spread).
    private func estimateNoseSneer(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let nose = landmarks.nose
        guard nose.count >= 4 else { return (0, 0) }
        // Nose points include nostrils. Wider spread = sneer.
        let leftNostril = nose[0]
        let rightNostril = nose[nose.count - 1]
        let noseCenter = centroid(nose)
        let faceWidth = Float(landmarks.boundingBox.width)
        guard faceWidth > 0 else { return (0, 0) }
        let leftSpread = abs(leftNostril.x - noseCenter.x) / faceWidth
        let rightSpread = abs(rightNostril.x - noseCenter.x) / faceWidth
        return (
            left: clamp01((leftSpread - 0.04) * 15.0),
            right: clamp01((rightSpread - 0.04) * 15.0)
        )
    }

    // MARK: - Geometry Utilities

    private func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        simd_distance(a, b)
    }

    private func centroid(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(SIMD2<Float>.zero, +)
        return sum / Float(points.count)
    }

    private func eyeAspectRatio(_ eyePoints: [SIMD2<Float>]) -> Float {
        // Eye aspect ratio = vertical height / horizontal width
        guard eyePoints.count >= 4 else { return 0.25 } // Return neutral if insufficient points
        let xs = eyePoints.map(\.x)
        let ys = eyePoints.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 0 else { return 0.25 }
        return height / width
    }

    private func eyeAspectRatioToBlink(_ eyePoints: [SIMD2<Float>]) -> Float {
        let ar = eyeAspectRatio(eyePoints)
        // Normal open eye AR ≈ 0.25. Closed ≈ 0.05.
        // Map: 0.05 → 1.0 (fully blinked), 0.25 → 0.0 (fully open)
        return clamp01((0.25 - ar) / 0.20)
    }

    private func browToEyeDistance(brow: [SIMD2<Float>], eye: [SIMD2<Float>]) -> Float {
        let browCenter = centroid(brow)
        let eyeCenter = centroid(eye)
        return abs(browCenter.y - eyeCenter.y)
    }

    private func clamp01(_ value: Float) -> Float {
        min(1.0, max(0.0, value))
    }
}
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 5: Create VisionFaceTracker — the FaceTracker protocol implementation

**File:** `Packages/Animate/Sources/AnimateUI/Capture/VisionFaceTracker.swift` (NEW)

**Why:** Concrete `FaceTracker` implementation using Apple Vision landmarks + `BlendShapeEstimator`. This is what `CaptureSession` calls on each frame to get blend shape weights.

```swift
import CoreVideo
import Foundation

/// Face tracking backend using Apple Vision framework.
///
/// Extracts 76 face landmarks via `VNDetectFaceLandmarksRequest` and converts
/// them to approximate ARKit 52 blend shape weights using geometric heuristics.
///
/// Thread-safe: uses an internal actor for state isolation.
@available(macOS 26.0, *)
final class VisionFaceTracker: FaceTracker, Sendable {

    private let extractor = VisionFaceLandmarkExtractor()
    private let estimator = BlendShapeEstimator()

    func track(pixelBuffer: CVPixelBuffer, timestamp: Double) async -> FaceTrackingResult? {
        guard let landmarks = await extractor.extract(from: pixelBuffer) else {
            return nil
        }

        guard landmarks.confidence > 0.3 else {
            return FaceTrackingResult(
                blendShapes: [:],
                confidence: landmarks.confidence,
                timestamp: timestamp
            )
        }

        let weights = estimator.estimate(from: landmarks)

        return FaceTrackingResult(
            blendShapes: weights,
            confidence: landmarks.confidence,
            timestamp: timestamp
        )
    }

    func reset() async {
        // VisionFaceTracker is stateless per-frame; nothing to reset.
        // Future: if temporal smoothing is added here, reset that state.
    }
}
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 6: Create FaceTrackingSmootherFilter

**File:** `Packages/Animate/Sources/AnimateUI/Capture/FaceTrackingSmootherFilter.swift` (NEW)

**Why:** Raw per-frame blend shape estimates from Vision landmarks are noisy. This applies the existing `TemporalFilter` (One Euro filter from Phase 1) to each blend shape channel independently, producing smooth, jitter-free weights suitable for driving morph targets in real-time.

```swift
import Foundation

/// Smooths raw per-frame blend shape weights using One Euro temporal filtering.
///
/// Wraps Phase 1's `TemporalFilter` with one filter instance per blend shape channel.
/// Call `smooth(_:timestamp:)` on each frame's raw weights to get filtered output.
@available(macOS 26.0, *)
final class FaceTrackingSmootherFilter: @unchecked Sendable {

    /// One Euro filter parameters tuned for facial motion.
    /// - minCutoff: Lower = smoother but more lag. 1.0 is good for facial blend shapes.
    /// - beta: Higher = less lag on fast movements. 0.5 balances smoothness and responsiveness.
    /// - dCutoff: Derivative cutoff. 1.0 is standard.
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double

    /// Per-channel filter state.
    private var filters: [BlendShapeName: TemporalFilter] = [:]
    private let lock = NSLock()

    init(minCutoff: Double = 1.0, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    /// Apply temporal smoothing to raw blend shape weights.
    /// - Parameters:
    ///   - weights: Raw unfiltered blend shape weights from the estimator.
    ///   - timestamp: Frame timestamp in seconds. Must be monotonically increasing.
    /// - Returns: Smoothed blend shape weights.
    func smooth(_ weights: [BlendShapeName: Float], timestamp: Double) -> [BlendShapeName: Float] {
        lock.lock()
        defer { lock.unlock() }

        var smoothed: [BlendShapeName: Float] = [:]
        for (name, value) in weights {
            if filters[name] == nil {
                filters[name] = TemporalFilter(
                    minCutoff: minCutoff,
                    beta: beta,
                    dCutoff: dCutoff
                )
            }
            let filtered = filters[name]!.filter(value: Double(value), timestamp: timestamp)
            smoothed[name] = Float(filtered)
        }
        return smoothed
    }

    /// Reset all filter state. Call when tracking is restarted or the face is lost.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        filters.removeAll()
    }
}
```

**Important note for implementer:** The above code assumes `TemporalFilter` from Phase 1 (`Capture/TemporalFilter.swift`) has this interface:
```swift
init(minCutoff: Double, beta: Double, dCutoff: Double)
func filter(value: Double, timestamp: Double) -> Double
```
If the Phase 1 `TemporalFilter` has a different interface, adapt the calls accordingly. The key requirement is a One Euro filter that takes a value + timestamp and returns a smoothed value.

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 7: Update UnifiedPoseFrame to include face blend shapes

**File:** `Packages/Animate/Sources/AnimateUI/Capture/UnifiedPoseFrame.swift` (EXISTS — Phase 1)

**What to change:** The Phase 1 `UnifiedPoseFrame` already has `faceBlendShapes: [BlendShapeName: Float]?` as an optional field. Verify this field exists. If it uses `[String: Float]` instead of `[BlendShapeName: Float]`, change it to use the new strongly-typed enum.

**Find this in the file:**
```swift
var faceBlendShapes: [String: Float]?
```

**Replace with:**
```swift
var faceBlendShapes: [BlendShapeName: Float]?
```

If it already uses `[BlendShapeName: Float]?`, no change is needed. The point is to ensure the Phase 1 data model uses our new strongly-typed enum.

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 8: Integrate face tracking into CaptureSession

**File:** `Packages/Animate/Sources/AnimateUI/Capture/CaptureSession.swift` (EXISTS — Phase 1)

**What to change:** Add face tracking alongside the existing body tracking. The CaptureSession distributes `CMSampleBuffer` frames. We need to:

1. Add a `faceTracker: FaceTracker` property
2. Add a `faceSmootherFilter: FaceTrackingSmootherFilter` property
3. On each frame, run face tracking in parallel with body tracking
4. Merge face results into `UnifiedPoseFrame.faceBlendShapes`

**Find the class declaration and add properties.** Look for something like:
```swift
final class CaptureSession {
```
or
```swift
actor CaptureSession {
```

**Add these stored properties near the top of the class/actor, alongside the existing `bodyTracker`:**
```swift
    private let faceTracker: FaceTracker
    private let faceSmootherFilter = FaceTrackingSmootherFilter()
```

**Find the initializer** and add a `faceTracker` parameter with a default value:
```swift
    init(faceTracker: FaceTracker = VisionFaceTracker()) {
```
Wire it to `self.faceTracker = faceTracker`.

**Find the frame processing method** — this is where each `CMSampleBuffer` is handled. It likely looks something like:
```swift
func processFrame(_ sampleBuffer: CMSampleBuffer) async {
```
or it might be in the `AVCaptureVideoDataOutputSampleBufferDelegate` callback.

**Inside that method**, find where the body tracker is called. It will look something like:
```swift
let bodyResult = await bodyTracker.track(pixelBuffer: pixelBuffer)
```

**Change it to run face + body in parallel using a TaskGroup or async let:**
```swift
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        async let bodyResult = bodyTracker.track(pixelBuffer: pixelBuffer)
        async let faceResult = faceTracker.track(pixelBuffer: pixelBuffer, timestamp: timestamp)

        let body = await bodyResult
        let rawFace = await faceResult

        // Apply temporal smoothing to face blend shapes
        let smoothedFace: [BlendShapeName: Float]?
        if let face = rawFace, face.faceDetected {
            smoothedFace = faceSmootherFilter.smooth(face.blendShapes, timestamp: timestamp)
        } else {
            smoothedFace = nil
        }

        // Build unified frame
        var frame = UnifiedPoseFrame(
            timestamp: timestamp,
            bodyPose: body
            // ... existing fields ...
        )
        frame.faceBlendShapes = smoothedFace
```

**Also find the reset/stop method** and add:
```swift
        await faceTracker.reset()
        faceSmootherFilter.reset()
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 9: Create MocapBlendShapeApplicator — bridge from UnifiedPoseFrame to CharacterPerformanceDriver

**File:** `Packages/Animate/Sources/AnimateUI/Capture/MocapBlendShapeApplicator.swift` (NEW)

**Why:** Bridges the gap between the capture pipeline (which produces `[BlendShapeName: Float]`) and the existing `CharacterPerformanceDriver.applyMorphWeights()` (which takes `[String: Double]`). Also handles mapping face blend shapes to the expression/mouth engine override paths.

```swift
import Foundation
import SceneKit

/// Bridges mocap face blend shapes to the existing character performance system.
///
/// Two application paths:
/// 1. **Direct morph weights** — Sends blend shape weights directly to
///    `CharacterPerformanceDriver.applyMorphWeights()` for characters with
///    morph targets matching ARKit blend shape names.
/// 2. **Expression/mouth override** — Converts key blend shapes to
///    `CharacterExpressionState` and `CharacterMouthState` parameters for
///    characters without direct morph targets (uses the generated-feature fallback).
@available(macOS 26.0, *)
@MainActor
struct MocapBlendShapeApplicator {

    /// Apply face blend shapes from mocap to a character's SceneKit nodes.
    ///
    /// - Parameters:
    ///   - blendShapes: ARKit-compatible blend shape weights (0...1).
    ///   - rootNode: The character's root SCNNode (same node passed to CharacterPerformanceDriver).
    ///   - driver: The character's performance driver, used for morph weight application.
    static func apply(
        blendShapes: [BlendShapeName: Float],
        toRootNode rootNode: SCNNode
    ) {
        // Convert BlendShapeName enum keys to String keys, Float to Double
        let stringWeights: [String: Double] = blendShapes.reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = Double(pair.value)
        }

        // Apply morph weights directly to any node with matching morph targets
        rootNode.enumerateChildNodes { node, _ in
            guard let morpher = node.morpher else { return }
            for (index, target) in morpher.targets.enumerated() {
                let name = target.name ?? ""
                guard let weight = stringWeights.first(where: { key, _ in
                    key.caseInsensitiveCompare(name) == .orderedSame
                })?.value else { continue }
                morpher.setWeight(CGFloat(weight), forTargetAt: index)
            }
        }
    }

    /// Convert blend shapes to a `CharacterExpressionState` for characters
    /// that use the generated-feature path (no morph targets).
    static func expressionState(from blendShapes: [BlendShapeName: Float]) -> CharacterExpressionState {
        let browLift = Double(
            (blendShapes[.browInnerUp] ?? 0) * 0.5 +
            ((blendShapes[.browOuterUpLeft] ?? 0) + (blendShapes[.browOuterUpRight] ?? 0)) * 0.25
        )
        let browDown = Double(
            ((blendShapes[.browDownLeft] ?? 0) + (blendShapes[.browDownRight] ?? 0)) * 0.5
        )
        let browTilt = Double(
            (blendShapes[.browDownLeft] ?? 0) - (blendShapes[.browDownRight] ?? 0)
        )
        let eyeOpen = 1.0 - Double(
            ((blendShapes[.eyeBlinkLeft] ?? 0) + (blendShapes[.eyeBlinkRight] ?? 0)) * 0.5
        )
        let smile = Double(
            ((blendShapes[.mouthSmileLeft] ?? 0) + (blendShapes[.mouthSmileRight] ?? 0)) * 0.5
        )
        let blink = Double(
            max(blendShapes[.eyeBlinkLeft] ?? 0, blendShapes[.eyeBlinkRight] ?? 0)
        )

        return CharacterExpressionState(
            cue: "mocap",
            intensity: 1.0,
            browLift: browLift - browDown,
            browTilt: browTilt,
            eyeOpen: eyeOpen,
            smile: smile,
            blink: blink,
            headPitch: 0
        )
    }

    /// Convert blend shapes to a `CharacterMouthState` for characters
    /// that use the generated-feature path (no morph targets).
    static func mouthState(from blendShapes: [BlendShapeName: Float]) -> CharacterMouthState {
        let jawOpen = Double(blendShapes[.jawOpen] ?? 0)
        let pucker = Double(blendShapes[.mouthPucker] ?? 0)
        let smileBlend = Double(
            ((blendShapes[.mouthSmileLeft] ?? 0) + (blendShapes[.mouthSmileRight] ?? 0)) * 0.5
        )
        // Approximate mouth width: wider with smile, narrower with pucker
        let mouthWidth = 0.42 + smileBlend * 0.3 - pucker * 0.2
        let mouthHeight = 0.08 + jawOpen * 0.82

        return CharacterMouthState(
            cue: "mocap",
            viseme: jawOpen > 0.5 ? .ai : jawOpen > 0.2 ? .consonant : .rest,
            jawOpen: jawOpen,
            mouthWidth: mouthWidth,
            mouthHeight: mouthHeight,
            pucker: pucker,
            smileBlend: smileBlend
        )
    }
}
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 10: Add mocap live override path to AnimateStore

**File:** `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` (EXISTS)

**Why:** The mocap system needs to inject live face data that overrides the timeline-based expression/mouth cues. We add a published property that holds the current mocap blend shapes, and modify the expression/mouth evaluation to check it first.

**Find the AnimateStore class declaration.** It will look like:
```swift
@Observable @MainActor
final class AnimateStore {
```

**Add these properties** near the other state properties (look for properties like `currentFrame`, `isPlaying`, etc.):

```swift
    // MARK: - Mocap Live Override

    /// Current live mocap face blend shapes. When non-nil, these override
    /// timeline-based expression and mouth cues for all characters.
    /// Set by the capture pipeline; cleared when capture stops.
    var liveMocapBlendShapes: [BlendShapeName: Float]?

    /// Whether mocap face data should be applied directly as morph weights
    /// (true for characters with ARKit morph targets) or converted to
    /// expression/mouth state (false for generated-feature characters).
    var mocapDirectMorphMode: Bool = true
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 11: Wire mocap blend shapes into ScenePreviewRenderer

**File:** `Packages/Animate/Sources/AnimateUI/Engine/ScenePreviewRenderer.swift` (EXISTS)

**Why:** This is where per-frame performance is applied to characters. We need to check for live mocap data and apply it, bypassing or supplementing the normal expression/mouth engine path.

**Find the `applyPerformance` method** (line ~623). It currently calls `expressionEngine.state()` and `mouthEngine.state()` then `driver.apply()`.

**Add a mocap check at the top of `applyPerformance`, before the existing expression/mouth engine calls.** Find this code block:

```swift
    private func applyPerformance(
        blocking: CharacterBlockingPlan,
        frame: Int,
        motionContext: MotionContext,
        holdResolution: HoldResolution
    ) {
        let profile = characterPerformanceProfilesByName[blocking.characterName]
        let liveExpression = store?.evaluatedExpression(
```

**Replace the entire method body with:**

```swift
    private func applyPerformance(
        blocking: CharacterBlockingPlan,
        frame: Int,
        motionContext: MotionContext,
        holdResolution: HoldResolution
    ) {
        // --- Mocap face override path ---
        if let mocapShapes = store?.liveMocapBlendShapes,
           !mocapShapes.isEmpty,
           let node = characterNodes[blocking.characterName] {
            if store?.mocapDirectMorphMode == true {
                // Direct morph weight application for characters with ARKit morph targets
                MocapBlendShapeApplicator.apply(
                    blendShapes: mocapShapes,
                    toRootNode: node
                )
            }
            // Also apply as expression/mouth state for the generated-feature path
            let mocapExpression = MocapBlendShapeApplicator.expressionState(from: mocapShapes)
            let mocapMouth = MocapBlendShapeApplicator.mouthState(from: mocapShapes)
            let applicationResult = characterPerformanceDrivers[blocking.characterName]?.apply(
                expression: mocapExpression,
                mouth: mocapMouth
            )
            if var status = characterPerformanceStatusesByName[blocking.characterName] {
                status.activeExpressionCue = "mocap"
                status.activeVisemeCue = "mocap"
                status.sourceExpressionCue = "mocap"
                status.sourceVisemeCue = "mocap"
                status.usingExpressionPreset = applicationResult?.usedExpressionPreset ?? false
                status.usingVisemePreset = applicationResult?.usedVisemePreset ?? false
                status.resolvedExpressionPresetCue = applicationResult?.resolvedExpressionPresetCue
                status.resolvedVisemePresetCue = applicationResult?.resolvedVisemePresetCue
                status.driverMode = characterPerformanceDrivers[blocking.characterName]?.driverMode ?? status.driverMode
                characterPerformanceStatusesByName[blocking.characterName] = status
            }
            return // Skip normal expression/mouth engine when mocap is active
        }

        // --- Normal timeline-driven path (unchanged) ---
        let profile = characterPerformanceProfilesByName[blocking.characterName]
        let liveExpression = store?.evaluatedExpression(
            for: blocking.characterName,
            at: frame
        )
        let liveMouthCue = store?.evaluatedMouthCue(
            for: blocking.characterName,
            at: frame
        )
        let rawExpressionState = expressionEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveExpression
        )
        let expressionState = expressionEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveExpression,
            profile: profile
        )
        let rawMouthState = mouthEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveMouthCue,
            baseFPS: currentPlan?.baseFPS ?? 24
        )
        let mouthState = mouthEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveMouthCue,
            baseFPS: currentPlan?.baseFPS ?? 24,
            profile: profile
        )
        let applicationResult = characterPerformanceDrivers[blocking.characterName]?.apply(
            expression: expressionState,
            mouth: mouthState
        )
        let resolvedMotion = motionContext.resolvedMotion
        if var status = characterPerformanceStatusesByName[blocking.characterName] {
            status.sourceExpressionCue = rawExpressionState.cue
            status.sourceVisemeCue = rawMouthState.cue
            status.expressionBehaviorCue = profile?.expressionBehaviorCue(for: rawExpressionState.cue)
            status.expressionCueProvenance = profile?.expressionCueProvenance(for: rawExpressionState.cue)
            status.visemeCueProvenance = profile?.visemeCueProvenance(for: rawMouthState)
            status.sourceActionCue = motionContext.actionCue
            status.sourcePoseCue = motionContext.poseCue
            status.resolvedMotionID = resolvedMotion?.descriptor.motionID
            status.resolvedMotionTitle = resolvedMotion?.descriptor.title
            status.motionProvenance = resolvedMotion?.provenance
            status.resolvedHoldMultiplier = holdResolution.multiplier
            status.holdProvenance = holdResolution.provenance
            status.motionHintSummary = motionHintSummary(for: resolvedMotion?.descriptor)
            status.activeExpressionCue = expressionState.cue
            status.activeVisemeCue = mouthState.cue
            status.usingExpressionPreset = applicationResult?.usedExpressionPreset ?? false
            status.usingVisemePreset = applicationResult?.usedVisemePreset ?? false
            status.resolvedExpressionPresetCue = applicationResult?.resolvedExpressionPresetCue
            status.resolvedVisemePresetCue = applicationResult?.resolvedVisemePresetCue
            status.driverMode = characterPerformanceDrivers[blocking.characterName]?.driverMode ?? status.driverMode
            characterPerformanceStatusesByName[blocking.characterName] = status
        }
    }
```

**Verify:** Run build command. Expect `BUILD SUCCEEDED`.

---

## Step 12: Build, deploy, and commit

**Action 1:** Run the full build:
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

If there are errors, fix them. Common issues to watch for:
- `TemporalFilter` interface mismatch — check Phase 1's actual init signature
- `UnifiedPoseFrame` field name mismatch — check actual field name in Phase 1 file
- Import issues — may need `import simd` in BlendShapeEstimator
- Sendability issues — ensure `VisionFaceLandmarkExtractor` and `BlendShapeEstimator` are properly `Sendable`

**Action 2:** Deploy to `!Applications`:
```bash
cp -R "/Volumes/Storage VIII/Programming/Amira Writer/build/Build/Products/Release/Opera.app" "/Volumes/Storage VIII/Programming/!Applications/"
```

**Action 3:** Commit all new and modified files:
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add \
    Packages/Animate/Sources/AnimateUI/Capture/BlendShapeName.swift \
    Packages/Animate/Sources/AnimateUI/Capture/FaceTracker.swift \
    Packages/Animate/Sources/AnimateUI/Capture/VisionFaceLandmarkExtractor.swift \
    Packages/Animate/Sources/AnimateUI/Capture/BlendShapeEstimator.swift \
    Packages/Animate/Sources/AnimateUI/Capture/VisionFaceTracker.swift \
    Packages/Animate/Sources/AnimateUI/Capture/FaceTrackingSmootherFilter.swift \
    Packages/Animate/Sources/AnimateUI/Capture/UnifiedPoseFrame.swift \
    Packages/Animate/Sources/AnimateUI/Capture/CaptureSession.swift \
    Packages/Animate/Sources/AnimateUI/Capture/MocapBlendShapeApplicator.swift \
    Packages/Animate/Sources/AnimateUI/AnimateStore.swift \
    Packages/Animate/Sources/AnimateUI/Engine/ScenePreviewRenderer.swift
git commit -m "feat: add Phase 2 face tracking — Vision landmarks to 52 ARKit blend shapes"
```

---

## File Summary

| # | File | Status | Purpose |
|---|------|--------|---------|
| 1 | `Capture/BlendShapeName.swift` | NEW | 52 ARKit blend shape name enum |
| 2 | `Capture/FaceTracker.swift` | NEW | Protocol + result type |
| 3 | `Capture/VisionFaceLandmarkExtractor.swift` | NEW | Apple Vision landmark extraction |
| 4 | `Capture/BlendShapeEstimator.swift` | NEW | Landmark geometry → blend shape weights |
| 5 | `Capture/VisionFaceTracker.swift` | NEW | FaceTracker implementation using Vision |
| 6 | `Capture/FaceTrackingSmootherFilter.swift` | NEW | One Euro temporal smoothing per channel |
| 7 | `Capture/UnifiedPoseFrame.swift` | MODIFY | Ensure faceBlendShapes uses BlendShapeName enum |
| 8 | `Capture/CaptureSession.swift` | MODIFY | Add parallel face tracking to frame pipeline |
| 9 | `Capture/MocapBlendShapeApplicator.swift` | NEW | Bridge: blend shapes → morph weights / expression state |
| 10 | `AnimateStore.swift` | MODIFY | Add liveMocapBlendShapes property |
| 11 | `Engine/ScenePreviewRenderer.swift` | MODIFY | Wire mocap override into applyPerformance() |

All paths are relative to `Packages/Animate/Sources/AnimateUI/`.

## Future: MediaPipe Upgrade Path

The `FaceTracker` protocol enables a drop-in replacement:

```swift
// Just change the default in CaptureSession init:
init(faceTracker: FaceTracker = MediaPipeFaceTracker()) {
```

A future `MediaPipeFaceTracker` would use MediaPipe's Face Landmarker (via Python subprocess or native C++ bridge) to produce ML-based blend shape weights instead of the geometric heuristics in `BlendShapeEstimator`. The entire downstream pipeline (smoothing, applicator, renderer integration) remains unchanged.
