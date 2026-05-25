import AppKit
import Vision
import CoreImage

@available(macOS 26.0, *)
@MainActor
final class ThumbnailBackgroundRemover {
    static let shared = ThumbnailBackgroundRemover()

    private let cache = NSCache<NSString, NSImage>()
    private let processingQueue = DispatchQueue(label: "com.amira.thumbnail-bg-removal", qos: .userInitiated, attributes: .concurrent)

    init() {
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    /// Returns a background-removed thumbnail for display. Returns nil if removal fails (caller should show original).
    func thumbnail(for path: String, size: CGFloat) async -> NSImage? {
        let cacheKey = "\(path)_\(Int(size))"
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        return await withCheckedContinuation { continuation in
            processingQueue.async {
                let result = Self.removeBackground(from: url, targetSize: size)
                DispatchQueue.main.async { [weak self] in
                    if let image = result {
                        let cost = Int(image.size.width) * Int(image.size.height) * 4
                        self?.cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
                    }
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Synchronous background removal — runs Vision ML model.
    private nonisolated static func removeBackground(from url: URL, targetSize: CGFloat) -> NSImage? {
        guard let ciImage = CIImage(contentsOf: url) else { return nil }

        // Scale down for speed — we only need thumbnail size
        let scale = min(targetSize * 2 / ciImage.extent.width, targetSize * 2 / ciImage.extent.height, 1.0)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let handler = VNImageRequestHandler(ciImage: scaledImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let result = request.results?.first else { return nil }

        do {
            let maskPixelBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            let maskCIImage = CIImage(cvPixelBuffer: maskPixelBuffer)

            let context = CIContext()

            // Apply mask: use the foreground mask as alpha
            guard let filter = CIFilter(name: "CIBlendWithMask") else {
                return nil
            }
            filter.setValue(scaledImage, forKey: kCIInputImageKey)
            filter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
            filter.setValue(maskCIImage, forKey: kCIInputMaskImageKey)

            guard let outputCIImage = filter.outputImage,
                  let cgImage = context.createCGImage(outputCIImage, from: outputCIImage.extent) else {
                return nil
            }

            return NSImage(cgImage: cgImage, size: NSSize(width: targetSize, height: targetSize))
        } catch {
            return nil
        }
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func evict(path: String) {
        // Remove all cached sizes for this path
        for size in [60, 80, 100, 120, 150, 200] {
            cache.removeObject(forKey: NSString(string: "\(path)_\(size)"))
        }
    }
}
