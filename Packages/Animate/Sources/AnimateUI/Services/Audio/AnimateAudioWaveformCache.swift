import Accelerate
import AVFoundation
import Combine
import CoreGraphics
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class AnimateAudioWaveformCache: ObservableObject {
    struct Summary {
        var image: CGImage?
        var durationSeconds: Double
    }

    @Published private var imageCache: [String: CGImage] = [:]
    @Published private var durationCache: [String: Double] = [:]
    private var pending: Set<String> = []
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var failed: Set<String> = []
    private var accessOrder: [String] = []

    private static let maxCacheEntries = 24
    nonisolated private static let waveformImageHeight = 96

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        installMemoryPressureHandler()
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    private func installMemoryPressureHandler() {
        memoryPressureSource = Self.makeMemoryPressureSource { [weak self] event in
            let isCritical = event.contains(.critical)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if isCritical {
                    self.clearAllCaches()
                } else {
                    self.trimHalfOldest()
                }
            }
        }
    }

    nonisolated private static func makeMemoryPressureSource(
        onEvent: @escaping @Sendable (DispatchSource.MemoryPressureEvent) -> Void
    ) -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak source] in
            guard let source else { return }
            onEvent(source.data)
        }
        source.resume()
        return source
    }

    private func clearAllCaches() {
        for task in pendingTasks.values { task.cancel() }
        pendingTasks.removeAll()
        pending.removeAll()
        failed.removeAll()
        accessOrder.removeAll()
        imageCache.removeAll()
        durationCache.removeAll()
    }

    private func trimHalfOldest() {
        let dropCount = accessOrder.count / 2
        guard dropCount > 0 else { return }
        for key in accessOrder.prefix(dropCount) {
            imageCache.removeValue(forKey: key)
            durationCache.removeValue(forKey: key)
            pendingTasks[key]?.cancel()
            pendingTasks.removeValue(forKey: key)
            failed.remove(key)
        }
        accessOrder.removeFirst(dropCount)
    }

    func waveformImage(for path: String) -> CGImage? {
        imageCache[path]
    }

    func durationSeconds(for path: String) -> Double? {
        durationCache[path]
    }

    func request(_ path: String) {
        guard imageCache[path] == nil, !failed.contains(path), !pending.contains(path) else { return }
        pending.insert(path)
        let task = Task(priority: .utility) { [weak self] in
            let summary = await Self.computeSummary(path)
            guard !Task.isCancelled else { return }
            self?.store(summary, for: path)
        }
        pendingTasks[path] = task
    }

    private func store(_ summary: Summary?, for path: String) {
        pending.remove(path)
        pendingTasks.removeValue(forKey: path)

        guard let summary else {
            failed.insert(path)
            return
        }

        durationCache[path] = summary.durationSeconds
        if let image = summary.image {
            imageCache[path] = image
        }
        accessOrder.removeAll { $0 == path }
        accessOrder.append(path)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while accessOrder.count > Self.maxCacheEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            imageCache.removeValue(forKey: oldest)
            durationCache.removeValue(forKey: oldest)
            pendingTasks[oldest]?.cancel()
            pendingTasks.removeValue(forKey: oldest)
            failed.remove(oldest)
        }
    }

    nonisolated private static func computeSummary(_ path: String) async -> Summary? {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let totalFrames = Int(file.length)
        let sampleRate = file.processingFormat.sampleRate
        guard totalFrames > 0, sampleRate > 0 else { return nil }

        let durationSeconds = Double(totalFrames) / sampleRate
        let peaks = computePeaks(file: file, totalFrames: totalFrames)
        let image = renderWaveformImage(peaks: peaks)
        return Summary(image: image, durationSeconds: durationSeconds)
    }

    nonisolated private static func computePeaks(file: AVAudioFile, totalFrames: Int) -> [Float] {
        let targetPeaks = min(max(totalFrames / 256, 64), 4096)
        let framesPerPeak = max(1, totalFrames / targetPeaks)
        let chunkSize: AVAudioFrameCount = 65536

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
            return []
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(targetPeaks)
        var accumulator: Float = 0
        var accumulatorCount = 0

        while true {
            if Task.isCancelled { return [] }

            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: chunkSize)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            let readFrames = Int(buffer.frameLength)

            if let floatData = buffer.floatChannelData {
                let channelCount = Int(file.processingFormat.channelCount)
                var frameOffset = 0
                while frameOffset < readFrames {
                    let remaining = readFrames - frameOffset
                    let batchSize = min(framesPerPeak - accumulatorCount, remaining)

                    var batchPeak = accumulator
                    for channel in 0..<channelCount {
                        var channelPeak: Float = 0
                        vDSP_maxmgv(
                            floatData[channel].advanced(by: frameOffset),
                            1,
                            &channelPeak,
                            vDSP_Length(batchSize)
                        )
                        batchPeak = max(batchPeak, channelPeak)
                    }

                    accumulator = batchPeak
                    accumulatorCount += batchSize
                    frameOffset += batchSize

                    if accumulatorCount >= framesPerPeak {
                        peaks.append(accumulator)
                        accumulator = 0
                        accumulatorCount = 0
                    }
                }
            } else if let int16Data = buffer.int16ChannelData {
                let channelCount = Int(file.processingFormat.channelCount)
                for frameIndex in 0..<readFrames {
                    var samplePeak: Float = 0
                    for channel in 0..<channelCount {
                        samplePeak = max(samplePeak, abs(Float(int16Data[channel][frameIndex])) / 32768.0)
                    }
                    accumulator = max(accumulator, samplePeak)
                    accumulatorCount += 1
                    if accumulatorCount >= framesPerPeak {
                        peaks.append(accumulator)
                        accumulator = 0
                        accumulatorCount = 0
                    }
                }
            }
        }

        if accumulatorCount > 0 {
            peaks.append(accumulator)
        }
        guard !peaks.isEmpty else { return [] }

        var maxPeak: Float = 0
        vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(peaks.count))
        guard maxPeak > 0.001 else { return peaks }

        var scale = 1.0 / maxPeak
        var normalized = [Float](repeating: 0, count: peaks.count)
        vDSP_vsmul(peaks, 1, &scale, &normalized, 1, vDSP_Length(peaks.count))
        return normalized
    }

    nonisolated private static func renderWaveformImage(peaks: [Float]) -> CGImage? {
        guard !peaks.isEmpty else { return nil }

        let scaleFactor = 2
        let logicalWidth = min(max(peaks.count, 192), 2048)
        let imgWidth = logicalWidth * scaleFactor
        let imgHeight = waveformImageHeight * scaleFactor
        let sampleCount = min(max(logicalWidth, 96), 2048)

        guard let ctx = CGContext(
            data: nil,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

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

        let centerY = CGFloat(imgHeight) / 2
        let halfHeight = max(CGFloat(8 * scaleFactor), CGFloat(imgHeight) * 0.34)
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
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.fillPath()

        let upperStroke = CGMutablePath()
        let lowerStroke = CGMutablePath()
        for index in 0..<sampleCount {
            let x = CGFloat(index) * stepX
            let amplitude = envelope[index] * halfHeight
            let upper = CGPoint(x: x, y: centerY - amplitude)
            let lower = CGPoint(x: x, y: centerY + amplitude)
            if index == 0 {
                upperStroke.move(to: upper)
                lowerStroke.move(to: lower)
            } else {
                upperStroke.addLine(to: upper)
                lowerStroke.addLine(to: lower)
            }
        }

        ctx.setLineWidth(CGFloat(scaleFactor))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(upperStroke)
        ctx.addPath(lowerStroke)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.42))
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: centerY))
        ctx.addLine(to: CGPoint(x: CGFloat(imgWidth), y: centerY))
        ctx.strokePath()

        return ctx.makeImage()
    }
}
