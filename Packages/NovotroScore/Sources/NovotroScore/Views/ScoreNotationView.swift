#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Score Notation View
// Renders a basic grand staff (treble + bass clef) from pianoRollNotes using Canvas.

@available(macOS 26.0, *)
struct ScoreNotationView: View {

    @Bindable var store: ScoreStore

    // View state
    @State private var scrollOffset: CGFloat = 0
    @State private var zoom: CGFloat = 1.0
    @State private var hoveredNoteID: UUID? = nil
    @State private var partFilter: Int? = nil  // nil = all tracks, otherwise trackIndex
    @State private var transposeSemitones: Int = 0  // for transposing instruments (e.g. Bb clarinet = -2)

    // Layout constants
    private let staffLineSpacing: CGFloat = 10
    private let staffTopMargin: CGFloat = 60
    private let trebleBassGap: CGFloat = 80
    private let clefAreaWidth: CGFloat = 60
    private let leftMargin: CGFloat = 20
    private let noteHeadWidth: CGFloat = 10
    private let noteHeadHeight: CGFloat = 8
    private let stemLength: CGFloat = 35

    /// Total height of one staff (5 lines, 4 spaces).
    private var singleStaffHeight: CGFloat { staffLineSpacing * 4 }

    /// Y origin for the top line of the treble staff.
    private var trebleStaffTop: CGFloat { staffTopMargin }

    /// Y origin for the top line of the bass staff.
    private var bassStaffTop: CGFloat { trebleStaffTop + singleStaffHeight + trebleBassGap }

    /// Total height needed for the grand staff area.
    private var grandStaffHeight: CGFloat { bassStaffTop + singleStaffHeight + staffTopMargin }

    private var ticksPerQuarter: Int { store.ticksPerQuarter }
    private var ticksPerBeat: CGFloat { CGFloat(ticksPerQuarter) }
    private var pixelsPerTick: CGFloat { 0.3 * zoom }

    /// Width of one measure in pixels (assuming 4/4 time).
    private var measureWidth: CGFloat { ticksPerBeat * 4 * pixelsPerTick }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Score")
                    .font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    Button(action: { zoom = max(0.25, zoom - 0.25) }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Text("\(Int(zoom * 100))%")
                        .monospacedDigit()
                        .frame(width: 44)
                    Button(action: { zoom = min(4.0, zoom + 0.25) }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Divider().frame(height: 16)

                    // Part filter
                    Picker("Part", selection: $partFilter) {
                        Text("All").tag(nil as Int?)
                        ForEach(availableTrackIndices, id: \.self) { idx in
                            Text(store.pianoRollTrackNames[idx] ?? "Track \(idx)").tag(idx as Int?)
                        }
                    }
                    .frame(width: 100)

                    // Transpose
                    Picker("Transpose", selection: $transposeSemitones) {
                        Text("Concert").tag(0)
                        Text("Bb (-2)").tag(-2)
                        Text("Eb (-9)").tag(-9)
                        Text("F (-7)").tag(-7)
                        Text("A (-3)").tag(-3)
                    }
                    .frame(width: 80)

                    Divider().frame(height: 16)
                    Button(action: { exportPDF() }) {
                        Image(systemName: "arrow.down.doc")
                    }
                    .help("Export as PDF")

                    Button(action: { exportPartPDF() }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Export Parts as separate PDFs")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            // Score canvas
            ScrollView(.horizontal, showsIndicators: true) {
                Canvas { context, size in
                    drawGrandStaff(context: &context, size: size)
                }
                .frame(width: totalContentWidth, height: grandStaffHeight)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var availableTrackIndices: [Int] {
        Set(store.pianoRollNotes.map(\.trackIndex)).sorted()
    }

    /// Notes filtered by part and transposed, clamped to valid MIDI range.
    private var displayNotes: [PianoRollNote] {
        var notes = store.pianoRollNotes
        if let filter = partFilter {
            notes = notes.filter { $0.trackIndex == filter }
        }
        if transposeSemitones != 0 {
            notes = notes.map {
                var n = $0
                n.pitch = max(0, min(127, n.pitch + transposeSemitones))
                return n
            }
        }
        return notes
    }

    private var totalContentWidth: CGFloat {
        let maxTick = displayNotes.map(\.startTick).max() ?? store.pianoRollLengthTicks
        return CGFloat(maxTick + ticksPerQuarter * 4) * pixelsPerTick + clefAreaWidth + leftMargin
    }

    // MARK: - Drawing

    private func drawGrandStaff(context: inout GraphicsContext, size: CGSize, notesOverride: [PianoRollNote]? = nil) {
        let lineColor = Color(nsColor: .labelColor).opacity(0.5)
        let noteColor = Color(nsColor: .labelColor)

        // Draw staff lines
        drawStaffLines(context: &context, topY: trebleStaffTop, width: size.width, color: lineColor)
        drawStaffLines(context: &context, topY: bassStaffTop, width: size.width, color: lineColor)

        // Draw clef symbols
        let clefX = leftMargin + 5
        context.draw(
            Text("\u{1D11E}").font(.system(size: 42)),
            at: CGPoint(x: clefX + 14, y: trebleStaffTop + singleStaffHeight * 0.65)
        )
        context.draw(
            Text("\u{1D122}").font(.system(size: 38)),
            at: CGPoint(x: clefX + 14, y: bassStaffTop + singleStaffHeight * 0.4)
        )

        // Draw time signature from first event (or default 4/4)
        let firstTimeSig = store.pianoRollTimeSignatures.first
            ?? TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)
        let tsX = leftMargin + 42
        let tsFont = Font.system(size: 20, weight: .bold, design: .serif)
        context.draw(
            Text("\(firstTimeSig.numerator)").font(tsFont),
            at: CGPoint(x: tsX, y: trebleStaffTop + singleStaffHeight * 0.25)
        )
        context.draw(
            Text("\(firstTimeSig.denominator)").font(tsFont),
            at: CGPoint(x: tsX, y: trebleStaffTop + singleStaffHeight * 0.75)
        )
        context.draw(
            Text("\(firstTimeSig.numerator)").font(tsFont),
            at: CGPoint(x: tsX, y: bassStaffTop + singleStaffHeight * 0.25)
        )
        context.draw(
            Text("\(firstTimeSig.denominator)").font(tsFont),
            at: CGPoint(x: tsX, y: bassStaffTop + singleStaffHeight * 0.75)
        )

        // Draw key signature
        if let keySig = store.pianoRollKeySignatures.first {
            drawKeySignature(context: &context, sharpsFlats: keySig.sharpsFlats, startX: tsX + 18)
        }

        // Draw bar lines (time-signature-aware)
        let totalTicks = store.pianoRollLengthTicks
        let timeSigs = store.pianoRollTimeSignatures.sorted(by: { $0.tick < $1.tick })
        var barTick = 0
        var measureNum = 1
        while barTick <= totalTicks {
            let x = tickToX(barTick)
            let barPath = Path { p in
                p.move(to: CGPoint(x: x, y: trebleStaffTop))
                p.addLine(to: CGPoint(x: x, y: trebleStaffTop + singleStaffHeight))
            }
            context.stroke(barPath, with: .color(lineColor), lineWidth: 1)

            let bassBarPath = Path { p in
                p.move(to: CGPoint(x: x, y: bassStaffTop))
                p.addLine(to: CGPoint(x: x, y: bassStaffTop + singleStaffHeight))
            }
            context.stroke(bassBarPath, with: .color(lineColor), lineWidth: 1)

            // Measure number (skip at tick 0, which is the opening barline)
            if barTick > 0 {
                context.draw(
                    Text("\(measureNum)").font(.system(size: 9)).foregroundColor(.secondary),
                    at: CGPoint(x: x + 4, y: trebleStaffTop - 10),
                    anchor: .leading
                )
            }

            // Compute ticks-per-measure from the active time signature at this bar
            let activeSig = timeSigs.last(where: { $0.tick <= barTick })
                ?? TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)
            let beatsInMeasure = activeSig.numerator
            let beatUnit = activeSig.denominator
            let ticksPerMeasure = ticksPerQuarter * 4 * beatsInMeasure / beatUnit

            barTick += ticksPerMeasure
            measureNum += 1
        }

        // Draw brace connecting treble and bass staves
        let braceX = leftMargin
        let bracePath = Path { p in
            p.move(to: CGPoint(x: braceX, y: trebleStaffTop))
            p.addLine(to: CGPoint(x: braceX, y: bassStaffTop + singleStaffHeight))
        }
        context.stroke(bracePath, with: .color(lineColor), lineWidth: 2)

        // Draw part name in left margin (if a part filter is active)
        if let filterIdx = partFilter,
           let trackName = store.pianoRollTrackNames[filterIdx] {
            context.draw(
                Text(trackName)
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(Color.secondary),
                at: CGPoint(x: leftMargin - 2, y: (trebleStaffTop + bassStaffTop + singleStaffHeight) / 2),
                anchor: .trailing
            )
        }

        // Draw notes
        drawNotes(context: &context, noteColor: noteColor, notesOverride: notesOverride)

        // Draw score annotations (dynamics, tempo, expression text)
        drawAnnotations(context: &context)
    }

    private func drawAnnotations(context: inout GraphicsContext) {
        for annotation in store.scoreAnnotations {
            // Skip if filtered to a specific track and annotation doesn't match
            if let filterIdx = partFilter, let annTrack = annotation.trackIndex, annTrack != filterIdx {
                continue
            }

            let x = tickToX(annotation.tick)
            let style = annotation.kind.displayFont

            // Position: dynamics below bass staff, tempo above treble, expression below treble
            let y: CGFloat
            switch annotation.kind {
            case .dynamic:
                y = bassStaffTop + singleStaffHeight + 18
            case .tempo:
                y = trebleStaffTop - 22
            case .expression:
                y = trebleStaffTop + singleStaffHeight + 8
            case .rehearsal:
                y = trebleStaffTop - 28
            }

            var font = Font.system(size: style.size, design: .serif)
            if style.bold { font = font.bold() }
            if style.italic { font = font.italic() }

            let color: Color = annotation.kind == .dynamic ? .blue : .primary
            context.draw(
                Text(annotation.text).font(font).foregroundStyle(color),
                at: CGPoint(x: x, y: y),
                anchor: .leading
            )
        }
    }

    private func drawStaffLines(context: inout GraphicsContext, topY: CGFloat, width: CGFloat, color: Color) {
        for i in 0..<5 {
            let y = topY + CGFloat(i) * staffLineSpacing
            let path = Path { p in
                p.move(to: CGPoint(x: leftMargin, y: y))
                p.addLine(to: CGPoint(x: width, y: y))
            }
            context.stroke(path, with: .color(color), lineWidth: 0.8)
        }
    }

    private func drawNotes(context: inout GraphicsContext, noteColor: Color, notesOverride: [PianoRollNote]? = nil) {
        // Group notes by start tick for potential beaming
        let sortedNotes = (notesOverride ?? displayNotes).sorted { $0.startTick < $1.startTick }

        for note in sortedNotes {
            let x = tickToX(note.startTick)
            let staffPosition = pitchToStaffPosition(note.pitch)

            guard let placement = staffPosition else { continue }

            let y = placement.y
            let isTreble = placement.isTreble

            // Draw ledger lines if needed
            drawLedgerLines(context: &context, x: x, pitch: note.pitch, isTreble: isTreble, noteColor: noteColor)

            // Note head (filled oval)
            let headRect = CGRect(
                x: x - noteHeadWidth / 2,
                y: y - noteHeadHeight / 2,
                width: noteHeadWidth,
                height: noteHeadHeight
            )
            let headPath = Path(ellipseIn: headRect)

            let isBright = note.velocity > 90
            let fillColor = isBright ? noteColor : noteColor.opacity(0.7)
            context.fill(headPath, with: .color(fillColor))

            // Stem
            let stemUp = y > (isTreble ? trebleStaffTop + singleStaffHeight / 2 : bassStaffTop + singleStaffHeight / 2)
            let stemStartY = stemUp ? y - noteHeadHeight / 2 : y + noteHeadHeight / 2
            let stemEndY = stemUp ? stemStartY - stemLength : stemStartY + stemLength
            let stemX = stemUp ? x + noteHeadWidth / 2 - 0.5 : x - noteHeadWidth / 2 + 0.5

            let stemPath = Path { p in
                p.move(to: CGPoint(x: stemX, y: stemStartY))
                p.addLine(to: CGPoint(x: stemX, y: stemEndY))
            }
            context.stroke(stemPath, with: .color(noteColor), lineWidth: 1.2)

            // Flag for eighth notes and shorter
            let durationBeats = Double(note.duration) / Double(ticksPerQuarter)
            if durationBeats <= 0.5 {
                let flagDir: CGFloat = stemUp ? 1 : -1
                let flagPath = Path { p in
                    p.move(to: CGPoint(x: stemX, y: stemEndY))
                    p.addQuadCurve(
                        to: CGPoint(x: stemX + 8, y: stemEndY + flagDir * 15),
                        control: CGPoint(x: stemX + 10, y: stemEndY + flagDir * 5)
                    )
                }
                context.stroke(flagPath, with: .color(noteColor), lineWidth: 1.2)
            }

            // Accidental display (sharp/flat) — simplified: show # for black keys
            let pitchClass = note.pitch % 12
            let isBlackKey = [1, 3, 6, 8, 10].contains(pitchClass)
            if isBlackKey {
                let accX = x - noteHeadWidth / 2 - 10
                context.draw(
                    Text(pitchClass == 1 || pitchClass == 6 || pitchClass == 8 ? "#" : "b")
                        .font(.system(size: 12, weight: .medium, design: .serif)),
                    at: CGPoint(x: accX, y: y)
                )
            }

            // Lyric syllable below the staff containing the note
            if let lyric = note.lyricSyllable, !lyric.isEmpty {
                let lyricY = placement.isTreble
                    ? trebleStaffTop + singleStaffHeight + 16
                    : bassStaffTop + singleStaffHeight + 16
                context.draw(
                    Text(lyric)
                        .font(.system(size: 9, weight: .regular, design: .serif))
                        .foregroundStyle(Color.primary),
                    at: CGPoint(x: x, y: lyricY),
                    anchor: .top
                )
            }
        }
    }

    private func drawLedgerLines(context: inout GraphicsContext, x: CGFloat, pitch: Int, isTreble: Bool, noteColor: Color) {
        let lineWidth: CGFloat = noteHeadWidth + 6
        let color = noteColor.opacity(0.4)

        if isTreble {
            // Middle C (60) is one ledger line below treble staff
            // Ledger lines below: for pitches at or below B3 (59) = middle C line and below
            if pitch == 60 {
                // Middle C ledger line
                let y = trebleStaffTop + singleStaffHeight + staffLineSpacing
                let path = Path { p in
                    p.move(to: CGPoint(x: x - lineWidth / 2, y: y))
                    p.addLine(to: CGPoint(x: x + lineWidth / 2, y: y))
                }
                context.stroke(path, with: .color(color), lineWidth: 0.8)
            }
            // Ledger lines above: for pitches above A5 (81)
            if pitch >= 82 {
                let stepsAbove = (pitch - 81) / 2
                for i in 0...stepsAbove {
                    let y = trebleStaffTop - CGFloat(i + 1) * staffLineSpacing
                    let path = Path { p in
                        p.move(to: CGPoint(x: x - lineWidth / 2, y: y))
                        p.addLine(to: CGPoint(x: x + lineWidth / 2, y: y))
                    }
                    context.stroke(path, with: .color(color), lineWidth: 0.8)
                }
            }
        } else {
            // Bass clef ledger lines above (middle C)
            if pitch >= 60 {
                let y = bassStaffTop - staffLineSpacing
                let path = Path { p in
                    p.move(to: CGPoint(x: x - lineWidth / 2, y: y))
                    p.addLine(to: CGPoint(x: x + lineWidth / 2, y: y))
                }
                context.stroke(path, with: .color(color), lineWidth: 0.8)
            }
            // Ledger lines below: for pitches below G1 (31)
            if pitch <= 30 {
                let stepsBelow = (31 - pitch) / 2
                for i in 0...stepsBelow {
                    let y = bassStaffTop + singleStaffHeight + CGFloat(i + 1) * staffLineSpacing
                    let path = Path { p in
                        p.move(to: CGPoint(x: x - lineWidth / 2, y: y))
                        p.addLine(to: CGPoint(x: x + lineWidth / 2, y: y))
                    }
                    context.stroke(path, with: .color(color), lineWidth: 0.8)
                }
            }
        }
    }

    // MARK: - Coordinate Mapping

    private func tickToX(_ tick: Int) -> CGFloat {
        clefAreaWidth + leftMargin + CGFloat(tick) * pixelsPerTick
    }

    /// Maps a MIDI pitch to a Y position on the grand staff.
    /// Returns nil for pitches outside renderable range.
    ///
    /// Treble clef: E4 (64) on bottom line to F5 (77) on top line
    /// Bass clef: G2 (43) on bottom line to A3 (57) on top line
    /// Middle C (60) sits between the two staves on a ledger line.
    private func pitchToStaffPosition(_ pitch: Int) -> (y: CGFloat, isTreble: Bool)? {
        // Use treble clef for pitch >= 60 (middle C and above)
        // Use bass clef for pitch < 60
        let isTreble = pitch >= 60

        if isTreble {
            // Treble staff: bottom line (E4=64) maps to trebleStaffTop + 4*spacing
            // Each semitone-to-staff-step uses diatonic mapping
            let staffY = trebleStaffTop + singleStaffHeight - diatonicStepsFromE4(pitch) * (staffLineSpacing / 2)
            return (staffY, true)
        } else {
            // Bass staff: bottom line (G2=43) maps to bassStaffTop + 4*spacing
            let staffY = bassStaffTop + singleStaffHeight - diatonicStepsFromG2(pitch) * (staffLineSpacing / 2)
            return (staffY, false)
        }
    }

    /// Returns the number of diatonic staff steps above E4 (MIDI 64).
    private func diatonicStepsFromE4(_ pitch: Int) -> CGFloat {
        // E4=64. Map pitch to (octave, noteIndex), then count diatonic steps.
        let e4Steps = diatonicPosition(64)
        let noteSteps = diatonicPosition(pitch)
        return CGFloat(noteSteps - e4Steps)
    }

    /// Returns the number of diatonic staff steps above G2 (MIDI 43).
    private func diatonicStepsFromG2(_ pitch: Int) -> CGFloat {
        let g2Steps = diatonicPosition(43)
        let noteSteps = diatonicPosition(pitch)
        return CGFloat(noteSteps - g2Steps)
    }

    /// Converts a MIDI pitch to an absolute diatonic position (C=0,D=1,E=2,F=3,G=4,A=5,B=6 per octave).
    private func diatonicPosition(_ pitch: Int) -> Int {
        let octave = pitch / 12
        let pitchClass = pitch % 12
        // C=0, C#=0, D=1, D#=1, E=2, F=3, F#=3, G=4, G#=4, A=5, A#=5, B=6
        let chromaticToDiatonic = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        return octave * 7 + chromaticToDiatonic[pitchClass]
    }

    // MARK: - Key Signature Drawing

    /// Draws sharps or flats for the key signature on both staves.
    /// sharpsFlats > 0 = sharps, < 0 = flats.
    private func drawKeySignature(context: inout GraphicsContext, sharpsFlats: Int, startX: CGFloat) {
        guard sharpsFlats != 0 else { return }

        // Staff line positions for sharps (treble): F5, C5, G5, D5, A4, E5, B4
        let sharpTrebleSteps: [CGFloat] = [8, 5, 9, 6, 3, 7, 4]  // steps above E4
        let sharpBassSteps: [CGFloat]   = [6, 3, 7, 4, 1, 5, 2]  // steps above G2

        // Staff line positions for flats (treble): B4, E5, A4, D5, G4, C5, F4
        let flatTrebleSteps: [CGFloat]  = [4, 7, 3, 6, 2, 5, 1]
        let flatBassSteps: [CGFloat]    = [2, 5, 1, 4, 0, 3, -1]

        let count = abs(sharpsFlats)
        let isSharp = sharpsFlats > 0
        let symbol = isSharp ? "\u{266F}" : "\u{266D}"  // ♯ or ♭
        let trebleSteps = isSharp ? sharpTrebleSteps : flatTrebleSteps
        let bassSteps = isSharp ? sharpBassSteps : flatBassSteps

        for i in 0..<min(count, 7) {
            let x = startX + CGFloat(i) * 12

            // Treble staff
            let trebleY = trebleStaffTop + singleStaffHeight - trebleSteps[i] * (staffLineSpacing / 2)
            context.draw(
                Text(symbol).font(.system(size: 14, weight: .bold)),
                at: CGPoint(x: x, y: trebleY)
            )

            // Bass staff
            let bassY = bassStaffTop + singleStaffHeight - bassSteps[i] * (staffLineSpacing / 2)
            context.draw(
                Text(symbol).font(.system(size: 14, weight: .bold)),
                at: CGPoint(x: x, y: bassY)
            )
        }
    }

    // MARK: - PDF Export

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.title = "Export Score as PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(store.metadata.name).pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let contentW = totalContentWidth
            let staffH = grandStaffHeight

            // Page layout: US Letter landscape
            let pageW: CGFloat = 792
            let pageH: CGFloat = 612
            let margin: CGFloat = 36
            let usableW = pageW - margin * 2
            let headerH: CGFloat = 30

            // Calculate how many content-pixels fit per page
            let contentPerPage = usableW
            let totalPages = max(1, Int(ceil(contentW / contentPerPage)))

            let pdfData = NSMutableData()
            var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

            for page in 0..<totalPages {
                ctx.beginPDFPage(nil)

                // White background
                ctx.setFillColor(CGColor.white)
                ctx.fill(CGRect(x: 0, y: 0, width: pageW, height: pageH))

                // Header: title and page number
                let title = "\(self.store.metadata.name) — Page \(page + 1) of \(totalPages)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.darkGray
                ]
                let attrStr = NSAttributedString(string: title, attributes: attrs)
                let line = CTLineCreateWithAttributedString(attrStr)
                ctx.textPosition = CGPoint(x: margin, y: pageH - margin + 5)
                CTLineDraw(line, ctx)

                // Render the staff section for this page
                let xOffset = CGFloat(page) * contentPerPage
                let scale = min(1.0, (pageH - margin * 2 - headerH) / staffH)

                ctx.saveGState()
                ctx.translateBy(x: margin, y: margin)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -xOffset, y: 0)

                // Clip to prevent drawing outside page bounds
                let clipRect = CGRect(x: xOffset, y: 0, width: contentPerPage / scale, height: staffH)
                ctx.clip(to: clipRect)

                // Render using ImageRenderer for this slice
                let sliceRenderer = ImageRenderer(content:
                    Canvas { context, size in
                        self.drawGrandStaff(context: &context, size: size)
                    }
                    .frame(width: contentW, height: staffH)
                    .background(.white)
                )
                sliceRenderer.scale = 2.0
                if let img = sliceRenderer.cgImage {
                    // CGImage draws with first row at bottom in CG PDF coordinates (Y-up),
                    // but ImageRenderer produces top-down images — flip Y to correct orientation.
                    ctx.translateBy(x: 0, y: staffH * scale)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: contentW, height: staffH))
                }

                ctx.restoreGState()
                ctx.endPDFPage()
            }

            ctx.closePDF()
            do {
                try pdfData.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.store.statusMessage = "Failed to export PDF: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Part Extraction Export

    private func exportPartPDF() {
        let panel = NSOpenPanel()
        panel.title = "Choose folder for part PDFs"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dir = panel.url else { return }
            let trackIndices = self.availableTrackIndices
            for idx in trackIndices {
                let name = self.store.pianoRollTrackNames[idx] ?? "Track \(idx)"
                // Look up instrument-specific transposition (e.g., Bb Clarinet = -2, F Horn = -7)
                let instrumentTranspose = self.instrumentTransposition(forTrackIndex: idx)
                let effectiveTranspose = instrumentTranspose != 0 ? instrumentTranspose : self.transposeSemitones
                let safeName = name.replacingOccurrences(of: "/", with: "-")
                let url = dir.appendingPathComponent("\(safeName).pdf")
                self.exportPDFTo(url: url, forPartFilter: idx, transpose: effectiveTranspose)
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
        }
    }

    /// Look up the transposition interval for a track's instrument (from InstrumentRangeDatabase).
    private func instrumentTransposition(forTrackIndex trackIndex: Int) -> Int {
        let trackName = store.pianoRollTrackNames[trackIndex] ?? ""
        // Try exact match, then fuzzy match by checking if the track name contains the instrument name
        if let profile = InstrumentRangeDatabase.profile(for: trackName) {
            return profile.transposition
        }
        // Fuzzy: check if any profile name is contained in the track name
        for profile in InstrumentRangeDatabase.allProfiles {
            if trackName.localizedCaseInsensitiveContains(profile.name) {
                return profile.transposition
            }
        }
        return 0
    }

    /// Get notes for a specific part filter + transpose, without mutating @State.
    private func notesForExport(partFilter: Int?, transpose: Int) -> [PianoRollNote] {
        var notes = store.pianoRollNotes
        if let filter = partFilter {
            notes = notes.filter { $0.trackIndex == filter }
        }
        if transpose != 0 {
            notes = notes.map {
                var n = $0
                n.pitch = max(0, min(127, n.pitch + transpose))
                return n
            }
        }
        return notes
    }

    private func exportPDFTo(url: URL, forPartFilter overridePartFilter: Int? = nil, transpose: Int = 0) {
        let contentW = totalContentWidth
        let staffH = grandStaffHeight
        let pageW: CGFloat = 792
        let pageH: CGFloat = 612
        let margin: CGFloat = 36
        let usableW = pageW - margin * 2
        let contentPerPage = usableW
        let totalPages = max(1, Int(ceil(contentW / contentPerPage)))

        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

        for page in 0..<totalPages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(x: 0, y: 0, width: pageW, height: pageH))

            let effectiveFilter = overridePartFilter ?? partFilter
            let effectiveTranspose = transpose != 0 ? transpose : transposeSemitones
            let exportNotes = notesForExport(partFilter: effectiveFilter, transpose: effectiveTranspose)
            let partName = effectiveFilter.flatMap { store.pianoRollTrackNames[$0] } ?? store.metadata.name
            let title = "\(partName) — Page \(page + 1)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.darkGray
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attrs))
            ctx.textPosition = CGPoint(x: margin, y: pageH - margin + 5)
            CTLineDraw(line, ctx)

            let xOffset = CGFloat(page) * contentPerPage
            let headerH: CGFloat = 30
            let scale = min(1.0, (pageH - margin * 2 - headerH) / staffH)

            ctx.saveGState()
            ctx.translateBy(x: margin, y: margin)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -xOffset, y: 0)
            let clipRect = CGRect(x: xOffset, y: 0, width: contentPerPage / scale, height: staffH)
            ctx.clip(to: clipRect)

            let sliceRenderer = ImageRenderer(content:
                Canvas { context, size in
                    self.drawGrandStaff(context: &context, size: size, notesOverride: exportNotes)
                }
                .frame(width: contentW, height: staffH)
                .background(.white)
            )
            sliceRenderer.scale = 2.0
            if let img = sliceRenderer.cgImage {
                // CGImage draws with first row at bottom in CG PDF coordinates (Y-up),
                // but ImageRenderer produces top-down images — flip Y to correct orientation.
                ctx.translateBy(x: 0, y: staffH * scale)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: contentW, height: staffH))
            }

            ctx.restoreGState()
            ctx.endPDFPage()
        }

        ctx.closePDF()
        do {
            try pdfData.write(to: url, options: .atomic)
        } catch {
            DispatchQueue.main.async {
                self.store.statusMessage = "Failed to export part PDF: \(error.localizedDescription)"
            }
        }
    }
}
#endif
