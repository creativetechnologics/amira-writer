import Foundation

// MARK: - StyleAnalyzer

/// Infers musical style from melodic, rhythmic, and harmonic characteristics.
///
/// All methods are pure functions operating on note/chord data. The caller
/// (`ProjectStore`) is responsible for providing pre-detected key and chords.
enum StyleAnalyzer {

    // MARK: - Melodic Profile

    /// Analyze melodic characteristics: density, intervals, range, contour distribution.
    static func analyzeMelodicProfile(
        notes: [PianoRollNote],
        ticksPerQuarter: Int
    ) -> MelodicProfile {
        guard notes.count >= 2 else {
            return MelodicProfile(
                noteDensity: 0,
                leapFrequency: 0,
                averageInterval: 0,
                pitchRange: 0,
                contourDistribution: [:]
            )
        }

        let sorted = notes.sorted { $0.startTick < $1.startTick }
        let tpq = max(1, ticksPerQuarter)
        let pitches = sorted.map(\.pitch)
        let minPitch = pitches.min() ?? 0
        let maxPitch = pitches.max() ?? 0

        // Note density: notes per beat
        let totalTicks = (sorted.last?.startTick ?? 0) + (sorted.last?.duration ?? 0) - (sorted.first?.startTick ?? 0)
        let totalBeats = max(1.0, Double(totalTicks) / Double(tpq))
        let noteDensity = Double(sorted.count) / totalBeats

        // Intervals between consecutive notes
        var intervals: [Int] = []
        for i in 1..<sorted.count {
            intervals.append(sorted[i].pitch - sorted[i - 1].pitch)
        }

        let absIntervals = intervals.map { abs($0) }
        let averageInterval = absIntervals.isEmpty ? 0 : Double(absIntervals.reduce(0, +)) / Double(absIntervals.count)
        let leapCount = absIntervals.filter { $0 > 4 }.count
        let leapFrequency = absIntervals.isEmpty ? 0 : Double(leapCount) / Double(absIntervals.count)

        // Contour distribution: classify intervals into ascending/descending/constant
        var ascending = 0
        var descending = 0
        var constant = 0
        for interval in intervals {
            if interval > 0 { ascending += 1 }
            else if interval < 0 { descending += 1 }
            else { constant += 1 }
        }
        let totalIntervals = max(1, intervals.count)
        var contourDist: [MelodicContour: Double] = [:]
        contourDist[.ascending] = Double(ascending) / Double(totalIntervals)
        contourDist[.descending] = Double(descending) / Double(totalIntervals)
        contourDist[.constant] = Double(constant) / Double(totalIntervals)

        // Classify overall shape using first/second half
        let midIdx = intervals.count / 2
        if midIdx > 0 {
            let firstHalfAvg = intervals.prefix(midIdx).reduce(0, +)
            let secondHalfAvg = intervals.suffix(from: midIdx).reduce(0, +)
            if firstHalfAvg > 0 && secondHalfAvg < 0 {
                contourDist[.arch] = 0.5
            } else if firstHalfAvg < 0 && secondHalfAvg > 0 {
                contourDist[.invertedArch] = 0.5
            }
        }

        return MelodicProfile(
            noteDensity: noteDensity,
            leapFrequency: leapFrequency,
            averageInterval: averageInterval,
            pitchRange: maxPitch - minPitch,
            contourDistribution: contourDist
        )
    }

    // MARK: - Rhythmic Profile

    /// Analyze rhythmic characteristics: syncopation, variety, durations, rests.
    static func analyzeRhythmicProfile(
        notes: [PianoRollNote],
        ticksPerQuarter: Int
    ) -> RhythmicProfile {
        guard !notes.isEmpty else {
            return RhythmicProfile(
                syncopationIndex: 0,
                rhythmicVariety: 0,
                averageDurationBeats: 0,
                dottedNoteFrequency: 0,
                restFrequency: 0
            )
        }

        let sorted = notes.sorted { $0.startTick < $1.startTick }
        let tpq = max(1, ticksPerQuarter)
        let tpqD = Double(tpq)

        // Syncopation: notes starting on off-beats (not on quarter note boundaries)
        let offBeatCount = sorted.filter { $0.startTick % tpq != 0 }.count
        let syncopationIndex = Double(offBeatCount) / Double(sorted.count)

        // Rhythmic variety: unique durations / total notes
        let uniqueDurations = Set(sorted.map(\.duration))
        let rhythmicVariety = Double(uniqueDurations.count) / Double(sorted.count)

        // Average duration in beats
        let totalDuration = sorted.map(\.duration).reduce(0, +)
        let averageDurationBeats = Double(totalDuration) / Double(sorted.count) / tpqD

        // Dotted note frequency: durations that are 1.5x a base value
        // Common dotted values: dotted quarter = 1.5 * tpq, dotted eighth = 0.75 * tpq
        let dottedValues: Set<Int> = [
            tpq * 3,               // dotted half
            tpq * 3 / 2,           // dotted quarter
            tpq * 3 / 4,           // dotted eighth
            tpq * 3 / 8            // dotted sixteenth
        ]
        let dottedCount = sorted.filter { note in
            dottedValues.contains(note.duration)
        }.count
        let dottedNoteFrequency = Double(dottedCount) / Double(sorted.count)

        // Rest frequency: gaps between consecutive notes > 0.5 beats
        var restCount = 0
        let halfBeatTicks = tpq / 2
        for i in 1..<sorted.count {
            let prevEnd = sorted[i - 1].startTick + sorted[i - 1].duration
            let gap = sorted[i].startTick - prevEnd
            if gap > halfBeatTicks {
                restCount += 1
            }
        }
        let restFrequency = sorted.count > 1 ? Double(restCount) / Double(sorted.count - 1) : 0

        return RhythmicProfile(
            syncopationIndex: syncopationIndex,
            rhythmicVariety: rhythmicVariety,
            averageDurationBeats: averageDurationBeats,
            dottedNoteFrequency: dottedNoteFrequency,
            restFrequency: restFrequency
        )
    }

    // MARK: - Harmonic Complexity

    /// Analyze harmonic complexity from detected chords and key.
    static func analyzeHarmonicComplexity(
        chords: [DetectedChord],
        key: DetectedKey
    ) -> HarmonicComplexity {
        guard !chords.isEmpty else {
            return HarmonicComplexity(
                chordDensity: 0,
                functionalStrength: 0,
                extensionUsage: 0,
                chromaticism: 0
            )
        }

        // Chord density: chords per bar (assuming 4 beats per bar)
        let totalTicks = (chords.map { $0.tick + $0.durationTicks }.max() ?? 0)
            - (chords.map(\.tick).min() ?? 0)
        // Approximate: assume 480 ticks per quarter (common default)
        let estimatedBars = max(1.0, Double(totalTicks) / Double(480 * 4))
        let chordDensity = Double(chords.count) / estimatedBars

        // Functional harmony strength: fraction of chords that are I, IV, V, or vi
        // In terms of intervals from key root: I=0, IV=5, V=7, vi=9(major)/8(minor)
        let functionalIntervals: Set<Int> = [0, 5, 7, 9, 8]  // covers both major vi and minor vi
        let functionalCount = chords.filter { chord in
            let interval = ((chord.root - key.root) % 12 + 12) % 12
            return functionalIntervals.contains(interval)
        }.count
        let functionalStrength = Double(functionalCount) / Double(chords.count)

        // Extension usage: chords with 7th, 9th, 11th, 13th
        let extensionIndicators = ["7", "9", "11", "13"]
        let extensionCount = chords.filter { chord in
            extensionIndicators.contains(where: { chord.quality.contains($0) })
        }.count
        let extensionUsage = Double(extensionCount) / Double(chords.count)

        // Chromaticism: chords with root outside the key's diatonic scale
        let scalePCs = key.scalePitchClasses
        let chromaticCount = chords.filter { !scalePCs.contains($0.root % 12) }.count
        let chromaticism = Double(chromaticCount) / Double(chords.count)

        return HarmonicComplexity(
            chordDensity: chordDensity,
            functionalStrength: functionalStrength,
            extensionUsage: extensionUsage,
            chromaticism: chromaticism
        )
    }

    // MARK: - Combined Analysis

    /// Full style analysis combining melodic, rhythmic, and harmonic profiles.
    static func analyze(
        notes: [PianoRollNote],
        chords: [DetectedChord],
        key: DetectedKey,
        ticksPerQuarter: Int
    ) -> MusicalStyleProfile {
        let melodic = analyzeMelodicProfile(notes: notes, ticksPerQuarter: ticksPerQuarter)
        let rhythmic = analyzeRhythmicProfile(notes: notes, ticksPerQuarter: ticksPerQuarter)
        let harmonic = analyzeHarmonicComplexity(chords: chords, key: key)

        var hints: [String] = []

        // Genre inference based on characteristic combinations
        // Operatic/Classical: wide intervals, low syncopation, strong functional harmony
        if melodic.leapFrequency > 0.3 && rhythmic.syncopationIndex < 0.3
            && harmonic.functionalStrength > 0.5 {
            hints.append("operatic")
        }

        // Romantic: wide pitch range, moderate extensions, arched contours
        if melodic.pitchRange > 18 && harmonic.extensionUsage > 0.1
            && (melodic.contourDistribution[.arch] ?? 0) > 0.2 {
            hints.append("romantic")
        }

        // Jazz: high syncopation, high extension usage
        if rhythmic.syncopationIndex > 0.4 && harmonic.extensionUsage > 0.3 {
            hints.append("jazz")
        }

        // Recitative: low melodic range, high rhythmic variety, speech-like
        if melodic.pitchRange < 10 && rhythmic.rhythmicVariety > 0.4
            && melodic.averageInterval < 3 {
            hints.append("recitative")
        }

        // Through-composed: high rhythmic variety, many contour types
        if rhythmic.rhythmicVariety > 0.3 && melodic.contourDistribution.count >= 3 {
            hints.append("through-composed")
        }

        // Lyrical: moderate density, small intervals, connected (few rests)
        if melodic.noteDensity > 1.0 && melodic.noteDensity < 4.0
            && melodic.averageInterval < 4 && rhythmic.restFrequency < 0.2 {
            hints.append("lyrical")
        }

        // Chromatic: high chromaticism score
        if harmonic.chromaticism > 0.3 {
            hints.append("chromatic")
        }

        // Minimalist: low rhythmic variety, constant contour dominates
        if rhythmic.rhythmicVariety < 0.15
            && (melodic.contourDistribution[.constant] ?? 0) > 0.3 {
            hints.append("minimalist")
        }

        if hints.isEmpty {
            hints.append("mixed")
        }

        return MusicalStyleProfile(
            melodicProfile: melodic,
            rhythmicProfile: rhythmic,
            harmonicComplexity: harmonic,
            genreHints: hints
        )
    }
}
