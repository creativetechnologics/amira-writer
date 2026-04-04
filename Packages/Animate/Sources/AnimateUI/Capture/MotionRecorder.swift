import Foundation
import simd

/// Records a stream of UnifiedPoseFrame into a MotionClip.
///
/// Usage:
///   1. Call `startRecording(fps:source:)` to begin
///   2. Feed frames via `recordFrame(_:)`
///   3. Call `stopRecording()` to get the finished MotionClip
///
@available(macOS 26.0, *)
@Observable @MainActor
final class MotionRecorder {

    // MARK: - State

    enum RecordingState: Sendable {
        case idle
        case recording
        case finalizing
    }

    private(set) var state: RecordingState = .idle
    private(set) var recordedFrameCount: Int = 0

    // MARK: - Internal Buffers

    private var fps: Int = 30
    private var source: MotionClipSource = .manual
    private var startTime: Date = .distantPast
    private var jointRotationBuffers: [String: [SIMD4<Float>]] = [:]
    private var rootPositionBuffer: [SIMD3<Float>] = []
    private var blendShapeBuffers: [String: [Float]] = [:]

    // MARK: - Joint Name Mapping

    /// Map from JointName enum cases to standard SMPL-H joint name strings.
    private static let jointToStandardName: [JointName: String] = [
        .hips: "Pelvis",
        .spine: "Spine1",
        .chest: "Spine2",
        .neck: "Neck",
        .head: "Head",
        .leftShoulder: "L_Shoulder",
        .rightShoulder: "R_Shoulder",
        .leftElbow: "L_Elbow",
        .rightElbow: "R_Elbow",
        .leftWrist: "L_Wrist",
        .rightWrist: "R_Wrist",
        .leftHip: "L_Hip",
        .rightHip: "R_Hip",
        .leftKnee: "L_Knee",
        .rightKnee: "R_Knee",
        .leftAnkle: "L_Ankle",
        .rightAnkle: "R_Ankle",
        .leftToe: "L_Foot",
        .rightToe: "R_Foot",
    ]

    // MARK: - Recording API

    func startRecording(fps: Int = 30, source: MotionClipSource = .manual) {
        guard state == .idle else { return }
        self.fps = fps
        self.source = source
        self.startTime = Date()
        self.jointRotationBuffers = [:]
        self.rootPositionBuffer = []
        self.blendShapeBuffers = [:]
        self.recordedFrameCount = 0
        self.state = .recording
    }

    /// Append a single capture frame to the recording buffers.
    /// Call this from the mocap frame callback.
    func recordFrame(_ frame: UnifiedPoseFrame) {
        guard state == .recording else { return }

        // -- Root position --
        let rootPos: SIMD3<Float>
        if let joints = frame.bodyJoints, let root = joints[.hips] {
            rootPos = root
        } else {
            rootPos = rootPositionBuffer.last ?? .zero
        }
        rootPositionBuffer.append(rootPos)

        // -- Body joint rotations --
        // Convert 3D joint positions to local rotations.
        if let bodyJoints = frame.bodyJoints {
            let rotations = Self.computeLocalRotations(from: bodyJoints)
            for (jointName, quat) in rotations {
                let standardName = Self.jointToStandardName[jointName] ?? jointName.rawValue
                let stored = SIMD4<Float>(quat.imag.x, quat.imag.y, quat.imag.z, quat.real)
                jointRotationBuffers[standardName, default: []].append(stored)
            }
        }

        // Pad any joints that didn't appear this frame with identity quaternion
        let identityQuat = SIMD4<Float>(0, 0, 0, 1)
        for key in jointRotationBuffers.keys {
            if jointRotationBuffers[key]!.count < recordedFrameCount + 1 {
                jointRotationBuffers[key]!.append(identityQuat)
            }
        }

        // -- Blend shapes (from faceBlendShapes) --
        if let faceBlendShapes = frame.faceBlendShapes {
            for (shapeName, weight) in faceBlendShapes {
                blendShapeBuffers[shapeName.rawValue, default: []].append(weight)
            }
        }

        // Pad blend shapes
        for key in blendShapeBuffers.keys {
            if blendShapeBuffers[key]!.count < recordedFrameCount + 1 {
                blendShapeBuffers[key]!.append(0)
            }
        }

        recordedFrameCount += 1
    }

    /// Stop recording and return the finalized MotionClip.
    func stopRecording(name: String = "Untitled Capture") -> MotionClip? {
        guard state == .recording, recordedFrameCount > 0 else {
            state = .idle
            return nil
        }

        state = .finalizing

        let duration = TimeInterval(recordedFrameCount) / TimeInterval(fps)

        let clip = MotionClip(
            name: name,
            source: source,
            fps: fps,
            frameCount: recordedFrameCount,
            duration: duration,
            jointRotations: jointRotationBuffers,
            rootPositions: rootPositionBuffer,
            blendShapeWeights: blendShapeBuffers,
            createdAt: startTime
        )

        // Reset
        state = .idle
        recordedFrameCount = 0
        jointRotationBuffers = [:]
        rootPositionBuffer = []
        blendShapeBuffers = [:]

        return clip
    }

    // MARK: - Position-to-Rotation Conversion

    /// Compute local joint rotations from 3D world-space positions.
    ///
    /// For each parent-child bone pair, we compute the rotation that transforms
    /// the rest-pose bone direction (typically +Y up) to the observed direction.
    static func computeLocalRotations(
        from joints: [JointName: SIMD3<Float>]
    ) -> [JointName: simd_quatf] {
        // Parent-child bone pairs for the Apple Vision skeleton
        let bonePairs: [(parent: JointName, child: JointName)] = [
            (.hips, .spine),
            (.spine, .chest),
            (.chest, .neck),
            (.neck, .head),
            (.hips, .leftHip),
            (.leftHip, .leftKnee),
            (.leftKnee, .leftAnkle),
            (.leftAnkle, .leftToe),
            (.hips, .rightHip),
            (.rightHip, .rightKnee),
            (.rightKnee, .rightAnkle),
            (.rightAnkle, .rightToe),
            (.neck, .leftShoulder),
            (.leftShoulder, .leftElbow),
            (.leftElbow, .leftWrist),
            (.neck, .rightShoulder),
            (.rightShoulder, .rightElbow),
            (.rightElbow, .rightWrist),
        ]

        let restDirection = SIMD3<Float>(0, 1, 0) // +Y up rest pose
        var rotations: [JointName: simd_quatf] = [:]

        for (parentName, childName) in bonePairs {
            guard let parentPos = joints[parentName],
                  let childPos = joints[childName] else { continue }

            let boneDir = childPos - parentPos
            let length = simd_length(boneDir)
            guard length > 1e-6 else { continue }

            let normalizedDir = boneDir / length
            rotations[parentName] = simd_quatf(from: restDirection, to: normalizedDir)
        }

        return rotations
    }
}
