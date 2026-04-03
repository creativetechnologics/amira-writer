import Accelerate
import AVFoundation
import CoreGraphics
import SwiftUI

/// Background peak computation and caching for audio waveform display.
/// Peaks are normalized 0…1, computed at ~172 peaks/sec (256 samples/peak at 44100 Hz).
/// Cache is keyed by absolute file path; LRU eviction at 50 entries.
///
/// Performance: peaks are pre-rendered into a CGImage (white bars on transparent) during
/// the background computation pass. The clip view displays this image directly — zero
/// per-frame Path object creation (vs. up to 8192 Path objects per clip per body eval).
///
/// When a file is unreadable (deleted, corrupt, or not an audio file), an empty array
/// sentinel is stored so the cache does not retry on every render frame.
@available(macOS 26.0, *)
@MainActor
@Observable final class MixWaveformCache {

    private var cache: [String: [Float]] = [:]
    /// Pre-rendered waveform images — keyed by file path. White bars on transparent
    /// background at 1× scale (retina handled by CGImage), height 128px.
    private var imageCache: [String: CGImage] = [:]
    private var accessOrder: [String] = []
    private var pending: Set<String> = []
    /// Active tasks keyed by path — stored so they can be cancelled on invalidation.
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    /// Paths whose peak computation failed — stored as a sentinel to prevent
    /// unbounded retries when the file is deleted or corrupt.
    private var failed: Set<String> = []

    private static let maxCacheEntries = 50
    /// Height of the pre-rendered waveform image in pixels.
    nonisolated private static let waveformImageHeight = 128

    // MARK: - Public API

    /// Returns cached peaks without triggering an LRU update.
    /// Returns `nil` if the file has not been loaded yet.
    /// Returns an empty array for files that failed to load (deleted / corrupt).
    ///
    /// LRU order is refreshed on insertion rather than on every read; the per-read
    /// `removeAll` was O(n) and ran on every render frame for every visible waveform.
    func peaks(for path: String) -> [Float]? {
        if failed.contains(path) { return [] }
        return cache[path]
    }

    /// Returns a pre-rendered CGImage of the waveform (white bars on transparent).
    /// Use with `Image(decorative:scale:).resizable()` for zero per-frame draw cost.
    /// Returns nil if peaks haven't been computed yet.
    func waveformImage(for path: String) -> CGImage? {
        imageCache[path]
    }

    func request(_ path: String) {
        guard cache[path] == nil, !failed.contains(path), !pending.contains(path) else { return }
        pending.insert(path)
        // Use [weak self] so the Task does not retain the cache and create a cycle:
        //   MixWaveformCache → pendingTasks[path] → Task → (strong) MixWaveformCache.
        // If the cache is deallocated while a computation is in flight the result is
        // simply discarded — no crash, no leak.
        let task = Task { [weak self] in
            let computed = await Self.computePeaks(path)
            // Only store if the task was not cancelled mid-computation.
            guard !Task.isCancelled else { return }
            // Pre-render waveform image on background thread before hopping to main.
            let image = Self.renderWaveformImage(peaks: computed)
            self?.store(peaks: computed, image: image, for: path)
        }
        pendingTasks[path] = task
    }

    /// Remove a cached entry — call when a clip's file path changes or a file is deleted.
    func invalidate(_ path: String) {
        // Cancel any in-flight computation for this path so it doesn't waste CPU
        // and so it doesn't overwrite an entry that may have been re-requested.
        pendingTasks[path]?.cancel()
        pendingTasks.removeValue(forKey: path)
        pending.remove(path)
        cache.removeValue(forKey: path)
        imageCache.removeValue(forKey: path)
        accessOrder.removeAll { $0 == path }
        failed.remove(path)
    }

    // MARK: - Internal

    private func store(peaks: [Float], image: CGImage?, for path: String) {
        pending.remove(path)
        pendingTasks.removeValue(forKey: path)
        if peaks.isEmpty {
            // Mark as failed so we don't retry on every render frame.
            failed.insert(path)
            return
        }
        // Each path is inserted once — request() guards against double-enqueueing —
        // so there is no existing entry to remove before appending.
        cache[path] = peaks
        if let image {
            imageCache[path] = image
        }
        accessOrder.append(path)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while cache.count > Self.maxCacheEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            imageCache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    // MARK: - Waveform Image Rendering

    /// Pre-renders peaks into a CGImage (white bars on transparent background)
    /// at 2× scale for Retina displays. The image is used with
    /// `Image(decorative: cgImage, scale: 2)` so SwiftUI maps 2 pixels → 1 point,
    /// producing sharp waveforms on Retina screens.
    ///
    /// Runs on a background thread. SwiftUI stretches this to fill the clip rect,
    /// giving zero per-frame draw cost.
    nonisolated private static func renderWaveformImage(peaks: [Float]) -> CGImage? {
        guard !peaks.isEmpty else { return nil }
        // Render at 2× for Retina sharpness
        let scaleFactor = 2
        let imgHeight = waveformImageHeight * scaleFactor
        // Use peak count as logical width but keep a reasonable minimum so short
        // clips still get a smooth waveform silhouette when stretched.
        let logicalWidth = min(max(peaks.count, 192), 2048)
        let imgWidth = logicalWidth * scaleFactor
        let sampleCount = min(max(logicalWidth, 96), 2048)

        guard let ctx = CGContext(
            data: nil,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        var envelope = [CGFloat](repeating: 0, count: sampleCount)
        for sampleIndex in 0..<sampleCount {
            let start = sampleIndex * peaks.count / sampleCount
            let end = min(peaks.count, max(start + 1, (sampleIndex + 1) * peaks.count / sampleCount))
            var windowPeak: CGFloat = 0
            for peakIndex in start..<end {
                windowPeak = max(windowPeak, CGFloat(peaks[peakIndex]))
            }
            envelope[sampleIndex] = min(1, CGFloat(pow(Double(windowPeak), 0.86)))
        }

        if sampleCount >= 3 {
            var filtered = envelope
            for index in 1..<(sampleCount - 1) {
                filtered[index] = (envelope[index - 1] + envelope[index] * 2 + envelope[index + 1]) / 4
            }
            envelope = filtered
        }

        let topInset = CGFloat(12 * scaleFactor)
        let bottomInset = CGFloat(10 * scaleFactor)
        let centerY = CGFloat(imgHeight) / 2
        let halfHeight = max(CGFloat(10 * scaleFactor), (CGFloat(imgHeight) - topInset - bottomInset) * 0.42)
        let stepX = CGFloat(imgWidth - 1) / CGFloat(max(sampleCount - 1, 1))

        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: 0, y: centerY))
        for index in 0..<sampleCount {
            let x = CGFloat(index) * stepX
            let amplitude = envelope[index] * halfHeight
            fillPath.addLine(to: CGPoint(x: x, y: centerY - amplitude))
        }
        for index in stride(from: sampleCount - 1, through: 0, by: -1) {
            let x = CGFloat(index) * stepX
            let amplitude = envelope[index] * halfHeight
            fillPath.addLine(to: CGPoint(x: x, y: centerY + amplitude))
        }
        fillPath.closeSubpath()

        ctx.addPath(fillPath)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.fillPath()

        let upperStroke = CGMutablePath()
        let lowerStroke = CGMutablePath()
        for index in 0..<sampleCount {
            let x = CGFloat(index) * stepX
            let amplitude = envelope[index] * halfHeight
            let upperPoint = CGPoint(x: x, y: centerY - amplitude)
            let lowerPoint = CGPoint(x: x, y: centerY + amplitude)
            if index == 0 {
                upperStroke.move(to: upperPoint)
                lowerStroke.move(to: lowerPoint)
            } else {
                upperStroke.addLine(to: upperPoint)
                lowerStroke.addLine(to: lowerPoint)
            }
        }

        ctx.setLineWidth(CGFloat(scaleFactor))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(upperStroke)
        ctx.addPath(lowerStroke)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.56))
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: centerY))
        ctx.addLine(to: CGPoint(x: CGFloat(imgWidth), y: centerY))
        ctx.strokePath()

        return ctx.makeImage()
    }

    // MARK: - Peak Computation

    nonisolated private static func computePeaks(_ path: String) async -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return [] }

        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }

        // ~172 peaks/sec at 44100 Hz (1 peak per 256 samples).
        // Cap at 4096 peaks so we never allocate unbounded memory for multi-hour files.
        let targetPeaks = min(max(totalFrames / 256, 64), 4096)
        let framesPerPeak = max(1, totalFrames / targetPeaks)
        let chunkSize: AVAudioFrameCount = 65536

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: chunkSize) else { return [] }

        var peaks: [Float] = []
        peaks.reserveCapacity(targetPeaks)
        var accumulator: Float = 0
        var accCount = 0

        while true {
            // Respect task cancellation so the background task can be released
            // promptly when the cache entry is invalidated or the view disappears.
            if Task.isCancelled { return [] }

            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: chunkSize) } catch { break }
            guard buffer.frameLength > 0 else { break }
            let readFrames = Int(buffer.frameLength)

            if let floatData = buffer.floatChannelData {
                let chCount = Int(file.processingFormat.channelCount)

                // Use vDSP for vectorized peak extraction — 10-50× faster on Apple Silicon.
                // Process `framesPerPeak` samples at a time using vDSP_maxmgv (max magnitude).
                var frameOffset = 0
                while frameOffset < readFrames {
                    let remaining = readFrames - frameOffset
                    let batchSize = min(framesPerPeak - accCount, remaining)

                    // Find max absolute value across all channels for this batch
                    var batchPeak: Float = accumulator
                    for ch in 0..<chCount {
                        var chPeak: Float = 0
                        vDSP_maxmgv(
                            floatData[ch].advanced(by: frameOffset),
                            1,
                            &chPeak,
                            vDSP_Length(batchSize)
                        )
                        batchPeak = max(batchPeak, chPeak)
                    }
                    accumulator = batchPeak
                    accCount += batchSize
                    frameOffset += batchSize

                    if accCount >= framesPerPeak {
                        peaks.append(accumulator)
                        accumulator = 0
                        accCount = 0
                    }
                }
            } else if let int16Data = buffer.int16ChannelData {
                let chCount = Int(file.processingFormat.channelCount)
                for i in 0..<readFrames {
                    var sample: Float = 0
                    for ch in 0..<chCount {
                        sample = max(sample, abs(Float(int16Data[ch][i])) / 32768.0)
                    }
                    accumulator = max(accumulator, sample)
                    accCount += 1
                    if accCount >= framesPerPeak {
                        peaks.append(accumulator)
                        accumulator = 0
                        accCount = 0
                    }
                }
            }
        }

        if accCount > 0 { peaks.append(accumulator) }
        guard !peaks.isEmpty else { return [] }

        // Normalize to 0…1 using vDSP for vectorized max + scale
        var maxPeak: Float = 0
        vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(peaks.count))
        guard maxPeak > 0.001 else { return peaks }
        var scale = 1.0 / maxPeak
        var result = [Float](repeating: 0, count: peaks.count)
        vDSP_vsmul(peaks, 1, &scale, &result, 1, vDSP_Length(peaks.count))
        return result
    }
}
