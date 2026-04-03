import Foundation

// MARK: - PhraseDetector

/// Detects musical phrase boundaries from MIDI note data using multi-criteria scoring.
///
/// Improves on the simple gap-based detection in `LyricAligner.detectPhraseStarts()`
/// by incorporating pitch jumps, rhythmic pattern changes, and bar-line snapping.
enum PhraseDetector {

    // MARK: - Public API

    /// Detect musical phrases from a sorted array of notes.
    ///
    /// Returns an array of `MusicalPhrase` objects, each containing note IDs,
    /// tick range, melodic contour, and pitch statistics.
    static func detectPhrases(
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int,
        config: PhraseDetectionConfig = .init()
    ) -> [MusicalPhrase] {
        let sorted = notes.sorted { $0.startTick < $1.startTick }
        guard !sorted.isEmpty else { return [] }
        let tpq = max(1, ticksPerQuarter)

        // Find phrase boundaries via multi-criteria scoring.
        var breakIndices: [Int] = [0] // first note always starts a phrase
        for i in 1..<sorted.count {
            let score = breakScore(
                prevNote: sorted[i - 1],
                currentNote: sorted[i],
                noteIndex: i,
                allNotes: sorted,
                ticksPerQuarter: tpq,
                config: config
            )
            if score >= 1.0 {
                breakIndices.append(i)
            }
        }

        // Snap phrase starts to bar lines if configured.
        if config.snapToBarLine {
            snapToBarLines(
                breakIndices: &breakIndices,
                notes: sorted,
                timeSignatures: timeSignatures,
                ticksPerQuarter: tpq
            )
        }

        // Enforce minimum phrase length by merging short phrases into previous.
        enforceMinPhraseLength(
            breakIndices: &breakIndices,
            noteCount: sorted.count,
            minLength: config.minPhraseLengthNotes
        )

        // Build MusicalPhrase objects.
        var phrases: [MusicalPhrase] = []
        for (idx, startIdx) in breakIndices.enumerated() {
            let endIdx = (idx + 1 < breakIndices.count) ? breakIndices[idx + 1] - 1 : sorted.count - 1
            guard endIdx >= startIdx else { continue }

            let phraseNotes = Array(sorted[startIdx...endIdx])
            guard let firstNote = phraseNotes.first, let lastNote = phraseNotes.last else { continue }
            let pitches = phraseNotes.map(\.pitch)
            let noteIDs = phraseNotes.map(\.id)
            let startTick = firstNote.startTick
            let endTick = lastNote.startTick + lastNote.duration

            let contour = MelodicContourAnalyzer.classify(pitches: pitches)
            let mean = pitches.isEmpty ? 60.0 : Double(pitches.reduce(0, +)) / Double(pitches.count)
            let range = (pitches.max() ?? 0) - (pitches.min() ?? 0)

            phrases.append(MusicalPhrase(
                startTick: startTick,
                endTick: endTick,
                noteIDs: noteIDs,
                startNoteIndex: startIdx,
                endNoteIndex: endIdx,
                contour: contour,
                meanPitch: mean,
                pitchRange: range
            ))
        }

        return phrases
    }

    /// Simple phrase start indices (compatible with LyricAligner's Set<Int> format).
    static func detectPhraseStartIndices(
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int,
        config: PhraseDetectionConfig = .init()
    ) -> Set<Int> {
        let phrases = detectPhrases(
            notes: notes,
            tempoEvents: tempoEvents,
            timeSignatures: timeSignatures,
            ticksPerQuarter: ticksPerQuarter,
            config: config
        )
        return Set(phrases.map(\.startNoteIndex))
    }

    // MARK: - Break Score Computation

    /// Compute a phrase break score for the boundary between prevNote and currentNote.
    /// A score >= 1.0 indicates a phrase break should occur.
    private static func breakScore(
        prevNote: PianoRollNote,
        currentNote: PianoRollNote,
        noteIndex: Int,
        allNotes: [PianoRollNote],
        ticksPerQuarter: Int,
        config: PhraseDetectionConfig
    ) -> Double {
        var score = 0.0

        // 1. Gap criterion — primary indicator.
        let prevEnd = prevNote.startTick + prevNote.duration
        let gap = max(0, currentNote.startTick - prevEnd)
        let gapInBeats = Double(gap) / Double(ticksPerQuarter)

        if gapInBeats >= config.gapThresholdBeats {
            // Strong break signal. Scale with gap size.
            score += min(2.0, 0.8 + gapInBeats * 0.4)
        } else if gapInBeats >= config.gapThresholdBeats * 0.5 {
            // Moderate gap — contributes but doesn't guarantee break.
            score += 0.4
        }

        // 2. Pitch jump criterion — large intervals suggest new phrase.
        let pitchInterval = abs(currentNote.pitch - prevNote.pitch)
        if pitchInterval >= config.pitchJumpThreshold {
            score += 0.6
        } else if pitchInterval >= config.pitchJumpThreshold / 2 {
            score += 0.2
        }

        // 3. Rhythmic pattern change — detect shift in note durations.
        if noteIndex >= 2 {
            let rhythmChangeScore = rhythmChangeScore(
                at: noteIndex,
                notes: allNotes,
                ticksPerQuarter: ticksPerQuarter
            )
            score += rhythmChangeScore * config.rhythmChangeWeight
        }

        // 4. Rest emphasis — even a small rest combined with other factors is significant.
        if gap > 0 && score > 0.3 {
            score += 0.2
        }

        return score
    }

    /// Score rhythmic pattern change at a given note index.
    /// Compares the duration ratio of recent notes to detect a shift in rhythm.
    private static func rhythmChangeScore(
        at index: Int,
        notes: [PianoRollNote],
        ticksPerQuarter: Int
    ) -> Double {
        guard index >= 2 && index < notes.count else { return 0 }

        // Look at duration of notes before and after this boundary.
        let prevDuration = notes[index - 1].duration
        let prevPrevDuration = notes[index - 2].duration
        let currDuration = notes[index].duration

        // If the previous two notes had similar durations but this one differs significantly...
        let prevRatio = Double(max(prevDuration, prevPrevDuration)) / Double(max(1, min(prevDuration, prevPrevDuration)))
        let changeRatio = Double(max(currDuration, prevDuration)) / Double(max(1, min(currDuration, prevDuration)))

        // Previous pair was consistent (ratio < 2x) but current changes significantly (ratio > 2x).
        if prevRatio < 2.0 && changeRatio >= 2.0 {
            return min(1.0, (changeRatio - 1.5) * 0.5)
        }

        return 0
    }

    // MARK: - Bar-Line Snapping

    /// Snap phrase boundary indices to the nearest bar line when within 1 beat.
    private static func snapToBarLines(
        breakIndices: inout [Int],
        notes: [PianoRollNote],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int
    ) {
        guard !breakIndices.isEmpty else { return }

        for i in 1..<breakIndices.count {
            let noteIdx = breakIndices[i]
            let noteTick = notes[noteIdx].startTick

            // Find the active time signature at this tick.
            let timeSig = activeTimeSignature(at: noteTick, timeSignatures: timeSignatures)
            let beatsPerBar = timeSig.numerator
            let ticksPerBeat: Int
            switch timeSig.denominator {
            case 8: ticksPerBeat = ticksPerQuarter / 2
            case 2: ticksPerBeat = ticksPerQuarter * 2
            default: ticksPerBeat = ticksPerQuarter
            }
            let ticksPerBar = beatsPerBar * ticksPerBeat

            guard ticksPerBar > 0 else { continue }

            // Find the nearest bar line.
            let barNumber = noteTick / ticksPerBar
            let barLineBefore = barNumber * ticksPerBar
            let barLineAfter = (barNumber + 1) * ticksPerBar

            let distBefore = abs(noteTick - barLineBefore)
            let distAfter = abs(noteTick - barLineAfter)
            let nearestBarLine = distBefore <= distAfter ? barLineBefore : barLineAfter
            let distance = min(distBefore, distAfter)

            // Only snap if within 1 beat of the bar line.
            if distance <= ticksPerBeat {
                // Find the note nearest to the bar line.
                var bestIdx = noteIdx
                var bestDist = abs(notes[noteIdx].startTick - nearestBarLine)
                // Check adjacent notes.
                for delta in [-1, 1] {
                    let candidate = noteIdx + delta
                    if candidate > 0 && candidate < notes.count {
                        let d = abs(notes[candidate].startTick - nearestBarLine)
                        if d < bestDist {
                            bestDist = d
                            bestIdx = candidate
                        }
                    }
                }
                if bestIdx != breakIndices[i] && bestIdx > breakIndices[i - 1] {
                    breakIndices[i] = bestIdx
                }
            }
        }
    }

    // MARK: - Minimum Phrase Length

    /// Merge short phrases (< minLength notes) into the previous phrase.
    private static func enforceMinPhraseLength(
        breakIndices: inout [Int],
        noteCount: Int,
        minLength: Int
    ) {
        guard breakIndices.count > 1 else { return }
        var i = breakIndices.count - 1
        while i > 0 {
            let startIdx = breakIndices[i]
            let endIdx = (i + 1 < breakIndices.count) ? breakIndices[i + 1] : noteCount
            let length = endIdx - startIdx
            if length < minLength {
                breakIndices.remove(at: i)
            }
            i -= 1
        }
    }

    // MARK: - Time Signature Helpers

    /// Find the active time signature at a given tick.
    static func activeTimeSignature(
        at tick: Int,
        timeSignatures: [TimeSignatureEvent]
    ) -> (numerator: Int, denominator: Int) {
        let sorted = timeSignatures.sorted { $0.tick < $1.tick }
        var result = (numerator: 4, denominator: 4) // default 4/4
        for ts in sorted {
            if ts.tick <= tick {
                result = (ts.numerator, ts.denominator)
            } else {
                break
            }
        }
        return result
    }

    /// Compute ticks per bar for a given time signature.
    static func ticksPerBar(
        timeSignature: (numerator: Int, denominator: Int),
        ticksPerQuarter: Int
    ) -> Int {
        let ticksPerBeat: Int
        switch timeSignature.denominator {
        case 8: ticksPerBeat = ticksPerQuarter / 2
        case 2: ticksPerBeat = ticksPerQuarter * 2
        default: ticksPerBeat = ticksPerQuarter
        }
        return timeSignature.numerator * ticksPerBeat
    }
}
