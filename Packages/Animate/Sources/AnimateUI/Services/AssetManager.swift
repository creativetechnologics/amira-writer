import AppKit
import CryptoKit
import Foundation
import ImageIO
import ProjectKit

/// Manages character images and background plates within an OWP project's Animate/ directory.
/// Handles import, thumbnail caching, and file organization.
@available(macOS 26.0, *)
@MainActor
final class AssetManager {
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let thumbnailQueue = DispatchQueue(
        label: "com.amira.asset-thumb-load",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Tracks every cache key stored for a given path so `invalidateThumbnail`
    /// can remove all size variants without guessing which sizes were used.
    private var keysByPath: [String: Set<String>] = [:]
    nonisolated private let diskCacheDir: URL

    init() {
        thumbnailCache.countLimit = 500
        thumbnailCache.totalCostLimit = 150 * 1024 * 1024 // 150 MB

        let base: URL
        if let cachesDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first {
            base = cachesDir.appendingPathComponent("com.amira.writer/asset-thumbs")
        } else {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("amira-asset-thumbs")
        }
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        self.diskCacheDir = base
    }

    nonisolated private static func diskCacheFileURL(
        base: URL,
        path: String,
        mtime: TimeInterval,
        maxSize: Int
    ) -> URL {
        let raw = "\(path)|\(Int(mtime))|\(maxSize)"
        let hash = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32)
        return base.appendingPathComponent("\(hash).png")
    }

    // MARK: - Import

    /// Import a character image into the Animate/characters/ directory.
    func importCharacterImage(
        from sourceURL: URL,
        characterSlug: String,
        category: String,
        animateURL: URL
    ) throws -> String {
        try importCharacterImageURL(
            from: sourceURL,
            characterSlug: characterSlug,
            category: category,
            animateURL: animateURL
        ).lastPathComponent
    }

    func importCharacterImageURL(
        from sourceURL: URL,
        characterSlug: String,
        category: String,
        animateURL: URL
    ) throws -> URL {
        let charDir = ProjectPaths(root: animateURL.deletingLastPathComponent())
            .characterFolder(slug: characterSlug)
            .appendingPathComponent(category)

        try FileManager.default.createDirectory(at: charDir, withIntermediateDirectories: true)

        let destURL = uniqueDestination(for: sourceURL.lastPathComponent, in: charDir)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        return destURL
    }

    func writeCharacterImageData(
        _ data: Data,
        suggestedFilename: String,
        characterSlug: String,
        category: String,
        animateURL: URL
    ) throws -> URL {
        let charDir = ProjectPaths(root: animateURL.deletingLastPathComponent())
            .characterFolder(slug: characterSlug)
            .appendingPathComponent(category)

        try FileManager.default.createDirectory(at: charDir, withIntermediateDirectories: true)

        let destURL = uniqueDestination(for: suggestedFilename, in: charDir)
        try data.write(to: destURL)
        return destURL
    }

    /// Import a background image into the Animate/backgrounds/ directory.
    func importBackgroundImage(
        from sourceURL: URL,
        animateURL: URL
    ) throws -> URL {
        let bgDir = animateURL.appendingPathComponent("backgrounds")
        try FileManager.default.createDirectory(at: bgDir, withIntermediateDirectories: true)

        let destURL = uniqueDestination(for: sourceURL.lastPathComponent, in: bgDir)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        return destURL
    }

    // MARK: - Thumbnails

    /// Get a cached thumbnail for an image file. Generates on cache miss.
    func thumbnail(for url: URL, maxSize: CGFloat = 120) -> NSImage? {
        let cacheKey = "\(url.path)#\(Int(maxSize.rounded()))" as NSString

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        let thumb = generateThumbnail(from: url, maxSize: maxSize)
        if let thumb {
            let cost = Int(thumb.size.width) * Int(thumb.size.height) * 4
            thumbnailCache.setObject(thumb, forKey: cacheKey, cost: cost)
            let key = cacheKey as String
            keysByPath[url.path, default: []].insert(key)
        }

        return thumb
    }

    /// Return a thumbnail ONLY if it's already in the cache. Never generates.
    /// Used by SwiftUI bodies on the hot path (character selection, grid
    /// rendering) so a cache miss never blocks the main thread for a full
    /// image decode. Pair with `thumbnailAsync` in a `.task` to fill the
    /// cache off-main after the first render.
    func cachedThumbnail(for url: URL, maxSize: CGFloat = 120) -> NSImage? {
        let cacheKey = "\(url.path)#\(Int(maxSize.rounded()))" as NSString
        return thumbnailCache.object(forKey: cacheKey)
    }

    /// Cache hit by an arbitrary identifier string. Thumbnail grids use the
    /// unresolved input path here so they can avoid the up-to-4 fileExists
    /// checks of URL resolution on every render cycle. The async loader
    /// writes the image under *both* the identifier key and the resolved
    /// URL key so later URL-keyed lookups still find it.
    func cachedThumbnail(forIdentifier identifier: String, maxSize: CGFloat = 120) -> NSImage? {
        let cacheKey = "id:\(identifier)#\(Int(maxSize.rounded()))" as NSString
        return thumbnailCache.object(forKey: cacheKey)
    }

    /// Store a thumbnail under a caller-supplied identifier as well as its
    /// resolved URL. Lets hot-path views key by the original input path to
    /// skip URL resolution on cache hits.
    func storeThumbnail(_ image: NSImage, forIdentifier identifier: String, maxSize: CGFloat) {
        let cacheKey = "id:\(identifier)#\(Int(maxSize.rounded()))" as NSString
        let cost = Int(image.size.width) * Int(image.size.height) * 4
        thumbnailCache.setObject(image, forKey: cacheKey, cost: cost)
        // identifier keys are not path-keyed, so no keysByPath registration needed here
    }

    /// Load a thumbnail asynchronously — returns cached image immediately or generates off-main-thread.
    /// Checks memory → disk (`~/Library/Caches/com.amira.writer/asset-thumbs/`) → CGImageSource in that order.
    /// Disk entries are SHA256-keyed by path+mtime+size so edits naturally miss and regenerate.
    func thumbnailAsync(for url: URL, maxSize: CGFloat = 120) async -> NSImage? {
        let cacheKey = "\(url.path)#\(Int(maxSize.rounded()))" as NSString

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard !Task.isCancelled else { return nil }

        let targetSize = max(64, Int(maxSize.rounded() * 2))
        let path = url.path
        let diskBase = diskCacheDir
        let thumb = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            thumbnailQueue.async {
                let mtime = (try? FileManager.default
                    .attributesOfItem(atPath: path)[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? 0
                let diskURL = Self.diskCacheFileURL(
                    base: diskBase,
                    path: path,
                    mtime: mtime,
                    maxSize: targetSize
                )

                if let diskImage = NSImage(contentsOf: diskURL) {
                    continuation.resume(returning: diskImage)
                    return
                }

                guard let imageSource = CGImageSourceCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, nil
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: targetSize,
                    kCGImageSourceShouldCacheImmediately: true,
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    imageSource, 0, options as CFDictionary
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                let size = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                let image = NSImage(cgImage: cgImage, size: size)

                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: diskURL, options: .atomic)
                }

                continuation.resume(returning: image)
            }
        }

        if Task.isCancelled {
            return nil
        }

        if let thumb {
            let cost = Int(thumb.size.width) * Int(thumb.size.height) * 4
            thumbnailCache.setObject(thumb, forKey: cacheKey, cost: cost)
            let key = cacheKey as String
            keysByPath[url.path, default: []].insert(key)
        }
        return thumb
    }

    /// Clear the thumbnail cache.
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
        keysByPath.removeAll()
    }

    /// Invalidate all cached size variants for a specific file (e.g., after overwriting).
    func invalidateThumbnail(for url: URL) {
        let path = url.path
        if let keys = keysByPath.removeValue(forKey: path) {
            for key in keys {
                thumbnailCache.removeObject(forKey: key as NSString)
            }
        }
    }

    // MARK: - File Listing

    /// List all image files in a directory, recursively.
    func listImages(in directoryURL: URL) -> [URL] {
        let fm = FileManager.default
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "webp"]

        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }

        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Private

    private func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var dest = directory.appendingPathComponent(filename)

        if fm.fileExists(atPath: dest.path) {
            let name = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var counter = 2
            repeat {
                dest = directory.appendingPathComponent("\(name)-\(counter).\(ext)")
                counter += 1
            } while fm.fileExists(atPath: dest.path)
        }

        return dest
    }

    private func generateThumbnail(from url: URL, maxSize: CGFloat) -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let targetSize = max(64, Int(maxSize.rounded() * 2))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let thumbSize = NSSize(
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        )
        return NSImage(cgImage: cgImage, size: thumbSize)
    }
}
