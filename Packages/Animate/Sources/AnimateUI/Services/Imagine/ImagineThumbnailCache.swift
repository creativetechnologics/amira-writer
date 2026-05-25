import AppKit
import Foundation
import ImageIO
import CoreImage
import CryptoKit

/// Two-tier thumbnail cache shared across all Amira Writer grids.
///
/// - Memory: `NSCache<NSString, NSImage>` keyed by canonical path + bucketed
///   pixel size. `cached(for:)` is a pure memory lookup — **no FileManager
///   syscalls** on the synchronous hot path, so SwiftUI bodies stay cheap.
/// - Disk: PNGs in `~/Library/Caches/com.amira.writer/thumbs/`, keyed by
///   SHA256(canonical path + mtime + file size + bucketed size). Mtime and
///   size naturally invalidate edited files, while symlink-resolved paths and
///   size buckets prevent the app from rebuilding near-identical thumbnails.
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
    private var canonicalPathByRawPath: [String: String] = [:]
    private let inflightLock = NSLock()
    private var inflightLoads: [String: Task<(NSImage, ThumbnailLoadSource)?, Never>] = [:]
    private let statsLock = NSLock()
    private var stats = ThumbnailCacheStats()

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
        "\(canonicalPath(for: path))#\(bucketedPixelSize(maxPixelSize))"
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

    private static let sizeBuckets = [64, 128, 256, 320, 512, 768, 1024, 1600, 2400]

    private struct ThumbnailCacheStats {
        var memoryHits = 0
        var diskExactHits = 0
        var diskNearestHits = 0
        var originalDecodes = 0
        var misses = 0
    }

    private enum ThumbnailLoadSource {
        case diskExact
        case diskNearest
        case originalDecode
    }

    private func canonicalPath(for path: String) -> String {
        registryLock.lock()
        if let cached = canonicalPathByRawPath[path] {
            registryLock.unlock()
            return cached
        }
        registryLock.unlock()

        let canonical = Self.canonicalPath(for: path)

        registryLock.lock()
        canonicalPathByRawPath[path] = canonical
        registryLock.unlock()
        return canonical
    }

    private static func canonicalPath(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        guard trimmed.hasPrefix("/") else { return trimmed }

        let url = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: trimmed) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.standardizedFileURL.path
    }

    private func bucketedPixelSize(_ requested: Int) -> Int {
        Self.bucketedPixelSize(requested)
    }

    private static func bucketedPixelSize(_ requested: Int) -> Int {
        let clamped = max(1, requested)
        return sizeBuckets.first(where: { $0 >= clamped }) ?? clamped
    }

    private static func candidatePixelSizes(for requested: Int) -> [Int] {
        let bucket = bucketedPixelSize(requested)
        var sizes = sizeBuckets.filter { $0 >= bucket }
        if !sizes.contains(bucket) {
            sizes.insert(bucket, at: 0)
        }
        return sizes
    }

    private static func legacyIdentityPaths(rawPath: String, canonicalPath: String) -> [String] {
        var out: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, !out.contains(path) else { return }
            out.append(path)
        }

        append(canonicalPath)
        append(rawPath)

        let storageUsersPrefix = "/Volumes/Storage VIII/Users/gary/"
        if canonicalPath.hasPrefix(storageUsersPrefix) {
            append("/Users/gary/" + canonicalPath.dropFirst(storageUsersPrefix.count))
        }

        return out
    }

    private func recordStat(_ update: (inout ThumbnailCacheStats) -> Void) {
        statsLock.lock()
        update(&stats)
        let snapshot = stats
        statsLock.unlock()

        let meaningfulEvents = snapshot.diskExactHits + snapshot.diskNearestHits + snapshot.originalDecodes + snapshot.misses
        guard meaningfulEvents > 0, meaningfulEvents % 50 == 0 else { return }
        AppLog.log(
            "THUMB_CACHE",
            "memory=\(snapshot.memoryHits) diskExact=\(snapshot.diskExactHits) diskNearest=\(snapshot.diskNearestHits) originalDecode=\(snapshot.originalDecodes) miss=\(snapshot.misses)"
        )
    }

    private func inflightLoadOrCreate(
        for key: String,
        create: () -> Task<(NSImage, ThumbnailLoadSource)?, Never>
    ) -> Task<(NSImage, ThumbnailLoadSource)?, Never> {
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
        canonicalPath: String,
        requestedPixelSize: Int,
        bucketedPixelSize: Int,
        diskCacheDir: URL
    ) -> (image: NSImage, source: ThumbnailLoadSource)? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: canonicalPath)
        let mtime = (attrs?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        for identityPath in Self.legacyIdentityPaths(rawPath: path, canonicalPath: canonicalPath) {
            for candidateSize in Self.candidatePixelSizes(for: requestedPixelSize) {
                let diskURL = Self.diskFileURL(
                    base: diskCacheDir,
                    path: identityPath,
                    mtime: mtime,
                    fileSize: fileSize,
                    maxPixelSize: candidateSize
                )

                if fm.fileExists(atPath: diskURL.path),
                   let diskImage = Self.decodeDownsampled(
                    url: diskURL,
                    maxPixelSize: candidateSize
                   ) {
                    return (diskImage, candidateSize == bucketedPixelSize ? .diskExact : .diskNearest)
                }
            }
        }

        guard let image = Self.decodeThumbnail(
            path: canonicalPath,
            maxPixelSize: bucketedPixelSize
        ) else {
            return nil
        }

        let diskURL = Self.diskFileURL(
            base: diskCacheDir,
            path: canonicalPath,
            mtime: mtime,
            fileSize: fileSize,
            maxPixelSize: bucketedPixelSize
        )
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: diskURL, options: .atomic)
        }

        return (image, .originalDecode)
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
        let canonicalPath = canonicalPath(for: path)
        let bucketedPixelSize = bucketedPixelSize(maxPixelSize)
        let key = "\(canonicalPath)#\(bucketedPixelSize)"
        let nsKey = key as NSString

        if let hit = memCache.object(forKey: nsKey) {
            recordStat { $0.memoryHits += 1 }
            return hit
        }

        let diskCacheDir = diskCacheDir
        let task = inflightLoadOrCreate(for: key) {
            Task.detached(priority: priority) { () -> (NSImage, ThumbnailLoadSource)? in
                guard !Task.isCancelled else { return nil }
                guard let result = Self.loadThumbnail(
                    path: path,
                    canonicalPath: canonicalPath,
                    requestedPixelSize: maxPixelSize,
                    bucketedPixelSize: bucketedPixelSize,
                    diskCacheDir: diskCacheDir
                ) else { return nil }
                return (result.image, result.source)
            }
        }

        let result = await task.value
        clearInflightLoad(for: key)
        if let (image, source) = result {
            switch source {
            case .diskExact:
                recordStat { $0.diskExactHits += 1 }
            case .diskNearest:
                recordStat { $0.diskNearestHits += 1 }
            case .originalDecode:
                recordStat { $0.originalDecodes += 1 }
            }
            cacheLoadedImage(image, key: key, path: canonicalPath)
            return image
        } else {
            recordStat { $0.misses += 1 }
            return nil
        }
    }

    /// Synchronous memory-only lookup. Safe to call from SwiftUI bodies —
    /// never touches disk, never stats files.
    func cached(for path: String, maxPixelSize: Int) -> NSImage? {
        let key = memKey(path: path, maxPixelSize: maxPixelSize) as NSString
        let hit = memCache.object(forKey: key)
        if hit != nil {
            recordStat { $0.memoryHits += 1 }
        }
        return hit
    }

    func store(_ image: NSImage, for path: String, maxPixelSize: Int) {
        let canonicalPath = canonicalPath(for: path)
        let key = "\(canonicalPath)#\(bucketedPixelSize(maxPixelSize))"
        cacheLoadedImage(image, key: key, path: canonicalPath)
    }

    /// Memory-only lookup that returns the best already-decoded image for a
    /// path, even if it was cached at a different target size. This lets
    /// larger previews render immediately from an existing grid thumbnail
    /// while a sharper decode is loaded in the background.
    func bestCached(for path: String, minimumPixelSize: Int = 1) -> NSImage? {
        let canonicalPath = canonicalPath(for: path)
        registryLock.lock()
        let keys = Array(keysByPath[canonicalPath] ?? [])
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
            if var registeredKeys = keysByPath[canonicalPath] {
                for key in staleKeys {
                    registeredKeys.remove(key)
                }
                keysByPath[canonicalPath] = registeredKeys.isEmpty ? nil : registeredKeys
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
        let canonicalPath = canonicalPath(for: path)
        registryLock.lock()
        let keys = keysByPath.removeValue(forKey: canonicalPath) ?? []
        registryLock.unlock()
        for k in keys {
            memCache.removeObject(forKey: k as NSString)
        }
    }

    func clearMemory() {
        memCache.removeAllObjects()
        registryLock.lock()
        keysByPath.removeAll()
        canonicalPathByRawPath.removeAll()
        registryLock.unlock()
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
