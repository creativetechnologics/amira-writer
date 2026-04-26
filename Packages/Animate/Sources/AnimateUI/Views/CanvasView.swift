import AppKit
import ImageIO
import Metal
import QuartzCore
import SwiftUI

// MARK: - CanvasRepresentable (SwiftUI Bridge)

@available(macOS 26.0, *)
enum AnimationCanvasPreviewMode: String, Sendable {
    case live
    case placeholder
}

@available(macOS 26.0, *)
struct CanvasRepresentable: NSViewRepresentable {
    var store: AnimateStore
    var previewMode: AnimationCanvasPreviewMode = .live

    func makeNSView(context: Context) -> AnimationCanvasView {
        let view = AnimationCanvasView()
        view.store = store
        view.previewMode = previewMode
        view.markDirty(.all)
        view.needsLayout = true
        return view
    }

    func updateNSView(_ nsView: AnimationCanvasView, context: Context) {
        nsView.store = store
        nsView.previewMode = previewMode
        nsView.markDirty(.all)
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
    }
}

// MARK: - AnimationCanvasView

/// Metal-backed NSView that composites background plates and character sprites.
/// Uses render-on-demand (lesson 12.8): only draws when setNeedsDisplay() is called.
@available(macOS 26.0, *)
@MainActor
final class AnimationCanvasView: NSView {
    private static let softwareBackgroundImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 200 * 1024 * 1024 // 200 MB
        return cache
    }()

    // MARK: - State

    weak var store: AnimateStore? {
        didSet {
            guard store !== oldValue else { return }
            pendingRenderAfterLayout = true
            markDirty(.all)
        }
    }
    var previewMode: AnimationCanvasPreviewMode = .live {
        didSet {
            guard previewMode != oldValue else { return }
            pendingRenderAfterLayout = true
            markDirty(.all)
        }
    }
    private var renderer: AnimationRenderer?
    private var spriteAtlas: SpriteAtlas?
    private let frameComposer = SceneFrameRenderComposer()
    private var dirtyFlags: CanvasDirtyFlags = .all
    private var metalRedrawScheduled = false
    private var cameraDrivenByTrack = false
    private let prefersSoftwareRendering = true
    private let softwareImageView = NSImageView()
    private var pendingRenderAfterLayout = true

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

    private var hasRenderableBounds: Bool {
        bounds.width > 1 && bounds.height > 1
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
        if prefersSoftwareRendering {
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            softwareImageView.imageScaling = .scaleAxesIndependently
            softwareImageView.imageAlignment = .alignCenter
            softwareImageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(softwareImageView)
            NSLayoutConstraint.activate([
                softwareImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                softwareImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                softwareImageView.topAnchor.constraint(equalTo: topAnchor),
                softwareImageView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay

            renderer = AnimationRenderer()
            if let device = renderer?.device {
                spriteAtlas = SpriteAtlas(device: device)
            }
        }
    }

    // MARK: - Layer Configuration

    override func makeBackingLayer() -> CALayer {
        if prefersSoftwareRendering {
            let layer = CALayer()
            layer.isOpaque = true
            layer.contentsGravity = .resize
            layer.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1).cgColor
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer.contentsScale = scale
            return layer
        }

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

    override var wantsUpdateLayer: Bool { !prefersSoftwareRendering }

    override func updateLayer() {
        renderMetal()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateBackingLayerScale()
        pendingRenderAfterLayout = true
        markDirty(.all)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateBackingLayerScale()
        pendingRenderAfterLayout = true
        markDirty(.all)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingLayerScale()
        pendingRenderAfterLayout = true
        markDirty(.all)
        schedulePostLayoutRenderPasses()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        pendingRenderAfterLayout = true
        markDirty(.all)
        schedulePostLayoutRenderPasses()
    }

    override func layout() {
        super.layout()
        updateBackingLayerScale()
        guard prefersSoftwareRendering, hasRenderableBounds else { return }
        if pendingRenderAfterLayout || !dirtyFlags.isEmpty || softwareImageView.image == nil {
            pendingRenderAfterLayout = false
            renderSoftwareImage()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingLayerScale()
        pendingRenderAfterLayout = true
        markDirty(.all)
    }

    private func updateBackingLayerScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(
            width: max(1, bounds.width) * scale,
            height: max(1, bounds.height) * scale
        )
    }

    private func schedulePostLayoutRenderPasses() {
        guard prefersSoftwareRendering else { return }
        let delays: [TimeInterval] = [0, 0.05, 0.2]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.renderImmediatelyForSnapshot()
            }
        }
    }

    // MARK: - Dirty Flags

    func markDirty(_ flags: CanvasDirtyFlags) {
        dirtyFlags.insert(flags)
        scheduleRedraw()
    }

    func renderImmediatelyForSnapshot() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard hasRenderableBounds else {
            pendingRenderAfterLayout = true
            return
        }
        pendingRenderAfterLayout = false
        if prefersSoftwareRendering {
            renderSoftwareImage()
        } else {
            needsDisplay = true
            displayIfNeeded()
        }
    }

    /// Coalesce render calls (lesson 12.1) — at most one per run loop cycle.
    private func scheduleRedraw() {
        guard !metalRedrawScheduled else { return }
        metalRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.metalRedrawScheduled else { return }
            self.metalRedrawScheduled = false
            if self.prefersSoftwareRendering {
                self.renderSoftwareImage()
            } else {
                self.needsDisplay = true
            }
        }
    }

    // MARK: - Render

    private func renderSoftwareImage() {
        guard hasRenderableBounds else {
            pendingRenderAfterLayout = true
            return
        }
        let viewportSize = bounds.size
        guard let cgImage = makeSoftwarePreviewImage(viewportSize: viewportSize) else { return }
        softwareImageView.image = NSImage(cgImage: cgImage, size: viewportSize)
        dirtyFlags = []
    }

    private func makeSoftwarePreviewImage(viewportSize: CGSize) -> CGImage? {
        let width = max(1, Int(viewportSize.width.rounded(.up)))
        let height = max(1, Int(viewportSize.height.rounded(.up)))
        guard width > 1, height > 1 else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        guard let store, let scene = store.selectedScene else {
            context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

        let viewport = CGSize(width: width, height: height)
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let cameraState = previewMode == .placeholder
            ? frameComposer.resolvedPlaceholderCameraState(
                store: store,
                scene: scene,
                frame: store.currentFrame,
                viewportSize: viewport
            )
            : frameComposer.resolvedCameraState(
                store: store,
                scene: scene,
                frame: store.currentFrame,
                viewportSize: viewport
            )

        if previewMode == .placeholder {
            drawSoftwarePlaceholderBackdrop(in: context, viewportSize: viewport)
        } else if let backgroundURL = scene.backgroundID
            .flatMap({ id in store.backgrounds.first(where: { $0.id == id })?.sourceURL }),
            let backgroundImage = cachedSoftwareBackgroundImage(
                for: backgroundURL,
                targetPixelSize: min(max(Int(max(viewport.width, viewport.height) * 2), 512), 4096)
            ),
            let cgImage = backgroundImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.saveGState()
            context.setAlpha(1)
            context.translateBy(x: -CGFloat(cameraState.offset.x) * CGFloat(cameraState.zoom),
                                y: -CGFloat(cameraState.offset.y) * CGFloat(cameraState.zoom))
            context.scaleBy(x: CGFloat(cameraState.zoom), y: CGFloat(cameraState.zoom))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height))
            context.restoreGState()
        }

        drawSoftwareObjects(
            in: context,
            store: store,
            scene: scene,
            viewportSize: viewport,
            cameraOffset: cameraState.offset,
            cameraZoom: cameraState.zoom
        )

        drawSoftwareCharacters(
            in: context,
            store: store,
            scene: scene,
            viewportSize: viewport,
            cameraOffset: cameraState.offset,
            cameraZoom: cameraState.zoom
        )

        return context.makeImage()
    }

    private func cachedSoftwareBackgroundImage(for url: URL, targetPixelSize: Int) -> NSImage? {
        let key = "\(url.path)#\(targetPixelSize)" as NSString
        if let cached = Self.softwareBackgroundImageCache.object(forKey: key) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            if let fallback = NSImage(contentsOf: url) {
                let cost = Int(fallback.size.width) * Int(fallback.size.height) * 4
                Self.softwareBackgroundImageCache.setObject(fallback, forKey: key, cost: cost)
                return fallback
            }
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        let image: NSImage?
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            image = NSImage(contentsOf: url)
        }

        if let image {
            let cost = Int(image.size.width) * Int(image.size.height) * 4
            Self.softwareBackgroundImageCache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

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
                viewportSize: viewportSize,
                placeholderOnly: previewMode == .placeholder
            )
            renderer.setBackgroundTexture(
                previewMode == .placeholder
                    ? nil
                    : frameComposer.backgroundTexture(
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
                placeholderOnly: previewMode == .placeholder,
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

    private func drawSoftwarePlaceholderBackdrop(in context: CGContext, viewportSize: CGSize) {
        let width = viewportSize.width
        let height = viewportSize.height
        context.setFillColor(CGColor(red: 0.14, green: 0.17, blue: 0.24, alpha: 0.7))
        context.fill(CGRect(
            x: width * 0.05,
            y: height * 0.36,
            width: width * 0.9,
            height: height * 0.44
        ))
        context.setFillColor(CGColor(red: 0.24, green: 0.27, blue: 0.34, alpha: 0.94))
        context.fill(CGRect(
            x: width * 0.09,
            y: height * 0.75,
            width: width * 0.82,
            height: height * 0.18
        ))
    }

    private func drawSoftwareObjects(
        in context: CGContext,
        store: AnimateStore,
        scene: AnimationScene,
        viewportSize: CGSize,
        cameraOffset: SIMD2<Float>,
        cameraZoom: Float
    ) {
        let frame = store.currentFrame
        let sortedObjects = scene.objectSetups.sorted { lhs, rhs in
            if lhs.zOrder == rhs.zOrder {
                return lhs.objectName.localizedCaseInsensitiveCompare(rhs.objectName) == .orderedAscending
            }
            return lhs.zOrder < rhs.zOrder
        }

        for object in sortedObjects {
            guard frame >= object.enterFrame else { continue }
            if let exitFrame = object.exitFrame, frame > exitFrame { continue }

            let transform = store.evaluatedObjectTransform(for: object.objectName, at: frame)
                ?? CharacterTransform(
                    x: object.initialX,
                    y: object.initialY,
                    rotation: 0,
                    scaleX: 1,
                    scaleY: 1,
                    opacity: 1,
                    zOrder: object.zOrder
                )
            let visibility = store.evaluatedObjectVisibility(for: object.objectName, at: frame)
                ?? (opacity: object.opacity, visible: object.visible)
            guard visibility.visible else { continue }

            let resolvedOpacity = min(
                max(CGFloat(transform.opacity * object.opacity * visibility.opacity), 0),
                1
            )
            guard resolvedOpacity > 0.001 else { continue }

            let imagePath = object.resolvedApprovedImagePath ?? object.imagePaths.first
            let image = imagePath
                .flatMap(store.resolvedCharacterAssetURL(for:))
                .flatMap(NSImage.init(contentsOf:))
            let isCharacterCutout = object.objectName.localizedCaseInsensitiveContains("cutout")

            let baseSize = softwareObjectBaseSize(
                objectName: object.objectName,
                image: image,
                viewportSize: viewportSize
            )
            let size = CGSize(
                width: CGFloat(abs(Float(baseSize.width) * Float(transform.scaleX) * cameraZoom)),
                height: CGFloat(abs(Float(baseSize.height) * Float(transform.scaleY) * cameraZoom))
            )
            guard size.width > 0.5, size.height > 0.5 else { continue }

            let position = CGPoint(
                x: (CGFloat(transform.x) * viewportSize.width - CGFloat(cameraOffset.x)) * CGFloat(cameraZoom),
                y: (CGFloat(transform.y) * viewportSize.height - CGFloat(cameraOffset.y)) * CGFloat(cameraZoom)
            )

            context.saveGState()
            context.setAlpha(resolvedOpacity)
            context.translateBy(x: position.x, y: position.y)
            context.rotate(by: CGFloat(transform.rotation * .pi / 180))
            let rect = CGRect(
                x: -size.width * 0.5,
                y: isCharacterCutout ? -size.height : -size.height * 0.5,
                width: size.width,
                height: size.height
            )

            if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cgImage, in: rect)
            } else {
                context.setFillColor(CGColor(red: 0.72, green: 0.58, blue: 0.36, alpha: 1))
                context.fill(rect)
            }
            context.restoreGState()
        }
    }

    private func drawSoftwareCharacters(
        in context: CGContext,
        store: AnimateStore,
        scene: AnimationScene,
        viewportSize: CGSize,
        cameraOffset: SIMD2<Float>,
        cameraZoom: Float
    ) {
        let visibleCharacters = scene.characterIDs.enumerated().compactMap { index, characterID -> (Int, AnimationCharacter)? in
            guard let character = store.characters.first(where: { $0.id == characterID }) else { return nil }
            return (index, character)
        }

        for (index, character) in visibleCharacters {
            let renderState = resolvedRenderState(
                for: character,
                index: index,
                characterCount: max(scene.characterIDs.count, 1),
                viewportSize: viewportSize,
                store: store
            )
            guard let renderState else { continue }

            let width = CGFloat(max(56, fallbackSpriteSize(viewportSize: viewportSize).x * abs(renderState.scale.x) * cameraZoom))
            let height = CGFloat(max(132, fallbackSpriteSize(viewportSize: viewportSize).y * abs(renderState.scale.y) * cameraZoom))
            let position = CGPoint(
                x: (CGFloat(renderState.position.x) - CGFloat(cameraOffset.x)) * CGFloat(cameraZoom),
                y: (CGFloat(renderState.position.y) - CGFloat(cameraOffset.y)) * CGFloat(cameraZoom)
            )
            let color = placeholderPaletteColor(index: index)

            context.saveGState()
            context.setAlpha(CGFloat(renderState.opacity))
            context.translateBy(x: position.x, y: position.y)
            context.rotate(by: CGFloat(renderState.rotationRadians))

            let bodyRect = CGRect(x: -width * 0.22, y: -height * 0.08, width: width * 0.44, height: height * 0.62)
            let headRect = CGRect(x: -width * 0.15, y: -height * 0.36, width: width * 0.3, height: height * 0.22)
            let shadowRect = CGRect(x: -width * 0.28, y: height * 0.28, width: width * 0.56, height: max(16, height * 0.08))

            context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.28))
            context.fillEllipse(in: shadowRect)
            context.setFillColor(CGColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1))
            context.fill(bodyRect)
            context.setFillColor(CGColor(red: min(CGFloat(color.x) + 0.18, 1), green: min(CGFloat(color.y) + 0.18, 1), blue: min(CGFloat(color.z) + 0.18, 1), alpha: 1))
            context.fillEllipse(in: headRect)
            context.restoreGState()
        }
    }

    private func softwareObjectBaseSize(
        objectName: String,
        image: NSImage?,
        viewportSize: CGSize
    ) -> CGSize {
        let isCharacterCutout = objectName.localizedCaseInsensitiveContains("cutout")
        let targetHeight = CGFloat(
            min(
                max(viewportSize.height * (isCharacterCutout ? 0.12 : 0.18), isCharacterCutout ? 92 : 64),
                isCharacterCutout ? 180 : 220
            )
        )
        guard let image else {
            return CGSize(width: targetHeight * 0.9, height: targetHeight * 0.9)
        }

        let size = image.size
        let aspectRatio = size.width / max(size.height, 1)
        if aspectRatio >= 1 {
            return CGSize(width: targetHeight * aspectRatio, height: targetHeight)
        }
        return CGSize(width: targetHeight, height: targetHeight / max(aspectRatio, 0.001))
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

    private func placeholderPaletteColor(index: Int) -> SIMD4<Float> {
        let palette: [SIMD4<Float>] = [
            SIMD4<Float>(0.42, 0.62, 0.9, 1),
            SIMD4<Float>(0.86, 0.48, 0.42, 1),
            SIMD4<Float>(0.5, 0.76, 0.56, 1),
            SIMD4<Float>(0.9, 0.72, 0.38, 1),
            SIMD4<Float>(0.66, 0.52, 0.9, 1)
        ]
        return palette[index % palette.count]
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
