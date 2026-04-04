# Phase 1: Webcam Capture + Body Tracking — Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Build a real-time webcam capture pipeline with Apple Vision 3D body tracking, temporal jitter filtering, and a SwiftUI preview overlay — exposed as a new "Motion" tab in the Animate workspace dock.

**Architecture:** `CaptureSession` wraps AVCaptureSession on a dedicated serial queue and vends CVPixelBuffers to `VisionBodyTracker`, which runs VNDetectHumanBodyPose3DRequest and maps results to a source-agnostic `UnifiedPoseFrame`. A `TemporalFilter` (OneEuro) smooths each joint independently. `CapturePreviewView` composites the live camera feed (via AVCaptureVideoPreviewLayer in NSViewRepresentable) with a Canvas skeleton overlay driven by the latest filtered pose. All state lives on `AnimateStore` so other subsystems can consume poses later.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26), AVFoundation, Vision (VNDetectHumanBodyPose3DRequest), simd, Combine (for frame bridging)

All file paths below are relative to `Packages/Animate/`.

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `Sources/AnimateUI/Models/MocapModels.swift` | `UnifiedPoseFrame`, `JointName`, `HandJointName`, `BlendShapeName`, `CaptureSource` |
| `Sources/AnimateUI/Services/CaptureSession.swift` | AVCaptureSession wrapper — camera discovery, start/stop, pixel buffer delegate |
| `Sources/AnimateUI/Services/VisionBodyTracker.swift` | Runs VNDetectHumanBodyPose3DRequest, maps to `UnifiedPoseFrame` |
| `Sources/AnimateUI/Services/TemporalFilter.swift` | OneEuro filter for SIMD3<Float> joint positions |
| `Sources/AnimateUI/Views/CapturePreviewView.swift` | NSViewRepresentable camera preview + Canvas skeleton overlay |
| `Sources/AnimateUI/Views/MotionCaptureDeck.swift` | The dock tab content view — start/stop controls, status, preview |
| `Tests/AnimateTests/TemporalFilterTests.swift` | Unit tests for OneEuro filter behavior |

### Modified Files
| File | Change |
|------|--------|
| `Sources/AnimateUI/Models/AnimateWorkspaceModels.swift` | Add `case motion` to `AnimateWorkspaceDockTab` |
| `Sources/AnimateUI/AnimateStore.swift` | Add mocap state properties |
| `Sources/AnimateUI/Views/AnimatePageView.swift` | Add `case .motion:` to dock tab switch |

---

### Task 1: Data Model — UnifiedPoseFrame and Supporting Types

**Files:**
- Create: `Sources/AnimateUI/Models/MocapModels.swift`

- [ ] **Step 1: Create MocapModels.swift with all mocap data types**

Create `Packages/Animate/Sources/AnimateUI/Models/MocapModels.swift`:

```swift
import Foundation
import simd

// MARK: - Joint Names

@available(macOS 26.0, *)
enum JointName: String, Codable, CaseIterable, Sendable {
    case root, hips, spine, chest, neck, head
    case leftShoulder, leftElbow, leftWrist
    case rightShoulder, rightElbow, rightWrist
    case leftHip, leftKnee, leftAnkle
    case rightHip, rightKnee, rightAnkle
    case leftEar, rightEar, nose
    case leftToe, rightToe
}

@available(macOS 26.0, *)
enum HandJointName: String, Codable, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

@available(macOS 26.0, *)
enum BlendShapeName: String, Codable, CaseIterable, Sendable {
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
    case mouthFunnel, mouthLeft, mouthLowerDownLeft
    case mouthLowerDownRight, mouthPressLeft, mouthPressRight
    case mouthPucker, mouthRight, mouthRollLower, mouthRollUpper
    case mouthShrugLower, mouthShrugUpper
    case mouthSmileLeft, mouthSmileRight
    case mouthStretchLeft, mouthStretchRight
    case mouthUpperUpLeft, mouthUpperUpRight
    case noseSneerLeft, noseSneerRight
    case tongueOut
}

// MARK: - Capture Source

@available(macOS 26.0, *)
enum CaptureSource: String, Codable, Sendable {
    case appleVision
    case mediaPipe
    case coreMLPose
    case imported
}

// MARK: - Unified Pose Frame

@available(macOS 26.0, *)
struct UnifiedPoseFrame: Codable, Sendable {
    let timestamp: TimeInterval
    let source: CaptureSource
    let bodyJoints: [JointName: SIMD3<Float>]?
    let bodyConfidences: [JointName: Float]?
    let leftHandJoints: [HandJointName: SIMD3<Float>]?
    let rightHandJoints: [HandJointName: SIMD3<Float>]?
    let faceBlendShapes: [BlendShapeName: Float]?
    let faceLandmarks: [SIMD2<Float>]?
}

// MARK: - Skeleton Connectivity (for overlay drawing)

@available(macOS 26.0, *)
enum SkeletonTopology {
    /// Pairs of joints that should be connected by lines in the skeleton overlay.
    static let bodyBones: [(JointName, JointName)] = [
        (.hips, .spine), (.spine, .chest), (.chest, .neck), (.neck, .head),
        (.neck, .leftShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.neck, .rightShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.hips, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.hips, .rightHip), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftToe), (.rightAnkle, .rightToe),
        (.head, .nose), (.head, .leftEar), (.head, .rightEar),
    ]
}
```

- [ ] **Step 2: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

---

### Task 2: OneEuro Temporal Filter

**Files:**
- Create: `Sources/AnimateUI/Services/TemporalFilter.swift`
- Create: `Tests/AnimateTests/TemporalFilterTests.swift`

- [ ] **Step 1: Write failing test for TemporalFilter**

Create `Packages/Animate/Tests/AnimateTests/TemporalFilterTests.swift`:

```swift
import Foundation
import simd
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class TemporalFilterTests: XCTestCase {

    func testStaticSignalConvergesToValue() {
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.007, dCutoff: 1.0)
        var result = SIMD3<Float>.zero
        // Feed same value 60 times at 60fps
        for i in 0..<60 {
            let t = Double(i) / 60.0
            result = filter.filter(value: SIMD3<Float>(1.0, 2.0, 3.0), timestamp: t)
        }
        // Should converge close to the input
        XCTAssertEqual(result.x, 1.0, accuracy: 0.05)
        XCTAssertEqual(result.y, 2.0, accuracy: 0.05)
        XCTAssertEqual(result.z, 3.0, accuracy: 0.05)
    }

    func testFirstValuePassesThrough() {
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.007, dCutoff: 1.0)
        let result = filter.filter(value: SIMD3<Float>(5.0, 10.0, 15.0), timestamp: 0.0)
        XCTAssertEqual(result.x, 5.0, accuracy: 0.001)
        XCTAssertEqual(result.y, 10.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 15.0, accuracy: 0.001)
    }

    func testHighBetaAllowsFastMovement() {
        var lowBeta = OneEuroFilter(minCutoff: 1.0, beta: 0.0, dCutoff: 1.0)
        var highBeta = OneEuroFilter(minCutoff: 1.0, beta: 1.0, dCutoff: 1.0)

        // First sample
        _ = lowBeta.filter(value: .zero, timestamp: 0.0)
        _ = highBeta.filter(value: .zero, timestamp: 0.0)

        // Jump to a distant value
        let jump = SIMD3<Float>(10.0, 0.0, 0.0)
        let lowResult = lowBeta.filter(value: jump, timestamp: 1.0 / 60.0)
        let highResult = highBeta.filter(value: jump, timestamp: 1.0 / 60.0)

        // High beta should track the jump more closely (closer to 10.0)
        XCTAssertGreaterThan(highResult.x, lowResult.x)
    }

    func testTemporalFilterManagerFiltersMultipleJoints() {
        var manager = TemporalFilterManager()
        let joints: [JointName: SIMD3<Float>] = [
            .head: SIMD3<Float>(0, 1, 0),
            .leftWrist: SIMD3<Float>(1, 0, 0),
        ]
        // Feed same values twice
        let result1 = manager.filter(joints: joints, timestamp: 0.0)
        let result2 = manager.filter(joints: joints, timestamp: 1.0 / 60.0)

        XCTAssertNotNil(result1[.head])
        XCTAssertNotNil(result2[.leftWrist])
    }
}
```

- [ ] **Step 2: Create TemporalFilter.swift with OneEuro implementation**

Create `Packages/Animate/Sources/AnimateUI/Services/TemporalFilter.swift`:

```swift
import Foundation
import simd

// MARK: - Low-Pass Filter (scalar)

/// Simple exponential smoothing low-pass filter.
@available(macOS 26.0, *)
struct LowPassFilter: Sendable {
    private var hatXPrev: Float?
    private(set) var hadPrev: Bool = false

    mutating func filter(value: Float, alpha: Float) -> Float {
        if let prev = hatXPrev {
            let result = alpha * value + (1.0 - alpha) * prev
            hatXPrev = result
            return result
        } else {
            hatXPrev = value
            return value
        }
    }

    mutating func reset() {
        hatXPrev = nil
        hadPrev = false
    }
}

// MARK: - OneEuro Filter (SIMD3<Float>)

/// Jitter reduction filter that adapts cutoff frequency based on speed of change.
///
/// When the signal moves slowly, heavy smoothing removes jitter.
/// When the signal moves fast, light smoothing preserves quick movements.
///
/// Reference: Casiez et al., "1€ Filter: A Simple Speed-based Low-pass Filter
/// for Noisy Input in Interactive Systems", CHI 2012.
@available(macOS 26.0, *)
struct OneEuroFilter: Sendable {
    let minCutoff: Float
    let beta: Float
    let dCutoff: Float

    private var xFilterX = LowPassFilter()
    private var xFilterY = LowPassFilter()
    private var xFilterZ = LowPassFilter()
    private var dxFilterX = LowPassFilter()
    private var dxFilterY = LowPassFilter()
    private var dxFilterZ = LowPassFilter()
    private var prevValue: SIMD3<Float>?
    private var prevTimestamp: Double?

    init(minCutoff: Float = 1.0, beta: Float = 0.007, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func filter(value: SIMD3<Float>, timestamp: Double) -> SIMD3<Float> {
        guard let prev = prevValue, let prevT = prevTimestamp else {
            prevValue = value
            prevTimestamp = timestamp
            // Initialize low-pass filters with first value
            _ = xFilterX.filter(value: value.x, alpha: 1.0)
            _ = xFilterY.filter(value: value.y, alpha: 1.0)
            _ = xFilterZ.filter(value: value.z, alpha: 1.0)
            _ = dxFilterX.filter(value: 0.0, alpha: 1.0)
            _ = dxFilterY.filter(value: 0.0, alpha: 1.0)
            _ = dxFilterZ.filter(value: 0.0, alpha: 1.0)
            return value
        }

        let dt = Float(max(timestamp - prevT, 1e-6))

        // Compute derivatives
        let dx = (value - prev) / dt

        // Filter derivatives to get speed estimate
        let edAlpha = Self.alpha(cutoff: dCutoff, dt: dt)
        let edx = SIMD3<Float>(
            dxFilterX.filter(value: dx.x, alpha: edAlpha),
            dxFilterY.filter(value: dx.y, alpha: edAlpha),
            dxFilterZ.filter(value: dx.z, alpha: edAlpha)
        )

        // Compute adaptive cutoff per component
        let cutoffX = minCutoff + beta * abs(edx.x)
        let cutoffY = minCutoff + beta * abs(edx.y)
        let cutoffZ = minCutoff + beta * abs(edx.z)

        // Filter signal with adaptive cutoff
        let result = SIMD3<Float>(
            xFilterX.filter(value: value.x, alpha: Self.alpha(cutoff: cutoffX, dt: dt)),
            xFilterY.filter(value: value.y, alpha: Self.alpha(cutoff: cutoffY, dt: dt)),
            xFilterZ.filter(value: value.z, alpha: Self.alpha(cutoff: cutoffZ, dt: dt))
        )

        prevValue = value
        prevTimestamp = timestamp

        return result
    }

    mutating func reset() {
        xFilterX.reset()
        xFilterY.reset()
        xFilterZ.reset()
        dxFilterX.reset()
        dxFilterY.reset()
        dxFilterZ.reset()
        prevValue = nil
        prevTimestamp = nil
    }

    /// Compute smoothing factor from cutoff frequency and time step.
    static func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1.0 / (2.0 * Float.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

// MARK: - Temporal Filter Manager

/// Manages per-joint OneEuro filters for the full skeleton.
@available(macOS 26.0, *)
struct TemporalFilterManager: Sendable {
    private var filters: [JointName: OneEuroFilter] = [:]
    var minCutoff: Float = 1.0
    var beta: Float = 0.007
    var dCutoff: Float = 1.0

    /// Filter a dictionary of joint positions, returning smoothed positions.
    mutating func filter(
        joints: [JointName: SIMD3<Float>],
        timestamp: Double
    ) -> [JointName: SIMD3<Float>] {
        var result: [JointName: SIMD3<Float>] = [:]
        for (name, position) in joints {
            if filters[name] == nil {
                filters[name] = OneEuroFilter(
                    minCutoff: minCutoff,
                    beta: beta,
                    dCutoff: dCutoff
                )
            }
            result[name] = filters[name]!.filter(value: position, timestamp: timestamp)
        }
        return result
    }

    /// Reset all joint filters (e.g. when tracking is lost and re-acquired).
    mutating func reset() {
        filters.removeAll()
    }
}
```

- [ ] **Step 3: Run tests to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild test -scheme "Opera" -only-testing AnimateTests/TemporalFilterTests -destination "platform=macOS" 2>&1 | grep -E "error:|Test Case|BUILD|passed|failed"
```

- [ ] **Step 4: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 5: Commit Task 2**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add Packages/Animate/Sources/AnimateUI/Models/MocapModels.swift Packages/Animate/Sources/AnimateUI/Services/TemporalFilter.swift Packages/Animate/Tests/AnimateTests/TemporalFilterTests.swift && git commit -m "feat(mocap): add UnifiedPoseFrame data model and OneEuro temporal filter"
```

---

### Task 3: CaptureSession — AVCaptureSession Wrapper

**Files:**
- Create: `Sources/AnimateUI/Services/CaptureSession.swift`

- [ ] **Step 1: Create CaptureSession.swift**

Create `Packages/Animate/Sources/AnimateUI/Services/CaptureSession.swift`:

```swift
import AVFoundation
import CoreVideo
import Foundation

/// Callback type for new pixel buffers from the capture session.
@available(macOS 26.0, *)
typealias PixelBufferHandler = @Sendable (CVPixelBuffer, CMTime) -> Void

/// Wraps AVCaptureSession for webcam video capture on macOS.
///
/// Runs capture on a dedicated serial dispatch queue. Vends CVPixelBuffers
/// via a callback for downstream Vision processing.
@available(macOS 26.0, *)
final class CaptureSession: NSObject, Sendable {

    // MARK: - State

    enum State: String, Sendable {
        case idle
        case starting
        case running
        case stopped
        case failed
    }

    // Use nonisolated(unsafe) for AVFoundation objects that must live on the processing queue.
    // These are only accessed from the serial processingQueue after initialization.
    nonisolated(unsafe) private var session: AVCaptureSession?
    nonisolated(unsafe) private var videoOutput: AVCaptureVideoDataOutput?

    private let processingQueue = DispatchQueue(
        label: "com.amira.mocap.capture",
        qos: .userInteractive
    )

    /// Current capture state.
    private let _state = MocapAtomicState(.idle)

    /// Called on processingQueue for each new frame.
    private let _pixelBufferHandler = MocapAtomicBox<PixelBufferHandler?>(nil)

    var state: State { _state.value }

    /// The underlying AVCaptureSession, for use by preview layers. Only valid after start().
    var captureSession: AVCaptureSession? { session }

    // MARK: - Public API

    /// Set the handler called for each captured pixel buffer.
    /// The handler is called on the internal processing queue — dispatch to MainActor if needed.
    func setPixelBufferHandler(_ handler: @escaping PixelBufferHandler) {
        _pixelBufferHandler.value = handler
    }

    /// Discover available cameras. Returns a list of (uniqueID, localizedName).
    static func availableCameras() -> [(id: String, name: String)] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// Start capturing from the specified camera (or default if nil).
    func start(cameraID: String? = nil) {
        guard _state.value == .idle || _state.value == .stopped || _state.value == .failed else {
            return
        }
        _state.value = .starting

        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureAndStart(cameraID: cameraID)
                self._state.value = .running
            } catch {
                print("[CaptureSession] Failed to start: \(error)")
                self._state.value = .failed
            }
        }
    }

    /// Stop the capture session.
    func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.session?.stopRunning()
            self._state.value = .stopped
        }
    }

    // MARK: - Configuration

    private func configureAndStart(cameraID: String?) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        // Find camera
        let device: AVCaptureDevice?
        if let cameraID {
            device = AVCaptureDevice(uniqueID: cameraID)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let camera = device else {
            throw CaptureSessionError.noCameraAvailable
        }

        // Add input
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CaptureSessionError.cannotAddInput
        }
        session.addInput(input)

        // Add video data output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: processingQueue)

        guard session.canAddOutput(output) else {
            throw CaptureSessionError.cannotAddOutput
        }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()

        self.session = session
        self.videoOutput = output
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

@available(macOS 26.0, *)
extension CaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        _pixelBufferHandler.value?(pixelBuffer, timestamp)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Intentionally dropped — Vision processing couldn't keep up. This is fine.
    }
}

// MARK: - Errors

@available(macOS 26.0, *)
enum CaptureSessionError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable: "No camera found. Connect a webcam or enable the built-in camera."
        case .cannotAddInput: "Cannot add camera input to capture session."
        case .cannotAddOutput: "Cannot add video output to capture session."
        }
    }
}

// MARK: - Thread-safe Helpers

/// Minimal atomic wrapper for Sendable state value.
@available(macOS 26.0, *)
final class MocapAtomicState<T: Sendable>: Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Minimal atomic box for optional closures.
@available(macOS 26.0, *)
final class MocapAtomicBox<T: Sendable>: Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
```

- [ ] **Step 2: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 3: Commit Task 3**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add Packages/Animate/Sources/AnimateUI/Services/CaptureSession.swift && git commit -m "feat(mocap): add CaptureSession AVFoundation webcam wrapper"
```

---

### Task 4: VisionBodyTracker — 3D Body Pose Detection

**Files:**
- Create: `Sources/AnimateUI/Services/VisionBodyTracker.swift`

- [ ] **Step 1: Create VisionBodyTracker.swift**

Create `Packages/Animate/Sources/AnimateUI/Services/VisionBodyTracker.swift`:

```swift
import CoreVideo
import Foundation
import simd
import Vision

/// Runs Apple Vision VNDetectHumanBodyPose3DRequest on pixel buffers
/// and produces UnifiedPoseFrame results.
///
/// Call `processFrame(_:timestamp:)` from the CaptureSession's processing queue.
/// Results are delivered via the `onPoseFrame` callback on the same queue.
@available(macOS 26.0, *)
final class VisionBodyTracker: Sendable {

    /// Callback when a new pose frame is ready. Called on the capture processing queue.
    let onPoseFrame: @Sendable (UnifiedPoseFrame) -> Void

    /// Track whether we have an active detection in flight to skip overlapping requests.
    private let _isBusy = MocapAtomicState(false)

    init(onPoseFrame: @escaping @Sendable (UnifiedPoseFrame) -> Void) {
        self.onPoseFrame = onPoseFrame
    }

    /// Process a single pixel buffer through Vision body pose detection.
    /// Designed to be called from CaptureSession's processingQueue.
    /// Drops frames if the previous detection is still in progress.
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        // Skip if previous frame is still processing
        guard !_isBusy.value else { return }
        _isBusy.value = true

        defer { _isBusy.value = false }

        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
            try handler.perform([request])
        } catch {
            print("[VisionBodyTracker] Detection failed: \(error.localizedDescription)")
            return
        }

        guard let observation = request.results?.first else {
            // No body detected this frame — that's normal
            return
        }

        let frame = Self.mapObservation(observation, timestamp: timestamp)
        onPoseFrame(frame)
    }

    // MARK: - Mapping

    /// Map Vision body pose joint names to our JointName enum.
    private static let jointMapping: [(VNHumanBodyPose3DObservation.JointName, JointName)] = [
        (.root, .root),
        (.centerShoulder, .chest),  // Vision's centerShoulder maps to our chest
        (.spine, .spine),
        (.centerHead, .head),
        (.leftShoulder, .leftShoulder),
        (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow),
        (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist),
        (.rightWrist, .rightWrist),
        (.leftHip, .leftHip),
        (.rightHip, .rightHip),
        (.leftKnee, .leftKnee),
        (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle),
        (.rightAnkle, .rightAnkle),
    ]

    private static func mapObservation(
        _ observation: VNHumanBodyPose3DObservation,
        timestamp: TimeInterval
    ) -> UnifiedPoseFrame {
        var bodyJoints: [JointName: SIMD3<Float>] = [:]
        var bodyConfidences: [JointName: Float] = [:]

        for (visionName, jointName) in jointMapping {
            do {
                let recognized = try observation.recognizedPoint(visionName)
                // Extract translation from 4x4 transform matrix
                let col3 = recognized.position.columns.3
                bodyJoints[jointName] = SIMD3<Float>(col3.x, col3.y, col3.z)
                bodyConfidences[jointName] = Float(recognized.confidence)
            } catch {
                // Joint not detected — skip it
                continue
            }
        }

        // Synthesize hips as midpoint of leftHip and rightHip
        if let leftHip = bodyJoints[.leftHip], let rightHip = bodyJoints[.rightHip] {
            bodyJoints[.hips] = (leftHip + rightHip) / 2.0
            let leftConf = bodyConfidences[.leftHip] ?? 0
            let rightConf = bodyConfidences[.rightHip] ?? 0
            bodyConfidences[.hips] = min(leftConf, rightConf)
        }

        // Synthesize neck as midpoint between head and chest
        if let head = bodyJoints[.head], let chest = bodyJoints[.chest] {
            bodyJoints[.neck] = (head + chest) / 2.0
            let headConf = bodyConfidences[.head] ?? 0
            let chestConf = bodyConfidences[.chest] ?? 0
            bodyConfidences[.neck] = min(headConf, chestConf)
        }

        return UnifiedPoseFrame(
            timestamp: timestamp,
            source: .appleVision,
            bodyJoints: bodyJoints.isEmpty ? nil : bodyJoints,
            bodyConfidences: bodyConfidences.isEmpty ? nil : bodyConfidences,
            leftHandJoints: nil,
            rightHandJoints: nil,
            faceBlendShapes: nil,
            faceLandmarks: nil
        )
    }
}
```

- [ ] **Step 2: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 3: Commit Task 4**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add Packages/Animate/Sources/AnimateUI/Services/VisionBodyTracker.swift && git commit -m "feat(mocap): add VisionBodyTracker — 3D body pose via Apple Vision"
```

---

### Task 5: AnimateStore Mocap State

**Files:**
- Modify: `Sources/AnimateUI/AnimateStore.swift`

- [ ] **Step 1: Add mocap state properties to AnimateStore**

Open `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` and find the line:

```
    // MARK: - Image Crop State
```

Insert the following block **immediately before** that line:

```swift
    // MARK: - Motion Capture State

    var mocapIsRunning = false
    var mocapCameraID: String?
    var mocapLatestPoseFrame: UnifiedPoseFrame?
    var mocapFrameCount: Int = 0
    var mocapErrorMessage: String?
    var mocapFilterEnabled = true

    /// The capture session and tracker are non-nil while capture is active.
    /// They are created/destroyed by startMocap()/stopMocap().
    nonisolated(unsafe) var mocapCaptureSession: CaptureSession?
    nonisolated(unsafe) var mocapBodyTracker: VisionBodyTracker?
    var mocapTemporalFilter = TemporalFilterManager()

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

        mocapCaptureSession = capture
        mocapBodyTracker = tracker
        capture.start(cameraID: mocapCameraID)
        mocapIsRunning = true
    }

    func stopMocap() {
        mocapCaptureSession?.stop()
        mocapCaptureSession = nil
        mocapBodyTracker = nil
        mocapIsRunning = false
    }
```

- [ ] **Step 2: Add CoreMedia import if not present**

At the top of `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`, check that `import CoreMedia` is present. If the file already imports `AVFoundation` or `CoreMedia`, skip this. Otherwise, add below the existing imports:

```swift
import CoreMedia
```

- [ ] **Step 3: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 4: Commit Task 5**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add Packages/Animate/Sources/AnimateUI/AnimateStore.swift && git commit -m "feat(mocap): add motion capture state and start/stop methods to AnimateStore"
```

---

### Task 6: CapturePreviewView — Camera Feed + Skeleton Overlay

**Files:**
- Create: `Sources/AnimateUI/Views/CapturePreviewView.swift`

- [ ] **Step 1: Create CapturePreviewView.swift**

Create `Packages/Animate/Sources/AnimateUI/Views/CapturePreviewView.swift`:

```swift
import AVFoundation
import SwiftUI

// MARK: - Camera Preview Layer (NSViewRepresentable)

@available(macOS 26.0, *)
struct CameraPreviewRepresentable: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.session !== session {
            nsView.session = session
        }
    }
}

@available(macOS 26.0, *)
final class CameraPreviewNSView: NSView {
    var session: AVCaptureSession? {
        didSet {
            guard let session else {
                previewLayer?.session = nil
                return
            }
            if previewLayer == nil {
                let layer = AVCaptureVideoPreviewLayer()
                layer.videoGravity = .resizeAspectFill
                self.wantsLayer = true
                self.layer = CALayer()
                self.layer?.addSublayer(layer)
                previewLayer = layer
            }
            previewLayer?.session = session
        }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}

// MARK: - Skeleton Overlay

@available(macOS 26.0, *)
struct SkeletonOverlayView: View {
    let poseFrame: UnifiedPoseFrame?
    let viewSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard let joints = poseFrame?.bodyJoints else { return }
            let confidences = poseFrame?.bodyConfidences ?? [:]

            // Draw bones
            for (startJoint, endJoint) in SkeletonTopology.bodyBones {
                guard let startPos = joints[startJoint],
                      let endPos = joints[endJoint] else { continue }

                let startPoint = projectToScreen(startPos, in: size)
                let endPoint = projectToScreen(endPos, in: size)

                let startConf = confidences[startJoint] ?? 0
                let endConf = confidences[endJoint] ?? 0
                let avgConf = (startConf + endConf) / 2.0

                var path = Path()
                path.move(to: startPoint)
                path.addLine(to: endPoint)

                context.stroke(
                    path,
                    with: .color(boneColor(confidence: avgConf)),
                    lineWidth: 3
                )
            }

            // Draw joints
            for (jointName, position) in joints {
                let point = projectToScreen(position, in: size)
                let confidence = confidences[jointName] ?? 0
                let radius: CGFloat = jointName == .head ? 8 : 5

                let rect = CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(jointColor(confidence: confidence))
                )
            }
        }
    }

    /// Project 3D joint position to 2D screen coordinates.
    /// Vision body 3D coordinates: X is right, Y is up, Z is toward camera.
    /// We use a simple orthographic projection with the view centered.
    private func projectToScreen(_ position: SIMD3<Float>, in size: CGSize) -> CGPoint {
        // Scale factor: map roughly -1..1 meter range to view size
        let scale = min(size.width, size.height) * 0.4
        let centerX = size.width / 2.0
        let centerY = size.height / 2.0

        // Mirror X so left/right appears natural (webcam is mirrored)
        let x = centerX - CGFloat(position.x) * scale
        // Invert Y: Vision Y is up, screen Y is down
        let y = centerY - CGFloat(position.y) * scale

        return CGPoint(x: x, y: y)
    }

    private func boneColor(confidence: Float) -> Color {
        if confidence > 0.5 {
            return Color.green.opacity(Double(confidence))
        } else if confidence > 0.1 {
            return Color.yellow.opacity(0.7)
        } else {
            return Color.red.opacity(0.4)
        }
    }

    private func jointColor(confidence: Float) -> Color {
        if confidence > 0.5 {
            return Color.white
        } else if confidence > 0.1 {
            return Color.yellow
        } else {
            return Color.red.opacity(0.6)
        }
    }
}

// MARK: - Combined Preview View

@available(macOS 26.0, *)
struct CapturePreviewView: View {
    let captureSession: AVCaptureSession?
    let poseFrame: UnifiedPoseFrame?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let session = captureSession {
                    CameraPreviewRepresentable(session: session)
                } else {
                    Rectangle()
                        .fill(Color.black)
                    Text("No camera feed")
                        .foregroundStyle(.secondary)
                }

                SkeletonOverlayView(
                    poseFrame: poseFrame,
                    viewSize: geo.size
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
```

- [ ] **Step 2: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 3: Commit Task 6**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add Packages/Animate/Sources/AnimateUI/Views/CapturePreviewView.swift && git commit -m "feat(mocap): add CapturePreviewView with camera feed and skeleton overlay"
```

---

### Task 7: MotionCaptureDeck — Dock Tab Content View

**Files:**
- Create: `Sources/AnimateUI/Views/MotionCaptureDeck.swift`

- [ ] **Step 1: Create MotionCaptureDeck.swift**

Create `Packages/Animate/Sources/AnimateUI/Views/MotionCaptureDeck.swift`:

```swift
import SwiftUI

@available(macOS 26.0, *)
struct MotionCaptureDeck: View {
    @Bindable var store: AnimateStore

    @State private var availableCameras: [(id: String, name: String)] = []
    @State private var selectedCameraID: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                // Camera picker
                Picker("Camera", selection: $selectedCameraID) {
                    Text("Default").tag(nil as String?)
                    ForEach(availableCameras, id: \.id) { camera in
                        Text(camera.name).tag(camera.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                Spacer()

                // Filter toggle
                Toggle("Smooth", isOn: Binding(
                    get: { store.mocapFilterEnabled },
                    set: { store.mocapFilterEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                // Frame counter
                Text("\(store.mocapFrameCount) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Start / Stop button
                Button {
                    if store.mocapIsRunning {
                        store.stopMocap()
                    } else {
                        store.mocapCameraID = selectedCameraID
                        store.startMocap()
                    }
                } label: {
                    Label(
                        store.mocapIsRunning ? "Stop" : "Start Capture",
                        systemImage: store.mocapIsRunning ? "stop.circle.fill" : "camera.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(store.mocapIsRunning ? .red : .accentColor)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Preview area
            if store.mocapIsRunning {
                CapturePreviewView(
                    captureSession: store.mocapCaptureSession?.captureSession,
                    poseFrame: store.mocapLatestPoseFrame
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Motion Capture")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Connect a webcam and press Start Capture to begin 3D body tracking.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Error banner
            if let error = store.mocapErrorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        store.mocapErrorMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
            }

            // Joint info footer (when tracking)
            if let frame = store.mocapLatestPoseFrame,
               let joints = frame.bodyJoints {
                HStack(spacing: 16) {
                    Label("\(joints.count) joints", systemImage: "figure.stand")
                    if let confidences = frame.bodyConfidences {
                        let avgConf = confidences.values.reduce(0, +) / max(Float(confidences.count), 1)
                        Label(
                            String(format: "%.0f%% avg confidence", avgConf * 100),
                            systemImage: "gauge.with.dots.needle.33percent"
                        )
                    }
                    Spacer()
                    Text(String(format: "t=%.2fs", frame.timestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.2))
            }
        }
        .onAppear {
            availableCameras = CaptureSession.availableCameras()
        }
        .onDisappear {
            if store.mocapIsRunning {
                store.stopMocap()
            }
        }
    }
}
```

- [ ] **Step 2: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 3: Commit Task 7**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add Packages/Animate/Sources/AnimateUI/Views/MotionCaptureDeck.swift && git commit -m "feat(mocap): add MotionCaptureDeck view with controls and status"
```

---

### Task 8: Wire Motion Tab into Workspace

**Files:**
- Modify: `Sources/AnimateUI/Models/AnimateWorkspaceModels.swift`
- Modify: `Sources/AnimateUI/Views/AnimatePageView.swift`

- [ ] **Step 1: Add `motion` case to AnimateWorkspaceDockTab**

In `Packages/Animate/Sources/AnimateUI/Models/AnimateWorkspaceModels.swift`, find:

```swift
    case handoff
```

Add immediately after that line:

```swift
    case motion
```

- [ ] **Step 2: Add title for the motion case**

In the same file, find the line:

```swift
        case .handoff: "LLM Handoff"
```

Add immediately after that line:

```swift
        case .motion: "Motion"
```

- [ ] **Step 3: Add motion case to the dock tab switch in AnimatePageView**

In `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift`, find these two lines:

```swift
                case .handoff:
                    handoffDeck(for: scene)
```

Add immediately after those lines:

```swift
                case .motion:
                    MotionCaptureDeck(store: store)
```

- [ ] **Step 4: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 5: Commit Task 8**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add Packages/Animate/Sources/AnimateUI/Models/AnimateWorkspaceModels.swift Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift && git commit -m "feat(mocap): wire Motion tab into workspace dock"
```

---

### Task 9: Camera Privacy Entitlement

**Files:**
- Modify: the app's `Info.plist` or entitlements (locate by searching for `NSCameraUsageDescription` or the existing entitlements file)

- [ ] **Step 1: Find and update camera usage description**

Search the project for `NSCameraUsageDescription`. If it already exists, skip this step. If not, find the app's `Info.plist` (try `Opera/Info.plist` or the Xcode project settings). Add:

```xml
<key>NSCameraUsageDescription</key>
<string>Amira Writer uses the camera for real-time motion capture to drive character animations.</string>
```

If the project uses Xcode build settings instead of Info.plist for this key, add it via the `INFOPLIST_KEY_NSCameraUsageDescription` build setting.

- [ ] **Step 2: Verify camera entitlement**

Search for `com.apple.security.device.camera` in the entitlements file. If the app is sandboxed, ensure this entitlement is `true`:

```xml
<key>com.apple.security.device.camera</key>
<true/>
```

If the app is not sandboxed (no sandbox entitlement), the `NSCameraUsageDescription` alone is sufficient.

- [ ] **Step 3: Run build to verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 4: Commit Task 9**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git add -A && git commit -m "feat(mocap): add camera usage description for motion capture"
```

---

### Task 10: Build, Deploy, and Final Verification

- [ ] **Step 1: Full release build**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Release -derivedDataPath build -destination "platform=macOS" 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 2: Deploy to !Applications**

```bash
cp -R "/Volumes/Storage VIII/Programming/Amira Writer/build/Build/Products/Release/Opera.app" "/Volumes/Storage VIII/Programming/!Applications/"
```

- [ ] **Step 3: Run unit tests**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild test -scheme "Opera" -only-testing AnimateTests/TemporalFilterTests -destination "platform=macOS" 2>&1 | grep -E "error:|Test Case|BUILD|passed|failed"
```

- [ ] **Step 4: Final commit with all files**

If any files were missed in earlier commits:

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git status && git add -A && git diff --cached --stat
```

Only commit if there are staged changes:

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && git commit -m "feat(mocap): Phase 1 complete — webcam capture + body tracking pipeline"
```

---

## Build Troubleshooting

If you encounter build errors, check these common issues:

1. **Missing `import CoreMedia`** in AnimateStore.swift — needed for `CMTimeGetSeconds` and `CMTime`.
2. **Sendable conformance** — all closures passed across isolation boundaries must be `@Sendable`. The `nonisolated(unsafe)` annotation on `CaptureSession`'s AVFoundation properties is intentional for Swift 6 strict concurrency.
3. **`@available(macOS 26.0, *)`** — must be on every new `struct`, `class`, `enum`, and `extension` in this codebase. The package declares `.macOS(.v26)` but types still need the annotation.
4. **Switch exhaustiveness** — after adding `case motion` to `AnimateWorkspaceDockTab`, any other `switch` statements on this enum elsewhere in the codebase will need a `case .motion:` branch. Search for `AnimateWorkspaceDockTab` or `selectedDockTab` across all files and add handling.
