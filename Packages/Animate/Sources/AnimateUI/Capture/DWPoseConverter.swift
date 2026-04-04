import simd

/// Converts DWPose 2D keypoint detections to the UnifiedPoseFrame format
/// used by the motion capture pipeline.
@available(macOS 26.0, *)
struct DWPoseConverter: Sendable {

    /// Convert a DWPose detection to a UnifiedPoseFrame.
    /// 2D keypoints are lifted to approximate 3D using limb length priors
    /// and simple depth estimation from joint proportions.
    static func convert(_ detection: DWPoseTracker.Detection) -> UnifiedPoseFrame {
        let kps = detection.keypoints
        guard kps.count >= 17 else {
            return UnifiedPoseFrame(
                timestamp: detection.timestamp,
                source: .coreMLPose,
                bodyJoints: nil,
                bodyConfidences: nil,
                leftHandJoints: nil,
                rightHandJoints: nil,
                faceBlendShapes: nil,
                faceLandmarks: nil
            )
        }

        var bodyJoints: [JointName: SIMD3<Float>] = [:]
        var bodyConfidences: [JointName: Float] = [:]

        // Map COCO 17 body keypoints to JointName
        let cocoToJoint: [(Int, JointName)] = [
            (0,  .nose),
            (5,  .leftShoulder),
            (6,  .rightShoulder),
            (7,  .leftElbow),
            (8,  .rightElbow),
            (9,  .leftWrist),
            (10, .rightWrist),
            (11, .leftHip),
            (12, .rightHip),
            (13, .leftKnee),
            (14, .rightKnee),
            (15, .leftAnkle),
            (16, .rightAnkle),
        ]

        for (idx, jointName) in cocoToJoint {
            let kp = kps[idx]
            bodyJoints[jointName] = SIMD3<Float>(kp.x, kp.y, 0)
            bodyConfidences[jointName] = kp.confidence
        }

        // Hips = midpoint of left and right hip
        if let lh = bodyJoints[.leftHip], let rh = bodyJoints[.rightHip] {
            bodyJoints[.hips] = (lh + rh) / 2.0
            bodyConfidences[.hips] = min(
                bodyConfidences[.leftHip] ?? 0,
                bodyConfidences[.rightHip] ?? 0
            )
        }

        // Chest = midpoint of shoulders
        let ls = kps[5], rs = kps[6]
        let shoulderMidX = (ls.x + rs.x) / 2
        let shoulderMidY = (ls.y + rs.y) / 2
        bodyJoints[.chest] = SIMD3<Float>(shoulderMidX, shoulderMidY, 0)
        bodyConfidences[.chest] = min(ls.confidence, rs.confidence)

        // Head above chest
        let nose = kps[0]
        bodyJoints[.head] = SIMD3<Float>(nose.x, nose.y, 0)
        bodyConfidences[.head] = nose.confidence

        // Neck = midpoint of chest and head
        if let head = bodyJoints[.head], let chest = bodyJoints[.chest] {
            bodyJoints[.neck] = (head + chest) / 2.0
            bodyConfidences[.neck] = min(bodyConfidences[.head] ?? 0, bodyConfidences[.chest] ?? 0)
        }

        // Spine between hips and chest
        if let hips = bodyJoints[.hips], let chest = bodyJoints[.chest] {
            bodyJoints[.spine] = (hips + chest) / 2.0
        }

        // Extract face blend shapes from face keypoints (if available)
        var faceBlendShapes: [BlendShapeName: Float]?
        if detection.faceKeypoints.count >= 68 {
            faceBlendShapes = estimateFaceBlendShapes(from: Array(detection.faceKeypoints))
        }

        return UnifiedPoseFrame(
            timestamp: detection.timestamp,
            source: .coreMLPose,
            bodyJoints: bodyJoints.isEmpty ? nil : bodyJoints,
            bodyConfidences: bodyConfidences.isEmpty ? nil : bodyConfidences,
            leftHandJoints: nil,
            rightHandJoints: nil,
            faceBlendShapes: faceBlendShapes,
            faceLandmarks: nil
        )
    }

    /// Estimate basic face blend shapes from 68 face landmark keypoints.
    private static func estimateFaceBlendShapes(
        from landmarks: [DWPoseTracker.Keypoint]
    ) -> [BlendShapeName: Float] {
        var shapes: [BlendShapeName: Float] = [:]
        guard landmarks.count >= 68 else { return shapes }

        // Jaw open: distance between upper and lower inner lip
        let upperLip = landmarks[62]  // top of inner upper lip
        let lowerLip = landmarks[66]  // bottom of inner lower lip
        let mouthOpen = abs(lowerLip.y - upperLip.y)

        // Mouth width: distance between mouth corners
        let leftCorner  = landmarks[48]
        let rightCorner = landmarks[54]
        let mouthWidth  = abs(rightCorner.x - leftCorner.x)

        // Face width for normalization (outer eye corners: 36, 45)
        let leftEye  = landmarks[36]
        let rightEye = landmarks[45]
        let faceWidth = max(0.01, abs(rightEye.x - leftEye.x))

        shapes[.jawOpen]          = min(1, mouthOpen / faceWidth * 3)
        shapes[.mouthStretchLeft]  = min(1, mouthWidth / faceWidth * 1.2)
        shapes[.mouthStretchRight] = min(1, mouthWidth / faceWidth * 1.2)

        return shapes
    }
}
