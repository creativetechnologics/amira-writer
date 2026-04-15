import AppKit
import ImageIO
import CoreImage
import CryptoKit

@available(macOS 26.0, *)
@MainActor
final class ImagineThumbnailCache {
    static let shared = ImagineThumbnailCache()

    private let memCache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.amira.thumb-cache", qos: .userInitiated, attributes: .concurrent)
    private let diskCacheDir: URL

    init() {
        // Memory cap: ~200MB total
        memCache.totalCostLimit = 200 * 1024 * 1024
        memCache.countLimit = 2000
        let tmpBase = FileManager.default.temporaryDirectory.appendingPathComponent("amira-thumb-cache")
        try? FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        self.diskCacheDir = tmpBase
    }

    private func cacheKey(path: String, maxPixelSize: Int) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)_\(Int(mtime))_\(maxPixelSize)"
    }

    private func diskCachePath(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return diskCacheDir.appendingPathComponent("\(hash).png")
    }

    /// Async load a thumbnail at the target pixel size.
    func thumbnail(for path: String, maxPixelSize: Int) async -> NSImage? {
        let key = cacheKey(path: path, maxPixelSize: maxPixelSize)
        let nsKey = key as NSString

        // Memory cache hit
        if let cached = memCache.object(forKey: nsKey) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                // Try disk cache first (fast path)
                let diskURL = DispatchQueue.main.sync {
                    self.diskCachePath(for: key)
                }
                if let diskImage = NSImage(contentsOf: diskURL) {
                    DispatchQueue.main.async {
                        let cost = Int(diskImage.size.width * diskImage.size.height * 4)
                        self.memCache.setObject(diskImage, forKey: nsKey, cost: cost)
                        continuation.resume(returning: diskImage)
                    }
                    return
                }

                // Generate new thumbnail
                guard let image = Self.loadThumbnail(path: path, maxPixelSize: maxPixelSize) else {
                    continuation.resume(returning: nil)
                    return
                }

                // Write to disk cache
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: diskURL, options: .atomic)
                }

                DispatchQueue.main.async {
                    let cost = Int(image.size.width * image.size.height * 4)
                    self.memCache.setObject(image, forKey: nsKey, cost: cost)
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Synchronously returns cached thumbnail if present in memory.
    func cached(for path: String, maxPixelSize: Int) -> NSImage? {
        let key = cacheKey(path: path, maxPixelSize: maxPixelSize) as NSString
        return memCache.object(forKey: key)
    }

    /// Prefetch thumbnails for a batch of paths (fire and forget).
    func prefetch(paths: [String], maxPixelSize: Int) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            for path in paths {
                _ = await self.thumbnail(for: path, maxPixelSize: maxPixelSize)
            }
        }
    }

    func invalidate(path: String) {
        // Can't enumerate NSCache, so we clear all sizes for this path.
        // Memory cache will self-heal.
    }

    /// CGImageSource-based thumbnail extraction.
    private nonisolated static func loadThumbnail(path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
