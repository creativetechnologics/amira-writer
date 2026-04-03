import AppKit
import Metal
import QuartzCore
import simd

// MARK: - TimelineDirtyFlags

@available(macOS 26.0, *)
struct TimelineDirtyFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let grid      = TimelineDirtyFlags(rawValue: 1 << 0)
    static let keyframes = TimelineDirtyFlags(rawValue: 1 << 1)
    static let playhead  = TimelineDirtyFlags(rawValue: 1 << 2)
    static let labels    = TimelineDirtyFlags(rawValue: 1 << 3)
    static let all: TimelineDirtyFlags = [.grid, .keyframes, .playhead, .labels]
}

// MARK: - TimelineRenderer

/// Metal renderer for the timeline/dope sheet editor.
/// Draws track lanes, keyframe diamonds, and the playhead.
@available(macOS 26.0, *)
@MainActor
final class TimelineRenderer {

    // MARK: - Metal State

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    // MARK: - Buffers

    private var gridBuffer: MTLBuffer?
    private var gridInstanceCount: Int = 0

    private var keyframeBuffer: MTLBuffer?
    private var keyframeInstanceCount: Int = 0

    private var playheadBuffer: MTLBuffer?
    private var playheadInstanceCount: Int = 0

    private static let maxGridInstances = 50_000
    private static let maxKeyframeInstances = 50_000
    private static let maxPlayheadInstances = 4

    // MARK: - Layout Constants

    let trackHeight: CGFloat = 24
    let rulerHeight: CGFloat = 24
    let labelWidth: CGFloat = 120

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[TimelineRenderer] No Metal device available.")
            return nil
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            print("[TimelineRenderer] Failed to create command queue.")
            return nil
        }
        self.commandQueue = commandQueue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: timelineShaderSource, options: nil)
        } catch {
            print("[TimelineRenderer] Shader compilation failed: \(error)")
            return nil
        }

        guard let vertexFn = library.makeFunction(name: "timeline_vertex_rect"),
              let fragmentFn = library.makeFunction(name: "timeline_fragment_rect") else {
            print("[TimelineRenderer] Failed to find shader functions.")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        let color = desc.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[TimelineRenderer] Pipeline creation failed: \(error)")
            return nil
        }

        let stride = MemoryLayout<RectInstance>.stride
        gridBuffer = device.makeBuffer(length: stride * Self.maxGridInstances, options: .storageModeShared)
        keyframeBuffer = device.makeBuffer(length: stride * Self.maxKeyframeInstances, options: .storageModeShared)
        playheadBuffer = device.makeBuffer(length: stride * Self.maxPlayheadInstances, options: .storageModeShared)
    }

    // MARK: - Build Grid

    func buildGrid(
        trackNames: [String],
        totalFrames: Int,
        fps: Int,
        pixelsPerFrame: CGFloat,
        viewport: CGSize,
        scrollOffset: CGPoint
    ) {
        guard let buffer = gridBuffer else { return }
        let ptr = buffer.contents().assumingMemoryBound(to: RectInstance.self)
        var count = 0

        let trackCount = trackNames.count
        let contentWidth = CGFloat(totalFrames) * pixelsPerFrame + labelWidth + 100

        // Track lane backgrounds
        for i in 0 ..< trackCount {
            let y = rulerHeight + CGFloat(i) * trackHeight
            let bgColor: SIMD4<Float> = (i % 2 == 0)
                ? SIMD4<Float>(0.10, 0.10, 0.12, 1.0)
                : SIMD4<Float>(0.08, 0.08, 0.10, 1.0)

            guard count < Self.maxGridInstances else { break }
            ptr[count] = RectInstance(
                position: SIMD2<Float>(Float(labelWidth), Float(y)),
                size: SIMD2<Float>(Float(contentWidth), Float(trackHeight)),
                color: bgColor,
                cornerRadius: 0
            )
            count += 1
        }

        // Vertical frame lines
        let framesPerBeat = fps  // 1-second grid lines
        let firstFrame = max(0, Int(scrollOffset.x / pixelsPerFrame) - 1)
        let lastFrame = min(totalFrames, Int((scrollOffset.x + viewport.width) / pixelsPerFrame) + 1)
        let totalHeight = Float(rulerHeight + CGFloat(trackCount) * trackHeight)

        var frame = firstFrame - (firstFrame % framesPerBeat)
        while frame <= lastFrame {
            guard count < Self.maxGridInstances else { break }
            let x = Float(labelWidth) + Float(frame) * Float(pixelsPerFrame)
            let isBeat = frame % fps == 0
            let alpha: Float = isBeat ? 0.25 : 0.10
            let lineColor = SIMD4<Float>(alpha, alpha, alpha, alpha) // premultiplied

            ptr[count] = RectInstance(
                position: SIMD2<Float>(x, 0),
                size: SIMD2<Float>(1, totalHeight),
                color: lineColor,
                cornerRadius: 0
            )
            count += 1
            frame += framesPerBeat / 4 // quarter-second subdivisions
            if frame == firstFrame { frame += 1 } // avoid infinite loop
        }

        // Track separator lines
        for i in 0 ... trackCount {
            guard count < Self.maxGridInstances else { break }
            let y = Float(rulerHeight + CGFloat(i) * trackHeight)
            let lineAlpha: Float = 0.15
            ptr[count] = RectInstance(
                position: SIMD2<Float>(0, y),
                size: SIMD2<Float>(Float(contentWidth), 1),
                color: SIMD4<Float>(lineAlpha, lineAlpha, lineAlpha, lineAlpha),
                cornerRadius: 0
            )
            count += 1
        }

        gridInstanceCount = count
    }

    // MARK: - Build Keyframes

    func buildKeyframes(
        tracks: [TimelineTrack],
        pixelsPerFrame: CGFloat,
        viewport: CGSize,
        scrollOffset: CGPoint
    ) {
        guard let buffer = keyframeBuffer else { return }
        let ptr = buffer.contents().assumingMemoryBound(to: RectInstance.self)
        var count = 0

        let diamondSize: Float = 8
        let firstVisibleFrame = max(0, Int((scrollOffset.x - CGFloat(labelWidth)) / pixelsPerFrame) - 1)
        let lastVisibleFrame = Int((scrollOffset.x - CGFloat(labelWidth) + viewport.width) / pixelsPerFrame) + 1

        for (trackIndex, track) in tracks.enumerated() {
            let centerY = Float(rulerHeight) + Float(trackIndex) * Float(trackHeight) + Float(trackHeight / 2)

            for keyframe in track.keyframes {
                guard keyframe.frame >= firstVisibleFrame, keyframe.frame <= lastVisibleFrame else { continue }
                guard count < Self.maxKeyframeInstances else { break }

                let x = Float(labelWidth) + Float(keyframe.frame) * Float(pixelsPerFrame) - diamondSize / 2
                let y = centerY - diamondSize / 2

                let color = keyframeColor(for: keyframe, track: track)

                ptr[count] = RectInstance(
                    position: SIMD2<Float>(x, y),
                    size: SIMD2<Float>(diamondSize, diamondSize),
                    color: color,
                    cornerRadius: 2
                )
                count += 1
            }
        }

        keyframeInstanceCount = count
    }

    private func keyframeColor(
        for keyframe: TimelineKeyframe,
        track: TimelineTrack
    ) -> SIMD4<Float> {
        switch keyframe.kind {
        case .transform:
            return SIMD4<Float>(0.20, 0.55, 0.90, 1.0)  // blue
        case .visibility:
            return SIMD4<Float>(0.70, 0.50, 0.85, 1.0)  // purple
        case .drawing:
            return SIMD4<Float>(0.85, 0.55, 0.20, 1.0)  // orange
        case .expression:
            switch track.role {
            case .facing:
                return SIMD4<Float>(0.55, 0.70, 0.22, 1.0)  // olive
            case .view:
                return SIMD4<Float>(0.15, 0.72, 0.88, 1.0)  // teal
            case .pose:
                return SIMD4<Float>(0.92, 0.47, 0.24, 1.0)  // amber
            case .action:
                return SIMD4<Float>(0.95, 0.35, 0.35, 1.0)  // red
            case .mouth:
                return SIMD4<Float>(0.92, 0.24, 0.62, 1.0)  // pink
            case .shadowStyle:
                return SIMD4<Float>(0.28, 0.28, 0.32, 1.0)  // charcoal
            case .shadowOpacity:
                return SIMD4<Float>(0.44, 0.44, 0.50, 1.0)  // slate
            case .cameraShot:
                return SIMD4<Float>(0.55, 0.44, 0.92, 1.0)  // indigo
            case .cameraDefaultShot:
                return SIMD4<Float>(0.36, 0.63, 0.95, 1.0)  // sky
            case .cameraFocus:
                return SIMD4<Float>(0.82, 0.58, 0.18, 1.0)  // ochre
            case .cameraIntent:
                return SIMD4<Float>(0.73, 0.40, 0.86, 1.0)  // orchid
            case .cameraBeat:
                return SIMD4<Float>(0.88, 0.72, 0.20, 1.0)  // gold
            case .cameraNotes:
                return SIMD4<Float>(0.48, 0.78, 0.70, 1.0)  // mint
            case .expression, .none, .some(.custom), .some(.camera), .some(.transform),
                 .some(.visibility), .some(.drawing):
                return SIMD4<Float>(0.20, 0.75, 0.45, 1.0)  // green
            }
        }
    }

    // MARK: - Build Playhead

    func buildPlayhead(
        currentFrame: Int,
        trackCount: Int,
        pixelsPerFrame: CGFloat
    ) {
        guard let buffer = playheadBuffer else { return }
        let ptr = buffer.contents().assumingMemoryBound(to: RectInstance.self)

        let x = Float(labelWidth) + Float(currentFrame) * Float(pixelsPerFrame)
        let totalHeight = Float(rulerHeight + CGFloat(trackCount) * trackHeight)

        // Playhead line
        let alpha: Float = 0.90
        ptr[0] = RectInstance(
            position: SIMD2<Float>(x - 0.5, 0),
            size: SIMD2<Float>(1.5, totalHeight),
            color: SIMD4<Float>(0.90 * alpha, 0.25 * alpha, 0.25 * alpha, alpha),
            cornerRadius: 0
        )

        // Playhead triangle at top
        ptr[1] = RectInstance(
            position: SIMD2<Float>(x - 4, 0),
            size: SIMD2<Float>(8, Float(rulerHeight)),
            color: SIMD4<Float>(0.90 * alpha, 0.25 * alpha, 0.25 * alpha, alpha),
            cornerRadius: 3
        )

        playheadInstanceCount = 2
    }

    // MARK: - Render

    func render(
        to layer: CAMetalLayer,
        scrollOffset: CGPoint,
        viewport: CGSize
    ) {
        guard let drawable = layer.nextDrawable() else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            commandBuffer.commit()
            return
        }

        var uniforms = TimelineUniforms(
            viewportSize: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
            scrollOffset: SIMD2<Float>(Float(scrollOffset.x), Float(scrollOffset.y))
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TimelineUniforms>.stride, index: 0)

        // Draw grid
        if gridInstanceCount > 0, let buffer = gridBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: gridInstanceCount)
        }

        // Draw keyframes
        if keyframeInstanceCount > 0, let buffer = keyframeBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyframeInstanceCount)
        }

        // Draw playhead (on top)
        if playheadInstanceCount > 0, let buffer = playheadBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: playheadInstanceCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
