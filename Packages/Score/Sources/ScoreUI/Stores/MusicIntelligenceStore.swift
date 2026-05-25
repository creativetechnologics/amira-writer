import Foundation

@available(macOS 26.0, *)
@MainActor
final class MusicIntelligenceStore {
    unowned let parent: ScoreStore
    init(parent: ScoreStore) { self.parent = parent }

    func analyzeCurrentSongStructure() {
        guard !parent.pianoRollNotes.isEmpty else { parent.musicEngineStatus = "No notes to analyze."; return }
        parent.musicEngineStatus = "Analyzing structure..."
        let capturedSongID = parent.selectedMidiID
        Task {
            let phrases = PhraseDetector.detectPhrases(notes: parent.pianoRollNotes, tempoEvents: parent.pianoRollTempoEvents, timeSignatures: parent.pianoRollTimeSignatures, ticksPerQuarter: parent.ticksPerQuarter)
            let sections = StructureAnalyzer.analyze(phrases: phrases, notes: parent.pianoRollNotes, tempoEvents: parent.pianoRollTempoEvents, timeSignatures: parent.pianoRollTimeSignatures, ticksPerQuarter: parent.ticksPerQuarter)
            let key = KeyDetector.detectKeyWithFallback(notes: parent.pianoRollNotes, keySignatures: parent.pianoRollKeySignatures)
            let chords = ChordProgressionAnalyzer.analyze(notes: parent.pianoRollNotes, timeSignatures: parent.pianoRollTimeSignatures, ticksPerQuarter: parent.ticksPerQuarter, key: key)
            guard parent.selectedMidiID == capturedSongID else { return }
            parent.currentStructuralAnalysis = StructuralAnalysis(phrases: phrases, sections: sections, detectedKey: key)
            parent.currentChordProgression = chords
            parent.musicEngineStatus = "Analysis complete: \(phrases.count) phrases, \(sections.count) sections, key: \(key?.displayName ?? "Unknown")"
        }
    }

    func performSmartAlignment() {
        guard !parent.pianoRollNotes.isEmpty else { parent.musicEngineStatus = "No notes for alignment."; return }
        guard let lyrics = parent.selectedLibrettoFile?.content, !lyrics.isEmpty else { parent.musicEngineStatus = "No lyrics for alignment."; return }
        parent.musicEngineStatus = "Aligning lyrics..."
        let capturedSongID = parent.selectedMidiID
        Task {
            let syllabified = SyllabificationService.syllabify(lyrics)
            let result = SmartLyricAligner.align(syllabifiedWords: syllabified, notes: parent.pianoRollNotes, tempoEvents: parent.pianoRollTempoEvents, timeSignatures: parent.pianoRollTimeSignatures, ticksPerQuarter: parent.ticksPerQuarter, lyricText: lyrics)
            guard parent.selectedMidiID == capturedSongID else { return }
            parent.smartAlignmentPreview = result
            parent.musicEngineStatus = "Alignment preview ready (\(result.assignments.count) assignments)."
        }
    }

    func acceptSmartAlignmentPreview() {
        guard let preview = parent.smartAlignmentPreview else { return }
        parent.pushUndoState(label: "Apply Lyric Alignment")
        for assignment in preview.assignments {
            if let noteIdx = parent.pianoRollNotes.firstIndex(where: { $0.id == assignment.noteID }) {
                parent.pianoRollNotes[noteIdx].lyricSyllable = assignment.syllable
            }
        }
        parent.smartAlignmentPreview = nil
        parent.isDirty = true
        parent.musicEngineStatus = "Alignment applied."
    }

    func rejectSmartAlignmentPreview() {
        parent.smartAlignmentPreview = nil
        parent.musicEngineStatus = "Alignment discarded."
    }
}
