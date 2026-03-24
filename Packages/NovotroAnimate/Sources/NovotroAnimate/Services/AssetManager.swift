import AppKit
import Foundation

/// Manages character images and background plates within an OWP project's Animate/ directory.
/// Handles import, thumbnail caching, and file organization.
@available(macOS 26.0, *)
@MainActor
final class AssetManager {
    private let thumbnailCache = NSCache<NSURL, NSImage>()

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
        let nsURL = url as NSURL

        if let cached = thumbnailCache.object(forKey: nsURL) {
            return cached
        }

        guard let image = NSImage(contentsOf: url) else { return nil }

        let thumb = generateThumbnail(from: image, maxSize: maxSize)
        if let thumb {
            thumbnailCache.setObject(thumb, forKey: nsURL)
        }

        return thumb
    }

    /// Clear the thumbnail cache.
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
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

    private func generateThumbnail(from image: NSImage, maxSize: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxSize / size.width
        } else {
            scale = maxSize / size.height
        }

        let thumbSize = NSSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )

        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: thumbSize),
            from: NSRect(origin: .zero, size: size),
            operation: .sourceOver,
            fraction: 1.0
        )
        thumb.unlockFocus()

        return thumb
    }
}
