import Foundation

// MARK: - MelodicContourAnalyzer

/// Analyzes melodic contour shapes and identifies stress points in note sequences.
///
/// Used by `SmartLyricAligner` to ensure stressed syllables land on melodic peaks
/// and unstressed syllables on valleys, creating natural text-music prosody.
enum MelodicContourAnalyzer {

    // MARK: - Contour Classification

    /// Classify the overall contour shape of a pitch sequence.
    ///
    /// Uses linear regression for trend direction and peak analysis for arch detection.
    static func classify(pitches: [Int]) -> MelodicContour {
        guard pitches.count >= 2 else { return .constant }

        let range = (pitches.max() ?? 0) - (pitches.min() ?? 0)
        // If all pitches are within 2 semitones, it's constant.
        if range <= 2 { return .constant }

        let n = Double(pitches.count)
        let xs = (0..<pitches.count).map { Double($0) }
        let ys = pitches.map { Double($0) }

        // Linear regression slope.
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for i in 0..<pitches.count {
            let dx = xs[i] - meanX
            numerator += dx * (ys[i] - meanY)
            denominator += dx * dx
        }
        let slope = denominator > 0 ? numerator / denominator : 0

        // Normalized slope relative to range.
        let normalizedSlope = slope * n / Double(max(1, range))

        // Check for arch / inverted arch patterns.
        // Find the peak and trough positions.
        let peakIndex = pitches.indices.max(by: { pitches[$0] < pitches[$1] }) ?? 0
        let troughIndex = pitches.indices.min(by: { pitches[$0] < pitches[$1] }) ?? 0
        let peakPosition = Double(peakIndex) / max(1, n - 1)  // 0.0 = start, 1.0 = end
        let troughPosition = Double(troughIndex) / max(1, n - 1)

        // Arch: peak in the middle (0.2–0.8), values lower at both ends.
        if peakPosition > 0.2 && peakPosition < 0.8 {
            let startPitch = Double(pitches[0])
            let endPitch = Double(pitches[pitches.count - 1])
            let peakPitch = Double(pitches[peakIndex])
            let riseFromStart = peakPitch - startPitch
            let dropToEnd = peakPitch - endPitch
            if riseFromStart > Double(range) * 0.3 && dropToEnd > Double(range) * 0.3 {
                return .arch
            }
        }

        // Inverted arch: trough in the middle, values higher at both ends.
        if troughPosition > 0.2 && troughPosition < 0.8 {
            let startPitch = Double(pitches[0])
            let endPitch = Double(pitches[pitches.count - 1])
            let troughPitch = Double(pitches[troughIndex])
            let dropFromStart = startPitch - troughPitch
            let riseToEnd = endPitch - troughPitch
            if dropFromStart > Double(range) * 0.3 && riseToEnd > Double(range) * 0.3 {
                return .invertedArch
            }
        }

        // Simple ascending / descending based on slope.
        if normalizedSlope > 0.5 { return .ascending }
        if normalizedSlope < -0.5 { return .descending }

        return .mixed
    }

    // MARK: - Stress Suitability

    /// For each note, compute a "stress suitability" score (0.0–1.0).
    ///
    /// Higher scores indicate notes suitable for stressed syllables or word beginnings:
    /// - Pitch peaks (local maxima)
    /// - Longer duration notes
    /// - Notes on strong metric beats
    /// - Notes reached by upward leaps
    ///
    /// Returns a dictionary keyed by note ID.
    static func stressSuitability(
        notes: [PianoRollNote],
        timeSignatures: [TimeSignatureEvent] = [],
        ticksPerQuarter: Int
    ) -> [UUID: Double] {
        guard !notes.isEmpty else { return [:] }
        let sorted = notes.sorted { $0.startTick < $1.startTick }
        let tpq = max(1, ticksPerQuarter)

        // Pre-compute median duration for relative comparison.
        let durations = sorted.map(\.duration).sorted()
        let medianDuration = Double(durations[durations.count / 2])

        var result: [UUID: Double] = [:]

        for (i, note) in sorted.enumerated() {
            var score = 0.0

            // Factor 1: Pitch peak — is this note a local maximum?
            let pitchPeakScore = pitchPeakFactor(index: i, notes: sorted)
            score += pitchPeakScore * 0.35

            // Factor 2: Duration — longer notes carry more emphasis.
            let durationScore = durationFactor(
                duration: note.duration,
                medianDuration: medianDuration
            )
            score += durationScore * 0.25

            // Factor 3: Metric position — notes on strong beats.
            let metricScore = metricPositionFactor(
                tick: note.startTick,
                timeSignatures: timeSignatures,
                ticksPerQuarter: tpq
            )
            score += metricScore * 0.25

            // Factor 4: Leap approach — notes reached by upward leap.
            let leapScore = leapApproachFactor(index: i, notes: sorted)
            score += leapScore * 0.15

            result[note.id] = min(1.0, max(0.0, score))
        }

        return result
    }

    // MARK: - Stress Points

    /// Returns indices of notes that represent melodic stress points.
    ///
    /// A note is a stress point if its suitability score exceeds the mean by
    /// at least 0.5 standard deviations, or if it's on beat 1 of a bar.
    static func findStressPoints(
        notes: [PianoRollNote],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int
    ) -> Set<Int> {
        let sorted = notes.sorted { $0.startTick < $1.startTick }
        let scores = stressSuitability(
            notes: sorted,
            timeSignatures: timeSignatures,
            ticksPerQuarter: ticksPerQuarter
        )

        let values = sorted.map { scores[$0.id] ?? 0 }
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let variance = values.isEmpty ? 0 : values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let stdDev = variance.squareRoot()
        let threshold = mean + stdDev * 0.5

        var stressPoints: Set<Int> = []
        for (i, val) in values.enumerated() {
            if val >= threshold {
                stressPoints.insert(i)
            }
        }

        return stressPoints
    }

    // MARK: - Factor Computations

    /// Pitch peak factor: how much this note stands out as a local maximum.
    private static func pitchPeakFactor(index: Int, notes: [PianoRollNote]) -> Double {
        let pitch = notes[index].pitch

        // Compare with neighbors (2 on each side).
        let window = 2
        var neighborsBelow = 0
        var neighborCount = 0

        for delta in -window...window where delta != 0 {
            let j = index + delta
            if j >= 0 && j < notes.count {
                neighborCount += 1
                if notes[j].pitch < pitch {
                    neighborsBelow += 1
                }
            }
        }

        guard neighborCount > 0 else { return 0.5 }

        // Score: proportion of neighbors that are lower.
        let rawScore = Double(neighborsBelow) / Double(neighborCount)

        // Bonus for being a strict local maximum (higher than all immediate neighbors).
        var isStrictMax = true
        if index > 0 && notes[index - 1].pitch >= pitch { isStrictMax = false }
        if index < notes.count - 1 && notes[index + 1].pitch >= pitch { isStrictMax = false }

        return isStrictMax ? min(1.0, rawScore + 0.2) : rawScore
    }

    /// Duration factor: longer notes relative to median get higher scores.
    private static func durationFactor(duration: Int, medianDuration: Double) -> Double {
        guard medianDuration > 0 else { return 0.5 }
        // Log-scaled ratio so extreme durations don't dominate.
        let ratio = Double(duration) / medianDuration
        let logRatio = log2(max(0.25, ratio)) // range: -2 to ~3
        // Map [-2, 3] to [0, 1]
        return min(1.0, max(0.0, (logRatio + 2) / 5.0))
    }

    /// Metric position factor: notes on strong beats score higher.
    private static func metricPositionFactor(
        tick: Int,
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int
    ) -> Double {
        let timeSig = PhraseDetector.activeTimeSignature(at: tick, timeSignatures: timeSignatures)
        let ticksPerBeat: Int
        switch timeSig.denominator {
        case 8: ticksPerBeat = ticksPerQuarter / 2
        case 2: ticksPerBeat = ticksPerQuarter * 2
        default: ticksPerBeat = ticksPerQuarter
        }
        let ticksPerBar = timeSig.numerator * ticksPerBeat
        guard ticksPerBar > 0 && ticksPerBeat > 0 else { return 0.5 }

        let posInBar = tick % ticksPerBar
        let beatInBar = posInBar / ticksPerBeat
        let posInBeat = posInBar % ticksPerBeat

        // Beat 1 (downbeat) = strongest.
        if beatInBar == 0 && posInBeat < ticksPerBeat / 8 {
            return 1.0
        }
        // Beat 3 in 4/4 = secondary stress.
        if timeSig.numerator == 4 && beatInBar == 2 && posInBeat < ticksPerBeat / 8 {
            return 0.75
        }
        // Any beat boundary.
        if posInBeat < ticksPerBeat / 8 {
            return 0.5
        }
        // Off-beat (between beats).
        if posInBeat > ticksPerBeat / 4 && posInBeat < ticksPerBeat * 3 / 4 {
            return 0.2
        }

        return 0.35
    }

    /// Leap approach factor: notes reached by upward leaps are stress points.
    private static func leapApproachFactor(index: Int, notes: [PianoRollNote]) -> Double {
        guard index > 0 else { return 0.3 }

        let interval = notes[index].pitch - notes[index - 1].pitch

        // Large upward leap = strong stress.
        if interval >= 7 { return 1.0 }     // fifth or larger
        if interval >= 4 { return 0.7 }     // major third
        if interval >= 2 { return 0.4 }     // whole step
        // Downward approach = less stress.
        if interval <= -7 { return 0.2 }
        if interval < 0 { return 0.3 }

        return 0.35
    }
}
