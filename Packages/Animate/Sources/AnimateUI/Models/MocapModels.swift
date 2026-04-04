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