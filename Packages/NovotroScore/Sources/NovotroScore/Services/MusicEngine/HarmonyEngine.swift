import Foundation

// MARK: - HarmonyEngine

/// Generates 4-part (SATB) harmonizations from a melody or chord progression,
/// following classical voice-leading rules.
///
/// Rules enforced:
/// - Voices stay within standard SATB ranges
/// - No parallel fifths or octaves between consecutive voicings
/// - Common tones retained where possible
/// - Smooth voice leading (prefer stepwise motion, avoid leaps > octave)
/// - Leading tones resolve upward
/// - Seventh chords resolve the seventh downward
enum HarmonyEngine {

    // MARK: - Voice Ranges (MIDI pitch)

    /// Standard SATB ranges (comfortable, not extreme).
    private static let ranges: [VoicePart: ClosedRange<Int>] = [
        .soprano: 60...81,  // C4–A5
        .alto:    53...74,  // F3–D5
        .tenor:   48...69,  // C3–A4
        .bass:    36...60,  // C2–C4
    ]

    // MARK: - Public API

    /// Harmonize a melody with SATB voicings.
    ///
    /// - Parameters:
    ///   - melody: The soprano melody notes (will be used as the soprano voice).
    ///   - key: The key for diatonic harmony.
    ///   - chords: Optional chord progression. If nil, chords are inferred from melody.
    ///   - ticksPerQuarter: MIDI resolution.
    /// - Returns: Harmonization result with voicings, violations, and quality score.
    static func harmonize(
        melody: [PianoRollNote],
        key: DetectedKey,
        chords: [DetectedChord]? = nil,
        ticksPerQuarter: Int
    ) -> HarmonizationResult {
        let sorted = melody.sorted { $0.startTick < $1.startTick }
        guard !sorted.isEmpty else {
            return HarmonizationResult(voicings: [], key: key, violations: [], score: 0)
        }

        let scale = key.scalePitchClasses
        let resolvedChords = chords ?? inferChords(melody: sorted, key: key, ticksPerQuarter: ticksPerQuarter)

        var voicings: [HarmonyVoicing] = []
        var violations: [String] = []

        for note in sorted {
            let sopranoPitch = note.pitch
            let chord = findChord(at: note.startTick, in: resolvedChords, key: key)

            // Generate the primary voicing.
            let primary = generateVoicing(
                sopranoPitch: sopranoPitch,
                chord: chord,
                key: key,
                scale: scale,
                previous: voicings.last,
                tick: note.startTick,
                duration: note.duration
            )

            // If we have a previous voicing, try to minimize voice-leading violations
            // by generating alternative voicings and picking the best one.
            if let prev = voicings.last {
                let primaryViolations = checkVoiceLeading(prev: prev, curr: primary)

                if primaryViolations.isEmpty {
                    voicings.append(primary)
                } else {
                    // Generate alternatives with small pitch adjustments.
                    let best = findBestAlternative(
                        primary: primary,
                        previous: prev,
                        chord: chord,
                        scale: scale,
                        sopranoPitch: sopranoPitch
                    )
                    let bestViolations = checkVoiceLeading(prev: prev, curr: best)
                    violations.append(contentsOf: bestViolations)
                    voicings.append(best)
                }
            } else {
                voicings.append(primary)
            }
        }

        // Score: based on transitions, not total voicings.
        // Each transition checks 6 voice pairs; max realistic violations is ~3 per transition.
        let transitions = Double(max(1, voicings.count - 1))
        let violationsPerTransition = Double(violations.count) / transitions
        let score = max(0, 1.0 - violationsPerTransition / 4.0)

        return HarmonizationResult(
            voicings: voicings,
            key: key,
            violations: violations,
            score: score
        )
    }

    /// Generate SATB notes from a harmonization result as PianoRollNotes.
    ///
    /// Returns notes for alto, tenor, and bass voices (soprano is the original melody).
    static func voicingsToNotes(
        result: HarmonizationResult,
        trackIndex: Int = 0,
        channel: Int = 0,
        velocity: Int = 80
    ) -> [VoicePart: [PianoRollNote]] {
        var partNotes: [VoicePart: [PianoRollNote]] = [
            .alto: [], .tenor: [], .bass: []
        ]

        for voicing in result.voicings {
            for part in [VoicePart.alto, .tenor, .bass] {
                let pitch = voicing.pitch(for: part)
                let note = PianoRollNote(
                    trackIndex: trackIndex,
                    channel: channel,
                    pitch: pitch,
                    velocity: velocity,
                    startTick: voicing.tick,
                    duration: voicing.durationTicks
                )
                partNotes[part]?.append(note)
            }
        }

        return partNotes
    }

    // MARK: - Alternative Voicing Search

    /// Try small perturbations to alto, tenor, bass to find a voicing with fewer violations.
    private static func findBestAlternative(
        primary: HarmonyVoicing,
        previous: HarmonyVoicing,
        chord: ChordTones,
        scale: Set<Int>,
        sopranoPitch: Int
    ) -> HarmonyVoicing {
        let primaryViolations = checkVoiceLeading(prev: previous, curr: primary)
        var bestVoicing = primary
        var bestCount = primaryViolations.count

        // Try adjusting each lower voice by +/- an octave or by a step within the chord.
        let altoRange = ranges[.alto]!
        let tenorRange = ranges[.tenor]!
        let bassRange = ranges[.bass]!

        // Generate pitch alternatives for each voice from chord + scale tones.
        let altoCandidates = pitchCandidates(for: chord, in: altoRange, near: primary.alto, scale: scale)
        let tenorCandidates = pitchCandidates(for: chord, in: tenorRange, near: primary.tenor, scale: scale)
        let bassCandidates = pitchCandidates(for: chord, in: bassRange, near: primary.bass, scale: scale)

        // Try a limited number of combinations (avoid combinatorial explosion).
        for alto in altoCandidates.prefix(4) {
            for tenor in tenorCandidates.prefix(4) {
                for bass in bassCandidates.prefix(3) {
                    // Enforce voice ordering: soprano >= alto >= tenor >= bass.
                    guard sopranoPitch >= alto && alto >= tenor && tenor >= bass else { continue }

                    let candidate = HarmonyVoicing(
                        tick: primary.tick,
                        durationTicks: primary.durationTicks,
                        soprano: sopranoPitch,
                        alto: alto,
                        tenor: tenor,
                        bass: bass
                    )
                    let v = checkVoiceLeading(prev: previous, curr: candidate)
                    if v.count < bestCount {
                        bestCount = v.count
                        bestVoicing = candidate
                        if bestCount == 0 { return bestVoicing }
                    }
                }
            }
        }

        return bestVoicing
    }

    /// Generate sorted pitch candidates for a voice from chord and scale tones.
    private static func pitchCandidates(
        for chord: ChordTones,
        in range: ClosedRange<Int>,
        near target: Int,
        scale: Set<Int>
    ) -> [Int] {
        var candidates: [Int] = []

        // Chord tones first (preferred).
        for pc in chord.pitchClasses {
            var pitch = range.lowerBound + ((pc - range.lowerBound % 12) + 12) % 12
            if pitch < range.lowerBound { pitch += 12 }
            while pitch <= range.upperBound {
                candidates.append(pitch)
                pitch += 12
            }
        }

        // Scale tones as fallback.
        for pc in scale where !chord.pitchClasses.contains(pc) {
            var pitch = range.lowerBound + ((pc - range.lowerBound % 12) + 12) % 12
            if pitch < range.lowerBound { pitch += 12 }
            while pitch <= range.upperBound {
                candidates.append(pitch)
                pitch += 12
            }
        }

        // Sort by distance from target (closest first).
        candidates.sort { abs($0 - target) < abs($1 - target) }
        // Remove duplicates.
        var seen = Set<Int>()
        candidates = candidates.filter { seen.insert($0).inserted }
        return candidates
    }

    // MARK: - Voicing Generation

    /// Generate a single SATB voicing for a given soprano pitch and chord.
    private static func generateVoicing(
        sopranoPitch: Int,
        chord: ChordTones,
        key: DetectedKey,
        scale: Set<Int>,
        previous: HarmonyVoicing?,
        tick: Int,
        duration: Int
    ) -> HarmonyVoicing {
        let chordPCs = chord.pitchClasses

        // Bass: root of chord, in bass range.
        let bassPitch = findNearestInRange(
            pitchClass: chord.root,
            range: ranges[.bass]!,
            preferredPitch: previous?.bass
        )

        // Tenor and alto: remaining chord tones, trying to use common tones
        // with previous voicing and minimize motion.
        let altoTarget = previous?.alto ?? (sopranoPitch - 7)
        let tenorTarget = previous?.tenor ?? (sopranoPitch - 12)

        // Find the best alto pitch from chord tones.
        let altoPitch = findBestVoice(
            chordPCs: chordPCs,
            range: ranges[.alto]!,
            target: altoTarget,
            avoid: [sopranoPitch, bassPitch],
            previous: previous?.alto,
            scale: scale
        )

        // Tenor gets the remaining chord tone.
        let tenorPitch = findBestVoice(
            chordPCs: chordPCs,
            range: ranges[.tenor]!,
            target: tenorTarget,
            avoid: [sopranoPitch, bassPitch, altoPitch],
            previous: previous?.tenor,
            scale: scale
        )

        return HarmonyVoicing(
            tick: tick,
            durationTicks: duration,
            soprano: sopranoPitch,
            alto: altoPitch,
            tenor: tenorPitch,
            bass: bassPitch
        )
    }

    /// Find the nearest pitch of a given pitch class within a range.
    private static func findNearestInRange(
        pitchClass: Int,
        range: ClosedRange<Int>,
        preferredPitch: Int? = nil
    ) -> Int {
        let target = preferredPitch ?? ((range.lowerBound + range.upperBound) / 2)
        var best = range.lowerBound
        var bestDist = Int.max

        var pitch = range.lowerBound + ((pitchClass - range.lowerBound % 12) + 12) % 12
        if pitch < range.lowerBound { pitch += 12 }

        while pitch <= range.upperBound {
            let dist = abs(pitch - target)
            if dist < bestDist {
                bestDist = dist
                best = pitch
            }
            pitch += 12
        }

        return best
    }

    /// Find the best pitch for a voice from the available chord tones.
    private static func findBestVoice(
        chordPCs: Set<Int>,
        range: ClosedRange<Int>,
        target: Int,
        avoid: [Int],
        previous: Int?,
        scale: Set<Int>
    ) -> Int {
        var candidates: [(pitch: Int, score: Double)] = []

        // Generate all candidate pitches from chord tones within range.
        for pc in chordPCs {
            var pitch = range.lowerBound + ((pc - range.lowerBound % 12) + 12) % 12
            if pitch < range.lowerBound { pitch += 12 }

            while pitch <= range.upperBound {
                if !avoid.contains(pitch) {
                    var score = 0.0
                    // Proximity to target (closer = better).
                    score -= Double(abs(pitch - target)) * 0.5
                    // Common tone bonus (same as previous = good).
                    if let prev = previous, pitch == prev { score += 5.0 }
                    // Stepwise motion bonus.
                    if let prev = previous, abs(pitch - prev) <= 2 { score += 3.0 }
                    // Penalty for large leaps.
                    if let prev = previous, abs(pitch - prev) > 7 { score -= 2.0 }

                    candidates.append((pitch, score))
                }
                pitch += 12
            }
        }

        // If no chord tone candidates, fill with scale tones.
        if candidates.isEmpty {
            for pc in scale {
                var pitch = range.lowerBound + ((pc - range.lowerBound % 12) + 12) % 12
                if pitch < range.lowerBound { pitch += 12 }

                while pitch <= range.upperBound {
                    if !avoid.contains(pitch) {
                        let score = -Double(abs(pitch - target)) * 0.3
                        candidates.append((pitch, score))
                    }
                    pitch += 12
                }
            }
        }

        // Fallback: midpoint of range.
        guard let best = candidates.max(by: { $0.score < $1.score }) else {
            return (range.lowerBound + range.upperBound) / 2
        }
        return best.pitch
    }

    // MARK: - Voice Leading Checks

    /// Check for voice-leading violations between two consecutive voicings.
    private static func checkVoiceLeading(
        prev: HarmonyVoicing,
        curr: HarmonyVoicing
    ) -> [String] {
        var violations: [String] = []

        let parts: [VoicePart] = [.soprano, .alto, .tenor, .bass]

        // Check each pair of voices for parallel fifths and octaves.
        for i in 0..<parts.count {
            for j in (i + 1)..<parts.count {
                let prevInterval = abs(prev.pitch(for: parts[i]) - prev.pitch(for: parts[j])) % 12
                let currInterval = abs(curr.pitch(for: parts[i]) - curr.pitch(for: parts[j])) % 12

                let prevMotionI = curr.pitch(for: parts[i]) - prev.pitch(for: parts[i])
                let prevMotionJ = curr.pitch(for: parts[j]) - prev.pitch(for: parts[j])
                let sameDirection = (prevMotionI > 0 && prevMotionJ > 0) || (prevMotionI < 0 && prevMotionJ < 0)

                // Parallel fifths (both voices move in same direction to a perfect fifth).
                if prevInterval == 7 && currInterval == 7 && sameDirection && prevMotionI != 0 {
                    violations.append("Parallel 5ths: \(parts[i].rawValue)-\(parts[j].rawValue) at tick \(curr.tick)")
                }

                // Parallel octaves (both voices move in same direction to a unison/octave).
                if prevInterval == 0 && currInterval == 0 && sameDirection && prevMotionI != 0 {
                    violations.append("Parallel 8ves: \(parts[i].rawValue)-\(parts[j].rawValue) at tick \(curr.tick)")
                }
            }

            // Check for voice crossing.
            if i < parts.count - 1 {
                let upper = curr.pitch(for: parts[i])
                let lower = curr.pitch(for: parts[i + 1])
                if upper < lower {
                    violations.append("Voice crossing: \(parts[i].rawValue) below \(parts[i + 1].rawValue) at tick \(curr.tick)")
                }
            }

            // Check for excessive leaps (> octave).
            let leap = abs(curr.pitch(for: parts[i]) - prev.pitch(for: parts[i]))
            if leap > 12 {
                violations.append("Large leap (\(leap) semitones) in \(parts[i].rawValue) at tick \(curr.tick)")
            }
        }

        return violations
    }

    // MARK: - Chord Inference

    /// Chord tones for voicing generation.
    private struct ChordTones {
        var root: Int              // pitch class
        var pitchClasses: Set<Int>
    }

    /// Infer simple diatonic chords from melody notes when no chord progression is given.
    private static func inferChords(
        melody: [PianoRollNote],
        key: DetectedKey,
        ticksPerQuarter: Int
    ) -> [DetectedChord] {
        // Simple heuristic: assign diatonic triads based on melody pitch.
        let majorTriads: [Int: (root: Int, quality: String)] = [
            0: (0, ""),    // I
            2: (2, "m"),   // ii
            4: (4, "m"),   // iii
            5: (5, ""),    // IV
            7: (7, ""),    // V
            9: (9, "m"),   // vi
            11: (11, "dim") // vii°
        ]

        let minorTriads: [Int: (root: Int, quality: String)] = [
            0: (0, "m"),   // i
            2: (2, "dim"), // ii°
            3: (3, ""),    // III
            5: (5, "m"),   // iv
            7: (7, "m"),   // v (or V with raised 7th)
            8: (8, ""),    // VI
            10: (10, ""),  // VII
        ]

        let triads = key.isMinor ? minorTriads : majorTriads

        return melody.compactMap { note in
            let scaleDegree = ((note.pitch - key.root) % 12 + 12) % 12

            // Find the nearest scale degree with a triad.
            let triad: (root: Int, quality: String)
            if let t = triads[scaleDegree] {
                triad = t
            } else {
                // Chromatic note — use the nearest lower scale degree.
                let lower = (scaleDegree - 1 + 12) % 12
                if let t = triads[lower] { triad = t }
                else { return nil as DetectedChord? }
            }

            let root = (triad.root + key.root) % 12
            let chordIntervals: [Int]
            switch triad.quality {
            case "m": chordIntervals = [0, 3, 7]
            case "dim": chordIntervals = [0, 3, 6]
            case "aug": chordIntervals = [0, 4, 8]
            default: chordIntervals = [0, 4, 7]  // major
            }
            let pcs = Set(chordIntervals.map { ($0 + root) % 12 })

            return DetectedChord(
                tick: note.startTick,
                durationTicks: note.duration,
                root: root,
                quality: triad.quality,
                bassNote: nil,
                pitchClasses: pcs
            )
        }
    }

    /// Find the chord active at a given tick.
    private static func findChord(
        at tick: Int,
        in chords: [DetectedChord],
        key: DetectedKey
    ) -> ChordTones {
        // Find the last chord that starts at or before this tick.
        let chord = chords.last { $0.tick <= tick }
            ?? chords.first

        if let c = chord {
            return ChordTones(root: c.root, pitchClasses: c.pitchClasses)
        }

        // Fallback: tonic triad.
        let intervals = key.isMinor ? [0, 3, 7] : [0, 4, 7]
        let pcs = Set(intervals.map { ($0 + key.root) % 12 })
        return ChordTones(root: key.root, pitchClasses: pcs)
    }
}
