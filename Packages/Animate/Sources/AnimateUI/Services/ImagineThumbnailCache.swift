import AppKit
import Foundation
import ImageIO
import CoreImage
import CryptoKit

/// Two-tier thumbnail cache shared across all Amira Writer grids.
///
/// - Memory: `NSCache<NSString, NSImage>` keyed by `path + maxPixelSize` (no
///   mtime). `cached(for:)` is a pure memory lookup — **no FileManager
///   syscalls** on the synchronous hot path, so SwiftUI bodies stay cheap.
/// - Disk: PNGs in `~/Library/Caches/com.amira.writer/thumbs/`, keyed by
///   SHA256(path + mtime + size). Mtime goes in the disk key so edited files
///   naturally miss. Stats happen only on memory miss, off the main thread.
///
/// Class is **nonisolated**. `NSCache` is documented thread-safe; the key
/// registry is guarded by a lock. `shared` is callable from any actor.
@available(macOS 26.0, *)
final class ImagineThumbnailCache: @unchecked Sendable {
    static let shared = ImagineThumbnailCache()

    private let memCache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(
        label: "com.amira.thumb-cache",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let diskCacheDir: URL

    private let registryLock = NSLock()
    private var keysByPath: [String: Set<String>] = [:]

    init() {
        memCache.totalCostLimit = 200 * 1024 * 1024
        memCache.countLimit = 2000

        let base: URL
        if let cachesDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first {
            base = cachesDir.appendingPathComponent("com.amira.writer/thumbs")
        } else {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("amira-thumb-cache")
        }
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        self.diskCacheDir = base
    }

    // MARK: - Keys

    private func memKey(path: String, maxPixelSize: Int) -> String {
        "\(path)#\(maxPixelSize)"
    }

    private func diskFileURL(
        path: String,
        mtime: TimeInterval,
        maxPixelSize: Int
    ) -> URL {
        let raw = "\(path)|\(Int(mtime))|\(maxPixelSize)"
        let hash = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32)
        return diskCacheDir.appendingPathComponent("\(hash).png")
    }

    private func registerKey(_ key: String, forPath path: String) {
        registryLock.lock()
        keysByPath[path, default: []].insert(key)
        registryLock.unlock()
    }

    // MARK: - Public API

    /// Async load: memory → disk → generate. Writes back up the chain.
    func thumbnail(for path: String, maxPixelSize: Int) async -> NSImage? {
        let key = memKey(path: path, maxPixelSize: maxPixelSize)
        let nsKey = key as NSString

        if let hit = memCache.object(forKey: nsKey) {
            return hit
        }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                let mtime = (try? FileManager.default
                    .attributesOfItem(atPath: path)[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? 0
                let diskURL = self.diskFileURL(
                    path: path,
                    mtime: mtime,
                    maxPixelSize: maxPixelSize
                )

                if let diskImage = NSImage(contentsOf: diskURL) {
                    let cost = Int(diskImage.size.width * diskImage.size.height * 4)
                    self.memCache.setObject(diskImage, forKey: nsKey, cost: cost)
                    self.registerKey(key, forPath: path)
                    continuation.resume(returning: diskImage)
                    return
                }

                guard let image = Self.loadThumbnail(
                    path: path,
                    maxPixelSize: maxPixelSize
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: diskURL, options: .atomic)
                }

                let cost = Int(image.size.width * image.size.height * 4)
                self.memCache.setObject(image, forKey: nsKey, cost: cost)
                self.registerKey(key, forPath: path)
                continuation.resume(returning: image)
            }
        }
    }

    /// Synchronous memory-only lookup. Safe to call from SwiftUI bodies —
    /// never touches disk, never stats files.
    func cached(for path: String, maxPixelSize: Int) -> NSImage? {
        let key = memKey(path: path, maxPixelSize: maxPixelSize) as NSString
        return memCache.object(forKey: key)
    }

    /// Fire-and-forget batch warming.
    func prefetch(paths: [String], maxPixelSize: Int) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            for path in paths {
                _ = await self.thumbnail(for: path, maxPixelSize: maxPixelSize)
            }
        }
    }

    /// After overwriting a file, drop its memory entries across all sizes.
    /// Disk entries self-invalidate via mtime change.
    func invalidate(path: String) {
        registryLock.lock()
        let keys = keysByPath.removeValue(forKey: path) ?? []
        registryLock.unlock()
        for k in keys {
            memCache.removeObject(forKey: k as NSString)
        }
    }

    // MARK: - Decoder

    private static func loadThumbnail(path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
