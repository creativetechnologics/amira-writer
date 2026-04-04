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

    nonisolated(unsafe) private let model: VNCoreMLModel

    init() throws {
        // The .mlmodelc should be added to the app bundle.
        // Model conversion: python3 convert_dwpose_coreml.py dwpose.onnx
        guard let modelURL = Bundle.main.url(forResource: "DWPose", withExtension: "mlmodelc") else {
            throw TrackerError.modelNotFound
        }
        let mlModel = try MLModel(contentsOf: modelURL)
        self.model = try VNCoreMLModel(for: mlModel)
    }

    /// Detect keypoints in a pixel buffer.
    func detect(in pixelBuffer: CVPixelBuffer, at timestamp: Double) throws -> Detection {
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
            let x    = multiArray[[0, i, 0] as [NSNumber]].floatValue
            let y    = multiArray[[0, i, 1] as [NSNumber]].floatValue
            let conf = multiArray[[0, i, 2] as [NSNumber]].floatValue
            keypoints.append(Keypoint(x: x, y: y, confidence: conf))
        }

        return Detection(keypoints: keypoints, timestamp: timestamp)
    }
}
