#if canImport(AppKit)
import AppKit
import AVFoundation
// Combine removed — ScoreStore uses @Observable, not @Published
import ProjectKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
final class PianoRollViewController: NSViewController {

    /// Custom pencil cursor for the Draw tool using SF Symbol (cached, created once).
    /// Hotspot at bottom-left (pencil tip) so it aligns with the note's top-right corner.
    private static let pencilCursor: NSCursor = {
        let pointSize: CGFloat = 24
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        if let sfImage = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Draw") {
            let configured = sfImage.withSymbolConfiguration(config) ?? sfImage
            // Render the SF Symbol as a white icon with a dark outline for visibility on dark backgrounds
            let finalSize = configured.size
            let rendered = NSImage(size: finalSize, flipped: false) { rect in
                // Lock focus to draw tinted versions of the symbol
                // Shadow layer for contrast
                let shadowImage = configured.copy() as! NSImage
                shadowImage.isTemplate = true
                shadowImage.lockFocus()
                NSColor.black.withAlphaComponent(0.7).set()
                NSRect(origin: .zero, size: finalSize).fill(using: .sourceAtop)
                shadowImage.unlockFocus()
                shadowImage.draw(in: rect.offsetBy(dx: 0.5, dy: -0.5),
                    from: .zero, operation: .sourceOver, fraction: 1.0)

                // White icon on top
                let whiteImage = configured.copy() as! NSImage
                whiteImage.isTemplate = true
                whiteImage.lockFocus()
                NSColor.white.set()
                NSRect(origin: .zero, size: finalSize).fill(using: .sourceAtop)
                whiteImage.unlockFocus()
                whiteImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            rendered.isTemplate = false
            // Hotspot at bottom-left: the pencil tip points down-left
            return NSCursor(image: rendered, hotSpot: NSPoint(x: 2, y: finalSize.height - 2))
        }
        // Fallback if SF Symbol not available
        return .crosshair
    }()

    private let store: ScoreStore
    private let chromeState = PianoRollChromeState()
    private var editorView: PianoRollEditorView?
    private var renderer: PianoRollMetalRenderer?
    private var toolbarHostView: NSHostingView<PianoRollToolbarView>?
    private var statusBarHost: NSHostingView<PianoRollStatusBarView>?

    // MARK: - Lane Views
    //
    // The velocity and tempo lanes sit below the Metal editor.
    // Each lane has a clickable label header that toggles its visibility.
    // Data sync happens in pushDataToEditor() and callbacks are wired in
    // configureLaneCallbacks().

    // Chord & rehearsal mark strips (SwiftUI hosted above the editor)
    private var chordRehearsalHost: NSHostingView<AnyView>?

    private var velocityLane: VelocityLaneView?
    private var tempoLane: TempoLaneView?
    private var velocityLabelButton: NSButton?
    private var tempoLabelButton: NSButton?
    private var velocityContainer: NSView?  // holds label + lane
    private var tempoContainer: NSView?     // holds label + lane
    private var lyricsLane: LyricsLaneView?
    private var lyricsLabelButton: NSButton?
    private var lyricsContainer: NSView?     // holds label + lane
    private var lyricsAutoAlignButton: NSButton?
    private var lyricsPreviewAcceptButton: NSButton?
    private var lyricsPreviewRejectButton: NSButton?
    /// Cached syllabified words from the last auto-align, used when building alignment on accept.
    private var lastAutoAlignSyllabified: [(word: String, syllables: [String])] = []

    private var velocityHeightConstraint: NSLayoutConstraint?
    private var tempoHeightConstraint: NSLayoutConstraint?
    private var lyricsHeightConstraint: NSLayoutConstraint?

    /// Whether the velocity lane is visible. Persisted in UserDefaults.
    private var velocityLaneVisible: Bool {
        get { UserDefaults.standard.bool(forKey: "operawriter.pianoroll.velocityLane.visible") }
        set {
            UserDefaults.standard.set(newValue, forKey: "operawriter.pianoroll.velocityLane.visible")
            updateLaneVisibility()
        }
    }

    /// Whether the tempo lane is visible. Persisted in UserDefaults.
    private var tempoLaneVisible: Bool {
        get { UserDefaults.standard.bool(forKey: "operawriter.pianoroll.tempoLane.visible") }
        set {
            UserDefaults.standard.set(newValue, forKey: "operawriter.pianoroll.tempoLane.visible")
            updateLaneVisibility()
        }
    }

    /// Persisted velocity lane height.
    private var velocityLaneHeight: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: "operawriter.pianoroll.velocityLane.height"))
            return v > 0 ? v : 60
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "operawriter.pianoroll.velocityLane.height") }
    }

    /// Persisted tempo lane height.
    private var tempoLaneHeight: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: "operawriter.pianoroll.tempoLane.height"))
            return v > 0 ? v : 60
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "operawriter.pianoroll.tempoLane.height") }
    }

    /// Whether the lyrics lane is visible. Persisted in UserDefaults.
    private var lyricsLaneVisible: Bool {
        get { UserDefaults.standard.bool(forKey: "operawriter.pianoroll.lyricsLane.visible") }
        set {
            UserDefaults.standard.set(newValue, forKey: "operawriter.pianoroll.lyricsLane.visible")
            updateLaneVisibility()
        }
    }

    /// Persisted lyrics lane height.
    private var lyricsLaneHeight: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: "operawriter.pianoroll.lyricsLane.height"))
            return v > 0 ? v : 40
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "operawriter.pianoroll.lyricsLane.height") }
    }

    // MARK: - Playhead State

    private(set) var playheadTick: Int = 0
    private var playheadStartDate: Date?
    private nonisolated(unsafe) var playheadTimer: Timer?
    private var playheadTempoMap: [TempoPoint] = []
    private var playheadTotalDurationSeconds: Double = 0
    private var playheadStartSeconds: Double = 0
    private var lastFollowPageStartTick: Int = 0
    private var wasPlaying = false
    private var lastSongID: UUID?
    private var lastTrackFilter: Set<Int> = []
    private var wasStepMode = false
    private var lastStoreGeneration: UInt64 = 0
    private var lastPreviewPartID: String?    // track generated part changes
    private var lastComposedMelodyCount: Int?  // track composed melody changes
    /// Snapshot of tempo events to detect when tempo specifically changes during playback.
    private var lastTempoSnapshot: [TempoPoint] = []
    /// Tracks whether playback was stopped in place (Logic Pro-style: second stop returns to start).
    var playheadStopped = false {
        didSet {
            guard playheadStopped != oldValue else { return }
            syncChromeState()
        }
    }
    /// Frame counter for throttling SwiftUI live display updates (~15Hz instead of 60Hz).
    private var liveDisplayFrameCounter: Int = 0

    // MARK: - Editing State (internal for toolbar access)

    private static let zoomHorizontalKey = "operawriter.pianoroll.zoom.horizontal"
    private static let zoomVerticalKey = "operawriter.pianoroll.zoom.vertical"

    var tool: PianoRollToolChoice = .select {
        didSet {
            guard tool != oldValue else { return }
            if isAllTracksConstrainedMode, tool != .select {
                tool = .select
                store.statusMessage = "All Tracks uses the Select tool only"
                return
            }
            tempoLane?.currentTool = tool
            syncChromeState()
            editorView?.refreshCursor()
        }
    }
    var snap: PianoRollSnapChoice = .sixteenth {
        didSet {
            guard snap != oldValue else { return }
            pushDataToEditor()
        }
    }
    var pixelsPerQuarter: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: PianoRollViewController.zoomHorizontalKey)
        return saved > 0 ? CGFloat(saved) : 128
    }() {
        didSet {
            guard pixelsPerQuarter != oldValue else { return }
            pushDataToEditor()
        }
    }
    var editorRowHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: PianoRollViewController.zoomVerticalKey)
        return saved > 0 ? CGFloat(saved) : 16
    }() {
        didSet {
            guard editorRowHeight != oldValue else { return }
            pushDataToEditor()
        }
    }
    private var lastSavedPixelsPerQuarter: CGFloat = 0
    private var lastSavedEditorRowHeight: CGFloat = 0
    var selectedNoteIDs: Set<UUID> = [] {
        didSet {
            guard selectedNoteIDs != oldValue else { return }
            store.selectedNoteIDs = selectedNoteIDs
            editorView?.selectedNoteIDs = selectedNoteIDs
            velocityLane?.selectedNoteIDs = selectedNoteIDs
            syncChromeState()
        }
    }
    var showAdvancedControls = false
    var showGhostNotes = true {
        didSet {
            guard showGhostNotes != oldValue else { return }
            pushDataToEditor()
        }
    }
    var scaleRoot: ScaleRoot = .c {
        didSet {
            guard scaleRoot != oldValue else { return }
            pushDataToEditor()
        }
    }
    var scaleType: ScaleType = .none {
        didSet {
            guard scaleType != oldValue else { return }
            pushDataToEditor()
        }
    }
    var velocityColorEnabled: Bool = false {
        didSet {
            guard velocityColorEnabled != oldValue else { return }
            pushDataToEditor()
        }
    }
    var multiVoiceMode: Bool = false {
        didSet {
            guard multiVoiceMode != oldValue else { return }
            pushDataToEditor()
        }
    }
    var stampChordQuality: ChordQuality = .major {
        didSet {
            guard stampChordQuality != oldValue else { return }
            syncChromeState()
        }
    }
    var stampChordRoot: ScaleRoot = .c {
        didSet {
            guard stampChordRoot != oldValue else { return }
            syncChromeState()
        }
    }
    var stampOctave: Int = 4 {
        didSet {
            guard stampOctave != oldValue else { return }
            syncChromeState()
        }
    }

    /// Detected chord name from currently selected notes.
    var detectedChordName: String? {
        guard !selectedNoteIDs.isEmpty else { return nil }
        let pitches = store.pianoRollNotes
            .filter { selectedNoteIDs.contains($0.id) }
            .map(\.pitch)
        return ChordDetector.detect(pitches: pitches)
    }

    private func syncChromeState() {
        chromeState.tool = tool
        chromeState.snap = snap
        chromeState.selectedNoteCount = selectedNoteIDs.count
        chromeState.isAllTracksView = isAllTracksConstrainedMode
        chromeState.showGhostNotes = showGhostNotes
        chromeState.scaleRoot = scaleRoot
        chromeState.scaleType = scaleType
        chromeState.velocityColorEnabled = velocityColorEnabled
        chromeState.multiVoiceMode = multiVoiceMode
        chromeState.stampChordQuality = stampChordQuality
        chromeState.stampChordRoot = stampChordRoot
        chromeState.stampOctave = stampOctave
        chromeState.detectedChordName = detectedChordName
        chromeState.followMode = followMode
        chromeState.playheadStopped = playheadStopped
        chromeState.canUndo = canUndo
        chromeState.canRedo = canRedo
        chromeState.pixelsPerQuarter = pixelsPerQuarter
        chromeState.editorRowHeight = editorRowHeight
    }

    /// Stamps a chord at the given tick using the current stamp settings.
    func stampChord(at tick: Int, trackIndex: Int = 0, channel: Int = 0) {
        let rootPitch = stampChordRoot.rawValue + (stampOctave + 1) * 12
        let intervals = stampChordQuality.intervals
        let snapped = snapToGrid(tick, division: snapTicks)
        let duration = max(1, snap.tickSpan(ticksPerQuarter: store.ticksPerQuarter))

        pushUndo()
        var notes = store.pianoRollNotes
        var newIDs: [UUID] = []
        for interval in intervals {
            let pitch = rootPitch + interval
            guard pitch >= 0, pitch <= 127 else { continue }
            let note = PianoRollNote(
                trackIndex: trackIndex,
                channel: channel,
                pitch: pitch,
                velocity: 100,
                startTick: snapped,
                duration: duration
            )
            notes.append(note)
            newIDs.append(note.id)
        }
        store.setPianoRollNotesFromEditor(notes)
        selectedNoteIDs = Set(newIDs)
    }

    private var dragOrigin: CGPoint?
    private var draftNote: (pitch: Int, startTick: Int, duration: Int, trackIndex: Int, channel: Int)?
    /// Tracks the last pitch previewed during a Draw tool drag, to avoid re-triggering the same note.
    private var lastDrawPreviewPitch: Int = -1

    /// Remembers the duration of the last committed note so the next drawn note
    /// inherits the same size (0 = not yet set, falls back to snap grid).
    private var lastCommittedNoteDuration: Int = 0
    private var _cachedFollowMode: PlayheadFollowMode?
    var followMode: PlayheadFollowMode {
        get {
            if let cached = _cachedFollowMode { return cached }
            let raw = UserDefaults.standard.string(forKey: "operawriter.transport.followMode") ?? PlayheadFollowMode.center.rawValue
            let mode = PlayheadFollowMode(rawValue: raw) ?? .center
            _cachedFollowMode = mode
            return mode
        }
        set {
            _cachedFollowMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "operawriter.transport.followMode")
            syncChromeState()
        }
    }

    // MARK: - Drag Interaction State

    /// What the current mouse drag is doing.
    private enum DragMode {
        case none
        case movingNotes         // dragging selected notes to new position
        case movingNotesPitchOnly // all-tracks select mode: vertical transposition only
        case resizingNotes       // dragging right edge of a note to change duration
        case resizingNotesLeft   // dragging left edge of a note to change start time + duration
        case drawingNote         // draw tool: creating a new note
        case marqueeSelect       // select tool: rubber-band selection
        case lassoSelect         // select tool + Alt: freeform lasso selection
    }

    private var dragMode: DragMode = .none

    /// The note whose right edge is being resized (if dragMode == .resizingNotes).
    private var resizeAnchorNoteID: UUID?

    /// Snapshot of selected notes at drag start (for move/resize), keyed by ID.
    private var dragStartNoteSnapshot: [UUID: PianoRollNote] = [:]

    /// The canvas point where the drag started (for computing deltas).
    private var dragStartPoint: CGPoint = .zero

    /// Whether Shift was held at drag start (for additive selection).
    private var dragShiftHeld: Bool = false

    /// Whether Alt is currently held during a drag (bypasses snap to grid).
    private var dragAltHeld: Bool = false

    /// Whether undo was already pushed for the current right-drag erase gesture.
    private var rightDragUndoPushed: Bool = false

    /// Selection state before the current drag started (for Shift-click additive).
    private var selectionBeforeDrag: Set<UUID> = []

    /// Lasso selection path points (canvas coordinates).
    private var lassoPoints: [CGPoint] = []

    /// Timer that fires during marquee/lasso drag near edges to auto-scroll.
    private nonisolated(unsafe) var autoScrollTimer: Timer?
    /// Last mouse position in canvas coordinates during an auto-scroll drag.
    private var autoScrollLastCanvasPoint: CGPoint = .zero

    // MARK: - Undo / Redo

    /// Saves the current note state to the undo stack. Call before any edit.
    func pushUndo() {
        store.pushUndoState(label: "Edit Notes")
        syncChromeState()
    }

    func undo() {
        store.undo()
        let validIDs = Set(store.pianoRollNotes.map(\.id))
        selectedNoteIDs = selectedNoteIDs.intersection(validIDs)
        pushDataToEditor()
    }

    func redo() {
        store.redo()
        let validIDs = Set(store.pianoRollNotes.map(\.id))
        selectedNoteIDs = selectedNoteIDs.intersection(validIDs)
        pushDataToEditor()
    }

    var canUndo: Bool { store.canUndo }
    var canRedo: Bool { store.canRedo }

    // MARK: - Clipboard

    /// Notes on the clipboard, stored with positions relative to the earliest note.
    private var clipboard: [PianoRollNote] = []
    /// The offset of the earliest copied note within its source measure (in ticks).
    /// Preserved on paste so notes keep their beat position within a measure.
    private var clipboardMeasureOffset: Int = 0
    var hasClipboard: Bool { !clipboard.isEmpty }

    func copySelected() {
        let source = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
        guard !source.isEmpty else { return }
        let minTick = source.map(\.startTick).min() ?? 0

        // Calculate the offset of the earliest note within its measure
        clipboardMeasureOffset = measureOffset(forTick: minTick)

        clipboard = source.map { note in
            var copy = note
            copy.startTick -= minTick
            return copy
        }
    }

    func cutSelected() {
        copySelected()
        guard !selectedNoteIDs.isEmpty else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        pushUndo()
        var notes = store.pianoRollNotes
        notes.removeAll { selectedNoteIDs.contains($0.id) }
        store.setPianoRollNotesFromEditor(notes)
        selectedNoteIDs.removeAll()
    }

    func pasteNotes() {
        guard !clipboard.isEmpty else { return }
        guard let editor = editorView else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        pushUndo()

        // Determine the target instrument (trackIndex, channel)
        let targetTrackIndex: Int
        let targetChannel: Int
        if let soloTrack = store.selectedTrackFilter.first, store.selectedTrackFilter.count == 1 {
            targetTrackIndex = soloTrack
            targetChannel = defaultChannel(for: soloTrack)
        } else {
            // No single instrument selected — keep original track/channel
            targetTrackIndex = -1
            targetChannel = -1
        }

        // Find the first measure start at or after the viewport's left edge
        let scrollOffsetX = editor.visibleScrollOffsetX
        let ppt = max(editor.pixelsPerTick, 0.001)
        let leftEdgeTick = Int(scrollOffsetX / ppt)
        let firstMeasureTick = firstMeasureStartAtOrAfter(tick: leftEdgeTick)

        // Paste at that measure boundary, preserving the in-measure offset
        let pasteOffset = firstMeasureTick + clipboardMeasureOffset

        let pasted = clipboard.map { note -> PianoRollNote in
            PianoRollNote(
                trackIndex: targetTrackIndex >= 0 ? targetTrackIndex : note.trackIndex,
                channel: targetChannel >= 0 ? targetChannel : note.channel,
                pitch: note.pitch,
                velocity: note.velocity,
                startTick: note.startTick + pasteOffset,
                duration: note.duration
            )
        }
        var notes = store.pianoRollNotes
        notes.append(contentsOf: pasted)
        store.setPianoRollNotesFromEditor(notes)
        selectedNoteIDs = Set(pasted.map(\.id))
    }

    /// Returns the tick offset of a given tick within its enclosing measure.
    private func measureOffset(forTick tick: Int) -> Int {
        let tpq = max(1, store.ticksPerQuarter)
        let sigs = store.pianoRollTimeSignatures.sorted { $0.tick < $1.tick }
        let activeSig = sigs.last(where: { $0.tick <= tick })
            ?? TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)
        let beatTicks = tpq * 4 / max(1, activeSig.denominator)
        let measureTicks = max(1, activeSig.numerator * beatTicks)
        let ticksSinceSig = tick - activeSig.tick
        return ticksSinceSig % measureTicks
    }

    /// Returns the tick of the first measure boundary at or after `tick`.
    private func firstMeasureStartAtOrAfter(tick: Int) -> Int {
        let tpq = max(1, store.ticksPerQuarter)
        let sigs = store.pianoRollTimeSignatures.sorted { $0.tick < $1.tick }
        let activeSig = sigs.last(where: { $0.tick <= tick })
            ?? TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)
        let beatTicks = tpq * 4 / max(1, activeSig.denominator)
        let measureTicks = max(1, activeSig.numerator * beatTicks)
        let ticksSinceSig = tick - activeSig.tick
        let measureIndex = ticksSinceSig / measureTicks
        let measureStart = activeSig.tick + measureIndex * measureTicks
        if measureStart >= tick {
            return measureStart
        }
        return measureStart + measureTicks
    }

    // MARK: - Color Cache

    private var mappedColorByPairKey: [String: SIMD4<Float>] = [:]
    private var mappedColorByTrackIndex: [Int: SIMD4<Float>] = [:]

    // MARK: - Observation

    private var storeObserver: Any?
    private nonisolated(unsafe) var updateTimer: Timer?
    // trackFilterCancellable removed — ScoreStore is @Observable, track filter changes pushed explicitly

    /// Single display-link that replaces both the 30Hz poll timer and
    /// the 60Hz playhead timer.  Pauses itself when idle.
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var displayLinkNeedsDataPush = true

    // MARK: - Init

    init(store: ScoreStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)

        removeLegacyWavPanePreferences()

        // Register defaults so lanes are visible on first launch
        UserDefaults.standard.register(defaults: [
            "operawriter.pianoroll.velocityLane.visible": true,
            "operawriter.pianoroll.tempoLane.visible": true,
            "operawriter.pianoroll.velocityLane.height": 60.0,
            "operawriter.pianoroll.tempoLane.height": 60.0,
        ])

        syncChromeState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func removeLegacyWavPanePreferences() {
        UserDefaults.standard.removeObject(forKey: "operawriter.pianoroll.wavPane.visible")
        UserDefaults.standard.removeObject(forKey: "operawriter.pianoroll.wavPane.height")
    }

    deinit {
        displayLink?.invalidate()
        playheadTimer?.invalidate()
        updateTimer?.invalidate()
        autoScrollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Load View

    override func loadView() {
        let containerView = NSView()
        containerView.wantsLayer = true
        self.view = containerView

        // --- Header: SwiftUI toolbar hosted in NSHostingView ---
        let toolbarView = PianoRollToolbarView(store: store, chrome: chromeState, controller: self)
        let toolbarHost = NSHostingView(rootView: toolbarView)
        toolbarHost.translatesAutoresizingMaskIntoConstraints = false
        toolbarHost.sizingOptions = [.intrinsicContentSize]
        toolbarHost.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        toolbarHost.setContentCompressionResistancePriority(.init(1), for: .vertical)
        toolbarHost.setContentHuggingPriority(.defaultHigh, for: .vertical)
        containerView.addSubview(toolbarHost)
        self.toolbarHostView = toolbarHost

        // --- Chord & Rehearsal Mark Strip ---
        let chordRehearsal = NSHostingView(rootView: AnyView(
            GeometryReader { [store = self.store] geo in
                ZStack(alignment: .leading) {
                    RehearsalMarkView(store: store, pixelsPerTick: 0.267, scrollOffset: 0, visibleWidth: geo.size.width)
                    ChordTrackView(store: store, pixelsPerTick: 0.267, scrollOffset: 0, visibleWidth: geo.size.width)
                }
            }
            .frame(height: 24)
        ))
        chordRehearsal.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(chordRehearsal)
        self.chordRehearsalHost = chordRehearsal

        // --- Metal Editor View ---
        let editor = PianoRollEditorView(frame: .zero)
        editor.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(editor)
        self.editorView = editor

        // Create Metal renderer
        let metalRenderer = PianoRollMetalRenderer()
        self.renderer = metalRenderer
        editor.renderer = metalRenderer

        // --- Empty State: "No Song Selected" (hidden when song is loaded) ---
        let emptyHost = NSHostingView(rootView: PianoRollEmptyStateView())
        emptyHost.translatesAutoresizingMaskIntoConstraints = false
        emptyHost.identifier = NSUserInterfaceItemIdentifier("emptyState")
        containerView.addSubview(emptyHost)

        // --- Velocity & Tempo Lanes ---
        //
        // Layout: editor sits above two lane sections stacked vertically.
        // Each section has a resize-handle header (label + drag area) and
        // a CoreGraphics lane view. Clicking the label toggles the lane.
        // Dragging in the header area vertically resizes the lane height.
        //
        // The lane views draw their own backgrounds with selective corner
        // rounding — velocity has NO rounded corners, tempo has only
        // bottom corners rounded.

        // Lyrics section (between editor and velocity)
        let lyrContainer = NSView()
        lyrContainer.translatesAutoresizingMaskIntoConstraints = false
        self.lyricsContainer = lyrContainer
        containerView.addSubview(lyrContainer)

        let lyrHandle = LaneResizeHandleView(frame: .zero)
        lyrHandle.translatesAutoresizingMaskIntoConstraints = false
        lyrContainer.addSubview(lyrHandle)

        let lyrLabel = NSButton(title: "▾ Lyrics", target: self, action: #selector(toggleLyricsLane))
        lyrLabel.translatesAutoresizingMaskIntoConstraints = false
        lyrLabel.isBordered = false
        lyrLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        lyrLabel.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        lyrLabel.setAccessibilityLabel("Toggle Lyrics Lane")
        self.lyricsLabelButton = lyrLabel
        lyrHandle.addSubview(lyrLabel)

        let autoAlignBtn = NSButton(title: "Auto-Align", target: self, action: #selector(lyricsAutoAlignTapped))
        autoAlignBtn.translatesAutoresizingMaskIntoConstraints = false
        autoAlignBtn.isBordered = false
        autoAlignBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        autoAlignBtn.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        autoAlignBtn.setAccessibilityLabel("Auto-Align Lyrics")
        self.lyricsAutoAlignButton = autoAlignBtn
        lyrHandle.addSubview(autoAlignBtn)

        let previewAcceptBtn = NSButton(title: "✓ Accept", target: self, action: #selector(lyricsPreviewAcceptTapped))
        previewAcceptBtn.translatesAutoresizingMaskIntoConstraints = false
        previewAcceptBtn.isBordered = false
        previewAcceptBtn.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        previewAcceptBtn.contentTintColor = NSColor(calibratedRed: 0.3, green: 0.85, blue: 0.4, alpha: 1.0)
        previewAcceptBtn.isHidden = true
        self.lyricsPreviewAcceptButton = previewAcceptBtn
        lyrHandle.addSubview(previewAcceptBtn)

        let previewRejectBtn = NSButton(title: "✗ Reject", target: self, action: #selector(lyricsPreviewRejectTapped))
        previewRejectBtn.translatesAutoresizingMaskIntoConstraints = false
        previewRejectBtn.isBordered = false
        previewRejectBtn.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        previewRejectBtn.contentTintColor = NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
        previewRejectBtn.isHidden = true
        self.lyricsPreviewRejectButton = previewRejectBtn
        lyrHandle.addSubview(previewRejectBtn)

        let lyrLaneView = LyricsLaneView(frame: .zero)
        lyrLaneView.translatesAutoresizingMaskIntoConstraints = false
        lyrLaneView.roundedCorners = []  // No rounded corners — sits above velocity
        self.lyricsLane = lyrLaneView
        lyrContainer.addSubview(lyrLaneView)

        let lyrHeightC = lyrLaneView.heightAnchor.constraint(equalToConstant: lyricsLaneHeight)
        lyrHeightC.priority = .defaultHigh
        self.lyricsHeightConstraint = lyrHeightC

        NSLayoutConstraint.activate([
            lyrHandle.topAnchor.constraint(equalTo: lyrContainer.topAnchor),
            lyrHandle.leadingAnchor.constraint(equalTo: lyrContainer.leadingAnchor),
            lyrHandle.trailingAnchor.constraint(equalTo: lyrContainer.trailingAnchor),
            lyrHandle.heightAnchor.constraint(equalToConstant: 18),

            lyrLabel.centerYAnchor.constraint(equalTo: lyrHandle.centerYAnchor),
            lyrLabel.leadingAnchor.constraint(equalTo: lyrHandle.leadingAnchor, constant: 6),

            autoAlignBtn.centerYAnchor.constraint(equalTo: lyrHandle.centerYAnchor),
            autoAlignBtn.leadingAnchor.constraint(equalTo: lyrLabel.trailingAnchor, constant: 8),

            previewAcceptBtn.centerYAnchor.constraint(equalTo: lyrHandle.centerYAnchor),
            previewAcceptBtn.leadingAnchor.constraint(equalTo: autoAlignBtn.trailingAnchor, constant: 8),

            previewRejectBtn.centerYAnchor.constraint(equalTo: lyrHandle.centerYAnchor),
            previewRejectBtn.leadingAnchor.constraint(equalTo: previewAcceptBtn.trailingAnchor, constant: 4),

            lyrLaneView.topAnchor.constraint(equalTo: lyrHandle.bottomAnchor),
            lyrLaneView.leadingAnchor.constraint(equalTo: lyrContainer.leadingAnchor),
            lyrLaneView.trailingAnchor.constraint(equalTo: lyrContainer.trailingAnchor),
            lyrLaneView.bottomAnchor.constraint(equalTo: lyrContainer.bottomAnchor),
            lyrHeightC,
        ])

        lyrHandle.onResize = { [weak self] delta in
            self?.resizeLyricsLane(by: delta)
        }

        // Velocity section
        let velContainer = NSView()
        velContainer.translatesAutoresizingMaskIntoConstraints = false
        self.velocityContainer = velContainer
        containerView.addSubview(velContainer)

        let velHandle = LaneResizeHandleView(frame: .zero)
        velHandle.translatesAutoresizingMaskIntoConstraints = false
        velContainer.addSubview(velHandle)

        let velLabel = NSButton(title: "▾ Velocity", target: self, action: #selector(toggleVelocityLane))
        velLabel.translatesAutoresizingMaskIntoConstraints = false
        velLabel.isBordered = false
        velLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        velLabel.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        velLabel.setAccessibilityLabel("Toggle Velocity Lane")
        self.velocityLabelButton = velLabel
        velHandle.addSubview(velLabel)

        let velLane = VelocityLaneView(frame: .zero)
        velLane.translatesAutoresizingMaskIntoConstraints = false
        velLane.roundedCorners = []  // No rounded corners on velocity
        self.velocityLane = velLane
        velContainer.addSubview(velLane)

        let velHeightC = velLane.heightAnchor.constraint(equalToConstant: velocityLaneHeight)
        velHeightC.priority = .defaultHigh
        self.velocityHeightConstraint = velHeightC

        NSLayoutConstraint.activate([
            velHandle.topAnchor.constraint(equalTo: velContainer.topAnchor),
            velHandle.leadingAnchor.constraint(equalTo: velContainer.leadingAnchor),
            velHandle.trailingAnchor.constraint(equalTo: velContainer.trailingAnchor),
            velHandle.heightAnchor.constraint(equalToConstant: 18),

            velLabel.centerYAnchor.constraint(equalTo: velHandle.centerYAnchor),
            velLabel.leadingAnchor.constraint(equalTo: velHandle.leadingAnchor, constant: 6),

            velLane.topAnchor.constraint(equalTo: velHandle.bottomAnchor),
            velLane.leadingAnchor.constraint(equalTo: velContainer.leadingAnchor),
            velLane.trailingAnchor.constraint(equalTo: velContainer.trailingAnchor),
            velLane.bottomAnchor.constraint(equalTo: velContainer.bottomAnchor),
            velHeightC,
        ])

        velHandle.onResize = { [weak self] delta in
            self?.resizeVelocityLane(by: delta)
        }

        // Tempo section
        let tempoContainer = NSView()
        tempoContainer.translatesAutoresizingMaskIntoConstraints = false
        self.tempoContainer = tempoContainer
        containerView.addSubview(tempoContainer)

        let tempoHandle = LaneResizeHandleView(frame: .zero)
        tempoHandle.translatesAutoresizingMaskIntoConstraints = false
        tempoContainer.addSubview(tempoHandle)

        let tempoLabel = NSButton(title: "▾ Tempo", target: self, action: #selector(toggleTempoLane))
        tempoLabel.translatesAutoresizingMaskIntoConstraints = false
        tempoLabel.isBordered = false
        tempoLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        tempoLabel.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        tempoLabel.setAccessibilityLabel("Toggle Tempo Lane")
        self.tempoLabelButton = tempoLabel
        tempoHandle.addSubview(tempoLabel)

        let tempoLaneView = TempoLaneView(frame: .zero)
        tempoLaneView.translatesAutoresizingMaskIntoConstraints = false
        tempoLaneView.roundedCorners = []
        self.tempoLane = tempoLaneView
        tempoContainer.addSubview(tempoLaneView)

        let tempoHeightC = tempoLaneView.heightAnchor.constraint(equalToConstant: tempoLaneHeight)
        tempoHeightC.priority = .defaultHigh
        self.tempoHeightConstraint = tempoHeightC

        NSLayoutConstraint.activate([
            tempoHandle.topAnchor.constraint(equalTo: tempoContainer.topAnchor),
            tempoHandle.leadingAnchor.constraint(equalTo: tempoContainer.leadingAnchor),
            tempoHandle.trailingAnchor.constraint(equalTo: tempoContainer.trailingAnchor),
            tempoHandle.heightAnchor.constraint(equalToConstant: 18),

            tempoLabel.centerYAnchor.constraint(equalTo: tempoHandle.centerYAnchor),
            tempoLabel.leadingAnchor.constraint(equalTo: tempoHandle.leadingAnchor, constant: 6),

            tempoLaneView.topAnchor.constraint(equalTo: tempoHandle.bottomAnchor),
            tempoLaneView.leadingAnchor.constraint(equalTo: tempoContainer.leadingAnchor),
            tempoLaneView.trailingAnchor.constraint(equalTo: tempoContainer.trailingAnchor),
            tempoLaneView.bottomAnchor.constraint(equalTo: tempoContainer.bottomAnchor),
            tempoHeightC,
        ])

        tempoHandle.onResize = { [weak self] delta in
            self?.resizeTempoLane(by: delta)
        }

        // --- Status Bar (bottom of window) ---
        let statusBar = NSHostingView(rootView: PianoRollStatusBarView(store: store, chrome: chromeState, controller: self))
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusBar)
        self.statusBarHost = statusBar

        // Layout
        // The bottom anchor uses high (but not required) priority so the window
        // can shrink below the ideal lane heights on smaller screens.
        let tempoBottomPin = tempoContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        tempoBottomPin.priority = .defaultHigh

        NSLayoutConstraint.activate([
            toolbarHost.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            toolbarHost.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            toolbarHost.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),

            chordRehearsal.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor, constant: 2),
            chordRehearsal.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            chordRehearsal.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            chordRehearsal.heightAnchor.constraint(equalToConstant: 22),

            editor.topAnchor.constraint(equalTo: chordRehearsal.bottomAnchor, constant: 0),
            editor.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            lyrContainer.topAnchor.constraint(equalTo: editor.bottomAnchor),
            lyrContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            lyrContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            velContainer.topAnchor.constraint(equalTo: lyrContainer.bottomAnchor),
            velContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            velContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            tempoContainer.topAnchor.constraint(equalTo: velContainer.bottomAnchor),
            tempoContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tempoContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tempoBottomPin,

            statusBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),

            emptyHost.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor, constant: 6),
            emptyHost.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            emptyHost.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            emptyHost.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // Wire editor callbacks
        configureEditorCallbacks(editor)

        // Wire lane callbacks
        configureLaneCallbacks(velLane, tempoLaneView, lyrLaneView)

        // Apply initial lane visibility from persisted state
        updateLaneVisibility()

        // Initial data push
        rebuildColorCache()
        syncChromeState()
        pushDataToEditor()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Observe app-level spacebar notification for global play/pause
        NotificationCenter.default.addObserver(
            self, selector: #selector(spacebarPlayPauseReceived),
            name: ScoreAppSignals.spacebarPlayPauseNotification, object: nil
        )

        // Use a CADisplayLink to drive store→editor sync and playhead at
        // native display refresh rate.  The link pauses itself when idle
        // (not playing and no pending data push).
        let link = self.view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link

        // Also keep a low-frequency timer for non-rendering store sync
        // (song change detection, playback state transitions, step input).
        // This fires at 10Hz — lightweight, does NOT trigger renders.
        let timer = Timer(timeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleStoreUpdate()
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.updateTimer = timer

        // Immediately respond to track filter changes (e.g., clicking an instrument
        // in the sidebar).  Call pushDataToEditor() synchronously so ghost notes
        // appear in the very same frame — no waiting for the display link or timer.
        //
        // CRITICAL: @Published fires on `willSet`, so `store.selectedTrackFilter`
        // still holds the OLD value when this sink runs.  That's why we update
        // `lastTrackFilter` FIRST, and `activeTrackSelection` reads from
        // `lastTrackFilter` (not from the store).
        // Track filter observation removed — pushed explicitly via trackFilterDidChange()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Feed the actual hosting view width to the store so SwiftUI can
        // select the right toolbar layout (2/3/4-row) via if/else.
        if let hostWidth = toolbarHostView?.bounds.width, hostWidth > 0 {
            let rounded = hostWidth.rounded()
            if store.toolbarAvailableWidth != rounded {
                store.toolbarAvailableWidth = rounded
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Force an immediate width update on first appearance so the correct
        // toolbar layout is selected before the user sees the view.
        if let hostWidth = toolbarHostView?.bounds.width, hostWidth > 0 {
            store.toolbarAvailableWidth = hostWidth.rounded()
        }
        // Center on middle C on first appearance so the user doesn't start at the top
        editorView?.scrollToPitch(60, anchor: 0.5)
        // Stop auto-scroll if the window loses focus mid-drag
        if let window = view.window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window
            )
        }
    }

    @objc private func windowResignedKey() {
        stopAutoScroll()
    }

    @objc private func displayLinkFired(_ sender: CADisplayLink) {
        // During playback, update the playhead every vsync frame
        if store.isPlaying {
            updatePlayheadPosition()
            pushPlayheadOnly()

            // Throttle SwiftUI LCD updates to ~15Hz (every 4 frames at 60fps)
            liveDisplayFrameCounter += 1
            if liveDisplayFrameCounter >= 4 {
                liveDisplayFrameCounter = 0
                store.livePlayheadTick = playheadTick
                store.liveTempoAtPlayhead = tempoAtTick(playheadTick)
            }
        }

        // Push full store data to editor at 10Hz (notes, colors, etc.)
        if displayLinkNeedsDataPush {
            displayLinkNeedsDataPush = false
            pushDataToEditor()
        }

        // Pause the display link when idle (not playing, nothing dirty)
        if !store.isPlaying && !displayLinkNeedsDataPush {
            sender.isPaused = true
        }
    }

    /// Lightweight per-frame push: only updates playhead position across all views.
    /// Runs at display refresh rate (~60fps) for smooth playhead movement.
    private func pushPlayheadOnly() {
        editorView?.playheadTick = playheadTick   // Metal render + ruler via didSet
        lyricsLane?.playheadTick = playheadTick
        velocityLane?.playheadTick = playheadTick
        tempoLane?.playheadTick = playheadTick
        updateFollowTarget(force: false)
    }

    // MARK: - Editor Callbacks

    private func configureEditorCallbacks(_ editor: PianoRollEditorView) {
        editor.onPreviewPitch = { [weak self] pitch in
            self?.store.startPreviewPitch(pitch)
        }
        editor.onEndPreviewPitch = { [weak self] in
            self?.store.stopPreviewPitch()
        }

        editor.onSeek = { [weak self] tick in
            guard let self else { return }
            setPlayhead(tick: tick)
        }

        editor.noteColorProvider = { [weak self] channel, trackIndex in
            self?.noteColorSIMD(channel: channel, trackIndex: trackIndex)
                ?? SIMD4<Float>(0.55, 0.78, 0.55, 1.0)
        }

        editor.onCanvasMouseDown = { [weak self] point, event in
            self?.handleCanvasMouseDown(point: point, event: event)
        }
        editor.onCanvasMouseDragged = { [weak self] point, event in
            self?.handleCanvasMouseDragged(point: point, event: event)
        }
        editor.onCanvasMouseUp = { [weak self] point, event in
            self?.handleCanvasMouseUp(point: point, event: event)
        }

        // Double-click: open note properties
        editor.onCanvasDoubleClick = { [weak self] point, event in
            self?.handleCanvasDoubleClick(point: point, event: event)
        }

        // Right-click: FL Studio-style delete in Draw/Paint, context menu otherwise
        editor.onCanvasRightClick = { [weak self] point, event in
            guard let self else { return nil }
            // C.1/C.2: Right-click delete in Draw and Paint tools
            if self.tool == .draw && !self.isAllTracksConstrainedMode {
                if let note = self.noteAtPoint(point) {
                    self.pushUndo()
                    var notes = self.store.pianoRollNotes
                    notes.removeAll { $0.id == note.id }
                    self.selectedNoteIDs.remove(note.id)
                    self.store.setPianoRollNotesFromEditor(notes)
                }
                return nil  // no context menu
            }
            return self.buildCanvasContextMenu(point: point, event: event)
        }

        // Right-drag: sweep-delete in Draw/Paint tools
        editor.onCanvasRightDragged = { [weak self] point, event in
            guard let self, self.tool == .draw, !self.isAllTracksConstrainedMode else { return }
            if !self.rightDragUndoPushed {
                self.pushUndo()
                self.rightDragUndoPushed = true
            }
            self.eraseNoteAt(point: point)
        }

        // Alt+scroll wheel: velocity adjustment
        editor.onCanvasScrollWheel = { [weak self] point, event in
            guard let self else { return false }
            return self.handleAltScrollVelocity(at: point, deltaY: event.scrollingDeltaY)
        }

        // Keyboard events
        editor.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event: event) ?? false
        }

        // Cursor management
        editor.cursorProvider = { [weak self] point in
            self?.cursorForCanvasPoint(point) ?? .arrow
        }

        // Marker callbacks
        editor.onAddMarker = { [weak self] tick in
            self?.addMarker(at: tick)
        }
        editor.onJumpToMarker = { [weak self] marker in
            self?.setPlayhead(tick: marker.tick)
        }
        editor.onDeleteMarker = { [weak self] id in
            self?.deleteMarker(id: id)
        }
        editor.onRenameMarker = { [weak self] id, name in
            self?.renameMarker(id: id, newName: name)
        }

        // Suno split callbacks
        editor.onAddSunoSplit = { [weak self] tick in
            self?.addSunoSplit(at: tick)
        }
        editor.onDeleteSunoSplit = { [weak self] tick in
            self?.deleteSunoSplit(at: tick)
        }
    }

    // MARK: - Lane Callbacks
    //
    // Wires velocity and tempo lane callbacks so edits flow back to the store.
    // Scroll offset sync is handled here via editor.onScrollOffsetChanged.
    //
    // ## Safe to change
    // - Callback logic inside closures (e.g., how velocity/tempo edits are applied)
    //
    // ## Do NOT change
    // - The callback wiring pattern itself (onVelocityChanged, onTempoChanged, onTempoAdded)
    // - The scroll offset sync mechanism

    private func configureLaneCallbacks(_ velocityLane: VelocityLaneView, _ tempoLane: TempoLaneView, _ lyricsLane: LyricsLaneView) {
        // Velocity: click+drag a bar to change a note's velocity
        velocityLane.onVelocityChanged = { [weak self] noteID, newVelocity in
            guard let self else { return }
            var notes = store.pianoRollNotes
            guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
            notes[index].velocity = max(1, min(127, newVelocity))
            store.setPianoRollNotesFromEditor(notes)
        }

        // Velocity curve painting: Alt+drag sets multiple velocities along a line
        velocityLane.onVelocityBatchChanged = { [weak self] changes in
            guard let self, !changes.isEmpty else { return }
            pushUndo()
            var notes = store.pianoRollNotes
            for (noteID, newVelocity) in changes {
                if let index = notes.firstIndex(where: { $0.id == noteID }) {
                    notes[index].velocity = max(1, min(127, newVelocity))
                }
            }
            store.setPianoRollNotesFromEditor(notes)
        }

        // Tempo: drag a marker to change its BPM
        tempoLane.onTempoChanged = { [weak self] eventIndex, newBPM in
            guard let self else { return }
            guard eventIndex < store.pianoRollTempoEvents.count else { return }
            let clamped = max(20, min(300, newBPM))
            store.pianoRollTempoEvents[eventIndex].bpm = clamped
            // Keep tempoBPM in sync when the tick-0 event is edited
            if store.pianoRollTempoEvents[eventIndex].tick == 0 {
                store.tempoBPM = clamped
            }
            store.isDirty = true
            // Immediately sync lane so BPM range stays consistent during drag
            tempoLane.tempoEvents = store.pianoRollTempoEvents
        }

        // Tempo: click/right-click to add a new tempo point
        tempoLane.onTempoAdded = { [weak self] tick, bpm in
            guard let self else { return }
            let clamped = max(20, min(300, bpm))
            store.pianoRollTempoEvents.append(TempoPoint(tick: tick, bpm: clamped))
            store.pianoRollTempoEvents.sort { $0.tick < $1.tick }
            // Sync tempoBPM with the (possibly new) tick-0 event
            if let first = store.pianoRollTempoEvents.first, first.tick == 0 {
                store.tempoBPM = first.bpm
            }
            store.isDirty = true
            // Immediately sync lane so newly added point is visible and draggable
            tempoLane.tempoEvents = store.pianoRollTempoEvents
        }

        // Paintbrush: set BPM at the snapped beat tick and clear any sub-beat
        // events in the range (snappedTick, snappedTick + beatTicks) so the
        // painted value fills the entire beat.
        tempoLane.onTempoPainted = { [weak self] snappedTick, beatTicks, bpm in
            guard let self else { return }
            let clamped = max(20, min(300, bpm))
            let nextBeatTick = snappedTick + beatTicks

            // 1. Remove all events strictly between this beat and the next
            store.pianoRollTempoEvents.removeAll { $0.tick > snappedTick && $0.tick < nextBeatTick }

            // 2. Set or insert the event at the snapped beat tick
            if let idx = store.pianoRollTempoEvents.firstIndex(where: { $0.tick == snappedTick }) {
                store.pianoRollTempoEvents[idx].bpm = clamped
            } else {
                store.pianoRollTempoEvents.append(TempoPoint(tick: snappedTick, bpm: clamped))
                store.pianoRollTempoEvents.sort { $0.tick < $1.tick }
            }

            // Sync tempoBPM with tick-0 event
            if let first = store.pianoRollTempoEvents.first, first.tick == 0 {
                store.tempoBPM = first.bpm
            }
            store.isDirty = true
            tempoLane.tempoEvents = store.pianoRollTempoEvents
        }

        tempoLane.onTempoPaintFinished = { [weak self, weak tempoLane] in
            guard let self else { return }
            simplifyPaintedTempoEvents()
            tempoLane?.tempoEvents = store.pianoRollTempoEvents
        }

        // Tempo: right-click on existing marker to delete it
        tempoLane.onTempoDeleted = { [weak self] eventIndex in
            guard let self else { return }
            guard eventIndex < store.pianoRollTempoEvents.count,
                  store.pianoRollTempoEvents.count > 1 else { return }
            store.pianoRollTempoEvents.remove(at: eventIndex)
            // Sync tempoBPM with the new first event
            if let first = store.pianoRollTempoEvents.first, first.tick == 0 {
                store.tempoBPM = first.bpm
            }
            store.isDirty = true
            tempoLane.tempoEvents = store.pianoRollTempoEvents
        }

        // Lyrics: syllable edited in the inline text field
        lyricsLane.onSyllableChanged = { [weak self] noteID, newSyllable in
            guard let self else { return }
            // Note: libretto is read-only in Novotro Score — syllable edits only update note data,
            // they do NOT propagate back to the libretto text.

            // Use lightweight single-note update — avoids O(n log n) sort of all notes
            store.updatePianoRollNote(id: noteID) { $0.lyricSyllable = newSyllable }

            // Update alignment: remove if syllable cleared.
            if newSyllable == nil || newSyllable?.isEmpty == true {
                store.removeLyricAlignment(noteID: noteID)
            }
        }

        // Lyrics: auto-align requested — syllabify libretto text and align to vocal notes
        lyricsLane.onAutoAlignRequested = { [weak self] in
            guard let self else { return }
            self.autoAlignLyrics()
        }

        // Lyrics: preview accepted — commit preview alignments to notes + build alignment mapping
        lyricsLane.onPreviewAccepted = { [weak self] in
            guard let self, let previews = self.lyricsLane?.previewAlignments else { return }
            pushUndo()
            var notes = store.pianoRollNotes
            for (noteID, syllable) in previews {
                if let idx = notes.firstIndex(where: { $0.id == noteID }) {
                    notes[idx].lyricSyllable = syllable
                }
            }
            store.setPianoRollNotesFromEditor(notes)
            self.lyricsLane?.previewAlignments = nil

            // Build the lyric alignment mapping from the committed syllables
            let trackKeys = resolveVocalTrackKeys()
            let trackKey = trackKeys.first ?? "default"
            if !lastAutoAlignSyllabified.isEmpty {
                store.buildLyricAlignmentsFromNotes(
                    trackKey: trackKey,
                    syllabifiedWords: lastAutoAlignSyllabified
                )
                lastAutoAlignSyllabified = []
            }

            store.statusMessage = "Lyrics alignment accepted — \(previews.count) syllables committed"
        }

        // Lyrics: preview rejected — discard preview alignments
        lyricsLane.onPreviewRejected = { [weak self] in
            self?.lyricsLane?.previewAlignments = nil
            self?.store.statusMessage = "Lyrics alignment preview discarded"
        }

        // Lyrics: forward unhandled keyboard events to main handler (spacebar, etc.)
        lyricsLane.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event: event) ?? false
        }

        // Lyrics: Option+click split — popup menu lets user choose split point
        lyricsLane.onSyllableSplit = { [weak self] noteID, splitPos in
            self?.splitSyllableAtNote(noteID, at: splitPos)
        }

        // Lyrics: Option+Shift+click join — merge this syllable with the next note's syllable
        lyricsLane.onSyllableJoin = { [weak self] noteID in
            self?.joinSyllableWithNext(noteID)
        }

        // Lyrics: drag started — push undo snapshot before syllable rearrangement
        lyricsLane.onSyllableDragStarted = { [weak self] in
            self?.pushUndo()
        }

        // Lyrics: drag syllable from one note to another.
        // Shift-drag moves this syllable and all following assignments as a block.
        lyricsLane.onSyllableDragged = { [weak self] sourceID, targetID, shiftMode in
            guard let self else { return }
            var notes = self.store.pianoRollNotes
            guard let sourceIdx = notes.firstIndex(where: { $0.id == sourceID }),
                  let targetIdx = notes.firstIndex(where: { $0.id == targetID }) else { return }

            if shiftMode {
                let vocalIndices = self.resolveVocalTrackIndices()
                let orderedIDs = notes
                    .filter { vocalIndices.isEmpty || vocalIndices.contains($0.trackIndex) }
                    .sorted {
                        if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
                        if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
                        if $0.channel != $1.channel { return $0.channel < $1.channel }
                        if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    .map(\.id)

                guard let dragIdx = orderedIDs.firstIndex(of: sourceID),
                      let dropIdx = orderedIDs.firstIndex(of: targetID) else { return }
                let offset = dropIdx - dragIdx
                guard offset != 0 else { return }

                let affectedIDs = Array(orderedIDs[dragIdx...])
                let noteIndexByID = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.id, $0) })
                let carried = affectedIDs.map { id -> String? in
                    guard let idx = noteIndexByID[id] else { return nil }
                    return notes[idx].lyricSyllable
                }

                for id in affectedIDs {
                    if let idx = noteIndexByID[id] {
                        notes[idx].lyricSyllable = nil
                    }
                }

                var remap: [UUID: UUID] = [:]
                var removed = Set<UUID>()
                for (i, oldID) in affectedIDs.enumerated() {
                    let newIdx = dragIdx + offset + i
                    if newIdx >= 0, newIdx < orderedIDs.count {
                        let newID = orderedIDs[newIdx]
                        remap[oldID] = newID
                        if let idx = noteIndexByID[newID] {
                            notes[idx].lyricSyllable = carried[i]
                        }
                    } else {
                        removed.insert(oldID)
                    }
                }

                self.store.remapLyricAlignments(noteRemap: remap, removedNoteIDs: removed)
            } else {
                let temp = notes[sourceIdx].lyricSyllable
                notes[sourceIdx].lyricSyllable = notes[targetIdx].lyricSyllable
                notes[targetIdx].lyricSyllable = temp
                self.store.remapLyricAlignments(noteRemap: [sourceID: targetID, targetID: sourceID])
            }

            self.store.setPianoRollNotesFromEditor(notes)
        }

        // Note: timed lyric line move/remove callbacks are not wired in Novotro Score
        // because the libretto is read-only. Timing tags are managed separately.

        // Sync horizontal scroll offset from editor to all visible lanes
        editorView?.onScrollOffsetChanged = { [weak self] offset in
            self?.lyricsLane?.scrollOffset = offset
            self?.velocityLane?.scrollOffset = offset
            self?.tempoLane?.scrollOffset = offset
        }

        // Wire horizontal scroll from all lanes back to the editor scroll view
        let scrollHandler: (CGFloat) -> Void = { [weak self] deltaX in
            guard let self, let editor = self.editorView else { return }
            let scrollView = editor.scrollView
            var origin = scrollView.contentView.bounds.origin
            origin.x = max(0, origin.x - deltaX)
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        lyricsLane.onHorizontalScroll = scrollHandler
        velocityLane.onHorizontalScroll = scrollHandler
        tempoLane.onHorizontalScroll = scrollHandler
    }

    // MARK: - Lane Toggle Actions

    @objc private func toggleVelocityLane() {
        velocityLaneVisible.toggle()
    }

    @objc private func toggleTempoLane() {
        tempoLaneVisible.toggle()
    }

    @objc private func toggleLyricsLane() {
        lyricsLaneVisible.toggle()
    }

    @objc private func lyricsAutoAlignTapped() {
        lyricsLane?.onAutoAlignRequested?()
    }

    @objc private func lyricsPreviewAcceptTapped() {
        lyricsLane?.onPreviewAccepted?()
        lyricsPreviewAcceptButton?.isHidden = true
        lyricsPreviewRejectButton?.isHidden = true
    }

    @objc private func lyricsPreviewRejectTapped() {
        lyricsLane?.onPreviewRejected?()
        lyricsPreviewAcceptButton?.isHidden = true
        lyricsPreviewRejectButton?.isHidden = true
    }

    /// Updates the visibility of the lane views based on persisted state.
    /// The label/handle remains visible — only the CoreGraphics lane hides.
    /// We set the height constraint to 0 when collapsed so the container shrinks
    /// to just the handle height.
    private func updateLaneVisibility() {
        // Lyrics lane
        let lyricsVisible = lyricsLaneVisible
        lyricsLane?.isHidden = !lyricsVisible
        lyricsHeightConstraint?.constant = lyricsVisible ? lyricsLaneHeight : 0
        lyricsLabelButton?.title = lyricsVisible ? "▾ Lyrics" : "▸ Lyrics"
        lyricsAutoAlignButton?.isHidden = !lyricsVisible

        // Velocity lane
        let velVisible = velocityLaneVisible
        velocityLane?.isHidden = !velVisible
        velocityHeightConstraint?.constant = velVisible ? velocityLaneHeight : 0
        velocityLabelButton?.title = velVisible ? "▾ Velocity" : "▸ Velocity"

        // Tempo lane
        let tempoVisible = tempoLaneVisible
        tempoLane?.isHidden = !tempoVisible
        tempoHeightConstraint?.constant = tempoVisible ? tempoLaneHeight : 0
        tempoLabelButton?.title = tempoVisible ? "▾ Tempo" : "▸ Tempo"

        // All lane views use flat bottom edges (no rounded corners)
        lyricsLane?.roundedCorners = []
        velocityLane?.roundedCorners = []
        tempoLane?.roundedCorners = []
    }

    // MARK: - Lane Resize

    private func resizeVelocityLane(by delta: CGFloat) {
        guard let c = velocityHeightConstraint else { return }
        let newHeight = max(30, min(200, c.constant - delta))
        c.constant = newHeight
        velocityLaneHeight = newHeight
    }

    private func resizeTempoLane(by delta: CGFloat) {
        guard let c = tempoHeightConstraint else { return }
        let newHeight = max(30, min(200, c.constant - delta))
        c.constant = newHeight
        tempoLaneHeight = newHeight
    }

    private func resizeLyricsLane(by delta: CGFloat) {
        guard let c = lyricsHeightConstraint else { return }
        let newHeight = max(30, min(200, c.constant - delta))
        c.constant = newHeight
        lyricsLaneHeight = newHeight
    }

    // MARK: - Store Observation

    private func handleStoreUpdate() {
        var needsDataPush = false

        // Song change detection
        let currentSongID = store.selectedMidiID
        if currentSongID != lastSongID {
            lastSongID = currentSongID
            selectedNoteIDs.removeAll()
            playheadTick = 0
            store.livePlayheadTick = 0
            rebuildColorCache()
            needsDataPush = true
            // Center on middle C so the user doesn't have to scroll down from the top
            editorView?.scrollToPitch(60, anchor: 0.5)
            // Reclaim keyboard focus so spacebar/shortcuts work immediately after song switch.
            // Without this, clicking in the song list leaves focus on the list/inspector text fields.
            view.window?.makeFirstResponder(view)
            // Pre-sync the tempo snapshot so the hot-restart check below doesn't fire
            // when continuous play advances songs. isPlaying is set optimistically during
            // transition, so without this the tempo-change detector would call seekPlayback()
            // immediately (tick=0 → playPianoRoll), causing a spurious double-start.
            lastTempoSnapshot = store.pianoRollTempoEvents
        }

        // Playback state
        if store.isPlaying && !wasPlaying {
            startPlayhead()
            needsDataPush = true
        } else if !store.isPlaying && wasPlaying {
            stopPlayhead()
            needsDataPush = true
        }
        wasPlaying = store.isPlaying

        // Track filter change → update preview sampler for note audition.
        // Do NOT restart playback — the filter is a visual/editing concern
        // and should not interrupt ongoing MIDI playback.
        let currentFilter = store.selectedTrackFilter
        if currentFilter != lastTrackFilter {
            lastTrackFilter = currentFilter
            store.updatePreviewMappingForTrackFilter()
            needsDataPush = true
        }

        // Step input: initialize step position on toggle, then sync playhead
        if store.midiInputStepMode && !wasStepMode {
            store.stepInputTick = playheadTick
            needsDataPush = true
        }
        wasStepMode = store.midiInputStepMode
        if store.midiInputStepMode && !store.isPlaying {
            playheadTick = store.stepInputTick
        }

        // Check store generation counter for data changes (notes, mappings, etc.)
        let gen = store.changeGeneration
        if gen != lastStoreGeneration {
            lastStoreGeneration = gen
            needsDataPush = true
        }

        // Detect preview note changes (generated parts, composed melodies)
        // These don't bump changeGeneration because they're previews, not commits.
        let currentPartID = store.generatedPart.map { "\($0.instrumentName):\($0.notes.count)" }
        if currentPartID != lastPreviewPartID {
            lastPreviewPartID = currentPartID
            needsDataPush = true
        }
        let currentMelodyCount = store.composedMelody?.count
        if currentMelodyCount != lastComposedMelodyCount {
            lastComposedMelodyCount = currentMelodyCount
            needsDataPush = true
        }

        // Hot-restart sequencer when tempo events change during playback,
        // so the baked-in MIDI tempo map stays in sync with the graph.
        if store.isPlaying {
            let currentTempo = store.pianoRollTempoEvents
            if currentTempo != lastTempoSnapshot {
                lastTempoSnapshot = currentTempo
                rebuildPlayheadTempoCache()
                store.seekPlayback(to: playheadTick, trackFilter: nil)
            }
        }

        // Push tool to tempo lane immediately (not gated by display link)
        tempoLane?.currentTool = tool

        // Only wake the display link when something actually changed
        if needsDataPush {
            displayLinkNeedsDataPush = true
            displayLink?.isPaused = false
        }
    }

    private func pushDataToEditor() {
        guard let editor = editorView else { return }

        let hasSong = store.selectedMidiID != nil

        // Show/hide editor vs empty state
        editor.isHidden = !hasSong
        if let emptyHost = view.subviews.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("emptyState")
        }) {
            emptyHost.isHidden = hasSong
        }

        // Show/hide lane containers with the editor
        lyricsContainer?.isHidden = !hasSong
        velocityContainer?.isHidden = !hasSong
        tempoContainer?.isHidden = !hasSong

        guard hasSong else {
            syncChromeState()
            return
        }

        let tpq = max(1, store.ticksPerQuarter)
        let safePixelsPerQuarter = max(24, min(pixelsPerQuarter, 340))
        let ppt = safePixelsPerQuarter / CGFloat(tpq)

        // Grid width: NO 14K clamp — Metal handles arbitrarily large canvases
        let lengthTicks = max(tpq * 32, store.pianoRollLengthTicks)
        let gridWidth = CGFloat(lengthTicks) * ppt + 220

        editor.ticksPerQuarter = tpq
        editor.pixelsPerTick = ppt
        editor.rowHeight = editorRowHeight
        editor.gridWidth = gridWidth
        editor.scaleHighlightPitchClasses = scaleType.pitchClasses(root: scaleRoot)

        // Persist zoom to UserDefaults when changed
        if pixelsPerQuarter != lastSavedPixelsPerQuarter {
            lastSavedPixelsPerQuarter = pixelsPerQuarter
            UserDefaults.standard.set(Double(pixelsPerQuarter), forKey: Self.zoomHorizontalKey)
        }
        if editorRowHeight != lastSavedEditorRowHeight {
            lastSavedEditorRowHeight = editorRowHeight
            UserDefaults.standard.set(Double(editorRowHeight), forKey: Self.zoomVerticalKey)
        }
        editor.velocityColorEnabled = velocityColorEnabled
        editor.snapTickSpan = snap == .line
            ? snap.dynamicTickSpan(ticksPerQuarter: tpq, pixelsPerQuarter: pixelsPerQuarter)
            : snap.tickSpan(ticksPerQuarter: tpq)
        editor.timeSignatures = store.pianoRollTimeSignatures
        editor.markers = store.pianoRollMarkers
        editor.sunoSplits = store.sunoSplitTicks

        // Filter notes by active track selection
        let activeFilter = activeTrackSelection
        let visibleNotes: [PianoRollNote]
        if let filter = activeFilter {
            visibleNotes = store.pianoRollNotes.filter { filter.contains($0.trackIndex) }
        } else {
            visibleNotes = store.pianoRollNotes
        }

        // Ghost notes: show notes from non-active tracks as faded background,
        // but keep the explicit toolbar toggle authoritative.
        let ghostNotes: [PianoRollNote]
        if let filter = activeFilter {
            ghostNotes = showGhostNotes
                ? store.pianoRollNotes.filter { !filter.contains($0.trackIndex) }
                : []
        } else {
            ghostNotes = []
        }

        #if DEBUG
        // Log every filter transition so we can diagnose ghost note issues
        let prevGhostCount = editor.ghostNotes.count
        let prevNoteCount = editor.notes.count
        if visibleNotes.count != prevNoteCount || ghostNotes.count != prevGhostCount {
            let total = store.pianoRollNotes.count
            print("[GHOST] pushDataToEditor: lastTrackFilter=\(lastTrackFilter), activeFilter=\(activeFilter.map { "\($0)" } ?? "nil"), visible=\(visibleNotes.count), ghost=\(ghostNotes.count), total=\(total) (was: visible=\(prevNoteCount), ghost=\(prevGhostCount))")
        }
        #endif

        editor.notes = visibleNotes
        editor.ghostNotes = ghostNotes

        // Preview notes from generated parts or composed melodies
        var preview: [PianoRollNote] = []
        if let part = store.generatedPart {
            preview.append(contentsOf: part.notes)
        }
        if let melody = store.composedMelody {
            preview.append(contentsOf: melody)
        }
        editor.previewNotes = preview

        // Sync selection bidirectionally with ScoreStore
        if selectedNoteIDs != store.selectedNoteIDs {
            selectedNoteIDs = store.selectedNoteIDs
        }
        let visibleNoteIDs = Set(visibleNotes.map(\.id))
        if !selectedNoteIDs.isSubset(of: visibleNoteIDs) {
            selectedNoteIDs.formIntersection(visibleNoteIDs)
        }
        editor.selectedNoteIDs = selectedNoteIDs
        editor.playheadTick = playheadTick
        editor.noteGroups = store.pianoRollNoteGroups
        if let expMap = store.activeExpressionMap {
            editor.articulationLookup = Dictionary(uniqueKeysWithValues: expMap.articulations.map { ($0.id, $0) })
        } else {
            editor.articulationLookup = [:]
        }

        // Multi-voice lanes: compute lane boundaries from note pitch ranges
        if multiVoiceMode {
            editor.voiceLanes = computeVoiceLanes(from: visibleNotes)
        } else {
            editor.voiceLanes = []
        }

        // --- Push data to velocity & tempo lanes ---

        let kbOffset = editor.keyboardWidth

        if let velLane = velocityLane {
            velLane.keyboardOffset = kbOffset
            velLane.notes = visibleNotes
            velLane.selectedNoteIDs = selectedNoteIDs
            velLane.pixelsPerTick = ppt
            velLane.gridWidth = gridWidth
            velLane.playheadTick = playheadTick
            velLane.colorProvider = { [weak self] channel, trackIndex in
                self?.noteColorSIMD(channel: channel, trackIndex: trackIndex)
                    ?? SIMD4<Float>(0.55, 0.78, 0.55, 1.0)
            }
            // Push ghost notes to velocity lane for ghost velocity bars
            velLane.ghostNotes = ghostNotes
        }

        if let tLane = tempoLane {
            tLane.keyboardOffset = kbOffset
            tLane.tempoEvents = store.pianoRollTempoEvents
            tLane.pixelsPerTick = ppt
            tLane.ticksPerQuarter = tpq
            tLane.gridWidth = gridWidth
            tLane.playheadTick = playheadTick
            tLane.currentTool = tool

            // Update label to show event count when there are multiple distinct events
            let eventCount = store.pianoRollTempoEvents.count
            let tempoVisible = tempoLaneVisible
            let arrow = tempoVisible ? "▾" : "▸"
            if eventCount > 1 {
                tempoLabelButton?.title = "\(arrow) Tempo (\(eventCount))"
            } else {
                tempoLabelButton?.title = "\(arrow) Tempo"
            }
        }

        // --- Push data to lyrics lane ---
        if let lLane = lyricsLane {
            lLane.keyboardOffset = kbOffset
            lLane.pixelsPerTick = ppt
            lLane.ticksPerQuarter = tpq
            lLane.gridWidth = gridWidth
            lLane.playheadTick = playheadTick

            // Filter to vocal track notes only
            let vocalIndices = resolveVocalTrackIndices()
            if vocalIndices.isEmpty {
                // No vocal tracks — show all notes in single row
                lLane.notes = visibleNotes
                lLane.vocalTrackKeys = []
                lLane.trackLabels = [:]
                lLane.trackIndicesByKey = [:]
            } else {
                lLane.notes = store.pianoRollNotes.filter { vocalIndices.contains($0.trackIndex) }
                lLane.vocalTrackKeys = resolveVocalTrackKeys()
                lLane.trackLabels = resolveVocalTrackLabels()
                lLane.trackIndicesByKey = resolveVocalTrackIndicesByKey()
            }

            lLane.colorProvider = { [weak self] channel, trackIndex in
                self?.noteColorSIMD(channel: channel, trackIndex: trackIndex)
                    ?? SIMD4<Float>(0.55, 0.78, 0.55, 1.0)
            }

            // Push timed lyric lines from embedded tags (new system)
            let newTimedLines = store.parsedLyricLines
            lLane.timedLyricLines = newTimedLines

            // Push standalone lyric cues as fallback (deprecated — used when no embedded tags)
            lLane.lyricCues = store.pianoRollLyricCues

            // Push per-track colors for label tinting
            lLane.trackColors = resolveVocalTrackColors()
        }

        syncChromeState()

    }

    // MARK: - Vocal Track Resolution

    /// Returns the set of track indices that belong to vocal tracks
    /// (based on `InstrumentMapping.trackRole == .vocal`).
    private func resolveVocalTrackIndices() -> Set<Int> {
        var result = Set<Int>()
        for (pairKey, mappingKey) in store.pianoRollChannelKeyByTrackChannel {
            guard let mapping = store.instrumentMappings[mappingKey],
                  mapping.trackRole == .vocal else { continue }
            // pairKey format: "trackIndex:channel"
            if let trackStr = pairKey.split(separator: ":").first,
               let trackIdx = Int(trackStr) {
                result.insert(trackIdx)
            }
        }
        return result
    }

    /// Returns an ordered list of vocal mapping keys (channelKey values).
    private func resolveVocalTrackKeys() -> [String] {
        var keys: [(key: String, order: Int)] = []
        for (_, mappingKey) in store.pianoRollChannelKeyByTrackChannel {
            guard let mapping = store.instrumentMappings[mappingKey],
                  mapping.trackRole == .vocal else { continue }
            if !keys.contains(where: { $0.key == mappingKey }) {
                keys.append((mappingKey, mapping.sortOrder ?? 999))
            }
        }
        return keys.sorted { $0.order < $1.order }.map(\.key)
    }

    /// Returns a mapping from vocal track key → display name.
    private func resolveVocalTrackLabels() -> [String: String] {
        var result: [String: String] = [:]
        for (_, mappingKey) in store.pianoRollChannelKeyByTrackChannel {
            guard let mapping = store.instrumentMappings[mappingKey],
                  mapping.trackRole == .vocal else { continue }
            result[mappingKey] = mapping.displayName
        }
        return result
    }

    /// Returns a mapping from vocal track key → set of track indices.
    private func resolveVocalTrackIndicesByKey() -> [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for (pairKey, mappingKey) in store.pianoRollChannelKeyByTrackChannel {
            guard let mapping = store.instrumentMappings[mappingKey],
                  mapping.trackRole == .vocal else { continue }
            if let trackStr = pairKey.split(separator: ":").first,
               let trackIdx = Int(trackStr) {
                result[mappingKey, default: []].insert(trackIdx)
            }
        }
        return result
    }

    /// Returns a mapping from vocal track key → NSColor for track label tinting.
    private func resolveVocalTrackColors() -> [String: NSColor] {
        var result: [String: NSColor] = [:]
        for (pairKey, mappingKey) in store.pianoRollChannelKeyByTrackChannel {
            guard let mapping = store.instrumentMappings[mappingKey],
                  mapping.trackRole == .vocal else { continue }
            guard result[mappingKey] == nil else { continue }
            // Use colorHex from mapping if available
            if let hex = mapping.colorHex, !hex.isEmpty,
               let nsColor = ColorHex.nsColor(from: hex) {
                result[mappingKey] = nsColor
            } else {
                // Derive color from the color provider using a representative track index
                if let trackStr = pairKey.split(separator: ":").first,
                   let trackIdx = Int(trackStr),
                   let chanStr = pairKey.split(separator: ":").last,
                   let channel = Int(chanStr) {
                    let simd = noteColorSIMD(channel: channel, trackIndex: trackIdx)
                    result[mappingKey] = NSColor(
                        red: CGFloat(simd.x),
                        green: CGFloat(simd.y),
                        blue: CGFloat(simd.z),
                        alpha: 1.0
                    )
                }
            }
        }
        return result
    }

    // MARK: - Lyrics Auto-Alignment

    /// Runs the full auto-align pipeline:
    /// 1. Get lyrics from the selected libretto file
    /// 2. Syllabify using SyllabificationService
    /// 3. Get vocal notes sorted by tick
    /// 4. Run LyricAligner.align()
    /// 5. Set preview alignments on the lyrics lane
    // MARK: - Syllable Split / Join (Option+click, Option+Shift+click)

    /// Splits the syllable at a given note into two parts.
    /// If in preview mode, operates on preview assignments.
    /// If in normal mode, operates on committed lyricSyllable data.
    /// The first half stays on this note; the second half goes to the next unassigned note.
    /// Paste text from the system pasteboard as lyrics onto vocal notes.
    /// Syllabifies the text and assigns syllables sequentially to notes.
    /// Uses selected notes if any are selected, otherwise all vocal notes in tick order.
    @available(macOS 26.0, *)
    private func pasteLyricsToNotes(_ text: String) {
        let syllabified = SyllabificationService.syllabify(text)
        var allSyllables: [String] = []
        for (wordIdx, entry) in syllabified.enumerated() {
            for (sylIdx, syl) in entry.syllables.enumerated() {
                let isLast = sylIdx == entry.syllables.count - 1
                if isLast {
                    allSyllables.append(syl)
                } else {
                    allSyllables.append(syl + "-")
                }
            }
            _ = wordIdx  // suppress unused warning
        }

        guard !allSyllables.isEmpty else {
            store.statusMessage = "No syllables found in pasted text"
            return
        }

        // Get target notes: selected vocal notes, or all vocal notes
        let vocalIndices = resolveVocalTrackIndices()
        var targetNotes: [PianoRollNote]
        if !selectedNoteIDs.isEmpty {
            targetNotes = store.pianoRollNotes
                .filter { selectedNoteIDs.contains($0.id) }
                .sorted { $0.startTick < $1.startTick }
        } else if !vocalIndices.isEmpty {
            targetNotes = store.pianoRollNotes
                .filter { vocalIndices.contains($0.trackIndex) }
                .sorted { $0.startTick < $1.startTick }
        } else {
            targetNotes = store.pianoRollNotes
                .sorted { $0.startTick < $1.startTick }
        }

        guard !targetNotes.isEmpty else {
            store.statusMessage = "No notes to assign lyrics to"
            return
        }

        pushUndo()
        var notes = store.pianoRollNotes
        let assignCount = min(allSyllables.count, targetNotes.count)

        for i in 0..<assignCount {
            let noteID = targetNotes[i].id
            if let idx = notes.firstIndex(where: { $0.id == noteID }) {
                notes[idx].lyricSyllable = allSyllables[i]
            }
        }

        store.setPianoRollNotesFromEditor(notes)

        let remaining = allSyllables.count - assignCount
        if remaining > 0 {
            store.statusMessage = "Pasted \(assignCount) syllables — \(remaining) unassigned (not enough notes)"
        } else {
            store.statusMessage = "Pasted \(assignCount) syllables to notes"
        }
    }

    private func splitSyllableAtNote(_ noteID: UUID, at splitPos: Int) {
        // Determine source of syllable text
        let isPreviewMode = lyricsLane?.previewAlignments != nil
        let syllable: String?
        if isPreviewMode {
            syllable = lyricsLane?.previewAlignments?[noteID]
        } else {
            syllable = store.pianoRollNotes.first(where: { $0.id == noteID })?.lyricSyllable
        }

        guard let text = syllable, !text.isEmpty, text != "_" else {
            store.statusMessage = "No syllable to split on this note"
            return
        }

        // Strip trailing hyphen for splitting purposes
        let cleanText = text.hasSuffix("-") ? String(text.dropLast()) : text

        guard cleanText.count >= 2, splitPos > 0, splitPos < cleanText.count else {
            store.statusMessage = "Syllable too short to split"
            return
        }

        let firstHalf = String(cleanText.prefix(splitPos))
        let secondHalf = String(cleanText.suffix(cleanText.count - splitPos))

        guard !firstHalf.isEmpty && !secondHalf.isEmpty else {
            store.statusMessage = "Cannot split this syllable further"
            return
        }

        let sortedNotes = store.pianoRollNotes
            .filter { resolveVocalTrackIndices().isEmpty || resolveVocalTrackIndices().contains($0.trackIndex) }
            .sorted { $0.startTick < $1.startTick }
        guard let noteIdx = sortedNotes.firstIndex(where: { $0.id == noteID }) else { return }

        // Next note is the immediate successor in tick order
        guard noteIdx + 1 < sortedNotes.count else {
            store.statusMessage = "No next note available for the second half"
            return
        }
        let nextNoteID = sortedNotes[noteIdx + 1].id

        // First half gets a trailing hyphen to indicate word continues
        let firstWithHyphen = firstHalf + "-"
        let secondWithSuffix = text.hasSuffix("-") ? secondHalf + "-" : secondHalf

        if isPreviewMode {
            var previews = lyricsLane?.previewAlignments ?? [:]

            // Shift all syllables from nextNote onward by one position to make room
            let noteIDs = sortedNotes.map(\.id)
            let startShiftIdx = noteIdx + 1
            // Find the last occupied note from startShiftIdx onward
            var lastOccupied = startShiftIdx - 1
            for i in startShiftIdx..<noteIDs.count {
                if let s = previews[noteIDs[i]], !s.isEmpty { lastOccupied = i }
            }
            // Shift backwards (from last to first) to avoid overwriting
            if lastOccupied >= startShiftIdx {
                for i in stride(from: min(lastOccupied + 1, noteIDs.count - 1), through: startShiftIdx + 1, by: -1) {
                    previews[noteIDs[i]] = previews[noteIDs[i - 1]]
                }
            }

            previews[noteID] = firstWithHyphen
            previews[nextNoteID] = secondWithSuffix
            lyricsLane?.previewAlignments = previews
            lyricsLane?.onPreviewAlignmentsChanged?(previews)
        } else {
            pushUndo()
            var notes = store.pianoRollNotes

            // Build a map of note ID → index in the mutable array
            let noteIDToIdx: [UUID: Int] = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.id, $0) })

            // Shift syllables forward by one from the split point to make room
            let orderedIDs = sortedNotes.map(\.id)
            let startShiftIdx = noteIdx + 1
            var lastOccupied = startShiftIdx - 1
            for i in startShiftIdx..<orderedIDs.count {
                if let idx = noteIDToIdx[orderedIDs[i]],
                   let s = notes[idx].lyricSyllable, !s.isEmpty {
                    lastOccupied = i
                }
            }
            // Shift backwards to avoid overwriting
            if lastOccupied >= startShiftIdx {
                for i in stride(from: min(lastOccupied + 1, orderedIDs.count - 1), through: startShiftIdx + 1, by: -1) {
                    if let fromIdx = noteIDToIdx[orderedIDs[i - 1]],
                       let toIdx = noteIDToIdx[orderedIDs[i]] {
                        notes[toIdx].lyricSyllable = notes[fromIdx].lyricSyllable
                    }
                }
            }

            // Place the split halves
            if let idx = noteIDToIdx[noteID] {
                notes[idx].lyricSyllable = firstWithHyphen
            }
            if let idx = noteIDToIdx[nextNoteID] {
                notes[idx].lyricSyllable = secondWithSuffix
            }
            store.setPianoRollNotesFromEditor(notes)
        }

        store.statusMessage = "Split: \"\(firstHalf)\" + \"\(secondHalf)\""
    }

    /// Joins the syllable at a given note with the next note's syllable.
    /// The combined text stays on the current note; the next note's syllable is cleared.
    private func joinSyllableWithNext(_ noteID: UUID) {
        let isPreviewMode = lyricsLane?.previewAlignments != nil

        let sortedNotes = store.pianoRollNotes
            .filter { resolveVocalTrackIndices().isEmpty || resolveVocalTrackIndices().contains($0.trackIndex) }
            .sorted { $0.startTick < $1.startTick }

        guard let noteIdx = sortedNotes.firstIndex(where: { $0.id == noteID }) else { return }

        // Get current syllable
        let currentSyllable: String?
        if isPreviewMode {
            currentSyllable = lyricsLane?.previewAlignments?[noteID]
        } else {
            currentSyllable = sortedNotes[noteIdx].lyricSyllable
        }

        guard let current = currentSyllable, !current.isEmpty, current != "_" else {
            store.statusMessage = "No syllable to join on this note"
            return
        }

        // Find the next note with a syllable
        var nextNoteID: UUID?
        var nextSyllable: String?
        for i in (noteIdx + 1)..<sortedNotes.count {
            let candidate = sortedNotes[i]
            let syl: String?
            if isPreviewMode {
                syl = lyricsLane?.previewAlignments?[candidate.id]
            } else {
                syl = candidate.lyricSyllable
            }
            if let s = syl, !s.isEmpty, s != "_" {
                nextNoteID = candidate.id
                nextSyllable = s
                break
            }
        }

        guard let targetID = nextNoteID, let targetSyl = nextSyllable else {
            store.statusMessage = "No next syllable to join with"
            return
        }

        // Join: strip trailing hyphen from current, then concatenate
        let cleanCurrent = current.hasSuffix("-") ? String(current.dropLast()) : current
        let cleanTarget = targetSyl.hasSuffix("-") ? String(targetSyl.dropLast()) : targetSyl
        // Preserve trailing hyphen from the target if it had one (word continues beyond)
        let joined = cleanCurrent + cleanTarget + (targetSyl.hasSuffix("-") ? "-" : "")

        if isPreviewMode {
            var previews = lyricsLane?.previewAlignments ?? [:]
            previews[noteID] = joined
            previews[targetID] = nil
            lyricsLane?.previewAlignments = previews
            lyricsLane?.onPreviewAlignmentsChanged?(previews)
        } else {
            pushUndo()
            var notes = store.pianoRollNotes
            if let idx = notes.firstIndex(where: { $0.id == noteID }) {
                notes[idx].lyricSyllable = joined
            }
            if let idx = notes.firstIndex(where: { $0.id == targetID }) {
                notes[idx].lyricSyllable = nil
            }
            store.setPianoRollNotesFromEditor(notes)
        }

        store.statusMessage = "Joined: \"\(cleanCurrent)\" + \"\(cleanTarget)\" → \"\(joined.hasSuffix("-") ? String(joined.dropLast()) : joined)\""
    }

    private func autoAlignLyrics() {
        // Get lyrics text
        guard let libretto = store.selectedLibrettoFile else {
            store.statusMessage = "No libretto file selected — open a song with lyrics first"
            return
        }

        let rawText = libretto.content
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.statusMessage = "Libretto is empty — add lyrics text first"
            return
        }

        // Extract only sung/spoken lyrics (tab-indented, non-bracket lines)
        let lyricsText = SyllabificationService.extractLyrics(from: rawText)
        guard !lyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.statusMessage = "No sung lyrics found — lyrics must be tab-indented in the libretto"
            return
        }

        // Syllabify
        let syllabified = SyllabificationService.syllabify(lyricsText)
        guard !syllabified.isEmpty else {
            store.statusMessage = "No words found in libretto text"
            return
        }

        // Get vocal notes
        let vocalIndices = resolveVocalTrackIndices()
        let vocalNotes: [PianoRollNote]
        if vocalIndices.isEmpty {
            // No vocal tracks marked — use all visible notes
            if let filter = activeTrackSelection {
                vocalNotes = store.pianoRollNotes.filter { filter.contains($0.trackIndex) }
            } else {
                vocalNotes = store.pianoRollNotes
            }
        } else {
            vocalNotes = store.pianoRollNotes.filter { vocalIndices.contains($0.trackIndex) }
        }

        guard !vocalNotes.isEmpty else {
            store.statusMessage = "No vocal notes found — mark a track as Vocal in the sidebar"
            return
        }

        // Align
        let tpq = max(1, store.ticksPerQuarter)
        let result = LyricAligner.align(
            syllabifiedWords: syllabified,
            notes: vocalNotes,
            ticksPerQuarter: tpq
        )

        guard !result.assignments.isEmpty else {
            store.statusMessage = "Alignment produced no results"
            return
        }

        // Cache the syllabified words for building alignment on accept
        lastAutoAlignSyllabified = syllabified

        // Set as preview (not committed yet)
        var preview: [UUID: String] = [:]
        for assignment in result.assignments {
            preview[assignment.noteID] = assignment.syllable
        }
        lyricsLane?.previewAlignments = preview

        // Show preview accept/reject buttons
        lyricsPreviewAcceptButton?.isHidden = false
        lyricsPreviewRejectButton?.isHidden = false

        // Status message with stats
        let matchedCount = result.assignments.count
        let totalSyllables = syllabified.reduce(0) { $0 + $1.syllables.count }
        let confidencePercent = Int(result.confidence * 100)
        store.statusMessage = "Preview: \(matchedCount) syllables aligned to notes (\(confidencePercent)% confidence, \(totalSyllables) total syllables)"
    }

    // MARK: - Smart Lyric Alignment (Music Intelligence Engine)

    /// Runs the SmartLyricAligner (phrase-aware, contour-aware) and shows results
    /// in the lyrics lane preview mode — same accept/reject workflow as basic align.
    func smartAutoAlignLyrics() {
        guard let libretto = store.selectedLibrettoFile else {
            store.statusMessage = "No libretto file selected — open a song with lyrics first"
            return
        }

        let rawText = libretto.content
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.statusMessage = "Libretto is empty — add lyrics text first"
            return
        }

        let lyricsText = SyllabificationService.extractLyrics(from: rawText)
        guard !lyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.statusMessage = "No sung lyrics found — lyrics must be tab-indented in the libretto"
            return
        }

        let vocalIndices = resolveVocalTrackIndices()
        let vocalNotes: [PianoRollNote]
        if vocalIndices.isEmpty {
            if let filter = activeTrackSelection {
                vocalNotes = store.pianoRollNotes.filter { filter.contains($0.trackIndex) }
            } else {
                vocalNotes = store.pianoRollNotes
            }
        } else {
            vocalNotes = store.pianoRollNotes.filter { vocalIndices.contains($0.trackIndex) }
        }

        guard !vocalNotes.isEmpty else {
            store.statusMessage = "No vocal notes found — mark a track as Vocal in the sidebar"
            return
        }

        // Syllabify
        let syllabified = SyllabificationService.syllabify(lyricsText)
        guard !syllabified.isEmpty else {
            store.statusMessage = "No words found in libretto text"
            return
        }

        // Cache for accept workflow
        lastAutoAlignSyllabified = syllabified

        store.statusMessage = "Smart aligning lyrics…"

        let tpq = max(1, store.ticksPerQuarter)
        let tempoEvents = store.pianoRollTempoEvents
        let timeSigs = store.pianoRollTimeSignatures

        // Run on background thread to keep UI responsive
        Task.detached {
            let result = SmartLyricAligner.align(
                syllabifiedWords: syllabified,
                notes: vocalNotes,
                tempoEvents: tempoEvents,
                timeSignatures: timeSigs,
                ticksPerQuarter: tpq,
                lyricText: lyricsText,
                vocalTrackIndices: vocalIndices
            )

            await MainActor.run { [weak self] in
                guard let self else { return }

                guard !result.assignments.isEmpty else {
                    self.store.statusMessage = "Smart alignment produced no results"
                    return
                }

                // Store result in ScoreStore for potential further use
                self.store.smartAlignmentPreview = result

                // Show in lyrics lane preview
                self.lyricsLane?.previewAlignments = result.previewDictionary
                self.lyricsPreviewAcceptButton?.isHidden = false
                self.lyricsPreviewRejectButton?.isHidden = false

                let matchedCount = result.assignments.count
                let confidencePercent = Int(result.confidence * 100)
                let phraseAligns = result.phraseBreakAlignments
                let contourPct = Int(result.contourScore * 100)
                var statusParts = ["Smart Preview: \(matchedCount) syllables (\(confidencePercent)% confidence, \(phraseAligns) phrase breaks, \(contourPct)% contour)"]
                if !result.fitWarnings.isEmpty {
                    let warningMsgs = result.fitWarnings.map(\.message)
                    statusParts.append("⚠️ \(warningMsgs.joined(separator: "; "))")
                }
                self.store.statusMessage = statusParts.joined(separator: " — ")
            }
        }
    }

    /// Runs the full structural analysis pipeline (phrase detection + structure labeling)
    /// on the current song's notes and stores the result in ScoreStore.
    func analyzeStructure() {
        guard !store.pianoRollNotes.isEmpty else {
            store.statusMessage = "No notes to analyze"
            return
        }
        store.analyzeCurrentSongStructure()
        store.statusMessage = "Analyzing song structure…"
    }

    // MARK: - Multi-Voice Lanes

    private func computeVoiceLanes(from notes: [PianoRollNote]) -> [NoteLabelsOverlayView.VoiceLaneInfo] {
        // Group notes by track index
        var trackPitchRanges: [Int: (min: Int, max: Int, count: Int)] = [:]
        for note in notes {
            if let existing = trackPitchRanges[note.trackIndex] {
                trackPitchRanges[note.trackIndex] = (
                    min: min(existing.min, note.pitch),
                    max: max(existing.max, note.pitch),
                    count: existing.count + 1
                )
            } else {
                trackPitchRanges[note.trackIndex] = (min: note.pitch, max: note.pitch, count: 1)
            }
        }

        guard trackPitchRanges.count > 1 else { return [] }

        let palette: [NSColor] = [
            NSColor(calibratedRed: 0.3, green: 0.7, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.7, blue: 0.3, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 0.7, green: 0.5, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.5, green: 0.9, blue: 0.9, alpha: 1),
        ]

        return trackPitchRanges.keys.sorted().enumerated().map { i, trackIndex in
            let range = trackPitchRanges[trackIndex]!
            let name = store.pianoRollTrackNames[trackIndex]
                ?? store.pianoRollChannelNames[trackIndex]
                ?? "Track \(trackIndex)"
            // Get color from instrument mapping if available
            let color: NSColor
            let pairKey = "\(trackIndex):0"
            if let mappingKey = store.pianoRollChannelKeyByTrackChannel[pairKey],
               let mapping = store.instrumentMappings[mappingKey],
               let hex = mapping.colorHex,
               let resolved = ColorHex.nsColor(from: hex) {
                color = resolved
            } else {
                color = palette[i % palette.count]
            }

            // Expand range slightly for visual padding
            let padded = max(2, (range.max - range.min) / 10)
            return NoteLabelsOverlayView.VoiceLaneInfo(
                name: name,
                trackIndex: trackIndex,
                minPitch: max(0, range.min - padded),
                maxPitch: min(127, range.max + padded),
                color: color
            )
        }
    }

    // MARK: - Track Filter

    /// Returns the current track filter, or nil if no filter is active.
    /// Uses `lastTrackFilter` (our local mirror) instead of reading
    /// `store.selectedTrackFilter` directly.  This is critical because
    /// `@Published` fires on `willSet` — when our Combine sink calls
    /// `pushDataToEditor()`, the store property still holds the OLD value.
    /// `lastTrackFilter` is always updated BEFORE `pushDataToEditor()` runs,
    /// both in the Combine sink and in the 10Hz `handleStoreUpdate()` timer.
    private var activeTrackSelection: Set<Int>? {
        return lastTrackFilter.isEmpty ? nil : lastTrackFilter
    }

    // MARK: - Playhead Timer

    private func startPlayhead() {
        stopPlayhead()
        rebuildPlayheadTempoCache()
        resetPlayheadPlaybackReference()
        lastTempoSnapshot = store.pianoRollTempoEvents

        // The shared display link handles playhead updates at vsync rate.
        // Just make sure it's running.
        displayLink?.isPaused = false
    }

    private func stopPlayhead() {
        playheadStartDate = nil
        // Display link will auto-pause on next frame if nothing else is dirty
    }

    private func resetPlayheadPlaybackReference() {
        playheadStartDate = Date()
        playheadStartSeconds = seconds(atTick: playheadTick, tempoMap: playheadTempoMap)
    }

    private func rebuildPlayheadTempoCache() {
        let maxTick = max(1, store.pianoRollLengthTicks)
        let tempoMap = normalizedTempoEvents(maxTick: maxTick)
        playheadTempoMap = tempoMap
        playheadTotalDurationSeconds = seconds(atTick: maxTick, tempoMap: tempoMap)
        playheadStartSeconds = seconds(atTick: playheadTick, tempoMap: tempoMap)
    }

    private func updatePlayheadPosition() {
        guard playheadStartDate != nil else { return }

        let tpq = max(1, store.ticksPerQuarter)
        let beats = store.playbackPositionInBeats
        let maxTick = max(1, store.pianoRollLengthTicks)

        // Convert beats → ticks. AVAudioSequencer uses quarter-note beats.
        let nextTick = min(max(0, Int((beats * Double(tpq)).rounded())), maxTick - 1)

        if nextTick != playheadTick {
            playheadTick = nextTick
            updateFollowTarget(force: false)
        }
    }

    // MARK: - Tempo Math

    private func simplifyPaintedTempoEvents() {
        guard !store.pianoRollTempoEvents.isEmpty else { return }

        let minSpacingTicks = max(1, store.ticksPerQuarter / 4)
        let bpmTolerance = 0.25

        var byTick: [Int: TempoPoint] = [:]
        for event in store.pianoRollTempoEvents {
            let tick = max(0, event.tick)
            byTick[tick] = TempoPoint(tick: tick, bpm: max(20, min(300, event.bpm)))
        }

        var sorted = byTick.values.sorted { $0.tick < $1.tick }
        if sorted.first?.tick != 0 {
            sorted.insert(TempoPoint(tick: 0, bpm: store.tempoBPM), at: 0)
        }

        var simplified: [TempoPoint] = []
        simplified.reserveCapacity(sorted.count)

        for event in sorted {
            guard let last = simplified.last else {
                simplified.append(event)
                continue
            }

            let sameBPM = abs(last.bpm - event.bpm) <= bpmTolerance
            if sameBPM {
                continue
            }

            // If two adjacent painted points landed very close together and the
            // newer point is only a tiny correction, keep the later one and
            // collapse the earlier slot. This keeps accidental dense jitter out
            // while preserving deliberate ramps at the 1/16-note paint grid.
            if event.tick - last.tick < minSpacingTicks,
               simplified.count > 1,
               abs(last.bpm - event.bpm) <= 1.0 {
                simplified[simplified.count - 1] = event
            } else {
                simplified.append(event)
            }
        }

        guard simplified != store.pianoRollTempoEvents else { return }
        store.pianoRollTempoEvents = simplified
        if let first = simplified.first, first.tick == 0 {
            store.tempoBPM = first.bpm
        }
        store.isDirty = true
    }

    private func normalizedTempoEvents(maxTick: Int) -> [TempoPoint] {
        var events = store.pianoRollTempoEvents
        if events.isEmpty {
            events = [TempoPoint(tick: 0, bpm: store.tempoBPM)]
        }
        events = events.map { event in
            TempoPoint(
                tick: min(max(0, event.tick), max(0, maxTick - 1)),
                bpm: max(20, min(event.bpm, 300))
            )
        }
        .sorted { $0.tick < $1.tick }

        var dedupByTick: [Int: TempoPoint] = [:]
        for event in events {
            dedupByTick[event.tick] = event
        }

        var deduped = dedupByTick.values.sorted { $0.tick < $1.tick }
        if deduped.first?.tick != 0 {
            deduped.insert(TempoPoint(tick: 0, bpm: store.tempoBPM), at: 0)
        }
        return deduped
    }

    /// Returns the BPM at a given tick position using the cached playhead tempo map.
    private func tempoAtTick(_ tick: Int) -> Double {
        let map = playheadTempoMap
        guard !map.isEmpty else { return store.tempoBPM }
        var bpm = map[0].bpm
        for event in map {
            if event.tick <= tick { bpm = event.bpm }
            else { break }
        }
        return bpm
    }

    private func seconds(atTick tick: Int, tempoMap: [TempoPoint]) -> Double {
        guard !tempoMap.isEmpty else { return 0 }
        let clampedTick = max(0, tick)
        if clampedTick == 0 { return 0 }

        var total: Double = 0
        let tpq = Double(max(1, store.ticksPerQuarter))
        var index = 0
        while index < tempoMap.count {
            let current = tempoMap[index]
            let nextTick = (index + 1 < tempoMap.count) ? tempoMap[index + 1].tick : clampedTick
            if clampedTick <= current.tick { break }
            let segmentStart = current.tick
            let segmentEnd = min(clampedTick, nextTick)
            if segmentEnd > segmentStart {
                let ticks = Double(segmentEnd - segmentStart)
                total += ticks * (60.0 / (max(20, current.bpm) * tpq))
            }
            if segmentEnd >= clampedTick { break }
            index += 1
        }
        return total
    }

    private func tick(atSeconds seconds: Double, tempoMap: [TempoPoint], maxTick: Int) -> Int {
        guard !tempoMap.isEmpty else { return 0 }
        var remaining = max(0, seconds)
        let tpq = Double(max(1, store.ticksPerQuarter))

        for index in tempoMap.indices {
            let current = tempoMap[index]
            let nextTick = (index + 1 < tempoMap.count) ? tempoMap[index + 1].tick : maxTick
            let segmentStart = min(maxTick, current.tick)
            let segmentEnd = min(maxTick, max(segmentStart, nextTick))
            let segmentTicks = max(0, segmentEnd - segmentStart)
            if segmentTicks == 0 { continue }

            let secPerTick = 60.0 / (max(20, current.bpm) * tpq)
            let segmentDuration = Double(segmentTicks) * secPerTick
            if remaining >= segmentDuration {
                remaining -= segmentDuration
                continue
            }

            let advanced = Int((remaining / secPerTick).rounded(.down))
            return min(maxTick, segmentStart + max(0, advanced))
        }

        return maxTick
    }

    // MARK: - Follow Playhead

    private func updateFollowTarget(force: Bool) {
        guard followMode != .off else { return }
        guard store.isPlaying else { return }
        guard let editor = editorView else { return }

        let tpq = max(1, store.ticksPerQuarter)
        let ticksPerBar = tpq * 4

        switch followMode {
        case .off:
            return
        case .center:
            editor.scrollToTick(playheadTick, anchor: 0.5, smooth: true)
        case .page:
            let viewportWidth = editor.bounds.width - 96 // minus keyboard
            let ppt = max(editor.pixelsPerTick, 0.01)
            let visibleTicks = max(1, Int((viewportWidth / ppt).rounded(.down)))
            let barsPerPage = max(1, visibleTicks / max(1, ticksPerBar))
            let pageSpan = max(ticksPerBar, barsPerPage * ticksPerBar)
            let clampedTick = max(0, min(playheadTick, max(0, store.pianoRollLengthTicks)))
            let pageStart = (clampedTick / pageSpan) * pageSpan
            if force || pageStart != lastFollowPageStartTick {
                lastFollowPageStartTick = pageStart
                editor.scrollToTick(pageStart, anchor: 0.0)
            }
        }
    }

    // MARK: - Playhead Control (called from toolbar)

    func setPlayhead(tick: Int) {
        playheadTick = min(max(0, tick), max(0, store.pianoRollLengthTicks - 1))
        store.livePlayheadTick = playheadTick
        store.liveTempoAtPlayhead = tempoAtTick(playheadTick)
        updateFollowTarget(force: true)

        // Always push playhead position to all views immediately for visual feedback
        pushPlayheadOnly()

        if store.isPlaying {
            resetPlayheadPlaybackReference()
            store.seekPlayback(to: playheadTick, trackFilter: nil)
        }
    }

    // MARK: - Public API (called from SwiftUI host)

    /// Called when store.selectedTrackFilter changes (replaces Combine subscription).
    func trackFilterDidChange() {
        let newFilter = store.selectedTrackFilter
        if newFilter != lastTrackFilter {
            lastTrackFilter = newFilter
            if isAllTracksConstrainedMode, tool != .select {
                tool = .select
            } else {
                syncChromeState()
            }
            store.updatePreviewMappingForTrackFilter()
            pushDataToEditor()
        } else {
            syncChromeState()
        }
    }

    /// Called when the selected song changes — triggers full data reload.
    func refreshFromStore() {
        pushDataToEditor()
        // Ensure the preview sampler is configured for the current track's
        // instrument so keyboard/drawing preview plays the correct sound.
        store.updatePreviewMappingForTrackFilter()
    }

    @objc private func spacebarPlayPauseReceived() {
        togglePlayPause()
    }

    func togglePlayPause() {
        if store.isPlaying {
            stopPlayhead()
            store.stopPlayback()
            playheadStopped = true
            store.livePlayheadTick = playheadTick
            store.liveTempoAtPlayhead = tempoAtTick(playheadTick)
        } else {
            playheadStopped = false
            // Auto-render vocal tracks before playback (MBROLA is ~1800× real-time, near-instant)
            let startTick = playheadTick
            Task { @MainActor in
                await store.autoRenderVocalTracksIfNeeded()
                // Only start if we haven't been stopped in the meantime
                guard !store.isPlaying else { return }
                store.playPianoRoll(startTick: startTick, trackFilter: nil)
            }
        }
    }

    func rewindPlayhead() {
        let jump = max(1, store.ticksPerQuarter * 4)
        setPlayhead(tick: playheadTick - jump)
    }

    func fastForwardPlayhead() {
        let jump = max(1, store.ticksPerQuarter * 4)
        setPlayhead(tick: playheadTick + jump)
    }

    func goToStart() { setPlayhead(tick: 0) }

    func goToEnd() { setPlayhead(tick: max(0, store.pianoRollLengthTicks - 1)) }

    /// Logic Pro-style stop: first press = stop in place, second press = return to start.
    func stopAndReset() {
        if store.isPlaying {
            // First press while playing: stop in place
            stopPlayhead()
            store.stopPlayback()
            playheadStopped = true
            store.livePlayheadTick = playheadTick
            store.liveTempoAtPlayhead = tempoAtTick(playheadTick)
        } else if playheadStopped {
            // Second press while already stopped: return to start
            playheadTick = 0
            playheadStopped = false
            store.livePlayheadTick = 0
            store.liveTempoAtPlayhead = tempoAtTick(0)
            pushPlayheadOnly()
            updateFollowTarget(force: true)
        }
    }

    // MARK: - Time Display

    func playheadTimeString() -> String {
        let tpq = max(1, store.ticksPerQuarter)
        let ticksPerBeat = tpq
        let ticksPerBar = ticksPerBeat * 4
        let tick = max(0, playheadTick)
        let bar = (tick / ticksPerBar) + 1
        let beat = ((tick % ticksPerBar) / ticksPerBeat) + 1
        let tickWithinBeat = tick % ticksPerBeat
        return String(format: "%03d:%02d:%03d", bar, beat, tickWithinBeat)
    }

    // MARK: - Note Color

    private func rebuildColorCache() {
        var byPair: [String: SIMD4<Float>] = [:]
        var byTrack: [Int: SIMD4<Float>] = [:]

        for (pairKey, mappingKey) in store.pianoRollChannelKeyByTrackChannel {
            guard let color = resolvedMappingColorSIMD(for: mappingKey) else { continue }
            byPair[pairKey] = color
            let parts = pairKey.split(separator: ":")
            if parts.count == 2, let trackIndex = Int(parts[0]), byTrack[trackIndex] == nil {
                byTrack[trackIndex] = color
            }
        }

        mappedColorByPairKey = byPair
        mappedColorByTrackIndex = byTrack
    }

    private func noteColorSIMD(channel: Int, trackIndex: Int) -> SIMD4<Float> {
        let directKey = "\(trackIndex):\(channel)"
        if let mappingKey = store.pianoRollChannelKeyByTrackChannel[directKey],
           let color = resolvedMappingColorSIMD(for: mappingKey) {
            return color
        }
        if let color = mappedColorByPairKey[directKey] { return color }
        if let color = mappedColorByTrackIndex[trackIndex] { return color }

        let palette: [SIMD4<Float>] = [
            SIMD4<Float>(0.98, 0.42, 0.35, 1), // coral
            SIMD4<Float>(0.98, 0.73, 0.24, 1), // amber
            SIMD4<Float>(0.58, 0.87, 0.29, 1), // lime
            SIMD4<Float>(0.23, 0.82, 0.63, 1), // mint
            SIMD4<Float>(0.25, 0.71, 0.99, 1), // sky
            SIMD4<Float>(0.55, 0.78, 0.55, 1), // sage green (FL Studio default)
            SIMD4<Float>(0.80, 0.48, 0.97, 1), // violet
            SIMD4<Float>(0.98, 0.45, 0.73, 1), // magenta
            SIMD4<Float>(0.95, 0.60, 0.35, 1), // orange
            SIMD4<Float>(0.71, 0.90, 0.42, 1), // spring
            SIMD4<Float>(0.38, 0.89, 0.89, 1), // cyan
            SIMD4<Float>(0.45, 0.78, 1.00, 1), // pale blue
            SIMD4<Float>(0.65, 0.69, 0.99, 1), // lavender
            SIMD4<Float>(0.91, 0.56, 0.96, 1), // pink violet
            SIMD4<Float>(0.98, 0.67, 0.62, 1), // rose
            SIMD4<Float>(0.85, 0.84, 0.34, 1), // yellow green
        ]

        var base = palette[abs(trackIndex) % palette.count]
        let opacity = Float(0.90 - (Double(abs(trackIndex) % 4) * 0.08))
        base.w = max(0.45, opacity)
        return base
    }

    private func resolvedMappingColorSIMD(for mappingKey: String) -> SIMD4<Float>? {
        if let hex = store.instrumentMappings[mappingKey]?.colorHex,
           let color = ColorHex.color(from: hex) {
            return colorToSIMD(color)
        }
        if mappingKey.hasPrefix("song|") {
            let pieces = mappingKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3 {
                let baseKey = String(pieces[2])
                if let hex = store.instrumentMappings[baseKey]?.colorHex,
                   let color = ColorHex.color(from: hex) {
                    return colorToSIMD(color)
                }
            }
        }
        return nil
    }

    private func colorToSIMD(_ color: Color) -> SIMD4<Float> {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    // MARK: - Canvas Mouse Handling

    private var snapTicks: Int {
        if dragAltHeld { return 1 }
        if snap == .line {
            return snap.dynamicTickSpan(ticksPerQuarter: store.ticksPerQuarter,
                                        pixelsPerQuarter: pixelsPerQuarter)
        }
        return snap.tickSpan(ticksPerQuarter: store.ticksPerQuarter)
    }

    private func snappedTick(forX x: CGFloat) -> Int {
        guard let editor = editorView else { return 0 }
        let rawTick = max(0, Int((x / editor.pixelsPerTick).rounded()))
        return snapToGrid(rawTick, division: snapTicks)
    }

    private func rawTick(forX x: CGFloat) -> Int {
        guard let editor = editorView else { return 0 }
        let tick = max(0, Int((x / editor.pixelsPerTick).rounded()))
        return min(tick, max(0, store.pianoRollLengthTicks - 1))
    }

    private func snapToGrid(_ tick: Int, division: Int) -> Int {
        guard division > 1 else { return max(0, tick) }
        let ratio = Double(max(0, tick)) / Double(division)
        return Int(ratio.rounded()) * division
    }

    /// Snaps to the grid position at or BEFORE the given tick (floor).
    /// Used by the Draw tool so the note always appears to the left of the cursor.
    private func floorSnappedTick(forX x: CGFloat) -> Int {
        guard let editor = editorView else { return 0 }
        let rawTick = max(0, x / editor.pixelsPerTick)
        guard snapTicks > 1 else { return max(0, Int(rawTick)) }
        return Int(rawTick / Double(snapTicks)) * snapTicks
    }

    private func pitchForY(_ y: CGFloat) -> Int {
        let row = Int(y / editorRowHeight)  // floor: cursor inside a row → that row's pitch
        let maxVisiblePitch = editorView?.maxPitch ?? 108
        let minVisiblePitch = editorView?.minPitch ?? 21
        let pitch = maxVisiblePitch - row
        return min(max(pitch, minVisiblePitch), maxVisiblePitch)
    }

    private func noteRect(
        for note: PianoRollNote,
        pixelsPerTick: CGFloat,
        rowHeight: CGFloat,
        maxPitch: Int
    ) -> CGRect {
        CGRect(
            x: CGFloat(note.startTick) * pixelsPerTick,
            y: CGFloat(maxPitch - note.pitch) * rowHeight,
            width: max(pianoRollMinimumNoteWidth, CGFloat(note.duration) * pixelsPerTick),
            height: rowHeight
        )
    }

    /// Hit-test: find the note under a canvas point.
    private func noteAtPoint(_ point: NSPoint) -> PianoRollNote? {
        guard let editor = editorView else { return nil }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        let maxPitch = editor.maxPitch

        for note in editor.notes {
            if noteRect(for: note, pixelsPerTick: ppt, rowHeight: rh, maxPitch: maxPitch).contains(point) {
                return note
            }
        }
        return nil
    }

    /// Check if a point is near the right edge of a note (for resize cursor/handle).
    /// Returns the note if within the resize zone, nil otherwise.
    private func noteForResize(at point: NSPoint) -> PianoRollNote? {
        guard let editor = editorView else { return nil }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        let maxPitch = editor.maxPitch
        let resizeZone: CGFloat = 6  // pixels from right edge

        for note in editor.notes {
            let noteRect = noteRect(for: note, pixelsPerTick: ppt, rowHeight: rh, maxPitch: maxPitch)
            guard noteRect.contains(point) else { continue }

            let rightEdge = noteRect.maxX
            if abs(point.x - rightEdge) <= resizeZone {
                return note
            }
        }
        return nil
    }

    /// Returns the note if the click is within the left-edge resize zone (6px from left edge).
    private func noteForLeftResize(at point: NSPoint) -> PianoRollNote? {
        guard let editor = editorView else { return nil }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        let maxPitch = editor.maxPitch
        let resizeZone: CGFloat = 6

        for note in editor.notes {
            let noteRect = noteRect(for: note, pixelsPerTick: ppt, rowHeight: rh, maxPitch: maxPitch)
            guard noteRect.contains(point) else { continue }

            if abs(point.x - noteRect.minX) <= resizeZone {
                return note
            }
        }
        return nil
    }

    /// Returns the desired cursor for the current tool and canvas position.
    func cursorForCanvasPoint(_ point: NSPoint) -> NSCursor {
        if isAllTracksConstrainedMode {
            if tool == .select, noteAtPoint(point) != nil {
                return .openHand
            }
            return .arrow
        }

        switch tool {
        case .select:
            if noteForResize(at: point) != nil || noteForLeftResize(at: point) != nil {
                return .resizeLeftRight
            }
            if let note = noteAtPoint(point), selectedNoteIDs.contains(note.id) {
                return .openHand
            }
            return .arrow
        case .draw:
            if noteForResize(at: point) != nil || noteForLeftResize(at: point) != nil {
                return .resizeLeftRight
            }
            if noteAtPoint(point) != nil { return .openHand }
            return Self.pencilCursor
        case .paintbrush:
            return .crosshair
        case .erase:
            return .crosshair
        case .mute:
            return .pointingHand
        case .slice:
            return .crosshair
        case .stamp:
            return .crosshair
        }
    }

    /// Tracks which tick positions have been sliced during the current slice drag.
    private var slicedTicks: Set<Int> = []

    // MARK: Mouse Down

    /// True when no specific track is selected — only Select-tool vertical pitch edits are allowed.
    private var isAllTracksConstrainedMode: Bool {
        store.selectedTrackFilter.isEmpty
    }

    private func handleCanvasMouseDown(point: NSPoint, event: NSEvent) {
        dragStartPoint = point
        dragOrigin = point
        dragShiftHeld = event.modifierFlags.contains(.shift)
        selectionBeforeDrag = selectedNoteIDs
        dragMode = .none
        dragStartNoteSnapshot = [:]
        resizeAnchorNoteID = nil
        rightDragUndoPushed = false

        // All-tracks view allows Select-only vertical pitch fixes.
        if isAllTracksConstrainedMode {
            switch tool {
            case .select:
                handleSelectMouseDownAllTracks(point: point, event: event)
            case .draw, .erase, .mute, .slice, .stamp:
                store.statusMessage = "All Tracks uses the Select tool only"
                return
            case .paintbrush:
                store.statusMessage = "All Tracks uses the Select tool only"
                return
            }
            return
        }

        switch tool {
        case .select:
            handleSelectMouseDown(point: point, event: event)
        case .draw:
            handleDrawMouseDown(point: point, event: event)
        case .erase:
            pushUndo()
            eraseNoteAt(point: point)
        case .mute:
            handleMuteMouseDown(point: point)
        case .slice:
            pushUndo()
            slicedTicks = []
            let tick = snappedTick(forX: point.x)
            slicedTicks.insert(tick)
            slice(at: tick)
        case .paintbrush:
            break  // paintbrush only operates in the tempo lane, not the note canvas
        case .stamp:
            let tick = Int(point.x / max(0.000_01, editorView?.pixelsPerTick ?? 0.267))
            let trackIndex = store.pianoRollNotes.first?.trackIndex ?? 0
            let channel = store.pianoRollNotes.first?.channel ?? 0
            stampChord(at: tick, trackIndex: trackIndex, channel: channel)
        }
    }

    /// All-tracks select handler: allows marquee/lasso selection and vertical pitch drags only.
    private func handleSelectMouseDownAllTracks(point: NSPoint, event: NSEvent) {
        if let hitNote = noteAtPoint(point) {
            if dragShiftHeld {
                if selectedNoteIDs.contains(hitNote.id) {
                    selectedNoteIDs.remove(hitNote.id)
                    return
                } else {
                    selectedNoteIDs.insert(hitNote.id)
                }
            } else if !selectedNoteIDs.contains(hitNote.id) {
                selectedNoteIDs = [hitNote.id]
            }

            dragMode = .movingNotesPitchOnly
            let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
            dragStartNoteSnapshot = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            pushUndo()
            beginDragPreview(for: hitNote.pitch)
            return
        }

        // Empty space: start marquee or lasso
        if !dragShiftHeld {
            selectedNoteIDs.removeAll()
        }
        if event.modifierFlags.contains(.option) {
            dragMode = .lassoSelect
            lassoPoints = [point]
        } else {
            dragMode = .marqueeSelect
        }
    }

    private func handleSelectMouseDown(point: NSPoint, event: NSEvent) {
        // Priority 1a: resize handle (right edge of any note)
        if let resizeNote = noteForResize(at: point) {
            if !selectedNoteIDs.contains(resizeNote.id) {
                selectedNoteIDs = [resizeNote.id]
            }
            dragMode = .resizingNotes
            resizeAnchorNoteID = resizeNote.id
            let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
            dragStartNoteSnapshot = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            pushUndo()
            return
        }

        // Priority 1b: resize handle (left edge of any note)
        if let leftNote = noteForLeftResize(at: point) {
            if !selectedNoteIDs.contains(leftNote.id) {
                selectedNoteIDs = [leftNote.id]
            }
            dragMode = .resizingNotesLeft
            resizeAnchorNoteID = leftNote.id
            let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
            dragStartNoteSnapshot = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            pushUndo()
            return
        }

        // Priority 2: click on an existing note
        if let hitNote = noteAtPoint(point) {
            if dragShiftHeld {
                // Shift-click: toggle note in/out of selection
                if selectedNoteIDs.contains(hitNote.id) {
                    selectedNoteIDs.remove(hitNote.id)
                } else {
                    selectedNoteIDs.insert(hitNote.id)
                }
            } else if !selectedNoteIDs.contains(hitNote.id) {
                // Click on unselected note: select only this one
                selectedNoteIDs = [hitNote.id]
            }
            // Prepare for potential move drag
            dragMode = .movingNotes
            expandSelectionToGroups()
            let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
            dragStartNoteSnapshot = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            pushUndo()
            beginDragPreview(for: hitNote.pitch)
            return
        }

        // Priority 3: click on empty space — start marquee or lasso
        if !dragShiftHeld {
            selectedNoteIDs.removeAll()
        }

        // Alt+click: lasso selection
        if event.modifierFlags.contains(.option) {
            dragMode = .lassoSelect
            lassoPoints = [point]
        } else {
            dragMode = .marqueeSelect
        }
    }

    private func handleDrawMouseDown(point: NSPoint, event: NSEvent) {
        // C.1 FL Studio-style Draw tool:
        // - Click on note right edge → resize
        // - Click on note body → move
        // - Click on empty space → create note

        // Priority 1a: resize handle (right edge of any note)
        if let resizeNote = noteForResize(at: point) {
            if !selectedNoteIDs.contains(resizeNote.id) {
                selectedNoteIDs = [resizeNote.id]
            }
            dragMode = .resizingNotes
            resizeAnchorNoteID = resizeNote.id
            let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
            dragStartNoteSnapshot = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            pushUndo()
            return
        }

        // Priority 1b: resize handle (left edge of any note)
        if let leftNote = noteForLeftResize(at: point) {
            if !selectedNoteIDs.contains(leftNote.id) {
                selectedNoteIDs = [leftNote.id]
            }
            dragMode = .resizingNotesLeft
            resizeAnchorNoteID = leftNote.id
            let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
            dragStartNoteSnapshot = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            pushUndo()
            return
        }

        // Priority 2: click on existing note → move
        if let hitNote = noteAtPoint(point) {
            if !selectedNoteIDs.contains(hitNote.id) {
                selectedNoteIDs = [hitNote.id]
            }
            dragMode = .movingNotes
            let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
            dragStartNoteSnapshot = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            pushUndo()
            beginDragPreview(for: hitNote.pitch)
            return
        }

        // Priority 3: empty space → create note
        dragMode = .drawingNote
        pushUndo()

        // FL Studio behavior: immediately create a draft note at click position
        // with default length of one snap unit. Floor-snap so note is always
        // to the left of the cursor. If the user drags, updateDraftNote moves it.
        let tick = floorSnappedTick(forX: point.x)
        let pitch = pitchForY(point.y)
        // Use the filtered (selected) instrument's track if a single instrument is solo'd,
        // otherwise fall back to the first available track.
        let trackIndex: Int
        if let soloTrack = store.selectedTrackFilter.first, store.selectedTrackFilter.count == 1 {
            trackIndex = soloTrack
        } else {
            trackIndex = availableTrackIndices.first ?? 0
        }
        let channel = defaultChannel(for: trackIndex)
        let duration = lastCommittedNoteDuration > 0 ? lastCommittedNoteDuration : max(1, snapTicks)
        draftNote = (pitch: pitch, startTick: tick, duration: duration,
                     trackIndex: trackIndex, channel: channel)
        pushDraftNotePreview()
        editorView?.highlightedPitchRow = pitch
        beginDragPreview(for: pitch)
    }

    // MARK: Mouse Dragged

    private func handleCanvasMouseDragged(point: NSPoint, event: NSEvent) {
        // Track Alt modifier for snap bypass (Alt held at any point during drag)
        dragAltHeld = event.modifierFlags.contains(.option)

        switch tool {
        case .select:
            handleSelectMouseDragged(point: point, event: event)
        case .draw:
            switch dragMode {
            case .drawingNote:
                updateDraftNote(current: point)
            case .movingNotes:
                let dx = point.x - dragStartPoint.x
                let dy = point.y - dragStartPoint.y
                guard sqrt(dx * dx + dy * dy) > 3 else { break }
                moveSelectedNotes(to: point)
                updateDragPreview(for: pitchForY(point.y))
            case .resizingNotes:
                let dx = point.x - dragStartPoint.x
                guard abs(dx) > 2 else { break }
                resizeSelectedNotes(to: point)
            case .resizingNotesLeft:
                let dx = point.x - dragStartPoint.x
                guard abs(dx) > 2 else { break }
                resizeSelectedNotesLeft(to: point)
            default: break
            }
        case .paintbrush:
            break  // paintbrush only operates in the tempo lane
        case .erase:
            // Drag-erase: continuously erase notes under cursor
            eraseNoteAt(point: point)
        case .mute:
            break  // mute only toggles on click, not drag
        case .slice:
            let tick = snappedTick(forX: point.x)
            if !slicedTicks.contains(tick) {
                slicedTicks.insert(tick)
                slice(at: tick)
            }
        case .stamp:
            break
        }
    }

    private func handleSelectMouseDragged(point: NSPoint, event: NSEvent) {
        let dx = point.x - dragStartPoint.x
        let dy = point.y - dragStartPoint.y
        let distance = sqrt(dx * dx + dy * dy)

        switch dragMode {
        case .movingNotes:
            guard distance > 3 else { return }
            moveSelectedNotes(to: point)
            updateDragPreview(for: pitchForY(point.y))

        case .movingNotesPitchOnly:
            guard distance > 3 else { return }
            moveSelectedNotes(to: point, allowHorizontal: false)
            updateDragPreview(for: pitchForY(point.y))

        case .resizingNotes:
            guard distance > 2 else { return }
            resizeSelectedNotes(to: point)

        case .resizingNotesLeft:
            guard distance > 2 else { return }
            resizeSelectedNotesLeft(to: point)

        case .marqueeSelect:
            updateMarquee(current: point)

        case .lassoSelect:
            updateLasso(current: point)

        case .drawingNote, .none:
            break
        }
    }

    // MARK: Mouse Up

    private func handleCanvasMouseUp(point: NSPoint, event: NSEvent) {
        endDragPreview()
        defer {
            dragOrigin = nil
            draftNote = nil
            dragMode = .none
            dragStartNoteSnapshot = [:]
            resizeAnchorNoteID = nil
            slicedTicks = []
            lassoPoints = []
            dragAltHeld = false
            lastDrawPreviewPitch = -1
            stopAutoScroll()
            editorView?.draftNotePreview = nil
            editorView?.highlightedPitchRow = nil
            editorView?.updateLassoOverlay(canvasPoints: nil)
            editorView?.updateMarqueeOverlay(canvasRect: nil)
        }

        switch tool {
        case .select:
            handleSelectMouseUp(point: point, event: event)
        case .draw:
            switch dragMode {
            case .drawingNote:
                commitDraftNote()
            case .movingNotes:
                let dx = point.x - dragStartPoint.x
                let dy = point.y - dragStartPoint.y
                if sqrt(dx * dx + dy * dy) < 3 { store.popLastUndo() }
            case .resizingNotes, .resizingNotesLeft:
                let dx = point.x - dragStartPoint.x
                if abs(dx) < 2 {
                    store.popLastUndo()
                } else if let anchorID = resizeAnchorNoteID,
                          let note = store.pianoRollNotes.first(where: { $0.id == anchorID }) {
                    lastCommittedNoteDuration = note.duration
                }
            default: break
            }
        case .slice:
            slicedTicks = []  // Clean up; slicing happened during mouse-down/drag
        case .paintbrush, .erase, .mute, .stamp:
            break
        }
    }

    private func handleSelectMouseUp(point: NSPoint, event: NSEvent) {
        let dx = point.x - dragStartPoint.x
        let dy = point.y - dragStartPoint.y
        let distance = sqrt(dx * dx + dy * dy)

        switch dragMode {
        case .movingNotes:
            if distance < 3 || !didDraggedNotesChange() {
                // Was a click, not a drag — undo the premature pushUndo
                store.popLastUndo()
            }
            // Notes already moved in place during drag

        case .movingNotesPitchOnly:
            if distance < 3 || !didDraggedNotesChange() {
                // Was a click, not a drag — undo the premature pushUndo
                store.popLastUndo()
            }
            // Notes already moved in place during drag

        case .resizingNotes, .resizingNotesLeft:
            if distance < 2 {
                store.popLastUndo()
            }

        case .marqueeSelect:
            if distance < 3 && !dragShiftHeld {
                // Tiny drag = click on empty space → deselect
                selectedNoteIDs.removeAll()
            }

        case .lassoSelect:
            if distance < 3 && !dragShiftHeld {
                selectedNoteIDs.removeAll()
            }
            // Selection was already updated live during drag

        case .drawingNote, .none:
            break
        }
    }

    // MARK: - Move Notes

    private func moveSelectedNotes(to point: NSPoint, allowHorizontal: Bool = true) {
        guard let editor = editorView else { return }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        guard ppt > 0, rh > 0 else { return }

        let deltaX = allowHorizontal ? point.x - dragStartPoint.x : 0
        let deltaY = point.y - dragStartPoint.y

        let deltaTicks = Int((deltaX / ppt).rounded())
        let deltaRows = Int((deltaY / rh).rounded())
        let deltaPitch = -deltaRows  // up = higher pitch

        // Snap the tick delta to the grid
        let snappedDeltaTicks: Int
        if snapTicks > 1 {
            snappedDeltaTicks = Int((Double(deltaTicks) / Double(snapTicks)).rounded()) * snapTicks
        } else {
            snappedDeltaTicks = deltaTicks
        }

        var notes = store.pianoRollNotes
        for i in notes.indices {
            guard let original = dragStartNoteSnapshot[notes[i].id] else { continue }
            notes[i].startTick = max(0, original.startTick + snappedDeltaTicks)
            notes[i].pitch = min(108, max(21, original.pitch + deltaPitch))
        }
        store.setPianoRollNotesFromEditor(notes)
    }

    private func didDraggedNotesChange() -> Bool {
        guard !dragStartNoteSnapshot.isEmpty else { return false }
        let currentByID = Dictionary(uniqueKeysWithValues: store.pianoRollNotes.map { ($0.id, $0) })
        for (id, original) in dragStartNoteSnapshot {
            guard let current = currentByID[id] else { return true }
            if current.startTick != original.startTick ||
                current.duration != original.duration ||
                current.pitch != original.pitch {
                return true
            }
        }
        return false
    }

    // MARK: - Resize Notes

    private func resizeSelectedNotes(to point: NSPoint) {
        guard let editor = editorView else { return }
        let ppt = editor.pixelsPerTick
        guard ppt > 0 else { return }

        let deltaX = point.x - dragStartPoint.x
        let deltaTicks = Int((deltaX / ppt).rounded())

        // Snap the delta
        let snappedDelta: Int
        if snapTicks > 1 {
            snappedDelta = Int((Double(deltaTicks) / Double(snapTicks)).rounded()) * snapTicks
        } else {
            snappedDelta = deltaTicks
        }

        var notes = store.pianoRollNotes
        for i in notes.indices {
            guard let original = dragStartNoteSnapshot[notes[i].id] else { continue }
            let newDuration = original.duration + snappedDelta
            notes[i].duration = max(1, max(snapTicks, newDuration))
        }
        store.setPianoRollNotesFromEditor(notes)
    }

    private func resizeSelectedNotesLeft(to point: NSPoint) {
        guard let editor = editorView else { return }
        let ppt = editor.pixelsPerTick
        guard ppt > 0 else { return }

        let deltaX = point.x - dragStartPoint.x
        let deltaTicks = Int((deltaX / ppt).rounded())

        // Snap the delta
        let snappedDelta: Int
        if snapTicks > 1 {
            snappedDelta = Int((Double(deltaTicks) / Double(snapTicks)).rounded()) * snapTicks
        } else {
            snappedDelta = deltaTicks
        }

        var notes = store.pianoRollNotes
        for i in notes.indices {
            guard let original = dragStartNoteSnapshot[notes[i].id] else { continue }
            let originalEnd = original.startTick + original.duration
            let newStart = max(0, original.startTick + snappedDelta)
            let newDuration = originalEnd - newStart
            // Keep minimum duration and don't let start pass the original end
            if newDuration >= max(1, snapTicks) {
                notes[i].startTick = newStart
                notes[i].duration = newDuration
            }
        }
        store.setPianoRollNotesFromEditor(notes)
    }

    // MARK: - Draw Tool

    private func updateDraftNote(current: CGPoint) {
        guard var draft = draftNote else { return }

        // FL Studio behavior: drag moves the note, not extends it.
        // Floor-snap so the note is always to the LEFT of the cursor.
        let startTick = floorSnappedTick(forX: current.x)
        let pitch = pitchForY(current.y)

        draft.startTick = max(0, startTick)
        draft.pitch = pitch
        // Duration stays fixed at the initial snap-unit length
        draftNote = draft
        pushDraftNotePreview()
        editorView?.highlightedPitchRow = pitch
        // Preview the note sound when pitch changes
        updateDragPreview(for: pitch)
    }

    private func beginDragPreview(for pitch: Int) {
        lastDrawPreviewPitch = pitch
        store.startPreviewPitch(pitch)
    }

    private func updateDragPreview(for pitch: Int) {
        guard pitch != lastDrawPreviewPitch else { return }
        if lastDrawPreviewPitch == -1 {
            beginDragPreview(for: pitch)
            return
        }
        lastDrawPreviewPitch = pitch
        store.updatePreviewPitch(pitch)
    }

    private func endDragPreview() {
        guard lastDrawPreviewPitch != -1 else { return }
        lastDrawPreviewPitch = -1
        store.stopPreviewPitch()
    }

    /// Pushes the current draftNote to the editor as a visual preview (rendered as a selected note).
    private func pushDraftNotePreview() {
        guard let draft = draftNote else {
            editorView?.draftNotePreview = nil
            return
        }
        let trackIndex = draft.trackIndex
        let channel = draft.channel
        editorView?.draftNotePreview = PianoRollNote(
            trackIndex: trackIndex,
            channel: channel,
            pitch: draft.pitch,
            velocity: 96,
            startTick: draft.startTick,
            duration: draft.duration
        )
    }

    private func commitDraftNote() {
        guard let draft = draftNote else { return }

        editorView?.draftNotePreview = nil  // Clear preview

        // Remember the duration so the next drawn note inherits the same size
        lastCommittedNoteDuration = draft.duration

        var notes = store.pianoRollNotes
        let newNote = PianoRollNote(
            trackIndex: draft.trackIndex,
            channel: draft.channel,
            pitch: draft.pitch,
            velocity: 96,
            startTick: draft.startTick,
            duration: draft.duration
        )
        notes.append(newNote)
        store.setPianoRollNotesFromEditor(notes)
        selectedNoteIDs = [newNote.id]
    }

    // MARK: - Mute Tool

    private func handleMuteMouseDown(point: NSPoint) {
        guard let note = noteAtPoint(point) else { return }
        pushUndo()
        var notes = store.pianoRollNotes
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[idx].muted.toggle()
        store.setPianoRollNotesFromEditor(notes)
    }

    /// Toggle mute on all selected notes.
    func toggleMuteSelected() {
        guard !selectedNoteIDs.isEmpty else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        pushUndo()
        var notes = store.pianoRollNotes
        // If any selected note is unmuted, mute all; else unmute all
        let anyUnmuted = notes.contains { selectedNoteIDs.contains($0.id) && !$0.muted }
        for i in notes.indices {
            guard selectedNoteIDs.contains(notes[i].id) else { continue }
            notes[i].muted = anyUnmuted
        }
        store.setPianoRollNotesFromEditor(notes)
    }

    // MARK: - Selection Auto-Scroll

    /// Computes auto-scroll speed based on cursor position relative to the visible viewport.
    /// Returns 0 when cursor is not near edges; positive = scroll right, negative = scroll left.
    private func autoScrollDelta(forCanvasX canvasX: CGFloat) -> CGFloat {
        guard let editor = editorView else { return 0 }
        let scrollOffset = editor.visibleScrollOffsetX
        let viewportWidth = editor.visibleViewportWidth
        let edgeMargin: CGFloat = 30  // pixels from edge to start scrolling
        let maxSpeed: CGFloat = 12    // pixels per tick at the very edge

        let relativeX = canvasX - scrollOffset  // position within viewport
        if relativeX < edgeMargin {
            // Near left edge — scroll left
            let proximity = max(0, edgeMargin - relativeX) / edgeMargin
            return -maxSpeed * proximity
        } else if relativeX > viewportWidth - edgeMargin {
            // Near right edge — scroll right
            let proximity = max(0, relativeX - (viewportWidth - edgeMargin)) / edgeMargin
            return maxSpeed * proximity
        }
        return 0
    }

    /// Starts or updates the auto-scroll timer for selection drag.
    private func updateAutoScroll(canvasPoint: CGPoint) {
        autoScrollLastCanvasPoint = canvasPoint
        let delta = autoScrollDelta(forCanvasX: canvasPoint.x)
        if abs(delta) > 0.1 {
            if autoScrollTimer == nil {
                autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.fireAutoScroll()
                    }
                }
            }
        } else {
            stopAutoScroll()
        }
    }

    private func fireAutoScroll() {
        let delta = autoScrollDelta(forCanvasX: autoScrollLastCanvasPoint.x)
        guard abs(delta) > 0.1, let editor = editorView else {
            stopAutoScroll()
            return
        }
        editor.scrollByHorizontalDelta(delta)
        // Re-run selection update with the same canvas point — the viewport
        // moved but the cursor's document-space coordinate is unchanged.
        switch dragMode {
        case .marqueeSelect:
            updateMarquee(current: autoScrollLastCanvasPoint)
        case .lassoSelect:
            updateLasso(current: autoScrollLastCanvasPoint)
        default:
            break
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    // MARK: - Select Tool (Marquee)

    private func updateMarquee(current: CGPoint) {
        guard let origin = dragOrigin else { return }
        let rect = CGRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )

        // Show the marquee bounding box
        editorView?.updateMarqueeOverlay(canvasRect: rect)

        // Auto-scroll when near the edges of the visible area
        updateAutoScroll(canvasPoint: current)

        guard let editor = editorView else { return }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        let maxPitch = editor.maxPitch
        var selected = dragShiftHeld ? selectionBeforeDrag : Set<UUID>()

        for note in editor.notes {
            let noteRect = noteRect(for: note, pixelsPerTick: ppt, rowHeight: rh, maxPitch: maxPitch)
            if rect.intersects(noteRect) {
                selected.insert(note.id)
            }
        }
        selectedNoteIDs = selected
    }

    // MARK: - Select Tool (Lasso)

    private func updateLasso(current: CGPoint) {
        // Subsample: skip points that are very close to the last one
        if let last = lassoPoints.last {
            let dx = current.x - last.x
            let dy = current.y - last.y
            guard dx * dx + dy * dy > 9 else { return }  // 3pt minimum distance
        }
        lassoPoints.append(current)

        // Update the visual overlay
        editorView?.updateLassoOverlay(canvasPoints: lassoPoints)

        // Auto-scroll when near the edges of the visible area
        updateAutoScroll(canvasPoint: current)

        // Build a CGPath from the points and test note centers for containment
        guard lassoPoints.count >= 3 else { return }
        let path = CGMutablePath()
        path.move(to: lassoPoints[0])
        for i in 1..<lassoPoints.count {
            path.addLine(to: lassoPoints[i])
        }
        path.closeSubpath()

        guard let editor = editorView else { return }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        let maxPitch = editor.maxPitch
        var selected = dragShiftHeld ? selectionBeforeDrag : Set<UUID>()

        for note in editor.notes {
            let noteRect = noteRect(for: note, pixelsPerTick: ppt, rowHeight: rh, maxPitch: maxPitch)
            // Test the center of the note against the lasso path
            let center = CGPoint(x: noteRect.midX, y: noteRect.midY)
            if path.contains(center) {
                selected.insert(note.id)
            }
        }
        selectedNoteIDs = selected
    }

    // MARK: - Alt+Scroll Velocity

    /// Adjust velocity of the note under the cursor (or all selected if it's selected) via Alt+scroll wheel.
    private func handleAltScrollVelocity(at point: NSPoint, deltaY: CGFloat) -> Bool {
        guard let editor = editorView else { return false }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        let maxPitch = editor.maxPitch

        // Find the note under the cursor
        var hitNote: PianoRollNote?
        for note in editor.notes {
            if noteRect(for: note, pixelsPerTick: ppt, rowHeight: rh, maxPitch: maxPitch).contains(point) {
                hitNote = note
                break
            }
        }
        guard let hitNote else { return false }

        let velDelta = Int(deltaY.rounded())
        guard velDelta != 0 else { return true }

        pushUndo()
        var notes = store.pianoRollNotes

        // If the hit note is selected, adjust all selected notes; otherwise just this one
        let targetIDs: Set<UUID> = selectedNoteIDs.contains(hitNote.id)
            ? selectedNoteIDs
            : [hitNote.id]

        for i in notes.indices where targetIDs.contains(notes[i].id) {
            notes[i].velocity = max(1, min(127, notes[i].velocity + velDelta))
        }
        store.setPianoRollNotesFromEditor(notes)
        return true
    }

    // MARK: - Erase Tool

    private func eraseNoteAt(point: NSPoint) {
        guard let editor = editorView else { return }
        let ppt = editor.pixelsPerTick
        let rh = editor.rowHeight
        let maxPitch = editor.maxPitch

        for note in editor.notes {
            if noteRect(for: note, pixelsPerTick: ppt, rowHeight: rh, maxPitch: maxPitch).contains(point) {
                var notes = store.pianoRollNotes
                notes.removeAll(where: { $0.id == note.id })
                store.setPianoRollNotesFromEditor(notes)
                selectedNoteIDs.remove(note.id)
                return
            }
        }
    }

    // MARK: - Slice Tool

    private func slice(at tick: Int) {
        guard tick > 0 else { return }
        var updated: [PianoRollNote] = []
        var anySplit = false

        for note in store.pianoRollNotes {
            let noteEnd = note.startTick + note.duration
            if note.startTick < tick, noteEnd > tick {
                var left = note
                left.duration = max(1, tick - note.startTick)
                let right = PianoRollNote(
                    trackIndex: note.trackIndex,
                    channel: note.channel,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    startTick: tick,
                    duration: max(1, noteEnd - tick)
                )
                updated.append(left)
                updated.append(right)
                anySplit = true
            } else {
                updated.append(note)
            }
        }

        if anySplit {
            store.setPianoRollNotesFromEditor(updated)
            selectedNoteIDs.removeAll()
        }
    }

    // MARK: - Note Actions (called from toolbar)

    func quantizeSelected() {
        applyQuantize(strength: 1.0)
    }

    /// Iterative quantize: moves notes toward the grid by the given strength (0.0–1.0).
    /// strength=1.0 is full quantize, 0.5 is half-way (preserves groove feel), 0.0 is no change.
    func applyQuantize(strength: Double, quantizeEnd: Bool = true) {
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        let notes = store.pianoRollNotes
        let targets = selectedNoteIDs.isEmpty ? Set(notes.map(\.id)) : selectedNoteIDs
        guard !targets.isEmpty else { return }

        pushUndo()
        let division = max(1, snapTicks)
        let s = min(1.0, max(0.0, strength))
        let updated = notes.map { note -> PianoRollNote in
            guard targets.contains(note.id) else { return note }
            var copy = note

            // Lerp start toward grid position
            let gridStart = snapToGrid(note.startTick, division: division)
            let newStart = Int(Double(note.startTick) + Double(gridStart - note.startTick) * s)
            copy.startTick = max(0, newStart)

            if quantizeEnd {
                let endTick = note.startTick + note.duration
                let gridEnd = snapToGrid(endTick, division: division)
                var newEnd = Int(Double(endTick) + Double(gridEnd - endTick) * s)
                if newEnd <= copy.startTick { newEnd = copy.startTick + division }
                copy.duration = max(1, newEnd - copy.startTick)
            } else {
                // Preserve original duration
                copy.duration = note.duration
            }

            return copy
        }
        store.setPianoRollNotesFromEditor(updated)
    }

    /// Shows a quantize dialog with strength and options.
    func showQuantizeDialog() {
        let alert = NSAlert()
        alert.messageText = "Intelligent Quantize"
        alert.informativeText = "Adjust quantize strength (100% = full grid snap, 50% = halfway, preserves groove feel)"
        alert.addButton(withTitle: "Quantize")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))

        // Strength slider
        let strengthLabel = NSTextField(labelWithString: "Strength: 100%")
        strengthLabel.frame = NSRect(x: 0, y: 44, width: 280, height: 18)
        strengthLabel.font = .systemFont(ofSize: 12)
        container.addSubview(strengthLabel)

        let slider = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 22, width: 280, height: 20)
        slider.numberOfTickMarks = 10
        slider.allowsTickMarkValuesOnly = false
        container.addSubview(slider)

        // Quantize ends checkbox
        let endCheck = NSButton(checkboxWithTitle: "Also quantize note ends", target: nil, action: nil)
        endCheck.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
        endCheck.state = .on
        container.addSubview(endCheck)

        // Live-update the label as slider moves
        @MainActor
        final class SliderDelegate: NSObject {
            weak var label: NSTextField?
            @objc func sliderChanged(_ sender: NSSlider) {
                label?.stringValue = "Strength: \(Int(sender.doubleValue))%"
            }
        }
        let delegate = SliderDelegate()
        delegate.label = strengthLabel
        slider.target = delegate
        slider.action = #selector(SliderDelegate.sliderChanged(_:))
        objc_setAssociatedObject(alert, "sliderDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let strength = slider.doubleValue / 100.0
        let quantizeEnds = endCheck.state == .on
        applyQuantize(strength: strength, quantizeEnd: quantizeEnds)

        store.statusMessage = "Quantized at \(Int(strength * 100))% strength"
    }

    /// Swing quantize: applies a shuffle feel by offsetting every other grid position.
    /// swingAmount: 0.0 = straight, 0.5 = medium shuffle, 1.0 = full triplet feel.
    func applySwing(swingAmount: Double) {
        let notes = store.pianoRollNotes
        let targets = selectedNoteIDs.isEmpty ? Set(notes.map(\.id)) : selectedNoteIDs
        guard !targets.isEmpty else { return }

        pushUndo()
        let division = max(1, snapTicks)
        let swingOffset = Int(Double(division) * min(1.0, max(0.0, swingAmount)) * 0.5)

        let updated = notes.map { note -> PianoRollNote in
            guard targets.contains(note.id) else { return note }
            var copy = note

            // Determine which grid position this note is nearest to
            let gridPos = snapToGrid(note.startTick, division: division)
            let beatInBar = gridPos / division

            // Apply swing to odd grid positions (the "ands")
            if beatInBar % 2 == 1 {
                copy.startTick = max(0, gridPos + swingOffset)
            } else {
                copy.startTick = max(0, gridPos)
            }

            return copy
        }
        store.setPianoRollNotesFromEditor(updated)
        store.statusMessage = "Applied swing (\(Int(swingAmount * 100))%)"
    }

    func duplicateSelected() {
        guard !selectedNoteIDs.isEmpty else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        let offset = max(store.ticksPerQuarter * 4, snapTicks)
        let source = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
        guard !source.isEmpty else { return }

        pushUndo()
        let duplicates = source.map { note in
            PianoRollNote(
                trackIndex: note.trackIndex,
                channel: note.channel,
                pitch: note.pitch,
                velocity: note.velocity,
                startTick: note.startTick + offset,
                duration: note.duration
            )
        }

        var notes = store.pianoRollNotes
        notes.append(contentsOf: duplicates)
        store.setPianoRollNotesFromEditor(notes)
        selectedNoteIDs = Set(duplicates.map(\.id))
    }

    func deleteSelected() {
        guard !selectedNoteIDs.isEmpty else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        pushUndo()
        var notes = store.pianoRollNotes
        notes.removeAll(where: { selectedNoteIDs.contains($0.id) })
        store.setPianoRollNotesFromEditor(notes)
        selectedNoteIDs.removeAll()
    }

    func selectAllNotes() {
        selectedNoteIDs = Set(store.pianoRollNotes.map(\.id))
    }

    /// Select all notes matching the channels and pitches of the current selection.
    func selectSimilar() {
        guard !selectedNoteIDs.isEmpty else { return }
        let selected = store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }
        let pitches = Set(selected.map(\.pitch))
        let channels = Set(selected.map(\.channel))
        selectedNoteIDs = Set(store.pianoRollNotes.filter {
            pitches.contains($0.pitch) && channels.contains($0.channel)
        }.map(\.id))
    }

    /// Select all notes on the same channel(s) as the current selection.
    func selectSameChannel() {
        guard !selectedNoteIDs.isEmpty else { return }
        let channels = Set(store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }.map(\.channel))
        selectedNoteIDs = Set(store.pianoRollNotes.filter { channels.contains($0.channel) }.map(\.id))
    }

    /// Select all notes with the same pitch(es) as the current selection.
    func selectSamePitch() {
        guard !selectedNoteIDs.isEmpty else { return }
        let pitches = Set(store.pianoRollNotes.filter { selectedNoteIDs.contains($0.id) }.map(\.pitch))
        selectedNoteIDs = Set(store.pianoRollNotes.filter { pitches.contains($0.pitch) }.map(\.id))
    }

    /// Invert the current selection.
    func invertSelection() {
        let allIDs = Set(store.pianoRollNotes.map(\.id))
        selectedNoteIDs = allIDs.subtracting(selectedNoteIDs)
    }

    /// Select notes within a velocity range.
    func selectByVelocityRange(low: Int, high: Int) {
        selectedNoteIDs = Set(store.pianoRollNotes.filter {
            $0.velocity >= low && $0.velocity <= high
        }.map(\.id))
    }

    /// Nudge selected notes by a tick and pitch delta.
    func nudgeSelected(tickDelta: Int, pitchDelta: Int) {
        guard !selectedNoteIDs.isEmpty else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        pushUndo()
        var notes = store.pianoRollNotes
        for i in notes.indices {
            guard selectedNoteIDs.contains(notes[i].id) else { continue }
            notes[i].startTick = max(0, notes[i].startTick + tickDelta)
            notes[i].pitch = min(108, max(21, notes[i].pitch + pitchDelta))
        }
        store.setPianoRollNotesFromEditor(notes)
    }

    func transposeSelected(semitones: Int) {
        nudgeSelected(tickDelta: 0, pitchDelta: semitones)
    }

    func applyLegato() {
        guard !selectedNoteIDs.isEmpty else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        pushUndo()
        var notes = store.pianoRollNotes

        // Collect selected notes sorted by start tick, then by pitch
        let selectedIndices = notes.indices.filter { selectedNoteIDs.contains(notes[$0].id) }
        let sorted = selectedIndices.sorted {
            if notes[$0].startTick != notes[$1].startTick {
                return notes[$0].startTick < notes[$1].startTick
            }
            return notes[$0].pitch < notes[$1].pitch
        }

        // For each selected note on the same pitch, extend it to reach the next note
        for i in 0..<sorted.count {
            let idx = sorted[i]
            let pitch = notes[idx].pitch
            // Find the next selected note on the same pitch
            var nextStart: Int?
            for j in (i + 1)..<sorted.count {
                let jIdx = sorted[j]
                if notes[jIdx].pitch == pitch {
                    nextStart = notes[jIdx].startTick
                    break
                }
            }
            if let next = nextStart {
                let gap = next - (notes[idx].startTick + notes[idx].duration)
                if gap > 0 {
                    notes[idx].duration += gap
                }
            }
        }

        store.setPianoRollNotesFromEditor(notes)
    }

    /// Strum: offset chord notes' start times by a small increment in pitch order.
    /// `ticksPerStep` controls the delay between successive notes.
    /// `ascending` = true means lowest pitch starts first.
    func applyStrum(ticksPerStep: Int = 30, ascending: Bool = true) {
        guard !selectedNoteIDs.isEmpty else { return }
        pushUndo()
        var notes = store.pianoRollNotes

        // Group selected notes by start tick (chords share the same start)
        let selectedIndices = notes.indices.filter { selectedNoteIDs.contains(notes[$0].id) }
        var byStartTick: [Int: [Int]] = [:]
        for idx in selectedIndices {
            byStartTick[notes[idx].startTick, default: []].append(idx)
        }

        for (_, indices) in byStartTick {
            guard indices.count > 1 else { continue }
            // Sort by pitch
            let sorted = ascending
                ? indices.sorted { notes[$0].pitch < notes[$1].pitch }
                : indices.sorted { notes[$0].pitch > notes[$1].pitch }
            for (i, idx) in sorted.enumerated() {
                notes[idx].startTick = max(0, notes[idx].startTick + i * ticksPerStep)
            }
        }

        store.setPianoRollNotesFromEditor(notes)
    }

    /// Humanize: apply random micro-offsets to start time, velocity, and duration.
    func applyHumanize(timeRange: Int = 20, velocityRange: Int = 12, durationRange: Int = 10) {
        guard !selectedNoteIDs.isEmpty else { return }
        pushUndo()
        var notes = store.pianoRollNotes

        for i in notes.indices {
            guard selectedNoteIDs.contains(notes[i].id) else { continue }
            let timeOffset = Int.random(in: -timeRange...timeRange)
            let velOffset = Int.random(in: -velocityRange...velocityRange)
            let durOffset = Int.random(in: -durationRange...durationRange)

            notes[i].startTick = max(0, notes[i].startTick + timeOffset)
            notes[i].velocity = min(127, max(1, notes[i].velocity + velOffset))
            notes[i].duration = max(1, notes[i].duration + durOffset)
        }

        store.setPianoRollNotesFromEditor(notes)
    }

    /// Chop: divide each selected note into equal subdivisions.
    /// `subdivisions` = number of parts (e.g., 4 = chop into 4 equal notes).
    /// `gapTicks` = silence between chopped notes (0 = legato, >0 = staccato).
    func applyChop(subdivisions: Int = 4, gapTicks: Int = 0) {
        guard !selectedNoteIDs.isEmpty, subdivisions >= 2 else { return }
        pushUndo()
        let notes = store.pianoRollNotes
        var newNotes: [PianoRollNote] = []

        for i in notes.indices {
            guard selectedNoteIDs.contains(notes[i].id) else {
                newNotes.append(notes[i])
                continue
            }
            let orig = notes[i]
            let subdivDuration = max(1, orig.duration / subdivisions)
            var newIDs: [UUID] = []

            for s in 0..<subdivisions {
                let start = orig.startTick + s * subdivDuration
                let dur = max(1, subdivDuration - gapTicks)
                let sub = PianoRollNote(
                    trackIndex: orig.trackIndex,
                    channel: orig.channel,
                    pitch: orig.pitch,
                    velocity: orig.velocity,
                    startTick: start,
                    duration: dur,
                    muted: orig.muted
                )
                newIDs.append(sub.id)
                newNotes.append(sub)
            }
            // Update selection to include new chopped notes
            selectedNoteIDs.remove(orig.id)
            for id in newIDs { selectedNoteIDs.insert(id) }
        }

        store.setPianoRollNotesFromEditor(newNotes)
    }

    /// Glue: merge adjacent same-pitch selected notes into single longer notes.
    func applyGlue() {
        guard !selectedNoteIDs.isEmpty else { return }
        guard !isAllTracksConstrainedMode else {
            store.statusMessage = "Select a track to edit notes"
            return
        }
        pushUndo()
        var notes = store.pianoRollNotes

        // Collect selected notes grouped by pitch
        let selectedIndices = notes.indices.filter { selectedNoteIDs.contains(notes[$0].id) }
        var byPitch: [Int: [Int]] = [:]
        for idx in selectedIndices {
            byPitch[notes[idx].pitch, default: []].append(idx)
        }

        var toRemove: Set<UUID> = []
        for (_, indices) in byPitch {
            guard indices.count > 1 else { continue }
            // Sort by start tick
            let sorted = indices.sorted { notes[$0].startTick < notes[$1].startTick }

            var i = 0
            while i < sorted.count {
                var mergeEnd = notes[sorted[i]].startTick + notes[sorted[i]].duration
                var j = i + 1
                // Find chain of adjacent/overlapping notes
                while j < sorted.count {
                    let nextStart = notes[sorted[j]].startTick
                    if nextStart <= mergeEnd {
                        // Overlapping or adjacent — extend
                        let nextEnd = nextStart + notes[sorted[j]].duration
                        mergeEnd = max(mergeEnd, nextEnd)
                        toRemove.insert(notes[sorted[j]].id)
                        j += 1
                    } else {
                        break
                    }
                }
                // Extend the first note to cover the merged range
                notes[sorted[i]].duration = mergeEnd - notes[sorted[i]].startTick
                i = j
            }
        }

        // Remove glued-away notes
        notes.removeAll { toRemove.contains($0.id) }
        selectedNoteIDs.subtract(toRemove)

        store.setPianoRollNotesFromEditor(notes)
    }

    /// Arpeggiate: convert selected chord notes into a sequential arpeggio.
    /// `direction`: "up", "down", "updown"
    /// `noteDuration`: duration of each arpeggiated note in ticks (0 = use snap)
    func applyArpeggiate(direction: String = "up", noteDuration: Int = 0) {
        guard !selectedNoteIDs.isEmpty else { return }
        pushUndo()
        var notes = store.pianoRollNotes

        let selectedIndices = notes.indices.filter { selectedNoteIDs.contains(notes[$0].id) }
        guard selectedIndices.count > 1 else { return }

        // Group by start tick
        var byStartTick: [Int: [Int]] = [:]
        for idx in selectedIndices {
            byStartTick[notes[idx].startTick, default: []].append(idx)
        }

        let stepDur = noteDuration > 0 ? noteDuration : snapTicks

        for (baseTick, indices) in byStartTick {
            guard indices.count > 1 else { continue }

            // Sort by pitch
            var ordered = indices.sorted { notes[$0].pitch < notes[$1].pitch }

            if direction == "down" {
                ordered.reverse()
            } else if direction == "updown" {
                // Up then down (excluding endpoints to avoid doubles)
                let up = ordered
                let down = Array(ordered.dropFirst().dropLast().reversed())
                ordered = up + down
            }

            for (step, idx) in ordered.enumerated() {
                notes[idx].startTick = baseTick + step * stepDur
                notes[idx].duration = stepDur
            }
        }

        store.setPianoRollNotesFromEditor(notes)
    }

    // MARK: - Keyboard Event Handling

    func handleKeyDown(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let hasShift = flags.contains(.shift)

        // Cmd-Z: Undo, Cmd-Shift-Z: Redo
        if hasCmd && event.charactersIgnoringModifiers == "z" {
            if hasShift { redo() } else { undo() }
            return true
        }

        // Cmd-A: Select All
        if hasCmd && event.charactersIgnoringModifiers == "a" {
            selectAllNotes()
            return true
        }

        // Cmd-C: Copy
        if hasCmd && event.charactersIgnoringModifiers == "c" {
            copySelected()
            return true
        }

        // Cmd-X: Cut
        if hasCmd && event.charactersIgnoringModifiers == "x" {
            cutSelected()
            return true
        }

        // Cmd-V: Paste (lyrics-to-assign when lyrics lane is visible + text on pasteboard)
        if hasCmd && event.charactersIgnoringModifiers == "v" {
            if lyricsLaneVisible,
               let pasteString = NSPasteboard.general.string(forType: .string),
               !pasteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               clipboard.isEmpty {
                pasteLyricsToNotes(pasteString)
            } else {
                pasteNotes()
            }
            return true
        }

        // Cmd-D: Duplicate
        if hasCmd && event.charactersIgnoringModifiers == "d" {
            duplicateSelected()
            return true
        }

        // Cmd-G: Glue notes
        if hasCmd && event.charactersIgnoringModifiers == "g" {
            applyGlue()
            return true
        }

        // Cmd-L: Legato
        if hasCmd && event.charactersIgnoringModifiers == "l" {
            applyLegato()
            return true
        }

        // Cmd-M: Add marker at playhead
        if hasCmd && event.charactersIgnoringModifiers == "m" {
            addMarker(at: playheadTick)
            return true
        }

        // Cmd-I: Invert selection
        if hasCmd && event.charactersIgnoringModifiers == "i" {
            invertSelection()
            return true
        }

        // Cmd-Shift-S: Select similar
        if hasCmd && hasShift && event.charactersIgnoringModifiers == "s" {
            selectSimilar()
            return true
        }

        // Cmd-Shift-G: Group selected notes
        if hasCmd && hasShift && event.charactersIgnoringModifiers == "g" {
            groupSelectedNotes()
            return true
        }

        // Cmd-Shift-U: Ungroup selected notes
        if hasCmd && hasShift && event.charactersIgnoringModifiers == "u" {
            ungroupSelectedNotes()
            return true
        }

        // Alt+G: Toggle ghost notes
        if flags.contains(.option) && event.charactersIgnoringModifiers?.lowercased() == "g" {
            showGhostNotes.toggle()
            // (objectWillChange not needed with @Observable)
            return true
        }

        // Ctrl+Q: Quick quantize (FL Studio shortcut)
        if flags.contains(.control) && event.charactersIgnoringModifiers?.lowercased() == "q" {
            quantizeSelected()
            return true
        }

        // Ctrl+Right/Left: Jump between markers
        if flags.contains(.control) {
            if event.keyCode == 124 { // Right arrow
                jumpToNextMarker()
                return true
            } else if event.keyCode == 123 { // Left arrow
                jumpToPreviousMarker()
                return true
            }
        }

        // No-modifier keys
        guard !hasCmd else { return false }

        switch event.keyCode {
        case 51, 117:  // Delete (backspace) / Forward Delete
            deleteSelected()
            return true

        case 53:  // Escape
            selectedNoteIDs.removeAll()
            return true

        case 49:  // Space — play/pause
            togglePlayPause()
            return true

        case 123:  // Left arrow — nudge left by snap
            let amount = hasShift ? store.ticksPerQuarter * 4 : snapTicks
            nudgeSelected(tickDelta: -amount, pitchDelta: 0)
            return true

        case 124:  // Right arrow — nudge right by snap
            let amount = hasShift ? store.ticksPerQuarter * 4 : snapTicks
            nudgeSelected(tickDelta: amount, pitchDelta: 0)
            return true

        case 126:  // Up arrow — nudge pitch up
            let amount = hasShift ? 12 : 1
            nudgeSelected(tickDelta: 0, pitchDelta: amount)
            return true

        case 125:  // Down arrow — nudge pitch down
            let amount = hasShift ? 12 : 1
            nudgeSelected(tickDelta: 0, pitchDelta: -amount)
            return true

        default:
            break
        }

        // M key: toggle mute on selected notes (no modifiers)
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "m", !hasShift {
            toggleMuteSelected()
            return true
        }

        // L key: toggle lyrics lane visibility
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "l", !hasShift {
            lyricsLaneVisible.toggle()
            // (objectWillChange not needed with @Observable)
            return true
        }

        // Tool shortcuts (single letter keys, no modifiers)
        if let chars = event.charactersIgnoringModifiers?.lowercased(), !hasShift {
            if isAllTracksConstrainedMode {
                switch chars {
                case "e":
                    tool = .select
                    return true
                case "p", "d", "t", "c":
                    store.statusMessage = "All Tracks uses the Select tool only"
                    return true
                default:
                    break
                }
            }
            switch chars {
            case "e": tool = .select; return true
            case "p": tool = .draw; return true
            case "d": tool = .erase; return true
            case "t": tool = .mute; return true
            case "c": tool = .slice; return true
            default: break
            }
        }

        return false
    }

    // MARK: - Double-Click (Note Properties)

    private func handleCanvasDoubleClick(point: NSPoint, event: NSEvent) {
        guard let note = noteAtPoint(point) else { return }
        selectedNoteIDs = [note.id]
        showNotePropertiesPopover(for: note, at: point)
    }

    private func showNotePropertiesPopover(for note: PianoRollNote, at canvasPoint: NSPoint) {
        guard let editor = editorView else { return }

        // Use the mouse location converted to editor view coordinates for positioning.
        // The popover anchors to a small rect around the click point.
        let mouseInEditor = NSPoint(
            x: max(10, min(editor.bounds.width - 10, canvasPoint.x)),
            y: max(10, min(editor.bounds.height - 10, editor.bounds.height / 2))
        )
        let anchorRect = CGRect(x: mouseInEditor.x - 1, y: mouseInEditor.y - 1, width: 2, height: 2)

        let popoverView = NotePropertiesView(
            store: store,
            noteID: note.id,
            ticksPerQuarter: store.ticksPerQuarter
        )
        let hostingVC = NSHostingController(rootView: popoverView)
        hostingVC.preferredContentSize = NSSize(width: 260, height: 240)

        let popover = NSPopover()
        popover.contentViewController = hostingVC
        popover.behavior = .transient
        popover.show(relativeTo: anchorRect, of: editor, preferredEdge: .maxY)
    }

    // MARK: - Right-Click Context Menu

    private func buildCanvasContextMenu(point: NSPoint, event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        // If right-clicked on a note, select it if not already
        if let hitNote = noteAtPoint(point) {
            if !selectedNoteIDs.contains(hitNote.id) {
                selectedNoteIDs = [hitNote.id]
            }
        }

        let hasSelection = !selectedNoteIDs.isEmpty

        let cutItem = NSMenuItem(title: "Cut", action: #selector(contextMenuCut), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = .command
        cutItem.target = self
        cutItem.isEnabled = hasSelection
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextMenuCopy), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextMenuPaste), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.target = self
        pasteItem.isEnabled = hasClipboard
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let dupItem = NSMenuItem(title: "Duplicate", action: #selector(contextMenuDuplicate), keyEquivalent: "d")
        dupItem.keyEquivalentModifierMask = .command
        dupItem.target = self
        dupItem.isEnabled = hasSelection
        menu.addItem(dupItem)

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextMenuDelete), keyEquivalent: "\u{08}")
        deleteItem.target = self
        deleteItem.isEnabled = hasSelection
        menu.addItem(deleteItem)

        menu.addItem(.separator())

        let muteTitle = {
            let anyUnmuted = store.pianoRollNotes.contains { selectedNoteIDs.contains($0.id) && !$0.muted }
            return anyUnmuted ? "Mute" : "Unmute"
        }()
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(contextMenuToggleMute), keyEquivalent: "m")
        muteItem.keyEquivalentModifierMask = []
        muteItem.target = self
        muteItem.isEnabled = hasSelection
        menu.addItem(muteItem)

        menu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(contextMenuSelectAll), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        // Select submenu
        let selectSubMenu = NSMenu()
        let similarItem = NSMenuItem(title: "Select Similar", action: #selector(contextMenuSelectSimilar), keyEquivalent: "")
        similarItem.target = self
        similarItem.isEnabled = hasSelection
        selectSubMenu.addItem(similarItem)

        let sameChItem = NSMenuItem(title: "Select Same Channel", action: #selector(contextMenuSelectSameChannel), keyEquivalent: "")
        sameChItem.target = self
        sameChItem.isEnabled = hasSelection
        selectSubMenu.addItem(sameChItem)

        let samePitchItem = NSMenuItem(title: "Select Same Pitch", action: #selector(contextMenuSelectSamePitch), keyEquivalent: "")
        samePitchItem.target = self
        samePitchItem.isEnabled = hasSelection
        selectSubMenu.addItem(samePitchItem)

        selectSubMenu.addItem(.separator())

        let invertItem = NSMenuItem(title: "Invert Selection", action: #selector(contextMenuInvertSelection), keyEquivalent: "")
        invertItem.target = self
        selectSubMenu.addItem(invertItem)

        let selectMenuItem = NSMenuItem(title: "Select...", action: nil, keyEquivalent: "")
        selectMenuItem.submenu = selectSubMenu
        menu.addItem(selectMenuItem)

        let quantizeMenu = NSMenu()
        let q100 = NSMenuItem(title: "Quantize 100%", action: #selector(contextMenuQuantize), keyEquivalent: "")
        q100.target = self
        quantizeMenu.addItem(q100)
        let qDialog = NSMenuItem(title: "Quantize...", action: #selector(contextMenuQuantizeDialog), keyEquivalent: "")
        qDialog.target = self
        quantizeMenu.addItem(qDialog)
        quantizeMenu.addItem(.separator())
        for (label, pct) in [("Light Swing (25%)", 25), ("Medium Swing (50%)", 50), ("Heavy Swing (75%)", 75)] {
            let item = NSMenuItem(title: label, action: #selector(contextMenuSwing(_:)), keyEquivalent: "")
            item.tag = pct
            item.target = self
            quantizeMenu.addItem(item)
        }
        let quantizeMenuItem = NSMenuItem(title: "Quantize", action: nil, keyEquivalent: "")
        quantizeMenuItem.submenu = quantizeMenu
        menu.addItem(quantizeMenuItem)

        let legatoItem = NSMenuItem(title: "Legato", action: #selector(contextMenuLegato), keyEquivalent: "")
        legatoItem.target = self
        legatoItem.isEnabled = hasSelection
        menu.addItem(legatoItem)

        // Transpose submenu
        if hasSelection {
            let transposeMenu = NSMenu()
            for (title, semitones) in [
                ("Up Octave (+12)", 12),
                ("Up Step (+1)", 1),
                ("Down Step (-1)", -1),
                ("Down Octave (-12)", -12),
            ] {
                let item = NSMenuItem(title: title, action: #selector(contextMenuTranspose(_:)), keyEquivalent: "")
                item.target = self
                item.tag = semitones
                transposeMenu.addItem(item)
            }
            let transposeItem = NSMenuItem(title: "Transpose", action: nil, keyEquivalent: "")
            transposeItem.submenu = transposeMenu
            menu.addItem(transposeItem)
        }

        if hasSelection {
            menu.addItem(.separator())

            // Strum submenu
            let strumMenu = NSMenu()
            let strumUp = NSMenuItem(title: "Strum Up (low → high)", action: #selector(contextMenuStrumUp), keyEquivalent: "")
            strumUp.target = self
            strumMenu.addItem(strumUp)
            let strumDown = NSMenuItem(title: "Strum Down (high → low)", action: #selector(contextMenuStrumDown), keyEquivalent: "")
            strumDown.target = self
            strumMenu.addItem(strumDown)
            let strumItem = NSMenuItem(title: "Strum", action: nil, keyEquivalent: "")
            strumItem.submenu = strumMenu
            menu.addItem(strumItem)

            // Arpeggiate submenu
            let arpMenu = NSMenu()
            for (title, dir) in [("Up", "up"), ("Down", "down"), ("Up-Down", "updown")] {
                let item = NSMenuItem(title: title, action: #selector(contextMenuArpeggiate(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = dir
                arpMenu.addItem(item)
            }
            let arpItem = NSMenuItem(title: "Arpeggiate", action: nil, keyEquivalent: "")
            arpItem.submenu = arpMenu
            menu.addItem(arpItem)

            let humanizeItem = NSMenuItem(title: "Humanize", action: #selector(contextMenuHumanize), keyEquivalent: "")
            humanizeItem.target = self
            menu.addItem(humanizeItem)

            // Chop submenu
            let chopMenu = NSMenu()
            for (title, subdivs) in [("÷2 (halves)", 2), ("÷3 (triplets)", 3), ("÷4 (quarters)", 4), ("÷8 (eighths)", 8)] {
                let item = NSMenuItem(title: title, action: #selector(contextMenuChop(_:)), keyEquivalent: "")
                item.target = self
                item.tag = subdivs
                chopMenu.addItem(item)
            }
            let chopItem = NSMenuItem(title: "Chop", action: nil, keyEquivalent: "")
            chopItem.submenu = chopMenu
            menu.addItem(chopItem)

            let glueItem = NSMenuItem(title: "Glue", action: #selector(contextMenuGlue), keyEquivalent: "g")
            glueItem.keyEquivalentModifierMask = .command
            glueItem.target = self
            menu.addItem(glueItem)
        }

        if hasSelection {
            menu.addItem(.separator())

            // Lyric submenu
            let lyricMenu = NSMenu()

            let setLyricItem = NSMenuItem(title: "Set Lyric...", action: #selector(contextMenuSetLyric), keyEquivalent: "l")
            setLyricItem.keyEquivalentModifierMask = .command
            setLyricItem.target = self
            lyricMenu.addItem(setLyricItem)

            let clearLyricItem = NSMenuItem(title: "Clear Lyric", action: #selector(contextMenuClearLyric), keyEquivalent: "")
            clearLyricItem.target = self
            lyricMenu.addItem(clearLyricItem)

            lyricMenu.addItem(.separator())

            let flowLyricsItem = NSMenuItem(title: "Flow Lyrics from Clipboard...", action: #selector(contextMenuFlowLyrics), keyEquivalent: "")
            flowLyricsItem.target = self
            lyricMenu.addItem(flowLyricsItem)

            let lyricSubmenuItem = NSMenuItem(title: "Lyrics", action: nil, keyEquivalent: "")
            lyricSubmenuItem.submenu = lyricMenu
            menu.addItem(lyricSubmenuItem)

            // Articulation submenu
            if let expMap = store.activeExpressionMap, !expMap.articulations.isEmpty {
                let artMenu = NSMenu()

                let clearArt = NSMenuItem(title: "None", action: #selector(contextMenuClearArticulation), keyEquivalent: "")
                clearArt.target = self
                artMenu.addItem(clearArt)
                artMenu.addItem(.separator())

                for art in expMap.articulations {
                    let item = NSMenuItem(title: art.name, action: #selector(contextMenuSetArticulation(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = art.id
                    // Mark if currently applied to the first selected note
                    if let firstNote = store.pianoRollNotes.first(where: { selectedNoteIDs.contains($0.id) }),
                       firstNote.articulationID == art.id {
                        item.state = .on
                    }
                    artMenu.addItem(item)
                }

                let artMenuItem = NSMenuItem(title: "Articulation", action: nil, keyEquivalent: "")
                artMenuItem.submenu = artMenu
                menu.addItem(artMenuItem)
            }
        }

        if hasSelection, let note = store.pianoRollNotes.first(where: { selectedNoteIDs.contains($0.id) }) {
            menu.addItem(.separator())
            let propsItem = NSMenuItem(title: "Properties...", action: #selector(contextMenuProperties), keyEquivalent: "")
            propsItem.target = self
            propsItem.representedObject = NotePropertiesContext(noteID: note.id, canvasPoint: point)
            menu.addItem(propsItem)
        }

        // Grouping
        if hasSelection {
            menu.addItem(.separator())

            // Check if any selected note is already in a group
            let selectedGroups = store.pianoRollNoteGroups.filter { group in
                !group.noteIDs.filter({ selectedNoteIDs.contains($0) }).isEmpty
            }

            if selectedGroups.isEmpty {
                let groupItem = NSMenuItem(title: "Group (Cmd+G)", action: #selector(contextMenuGroupNotes), keyEquivalent: "g")
                groupItem.keyEquivalentModifierMask = .command
                groupItem.target = self
                menu.addItem(groupItem)
            } else {
                let ungroupItem = NSMenuItem(title: "Ungroup (Cmd+Shift+G)", action: #selector(contextMenuUngroupNotes), keyEquivalent: "G")
                ungroupItem.keyEquivalentModifierMask = [.command, .shift]
                ungroupItem.target = self
                menu.addItem(ungroupItem)

                if selectedGroups.count == 1 {
                    let renameItem = NSMenuItem(title: "Rename Group...", action: #selector(contextMenuRenameGroup), keyEquivalent: "")
                    renameItem.target = self
                    renameItem.representedObject = selectedGroups[0].id
                    menu.addItem(renameItem)
                }
            }
        }

        return menu
    }

    /// Helper struct for passing note context through menu items.
    private class NotePropertiesContext: NSObject {
        let noteID: UUID
        let canvasPoint: NSPoint
        init(noteID: UUID, canvasPoint: NSPoint) {
            self.noteID = noteID
            self.canvasPoint = canvasPoint
        }
    }

    @objc private func contextMenuCut() { cutSelected() }
    @objc private func contextMenuCopy() { copySelected() }
    @objc private func contextMenuPaste() { pasteNotes() }
    @objc private func contextMenuDuplicate() { duplicateSelected() }
    @objc private func contextMenuDelete() { deleteSelected() }
    @objc private func contextMenuToggleMute() { toggleMuteSelected() }
    @objc private func contextMenuSelectAll() { selectAllNotes() }
    @objc private func contextMenuSelectSimilar() { selectSimilar() }
    @objc private func contextMenuSelectSameChannel() { selectSameChannel() }
    @objc private func contextMenuSelectSamePitch() { selectSamePitch() }
    @objc private func contextMenuInvertSelection() { invertSelection() }
    @objc private func contextMenuQuantize() { quantizeSelected() }
    @objc private func contextMenuQuantizeDialog() { showQuantizeDialog() }
    @objc private func contextMenuSwing(_ sender: NSMenuItem) { applySwing(swingAmount: Double(sender.tag) / 100.0) }
    @objc private func contextMenuSetArticulation(_ sender: NSMenuItem) {
        guard let artID = sender.representedObject as? UUID else { return }
        pushUndo()
        var notes = store.pianoRollNotes
        for id in selectedNoteIDs {
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx].articulationID = artID
            }
        }
        store.setPianoRollNotesFromEditor(notes)
    }
    @objc private func contextMenuClearArticulation() {
        pushUndo()
        var notes = store.pianoRollNotes
        for id in selectedNoteIDs {
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx].articulationID = nil
            }
        }
        store.setPianoRollNotesFromEditor(notes)
    }
    @objc private func contextMenuLegato() { applyLegato() }
    @objc private func contextMenuTranspose(_ sender: NSMenuItem) { transposeSelected(semitones: sender.tag) }
    @objc private func contextMenuStrumUp() { applyStrum(ticksPerStep: 30, ascending: true) }
    @objc private func contextMenuStrumDown() { applyStrum(ticksPerStep: 30, ascending: false) }
    @objc private func contextMenuHumanize() { applyHumanize() }
    @objc private func contextMenuChop(_ sender: NSMenuItem) { applyChop(subdivisions: sender.tag) }
    @objc private func contextMenuGlue() { applyGlue() }
    @objc private func contextMenuArpeggiate(_ sender: NSMenuItem) {
        let dir = sender.representedObject as? String ?? "up"
        applyArpeggiate(direction: dir)
    }

    @objc private func contextMenuSetLyric() {
        guard !selectedNoteIDs.isEmpty else { return }
        // If single note selected, show current lyric in the text field
        let currentLyric: String
        if selectedNoteIDs.count == 1,
           let note = store.pianoRollNotes.first(where: { $0.id == selectedNoteIDs.first }) {
            currentLyric = note.lyricSyllable ?? ""
        } else {
            currentLyric = ""
        }

        let alert = NSAlert()
        alert.messageText = "Set Lyric Syllable"
        alert.informativeText = selectedNoteIDs.count == 1
            ? "Enter the lyric syllable for this note:"
            : "Enter the lyric syllable for \(selectedNoteIDs.count) notes:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = currentLyric
        textField.placeholderString = "e.g. la, do, re"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let syllable = textField.stringValue.trimmingCharacters(in: .whitespaces)
        let value = syllable.isEmpty ? nil : syllable

        pushUndo()
        var notes = store.pianoRollNotes
        for id in selectedNoteIDs {
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx].lyricSyllable = value
            }
        }
        store.setPianoRollNotesFromEditor(notes)
    }

    @objc private func contextMenuClearLyric() {
        guard !selectedNoteIDs.isEmpty else { return }
        pushUndo()
        var notes = store.pianoRollNotes
        for id in selectedNoteIDs {
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx].lyricSyllable = nil
            }
        }
        store.setPianoRollNotesFromEditor(notes)
    }

    @objc private func contextMenuFlowLyrics() {
        guard !selectedNoteIDs.isEmpty else { return }
        guard let clipText = NSPasteboard.general.string(forType: .string), !clipText.isEmpty else {
            store.statusMessage = "No text on clipboard"
            return
        }

        // Split text into syllables by whitespace, hyphens become separate syllables
        // "A-mi-ra sings to-night" → ["A", "mi", "ra", "sings", "to", "night"]
        let syllables = clipText
            .components(separatedBy: .whitespaces)
            .flatMap { word -> [String] in
                let parts = word.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
                return parts.isEmpty ? [word] : parts
            }
            .filter { !$0.isEmpty }

        guard !syllables.isEmpty else {
            store.statusMessage = "No syllables found in clipboard text"
            return
        }

        // Sort selected notes by start tick, then by pitch (low to high)
        let sortedIDs = store.pianoRollNotes
            .filter { selectedNoteIDs.contains($0.id) }
            .sorted { a, b in
                if a.startTick != b.startTick { return a.startTick < b.startTick }
                return a.pitch < b.pitch
            }
            .map(\.id)

        pushUndo()
        var notes = store.pianoRollNotes
        for (i, noteID) in sortedIDs.enumerated() {
            guard i < syllables.count else { break }
            if let idx = notes.firstIndex(where: { $0.id == noteID }) {
                notes[idx].lyricSyllable = syllables[i]
            }
        }
        store.setPianoRollNotesFromEditor(notes)

        let assigned = min(sortedIDs.count, syllables.count)
        store.statusMessage = "Flowed \(assigned) syllable\(assigned == 1 ? "" : "s") onto notes"
    }

    @objc private func contextMenuProperties(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? NotePropertiesContext,
              let note = store.pianoRollNotes.first(where: { $0.id == ctx.noteID }) else { return }
        showNotePropertiesPopover(for: note, at: ctx.canvasPoint)
    }

    // MARK: - Note Grouping

    @objc private func contextMenuGroupNotes() { groupSelectedNotes() }
    @objc private func contextMenuUngroupNotes() { ungroupSelectedNotes() }

    @objc private func contextMenuRenameGroup(_ sender: NSMenuItem) {
        guard let groupID = sender.representedObject as? UUID,
              let idx = store.pianoRollNoteGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = store.pianoRollNoteGroups[idx]

        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.informativeText = "Enter a new name for this phrase group:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = group.name
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.pianoRollNoteGroups[idx].name = name
        store.isDirty = true
        pushDataToEditor()
    }

    func groupSelectedNotes() {
        guard selectedNoteIDs.count >= 2 else {
            store.statusMessage = "Select 2+ notes to group"
            return
        }

        // Remove selected notes from any existing groups
        for i in store.pianoRollNoteGroups.indices {
            store.pianoRollNoteGroups[i].noteIDs.removeAll { selectedNoteIDs.contains($0) }
        }
        store.pianoRollNoteGroups.removeAll { $0.noteIDs.isEmpty }

        let count = store.pianoRollNoteGroups.count + 1
        let group = NoteGroup(name: "Phrase \(count)", noteIDs: Array(selectedNoteIDs))
        store.pianoRollNoteGroups.append(group)
        store.isDirty = true
        store.statusMessage = "Grouped \(selectedNoteIDs.count) notes as \"\(group.name)\""
        pushDataToEditor()
    }

    func ungroupSelectedNotes() {
        var removed = 0
        for i in store.pianoRollNoteGroups.indices.reversed() {
            let before = store.pianoRollNoteGroups[i].noteIDs.count
            store.pianoRollNoteGroups[i].noteIDs.removeAll { selectedNoteIDs.contains($0) }
            removed += before - store.pianoRollNoteGroups[i].noteIDs.count
        }
        store.pianoRollNoteGroups.removeAll { $0.noteIDs.isEmpty }
        if removed > 0 {
            store.isDirty = true
            store.statusMessage = "Ungrouped \(removed) notes"
            pushDataToEditor()
        }
    }

    /// Expands selection to include all notes in any group that overlaps the current selection.
    private func expandSelectionToGroups() {
        var expanded = selectedNoteIDs
        for group in store.pianoRollNoteGroups {
            if !group.noteIDs.filter({ expanded.contains($0) }).isEmpty {
                for noteID in group.noteIDs {
                    expanded.insert(noteID)
                }
            }
        }
        selectedNoteIDs = expanded
    }

    // MARK: - Markers

    private func addMarker(at tick: Int) {
        let count = store.pianoRollMarkers.count + 1
        let marker = MixMarker(tick: tick, name: "Marker \(count)")
        store.pianoRollMarkers.append(marker)
        store.pianoRollMarkers.sort(by: { $0.tick < $1.tick })
        store.isDirty = true
        pushDataToEditor()
    }

    private func deleteMarker(id: UUID) {
        store.pianoRollMarkers.removeAll(where: { $0.id == id })
        store.isDirty = true
        pushDataToEditor()
    }

    private func renameMarker(id: UUID, newName: String) {
        if let idx = store.pianoRollMarkers.firstIndex(where: { $0.id == id }) {
            store.pianoRollMarkers[idx].name = newName
            store.isDirty = true
            pushDataToEditor()
        }
    }

    /// Jump playhead to the next marker after the current playhead position.
    func jumpToNextMarker() {
        let markers = store.pianoRollMarkers.sorted(by: { $0.tick < $1.tick })
        if let next = markers.first(where: { $0.tick > playheadTick }) {
            setPlayhead(tick: next.tick)
        }
    }

    /// Jump playhead to the previous marker before the current playhead position.
    func jumpToPreviousMarker() {
        let markers = store.pianoRollMarkers.sorted(by: { $0.tick < $1.tick })
        if let prev = markers.last(where: { $0.tick < playheadTick }) {
            setPlayhead(tick: prev.tick)
        }
    }

    // MARK: - Suno Splits

    private func addSunoSplit(at tick: Int) {
        // Don't add duplicate splits (within 1 beat tolerance)
        let tpq = max(1, store.ticksPerQuarter)
        let tooClose = store.sunoSplitTicks.contains { abs($0 - tick) < tpq }
        guard !tooClose else { return }
        store.sunoSplitTicks.append(tick)
        store.sunoSplitTicks.sort()
        store.isDirty = true
        pushDataToEditor()
    }

    private func deleteSunoSplit(at tick: Int) {
        store.sunoSplitTicks.removeAll { $0 == tick }
        store.isDirty = true
        pushDataToEditor()
    }

    // MARK: - Helpers

    private var availableTrackIndices: [Int] {
        store.availableTrackIndices
    }

    private func defaultChannel(for trackIndex: Int) -> Int {
        if let existing = store.pianoRollNotes.first(where: { $0.trackIndex == trackIndex }) {
            return existing.channel
        }
        let prefix = "\(trackIndex):"
        let matchingPairKeys = store.pianoRollChannelKeyByTrackChannel.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        if let firstPairKey = matchingPairKeys.first {
            let parts = firstPairKey.split(separator: ":")
            if parts.count == 2, let channel = Int(parts[1]) { return channel }
        }
        if let knownChannels = store.pianoRollTrackChannelPrograms[trackIndex]?.keys.sorted(),
           let first = knownChannels.first {
            return first
        }
        return max(0, trackIndex % 16)
    }
}

// Tool & Snap enums and PianoRollToolbarView are in PianoRollToolbarView.swift

// MARK: - Lane Resize Handle

/// A transparent view that shows a vertical-resize cursor and reports drag deltas.
/// Used as the header/padding area above each lane section (velocity, tempo).
/// Click to pass through to the label button; drag to resize the lane height.
@available(macOS 26.0, *)
@MainActor
final class LaneResizeHandleView: NSView {

    /// Called during a drag with the vertical delta (positive = mouse moved down).
    var onResize: ((CGFloat) -> Void)?

    private var lastDragY: CGFloat = 0
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastDragY = location.y
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let delta = location.y - lastDragY
        if !isDragging && abs(delta) > 2 {
            isDragging = true
        }
        if isDragging {
            onResize?(delta)
            lastDragY = location.y
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            // If it was a click (not a drag), pass through to the label button
            for subview in subviews {
                if let button = subview as? NSButton {
                    button.performClick(nil)
                    break
                }
            }
        }
        isDragging = false
    }
}

// MARK: - Empty State View

@available(macOS 26.0, *)
private struct PianoRollEmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a song from the left column",
            systemImage: "music.note"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Note Properties Popover

/// A small SwiftUI form shown in a popover when double-clicking a note.
@available(macOS 26.0, *)
private struct NotePropertiesView: View {
    var store: ScoreStore
    let noteID: UUID
    let ticksPerQuarter: Int

    private var noteBinding: Binding<PianoRollNote?> {
        Binding(
            get: { store.pianoRollNotes.first(where: { $0.id == noteID }) },
            set: { newValue in
                guard let note = newValue,
                      let idx = store.pianoRollNotes.firstIndex(where: { $0.id == noteID }) else { return }
                store.pianoRollNotes[idx] = note
                store.isDirty = true
            }
        )
    }

    private static let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    private func noteName(for pitch: Int) -> String {
        let name = Self.pitchNames[pitch % 12]
        let octave = (pitch / 12) - 1
        return "\(name)\(octave)"
    }

    private func barBeatTick(_ tick: Int) -> String {
        let tpq = max(1, ticksPerQuarter)
        let ticksPerBar = tpq * 4
        let bar = (tick / ticksPerBar) + 1
        let beat = ((tick % ticksPerBar) / tpq) + 1
        let remainder = tick % tpq
        return "\(bar):\(beat):\(String(format: "%03d", remainder))"
    }

    var body: some View {
        if let note = noteBinding.wrappedValue {
            Form {
                LabeledContent("Pitch") {
                    HStack(spacing: 4) {
                        Text(noteName(for: note.pitch))
                            .font(.system(.body, design: .monospaced))
                        Stepper("", value: Binding(
                            get: { note.pitch },
                            set: { newPitch in
                                var n = note
                                n.pitch = min(108, max(21, newPitch))
                                noteBinding.wrappedValue = n
                            }
                        ), in: 21...108)
                        .labelsHidden()
                    }
                }

                LabeledContent("Velocity") {
                    HStack(spacing: 4) {
                        Text("\(note.velocity)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 30, alignment: .trailing)
                        Slider(value: Binding(
                            get: { Double(note.velocity) },
                            set: { v in
                                var n = note
                                n.velocity = max(1, min(127, Int(v.rounded())))
                                noteBinding.wrappedValue = n
                            }
                        ), in: 1...127, step: 1)
                        .frame(width: 100)
                    }
                }

                LabeledContent("Start") {
                    Text(barBeatTick(note.startTick))
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Duration") {
                    Text(barBeatTick(note.duration))
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Channel") {
                    Text("\(note.channel)")
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Track") {
                    Text("\(note.trackIndex)")
                        .font(.system(.body, design: .monospaced))
                }

                Toggle("Muted", isOn: Binding(
                    get: { note.muted },
                    set: { m in
                        var n = note
                        n.muted = m
                        noteBinding.wrappedValue = n
                    }
                ))
            }
            .formStyle(.grouped)
            .frame(width: 260, height: 220)
        } else {
            Text("Note not found")
                .foregroundStyle(.secondary)
                .frame(width: 260, height: 100)
        }
    }
}
#endif
