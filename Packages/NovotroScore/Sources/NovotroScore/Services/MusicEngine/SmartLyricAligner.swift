import Foundation

// MARK: - SmartLyricAligner

/// Enhanced lyric-to-note alignment with phrase-awareness, structural analysis,
/// and melodic contour matching.
///
/// Wraps the existing `LyricAligner` — calls it internally for per-phrase alignment,
/// then applies post-processing to improve results based on musical structure.
///
/// **Algorithm**:
/// 1. Detect musical phrases via `PhraseDetector`
/// 2. Compute melodic stress suitability via `MelodicContourAnalyzer`
/// 3. Split lyrics at line breaks into "lyric phrases"
/// 4. Optimal DP-based partition matches lyric phrases to musical phrases
/// 5. Align strictly within each matched group using `LyricAligner`
/// 6. Post-process to improve stress-syllable correlation
@available(macOS 26.0, *)
enum SmartLyricAligner {

    // MARK: - Public API

    /// Perform smart alignment of lyrics to notes with structural awareness.
    ///
    /// - Parameters:
    ///   - syllabifiedWords: Output of `SyllabificationService.syllabify()`.
    ///   - notes: All notes (will be filtered to vocal track if `vocalTrackIndices` provided).
    ///   - tempoEvents: Tempo map for the song.
    ///   - timeSignatures: Time signature events.
    ///   - ticksPerQuarter: MIDI division.
    ///   - lyricText: Raw lyrics text with line breaks preserved (from `extractLyrics`).
    ///   - vocalTrackIndices: If provided, only align notes from these tracks.
    ///   - config: Alignment configuration.
    static func align(
        syllabifiedWords: [(word: String, syllables: [String])],
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int,
        lyricText: String? = nil,
        vocalTrackIndices: Set<Int>? = nil,
        config: SmartAlignmentConfig = .init()
    ) -> SmartAlignmentResult {
        let tpq = max(1, ticksPerQuarter)

        // Filter to vocal notes if specified.
        let targetNotes: [PianoRollNote]
        if let tracks = vocalTrackIndices {
            targetNotes = notes.filter { tracks.contains($0.trackIndex) }
                .sorted { $0.startTick < $1.startTick }
        } else {
            targetNotes = notes.sorted { $0.startTick < $1.startTick }
        }

        guard !targetNotes.isEmpty && !syllabifiedWords.isEmpty else {
            return SmartAlignmentResult(
                assignments: [],
                unmatchedSyllables: syllabifiedWords.flatMap(\.syllables),
                unmatchedNotes: targetNotes.map(\.id),
                confidence: 0,
                phraseBreakAlignments: 0,
                contourScore: 0,
                fitWarnings: []
            )
        }

        // Step 1: Detect musical phrases.
        let phrases = PhraseDetector.detectPhrases(
            notes: targetNotes,
            tempoEvents: tempoEvents,
            timeSignatures: timeSignatures,
            ticksPerQuarter: tpq
        )

        // Step 2: Compute stress suitability if contour awareness is enabled.
        let stressScores: [UUID: Double]
        if config.useContourAwareness {
            stressScores = MelodicContourAnalyzer.stressSuitability(
                notes: targetNotes,
                timeSignatures: timeSignatures,
                ticksPerQuarter: tpq
            )
        } else {
            stressScores = [:]
        }

        // Step 3: Split lyrics into lyric phrases at line breaks.
        let lyricPhrases = splitLyricsIntoPhrases(
            syllabifiedWords: syllabifiedWords,
            lyricText: lyricText
        )

        // Step 4: Match lyric phrases to musical phrases via DP and align within each.
        let (phraseAlignments, phraseBreakAlignments) = alignByPhrases(
            lyricPhrases: lyricPhrases,
            musicalPhrases: phrases,
            allNotes: targetNotes,
            ticksPerQuarter: tpq
        )

        // Step 5: Compute fit warnings using the same DP partition.
        let partition = optimalPhrasePartition(
            lyricPhrases: lyricPhrases,
            musicalPhrases: phrases,
            allNotes: targetNotes
        )
        let fitWarnings = computeFitWarnings(partition: partition)

        // Compute confidence and contour score.
        let matchedCount = phraseAlignments.filter { $0.syllable != "_" }.count
        let totalItems = max(targetNotes.count, syllabifiedWords.reduce(0) { $0 + $1.syllables.count })
        let coverage = totalItems > 0 ? Double(matchedCount) / Double(totalItems) : 0
        let contourScore = computeContourScore(
            assignments: phraseAlignments,
            stressScores: stressScores,
            syllabifiedWords: syllabifiedWords
        )

        let confidence = coverage * 0.50 + contourScore * 0.20 + Double(phraseBreakAlignments) / Double(max(1, lyricPhrases.count)) * 0.30

        // Collect unmatched.
        let assignedSyllableCount = phraseAlignments.filter { $0.syllable != "_" }.count
        let totalSyllableCount = syllabifiedWords.reduce(0) { $0 + $1.syllables.count }
        let unmatchedSyllables = assignedSyllableCount < totalSyllableCount
            ? Array(repeating: "", count: totalSyllableCount - assignedSyllableCount) // placeholder
            : []
        let assignedNoteIDs = Set(phraseAlignments.map(\.noteID))
        let unmatchedNotes = targetNotes.filter { !assignedNoteIDs.contains($0.id) }.map(\.id)

        return SmartAlignmentResult(
            assignments: phraseAlignments,
            unmatchedSyllables: unmatchedSyllables,
            unmatchedNotes: unmatchedNotes,
            confidence: min(1.0, max(0.0, confidence)),
            phraseBreakAlignments: phraseBreakAlignments,
            contourScore: contourScore,
            fitWarnings: fitWarnings
        )
    }

    /// Match lyric phrases to musical phrases without performing alignment.
    ///
    /// Returns the optimal DP-based partition that minimizes syllable/note mismatch
    /// across all groups. Useful for the Fit MIDI flow and for testing.
    ///
    /// - Parameters:
    ///   - syllabifiedWords: Output of `SyllabificationService.syllabify()`.
    ///   - lyricText: Raw lyrics with line breaks for phrase splitting.
    ///   - notes: All target notes (sorted by startTick).
    ///   - tempoEvents: Tempo map.
    ///   - timeSignatures: Time signature events.
    ///   - ticksPerQuarter: MIDI division.
    /// - Returns: Array of `PhraseMatch` describing how lyric phrases map to musical phrases.
    static func matchPhrases(
        syllabifiedWords: [(word: String, syllables: [String])],
        lyricText: String?,
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int
    ) -> [PhraseMatch] {
        let tpq = max(1, ticksPerQuarter)
        let sorted = notes.sorted { $0.startTick < $1.startTick }

        let phrases = PhraseDetector.detectPhrases(
            notes: sorted,
            tempoEvents: tempoEvents,
            timeSignatures: timeSignatures,
            ticksPerQuarter: tpq
        )

        let lyricPhrases = splitLyricsIntoPhrases(
            syllabifiedWords: syllabifiedWords,
            lyricText: lyricText
        )

        return optimalPhrasePartition(
            lyricPhrases: lyricPhrases,
            musicalPhrases: phrases,
            allNotes: sorted
        )
    }

    // MARK: - Elastic Alignment

    /// Perform smart alignment using elastic syllable counts.
    ///
    /// Like `align(syllabifiedWords:...)`, but words with uncertain syllable counts
    /// (e.g., "fire" 1-2 syl, "every" 2-3 syl) are compressed or expanded per phrase
    /// to best match the note count before the DP aligner runs.
    ///
    /// Strategy per phrase group:
    /// - If notes < preferred syllables: compress most-uncertain words first
    /// - If notes > preferred syllables: expand most-uncertain words first
    /// - This reduces melisma need and eliminates unnecessary MelodicMutator calls
    static func align(
        elasticWords: [ElasticWord],
        notes: [PianoRollNote],
        tempoEvents: [TempoPoint],
        timeSignatures: [TimeSignatureEvent],
        ticksPerQuarter: Int,
        lyricText: String? = nil,
        vocalTrackIndices: Set<Int>? = nil,
        config: SmartAlignmentConfig = .init()
    ) -> SmartAlignmentResult {
        let tpq = max(1, ticksPerQuarter)

        // Filter to vocal notes if specified.
        let targetNotes: [PianoRollNote]
        if let tracks = vocalTrackIndices {
            targetNotes = notes.filter { tracks.contains($0.trackIndex) }
                .sorted { $0.startTick < $1.startTick }
        } else {
            targetNotes = notes.sorted { $0.startTick < $1.startTick }
        }

        // Convert to standard format for empty checks.
        let standardWords = elasticWords.map { ew in
            (word: ew.word, syllables: ew.syllableVariants[ew.range.preferred] ?? [ew.word])
        }

        guard !targetNotes.isEmpty && !elasticWords.isEmpty else {
            return SmartAlignmentResult(
                assignments: [],
                unmatchedSyllables: standardWords.flatMap(\.syllables),
                unmatchedNotes: targetNotes.map(\.id),
                confidence: 0,
                phraseBreakAlignments: 0,
                contourScore: 0,
                fitWarnings: []
            )
        }

        // Step 1: Detect musical phrases.
        let phrases = PhraseDetector.detectPhrases(
            notes: targetNotes,
            tempoEvents: tempoEvents,
            timeSignatures: timeSignatures,
            ticksPerQuarter: tpq
        )

        // Step 2: Compute stress suitability.
        let stressScores: [UUID: Double]
        if config.useContourAwareness {
            stressScores = MelodicContourAnalyzer.stressSuitability(
                notes: targetNotes,
                timeSignatures: timeSignatures,
                ticksPerQuarter: tpq
            )
        } else {
            stressScores = [:]
        }

        // Step 3: Split elastic words into lyric phrases at line breaks.
        let elasticPhrases = splitElasticWordsIntoPhrases(
            elasticWords: elasticWords,
            lyricText: lyricText
        )

        // Step 4: Build syllable counts for the DP partition (use preferred counts).
        let lyricPhrasesStandard: [[(word: String, syllables: [String])]] = elasticPhrases.map { ep in
            ep.map { ew in (word: ew.word, syllables: ew.syllableVariants[ew.range.preferred] ?? [ew.word]) }
        }

        // Step 5: Get the optimal phrase partition.
        let partition = optimalPhrasePartition(
            lyricPhrases: lyricPhrasesStandard,
            musicalPhrases: phrases,
            allNotes: targetNotes
        )

        // Step 6: For each partition group, resolve elastic counts then align.
        let notesByID = Dictionary(uniqueKeysWithValues: targetNotes.map { ($0.id, $0) })
        var allAssignments: [SmartAlignmentResult.Assignment] = []
        var phraseBreakAlignments = 0

        for match in partition {
            // Gather elastic words for this group.
            let groupElasticWords = match.lyricPhraseIndices.flatMap { elasticPhrases[$0] }

            // Gather notes for this group.
            let groupNotes = match.musicalPhraseIndices.flatMap { phrases[$0].noteIDs }
                .compactMap { notesByID[$0] }
                .sorted { $0.startTick < $1.startTick }

            guard !groupNotes.isEmpty else { continue }

            // Resolve elastic counts to best match note count.
            let resolvedWords = resolveElasticCounts(
                words: groupElasticWords,
                targetNoteCount: groupNotes.count
            )

            // Run LyricAligner within this phrase group (strict boundary).
            let localResult = LyricAligner.align(
                syllabifiedWords: resolvedWords,
                notes: groupNotes,
                ticksPerQuarter: tpq
            )

            for (noteID, syllable) in localResult.assignments {
                allAssignments.append(SmartAlignmentResult.Assignment(
                    noteID: noteID,
                    syllable: syllable,
                    phraseID: nil
                ))
            }

            // Count phrase-break alignment: if the first word of a lyric phrase
            // lands on the first note of a musical phrase, it's a good match.
            if match.lyricPhraseIndices.count == 1 && match.musicalPhraseIndices.count == 1 {
                phraseBreakAlignments += 1
            }
        }

        // Step 7: Compute fit warnings.
        let fitWarnings = computeFitWarnings(partition: partition)

        // Compute confidence and contour score.
        let matchedCount = allAssignments.filter { $0.syllable != "_" }.count
        let totalSylCount = standardWords.reduce(0) { $0 + $1.syllables.count }
        let totalItems = max(targetNotes.count, totalSylCount)
        let coverage = totalItems > 0 ? Double(matchedCount) / Double(totalItems) : 0
        let contourScore = computeContourScore(
            assignments: allAssignments,
            stressScores: stressScores,
            syllabifiedWords: standardWords
        )

        let confidence = coverage * 0.50 + contourScore * 0.20
            + Double(phraseBreakAlignments) / Double(max(1, elasticPhrases.count)) * 0.30

        // Collect unmatched.
        let assignedNoteIDs = Set(allAssignments.map(\.noteID))
        let unmatchedNotes = targetNotes.filter { !assignedNoteIDs.contains($0.id) }.map(\.id)
        let unmatchedSyllables = matchedCount < totalSylCount
            ? Array(repeating: "", count: totalSylCount - matchedCount)
            : []

        return SmartAlignmentResult(
            assignments: allAssignments,
            unmatchedSyllables: unmatchedSyllables,
            unmatchedNotes: unmatchedNotes,
            confidence: min(1.0, max(0.0, confidence)),
            phraseBreakAlignments: phraseBreakAlignments,
            contourScore: contourScore,
            fitWarnings: fitWarnings
        )
    }

    /// Resolve elastic syllable counts to best match a target note count.
    ///
    /// Strategy:
    /// 1. Start with each word's preferred count → compute total
    /// 2. If total > target: compress most-uncertain (elastic) words first (min certainty)
    /// 3. If total < target: expand most-uncertain words first
    /// 4. Return resolved `(word, syllables)` tuples for `LyricAligner`
    static func resolveElasticCounts(
        words: [ElasticWord],
        targetNoteCount: Int
    ) -> [(word: String, syllables: [String])] {
        guard !words.isEmpty else { return [] }

        // Start with preferred counts.
        var chosenCounts = words.map { $0.range.preferred }
        var total = chosenCounts.reduce(0, +)

        if total > targetNoteCount {
            // Need to compress — sort elastic word indices by certainty ascending
            // (most uncertain = most compressible first).
            let elasticIndices = words.indices.filter { words[$0].range.isElastic }
                .sorted { words[$0].range.certainty < words[$1].range.certainty }

            for idx in elasticIndices {
                guard total > targetNoteCount else { break }
                let currentCount = chosenCounts[idx]
                let minCount = words[idx].range.min
                if currentCount > minCount {
                    let reduction = min(currentCount - minCount, total - targetNoteCount)
                    chosenCounts[idx] -= reduction
                    total -= reduction
                }
            }
        } else if total < targetNoteCount {
            // Need to expand — sort elastic word indices by certainty ascending.
            let elasticIndices = words.indices.filter { words[$0].range.isElastic }
                .sorted { words[$0].range.certainty < words[$1].range.certainty }

            for idx in elasticIndices {
                guard total < targetNoteCount else { break }
                let currentCount = chosenCounts[idx]
                let maxCount = words[idx].range.max
                if currentCount < maxCount {
                    let expansion = min(maxCount - currentCount, targetNoteCount - total)
                    chosenCounts[idx] += expansion
                    total += expansion
                }
            }
        }

        // Build resolved word tuples.
        return zip(words, chosenCounts).map { ew, count in
            let syllables = ew.syllableVariants[count]
                ?? ew.syllableVariants[ew.range.preferred]
                ?? [ew.word]
            return (word: ew.word, syllables: syllables)
        }
    }

    /// Split elastic words into per-line phrase groups based on lyric text line breaks.
    static func splitElasticWordsIntoPhrases(
        elasticWords: [ElasticWord],
        lyricText: String?
    ) -> [[ElasticWord]] {
        guard let text = lyricText, text.contains("\n") else {
            return [elasticWords]
        }

        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else {
            return [elasticWords]
        }

        var result: [[ElasticWord]] = []
        var wordIdx = 0

        for line in lines {
            let lineWords = line.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }

            var lineGroup: [ElasticWord] = []
            var matchedCount = 0

            while wordIdx < elasticWords.count && matchedCount < lineWords.count {
                lineGroup.append(elasticWords[wordIdx])
                matchedCount += 1
                wordIdx += 1
            }

            if !lineGroup.isEmpty {
                result.append(lineGroup)
            }
        }

        // Any remaining words go into the last phrase.
        if wordIdx < elasticWords.count {
            let remaining = Array(elasticWords[wordIdx...])
            if result.isEmpty {
                result.append(remaining)
            } else {
                result[result.count - 1].append(contentsOf: remaining)
            }
        }

        return result.filter { !$0.isEmpty }
    }

    // MARK: - Lyric Phrase Splitting

    /// Split syllabified words into per-line groups based on the original lyric text's line breaks.
    static func splitLyricsIntoPhrases(
        syllabifiedWords: [(word: String, syllables: [String])],
        lyricText: String?
    ) -> [[(word: String, syllables: [String])]] {
        guard let text = lyricText, text.contains("\n") else {
            // No line breaks — treat all words as one phrase.
            return [syllabifiedWords]
        }

        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else {
            return [syllabifiedWords]
        }

        // Match words to lines by walking through both arrays.
        var result: [[(word: String, syllables: [String])]] = []
        var wordIdx = 0

        for line in lines {
            let lineWords = line.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }

            var lineGroup: [(word: String, syllables: [String])] = []
            var matchedCount = 0

            while wordIdx < syllabifiedWords.count && matchedCount < lineWords.count {
                lineGroup.append(syllabifiedWords[wordIdx])
                matchedCount += 1
                wordIdx += 1
            }

            if !lineGroup.isEmpty {
                result.append(lineGroup)
            }
        }

        // Any remaining words go into the last phrase.
        if wordIdx < syllabifiedWords.count {
            let remaining = Array(syllabifiedWords[wordIdx...])
            if result.isEmpty {
                result.append(remaining)
            } else {
                result[result.count - 1].append(contentsOf: remaining)
            }
        }

        return result.filter { !$0.isEmpty }
    }

    // MARK: - DP-Based Optimal Phrase Partition

    /// Find the optimal mapping of lyric phrases to musical phrases using dynamic programming.
    ///
    /// Minimizes total syllable/note count mismatch across all groups. Allows merging
    /// up to `maxMerge` consecutive lyric or musical phrases into a single group.
    ///
    /// - Returns: Array of `PhraseMatch` in order, covering all lyric and musical phrases.
    private static func optimalPhrasePartition(
        lyricPhrases: [[(word: String, syllables: [String])]],
        musicalPhrases: [MusicalPhrase],
        allNotes: [PianoRollNote],
        maxMerge: Int = 4
    ) -> [PhraseMatch] {
        let L = lyricPhrases.count
        let M = musicalPhrases.count

        guard L > 0 && M > 0 else { return [] }

        let notesByID = Dictionary(uniqueKeysWithValues: allNotes.map { ($0.id, $0) })

        // Pre-compute syllable counts per lyric phrase and note counts per musical phrase.
        let sylCounts = lyricPhrases.map { lp in lp.reduce(0) { $0 + $1.syllables.count } }
        let noteCounts = musicalPhrases.map { mp in mp.noteIDs.compactMap { notesByID[$0] }.count }

        // Prefix sums for range queries.
        var sylPrefix = [0]
        for c in sylCounts { sylPrefix.append(sylPrefix.last! + c) }
        var notePrefix = [0]
        for c in noteCounts { notePrefix.append(notePrefix.last! + c) }

        func sylRange(_ from: Int, _ to: Int) -> Int { sylPrefix[to] - sylPrefix[from] }
        func noteRange(_ from: Int, _ to: Int) -> Int { notePrefix[to] - notePrefix[from] }

        /// Cost of grouping lyricPhrases[li..<liEnd] with musicalPhrases[mi..<miEnd].
        func groupCost(li: Int, liEnd: Int, mi: Int, miEnd: Int) -> Double {
            let syls = sylRange(li, liEnd)
            let notes = noteRange(mi, miEnd)
            let maxCount = max(syls, notes)
            guard maxCount > 0 else { return 0 }
            var cost = Double(abs(syls - notes)) / Double(maxCount)
            // Small bonus for 1:1 phrase count matches.
            if (liEnd - li) == 1 && (miEnd - mi) == 1 {
                cost -= 0.05
            }
            return cost
        }

        // DP: dp[i][j] = min cost to match lyricPhrases[0..<i] to musicalPhrases[0..<j].
        let inf = Double.infinity
        var dp = Array(repeating: Array(repeating: inf, count: M + 1), count: L + 1)
        dp[0][0] = 0

        // Parent tracking for backtracking: (prevI, prevJ) for each (i, j).
        var parent = Array(repeating: Array(repeating: (-1, -1), count: M + 1), count: L + 1)

        for i in 0...L {
            for j in 0...M {
                guard dp[i][j] < inf else { continue }
                let base = dp[i][j]

                // Try grouping k lyric phrases with m musical phrases.
                let maxK = min(maxMerge, L - i)
                let maxM = min(maxMerge, M - j)

                for k in 1...max(1, maxK) {
                    guard i + k <= L else { break }
                    for m in 1...max(1, maxM) {
                        guard j + m <= M else { break }
                        let cost = base + groupCost(li: i, liEnd: i + k, mi: j, miEnd: j + m)
                        if cost < dp[i + k][j + m] {
                            dp[i + k][j + m] = cost
                            parent[i + k][j + m] = (i, j)
                        }
                    }
                }
            }
        }

        // Backtrack from dp[L][M].
        guard dp[L][M] < inf else {
            // Fallback: if DP can't find a valid path (shouldn't happen), put everything in one group.
            return [PhraseMatch(
                lyricPhraseIndices: Array(0..<L),
                musicalPhraseIndices: Array(0..<M),
                syllableCount: sylRange(0, L),
                noteCount: noteRange(0, M)
            )]
        }

        var matches: [PhraseMatch] = []
        var ci = L, cj = M
        while ci > 0 || cj > 0 {
            let (pi, pj) = parent[ci][cj]
            if pi < 0 { break }
            matches.append(PhraseMatch(
                lyricPhraseIndices: Array(pi..<ci),
                musicalPhraseIndices: Array(pj..<cj),
                syllableCount: sylRange(pi, ci),
                noteCount: noteRange(pj, cj)
            ))
            ci = pi
            cj = pj
        }

        matches.reverse()
        return matches
    }

    // MARK: - Per-Phrase Alignment

    /// Match lyric phrases to musical phrases via DP partition, then run LyricAligner
    /// strictly within each matched group.
    private static func alignByPhrases(
        lyricPhrases: [[(word: String, syllables: [String])]],
        musicalPhrases: [MusicalPhrase],
        allNotes: [PianoRollNote],
        ticksPerQuarter: Int
    ) -> (assignments: [SmartAlignmentResult.Assignment], phraseBreakAlignments: Int) {
        guard !lyricPhrases.isEmpty && !musicalPhrases.isEmpty else {
            // Fall back to flat alignment.
            let allWords = lyricPhrases.flatMap { $0 }
            let result = LyricAligner.align(
                syllabifiedWords: allWords,
                notes: allNotes,
                ticksPerQuarter: ticksPerQuarter
            )
            let assignments = result.assignments.map {
                SmartAlignmentResult.Assignment(noteID: $0.noteID, syllable: $0.syllable, phraseID: nil)
            }
            return (assignments, 0)
        }

        let notesByID = Dictionary(uniqueKeysWithValues: allNotes.map { ($0.id, $0) })
        let partition = optimalPhrasePartition(
            lyricPhrases: lyricPhrases,
            musicalPhrases: musicalPhrases,
            allNotes: allNotes
        )

        var allAssignments: [SmartAlignmentResult.Assignment] = []
        var phraseBreakCount = 0

        for match in partition {
            // Collect all lyric words in this group.
            let groupWords = match.lyricPhraseIndices.flatMap { lyricPhrases[$0] }

            // Collect all notes from the matched musical phrases.
            var groupNotes: [PianoRollNote] = []
            var groupPhraseIDs: [UUID] = []
            for mi in match.musicalPhraseIndices {
                let mp = musicalPhrases[mi]
                groupPhraseIDs.append(mp.id)
                let notes = mp.noteIDs.compactMap { notesByID[$0] }
                groupNotes.append(contentsOf: notes)
            }
            groupNotes.sort { $0.startTick < $1.startTick }

            guard !groupWords.isEmpty && !groupNotes.isEmpty else { continue }

            // Align strictly within this group's boundaries.
            let result = LyricAligner.align(
                syllabifiedWords: groupWords,
                notes: groupNotes,
                ticksPerQuarter: ticksPerQuarter
            )

            for assignment in result.assignments {
                allAssignments.append(SmartAlignmentResult.Assignment(
                    noteID: assignment.noteID,
                    syllable: assignment.syllable,
                    phraseID: groupPhraseIDs.first
                ))
            }
            phraseBreakCount += 1
        }

        return (allAssignments, phraseBreakCount)
    }

    // MARK: - Fit Warning Detection

    /// Detect phrase groups where syllable count is a poor fit for available note count.
    /// Uses the DP partition to ensure warnings match actual alignment behavior.
    private static func computeFitWarnings(
        partition: [PhraseMatch]
    ) -> [SmartAlignmentResult.FitWarning] {
        var warnings: [SmartAlignmentResult.FitWarning] = []

        for (idx, match) in partition.enumerated() {
            let syls = match.syllableCount
            let notes = match.noteCount

            guard notes > 0 else {
                warnings.append(SmartAlignmentResult.FitWarning(
                    phraseIndex: idx,
                    syllableCount: syls,
                    noteCount: 0,
                    message: "Group \(idx + 1): \(syls) syllables but no matching notes"
                ))
                continue
            }

            let ratio = Double(syls) / Double(notes)
            if ratio > 2.0 {
                warnings.append(SmartAlignmentResult.FitWarning(
                    phraseIndex: idx,
                    syllableCount: syls,
                    noteCount: notes,
                    message: "Group \(idx + 1): \(syls) syllables for \(notes) notes (crowded)"
                ))
            } else if ratio < 0.5 && syls > 0 {
                warnings.append(SmartAlignmentResult.FitWarning(
                    phraseIndex: idx,
                    syllableCount: syls,
                    noteCount: notes,
                    message: "Group \(idx + 1): \(syls) syllables for \(notes) notes (sparse)"
                ))
            }
        }

        return warnings
    }

    // MARK: - Contour Score

    /// Compute how well syllable stress aligns with melodic stress.
    private static func computeContourScore(
        assignments: [SmartAlignmentResult.Assignment],
        stressScores: [UUID: Double],
        syllabifiedWords: [(word: String, syllables: [String])]
    ) -> Double {
        guard !assignments.isEmpty && !stressScores.isEmpty else { return 0.5 }

        var matchCount = 0
        var totalChecked = 0

        // For each assignment, check if word-starts land on high-stress notes.
        for assignment in assignments {
            guard assignment.syllable != "_" else { continue }
            let stress = stressScores[assignment.noteID] ?? 0.5
            let isWordStart = !assignment.syllable.hasSuffix("-")

            totalChecked += 1
            // Word start on high stress, or continuation on low stress = good.
            if (isWordStart && stress >= 0.5) || (!isWordStart && stress < 0.5) {
                matchCount += 1
            }
        }

        return totalChecked > 0 ? Double(matchCount) / Double(totalChecked) : 0.5
    }
}
