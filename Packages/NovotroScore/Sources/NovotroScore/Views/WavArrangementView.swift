#if canImport(AppKit)
/// WavArrangementView — CoreGraphics-based audio clip lane for the piano roll.
///
/// Displays AudioClips as rounded rectangles with waveform peaks, a volume
/// gain line, fade in/out indicators, pitch-shift badges, and supports
/// drag-and-drop import, clip repositioning, gain dragging, and a context menu.

import AppKit
import AVFoundation
import UniformTypeIdentifiers

@available(macOS 26.0, *)
final class WavArrangementView: NSView {

    // MARK: - Public interface (expected by PianoRollViewController)

    private unowned let store: ScoreStore

    var scrollOffset: CGFloat = 0 {
        didSet { if scrollOffset != oldValue { needsDisplay = true } }
    }
    var pixelsPerTick: CGFloat = 0 {
        didSet { if pixelsPerTick != oldValue { recalculateLayout(); needsDisplay = true } }
    }
    var keyboardOffset: CGFloat = 0 {
        didSet { if keyboardOffset != oldValue { recalculateLayout(); needsDisplay = true } }
    }
    var onHorizontalScroll: ((CGFloat) -> Void)?

    func reloadClips() {
        if let selectedClipID,
           !store.pianoRollAudioClips.contains(where: { $0.id == selectedClipID }) {
            self.selectedClipID = nil
        }
        if let activeDragPreview,
           !store.pianoRollAudioClips.contains(where: { $0.id == activeDragPreview.clipID }) {
            self.activeDragPreview = nil
        }
        recalculateLayout()
        needsDisplay = true
    }

    // MARK: - Layout

    private struct ClipFrame {
        let clip: AudioClip
        let frame: CGRect   // in content-space (before scroll/keyboard offset)
        let lane: Int
    }

    private var clipFrames: [ClipFrame] = []
    private let laneHeight: CGFloat = 50
    private let clipCornerRadius: CGFloat = 6
    private let clipInset: CGFloat = 2  // vertical gap between stacked clips

    // MARK: - Waveform cache

    private var waveformCache: [String: [Float]] = [:]
    private let peaksPerSecond: Int = 200

    // MARK: - Interaction state

    private enum DragMode {
        case none
        case clip(id: UUID, startTickOrigin: Int)
        case gain(id: UUID)
    }
    private var dragMode: DragMode = .none
    private var dragStartPoint: CGPoint = .zero
    private var selectedClipID: UUID?
    private var activeDragPreview: (clipID: UUID, originTick: Int, previewTick: Int, lane: Int)?
    private var didMoveClipDuringDrag = false

    /// Track where a drag-drop file would land (for drawing indicator).
    private var dropIndicatorTick: Int?

    // MARK: - Gain line constants

    private let envelopeMinDB: Double = -24
    private let envelopeMaxDB: Double = 12
    private var envelopeRangeDB: Double { envelopeMaxDB - envelopeMinDB }

    // MARK: - Clip colors (cycling palette)

    private static let clipColors: [NSColor] = [
        NSColor(calibratedRed: 0.30, green: 0.70, blue: 0.95, alpha: 1.0),  // blue
        NSColor(calibratedRed: 0.40, green: 0.80, blue: 0.50, alpha: 1.0),  // green
        NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.30, alpha: 1.0),  // orange
        NSColor(calibratedRed: 0.80, green: 0.45, blue: 0.85, alpha: 1.0),  // purple
        NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.30, alpha: 1.0),  // yellow
        NSColor(calibratedRed: 0.85, green: 0.40, blue: 0.45, alpha: 1.0),  // red
    ]

    // MARK: - Init

    init(store: ScoreStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(store:) instead")
    }

    // MARK: - Layout calculation

    private func recalculateLayout() {
        let clips = store.pianoRollAudioClips
        let sorted = clips.sorted { $0.startTick < $1.startTick }

        var laneEnds: [Int] = []  // tick where each lane becomes free
        var frames: [ClipFrame] = []

        for clip in sorted {
            let endTick = clip.startTick + clip.durationTicks

            // Find first available lane
            let lane: Int
            if let freeLane = laneEnds.firstIndex(where: { $0 <= clip.startTick }) {
                lane = freeLane
                laneEnds[freeLane] = endTick
            } else {
                lane = laneEnds.count
                laneEnds.append(endTick)
            }

            let x = CGFloat(Double(clip.startTick) * Double(pixelsPerTick))
            let w = max(CGFloat(Double(clip.durationTicks) * Double(pixelsPerTick)), 4)
            let y = CGFloat(lane) * laneHeight
            let rect = CGRect(x: x, y: y + clipInset, width: w, height: laneHeight - clipInset * 2)

            frames.append(ClipFrame(clip: clip, frame: rect, lane: lane))
        }

        clipFrames = frames
    }

    // MARK: - Coordinate helpers

    /// Convert a point in view coordinates to content-space (accounting for scroll + keyboard offset).
    /// With isFlipped = true, Y=0 is at top in both systems.
    private func viewToContent(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x - keyboardOffset + scrollOffset,
                y: viewPoint.y)
    }

    /// Convert a content-space rect to view coordinates for drawing.
    private func contentRectToView(_ rect: CGRect) -> CGRect {
        let x = rect.minX - scrollOffset + keyboardOffset
        return CGRect(x: x, y: rect.minY, width: rect.width, height: rect.height)
    }

    private func contentFrame(for entry: ClipFrame) -> CGRect {
        guard let preview = activeDragPreview, preview.clipID == entry.clip.id else {
            return entry.frame
        }

        let x = CGFloat(Double(preview.previewTick) * Double(pixelsPerTick))
        return CGRect(
            x: x,
            y: CGFloat(preview.lane) * laneHeight + clipInset,
            width: entry.frame.width,
            height: entry.frame.height
        )
    }

    private func viewRect(for entry: ClipFrame) -> CGRect {
        contentRectToView(contentFrame(for: entry))
    }

    // MARK: - Gain ↔ Y conversion

    private func gainDBToY(_ gainDB: Double, in clipRect: CGRect) -> CGFloat {
        let normalized = (gainDB - envelopeMinDB) / envelopeRangeDB
        return clipRect.minY + CGFloat(1.0 - normalized) * clipRect.height
    }

    private func yToGainDB(_ y: CGFloat, in clipRect: CGRect) -> Double {
        let normalized = 1.0 - Double((y - clipRect.minY) / clipRect.height)
        return envelopeMinDB + normalized * envelopeRangeDB
    }

    // MARK: - Waveform peak extraction

    private func getWaveformPeaks(for absolutePath: String) -> [Float] {
        if let cached = waveformCache[absolutePath] { return cached }

        let url = URL(fileURLWithPath: absolutePath)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else { return [] }
        let sampleRate = audioFile.processingFormat.sampleRate
        let durationSeconds = Double(frameCount) / sampleRate
        let numPeaks = max(1, Int(durationSeconds * Double(peaksPerSecond)))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                            frameCapacity: frameCount) else { return [] }
        do { try audioFile.read(into: buffer) } catch { return [] }
        guard let channelData = buffer.floatChannelData else { return [] }

        let samplesPerPeak = max(1, Int(frameCount) / numPeaks)
        var peaks = [Float](repeating: 0, count: numPeaks)
        let samples = channelData[0]

        for i in 0..<numPeaks {
            let start = i * samplesPerPeak
            let end = min(start + samplesPerPeak, Int(frameCount))
            var maxVal: Float = 0
            for s in start..<end {
                maxVal = max(maxVal, abs(samples[s]))
            }
            peaks[i] = maxVal
        }

        waveformCache[absolutePath] = peaks
        return peaks
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }  // top-left origin (matches piano roll convention)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        ctx.fill(bounds)

        // Draw drop indicator if dragging a file over
        if let dropTick = dropIndicatorTick {
            drawDropPreview(ctx: ctx, tick: dropTick)
        }

        // Draw each clip
        for (index, entry) in clipFrames.enumerated() {
            let viewRect = viewRect(for: entry)

            // Skip if offscreen
            guard viewRect.maxX > 0, viewRect.minX < bounds.width else { continue }

            drawClip(
                ctx: ctx,
                entry: entry,
                viewRect: viewRect,
                colorIndex: index,
                isSelected: entry.clip.id == selectedClipID
            )
        }

        // Empty state hint
        if clipFrames.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, 11, nil)
            let color = CGColor(gray: 1.0, alpha: 0.25)
            let text = "Drag audio files here" as CFString
            let cfAttrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
            let cfStr = CFAttributedStringCreate(nil, text, cfAttrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(cfStr)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let asc = CTFontGetAscent(font)
            let desc = CTFontGetDescent(font)
            let lineHeight = asc + desc
            ctx.saveGState()
            ctx.translateBy(x: (bounds.width - lineWidth) / 2, y: (bounds.height - lineHeight) / 2 + asc)
            ctx.scaleBy(x: 1, y: -1)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    private func drawDropPreview(ctx: CGContext, tick: Int) {
        let previewWidth = max(CGFloat(store.ticksPerQuarter) * pixelsPerTick * 2, 96)
        let x = CGFloat(Double(tick) * Double(pixelsPerTick)) - scrollOffset + keyboardOffset
        let previewRect = CGRect(x: x, y: clipInset, width: previewWidth, height: laneHeight - clipInset * 2)
        let previewPath = CGPath(
            roundedRect: previewRect,
            cornerWidth: clipCornerRadius,
            cornerHeight: clipCornerRadius,
            transform: nil
        )

        ctx.saveGState()
        ctx.addPath(previewPath)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        ctx.fillPath()
        ctx.addPath(previewPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.restoreGState()
    }

    private func drawClip(ctx: CGContext, entry: ClipFrame, viewRect: CGRect, colorIndex: Int, isSelected: Bool) {
        let clip = entry.clip
        let color = Self.clipColors[colorIndex % Self.clipColors.count]
        let baseAlpha: CGFloat = clip.muted ? 0.18 : (isSelected ? 0.88 : 0.64)

        // Clip body
        let path = CGPath(roundedRect: viewRect, cornerWidth: clipCornerRadius, cornerHeight: clipCornerRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        let topColor = color.blended(withFraction: 0.22, of: .white) ?? color
        let bottomColor = color.blended(withFraction: 0.30, of: .black) ?? color
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                topColor.withAlphaComponent(baseAlpha).cgColor,
                bottomColor.withAlphaComponent(baseAlpha).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )
        if let gradient {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: viewRect.midX, y: viewRect.minY),
                end: CGPoint(x: viewRect.midX, y: viewRect.maxY),
                options: []
            )
        } else {
            ctx.setFillColor(color.withAlphaComponent(baseAlpha).cgColor)
            ctx.fill(viewRect)
        }

        let headerRect = CGRect(
            x: viewRect.minX,
            y: viewRect.minY,
            width: viewRect.width,
            height: min(16, viewRect.height * 0.34)
        )
        ctx.setFillColor(NSColor.black.withAlphaComponent(isSelected ? 0.22 : 0.16).cgColor)
        ctx.fill(headerRect)

        // Waveform
        let peaks = getWaveformPeaks(for: clip.filePath)
        if !peaks.isEmpty {
            drawWaveform(ctx: ctx, peaks: peaks, clip: clip, viewRect: viewRect, color: color)
        }

        // Fade in/out overlays
        if clip.fadeInTicks > 0 {
            drawFadeIn(ctx: ctx, clip: clip, viewRect: viewRect)
        }
        if clip.fadeOutTicks > 0 {
            drawFadeOut(ctx: ctx, clip: clip, viewRect: viewRect)
        }

        // Volume gain line
        drawGainLine(ctx: ctx, clip: clip, viewRect: viewRect)

        // Muted overlay
        if clip.muted {
            // Diagonal stripes pattern
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            ctx.setLineWidth(1)
            let step: CGFloat = 8
            var x = viewRect.minX - viewRect.height
            while x < viewRect.maxX {
                ctx.move(to: CGPoint(x: x, y: viewRect.maxY))
                ctx.addLine(to: CGPoint(x: x + viewRect.height, y: viewRect.minY))
                x += step
            }
            ctx.strokePath()
        }

        ctx.restoreGState()  // unclip

        // Clip border
        ctx.setStrokeColor((isSelected ? NSColor.white : color).withAlphaComponent(clip.muted ? 0.22 : (isSelected ? 0.92 : 0.44)).cgColor)
        ctx.setLineWidth(isSelected ? 2 : 1)
        ctx.addPath(path)
        ctx.strokePath()

        // Clip name (top-left) — use CTLine to avoid CoreText crash
        let nameFont = CTFontCreateWithName("Helvetica Neue" as CFString, 9, nil)
        let nameColor = NSColor.white.withAlphaComponent(clip.muted ? 0.30 : 0.85).cgColor
        let nameCFAttrs: [CFString: Any] = [kCTFontAttributeName: nameFont, kCTForegroundColorAttributeName: nameColor]
        let displayName = clip.displayName
        let nameCFStr = CFAttributedStringCreate(nil, displayName as CFString, nameCFAttrs as CFDictionary)!
        let nameLine = CTLineCreateWithAttributedString(nameCFStr)
        let nameWidth = CGFloat(CTLineGetTypographicBounds(nameLine, nil, nil, nil))
        let nameAsc = CTFontGetAscent(nameFont)
        let drawLine: CTLine
        if nameWidth < viewRect.width - 8 {
            drawLine = nameLine
        } else {
            let truncStr = String(displayName.prefix(Int(viewRect.width / 6)))
            let truncCFStr = CFAttributedStringCreate(nil, truncStr as CFString, nameCFAttrs as CFDictionary)!
            drawLine = CTLineCreateWithAttributedString(truncCFStr)
        }
        ctx.saveGState()
        ctx.translateBy(x: viewRect.minX + 4, y: viewRect.minY + 2 + nameAsc)
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(drawLine, ctx)
        ctx.restoreGState()

        // Pitch shift badge (top-right) — use CTLine
        if clip.pitchCents != 0 {
            let semitones = Int((clip.pitchCents / 100).rounded())
            let sign = semitones > 0 ? "+" : ""
            let badgeText = "\(sign)\(semitones) st"
            let badgeFont = CTFontCreateWithName("Menlo" as CFString, 8, nil)
            let badgeColor = CGColor(gray: 1.0, alpha: 0.9)
            let badgeCFAttrs: [CFString: Any] = [kCTFontAttributeName: badgeFont, kCTForegroundColorAttributeName: badgeColor]
            let badgeCFStr = CFAttributedStringCreate(nil, badgeText as CFString, badgeCFAttrs as CFDictionary)!
            let badgeLine = CTLineCreateWithAttributedString(badgeCFStr)
            let badgeWidth = CGFloat(CTLineGetTypographicBounds(badgeLine, nil, nil, nil))
            let badgeAsc = CTFontGetAscent(badgeFont)
            let badgeDesc = CTFontGetDescent(badgeFont)
            let badgeHeight = badgeAsc + badgeDesc
            let badgePad: CGFloat = 3
            let badgeRect = CGRect(
                x: viewRect.maxX - badgeWidth - badgePad * 2 - 4,
                y: viewRect.minY + 2,
                width: badgeWidth + badgePad * 2,
                height: badgeHeight + badgePad
            )
            if badgeRect.minX > viewRect.minX + 30 {
                let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.setFillColor(NSColor(calibratedRed: 0.5, green: 0.3, blue: 0.8, alpha: 0.7).cgColor)
                ctx.addPath(badgePath)
                ctx.fillPath()
                ctx.saveGState()
                ctx.translateBy(x: badgeRect.minX + badgePad, y: badgeRect.minY + badgePad / 2 + badgeAsc)
                ctx.scaleBy(x: 1, y: -1)
                CTLineDraw(badgeLine, ctx)
                ctx.restoreGState()
            }
        }
    }

    // MARK: - Waveform drawing

    private func drawWaveform(ctx: CGContext, peaks: [Float], clip: AudioClip, viewRect: CGRect, color: NSColor) {
        let peakCount = peaks.count
        guard peakCount > 0 else { return }

        // Compute which portion of peaks to draw based on offsetTicks
        let offsetSeconds = store.ticksToSeconds(clip.offsetTicks)
        let clipDurationSeconds = store.ticksToSeconds(clip.startTick + clip.durationTicks) - store.ticksToSeconds(clip.startTick)
        let startPeakIdx = max(0, Int(offsetSeconds * Double(peaksPerSecond)))
        let endPeakIdx = min(peakCount, startPeakIdx + max(1, Int(clipDurationSeconds * Double(peaksPerSecond))))
        let visiblePeaks = Array(peaks[startPeakIdx..<endPeakIdx])
        guard !visiblePeaks.isEmpty else { return }

        let drawSamples = max(24, Int(viewRect.width.rounded(.up)))
        guard drawSamples > 1 else { return }

        var smoothedPeaks = [CGFloat](repeating: 0, count: drawSamples)
        for sampleIndex in 0..<drawSamples {
            let start = sampleIndex * visiblePeaks.count / drawSamples
            let end = min(visiblePeaks.count, max(start + 1, (sampleIndex + 1) * visiblePeaks.count / drawSamples))
            var windowPeak: CGFloat = 0
            for peakIndex in start..<end {
                windowPeak = max(windowPeak, CGFloat(visiblePeaks[peakIndex]))
            }
            smoothedPeaks[sampleIndex] = min(1, pow(windowPeak, 0.85))
        }

        if drawSamples >= 3 {
            var filtered = smoothedPeaks
            for index in 1..<(drawSamples - 1) {
                filtered[index] = (smoothedPeaks[index - 1] + smoothedPeaks[index] * 2 + smoothedPeaks[index + 1]) / 4
            }
            smoothedPeaks = filtered
        }

        let topInset: CGFloat = 18
        let bottomInset: CGFloat = 8
        let centerY = viewRect.minY + topInset + max(6, (viewRect.height - topInset - bottomInset) * 0.5)
        let halfHeight = max(4, (viewRect.height - topInset - bottomInset) * 0.42)
        let stepX = viewRect.width / CGFloat(drawSamples - 1)

        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: viewRect.minX, y: centerY))
        for index in 0..<drawSamples {
            let x = viewRect.minX + CGFloat(index) * stepX
            let amplitude = smoothedPeaks[index] * halfHeight
            fillPath.addLine(to: CGPoint(x: x, y: centerY - amplitude))
        }
        for index in stride(from: drawSamples - 1, through: 0, by: -1) {
            let x = viewRect.minX + CGFloat(index) * stepX
            let amplitude = smoothedPeaks[index] * halfHeight
            fillPath.addLine(to: CGPoint(x: x, y: centerY + amplitude))
        }
        fillPath.closeSubpath()

        ctx.saveGState()
        ctx.addPath(fillPath)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let upperStroke = CGMutablePath()
        let lowerStroke = CGMutablePath()
        for index in 0..<drawSamples {
            let x = viewRect.minX + CGFloat(index) * stepX
            let amplitude = smoothedPeaks[index] * halfHeight
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

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.34).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(upperStroke)
        ctx.addPath(lowerStroke)
        ctx.strokePath()

        ctx.setStrokeColor(color.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: viewRect.minX, y: centerY))
        ctx.addLine(to: CGPoint(x: viewRect.maxX, y: centerY))
        ctx.strokePath()
    }

    // MARK: - Gain line drawing

    private func drawGainLine(ctx: CGContext, clip: AudioClip, viewRect: CGRect) {
        let y = gainDBToY(clip.gainDB, in: viewRect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: viewRect.minX, y: y))
        ctx.addLine(to: CGPoint(x: viewRect.maxX, y: y))
        ctx.strokePath()

        // Small circles at endpoints
        let circleR: CGFloat = 2.5
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.fillEllipse(in: CGRect(x: viewRect.minX - circleR, y: y - circleR,
                                   width: circleR * 2, height: circleR * 2))
        ctx.fillEllipse(in: CGRect(x: viewRect.maxX - circleR, y: y - circleR,
                                   width: circleR * 2, height: circleR * 2))
    }

    // MARK: - Fade drawing

    private func drawFadeIn(ctx: CGContext, clip: AudioClip, viewRect: CGRect) {
        let fadeWidth = CGFloat(Double(clip.fadeInTicks) * Double(pixelsPerTick))
        guard fadeWidth > 1 else { return }
        let w = min(fadeWidth, viewRect.width)

        // Semi-transparent overlay triangle (darker at left, clear at right)
        ctx.saveGState()
        let fadePath = CGMutablePath()
        fadePath.move(to: CGPoint(x: viewRect.minX, y: viewRect.minY))
        fadePath.addLine(to: CGPoint(x: viewRect.minX, y: viewRect.maxY))
        fadePath.addLine(to: CGPoint(x: viewRect.minX + w, y: viewRect.minY))
        fadePath.closeSubpath()
        ctx.addPath(fadePath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fillPath()

        // Diagonal line
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: viewRect.minX, y: viewRect.maxY))
        ctx.addLine(to: CGPoint(x: viewRect.minX + w, y: viewRect.minY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawFadeOut(ctx: CGContext, clip: AudioClip, viewRect: CGRect) {
        let fadeWidth = CGFloat(Double(clip.fadeOutTicks) * Double(pixelsPerTick))
        guard fadeWidth > 1 else { return }
        let w = min(fadeWidth, viewRect.width)

        ctx.saveGState()
        let fadePath = CGMutablePath()
        fadePath.move(to: CGPoint(x: viewRect.maxX, y: viewRect.minY))
        fadePath.addLine(to: CGPoint(x: viewRect.maxX, y: viewRect.maxY))
        fadePath.addLine(to: CGPoint(x: viewRect.maxX - w, y: viewRect.minY))
        fadePath.closeSubpath()
        ctx.addPath(fadePath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: viewRect.maxX, y: viewRect.maxY))
        ctx.addLine(to: CGPoint(x: viewRect.maxX - w, y: viewRect.minY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Hit testing

    private func clipEntry(at viewPoint: CGPoint) -> ClipFrame? {
        let contentPt = viewToContent(viewPoint)
        return clipFrames.reversed().first { contentFrame(for: $0).insetBy(dx: -4, dy: -3).contains(contentPt) }
    }

    private func clipEntryInViewCoords(at viewPoint: CGPoint) -> ClipFrame? {
        clipFrames.reversed().first { entry in
            let vr = viewRect(for: entry).insetBy(dx: -4, dy: -3)
            return vr.contains(viewPoint)
        }
    }

    /// Check if a point is near the gain line of a clip (within ±4pt).
    private func gainLineHit(at viewPoint: CGPoint) -> ClipFrame? {
        for entry in clipFrames {
            let vr = viewRect(for: entry)
            guard vr.contains(viewPoint) else { continue }
            let gainY = gainDBToY(entry.clip.gainDB, in: vr)
            if abs(viewPoint.y - gainY) < 4 {
                return entry
            }
        }
        return nil
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        didMoveClipDuringDrag = false

        // Check gain line first (higher priority for vertical drag)
        if let entry = gainLineHit(at: point) {
            selectedClipID = entry.clip.id
            dragMode = .gain(id: entry.clip.id)
            needsDisplay = true
            return
        }

        // Check clip body for drag-reposition
        if let entry = clipEntryInViewCoords(at: point) {
            selectedClipID = entry.clip.id
            dragMode = .clip(id: entry.clip.id, startTickOrigin: entry.clip.startTick)
            activeDragPreview = nil
            needsDisplay = true
            return
        }

        selectedClipID = nil
        dragMode = .none
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch dragMode {
        case .none:
            break

        case .gain(let id):
            guard let entryIdx = clipFrames.firstIndex(where: { $0.clip.id == id }) else { return }
            let vr = contentRectToView(clipFrames[entryIdx].frame)
            let rawGain = yToGainDB(point.y, in: vr)
            let clamped = min(max(rawGain, envelopeMinDB), envelopeMaxDB)

            if let storeIdx = store.pianoRollAudioClips.firstIndex(where: { $0.id == id }) {
                store.pianoRollAudioClips[storeIdx].gainDB = clamped
                store.isDirty = true
                recalculateLayout()
                needsDisplay = true
            }

        case .clip(let id, let originTick):
            let deltaX = point.x - dragStartPoint.x
            guard pixelsPerTick > 0 else { return }
            let deltaTicks = Int((Double(deltaX) / Double(pixelsPerTick)).rounded())
            let newStart = max(0, originTick + deltaTicks)
            guard let entry = clipFrames.first(where: { $0.clip.id == id }) else { return }
            didMoveClipDuringDrag = didMoveClipDuringDrag || abs(deltaX) >= 1
            activeDragPreview = (clipID: id, originTick: originTick, previewTick: newStart, lane: entry.lane)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .clip(let id, _):
            if let preview = activeDragPreview,
               preview.clipID == id,
               preview.previewTick != preview.originTick,
               didMoveClipDuringDrag {
                var updated = store.pianoRollAudioClips
                if let clipIndex = updated.firstIndex(where: { $0.id == id }) {
                    updated[clipIndex].startTick = preview.previewTick
                    store.setPianoRollAudioClipsFromEditor(updated)
                }
            }
        case .gain:
            break  // already set isDirty during drag
        case .none:
            break
        }
        activeDragPreview = nil
        didMoveClipDuringDrag = false
        dragMode = .none
        reloadClips()
    }

    // MARK: - Scroll sync

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            onHorizontalScroll?(event.scrollingDeltaX)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: - Drag-and-drop

    private static let audioExtensions: Set<String> = ["wav", "mp3", "aiff", "aif", "m4a", "flac", "ogg"]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasAudioURLs(in: sender) else { return [] }
        updateDropIndicator(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasAudioURLs(in: sender) else { return [] }
        updateDropIndicator(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropIndicator()

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return false }

        let audioURLs = urls.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !audioURLs.isEmpty else { return false }

        let dropPoint = convert(sender.draggingLocation, from: nil)
        let dropTick = tickFromViewX(dropPoint.x)

        var importedClips: [AudioClip] = []
        for (i, url) in audioURLs.enumerated() {
            let tick = dropTick + i * (store.ticksPerQuarter * 4)  // space multiple files 1 bar apart
            if let clip = store.importAudioClipFromDrop(url: url, atTick: tick) {
                importedClips.append(clip)
            }
        }

        selectedClipID = importedClips.last?.id ?? selectedClipID
        reloadClips()
        return !importedClips.isEmpty
    }

    private func hasAudioURLs(in sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func updateDropIndicator(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        dropIndicatorTick = tickFromViewX(point.x)
        needsDisplay = true
    }

    private func clearDropIndicator() {
        dropIndicatorTick = nil
        needsDisplay = true
    }

    private func tickFromViewX(_ viewX: CGFloat) -> Int {
        guard pixelsPerTick > 0 else { return 0 }
        return max(0, Int((Double(viewX - keyboardOffset) + Double(scrollOffset)) / Double(pixelsPerTick)))
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)

        // Right-click on a clip
        if let entry = clipEntryInViewCoords(at: point) {
            return buildClipMenu(for: entry.clip)
        }

        // Right-click on empty space
        let emptyMenu = NSMenu()
        let tick = tickFromViewX(point.x)
        let importItem = NSMenuItem(title: "Import Audio File…", action: #selector(importAudioFile(_:)), keyEquivalent: "")
        importItem.representedObject = tick
        importItem.target = self
        emptyMenu.addItem(importItem)
        return emptyMenu
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(sender)
        clearDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        clearDropIndicator()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildClipMenu(for clip: AudioClip) -> NSMenu {
        let menu = NSMenu()

        // Mute/Unmute
        let muteTitle = clip.muted ? "Unmute" : "Mute"
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(toggleMute(_:)), keyEquivalent: "")
        muteItem.representedObject = clip.id
        muteItem.target = self
        menu.addItem(muteItem)

        // Mute overlapping MIDI
        let overlapItem = NSMenuItem(title: "Mute Overlapping MIDI", action: #selector(muteOverlappingMIDI(_:)), keyEquivalent: "")
        overlapItem.representedObject = clip.id
        overlapItem.target = self
        menu.addItem(overlapItem)

        menu.addItem(.separator())

        // Pitch shift submenu
        let pitchMenu = NSMenu()
        let currentSemitones = Int((clip.pitchCents / 100).rounded())
        for semi in stride(from: 12, through: -12, by: -1) {
            let sign = semi > 0 ? "+" : ""
            let title = semi == 0 ? "No Shift" : "\(sign)\(semi) semitone\(abs(semi) == 1 ? "" : "s")"
            let item = NSMenuItem(title: title, action: #selector(setPitchShift(_:)), keyEquivalent: "")
            item.representedObject = ["clipID": clip.id, "semitones": semi] as [String: Any]
            item.target = self
            if semi == currentSemitones { item.state = .on }
            pitchMenu.addItem(item)
        }
        let pitchItem = NSMenuItem(title: "Pitch Shift", action: nil, keyEquivalent: "")
        pitchItem.submenu = pitchMenu
        menu.addItem(pitchItem)

        // Fade in
        let fadeInMenu = NSMenu()
        for ticks in [0, 240, 480, 960, 1920, 3840] {
            let label = ticks == 0 ? "None" : "\(ticks) ticks"
            let item = NSMenuItem(title: label, action: #selector(setFadeIn(_:)), keyEquivalent: "")
            item.representedObject = ["clipID": clip.id, "ticks": ticks] as [String: Any]
            item.target = self
            if ticks == clip.fadeInTicks { item.state = .on }
            fadeInMenu.addItem(item)
        }
        let fadeInItem = NSMenuItem(title: "Fade In", action: nil, keyEquivalent: "")
        fadeInItem.submenu = fadeInMenu
        menu.addItem(fadeInItem)

        // Fade out
        let fadeOutMenu = NSMenu()
        for ticks in [0, 240, 480, 960, 1920, 3840] {
            let label = ticks == 0 ? "None" : "\(ticks) ticks"
            let item = NSMenuItem(title: label, action: #selector(setFadeOut(_:)), keyEquivalent: "")
            item.representedObject = ["clipID": clip.id, "ticks": ticks] as [String: Any]
            item.target = self
            if ticks == clip.fadeOutTicks { item.state = .on }
            fadeOutMenu.addItem(item)
        }
        let fadeOutItem = NSMenuItem(title: "Fade Out", action: nil, keyEquivalent: "")
        fadeOutItem.submenu = fadeOutMenu
        menu.addItem(fadeOutItem)

        menu.addItem(.separator())

        // Duplicate
        let dupItem = NSMenuItem(title: "Duplicate", action: #selector(duplicateClip(_:)), keyEquivalent: "")
        dupItem.representedObject = clip.id
        dupItem.target = self
        menu.addItem(dupItem)

        // Remove
        let removeItem = NSMenuItem(title: "Remove Clip", action: #selector(removeClip(_:)), keyEquivalent: "")
        removeItem.representedObject = clip.id
        removeItem.target = self
        menu.addItem(removeItem)

        return menu
    }

    // MARK: - Context menu actions

    @objc private func importAudioFile(_ sender: NSMenuItem) {
        let tick = sender.representedObject as? Int ?? 0
        store.addAudioClipFromPanel(trackKey: nil, startTick: tick)
        // The store sets isDirty — we reload after a short delay to let the panel finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reloadClips()
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let clipID = sender.representedObject as? UUID,
              let idx = store.pianoRollAudioClips.firstIndex(where: { $0.id == clipID }) else { return }
        store.pianoRollAudioClips[idx].muted.toggle()
        store.isDirty = true
        reloadClips()
    }

    @objc private func muteOverlappingMIDI(_ sender: NSMenuItem) {
        guard let clipID = sender.representedObject as? UUID else { return }
        store.muteOverlappingMIDI(for: clipID)
        reloadClips()
    }

    @objc private func setPitchShift(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let clipID = info["clipID"] as? UUID,
              let semitones = info["semitones"] as? Int,
              let idx = store.pianoRollAudioClips.firstIndex(where: { $0.id == clipID }) else { return }
        store.pianoRollAudioClips[idx].pitchCents = Float(semitones * 100)
        store.isDirty = true
        reloadClips()
    }

    @objc private func setFadeIn(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let clipID = info["clipID"] as? UUID,
              let ticks = info["ticks"] as? Int,
              let idx = store.pianoRollAudioClips.firstIndex(where: { $0.id == clipID }) else { return }
        store.pianoRollAudioClips[idx].fadeInTicks = ticks
        store.isDirty = true
        reloadClips()
    }

    @objc private func setFadeOut(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let clipID = info["clipID"] as? UUID,
              let ticks = info["ticks"] as? Int,
              let idx = store.pianoRollAudioClips.firstIndex(where: { $0.id == clipID }) else { return }
        store.pianoRollAudioClips[idx].fadeOutTicks = ticks
        store.isDirty = true
        reloadClips()
    }

    @objc private func duplicateClip(_ sender: NSMenuItem) {
        guard let clipID = sender.representedObject as? UUID else { return }
        store.duplicateAudioClip(id: clipID)
        reloadClips()
    }

    @objc private func removeClip(_ sender: NSMenuItem) {
        guard let clipID = sender.representedObject as? UUID else { return }
        store.removeAudioClip(id: clipID)
        reloadClips()
    }
}
#endif
