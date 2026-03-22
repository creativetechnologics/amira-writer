#if os(macOS)
import SwiftUI
import NovotroProjectKit

// MARK: - Tool & Snap Enums (for PianoRollViewController)

@available(macOS 26.0, *)
enum PianoRollToolChoice: String, CaseIterable, Identifiable {
    case select = "Select"
    case draw = "Draw"
    case paintbrush = "Paint"
    case erase = "Erase"
    case mute = "Mute"
    case slice = "Slice"
    case stamp = "Stamp"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .draw: return "pencil"
        case .paintbrush: return "paintbrush"
        case .erase: return "eraser"
        case .mute: return "speaker.slash"
        case .slice: return "scissors"
        case .stamp: return "music.note.list"
        }
    }
}

@available(macOS 26.0, *)
enum PianoRollSnapChoice: String, CaseIterable, Identifiable {
    case line = "Line"
    case off = "Off"
    case bar = "1 Bar"
    case half = "1/2"
    case halfDotted = "1/2."
    case halfTriplet = "1/2T"
    case quarter = "1/4"
    case quarterDotted = "1/4."
    case quarterTriplet = "1/4T"
    case eighth = "1/8"
    case eighthDotted = "1/8."
    case eighthTriplet = "1/8T"
    case sixteenth = "1/16"
    case sixteenthTriplet = "1/16T"
    case thirtySecond = "1/32"

    var id: String { rawValue }

    func tickSpan(ticksPerQuarter: Int) -> Int {
        let tpq = max(1, ticksPerQuarter)
        switch self {
        case .line: return tpq // default; actual resolution computed dynamically
        case .off: return 1
        case .bar: return tpq * 4
        case .half: return tpq * 2
        case .halfDotted: return tpq * 3              // 1/2 + 1/4
        case .halfTriplet: return max(1, tpq * 4 / 3) // 2/3 of a half note
        case .quarter: return tpq
        case .quarterDotted: return max(1, tpq * 3 / 2) // 1/4 + 1/8
        case .quarterTriplet: return max(1, tpq * 2 / 3) // 2/3 of a quarter
        case .eighth: return max(1, tpq / 2)
        case .eighthDotted: return max(1, tpq * 3 / 4) // 1/8 + 1/16
        case .eighthTriplet: return max(1, tpq / 3)    // 2/3 of an eighth
        case .sixteenth: return max(1, tpq / 4)
        case .sixteenthTriplet: return max(1, tpq / 6) // 2/3 of a sixteenth
        case .thirtySecond: return max(1, tpq / 8)
        }
    }

    /// Dynamic "Line" snap: adapts grid resolution to zoom level.
    func dynamicTickSpan(ticksPerQuarter: Int, pixelsPerQuarter: CGFloat) -> Int {
        let tpq = max(1, ticksPerQuarter)
        guard self == .line else { return tickSpan(ticksPerQuarter: tpq) }

        // Choose finest grid that keeps grid lines >= 12px apart
        let minPixelGap: CGFloat = 12
        let pixelsPerTick = pixelsPerQuarter / CGFloat(tpq)
        let candidates = [tpq / 8, tpq / 6, tpq / 4, tpq / 3, tpq / 2, tpq, tpq * 2, tpq * 4]
        for ticks in candidates {
            let gap = CGFloat(ticks) * pixelsPerTick
            if gap >= minPixelGap { return max(1, ticks) }
        }
        return tpq * 4
    }
}

// MARK: - Scale Enums

@available(macOS 26.0, *)
enum ScaleRoot: Int, CaseIterable, Identifiable {
    case c = 0, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .c: return "C"
        case .cSharp: return "C#"
        case .d: return "D"
        case .dSharp: return "D#"
        case .e: return "E"
        case .f: return "F"
        case .fSharp: return "F#"
        case .g: return "G"
        case .gSharp: return "G#"
        case .a: return "A"
        case .aSharp: return "A#"
        case .b: return "B"
        }
    }
}

@available(macOS 26.0, *)
enum ScaleType: String, CaseIterable, Identifiable {
    case none = "Off"
    case major = "Major"
    case minor = "Minor"
    case harmonicMinor = "Harmonic Minor"
    case melodicMinor = "Melodic Minor"
    case dorian = "Dorian"
    case phrygian = "Phrygian"
    case lydian = "Lydian"
    case mixolydian = "Mixolydian"
    case locrian = "Locrian"
    case pentatonicMajor = "Pentatonic Major"
    case pentatonicMinor = "Pentatonic Minor"
    case blues = "Blues"
    case chromatic = "Chromatic"
    case wholeTone = "Whole Tone"

    var id: String { rawValue }

    /// Intervals relative to root (semitones from root that are "in scale").
    var intervals: Set<Int>? {
        switch self {
        case .none: return nil
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .harmonicMinor: return [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor: return [0, 2, 3, 5, 7, 9, 11]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian: return [0, 1, 3, 5, 7, 8, 10]
        case .lydian: return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .locrian: return [0, 1, 3, 5, 6, 8, 10]
        case .pentatonicMajor: return [0, 2, 4, 7, 9]
        case .pentatonicMinor: return [0, 3, 5, 7, 10]
        case .blues: return [0, 3, 5, 6, 7, 10]
        case .chromatic: return Set(0..<12)
        case .wholeTone: return [0, 2, 4, 6, 8, 10]
        }
    }

    /// Returns the set of pitch classes (0-11) in scale for the given root.
    func pitchClasses(root: ScaleRoot) -> Set<Int>? {
        guard let intervals else { return nil }
        return Set(intervals.map { ($0 + root.rawValue) % 12 })
    }
}

// MARK: - Chord Detection & Stamp

@available(macOS 26.0, *)
enum ChordQuality: String, CaseIterable, Identifiable {
    case major = "Major"
    case minor = "Minor"
    case diminished = "Dim"
    case augmented = "Aug"
    case sus2 = "Sus2"
    case sus4 = "Sus4"
    case dom7 = "7"
    case maj7 = "Maj7"
    case min7 = "Min7"
    case dim7 = "Dim7"
    case halfDim7 = "m7b5"
    case aug7 = "Aug7"
    case minMaj7 = "mMaj7"
    case add9 = "Add9"
    case power = "5"

    var id: String { rawValue }

    /// Semitone intervals from root (0 = root).
    var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .dom7: return [0, 4, 7, 10]
        case .maj7: return [0, 4, 7, 11]
        case .min7: return [0, 3, 7, 10]
        case .dim7: return [0, 3, 6, 9]
        case .halfDim7: return [0, 3, 6, 10]
        case .aug7: return [0, 4, 8, 10]
        case .minMaj7: return [0, 3, 7, 11]
        case .add9: return [0, 4, 7, 14]
        case .power: return [0, 7]
        }
    }

    /// Short suffix for display (e.g. "m", "dim", "7").
    var suffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .diminished: return "dim"
        case .augmented: return "aug"
        case .sus2: return "sus2"
        case .sus4: return "sus4"
        case .dom7: return "7"
        case .maj7: return "maj7"
        case .min7: return "m7"
        case .dim7: return "dim7"
        case .halfDim7: return "m7b5"
        case .aug7: return "aug7"
        case .minMaj7: return "mMaj7"
        case .add9: return "add9"
        case .power: return "5"
        }
    }
}

/// Detects chord names from a set of MIDI pitches.
@available(macOS 26.0, *)
enum ChordDetector {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Known chord interval patterns (sorted by specificity — longer chords first).
    private static let knownChords: [(Set<Int>, String)] = {
        // 4-note chords first, then 3-note, then 2-note
        var chords: [(Set<Int>, String)] = []
        for quality in ChordQuality.allCases {
            let intervals = Set(quality.intervals.map { $0 % 12 })
            chords.append((intervals, quality.suffix))
        }
        // Sort by interval count descending (match most specific first)
        chords.sort { $0.0.count > $1.0.count }
        return chords
    }()

    /// Detects chord name from MIDI pitches. Returns nil if unrecognized or fewer than 2 notes.
    static func detect(pitches: [Int]) -> String? {
        let pitchClasses = Set(pitches.map { (($0 % 12) + 12) % 12 })
        guard pitchClasses.count >= 2 else { return nil }

        // Try each pitch class as potential root
        for root in pitchClasses.sorted() {
            let intervals = Set(pitchClasses.map { (($0 - root) + 12) % 12 })

            for (pattern, suffix) in knownChords {
                if intervals == pattern {
                    let rootName = noteNames[root]
                    return "\(rootName)\(suffix)"
                }
            }
        }

        // Check for inversions: try all 12 roots
        for root in 0..<12 {
            let intervals = Set(pitchClasses.map { (($0 - root) + 12) % 12 })

            for (pattern, suffix) in knownChords where pattern.count <= pitchClasses.count {
                if pattern.isSubset(of: intervals) {
                    let rootName = noteNames[root]
                    let bassPC = pitchClasses.min()!
                    if bassPC != root {
                        let bassName = noteNames[bassPC]
                        return "\(rootName)\(suffix)/\(bassName)"
                    }
                    return "\(rootName)\(suffix)"
                }
            }
        }

        return nil
    }

    /// Returns the note name for display (e.g. "C4", "F#5").
    static func noteName(pitch: Int) -> String {
        let pc = ((pitch % 12) + 12) % 12
        let octave = (pitch / 12) - 1
        return "\(noteNames[pc])\(octave)"
    }
}

// MARK: - PianoRollToolbarView (SwiftUI)

/// SwiftUI toolbar hosted above the Metal editor view.
/// Logic Pro-style 2-row layout: Control Bar (transport + LCD + modes) / Tool Bar (tools + snap + actions).
@available(macOS 26.0, *)
struct PianoRollToolbarView: View {
    var store: ScoreStore
    unowned let controller: PianoRollViewController

    @State private var rewindTimer: Timer?
    @State private var ffTimer: Timer?
    @State private var showPartGenPopover = false
    @State private var partGenInstrument: String = "Violins I"
    @State private var partGenStyle: InstrumentPartGenerator.GenerationStyle = .sustained
    @State private var showLLMPopover = false
    @State private var llmFreeformPrompt: String = ""

    #if canImport(MLXLLM)
    /// Computed binding for the LLM model picker, backed by the persisted store preference.
    private var llmModelSelection: Binding<LLMClient.DefaultModel> {
        Binding(
            get: { LLMClient.DefaultModel(rawValue: store.preferredLLMModelID) ?? .llama3_2_3B },
            set: { store.preferredLLMModelID = $0.rawValue }
        )
    }
    #endif

    // Phase 5: Style Analysis & Composition
    @State private var showStylePopover = false
    @State private var showComposePopover = false
    @State private var showLeitmotifPopover = false
    @State private var composeContour: MelodicContour = .arch
    @State private var composePitchLow: Double = 60
    @State private var composePitchHigh: Double = 84
    @State private var composeDuration: Double = 8
    @State private var composeDensity: Double = 2.0
    @State private var leitmotifName: String = ""
    @State private var selectedVariationType: VariationType = .inversion
    @State private var transposeSemitones: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.selectedMidiID != nil {
                // Layout selection based on actual hosting view width fed from AppKit.
                // Using store.toolbarAvailableWidth (not GeometryReader or ViewThatFits)
                // because NSHostingView with intrinsicContentSize proposes IDEAL width
                // to SwiftUI — only this external width is reliable.
                if store.toolbarAvailableWidth >= 960 {
                    wideLayout       // preferred: 2-row
                } else if store.toolbarAvailableWidth >= 700 {
                    compactLayout    // medium: 3-row
                } else {
                    narrowLayout     // narrow: 4-row
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "pianokeys.inverse")
                        .foregroundStyle(.secondary)
                    Text("No Song Selected")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .clipped()
    }

    // MARK: - Wide Layout (2-row, preferred)

    private var wideLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            controlBarWide
            activityProgressBar
            toolBarWide
        }
    }

    // MARK: - Compact Layout (3-row, medium)

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            compactRow1
            compactRow2
            activityProgressBar
            compactRow3
            musicIntelligenceBar
        }
    }

    // MARK: - Narrow Layout (4-row, most compact)

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            compactRow1
            compactRow2
            activityProgressBar
            narrowRow3
            narrowRow4
            musicIntelligenceBar
        }
    }

    // MARK: - Toolbar Sections (shared between inline and overflow layouts)

    private var sectionSongNav: some View {
        toolbarSection {
            HStack(spacing: 2) {
                ToolbarHoverButton(action: { store.selectPreviousMidi() }, help: "Previous song") {
                    Image(systemName: "backward.end.fill").frame(width: 20, height: 20)
                }
                ToolbarHoverButton(action: { store.selectNextMidi() }, help: "Next song") {
                    Image(systemName: "forward.end.fill").frame(width: 20, height: 20)
                }
            }
        }
    }

    private var sectionTransport: some View {
        toolbarSection {
            HStack(spacing: 3) {
                Button { controller.goToStart() } label: {
                    Image(systemName: "backward.frame.fill").frame(width: 20, height: 20)
                }
                .buttonStyle(TransportButtonStyle())
                .help("Go to start")

                RepeatButton(action: { controller.rewindPlayhead() }, delay: 0.35, interval: 0.12) {
                    Image(systemName: "backward.fill").frame(width: 20, height: 20)
                }
                .help("Rewind one bar (hold to repeat)")

                Button { controller.stopAndReset() } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(TransportButtonStyle())
                .foregroundStyle(store.isPlaying ? .primary : (controller.playheadStopped ? .secondary : .primary))
                .help(store.isPlaying ? "Stop (keep position)" : "Return to start")

                Button { controller.togglePlayPause() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(TransportButtonStyle())
                .foregroundStyle(store.isPlaying ? Color.accentColor : .primary)
                .help(store.isPlaying ? "Pause (Space)" : "Play (Space)")

                RepeatButton(action: { controller.fastForwardPlayhead() }, delay: 0.35, interval: 0.12) {
                    Image(systemName: "forward.fill").frame(width: 20, height: 20)
                }
                .help("Forward one bar (hold to repeat)")

                Button { controller.goToEnd() } label: {
                    Image(systemName: "forward.frame.fill").frame(width: 20, height: 20)
                }
                .buttonStyle(TransportButtonStyle())
                .help("Go to end")

                Button { store.continuousPlay.toggle() } label: {
                    Image(systemName: "arrow.right.to.line.compact")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(TransportButtonStyle())
                .foregroundStyle(store.continuousPlay ? Color.green : .secondary)
                .background(store.continuousPlay ? Color.green.opacity(0.15) : .clear,
                            in: .rect(cornerRadius: 5))
                .help(store.continuousPlay ? "Continuous play ON — auto-advances to next song" : "Continuous play OFF")

                Button {
                    let alert = NSAlert()
                    alert.messageText = "Reset Tempo?"
                    alert.informativeText = "This will replace all tempo events with a single \(String(format: "%.1f", store.tempoBPM)) BPM event at the start."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        store.pianoRollTempoEvents = [TempoPoint(tick: 0, bpm: store.tempoBPM)]
                        store.isDirty = true
                    }
                } label: {
                    Image(systemName: "metronome")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(TransportButtonStyle())
                .help("Reset all tempo events to current BPM")
            }
        }
    }

    private var sectionLCD: some View {
        toolbarSection { lcdDisplay }
    }

    private var sectionModes: some View {
        toolbarSection {
            HStack(spacing: 5) {
                modeToggle(icon: "scope", isActive: controller.followMode != .off,
                           help: "Playhead follow: \(controller.followMode.rawValue)") {
                    let modes = PlayheadFollowMode.allCases
                    let idx = modes.firstIndex(of: controller.followMode) ?? 0
                    controller.followMode = modes[(idx + 1) % modes.count]
                    // (objectWillChange not needed with @Observable)
                }
                modeToggle(icon: "antenna.radiowaves.left.and.right",
                           isActive: store.midiInputMonitorEnabled, help: "MIDI Monitor") {
                    store.midiInputMonitorEnabled.toggle()
                    if store.midiInputMonitorEnabled && !store.midiInputManager.isConnected {
                        store.midiInputManager.connectToAll()
                    }
                }
                modeToggle(icon: "arrow.right.to.line.compact",
                           isActive: store.midiInputStepMode, activeColor: .orange, help: "Step Input") {
                    store.midiInputStepMode.toggle()
                    if store.midiInputStepMode && !store.midiInputManager.isConnected {
                        store.midiInputManager.connectToAll()
                    }
                }
                Circle()
                    .fill(store.midiInputManager.midiActivity ? Color.green : Color.gray.opacity(0.2))
                    .frame(width: 6, height: 6)
                if store.midiInputStepMode {
                    Picker("", selection: Binding(
                        get: { StepDuration.fromTicks(store.stepInputDuration, tpq: store.ticksPerQuarter) },
                        set: { store.stepInputDuration = $0.ticks(tpq: store.ticksPerQuarter) }
                    )) {
                        ForEach(StepDuration.allCases) { dur in
                            Text(dur.rawValue).tag(dur)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 56)
                }
            }
        }
    }

    private var sectionVolume: some View {
        toolbarSection {
            HStack(spacing: 4) {
                Image(systemName: volumeIcon)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: Binding(
                    get: { store.masterVolume },
                    set: { store.setMasterVolume($0) }
                ), in: 0...1)
                    .frame(width: 80)
                Text("\(Int((store.masterVolume * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private var sectionTools: some View {
        toolbarSection {
            HStack(spacing: 1) {
                ForEach(Array(PianoRollToolChoice.allCases), id: \.self) { item in
                    let isSelected = controller.tool == item
                    Button {
                        controller.tool = item
                        // (objectWillChange not needed with @Observable)
                    } label: {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 13))
                            .frame(width: 26, height: 24)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(ToolSelectorStyle(isSelected: isSelected))
                    .help(item.rawValue)
                }
            }
        }
    }

    private var sectionSnap: some View {
        toolbarSection {
            HStack(spacing: 4) {
                Image(systemName: "magnet")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { controller.snap },
                    set: { controller.snap = $0 }
                )) {
                    ForEach(PianoRollSnapChoice.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 76)
            }
        }
    }

    private var sectionUndoRedo: some View {
        toolbarSection {
            HStack(spacing: 2) {
                ToolbarHoverButton(action: { controller.undo() }, help: "Undo (Cmd-Z)") {
                    Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 22)
                }
                .disabled(!controller.canUndo)
                ToolbarHoverButton(action: { controller.redo() }, help: "Redo (Cmd-Shift-Z)") {
                    Image(systemName: "arrow.uturn.forward").frame(width: 22, height: 22)
                }
                .disabled(!controller.canRedo)
            }
        }
    }

    private var sectionQuickActions: some View {
        toolbarSection {
            HStack(spacing: 3) {
                miniButton("Qtz", icon: "metronome", help: "Quantize (Ctrl+Q)") {
                    controller.quantizeSelected()
                }
                miniButton("Dup", icon: "plus.square.on.square", help: "Duplicate (Cmd-D)") {
                    controller.duplicateSelected()
                }
                .disabled(controller.selectedNoteIDs.isEmpty)
                miniButton("Del", icon: "trash", help: "Delete") {
                    controller.deleteSelected()
                }
                .disabled(controller.selectedNoteIDs.isEmpty)
                miniButton("All", icon: "selection.pin.in.out", help: "Select All (Cmd-A)") {
                    controller.selectAllNotes()
                }
            }
        }
    }

    private var sectionViewToggles: some View {
        toolbarSection {
            HStack(spacing: 4) {
                modeToggle(icon: "square.stack.3d.up.fill",
                           isActive: controller.showGhostNotes, help: "Ghost notes") {
                    controller.showGhostNotes.toggle()
                    // (objectWillChange not needed with @Observable)
                }
                modeToggle(icon: "person.2.fill",
                           isActive: controller.multiVoiceMode, activeColor: .cyan, help: "Voice lanes") {
                    controller.multiVoiceMode.toggle()
                    // (objectWillChange not needed with @Observable)
                }
                modeToggle(icon: "paintpalette.fill",
                           isActive: controller.velocityColorEnabled, activeColor: .orange, help: "Velocity coloring") {
                    controller.velocityColorEnabled.toggle()
                    // (objectWillChange not needed with @Observable)
                }
            }
        }
    }

    private var sectionScale: some View {
        toolbarSection {
            HStack(spacing: 3) {
                Picker("", selection: Binding(
                    get: { controller.scaleType },
                    set: { controller.scaleType = $0 }
                )) {
                    ForEach(ScaleType.allCases) { scale in
                        Text(scale.rawValue).tag(scale)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                if controller.scaleType != .none {
                    Picker("", selection: Binding(
                        get: { controller.scaleRoot },
                        set: { controller.scaleRoot = $0 }
                    )) {
                        ForEach(ScaleRoot.allCases) { root in
                            Text(root.displayName).tag(root)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 50)
                }
            }
        }
    }

    private func sectionChord(_ chord: String) -> some View {
        toolbarSection {
            HStack(spacing: 3) {
                Image(systemName: "tuningfork").font(.caption).foregroundStyle(.secondary)
                Text(chord)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
            }
        }
    }

    // MARK: - Music Intelligence Section

    private var sectionMusicIntelligence: some View {
        toolbarSection {
            HStack(spacing: 3) {
                miniButton("SA", icon: "wand.and.stars", help: "Smart Align lyrics (phrase + contour aware)") {
                    controller.smartAutoAlignLyrics()
                }
                #if canImport(MLXLLM)
                miniButton("LA", icon: "brain.head.profile", help: "LLM Align lyrics (AI-powered)") {
                    store.performLLMAlignment()
                }
                #endif
                miniButton("FM", icon: "arrow.triangle.2.circlepath", help: "Fit MIDI notes to match lyric syllable counts per phrase") {
                    store.fitMIDIToLyrics()
                }
                if store.smartAlignmentPreview != nil {
                    miniButton("Ok", icon: "checkmark.diamond.fill", help: "Accept alignment") {
                        store.acceptSmartAlignmentPreview()
                    }
                    .tint(.green)
                    miniButton("No", icon: "xmark.diamond.fill", help: "Reject alignment") {
                        store.rejectSmartAlignmentPreview()
                    }
                    .tint(.red)
                }
                miniButton("An", icon: "waveform.path.ecg", help: "Analyze structure + key + chords") {
                    controller.analyzeStructure()
                }
                miniButton("H4", icon: "music.quarternote.3", help: "Generate SATB harmonization") {
                    store.generateHarmonization()
                }
                miniButton("IP", icon: "pianokeys", help: "Generate instrument part") {
                    showPartGenPopover.toggle()
                }
                .popover(isPresented: $showPartGenPopover, arrowEdge: .bottom) {
                    partGenerationPopover
                }
                if store.generatedPart != nil {
                    miniButton("Ok", icon: "checkmark.diamond.fill", help: "Accept instrument part") {
                        store.acceptGeneratedPart()
                    }
                    .tint(.green)
                    miniButton("No", icon: "xmark.diamond.fill", help: "Reject instrument part") {
                        store.rejectGeneratedPart()
                    }
                    .tint(.red)
                }
                #if canImport(MLXLLM)
                miniButton("AI", icon: "brain", help: "LLM musical reasoning") {
                    showLLMPopover.toggle()
                }
                .popover(isPresented: $showLLMPopover, arrowEdge: .bottom) {
                    llmPopover
                }
                if store.llmGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .help("LLM generating...")
                }
                #endif
                miniButton("Sty", icon: "waveform.badge.magnifyingglass", help: "Analyze musical style") {
                    showStylePopover.toggle()
                }
                .popover(isPresented: $showStylePopover, arrowEdge: .bottom) {
                    styleAnalysisPopover
                }
                miniButton("Cmp", icon: "music.note.list", help: "Compose melody") {
                    showComposePopover.toggle()
                }
                .popover(isPresented: $showComposePopover, arrowEdge: .bottom) {
                    melodyComposePopover
                }
                miniButton("LM", icon: "repeat", help: "Leitmotif manager") {
                    showLeitmotifPopover.toggle()
                }
                .popover(isPresented: $showLeitmotifPopover, arrowEdge: .bottom) {
                    leitmotifPopover
                }
                if store.composedMelody != nil {
                    miniButton("Ok", icon: "checkmark.seal.fill", help: "Accept composed melody") {
                        store.acceptComposedMelody()
                    }
                    .tint(.green)
                    miniButton("No", icon: "xmark.seal.fill", help: "Reject composed melody") {
                        store.rejectComposedMelody()
                    }
                    .tint(.red)
                }
                if let style = store.detectedStyle {
                    Text(style.genreHints.prefix(3).joined(separator: ", "))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.purple)
                        .help("Detected style: \(style.genreHints.joined(separator: ", "))")
                }
                if let analysis = store.currentStructuralAnalysis {
                    if let key = analysis.detectedKey {
                        Text(key.displayName)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.cyan)
                            .help("Detected key: \(key.displayName) (\(String(format: "%.0f%%", key.confidence * 100)) confidence)")
                    }
                    Text("\(analysis.phrases.count)P \(analysis.sections.count)S")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("\(analysis.phrases.count) phrases, \(analysis.sections.count) sections detected")
                }
                if let chords = store.currentChordProgression, !chords.chords.isEmpty {
                    Text("\(chords.chords.count)ch")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                        .help("Chords: \(chords.chords.prefix(8).map(\.displayName).joined(separator: " "))\(chords.chords.count > 8 ? "..." : "")")
                }
                if store.proposedMelodicMutation != nil {
                    miniButton("Ok", icon: "checkmark.circle", help: "Accept melodic changes") {
                        store.acceptMelodicMutation()
                    }
                    .tint(.green)
                    miniButton("No", icon: "xmark.circle", help: "Reject melodic changes") {
                        store.rejectMelodicMutation()
                    }
                    .tint(.red)
                }
                if store.currentHarmonization != nil {
                    miniButton("Ok", icon: "checkmark.circle.fill", help: "Accept SATB harmonization") {
                        store.acceptHarmonization()
                    }
                    .tint(.green)
                    miniButton("No", icon: "xmark.circle.fill", help: "Reject harmonization") {
                        store.rejectHarmonization()
                    }
                    .tint(.red)
                }
            }
        }
    }

    /// Popover content for instrument part generation.
    private var partGenerationPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generate Instrument Part")
                .font(.system(size: 11, weight: .semibold))

            Picker("Instrument", selection: $partGenInstrument) {
                ForEach(availableInstrumentNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 11))

            Picker("Style", selection: $partGenStyle) {
                ForEach(InstrumentPartGenerator.GenerationStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 11))

            Button("Generate") {
                showPartGenPopover = false
                store.generateInstrumentPart(instrument: partGenInstrument, style: partGenStyle)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 200)
    }

    /// Instrument names from loaded mappings (instrument role only), sorted by canonical order.
    private var availableInstrumentNames: [String] {
        store.instrumentMappings.values
            .filter { $0.trackRole == .instrument }
            .sorted { $0.effectiveSortOrder < $1.effectiveSortOrder }
            .map(\.displayName)
    }

    #if canImport(MLXLLM)
    /// Popover content for LLM musical reasoning.
    private var llmPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Musical Reasoning")
                .font(.system(size: 11, weight: .semibold))

            // Model control
            HStack(spacing: 4) {
                Picker("Model", selection: llmModelSelection) {
                    ForEach(LLMClient.DefaultModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 10))
                .frame(maxWidth: 120)

                switch store.llmClient.modelState {
                case .idle:
                    Button("Load") {
                        store.loadLLMModel(id: llmModelSelection.wrappedValue.rawValue)
                    }
                    .controlSize(.small)
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 50)
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                case .ready:
                    Button("Unload") {
                        store.unloadLLMModel()
                    }
                    .controlSize(.small)
                    .tint(.red)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if case .error(let msg) = store.llmClient.modelState {
                Text(msg)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if case .ready = store.llmClient.modelState {
                Divider()

                // Quick actions
                Text("Quick Actions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Button("Lyric Fit") { store.evaluateLyricMelodyFit() }
                    Button("Chords") { store.suggestChordsWithLLM() }
                    Button("Style") { store.describeStyleWithLLM() }
                    Button("Arrange") { store.suggestArrangementWithLLM() }
                }
                .controlSize(.mini)
                .disabled(store.llmGenerating)

                Divider()

                // Freeform prompt
                HStack(spacing: 4) {
                    TextField("Ask about the music...", text: $llmFreeformPrompt)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .onSubmit {
                            store.askLLMFreeform(prompt: llmFreeformPrompt)
                            llmFreeformPrompt = ""
                        }
                    Button("Send") {
                        store.askLLMFreeform(prompt: llmFreeformPrompt)
                        llmFreeformPrompt = ""
                    }
                    .controlSize(.mini)
                    .disabled(llmFreeformPrompt.isEmpty || store.llmGenerating)
                }

                // Response area
                if !store.llmResponse.isEmpty {
                    ScrollView {
                        Text(store.llmResponse)
                            .font(.system(size: 10))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }

                if store.llmGenerating {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating...")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 280)
    }
    #endif

    /// Popover content for style analysis.
    private var styleAnalysisPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style Analysis")
                .font(.system(size: 11, weight: .semibold))

            Button("Analyze Style") {
                showStylePopover = false
                store.analyzeMusicalStyle()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if let style = store.detectedStyle {
                Divider()

                // Genre hints
                Text("Genre Hints")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(style.genreHints, id: \.self) { hint in
                        Text(hint)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                // Sub-scores
                VStack(alignment: .leading, spacing: 4) {
                    Text("Melodic")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        styleMetric("Density", value: style.melodicProfile.noteDensity, format: "%.1f n/b")
                        styleMetric("Leaps", value: style.melodicProfile.leapFrequency * 100, format: "%.0f%%")
                        styleMetric("Range", value: Double(style.melodicProfile.pitchRange), format: "%.0f st")
                    }

                    Text("Rhythmic")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        styleMetric("Sync", value: style.rhythmicProfile.syncopationIndex * 100, format: "%.0f%%")
                        styleMetric("Variety", value: style.rhythmicProfile.rhythmicVariety * 100, format: "%.0f%%")
                        styleMetric("Rests", value: style.rhythmicProfile.restFrequency * 100, format: "%.0f%%")
                    }

                    Text("Harmonic")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        styleMetric("Func", value: style.harmonicComplexity.functionalStrength * 100, format: "%.0f%%")
                        styleMetric("Ext", value: style.harmonicComplexity.extensionUsage * 100, format: "%.0f%%")
                        styleMetric("Chrom", value: style.harmonicComplexity.chromaticism * 100, format: "%.0f%%")
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    private func styleMetric(_ label: String, value: Double, format: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(String(format: format, value))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
    }

    /// Popover content for melody composition.
    private var melodyComposePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compose Melody")
                .font(.system(size: 11, weight: .semibold))

            Picker("Contour", selection: $composeContour) {
                Text("Ascending").tag(MelodicContour.ascending)
                Text("Descending").tag(MelodicContour.descending)
                Text("Arch").tag(MelodicContour.arch)
                Text("Inverted Arch").tag(MelodicContour.invertedArch)
                Text("Constant").tag(MelodicContour.constant)
                Text("Mixed").tag(MelodicContour.mixed)
            }
            .pickerStyle(.menu)
            .font(.system(size: 10))

            HStack {
                Text("Pitch Range")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(composePitchLow))–\(Int(composePitchHigh))")
                    .font(.system(size: 10, design: .monospaced))
            }
            HStack(spacing: 4) {
                Slider(value: $composePitchLow, in: 36...96, step: 1)
                    .frame(width: 80)
                Slider(value: $composePitchHigh, in: 48...108, step: 1)
                    .frame(width: 80)
            }

            HStack {
                Text("Duration (beats)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f", composeDuration))
                    .font(.system(size: 10, design: .monospaced))
            }
            Slider(value: $composeDuration, in: 2...64, step: 1)

            HStack {
                Text("Density (notes/beat)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f", composeDensity))
                    .font(.system(size: 10, design: .monospaced))
            }
            Slider(value: $composeDensity, in: 0.5...8.0, step: 0.5)

            Button("Generate") {
                showComposePopover = false
                let key = store.currentStructuralAnalysis?.detectedKey
                    ?? DetectedKey(root: 0, isMinor: false, confidence: 0.5)
                let startTick = store.pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? 0
                let constraints = MelodyConstraints(
                    key: key,
                    pitchRange: Int(composePitchLow)...Int(composePitchHigh),
                    durationBeats: composeDuration,
                    contour: composeContour,
                    noteDensity: composeDensity,
                    startTick: startTick + store.ticksPerQuarter,
                    ticksPerQuarter: store.ticksPerQuarter,
                    channel: 0,
                    trackIndex: 0,
                    velocity: 80
                )
                store.composeMelody(constraints: constraints)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 240)
    }

    /// Popover content for leitmotif management.
    private var leitmotifPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leitmotif Manager")
                .font(.system(size: 11, weight: .semibold))

            // Register new motif from selection
            HStack(spacing: 4) {
                TextField("Motif name", text: $leitmotifName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                Button("Register") {
                    store.registerLeitmotif(
                        name: leitmotifName.isEmpty ? "Motif \(store.leitmotifs.count + 1)" : leitmotifName,
                        noteIDs: Array(controller.selectedNoteIDs)
                    )
                    leitmotifName = ""
                }
                .controlSize(.mini)
                .disabled(controller.selectedNoteIDs.count < 2)
            }

            if !store.leitmotifs.isEmpty {
                Divider()

                Text("Registered Motifs")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.leitmotifs) { motif in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(motif.name)
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(motif.pitchPattern.count) notes")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 4) {
                                    Picker("", selection: $selectedVariationType) {
                                        ForEach(VariationType.allCases, id: \.self) { vt in
                                            Text(vt.displayName).tag(vt)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .font(.system(size: 9))
                                    .frame(maxWidth: 110)

                                    if selectedVariationType == .transposition {
                                        Stepper(
                                            value: $transposeSemitones,
                                            in: -12...12,
                                            step: 1
                                        ) {
                                            Text("\(Int(transposeSemitones))st")
                                                .font(.system(size: 9, design: .monospaced))
                                        }
                                    }

                                    Button("Go") {
                                        store.generateLeitmotifVariation(
                                            id: motif.id,
                                            type: selectedVariationType,
                                            semitones: Int(transposeSemitones)
                                        )
                                    }
                                    .controlSize(.mini)
                                }
                            }
                            .padding(4)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    private var sectionZoom: some View {
        toolbarSection {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { controller.pixelsPerQuarter },
                    set: { controller.pixelsPerQuarter = $0 }
                ), in: 24...340)
                    .frame(width: 90)
                Image(systemName: "arrow.up.and.down").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { controller.editorRowHeight },
                    set: { controller.editorRowHeight = $0 }
                ), in: 11...24)
                    .frame(width: 70)
            }
        }
    }

    // MARK: - Wide Row Variants

    private var controlBarWide: some View {
        HStack(spacing: 0) {
            sectionSongNav; toolbarDivider
            sectionTransport; toolbarDivider
            sectionModes; toolbarDivider
            sectionUndoRedo; toolbarDivider
            sectionQuickActions; toolbarDivider
            sectionViewToggles; toolbarDivider
            sectionScale
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var toolBarWide: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                sectionTools; toolbarDivider
                sectionSnap; toolbarDivider
                if let chord = controller.detectedChordName {
                    sectionChord(chord); toolbarDivider
                }
                if controller.tool == .stamp {
                    toolbarSection { stampToolControls }; toolbarDivider
                }
                sectionMusicIntelligence
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Compact Row Variants (3-row)

    private var compactRow1: some View {
        HStack(spacing: 0) {
            sectionSongNav; toolbarDivider
            sectionTransport; toolbarDivider
            sectionUndoRedo
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var compactRow2: some View {
        HStack(spacing: 0) {
            sectionTools; toolbarDivider
            sectionSnap
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var compactRow3: some View {
        HStack(spacing: 0) {
            sectionModes; toolbarDivider
            sectionQuickActions; toolbarDivider
            sectionViewToggles; toolbarDivider
            sectionScale
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Narrow Row Variants (4-row, splits compact row 3)

    private var narrowRow3: some View {
        HStack(spacing: 0) {
            sectionModes; toolbarDivider
            sectionQuickActions
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var narrowRow4: some View {
        HStack(spacing: 0) {
            sectionViewToggles; toolbarDivider
            sectionScale
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Music Intelligence Bar (dedicated scrollable row)

    private var musicIntelligenceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if let chord = controller.detectedChordName {
                    sectionChord(chord); toolbarDivider
                }
                if controller.tool == .stamp {
                    toolbarSection { stampToolControls }; toolbarDivider
                }
                sectionMusicIntelligence
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - Activity Progress Bar (downloads & renders)

    /// Compact progress strip that appears between control bar and tool bar when a model is
    /// downloading or a vocal track is rendering. Full width, thin, auto-hides when idle.
    @ViewBuilder
    private var activityProgressBar: some View {
        if let activity = activeRender {
            HStack(spacing: 6) {
                Image(systemName: activity.icon)
                    .font(.system(size: 9))
                    .foregroundStyle(activity.tint)

                Text(activity.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track background
                        Capsule()
                            .fill(.white.opacity(0.06))
                            .frame(height: 4)

                        // Filled portion
                        Capsule()
                            .fill(activity.tint.opacity(0.8))
                            .frame(width: max(0, geo.size.width * activity.progress), height: 4)
                            .animation(.easeInOut(duration: 0.3), value: activity.progress)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)
                }

                Text("\(Int(activity.progress * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(activity.tint)
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Describes an in-progress activity for the toolbar progress bar.
    private struct ActivityInfo {
        let label: String
        let progress: Double
        let icon: String
        let tint: Color
    }

    /// Finds the first vocal track currently rendering, if any.
    private var activeRender: ActivityInfo? {
        for (_, state) in store.voiceSynthesisService.renderStates {
            if case .rendering(let progress, let status) = state {
                return ActivityInfo(
                    label: status.isEmpty ? "Rendering vocals…" : status,
                    progress: progress,
                    icon: "waveform",
                    tint: .purple
                )
            }
        }
        return nil
    }

    // MARK: - LCD Position Display

    private var lcdDisplay: some View {
        HStack(spacing: 10) {
            // Bar : Beat : Tick (reads live playhead from store, updated at ~15Hz)
            HStack(spacing: 0) {
                let tpq = max(1, store.ticksPerQuarter)
                let ticksPerBeat = tpq
                let ticksPerBar = ticksPerBeat * 4
                let tick = max(0, store.livePlayheadTick)
                let bar = (tick / ticksPerBar) + 1
                let beat = ((tick % ticksPerBar) / ticksPerBeat) + 1
                let sub = tick % ticksPerBeat

                lcdDigits(String(format: "%03d", bar))
                lcdSeparator
                lcdDigits(String(format: "%02d", beat))
                lcdSeparator
                lcdDigits(String(format: "%03d", sub))
            }
            .fixedSize()  // keep time display as a solid block — never compress
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.35), in: .rect(cornerRadius: 4))

            // Tempo (shows live tempo at playhead position)
            HStack(spacing: 3) {
                Text("\u{2669}=")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(Int(store.liveTempoAtPlayhead.rounded()))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .onTapGesture { } // future: click-drag to adjust tempo

            // Audio activity waveform
            AudioWaveformView(store: store)
                .help(store.masterMeterLevels.rmsL > -55 ? "Audio output active" : "No audio output detected")

            // Song name (compact) — pulses briefly on song change
            Text(store.selectedMidiAsset?.displayName ?? "")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: 100)
                .id(store.selectedMidiID)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .animation(.easeOut(duration: 0.3), value: store.selectedMidiID)
        }
    }

    // MARK: - Stamp Tool Controls

    private var stampToolControls: some View {
        HStack(spacing: 3) {
            Picker("", selection: Binding(
                get: { controller.stampChordRoot },
                set: { controller.stampChordRoot = $0 }
            )) {
                ForEach(ScaleRoot.allCases) { root in
                    Text(root.displayName).tag(root)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 44)

            Picker("", selection: Binding(
                get: { controller.stampChordQuality },
                set: { controller.stampChordQuality = $0 }
            )) {
                ForEach(ChordQuality.allCases) { q in
                    Text(q.rawValue).tag(q)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 70)

            Stepper("Oct \(controller.stampOctave)", value: Binding(
                get: { controller.stampOctave },
                set: { controller.stampOctave = max(0, min(8, $0)) }
            ), in: 0...8)
            .font(.caption2)
        }
    }

    // MARK: - Reusable Components

    /// A section wrapper with horizontal padding.
    private func toolbarSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 6)
    }

    /// Thin vertical divider between toolbar sections.
    private var toolbarDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 24)
    }

    /// LCD digit text.
    private func lcdDigits(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
    }

    /// LCD dot separator.
    private var lcdSeparator: some View {
        Text(".")
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 1)
    }

    /// Mode toggle icon button (brighter when active, dimmer when inactive).
    private func modeToggle(icon: String, isActive: Bool, activeColor: Color = .accentColor,
                            help: String, action: @escaping () -> Void) -> some View {
        ToolbarHoverButton(action: action, help: help) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 24, height: 22)
                .foregroundStyle(isActive ? activeColor : Color.gray.opacity(0.5))
        }
    }

    /// Compact action button with icon only.
    private func miniButton(_ label: String, icon: String, help: String,
                            action: @escaping () -> Void) -> some View {
        ToolbarHoverButton(action: action, help: help) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
        }
    }

    private var volumeIcon: String {
        if store.masterVolume < 0.01 { return "speaker.slash.fill" }
        if store.masterVolume < 0.33 { return "speaker.wave.1.fill" }
        if store.masterVolume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - RepeatButton (Hold-to-Repeat)

/// Button style for tool selector buttons — shows active state and hover,
/// with the entire padded area clickable.
@available(macOS 26.0, *)
struct ToolSelectorStyle: ButtonStyle {
    var isSelected: Bool = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected
                        ? Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.15)
                        : configuration.isPressed
                            ? Color.white.opacity(0.14)
                            : isHovered ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.06), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// Button style for transport controls — hover tint, generous click area, press animation.
@available(macOS 26.0, *)
struct TransportButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed
                        ? Color.white.opacity(0.14)
                        : isHovered ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.82 : 1.0)
            .brightness(configuration.isPressed ? 0.3 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.06), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// Generic toolbar button style with hover tint and expanded hit target.
/// Padding and contentShape are INSIDE makeBody so the entire padded area is clickable.
@available(macOS 26.0, *)
struct ToolbarHoverStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed
                        ? Color.white.opacity(0.14)
                        : isHovered ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.06), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// Convenience wrapper: Button + ToolbarHoverStyle + .help().
@available(macOS 26.0, *)
private struct ToolbarHoverButton<Label: View>: View {
    let action: () -> Void
    var help: String = ""
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(ToolbarHoverStyle())
        .help(help)
    }
}

/// A button that fires once immediately, then repeats while held.
@available(macOS 26.0, *)
struct RepeatButton<Label: View>: View {
    let action: () -> Void
    let delay: TimeInterval
    let interval: TimeInterval
    @ViewBuilder let label: () -> Label

    @StateObject private var repeater = RepeatButtonCoordinator()
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        label()
            .frame(width: 16, height: 16)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isPressed ? Color.white.opacity(0.14) : isHovered ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                if pressing {
                    isPressed = true
                    action()
                    repeater.start(delay: delay, interval: interval, action: action)
                } else {
                    isPressed = false
                    repeater.stop()
                }
            }, perform: {})
            .foregroundStyle(isPressed ? .primary : .secondary)
            .scaleEffect(isPressed ? 0.78 : 1.0)
            .brightness(isPressed ? 0.3 : 0)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .animation(.easeOut(duration: 0.06), value: isHovered)
            .onHover { isHovered = $0 }
            .onDisappear { repeater.stop() }
    }
}

@MainActor
private final class RepeatButtonCoordinator: ObservableObject {
    private var delayTimer: Timer?
    private var repeatTimer: Timer?
    private var action: (() -> Void)?
    private var repeatInterval: TimeInterval = 0.1

    func start(delay: TimeInterval, interval: TimeInterval, action: @escaping () -> Void) {
        stop()
        self.action = action
        repeatInterval = max(0.01, interval)
        delayTimer = Timer.scheduledTimer(
            timeInterval: max(0, delay),
            target: self,
            selector: #selector(beginRepeating),
            userInfo: nil,
            repeats: false
        )
    }

    func stop() {
        delayTimer?.invalidate()
        repeatTimer?.invalidate()
        delayTimer = nil
        repeatTimer = nil
        action = nil
    }

    @objc private func beginRepeating() {
        repeatTimer = Timer.scheduledTimer(
            timeInterval: repeatInterval,
            target: self,
            selector: #selector(fireAction),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func fireAction() {
        action?()
    }
}

// MARK: - Standalone LCD View (positioned in title bar area by PianoRollViewController)

@available(macOS 26.0, *)
/// Title bar overlay: volume (left) | LCD timecode (center) | zoom with +/- (right).
@available(macOS 26.0, *)
struct TitleBarOverlay: View {
    var store: ScoreStore
    var controller: PianoRollViewController?

    var body: some View {
        HStack(spacing: 0) {
            // --- Volume (leading) ---
            HStack(spacing: 4) {
                Image(systemName: titleBarVolumeIcon)
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .frame(width: 16)
                Slider(value: Binding(
                    get: { store.masterVolume },
                    set: { store.setMasterVolume($0) }
                ), in: 0...1)
                    .frame(width: 80)
                Text("\(Int((store.masterVolume * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.leading, 8)

            // --- Suno A/B mode indicator ---
            if store.sunoRenderLayer != nil {
                Text(store.sunoRenderLayer?.playbackMode.rawValue ?? "—")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OperaChromeTheme.accentMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            // --- LCD timecode (center, non-interactive) ---
            PianoRollLCDView(store: store)

            Spacer()

            // --- Zoom sliders with +/- buttons (trailing) ---
            if let ctl = controller {
                HStack(spacing: 4) {
                    // Horizontal zoom
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    zoomButton(systemName: "minus") {
                        ctl.pixelsPerQuarter = max(24, ctl.pixelsPerQuarter - 20)
                    }
                    Slider(value: Binding(
                        get: { ctl.pixelsPerQuarter },
                        set: { ctl.pixelsPerQuarter = $0 }
                    ), in: 24...340)
                        .frame(width: 80)
                    zoomButton(systemName: "plus") {
                        ctl.pixelsPerQuarter = min(340, ctl.pixelsPerQuarter + 20)
                    }

                    // Vertical zoom
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    zoomButton(systemName: "minus") {
                        ctl.editorRowHeight = max(11, ctl.editorRowHeight - 1)
                    }
                    Slider(value: Binding(
                        get: { ctl.editorRowHeight },
                        set: { ctl.editorRowHeight = $0 }
                    ), in: 11...24)
                        .frame(width: 60)
                    zoomButton(systemName: "plus") {
                        ctl.editorRowHeight = min(24, ctl.editorRowHeight + 1)
                    }
                }
                .padding(.trailing, 8)
            }
        }
    }

    /// +/- button with a generous 22×22 hit target for easy clicking in the title bar.
    private func zoomButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OperaChromeTheme.textSecondary)
    }

    private var titleBarVolumeIcon: String {
        if store.masterVolume < 0.01 { return "speaker.slash.fill" }
        if store.masterVolume < 0.33 { return "speaker.wave.1.fill" }
        if store.masterVolume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

@available(macOS 26.0, *)
struct PianoRollLCDView: View {
    var store: ScoreStore

    var body: some View {
        if store.selectedMidiID != nil {
            HStack(spacing: 12) {
                // Bar : Beat : Tick (reads live playhead from store, updated at ~15Hz)
                HStack(spacing: 0) {
                    let tpq = max(1, store.ticksPerQuarter)
                    let ticksPerBeat = tpq
                    let ticksPerBar = ticksPerBeat * 4
                    let tick = max(0, store.livePlayheadTick)
                    let bar = (tick / ticksPerBar) + 1
                    let beat = ((tick % ticksPerBar) / ticksPerBeat) + 1
                    let sub = tick % ticksPerBeat

                    lcdDigits(String(format: "%03d", bar))
                    lcdSeparator
                    lcdDigits(String(format: "%02d", beat))
                    lcdSeparator
                    lcdDigits(String(format: "%03d", sub))
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    OperaChromeTheme.workspaceBackground.opacity(0.9),
                    in: .rect(cornerRadius: 5)
                )

                // Tempo (shows live tempo at playhead position)
                HStack(spacing: 3) {
                    Text("\u{2669}=")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("\(Int(store.liveTempoAtPlayhead.rounded()))")
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                }

                // Audio activity waveform — shows when audio pipeline is producing sound
                AudioWaveformView(store: store)
                    .help(store.masterMeterLevels.rmsL > -55 ? "Audio output active" : "No audio output detected")
            }
            .allowsHitTesting(false)
        }
    }

    private func lcdDigits(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 21, weight: .medium, design: .monospaced))
            .foregroundStyle(OperaChromeTheme.textPrimary)
    }

    private var lcdSeparator: some View {
        Text(".")
            .font(.system(size: 18, weight: .bold, design: .monospaced))
            .foregroundStyle(OperaChromeTheme.textSecondary)
            .padding(.horizontal, 1.5)
    }
}

// MARK: - Audio Waveform Activity Indicator

/// Animated waveform bars that show real audio pipeline activity.
///
/// Two modes:
/// - **Sequencer running** (`store.isPlaying`): bars always animate at minimum
///   height, scaling up with actual RMS level from the audio tap. This confirms
///   the engine is running even when system audio is muted.
/// - **Stopped**: bars collapse to a flat thin line.
///
/// Color: green = normal, yellow = loud (>-12 dB), red = clipping.
@available(macOS 26.0, *)
struct AudioWaveformView: View {
    var store: ScoreStore
    private let barCount = 5

    var body: some View {
        let isPlaying = store.isPlaying
        // Use peak for color cues, RMS for height (smoother feel)
        let rmsDB = max(store.masterMeterLevels.rmsL, store.masterMeterLevels.rmsR)
        let peakDB = max(store.masterMeterLevels.peakL, store.masterMeterLevels.peakR)
        let clipped = store.masterMeterLevels.clipped

        // Normalised 0-1 amplitude from RMS (-70 dB floor to 0 dB ceiling)
        let floorDB: Float = -70
        let meterAmplitude = isPlaying
            ? Double(max(0, min(1, (rmsDB - floorDB) / (-floorDB))))
            : 0.0
        // Minimum animation height when playing (so bars always move, even when muted)
        let minAmplitude: Double = isPlaying ? 0.18 : 0
        let amplitude = max(meterAmplitude, minAmplitude)

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = Double(i) * 0.72
                    let speed = 3.2 + Double(i) * 0.55
                    let osc = abs(sin(t * speed + phase))
                    let height = 2 + 11 * amplitude * osc
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(peakDB: peakDB, clipped: clipped))
                        .frame(width: 2.5, height: max(2, height))
                }
            }
            .frame(width: 22, height: 16)
        }
        .animation(.easeOut(duration: 0.15), value: isPlaying)
    }

    private func barColor(peakDB: Float, clipped: Bool) -> Color {
        if clipped || peakDB > -1  { return .red }
        if peakDB > -12            { return .yellow }
        return .green
    }
}

/// Step duration choices for step input mode.
enum StepDuration: String, CaseIterable, Identifiable {
    case whole = "1"
    case half = "1/2"
    case quarter = "1/4"
    case eighth = "1/8"
    case sixteenth = "1/16"
    case thirtySecond = "1/32"
    case quarterTriplet = "1/4T"
    case eighthTriplet = "1/8T"

    var id: String { rawValue }

    func ticks(tpq: Int) -> Int {
        switch self {
        case .whole:          return tpq * 4
        case .half:           return tpq * 2
        case .quarter:        return tpq
        case .eighth:         return tpq / 2
        case .sixteenth:      return tpq / 4
        case .thirtySecond:   return tpq / 8
        case .quarterTriplet: return (tpq * 2) / 3
        case .eighthTriplet:  return tpq / 3
        }
    }

    static func fromTicks(_ ticks: Int, tpq: Int) -> StepDuration {
        for dur in allCases {
            if dur.ticks(tpq: tpq) == ticks { return dur }
        }
        return .quarter
    }
}

// MARK: - Width-Aware Toolbar Hosting View
//
// NSHostingView with `sizingOptions = [.intrinsicContentSize]` proposes the view's
// IDEAL width to SwiftUI for intrinsicContentSize measurement. This breaks both
// ViewThatFits and GeometryReader — they always see unconstrained width.
//
// Solution: Feed the actual hosting view width to SwiftUI via ScoreStore.toolbarAvailableWidth.
// PianoRollToolbarView uses if/else on this value (NOT the proposed width) to select
// 2/3/4-row layout. Since the if/else checks the store property, the layout selection
// is correct even during intrinsicContentSize measurement at ideal width. The hosting
// view keeps `sizingOptions = [.intrinsicContentSize]` so Auto Layout gets the correct
// height automatically.
#endif
