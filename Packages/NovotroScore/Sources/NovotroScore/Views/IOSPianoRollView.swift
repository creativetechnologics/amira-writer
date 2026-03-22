#if os(iOS)
import SwiftUI

// MARK: - iOS Piano Roll (SwiftUI Canvas)

@available(iOS 26.0, *)
struct IOSPianoRollView: View {
    @Bindable var store: ScoreStore

    // Viewport state (local to view)
    @State private var scrollOffset: CGPoint = .zero   // x=tick offset, y=pitch offset
    @State private var ticksPerPoint: Double = 2.0     // horizontal zoom (lower=more zoomed in)
    @State private var pitchHeight: Double = 10.0      // vertical zoom (height per semitone)

    // Gesture state
    @State private var dragStart: CGPoint?
    @State private var lastMagnification: CGFloat = 1.0
    // Constants
    private let pianoKeyWidth: CGFloat = 44
    private let headerHeight: CGFloat = 28
    private let minPitch = 21   // A0
    private let maxPitch = 108  // C8
    private let minTicksPerPoint: Double = 0.25
    private let maxTicksPerPoint: Double = 16.0

    // MARK: - Color Palette

    private static let trackPalette: [Color] = [
        Color(red: 0.98, green: 0.42, blue: 0.35),
        Color(red: 0.98, green: 0.73, blue: 0.24),
        Color(red: 0.58, green: 0.87, blue: 0.29),
        Color(red: 0.23, green: 0.82, blue: 0.63),
        Color(red: 0.25, green: 0.71, blue: 0.99),
        Color(red: 0.55, green: 0.78, blue: 0.55),
        Color(red: 0.80, green: 0.48, blue: 0.97),
        Color(red: 0.98, green: 0.45, blue: 0.73),
        Color(red: 0.95, green: 0.60, blue: 0.35),
        Color(red: 0.71, green: 0.90, blue: 0.42),
        Color(red: 0.38, green: 0.89, blue: 0.89),
        Color(red: 0.45, green: 0.78, blue: 1.00),
        Color(red: 0.65, green: 0.69, blue: 0.99),
        Color(red: 0.91, green: 0.56, blue: 0.96),
        Color(red: 0.98, green: 0.67, blue: 0.62),
        Color(red: 0.85, green: 0.84, blue: 0.34),
    ]

    var body: some View {
        GeometryReader { geo in
            let gridArea = CGRect(
                x: pianoKeyWidth,
                y: headerHeight,
                width: geo.size.width - pianoKeyWidth,
                height: geo.size.height - headerHeight
            )

            ZStack(alignment: .topLeading) {
                // Background
                Color.black

                // Grid + notes canvas
                Canvas { context, size in
                    drawTimeline(context: &context, rect: CGRect(x: pianoKeyWidth, y: 0, width: gridArea.width, height: headerHeight))
                    drawGrid(context: &context, rect: gridArea)
                    drawNotes(context: &context, rect: gridArea)
                    drawPlayhead(context: &context, rect: gridArea)
                    drawPianoKeys(context: &context, rect: CGRect(x: 0, y: headerHeight, width: pianoKeyWidth, height: gridArea.height))
                }
                .gesture(panGesture(gridArea: gridArea))
                .gesture(zoomGesture())
                .onTapGesture { location in
                    handleTap(at: location, gridArea: gridArea)
                }
            }
        }
        .onAppear {
            centerOnContent()
        }
        .onChange(of: store.pianoRollNotes.count) { _, _ in
            if scrollOffset == .zero { centerOnContent() }
        }
    }

    // MARK: - Drawing: Timeline Header

    private func drawTimeline(context: inout GraphicsContext, rect: CGRect) {
        context.fill(Path(rect), with: .color(Color(white: 0.12)))

        let ppq = Double(store.ticksPerQuarter)
        let startTick = Int(scrollOffset.x)
        let endTick = startTick + Int(rect.width * ticksPerPoint)

        // Draw bar numbers
        let beatsPerBar = 4 // default 4/4
        let ticksPerBar = Int(ppq) * beatsPerBar
        guard ticksPerBar > 0 else { return }

        let firstBar = max(0, startTick / ticksPerBar)
        let lastBar = endTick / ticksPerBar + 1

        for bar in firstBar...lastBar {
            let tick = bar * ticksPerBar
            let x = rect.minX + CGFloat(Double(tick - startTick) / ticksPerPoint)
            guard x >= rect.minX && x <= rect.maxX else { continue }

            // Bar line in header
            var line = Path()
            line.move(to: CGPoint(x: x, y: rect.minY))
            line.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(line, with: .color(.white.opacity(0.3)), lineWidth: 1)

            // Bar number
            let text = Text("\(bar + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            context.draw(text, at: CGPoint(x: x + 4, y: rect.midY), anchor: .leading)
        }
    }

    // MARK: - Drawing: Grid

    private func drawGrid(context: inout GraphicsContext, rect: CGRect) {
        // Background
        context.fill(Path(rect), with: .color(Color(white: 0.08)))

        let ppq = Double(store.ticksPerQuarter)
        let startTick = Int(scrollOffset.x)
        let endTick = startTick + Int(rect.width * ticksPerPoint)

        // Horizontal pitch lines
        let startPitch = Int(scrollOffset.y / pitchHeight)
        let visiblePitches = Int(rect.height / pitchHeight) + 2

        for i in 0..<visiblePitches {
            let pitch = maxPitch - startPitch - i
            guard pitch >= minPitch && pitch <= maxPitch else { continue }

            let y = rect.minY + CGFloat(Double(maxPitch - pitch) * pitchHeight - scrollOffset.y)
            guard y >= rect.minY - pitchHeight && y <= rect.maxY else { continue }

            // Alternate black/white key shading
            let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
            if isBlackKey {
                let rowRect = CGRect(x: rect.minX, y: y, width: rect.width, height: pitchHeight)
                context.fill(Path(rowRect), with: .color(Color.white.opacity(0.03)))
            }

            // C note lines (octave boundaries)
            if pitch % 12 == 0 {
                var line = Path()
                line.move(to: CGPoint(x: rect.minX, y: y))
                line.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(line, with: .color(.white.opacity(0.15)), lineWidth: 1)
            }
        }

        // Vertical beat/bar lines
        let ticksPerBar = Int(ppq) * 4
        let ticksPerBeat = Int(ppq)
        guard ticksPerBeat > 0 else { return }

        // Beat lines
        let firstBeat = max(0, startTick / ticksPerBeat)
        let lastBeat = endTick / ticksPerBeat + 1

        for beat in firstBeat...lastBeat {
            let tick = beat * ticksPerBeat
            let x = rect.minX + CGFloat(Double(tick - startTick) / ticksPerPoint)
            guard x >= rect.minX && x <= rect.maxX else { continue }

            let isBar = ticksPerBar > 0 && (tick % ticksPerBar == 0)
            let opacity: Double = isBar ? 0.2 : 0.08
            let width: CGFloat = isBar ? 1.0 : 0.5

            var line = Path()
            line.move(to: CGPoint(x: x, y: rect.minY))
            line.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(line, with: .color(.white.opacity(opacity)), lineWidth: width)
        }
    }

    // MARK: - Drawing: Notes

    private func drawNotes(context: inout GraphicsContext, rect: CGRect) {
        let startTick = Int(scrollOffset.x)
        let endTick = startTick + Int(rect.width * ticksPerPoint)
        let filter = store.selectedTrackFilter

        for note in store.pianoRollNotes {
            // Track filter
            if !filter.isEmpty && !filter.contains(note.trackIndex) { continue }

            // Visibility culling
            let noteEnd = note.startTick + note.duration
            guard noteEnd > startTick && note.startTick < endTick else { continue }

            let y = rect.minY + CGFloat(Double(maxPitch - note.pitch) * pitchHeight - scrollOffset.y)
            guard y + pitchHeight > rect.minY && y < rect.maxY else { continue }

            // Position
            let x = rect.minX + CGFloat(Double(note.startTick - startTick) / ticksPerPoint)
            let w = CGFloat(Double(note.duration) / ticksPerPoint)
            let noteRect = CGRect(x: x, y: y, width: max(w, 2), height: pitchHeight - 1)

            // Color
            let color = noteColor(for: note)
            let isSelected = store.selectedNoteIDs.contains(note.id)
            let velFactor = 0.4 + 0.6 * (Double(note.velocity) / 127.0)

            let fillColor = isSelected
                ? Color.white.opacity(0.9)
                : color.opacity(note.muted ? 0.2 : velFactor)

            context.fill(Path(roundedRect: noteRect, cornerRadius: 2), with: .color(fillColor))

            // Selection border
            if isSelected {
                context.stroke(
                    Path(roundedRect: noteRect, cornerRadius: 2),
                    with: .color(.white),
                    lineWidth: 1.5
                )
            }

            // Lyric syllable
            if let syllable = note.lyricSyllable, !syllable.isEmpty, w > 20 {
                let text = Text(syllable)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.8))
                context.draw(text, at: CGPoint(x: noteRect.midX, y: noteRect.midY), anchor: .center)
            }
        }
    }

    // MARK: - Drawing: Playhead

    private func drawPlayhead(context: inout GraphicsContext, rect: CGRect) {
        guard store.isPlaying || store.livePlayheadTick > 0 else { return }

        let startTick = Int(scrollOffset.x)
        let x = rect.minX + CGFloat(Double(store.livePlayheadTick - startTick) / ticksPerPoint)
        guard x >= rect.minX && x <= rect.maxX else { return }

        var line = Path()
        line.move(to: CGPoint(x: x, y: rect.minY))
        line.addLine(to: CGPoint(x: x, y: rect.maxY))
        context.stroke(line, with: .color(.white), lineWidth: 1.5)

        // Playhead triangle at top
        var triangle = Path()
        triangle.move(to: CGPoint(x: x - 5, y: rect.minY))
        triangle.addLine(to: CGPoint(x: x + 5, y: rect.minY))
        triangle.addLine(to: CGPoint(x: x, y: rect.minY + 8))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(.white))
    }

    // MARK: - Drawing: Piano Keys

    private func drawPianoKeys(context: inout GraphicsContext, rect: CGRect) {
        context.fill(Path(rect), with: .color(Color(white: 0.14)))

        let startPitch = Int(scrollOffset.y / pitchHeight)
        let visiblePitches = Int(rect.height / pitchHeight) + 2

        for i in 0..<visiblePitches {
            let pitch = maxPitch - startPitch - i
            guard pitch >= minPitch && pitch <= maxPitch else { continue }

            let y = rect.minY + CGFloat(Double(maxPitch - pitch) * pitchHeight - scrollOffset.y)
            guard y + pitchHeight > rect.minY && y < rect.maxY else { continue }

            let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
            let keyRect = CGRect(x: rect.minX, y: y, width: rect.width, height: pitchHeight)

            if isBlackKey {
                context.fill(Path(keyRect), with: .color(Color(white: 0.08)))
            }

            // Key border
            var border = Path()
            border.move(to: CGPoint(x: rect.minX, y: y + pitchHeight))
            border.addLine(to: CGPoint(x: rect.maxX, y: y + pitchHeight))
            context.stroke(border, with: .color(.white.opacity(0.06)), lineWidth: 0.5)

            // C labels
            if pitch % 12 == 0 {
                let octave = pitch / 12 - 1
                let label = Text("C\(octave)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                context.draw(label, at: CGPoint(x: rect.midX, y: y + pitchHeight * 0.5), anchor: .center)
            }
        }

        // Right border
        var rightBorder = Path()
        rightBorder.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        rightBorder.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.stroke(rightBorder, with: .color(.white.opacity(0.2)), lineWidth: 1)
    }

    // MARK: - Gestures

    private func panGesture(gridArea: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if dragStart == nil { dragStart = scrollOffset }
                guard let start = dragStart else { return }
                scrollOffset = CGPoint(
                    x: max(0, start.x - Double(value.translation.width) * ticksPerPoint),
                    y: max(0, start.y - Double(value.translation.height))
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let scale = value.magnification / lastMagnification
                lastMagnification = value.magnification

                // Zoom both axes
                ticksPerPoint = min(maxTicksPerPoint, max(minTicksPerPoint, ticksPerPoint / Double(scale)))
                pitchHeight = min(30, max(4, pitchHeight * Double(scale)))
            }
            .onEnded { _ in
                lastMagnification = 1.0
            }
    }

    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint, gridArea: CGRect) {
        guard gridArea.contains(location) else { return }

        let startTick = Int(scrollOffset.x)
        let tapTick = startTick + Int(Double(location.x - gridArea.minX) * ticksPerPoint)
        let tapPitch = maxPitch - Int((Double(location.y - gridArea.minY) + scrollOffset.y) / pitchHeight)

        // Find note under tap (with tolerance)
        let filter = store.selectedTrackFilter
        if let note = store.pianoRollNotes.first(where: { n in
            if !filter.isEmpty && !filter.contains(n.trackIndex) { return false }
            return n.pitch == tapPitch
                && tapTick >= n.startTick
                && tapTick <= n.startTick + n.duration
        }) {
            store.selectedNoteIDs = [note.id]
        } else {
            store.selectedNoteIDs.removeAll()
        }
    }

    // MARK: - Helpers

    private func noteColor(for note: PianoRollNote) -> Color {
        let pairKey = "(\(note.trackIndex),\(note.channel))"
        let channelKey = store.pianoRollChannelKeyByTrackChannel[pairKey] ?? pairKey

        if let mapping = store.instrumentMappings[channelKey],
           let hex = mapping.colorHex,
           let color = ColorHex.color(from: hex) {
            return color
        }

        return Self.trackPalette[abs(note.trackIndex) % Self.trackPalette.count]
    }

    private func centerOnContent() {
        guard !store.pianoRollNotes.isEmpty else {
            // Default: center on middle C area
            scrollOffset = CGPoint(x: 0, y: Double(maxPitch - 72) * pitchHeight)
            return
        }

        let pitches = store.pianoRollNotes.map(\.pitch)
        let minP = pitches.min() ?? 60
        let maxP = pitches.max() ?? 72
        let midPitch = (minP + maxP) / 2

        let ticks = store.pianoRollNotes.map(\.startTick)
        let minTick = ticks.min() ?? 0

        scrollOffset = CGPoint(
            x: max(0, Double(minTick - 200)),
            y: max(0, Double(maxPitch - midPitch - 10) * pitchHeight)
        )
    }
}
#endif
