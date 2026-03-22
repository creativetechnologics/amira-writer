import Foundation

// MARK: - CompositionEngine

/// Algorithmic melody generation, motif transformation, and phrase continuation.
///
/// All methods are pure functions that return new note arrays. The caller
/// (`ProjectStore`) manages preview state and acceptance into the piano roll.
enum CompositionEngine {

    // MARK: - Melody Generation

    /// Generate a melody from constraints using a scale-tone random walk.
    ///
    /// The algorithm starts at a scale tone near the midpoint of the pitch range,
    /// then walks through scale tones with contour-biased interval selection.
    /// Each note gets a duration derived from `noteDensity` with ±25% variation.
    static func generateMelody(constraints: MelodyConstraints) -> [PianoRollNote] {
        let tpq = max(1, constraints.ticksPerQuarter)
        let scalePCs = Array(constraints.key.scalePitchClasses).sorted()
        guard !scalePCs.isEmpty else { return [] }

        // Build scale tones within pitch range
        var scaleTones: [Int] = []
        for pitch in constraints.pitchRange {
            if scalePCs.contains(pitch % 12) {
                scaleTones.append(pitch)
            }
        }
        guard !scaleTones.isEmpty else { return [] }

        var rng = SystemRandomNumberGenerator()

        // Start near the midpoint
        let midPitch = (constraints.pitchRange.lowerBound + constraints.pitchRange.upperBound) / 2
        var currentIndex = scaleTones.enumerated()
            .min(by: { abs($0.element - midPitch) < abs($1.element - midPitch) })!.offset

        let totalTicks = Int(constraints.durationBeats * Double(tpq))
        let baseDuration = max(1, Int(Double(tpq) / max(0.5, constraints.noteDensity)))

        var notes: [PianoRollNote] = []
        var tick = constraints.startTick

        while tick < constraints.startTick + totalTicks {
            let pitch = scaleTones[currentIndex]

            // Duration with ±25% variation
            let variation = Double.random(in: 0.75...1.25, using: &rng)
            let duration = max(1, Int(Double(baseDuration) * variation))

            notes.append(PianoRollNote(
                trackIndex: constraints.trackIndex,
                channel: constraints.channel,
                pitch: pitch,
                velocity: constraints.velocity,
                startTick: tick,
                duration: min(duration, constraints.startTick + totalTicks - tick)
            ))

            tick += duration

            // Step through scale with contour bias
            let step = contourBiasedStep(
                contour: constraints.contour,
                progress: Double(tick - constraints.startTick) / Double(max(1, totalTicks)),
                rng: &rng
            )

            currentIndex = max(0, min(scaleTones.count - 1, currentIndex + step))
        }

        return notes
    }

    /// Compute a contour-biased step size for scale-tone walking.
    private static func contourBiasedStep(
        contour: MelodicContour,
        progress: Double,
        rng: inout SystemRandomNumberGenerator
    ) -> Int {
        // Base random step: -2 to +2 scale degrees
        let baseStep = Int.random(in: -2...2, using: &rng)

        let bias: Int
        switch contour {
        case .ascending:
            bias = 1
        case .descending:
            bias = -1
        case .arch:
            // Rise in first half, fall in second
            bias = progress < 0.5 ? 1 : -1
        case .invertedArch:
            // Fall in first half, rise in second
            bias = progress < 0.5 ? -1 : 1
        case .constant:
            bias = 0
        case .mixed:
            bias = 0
        }

        // Combine base step with bias — bias shifts the distribution
        let combined = baseStep + bias
        return max(-3, min(3, combined))
    }

    // MARK: - Motif Transformation

    /// Transform a motif using standard variation techniques.
    ///
    /// - Parameters:
    ///   - notes: Input notes (will be sorted by startTick).
    ///   - type: Variation type to apply.
    ///   - semitones: Transposition amount (only used for `.transposition`).
    ///   - ticksPerQuarter: Ticks per quarter note (used for duration scaling).
    /// - Returns: Transformed notes with new UUIDs.
    static func transformMotif(
        notes: [PianoRollNote],
        type: VariationType,
        semitones: Int = 0,
        ticksPerQuarter: Int
    ) -> [PianoRollNote] {
        guard !notes.isEmpty else { return [] }
        let sorted = notes.sorted { $0.startTick < $1.startTick }

        switch type {
        case .inversion:
            return invertMotif(sorted)
        case .retrograde:
            return retrogradeMotif(sorted)
        case .augmentation:
            return scaleMotifDuration(sorted, factor: 2.0)
        case .diminution:
            return scaleMotifDuration(sorted, factor: 0.5)
        case .transposition:
            return transposeMotif(sorted, semitones: semitones)
        }
    }

    /// Mirror pitches around the mean pitch (inversion).
    private static func invertMotif(_ sorted: [PianoRollNote]) -> [PianoRollNote] {
        guard !sorted.isEmpty else { return [] }
        let meanPitch = Double(sorted.map(\.pitch).reduce(0, +)) / Double(sorted.count)

        return sorted.map { note in
            let invertedPitch = Int(round(2.0 * meanPitch - Double(note.pitch)))
            return PianoRollNote(
                trackIndex: note.trackIndex,
                channel: note.channel,
                pitch: max(0, min(127, invertedPitch)),
                velocity: note.velocity,
                startTick: note.startTick,
                duration: note.duration
            )
        }
    }

    /// Reverse the note order while preserving timing structure (retrograde).
    private static func retrogradeMotif(_ sorted: [PianoRollNote]) -> [PianoRollNote] {
        guard sorted.count > 1 else {
            return sorted.map { note in
                PianoRollNote(
                    trackIndex: note.trackIndex,
                    channel: note.channel,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    startTick: note.startTick,
                    duration: note.duration
                )
            }
        }

        guard let first = sorted.first else { return [] }
        let baseStartTick = first.startTick

        // Compute inter-onset intervals (gaps between start ticks)
        var onsetIntervals: [Int] = []
        for i in 1..<sorted.count {
            onsetIntervals.append(sorted[i].startTick - sorted[i - 1].startTick)
        }

        // Reverse: the pitches + durations go backwards, onset intervals stay forward
        let reversedNotes = sorted.reversed().map { $0 }

        var result: [PianoRollNote] = []
        var tick = baseStartTick

        for (i, note) in reversedNotes.enumerated() {
            result.append(PianoRollNote(
                trackIndex: note.trackIndex,
                channel: note.channel,
                pitch: note.pitch,
                velocity: note.velocity,
                startTick: tick,
                duration: note.duration
            ))
            if i < onsetIntervals.count {
                tick += onsetIntervals[i]
            }
        }

        return result
    }

    /// Scale all durations and inter-note gaps by a factor (augmentation/diminution).
    private static func scaleMotifDuration(_ sorted: [PianoRollNote], factor: Double) -> [PianoRollNote] {
        guard let first = sorted.first else { return [] }
        let baseStartTick = first.startTick

        return sorted.enumerated().map { (i, note) in
            let offsetFromStart = note.startTick - baseStartTick
            let newOffset = Int(Double(offsetFromStart) * factor)
            let newDuration = max(1, Int(Double(note.duration) * factor))

            return PianoRollNote(
                trackIndex: note.trackIndex,
                channel: note.channel,
                pitch: note.pitch,
                velocity: note.velocity,
                startTick: baseStartTick + newOffset,
                duration: newDuration
            )
        }
    }

    /// Transpose all pitches by a semitone offset.
    private static func transposeMotif(_ sorted: [PianoRollNote], semitones: Int) -> [PianoRollNote] {
        sorted.map { note in
            PianoRollNote(
                trackIndex: note.trackIndex,
                channel: note.channel,
                pitch: max(0, min(127, note.pitch + semitones)),
                velocity: note.velocity,
                startTick: note.startTick,
                duration: note.duration
            )
        }
    }

    // MARK: - Phrase Continuation

    /// Continue a phrase by extending its interval and rhythm patterns.
    ///
    /// Analyzes the last 4–8 notes to extract interval and duration patterns,
    /// then cycles through them to generate new notes for the specified duration.
    /// Generated pitches are snapped to the key's diatonic scale.
    static func continuePhrase(
        existingNotes: [PianoRollNote],
        additionalBeats: Double,
        key: DetectedKey,
        ticksPerQuarter: Int
    ) -> [PianoRollNote] {
        let tpq = max(1, ticksPerQuarter)
        guard existingNotes.count >= 2 else { return [] }

        let sorted = existingNotes.sorted { $0.startTick < $1.startTick }
        let window = Array(sorted.suffix(min(8, sorted.count)))

        // Extract interval pattern from the window
        var intervalPattern: [Int] = []
        for i in 1..<window.count {
            intervalPattern.append(window[i].pitch - window[i - 1].pitch)
        }
        guard !intervalPattern.isEmpty else { return [] }

        // Extract duration pattern
        let durationPattern = window.map(\.duration)

        // Extract inter-onset pattern
        var onsetPattern: [Int] = []
        for i in 1..<window.count {
            onsetPattern.append(max(1, window[i].startTick - window[i - 1].startTick))
        }

        guard let lastNote = window.last else { return [] }
        let scalePCs = key.scalePitchClasses

        let totalTicks = Int(additionalBeats * Double(tpq))
        var notes: [PianoRollNote] = []
        var currentPitch = lastNote.pitch
        var tick = lastNote.startTick + lastNote.duration
        let endTick = tick + totalTicks
        var patternIdx = 0

        while tick < endTick {
            // Apply next interval from pattern
            let interval = intervalPattern[patternIdx % intervalPattern.count]
            var nextPitch = currentPitch + interval

            // Snap to nearest scale tone
            nextPitch = snapToScale(pitch: nextPitch, scalePitchClasses: scalePCs)
            nextPitch = max(0, min(127, nextPitch))

            let duration = durationPattern[patternIdx % durationPattern.count]
            let onset = onsetPattern.isEmpty ? duration : onsetPattern[patternIdx % onsetPattern.count]

            notes.append(PianoRollNote(
                trackIndex: lastNote.trackIndex,
                channel: lastNote.channel,
                pitch: nextPitch,
                velocity: lastNote.velocity,
                startTick: tick,
                duration: min(duration, endTick - tick)
            ))

            currentPitch = nextPitch
            tick += onset
            patternIdx += 1
        }

        return notes
    }

    /// Snap a pitch to the nearest tone in the given scale.
    private static func snapToScale(pitch: Int, scalePitchClasses: Set<Int>) -> Int {
        guard !scalePitchClasses.contains(pitch % 12) else { return pitch }

        // Search up and down for nearest scale tone
        for offset in 1...6 {
            if scalePitchClasses.contains((pitch + offset) % 12) {
                return pitch + offset
            }
            if scalePitchClasses.contains(((pitch - offset) % 12 + 12) % 12) {
                return pitch - offset
            }
        }
        return pitch
    }
}
