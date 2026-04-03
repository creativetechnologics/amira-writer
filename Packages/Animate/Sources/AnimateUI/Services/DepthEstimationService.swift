import Foundation
import CoreML
import Vision
import AppKit

/// Estimates monocular depth from a 2D image using Depth Anything V2 CoreML model.
///
/// The CoreML model (DepthAnythingV2Small.mlmodel or DepthAnythingV2Large.mlmodel)
/// must be bundled in the app's resource bundle at `Resources/DepthAnything/`.
/// If the model is unavailable, returns a linear depth gradient fallback.
///
/// Output depth maps are used by SceneDepthManager for parallax layering of
/// background plates and character compositing in the 3D production engine.
@available(macOS 26.0, *)
struct DepthEstimationService: Sendable {

    enum DepthError: LocalizedError {
        case modelNotFound
        case predictionFailed(String)
        case imageConversionFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Depth Anything V2 CoreML model not found. Bundle 'DepthAnythingV2Small.mlpackage' in Resources/DepthAnything/."
            case .predictionFailed(let msg):
                return "Depth prediction failed: \(msg)"
            case .imageConversionFailed:
                return "Could not convert image for depth estimation."
            }
        }
    }

    /// A normalized depth map (values 0.0–1.0, where 1.0 = farthest).
    struct DepthMap: Sendable {
        let width: Int
        let height: Int
        let values: [Float]          // Row-major, normalized 0…1
        let source: Source

        enum Source: Sendable {
            case coreML
            case linearFallback
        }

        /// Sample depth at normalized coordinates (0…1).
        func depth(atX x: Double, y: Double) -> Float {
            let px = min(max(Int(x * Double(width)), 0), width - 1)
            let py = min(max(Int(y * Double(height)), 0), height - 1)
            return values[py * width + px]
        }
    }

    /// Estimate depth for an image file.
    static func estimateDepth(imageURL: URL) async throws -> DepthMap {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DepthError.imageConversionFailed
        }
        return try await estimateDepth(cgImage: cgImage)
    }

    /// Estimate depth for a CGImage.
    static func estimateDepth(cgImage: CGImage) async throws -> DepthMap {
        // Try CoreML model first
        if let map = try? await runCoreMLModel(cgImage: cgImage) {
            return map
        }
        // Fallback: linear gradient (objects at bottom of frame = closer)
        return linearFallback(width: cgImage.width, height: cgImage.height)
    }

    // MARK: - CoreML

    private static func runCoreMLModel(cgImage: CGImage) async throws -> DepthMap {
        // Look for the model in the app bundle
        guard let modelURL = findModelURL() else {
            throw DepthError.modelNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine
                    let model = try MLModel(contentsOf: modelURL, configuration: config)

                    // Use VNCoreMLRequest for custom CoreML depth models (e.g. Depth Anything V2).
                    // The model output is expected to be a single-channel float MLMultiArray
                    // which we reshape into a DepthMap.
                    let vnModel = try VNCoreMLModel(for: model)
                    let request = VNCoreMLRequest(model: vnModel) { req, error in
                        if let error {
                            continuation.resume(throwing: DepthError.predictionFailed(error.localizedDescription))
                            return
                        }
                        // Extract depth from MLFeatureValue in observation
                        guard let obs = req.results?.first as? VNCoreMLFeatureValueObservation,
                              let multiArray = obs.featureValue.multiArrayValue else {
                            // Model output format not handled — fall back via error
                            continuation.resume(throwing: DepthError.predictionFailed("Unexpected model output format"))
                            return
                        }
                        let map = multiArrayToDepthMap(multiArray)
                        continuation.resume(returning: map)
                    }
                    let handler = VNImageRequestHandler(cgImage: cgImage)
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: DepthError.predictionFailed(error.localizedDescription))
                }
            }
        }
    }

    private static func findModelURL() -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "DepthAnythingV2Small", withExtension: "mlmodelc"),
            Bundle.main.url(forResource: "DepthAnythingV2Large", withExtension: "mlmodelc"),
        ]
        return candidates.compactMap { $0 }.first
    }

    private static func multiArrayToDepthMap(_ array: MLMultiArray) -> DepthMap {
        // Depth Anything V2 typically outputs shape [1, H, W] or [H, W]
        let shape = array.shape.map { $0.intValue }
        let h = shape.count >= 2 ? shape[shape.count - 2] : 1
        let w = shape.count >= 1 ? shape[shape.count - 1] : 1
        var raw = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            raw[i] = array[i].floatValue
        }
        let minV = raw.min() ?? 0
        let maxV = raw.max() ?? 1
        let range = max(maxV - minV, 1e-6)
        raw = raw.map { ($0 - minV) / range }
        return DepthMap(width: w, height: h, values: raw, source: .coreML)
    }

    private static func pixelBufferToDepthMap(_ buffer: CVPixelBuffer) -> DepthMap {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let baseAddr = CVPixelBufferGetBaseAddress(buffer) else {
            return linearFallback(width: w, height: h)
        }
        let floatPtr = baseAddr.assumingMemoryBound(to: Float.self)
        var raw = Array(UnsafeBufferPointer(start: floatPtr, count: w * h))
        // Normalize to 0…1
        let minV = raw.min() ?? 0
        let maxV = raw.max() ?? 1
        let range = max(maxV - minV, 1e-6)
        raw = raw.map { ($0 - minV) / range }
        return DepthMap(width: w, height: h, values: raw, source: .coreML)
    }

    // MARK: - Fallback

    private static func linearFallback(width: Int, height: Int) -> DepthMap {
        // Objects near bottom of frame are closer (depth 0.0), top is farthest (1.0)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let depth = Float(y) / Float(max(height - 1, 1))
            let invDepth = 1.0 - depth   // bottom rows = near = low depth value
            for x in 0..<width {
                values[y * width + x] = invDepth
            }
        }
        return DepthMap(width: width, height: height, values: values, source: .linearFallback)
    }
}
