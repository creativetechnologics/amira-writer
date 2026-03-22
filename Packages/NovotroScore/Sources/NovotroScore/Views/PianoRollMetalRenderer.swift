#if canImport(AppKit)
import AppKit
import Metal
import QuartzCore
import simd

// MARK: - Metal Shader Source

private let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewportSize;
    float2 scrollOffset;
};

struct RectInstance {
    float2 position;
    float2 size;
    float4 color;
    float cornerRadius;
    float _padding;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 rectPos;
    float2 rectSize;
    float cornerRadius;
};

vertex VertexOut vertex_rect(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant RectInstance* instances [[buffer(1)]]
) {
    const float2 positions[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    float2 unitPos = positions[vertexID];
    RectInstance inst = instances[instanceID];

    float2 pointPos = inst.position - uniforms.scrollOffset + unitPos * inst.size;

    float2 ndc;
    ndc.x = (pointPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pointPos.y / uniforms.viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = inst.color;
    out.rectPos = unitPos * inst.size;
    out.rectSize = inst.size;
    out.cornerRadius = inst.cornerRadius;
    return out;
}

fragment float4 fragment_rect(VertexOut in [[stage_in]]) {
    if (in.cornerRadius > 0.001) {
        float2 halfSize = in.rectSize * 0.5;
        float2 center = in.rectPos - halfSize;
        float2 q = abs(center) - halfSize + in.cornerRadius;
        float dist = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - in.cornerRadius;
        if (dist > 0.5) {
            discard_fragment();
        }
        float alpha = in.color.a * saturate(0.5 - dist);
        return float4(in.color.rgb * alpha, alpha);
    }
    return in.color;
}
"""

// MARK: - PianoRollMetalRenderer

@available(macOS 26.0, *)
@MainActor
final class PianoRollMetalRenderer {

    // MARK: - GPU Types

    struct Uniforms {
        var viewportSize: SIMD2<Float>
        var scrollOffset: SIMD2<Float>
    }

    struct RectInstance {
        var position: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
        var cornerRadius: Float
        var _padding: Float = 0
    }

    // MARK: - Metal State

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    // MARK: - Instance Buffers

    private var gridBuffer: MTLBuffer?
    private var gridInstanceCount: Int = 0

    private var noteBuffer: MTLBuffer?
    private var noteInstanceCount: Int = 0

    private var ghostBuffer: MTLBuffer?
    private var ghostInstanceCount: Int = 0

    private var playheadBuffer: MTLBuffer?
    private var playheadInstanceCount: Int = 0

    private var velocityBuffer: MTLBuffer?
    private var velocityInstanceCount: Int = 0

    private var highlightBuffer: MTLBuffer?
    private var highlightInstanceCount: Int = 0

    // MARK: - Dirty Checking State

    private var lastGridWidth: CGFloat = 0
    private var lastGridHeight: CGFloat = 0
    private var lastRowHeight: CGFloat = 0
    private var lastPixelsPerTick: CGFloat = 0
    private var lastTicksPerQuarter: Int = 0
    private var lastMinPitch: Int = 0
    private var lastMaxPitch: Int = 0

    // MARK: - Constants

    /// Maximum number of instances in a single buffer allocation.
    /// 500K instances covers even extremely large scores.
    private static let maxGridInstances = 500_000
    private static let maxNoteInstances = 100_000
    private static let maxGhostInstances = 100_000
    private static let maxPlayheadInstances = 8
    private static let maxVelocityInstances = 100_000
    private static let maxHighlightInstances = 2

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[PianoRollMetalRenderer] No Metal device available.")
            return nil
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            print("[PianoRollMetalRenderer] Failed to create command queue.")
            return nil
        }
        self.commandQueue = commandQueue

        // Compile shaders from source string
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            print("[PianoRollMetalRenderer] Shader compilation failed: \(error)")
            return nil
        }

        guard let vertexFunction = library.makeFunction(name: "vertex_rect"),
              let fragmentFunction = library.makeFunction(name: "fragment_rect") else {
            print("[PianoRollMetalRenderer] Failed to find shader functions.")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        // Single color attachment with premultiplied alpha blending
        let colorAttachment = descriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = .bgra8Unorm
        colorAttachment.isBlendingEnabled = true
        colorAttachment.sourceRGBBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[PianoRollMetalRenderer] Pipeline state creation failed: \(error)")
            return nil
        }

        // Pre-allocate buffers
        let stride = MemoryLayout<RectInstance>.stride
        gridBuffer = device.makeBuffer(length: stride * Self.maxGridInstances, options: .storageModeShared)
        noteBuffer = device.makeBuffer(length: stride * Self.maxNoteInstances, options: .storageModeShared)
        ghostBuffer = device.makeBuffer(length: stride * Self.maxGhostInstances, options: .storageModeShared)
        playheadBuffer = device.makeBuffer(length: stride * Self.maxPlayheadInstances, options: .storageModeShared)
        velocityBuffer = device.makeBuffer(length: stride * Self.maxVelocityInstances, options: .storageModeShared)
        highlightBuffer = device.makeBuffer(length: stride * Self.maxHighlightInstances, options: .storageModeShared)
    }

    // MARK: - Black Key Detection

    private func isBlackKey(_ pitch: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(pitch % 12)
    }

    // MARK: - Update Grid

    /// Optional set of pitch classes (0-11) that are "in scale".
    /// When non-nil, in-scale rows get a subtle highlight tint.
    var scaleHighlightPitchClasses: Set<Int>?

    /// Current snap grid spacing in ticks. When > 0 and smaller than beat spacing,
    /// draws additional subtle subdivision lines at snap positions.
    var snapTickSpan: Int = 0

    /// Time signature events for correct bar/beat grid lines.
    var timeSignatures: [TimeSignatureEvent] = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]

    private var lastScaleHighlight: Set<Int>?
    private var lastSnapTickSpan: Int = 0
    private var lastTimeSignatures: [TimeSignatureEvent] = []

    func updateGrid(
        width: CGFloat,
        height: CGFloat,
        rowHeight: CGFloat,
        minPitch: Int,
        maxPitch: Int,
        ticksPerQuarter: Int,
        pixelsPerTick: CGFloat
    ) {
        // Dirty check — skip if nothing changed
        if width == lastGridWidth,
           height == lastGridHeight,
           rowHeight == lastRowHeight,
           pixelsPerTick == lastPixelsPerTick,
           ticksPerQuarter == lastTicksPerQuarter,
           minPitch == lastMinPitch,
           maxPitch == lastMaxPitch,
           scaleHighlightPitchClasses == lastScaleHighlight,
           snapTickSpan == lastSnapTickSpan,
           timeSignatures == lastTimeSignatures {
            return
        }

        lastGridWidth = width
        lastGridHeight = height
        lastRowHeight = rowHeight
        lastPixelsPerTick = pixelsPerTick
        lastTicksPerQuarter = ticksPerQuarter
        lastMinPitch = minPitch
        lastMaxPitch = maxPitch
        lastScaleHighlight = scaleHighlightPitchClasses
        lastSnapTickSpan = snapTickSpan
        lastTimeSignatures = timeSignatures

        guard let buffer = gridBuffer else { return }

        let ptr = buffer.contents().bindMemory(to: RectInstance.self, capacity: Self.maxGridInstances)
        var count = 0
        let maxCount = Self.maxGridInstances

        let rowCount = max(0, maxPitch - minPitch + 1)
        let fWidth = Float(width)
        let fRowHeight = Float(rowHeight)

        // Row background colors — FL Studio style dark slate with subtle blue-green tint
        // Background clears to (0.14, 0.15, 0.16) so these sit just above/below that
        let blackKeyBase = SIMD4<Float>(0.13, 0.14, 0.15, 1.0)
        let whiteKeyBase = SIMD4<Float>(0.19, 0.20, 0.21, 1.0)

        // Scale highlighting: in-scale rows get a subtle warm tint, out-of-scale rows get dimmed
        let scaleClasses: Set<Int>? = (scaleHighlightPitchClasses?.isEmpty == false) ? scaleHighlightPitchClasses : nil

        // 1. Row backgrounds
        for row in 0..<rowCount {
            guard count < maxCount else { break }
            let pitch = maxPitch - row
            let y = Float(row) * fRowHeight
            let baseColor = isBlackKey(pitch) ? blackKeyBase : whiteKeyBase

            let color: SIMD4<Float>
            if let scaleClasses {
                let pitchClass = ((pitch % 12) + 12) % 12
                let inScale = scaleClasses.contains(pitchClass)
                if inScale {
                    // FL Studio-style: scale rows get noticeably lighter
                    color = SIMD4<Float>(
                        baseColor.x + 0.05,
                        baseColor.y + 0.05,
                        baseColor.z + 0.05,
                        1.0
                    )
                } else {
                    // FL Studio-style: out-of-scale rows get noticeably darker
                    color = SIMD4<Float>(
                        baseColor.x * 0.60,
                        baseColor.y * 0.60,
                        baseColor.z * 0.60,
                        1.0
                    )
                }
            } else {
                color = baseColor
            }

            ptr[count] = RectInstance(
                position: SIMD2<Float>(0, y),
                size: SIMD2<Float>(fWidth, fRowHeight),
                color: color,
                cornerRadius: 0
            )
            count += 1
        }

        // 2. Horizontal grid lines (row separators) — very subtle dark lines (premultiplied)
        let hLineColor = SIMD4<Float>(0, 0, 0, 0.40)
        let hLineThickness: Float = 0.5
        for row in 0...rowCount {
            guard count < maxCount else { break }
            let y = Float(row) * fRowHeight
            ptr[count] = RectInstance(
                position: SIMD2<Float>(0, y - hLineThickness * 0.5),
                size: SIMD2<Float>(fWidth, hLineThickness),
                color: hLineColor,
                cornerRadius: 0
            )
            count += 1
        }

        // 3. Beat and bar lines (premultiplied alpha: RGB * A)
        // Time-signature-aware: computes bar boundaries from timeSignatures list
        let beatLineColor = SIMD4<Float>(0.14, 0.14, 0.14, 0.14)
        let beatLineThickness: Float = 0.5
        let barLineColor = SIMD4<Float>(0.35, 0.35, 0.35, 0.35)
        let barLineThickness: Float = 0.5

        let safePPT = max(pixelsPerTick, 0.000_01)
        let beatTicks = max(1, ticksPerQuarter)
        let maxTick = Int(CGFloat(width) / safePPT)
        let fHeight = Float(height)

        // Collect all bar and beat positions using time signatures
        var barTicks_set = Set<Int>()   // ticks where bar lines go
        var beatTicks_set = Set<Int>()  // ticks where beat lines go (non-bar)

        let tsEvents = timeSignatures.isEmpty
            ? [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
            : timeSignatures.sorted(by: { $0.tick < $1.tick })

        var tsIdx = 0
        var currentNum = tsEvents[0].numerator
        var currentDenom = tsEvents[0].denominator
        var barStart = 0
        var safetyCount = 0
        let maxLines = 6000

        while barStart <= maxTick, safetyCount < maxLines {
            safetyCount += 1
            barTicks_set.insert(barStart)

            // Beat ticks per beat for this time signature
            // In X/4 time, beat = quarter note = ticksPerQuarter
            // In X/8 time, beat = eighth note = ticksPerQuarter / 2
            // In X/2 time, beat = half note = ticksPerQuarter * 2
            let beatTicksForTS = max(1, beatTicks * 4 / max(1, currentDenom))
            let barLength = beatTicksForTS * currentNum

            // Add beat lines within this bar
            for b in 1..<currentNum {
                let beatPos = barStart + b * beatTicksForTS
                if beatPos <= maxTick {
                    beatTicks_set.insert(beatPos)
                }
            }

            let nextBar = barStart + barLength

            // Check if a time signature change occurs before the next bar
            while tsIdx + 1 < tsEvents.count, tsEvents[tsIdx + 1].tick <= nextBar {
                tsIdx += 1
                currentNum = tsEvents[tsIdx].numerator
                currentDenom = tsEvents[tsIdx].denominator
            }

            barStart = nextBar
        }

        // Draw bar lines
        let sortedBars = barTicks_set.sorted()
        for barTick in sortedBars {
            guard count < maxCount else { break }
            let x = Float(barTick) * Float(safePPT)
            ptr[count] = RectInstance(
                position: SIMD2<Float>(x - barLineThickness * 0.5, 0),
                size: SIMD2<Float>(barLineThickness, fHeight),
                color: barLineColor,
                cornerRadius: 0
            )
            count += 1
        }

        // Draw beat lines (already excludes bar positions)
        let sortedBeats = beatTicks_set.sorted()
        for bt in sortedBeats {
            guard count < maxCount else { break }
            let x = Float(bt) * Float(safePPT)
            ptr[count] = RectInstance(
                position: SIMD2<Float>(x - beatLineThickness * 0.5, 0),
                size: SIMD2<Float>(beatLineThickness, fHeight),
                color: beatLineColor,
                cornerRadius: 0
            )
            count += 1
        }

        // 4. Snap subdivision lines (drawn even lighter than beat lines)
        // Only draw when snap is finer than beat grid and coarser than 1 tick
        if snapTickSpan > 1, snapTickSpan < beatTicks {
            let snapLineColor = SIMD4<Float>(0.09, 0.09, 0.09, 0.09)  // premultiplied
            let snapLineThickness: Float = 0.5
            let allGridTicks = barTicks_set.union(beatTicks_set)
            let maxSnapLines = 4800
            let canDrawSnap = maxTick <= snapTickSpan * maxSnapLines
            if canDrawSnap {
                var tick = 0
                while tick <= maxTick {
                    if !allGridTicks.contains(tick) {
                        guard count < maxCount else { break }
                        let x = Float(tick) * Float(safePPT)
                        ptr[count] = RectInstance(
                            position: SIMD2<Float>(x - snapLineThickness * 0.5, 0),
                            size: SIMD2<Float>(snapLineThickness, fHeight),
                            color: snapLineColor,
                            cornerRadius: 0
                        )
                        count += 1
                    }
                    tick += snapTickSpan
                }
            }
        }

        gridInstanceCount = count
    }

    // MARK: - Update Notes

    // MARK: - Update Ghost Notes

    /// Renders notes from non-active tracks as faded background hints.
    /// Ghost notes are drawn at very low opacity with no selection border.
    /// Viewport culling: notes entirely outside `scrollOffsetX..<scrollOffsetX+viewportWidth`
    /// are skipped to avoid filling the GPU buffer with invisible geometry.
    func updateGhostNotes(
        notes: [PianoRollNote],
        maxPitch: Int,
        rowHeight: CGFloat,
        pixelsPerTick: CGFloat,
        colorProvider: (Int, Int) -> SIMD4<Float>,
        scrollOffsetX: CGFloat = 0,
        viewportWidth: CGFloat = .greatestFiniteMagnitude
    ) {
        guard let buffer = ghostBuffer else { return }

        let ptr = buffer.contents().bindMemory(to: RectInstance.self, capacity: Self.maxGhostInstances)
        var count = 0
        let maxCount = Self.maxGhostInstances
        let fRowHeight = Float(rowHeight)
        let fPPT = Float(pixelsPerTick)
        let ghostAlpha: Float = 0.70

        // Visible tick range for culling (with small margin)
        let visMinX = Float(scrollOffsetX) - 20
        let visMaxX = Float(scrollOffsetX + viewportWidth) + 20

        for note in notes {
            guard count < maxCount else { break }

            let x = Float(note.startTick) * fPPT
            let w = max(6, Float(note.duration) * fPPT)

            // Viewport culling: skip notes entirely outside the visible range
            guard x + w > visMinX && x < visMaxX else { continue }

            let y = Float(maxPitch - note.pitch) * fRowHeight
            let h = fRowHeight - 1

            // Ghost notes — neutral grey, clearly visible against lightened backgrounds
            let greyVal: Float = 0.55 * ghostAlpha  // premultiplied neutral grey
            let color = SIMD4<Float>(greyVal, greyVal, greyVal, ghostAlpha)

            ptr[count] = RectInstance(
                position: SIMD2<Float>(x, y),
                size: SIMD2<Float>(w, h),
                color: color,
                cornerRadius: 2
            )
            count += 1
        }

        ghostInstanceCount = count
    }

    /// Clears ghost note buffer when ghost notes are disabled.
    func clearGhostNotes() {
        ghostInstanceCount = 0
    }

    /// When true, note colors are blended with a cool-to-warm gradient based on velocity.
    var velocityColorEnabled: Bool = false

    // MARK: - Update Notes

    /// Viewport culling: notes entirely outside `scrollOffsetX..<scrollOffsetX+viewportWidth`
    /// are skipped to avoid filling the GPU buffer with invisible geometry.
    func updateNotes(
        notes: [PianoRollNote],
        maxPitch: Int,
        rowHeight: CGFloat,
        pixelsPerTick: CGFloat,
        selectedNoteIDs: Set<UUID>,
        colorProvider: (Int, Int) -> SIMD4<Float>,
        scrollOffsetX: CGFloat = 0,
        viewportWidth: CGFloat = .greatestFiniteMagnitude
    ) {
        guard let buffer = noteBuffer else { return }

        let ptr = buffer.contents().bindMemory(to: RectInstance.self, capacity: Self.maxNoteInstances)
        var count = 0
        let maxCount = Self.maxNoteInstances
        let fRowHeight = Float(rowHeight)
        let fPPT = Float(pixelsPerTick)

        // Visible tick range for culling (with small margin)
        let visMinX = Float(scrollOffsetX) - 20
        let visMaxX = Float(scrollOffsetX + viewportWidth) + 20

        for note in notes {
            guard count < maxCount - 5 else { break }  // reserve space for border rects

            let x = Float(note.startTick) * fPPT
            let w = max(8, Float(note.duration) * fPPT)

            // Viewport culling: skip notes entirely outside the visible range
            guard x + w > visMinX && x < visMaxX else { continue }

            let y = Float(maxPitch - note.pitch) * fRowHeight
            let h = fRowHeight - 1
            let isSelected = selectedNoteIDs.contains(note.id)

            var baseColor = colorProvider(note.channel, note.trackIndex)

            // B.3: Velocity → brightness mapping (FL Studio style)
            // Higher velocity = brighter, lower velocity = darker
            let velT = Float(note.velocity) / 127.0
            let brightnessMul: Float = 0.55 + velT * 0.45  // range 0.55–1.0
            baseColor = SIMD4<Float>(
                baseColor.x * brightnessMul,
                baseColor.y * brightnessMul,
                baseColor.z * brightnessMul,
                baseColor.w
            )

            // Velocity coloring mode: blend with cool-to-warm gradient
            if velocityColorEnabled {
                let t = velT
                let velR: Float = min(1.0, 0.3 + t * 0.7)
                let velG: Float = 0.3 + t * 0.4 - max(0, (t - 0.6) * 1.0)
                let velB: Float = max(0.1, 0.9 - t * 0.8)
                baseColor = SIMD4<Float>(
                    baseColor.x * 0.5 + velR * 0.5,
                    baseColor.y * 0.5 + velG * 0.5,
                    baseColor.z * 0.5 + velB * 0.5,
                    baseColor.w
                )
            }

            // Muted notes render at ~30% opacity
            let muteFactor: Float = note.muted ? 0.30 : 1.0
            let noteAlpha: Float = (isSelected ? 0.95 : 0.88) * baseColor.w * muteFactor

            // B.2: Note border — 1px darker outline behind the note body (premultiplied)
            let borderDarken: Float = 0.35
            let borderAlpha: Float = noteAlpha * 0.80
            let borderColor = SIMD4<Float>(
                baseColor.x * borderDarken * borderAlpha,
                baseColor.y * borderDarken * borderAlpha,
                baseColor.z * borderDarken * borderAlpha,
                borderAlpha
            )
            ptr[count] = RectInstance(
                position: SIMD2<Float>(x - 0.5, y - 0.5),
                size: SIMD2<Float>(w + 1, h + 1),
                color: borderColor,
                cornerRadius: 3.5
            )
            count += 1

            // Note body (premultiplied alpha)
            let noteColor = SIMD4<Float>(baseColor.x * noteAlpha, baseColor.y * noteAlpha, baseColor.z * noteAlpha, noteAlpha)
            ptr[count] = RectInstance(
                position: SIMD2<Float>(x, y),
                size: SIMD2<Float>(w, h),
                color: noteColor,
                cornerRadius: 3
            )
            count += 1

            // B.4: Selection highlight — bright accent outline (premultiplied)
            if isSelected {
                let bAlpha: Float = 0.95
                let borderColor = SIMD4<Float>(bAlpha, bAlpha, bAlpha, bAlpha)
                let bw: Float = 1.5
                // Top
                ptr[count] = RectInstance(
                    position: SIMD2<Float>(x, y),
                    size: SIMD2<Float>(w, bw),
                    color: borderColor,
                    cornerRadius: 0
                )
                count += 1
                // Bottom
                ptr[count] = RectInstance(
                    position: SIMD2<Float>(x, y + h - bw),
                    size: SIMD2<Float>(w, bw),
                    color: borderColor,
                    cornerRadius: 0
                )
                count += 1
                // Left
                ptr[count] = RectInstance(
                    position: SIMD2<Float>(x, y),
                    size: SIMD2<Float>(bw, h),
                    color: borderColor,
                    cornerRadius: 0
                )
                count += 1
                // Right
                ptr[count] = RectInstance(
                    position: SIMD2<Float>(x + w - bw, y),
                    size: SIMD2<Float>(bw, h),
                    color: borderColor,
                    cornerRadius: 0
                )
                count += 1
            }
        }

        noteInstanceCount = count
    }

    // MARK: - Update Playhead

    func updatePlayhead(
        tick: Int,
        height: CGFloat,
        pixelsPerTick: CGFloat
    ) {
        guard let buffer = playheadBuffer else { return }

        let ptr = buffer.contents().bindMemory(to: RectInstance.self, capacity: Self.maxPlayheadInstances)
        var count = 0
        let fHeight = Float(height)
        let x = Float(tick) * Float(pixelsPerTick)

        // Soft outer glow (premultiplied alpha)
        let glowWidth: Float = 3.0
        let glowAlpha: Float = 0.06
        let glowColor = SIMD4<Float>(0.7 * glowAlpha, 0.85 * glowAlpha, 1.0 * glowAlpha, glowAlpha)
        ptr[count] = RectInstance(
            position: SIMD2<Float>(x - glowWidth * 0.5, 0),
            size: SIMD2<Float>(glowWidth, fHeight),
            color: glowColor,
            cornerRadius: 0
        )
        count += 1

        // Core line — 0.5pt = 1 physical pixel on Retina (premultiplied alpha)
        let lineWidth: Float = 0.5
        let lineAlpha: Float = 0.85
        let lineColor = SIMD4<Float>(0.8 * lineAlpha, 0.9 * lineAlpha, 1.0 * lineAlpha, lineAlpha)
        ptr[count] = RectInstance(
            position: SIMD2<Float>(x - lineWidth * 0.5, 0),
            size: SIMD2<Float>(lineWidth, fHeight),
            color: lineColor,
            cornerRadius: 0
        )
        count += 1

        playheadInstanceCount = count
    }

    // MARK: - Update Highlight Row

    func updateHighlight(
        pitch: Int?,
        maxPitch: Int,
        rowHeight: CGFloat,
        gridWidth: CGFloat
    ) {
        guard let buffer = highlightBuffer else { return }
        let ptr = buffer.contents().bindMemory(to: RectInstance.self, capacity: Self.maxHighlightInstances)

        guard let pitch = pitch else {
            highlightInstanceCount = 0
            return
        }

        let fRowHeight = Float(rowHeight)
        let y = Float(maxPitch - pitch) * fRowHeight
        // Premultiplied alpha: white at 6% opacity
        let alpha: Float = 0.06
        let color = SIMD4<Float>(alpha, alpha, alpha, alpha)

        ptr[0] = RectInstance(
            position: SIMD2<Float>(0, y),
            size: SIMD2<Float>(Float(gridWidth), fRowHeight),
            color: color,
            cornerRadius: 0
        )
        highlightInstanceCount = 1
    }

    // MARK: - Update Velocity Bars

    func updateVelocityBars(
        notes: [PianoRollNote],
        maxHeight: CGFloat,
        pixelsPerTick: CGFloat,
        selectedNoteIDs: Set<UUID>,
        colorProvider: (Int, Int) -> SIMD4<Float>
    ) {
        guard let buffer = velocityBuffer else { return }

        let ptr = buffer.contents().bindMemory(to: RectInstance.self, capacity: Self.maxVelocityInstances)
        var count = 0
        let maxCount = Self.maxVelocityInstances
        let fMaxHeight = Float(maxHeight)
        let fPPT = Float(pixelsPerTick)
        let barWidth: Float = max(3, 4 * fPPT)

        let stemWidth: Float = max(2, min(barWidth * 0.35, 3))
        let circleSize: Float = max(5, min(barWidth * 0.8, 8))

        for note in notes {
            guard count + 2 < maxCount else { break }

            let x = Float(note.startTick) * fPPT
            let velocityFraction = Float(note.velocity) / 127.0
            let barHeight = max(2, velocityFraction * fMaxHeight)
            let y = fMaxHeight - barHeight

            let isSelected = selectedNoteIDs.contains(note.id)
            let baseColor = colorProvider(note.channel, note.trackIndex)

            let alpha: Float = isSelected ? 0.90 : 0.65

            // B.6: FL Studio-style velocity stem (thin vertical line)
            let stemAlpha = alpha * 0.7
            let stemColor = SIMD4<Float>(baseColor.x * stemAlpha, baseColor.y * stemAlpha, baseColor.z * stemAlpha, stemAlpha)
            ptr[count] = RectInstance(
                position: SIMD2<Float>(x + barWidth * 0.5 - stemWidth * 0.5, y),
                size: SIMD2<Float>(stemWidth, barHeight),
                color: stemColor,
                cornerRadius: 0
            )
            count += 1

            // B.6: Circle handle at the top of the velocity bar
            let circleColor = SIMD4<Float>(baseColor.x * alpha, baseColor.y * alpha, baseColor.z * alpha, alpha)
            ptr[count] = RectInstance(
                position: SIMD2<Float>(x + barWidth * 0.5 - circleSize * 0.5, y - circleSize * 0.3),
                size: SIMD2<Float>(circleSize, circleSize),
                color: circleColor,
                cornerRadius: circleSize * 0.5  // fully round
            )
            count += 1
        }

        velocityInstanceCount = count
    }

    // MARK: - Layer Configuration

    /// One-time CAMetalLayer setup. Call from `PianoRollEditorView`'s
    /// `updateLayout()` or when the renderer is first assigned, instead of
    /// repeating this work on every frame.
    private var layerConfigured = false

    func configureLayer(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layerConfigured = true
    }

    // MARK: - Render (Main Grid)

    func render(
        to layer: CAMetalLayer,
        scrollOffset: CGPoint,
        viewport: CGSize
    ) {
        if !layerConfigured { configureLayer(layer) }

        guard let drawable = layer.nextDrawable() else { return }

        let passDescriptor = MTLRenderPassDescriptor()
        let colorAttachment = passDescriptor.colorAttachments[0]!
        colorAttachment.texture = drawable.texture
        colorAttachment.loadAction = .clear
        // Background clear color: FL Studio-style dark slate with subtle blue-green tint
        colorAttachment.clearColor = MTLClearColor(red: 0.14, green: 0.15, blue: 0.16, alpha: 1.0)
        colorAttachment.storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)

        // The viewport size in points (Metal works in pixels, but our uniforms
        // handle the point-to-NDC transform; layer handles scale factor)
        var uniforms = Uniforms(
            viewportSize: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
            scrollOffset: SIMD2<Float>(Float(scrollOffset.x), Float(scrollOffset.y))
        )

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        // Draw grid (background rows + lines)
        if gridInstanceCount > 0, let buffer = gridBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: gridInstanceCount
            )
        }

        // Draw row highlight (faint glow on active pitch row during drawing)
        if highlightInstanceCount > 0, let buffer = highlightBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: highlightInstanceCount
            )
        }

        // Draw ghost notes (faded background hints from other tracks)
        if ghostInstanceCount > 0, let buffer = ghostBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: ghostInstanceCount
            )
        }

        // Draw notes
        if noteInstanceCount > 0, let buffer = noteBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: noteInstanceCount
            )
        }

        // Draw playhead (on top)
        if playheadInstanceCount > 0, let buffer = playheadBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: playheadInstanceCount
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Render Velocity Lane

    func renderVelocity(
        to layer: CAMetalLayer,
        scrollOffset: CGPoint,
        viewport: CGSize
    ) {
        if !layerConfigured { configureLayer(layer) }

        guard let drawable = layer.nextDrawable() else { return }

        let passDescriptor = MTLRenderPassDescriptor()
        let colorAttachment = passDescriptor.colorAttachments[0]!
        colorAttachment.texture = drawable.texture
        colorAttachment.loadAction = .clear
        colorAttachment.clearColor = MTLClearColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1.0)
        colorAttachment.storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)

        var uniforms = Uniforms(
            viewportSize: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
            scrollOffset: SIMD2<Float>(Float(scrollOffset.x), 0)
        )

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        if velocityInstanceCount > 0, let buffer = velocityBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: velocityInstanceCount
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
#endif
