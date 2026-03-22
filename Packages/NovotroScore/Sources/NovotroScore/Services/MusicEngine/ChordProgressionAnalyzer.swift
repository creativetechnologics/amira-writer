import Foundation

// MARK: - ChordProgressionAnalyzer

/// Analyzes chord progressions from piano roll note data by quantizing notes
/// to beat boundaries, grouping simultaneous notes, classifying chords, and
/// identifying common harmonic patterns.
///
/// Builds on the existing `ChordDetector` (in PianoRollToolbarView) for
/// individual chord classification, extending it to sequential analysis.
enum ChordProgressionAnalyzer {

    // MARK: - Public API

    /// Analyze chord progression from piano roll notes.
    ///
    /// - Parameters:
    ///   - notes: All notes to analyze (can be multi-track).
    ///   - tempoEvents: Tempo map for beat quantization.
    ///   - timeSignatures: Time signatures for bar/beat grid.
    ///   - ticksPerQuarter: MIDI resolution.
    ///   - key: Optional detected key for Roman numeral analysis.
    ///   - quantizeBasis: How many ticks to quantize chord boundaries to.
    ///     Defaults to `ticksPerQuarter` (1 beat). Use `ticksPerQuarter/2` for half-beat resolution.
    /// - Returns: Chord progression analysis with detected chords and patterns.
    static func analyze(
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint] = [],
        timeSignatures: [TimeSignatureEvent] = [],
        ticksPerQuarter: Int,
        key: DetectedKey? = nil,
        quantizeBasis: Int? = nil
    ) -> ChordProgressionResult {
        let tpq = max(1, ticksPerQuarter)
        let basis = quantizeBasis ?? tpq
        guard basis > 0, !notes.isEmpty else {
            return ChordProgressionResult()
        }

        // Step 1: Build a beat-quantized timeline of active note groups.
        let chordSlots = buildChordSlots(notes: notes, quantizeBasis: basis, ticksPerQuarter: tpq)

        // Step 2: Classify each slot into a chord.
        var detectedChords: [DetectedChord] = []
        for slot in chordSlots {
            guard slot.pitchClasses.count >= 2 else { continue }
            if let chord = classifyChord(slot: slot) {
                // Merge with previous chord if same chord type.
                if let last = detectedChords.last,
                   last.root == chord.root && last.quality == chord.quality &&
                   last.tick + last.durationTicks >= chord.tick {
                    // Extend previous chord.
                    detectedChords[detectedChords.count - 1].durationTicks =
                        (chord.tick + chord.durationTicks) - last.tick
                } else {
                    detectedChords.append(chord)
                }
            }
        }

        // Step 3: Detect common progressions.
        let patterns = detectCommonProgressions(chords: detectedChords, key: key)

        return ChordProgressionResult(
            chords: detectedChords,
            key: key,
            commonProgressions: patterns
        )
    }

    /// Analyze chords within a specific tick range (e.g., one section).
    static func analyzeRange(
        notes: [PianoRollNote],
        startTick: Int,
        endTick: Int,
        ticksPerQuarter: Int,
        key: DetectedKey? = nil
    ) -> ChordProgressionResult {
        let filtered = notes.filter { note in
            let noteEnd = note.startTick + note.duration
            return note.startTick < endTick && noteEnd > startTick
        }
        return analyze(
            notes: filtered,
            ticksPerQuarter: ticksPerQuarter,
            key: key
        )
    }

    // MARK: - Beat Quantization

    /// A time slot containing note pitch classes that sound simultaneously.
    private struct ChordSlot {
        var tick: Int
        var durationTicks: Int
        var pitchClasses: Set<Int>
        var lowestPitch: Int        // absolute MIDI pitch (not pitch class)
        var pitches: [Int]          // all sounding MIDI pitches
    }

    /// Quantize notes to a grid and group co-sounding pitches.
    private static func buildChordSlots(
        notes: [PianoRollNote],
        quantizeBasis: Int,
        ticksPerQuarter: Int
    ) -> [ChordSlot] {
        guard !notes.isEmpty else { return [] }

        // Find the range of the piece.
        let minTick = notes.map(\.startTick).min() ?? 0
        let maxTick = notes.map { $0.startTick + $0.duration }.max() ?? 0

        // Quantize start to grid.
        let gridStart = (minTick / quantizeBasis) * quantizeBasis
        let gridEnd = ((maxTick + quantizeBasis - 1) / quantizeBasis) * quantizeBasis

        var slots: [ChordSlot] = []

        var tick = gridStart
        while tick < gridEnd {
            let slotEnd = tick + quantizeBasis

            // Find all notes sounding during this slot.
            var pitches: [Int] = []
            for note in notes {
                let noteEnd = note.startTick + note.duration
                // Note is active if it overlaps with [tick, slotEnd).
                if note.startTick < slotEnd && noteEnd > tick {
                    pitches.append(note.pitch)
                }
            }

            if !pitches.isEmpty {
                let pcs = Set(pitches.map { (($0 % 12) + 12) % 12 })
                let lowest = pitches.min() ?? 0
                slots.append(ChordSlot(
                    tick: tick,
                    durationTicks: quantizeBasis,
                    pitchClasses: pcs,
                    lowestPitch: lowest,
                    pitches: pitches
                ))
            }

            tick = slotEnd
        }

        return slots
    }

    // MARK: - Chord Classification

    /// Known chord interval patterns, sorted by specificity (most intervals first).
    private static let chordPatterns: [(intervals: Set<Int>, quality: String)] = [
        // 4-note chords
        (Set([0, 4, 7, 11]), "maj7"),
        (Set([0, 4, 7, 10]), "7"),
        (Set([0, 3, 7, 10]), "m7"),
        (Set([0, 3, 6, 10]), "m7b5"),
        (Set([0, 3, 6, 9]),  "dim7"),
        (Set([0, 4, 8, 10]), "aug7"),
        (Set([0, 3, 7, 11]), "mMaj7"),
        // 3-note chords
        (Set([0, 4, 7]),     ""),       // major
        (Set([0, 3, 7]),     "m"),      // minor
        (Set([0, 3, 6]),     "dim"),    // diminished
        (Set([0, 4, 8]),     "aug"),    // augmented
        (Set([0, 2, 7]),     "sus2"),   // sus2
        (Set([0, 5, 7]),     "sus4"),   // sus4
        // 2-note (power chord / interval)
        (Set([0, 7]),        "5"),      // power chord
    ]

    /// Classify a chord slot into a DetectedChord.
    private static func classifyChord(slot: ChordSlot) -> DetectedChord? {
        let pcs = slot.pitchClasses
        guard pcs.count >= 2 else { return nil }

        // Try each pitch class present as potential root.
        for root in pcs.sorted() {
            let intervals = Set(pcs.map { (($0 - root) + 12) % 12 })
            for pattern in chordPatterns {
                if intervals == pattern.intervals {
                    let bassPC = (slot.lowestPitch % 12 + 12) % 12
                    return DetectedChord(
                        tick: slot.tick,
                        durationTicks: slot.durationTicks,
                        root: root,
                        quality: pattern.quality,
                        bassNote: bassPC != root ? bassPC : nil,
                        pitchClasses: pcs
                    )
                }
            }
        }

        // Try all 12 roots for subset matching (inversions with extra notes).
        for root in 0..<12 {
            let intervals = Set(pcs.map { (($0 - root) + 12) % 12 })
            for pattern in chordPatterns where pattern.intervals.count <= pcs.count {
                if pattern.intervals.isSubset(of: intervals) {
                    let bassPC = (slot.lowestPitch % 12 + 12) % 12
                    return DetectedChord(
                        tick: slot.tick,
                        durationTicks: slot.durationTicks,
                        root: root,
                        quality: pattern.quality,
                        bassNote: bassPC != root ? bassPC : nil,
                        pitchClasses: pcs
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Progression Pattern Detection

    /// Detect common chord progression patterns.
    private static func detectCommonProgressions(
        chords: [DetectedChord],
        key: DetectedKey?
    ) -> [String] {
        guard let key = key, chords.count >= 3 else { return [] }

        // Convert chords to Roman numerals.
        let numerals = chords.map { $0.romanNumeral(in: key) }

        // Look for common patterns in sliding windows.
        var foundPatterns: [String] = []

        // Common progressions to detect (as arrays for n-gram matching).
        let knownProgressions: [([String], String)] = [
            (["I", "IV", "V", "I"], "I-IV-V-I (authentic cadence)"),
            (["I", "V", "vi", "IV"], "I-V-vi-IV (pop progression)"),
            (["i", "iv", "V", "i"], "i-iv-V-i (minor cadence)"),
            (["I", "IV", "I", "V"], "I-IV-I-V"),
            (["ii", "V", "I"], "ii-V-I (jazz turnaround)"),
            (["I", "vi", "IV", "V"], "I-vi-IV-V (50s progression)"),
            (["IV", "V", "I"], "IV-V-I (plagal approach)"),
            (["V", "I"], "V-I (perfect cadence)"),
            (["IV", "I"], "IV-I (plagal cadence)"),
            (["i", "VI", "III", "VII"], "i-VI-III-VII (Andalusian cadence)"),
        ]

        for (pattern, name) in knownProgressions {
            let patternLen = pattern.count
            if numerals.count < patternLen { continue }
            for i in 0...(numerals.count - patternLen) {
                let window = Array(numerals[i..<(i + patternLen)])
                if window == pattern {
                    if !foundPatterns.contains(name) {
                        foundPatterns.append(name)
                    }
                }
            }
        }

        // Also summarize the overall progression.
        if chords.count <= 16 {
            let summary = numerals.joined(separator: "-")
            if !summary.isEmpty && !foundPatterns.contains(where: { $0 == summary }) {
                foundPatterns.insert(summary, at: 0)
            }
        }

        return foundPatterns
    }
}
