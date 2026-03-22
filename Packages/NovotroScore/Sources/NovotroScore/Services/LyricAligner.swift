import Foundation

// MARK: - LyricAligner

/// Aligns syllables to MIDI notes.
///
/// Primary strategy uses a dynamic-programming matcher with phrase-boundary
/// and melisma penalties. For very large inputs, it falls back to a fast
/// heuristic sequential aligner.
@available(macOS 26.0, *)
enum LyricAligner {

    // MARK: - Result

    struct AlignmentResult: Sendable {
        /// Ordered assignments: noteID → syllable text (with trailing hyphens for continuations).
        var assignments: [(noteID: UUID, syllable: String)]

        /// Syllables that couldn't be matched to notes (more lyrics than notes).
        var unmatchedSyllables: [String]

        /// Notes that didn't receive a syllable (more notes than lyrics).
        var unmatchedNotes: [UUID]

        /// Confidence score 0.0–1.0 based on how well syllables and notes aligned.
        var confidence: Double
    }

    // MARK: - Internal Types

    private struct SyllableUnit {
        var text: String
        var isWordStart: Bool
    }

    private struct DPState: Hashable {
        var syllableIndex: Int
        var lastWasMelisma: Bool
    }

    private struct DPParent {
        var previous: DPState
        var assignedText: String
    }

    // MARK: - Public API

    /// Aligns syllables from `SyllabificationService` output to notes.
    static func align(
        syllabifiedWords: [(word: String, syllables: [String])],
        notes: [PianoRollNote],
        ticksPerQuarter: Int
    ) -> AlignmentResult {
        let sortedNotes = notes.sorted { $0.startTick < $1.startTick }
        let tpq = max(1, ticksPerQuarter)
        let units = flattenSyllables(syllabifiedWords)

        guard !sortedNotes.isEmpty && !units.isEmpty else {
            return AlignmentResult(
                assignments: [],
                unmatchedSyllables: units.map(\.text),
                unmatchedNotes: sortedNotes.map(\.id),
                confidence: 0
            )
        }

        let phraseStarts = detectPhraseStarts(notes: sortedNotes, ticksPerQuarter: tpq)

        // Keep runtime bounded on very large inputs.
        let complexity = sortedNotes.count * max(1, units.count)
        if complexity <= 2_500_000,
           let dp = alignDynamicProgramming(units: units, notes: sortedNotes, phraseStarts: phraseStarts, ticksPerQuarter: tpq) {
            return dp
        }

        return alignHeuristic(units: units, notes: sortedNotes, phraseStarts: phraseStarts, ticksPerQuarter: tpq)
    }

    // MARK: - Dynamic Programming Aligner

    private static func alignDynamicProgramming(
        units: [SyllableUnit],
        notes: [PianoRollNote],
        phraseStarts: Set<Int>,
        ticksPerQuarter: Int
    ) -> AlignmentResult? {
        var frontier: [DPState: Double] = [DPState(syllableIndex: 0, lastWasMelisma: false): 0]
        var parents = Array(repeating: [DPState: DPParent](), count: notes.count + 1)

        for noteIdx in notes.indices {
            let note = notes[noteIdx]
            let prevNote = noteIdx > 0 ? notes[noteIdx - 1] : nil
            let isPhraseStart = phraseStarts.contains(noteIdx)
            var next: [DPState: Double] = [:]

            func relax(to state: DPState, cost: Double, parent: DPParent) {
                let existing = next[state] ?? .infinity
                if cost < existing {
                    next[state] = cost
                    parents[noteIdx + 1][state] = parent
                }
            }

            for (state, cost) in frontier {
                let j = state.syllableIndex

                // Transition 1: consume next syllable.
                if j < units.count {
                    let unit = units[j]
                    let remainingNotes = notes.count - (noteIdx + 1)
                    let remainingSylsAfterConsume = units.count - (j + 1)
                    let delta = syllablePenalty(
                        unit: unit,
                        note: note,
                        prevNote: prevNote,
                        isPhraseStart: isPhraseStart,
                        remainingNotes: remainingNotes,
                        remainingSyllables: remainingSylsAfterConsume,
                        ticksPerQuarter: ticksPerQuarter,
                        lastWasMelisma: state.lastWasMelisma
                    )
                    let nextState = DPState(syllableIndex: j + 1, lastWasMelisma: false)
                    relax(
                        to: nextState,
                        cost: cost + delta,
                        parent: DPParent(previous: state, assignedText: unit.text)
                    )
                }

                // Transition 2: melisma extension ("_"), no syllable consumed.
                let remainingNotesIncludingCurrent = notes.count - noteIdx
                let remainingSylsCurrent = units.count - j
                if j > 0 && remainingNotesIncludingCurrent > remainingSylsCurrent {
                    let remainingNotes = notes.count - (noteIdx + 1)
                    let remainingSyls = units.count - j
                    let delta = melismaPenalty(
                        note: note,
                        prevNote: prevNote,
                        isPhraseStart: isPhraseStart,
                        remainingNotes: remainingNotes,
                        remainingSyllables: remainingSyls,
                        ticksPerQuarter: ticksPerQuarter,
                        lastWasMelisma: state.lastWasMelisma
                    )
                    let nextState = DPState(syllableIndex: j, lastWasMelisma: true)
                    relax(
                        to: nextState,
                        cost: cost + delta,
                        parent: DPParent(previous: state, assignedText: "_")
                    )
                }
            }

            if next.isEmpty { return nil }
            frontier = next
        }

        guard !frontier.isEmpty else { return nil }

        var bestState: DPState?
        var bestScore = Double.infinity
        for (state, cost) in frontier {
            let leftover = max(0, units.count - state.syllableIndex)
            let score = cost + Double(leftover) * 1.35
            if score < bestScore {
                bestScore = score
                bestState = state
            }
        }

        guard var state = bestState else { return nil }

        var assignedReversed: [String] = []
        assignedReversed.reserveCapacity(notes.count)
        for step in stride(from: notes.count, to: 0, by: -1) {
            guard let parent = parents[step][state] else { return nil }
            assignedReversed.append(parent.assignedText)
            state = parent.previous
        }

        let assigned = assignedReversed.reversed()
        let assignments = zip(notes, assigned).map { (noteID: $0.id, syllable: $1) }

        let consumedSyllables = bestState?.syllableIndex ?? 0
        let unmatchedSyllables = consumedSyllables < units.count
            ? Array(units[consumedSyllables...].map(\.text))
            : []

        let phraseViolations = assignments.enumerated().filter {
            phraseStarts.contains($0.offset) && $0.element.syllable == "_"
        }.count
        let phraseScore = max(0, 1 - Double(phraseViolations) / Double(max(1, phraseStarts.count)))
        let matchedCount = assignments.filter { $0.syllable != "_" }.count
        let coverage = Double(matchedCount) / Double(max(notes.count, units.count))
        let meanCost = bestScore / Double(max(1, notes.count))
        let costScore = exp(-meanCost)
        let confidence = max(0, min(1, coverage * 0.60 + costScore * 0.25 + phraseScore * 0.15))

        return AlignmentResult(
            assignments: assignments,
            unmatchedSyllables: unmatchedSyllables,
            unmatchedNotes: [],
            confidence: confidence
        )
    }

    private static func syllablePenalty(
        unit: SyllableUnit,
        note: PianoRollNote,
        prevNote: PianoRollNote?,
        isPhraseStart: Bool,
        remainingNotes: Int,
        remainingSyllables: Int,
        ticksPerQuarter: Int,
        lastWasMelisma: Bool
    ) -> Double {
        var penalty = 0.03

        if isPhraseStart && !unit.isWordStart {
            penalty += 0.75
        }
        if lastWasMelisma && unit.isWordStart {
            penalty += 0.08
        }

        if let prevNote {
            let prevEnd = prevNote.startTick + prevNote.duration
            let gap = max(0, note.startTick - prevEnd)
            if gap > ticksPerQuarter && !unit.isWordStart {
                penalty += 0.45
            }
        }

        if note.duration < ticksPerQuarter / 4 && unit.isWordStart {
            penalty += 0.12
        }

        if remainingNotes < remainingSyllables {
            penalty += 0.18
        }

        return penalty
    }

    private static func melismaPenalty(
        note: PianoRollNote,
        prevNote: PianoRollNote?,
        isPhraseStart: Bool,
        remainingNotes: Int,
        remainingSyllables: Int,
        ticksPerQuarter: Int,
        lastWasMelisma: Bool
    ) -> Double {
        var penalty = 1.10

        if isPhraseStart {
            penalty += 1.20
        }
        if lastWasMelisma {
            penalty += 0.35
        }

        if note.duration < ticksPerQuarter / 2 {
            penalty -= 0.35
        } else {
            penalty += 0.25
        }

        if let prevNote {
            let prevEnd = prevNote.startTick + prevNote.duration
            let gap = max(0, note.startTick - prevEnd)
            if gap <= ticksPerQuarter / 10 {
                penalty -= 0.20
            } else {
                penalty += 0.20
            }
        }

        if remainingNotes <= remainingSyllables {
            penalty += 1.00
        } else if remainingNotes > remainingSyllables + 6 {
            penalty -= 0.25
        }

        return max(0.05, penalty)
    }

    // MARK: - Heuristic Fallback

    private static func alignHeuristic(
        units: [SyllableUnit],
        notes: [PianoRollNote],
        phraseStarts: Set<Int>,
        ticksPerQuarter: Int
    ) -> AlignmentResult {
        var assignments: [(noteID: UUID, syllable: String)] = []
        var syllableIndex = 0
        var noteIndex = 0
        var matchedCount = 0
        let tpq = max(1, ticksPerQuarter)
        let wordStarts = Set(units.enumerated().filter { $0.element.isWordStart }.map { $0.offset })

        let useMelisma = units.count > 0 && notes.count > units.count && Double(units.count) / Double(notes.count) < 0.70

        while noteIndex < notes.count && syllableIndex < units.count {
            if phraseStarts.contains(noteIndex), syllableIndex > 0, !wordStarts.contains(syllableIndex) {
                var nextWordStart = syllableIndex
                while nextWordStart < units.count && !wordStarts.contains(nextWordStart) {
                    nextWordStart += 1
                }
                if nextWordStart < units.count {
                    syllableIndex = nextWordStart
                }
            }

            let note = notes[noteIndex]

            if useMelisma && noteIndex > 0 && !assignments.isEmpty {
                let prev = notes[noteIndex - 1]
                let gap = note.startTick - (prev.startTick + prev.duration)
                let remainingNotes = notes.count - noteIndex
                let remainingSyls = units.count - syllableIndex
                if note.duration < tpq / 2,
                   gap <= tpq / 8,
                   remainingNotes > remainingSyls + 2 {
                    assignments.append((noteID: note.id, syllable: "_"))
                    noteIndex += 1
                    continue
                }
            }

            assignments.append((noteID: note.id, syllable: units[syllableIndex].text))
            syllableIndex += 1
            matchedCount += 1
            noteIndex += 1
        }

        if syllableIndex >= units.count && noteIndex < notes.count {
            let trailingCount = notes.count - noteIndex
            if trailingCount <= 8 && !assignments.isEmpty {
                for i in noteIndex..<notes.count {
                    let note = notes[i]
                    if i > 0 {
                        let prevEnd = notes[i - 1].startTick + notes[i - 1].duration
                        if note.startTick - prevEnd > tpq { break }
                    }
                    assignments.append((noteID: note.id, syllable: "_"))
                }
            }
        }

        let unmatchedSyllables = syllableIndex < units.count
            ? Array(units[syllableIndex...].map(\.text))
            : []
        let assignedNoteIDs = Set(assignments.map(\.noteID))
        let unmatchedNoteIDs = notes.filter { !assignedNoteIDs.contains($0.id) }.map(\.id)
        let maxTotal = max(units.count, notes.count)
        let confidence = maxTotal > 0 ? Double(matchedCount) / Double(maxTotal) : 0

        return AlignmentResult(
            assignments: assignments,
            unmatchedSyllables: unmatchedSyllables,
            unmatchedNotes: unmatchedNoteIDs,
            confidence: confidence
        )
    }

    // MARK: - Helpers

    private static func flattenSyllables(_ syllabifiedWords: [(word: String, syllables: [String])]) -> [SyllableUnit] {
        var units: [SyllableUnit] = []
        units.reserveCapacity(syllabifiedWords.reduce(0) { $0 + $1.syllables.count })
        for (_, syllables) in syllabifiedWords {
            let formatted = SyllabificationService.formatAllForDisplay(syllables)
            for (idx, text) in formatted.enumerated() {
                units.append(
                    SyllableUnit(
                        text: text,
                        isWordStart: idx == 0
                    )
                )
            }
        }
        return units
    }

    private static func detectPhraseStarts(notes: [PianoRollNote], ticksPerQuarter: Int) -> Set<Int> {
        guard !notes.isEmpty else { return [] }
        let tpq = max(1, ticksPerQuarter)
        var starts: Set<Int> = [0]
        for i in 1..<notes.count {
            let prevEnd = notes[i - 1].startTick + notes[i - 1].duration
            if notes[i].startTick - prevEnd > tpq {
                starts.insert(i)
            }
        }
        return starts
    }
}
