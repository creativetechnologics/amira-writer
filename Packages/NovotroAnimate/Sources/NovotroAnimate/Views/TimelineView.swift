import AppKit
import Metal
import QuartzCore
import SwiftUI

// MARK: - TimelineRepresentable (SwiftUI Bridge)

@available(macOS 26.0, *)
struct TimelineRepresentable: NSViewRepresentable {
    var store: AnimateStore

    func makeNSView(context: Context) -> TimelineEditorView {
        let view = TimelineEditorView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: TimelineEditorView, context: Context) {
        nsView.store = store
        nsView.refresh()
    }
}

// MARK: - TimelineEditorView

/// Metal-backed timeline / dope sheet editor.
/// Shows track lanes with keyframe diamonds and a playhead.
@available(macOS 26.0, *)
@MainActor
final class TimelineEditorView: NSView {

    // MARK: - State

    weak var store: AnimateStore?
    private var renderer: TimelineRenderer?
    private var dirtyFlags: TimelineDirtyFlags = .all
    private var metalRedrawScheduled = false

    // MARK: - Layout

    var pixelsPerFrame: CGFloat = 6.0 {
        didSet {
            guard pixelsPerFrame != oldValue else { return }
            pixelsPerFrame = max(1, min(pixelsPerFrame, 40))
            markDirty(.all)
        }
    }

    var scrollOffset: CGPoint = .zero {
        didSet {
            guard scrollOffset != oldValue else { return }
            markDirty(.all)
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
        renderer = TimelineRenderer()
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

    func markDirty(_ flags: TimelineDirtyFlags) {
        dirtyFlags.insert(flags)
        scheduleRedraw()
    }

    func refresh() {
        markDirty(.all)
    }

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
        guard bounds.width > 0, bounds.height > 0 else { return }

        let viewport = bounds.size
        let store = self.store

        // Build track names from scene data
        var trackNames: [String] = []
        var tracks: [TimelineTrack] = []

        if let scene = store?.selectedScene {
            let orderedTracks = store?.orderedTimelineTracks(for: scene) ?? []
            if !orderedTracks.isEmpty {
                trackNames = orderedTracks.map { track in
                    store?.displayName(for: track, in: scene) ?? track.name
                }
                tracks = orderedTracks
            } else {
                trackNames.append("Background")
                tracks.append(TimelineTrack(name: "Background", keyframes: []))

                for charID in scene.characterIDs {
                    if let char = store?.characters.first(where: { $0.id == charID }) {
                        trackNames.append(char.name)
                        tracks.append(TimelineTrack(name: char.name, keyframes: []))
                    }
                }
            }
        }

        if trackNames.isEmpty {
            trackNames = ["(No scene selected)"]
            tracks = [TimelineTrack(name: "(No scene selected)", keyframes: [])]
        }

        let totalFrames = max(store?.totalFrames ?? 240, 240)
        let fps = store?.fps ?? 24

        // Rebuild buffers
        if dirtyFlags.contains(.grid) {
            renderer.buildGrid(
                trackNames: trackNames,
                totalFrames: totalFrames,
                fps: fps,
                pixelsPerFrame: pixelsPerFrame,
                viewport: viewport,
                scrollOffset: scrollOffset
            )
        }

        if dirtyFlags.contains(.keyframes) {
            renderer.buildKeyframes(
                tracks: tracks,
                pixelsPerFrame: pixelsPerFrame,
                viewport: viewport,
                scrollOffset: scrollOffset
            )
        }

        if dirtyFlags.contains(.playhead) || dirtyFlags.contains(.grid) {
            renderer.buildPlayhead(
                currentFrame: store?.currentFrame ?? 0,
                trackCount: trackNames.count,
                pixelsPerFrame: pixelsPerFrame
            )
        }

        renderer.render(
            to: metalLayer,
            scrollOffset: scrollOffset,
            viewport: viewport
        )

        dirtyFlags = []
    }

    // MARK: - Mouse Events

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            // Horizontal zoom
            let delta = event.scrollingDeltaY * 0.5
            pixelsPerFrame += delta
        } else {
            // Scroll
            scrollOffset.x -= event.scrollingDeltaX
            scrollOffset.y -= event.scrollingDeltaY
            scrollOffset.x = max(0, scrollOffset.x)
            scrollOffset.y = max(0, scrollOffset.y)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Click on timeline area to set playhead
        if point.x > renderer?.labelWidth ?? 120 {
            let frame = Int((point.x - (renderer?.labelWidth ?? 120) + scrollOffset.x) / pixelsPerFrame)
            store.currentFrame = max(0, frame)
            markDirty(.playhead)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
