import Foundation

// MARK: - KeyDetector

/// Detects the key of a piece using the Krumhansl-Schmuckler key-finding algorithm.
///
/// The algorithm computes a pitch class histogram weighted by note duration, then
/// correlates it (Pearson r) against 24 major/minor key profiles to find the
/// best-fitting key.
///
/// Reference: Krumhansl, C.L. (1990). Cognitive Foundations of Musical Pitch.
enum KeyDetector {

    // MARK: - Public API

    /// Detect the most likely key from a set of MIDI notes.
    ///
    /// - Parameters:
    ///   - notes: Piano roll notes to analyze.
    ///   - ticksPerQuarter: MIDI resolution for duration weighting.
    /// - Returns: The detected key with confidence, or nil if too few notes.
    static func detectKey(
        notes: [PianoRollNote],
        ticksPerQuarter: Int = 480
    ) -> DetectedKey? {
        guard notes.count >= 4 else { return nil }

        let histogram = pitchClassHistogram(notes: notes)

        // Correlate against all 24 key profiles (12 major + 12 minor).
        var bestRoot = 0
        var bestIsMinor = false
        var bestCorrelation = -2.0
        var secondBest = -2.0

        for root in 0..<12 {
            let majorCorr = pearsonCorrelation(histogram, rotatedProfile(majorProfile, by: root))
            if majorCorr > bestCorrelation {
                secondBest = bestCorrelation
                bestCorrelation = majorCorr
                bestRoot = root
                bestIsMinor = false
            } else if majorCorr > secondBest {
                secondBest = majorCorr
            }

            let minorCorr = pearsonCorrelation(histogram, rotatedProfile(minorProfile, by: root))
            if minorCorr > bestCorrelation {
                secondBest = bestCorrelation
                bestCorrelation = minorCorr
                bestRoot = root
                bestIsMinor = true
            } else if minorCorr > secondBest {
                secondBest = minorCorr
            }
        }

        // Confidence: difference between best and second-best correlation,
        // mapped to 0–1 range. A clear winner has high confidence.
        let gap = bestCorrelation - secondBest
        let confidence = min(1.0, max(0.0, gap / 0.4))

        guard bestCorrelation > 0.1 else { return nil }

        return DetectedKey(
            root: bestRoot,
            isMinor: bestIsMinor,
            confidence: confidence
        )
    }

    /// Detect key from an existing key signature event (MIDI metadata).
    ///
    /// Converts `sharpsFlats` (-7..+7) and `isMinor` into a `DetectedKey`.
    static func fromKeySignature(_ keySig: KeySignatureEvent) -> DetectedKey {
        // Circle of fifths: sharpsFlats maps to pitch class.
        // 0 sharps = C major / A minor
        // +1 = G major / E minor, +2 = D major / B minor, etc.
        // -1 = F major / D minor, -2 = Bb major / G minor, etc.
        let majorRoot = ((keySig.sharpsFlats * 7) % 12 + 12) % 12
        let root = keySig.isMinor ? (majorRoot + 9) % 12 : majorRoot

        return DetectedKey(
            root: root,
            isMinor: keySig.isMinor,
            confidence: 1.0  // key signature is authoritative
        )
    }

    /// Detect key using both MIDI key signatures and pitch analysis.
    ///
    /// If a key signature exists and the pitch analysis agrees (or pitch analysis
    /// has low confidence), uses the key signature. Otherwise, uses pitch analysis.
    static func detectKeyWithFallback(
        notes: [PianoRollNote],
        keySignatures: [KeySignatureEvent],
        ticksPerQuarter: Int = 480
    ) -> DetectedKey? {
        let pitchKey = detectKey(notes: notes, ticksPerQuarter: ticksPerQuarter)

        // Find the most relevant key signature (last one before the majority of notes).
        guard let keySig = relevantKeySignature(keySignatures: keySignatures, notes: notes) else {
            return pitchKey
        }

        // If key signature is all-zero (C major / A minor default), prefer pitch analysis.
        if keySig.sharpsFlats == 0 && !keySig.isMinor {
            // Default key sig — could be intentional C major or just unset.
            if let pk = pitchKey, pk.confidence > 0.5 {
                return pk
            }
        }

        let sigKey = fromKeySignature(keySig)

        // If pitch analysis agrees with key signature, boost confidence.
        if let pk = pitchKey {
            if pk.root == sigKey.root && pk.isMinor == sigKey.isMinor {
                return DetectedKey(root: sigKey.root, isMinor: sigKey.isMinor, confidence: min(1.0, pk.confidence + 0.2))
            }
            // Relative major/minor agreement (e.g., C major and A minor share the same scale).
            let relativeRoot = sigKey.isMinor ? (sigKey.root + 3) % 12 : (sigKey.root + 9) % 12
            if pk.root == relativeRoot && pk.isMinor != sigKey.isMinor {
                // Pitch analysis favors relative key — use pitch analysis if confident.
                if pk.confidence > 0.6 { return pk }
            }
            // Disagreement — use key signature if pitch confidence is low.
            if pk.confidence < 0.4 { return sigKey }
            return pk
        }

        return sigKey
    }

    // MARK: - Krumhansl-Schmuckler Key Profiles

    /// Major key profile (Krumhansl-Kessler empirical ratings for C major).
    /// Index 0 = C, 1 = C#, ..., 11 = B.
    private static let majorProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
        2.52, 5.19, 2.39, 3.66, 2.29, 2.88
    ]

    /// Minor key profile (Krumhansl-Kessler empirical ratings for C minor).
    private static let minorProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
        2.54, 4.75, 3.98, 2.69, 3.34, 3.17
    ]

    // MARK: - Histogram & Correlation

    /// Build a duration-weighted pitch class histogram from notes.
    private static func pitchClassHistogram(notes: [PianoRollNote]) -> [Double] {
        var hist = Array(repeating: 0.0, count: 12)
        for note in notes {
            let pc = ((note.pitch % 12) + 12) % 12
            hist[pc] += Double(max(1, note.duration))
        }
        // Normalize to sum = 1.
        let total = hist.reduce(0, +)
        if total > 0 {
            for i in 0..<12 { hist[i] /= total }
        }
        return hist
    }

    /// Rotate a key profile to start from a different root.
    ///
    /// `rotatedProfile(majorProfile, by: 7)` gives G major profile.
    private static func rotatedProfile(_ profile: [Double], by semitones: Int) -> [Double] {
        let n = profile.count
        let shift = ((semitones % n) + n) % n
        return (0..<n).map { profile[((($0 - shift) % n) + n) % n] }
    }

    /// Pearson correlation coefficient between two arrays of equal length.
    private static func pearsonCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n

        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            cov += da * db
            varA += da * da
            varB += db * db
        }

        let denom = (varA * varB).squareRoot()
        return denom > 0 ? cov / denom : 0
    }

    // MARK: - Helpers

    /// Find the most relevant key signature event for the given notes.
    private static func relevantKeySignature(
        keySignatures: [KeySignatureEvent],
        notes: [PianoRollNote]
    ) -> KeySignatureEvent? {
        guard !keySignatures.isEmpty else { return nil }
        if keySignatures.count == 1 { return keySignatures[0] }

        // Use the key signature closest to the median note position.
        let sorted = notes.sorted { $0.startTick < $1.startTick }
        let medianTick = sorted[sorted.count / 2].startTick
        let keySigs = keySignatures.sorted { $0.tick < $1.tick }
        // Find last key sig before or at the median tick.
        return keySigs.last { $0.tick <= medianTick } ?? keySigs.first
    }
}
