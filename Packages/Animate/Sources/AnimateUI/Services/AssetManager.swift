import AppKit
import Foundation
import ImageIO

/// Manages character images and background plates within an OWP project's Animate/ directory.
/// Handles import, thumbnail caching, and file organization.
@available(macOS 26.0, *)
@MainActor
final class AssetManager {
    private let thumbnailCache = NSCache<NSString, NSImage>()

    init() {
        thumbnailCache.countLimit = 500
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
        let charDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(characterSlug)
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
        let charDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(characterSlug)
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
            thumbnailCache.setObject(thumb, forKey: cacheKey)
        }

        return thumb
    }

    /// Load a thumbnail asynchronously — returns cached image immediately or generates off-main-thread.
    func thumbnailAsync(for url: URL, maxSize: CGFloat = 120) async -> NSImage? {
        let cacheKey = "\(url.path)#\(Int(maxSize.rounded()))" as NSString

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        let targetSize = max(64, Int(maxSize.rounded() * 2))
        let path = url.path
        let thumb = await Task.detached(priority: .medium) {
            guard let imageSource = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, nil
            ) else { return nil as NSImage? }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetSize,
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource, 0, options as CFDictionary
            ) else { return nil as NSImage? }

            let size = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            return NSImage(cgImage: cgImage, size: size)
        }.value

        if let thumb {
            thumbnailCache.setObject(thumb, forKey: cacheKey)
        }
        return thumb
    }

    /// Clear the thumbnail cache.
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    /// Invalidate the cached thumbnail for a specific file (e.g., after overwriting).
    func invalidateThumbnail(for url: URL) {
        let cacheKey = url.path as NSString
        thumbnailCache.removeObject(forKey: cacheKey)
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
            kCGImageSourceThumbnailMaxPixelSize: targetSize
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
