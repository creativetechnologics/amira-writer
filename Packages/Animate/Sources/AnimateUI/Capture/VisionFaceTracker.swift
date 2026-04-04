import CoreVideo
import Foundation

@available(macOS 26.0, *)
final class VisionFaceTracker: FaceTracker, Sendable {

    private let extractor = VisionFaceLandmarkExtractor()
    private let estimator = BlendShapeEstimator()

    func track(pixelBuffer: CVPixelBuffer, timestamp: Double) async -> FaceTrackingResult? {
        trackSync(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    func trackSync(pixelBuffer: CVPixelBuffer, timestamp: Double) -> FaceTrackingResult? {
        guard let landmarks = extractor.extractSync(from: pixelBuffer) else {
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
    }
}
