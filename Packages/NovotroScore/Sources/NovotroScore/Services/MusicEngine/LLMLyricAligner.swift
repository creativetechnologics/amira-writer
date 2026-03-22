import Foundation

// MARK: - LLMLyricAligner

/// Prompt builder and response parser for LLM-powered lyric-to-note alignment.
///
/// Follows the `LLMMusicalReasoner` pattern — all methods are pure functions that
/// build prompt strings and parse response strings. The caller (`ProjectStore`) is
/// responsible for wiring prompts through `LLMClient.generate()`.
///
/// The LLM alignment approach sends a compact representation of melody notes and
/// syllabified lyrics, asking the model to assign each syllable to a note index.
/// This can produce better results than algorithmic alignment for complex passages
/// where syllable-to-note mapping requires musical understanding.
@available(macOS 26.0, *)
enum LLMLyricAligner {

    // MARK: - Data Structures

    /// A single syllable-to-note assignment parsed from the LLM response.
    struct Assignment: Sendable {
        var syllable: String
        var noteIndex: Int
        var confidence: Double  // 0.0–1.0
    }

    /// Result of parsing the LLM alignment response.
    struct AlignmentResult: Sendable {
        var assignments: [Assignment]
        var unmatchedSyllables: [String]
        var parseErrors: [String]
    }

    // MARK: - System Prompt

    private static let systemPrompt = """
        You are a vocal music alignment expert. Your task is to map lyric syllables \
        to melody notes in opera and vocal music. You understand how singers phrase \
        lyrics over melodic lines — one syllable per note, preserving word order, \
        with melismas (held vowels) on longer or repeated notes.
        """

    // MARK: - Prompt Builder

    /// Build a prompt to align syllabified lyrics to sorted melody notes.
    ///
    /// - Parameters:
    ///   - syllabifiedWords: Output of `SyllabificationService.syllabify()`.
    ///   - notes: Sorted melody notes (vocal track only).
    ///   - ticksPerQuarter: MIDI resolution for beat calculation.
    /// - Returns: System and user prompt strings for `LLMClient.generate()`.
    static func buildAlignmentPrompt(
        syllabifiedWords: [(word: String, syllables: [String])],
        notes: [PianoRollNote],
        ticksPerQuarter: Int
    ) -> (system: String, user: String) {
        let tpq = max(1, ticksPerQuarter)
        let noteNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

        // Build compact note table (limit to first 200 notes to stay within token budget)
        let cappedNotes = Array(notes.prefix(200))
        var noteLines: [String] = []
        for (i, note) in cappedNotes.enumerated() {
            let beat = String(format: "%.2f", Double(note.startTick) / Double(tpq))
            let dur = String(format: "%.2f", Double(note.duration) / Double(tpq))
            let pc = note.pitch % 12
            let octave = note.pitch / 12 - 1
            let pitchName = "\(noteNames[pc])\(octave)"
            noteLines.append("\(i)|\(beat)|\(dur)|\(pitchName)")
        }

        // Build syllable list (limit to first 300 syllables)
        var allSyllables: [String] = []
        var wordBoundaries: [Int] = [] // indices where new words start
        for (word, syllables) in syllabifiedWords {
            if allSyllables.count >= 300 { break }
            wordBoundaries.append(allSyllables.count)
            for syl in syllables {
                if allSyllables.count >= 300 { break }
                allSyllables.append(syl)
            }
            _ = word // suppress unused warning
        }

        let syllableList = allSyllables.enumerated().map { i, syl in
            let isWordStart = wordBoundaries.contains(i)
            return isWordStart ? "[\(syl)" : syl
        }.joined(separator: " ")

        let user = """
            Map each syllable to a note index. One syllable per note, preserve order.
            Syllables starting with [ mark word boundaries.

            NOTES (index|beat|duration|pitch):
            \(noteLines.joined(separator: "\n"))

            SYLLABLES (\(allSyllables.count) total):
            \(syllableList)

            Rules:
            - Assign one syllable per note in order
            - Skip notes for melismas (long notes without new syllables)
            - If more syllables than notes, leave extras unassigned
            - If more notes than syllables, leave extra notes empty

            Output ONLY the assignments, one per line:
            <note_index>:<syllable>
            """

        return (system: systemPrompt, user: user)
    }

    // MARK: - Response Parser

    /// Parse the LLM response into structured assignments.
    ///
    /// Expects lines in format `<note_index>:<syllable>`.
    /// Tolerates minor formatting variations (extra whitespace, blank lines).
    ///
    /// - Parameters:
    ///   - raw: Raw LLM response text.
    ///   - syllabifiedWords: Original syllable data for validation.
    ///   - noteCount: Number of notes in the melody.
    /// - Returns: Parsed alignment result with assignments and any errors.
    static func parseAlignmentResponse(
        _ raw: String,
        syllabifiedWords: [(word: String, syllables: [String])],
        noteCount: Int
    ) -> AlignmentResult {
        var assignments: [Assignment] = []
        var parseErrors: [String] = []
        var usedNoteIndices = Set<Int>()

        // Flatten expected syllables for validation
        let expectedSyllables = syllabifiedWords.flatMap(\.syllables)

        let lines = raw.components(separatedBy: .newlines)
        var syllableIndex = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Parse "index:syllable" format
            guard let colonRange = trimmed.range(of: ":") else {
                // Skip non-assignment lines (preamble, explanations)
                if trimmed.first?.isNumber != true {
                    continue
                }
                parseErrors.append("Malformed line: \(trimmed.prefix(60))")
                continue
            }

            let indexStr = trimmed[trimmed.startIndex..<colonRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let syllable = trimmed[colonRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "[", with: "") // strip word boundary markers

            guard let noteIndex = Int(indexStr) else {
                parseErrors.append("Invalid note index: \(indexStr)")
                continue
            }

            guard noteIndex >= 0 && noteIndex < noteCount else {
                parseErrors.append("Note index out of range: \(noteIndex)")
                continue
            }

            guard !usedNoteIndices.contains(noteIndex) else {
                parseErrors.append("Duplicate note index: \(noteIndex)")
                continue
            }

            guard !syllable.isEmpty else { continue }

            usedNoteIndices.insert(noteIndex)
            assignments.append(Assignment(
                syllable: String(syllable),
                noteIndex: noteIndex,
                confidence: 0.8 // default confidence for LLM assignments
            ))
            syllableIndex += 1
        }

        // Validate order preservation
        var isOrdered = true
        for i in 1..<assignments.count {
            if assignments[i].noteIndex <= assignments[i - 1].noteIndex {
                isOrdered = false
                break
            }
        }

        if !isOrdered {
            // Sort by note index to enforce order
            assignments.sort { $0.noteIndex < $1.noteIndex }
            parseErrors.append("Note order was not strictly increasing — sorted to fix")
        }

        // Adjust confidence based on coverage
        let coverage = Double(assignments.count) / Double(max(1, expectedSyllables.count))
        let adjustedConfidence = min(1.0, coverage) * (isOrdered ? 1.0 : 0.7)
        for i in assignments.indices {
            assignments[i].confidence = adjustedConfidence
        }

        // Collect unmatched syllables
        let matchedSyllables = Set(assignments.map(\.syllable))
        let unmatched = expectedSyllables.filter { !matchedSyllables.contains($0) }

        return AlignmentResult(
            assignments: assignments,
            unmatchedSyllables: Array(unmatched.prefix(50)),
            parseErrors: parseErrors
        )
    }

    // MARK: - Conversion

    /// Convert LLM alignment assignments to `SmartAlignmentResult` format
    /// for use with the existing preview/accept/reject flow.
    ///
    /// - Parameters:
    ///   - result: Parsed LLM alignment result.
    ///   - notes: The sorted melody notes that were sent to the LLM.
    /// - Returns: A `SmartAlignmentResult` compatible with the existing UI flow.
    static func toSmartAlignmentResult(
        _ result: AlignmentResult,
        notes: [PianoRollNote]
    ) -> SmartAlignmentResult {
        let smartAssignments = result.assignments.compactMap { assignment -> SmartAlignmentResult.Assignment? in
            guard assignment.noteIndex < notes.count else { return nil }
            return SmartAlignmentResult.Assignment(
                noteID: notes[assignment.noteIndex].id,
                syllable: assignment.syllable
            )
        }

        let assignedNoteIDs = Set(smartAssignments.map(\.noteID))
        let unmatchedNoteIDs = notes.filter { !assignedNoteIDs.contains($0.id) }.map(\.id)

        let confidence = result.assignments.isEmpty ? 0.0
            : result.assignments.map(\.confidence).reduce(0, +) / Double(result.assignments.count)

        return SmartAlignmentResult(
            assignments: smartAssignments,
            unmatchedSyllables: result.unmatchedSyllables,
            unmatchedNotes: unmatchedNoteIDs,
            confidence: confidence,
            phraseBreakAlignments: 0,
            contourScore: 0,
            fitWarnings: result.parseErrors.isEmpty ? [] : [
                SmartAlignmentResult.FitWarning(
                    phraseIndex: 0,
                    syllableCount: result.assignments.count,
                    noteCount: notes.count,
                    message: "LLM parse issues: \(result.parseErrors.joined(separator: "; "))"
                )
            ]
        )
    }
}
