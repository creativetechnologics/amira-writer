import Foundation

@available(macOS 26.0, *)
@MainActor
final class CompositionStore {
    unowned let parent: ScoreStore
    init(parent: ScoreStore) { self.parent = parent }

    func analyzeMusicalStyle() {
        guard !parent.pianoRollNotes.isEmpty else { return }
        let key = parent.currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: parent.pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
        let melodic = StyleAnalyzer.analyzeMelodicProfile(notes: parent.pianoRollNotes, ticksPerQuarter: parent.ticksPerQuarter)
        let rhythmic = StyleAnalyzer.analyzeRhythmicProfile(notes: parent.pianoRollNotes, ticksPerQuarter: parent.ticksPerQuarter)
        let harmonic = StyleAnalyzer.analyzeHarmonicComplexity(chords: parent.currentChordProgression?.chords ?? [], key: key)
        parent.detectedStyle = MusicalStyleProfile(melodicProfile: melodic, rhythmicProfile: rhythmic, harmonicComplexity: harmonic, genreHints: [])
    }

    func composeMelody(constraints: MelodyConstraints) {
        let melody = CompositionEngine.generateMelody(constraints: constraints)
        parent.composedMelody = melody
    }

    func midiAIGenerateFromText(_ prompt: String, maxTokens: Int = 1024, temperature: Double = 0.95) {
        parent.midiAIStatusMessage = "MidiAI not available in Score."
    }

    func midiAIGenerateMelody(lyrics: String, tempoBPM: Int? = nil, key: String? = nil) {
        midiAIGenerateFromText(lyrics)
    }

    func midiAIGenerateContinuation(maxTokens: Int = 512, temperature: Double = 0.95) {
        parent.midiAIStatusMessage = "MidiAI not available in Score."
    }
}
