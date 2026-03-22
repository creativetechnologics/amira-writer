import Foundation

// MARK: - InstrumentPartGenerator

/// Generates instrument parts from a melody, detected chords, and key.
///
/// Five generation styles are available: sustained pads, arpeggiated patterns,
/// rhythmic stabs, countermelody lines, and octave doubling. All generated
/// notes are constrained to the target instrument's range via
/// `InstrumentRangeDatabase`.
enum InstrumentPartGenerator {

    // MARK: - Generation Style

    /// Available part generation styles.
    enum GenerationStyle: String, CaseIterable, Sendable {
        case sustained      // long held notes on chord roots/fifths
        case arpeggiated    // broken chord patterns
        case rhythmic       // repeated stabs on beat subdivisions
        case countermelody  // contrary motion derived from melody
        case doubling       // octave-transposed melody copy

        var displayName: String {
            switch self {
            case .sustained: return "Sustained"
            case .arpeggiated: return "Arpeggiated"
            case .rhythmic: return "Rhythmic"
            case .countermelody: return "Countermelody"
            case .doubling: return "Doubling"
            }
        }
    }

    // MARK: - Public API

    /// Generate an instrument part.
    ///
    /// - Parameters:
    ///   - melody: Source melody notes (typically the vocal track).
    ///   - chords: Detected chord progression from `ChordProgressionAnalyzer`.
    ///   - key: Detected key for scale-aware generation.
    ///   - instrument: Target instrument name (must match `InstrumentRangeDatabase`).
    ///   - style: Generation style to use.
    ///   - trackIndex: Track index for generated notes.
    ///   - channel: MIDI channel for generated notes.
    ///   - ticksPerQuarter: MIDI resolution.
    ///   - config: Generation configuration.
    /// - Returns: Array of generated `PianoRollNote`s.
    static func generate(
        melody: [PianoRollNote],
        chords: [DetectedChord],
        key: DetectedKey,
        instrument: String,
        style: GenerationStyle,
        trackIndex: Int,
        channel: Int,
        ticksPerQuarter: Int,
        config: PartGenerationConfig = .init()
    ) -> [PianoRollNote] {
        guard !melody.isEmpty else { return [] }

        let tpq = max(1, ticksPerQuarter)

        switch style {
        case .sustained:
            return generateSustained(
                chords: chords, instrument: instrument,
                trackIndex: trackIndex, channel: channel,
                tpq: tpq, config: config
            )
        case .arpeggiated:
            return generateArpeggiated(
                chords: chords, key: key, instrument: instrument,
                trackIndex: trackIndex, channel: channel,
                tpq: tpq, config: config
            )
        case .rhythmic:
            return generateRhythmic(
                chords: chords, instrument: instrument,
                trackIndex: trackIndex, channel: channel,
                tpq: tpq, config: config
            )
        case .countermelody:
            return generateCountermelody(
                melody: melody, chords: chords, key: key, instrument: instrument,
                trackIndex: trackIndex, channel: channel,
                tpq: tpq, config: config
            )
        case .doubling:
            return generateDoubling(
                melody: melody, instrument: instrument,
                trackIndex: trackIndex, channel: channel,
                config: config
            )
        }
    }

    // MARK: - Sustained

    /// Generate long held notes on chord roots, alternating with fifths for variety.
    private static func generateSustained(
        chords: [DetectedChord],
        instrument: String,
        trackIndex: Int,
        channel: Int,
        tpq: Int,
        config: PartGenerationConfig
    ) -> [PianoRollNote] {
        guard !chords.isEmpty else { return [] }

        let baseVelocity = Int(Double(80) * config.velocityScale)
        var notes: [PianoRollNote] = []

        for (i, chord) in chords.enumerated() {
            // Alternate between root and fifth for variety.
            let pc = i % 2 == 0 ? chord.root : (chord.root + 7) % 12
            let pitch = InstrumentRangeDatabase.transposeToComfortableRange(
                60 + pc, instrument: instrument
            )

            let duration = max(tpq / 2, chord.durationTicks)
            notes.append(PianoRollNote(
                trackIndex: trackIndex,
                channel: channel,
                pitch: pitch,
                velocity: clampVelocity(baseVelocity),
                startTick: chord.tick,
                duration: duration
            ))
        }

        return notes
    }

    // MARK: - Arpeggiated

    /// Generate broken chord patterns cycling through chord tones.
    private static func generateArpeggiated(
        chords: [DetectedChord],
        key: DetectedKey,
        instrument: String,
        trackIndex: Int,
        channel: Int,
        tpq: Int,
        config: PartGenerationConfig
    ) -> [PianoRollNote] {
        guard !chords.isEmpty else { return [] }

        let baseVelocity = Int(Double(70) * config.velocityScale)
        // Subdivision: density 1.0 = eighth notes, 2.0 = sixteenths, 0.5 = quarters.
        let subdivisionTicks = max(tpq / 8, Int(Double(tpq) / (2.0 * config.rhythmDensity)))
        var notes: [PianoRollNote] = []

        for chord in chords {
            let chordTones = chordPitchClasses(chord: chord, includeExtensions: config.useChordExtensions)
            guard !chordTones.isEmpty else { continue }

            var tick = chord.tick
            let endTick = chord.tick + chord.durationTicks
            var toneIndex = 0

            while tick < endTick {
                let pc = chordTones[toneIndex % chordTones.count]
                let pitch = InstrumentRangeDatabase.transposeToComfortableRange(
                    60 + pc, instrument: instrument
                )

                let dur = min(subdivisionTicks, endTick - tick)
                if dur > 0 {
                    notes.append(PianoRollNote(
                        trackIndex: trackIndex,
                        channel: channel,
                        pitch: pitch,
                        velocity: clampVelocity(baseVelocity),
                        startTick: tick,
                        duration: dur
                    ))
                }

                tick += subdivisionTicks
                toneIndex += 1
            }
        }

        return notes
    }

    // MARK: - Rhythmic

    /// Generate repeated chord root stabs on beat subdivisions.
    private static func generateRhythmic(
        chords: [DetectedChord],
        instrument: String,
        trackIndex: Int,
        channel: Int,
        tpq: Int,
        config: PartGenerationConfig
    ) -> [PianoRollNote] {
        guard !chords.isEmpty else { return [] }

        let baseVelocity = Int(Double(85) * config.velocityScale)
        // Rhythm density: 1.0 = quarter note stabs, 2.0 = eighth note stabs.
        let stabInterval = max(tpq / 4, Int(Double(tpq) / config.rhythmDensity))
        let stabDuration = max(tpq / 8, stabInterval / 2) // staccato: half the interval
        var notes: [PianoRollNote] = []

        for chord in chords {
            let pc = chord.root
            let pitch = InstrumentRangeDatabase.transposeToComfortableRange(
                60 + pc, instrument: instrument
            )

            var tick = chord.tick
            let endTick = chord.tick + chord.durationTicks

            while tick < endTick {
                let dur = min(stabDuration, endTick - tick)
                if dur > 0 {
                    notes.append(PianoRollNote(
                        trackIndex: trackIndex,
                        channel: channel,
                        pitch: pitch,
                        velocity: clampVelocity(baseVelocity),
                        startTick: tick,
                        duration: dur
                    ))
                }
                tick += stabInterval
            }
        }

        return notes
    }

    // MARK: - Countermelody

    /// Generate a contrary-motion line derived from the melody.
    ///
    /// When the melody moves up, the countermelody moves down by a similar
    /// interval, snapping to chord tones and scale degrees from the detected key.
    private static func generateCountermelody(
        melody: [PianoRollNote],
        chords: [DetectedChord],
        key: DetectedKey,
        instrument: String,
        trackIndex: Int,
        channel: Int,
        tpq: Int,
        config: PartGenerationConfig
    ) -> [PianoRollNote] {
        let sorted = melody.sorted { $0.startTick < $1.startTick }
        guard sorted.count >= 2 else { return [] }

        let baseVelocity = Int(Double(75) * config.velocityScale)
        let scalePCs = key.scalePitchClasses
        var notes: [PianoRollNote] = []

        // Start the countermelody at the melody's first pitch, transposed to instrument range.
        var currentPitch = InstrumentRangeDatabase.transposeToComfortableRange(
            sorted[0].pitch, instrument: instrument
        )

        for i in 0..<sorted.count {
            let melodyNote = sorted[i]

            if i > 0 {
                let prevMelody = sorted[i - 1]
                let interval = melodyNote.pitch - prevMelody.pitch
                // Move in contrary motion.
                let rawPitch = currentPitch - interval
                // Snap to nearest scale tone.
                currentPitch = snapToScale(rawPitch, scalePitchClasses: scalePCs)
            }

            // Clamp to instrument range.
            currentPitch = InstrumentRangeDatabase.clampToRange(currentPitch, instrument: instrument)

            // Prefer chord tones when available.
            if let chord = chordAt(tick: melodyNote.startTick, chords: chords) {
                let chordPCs = chordPitchClasses(chord: chord, includeExtensions: false)
                let pc = ((currentPitch % 12) + 12) % 12
                if !chordPCs.contains(pc) {
                    // Nudge to nearest chord tone.
                    if let nearest = nearestChordTone(pitch: currentPitch, chordPCs: chordPCs, instrument: instrument) {
                        currentPitch = nearest
                    }
                }
            }

            notes.append(PianoRollNote(
                trackIndex: trackIndex,
                channel: channel,
                pitch: currentPitch,
                velocity: clampVelocity(baseVelocity),
                startTick: melodyNote.startTick,
                duration: melodyNote.duration
            ))
        }

        return notes
    }

    // MARK: - Doubling

    /// Copy the melody transposed to fit the instrument's comfortable range.
    private static func generateDoubling(
        melody: [PianoRollNote],
        instrument: String,
        trackIndex: Int,
        channel: Int,
        config: PartGenerationConfig
    ) -> [PianoRollNote] {
        guard !melody.isEmpty else { return [] }

        let baseVelocityScale = config.velocityScale

        // Determine octave offset: find the transposition that puts the melody's
        // mean pitch closest to the instrument's comfortable center.
        guard let prof = InstrumentRangeDatabase.profile(for: instrument) else {
            return melody.map { note in
                PianoRollNote(
                    trackIndex: trackIndex,
                    channel: channel,
                    pitch: note.pitch,
                    velocity: clampVelocity(Int(Double(note.velocity) * baseVelocityScale)),
                    startTick: note.startTick,
                    duration: note.duration
                )
            }
        }

        let comfCenter = (prof.comfortableRange.lowerBound + prof.comfortableRange.upperBound) / 2
        guard !melody.isEmpty else { return [] }
        let melodyMean = melody.map(\.pitch).reduce(0, +) / melody.count
        let rawOffset = comfCenter - melodyMean
        // Round to nearest octave.
        let octaveOffset = Int((Double(rawOffset) / 12.0).rounded()) * 12

        return melody.map { note in
            var pitch = note.pitch + octaveOffset
            pitch = InstrumentRangeDatabase.clampToRange(pitch, instrument: instrument)
            return PianoRollNote(
                trackIndex: trackIndex,
                channel: channel,
                pitch: pitch,
                velocity: clampVelocity(Int(Double(note.velocity) * baseVelocityScale)),
                startTick: note.startTick,
                duration: note.duration
            )
        }
    }

    // MARK: - Helpers

    /// Extract ordered chord pitch classes from a DetectedChord.
    private static func chordPitchClasses(chord: DetectedChord, includeExtensions: Bool) -> [Int] {
        // Build from root + known intervals.
        var pcs = [chord.root]
        let quality = chord.quality

        // Third
        if quality.hasPrefix("m") && !quality.hasPrefix("maj") {
            pcs.append((chord.root + 3) % 12) // minor third
        } else if quality == "sus2" {
            pcs.append((chord.root + 2) % 12)
        } else if quality == "sus4" {
            pcs.append((chord.root + 5) % 12)
        } else if quality != "5" {
            pcs.append((chord.root + 4) % 12) // major third
        }

        // Fifth
        if quality == "dim" || quality == "dim7" || quality == "m7b5" {
            pcs.append((chord.root + 6) % 12) // diminished fifth
        } else if quality == "aug" || quality == "aug7" {
            pcs.append((chord.root + 8) % 12) // augmented fifth
        } else {
            pcs.append((chord.root + 7) % 12) // perfect fifth
        }

        // Seventh (if extensions enabled or chord quality implies it)
        if includeExtensions || quality.contains("7") {
            if quality == "maj7" || quality == "mMaj7" {
                pcs.append((chord.root + 11) % 12)
            } else if quality.contains("7") {
                pcs.append((chord.root + 10) % 12)
            }
        }

        return pcs
    }

    /// Find the chord active at a given tick.
    private static func chordAt(tick: Int, chords: [DetectedChord]) -> DetectedChord? {
        chords.last { chord in
            tick >= chord.tick && tick < chord.tick + chord.durationTicks
        }
    }

    /// Snap a pitch to the nearest scale tone.
    private static func snapToScale(_ pitch: Int, scalePitchClasses: Set<Int>) -> Int {
        let pc = ((pitch % 12) + 12) % 12
        if scalePitchClasses.contains(pc) { return pitch }

        // Try +1 and -1 semitone.
        let up = ((pc + 1) % 12 + 12) % 12
        let down = ((pc - 1) % 12 + 12) % 12
        if scalePitchClasses.contains(up) { return pitch + 1 }
        if scalePitchClasses.contains(down) { return pitch - 1 }
        // Try +2.
        let up2 = ((pc + 2) % 12 + 12) % 12
        if scalePitchClasses.contains(up2) { return pitch + 2 }
        return pitch // fallback
    }

    /// Find the nearest chord tone pitch to the given pitch within instrument range.
    private static func nearestChordTone(pitch: Int, chordPCs: [Int], instrument: String) -> Int? {
        guard !chordPCs.isEmpty else { return nil }

        var bestPitch = pitch
        var bestDist = Int.max

        for pc in chordPCs {
            // Try pitches within +-12 semitones of current.
            for octaveOffset in stride(from: -12, through: 12, by: 12) {
                let candidate = pitch + octaveOffset + ((pc - ((pitch % 12) + 12) % 12 + 12) % 12)
                let dist = abs(candidate - pitch)
                if dist < bestDist {
                    let clamped = InstrumentRangeDatabase.clampToRange(candidate, instrument: instrument)
                    if clamped == candidate { // only if it's actually in range
                        bestDist = dist
                        bestPitch = candidate
                    }
                }
            }
        }

        return bestPitch
    }

    /// Clamp velocity to valid MIDI range.
    private static func clampVelocity(_ v: Int) -> Int {
        min(127, max(1, v))
    }
}
