import AppKit
import Metal
import QuartzCore
import SwiftUI

// MARK: - CanvasRepresentable (SwiftUI Bridge)

@available(macOS 26.0, *)
struct CanvasRepresentable: NSViewRepresentable {
    var store: AnimateStore

    func makeNSView(context: Context) -> AnimationCanvasView {
        let view = AnimationCanvasView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: AnimationCanvasView, context: Context) {
        nsView.store = store
        nsView.markDirty(.all)
    }
}

// MARK: - AnimationCanvasView

/// Metal-backed NSView that composites background plates and character sprites.
/// Uses render-on-demand (lesson 12.8): only draws when setNeedsDisplay() is called.
@available(macOS 26.0, *)
@MainActor
final class AnimationCanvasView: NSView {

    // MARK: - State

    weak var store: AnimateStore?
    private var renderer: AnimationRenderer?
    private var spriteAtlas: SpriteAtlas?
    private let frameComposer = SceneFrameRenderComposer()
    private var dirtyFlags: CanvasDirtyFlags = .all
    private var metalRedrawScheduled = false
    private var cameraDrivenByTrack = false

    private struct CharacterRenderState {
        var position: SIMD2<Float>
        var rotationRadians: Float
        var scale: SIMD2<Float>
        var opacity: Float
        var baseZOrder: Float

        var absoluteScale: SIMD2<Float> {
            SIMD2<Float>(abs(scale.x), abs(scale.y))
        }
    }

    // MARK: - Metal Layer

    private var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        renderer = AnimationRenderer()
        if let device = renderer?.device {
            spriteAtlas = SpriteAtlas(device: device)
        }
    }

    // MARK: - Layer Configuration

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        layer.drawableSize = CGSize(
            width: max(1, frame.width) * scale,
            height: max(1, frame.height) * scale
        )
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        renderMetal()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMetalLayerSize()
        markDirty(.all)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMetalLayerSize()
        markDirty(.all)
    }

    private func updateMetalLayerSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width) * scale,
            height: max(1, bounds.height) * scale
        )
    }

    // MARK: - Dirty Flags

    func markDirty(_ flags: CanvasDirtyFlags) {
        dirtyFlags.insert(flags)
        scheduleRedraw()
    }

    /// Coalesce render calls (lesson 12.1) — at most one per run loop cycle.
    private func scheduleRedraw() {
        guard !metalRedrawScheduled else { return }
        metalRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.metalRedrawScheduled else { return }
            self.metalRedrawScheduled = false
            self.needsDisplay = true
        }
    }

    // MARK: - Render

    private func renderMetal() {
        guard let renderer, let metalLayer else { return }
        guard let drawable = metalLayer.nextDrawable() else { return }

        let viewportSize = bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        var drawItems: [AnimationRenderer.DrawItem] = []

        if let store, let scene = store.selectedScene {
            frameComposer.applyCamera(
                renderer: renderer,
                store: store,
                scene: scene,
                frame: store.currentFrame,
                viewportSize: viewportSize
            )
            renderer.setBackgroundTexture(
                frameComposer.backgroundTexture(
                    store: store,
                    scene: scene,
                    textureProvider: { url in
                        spriteAtlas?.loadTexture(from: url)
                    }
                )
            )
            drawItems = frameComposer.composeDrawItems(
                store: store,
                scene: scene,
                viewportSize: viewportSize,
                frame: store.currentFrame,
                textureProvider: { url in
                    spriteAtlas?.loadTexture(from: url)
                }
            )
        } else {
            renderer.cameraOffset = .zero
            renderer.cameraZoom = 1.0
            renderer.setBackgroundTexture(nil)
            drawItems = []
        }

        renderer.render(
            to: drawable,
            viewportSize: viewportSize,
            drawItems: drawItems
        )

        dirtyFlags = []
    }

    // MARK: - Mouse Events (pan/zoom)

    private var lastDragPoint: NSPoint?

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }

        if event.modifierFlags.contains(.option) {
            // Zoom
            let delta = Float(event.scrollingDeltaY) * 0.01
            renderer.cameraZoom = max(0.1, min(renderer.cameraZoom + delta, 10.0))
        } else {
            // Pan
            renderer.cameraOffset.x -= Float(event.scrollingDeltaX)
            renderer.cameraOffset.y -= Float(event.scrollingDeltaY)
        }

        markDirty(.all)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer, let lastPoint = lastDragPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = Float(current.x - lastPoint.x)
        let dy = Float(current.y - lastPoint.y)

        renderer.cameraOffset.x -= dx / renderer.cameraZoom
        renderer.cameraOffset.y += dy / renderer.cameraZoom

        lastDragPoint = current
        markDirty(.all)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    override var acceptsFirstResponder: Bool { true }

    private func fallbackSpriteSize(viewportSize: CGSize) -> SIMD2<Float> {
        let targetHeight = Float(min(max(viewportSize.height * 0.42, 220), 420))
        return SIMD2<Float>(targetHeight * 0.65, targetHeight)
    }

    private func applyCameraTrackIfNeeded(
        from store: AnimateStore,
        viewportSize: CGSize
    ) {
        guard let renderer else { return }

        if let cameraTransform = store.evaluatedCameraTransform() {
            renderer.cameraOffset = SIMD2<Float>(
                Float(cameraTransform.x) * Float(viewportSize.width),
                Float(cameraTransform.y) * Float(viewportSize.height)
            )
            renderer.cameraZoom = max(
                0.1,
                Float((abs(cameraTransform.scaleX) + abs(cameraTransform.scaleY)) / 2.0)
            )
            cameraDrivenByTrack = true
        } else if cameraDrivenByTrack {
            renderer.cameraOffset = .zero
            renderer.cameraZoom = 1.0
            cameraDrivenByTrack = false
        }
    }

    private func resolvedRenderState(
        for character: AnimationCharacter,
        index: Int,
        characterCount: Int,
        viewportSize: CGSize,
        store: AnimateStore
    ) -> CharacterRenderState? {
        let transformTrackName = "\(character.name):transform"
        let fallbackTransform = fallbackCharacterTransform(
            index: index,
            characterCount: characterCount,
            viewportSize: viewportSize
        )

        let transform: CharacterTransform
        if store.timelineTrack(named: transformTrackName) != nil {
            guard let evaluated = store.evaluatedTransform(for: character.name) else {
                return nil
            }
            transform = evaluated
        } else {
            transform = fallbackTransform
        }

        if let visibility = store.evaluatedVisibility(for: character.name),
           !visibility.visible {
            return nil
        }

        let visibilityOpacity = Float(store.evaluatedVisibility(for: character.name)?.opacity ?? 1.0)
        let resolvedOpacity = max(0, Float(transform.opacity) * visibilityOpacity)
        guard resolvedOpacity > 0.001 else { return nil }

        let resolvedZOrder = transform.zOrder == 0 ? index + 1 : transform.zOrder

        return CharacterRenderState(
            position: SIMD2<Float>(
                Float(transform.x) * Float(viewportSize.width),
                Float(transform.y) * Float(viewportSize.height)
            ),
            rotationRadians: Float(transform.rotation * .pi / 180),
            scale: SIMD2<Float>(Float(transform.scaleX), Float(transform.scaleY)),
            opacity: resolvedOpacity,
            baseZOrder: Float(resolvedZOrder) * 100
        )
    }

    private func renderSelection(
        for character: AnimationCharacter,
        store: AnimateStore
    ) -> CharacterRenderSelectionContext {
        CharacterRenderSelectionContext(
            preferredAngle: store.evaluatedViewAngle(for: character.name) ?? character.preferredViewAngle,
            preferredPose: store.evaluatedPose(for: character.name),
            expressionCue: store.evaluatedExpression(for: character.name),
            actionCue: store.evaluatedAction(for: character.name),
            mouthCue: store.evaluatedMouthCue(for: character.name)
        )
    }

    private func fallbackCharacterTransform(
        index: Int,
        characterCount: Int,
        viewportSize: CGSize
    ) -> CharacterTransform {
        let xSpacing = Float(viewportSize.width) / Float(characterCount + 1)
        return CharacterTransform(
            x: Double(xSpacing * Float(index + 1) / Float(viewportSize.width)),
            y: 0.56,
            rotation: 0,
            scaleX: 1,
            scaleY: 1,
            opacity: 1,
            zOrder: index + 1
        )
    }

    private func packageCanvasSize(
        for renderPlan: CharacterPackageResolvedRenderPlan,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        resolvedCanvasSize(
            packageCanvasSizeHint: renderPlan.package.manifest.defaults.defaultCanvasSize,
            viewportSize: viewportSize
        )
    }

    private func rigCanvasSize(
        for renderPlan: CharacterRigResolvedRenderPlan,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        resolvedCanvasSize(
            packageCanvasSizeHint: renderPlan.packageCanvasSizeHint,
            viewportSize: viewportSize
        )
    }

    private func resolvedCanvasSize(
        packageCanvasSizeHint: CharacterPackageCanvasSize?,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        let targetHeight = Float(min(max(viewportSize.height * 0.42, 220), 420))

        if let packageCanvasSizeHint,
           packageCanvasSizeHint.width > 0,
           packageCanvasSizeHint.height > 0 {
            let aspectRatio = Float(packageCanvasSizeHint.width) / Float(packageCanvasSizeHint.height)
            return SIMD2<Float>(max(120, targetHeight * aspectRatio), targetHeight)
        }

        let fallbackWidth = max(Float(viewportSize.width) * 0.18, targetHeight * 0.78)
        return SIMD2<Float>(fallbackWidth, targetHeight)
    }

    private func makeDrawItems(
        for renderPlan: CharacterPackageResolvedRenderPlan,
        renderState: CharacterRenderState,
        viewportSize: CGSize,
    ) -> [AnimationRenderer.DrawItem] {
        let fullCanvasSize = packageCanvasSize(for: renderPlan, viewportSize: viewportSize)

        switch renderPlan.mode {
        case .wholeCharacter:
            guard let layer = renderPlan.layers.first else { return [] }
            guard let drawItem = makeDrawItem(
                for: layer,
                renderState: renderState,
                fullCanvasSize: fullCanvasSize,
                baseZOrder: renderState.baseZOrder
            ) else {
                return []
            }
            return [drawItem]
        case .layeredParts:
            return renderPlan.layers.compactMap { layer in
                makeDrawItem(
                    for: layer,
                    renderState: renderState,
                    fullCanvasSize: fullCanvasSize,
                    baseZOrder: renderState.baseZOrder + layer.zOrder
                )
            }
        }
    }

    private func makeDrawItems(
        for renderPlan: CharacterRigResolvedRenderPlan,
        renderState: CharacterRenderState,
        viewportSize: CGSize,
    ) -> [AnimationRenderer.DrawItem] {
        let fullCanvasSize = rigCanvasSize(for: renderPlan, viewportSize: viewportSize)

        return renderPlan.layers.compactMap { layer in
            makeDrawItem(
                for: layer,
                renderState: renderState,
                fullCanvasSize: fullCanvasSize,
                baseZOrder: renderState.baseZOrder + layer.zOrder
            )
        }
    }

    private func makeDrawItem(
        for layer: CharacterPackageResolvedLayer,
        renderState: CharacterRenderState,
        fullCanvasSize: SIMD2<Float>,
        baseZOrder: Float
    ) -> AnimationRenderer.DrawItem? {
        let texture = spriteAtlas?.loadTexture(from: layer.assetURL)
        let baseSize = layer.usesFullCanvasPlacement
            ? fullCanvasSize
            : layeredSpriteSize(
                for: layer,
                texture: texture,
                baseWidth: fullCanvasSize.x,
                targetHeight: fullCanvasSize.y
            )
        let size = scaledSize(baseSize, scale: renderState.scale)
        guard abs(size.x) > 0, abs(size.y) > 0 else { return nil }

        let position = layer.usesFullCanvasPlacement
            ? renderState.position
            : transformedLayerPosition(
                basePosition: renderState.position,
                normalizedCenter: layer.normalizedCenter,
                fullCanvasSize: fullCanvasSize,
                scale: renderState.scale,
                rotationRadians: renderState.rotationRadians
            )

        return AnimationRenderer.DrawItem(
            sprite: SpriteInstance(
                position: position,
                size: size,
                rotation: renderState.rotationRadians,
                opacity: renderState.opacity,
                uvOrigin: .zero,
                uvSize: SIMD2<Float>(1, 1),
                zOrder: baseZOrder
            ),
            texture: texture
        )
    }

    private func makeDrawItem(
        for layer: CharacterRigResolvedLayer,
        renderState: CharacterRenderState,
        fullCanvasSize: SIMD2<Float>,
        baseZOrder: Float
    ) -> AnimationRenderer.DrawItem? {
        let texture = spriteAtlas?.loadTexture(from: layer.assetURL)
        let baseSize = layer.usesFullCanvasPlacement
            ? fullCanvasSize
            : layeredSpriteSize(
                normalizedSizeHint: layer.normalizedSizeHint,
                texture: texture,
                baseWidth: fullCanvasSize.x,
                targetHeight: fullCanvasSize.y
            )
        let size = scaledSize(baseSize, scale: renderState.scale)
        guard abs(size.x) > 0, abs(size.y) > 0 else { return nil }

        let position = layer.usesFullCanvasPlacement
            ? renderState.position
            : transformedLayerPosition(
                basePosition: renderState.position,
                normalizedCenter: layer.normalizedCenter,
                fullCanvasSize: fullCanvasSize,
                scale: renderState.scale,
                rotationRadians: renderState.rotationRadians
            )

        return AnimationRenderer.DrawItem(
            sprite: SpriteInstance(
                position: position,
                size: size,
                rotation: renderState.rotationRadians,
                opacity: renderState.opacity,
                uvOrigin: .zero,
                uvSize: SIMD2<Float>(1, 1),
                zOrder: baseZOrder
            ),
            texture: texture
        )
    }

    private func scaledSize(
        _ size: SIMD2<Float>,
        scale: SIMD2<Float>
    ) -> SIMD2<Float> {
        SIMD2<Float>(size.x * scale.x, size.y * scale.y)
    }

    private func transformedLayerPosition(
        basePosition: SIMD2<Float>,
        normalizedCenter: SIMD2<Float>,
        fullCanvasSize: SIMD2<Float>,
        scale: SIMD2<Float>,
        rotationRadians: Float
    ) -> SIMD2<Float> {
        let rawOffset = SIMD2<Float>(
            (normalizedCenter.x - 0.5) * fullCanvasSize.x,
            (0.5 - normalizedCenter.y) * fullCanvasSize.y
        )
        let scaledOffset = SIMD2<Float>(
            rawOffset.x * scale.x,
            rawOffset.y * scale.y
        )
        return basePosition + rotated(scaledOffset, by: rotationRadians)
    }

    private func rotated(
        _ vector: SIMD2<Float>,
        by radians: Float
    ) -> SIMD2<Float> {
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        return SIMD2<Float>(
            vector.x * cosValue - vector.y * sinValue,
            vector.x * sinValue + vector.y * cosValue
        )
    }

    private func layeredSpriteSize(
        for layer: CharacterPackageResolvedLayer,
        texture: MTLTexture?,
        baseWidth: Float,
        targetHeight: Float
    ) -> SIMD2<Float> {
        layeredSpriteSize(
            normalizedSizeHint: layer.normalizedSizeHint,
            texture: texture,
            baseWidth: baseWidth,
            targetHeight: targetHeight
        )
    }

    private func layeredSpriteSize(
        normalizedSizeHint: SIMD2<Float>,
        texture: MTLTexture?,
        baseWidth: Float,
        targetHeight: Float
    ) -> SIMD2<Float> {
        let height = max(24, normalizedSizeHint.y * targetHeight)

        if let texture, texture.height > 0 {
            let aspectRatio = Float(texture.width) / Float(texture.height)
            let aspectWidth = height * aspectRatio
            let maxPreferredWidth = max(24, normalizedSizeHint.x * baseWidth * 1.35)
            return SIMD2<Float>(min(aspectWidth, maxPreferredWidth), height)
        }

        return SIMD2<Float>(
            max(24, normalizedSizeHint.x * baseWidth),
            height
        )
    }
}
