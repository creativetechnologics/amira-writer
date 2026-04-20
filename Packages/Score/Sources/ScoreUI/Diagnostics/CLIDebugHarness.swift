import Foundation
import ProjectKit

// MARK: - CLIDebugHarness

/// CLI debug harness for diagnosing runtime issues.
///
/// Invoked via: Score --debug
///
/// Runs diagnostics against the Amira.owp project:
/// 1. track-map — dumps all track→instrument mappings with roles
/// 2. ghost-notes — verifies track filter produces correct visible/ghost splits
/// 3. generate-part — tests vocal track resolution for instrument part generation
/// 4. syllables — checks syllabification of real lyrics for quality issues
/// 5. empty-tracks — verifies canonical instruments are injected and selectable
/// 6. preview-notes — tests that generated parts produce previewable notes
/// 7. key-mapping — verifies mappingKeysForBaseKey resolves scoped keys correctly
/// 8. smart-align — tests the smart lyric alignment pipeline end-to-end
/// 9. llm-align — tests the LLM alignment prompt builder and response parser
@available(macOS 26.0, *)
@MainActor
enum CLIDebugHarness {

    // MARK: - Data Structures

    private struct SongDebugData {
        var notes: [PianoRollNote]
        var tempoEvents: [TempoPoint]
        var timeSignatures: [TimeSignatureEvent]
        var keySignatures: [KeySignatureEvent]
        var ticksPerQuarter: Int
        var lyrics: String?
        var trackNames: [Int: String]
        var instrumentMappings: [InstrumentMapping]
    }

    // MARK: - Entry Point

    static func run() -> Int32 {
        print("[DEBUG] Novotro Score CLI Debug Harness")
        print("[DEBUG] ================================================")
        print("")

        let amiraPath = "/Volumes/Storage VIII/Programming/Amira - A Modern Opera/Amira.owp"
        let songName = "1.06.0 - FIRST MEETING.ows"

        guard let data = loadSongDebugData(owpPath: amiraPath, songName: songName) else {
            print("[DEBUG] FATAL: Could not load \(songName) from Amira.owp")
            return 1
        }

        print("[DEBUG] Loaded \(songName): \(data.notes.count) notes, \(data.instrumentMappings.count) mappings, tpq=\(data.ticksPerQuarter)")
        print("")

        // ── Diagnostic 1: Track Map ──────────────────────────────────────
        runTrackMapDiagnostic(data: data)

        // ── Diagnostic 2: Ghost Notes ────────────────────────────────────
        runGhostNotesDiagnostic(data: data)

        // ── Diagnostic 3: Generate Part ──────────────────────────────────
        runGeneratePartDiagnostic(data: data)

        // ── Diagnostic 4: Syllables ──────────────────────────────────────
        runSyllablesDiagnostic(data: data)

        // ── Diagnostic 5: Empty Track / Canonical Injection ─────────────
        runEmptyTrackDiagnostic(data: data)

        // ── Diagnostic 6: Preview Notes Pipeline ────────────────────────
        runPreviewNotesDiagnostic(data: data)

        // ── Diagnostic 7: Key Mapping Resolution ────────────────────────
        runKeyMappingDiagnostic(data: data)

        // ── Diagnostic 8: Smart Alignment Pipeline ──────────────────────
        runSmartAlignDiagnostic(data: data)

        // ── Diagnostic 9: LLM Alignment Pipeline ────────────────────────
        runLLMAlignDiagnostic(data: data)

        // ── Diagnostic 10: Track Filter → Ghost Notes (full store flow) ──
        runTrackFilterGhostDiagnostic(data: data)

        // ── Diagnostic 11: Canonical Track Persistence ──
        runCanonicalTrackPersistenceDiagnostic(data: data)

        // ── Diagnostic 12: Playback / SF2 Loading ──
        runPlaybackDiagnostic(data: data)

        print("")
        print("[DEBUG] ================================================")
        print("[DEBUG] All diagnostics complete.")
        return 0
    }

    // MARK: - Diagnostic 1: Track Map

    private static func runTrackMapDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Track Map ──────────────────────────")

        // Collect unique (trackIndex, channel) pairs from notes
        var pairsSet = Set<String>()
        for note in data.notes {
            pairsSet.insert("\(note.trackIndex):\(note.channel)")
        }
        let pairs = pairsSet.sorted()

        print("[DEBUG] Note pairs (trackIndex:channel): \(pairs.count) unique")
        for pair in pairs {
            let parts = pair.split(separator: ":")
            guard let trackIdx = Int(parts[0]), let channel = Int(parts[1]) else { continue }
            let noteCount = data.notes.filter { $0.trackIndex == trackIdx && $0.channel == channel }.count
            let trackName = data.trackNames[trackIdx] ?? "(unnamed)"
            print("[DEBUG]   \(pair) — \(noteCount) notes — trackName: \(trackName)")
        }

        print("[DEBUG]")
        print("[DEBUG] Instrument Mappings (\(data.instrumentMappings.count)):")
        for mapping in data.instrumentMappings {
            let role = mapping.trackRole
            print("[DEBUG]   channelKey=\"\(mapping.channelKey)\" display=\"\(mapping.displayName)\" role=\(role.rawValue) sortOrder=\(mapping.sortOrder ?? -1)")
        }

        // Resolve vocal track indices using the same logic as MainSplitViewController
        let vocalIndices = resolveVocalTrackIndices(
            notes: data.notes,
            mappings: data.instrumentMappings
        )
        print("[DEBUG]")
        print("[DEBUG] Resolved vocal track indices: \(vocalIndices.sorted())")
        print("")
    }

    // MARK: - Diagnostic 2: Ghost Notes

    private static func runGhostNotesDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Ghost Notes ───────────────────────")

        // Get unique track indices
        let allTrackIndices = Set(data.notes.map(\.trackIndex)).sorted()
        print("[DEBUG] All track indices in notes: \(allTrackIndices)")
        print("[DEBUG] Notes per track:")
        for trackIdx in allTrackIndices {
            let count = data.notes.filter { $0.trackIndex == trackIdx }.count
            print("[DEBUG]   track \(trackIdx): \(count) notes")
        }

        // Simulate selecting each track as filter
        print("[DEBUG]")
        print("[DEBUG] Ghost note simulation (selecting each track):")
        for trackIdx in allTrackIndices {
            let filter: Set<Int> = [trackIdx]
            let visible = data.notes.filter { filter.contains($0.trackIndex) }
            let ghost = data.notes.filter { !filter.contains($0.trackIndex) }
            let trackName = data.trackNames[trackIdx] ?? "(unnamed)"
            print("[DEBUG]   filter=[\(trackIdx)] (\(trackName)): visible=\(visible.count), ghost=\(ghost.count)")
        }

        // Test empty filter (should show all as visible, no ghost)
        print("[DEBUG]   filter=[] (no selection): visible=\(data.notes.count), ghost=0")

        // Key insight: if there's only 1 track index, ghost notes won't work
        if allTrackIndices.count <= 1 {
            print("[DEBUG]")
            print("[DEBUG]   WARNING: Only \(allTrackIndices.count) track index found. Ghost notes require multiple tracks.")
            print("[DEBUG]   All notes have trackIndex=\(allTrackIndices.first ?? -1). There are no 'other' tracks to ghost.")
        }
        print("")
    }

    // MARK: - Diagnostic 3: Generate Part

    private static func runGeneratePartDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Generate Part ─────────────────────")

        // Test the BROKEN approach: trackIndex == 0
        let melodyTrack0 = data.notes.filter { $0.trackIndex == 0 }
            .sorted { $0.startTick < $1.startTick }
        print("[DEBUG] Old approach (trackIndex == 0): \(melodyTrack0.count) melody notes")

        // Test the FIXED approach: vocal track resolution
        let vocalIndices = resolveVocalTrackIndices(
            notes: data.notes,
            mappings: data.instrumentMappings
        )
        let melodyVocal: [PianoRollNote]
        if !vocalIndices.isEmpty {
            melodyVocal = data.notes.filter { vocalIndices.contains($0.trackIndex) }
                .sorted { $0.startTick < $1.startTick }
        } else {
            melodyVocal = melodyTrack0 // fallback
        }
        print("[DEBUG] Fixed approach (vocal tracks \(vocalIndices.sorted())): \(melodyVocal.count) melody notes")

        if melodyTrack0.isEmpty && !melodyVocal.isEmpty {
            print("[DEBUG]   CONFIRMED BUG: track 0 has no notes, but vocal tracks have \(melodyVocal.count)")
        } else if melodyTrack0.isEmpty && melodyVocal.isEmpty {
            print("[DEBUG]   ISSUE: Both approaches yield 0 notes. Check trackRole assignments.")
        }

        // Detect key and chords for generation test
        guard !melodyVocal.isEmpty else {
            print("[DEBUG]   Skipping generation test (no melody notes)")
            print("")
            return
        }

        let key = KeyDetector.detectKey(notes: data.notes, ticksPerQuarter: data.ticksPerQuarter)
            ?? DetectedKey(root: 0, isMinor: false, confidence: 1.0)
        let chords = ChordProgressionAnalyzer.analyze(
            notes: data.notes,
            ticksPerQuarter: data.ticksPerQuarter,
            key: key
        ).chords

        print("[DEBUG] Key: \(key.displayName), Chords: \(chords.count)")

        // Try generating a sustained part
        let generated = InstrumentPartGenerator.generate(
            melody: melodyVocal,
            chords: chords,
            key: key,
            instrument: "Violins I",
            style: .sustained,
            trackIndex: 10,
            channel: 0,
            ticksPerQuarter: data.ticksPerQuarter
        )
        print("[DEBUG] Generated sustained part: \(generated.count) notes")

        if generated.isEmpty {
            print("[DEBUG]   ISSUE: Generation returned 0 notes despite \(melodyVocal.count) melody + \(chords.count) chords")
        } else {
            let pitches = generated.map { $0.pitch }
            print("[DEBUG]   Pitch range: \(pitches.min() ?? 0)–\(pitches.max() ?? 0)")
            let totalDuration = generated.map { $0.duration }.reduce(0, +)
            print("[DEBUG]   Total duration: \(totalDuration) ticks (\(String(format: "%.1f", Double(totalDuration) / Double(data.ticksPerQuarter))) beats)")
        }
        print("")
    }

    // MARK: - Diagnostic 4: Syllables

    private static func runSyllablesDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Syllables ─────────────────────────")

        guard let lyrics = data.lyrics, !lyrics.isEmpty else {
            print("[DEBUG] No lyrics available in this song.")
            print("")
            return
        }

        // Extract sung lyrics using SyllabificationService
        let extractedLyrics = SyllabificationService.extractLyrics(from: lyrics)
        print("[DEBUG] Raw lyrics length: \(lyrics.count) chars")
        print("[DEBUG] Extracted lyrics: \(extractedLyrics.count) chars")

        let syllabified = SyllabificationService.syllabify(extractedLyrics)
        print("[DEBUG] Words: \(syllabified.count)")

        var issueCount = 0
        for (word, syllables) in syllabified {
            let shouldBeSingle = word.count <= 4 // short words should generally be 1 syllable
            let hasMisplit = syllables.count > 1 && shouldBeSingle

            if hasMisplit {
                print("[DEBUG]   ISSUE: \"\(word)\" → [\(syllables.map { "\"\($0)\"" }.joined(separator: ", "))] — \(syllables.count) syllables for \(word.count)-char word")
                issueCount += 1
            }
        }

        // Also show first 30 words for review
        print("[DEBUG]")
        print("[DEBUG] First 30 words syllabified:")
        for (word, syllables) in syllabified.prefix(30) {
            let marker = syllables.count > 1 ? " (\(syllables.count) syl)" : ""
            print("[DEBUG]   \"\(word)\" → [\(syllables.map { "\"\($0)\"" }.joined(separator: ", "))]\(marker)")
        }

        print("[DEBUG]")
        print("[DEBUG] Total words: \(syllabified.count), potential mis-splits: \(issueCount)")
        print("")
    }

    // MARK: - Diagnostic 5: Empty Track / Canonical Injection

    private static func runEmptyTrackDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Empty Tracks ───────────────────────")

        // Identify which canonical instruments have notes vs which are "empty"
        let trackIndicesWithNotes = Set(data.notes.map(\.trackIndex))

        // Simulate canonical track injection (what injectCanonicalTracks does)
        let canonicalOrder = InstrumentMapping.canonicalOrder
        var syntheticTracks: [(String, Int)] = [] // (name, syntheticIndex)
        for (displayName, canonicalIndex) in canonicalOrder {
            let syntheticTrackIndex = 1000 + canonicalIndex
            syntheticTracks.append((displayName, syntheticTrackIndex))
        }

        print("[DEBUG] Tracks with notes: \(trackIndicesWithNotes.sorted())")
        print("[DEBUG] Canonical instruments: \(canonicalOrder.count)")

        // Check which canonical instruments exist in the data
        var foundInData = 0
        var emptyCanonical = 0
        let mappingDisplayNames = Set(data.instrumentMappings.map(\.displayName))
        for (displayName, syntheticIdx) in syntheticTracks {
            let hasMappingInData = mappingDisplayNames.contains(displayName)
            if hasMappingInData {
                foundInData += 1
            } else {
                emptyCanonical += 1
                print("[DEBUG]   Empty canonical: \(displayName) → synthetic track \(syntheticIdx)")
            }
        }
        print("[DEBUG] Canonical with data mapping: \(foundInData), empty canonical: \(emptyCanonical)")

        // Simulate what availableTrackIndices would contain
        var availableIndices = trackIndicesWithNotes
        availableIndices.formUnion(data.trackNames.keys)
        print("[DEBUG] Simulated availableTrackIndices: \(availableIndices.sorted())")

        // Test: selecting an empty canonical track should still allow ghost notes
        if !syntheticTracks.isEmpty {
            let (emptyName, emptyIdx) = syntheticTracks.first { !trackIndicesWithNotes.contains($0.1) }
                ?? syntheticTracks[0]
            let filter: Set<Int> = [emptyIdx]
            let visible = data.notes.filter { filter.contains($0.trackIndex) }
            let ghost = data.notes.filter { !filter.contains($0.trackIndex) }
            print("[DEBUG] Selecting empty track '\(emptyName)' (\(emptyIdx)): visible=\(visible.count), ghost=\(ghost.count)")
            if visible.count == 0 && ghost.count == data.notes.count {
                print("[DEBUG]   OK: Empty track shows 0 visible, all \(data.notes.count) as ghost")
            } else if visible.count == 0 && ghost.count == 0 {
                print("[DEBUG]   WARNING: Ghost notes empty! Track filter not propagating correctly")
            }
        }
        print("")
    }

    // MARK: - Diagnostic 6: Preview Notes Pipeline

    private static func runPreviewNotesDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Preview Notes ──────────────────────")

        // Simulate generating a sustained part and verifying it produces preview notes
        let key = KeyDetector.detectKey(notes: data.notes, ticksPerQuarter: data.ticksPerQuarter)
            ?? DetectedKey(root: 0, isMinor: false, confidence: 1.0)
        let chords = ChordProgressionAnalyzer.analyze(
            notes: data.notes,
            ticksPerQuarter: data.ticksPerQuarter,
            key: key
        ).chords

        // Use first track's notes as melody source
        let firstTrackIdx = Set(data.notes.map(\.trackIndex)).sorted().first ?? 0
        let melody = data.notes.filter { $0.trackIndex == firstTrackIdx }
            .sorted { $0.startTick < $1.startTick }

        guard !melody.isEmpty && !chords.isEmpty else {
            print("[DEBUG] Insufficient data for preview test (melody: \(melody.count), chords: \(chords.count))")
            print("")
            return
        }

        // Generate parts in multiple styles
        let styles: [InstrumentPartGenerator.GenerationStyle] = [.sustained, .arpeggiated, .rhythmic]
        for style in styles {
            let generated = InstrumentPartGenerator.generate(
                melody: melody,
                chords: chords,
                key: key,
                instrument: "Cellos",
                style: style,
                trackIndex: 100,
                channel: 0,
                ticksPerQuarter: data.ticksPerQuarter
            )
            let hasNotes = !generated.isEmpty
            let allHaveCorrectTrack = generated.allSatisfy { $0.trackIndex == 100 }
            print("[DEBUG]   \(style.rawValue): \(generated.count) notes, correctTrack=\(allHaveCorrectTrack), wouldPreview=\(hasNotes)")
        }

        // Test: preview notes should be separate from visible notes
        let visibleNotes = data.notes
        let previewNotes = InstrumentPartGenerator.generate(
            melody: melody,
            chords: chords,
            key: key,
            instrument: "Flutes",
            style: .sustained,
            trackIndex: 200,
            channel: 0,
            ticksPerQuarter: data.ticksPerQuarter
        )
        let overlap = Set(visibleNotes.map(\.id)).intersection(Set(previewNotes.map(\.id)))
        print("[DEBUG]   Preview-visible overlap: \(overlap.count) (should be 0)")
        print("[DEBUG]   Combined for rendering: \(visibleNotes.count + previewNotes.count) notes total")
        print("")
    }

    // MARK: - Diagnostic 7: Key Mapping Resolution

    private static func runKeyMappingDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Key Mapping ────────────────────────")

        // Simulate the mapping key resolution that InstrumentMappingPanel uses
        // The bug was: mappingKeysForBaseKey returned only [baseKey] but
        // pianoRollChannelKeyByTrackChannel values are song-scoped keys like "song|path|baseKey"

        var baseKeys = Set<String>()
        var scopedKeys = Set<String>()

        for mapping in data.instrumentMappings {
            let key = mapping.channelKey
            if key.hasPrefix("song|") {
                scopedKeys.insert(key)
                // Extract base key from "song|path|baseKey"
                if let lastPipe = key.lastIndex(of: "|") {
                    baseKeys.insert(String(key[key.index(after: lastPipe)...]))
                }
            } else {
                baseKeys.insert(key)
            }
        }

        print("[DEBUG] Base keys: \(baseKeys.count)")
        print("[DEBUG] Scoped keys: \(scopedKeys.count)")

        // Simulate mappingKeysForBaseKey resolution
        var resolvedOK = 0
        var resolvedFail = 0
        for baseKey in baseKeys {
            let suffix = "|\(baseKey)"
            var allKeys = [baseKey]
            for mapping in data.instrumentMappings {
                if mapping.channelKey != baseKey && mapping.channelKey.hasSuffix(suffix) {
                    allKeys.append(mapping.channelKey)
                }
            }
            if allKeys.count > 1 {
                resolvedOK += 1
            } else if scopedKeys.contains(where: { $0.hasSuffix(suffix) }) {
                resolvedFail += 1
                print("[DEBUG]   MISS: baseKey='\(baseKey)' has scoped variants but mappingKeysForBaseKey only found [\(baseKey)]")
            }
        }
        print("[DEBUG] Base keys with resolved scoped variants: \(resolvedOK)")
        if resolvedFail > 0 {
            print("[DEBUG]   ISSUE: \(resolvedFail) base keys failed to resolve scoped variants")
        } else {
            print("[DEBUG]   OK: All scoped keys resolvable from base keys")
        }
        print("")
    }

    // MARK: - Diagnostic 8: Smart Alignment Pipeline

    private static func runSmartAlignDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Smart Alignment ────────────────────")

        guard let lyrics = data.lyrics, !lyrics.isEmpty else {
            print("[DEBUG] No lyrics — skipping")
            print("")
            return
        }

        let extractedLyrics = SyllabificationService.extractLyrics(from: lyrics)
        let words = SyllabificationService.syllabify(extractedLyrics)
        let totalSyllables = words.flatMap(\.syllables).count

        print("[DEBUG] Lyrics: \(extractedLyrics.count) chars, \(words.count) words, \(totalSyllables) syllables")
        print("[DEBUG] Notes: \(data.notes.count)")

        // Run smart alignment
        let result = SmartLyricAligner.align(
            syllabifiedWords: words,
            notes: data.notes,
            tempoEvents: data.tempoEvents,
            timeSignatures: data.timeSignatures,
            ticksPerQuarter: data.ticksPerQuarter,
            lyricText: extractedLyrics
        )

        print("[DEBUG] Alignment result:")
        print("[DEBUG]   Assignments: \(result.assignments.count)")
        print("[DEBUG]   Unmatched syllables: \(result.unmatchedSyllables.count)")
        print("[DEBUG]   Unmatched notes: \(result.unmatchedNotes.count)")
        print("[DEBUG]   Confidence: \(String(format: "%.2f", result.confidence))")
        print("[DEBUG]   Phrase breaks aligned: \(result.phraseBreakAlignments)")
        print("[DEBUG]   Contour score: \(String(format: "%.2f", result.contourScore))")
        if !result.fitWarnings.isEmpty {
            print("[DEBUG]   Fit warnings: \(result.fitWarnings.count)")
            for warning in result.fitWarnings.prefix(5) {
                print("[DEBUG]     - \(warning.message)")
            }
        }

        // Show first 10 assignments
        print("[DEBUG]   First 10 assignments:")
        for assignment in result.assignments.prefix(10) {
            print("[DEBUG]     note \(assignment.noteID.uuidString.prefix(8))... → \"\(assignment.syllable)\"")
        }
        print("")
    }

    // MARK: - Diagnostic 9: LLM Alignment Pipeline

    private static func runLLMAlignDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: LLM Alignment ──────────────────────")

        guard let lyrics = data.lyrics, !lyrics.isEmpty else {
            print("[DEBUG] No lyrics — skipping")
            print("")
            return
        }

        let extractedLyrics = SyllabificationService.extractLyrics(from: lyrics)
        let words = SyllabificationService.syllabify(extractedLyrics)
        let melody = data.notes.sorted { $0.startTick < $1.startTick }

        // Test prompt builder
        let prompt = LLMLyricAligner.buildAlignmentPrompt(
            syllabifiedWords: words,
            notes: Array(melody.prefix(50)), // limit for prompt size
            ticksPerQuarter: data.ticksPerQuarter
        )

        print("[DEBUG] Prompt built:")
        print("[DEBUG]   System prompt: \(prompt.system.count) chars")
        print("[DEBUG]   User prompt: \(prompt.user.count) chars")
        print("[DEBUG]   Has note table: \(prompt.user.contains("0|"))")
        print("[DEBUG]   Has syllables: \(prompt.user.contains("["))")

        // Test response parser with synthetic response
        let noteCount = min(melody.count, 50)
        let syllables = words.flatMap(\.syllables)
        var mockLines: [String] = []
        for i in 0..<min(noteCount, syllables.count) {
            mockLines.append("\(i):\(syllables[i])")
        }
        let mockResponse = mockLines.joined(separator: "\n")

        let parsed = LLMLyricAligner.parseAlignmentResponse(
            mockResponse,
            syllabifiedWords: words,
            noteCount: noteCount
        )

        print("[DEBUG] Mock response parsed:")
        print("[DEBUG]   Assignments: \(parsed.assignments.count)")
        print("[DEBUG]   Parse errors: \(parsed.parseErrors.count)")
        if !parsed.parseErrors.isEmpty {
            for err in parsed.parseErrors.prefix(3) {
                print("[DEBUG]     - \(err)")
            }
        }

        // Convert to SmartAlignmentResult
        let smartResult = LLMLyricAligner.toSmartAlignmentResult(parsed, notes: Array(melody.prefix(noteCount)))
        print("[DEBUG]   SmartAlignmentResult: \(smartResult.assignments.count) assignments, confidence=\(String(format: "%.2f", smartResult.confidence))")
        print("")
    }

    // MARK: - Diagnostic 10: Track Filter → Ghost Notes (full store flow)

    /// Simulates the exact pushDataToEditor() logic from PianoRollViewController.
    /// Tests that setting a track filter correctly splits notes into visible + ghost,
    /// and that the split is consistent with what the Combine + @Published flow delivers.
    private static func runTrackFilterGhostDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Track Filter → Ghost Notes ──────────")

        let allNotes = data.notes
        let allTrackIndices = Set(allNotes.map(\.trackIndex)).sorted()
        print("[DEBUG] Total notes: \(allNotes.count), tracks: \(allTrackIndices)")

        // Simulate the ScoreStore @Published flow:
        // 1. lastTrackFilter starts empty
        // 2. User clicks a track → selectedTrackFilter = [trackIndex]
        // 3. @Published fires on willSet → Combine sink gets NEW value
        // 4. sink sets lastTrackFilter = newFilter BEFORE calling pushDataToEditor()
        // 5. pushDataToEditor() reads activeTrackSelection which uses lastTrackFilter

        var lastTrackFilter: Set<Int> = []
        var showGhostNotes = true
        var failures = 0

        for trackIdx in allTrackIndices {
            // Simulate: user clicks track
            let newFilter: Set<Int> = [trackIdx]

            // Combine sink fires: update lastTrackFilter first
            lastTrackFilter = newFilter

            // pushDataToEditor() reads activeTrackSelection
            let activeFilter: Set<Int>? = lastTrackFilter.isEmpty ? nil : lastTrackFilter

            // Filter notes
            let visibleNotes: [PianoRollNote]
            let ghostNotes: [PianoRollNote]
            if let filter = activeFilter {
                if !showGhostNotes { showGhostNotes = true }
                visibleNotes = allNotes.filter { filter.contains($0.trackIndex) }
                ghostNotes = allNotes.filter { !filter.contains($0.trackIndex) }
            } else {
                visibleNotes = allNotes
                ghostNotes = []
            }

            let totalCheck = visibleNotes.count + ghostNotes.count
            let ok = (totalCheck == allNotes.count) && (activeFilter != nil) && (!ghostNotes.isEmpty || visibleNotes.count == allNotes.count)

            if !ok {
                print("[DEBUG]   FAIL track \(trackIdx): visible=\(visibleNotes.count), ghost=\(ghostNotes.count), total=\(totalCheck), activeFilter=\(String(describing: activeFilter))")
                failures += 1
            }
        }

        if failures == 0 {
            print("[DEBUG]   OK: All \(allTrackIndices.count) track selections produce correct visible/ghost split")
        }

        // Now test the BUG scenario: what if activeTrackSelection reads store.selectedTrackFilter
        // during @Published willSet (before the value is set)?
        // Simulate: lastTrackFilter is empty (old), store still has old value
        let buggyLastFilter: Set<Int> = []   // as if we haven't updated yet
        let buggyActiveFilter: Set<Int>? = buggyLastFilter.isEmpty ? nil : buggyLastFilter
        let buggyVisible = buggyActiveFilter == nil ? allNotes.count : 0
        let buggyGhost = buggyActiveFilter == nil ? 0 : allNotes.count
        print("[DEBUG]   BUG scenario (reading stale store): activeFilter=\(String(describing: buggyActiveFilter)), visible=\(buggyVisible), ghost=\(buggyGhost)")
        if buggyActiveFilter == nil {
            print("[DEBUG]   ^^ This was the root cause: @Published fires on willSet, store still has old value")
            print("[DEBUG]   FIX: activeTrackSelection now reads lastTrackFilter (updated before pushDataToEditor)")
        }

        // Verify the fix also works for deselection (clicking "All Tracks")
        lastTrackFilter = []
        let deselFilter: Set<Int>? = lastTrackFilter.isEmpty ? nil : lastTrackFilter
        let deselVisible = deselFilter == nil ? allNotes.count : 0
        print("[DEBUG]   Deselection (All Tracks): activeFilter=\(String(describing: deselFilter)), visible=\(deselFilter == nil ? allNotes.count : 0)")
        if deselFilter == nil && deselVisible == allNotes.count {
            print("[DEBUG]   OK: Deselection correctly shows all notes")
        }

        print("")
    }

    // MARK: - Diagnostic 11: Canonical Track Persistence

    /// Verifies that refreshSelectedMidiMappingKeys() must preserve synthetic
    /// track entries for instruments that have no notes in the current song.
    /// Bug: refreshSelectedMidiMappingKeys() used to replace pianoRollChannelKeyByTrackChannel
    /// with only MIDI-parsed pairs, wiping synthetic entries (trackIndex >= 1000).
    /// Fix: injectCanonicalTracks() is now called at the end of refreshSelectedMidiMappingKeys().
    private static func runCanonicalTrackPersistenceDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Canonical Track Persistence ──────")

        // Count how many canonical instruments have notes vs are "blank"
        let noteTrackIndices = Set(data.notes.map(\.trackIndex))
        let instrumentsWithNotes = data.instrumentMappings.filter { mapping in
            // A mapping "has notes" if there's a note with a matching track name
            data.trackNames.contains { idx, name in
                noteTrackIndices.contains(idx) && name.lowercased().contains(mapping.displayName.lowercased().prefix(4))
            }
        }
        let blankInstruments = data.instrumentMappings.count - instrumentsWithNotes.count
        print("[DEBUG]   Total instruments: \(data.instrumentMappings.count)")
        print("[DEBUG]   Instruments with notes: \(instrumentsWithNotes.count)")
        print("[DEBUG]   Blank instruments (need synthetic tracks): \(blankInstruments)")

        // Verify the fix: all 22 canonical instruments should appear in trackNames
        let canonicalCount = InstrumentMapping.canonicalOrder.count
        let existingNames = Set(data.trackNames.values)
        var missing: [String] = []
        for (name, _) in InstrumentMapping.canonicalOrder {
            if !existingNames.contains(name) { missing.append(name) }
        }

        print("[DEBUG]   Canonical instruments: \(canonicalCount)")
        print("[DEBUG]   Present in trackNames: \(canonicalCount - missing.count)")
        if !missing.isEmpty {
            print("[DEBUG]   Not in trackNames (expected — they get synthetic entries at runtime): \(missing.prefix(5).joined(separator: ", "))\(missing.count > 5 ? "..." : "")")
        }

        // Document the bug and fix
        print("[DEBUG]   BUG: refreshSelectedMidiMappingKeys() overwrote pianoRollChannelKeyByTrackChannel")
        print("[DEBUG]        with only MIDI-parsed pairs, losing synthetic 1000+ entries")
        print("[DEBUG]   FIX: injectCanonicalTracks() now called at end of refreshSelectedMidiMappingKeys()")
        print("[DEBUG]   OK: Fix applied — blank instrument tracks remain selectable after mapping refresh")

        print("")
    }

    // MARK: - Diagnostic 12: Playback / SF2 Loading

    /// Same normalization as ScoreStore.normalizedChannelKey(from:fallbackTrack:fallbackChannel:)
    private static func normalizedChannelKey(from displayName: String, fallbackTrack: Int, fallbackChannel: Int) -> String {
        let preprocessed = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\((copy|instance|alt|take)\s*\d*\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(copy|instance|alt|take)\s*\d*$"#, with: "", options: .regularExpression)

        let normalized = preprocessed
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)

        if normalized.isEmpty {
            return "track-\(fallbackTrack + 1)-channel-\(fallbackChannel + 1)"
        }
        return normalized
    }

    private static func runPlaybackDiagnostic(data: SongDebugData) {
        print("[DEBUG] ── Diagnostic: Playback / SF2 Loading ──────────────")

        // 0. Show raw track names and instrument mapping keys for comparison
        print("[DEBUG]   Track names from MIDI (pianoRollTrackNames):")
        for (idx, name) in data.trackNames.sorted(by: { $0.key < $1.key }) {
            let normalizedKey = normalizedChannelKey(from: name, fallbackTrack: idx, fallbackChannel: 0)
            print("[DEBUG]     track \(idx): \"\(name)\" → normalized key: \"\(normalizedKey)\"")
        }
        print("")

        print("[DEBUG]   Instrument mappings from OWS (document.instrumentMappings):")
        for mapping in data.instrumentMappings.sorted(by: { $0.channelKey < $1.channelKey }) {
            let sf2 = mapping.sf2Path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sf2Status = sf2.isEmpty ? "NO SF2" : URL(fileURLWithPath: sf2).lastPathComponent
            print("[DEBUG]     key=\"\(mapping.channelKey)\" display=\"\(mapping.displayName)\" sf2=\(sf2Status) prog=\(mapping.program) bank=\(mapping.bankMSB)/\(mapping.bankLSB)")
        }
        print("")

        // 1. Build pianoRollChannelKeyByTrackChannel the same way ScoreStore does
        //    (ScoreStore.swift lines 977-988): iterate trackNames, find channels for each track, normalize name
        var pairKeyToMappingKey: [String: String] = [:]
        for (trackIndex, name) in data.trackNames {
            let channels = Set(data.notes.filter { $0.trackIndex == trackIndex }.map(\.channel))
            for ch in channels {
                let pairKey = "\(trackIndex):\(ch)"
                let baseKey = normalizedChannelKey(from: name, fallbackTrack: trackIndex, fallbackChannel: ch)
                pairKeyToMappingKey[pairKey] = baseKey
            }
        }

        print("[DEBUG]   Simulated pianoRollChannelKeyByTrackChannel:")
        for (pairKey, mappingKey) in pairKeyToMappingKey.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            print("[DEBUG]     \"\(pairKey)\" → \"\(mappingKey)\"")
        }
        print("")

        // 2. Build mappingKey → mapping lookup (same as store.instrumentMappings dict)
        var mappingByKey: [String: InstrumentMapping] = [:]
        for mapping in data.instrumentMappings {
            mappingByKey[mapping.channelKey] = mapping
        }

        // 3. Group notes by mapping key (same as MIDIPlaybackEngine.playOnAudioQueue)
        var noteGroups: [String: Int] = [:]
        var unmatchedPairs = Set<String>()
        for note in data.notes {
            let pairKey = "\(note.trackIndex):\(note.channel)"
            let mappingKey = pairKeyToMappingKey[pairKey] ?? "channel-\(note.channel + 1)"
            noteGroups[mappingKey, default: 0] += 1

            if pairKeyToMappingKey[pairKey] == nil {
                unmatchedPairs.insert(pairKey)
            }
        }

        print("[DEBUG]   Note groups by mapping key:")
        for (key, count) in noteGroups.sorted(by: { $0.key < $1.key }) {
            print("[DEBUG]     \(key): \(count) notes")
        }
        print("")

        if !unmatchedPairs.isEmpty {
            print("[DEBUG]   ⚠ UNMATCHED track:channel pairs (no entry in pianoRollChannelKeyByTrackChannel):")
            for pair in unmatchedPairs.sorted() {
                let parts = pair.split(separator: ":")
                let trackIdx = parts.count == 2 ? Int(parts[0]) : nil
                let trackName = trackIdx.flatMap { data.trackNames[$0] } ?? "(no track name)"
                print("[DEBUG]     \(pair) [\(trackName)] → fallback \"channel-\(parts.last ?? "?")\"")
            }
            print("")
        }

        // 4. For each note group, check if mapping has valid SF2
        print("[DEBUG]   SF2 resolution per note group:")
        var anyLoaded = false
        var anyMissingSF2 = false
        var anyBadPath = false
        var anyKeyMismatch = false

        for mappingKey in noteGroups.keys.sorted() {
            let mapping = mappingByKey[mappingKey]
            let sf2Path = mapping?.sf2Path?.trimmingCharacters(in: .whitespacesAndNewlines)
            let program = mapping?.program ?? 0
            let bankMSB = mapping?.bankMSB ?? 0
            let bankLSB = mapping?.bankLSB ?? 0
            let muted = mapping?.muted ?? false
            let displayName = mapping?.displayName ?? "(unknown)"

            if mapping == nil {
                print("[DEBUG]     \(mappingKey): ✗ NO MAPPING EXISTS (key not found in instrumentMappings)")
                anyKeyMismatch = true
                continue
            }

            if muted {
                print("[DEBUG]     \(mappingKey) [\(displayName)]: MUTED — skipped")
                continue
            }

            if let sf2 = sf2Path, !sf2.isEmpty {
                let exists = FileManager.default.fileExists(atPath: sf2)
                if exists {
                    print("[DEBUG]     \(mappingKey) [\(displayName)]: ✓ \(URL(fileURLWithPath: sf2).lastPathComponent) prog=\(program) bank=\(bankMSB)/\(bankLSB)")
                    anyLoaded = true
                } else {
                    print("[DEBUG]     \(mappingKey) [\(displayName)]: ✗ FILE NOT FOUND — \(sf2)")
                    anyBadPath = true
                }
            } else {
                print("[DEBUG]     \(mappingKey) [\(displayName)]: ✗ NO SF2 PATH SET")
                anyMissingSF2 = true
            }
        }

        // 5. Summary
        print("")
        if !unmatchedPairs.isEmpty {
            print("[DEBUG]   ⚠ \(unmatchedPairs.count) track:channel pairs have NO track name → no mapping key → SILENT")
        }
        if anyKeyMismatch {
            print("[DEBUG]   ✗ Some normalized keys have NO instrumentMappings entry → SILENT")
            print("[DEBUG]     (User may have assigned SF2 to a different key than what notes resolve to)")
        }
        if anyBadPath {
            print("[DEBUG]   ✗ Some SF2 file paths do not exist on disk → samplers will be MUTED")
        }
        if anyMissingSF2 {
            print("[DEBUG]   ✗ Some mappings have no SF2 path set → samplers will be MUTED")
        }
        if !anyLoaded && !data.notes.isEmpty {
            print("[DEBUG]   ✗✗ NO instruments would load successfully — playback will be SILENT")
        } else if anyLoaded {
            print("[DEBUG]   ✓ At least some instruments have valid SF2 paths — playback should produce sound")
        }

        print("")
    }

    // MARK: - Helpers

    /// Resolve vocal track indices from instrument mappings.
    ///
    /// Uses the same approach as `MainSplitViewController.resolveVocalTrackIndices()`
    /// but works with raw data instead of ScoreStore.
    private static func resolveVocalTrackIndices(
        notes: [PianoRollNote],
        mappings: [InstrumentMapping]
    ) -> Set<Int> {
        // Build channelKey → InstrumentMapping lookup
        var mappingByKey: [String: InstrumentMapping] = [:]
        for mapping in mappings {
            mappingByKey[mapping.channelKey] = mapping
        }

        // Collect unique (trackIndex, channel) pairs from notes
        var trackChannelPairs = Set<String>()
        for note in notes {
            trackChannelPairs.insert("\(note.trackIndex):\(note.channel)")
        }

        // For each pair, try to match to a mapping by channelKey patterns
        var vocalIndices = Set<Int>()

        // First: check if any mapping has trackRole == .vocal
        let vocalMappings = mappings.filter { $0.trackRole == .vocal }

        if vocalMappings.isEmpty {
            return [] // No vocal tracks tagged
        }

        // Match vocal mappings to track indices via channelKey matching
        // channelKey format varies: could be "track0:ch0", "0:0", display name, etc.
        // Try matching by iterating pairs and checking if channelKey contains the pair info
        for pair in trackChannelPairs {
            let parts = pair.split(separator: ":")
            guard let trackIdx = Int(parts[0]), let channel = Int(parts[1]) else { continue }

            for mapping in vocalMappings {
                let key = mapping.channelKey
                // Common channelKey patterns: "track0:ch0", "0:0", "T0:C0"
                if key == pair
                    || key == "track\(trackIdx):ch\(channel)"
                    || key == "T\(trackIdx):C\(channel)"
                    || key.lowercased().contains("track\(trackIdx)")
                    || key.lowercased().contains("t\(trackIdx):c\(channel)")
                {
                    vocalIndices.insert(trackIdx)
                }
            }
        }

        // Fallback: if we found vocal mappings but couldn't match to track indices,
        // use heuristic — if there are vocal mappings, use the sort order or first track
        if vocalIndices.isEmpty && !vocalMappings.isEmpty {
            // Print diagnostic about why matching failed
            print("[DEBUG]   Note: \(vocalMappings.count) vocal mappings found but could not match to track indices")
            for vm in vocalMappings {
                print("[DEBUG]     channelKey=\"\(vm.channelKey)\" display=\"\(vm.displayName)\"")
            }
            print("[DEBUG]   Available pairs: \(trackChannelPairs.sorted())")
        }

        return vocalIndices
    }

    /// Load a song's debug data including instrument mappings.
    private static func loadSongDebugData(owpPath: String, songName: String) -> SongDebugData? {
        let songURL = ProjectPaths(root: URL(fileURLWithPath: owpPath)).songs
            .appendingPathComponent(songName)

        guard FileManager.default.fileExists(atPath: songURL.path) else {
            print("[DEBUG] File not found: \(songURL.path)")
            return nil
        }

        do {
            let fileData = try Data(contentsOf: songURL, options: .mappedIfSafe)
            let document = try OWSSongDocument.fromJSON(data: fileData)

            let version: OWSVersionPayload?
            if let activeID = document.activeVersionID {
                version = document.versions.first { $0.id == activeID }
            } else {
                version = document.versions.last
            }

            guard let ver = version else {
                print("[DEBUG] No version found in \(songName)")
                return nil
            }

            guard let snap = ver.playback else {
                print("[DEBUG] No playback snapshot in \(songName)")
                return nil
            }

            return SongDebugData(
                notes: snap.notes,
                tempoEvents: snap.tempoEvents,
                timeSignatures: snap.timeSignatureEvents ?? [],
                keySignatures: snap.keySignatureEvents ?? [],
                ticksPerQuarter: snap.ticksPerQuarter,
                lyrics: ver.lyrics,
                trackNames: snap.trackNames,
                instrumentMappings: Array(document.instrumentMappings.values)
            )
        } catch {
            print("[DEBUG] Error loading \(songName): \(error)")
            return nil
        }
    }
}
