import Foundation

// MARK: - MelodicMutator

/// Proposes musically sensible MIDI modifications when lyrics need more or fewer
/// notes than currently available.
///
/// **Core principle**: Never produce notes that sound out of place. All mutations
/// preserve melodic contour, stay within the detected key's scale, and follow
/// natural voice-leading principles.
///
/// - **Need more notes**: Split long notes, insert passing tones, subdivide beats
/// - **Need fewer notes**: Merge short adjacent notes, convert excess to melisma
enum MelodicMutator {

    // MARK: - Public API

    /// Propose a melodic mutation to accommodate a different syllable count.
    ///
    /// - Parameters:
    ///   - currentNotes: The current vocal melody notes (sorted by startTick).
    ///   - targetSyllableCount: How many syllables the new lyrics need.
    ///   - detectedKey: Optional key for constraining new pitches to scale tones.
    ///   - tempoEvents: Tempo map.
    ///   - timeSignatures: Time signature events.
    ///   - ticksPerQuarter: MIDI division.
    ///   - config: Mutation configuration.
    /// - Returns: A `MelodicMutation` describing proposed changes.
    static func propose(
        currentNotes: [PianoRollNote],
        targetSyllableCount: Int,
        detectedKey: DetectedKey? = nil,
        tempoEvents: [TempoPoint] = [],
        timeSignatures: [TimeSignatureEvent] = [],
        ticksPerQuarter: Int,
        config: MelodicMutationConfig = .init()
    ) -> MelodicMutation {
        let sorted = currentNotes.sorted { $0.startTick < $1.startTick }
        let tpq = max(1, ticksPerQuarter)
        let currentCount = sorted.count
        let delta = targetSyllableCount - currentCount

        if delta == 0 {
            return MelodicMutation(
                notesToInsert: [],
                notesToRemove: [],
                notesToModify: [],
                description: "No changes needed — note count matches syllable count.",
                confidence: 1.0
            )
        }

        if delta > 0 {
            return proposeExpansion(
                notes: sorted,
                neededExtra: min(delta, config.maxInsertions),
                detectedKey: detectedKey,
                ticksPerQuarter: tpq,
                config: config
            )
        } else {
            return proposeReduction(
                notes: sorted,
                excessCount: min(-delta, config.maxRemovals),
                ticksPerQuarter: tpq,
                config: config
            )
        }
    }

    // MARK: - Expansion (Need More Notes)

    /// Propose adding notes when we need more syllable slots.
    ///
    /// Strategy priority:
    /// 1. Split long notes (> 1 beat) at their midpoint
    /// 2. Insert passing tones between large intervals
    /// 3. Subdivide notes on strong beats
    private static func proposeExpansion(
        notes: [PianoRollNote],
        neededExtra: Int,
        detectedKey: DetectedKey?,
        ticksPerQuarter: Int,
        config: MelodicMutationConfig
    ) -> MelodicMutation {
        var inserts: [PianoRollNote] = []
        var modifications: [MelodicMutation.NoteModification] = []
        var remaining = neededExtra

        // Rank notes by suitability for splitting (longest first).
        let candidatesForSplit = notes.enumerated()
            .filter { $0.element.duration > ticksPerQuarter }
            .sorted { $0.element.duration > $1.element.duration }

        // Strategy 1: Split long notes.
        if config.preferSplitOverInsert {
            for (_, note) in candidatesForSplit {
                guard remaining > 0 else { break }

                let halfDuration = note.duration / 2
                guard halfDuration >= ticksPerQuarter / 4 else { continue }

                // Shorten the original note to the first half.
                modifications.append(MelodicMutation.NoteModification(
                    noteID: note.id,
                    newPitch: nil,
                    newDuration: halfDuration,
                    newStartTick: nil
                ))

                // Insert a new note for the second half at the same pitch.
                inserts.append(PianoRollNote(
                    trackIndex: note.trackIndex,
                    channel: note.channel,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    startTick: note.startTick + halfDuration,
                    duration: note.duration - halfDuration
                ))

                remaining -= 1
            }
        }

        // Strategy 2: Insert passing tones between large intervals.
        if remaining > 0 {
            let scalePCs = detectedKey?.scalePitchClasses
            for i in 0..<(notes.count - 1) {
                guard remaining > 0 else { break }

                let current = notes[i]
                let next = notes[i + 1]
                let interval = abs(next.pitch - current.pitch)

                // Need at least a third (4 semitones) to insert a passing tone.
                guard interval >= 4 else { continue }

                // Check there's enough space between notes.
                let gapStart = current.startTick + current.duration
                let gapDuration = next.startTick - gapStart
                guard gapDuration >= ticksPerQuarter / 4 else { continue }

                // Find a passing tone: midpoint pitch, constrained to scale.
                let midPitch = (current.pitch + next.pitch) / 2
                let constrainedPitch = constrainToScale(pitch: midPitch, scalePCs: scalePCs)

                let insertDuration = min(gapDuration, ticksPerQuarter / 2)

                inserts.append(PianoRollNote(
                    trackIndex: current.trackIndex,
                    channel: current.channel,
                    pitch: constrainedPitch,
                    velocity: max(1, current.velocity - 10), // slightly softer
                    startTick: gapStart,
                    duration: insertDuration
                ))

                remaining -= 1
            }
        }

        // Strategy 3: Subdivide notes on strong beats.
        if remaining > 0 {
            // Re-evaluate after splits — find notes still long enough.
            let modifiedDurations = Dictionary(uniqueKeysWithValues:
                modifications.compactMap { mod -> (UUID, Int)? in
                    guard let dur = mod.newDuration else { return nil }
                    return (mod.noteID, dur)
                }
            )

            for note in notes {
                guard remaining > 0 else { break }
                let effectiveDuration = modifiedDurations[note.id] ?? note.duration
                guard effectiveDuration > ticksPerQuarter / 2 else { continue }

                // Already split this note? Skip.
                if modifications.contains(where: { $0.noteID == note.id }) { continue }

                let thirdDuration = effectiveDuration / 3
                guard thirdDuration >= ticksPerQuarter / 8 else { continue }

                // Shorten original to first third.
                modifications.append(MelodicMutation.NoteModification(
                    noteID: note.id,
                    newPitch: nil,
                    newDuration: thirdDuration,
                    newStartTick: nil
                ))

                // Insert note for remaining two-thirds (could be split further).
                inserts.append(PianoRollNote(
                    trackIndex: note.trackIndex,
                    channel: note.channel,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    startTick: note.startTick + thirdDuration,
                    duration: effectiveDuration - thirdDuration
                ))

                remaining -= 1
            }
        }

        let actualAdded = neededExtra - remaining
        let description = actualAdded > 0
            ? "Added \(actualAdded) note\(actualAdded == 1 ? "" : "s") by splitting long notes and inserting passing tones."
            : "Could not add enough notes — the melody may be too dense."

        return MelodicMutation(
            notesToInsert: inserts,
            notesToRemove: [],
            notesToModify: modifications,
            description: description,
            confidence: remaining == 0 ? 0.85 : Double(actualAdded) / Double(neededExtra) * 0.7
        )
    }

    // MARK: - Reduction (Need Fewer Notes)

    /// Propose removing notes when we have too many for the lyrics.
    ///
    /// Strategy priority:
    /// 1. Merge short adjacent notes that are close in pitch
    /// 2. Convert trailing phrase notes to melisma (let SmartLyricAligner handle them)
    private static func proposeReduction(
        notes: [PianoRollNote],
        excessCount: Int,
        ticksPerQuarter: Int,
        config: MelodicMutationConfig
    ) -> MelodicMutation {
        var removals: [UUID] = []
        var modifications: [MelodicMutation.NoteModification] = []
        var remaining = excessCount

        // Strategy 1: Merge short adjacent notes close in pitch.
        // Build merge candidates: pairs of adjacent notes where both are short and close in pitch.
        var mergeCandidates: [(index: Int, score: Double)] = []
        for i in 0..<(notes.count - 1) {
            let a = notes[i]
            let b = notes[i + 1]

            let aShort = a.duration < ticksPerQuarter
            let bShort = b.duration < ticksPerQuarter
            let closePitch = abs(a.pitch - b.pitch) <= 3
            let contiguous = b.startTick <= a.startTick + a.duration + ticksPerQuarter / 8

            if (aShort || bShort) && closePitch && contiguous {
                // Lower score = better merge candidate.
                let pitchDist = Double(abs(a.pitch - b.pitch))
                let durationScore = Double(min(a.duration, b.duration)) / Double(ticksPerQuarter)
                mergeCandidates.append((index: i, score: pitchDist + durationScore))
            }
        }

        // Sort by score (best candidates first).
        mergeCandidates.sort { $0.score < $1.score }

        var mergedIndices: Set<Int> = []
        for candidate in mergeCandidates {
            guard remaining > 0 else { break }
            let i = candidate.index

            // Don't merge if either note is already involved in a merge.
            guard !mergedIndices.contains(i) && !mergedIndices.contains(i + 1) else { continue }

            let a = notes[i]
            let b = notes[i + 1]

            // Extend first note to cover both.
            let newDuration = (b.startTick + b.duration) - a.startTick
            modifications.append(MelodicMutation.NoteModification(
                noteID: a.id,
                newPitch: nil,
                newDuration: newDuration,
                newStartTick: nil
            ))

            // Remove second note.
            removals.append(b.id)
            mergedIndices.insert(i)
            mergedIndices.insert(i + 1)
            remaining -= 1
        }

        // Strategy 2: No further action needed — excess notes become melisma ("_")
        // which SmartLyricAligner/LyricAligner handles naturally.

        let actualRemoved = excessCount - remaining
        let description: String
        if actualRemoved > 0 {
            description = "Merged \(actualRemoved) short note pair\(actualRemoved == 1 ? "" : "s"). Remaining excess notes will become melisma extensions."
        } else {
            description = "No merges needed — excess notes will become melisma extensions."
        }

        return MelodicMutation(
            notesToInsert: [],
            notesToRemove: removals,
            notesToModify: modifications,
            description: description,
            confidence: 0.80
        )
    }

    // MARK: - Scale Constraint

    /// Constrain a pitch to the nearest scale tone.
    private static func constrainToScale(pitch: Int, scalePCs: Set<Int>?) -> Int {
        guard let scale = scalePCs, !scale.isEmpty else { return pitch }

        let pc = pitch % 12
        if scale.contains(pc) { return pitch }

        // Find nearest scale tone.
        for offset in 1...6 {
            if scale.contains((pc + offset) % 12) { return pitch + offset }
            if scale.contains(((pc - offset) % 12 + 12) % 12) { return pitch - offset }
        }

        return pitch
    }

    // MARK: - Utility

    /// Check if a proposed mutation preserves the overall melodic contour.
    static func preservesContour(
        original: [PianoRollNote],
        mutated: [PianoRollNote]
    ) -> Bool {
        let origPitches = original.sorted { $0.startTick < $1.startTick }.map(\.pitch)
        let mutPitches = mutated.sorted { $0.startTick < $1.startTick }.map(\.pitch)

        let origContour = MelodicContourAnalyzer.classify(pitches: origPitches)
        let mutContour = MelodicContourAnalyzer.classify(pitches: mutPitches)

        // Same contour class, or both are "complex" (mixed).
        return origContour == mutContour || origContour == .mixed || mutContour == .mixed
    }
}
