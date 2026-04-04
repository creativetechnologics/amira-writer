import CoreVideo
import Foundation
import Vision

@available(macOS 26.0, *)
struct VisionFaceLandmarks: Sendable {
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
    let boundingBox: CGRect
    let confidence: Float
}

@available(macOS 26.0, *)
final class VisionFaceLandmarkExtractor: Sendable {

    func extract(from pixelBuffer: CVPixelBuffer) async -> VisionFaceLandmarks? {
        await withCheckedContinuation { continuation in
            continuation.resume(returning: extractSync(from: pixelBuffer))
        }
    }

    func extractSync(from pixelBuffer: CVPixelBuffer) -> VisionFaceLandmarks? {
        var result: VisionFaceLandmarks?
        let request = VNDetectFaceLandmarksRequest { req, error in
            guard error == nil,
                  let results = req.results as? [VNFaceObservation],
                  let face = results.first,
                  let landmarks = face.landmarks
            else { return }

            result = VisionFaceLandmarks(
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
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
        return result
    }

    private static func points(from region: VNFaceLandmarkRegion2D?) -> [SIMD2<Float>] {
        guard let region else { return [] }
        let pointCount = region.pointCount
        guard pointCount > 0 else { return [] }
        let buffer = region.normalizedPoints
        return (0..<pointCount).map { i in
            let p = buffer[i]
            return SIMD2<Float>(Float(p.x), Float(p.y))
        }
    }
}
