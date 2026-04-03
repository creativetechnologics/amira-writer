import AppKit
import Metal
import QuartzCore
import MetalKit
import simd

// MARK: - CanvasDirtyFlags

@available(macOS 26.0, *)
struct CanvasDirtyFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let background  = CanvasDirtyFlags(rawValue: 1 << 0)
    static let characters  = CanvasDirtyFlags(rawValue: 1 << 1)
    static let playhead    = CanvasDirtyFlags(rawValue: 1 << 2)
    static let overlays    = CanvasDirtyFlags(rawValue: 1 << 3)
    static let all: CanvasDirtyFlags = [.background, .characters, .playhead, .overlays]
}

// MARK: - AnimationRenderer

/// Metal-based 2D sprite compositor for the animation canvas.
/// Renders background plates and character sprites as textured quads.
@available(macOS 26.0, *)
@MainActor
final class AnimationRenderer {
    struct DrawItem {
        var sprite: SpriteInstance
        var texture: MTLTexture?

        init(sprite: SpriteInstance, texture: MTLTexture? = nil) {
            self.sprite = sprite
            self.texture = texture
        }
    }

    // MARK: - Shared Instance

    static let shared: AnimationRenderer? = AnimationRenderer()

    // MARK: - Metal State

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let spritePipeline: MTLRenderPipelineState
    private let flatPipeline: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let textureLoader: MTKTextureLoader

    // MARK: - Buffers

    private var spriteBuffer: MTLBuffer?
    private var spriteInstanceCount: Int = 0
    private static let maxSpriteInstances = 10_000

    // MARK: - Textures

    private var backgroundTexture: MTLTexture?
    private var characterTextures: [UUID: MTLTexture] = [:]

    // MARK: - Camera

    var cameraOffset: SIMD2<Float> = .zero
    var cameraZoom: Float = 1.0
    var canvasSize: SIMD2<Float> = SIMD2<Float>(1920, 1080)

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[AnimationRenderer] No Metal device available.")
            return nil
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            print("[AnimationRenderer] Failed to create command queue.")
            return nil
        }
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)

        // Compile sprite shaders
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: canvasShaderSource, options: nil)
        } catch {
            print("[AnimationRenderer] Shader compilation failed: \(error)")
            return nil
        }

        guard let vertexFn = library.makeFunction(name: "sprite_vertex"),
              let fragmentFn = library.makeFunction(name: "sprite_fragment"),
              let flatFragFn = library.makeFunction(name: "sprite_flat_fragment") else {
            print("[AnimationRenderer] Failed to find shader functions.")
            return nil
        }

        // Textured sprite pipeline — sourceAlpha / oneMinusSourceAlpha (premultiplied in shader)
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
            self.spritePipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[AnimationRenderer] Pipeline creation failed: \(error)")
            return nil
        }

        // Flat (untextured) pipeline for placeholders
        desc.fragmentFunction = flatFragFn
        do {
            self.flatPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[AnimationRenderer] Flat pipeline creation failed: \(error)")
            return nil
        }

        // Sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            print("[AnimationRenderer] Sampler creation failed.")
            return nil
        }
        self.samplerState = sampler

        // Pre-allocate sprite buffer
        let stride = MemoryLayout<SpriteInstance>.stride
        spriteBuffer = device.makeBuffer(
            length: stride * Self.maxSpriteInstances,
            options: .storageModeShared
        )
    }

    // MARK: - Texture Loading

    func loadTexture(from url: URL) -> MTLTexture? {
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]
        return try? textureLoader.newTexture(URL: url, options: options)
    }

    func loadTexture(from image: NSImage) -> MTLTexture? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]
        return try? textureLoader.newTexture(cgImage: cgImage, options: options)
    }

    func setBackgroundTexture(_ texture: MTLTexture?) {
        backgroundTexture = texture
    }

    func setCharacterTexture(_ texture: MTLTexture, for characterID: UUID) {
        characterTextures[characterID] = texture
    }

    // MARK: - Render

    /// Render the current frame to the given Metal drawable.
    func render(
        to drawable: CAMetalDrawable,
        viewportSize: CGSize,
        sprites: [SpriteInstance]
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        canvasSize = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            commandBuffer.commit()
            return
        }

        // Build uniforms
        let projection = orthographicProjection(
            width: Float(viewportSize.width) / cameraZoom,
            height: Float(viewportSize.height) / cameraZoom
        )
        let view = translationMatrix(x: -cameraOffset.x, y: -cameraOffset.y)
        var uniforms = CanvasUniforms(projectionMatrix: projection, viewMatrix: view)

        // Render background if available
        if let bgTex = backgroundTexture {
            renderBackground(encoder: encoder, texture: bgTex, viewportSize: viewportSize, uniforms: &uniforms)
        }

        // Render sprite instances
        if !sprites.isEmpty {
            renderSprites(encoder: encoder, sprites: sprites, uniforms: &uniforms)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func render(
        to drawable: CAMetalDrawable,
        viewportSize: CGSize,
        drawItems: [DrawItem]
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        canvasSize = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            commandBuffer.commit()
            return
        }

        let projection = orthographicProjection(
            width: Float(viewportSize.width) / cameraZoom,
            height: Float(viewportSize.height) / cameraZoom
        )
        let view = translationMatrix(x: -cameraOffset.x, y: -cameraOffset.y)
        var uniforms = CanvasUniforms(projectionMatrix: projection, viewMatrix: view)

        if let bgTex = backgroundTexture {
            renderBackground(encoder: encoder, texture: bgTex, viewportSize: viewportSize, uniforms: &uniforms)
        }

        if !drawItems.isEmpty {
            renderDrawItems(encoder: encoder, drawItems: drawItems, uniforms: &uniforms)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Render to an offscreen texture (used by VideoExporter).
    func render(
        to texture: MTLTexture,
        viewportSize: SIMD2<Float>,
        sprites: [SpriteInstance]
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            commandBuffer.commit()
            return
        }

        canvasSize = viewportSize
        let projection = orthographicProjection(
            width: viewportSize.x / cameraZoom,
            height: viewportSize.y / cameraZoom
        )
        let view = translationMatrix(x: -cameraOffset.x, y: -cameraOffset.y)
        var uniforms = CanvasUniforms(projectionMatrix: projection, viewMatrix: view)

        if let bgTex = backgroundTexture {
            renderBackground(
                encoder: encoder, texture: bgTex,
                viewportSize: CGSize(width: CGFloat(viewportSize.x), height: CGFloat(viewportSize.y)),
                uniforms: &uniforms
            )
        }

        if !sprites.isEmpty {
            renderSprites(encoder: encoder, sprites: sprites, uniforms: &uniforms)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func render(
        to texture: MTLTexture,
        viewportSize: SIMD2<Float>,
        drawItems: [DrawItem]
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            commandBuffer.commit()
            return
        }

        canvasSize = viewportSize
        let projection = orthographicProjection(
            width: viewportSize.x / cameraZoom,
            height: viewportSize.y / cameraZoom
        )
        let view = translationMatrix(x: -cameraOffset.x, y: -cameraOffset.y)
        var uniforms = CanvasUniforms(projectionMatrix: projection, viewMatrix: view)

        if let bgTex = backgroundTexture {
            renderBackground(
                encoder: encoder,
                texture: bgTex,
                viewportSize: CGSize(width: CGFloat(viewportSize.x), height: CGFloat(viewportSize.y)),
                uniforms: &uniforms
            )
        }

        if !drawItems.isEmpty {
            renderDrawItems(encoder: encoder, drawItems: drawItems, uniforms: &uniforms)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Private Render Helpers

    private func renderBackground(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        viewportSize: CGSize,
        uniforms: inout CanvasUniforms
    ) {
        // Render background as a full-canvas textured quad
        let bgWidth = Float(canvasSize.x)
        let bgHeight = Float(canvasSize.y)
        let bgSprite = SpriteInstance(
            position: SIMD2<Float>(bgWidth / 2, bgHeight / 2),
            size: SIMD2<Float>(bgWidth, bgHeight),
            rotation: 0,
            opacity: 1.0,
            uvOrigin: SIMD2<Float>(0, 0),
            uvSize: SIMD2<Float>(1, 1),
            zOrder: 0
        )

        guard let buffer = spriteBuffer else { return }
        buffer.contents().assumingMemoryBound(to: SpriteInstance.self).pointee = bgSprite

        encoder.setRenderPipelineState(spritePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
    }

    private func renderSprites(
        encoder: MTLRenderCommandEncoder,
        sprites: [SpriteInstance],
        uniforms: inout CanvasUniforms
    ) {
        guard let buffer = spriteBuffer else { return }
        let count = min(sprites.count, Self.maxSpriteInstances)
        let ptr = buffer.contents().assumingMemoryBound(to: SpriteInstance.self)
        for i in 0 ..< count {
            ptr[i] = sprites[i]
        }

        // For now render all sprites with flat (untextured) pipeline
        // Phase 3 will add per-character texture binding
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
    }

    private func renderDrawItems(
        encoder: MTLRenderCommandEncoder,
        drawItems: [DrawItem],
        uniforms: inout CanvasUniforms
    ) {
        guard let buffer = spriteBuffer else { return }

        let sortedItems = drawItems.sorted { $0.sprite.zOrder < $1.sprite.zOrder }
        let ptr = buffer.contents().assumingMemoryBound(to: SpriteInstance.self)

        for item in sortedItems {
            ptr.pointee = item.sprite

            if let texture = item.texture {
                encoder.setRenderPipelineState(spritePipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
            } else {
                encoder.setRenderPipelineState(flatPipeline)
            }

            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }
    }
}
