import CoreVideo
import Foundation
import Metal
import simd

@available(macOS 26.0, *)
@MainActor
final class MouthSpriteComposer {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    init?(device: MTLDevice) {
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: canvasShaderSource, options: nil)
        } catch { return nil }

        guard let vertexFn = library.makeFunction(name: "sprite_vertex"),
              let fragmentFn = library.makeFunction(name: "sprite_fragment")
        else { return nil }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        let color = pipelineDesc.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch { return nil }

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.samplerState = sampler

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    func composite(
        originalBuffer: CVPixelBuffer,
        overlays: [MouthOverlay],
        outputSize: SIMD2<Int>,
        featherRadius: Float
    ) -> CVPixelBuffer? {
        let width = outputSize.x
        let height = outputSize.y
        guard width > 0, height > 0 else { return nil }
        guard let textureCache, let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let inputWidth = CVPixelBufferGetWidth(originalBuffer)
        let inputHeight = CVPixelBufferGetHeight(originalBuffer)

        var cvInputTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, originalBuffer, nil,
            .bgra8Unorm, inputWidth, inputHeight, 0, &cvInputTexture
        )
        guard let inputTexture = cvInputTexture.flatMap({ CVMetalTextureGetTexture($0) }) else { return nil }

        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        outputDesc.usage = [.renderTarget, .shaderRead]
        outputDesc.storageMode = .private
        guard let outputTexture = device.makeTexture(descriptor: outputDesc) else { return nil }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = outputTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return nil }

        let projection = orthographicProjection(width: Float(width), height: Float(height))
        var uniforms = CanvasUniforms(
            projectionMatrix: projection,
            viewMatrix: simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        )

        var bgSprite = SpriteInstance(
            position: SIMD2<Float>(Float(width) / 2, Float(height) / 2),
            size: SIMD2<Float>(Float(width), Float(height)),
            rotation: 0, opacity: 1.0,
            uvOrigin: SIMD2<Float>(0, 0), uvSize: SIMD2<Float>(1, 1), zOrder: 0
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.setVertexBytes(&bgSprite, length: MemoryLayout<SpriteInstance>.stride, index: 1)
        encoder.setFragmentTexture(inputTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        for overlay in overlays {
            var sprite = SpriteInstance(
                position: overlay.transform.centerPosition,
                size: overlay.transform.size,
                rotation: overlay.transform.rotation,
                opacity: overlay.transform.opacity,
                uvOrigin: SIMD2<Float>(0, 0), uvSize: SIMD2<Float>(1, 1), zOrder: 1
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.setVertexBytes(&sprite, length: MemoryLayout<SpriteInstance>.stride, index: 1)
            encoder.setFragmentTexture(inputTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        encoder.endEncoding()

        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height
        guard let stagingBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else { return nil }

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blitEncoder.copy(
            from: outputTexture,
            sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: stagingBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &outputBuffer)
        guard let output = outputBuffer else { return nil }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(output) else { return nil }
        let dstBPRow = CVPixelBufferGetBytesPerRow(output)
        let srcBase = stagingBuffer.contents()

        if dstBPRow == bytesPerRow {
            memcpy(dstBase, srcBase, bufferSize)
        } else {
            for row in 0..<height {
                memcpy(dstBase.advanced(by: row * dstBPRow), srcBase.advanced(by: row * bytesPerRow), bytesPerRow)
            }
        }

        return output
    }

    func compositeWithMouthWarp(
        originalBuffer: CVPixelBuffer,
        overlays: [MouthOverlay],
        outputSize: SIMD2<Int>,
        featherRadius: Float
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(originalBuffer)
        let height = CVPixelBufferGetHeight(originalBuffer)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(originalBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(originalBuffer, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(originalBuffer) else { return nil }
        let srcBPRow = CVPixelBufferGetBytesPerRow(originalBuffer)

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &outputBuffer)
        guard let dstBuffer = outputBuffer else { return nil }

        CVPixelBufferLockBaseAddress(dstBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(dstBuffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(dstBuffer) else { return nil }
        let dstBPRow = CVPixelBufferGetBytesPerRow(dstBuffer)

        if dstBPRow == srcBPRow {
            memcpy(dstBase, srcBase, dstBPRow * height)
        } else {
            for row in 0..<height {
                memcpy(dstBase.advanced(by: row * dstBPRow), srcBase.advanced(by: row * srcBPRow), min(dstBPRow, srcBPRow))
            }
        }

        for overlay in overlays {
            warpMouthRegion(
                from: srcBase,
                to: dstBase,
                width: width,
                height: height,
                sourceBytesPerRow: srcBPRow,
                destinationBytesPerRow: dstBPRow,
                overlay: overlay, featherRadius: featherRadius
            )
        }

        return dstBuffer
    }

    private func warpMouthRegion(
        from sourcePixels: UnsafeRawPointer,
        to destinationPixels: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        sourceBytesPerRow: Int,
        destinationBytesPerRow: Int,
        overlay: MouthOverlay,
        featherRadius: Float
    ) {
        let outerDetected = overlay.detectedOuterLips
        guard outerDetected.count >= 6 else { return }
        let innerDetected = overlay.detectedInnerLips

        let sourceW = overlay.sourceSize.x > 0 ? overlay.sourceSize.x : width
        let sourceH = overlay.sourceSize.y > 0 ? overlay.sourceSize.y : height
        let fw = Float(sourceW)
        let fh = Float(sourceH)

        let outerSourcePoints = outerDetected.map { point in
            SIMD2<Float>(point.x * fw, (1.0 - point.y) * fh)
        }
        let innerSourcePoints = innerDetected.map { point in
            SIMD2<Float>(point.x * fw, (1.0 - point.y) * fh)
        }

        let xs = outerSourcePoints.map { $0.x }
        let ys = outerSourcePoints.map { $0.y }
        guard let srcLeftX = xs.min(), let srcRightX = xs.max(),
              let srcUpperLipY = ys.min(), let srcLowerLipY = ys.max()
        else { return }

        let srcCenterX = (srcLeftX + srcRightX) * 0.5
        let srcCenterY = (srcUpperLipY + srcLowerLipY) * 0.5
        let srcMouthWidth = max(srcRightX - srcLeftX, 1.0)
        let srcMouthHeight = max(srcLowerLipY - srcUpperLipY, 1.0)

        let state = overlay.mouthState
        let jawOpen = min(max(Float(state.jawOpen), 0.0), 1.0)
        let mouthWidth = min(max(Float(state.mouthWidth), 0.0), 1.0)
        let mouthHeight = min(max(Float(state.mouthHeight), 0.0), 1.0)
        let pucker = min(max(Float(state.pucker), 0.0), 1.0)

        let widthScale = 1.0 + (mouthWidth - 0.5) * 0.35 - pucker * 0.2 + jawOpen * 0.08
        let openAmount = jawOpen * srcMouthHeight * 0.9 + mouthHeight * srcMouthHeight * 0.25
        let upperLift = openAmount * 0.2
        let lowerDrop = openAmount * 0.7
        let puckerPull = pucker * srcMouthWidth * 0.08

        let outerTargetPoints = outerSourcePoints.map { point -> SIMD2<Float> in
            let relX = (point.x - srcCenterX) / max(srcMouthWidth * 0.5, 1.0)
            let centerWeight = max(0.0, 1.0 - abs(relX))
            let isUpper = point.y < srcCenterY

            var x = srcCenterX + (point.x - srcCenterX) * widthScale
            x += (relX < 0 ? 1.0 : -1.0) * puckerPull * centerWeight

            var y = point.y
            if isUpper {
                y -= upperLift * centerWeight
                y = srcCenterY + (y - srcCenterY) * (1.0 + jawOpen * 0.15)
            } else {
                y += lowerDrop * centerWeight
                y = srcCenterY + (y - srcCenterY) * (1.0 + jawOpen * 0.45)
            }

            return SIMD2<Float>(x, y)
        }

        let innerTargetPoints = innerSourcePoints.map { point -> SIMD2<Float> in
            let relX = (point.x - srcCenterX) / max(srcMouthWidth * 0.5, 1.0)
            let centerWeight = max(0.0, 1.0 - abs(relX))
            let isUpper = point.y < srcCenterY

            var x = srcCenterX + (point.x - srcCenterX) * (widthScale - pucker * 0.08)
            x += (relX < 0 ? 1.0 : -1.0) * puckerPull * (centerWeight + 0.2)

            var y = point.y
            if isUpper {
                y -= upperLift * (centerWeight + 0.2)
                y = srcCenterY + (y - srcCenterY) * (1.0 + jawOpen * 0.2)
            } else {
                y += lowerDrop * (centerWeight + 0.3)
                y = srcCenterY + (y - srcCenterY) * (1.0 + jawOpen * 0.7)
            }

            return SIMD2<Float>(x, y)
        }

        let targetXs = outerTargetPoints.map { $0.x }
        let targetYs = outerTargetPoints.map { $0.y }
        guard let targetMinX = targetXs.min(), let targetMaxX = targetXs.max(),
              let targetMinY = targetYs.min(), let targetMaxY = targetYs.max()
        else { return }

        let anchorMargin = max(srcMouthWidth * 0.35, 10.0)
        let anchors: [SIMD2<Float>] = [
            SIMD2<Float>(srcLeftX - anchorMargin, srcUpperLipY - anchorMargin),
            SIMD2<Float>(srcRightX + anchorMargin, srcUpperLipY - anchorMargin),
            SIMD2<Float>(srcRightX + anchorMargin, srcLowerLipY + anchorMargin),
            SIMD2<Float>(srcLeftX - anchorMargin, srcLowerLipY + anchorMargin),
            SIMD2<Float>(srcCenterX, srcUpperLipY - anchorMargin),
            SIMD2<Float>(srcCenterX, srcLowerLipY + anchorMargin)
        ]

        let controlSource = outerSourcePoints + innerSourcePoints + anchors
        let controlTarget = outerTargetPoints + innerTargetPoints + anchors

        let rx0 = max(0, Int(floor(targetMinX - anchorMargin)))
        let ry0 = max(0, Int(floor(targetMinY - anchorMargin)))
        let rx1 = min(width - 1, Int(ceil(targetMaxX + anchorMargin)))
        let ry1 = min(height - 1, Int(ceil(targetMaxY + anchorMargin)))
        guard rx1 > rx0, ry1 > ry0 else { return }

        for gy in ry0...ry1 {
            for gx in rx0...rx1 {
                let point = SIMD2<Float>(Float(gx), Float(gy))
                let inside = pointInPolygon(point, polygon: outerTargetPoints)
                let edgeDistance = distanceToPolygon(point, polygon: outerTargetPoints)
                guard inside || edgeDistance <= featherRadius else { continue }

                let alpha: Float = inside ? 1.0 : max(0.0 as Float, min(1.0 as Float, 1.0 - edgeDistance / max(featherRadius, 0.001 as Float)))

                var totalWeight: Float = 0.0
                var displacement = SIMD2<Float>(repeating: 0)
                for index in controlTarget.indices {
                    let delta = point - controlTarget[index]
                    let dist2 = max(simd_length_squared(delta), 1.0)
                    let weight = 1.0 / dist2
                    totalWeight += weight
                    displacement += (controlSource[index] - controlTarget[index]) * weight
                }
                guard totalWeight > 0 else { continue }

                let sourcePoint = point + displacement / totalWeight
                let srcPx = max(0.0, min(Float(width - 1), sourcePoint.x))
                let srcPy = max(0.0, min(Float(height - 1), sourcePoint.y))

                let sx0 = max(0, min(width - 1, Int(floor(srcPx))))
                let sy0 = max(0, min(height - 1, Int(floor(srcPy))))
                let sx1 = max(0, min(width - 1, sx0 + 1))
                let sy1 = max(0, min(height - 1, sy0 + 1))

                let fx = srcPx - Float(sx0)
                let fy = srcPy - Float(sy0)

                let i00 = sy0 * sourceBytesPerRow + sx0 * 4
                let i10 = sy0 * sourceBytesPerRow + sx1 * 4
                let i01 = sy1 * sourceBytesPerRow + sx0 * 4
                let i11 = sy1 * sourceBytesPerRow + sx1 * 4

                let s00 = sourcePixels.advanced(by: i00).assumingMemoryBound(to: UInt8.self)
                let s10 = sourcePixels.advanced(by: i10).assumingMemoryBound(to: UInt8.self)
                let s01 = sourcePixels.advanced(by: i01).assumingMemoryBound(to: UInt8.self)
                let s11 = sourcePixels.advanced(by: i11).assumingMemoryBound(to: UInt8.self)

                let dstIdx = gy * destinationBytesPerRow + gx * 4
                let dst = destinationPixels.advanced(by: dstIdx).assumingMemoryBound(to: UInt8.self)

                let fx1: Float = 1.0 - fx
                let fy1: Float = 1.0 - fy
                for c in 0..<3 {
                    let v00 = Float(s00[c])
                    let v10 = Float(s10[c])
                    let v01 = Float(s01[c])
                    let v11 = Float(s11[c])
                    let sampled = v00 * fx1 * fy1 + v10 * fx * fy1 + v01 * fx1 * fy + v11 * fx * fy
                    let original = Float(dst[c])
                    let blended = original * (1.0 - alpha) + sampled * alpha
                    dst[c] = UInt8(max(0, min(255, blended)))
                }
                dst[3] = 255
            }
        }
    }

    private func pointInPolygon(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[previous]
            let crosses = ((a.y > point.y) != (b.y > point.y))
                && (point.x < (b.x - a.x) * (point.y - a.y) / max(b.y - a.y, 0.0001) + a.x)
            if crosses { inside.toggle() }
            previous = index
        }
        return inside
    }

    private func distanceToPolygon(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 2 else { return .greatestFiniteMagnitude }
        var minimum = Float.greatestFiniteMagnitude
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            minimum = min(minimum, distanceToSegment(point, a, b))
        }
        return minimum
    }

    private func distanceToSegment(_ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = max(simd_length_squared(ab), 0.0001)
        let t = max(0.0, min(1.0, simd_dot(point - a, ab) / lengthSquared))
        let projection = a + ab * t
        return simd_length(point - projection)
    }
}
