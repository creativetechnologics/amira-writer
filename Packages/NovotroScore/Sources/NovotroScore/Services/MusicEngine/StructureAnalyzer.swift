import Foundation

// MARK: - StructureAnalyzer

/// Detects song structure (verse, chorus, bridge, etc.) by analyzing phrase
/// similarity patterns using a self-similarity matrix approach.
///
/// For opera, also distinguishes recitative (speech-like, stepwise) from
/// aria (lyrical, wider intervals, melismatic).
enum StructureAnalyzer {

    // MARK: - Public API

    /// Analyze the structure of a song from its detected phrases.
    ///
    /// Returns labeled `SongSection` objects with type, tick range, and confidence.
    static func analyze(
        phrases: [MusicalPhrase],
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int
    ) -> [SongSection] {
        guard phrases.count >= 2 else {
            if let phrase = phrases.first {
                return [SongSection(
                    type: classifyAsOperaType(phrase: phrase, notes: notesInPhrase(phrase, allNotes: notes), ticksPerQuarter: ticksPerQuarter),
                    startTick: phrase.startTick,
                    endTick: phrase.endTick,
                    phraseIDs: [phrase.id],
                    confidence: 0.5,
                    label: "Section 1"
                )]
            }
            return []
        }

        let tpq = max(1, ticksPerQuarter)
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        // Step 1: Compute feature vectors for each phrase.
        let features = phrases.map { phrase in
            phraseFeatures(phrase: phrase, notesByID: notesByID, ticksPerQuarter: tpq)
        }

        // Step 2: Build self-similarity matrix.
        let similarityMatrix = buildSimilarityMatrix(features: features)

        // Step 3: Cluster similar phrases into groups.
        let groups = clusterPhrases(similarityMatrix: similarityMatrix, threshold: 0.75)

        // Step 4: Label sections from phrase groups.
        let sections = labelSections(
            groups: groups,
            phrases: phrases,
            notes: notes,
            tempoEvents: tempoEvents,
            ticksPerQuarter: tpq
        )

        return sections
    }

    // MARK: - Feature Extraction

    /// 36-dimensional feature vector for a phrase.
    ///
    /// - 12 dimensions: normalized pitch class histogram
    /// - 8 dimensions: quantized rhythm pattern (inter-onset intervals)
    /// - 3 dimensions: duration stats (mean, variance, max)
    /// - 1 dimension: phrase length in beats
    /// - 4 dimensions: melodic contour (ascending ratio, descending ratio, leap ratio, mean interval)
    /// - 4 dimensions: pitch register (mean pitch, pitch range, min pitch, max pitch — normalized)
    /// - 4 dimensions: interval histogram (unison/step, third, fourth/fifth, larger — normalized)
    private static let featureDimCount = 36

    private static func phraseFeatures(
        phrase: MusicalPhrase,
        notesByID: [UUID: PianoRollNote],
        ticksPerQuarter: Int
    ) -> [Double] {
        let phraseNotes = phrase.noteIDs.compactMap { notesByID[$0] }
            .sorted { $0.startTick < $1.startTick }

        guard !phraseNotes.isEmpty else {
            return Array(repeating: 0, count: featureDimCount)
        }

        // Pitch class histogram (12 bins), weighted by duration.
        var pitchHist = Array(repeating: 0.0, count: 12)
        var totalDuration = 0.0
        for note in phraseNotes {
            let pc = note.pitch % 12
            pitchHist[pc] += Double(note.duration)
            totalDuration += Double(note.duration)
        }
        if totalDuration > 0 {
            for i in 0..<12 { pitchHist[i] /= totalDuration }
        }

        // Rhythm pattern: quantize inter-onset intervals to fractions of a beat.
        // Use up to 8 IOI values, padded with zeros.
        var iois = [Double]()
        for i in 1..<phraseNotes.count {
            let ioi = Double(phraseNotes[i].startTick - phraseNotes[i - 1].startTick)
            let quantized = (ioi / Double(ticksPerQuarter)).rounded(.toNearestOrEven)
            iois.append(min(4.0, quantized))  // cap at 4 beats
        }
        // Pad or truncate to 8 values.
        var rhythmFeatures = Array(repeating: 0.0, count: 8)
        for i in 0..<min(8, iois.count) {
            rhythmFeatures[i] = iois[i] / 4.0  // normalize to [0, 1]
        }

        // Duration stats: mean, variance, max (normalized by quarter note).
        let durations = phraseNotes.map { Double($0.duration) / Double(ticksPerQuarter) }
        let meanDur = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        let varianceDur = durations.isEmpty ? 0 : durations.map { ($0 - meanDur) * ($0 - meanDur) }.reduce(0, +) / Double(durations.count)
        let maxDur = durations.max() ?? 0
        let durationFeatures = [
            min(1.0, meanDur / 4.0),
            min(1.0, varianceDur.squareRoot() / 2.0),
            min(1.0, maxDur / 8.0)
        ]

        // Phrase length in beats, normalized.
        let lengthBeats = Double(phrase.endTick - phrase.startTick) / Double(ticksPerQuarter)
        let lengthFeature = [min(1.0, lengthBeats / 32.0)]

        // Melodic contour features — capture the SHAPE of the melody, not just pitch classes.
        let pitches = phraseNotes.map(\.pitch)
        var ascending = 0, descending = 0, leapCount = 0
        var totalInterval = 0.0
        // Interval histogram: [unison/step (0-2), third (3-4), fourth/fifth (5-7), larger (8+)]
        var intervalBins = [0.0, 0.0, 0.0, 0.0]

        if pitches.count >= 2 {
            for i in 1..<pitches.count {
                let interval = pitches[i] - pitches[i - 1]
                let absInterval = abs(interval)
                totalInterval += Double(absInterval)
                if interval > 0 { ascending += 1 }
                else if interval < 0 { descending += 1 }
                if absInterval > 4 { leapCount += 1 }

                // Bin the interval
                switch absInterval {
                case 0...2: intervalBins[0] += 1
                case 3...4: intervalBins[1] += 1
                case 5...7: intervalBins[2] += 1
                default:    intervalBins[3] += 1
                }
            }
            let intervalCount = Double(pitches.count - 1)
            let totalBins = intervalBins.reduce(0, +)
            if totalBins > 0 {
                for i in 0..<4 { intervalBins[i] /= totalBins }
            }

            let contourFeatures = [
                Double(ascending) / intervalCount,      // ascending ratio
                Double(descending) / intervalCount,     // descending ratio
                Double(leapCount) / intervalCount,      // leap ratio
                min(1.0, totalInterval / intervalCount / 12.0)  // mean interval (normalized to octave)
            ]

            // Pitch register features — where on the keyboard this phrase lives.
            let minPitch = Double(pitches.min() ?? 0)
            let maxPitch = Double(pitches.max() ?? 127)
            let meanPitch = Double(pitches.reduce(0, +)) / Double(pitches.count)
            let registerFeatures = [
                meanPitch / 127.0,                      // mean pitch (normalized to MIDI range)
                (maxPitch - minPitch) / 48.0,           // pitch range (normalized to 4 octaves)
                minPitch / 127.0,                       // lowest note
                maxPitch / 127.0                        // highest note
            ]

            return pitchHist + rhythmFeatures + durationFeatures + lengthFeature + contourFeatures + registerFeatures + intervalBins
        } else {
            // Single note phrase — zero contour/register features.
            let singlePitch = Double(pitches[0]) / 127.0
            let contourFeatures = [0.0, 0.0, 0.0, 0.0]
            let registerFeatures = [singlePitch, 0.0, singlePitch, singlePitch]
            let intervalBinsZero = [0.0, 0.0, 0.0, 0.0]
            return pitchHist + rhythmFeatures + durationFeatures + lengthFeature + contourFeatures + registerFeatures + intervalBinsZero
        }
    }

    // MARK: - Similarity Matrix

    /// Build a cosine similarity matrix between all phrase feature vectors.
    private static func buildSimilarityMatrix(features: [[Double]]) -> [[Double]] {
        let n = features.count
        var matrix = Array(repeating: Array(repeating: 0.0, count: n), count: n)

        for i in 0..<n {
            matrix[i][i] = 1.0
            for j in (i + 1)..<n {
                let sim = cosineSimilarity(features[i], features[j])
                matrix[i][j] = sim
                matrix[j][i] = sim
            }
        }

        return matrix
    }

    /// Cosine similarity between two feature vectors.
    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Clustering

    /// Cluster phrases into groups by greedy similarity-based grouping.
    ///
    /// Returns an array where each element is a group of phrase indices that
    /// are mutually similar above the threshold.
    private static func clusterPhrases(
        similarityMatrix: [[Double]],
        threshold: Double
    ) -> [[Int]] {
        let n = similarityMatrix.count
        var assigned = Array(repeating: false, count: n)
        var groups: [[Int]] = []

        for i in 0..<n {
            if assigned[i] { continue }

            var group = [i]
            assigned[i] = true

            for j in (i + 1)..<n {
                if assigned[j] { continue }
                // Check similarity with the first member (centroid-like).
                if similarityMatrix[i][j] >= threshold {
                    // Verify similarity with all existing members.
                    let allSimilar = group.allSatisfy { memberIdx in
                        similarityMatrix[memberIdx][j] >= threshold * 0.8
                    }
                    if allSimilar {
                        group.append(j)
                        assigned[j] = true
                    }
                }
            }

            groups.append(group)
        }

        return groups
    }

    // MARK: - Section Labeling

    /// Label sections based on phrase group patterns.
    private static func labelSections(
        groups: [[Int]],
        phrases: [MusicalPhrase],
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint],
        ticksPerQuarter: Int
    ) -> [SongSection] {
        guard !groups.isEmpty else { return [] }

        // Sort groups by the first phrase index in each group (order of appearance).
        let sortedGroups = groups.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }

        // Count repetitions: repeating groups are candidates for verse/chorus.
        let groupSizes = sortedGroups.map(\.count)

        // Find the most-repeated group (likely chorus) and the first repeated group (likely verse).
        var verseGroupIdx: Int?
        var chorusGroupIdx: Int?

        // Groups that repeat at least twice.
        let repeatingGroups = sortedGroups.enumerated().filter { $0.element.count >= 2 }

        if repeatingGroups.count >= 2 {
            // First repeating group = verse, most-repeated = chorus.
            verseGroupIdx = repeatingGroups[0].offset
            chorusGroupIdx = repeatingGroups.max(by: { $0.element.count < $1.element.count })?.offset
            // If they're the same, chorus is the second repeating group.
            if verseGroupIdx == chorusGroupIdx && repeatingGroups.count > 1 {
                chorusGroupIdx = repeatingGroups[1].offset
            }
        } else if repeatingGroups.count == 1 {
            // Only one repeating group — could be verse or chorus.
            // If it appears more than twice, likely chorus.
            let rg = repeatingGroups[0]
            if rg.element.count >= 3 {
                chorusGroupIdx = rg.offset
            } else {
                verseGroupIdx = rg.offset
            }
        }

        // Precompute tempo change tick positions for forced section breaks.
        let sortedTempoTicks = tempoEvents
            .sorted { $0.tick < $1.tick }
            .map(\.tick)

        // Build sections by iterating through phrases in order.
        var sections: [SongSection] = []
        var phraseToGroup: [Int: Int] = [:] // phraseIndex -> groupIndex
        for (gi, group) in sortedGroups.enumerated() {
            for pi in group {
                phraseToGroup[pi] = gi
            }
        }

        // Track verse/chorus counters for labeling.
        var verseCounts: [Int: Int] = [:] // groupIdx -> count
        var sectionPhrases: [(groupIdx: Int, phraseIndices: [Int])] = []

        // Group consecutive phrases that belong to the same group into sections,
        // BUT force a section break when:
        //   (a) the cluster changes, OR
        //   (b) there's a large gap between phrases (>= 4 beats), OR
        //   (c) a tempo change occurs between two consecutive phrases.
        let gapBreakThresholdTicks = ticksPerQuarter * 4  // 4 beats = 1 bar in 4/4

        var currentGroupIdx: Int?
        var currentPhraseIndices: [Int] = []

        for pi in 0..<phrases.count {
            let gi = phraseToGroup[pi] ?? -1

            var forceBreak = false

            // Check forced breaks only when we already have phrases accumulated.
            if !currentPhraseIndices.isEmpty {
                guard let prevPhraseIdx = currentPhraseIndices.last else { continue }
                let prevPhrase = phrases[prevPhraseIdx]
                let currPhrase = phrases[pi]

                // (a) Cluster change
                if gi != currentGroupIdx {
                    forceBreak = true
                }

                // (b) Large gap between phrases
                let gap = currPhrase.startTick - prevPhrase.endTick
                if gap >= gapBreakThresholdTicks {
                    forceBreak = true
                }

                // (c) Tempo change between the two phrases
                if !forceBreak {
                    for tempoTick in sortedTempoTicks {
                        if tempoTick > prevPhrase.endTick && tempoTick <= currPhrase.startTick {
                            forceBreak = true
                            break
                        }
                        if tempoTick > currPhrase.startTick { break }
                    }
                }
            }

            if forceBreak {
                sectionPhrases.append((groupIdx: currentGroupIdx ?? -1, phraseIndices: currentPhraseIndices))
                currentGroupIdx = gi
                currentPhraseIndices = [pi]
            } else {
                if currentGroupIdx == nil { currentGroupIdx = gi }
                currentPhraseIndices.append(pi)
            }
        }
        if !currentPhraseIndices.isEmpty {
            sectionPhrases.append((groupIdx: currentGroupIdx ?? -1, phraseIndices: currentPhraseIndices))
        }

        // Label each section.
        for (si, sp) in sectionPhrases.enumerated() {
            let sectionPhrasesData = sp.phraseIndices.map { phrases[$0] }
            guard let firstPhrase = sectionPhrasesData.first,
                  let lastPhrase = sectionPhrasesData.last else { continue }
            let phraseIDs = sectionPhrasesData.map(\.id)

            // Determine section type.
            let sType: SectionType
            let confidence: Double
            let label: String

            if si == 0 && sp.phraseIndices.count <= 2 && sp.groupIdx != verseGroupIdx && sp.groupIdx != chorusGroupIdx {
                // Short opening section that isn't verse or chorus → intro.
                sType = .intro
                confidence = 0.7
                label = "Intro"
            } else if si == sectionPhrases.count - 1 && sp.phraseIndices.count <= 2 && sp.groupIdx != verseGroupIdx && sp.groupIdx != chorusGroupIdx {
                // Short closing section → outro.
                sType = .outro
                confidence = 0.7
                label = "Outro"
            } else if sp.groupIdx == verseGroupIdx {
                let count = (verseCounts[sp.groupIdx] ?? 0) + 1
                verseCounts[sp.groupIdx] = count
                sType = .verse
                confidence = 0.8
                label = "Verse \(count)"
            } else if sp.groupIdx == chorusGroupIdx {
                sType = .chorus
                confidence = 0.85
                label = "Chorus"
            } else if groupSizes.indices.contains(sp.groupIdx) && groupSizes[sp.groupIdx] == 1 {
                // Non-repeating, single occurrence.
                // Check if it's between verse and chorus → bridge.
                let prevIsVerse = si > 0 && sectionPhrases[si - 1].groupIdx == verseGroupIdx
                let nextIsChorus = si + 1 < sectionPhrases.count && sectionPhrases[si + 1].groupIdx == chorusGroupIdx
                if prevIsVerse || nextIsChorus {
                    sType = .bridge
                    confidence = 0.65
                    label = "Bridge"
                } else {
                    // Check opera-specific types.
                    let operaType = classifyAsOperaType(
                        phrase: firstPhrase,
                        notes: sp.phraseIndices.flatMap { pi in
                            notesInPhrase(phrases[pi], allNotes: notes)
                        },
                        ticksPerQuarter: ticksPerQuarter
                    )
                    sType = operaType
                    confidence = 0.5
                    label = operaType.rawValue.capitalized
                }
            } else {
                // Repeating but not verse or chorus.
                sType = .unknown
                confidence = 0.4
                label = "Section"
            }

            sections.append(SongSection(
                type: sType,
                startTick: firstPhrase.startTick,
                endTick: lastPhrase.endTick,
                phraseIDs: phraseIDs,
                confidence: confidence,
                label: label
            ))
        }

        return sections
    }

    // MARK: - Opera-Specific Classification

    /// Classify a phrase as recitative, aria, or instrumental based on musical features.
    ///
    /// - **Recitative**: Mostly stepwise motion (intervals ≤ 2), varied rhythm, speech-like.
    /// - **Aria**: Wider intervals, longer notes, more melismatic.
    /// - **Instrumental**: No vocal track association (future enhancement).
    static func classifyAsOperaType(
        phrase: MusicalPhrase,
        notes: [PianoRollNote],
        ticksPerQuarter: Int
    ) -> SectionType {
        guard notes.count >= 3 else { return .unknown }

        let sorted = notes.sorted { $0.startTick < $1.startTick }

        // Compute interval distribution.
        var stepwise = 0   // intervals ≤ 2 semitones
        var leaps = 0      // intervals > 4 semitones
        for i in 1..<sorted.count {
            let interval = abs(sorted[i].pitch - sorted[i - 1].pitch)
            if interval <= 2 { stepwise += 1 }
            if interval > 4 { leaps += 1 }
        }
        let intervalCount = max(1, sorted.count - 1)
        let stepwiseRatio = Double(stepwise) / Double(intervalCount)
        let leapRatio = Double(leaps) / Double(intervalCount)

        // Compute duration variance (normalized).
        let durations = sorted.map { Double($0.duration) / Double(max(1, ticksPerQuarter)) }
        let meanDur = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        let variance = durations.isEmpty ? 0 : durations.map { ($0 - meanDur) * ($0 - meanDur) }.reduce(0, +) / Double(durations.count)
        let cv = meanDur > 0 ? variance.squareRoot() / meanDur : 0  // coefficient of variation

        // Recitative: mostly stepwise, high rhythmic variance (speech-like).
        if stepwiseRatio > 0.65 && cv > 0.4 {
            return .recitative
        }

        // Aria: wider intervals, longer average notes, lower rhythmic variance.
        if leapRatio > 0.2 && meanDur > 0.8 {
            return .aria
        }

        return .unknown
    }

    // MARK: - Helpers

    /// Extract notes belonging to a phrase from the full note array.
    static func notesInPhrase(_ phrase: MusicalPhrase, allNotes: [PianoRollNote]) -> [PianoRollNote] {
        let ids = Set(phrase.noteIDs)
        return allNotes.filter { ids.contains($0.id) }
    }
}
