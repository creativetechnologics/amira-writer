import CoreVideo
import Foundation
import simd
import Vision

@available(macOS 26.0, *)
final class VisionBodyTracker: Sendable {

    let onPoseFrame: @Sendable (UnifiedPoseFrame) -> Void

    private let _isBusy = MocapAtomicState(false)
    nonisolated(unsafe) private let request = VNDetectHumanBodyPose3DRequest()
    nonisolated(unsafe) private let faceTracker: any FaceTracker
    nonisolated(unsafe) private let faceSmootherFilter = FaceTrackingSmootherFilter()

    init(onPoseFrame: @escaping @Sendable (UnifiedPoseFrame) -> Void,
         faceTracker: any FaceTracker = VisionFaceTracker()) {
        self.onPoseFrame = onPoseFrame
        self.faceTracker = faceTracker
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard !_isBusy.value else { return }
        _isBusy.value = true

        defer { _isBusy.value = false }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
            try handler.perform([request])
        } catch {
            print("[VisionBodyTracker] Detection failed: \(error.localizedDescription)")
            return
        }

        guard let observation = request.results?.first else {
            return
        }

        let frame = Self.mapObservation(observation, timestamp: timestamp)

        let rawFace = faceTracker.trackSync(pixelBuffer: pixelBuffer, timestamp: timestamp)
        var smoothedFace: [BlendShapeName: Float]?
        if let face = rawFace, face.faceDetected {
            smoothedFace = faceSmootherFilter.smooth(face.blendShapes, timestamp: timestamp)
        }

        let faceFrame = UnifiedPoseFrame(
            timestamp: timestamp,
            source: .appleVision,
            bodyJoints: frame.bodyJoints,
            bodyConfidences: frame.bodyConfidences,
            leftHandJoints: frame.leftHandJoints,
            rightHandJoints: frame.rightHandJoints,
            faceBlendShapes: smoothedFace,
            faceLandmarks: frame.faceLandmarks
        )

        onPoseFrame(faceFrame)
    }

    private static let jointMapping: [(VNHumanBodyPose3DObservation.JointName, JointName)] = [
        (.root, .root),
        (.centerShoulder, .chest),
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
                let col3 = recognized.position.columns.3
                bodyJoints[jointName] = SIMD3<Float>(col3.x, col3.y, col3.z)
                bodyConfidences[jointName] = Float(observation.confidence)
            } catch {
                continue
            }
        }

        if let leftHip = bodyJoints[.leftHip], let rightHip = bodyJoints[.rightHip] {
            bodyJoints[.hips] = (leftHip + rightHip) / 2.0
            let leftConf = bodyConfidences[.leftHip] ?? 0
            let rightConf = bodyConfidences[.rightHip] ?? 0
            bodyConfidences[.hips] = min(leftConf, rightConf)
        }

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