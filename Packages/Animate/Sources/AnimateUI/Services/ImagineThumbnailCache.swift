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
    private let inflightLock = NSLock()
    private var inflightLoads: [String: Task<NSImage?, Never>] = [:]

    private var memoryPressureSource: DispatchSourceMemoryPressure?

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

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.memCache.removeAllObjects()
                self.registryLock.lock()
                self.keysByPath.removeAll()
                self.registryLock.unlock()
            } else {
                self.memCache.totalCostLimit = max(
                    50 * 1024 * 1024,
                    self.memCache.totalCostLimit / 2
                )
            }
        }
        source.resume()
        self.memoryPressureSource = source
    }

    // MARK: - Keys

    private func memKey(path: String, maxPixelSize: Int) -> String {
        "\(path)#\(maxPixelSize)"
    }

    private static func diskFileURL(
        base: URL,
        path: String,
        mtime: TimeInterval,
        fileSize: Int64,
        maxPixelSize: Int
    ) -> URL {
        let raw = "\(path)|\(Int(mtime))|\(fileSize)|\(maxPixelSize)"
        let hash = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32)
        return base.appendingPathComponent("\(hash).png")
    }

    private func inflightLoadOrCreate(
        for key: String,
        create: () -> Task<NSImage?, Never>
    ) -> Task<NSImage?, Never> {
        inflightLock.lock()
        if let existing = inflightLoads[key] {
            inflightLock.unlock()
            return existing
        }

        let task = create()
        inflightLoads[key] = task
        inflightLock.unlock()
        return task
    }

    private func clearInflightLoad(for key: String) {
        inflightLock.lock()
        inflightLoads.removeValue(forKey: key)
        inflightLock.unlock()
    }

    private func cacheLoadedImage(_ image: NSImage, key: String, path: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        memCache.setObject(image, forKey: key as NSString, cost: cost)
        registerKey(key, forPath: path)
    }

    private static func loadThumbnail(
        path: String,
        maxPixelSize: Int,
        diskCacheDir: URL
    ) -> NSImage? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let diskURL = Self.diskFileURL(
            base: diskCacheDir,
            path: path,
            mtime: mtime,
            fileSize: fileSize,
            maxPixelSize: maxPixelSize
        )

        if fm.fileExists(atPath: diskURL.path),
           let diskImage = Self.decodeDownsampled(
            url: diskURL,
            maxPixelSize: maxPixelSize
           ) {
            return diskImage
        }

        guard let image = Self.decodeThumbnail(
            path: path,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: diskURL, options: .atomic)
        }

        return image
    }

    private func registerKey(_ key: String, forPath path: String) {
        registryLock.lock()
        keysByPath[path, default: []].insert(key)
        registryLock.unlock()
    }

    private static func maxPixelSize(fromMemKey key: String) -> Int? {
        guard let separatorIndex = key.lastIndex(of: "#") else { return nil }
        return Int(key[key.index(after: separatorIndex)...])
    }

    // MARK: - Public API

    /// Async load: memory → disk → generate. Writes back up the chain.
    func thumbnail(
        for path: String,
        maxPixelSize: Int,
        priority: TaskPriority = .userInitiated
    ) async -> NSImage? {
        let key = memKey(path: path, maxPixelSize: maxPixelSize)
        let nsKey = key as NSString

        if let hit = memCache.object(forKey: nsKey) {
            return hit
        }

        let diskCacheDir = diskCacheDir
        let task = inflightLoadOrCreate(for: key) {
            Task.detached(priority: priority) { () -> NSImage? in
                guard !Task.isCancelled else { return nil }
                return Self.loadThumbnail(
                    path: path,
                    maxPixelSize: maxPixelSize,
                    diskCacheDir: diskCacheDir
                )
            }
        }

        let image = await task.value
        clearInflightLoad(for: key)
        if let image {
            cacheLoadedImage(image, key: key, path: path)
        }
        return image
    }

    /// Synchronous memory-only lookup. Safe to call from SwiftUI bodies —
    /// never touches disk, never stats files.
    func cached(for path: String, maxPixelSize: Int) -> NSImage? {
        let key = memKey(path: path, maxPixelSize: maxPixelSize) as NSString
        return memCache.object(forKey: key)
    }

    /// Memory-only lookup that returns the best already-decoded image for a
    /// path, even if it was cached at a different target size. This lets
    /// larger previews render immediately from an existing grid thumbnail
    /// while a sharper decode is loaded in the background.
    func bestCached(for path: String, minimumPixelSize: Int = 1) -> NSImage? {
        registryLock.lock()
        let keys = Array(keysByPath[path] ?? [])
        registryLock.unlock()

        var smallestAdequate: (pixelSize: Int, image: NSImage)?
        var largestFallback: (pixelSize: Int, image: NSImage)?
        var staleKeys: [String] = []

        for key in keys {
            guard let pixelSize = Self.maxPixelSize(fromMemKey: key) else { continue }
            guard let image = memCache.object(forKey: key as NSString) else {
                staleKeys.append(key)
                continue
            }

            if pixelSize >= minimumPixelSize {
                if smallestAdequate == nil || pixelSize < smallestAdequate!.pixelSize {
                    smallestAdequate = (pixelSize, image)
                }
            } else if largestFallback == nil || pixelSize > largestFallback!.pixelSize {
                largestFallback = (pixelSize, image)
            }
        }

        if !staleKeys.isEmpty {
            registryLock.lock()
            if var registeredKeys = keysByPath[path] {
                for key in staleKeys {
                    registeredKeys.remove(key)
                }
                keysByPath[path] = registeredKeys.isEmpty ? nil : registeredKeys
            }
            registryLock.unlock()
        }

        return smallestAdequate?.image ?? largestFallback?.image
    }

    /// Fire-and-forget batch warming. Keep this intentionally conservative:
    /// large image galleries can otherwise saturate ImageIO/AppleJPEG and make
    /// the UI feel beachballed even though decoding is technically off-main.
    func prefetch(paths: [String], maxPixelSize: Int) {
        var uniquePaths: [String] = []
        uniquePaths.reserveCapacity(paths.count)
        for path in paths where !uniquePaths.contains(path) {
            uniquePaths.append(path)
        }
        guard !uniquePaths.isEmpty else { return }

        let isLargePreview = maxPixelSize >= 1200
        let concurrencyLimit = isLargePreview ? 1 : 2
        let cappedPaths = Array(uniquePaths.prefix(isLargePreview ? 1 : 48))

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var inflight = 0
                for path in cappedPaths {
                    if Task.isCancelled {
                        break
                    }
                    if inflight >= concurrencyLimit {
                        await group.next()
                        inflight -= 1
                    }
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        _ = await self.thumbnail(
                            for: path,
                            maxPixelSize: maxPixelSize,
                            priority: .utility
                        )
                    }
                    inflight += 1
                }
                while inflight > 0 {
                    await group.next()
                    inflight -= 1
                }
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

    private static func decodeThumbnail(path: String, maxPixelSize: Int) -> NSImage? {
        decodeDownsampled(url: URL(fileURLWithPath: path), maxPixelSize: maxPixelSize)
    }

    private static func decodeDownsampled(url: URL, maxPixelSize: Int) -> NSImage? {
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
