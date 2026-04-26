#if canImport(AppKit)
import AppKit
import Metal
import QuartzCore

// MARK: - MetalDirtyFlags

/// Tracks which Metal buffers need rebuilding on the next render pass.
@available(macOS 26.0, *)
struct MetalDirtyFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let grid       = MetalDirtyFlags(rawValue: 1 << 0)
    static let notes      = MetalDirtyFlags(rawValue: 1 << 1)
    static let ghostNotes = MetalDirtyFlags(rawValue: 1 << 2)
    static let playhead   = MetalDirtyFlags(rawValue: 1 << 3)
    static let velocity   = MetalDirtyFlags(rawValue: 1 << 4)
    static let labels     = MetalDirtyFlags(rawValue: 1 << 5)
    static let highlight  = MetalDirtyFlags(rawValue: 1 << 6)
    static let all: MetalDirtyFlags = [.grid, .notes, .ghostNotes, .playhead, .velocity, .labels, .highlight]
}

let pianoRollMinimumNoteWidth: CGFloat = 8

// MARK: - PianoRollEditorView

/// The main AppKit container for the piano roll editor surface.
///
/// Layout:
/// ```
/// +--------------------------------------------------+
/// | PianoRollRulerView (24pt tall, fixed at top)      |
/// +----------+---------------------------------------+
/// | Keyboard | NSScrollView                          |
/// | Strip    |   +-- PianoRollCanvasView (Metal) --+ |
/// | (96pt    |   |   (gridWidth x gridHeight)      | |
/// |  wide)   |   +--------------------------------+ |
/// |          |                                       |
/// +----------+---------------------------------------+
/// | Horizontal + vertical scrollbars (overlay style) |
/// +--------------------------------------------------+
/// ```
///
/// The keyboard strip and ruler are *not* inside the scroll view. They are
/// separate sibling views whose drawing offsets are synchronised with the
/// scroll view's clip-view bounds origin.
@available(macOS 26.0, *)
@MainActor
final class PianoRollEditorView: NSView {

    // MARK: - Public Configuration

    /// Total horizontal extent of the canvas in points.
    var gridWidth: CGFloat = 5000 {
        didSet {
            guard gridWidth != oldValue else { return }
            gridWidth = min(max(gridWidth, 100), 1_000_000)
            updateLayout()
        }
    }

    /// Height of a single pitch row.
    var rowHeight: CGFloat = 16 {
        didSet {
            guard rowHeight != oldValue else { return }
            rowHeight = max(4, min(rowHeight, 64))
            updateLayout()
        }
    }

    /// Scale factor: points per MIDI tick.
    var pixelsPerTick: CGFloat = 0.267 {
        didSet {
            guard pixelsPerTick != oldValue else { return }
            pixelsPerTick = max(0.001, min(pixelsPerTick, 10))
            rulerView.pixelsPerTick = pixelsPerTick
            updateLayout()
        }
    }

    /// Resolution of the MIDI file (pulses per quarter note).
    var ticksPerQuarter: Int = 480 {
        didSet {
            guard ticksPerQuarter != oldValue else { return }
            ticksPerQuarter = max(1, min(ticksPerQuarter, 9600))
            rulerView.ticksPerQuarter = ticksPerQuarter
            updateLayout()
        }
    }

    /// Lowest MIDI pitch displayed (A0 = 21).
    var minPitch: Int = 21 {
        didSet { updateLayout() }
    }

    /// Highest MIDI pitch displayed (C8 = 108).
    var maxPitch: Int = 108 {
        didSet { updateLayout() }
    }

    /// Number of rows (pitches) visible in the grid.
    var rows: Int { maxPitch - minPitch + 1 }

    /// Total vertical extent of the canvas.
    var gridHeight: CGFloat { CGFloat(rows) * rowHeight }

    // MARK: - Note Data

    /// The notes to render on the grid.
    var notes: [PianoRollNote] = [] {
        didSet { guard notes != oldValue else { return }; markDirty([.notes, .velocity, .labels]) }
    }

    /// Draft note being drawn (Draw tool preview). Rendered as a selected note in real-time.
    var draftNotePreview: PianoRollNote? {
        didSet { guard draftNotePreview != oldValue else { return }; markDirty(.notes) }
    }

    /// Highlighted pitch row (faint glow during Draw tool creation).
    var highlightedPitchRow: Int? {
        didSet { guard highlightedPitchRow != oldValue else { return }; markDirty(.highlight) }
    }

    /// Ghost notes from non-active tracks (rendered as faded background hints).
    var ghostNotes: [PianoRollNote] = [] {
        didSet { guard ghostNotes != oldValue else { return }; markDirty(.ghostNotes) }
    }

    /// Preview notes from generated instrument parts or composed melodies.
    /// Rendered with a distinctive pulsing/translucent style to distinguish from committed notes.
    var previewNotes: [PianoRollNote] = [] {
        didSet { guard previewNotes != oldValue else { return }; markDirty(.notes) }
    }

    /// Currently selected note IDs (rendered with highlight).
    var selectedNoteIDs: Set<UUID> = [] {
        didSet { guard selectedNoteIDs != oldValue else { return }; markDirty([.notes, .velocity, .labels]) }
    }

    /// Note groups for phrase outline rendering.
    var noteGroups: [NoteGroup] = [] {
        didSet { guard noteGroups != oldValue else { return }; markDirty(.labels) }
    }

    /// Articulation entries keyed by ID for tag rendering.
    var articulationLookup: [UUID: ArticulationEntry] = [:] {
        didSet { guard articulationLookup != oldValue else { return }; markDirty(.labels) }
    }

    /// Voice lane info for multi-voice mode rendering.
    var voiceLanes: [NoteLabelsOverlayView.VoiceLaneInfo] = [] {
        didSet { guard voiceLanes != oldValue else { return }; markDirty(.labels) }
    }

    // MARK: - Playhead

    /// Current playhead position in MIDI ticks.
    var playheadTick: Int = 0 {
        didSet {
            guard playheadTick != oldValue else { return }
            rulerView.playheadTick = playheadTick
            rulerView.updatePlayheadLayerPosition()
            renderPlayheadOnly()
        }
    }

    // MARK: - Scale Highlighting

    /// Pitch classes (0-11) in the active scale. Nil = no scale highlighting.
    var scaleHighlightPitchClasses: Set<Int>? {
        didSet { guard scaleHighlightPitchClasses != oldValue else { return }; markDirty(.grid) }
    }

    /// When true, note colors blend with a cool-to-warm velocity gradient.
    var velocityColorEnabled: Bool = false {
        didSet { guard velocityColorEnabled != oldValue else { return }; markDirty([.notes, .velocity]) }
    }

    /// Current snap grid spacing in ticks for drawing subdivision lines.
    var snapTickSpan: Int = 0 {
        didSet { guard snapTickSpan != oldValue else { return }; markDirty(.grid) }
    }

    /// Time signature events for correct bar/beat grid alignment.
    var timeSignatures: [TimeSignatureEvent] = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)] {
        didSet { guard timeSignatures != oldValue else { return }; markDirty(.grid) }
    }

    /// Named timeline markers (shown on the ruler).
    var markers: [MixMarker] = [] {
        didSet { rulerView.markers = markers; rulerView.setNeedsDisplay(rulerView.bounds) }
    }

    /// Suno split tick positions (shown on the ruler as green dashed lines).
    var sunoSplits: [Int] = [] {
        didSet { rulerView.sunoSplits = sunoSplits; rulerView.setNeedsDisplay(rulerView.bounds) }
    }

    // MARK: - Lasso Overlay

    /// Update the lasso overlay from canvas-coordinate points. Pass nil/empty to clear.
    func updateLassoOverlay(canvasPoints: [CGPoint]?) {
        guard let points = canvasPoints, points.count >= 2 else {
            lassoShapeLayer.path = nil
            lassoShapeLayer.isHidden = true
            return
        }
        let scrollOrigin = scrollView.contentView.bounds.origin
        let path = CGMutablePath()
        let first = CGPoint(x: points[0].x - scrollOrigin.x, y: points[0].y - scrollOrigin.y)
        path.move(to: first)
        for i in 1..<points.count {
            let p = CGPoint(x: points[i].x - scrollOrigin.x, y: points[i].y - scrollOrigin.y)
            path.addLine(to: p)
        }
        path.closeSubpath()
        lassoShapeLayer.path = path
        lassoShapeLayer.isHidden = false
    }

    private let lassoShapeLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = [4, 3]
        layer.isHidden = true
        return layer
    }()

    // MARK: - Marquee Selection Overlay

    /// Update the marquee rectangle overlay from a canvas-coordinate rect. Pass nil to clear.
    func updateMarqueeOverlay(canvasRect: CGRect?) {
        guard let rect = canvasRect else {
            marqueeShapeLayer.path = nil
            marqueeShapeLayer.isHidden = true
            return
        }
        let scrollOrigin = scrollView.contentView.bounds.origin
        let viewportRect = CGRect(
            x: rect.origin.x - scrollOrigin.x,
            y: rect.origin.y - scrollOrigin.y,
            width: rect.width,
            height: rect.height
        )
        marqueeShapeLayer.path = CGPath(rect: viewportRect, transform: nil)
        marqueeShapeLayer.isHidden = false
    }

    private let marqueeShapeLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = [4, 3]
        layer.isHidden = true
        return layer
    }()

    // MARK: - Color Provider

    /// Callback that returns an RGBA color for a given `(channel, trackIndex)` pair.
    /// Used by the Metal renderer to colour each note.
    var noteColorProvider: ((Int, Int) -> SIMD4<Float>)?

    // MARK: - Scroll State Callbacks

    /// Fires whenever the horizontal scroll offset changes.
    /// The value is the *negative* x origin (matches the SwiftUI offset convention).
    var onScrollOffsetChanged: ((CGFloat) -> Void)?

    /// Fires whenever the visible viewport width changes.
    var onViewportWidthChanged: ((CGFloat) -> Void)?

    // MARK: - Canvas Gesture Callbacks

    /// Mouse-down on the canvas, with the point in *canvas* coordinates.
    var onCanvasMouseDown: ((NSPoint, NSEvent) -> Void)?

    /// Mouse-dragged on the canvas, with the point in *canvas* coordinates.
    var onCanvasMouseDragged: ((NSPoint, NSEvent) -> Void)?

    /// Mouse-up on the canvas, with the point in *canvas* coordinates.
    var onCanvasMouseUp: ((NSPoint, NSEvent) -> Void)?

    /// Double-click on the canvas, with the point in *canvas* coordinates.
    var onCanvasDoubleClick: ((NSPoint, NSEvent) -> Void)?

    /// Right-click on the canvas, with the point in *canvas* coordinates.
    /// Return an NSMenu to show, or nil for no menu.
    var onCanvasRightClick: ((NSPoint, NSEvent) -> NSMenu?)?

    /// Right-mouse-dragged on the canvas (for sweep-delete in Draw/Paint tools).
    var onCanvasRightDragged: ((NSPoint, NSEvent) -> Void)?

    /// Alt+scroll wheel on canvas — returns true if handled (velocity adjust)
    var onCanvasScrollWheel: ((NSPoint, NSEvent) -> Bool)?

    // MARK: - Other Callbacks

    /// Called when the user clicks on the keyboard strip to preview a pitch.
    var onPreviewPitch: ((Int) -> Void)?
    /// Called when keyboard preview interaction ends.
    var onEndPreviewPitch: (() -> Void)?

    /// Called when the user clicks or drags on the ruler to seek.
    var onSeek: ((Int) -> Void)?

    /// Called when the user right-clicks on the ruler to add a marker.
    var onAddMarker: ((Int) -> Void)?

    /// Called when the user clicks on a marker to jump to it.
    var onJumpToMarker: ((MixMarker) -> Void)?

    /// Called when the user deletes a marker.
    var onDeleteMarker: ((UUID) -> Void)?

    /// Called when the user renames a marker.
    var onRenameMarker: ((UUID, String) -> Void)?

    /// Called when the user adds a Suno split via right-click menu.
    var onAddSunoSplit: ((Int) -> Void)?

    /// Called when the user deletes a Suno split via right-click menu.
    var onDeleteSunoSplit: ((Int) -> Void)?

    // MARK: - Subviews

    let scrollView = NSScrollView()
    private let canvasView = PianoRollCanvasView()
    private let metalOverlay = PianoRollMetalOverlayView()
    private let noteLabelsOverlay = NoteLabelsOverlayView()
    private let rulerView = PianoRollRulerView()
    private let keyboardView = PianoRollKeyboardView()

    // MARK: - Renderer

    /// The Metal renderer (created externally, defined in PianoRollMetalRenderer.swift).
    var renderer: PianoRollMetalRenderer? {
        didSet {
            metalOverlay.renderCallback = { [weak self] in
                self?.renderMetal()
            }
            if let metalLayer = metalOverlay.metalLayer {
                renderer?.configureLayer(metalLayer)
            }
            markDirty(.all)
        }
    }

    // MARK: - Layout Constants

    let keyboardWidth: CGFloat = 96
    private let rulerHeight: CGFloat = 24

    // MARK: - Render Coalescing

    /// When true, a deferred `renderMetal()` call is already scheduled for this
    /// run-loop iteration.  Additional `setNeedsMetal()` calls are no-ops until
    /// the render fires.
    private var metalRedrawScheduled = false

    /// Tracks which Metal buffers need rebuilding on the next render pass.
    private var dirtyFlags: MetalDirtyFlags = .all

    // MARK: - Notification Observer

    private nonisolated(unsafe) var boundsChangeObserver: NSObjectProtocol?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer = boundsChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func commonInit() {
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        setupScrollView()
        setupCanvasView()
        setupMetalOverlay()
        setupRulerView()
        setupKeyboardView()
        installConstraints()
        observeScrollBounds()
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(
            red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0
        )
        scrollView.borderType = .noBorder
        scrollView.scrollerKnobStyle = .light

        // Use a flipped clip view so (0,0) is top-left.
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        addSubview(scrollView)
    }

    private func setupCanvasView() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvasView
    }

    private func setupMetalOverlay() {
        metalOverlay.translatesAutoresizingMaskIntoConstraints = false
        metalOverlay.renderCallback = { [weak self] in
            self?.renderMetal()
        }
        // Add the overlay ON TOP of the scroll view so it covers the viewport.
        addSubview(metalOverlay)

        // Note labels overlay: on top of Metal, passes through mouse events
        noteLabelsOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteLabelsOverlay)

        // Selection overlays: CAShapeLayers on the Metal overlay
        metalOverlay.wantsLayer = true
        metalOverlay.layer?.addSublayer(lassoShapeLayer)
        metalOverlay.layer?.addSublayer(marqueeShapeLayer)
    }

    private func setupRulerView() {
        rulerView.translatesAutoresizingMaskIntoConstraints = false
        rulerView.pixelsPerTick = pixelsPerTick
        rulerView.ticksPerQuarter = ticksPerQuarter
        rulerView.playheadTick = playheadTick
        rulerView.onSeek = { [weak self] tick in
            self?.onSeek?(tick)
        }
        rulerView.onAddMarker = { [weak self] tick in
            self?.onAddMarker?(tick)
        }
        rulerView.onJumpToMarker = { [weak self] marker in
            self?.onJumpToMarker?(marker)
        }
        rulerView.onDeleteMarker = { [weak self] id in
            self?.onDeleteMarker?(id)
        }
        rulerView.onRenameMarker = { [weak self] id, name in
            self?.onRenameMarker?(id, name)
        }
        rulerView.onAddSunoSplit = { [weak self] tick in
            self?.onAddSunoSplit?(tick)
        }
        rulerView.onDeleteSunoSplit = { [weak self] tick in
            self?.onDeleteSunoSplit?(tick)
        }
        addSubview(rulerView)
    }

    private func setupKeyboardView() {
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.minPitch = minPitch
        keyboardView.maxPitch = maxPitch
        keyboardView.rowHeight = rowHeight
        keyboardView.onPreviewPitch = { [weak self] pitch in
            self?.onPreviewPitch?(pitch)
        }
        keyboardView.onEndPreviewPitch = { [weak self] in
            self?.onEndPreviewPitch?()
        }
        addSubview(keyboardView)
    }

    private func installConstraints() {
        NSLayoutConstraint.activate([
            // Ruler: top, right of keyboard, full remaining width
            rulerView.topAnchor.constraint(equalTo: topAnchor),
            rulerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: keyboardWidth),
            rulerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rulerView.heightAnchor.constraint(equalToConstant: rulerHeight),

            // Keyboard: left side, below ruler, full remaining height
            keyboardView.topAnchor.constraint(equalTo: topAnchor, constant: rulerHeight),
            keyboardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardView.widthAnchor.constraint(equalToConstant: keyboardWidth),
            keyboardView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Scroll view: fills the remaining space
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: rulerHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: keyboardWidth),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Metal overlay: exactly matches the scroll view frame
            metalOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            metalOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            metalOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            metalOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            // Note labels overlay: matches Metal overlay
            noteLabelsOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            noteLabelsOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            noteLabelsOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            noteLabelsOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
    }

    private func observeScrollBounds() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsChangeObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScrollBoundsChanged()
            }
        }
    }

    // MARK: - Override: isFlipped

    override var isFlipped: Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        updateLayout()
        // Keep selection shape layers sized to the Metal overlay viewport.
        lassoShapeLayer.frame = metalOverlay.bounds
        marqueeShapeLayer.frame = metalOverlay.bounds
    }

    /// Recalculate internal sizes and synchronise subviews.
    private func updateLayout() {
        // Update canvas document view size (the full scrollable area).
        let docWidth = max(bounds.width - keyboardWidth, gridWidth)
        let docHeight = max(bounds.height - rulerHeight, gridHeight)
        let docSize = NSSize(width: docWidth, height: docHeight)
        if canvasView.frame.size != docSize {
            canvasView.setFrameSize(docSize)
        }

        // Update the Metal overlay's drawable to match the visible viewport.
        // The overlay sits on top of the scroll view at viewport size.
        // The renderer handles scroll offset via uniforms.
        if let metalLayer = metalOverlay.metalLayer {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let overlaySize = metalOverlay.bounds.size
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(
                width: max(1, overlaySize.width) * scale,
                height: max(1, overlaySize.height) * scale
            )
            renderer?.configureLayer(metalLayer)
        }

        // Sync keyboard configuration.
        keyboardView.minPitch = minPitch
        keyboardView.maxPitch = maxPitch
        keyboardView.rowHeight = rowHeight
        keyboardView.gridHeight = gridHeight

        // Sync ruler configuration.
        rulerView.pixelsPerTick = pixelsPerTick
        rulerView.ticksPerQuarter = ticksPerQuarter
        rulerView.playheadTick = playheadTick
        rulerView.totalWidth = docWidth
        rulerView.timeSignatures = timeSignatures
        rulerView.markers = markers

        // Sync scroll positions.
        handleScrollBoundsChanged()

        // Trigger a full Metal redraw (layout changed).
        markDirty(.all)
    }

    // MARK: - Scroll Handling

    private func handleScrollBoundsChanged() {
        let origin = scrollView.contentView.bounds.origin

        // Synchronise the ruler's horizontal scroll offset.
        rulerView.scrollOffset = origin.x
        rulerView.setNeedsDisplay(rulerView.bounds)
        rulerView.updatePlayheadLayerPosition()

        // Synchronise the keyboard's vertical scroll offset.
        keyboardView.scrollOffset = origin.y
        keyboardView.setNeedsDisplay(keyboardView.bounds)

        // Notify external listeners (positive offset = scrolled right).
        onScrollOffsetChanged?(origin.x)

        let viewportWidth = scrollView.contentView.bounds.width
        onViewportWidthChanged?(viewportWidth)

        // Scroll offset is handled in the Metal vertex shader via uniforms,
        // so only the playhead and labels need updating — NOT notes/grid/ghost.
        // Notes and ghost notes use viewport culling so they need a redraw when
        // the visible region shifts significantly.
        markDirty([.playhead, .labels, .notes, .ghostNotes])
    }

    // MARK: - Metal Rendering

    /// Marks the Metal overlay as needing a redraw.
    /// Coalesces multiple calls within the same run-loop iteration into a
    /// single `renderMetal()` at the end of the current event, so that
    /// `pushDataToEditor()` assigning 13 properties results in one render
    /// instead of 13.
    func setNeedsMetal() {
        guard !metalRedrawScheduled else { return }
        metalRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.metalRedrawScheduled else { return }
            self.metalRedrawScheduled = false
            self.renderMetal()
        }
    }

    /// Sets specific dirty flags and schedules a coalesced Metal redraw.
    private func markDirty(_ flags: MetalDirtyFlags) {
        dirtyFlags.insert(flags)
        setNeedsMetal()
    }

    /// Renders only the playhead (and issues the draw call) without
    /// rebuilding notes, ghost notes, grid, or label overlays.
    /// Used by the playhead timer for smooth 60fps animation.
    func renderPlayheadOnly() {
        // If a full renderMetal() is already queued via setNeedsMetal(),
        // skip this pass to avoid two Metal command buffer submissions per frame.
        guard !metalRedrawScheduled else { return }

        guard let renderer else { return }
        guard let metalLayer = metalOverlay.metalLayer else { return }

        let visibleOrigin = scrollView.contentView.bounds.origin
        let visibleSize = scrollView.contentView.bounds.size

        renderer.updatePlayhead(
            tick: playheadTick,
            height: gridHeight,
            pixelsPerTick: pixelsPerTick
        )
        renderer.render(
            to: metalLayer,
            scrollOffset: visibleOrigin,
            viewport: visibleSize
        )
    }

    /// Performs the actual Metal render pass. Called from the coalesced
    /// `setNeedsMetal()` dispatch.
    ///
    /// Only rebuilds the instance buffers whose dirty flags are set.
    /// The renderer's `updateGrid` call also has its own internal
    /// dirty-checking so it skips work when dimensions haven't changed.
    private func renderMetal() {
        guard let renderer else { return }
        guard let metalLayer = metalOverlay.metalLayer else { return }

        let visibleOrigin = scrollView.contentView.bounds.origin
        let visibleSize = scrollView.contentView.bounds.size

        // Snapshot and clear dirty flags for this pass.
        let flags = dirtyFlags
        dirtyFlags = []

        // 1. Update grid geometry (only when grid-related properties changed).
        if flags.contains(.grid) {
            renderer.scaleHighlightPitchClasses = scaleHighlightPitchClasses
            renderer.snapTickSpan = snapTickSpan
            renderer.timeSignatures = timeSignatures
            renderer.updateGrid(
                width: gridWidth,
                height: gridHeight,
                rowHeight: rowHeight,
                minPitch: minPitch,
                maxPitch: maxPitch,
                ticksPerQuarter: ticksPerQuarter,
                pixelsPerTick: pixelsPerTick
            )
        }

        // 1b. Update row highlight (faint glow during Draw tool creation).
        if flags.contains(.highlight) {
            renderer.updateHighlight(
                pitch: highlightedPitchRow,
                maxPitch: maxPitch,
                rowHeight: rowHeight,
                gridWidth: gridWidth
            )
        }

        // Shared color provider for notes, ghost notes, and velocity.
        let colorProvider = noteColorProvider ?? { _, _ in SIMD4<Float>(0.55, 0.78, 0.55, 1.0) }

        // 2a. Update ghost note instances (faded background from other tracks).
        if flags.contains(.ghostNotes) {
            if !ghostNotes.isEmpty {
                renderer.updateGhostNotes(
                    notes: ghostNotes,
                    maxPitch: maxPitch,
                    rowHeight: rowHeight,
                    pixelsPerTick: pixelsPerTick,
                    colorProvider: colorProvider,
                    scrollOffsetX: visibleOrigin.x,
                    viewportWidth: visibleSize.width
                )
            } else {
                renderer.clearGhostNotes()
            }
        }

        // 2b. Update note instances (include draft note preview and preview notes).
        if flags.contains(.notes) {
            var renderNotes = notes
            var renderSelected = selectedNoteIDs
            if let draft = draftNotePreview {
                renderNotes.append(draft)
                renderSelected.insert(draft.id)  // Render draft as "selected" so it stands out
            }
            // Include preview notes (generated parts / composed melodies) in render with selected style
            if !previewNotes.isEmpty {
                let previewIDs = Set(previewNotes.map(\.id))
                renderNotes.append(contentsOf: previewNotes)
                renderSelected.formUnion(previewIDs)
            }
            renderer.velocityColorEnabled = velocityColorEnabled
            renderer.updateNotes(
                notes: renderNotes,
                maxPitch: maxPitch,
                rowHeight: rowHeight,
                pixelsPerTick: pixelsPerTick,
                selectedNoteIDs: renderSelected,
                colorProvider: colorProvider,
                scrollOffsetX: visibleOrigin.x,
                viewportWidth: visibleSize.width
            )
        }

        // 3. Update playhead.
        if flags.contains(.playhead) {
            renderer.updatePlayhead(
                tick: playheadTick,
                height: gridHeight,
                pixelsPerTick: pixelsPerTick
            )
        }

        // 4. Issue the draw call (always — we need to present the frame).
        renderer.render(
            to: metalLayer,
            scrollOffset: visibleOrigin,
            viewport: visibleSize
        )

        // 5. Update note name labels (CoreGraphics overlay).
        if flags.contains(.labels) {
            noteLabelsOverlay.updateLabels(
                notes: notes,
                maxPitch: maxPitch,
                rowHeight: rowHeight,
                pixelsPerTick: pixelsPerTick,
                scrollOffset: visibleOrigin,
                viewport: visibleSize,
                noteGroups: noteGroups,
                articulationLookup: articulationLookup,
                voiceLaneInfos: voiceLanes
            )
        }
    }

    // MARK: - Programmatic Scrolling

    /// The horizontal scroll offset in points (left edge of the visible area).
    var visibleScrollOffsetX: CGFloat {
        scrollView.contentView.bounds.origin.x
    }

    /// Scrolls the canvas so that the given tick is visible at the specified anchor
    /// position within the viewport (0 = left edge, 0.5 = center, 1 = right edge).
    /// When `smooth` is true, lerps toward the target for fluid playback tracking.
    func scrollToTick(_ tick: Int, anchor: CGFloat = 0.5, smooth: Bool = false) {
        let x = CGFloat(tick) * pixelsPerTick
        let viewportWidth = scrollView.contentView.bounds.width
        let contentWidth = canvasView.frame.width
        let maxOffsetX = max(0, contentWidth - viewportWidth)
        let targetX = min(max(0, x - viewportWidth * anchor), maxOffsetX)

        let currentOrigin = scrollView.contentView.bounds.origin
        let finalX: CGFloat
        if smooth {
            // Lerp ~85% toward target each frame for buttery-smooth tracking
            let delta = targetX - currentOrigin.x
            finalX = abs(delta) < 0.5 ? targetX : currentOrigin.x + delta * 0.85
        } else {
            finalX = targetX
        }
        let newOrigin = NSPoint(x: finalX, y: currentOrigin.y)
        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls the canvas to the specified absolute horizontal offset.
    func scrollToHorizontalOffset(_ offset: CGFloat) {
        let viewportWidth = scrollView.contentView.bounds.width
        let contentWidth = canvasView.frame.width
        let maxOffsetX = max(0, contentWidth - viewportWidth)
        let targetX = min(max(0, offset), maxOffsetX)

        let currentOrigin = scrollView.contentView.bounds.origin
        let newOrigin = NSPoint(x: targetX, y: currentOrigin.y)
        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls the canvas horizontally by a pixel delta (positive = scroll right).
    func scrollByHorizontalDelta(_ delta: CGFloat) {
        let viewportWidth = scrollView.contentView.bounds.width
        let contentWidth = canvasView.frame.width
        let maxOffsetX = max(0, contentWidth - viewportWidth)
        let currentOrigin = scrollView.contentView.bounds.origin
        let targetX = min(max(0, currentOrigin.x + delta), maxOffsetX)
        let newOrigin = NSPoint(x: targetX, y: currentOrigin.y)
        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The visible viewport width of the scroll area.
    var visibleViewportWidth: CGFloat {
        scrollView.contentView.bounds.width
    }

    /// Scrolls the canvas vertically so that the given MIDI pitch is centered in the viewport.
    func scrollToPitch(_ pitch: Int, anchor: CGFloat = 0.5) {
        let y = CGFloat(maxPitch - pitch) * rowHeight
        let viewportHeight = scrollView.contentView.bounds.height
        let contentHeight = canvasView.frame.height
        let maxOffsetY = max(0, contentHeight - viewportHeight)
        let targetY = min(max(0, y - viewportHeight * anchor), maxOffsetY)

        let currentOrigin = scrollView.contentView.bounds.origin
        let newOrigin = NSPoint(x: currentOrigin.x, y: targetY)
        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - First Responder & Keyboard

    override var acceptsFirstResponder: Bool { true }

    /// Callback for keyboard events. Returns true if handled.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let handler = onKeyDown, handler(event) {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Mouse Events (forwarded to canvas callbacks)

    /// Callback to determine the cursor for a given canvas point.
    var cursorProvider: ((NSPoint) -> NSCursor)?

    override func mouseDown(with event: NSEvent) {
        // Become first responder to receive key events
        window?.makeFirstResponder(self)

        let locationInCanvas = canvasView.convert(event.locationInWindow, from: nil)

        // Check if the click is within the canvas portion of the scroll view.
        let locationInScroll = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(locationInScroll) else {
            super.mouseDown(with: event)
            return
        }

        // Double-click
        if event.clickCount == 2 {
            onCanvasDoubleClick?(locationInCanvas, event)
            return
        }

        onCanvasMouseDown?(locationInCanvas, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let locationInCanvas = canvasView.convert(event.locationInWindow, from: nil)
        let locationInScroll = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(locationInScroll) else {
            super.rightMouseDown(with: event)
            return
        }

        if let menu = onCanvasRightClick?(locationInCanvas, event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        let locationInCanvas = canvasView.convert(event.locationInWindow, from: nil)
        onCanvasRightDragged?(locationInCanvas, event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option),
           let handler = onCanvasScrollWheel {
            let locationInCanvas = canvasView.convert(event.locationInWindow, from: nil)
            if handler(locationInCanvas, event) { return }
        }
        super.scrollWheel(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let locationInCanvas = canvasView.convert(event.locationInWindow, from: nil)
        onCanvasMouseDragged?(locationInCanvas, event)
    }

    override func mouseUp(with event: NSEvent) {
        let locationInCanvas = canvasView.convert(event.locationInWindow, from: nil)
        onCanvasMouseUp?(locationInCanvas, event)
        // Update cursor after drag ends
        updateCursorForEvent(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursorForEvent(event)
    }

    func refreshCursor() {
        guard let window, let provider = cursorProvider else { return }
        let locationInWindow = window.mouseLocationOutsideOfEventStream
        let locationInScroll = scrollView.convert(locationInWindow, from: nil)
        guard scrollView.bounds.contains(locationInScroll) else {
            NSCursor.arrow.set()
            return
        }
        let locationInCanvas = canvasView.convert(locationInWindow, from: nil)
        provider(locationInCanvas).set()
    }

    private func updateCursorForEvent(_ event: NSEvent) {
        guard let provider = cursorProvider else { return }
        let locationInCanvas = canvasView.convert(event.locationInWindow, from: nil)
        let locationInScroll = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(locationInScroll) else {
            NSCursor.arrow.set()
            return
        }
        provider(locationInCanvas).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove old tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // Add a tracking area that covers the whole view for mouseMoved + mouseExited
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}

// MARK: - FlippedClipView

/// A flipped NSClipView so that (0,0) is top-left, matching the piano roll's
/// pitch ordering (highest pitch at top).
@available(macOS 26.0, *)
@MainActor
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - PianoRollCanvasView

/// The document view inside the NSScrollView. Its frame represents the entire
/// scrollable canvas (gridWidth x gridHeight). This is a plain NSView that
/// defines the scrollable area — Metal rendering is done by a separate overlay.
@available(macOS 26.0, *)
@MainActor
final class PianoRollCanvasView: NSView {

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Flipped

    override var isFlipped: Bool { true }
}

// MARK: - PianoRollMetalOverlayView

/// A view placed on top of the scroll view that hosts the CAMetalLayer.
/// Its frame matches the scroll view's visible area (viewport), not the
/// full document. It passes all mouse events through to the views below.
@available(macOS 26.0, *)
@MainActor
final class PianoRollMetalOverlayView: NSView {

    /// Called during `updateLayer()` to trigger a Metal render pass.
    var renderCallback: (() -> Void)?

    /// Convenience accessor for the backing `CAMetalLayer`.
    var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layer Configuration

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, frame.width) * scale,
            height: max(1, frame.height) * scale
        )
        return metalLayer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        renderCallback?()
    }

    // MARK: - Pass-through hit testing

    /// Returns nil so that all mouse events pass through to the scroll view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    // MARK: - Flipped

    override var isFlipped: Bool { true }
}

// MARK: - PianoRollRulerView

/// A ruler bar across the top of the piano roll showing bar numbers, beat
/// markers, and the playhead indicator. Rendered with CoreGraphics.
///
/// This view is positioned *outside* the scroll view and tracks the horizontal
/// scroll offset to stay in sync.
@available(macOS 26.0, *)
@MainActor
final class PianoRollRulerView: NSView {

    // MARK: - Configuration

    /// Horizontal scroll offset from the main scroll view's clip-view origin.x.
    var scrollOffset: CGFloat = 0

    /// Points per MIDI tick.
    var pixelsPerTick: CGFloat = 0.267

    /// MIDI resolution (pulses per quarter note).
    var ticksPerQuarter: Int = 480

    /// Current playhead position in MIDI ticks.
    var playheadTick: Int = 0

    /// Total scrollable width (used to size the drawing area).
    var totalWidth: CGFloat = 5000

    /// Time signature events for correct bar numbering and grid lines.
    var timeSignatures: [TimeSignatureEvent] = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]

    /// Named timeline markers displayed as colored flags.
    var markers: [MixMarker] = []

    /// Suno split tick positions (sorted).
    var sunoSplits: [Int] = []

    /// Callback when the user clicks/drags to seek.
    var onSeek: ((Int) -> Void)?

    /// Callback when the user right-clicks on the ruler to add a marker at a tick.
    var onAddMarker: ((Int) -> Void)?

    /// Callback when the user adds a Suno split via right-click menu.
    var onAddSunoSplit: ((Int) -> Void)?

    /// Callback when the user deletes a Suno split via right-click menu.
    var onDeleteSunoSplit: ((Int) -> Void)?

    /// Callback when the user clicks on a marker to jump to it.
    var onJumpToMarker: ((MixMarker) -> Void)?

    /// Callback to delete a marker.
    var onDeleteMarker: ((UUID) -> Void)?

    /// Callback to rename a marker.
    var onRenameMarker: ((UUID, String) -> Void)?

    // MARK: - Cached Fonts & Label Attributes

    /// Pre-created font for bar number labels — avoids repeated font lookups in draw().
    private let rulerFont: NSFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

    // MARK: - Cached Bar/Beat Positions

    private var cachedBarPositions: [(tick: Int, barNumber: Int)] = []
    private var cachedBeatPositions: [Int] = []
    private var lastCachedPixelsPerTick: CGFloat = -1
    private var lastCachedTicksPerQuarter: Int = -1
    private var lastCachedTimeSignatures: [TimeSignatureEvent] = []
    private var lastCachedTotalWidth: CGFloat = -1

    /// CALayer overlay for the playhead vertical line.
    private lazy var playheadLineLayer: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        l.zPosition = 100
        return l
    }()

    /// CAShapeLayer for the playhead triangle.
    private lazy var playheadTriangleLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = NSColor.white.cgColor
        l.zPosition = 101
        // Triangle pointing down: 10px wide, 8px tall
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -5, y: 0))
        path.addLine(to: CGPoint(x: 5, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 8))
        path.closeSubpath()
        l.path = path
        return l
    }()

    func updatePlayheadLayerPosition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x = CGFloat(playheadTick) * pixelsPerTick - scrollOffset
        let h = bounds.height
        let visible = x >= -6 && x <= bounds.width + 6
        playheadLineLayer.frame = CGRect(x: x - 0.5, y: 8, width: 1, height: max(0, h - 8))
        playheadLineLayer.isHidden = !visible
        playheadTriangleLayer.position = CGPoint(x: x, y: 0)
        playheadTriangleLayer.isHidden = !visible
        CATransaction.commit()
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playheadLineLayer)
        layer?.addSublayer(playheadTriangleLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Flipped

    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let height = bounds.height
        let width = bounds.width

        // Background
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        context.fill(bounds)

        let safePixelsPerTick = max(pixelsPerTick, 0.000_01)
        let beatTicks = max(1, ticksPerQuarter)

        // Determine visible tick range based on scroll offset.
        let visibleStartTick = max(0, Int(scrollOffset / safePixelsPerTick) - beatTicks)
        let visibleEndTick = Int((scrollOffset + width) / safePixelsPerTick) + beatTicks

        // Rebuild bar/beat position cache if inputs changed
        let needsRebuild = pixelsPerTick != lastCachedPixelsPerTick
            || ticksPerQuarter != lastCachedTicksPerQuarter
            || totalWidth != lastCachedTotalWidth
            || timeSignatures != lastCachedTimeSignatures

        if needsRebuild {
            let tsEvents = timeSignatures.isEmpty
                ? [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
                : timeSignatures.sorted(by: { $0.tick < $1.tick })

            var newBarPositions: [(tick: Int, barNumber: Int)] = []
            var newBeatPositions: [Int] = []
            var tsIdx = 0
            var currentNum = tsEvents[0].numerator
            var currentDenom = tsEvents[0].denominator
            var barStart = 0
            var barNumber = 1

            let fullEndTick = Int(totalWidth / safePixelsPerTick) + beatTicks * 4
            var safetyCount = 0

            while barStart <= fullEndTick, safetyCount < 8000 {
                safetyCount += 1
                newBarPositions.append((tick: barStart, barNumber: barNumber))

                let beatTicksForTS = max(1, beatTicks * 4 / max(1, currentDenom))
                let barLength = beatTicksForTS * currentNum

                for b in 1..<currentNum {
                    newBeatPositions.append(barStart + b * beatTicksForTS)
                }

                let nextBar = barStart + barLength

                while tsIdx + 1 < tsEvents.count, tsEvents[tsIdx + 1].tick <= nextBar {
                    tsIdx += 1
                    currentNum = tsEvents[tsIdx].numerator
                    currentDenom = tsEvents[tsIdx].denominator
                }

                barStart = nextBar
                barNumber += 1
            }

            cachedBarPositions = newBarPositions
            cachedBeatPositions = newBeatPositions
            lastCachedPixelsPerTick = pixelsPerTick
            lastCachedTicksPerQuarter = ticksPerQuarter
            lastCachedTotalWidth = totalWidth
            lastCachedTimeSignatures = timeSignatures
        }

        let barPositions = cachedBarPositions
        let beatPositions = cachedBeatPositions

        // --- Beat tick marks ---
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(0.8)

        for bt in beatPositions {
            guard bt >= visibleStartTick, bt <= visibleEndTick else { continue }
            let x = CGFloat(bt) * safePixelsPerTick - scrollOffset
            if x >= -1 && x <= width + 1 {
                context.move(to: CGPoint(x: x, y: height * 0.36))
                context.addLine(to: CGPoint(x: x, y: height))
            }
        }
        context.strokePath()

        // --- Bar lines ---
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.30).cgColor)
        context.setLineWidth(1.0)

        for (barTick, _) in barPositions {
            guard barTick >= visibleStartTick - beatTicks, barTick <= visibleEndTick else { continue }
            let x = CGFloat(barTick) * safePixelsPerTick - scrollOffset
            if x >= -1 && x <= width + 1 {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: height))
            }
        }
        context.strokePath()

        // --- Bar number labels ---
        // Determine label stride: skip labels when bars are very narrow
        let avgBarWidth: CGFloat
        if barPositions.count >= 2 {
            let firstFew = min(barPositions.count, 10)
            let span = CGFloat(barPositions[firstFew - 1].tick - barPositions[0].tick) * safePixelsPerTick
            avgBarWidth = span / CGFloat(firstFew - 1)
        } else {
            avgBarWidth = CGFloat(beatTicks * 4) * safePixelsPerTick
        }
        let labelStride = max(1, Int((56.0 / max(1, avgBarWidth)).rounded(.up)))

        let ctFont = rulerFont as CTFont
        let labelColor = NSColor.white.withAlphaComponent(0.78).cgColor
        let labelAttrs: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: labelColor,
        ]

        for (barTick, barNum) in barPositions {
            guard (barNum - 1) % labelStride == 0 else { continue }
            guard barTick >= visibleStartTick - beatTicks, barTick <= visibleEndTick else { continue }
            let x = CGFloat(barTick) * safePixelsPerTick - scrollOffset + 4
            if x >= -30 && x <= width + 30 {
                let attrStr = CFAttributedStringCreate(
                    nil,
                    "\(barNum)" as CFString,
                    labelAttrs as CFDictionary
                )!
                let line = CTLineCreateWithAttributedString(attrStr)
                context.saveGState()
                // CTLineDraw uses a non-flipped coordinate system; flip for our isFlipped view
                context.translateBy(x: x, y: 3 + rulerFont.ascender)
                context.scaleBy(x: 1, y: -1)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }

        // --- Markers ---
        let markerNSFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let markerCTFont = markerNSFont as CTFont
        let markerFontAscent = CTFontGetAscent(markerCTFont)
        for marker in markers {
            let mx = CGFloat(marker.tick) * safePixelsPerTick - scrollOffset
            guard mx >= -60, mx <= width + 10 else { continue }

            // Parse color or use default orange
            let markerColor: NSColor
            if let hex = marker.colorHex, hex.count >= 6 {
                let hexStr = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
                if let val = UInt64(hexStr, radix: 16) {
                    let r = CGFloat((val >> 16) & 0xFF) / 255.0
                    let g = CGFloat((val >> 8) & 0xFF) / 255.0
                    let b = CGFloat(val & 0xFF) / 255.0
                    markerColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
                } else {
                    markerColor = NSColor.systemOrange
                }
            } else {
                markerColor = NSColor.systemOrange
            }

            // Draw flag triangle
            context.setFillColor(markerColor.cgColor)
            context.beginPath()
            context.move(to: CGPoint(x: mx, y: 0))
            context.addLine(to: CGPoint(x: mx + 8, y: 0))
            context.addLine(to: CGPoint(x: mx + 8, y: 12))
            context.addLine(to: CGPoint(x: mx, y: 16))
            context.closePath()
            context.fillPath()

            // Draw marker name via CTLine (avoids NSAttributedString.draw crash path)
            let mAttrs: [CFString: Any] = [
                kCTFontAttributeName: markerCTFont,
                kCTForegroundColorAttributeName: markerColor.cgColor,
            ]
            let mAttrStr = CFAttributedStringCreate(nil, marker.name as CFString, mAttrs as CFDictionary)!
            let mLine = CTLineCreateWithAttributedString(mAttrStr)
            context.saveGState()
            context.translateBy(x: mx + 10, y: 2 + markerFontAscent)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(mLine, context)
            context.restoreGState()

            // Thin vertical line
            context.setStrokeColor(markerColor.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: mx, y: 16))
            context.addLine(to: CGPoint(x: mx, y: height))
            context.strokePath()
        }

        // --- Suno Splits ---
        let sunoColor = NSColor.systemGreen
        let sunoFont = NSFont.systemFont(ofSize: 8, weight: .bold)
        let sunoCTFont = sunoFont as CTFont
        let sunoFontAscent = CTFontGetAscent(sunoCTFont)
        for (idx, splitTick) in sunoSplits.enumerated() {
            let sx = CGFloat(splitTick) * safePixelsPerTick - scrollOffset
            guard sx >= -40, sx <= width + 10 else { continue }

            // Draw scissor icon (small diamond)
            context.setFillColor(sunoColor.cgColor)
            context.beginPath()
            context.move(to: CGPoint(x: sx, y: 0))
            context.addLine(to: CGPoint(x: sx + 6, y: 0))
            context.addLine(to: CGPoint(x: sx + 6, y: 6))
            context.addLine(to: CGPoint(x: sx + 3, y: 10))
            context.addLine(to: CGPoint(x: sx, y: 6))
            context.closePath()
            context.fillPath()

            // Draw split label
            let splitLabel = "S\(idx + 1)" as CFString
            let sAttrs: [CFString: Any] = [
                kCTFontAttributeName: sunoCTFont,
                kCTForegroundColorAttributeName: sunoColor.cgColor,
            ]
            let sAttrStr = CFAttributedStringCreate(nil, splitLabel, sAttrs as CFDictionary)!
            let sLine = CTLineCreateWithAttributedString(sAttrStr)
            context.saveGState()
            context.translateBy(x: sx + 8, y: 1 + sunoFontAscent)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(sLine, context)
            context.restoreGState()

            // Dashed vertical line
            context.setStrokeColor(sunoColor.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(1.0)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.move(to: CGPoint(x: sx, y: 10))
            context.addLine(to: CGPoint(x: sx, y: height))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }

        // Playhead is rendered via playheadLineLayer + playheadTriangleLayer (CALayer) for 60fps smoothness

        // Bottom border line
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: 0, y: height - 0.5))
        context.addLine(to: CGPoint(x: width, y: height - 0.5))
        context.strokePath()
    }

    // MARK: - Mouse Events (Seek)

    override func mouseDown(with event: NSEvent) {
        seekFromEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        seekFromEvent(event)
    }

    private func seekFromEvent(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let safePixelsPerTick = max(pixelsPerTick, 0.000_01)
        let tick = Int(((location.x + scrollOffset) / safePixelsPerTick).rounded())
        onSeek?(max(0, tick))
    }

    // MARK: - Right-Click (Markers)

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let safePixelsPerTick = max(pixelsPerTick, 0.000_01)
        let clickTick = max(0, Int(((location.x + scrollOffset) / safePixelsPerTick).rounded()))

        // Check if clicking on an existing marker (within 20px)
        let hitMarker = markers.first { marker in
            let mx = CGFloat(marker.tick) * safePixelsPerTick - scrollOffset
            return abs(location.x - mx) < 20 && location.y < 20
        }

        // Check if clicking near a Suno split (within 20px)
        let hitSunoSplit = sunoSplits.first { splitTick in
            let sx = CGFloat(splitTick) * safePixelsPerTick - scrollOffset
            return abs(location.x - sx) < 20
        }

        let menu = NSMenu()

        if let marker = hitMarker {
            let jumpItem = NSMenuItem(title: "Jump to \"\(marker.name)\"", action: nil, keyEquivalent: "")
            jumpItem.target = self
            menu.addItem(jumpItem)
            jumpItem.action = #selector(rulerJumpToMarker(_:))
            jumpItem.representedObject = marker

            let renameItem = NSMenuItem(title: "Rename...", action: #selector(rulerRenameMarker(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = marker
            menu.addItem(renameItem)

            let deleteItem = NSMenuItem(title: "Delete Marker", action: #selector(rulerDeleteMarker(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = marker
            menu.addItem(deleteItem)
        } else if let splitTick = hitSunoSplit {
            let deleteItem = NSMenuItem(title: "Delete Suno Split", action: #selector(rulerDeleteSunoSplit(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.tag = splitTick
            menu.addItem(deleteItem)
        } else {
            let addItem = NSMenuItem(title: "Add Marker Here", action: #selector(rulerAddMarker(_:)), keyEquivalent: "")
            addItem.target = self
            addItem.tag = clickTick
            menu.addItem(addItem)

            menu.addItem(NSMenuItem.separator())

            let addSunoItem = NSMenuItem(title: "Add Suno Split", action: #selector(rulerAddSunoSplit(_:)), keyEquivalent: "")
            addSunoItem.target = self
            addSunoItem.tag = clickTick
            menu.addItem(addSunoItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func rulerAddMarker(_ sender: NSMenuItem) {
        onAddMarker?(sender.tag)
    }

    @objc private func rulerJumpToMarker(_ sender: NSMenuItem) {
        guard let marker = sender.representedObject as? MixMarker else { return }
        onJumpToMarker?(marker)
    }

    @objc private func rulerDeleteMarker(_ sender: NSMenuItem) {
        guard let marker = sender.representedObject as? MixMarker else { return }
        onDeleteMarker?(marker.id)
    }

    @objc private func rulerRenameMarker(_ sender: NSMenuItem) {
        guard let marker = sender.representedObject as? MixMarker else { return }
        // Show a simple rename alert
        let alert = NSAlert()
        alert.messageText = "Rename Marker"
        alert.informativeText = "Enter a new name for the marker:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = marker.name
        alert.accessoryView = textField
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if !newName.isEmpty {
                onRenameMarker?(marker.id, newName)
            }
        }
    }

    @objc private func rulerAddSunoSplit(_ sender: NSMenuItem) {
        onAddSunoSplit?(sender.tag)
    }

    @objc private func rulerDeleteSunoSplit(_ sender: NSMenuItem) {
        onDeleteSunoSplit?(sender.tag)
    }

    // MARK: - Hit Testing

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - PianoRollKeyboardView

/// A piano keyboard strip drawn on the left side of the piano roll. Shows
/// black/white key indicators and note labels for C notes. Rendered with
/// CoreGraphics.
///
/// This view is positioned *outside* the scroll view and tracks the vertical
/// scroll offset to stay in sync.
@available(macOS 26.0, *)
@MainActor
final class PianoRollKeyboardView: NSView {

    // MARK: - Configuration

    /// Vertical scroll offset from the main scroll view's clip-view origin.y.
    var scrollOffset: CGFloat = 0

    /// Lowest MIDI pitch displayed.
    var minPitch: Int = 21

    /// Highest MIDI pitch displayed.
    var maxPitch: Int = 108

    /// Height of each pitch row.
    var rowHeight: CGFloat = 16

    /// Callback when the user clicks a key to preview a pitch.
    var onPreviewPitch: ((Int) -> Void)?
    /// Called when the keyboard preview interaction ends.
    var onEndPreviewPitch: (() -> Void)?

    /// Total grid height — keyboard drawing is clipped to this.
    var gridHeight: CGFloat = 0

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Flipped

    override var isFlipped: Bool { true }

    // MARK: - Drawing

    // MARK: - FL Studio Keyboard Constants

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let viewWidth = bounds.width
        let viewHeight = bounds.height

        // Background — matches the desaturated grid background
        context.setFillColor(CGColor(gray: 0.11, alpha: 1.0))
        context.fill(bounds)

        // Guard against degenerate layout — rowHeight must be positive and finite
        guard rowHeight > 0, rowHeight.isFinite else { return }

        // Clip drawing to the actual grid height (don't draw keys below the grid)
        if gridHeight > 0 {
            let clipHeight = min(viewHeight, gridHeight - scrollOffset)
            if clipHeight < viewHeight {
                context.clip(to: CGRect(x: 0, y: 0, width: viewWidth, height: max(0, clipHeight)))
            }
        }

        // Determine which pitch rows are visible.
        let totalRows = maxPitch - minPitch + 1
        let firstVisibleRow = max(0, Int(scrollOffset / rowHeight) - 1)
        let lastVisibleRow = min(totalRows - 1, Int((scrollOffset + viewHeight) / rowHeight) + 1)
        guard firstVisibleRow <= lastVisibleRow else { return }

        // FL Studio keyboard: white keys extend full width, black keys are shorter and overlap
        let whiteKeyWidth = viewWidth - 2     // nearly full width
        let blackKeyWidth = viewWidth * 0.58  // ~58% of keyboard width

        // Label fonts — use CTFont/CTLine to avoid NSAttributedString CoreText crash
        let labelFontSize = min(9, max(6.5, rowHeight * 0.55))
        let whiteCTFont = CTFontCreateWithName("Menlo" as CFString, labelFontSize, nil)
        let blackCTFont = CTFontCreateWithName("Menlo" as CFString, max(5.5, labelFontSize - 1), nil)
        let whiteLabelColor = CGColor(gray: 0.32, alpha: 1.0)
        let blackLabelColor = CGColor(gray: 0.50, alpha: 1.0)
        let whiteLabelAttrs: [CFString: Any] = [
            kCTFontAttributeName: whiteCTFont,
            kCTForegroundColorAttributeName: whiteLabelColor,
        ]
        let blackLabelAttrs: [CFString: Any] = [
            kCTFontAttributeName: blackCTFont,
            kCTForegroundColorAttributeName: blackLabelColor,
        ]

        // --- First pass: draw white key backgrounds ---
        for row in firstVisibleRow...lastVisibleRow {
            let pitch = maxPitch - row
            guard pitch >= minPitch && pitch <= maxPitch else { continue }
            let y = CGFloat(row) * rowHeight - scrollOffset
            guard y + rowHeight > 0 && y < viewHeight else { continue }
            let black = isBlackKey(pitch)
            if black { continue }

            // White key row background — FL Studio light gray
            let keyRect = NSRect(x: 0, y: y + 0.5, width: whiteKeyWidth, height: rowHeight - 1)
            context.setFillColor(CGColor(gray: 0.52, alpha: 1.0))
            let keyPath = CGPath(
                roundedRect: keyRect,
                cornerWidth: 2, cornerHeight: 2, transform: nil
            )
            context.addPath(keyPath)
            context.fillPath()

            // Subtle top highlight for 3D effect
            context.setFillColor(CGColor(gray: 0.62, alpha: 1.0))
            context.fill(CGRect(x: 1, y: y + 0.5, width: whiteKeyWidth - 2, height: max(1, rowHeight * 0.15)))
        }

        // --- Second pass: draw black keys on top ---
        for row in firstVisibleRow...lastVisibleRow {
            let pitch = maxPitch - row
            guard pitch >= minPitch && pitch <= maxPitch else { continue }
            let y = CGFloat(row) * rowHeight - scrollOffset
            guard y + rowHeight > 0 && y < viewHeight else { continue }
            let black = isBlackKey(pitch)
            if !black { continue }

            // Black key — FL Studio dark with slight 3D bevel
            let keyRect = NSRect(x: 0, y: y + 0.5, width: blackKeyWidth, height: rowHeight - 1)
            context.setFillColor(CGColor(gray: 0.18, alpha: 1.0))
            let keyPath = CGPath(
                roundedRect: keyRect,
                cornerWidth: 2, cornerHeight: 2, transform: nil
            )
            context.addPath(keyPath)
            context.fillPath()

            // Subtle top highlight
            context.setFillColor(CGColor(gray: 0.24, alpha: 1.0))
            context.fill(CGRect(x: 1, y: y + 0.5, width: blackKeyWidth - 2, height: max(1, rowHeight * 0.15)))
        }

        // --- Third pass: labels on top of everything ---
        for row in firstVisibleRow...lastVisibleRow {
            let pitch = maxPitch - row
            guard pitch >= minPitch && pitch <= maxPitch else { continue }
            let y = CGFloat(row) * rowHeight - scrollOffset
            guard y + rowHeight > 0 && y < viewHeight else { continue }

            let black = isBlackKey(pitch)
            let pitchClass = ((pitch % 12) + 12) % 12
            let noteName = Self.noteNames[pitchClass]
            let octave = (pitch / 12) - 1

            if black {
                // Black key label — note name only, right-aligned inside the key
                guard rowHeight >= 10 else { continue }
                let label = noteName
                let cfStr = CFAttributedStringCreate(nil, label as CFString, blackLabelAttrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(cfStr)
                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil))
                let lineHeight = lineAscent + lineDescent
                let labelX = max(4, blackKeyWidth - lineWidth - 6)
                context.saveGState()
                context.translateBy(x: labelX, y: y + (rowHeight - lineHeight) / 2 + lineAscent)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            } else {
                // White key label — note name, and octave number for C notes
                guard rowHeight >= 10 else { continue }
                let label = pitchClass == 0 ? "\(noteName)\(octave)" : noteName
                let cfStr = CFAttributedStringCreate(nil, label as CFString, whiteLabelAttrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(cfStr)
                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
                let lineHeight = lineAscent + lineDescent
                let labelX: CGFloat = 6
                context.saveGState()
                context.translateBy(x: labelX, y: y + (rowHeight - lineHeight) / 2 + lineAscent)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }

            // Octave separator — thicker line at C boundaries
            if pitchClass == 0 {
                context.setStrokeColor(CGColor(gray: 0.0, alpha: 0.6))
                context.setLineWidth(1.0)
                context.move(to: CGPoint(x: 0, y: y + rowHeight - 0.5))
                context.addLine(to: CGPoint(x: viewWidth, y: y + rowHeight - 0.5))
                context.strokePath()
            }
        }

        // Right border
        context.setStrokeColor(CGColor(gray: 0.0, alpha: 0.5))
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: viewWidth - 0.5, y: 0))
        context.addLine(to: CGPoint(x: viewWidth - 0.5, y: viewHeight))
        context.strokePath()
    }

    // MARK: - Mouse Events (Pitch Preview)

    /// Tracks the last previewed pitch during a drag so we only re-trigger when the pitch changes.
    private var lastPreviewedPitch: Int = -1

    override func mouseDown(with event: NSEvent) {
        let pitch = pitchAtLocation(event)
        if pitch >= minPitch && pitch <= maxPitch {
            lastPreviewedPitch = pitch
            onPreviewPitch?(pitch)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pitch = pitchAtLocation(event)
        if pitch >= minPitch && pitch <= maxPitch {
            if pitch != lastPreviewedPitch {
                lastPreviewedPitch = pitch
                onPreviewPitch?(pitch)
            }
        } else if lastPreviewedPitch != -1 {
            lastPreviewedPitch = -1
            onEndPreviewPitch?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if lastPreviewedPitch != -1 {
            onEndPreviewPitch?()
        }
        lastPreviewedPitch = -1
    }

    private func pitchAtLocation(_ event: NSEvent) -> Int {
        let location = convert(event.locationInWindow, from: nil)
        let row = Int((location.y + scrollOffset) / rowHeight)
        return maxPitch - row
    }

    // MARK: - Scroll Forwarding

    /// Forward scroll-wheel events to the parent scroll view so the user can
    /// scroll the piano roll vertically while hovering over the keyboard.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // MARK: - Hit Testing

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Helpers

    private func isBlackKey(_ pitch: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(pitch % 12)
    }

    private func noteLabel(for pitch: Int) -> String {
        guard pitch % 12 == 0 else { return "" }
        let octave = (pitch / 12) - 1
        return "C\(octave)"
    }
}

// MARK: - VelocityLaneView

/// CoreGraphics-rendered velocity lane showing note velocities as vertical bars.
/// Sits below the piano roll, horizontally synced with the scroll offset.
@available(macOS 26.0, *)
@MainActor
final class VelocityLaneView: NSView {

    var notes: [PianoRollNote] = [] { didSet { guard notes != oldValue else { return }; setNeedsDisplay(bounds) } }
    var ghostNotes: [PianoRollNote] = [] { didSet { guard ghostNotes != oldValue else { return }; setNeedsDisplay(bounds) } }
    var selectedNoteIDs: Set<UUID> = [] { didSet { guard selectedNoteIDs != oldValue else { return }; setNeedsDisplay(bounds) } }
    private var scrollRedrawScheduled = false
    var scrollOffset: CGFloat = 0 { didSet { guard scrollOffset != oldValue else { return }; scheduleScrollRedraw(); updatePlayheadLayerPosition() } }
    private func scheduleScrollRedraw() {
        guard !scrollRedrawScheduled else { return }
        scrollRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrollRedrawScheduled else { return }
            self.scrollRedrawScheduled = false
            self.setNeedsDisplay(self.bounds)
        }
    }
    var pixelsPerTick: CGFloat = 0.267 { didSet { guard pixelsPerTick != oldValue else { return }; setNeedsDisplay(bounds); updatePlayheadLayerPosition() } }
    var gridWidth: CGFloat = 5000 { didSet { guard gridWidth != oldValue else { return }; setNeedsDisplay(bounds) } }
    var playheadTick: Int = 0 { didSet { guard playheadTick != oldValue else { return }; updatePlayheadLayerPosition() } }
    var colorProvider: ((Int, Int) -> SIMD4<Float>)?
    /// Horizontal offset where the scroll content begins (keyboard strip width).
    var keyboardOffset: CGFloat = 96 { didSet { guard keyboardOffset != oldValue else { return }; setNeedsDisplay(bounds); updatePlayheadLayerPosition() } }

    /// Which corners to round. Use CACornerMask values.
    var roundedCorners: CACornerMask = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Called when the user drags to change a note's velocity. Params: (noteID, newVelocity).
    var onVelocityChanged: ((UUID, Int) -> Void)?

    /// Called when velocity curve painting finishes with batch of (noteID, newVelocity) pairs.
    var onVelocityBatchChanged: (([(UUID, Int)]) -> Void)?

    /// Called when the user scrolls horizontally in the lane.
    var onHorizontalScroll: ((CGFloat) -> Void)?

    // Drag state
    private var dragNoteID: UUID?
    /// When true, the drag paints velocity on every note the cursor passes over
    /// (not just the initially clicked note). Activated as soon as the drag
    /// moves horizontally away from the starting note.
    private var isDragPainting = false
    /// Collects (noteID, velocity) pairs during a drag-paint for batch commit on mouseUp.
    private var dragPaintChanges: [(UUID, Int)] = []
    private var lastDragPaintPoint: NSPoint?
    private var lastAppliedVelocityByNoteID: [UUID: Int] = [:]

    // Velocity curve painting state (Alt+drag)
    private var isLinePainting = false
    private var lineStartPoint: NSPoint = .zero
    private var lineEndPoint: NSPoint = .zero

    /// CALayer overlay for the playhead line — repositioned at display refresh rate without full redraws.
    private lazy var playheadLayer: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        l.zPosition = 100
        return l
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playheadLayer)
    }

    private func updatePlayheadLayerPosition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x = keyboardOffset + CGFloat(playheadTick) * pixelsPerTick - scrollOffset
        playheadLayer.frame = CGRect(x: x - 0.5, y: 0, width: 1, height: bounds.height)
        playheadLayer.isHidden = x < -2 || x > bounds.width + 2
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let width = bounds.width
        let height = bounds.height
        let cr: CGFloat = 10

        // Build per-corner path
        let bgPath = Self.pathWithSelectiveCorners(bounds, radius: cr, corners: roundedCorners)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor(red: 0.14, green: 0.15, blue: 0.16, alpha: 0.90).cgColor)
        ctx.fillPath()

        // Border
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let borderPath = Self.pathWithSelectiveCorners(borderRect, radius: cr, corners: roundedCorners)
        ctx.addPath(borderPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let safePPT = max(pixelsPerTick, 0.000_01)
        let kbOff = keyboardOffset

        // Clip to the content area (right of keyboard offset) so velocity
        // stems, dots, and bars never bleed into the label/keyboard zone.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: kbOff, y: 0, width: width - kbOff, height: height))

        // Determine visible tick range
        let startTick = max(0, Int(scrollOffset / safePPT) - 100)
        let endTick = Int((scrollOffset + width) / safePPT) + 100

        // Draw velocity stems + dots + horizontal bars (FL Studio style)
        let maxBarHeight = height - 8
        let bottomY = height - 4
        let defaultColor = SIMD4<Float>(0.55, 0.78, 0.55, 1.0)
        let stemWidth: CGFloat = 1.0
        let dotRadius: CGFloat = 3.0
        let hBarHeight: CGFloat = 1.0

        // Ghost velocity bars — faded bars for non-active tracks
        if !ghostNotes.isEmpty {
            let ghostAlpha: CGFloat = 0.45
            let ghostColor = CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: ghostAlpha)
            for note in ghostNotes {
                let noteEndTick = note.startTick + note.duration
                guard noteEndTick >= startTick && note.startTick <= endTick else { continue }

                let x = kbOff + CGFloat(note.startTick) * safePPT - scrollOffset
                let velocityFraction = CGFloat(note.velocity) / 127.0
                let stemHeight = max(5, velocityFraction * maxBarHeight)
                let topY = bottomY - stemHeight

                ctx.setFillColor(ghostColor)
                ctx.fill(CGRect(x: x - stemWidth * 0.5, y: topY, width: stemWidth, height: stemHeight))
                ctx.fillEllipse(in: CGRect(
                    x: x - dotRadius * 0.7, y: topY - dotRadius * 0.7,
                    width: dotRadius * 1.4, height: dotRadius * 1.4
                ))
            }
        }

        for note in notes {
            let noteEndTick = note.startTick + note.duration
            guard noteEndTick >= startTick && note.startTick <= endTick else { continue }

            let x = kbOff + CGFloat(note.startTick) * safePPT - scrollOffset
            let noteWidth = max(3, CGFloat(note.duration) * safePPT)
            let velocityFraction = CGFloat(note.velocity) / 127.0
            let stemHeight = max(5, velocityFraction * maxBarHeight)
            let topY = bottomY - stemHeight

            let isSelected = selectedNoteIDs.contains(note.id)
            let simdColor = colorProvider?(note.channel, note.trackIndex) ?? defaultColor
            let alpha: CGFloat = isSelected ? 0.90 : 0.65
            let color = CGColor(
                red: CGFloat(simdColor.x),
                green: CGFloat(simdColor.y),
                blue: CGFloat(simdColor.z),
                alpha: alpha
            )

            // 1. Vertical stem from bottom up to velocity height
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x - stemWidth * 0.5, y: topY, width: stemWidth, height: stemHeight))

            // 2. Dot at the top of the stem
            ctx.fillEllipse(in: CGRect(
                x: x - dotRadius, y: topY - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            ))

            // 3. Horizontal bar extending right from the dot (note duration)
            ctx.fill(CGRect(x: x, y: topY - hBarHeight * 0.5, width: noteWidth, height: hBarHeight))
        }

        // Playhead is rendered via playheadLayer (CALayer) for 60fps smoothness

        // Velocity curve painting line preview
        if isLinePainting {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: lineStartPoint)
            ctx.addLine(to: lineEndPoint)
            ctx.strokePath()
        }

        ctx.restoreGState()  // restore clip from keyboard offset
    }

    // MARK: - Mouse Editing

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Alt+click: start velocity curve painting
        if event.modifierFlags.contains(.option) {
            isLinePainting = true
            lineStartPoint = location
            lineEndPoint = location
            setNeedsDisplay(bounds)
            return
        }

        isDragPainting = false
        dragPaintChanges = []
        lastDragPaintPoint = location
        lastAppliedVelocityByNoteID = [:]

        if let note = noteAtPoint(location) {
            dragNoteID = note.id
            applyVelocity(at: location, for: note.id, recordForBatch: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if isLinePainting {
            lineEndPoint = location
            setNeedsDisplay(bounds)
            return
        }

        guard dragNoteID != nil else { return }

        let previousPoint = lastDragPaintPoint
        let targets = velocityStrokeTargets(from: previousPoint, to: location)

        if targets.isEmpty, let dragNoteID, abs((previousPoint?.x ?? location.x) - location.x) < 4 {
            // Pure vertical drags should still adjust the originally clicked bar.
            applyVelocity(at: location, for: dragNoteID)
        } else {
            for target in targets {
                let syntheticPoint = NSPoint(x: target.stemX, y: target.y)
                applyVelocity(at: syntheticPoint, for: target.note.id)
            }
        }

        lastDragPaintPoint = location
    }

    override func mouseUp(with event: NSEvent) {
        if isLinePainting {
            applyVelocityCurve()
            isLinePainting = false
            setNeedsDisplay(bounds)
            return
        }
        // If we painted multiple notes during the drag, commit as a batch
        // so it's a single undo step.
        if isDragPainting, !dragPaintChanges.isEmpty {
            onVelocityBatchChanged?(dragPaintChanges)
        }
        dragNoteID = nil
        isDragPainting = false
        dragPaintChanges = []
        lastDragPaintPoint = nil
        lastAppliedVelocityByNoteID = [:]
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
        if abs(dx) > 0.1 {
            onHorizontalScroll?(dx)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Apply velocity curve: sets velocity of all notes in the horizontal range
    /// based on linear interpolation between start and end y positions.
    private func applyVelocityCurve() {
        let safePPT = max(pixelsPerTick, 0.000_01)

        let startX = min(lineStartPoint.x, lineEndPoint.x)
        let endX = max(lineStartPoint.x, lineEndPoint.x)
        guard endX - startX > 2 else { return }

        // Determine velocity at start and end of the line
        let startVel = velocityAtY(lineStartPoint.x == startX ? lineStartPoint.y : lineEndPoint.y)
        let endVel = velocityAtY(lineStartPoint.x == startX ? lineEndPoint.y : lineStartPoint.y)

        var changes: [(UUID, Int)] = []

        for note in notes {
            let noteX = keyboardOffset + CGFloat(note.startTick) * safePPT - scrollOffset
            guard noteX >= startX - 2 && noteX <= endX + 2 else { continue }

            // Interpolate velocity based on x position
            let t = (endX > startX) ? (noteX - startX) / (endX - startX) : 0.5
            let vel = Int((Double(startVel) + t * Double(endVel - startVel)).rounded())
            let clamped = max(1, min(127, vel))
            changes.append((note.id, clamped))
        }

        if !changes.isEmpty {
            onVelocityBatchChanged?(changes)
        }
    }

    private func velocityAtY(_ y: CGFloat) -> Int {
        let height = bounds.height
        let maxBarHeight = height - 8
        let fraction = max(0, min(1, (height - y - 4) / maxBarHeight))
        return max(1, min(127, Int((fraction * 127).rounded())))
    }

    private func applyVelocity(at point: NSPoint, for noteID: UUID, recordForBatch: Bool = true) {
        let newVelocity = velocityAtY(point.y)
        guard lastAppliedVelocityByNoteID[noteID] != newVelocity else { return }

        lastAppliedVelocityByNoteID[noteID] = newVelocity
        if let index = notes.firstIndex(where: { $0.id == noteID }) {
            notes[index].velocity = newVelocity
        } else {
            setNeedsDisplay(bounds)
        }
        onVelocityChanged?(noteID, newVelocity)

        guard recordForBatch else { return }
        isDragPainting = true
        if let existing = dragPaintChanges.firstIndex(where: { $0.0 == noteID }) {
            dragPaintChanges[existing].1 = newVelocity
        } else {
            dragPaintChanges.append((noteID, newVelocity))
        }
    }

    private func stemX(for note: PianoRollNote) -> CGFloat {
        let safePPT = max(pixelsPerTick, 0.000_01)
        return keyboardOffset + CGFloat(note.startTick) * safePPT - scrollOffset
    }

    private func velocityStrokeTargets(
        from startPoint: NSPoint?,
        to endPoint: NSPoint
    ) -> [(note: PianoRollNote, stemX: CGFloat, y: CGFloat)] {
        guard let startPoint else {
            return noteAtStem(nearX: endPoint.x).map { [($0.note, $0.stemX, endPoint.y)] } ?? []
        }

        let startX = startPoint.x
        let endX = endPoint.x
        let minX = min(startX, endX) - 5
        let maxX = max(startX, endX) + 5

        var targets: [(note: PianoRollNote, stemX: CGFloat, y: CGFloat)] = []
        for note in notes {
            let x = stemX(for: note)
            guard x >= minX && x <= maxX else { continue }
            let t = abs(endX - startX) > 0.5
                ? max(0, min(1, (x - startX) / (endX - startX)))
                : 1
            let y = startPoint.y + (endPoint.y - startPoint.y) * t
            targets.append((note, x, y))
        }

        if targets.isEmpty,
           let nearest = noteAtStem(nearX: endPoint.x) {
            targets.append((nearest.note, nearest.stemX, endPoint.y))
        }

        if endX < startX {
            targets.sort { $0.stemX > $1.stemX }
        } else {
            targets.sort { $0.stemX < $1.stemX }
        }
        return targets
    }

    private func noteAtStem(nearX pointX: CGFloat) -> (note: PianoRollNote, stemX: CGFloat)? {
        let tolerance: CGFloat = 8
        var best: (note: PianoRollNote, stemX: CGFloat, distance: CGFloat)?

        for note in notes {
            let x = stemX(for: note)
            let distance = abs(pointX - x)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance {
                best = (note, x, distance)
            }
        }

        guard let best else { return nil }
        return (best.note, best.stemX)
    }

    private func noteAtPoint(_ point: NSPoint) -> PianoRollNote? {
        let safePPT = max(pixelsPerTick, 0.000_01)
        let height = bounds.height
        let maxBarHeight = height - 8
        let dotRadius: CGFloat = 3.0

        // Find the note whose dot/stem is closest to the click point.
        // Prioritize proximity to the dot (top of stem) over just being in the column.
        var bestNote: PianoRollNote?
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for note in notes {
            let x = keyboardOffset + CGFloat(note.startTick) * safePPT - scrollOffset
            let noteWidth = max(6, CGFloat(note.duration) * safePPT)
            let velocityFraction = CGFloat(note.velocity) / 127.0
            let stemHeight = max(5, velocityFraction * maxBarHeight)
            let bottomY = height - 4
            let topY = bottomY - stemHeight

            // Hit test: must be within the horizontal extent of this note
            // (stem x ± generous zone, or within the horizontal bar)
            let hitZone: CGFloat = max(dotRadius + 4, noteWidth)
            guard point.x >= x - dotRadius - 4 && point.x <= x + hitZone else { continue }

            // Distance from click to the dot center at (x, topY)
            let dx = point.x - x
            let dy = point.y - topY
            let dist = sqrt(dx * dx + dy * dy)

            if dist < bestDist {
                bestDist = dist
                bestNote = note
            }
        }
        // Don't match if click is far from any note's dot/stem
        guard bestDist < 30 else { return nil }
        return bestNote
    }

    // MARK: - Selective Corner Rounding

    /// Builds a CGPath with only the specified corners rounded.
    /// Uses CACornerMask constants:
    ///   .layerMinXMinYCorner = top-left, .layerMaxXMinYCorner = top-right,
    ///   .layerMinXMaxYCorner = bottom-left, .layerMaxXMaxYCorner = bottom-right
    static func pathWithSelectiveCorners(_ rect: CGRect, radius: CGFloat, corners: CACornerMask) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let path = CGMutablePath()

        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY

        // NOTE: These views use isFlipped = true, so minY is TOP, maxY is BOTTOM.
        // CACornerMask names refer to the visual position, but in a flipped coordinate
        // system the Y axis is inverted relative to layer conventions.
        // layerMinXMinYCorner = top-left visually (but minY in flipped = top)
        // layerMinXMaxYCorner = bottom-left visually (maxY in flipped = bottom)
        let tl = corners.contains(.layerMinXMinYCorner) ? r : 0
        let tr = corners.contains(.layerMaxXMinYCorner) ? r : 0
        let bl = corners.contains(.layerMinXMaxYCorner) ? r : 0
        let br = corners.contains(.layerMaxXMaxYCorner) ? r : 0

        // Start at top-left, after the top-left corner arc
        path.move(to: CGPoint(x: minX + tl, y: minY))

        // Top edge → top-right corner
        path.addLine(to: CGPoint(x: maxX - tr, y: minY))
        if tr > 0 {
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY),
                        tangent2End: CGPoint(x: maxX, y: minY + tr), radius: tr)
        } else {
            path.addLine(to: CGPoint(x: maxX, y: minY))
        }

        // Right edge → bottom-right corner
        path.addLine(to: CGPoint(x: maxX, y: maxY - br))
        if br > 0 {
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY),
                        tangent2End: CGPoint(x: maxX - br, y: maxY), radius: br)
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        }

        // Bottom edge → bottom-left corner
        path.addLine(to: CGPoint(x: minX + bl, y: maxY))
        if bl > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY),
                        tangent2End: CGPoint(x: minX, y: maxY - bl), radius: bl)
        } else {
            path.addLine(to: CGPoint(x: minX, y: maxY))
        }

        // Left edge → top-left corner
        path.addLine(to: CGPoint(x: minX, y: minY + tl))
        if tl > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: minY),
                        tangent2End: CGPoint(x: minX + tl, y: minY), radius: tl)
        } else {
            path.addLine(to: CGPoint(x: minX, y: minY))
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - TempoLaneView

/// CoreGraphics-rendered tempo lane showing tempo automation curve.
/// Sits below the velocity lane, horizontally synced with the scroll offset.
@available(macOS 26.0, *)
@MainActor
final class TempoLaneView: NSView {

    var tempoEvents: [TempoPoint] = [] { didSet { guard tempoEvents != oldValue else { return }; setNeedsDisplay(bounds) } }
    private var scrollRedrawScheduled = false
    var scrollOffset: CGFloat = 0 { didSet { guard scrollOffset != oldValue else { return }; scheduleScrollRedraw(); updatePlayheadLayerPosition() } }
    private func scheduleScrollRedraw() {
        guard !scrollRedrawScheduled else { return }
        scrollRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrollRedrawScheduled else { return }
            self.scrollRedrawScheduled = false
            self.setNeedsDisplay(self.bounds)
        }
    }
    var pixelsPerTick: CGFloat = 0.267 { didSet { guard pixelsPerTick != oldValue else { return }; setNeedsDisplay(bounds); updatePlayheadLayerPosition() } }
    var ticksPerQuarter: Int = 480 { didSet { guard ticksPerQuarter != oldValue else { return }; setNeedsDisplay(bounds) } }
    var gridWidth: CGFloat = 5000 { didSet { guard gridWidth != oldValue else { return }; setNeedsDisplay(bounds) } }
    var playheadTick: Int = 0 { didSet { guard playheadTick != oldValue else { return }; updatePlayheadLayerPosition() } }
    /// Horizontal offset where the scroll content begins (keyboard strip width).
    var keyboardOffset: CGFloat = 96 { didSet { guard keyboardOffset != oldValue else { return }; setNeedsDisplay(bounds); updatePlayheadLayerPosition() } }

    /// Which corners to round. Use CACornerMask values.
    var roundedCorners: CACornerMask = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Active piano roll tool. Mouse editing is only active when this is `.paintbrush`.
    var currentTool: PianoRollToolChoice = .select

    /// Frozen BPM range during a paint stroke — keeps Y axis stable so painting
    /// produces a clean ramp instead of jittering from dynamic rescaling.
    private var frozenRange: (minBPM: Double, maxBPM: Double, range: Double)?

    /// Called when the user scrolls horizontally in the lane.
    var onHorizontalScroll: ((CGFloat) -> Void)?

    /// Called when the user drags a tempo marker. Params: (eventIndex, newBPM).
    var onTempoChanged: ((Int, Double) -> Void)?

    /// Called when the user double-clicks to add a tempo point. Params: (tick, bpm).
    var onTempoAdded: ((Int, Double) -> Void)?

    /// Called when the user right-clicks an existing marker to delete it. Param: eventIndex.
    var onTempoDeleted: ((Int) -> Void)?

    /// Paintbrush callback: sets BPM at the given beat tick and clears all events
    /// between that tick and the next beat so the painted value fills the whole beat.
    /// Params: (snappedTick, beatTicks, bpm).
    var onTempoPainted: ((Int, Int, Double) -> Void)?

    /// Called after a tempo drag/paint stroke so the controller can collapse
    /// redundant points once, instead of simplifying on every mouse move.
    var onTempoPaintFinished: (() -> Void)?

    // Paintbrush paint state — last beat tick painted to avoid duplicate events during drag
    private var lastPaintedTick: Int = -1

    /// CALayer overlay for the playhead line — repositioned at display refresh rate without full redraws.
    private lazy var playheadLayer: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        l.zPosition = 100
        return l
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playheadLayer)
    }

    private func updatePlayheadLayerPosition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x = keyboardOffset + CGFloat(playheadTick) * pixelsPerTick - scrollOffset
        playheadLayer.frame = CGRect(x: x - 0.5, y: 0, width: 1, height: bounds.height)
        playheadLayer.isHidden = x < -2 || x > bounds.width + 2
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let width = bounds.width
        let height = bounds.height
        let cr: CGFloat = 10

        // Build per-corner path
        let bgPath = VelocityLaneView.pathWithSelectiveCorners(bounds, radius: cr, corners: roundedCorners)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor(red: 0.14, green: 0.15, blue: 0.16, alpha: 0.90).cgColor)
        ctx.fillPath()

        // Border
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let borderPath = VelocityLaneView.pathWithSelectiveCorners(borderRect, radius: cr, corners: roundedCorners)
        ctx.addPath(borderPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let safePPT = max(pixelsPerTick, 0.000_01)
        let kbOff = keyboardOffset

        // Clip to the content area (right of keyboard offset) so tempo
        // bars and grid lines never bleed into the label/keyboard zone.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: kbOff, y: 0, width: width - kbOff, height: height))

        // Grid lines (bars)
        let beatTicks = max(1, ticksPerQuarter)
        let barTicks = beatTicks * 4
        let startTick = max(0, Int(scrollOffset / safePPT) - barTicks)
        let endTick = Int((scrollOffset + width) / safePPT) + barTicks

        // Bar lines
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1.0)
        var tick = (startTick / barTicks) * barTicks
        while tick <= endTick {
            let x = kbOff + CGFloat(tick) * safePPT - scrollOffset
            if x >= -1 && x <= width + 1 {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: height))
            }
            tick += barTicks
        }
        ctx.strokePath()

        // Beat lines
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        ctx.setLineWidth(0.7)
        tick = (startTick / beatTicks) * beatTicks
        while tick <= endTick {
            if tick % barTicks != 0 {
                let x = kbOff + CGFloat(tick) * safePPT - scrollOffset
                if x >= -1 && x <= width + 1 {
                    ctx.move(to: CGPoint(x: x, y: 0))
                    ctx.addLine(to: CGPoint(x: x, y: height))
                }
            }
            tick += beatTicks
        }
        ctx.strokePath()

        // Tempo range (uses frozenRange during painting for Y axis stability)
        guard !tempoEvents.isEmpty else { return }
        let (minBPM, _, bpmRange) = tempoRange

        let padding: CGFloat = 6
        let graphHeight = height - padding * 2
        let bottomY = padding + graphHeight  // y-coordinate of BPM = minBPM

        func yForBPM(_ bpm: Double) -> CGFloat {
            let fraction = CGFloat((bpm - minBPM) / bpmRange)
            return padding + graphHeight * (1 - fraction)
        }

        // Draw staircase filled bars (FL Studio discrete step style).
        // Each event holds its BPM until the next event — no interpolation.
        let fillColor = NSColor(red: 0.19, green: 0.77, blue: 0.98, alpha: 0.30)
        let topEdgeColor = NSColor(red: 0.19, green: 0.77, blue: 0.98, alpha: 0.85)
        let sorted = tempoEvents.sorted { $0.tick < $1.tick }
        let endX = kbOff + gridWidth - scrollOffset

        // Filled bars
        ctx.setFillColor(fillColor.cgColor)
        for i in sorted.indices {
            let event = sorted[i]
            let x0 = kbOff + CGFloat(event.tick) * safePPT - scrollOffset
            let x1 = (i + 1 < sorted.count)
                ? kbOff + CGFloat(sorted[i + 1].tick) * safePPT - scrollOffset
                : endX
            let topY = yForBPM(event.bpm)

            // Skip bars entirely off-screen
            if x1 < -1 || x0 > width + 1 { continue }

            let barRect = CGRect(x: x0, y: topY, width: x1 - x0, height: bottomY - topY)
            ctx.fill(barRect)
        }

        // Top edges (bright line at BPM level for each step)
        ctx.setStrokeColor(topEdgeColor.cgColor)
        ctx.setLineWidth(1.5)
        for i in sorted.indices {
            let event = sorted[i]
            let x0 = kbOff + CGFloat(event.tick) * safePPT - scrollOffset
            let x1 = (i + 1 < sorted.count)
                ? kbOff + CGFloat(sorted[i + 1].tick) * safePPT - scrollOffset
                : endX
            let topY = yForBPM(event.bpm)

            if x1 < -1 || x0 > width + 1 { continue }

            // Horizontal line at BPM level
            ctx.move(to: CGPoint(x: max(x0, -1), y: topY))
            ctx.addLine(to: CGPoint(x: min(x1, width + 1), y: topY))

            // Vertical riser to next step (if BPM changes)
            if i + 1 < sorted.count {
                let nextY = yForBPM(sorted[i + 1].bpm)
                if abs(nextY - topY) > 0.5 && x1 >= -1 && x1 <= width + 1 {
                    ctx.addLine(to: CGPoint(x: x1, y: nextY))
                }
            }
        }
        ctx.strokePath()

        ctx.restoreGState()  // restore clip from keyboard offset

        // Playhead is rendered via playheadLayer (CALayer) for 60fps smoothness
    }

    // MARK: - Tempo Range Helpers (shared between draw and mouse)

    /// Dynamic BPM range computed from current events.
    private var dynamicTempoRange: (minBPM: Double, maxBPM: Double, range: Double) {
        guard !tempoEvents.isEmpty else { return (115, 125, 10) }
        let minBPM = max(20, tempoEvents.map(\.bpm).min() ?? 120) - 5
        let maxBPM = min(300, tempoEvents.map(\.bpm).max() ?? 120) + 5
        return (minBPM, maxBPM, max(1, maxBPM - minBPM))
    }

    /// Effective range: frozen during a paint stroke, dynamic otherwise.
    private var tempoRange: (minBPM: Double, maxBPM: Double, range: Double) {
        frozenRange ?? dynamicTempoRange
    }

    private func bpmForY(_ y: CGFloat) -> Double {
        let height = bounds.height
        let padding: CGFloat = 6
        let graphHeight = height - padding * 2
        let (minBPM, _, range) = tempoRange
        let fraction = max(0, min(1, (height - y - padding) / graphHeight))
        return minBPM + fraction * range
    }

    // MARK: - Mouse Editing (bar-based, FL Studio discrete step style)

    /// Index of the tempo bar being dragged with the select tool.
    private var selectDragBarIndex: Int?

    /// Find which bar (event index) contains the given x coordinate.
    /// Each bar spans from its event tick to the next event tick.
    private func barIndex(at x: CGFloat) -> Int? {
        let safePPT = max(pixelsPerTick, 0.000_01)
        let sorted = tempoEvents.sorted { $0.tick < $1.tick }
        guard !sorted.isEmpty else { return nil }

        for i in sorted.indices {
            let x0 = keyboardOffset + CGFloat(sorted[i].tick) * safePPT - scrollOffset
            let x1: CGFloat
            if i + 1 < sorted.count {
                x1 = keyboardOffset + CGFloat(sorted[i + 1].tick) * safePPT - scrollOffset
            } else {
                x1 = keyboardOffset + gridWidth - scrollOffset
            }
            if x >= x0 && x < x1 {
                // Map back to the unsorted index in tempoEvents (match by tick
                // only — each tick should be unique, and tick+bpm matching can
                // return the wrong index when two events share both values).
                let matchTick = sorted[i].tick
                return tempoEvents.firstIndex(where: { $0.tick == matchTick })
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        lastPaintedTick = -1
        // Freeze the BPM range at the start of every tempo stroke so dragging
        // left/right follows the user's mouse path instead of rescaling the Y
        // axis while new points are created.
        frozenRange = dynamicTempoRange

        if currentTool == .paintbrush {
            paintAt(event: event, quantumTicks: max(1, ticksPerQuarter))
            return
        }

        // Select/draw tool: paint tempo under the cursor. This avoids the old
        // behavior where the drag locked to one bar and could only move up/down.
        if currentTool == .select || currentTool == .draw {
            paintAt(event: event, quantumTicks: fineTempoPaintQuantumTicks)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if currentTool == .paintbrush {
            paintAt(event: event, quantumTicks: max(1, ticksPerQuarter))
            return
        }

        if currentTool == .select || currentTool == .draw {
            paintAt(event: event, quantumTicks: fineTempoPaintQuantumTicks)
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastPaintedTick = -1
        selectDragBarIndex = nil
        frozenRange = nil
        onTempoPaintFinished?()
        // Redraw with dynamic range now that painting/dragging is done
        setNeedsDisplay(bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
        if abs(dx) > 0.1 {
            onHorizontalScroll?(dx)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        // Right-click on any bar → delete it (if not the only one)
        if let index = barIndex(at: location.x), tempoEvents.count > 1 {
            onTempoDeleted?(index)
        }
    }

    /// Inserts or updates a tempo event at the beat-snapped tick under the cursor.
    /// Fires only when the cursor moves to a new beat, so dragging paints a series
    /// of new discrete steps — FL Studio paintbrush style.
    /// Clears sub-beat events between this beat and the next so the painted BPM
    /// fills the entire beat duration.
    private var fineTempoPaintQuantumTicks: Int {
        max(1, ticksPerQuarter / 4)
    }

    private func paintAt(event: NSEvent, quantumTicks: Int) {
        let location = convert(event.locationInWindow, from: nil)
        let safePPT = max(pixelsPerTick, 0.000_01)
        let paintTicks = max(1, quantumTicks)

        // Snap to a fixed grid so the stroke follows horizontal mouse movement
        // without creating an unbounded number of tempo points.
        let rawTick = max(0, Int(((location.x - keyboardOffset + scrollOffset) / safePPT).rounded()))
        let snappedTick = (rawTick / paintTicks) * paintTicks

        // Only fire once per grid slot to avoid flooding the store with duplicates.
        guard snappedTick != lastPaintedTick else { return }
        lastPaintedTick = snappedTick

        let bpm = max(20, min(300, bpmForY(location.y)))

        // Use the atomic paint callback: sets BPM at snappedTick and clears
        // all events between snappedTick and snappedTick+paintTicks.
        onTempoPainted?(snappedTick, paintTicks, bpm)
    }
}

// MARK: - LyricsLaneView

/// CoreGraphics-rendered lyrics lane showing syllable text aligned to vocal MIDI notes.
/// Sits between the piano roll editor and the velocity lane, horizontally synced
/// with the scroll offset. Supports multiple vocal tracks as stacked rows.
@available(macOS 26.0, *)
@MainActor
final class LyricsLaneView: NSView {

    // MARK: - Data Properties

    /// Vocal notes only (filtered by caller to vocal tracks).
    var notes: [PianoRollNote] = [] { didSet { guard notes != oldValue else { return }; setNeedsDisplay(bounds) } }

    /// Ordered list of vocal track keys to display as rows.
    var vocalTrackKeys: [String] = [] { didSet { guard vocalTrackKeys != oldValue else { return }; setNeedsDisplay(bounds) } }

    /// trackKey → character/display name for the keyboard offset label area.
    var trackLabels: [String: String] = [:] { didSet { setNeedsDisplay(bounds) } }

    /// trackKey → track indices, used for filtering notes per row.
    var trackIndicesByKey: [String: Set<Int>] = [:] { didSet { setNeedsDisplay(bounds) } }

    /// trackKey → color (NSColor) for multi-row track label tinting.
    var trackColors: [String: NSColor] = [:] { didSet { setNeedsDisplay(bounds) } }

    /// Standalone LyricCue objects (spoken word, annotations, stage directions).
    /// @deprecated — kept for backward compat; prefer timedLyricLines from embedded tags.
    var lyricCues: [LyricCue] = [] { didSet { guard lyricCues != oldValue else { return }; setNeedsDisplay(bounds) } }

    /// Timed lyric lines parsed from embedded `[t:TICK]` tags in the libretto text.
    /// Each entry has a tick position, the display text, and the line index in the source.
    var timedLyricLines: [(tick: Int, line: String, lineIndex: Int)] = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    /// ticksPerQuarter (kept for backward compat; no longer used for grid drawing).
    var ticksPerQuarter: Int = 480

    // MARK: - Scroll/Zoom Sync

    private var scrollRedrawScheduled = false
    var scrollOffset: CGFloat = 0 {
        didSet {
            guard scrollOffset != oldValue else { return }
            commitEditing() // Dismiss inline editor — its pixel position is now stale
            scheduleScrollRedraw()
            updatePlayheadLayerPosition()
        }
    }
    private func scheduleScrollRedraw() {
        guard !scrollRedrawScheduled else { return }
        scrollRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrollRedrawScheduled else { return }
            self.scrollRedrawScheduled = false
            self.setNeedsDisplay(self.bounds)
        }
    }
    var pixelsPerTick: CGFloat = 0.267 {
        didSet {
            guard pixelsPerTick != oldValue else { return }
            commitEditing() // Dismiss inline editor — zoom changed its position
            setNeedsDisplay(bounds)
            updatePlayheadLayerPosition()
        }
    }
    var gridWidth: CGFloat = 5000 { didSet { guard gridWidth != oldValue else { return }; setNeedsDisplay(bounds) } }
    var playheadTick: Int = 0 { didSet { guard playheadTick != oldValue else { return }; updatePlayheadLayerPosition() } }
    var colorProvider: ((Int, Int) -> SIMD4<Float>)?

    /// Horizontal offset where the scroll content begins (keyboard strip width).
    var keyboardOffset: CGFloat = 96 { didSet { guard keyboardOffset != oldValue else { return }; setNeedsDisplay(bounds); updatePlayheadLayerPosition() } }

    /// Which corners to round. Use CACornerMask values.
    var roundedCorners: CACornerMask = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    // MARK: - Preview Mode

    /// When non-nil, the lane is in "AI preview" mode. Maps noteID → suggested syllable.
    /// Preview syllables render with dashed outline and yellow tint.
    var previewAlignments: [UUID: String]? { didSet { setNeedsDisplay(bounds) } }

    // MARK: - Callbacks

    /// Called when the user edits a syllable via inline text field. Params: (noteID, newSyllable or nil to clear).
    var onSyllableChanged: ((UUID, String?) -> Void)?

    /// Called when user clicks "Auto-Align" in the header.
    var onAutoAlignRequested: (() -> Void)?

    /// Called when user accepts AI preview alignments.
    var onPreviewAccepted: (() -> Void)?

    /// Called when user rejects AI preview alignments.
    var onPreviewRejected: (() -> Void)?

    /// Callback for keyboard events not handled by LyricsLaneView.
    /// Returns true if the event was consumed.
    var onKeyDown: ((NSEvent) -> Bool)?

    /// Called when user selects a split point from the popup menu.
    /// Params: (noteID, characterIndex). Controller should split the syllable at that position.
    var onSyllableSplit: ((UUID, Int) -> Void)?

    /// Called when user Option+Shift-clicks to join a syllable with the next note's syllable.
    /// Params: (noteID). Controller should merge this syllable with the next.
    var onSyllableJoin: ((UUID) -> Void)?

    /// Called once when a normal-mode drag begins (for undo capture).
    var onSyllableDragStarted: (() -> Void)?

    /// Called when user drags a syllable in normal mode.
    /// Params: (sourceNoteID, targetNoteID, shiftMode).
    /// - shiftMode=false: swap source/target syllables.
    /// - shiftMode=true: drag this syllable and following assignments as a block.
    var onSyllableDragged: ((UUID, UUID, Bool) -> Void)?

    // MARK: - Editing State

    /// The note currently being text-edited.
    private var editingNoteID: UUID?

    /// The inline text field for syllable editing.
    private var editingTextField: NSTextField?

    /// Currently selected note ID (for keyboard navigation).
    private var selectedNoteID: UUID?

    // MARK: - Preview Drag State

    /// The note ID being dragged in preview mode.
    private var dragNoteID: UUID?

    /// Whether shift was held when the drag started (drags this + all following).
    private var dragShiftMode = false

    /// The note ID that was under the cursor at the last drag position.
    private var dragLastTargetID: UUID?

    /// Ordered list of note IDs in the preview, sorted by tick.
    private var previewNoteOrder: [UUID] = []

    /// Called when preview alignments are rearranged by dragging.
    /// Provides the updated preview dictionary.
    var onPreviewAlignmentsChanged: (([UUID: String]) -> Void)?

    /// Called when the user scrolls horizontally in the lane.
    /// Params: (deltaX in points). Controller should update the editor scroll view.
    var onHorizontalScroll: ((CGFloat) -> Void)?

    /// Called when user clicks a timed lyric line to move it to a new tick position.
    /// Params: (lineIndex in source text, new tick). Controller writes back via LyricTimingParser.setTiming.
    var onTimedLyricLineMoved: ((Int, Int) -> Void)?

    /// Called when user right-clicks a timed lyric line to remove its timing tag.
    /// Params: (lineIndex in source text). Controller writes back via LyricTimingParser.removeTiming.
    var onTimedLyricLineRemoved: ((Int) -> Void)?

    // MARK: - Playhead Layer

    /// CALayer overlay for the playhead line — repositioned at display refresh rate without full redraws.
    private lazy var playheadLayer: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        l.zPosition = 100
        return l
    }()

    // MARK: - CTLine Cache

    private var ctLineCache: [String: CTLine] = [:]
    private var lastCacheFlushNoteCount = 0

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playheadLayer)
    }

    private func updatePlayheadLayerPosition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x = keyboardOffset + CGFloat(playheadTick) * pixelsPerTick - scrollOffset
        playheadLayer.frame = CGRect(x: x - 0.5, y: 0, width: 1, height: bounds.height)
        playheadLayer.isHidden = x < -2 || x > bounds.width + 2
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let width = bounds.width
        let height = bounds.height
        let cr: CGFloat = 10

        // Rounded background
        let bgPath = VelocityLaneView.pathWithSelectiveCorners(bounds, radius: cr, corners: roundedCorners)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor(red: 0.14, green: 0.15, blue: 0.16, alpha: 0.90).cgColor)
        ctx.fillPath()

        // Border
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let borderPath = VelocityLaneView.pathWithSelectiveCorners(borderRect, radius: cr, corners: roundedCorners)
        ctx.addPath(borderPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let safePPT = max(pixelsPerTick, 0.000_01)
        let kbOff = keyboardOffset

        // Visible tick range
        let startTick = max(0, Int(scrollOffset / safePPT) - 100)
        let endTick = Int((scrollOffset + width) / safePPT) + 100

        // Determine row layout: one row per vocal track, or single row if none
        let trackCount = max(1, vocalTrackKeys.count)
        let rowHeight = max(18, height / CGFloat(trackCount))

        // Flush CTLine cache if note count changed significantly
        if abs(notes.count - lastCacheFlushNoteCount) > 50 {
            ctLineCache.removeAll()
            lastCacheFlushNoteCount = notes.count
        }

        // Draw horizontal row dividers if multiple vocal tracks
        if trackCount > 1 {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(0.5)
            for i in 1..<trackCount {
                let y = CGFloat(i) * rowHeight
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: width, y: y))
            }
            ctx.strokePath()
        }

        // Draw track labels in keyboard offset area with per-track colors
        if trackCount > 1 {
            let labelFont: NSFont = NSFont(name: "Menlo", size: 9)
                ?? NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            for (i, key) in vocalTrackKeys.enumerated() {
                let label = trackLabels[key] ?? key
                let rowY = CGFloat(i) * rowHeight

                // Use track color if available, otherwise default white
                let trackColor = trackColors[key] ?? NSColor.white.withAlphaComponent(0.55)
                let labelColor = trackColor.withAlphaComponent(0.75)

                // Draw a subtle color strip at the left edge of the row
                ctx.setFillColor(trackColor.withAlphaComponent(0.12).cgColor)
                ctx.fill(CGRect(x: 0, y: rowY, width: 3, height: rowHeight))

                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont,
                    .foregroundColor: labelColor,
                ]
                let labelStr = NSAttributedString(string: label, attributes: labelAttrs)
                let line = CTLineCreateWithAttributedString(labelStr)
                let textBounds = CTLineGetBoundsWithOptions(line, [])
                let labelX: CGFloat = 6
                let labelY = rowY + (rowHeight - textBounds.height) / 2

                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: labelX, y: labelY + textBounds.height)
                ctx.scaleBy(x: 1, y: -1)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        // Clip all note content drawing to the scrollable area (prevents text clumping at keyboard edge)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: kbOff, y: 0, width: width - kbOff, height: height))

        // Draw note slot indicators for every vocal note (visible drag/edit targets)
        for note in notes {
            let noteEndTick = note.startTick + note.duration
            guard noteEndTick >= startTick && note.startTick <= endTick else { continue }

            let slotRow: Int
            if trackCount > 1 {
                slotRow = vocalTrackKeys.firstIndex(where: { key in
                    trackIndicesByKey[key]?.contains(note.trackIndex) == true
                }) ?? 0
            } else {
                slotRow = 0
            }
            let slotRowY = CGFloat(slotRow) * rowHeight
            let slotX = kbOff + CGFloat(note.startTick) * safePPT - scrollOffset
            let noteWidth = max(4, CGFloat(note.duration) * safePPT)

            // Grey note slot background — mirrors the note blocks from the piano roll above
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
            ctx.fill(CGRect(x: slotX, y: slotRowY + 1, width: noteWidth, height: rowHeight - 2))
        }

        // Draw syllable text at note positions
        let syllableFont: NSFont = NSFont(name: "Menlo", size: 11)
            ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let normalColor = NSColor.white.withAlphaComponent(0.85)
        let previewColor = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.5, alpha: 0.60)
        let melismaColor = NSColor.white.withAlphaComponent(0.35)

        for note in notes {
            let noteEndTick = note.startTick + note.duration
            guard noteEndTick >= startTick && note.startTick <= endTick else { continue }

            // Determine which row this note belongs to
            let rowIndex: Int
            if trackCount > 1 {
                // Find the vocal track key for this note's trackIndex
                rowIndex = vocalTrackKeys.firstIndex(where: { key in
                    trackIndicesByKey[key]?.contains(note.trackIndex) == true
                }) ?? 0
            } else {
                rowIndex = 0
            }

            let rowY = CGFloat(rowIndex) * rowHeight

            // Get the syllable text: preview mode overrides committed text
            let syllable: String?
            let isPreview: Bool
            if let previews = previewAlignments {
                syllable = previews[note.id] ?? note.lyricSyllable
                isPreview = previews[note.id] != nil
            } else {
                syllable = note.lyricSyllable
                isPreview = false
            }

            guard let text = syllable, !text.isEmpty else { continue }

            let x = kbOff + CGFloat(note.startTick) * safePPT - scrollOffset
            guard x < width + 50 else { continue }

            // Choose style based on preview/melisma/normal
            let isMelisma = text == "_"
            let textColor: NSColor
            if isMelisma {
                textColor = melismaColor
            } else if isPreview {
                textColor = previewColor
            } else {
                textColor = normalColor
            }

            if isMelisma {
                // Draw extender line for melisma
                let lineY = rowY + rowHeight / 2
                let noteWidth = CGFloat(note.duration) * safePPT
                ctx.setStrokeColor(melismaColor.cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [3, 2])
                ctx.move(to: CGPoint(x: x + 2, y: lineY))
                ctx.addLine(to: CGPoint(x: x + noteWidth - 2, y: lineY))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            } else {
                // Draw syllable text
                let cacheKey = "\(text)_\(isPreview ? 1 : 0)"
                let line: CTLine
                if let cached = ctLineCache[cacheKey] {
                    line = cached
                } else {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: syllableFont,
                        .foregroundColor: textColor,
                    ]
                    let attrStr = NSAttributedString(string: text, attributes: attrs)
                    line = CTLineCreateWithAttributedString(attrStr)
                    ctLineCache[cacheKey] = line
                }

                let textBounds = CTLineGetBoundsWithOptions(line, [])
                let textX = x + 2
                let textY = rowY + (rowHeight - textBounds.height) / 2

                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: textX, y: textY + textBounds.height)
                ctx.scaleBy(x: 1, y: -1)
                CTLineDraw(line, ctx)
                ctx.restoreGState()

                // Preview: draw dashed outline around the syllable
                if isPreview {
                    let outlineRect = CGRect(
                        x: x + 1,
                        y: rowY + (rowHeight - textBounds.height) / 2 - 1,
                        width: textBounds.width + 4,
                        height: textBounds.height + 2
                    )
                    ctx.setStrokeColor(previewColor.cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.setLineDash(phase: 0, lengths: [3, 2])
                    ctx.stroke(outlineRect)
                    ctx.setLineDash(phase: 0, lengths: [])
                }

                // Draw hyphen connector if the syllable ends with "-"
                if text.hasSuffix("-") {
                    let hyphenX = x + 2 + textBounds.width + 2
                    let hyphenY = rowY + rowHeight / 2
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.move(to: CGPoint(x: hyphenX, y: hyphenY))
                    ctx.addLine(to: CGPoint(x: hyphenX + 6, y: hyphenY))
                    ctx.strokePath()
                }
            }

            // Highlight selected note
            if note.id == selectedNoteID {
                let noteWidth = max(4, CGFloat(note.duration) * safePPT)
                let selRect = CGRect(x: x, y: rowY + 1, width: noteWidth, height: rowHeight - 2)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(selRect)
            }
        }

        // Draw timed lyric lines from embedded [t:TICK] tags
        if !timedLyricLines.isEmpty {
            let lineFont: NSFont = NSFont(name: "Menlo-Italic", size: 10)
                ?? NSFont(name: "Menlo", size: 10)
                ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let lineColor = NSColor(calibratedRed: 0.65, green: 0.85, blue: 1.0, alpha: 0.55)
            let lineAttrs: [NSAttributedString.Key: Any] = [
                .font: lineFont,
                .foregroundColor: lineColor,
            ]

            for entry in timedLyricLines {
                guard entry.tick >= startTick && entry.tick <= endTick else { continue }
                let x = kbOff + CGFloat(entry.tick) * safePPT - scrollOffset
                guard x < width + 50 && x > kbOff - 200 else { continue }

                let rowY: CGFloat = 0
                let displayText = entry.line.trimmingCharacters(in: .whitespaces)
                guard !displayText.isEmpty else { continue }

                // Draw lyric line text
                let attrStr = NSAttributedString(string: displayText, attributes: lineAttrs)
                let ctLine = CTLineCreateWithAttributedString(attrStr)
                let textBounds = CTLineGetBoundsWithOptions(ctLine, [])
                let textX = x + 2
                let textY = rowY + (rowHeight - textBounds.height) / 2

                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: textX, y: textY + textBounds.height)
                ctx.scaleBy(x: 1, y: -1)
                CTLineDraw(ctLine, ctx)
                ctx.restoreGState()

                // Draw subtle tick marker line above the text
                ctx.setStrokeColor(lineColor.withAlphaComponent(0.25).cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: x, y: rowY))
                ctx.addLine(to: CGPoint(x: x, y: rowY + 4))
                ctx.strokePath()
            }
        } else if !lyricCues.isEmpty {
            // Fallback: draw standalone LyricCue objects (deprecated path)
            let cueFont: NSFont = NSFont(name: "Menlo-Italic", size: 10)
                ?? NSFont(name: "Menlo", size: 10)
                ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let cueColor = NSColor.white.withAlphaComponent(0.40)
            let cueAttrs: [NSAttributedString.Key: Any] = [
                .font: cueFont,
                .foregroundColor: cueColor,
            ]

            for cue in lyricCues {
                guard cue.tick + cue.durationTicks >= startTick && cue.tick <= endTick else { continue }
                let x = kbOff + CGFloat(cue.tick) * safePPT - scrollOffset
                guard x < width + 50 else { continue }

                // Find which row to draw in (match cue trackKey to vocal track)
                let rowIndex: Int
                if trackCount > 1, let idx = vocalTrackKeys.firstIndex(of: cue.trackKey) {
                    rowIndex = idx
                } else {
                    rowIndex = 0
                }
                let rowY = CGFloat(rowIndex) * rowHeight

                // Draw cue text in italic, dimmed
                let cueStr = NSAttributedString(string: cue.text, attributes: cueAttrs)
                let cueLine = CTLineCreateWithAttributedString(cueStr)
                let cueBounds = CTLineGetBoundsWithOptions(cueLine, [])
                let textX = x + 2
                let textY = rowY + (rowHeight - cueBounds.height) / 2

                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: textX, y: textY + cueBounds.height)
                ctx.scaleBy(x: 1, y: -1)
                CTLineDraw(cueLine, ctx)
                ctx.restoreGState()

                // Draw subtle dotted underline to distinguish from note syllables
                let underY = rowY + (rowHeight + cueBounds.height) / 2 + 2
                ctx.setStrokeColor(cueColor.withAlphaComponent(0.25).cgColor)
                ctx.setLineWidth(0.5)
                ctx.setLineDash(phase: 0, lengths: [2, 3])
                ctx.move(to: CGPoint(x: textX, y: underY))
                ctx.addLine(to: CGPoint(x: textX + cueBounds.width, y: underY))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        // Restore clip state (end of scrollable content area clipping)
        ctx.restoreGState()
    }

    // MARK: - Mouse Interaction

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Commit any open inline editor before handling the click.
        // This prevents re-entrant issues from controlTextDidEndEditing.
        if editingNoteID != nil {
            commitEditing()
        }

        // If double-click, open inline editor (only in non-preview mode)
        if event.clickCount == 2 && previewAlignments == nil {
            openInlineEditor(at: location)
            // Note: openInlineEditorForNote() already makes the text field first responder.
            // Do NOT call makeFirstResponder(self) here — that steals focus from the editor.
            return
        }

        let clickedNote = noteAt(location)

        // Option+click: split or join syllable at this note
        if event.modifierFlags.contains(.option), let note = clickedNote {
            if event.modifierFlags.contains(.shift) {
                // Option+Shift+click: join this syllable with the next
                onSyllableJoin?(note.id)
            } else {
                // Option+click: show split point selection menu
                showSplitMenu(for: note, at: location)
            }
            selectedNoteID = note.id
            window?.makeFirstResponder(self)
            setNeedsDisplay(bounds)
            return
        }

        // Initiate drag for notes with syllables (both normal and preview modes)
        if let note = clickedNote {
            let hasSyllable: Bool
            if let previews = previewAlignments {
                hasSyllable = (previews[note.id] ?? note.lyricSyllable).map { !$0.isEmpty } ?? false
            } else {
                hasSyllable = note.lyricSyllable.map { !$0.isEmpty } ?? false
            }

            if hasSyllable {
                dragNoteID = note.id
                dragShiftMode = event.modifierFlags.contains(.shift)
                dragLastTargetID = note.id

                // Build sorted order of ALL vocal notes (drag targets include empty notes)
                previewNoteOrder = notes.sorted { $0.startTick < $1.startTick }.map(\.id)

                // Push undo for normal mode drag
                if previewAlignments == nil {
                    onSyllableDragStarted?()
                }

                selectedNoteID = note.id
                window?.makeFirstResponder(self)
                setNeedsDisplay(bounds)
                return
            }
        }

        // Single click to select
        selectedNoteID = clickedNote?.id

        if clickedNote != nil {
            // Selected a note — become first responder for keyboard navigation
            window?.makeFirstResponder(self)
        }

        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragID = dragNoteID else { return }
        let location = convert(event.locationInWindow, from: nil)

        // Find the note under the cursor
        guard let targetNote = noteAt(location) else { return }
        let targetID = targetNote.id

        // Don't do anything if we haven't moved to a different note
        guard targetID != dragLastTargetID else { return }
        dragLastTargetID = targetID

        // Find positions in the sorted note order (includes ALL vocal notes)
        guard let dragIdx = previewNoteOrder.firstIndex(of: dragID),
              let targetIdx = previewNoteOrder.firstIndex(of: targetID) else { return }
        guard dragIdx != targetIdx else { return }

        if var previews = previewAlignments {
            // Preview mode: rearrange preview assignments
            let offset = targetIdx - dragIdx

            if dragShiftMode {
                // Shift+drag: move this syllable and ALL following syllables by the same offset
                let affectedIDs = Array(previewNoteOrder[dragIdx...])
                let syllables = affectedIDs.compactMap { previews[$0] }

                for id in affectedIDs {
                    previews[id] = nil
                }

                for (i, syllable) in syllables.enumerated() {
                    let newIdx = dragIdx + offset + i
                    if newIdx >= 0 && newIdx < previewNoteOrder.count {
                        previews[previewNoteOrder[newIdx]] = syllable
                    }
                }

                let newDragIdx = dragIdx + offset
                if newDragIdx >= 0 && newDragIdx < previewNoteOrder.count {
                    dragNoteID = previewNoteOrder[newDragIdx]
                    selectedNoteID = dragNoteID
                }
            } else {
                // Normal drag: swap syllables between source and target
                let dragSyllable = previews[dragID]
                let targetSyllable = previews[targetID]
                previews[dragID] = targetSyllable
                previews[targetID] = dragSyllable

                dragNoteID = targetID
                selectedNoteID = targetID
            }

            previewAlignments = previews
            onPreviewAlignmentsChanged?(previews)
        } else {
            // Normal mode: swap syllables via controller callback
            onSyllableDragged?(dragID, targetID, dragShiftMode)
            dragNoteID = targetID
            selectedNoteID = targetID
        }

        dragLastTargetID = targetID
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        dragNoteID = nil
        dragShiftMode = false
        dragLastTargetID = nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward horizontal scroll to the main editor scroll view
        let dx = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
        if abs(dx) > 0.1 {
            onHorizontalScroll?(dx)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Right-click on a timed lyric line: show context menu to remove timing
        if let entry = timedLyricLineAt(location) {
            let menu = NSMenu(title: "Lyric Line")
            menu.autoenablesItems = false

            let removeItem = NSMenuItem(
                title: "Remove Timing",
                action: #selector(removeTimedLyricLineClicked(_:)),
                keyEquivalent: ""
            )
            removeItem.target = self
            removeItem.tag = entry.lineIndex
            removeItem.isEnabled = true
            menu.addItem(removeItem)

            menu.popUp(positioning: nil, at: location, in: self)
            return
        }

        super.rightMouseDown(with: event)
    }

    @objc private func removeTimedLyricLineClicked(_ sender: NSMenuItem) {
        onTimedLyricLineRemoved?(sender.tag)
    }

    override func keyDown(with event: NSEvent) {
        // Always forward global shortcuts (spacebar, etc.) to the controller first
        if let handler = onKeyDown {
            // Lyrics-specific keys only when editing/selected
            let isLyricsKey: Bool
            if selectedNoteID != nil || editingNoteID != nil {
                switch event.keyCode {
                case 48, 51, 53, 36, 123, 124: isLyricsKey = true
                default: isLyricsKey = false
                }
            } else {
                isLyricsKey = false
            }

            // If not a lyrics-specific key, let the controller handle it
            if !isLyricsKey && handler(event) {
                return
            }
        }

        guard let _ = selectedNoteID ?? editingNoteID else {
            if let handler = onKeyDown, handler(event) { return }
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 48: // Tab
            commitEditing()
            if event.modifierFlags.contains(.shift) {
                selectPreviousNote()
            } else {
                selectNextNote()
            }
            // Open editor on the newly selected note
            if let sel = selectedNoteID {
                openInlineEditorForNote(sel)
            }
        case 51: // Delete
            if editingNoteID == nil {
                // Clear syllable from selected note
                if let sel = selectedNoteID {
                    onSyllableChanged?(sel, nil)
                    setNeedsDisplay(bounds)
                }
            } else {
                super.keyDown(with: event)
            }
        case 53: // Escape
            cancelEditing()
            selectedNoteID = nil
            setNeedsDisplay(bounds)
        case 36: // Return/Enter — confirm edit and close (no auto-advance)
            commitEditing()
        case 123: // Left arrow
            selectPreviousNote()
        case 124: // Right arrow
            selectNextNote()
        default:
            if let handler = onKeyDown, handler(event) { return }
            super.keyDown(with: event)
        }
    }

    /// Always accept first responder so double-click and keyboard events are reliably delivered.
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Split Menu

    /// Shows a popup menu letting the user choose exactly where to split a syllable.
    private func showSplitMenu(for note: PianoRollNote, at point: NSPoint) {
        let text: String?
        if let previews = previewAlignments {
            text = previews[note.id] ?? note.lyricSyllable
        } else {
            text = note.lyricSyllable
        }

        guard let syllable = text, !syllable.isEmpty, syllable != "_" else { return }
        let cleanText = syllable.hasSuffix("-") ? String(syllable.dropLast()) : syllable
        guard cleanText.count >= 2 else { return }

        let menu = NSMenu(title: "Split Syllable")
        menu.autoenablesItems = false

        for i in 1..<cleanText.count {
            let first = String(cleanText.prefix(i))
            let second = String(cleanText.suffix(cleanText.count - i))
            let title = "\(first)  ·  \(second)"
            let item = NSMenuItem(title: title, action: #selector(splitMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.representedObject = note.id
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func splitMenuItemClicked(_ sender: NSMenuItem) {
        guard let noteID = sender.representedObject as? UUID else { return }
        onSyllableSplit?(noteID, sender.tag)
    }

    // MARK: - Note Lookup

    /// Find the vocal note at a given point in the lane.
    private func noteAt(_ point: NSPoint) -> PianoRollNote? {
        let safePPT = max(pixelsPerTick, 0.000_01)
        let kbOff = keyboardOffset
        let trackCount = max(1, vocalTrackKeys.count)
        let rowHeight = max(18, bounds.height / CGFloat(trackCount))

        // Determine which row was clicked
        let clickedRow = min(trackCount - 1, max(0, Int(point.y / rowHeight)))

        for note in notes {
            // Check row match
            let noteRow: Int
            if trackCount > 1 {
                noteRow = vocalTrackKeys.firstIndex(where: { key in
                    trackIndicesByKey[key]?.contains(note.trackIndex) == true
                }) ?? 0
            } else {
                noteRow = 0
            }
            guard noteRow == clickedRow else { continue }

            let x = kbOff + CGFloat(note.startTick) * safePPT - scrollOffset
            let noteWidth = max(8, CGFloat(note.duration) * safePPT)
            if point.x >= x && point.x <= x + noteWidth {
                return note
            }
        }
        return nil
    }

    /// Find the timed lyric line entry at a given point.
    /// Returns the entry and its approximate pixel width for hit testing.
    private func timedLyricLineAt(_ point: NSPoint) -> (tick: Int, line: String, lineIndex: Int)? {
        let safePPT = max(pixelsPerTick, 0.000_01)
        let kbOff = keyboardOffset
        let trackCount = max(1, vocalTrackKeys.count)
        let rowHeight = max(18, bounds.height / CGFloat(trackCount))

        for entry in timedLyricLines {
            let x = kbOff + CGFloat(entry.tick) * safePPT - scrollOffset
            let displayText = entry.line.trimmingCharacters(in: .whitespaces)
            guard !displayText.isEmpty else { continue }

            // Approximate text width: ~7pt per character for Menlo 10pt
            let approxWidth = max(30, CGFloat(displayText.count) * 7)
            let hitRect = CGRect(x: x, y: 0, width: approxWidth + 4, height: rowHeight)
            if hitRect.contains(point) {
                return entry
            }
        }
        return nil
    }

    /// Sorted vocal notes for keyboard navigation.
    private var sortedNotes: [PianoRollNote] {
        notes.sorted { $0.startTick < $1.startTick }
    }

    private func selectNextNote() {
        let sorted = sortedNotes
        guard !sorted.isEmpty else { return }
        if let current = selectedNoteID,
           let idx = sorted.firstIndex(where: { $0.id == current }),
           idx + 1 < sorted.count {
            selectedNoteID = sorted[idx + 1].id
        } else {
            selectedNoteID = sorted.first?.id
        }
        setNeedsDisplay(bounds)
    }

    private func selectPreviousNote() {
        let sorted = sortedNotes
        guard !sorted.isEmpty else { return }
        if let current = selectedNoteID,
           let idx = sorted.firstIndex(where: { $0.id == current }),
           idx > 0 {
            selectedNoteID = sorted[idx - 1].id
        } else {
            selectedNoteID = sorted.last?.id
        }
        setNeedsDisplay(bounds)
    }

    // MARK: - Inline Text Editing

    private func openInlineEditor(at point: NSPoint) {
        guard let note = noteAt(point) else { return }
        openInlineEditorForNote(note.id)
    }

    private func openInlineEditorForNote(_ noteID: UUID) {
        commitEditing() // Close any existing editor

        guard let note = notes.first(where: { $0.id == noteID }) else { return }
        let safePPT = max(pixelsPerTick, 0.000_01)
        let kbOff = keyboardOffset
        let trackCount = max(1, vocalTrackKeys.count)
        let rowHeight = max(18, bounds.height / CGFloat(trackCount))

        let noteRow: Int
        if trackCount > 1 {
            noteRow = vocalTrackKeys.firstIndex(where: { key in
                trackIndicesByKey[key]?.contains(note.trackIndex) == true
            }) ?? 0
        } else {
            noteRow = 0
        }

        let x = kbOff + CGFloat(note.startTick) * safePPT - scrollOffset
        let rowY = CGFloat(noteRow) * rowHeight
        let fieldWidth = max(40, min(120, CGFloat(note.duration) * safePPT))

        let tf = NSTextField(frame: CGRect(x: x, y: rowY + 1, width: fieldWidth, height: rowHeight - 2))
        tf.stringValue = note.lyricSyllable ?? ""
        tf.font = NSFont(name: "Menlo", size: 11)
        tf.textColor = .white
        tf.backgroundColor = NSColor(white: 0.2, alpha: 0.95)
        tf.isBordered = true
        tf.isBezeled = false
        tf.focusRingType = .none
        tf.isEditable = true
        tf.delegate = self
        tf.tag = noteID.hashValue

        addSubview(tf)
        tf.selectText(nil)
        window?.makeFirstResponder(tf)

        editingNoteID = noteID
        editingTextField = tf
        selectedNoteID = noteID
    }

    private func commitEditing() {
        guard let tf = editingTextField, let noteID = editingNoteID else { return }
        let text = tf.stringValue.trimmingCharacters(in: .whitespaces)

        // Clear state BEFORE removing from superview and firing callback.
        // removeFromSuperview() triggers controlTextDidEndEditing synchronously,
        // which calls commitEditing() again. By clearing state first, that
        // re-entrant call hits the guard and returns immediately.
        editingTextField = nil
        editingNoteID = nil
        tf.removeFromSuperview()

        onSyllableChanged?(noteID, text.isEmpty ? nil : text)
    }

    private func cancelEditing() {
        guard let tf = editingTextField else { return }
        // Clear state BEFORE removing from superview (same re-entrancy guard as commitEditing)
        editingTextField = nil
        editingNoteID = nil
        tf.removeFromSuperview()
    }

    // MARK: - Selective Corner Rounding (reuse from VelocityLaneView)
    // Uses VelocityLaneView.pathWithSelectiveCorners (static method).
}

// MARK: - LyricsLaneView + NSTextFieldDelegate

@available(macOS 26.0, *)
extension LyricsLaneView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            commitEditing()
            selectNextNote()
            if let sel = selectedNoteID {
                openInlineEditorForNote(sel)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            commitEditing()
            selectPreviousNote()
            if let sel = selectedNoteID {
                openInlineEditorForNote(sel)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Return/Enter: confirm edit and close editor (no auto-advance)
            commitEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        return false
    }
}

// MARK: - NoteLabelsOverlayView

/// A CoreGraphics overlay that draws note name labels (e.g. "C4", "F#5") on notes
/// when zoomed in enough. Passes all mouse events through to layers below.
@available(macOS 26.0, *)
@MainActor
final class NoteLabelsOverlayView: NSView {

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Minimum note width in points to show a label.
    private let minWidthForLabel: CGFloat = 24

    /// Minimum row height in points to show labels.
    private let minRowHeightForLabel: CGFloat = 14

    // MARK: - Cached render data

    private struct LabelInfo {
        let text: String
        let rect: CGRect
    }

    private struct LyricLabelInfo {
        let text: String
        let x: CGFloat
        let y: CGFloat       // top of the note — lyric draws above
        let noteWidth: CGFloat
    }

    private struct ArticulationTagInfo {
        let shortName: String
        let x: CGFloat
        let y: CGFloat       // bottom of the note
        let color: NSColor
    }

    private struct GroupOutlineInfo {
        let rect: CGRect
        let name: String
        let color: NSColor
    }

    struct VoiceLaneInfo: Equatable {
        let name: String
        let trackIndex: Int
        let minPitch: Int
        let maxPitch: Int
        let color: NSColor

        static func == (lhs: VoiceLaneInfo, rhs: VoiceLaneInfo) -> Bool {
            lhs.name == rhs.name && lhs.trackIndex == rhs.trackIndex
                && lhs.minPitch == rhs.minPitch && lhs.maxPitch == rhs.maxPitch
                && lhs.color == rhs.color
        }
    }

    private var labels: [LabelInfo] = []
    private var lyricLabels: [LyricLabelInfo] = []
    private var articulationTags: [ArticulationTagInfo] = []
    private var voiceLanes: [VoiceLaneInfo] = []
    private var groupOutlines: [GroupOutlineInfo] = []

    // MARK: - CTLine Cache
    /// Caches CTLine objects by text string to avoid recreating them every draw call.
    /// Cleared whenever updateLabels is called with new data.
    private var ctLineCache: [String: CTLine] = [:]

    // MARK: - Label Computation Cache
    /// Tracks the inputs to `updateLabels` so we can skip recomputation when
    /// the scroll offset or viewport merely shifted by sub-pixel amounts, or
    /// when nothing relevant changed at all.
    private var cachedNoteCount: Int = -1
    private var cachedScrollOffset: CGPoint = CGPoint(x: -999, y: -999)
    private var cachedViewportSize: CGSize = .zero
    private var cachedPixelsPerTick: CGFloat = 0
    private var cachedGroupCount: Int = -1
    private var cachedVoiceLaneCount: Int = -1
    private var cachedMaxPitch: Int = -1
    private var cachedRowHeight: CGFloat = 0

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Pass-through hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override var isFlipped: Bool { true }

    // MARK: - Update

    func updateLabels(
        notes: [PianoRollNote],
        maxPitch: Int,
        rowHeight: CGFloat,
        pixelsPerTick: CGFloat,
        scrollOffset: CGPoint,
        viewport: CGSize,
        noteGroups: [NoteGroup] = [],
        articulationLookup: [UUID: ArticulationEntry] = [:],
        voiceLaneInfos: [VoiceLaneInfo] = []
    ) {
        // Cache check: skip full recomputation when nothing relevant changed.
        // Use an 8-point threshold for scroll offset to avoid churning during
        // smooth follow-mode scrolling at 60fps.
        let scrollThreshold: CGFloat = 8.0
        if notes.count == cachedNoteCount,
           maxPitch == cachedMaxPitch,
           rowHeight == cachedRowHeight,
           pixelsPerTick == cachedPixelsPerTick,
           noteGroups.count == cachedGroupCount,
           voiceLaneInfos.count == cachedVoiceLaneCount,
           viewport == cachedViewportSize,
           abs(scrollOffset.x - cachedScrollOffset.x) < scrollThreshold,
           abs(scrollOffset.y - cachedScrollOffset.y) < scrollThreshold {
            return
        }

        // Update cache keys.
        cachedNoteCount = notes.count
        cachedMaxPitch = maxPitch
        cachedRowHeight = rowHeight
        cachedPixelsPerTick = pixelsPerTick
        cachedGroupCount = noteGroups.count
        cachedVoiceLaneCount = voiceLaneInfos.count
        cachedScrollOffset = scrollOffset
        cachedViewportSize = viewport

        ctLineCache.removeAll(keepingCapacity: true)
        voiceLanes = voiceLaneInfos
        lastMaxPitch = maxPitch
        lastRowHeight = rowHeight
        lastScrollOffset = scrollOffset
        lastViewport = viewport

        // Only show labels when row height is large enough
        guard rowHeight >= minRowHeightForLabel else {
            if !labels.isEmpty || !lyricLabels.isEmpty || !articulationTags.isEmpty || !groupOutlines.isEmpty || !voiceLanes.isEmpty {
                labels = []
                lyricLabels = []
                articulationTags = []
                groupOutlines = []
                voiceLanes = []
                setNeedsDisplay(bounds)
            }
            return
        }

        var newLabels: [LabelInfo] = []
        newLabels.reserveCapacity(min(notes.count, 500))
        var newLyricLabels: [LyricLabelInfo] = []
        var newArtTags: [ArticulationTagInfo] = []

        let visibleMinX = scrollOffset.x
        let visibleMaxX = scrollOffset.x + viewport.width
        let visibleMinY = scrollOffset.y
        let visibleMaxY = scrollOffset.y + viewport.height

        for note in notes {
            let x = CGFloat(note.startTick) * pixelsPerTick
            let w = max(8, CGFloat(note.duration) * pixelsPerTick)

            // Skip notes outside visible horizontal range
            guard x + w > visibleMinX && x < visibleMaxX else { continue }

            let y = CGFloat(maxPitch - note.pitch) * rowHeight
            let h = rowHeight - 1

            // Skip notes outside visible vertical range
            guard y + h > visibleMinY && y < visibleMaxY else { continue }

            // Convert from canvas to viewport coordinates
            let viewX = x - scrollOffset.x
            let viewY = y - scrollOffset.y

            // Note name labels disabled — they cause rendering issues at small row heights.

            // Lyric syllable label (drawn above the note)
            if let syllable = note.lyricSyllable, !syllable.isEmpty {
                newLyricLabels.append(LyricLabelInfo(
                    text: syllable,
                    x: viewX,
                    y: viewY,
                    noteWidth: w
                ))
            }

            // Articulation tag (drawn below the note)
            if let artID = note.articulationID, let art = articulationLookup[artID] {
                let color: NSColor
                if let hex = art.colorHex, hex.count == 6,
                   let r = UInt8(hex.prefix(2), radix: 16),
                   let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
                   let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16) {
                    color = NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
                } else {
                    color = NSColor.white
                }
                newArtTags.append(ArticulationTagInfo(
                    shortName: art.shortName,
                    x: viewX,
                    y: viewY + h,
                    color: color
                ))
            }

            // Limit to prevent excessive drawing
            if newLabels.count >= 500 && newLyricLabels.count >= 300 { break }
        }

        // Compute group outlines
        var newGroupOutlines: [GroupOutlineInfo] = []
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let groupColors: [NSColor] = [
            NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.4, green: 1.0, blue: 0.6, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.7, blue: 0.3, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.6, alpha: 1),
            NSColor(calibratedRed: 0.7, green: 0.5, blue: 1.0, alpha: 1),
        ]

        for (gi, group) in noteGroups.enumerated() {
            let memberNotes = group.noteIDs.compactMap { notesByID[$0] }
            guard !memberNotes.isEmpty else { continue }

            var minX = CGFloat.greatestFiniteMagnitude
            var maxX = CGFloat.leastNormalMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY = CGFloat.leastNormalMagnitude

            for note in memberNotes {
                let x = CGFloat(note.startTick) * pixelsPerTick
                let w = max(8, CGFloat(note.duration) * pixelsPerTick)
                let y = CGFloat(maxPitch - note.pitch) * rowHeight
                let h = rowHeight - 1
                minX = min(minX, x)
                maxX = max(maxX, x + w)
                minY = min(minY, y)
                maxY = max(maxY, y + h)
            }

            // Convert to viewport coordinates
            let viewRect = CGRect(
                x: minX - scrollOffset.x - 3,
                y: minY - scrollOffset.y - 14,
                width: maxX - minX + 6,
                height: maxY - minY + 17
            )

            // Skip if off-screen
            let expanded = viewRect.insetBy(dx: -20, dy: -20)
            guard expanded.intersects(CGRect(origin: .zero, size: viewport)) else { continue }

            let color: NSColor
            if let hex = group.colorHex, hex.count == 6,
               let r = UInt8(hex.prefix(2), radix: 16),
               let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
               let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16) {
                color = NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            } else {
                color = groupColors[gi % groupColors.count]
            }

            newGroupOutlines.append(GroupOutlineInfo(
                rect: viewRect,
                name: group.name,
                color: color
            ))
        }

        labels = newLabels
        lyricLabels = newLyricLabels
        articulationTags = newArtTags
        groupOutlines = newGroupOutlines
        setNeedsDisplay(bounds)
    }

    // MARK: - Drawing

    // Store last known layout params for voice lane drawing
    private var lastMaxPitch: Int = 127
    private var lastRowHeight: CGFloat = 16
    private var lastScrollOffset: CGPoint = .zero
    private var lastViewport: CGSize = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard !labels.isEmpty || !lyricLabels.isEmpty || !articulationTags.isEmpty || !groupOutlines.isEmpty || !voiceLanes.isEmpty else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw voice lane separators and labels
        if !voiceLanes.isEmpty {
            drawVoiceLanes(context: context, dirtyRect: dirtyRect)
        }

        // Draw group outlines (behind everything else)
        for group in groupOutlines {
            guard group.rect.intersects(dirtyRect) else { continue }

            let roundedPath = CGPath(roundedRect: group.rect, cornerWidth: 5, cornerHeight: 5, transform: nil)

            // Faint fill
            context.saveGState()
            context.addPath(roundedPath)
            context.setFillColor(group.color.withAlphaComponent(0.06).cgColor)
            context.fillPath()
            context.restoreGState()

            // Dashed border
            context.saveGState()
            context.addPath(roundedPath)
            context.setStrokeColor(group.color.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1.0)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.strokePath()
            context.restoreGState()

            // Group name label (top-left)
            let labelFont = NSFont.systemFont(ofSize: 9)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: group.color.withAlphaComponent(0.75)
            ]
            let attrStr = NSAttributedString(string: group.name, attributes: labelAttrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

            let textX = group.rect.origin.x + 4
            let textY = group.rect.origin.y + 2

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: textX, y: textY + textBounds.height)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        // Note name labels drawing disabled.

        // Draw lyric syllable labels above notes
        if !lyricLabels.isEmpty {
            let lyricFontSize: CGFloat = 11
            let lyricFont = NSFont.systemFont(ofSize: lyricFontSize)

            let lyricAttrs: [NSAttributedString.Key: Any] = [
                .font: lyricFont,
                .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.4, alpha: 0.95)
            ]

            let shadowAttrs: [NSAttributedString.Key: Any] = [
                .font: lyricFont,
                .foregroundColor: NSColor.black.withAlphaComponent(0.6)
            ]

            for lyric in lyricLabels {
                let lyricCacheKey = "l:\(lyric.text)"
                let line: CTLine
                if let cached = ctLineCache[lyricCacheKey] {
                    line = cached
                } else {
                    let attrStr = NSAttributedString(string: lyric.text, attributes: lyricAttrs)
                    line = CTLineCreateWithAttributedString(attrStr)
                    ctLineCache[lyricCacheKey] = line
                }
                let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

                // Position above the note, left-aligned with slight offset
                let textX = lyric.x + 2
                let textY = lyric.y - textBounds.height - 2

                // Skip if off-screen
                let labelRect = CGRect(x: textX, y: textY, width: textBounds.width, height: textBounds.height)
                guard labelRect.intersects(dirtyRect) else { continue }

                // Draw shadow for legibility
                let shadowCacheKey = "ls:\(lyric.text)"
                let shadowLine: CTLine
                if let cached = ctLineCache[shadowCacheKey] {
                    shadowLine = cached
                } else {
                    let shadowStr = NSAttributedString(string: lyric.text, attributes: shadowAttrs)
                    shadowLine = CTLineCreateWithAttributedString(shadowStr)
                    ctLineCache[shadowCacheKey] = shadowLine
                }
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: textX + 0.5, y: textY + textBounds.height + 0.5)
                context.scaleBy(x: 1, y: -1)
                CTLineDraw(shadowLine, context)
                context.restoreGState()

                // Draw text
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: textX, y: textY + textBounds.height)
                context.scaleBy(x: 1, y: -1)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }

        // Draw articulation tags below notes
        if !articulationTags.isEmpty {
            let tagFont: NSFont = NSFont(name: "Menlo", size: 8)
                ?? NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)

            for tag in articulationTags {
                let tagAttrs: [NSAttributedString.Key: Any] = [
                    .font: tagFont,
                    .foregroundColor: tag.color.withAlphaComponent(0.9)
                ]
                let attrStr = NSAttributedString(string: tag.shortName, attributes: tagAttrs)
                let line = CTLineCreateWithAttributedString(attrStr)
                let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

                let textX = tag.x + 2
                let textY = tag.y + 1

                let labelRect = CGRect(x: textX, y: textY, width: textBounds.width + 4, height: textBounds.height + 2)
                guard labelRect.intersects(dirtyRect) else { continue }

                // Small background pill
                let pill = CGRect(x: textX - 1, y: textY, width: textBounds.width + 4, height: textBounds.height + 2)
                let pillPath = CGPath(roundedRect: pill, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.saveGState()
                context.addPath(pillPath)
                context.setFillColor(tag.color.withAlphaComponent(0.15).cgColor)
                context.fillPath()
                context.restoreGState()

                // Text
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: textX + 1, y: textY + textBounds.height + 1)
                context.scaleBy(x: 1, y: -1)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
    }

    // MARK: - Voice Lane Drawing

    private func drawVoiceLanes(context: CGContext, dirtyRect: NSRect) {
        let rowHeight = lastRowHeight
        let maxPitch = lastMaxPitch
        let scrollOffset = lastScrollOffset
        let viewport = lastViewport

        let laneFont = NSFont.systemFont(ofSize: 11)
        let laneBgFont = NSFont.systemFont(ofSize: 11)

        let laneColors: [NSColor] = [
            NSColor(calibratedRed: 0.3, green: 0.7, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.7, blue: 0.3, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 0.7, green: 0.5, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.5, green: 0.9, blue: 0.9, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.8, alpha: 1),
            NSColor(calibratedRed: 0.8, green: 0.9, blue: 0.3, alpha: 1),
        ]

        for (i, lane) in voiceLanes.enumerated() {
            let color = lane.color.alphaComponent > 0.01 ? lane.color : laneColors[i % laneColors.count]

            // Lane boundary: horizontal line at the top of the lane's pitch range
            // The lane occupies from maxPitch of the lane to minPitch - 1
            let topY = CGFloat(maxPitch - lane.maxPitch) * rowHeight - scrollOffset.y
            let bottomY = CGFloat(maxPitch - lane.minPitch + 1) * rowHeight - scrollOffset.y

            // Only draw if visible
            guard bottomY > 0 && topY < viewport.height else { continue }

            // Draw separator line at top of lane
            let lineY = max(0, topY)
            let lineRect = CGRect(x: 0, y: lineY, width: viewport.width, height: 1)
            if lineRect.intersects(dirtyRect) {
                context.saveGState()
                context.setFillColor(color.withAlphaComponent(0.35).cgColor)
                context.fill(lineRect)
                context.restoreGState()
            }

            // Faint background tint for the lane
            let laneRect = CGRect(x: 0, y: topY, width: viewport.width, height: bottomY - topY)
            let clippedLane = laneRect.intersection(CGRect(origin: .zero, size: viewport))
            if clippedLane.width > 0 && clippedLane.height > 0 && clippedLane.intersects(dirtyRect) {
                context.saveGState()
                context.setFillColor(color.withAlphaComponent(0.03).cgColor)
                context.fill(clippedLane)
                context.restoreGState()
            }

            // Lane label (fixed at left edge)
            let labelY = max(2, topY + 2)
            guard labelY < viewport.height - 16 else { continue }

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: laneFont,
                .foregroundColor: color.withAlphaComponent(0.85)
            ]
            let bgAttrs: [NSAttributedString.Key: Any] = [
                .font: laneBgFont,
                .foregroundColor: NSColor.black.withAlphaComponent(0.5)
            ]

            let attrStr = NSAttributedString(string: lane.name, attributes: labelAttrs)
            let bgStr = NSAttributedString(string: lane.name, attributes: bgAttrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let bgLine = CTLineCreateWithAttributedString(bgStr)
            let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

            let textX: CGFloat = 6
            let textYBase = labelY

            // Background pill
            let pillRect = CGRect(x: textX - 3, y: textYBase - 1, width: textBounds.width + 8, height: textBounds.height + 4)
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.saveGState()
            context.addPath(pillPath)
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fillPath()
            context.addPath(pillPath)
            context.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
            context.restoreGState()

            // Shadow text
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: textX + 0.5, y: textYBase + textBounds.height + 0.5)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(bgLine, context)
            context.restoreGState()

            // Label text
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: textX, y: textYBase + textBounds.height)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
#endif
