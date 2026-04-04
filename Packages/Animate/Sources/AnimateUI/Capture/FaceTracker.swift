import CoreVideo
import Foundation

@available(macOS 26.0, *)
struct FaceTrackingResult: Sendable {
    let blendShapes: [BlendShapeName: Float]
    let confidence: Float
    let timestamp: Double

    var faceDetected: Bool { confidence > 0.1 }
}

@available(macOS 26.0, *)
protocol FaceTracker: Sendable {
    func track(pixelBuffer: CVPixelBuffer, timestamp: Double) async -> FaceTrackingResult?
    func trackSync(pixelBuffer: CVPixelBuffer, timestamp: Double) -> FaceTrackingResult?
    func reset() async
}
