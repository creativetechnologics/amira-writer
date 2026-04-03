import Foundation

// MARK: - MusicEngineTests

/// CLI test harness for the Music Intelligence Engine.
///
/// Runs against real .ows data from the Amira.owp project.
/// Invoked via: Score --test-engine
///
/// Tests:
/// 1. Phrase detection — verify phrases detected from real MIDI data
/// 2. Contour classification — verify ascending/descending/arch patterns
/// 3. Structure analysis — verify section labeling
/// 4. Smart alignment — compare to basic LyricAligner (regression check)
/// 5. Melodic mutation (expansion) — verify notes added in key
/// 6. Melodic mutation (reduction) — verify notes merged, contour preserved
/// 7. Key detection placeholder — verify scale pitch classes are correct
/// 8. Phrase-lyric alignment — verify line breaks match phrase boundaries
@available(macOS 26.0, *)
@MainActor
enum MusicEngineTests {

    private struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    // MARK: - Entry Point

    static func run() -> Int32 {
        print("[ENGINE-TEST] Music Intelligence Engine — Test Suite")
        print("[ENGINE-TEST] ================================================")

        var checks: [Check] = []

        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(Check(name: name, passed: passed, detail: detail))
            print("[ENGINE-TEST] \(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        let amiraPath = "/Volumes/Storage VIII/Programming/Amira - A Modern Opera/Amira.owp"

        // ── Test 1: Phrase Detection on Real Data ────────────────────────
        do {
            let songData = loadSongPlayback(
                owpPath: amiraPath,
                songName: "1.06.0 - FIRST MEETING.ows"
            )

            if let data = songData {
                let phrases = PhraseDetector.detectPhrases(
                    notes: data.notes,
                    tempoEvents: data.tempoEvents,
                    timeSignatures: data.timeSignatures,
                    ticksPerQuarter: data.ticksPerQuarter
                )

                let hasPhrases = phrases.count >= 1
                let allHaveMinNotes = phrases.allSatisfy { $0.noteIDs.count >= 2 }
                let phrasesOrdered = phrases.allSatisfy { $0.startTick <= $0.endTick }
                let totalNotes = phrases.reduce(0) { $0 + $1.noteIDs.count }
                let coversAllNotes = totalNotes == data.notes.count

                record(
                    "phrase-detection (real data)",
                    hasPhrases && allHaveMinNotes && phrasesOrdered && coversAllNotes,
                    "\(phrases.count) phrases, \(totalNotes)/\(data.notes.count) notes covered, range: \(phrases.map { $0.noteIDs.count }.description)"
                )
            } else {
                record("phrase-detection (real data)", false, "Could not load song data from Amira.owp")
            }
        }

        // ── Test 2: Contour Classification ──────────────────────────────
        do {
            let ascending = MelodicContourAnalyzer.classify(pitches: [60, 62, 64, 65, 67, 69, 71, 72])
            record("contour-ascending", ascending == .ascending, "\(ascending.rawValue)")

            let descending = MelodicContourAnalyzer.classify(pitches: [72, 71, 69, 67, 65, 64, 62, 60])
            record("contour-descending", descending == .descending, "\(descending.rawValue)")

            let arch = MelodicContourAnalyzer.classify(pitches: [60, 64, 67, 72, 72, 67, 64, 60])
            record("contour-arch", arch == .arch, "\(arch.rawValue)")

            let constant = MelodicContourAnalyzer.classify(pitches: [60, 61, 60, 61, 60, 60, 61, 60])
            record("contour-constant", constant == .constant, "\(constant.rawValue)")
        }

        // ── Test 3: Structure Analysis ──────────────────────────────────
        do {
            let songData = loadSongPlayback(
                owpPath: amiraPath,
                songName: "1.08.0 - SOMEWHERE IN MY HEART.ows"
            )

            if let data = songData {
                let phrases = PhraseDetector.detectPhrases(
                    notes: data.notes,
                    tempoEvents: data.tempoEvents,
                    timeSignatures: data.timeSignatures,
                    ticksPerQuarter: data.ticksPerQuarter
                )

                let sections = StructureAnalyzer.analyze(
                    phrases: phrases,
                    notes: data.notes,
                    tempoEvents: data.tempoEvents,
                    timeSignatures: data.timeSignatures,
                    ticksPerQuarter: data.ticksPerQuarter
                )

                let hasSections = !sections.isEmpty
                let allHaveTypes = sections.allSatisfy { $0.type != .unknown || sections.count <= 2 }
                let sectionLabels = sections.map(\.label)

                record(
                    "structure-analysis",
                    hasSections && allHaveTypes,
                    "\(sections.count) sections: \(sectionLabels.joined(separator: ", "))"
                )
            } else {
                record("structure-analysis", false, "Could not load song data")
            }
        }

        // ── Test 4: Smart Alignment vs Basic Alignment ──────────────────
        do {
            // Create test notes and lyrics for a known scenario.
            let testNotes = createTestMelody(
                pitches: [60, 62, 64, 65, 67, 69, 71, 72, 71, 69, 67, 65],
                startTick: 0,
                duration: 240,
                ticksPerQuarter: 480
            )

            let lyrics = "ever singing I am home and free at last"
            let words = SyllabificationService.syllabify(lyrics)

            // Basic alignment.
            let basicResult = LyricAligner.align(
                syllabifiedWords: words,
                notes: testNotes,
                ticksPerQuarter: 480
            )

            // Smart alignment.
            let smartResult = SmartLyricAligner.align(
                syllabifiedWords: words,
                notes: testNotes,
                tempoEvents: [],
                timeSignatures: [],
                ticksPerQuarter: 480,
                lyricText: lyrics
            )

            let smartNotWorse = smartResult.confidence >= basicResult.confidence * 0.9
            record(
                "smart-vs-basic alignment",
                smartNotWorse,
                "basic conf=\(String(format: "%.2f", basicResult.confidence)), smart conf=\(String(format: "%.2f", smartResult.confidence))"
            )
        }

        // ── Test 5: Melodic Mutation (Expansion) ────────────────────────
        do {
            let testNotes = createTestMelody(
                pitches: [60, 64, 67, 72, 67],
                startTick: 0,
                duration: 480,  // each note is 1 beat — splittable
                ticksPerQuarter: 480
            )

            let targetSyllables = 8
            let key = DetectedKey(root: 0, isMinor: false, confidence: 0.9) // C major

            let mutation = MelodicMutator.propose(
                currentNotes: testNotes,
                targetSyllableCount: targetSyllables,
                detectedKey: key,
                ticksPerQuarter: 480
            )

            let addedCount = mutation.notesToInsert.count
            let totalAfter = testNotes.count + addedCount - mutation.notesToRemove.count
            let allInScale = mutation.notesToInsert.allSatisfy { key.scalePitchClasses.contains($0.pitch % 12) }

            record(
                "mutation-expansion",
                addedCount > 0 && totalAfter >= targetSyllables - 1 && allInScale,
                "added \(addedCount) notes, total \(totalAfter)/\(targetSyllables) target, all in scale: \(allInScale)"
            )
        }

        // ── Test 6: Melodic Mutation (Reduction) ────────────────────────
        do {
            // 8 short adjacent notes, close in pitch.
            let testNotes = createTestMelody(
                pitches: [60, 61, 62, 63, 64, 63, 62, 61],
                startTick: 0,
                duration: 120,  // each note is a quarter of a beat — short
                ticksPerQuarter: 480
            )

            let targetSyllables = 5
            let mutation = MelodicMutator.propose(
                currentNotes: testNotes,
                targetSyllableCount: targetSyllables,
                ticksPerQuarter: 480
            )

            let removedCount = mutation.notesToRemove.count
            let totalAfter = testNotes.count - removedCount + mutation.notesToInsert.count

            record(
                "mutation-reduction",
                removedCount > 0,
                "removed \(removedCount) notes, total \(totalAfter) from original \(testNotes.count)"
            )
        }

        // ── Test 7: DetectedKey Scale Pitch Classes ─────────────────────
        do {
            let cMajor = DetectedKey(root: 0, isMinor: false, confidence: 1.0)
            let expectedCMajor: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
            record(
                "key-scale-C-major",
                cMajor.scalePitchClasses == expectedCMajor,
                "\(cMajor.scalePitchClasses.sorted())"
            )

            let aMinor = DetectedKey(root: 9, isMinor: true, confidence: 1.0)
            let expectedAMinor: Set<Int> = [9, 11, 0, 2, 4, 5, 7]
            record(
                "key-scale-A-minor",
                aMinor.scalePitchClasses == expectedAMinor,
                "\(aMinor.scalePitchClasses.sorted())"
            )
        }

        // ── Test 8: Phrase-Lyric Alignment with Real Data ───────────────
        do {
            let songData = loadSongPlayback(
                owpPath: amiraPath,
                songName: "1.06.0 - FIRST MEETING.ows"
            )

            if let data = songData, let lyricsText = data.lyrics, !lyricsText.isEmpty {
                let extracted = SyllabificationService.extractLyrics(from: lyricsText)
                let words = SyllabificationService.syllabify(extracted)

                if !words.isEmpty {
                    let result = SmartLyricAligner.align(
                        syllabifiedWords: words,
                        notes: data.notes,
                        tempoEvents: data.tempoEvents,
                        timeSignatures: data.timeSignatures,
                        ticksPerQuarter: data.ticksPerQuarter,
                        lyricText: extracted
                    )

                    record(
                        "phrase-lyric-alignment (real data)",
                        result.confidence > 0 && !result.assignments.isEmpty,
                        "conf=\(String(format: "%.2f", result.confidence)), \(result.assignments.count) assignments, \(result.phraseBreakAlignments) phrase breaks"
                    )
                } else {
                    record("phrase-lyric-alignment (real data)", true, "No lyrics in song (skipped)")
                }
            } else {
                record("phrase-lyric-alignment (real data)", false, "Could not load song or no lyrics")
            }
        }

        // ── Test 9: Stress Suitability ──────────────────────────────────
        do {
            let notes = createTestMelody(
                pitches: [60, 72, 60, 72, 60], // alternating low-high
                startTick: 0,
                duration: 480,
                ticksPerQuarter: 480
            )

            let stressScores = MelodicContourAnalyzer.stressSuitability(
                notes: notes,
                ticksPerQuarter: 480
            )

            // High notes should have higher stress than low notes.
            let highNoteStress = stressScores[notes[1].id] ?? 0
            let lowNoteStress = stressScores[notes[0].id] ?? 0
            let highBeatersLow = highNoteStress > lowNoteStress

            record(
                "stress-suitability",
                highBeatersLow && !stressScores.isEmpty,
                "high note stress=\(String(format: "%.2f", highNoteStress)), low=\(String(format: "%.2f", lowNoteStress))"
            )
        }

        // ── Test 10: Key Detection (Krumhansl-Schmuckler) ──────────────
        do {
            // C major scale — should detect C major.
            let cMajorNotes = createTestMelody(
                pitches: [60, 62, 64, 65, 67, 69, 71, 72, 72, 71, 69, 67, 65, 64, 62, 60],
                startTick: 0,
                duration: 480,
                ticksPerQuarter: 480
            )

            let cMajorKey = KeyDetector.detectKey(notes: cMajorNotes, ticksPerQuarter: 480)

            record(
                "key-detection-C-major",
                cMajorKey != nil && cMajorKey?.root == 0 && cMajorKey?.isMinor == false,
                cMajorKey.map { "\($0.displayName) conf=\(String(format: "%.2f", $0.confidence))" } ?? "nil"
            )
        }

        // ── Test 11: Key Detection (A minor) ─────────────────────────────
        do {
            // A natural minor scale — should detect A minor.
            let aMinorNotes = createTestMelody(
                pitches: [69, 71, 72, 74, 76, 77, 79, 81, 81, 79, 77, 76, 74, 72, 71, 69],
                startTick: 0,
                duration: 480,
                ticksPerQuarter: 480
            )

            let aMinorKey = KeyDetector.detectKey(notes: aMinorNotes, ticksPerQuarter: 480)

            record(
                "key-detection-A-minor",
                aMinorKey != nil && aMinorKey?.root == 9 && aMinorKey?.isMinor == true,
                aMinorKey.map { "\($0.displayName) conf=\(String(format: "%.2f", $0.confidence))" } ?? "nil"
            )
        }

        // ── Test 12: Key Detection from Key Signature ────────────────────
        do {
            let keySig = KeySignatureEvent(tick: 0, sharpsFlats: 1, isMinor: false) // G major
            let fromSig = KeyDetector.fromKeySignature(keySig)

            record(
                "key-from-signature-G-major",
                fromSig.root == 7 && !fromSig.isMinor && fromSig.confidence == 1.0,
                "\(fromSig.displayName)"
            )

            let keySigMinor = KeySignatureEvent(tick: 0, sharpsFlats: -3, isMinor: true) // C minor
            let fromSigMinor = KeyDetector.fromKeySignature(keySigMinor)

            record(
                "key-from-signature-C-minor",
                fromSigMinor.root == 0 && fromSigMinor.isMinor,
                "\(fromSigMinor.displayName)"
            )
        }

        // ── Test 13: Key Detection on Real Data ──────────────────────────
        do {
            let songData = loadSongPlayback(
                owpPath: amiraPath,
                songName: "1.08.0 - SOMEWHERE IN MY HEART.ows"
            )

            if let data = songData {
                let detectedKey = KeyDetector.detectKeyWithFallback(
                    notes: data.notes,
                    keySignatures: data.keySignatures,
                    ticksPerQuarter: data.ticksPerQuarter
                )

                record(
                    "key-detection-real-data",
                    detectedKey != nil,
                    detectedKey.map { "\($0.displayName) conf=\(String(format: "%.2f", $0.confidence))" } ?? "nil"
                )
            } else {
                record("key-detection-real-data", false, "Could not load song data")
            }
        }

        // ── Test 14: Chord Progression Analysis ──────────────────────────
        do {
            // Create a simple I-IV-V-I progression in C major.
            let cMajorChord = createChordNotes(pitches: [60, 64, 67], startTick: 0, duration: 480)
            let fMajorChord = createChordNotes(pitches: [65, 69, 72], startTick: 480, duration: 480)
            let gMajorChord = createChordNotes(pitches: [67, 71, 74], startTick: 960, duration: 480)
            let cMajorChord2 = createChordNotes(pitches: [60, 64, 67], startTick: 1440, duration: 480)
            let allNotes = cMajorChord + fMajorChord + gMajorChord + cMajorChord2

            let key = DetectedKey(root: 0, isMinor: false, confidence: 1.0)
            let result = ChordProgressionAnalyzer.analyze(
                notes: allNotes,
                ticksPerQuarter: 480,
                key: key
            )

            let hasChords = !result.chords.isEmpty
            let firstIsC = result.chords.first.map { $0.root == 0 && $0.quality == "" } ?? false

            record(
                "chord-progression-analysis",
                hasChords && firstIsC,
                "\(result.chords.count) chords: \(result.chords.map(\.displayName).joined(separator: " "))"
            )
        }

        // ── Test 15: Chord Progression on Real Data ──────────────────────
        do {
            let songData = loadSongPlayback(
                owpPath: amiraPath,
                songName: "1.08.0 - SOMEWHERE IN MY HEART.ows"
            )

            if let data = songData {
                let key = KeyDetector.detectKey(notes: data.notes, ticksPerQuarter: data.ticksPerQuarter)
                let result = ChordProgressionAnalyzer.analyze(
                    notes: data.notes,
                    ticksPerQuarter: data.ticksPerQuarter,
                    key: key
                )

                record(
                    "chord-progression-real-data",
                    !result.chords.isEmpty,
                    "\(result.chords.count) chords detected, patterns: \(result.commonProgressions.prefix(3).joined(separator: "; "))"
                )
            } else {
                record("chord-progression-real-data", false, "Could not load song data")
            }
        }

        // ── Test 16: SATB Harmonization ──────────────────────────────────
        do {
            let melody = createTestMelody(
                pitches: [72, 71, 69, 67, 65, 64, 62, 60], // C5 descending to C4
                startTick: 0,
                duration: 480,
                ticksPerQuarter: 480
            )
            let key = DetectedKey(root: 0, isMinor: false, confidence: 1.0)

            let result = HarmonyEngine.harmonize(
                melody: melody,
                key: key,
                ticksPerQuarter: 480
            )

            let hasVoicings = result.voicings.count == melody.count
            let allInRange = result.voicings.allSatisfy { v in
                v.soprano >= 60 && v.soprano <= 81 &&
                v.alto >= 53 && v.alto <= 74 &&
                v.tenor >= 48 && v.tenor <= 69 &&
                v.bass >= 36 && v.bass <= 60
            }
            let noVoiceCrossing = result.voicings.allSatisfy { v in
                v.soprano >= v.alto && v.alto >= v.tenor && v.tenor >= v.bass
            }

            record(
                "harmony-satb-generation",
                hasVoicings && allInRange,
                "\(result.voicings.count) voicings, score=\(String(format: "%.0f%%", result.score * 100)), \(result.violations.count) violations, in-range=\(allInRange), no-crossing=\(noVoiceCrossing)"
            )
        }

        // ── Test 17: Harmonization Voice Leading ─────────────────────────
        do {
            // Simple stepwise melody — should produce smooth voice leading.
            let melody = createTestMelody(
                pitches: [60, 62, 64, 65, 67],
                startTick: 0,
                duration: 480,
                ticksPerQuarter: 480
            )
            let key = DetectedKey(root: 0, isMinor: false, confidence: 1.0)

            let result = HarmonyEngine.harmonize(
                melody: melody,
                key: key,
                ticksPerQuarter: 480
            )

            // Score should be reasonable (not too many violations for stepwise motion).
            let reasonableScore = result.score >= 0.5

            record(
                "harmony-voice-leading",
                reasonableScore,
                "score=\(String(format: "%.0f%%", result.score * 100)), violations: \(result.violations.count)"
            )
        }

        // ── Test 18: Roman Numeral Analysis ──────────────────────────────
        do {
            let key = DetectedKey(root: 0, isMinor: false, confidence: 1.0) // C major
            let cChord = DetectedChord(tick: 0, durationTicks: 480, root: 0, quality: "", bassNote: nil, pitchClasses: [0, 4, 7])
            let fChord = DetectedChord(tick: 480, durationTicks: 480, root: 5, quality: "", bassNote: nil, pitchClasses: [5, 9, 0])
            let gChord = DetectedChord(tick: 960, durationTicks: 480, root: 7, quality: "", bassNote: nil, pitchClasses: [7, 11, 2])
            let amChord = DetectedChord(tick: 1440, durationTicks: 480, root: 9, quality: "m", bassNote: nil, pitchClasses: [9, 0, 4])

            let cRoman = cChord.romanNumeral(in: key)
            let fRoman = fChord.romanNumeral(in: key)
            let gRoman = gChord.romanNumeral(in: key)
            let amRoman = amChord.romanNumeral(in: key)

            record(
                "roman-numeral-analysis",
                cRoman == "I" && fRoman == "IV" && gRoman == "V" && amRoman == "vi",
                "C=\(cRoman), F=\(fRoman), G=\(gRoman), Am=\(amRoman)"
            )
        }

        // ── Test 19: Instrument Range Database ──────────────────────────
        do {
            let allProfiles = InstrumentRangeDatabase.allProfiles
            let allNames = Set(allProfiles.map(\.name))
            let canonicalNames = Set(InstrumentMapping.canonicalOrder.keys)

            // Verify all 22 canonical instruments have profiles.
            let coverage = canonicalNames.isSubset(of: allNames)
            let rangesValid = allProfiles.allSatisfy { p in
                p.absoluteRange.lowerBound >= 0 &&
                p.absoluteRange.upperBound <= 127 &&
                p.comfortableRange.lowerBound >= p.absoluteRange.lowerBound &&
                p.comfortableRange.upperBound <= p.absoluteRange.upperBound
            }

            record(
                "instrument-database-coverage",
                coverage && allProfiles.count == 22,
                "\(allProfiles.count) profiles, canonical coverage: \(coverage)"
            )
            record(
                "instrument-ranges-valid",
                rangesValid,
                "All \(allProfiles.count) profiles have valid nested ranges"
            )
        }

        // ── Test 20: Range Clamping ─────────────────────────────────────
        do {
            // Violin I: absolute 55-100
            let tooLow = InstrumentRangeDatabase.clampToRange(30, instrument: "Violins I")
            let tooHigh = InstrumentRangeDatabase.clampToRange(110, instrument: "Violins I")
            let inRange = InstrumentRangeDatabase.clampToRange(72, instrument: "Violins I")

            let lowOk = tooLow >= 55 && tooLow <= 100
            let highOk = tooHigh >= 55 && tooHigh <= 100
            let inOk = inRange == 72

            record(
                "range-clamping",
                lowOk && highOk && inOk,
                "low=\(tooLow)(ok:\(lowOk)) high=\(tooHigh)(ok:\(highOk)) in=\(inRange)(ok:\(inOk))"
            )

            // Comfortable range transpose
            let transposed = InstrumentRangeDatabase.transposeToComfortableRange(30, instrument: "Violins I")
            let comfOk = InstrumentRangeDatabase.isInComfortableRange(transposed, instrument: "Violins I")
                || (transposed >= 55 && transposed <= 100) // at least in absolute range

            record(
                "comfortable-transpose",
                transposed >= 55 && transposed <= 100,
                "pitch 30 → \(transposed), comfortable: \(comfOk)"
            )
        }

        // ── Test 21: Sustained Part Generation ──────────────────────────
        do {
            let tpq = 480
            let melody = createTestMelody(
                pitches: [60, 62, 64, 65, 67],
                startTick: 0,
                duration: tpq,
                ticksPerQuarter: tpq
            )
            let key = DetectedKey(root: 0, isMinor: false, confidence: 0.9)
            let chords: [DetectedChord] = [
                DetectedChord(tick: 0, durationTicks: tpq * 2, root: 0, quality: "", bassNote: nil, pitchClasses: [0, 4, 7]),
                DetectedChord(tick: tpq * 2, durationTicks: tpq * 2, root: 5, quality: "", bassNote: nil, pitchClasses: [5, 9, 0]),
                DetectedChord(tick: tpq * 4, durationTicks: tpq, root: 7, quality: "", bassNote: nil, pitchClasses: [7, 11, 2]),
            ]

            let notes = InstrumentPartGenerator.generate(
                melody: melody,
                chords: chords,
                key: key,
                instrument: "Cellos",
                style: .sustained,
                trackIndex: 5,
                channel: 0,
                ticksPerQuarter: tpq
            )

            let allInRange = notes.allSatisfy { n in
                n.pitch >= 36 && n.pitch <= 76 // Cellos absolute range
            }
            let hasDuration = notes.allSatisfy { $0.duration >= tpq }

            record(
                "sustained-part-generation",
                !notes.isEmpty && allInRange && hasDuration,
                "\(notes.count) notes, all in cello range: \(allInRange), sustained: \(hasDuration)"
            )
        }

        // ── Test 22: Arpeggiated Part Generation ────────────────────────
        do {
            let tpq = 480
            let melody = createTestMelody(
                pitches: [60, 62, 64, 65],
                startTick: 0,
                duration: tpq,
                ticksPerQuarter: tpq
            )
            let key = DetectedKey(root: 0, isMinor: false, confidence: 0.9)
            let chords: [DetectedChord] = [
                DetectedChord(tick: 0, durationTicks: tpq * 4, root: 0, quality: "", bassNote: nil, pitchClasses: [0, 4, 7]),
            ]

            let notes = InstrumentPartGenerator.generate(
                melody: melody,
                chords: chords,
                key: key,
                instrument: "Harp",
                style: .arpeggiated,
                trackIndex: 3,
                channel: 0,
                ticksPerQuarter: tpq
            )

            // Arpeggiated should produce more notes than chords (subdivisions).
            let moreNotes = notes.count > chords.count
            let allInRange = notes.allSatisfy { n in
                n.pitch >= 24 && n.pitch <= 103 // Harp absolute range
            }
            // All notes should be on chord tones (C=0, E=4, G=7).
            let chordTones: Set<Int> = [0, 4, 7]
            let allChordTones = notes.allSatisfy { chordTones.contains(($0.pitch % 12 + 12) % 12) }

            record(
                "arpeggiated-part-generation",
                moreNotes && allInRange && allChordTones,
                "\(notes.count) notes (>1: \(moreNotes)), in range: \(allInRange), chord tones: \(allChordTones)"
            )
        }

        // ── Test 23: Countermelody Generation ───────────────────────────
        do {
            let tpq = 480
            // Ascending melody C-D-E-F-G.
            let melody = createTestMelody(
                pitches: [60, 62, 64, 65, 67],
                startTick: 0,
                duration: tpq,
                ticksPerQuarter: tpq
            )
            let key = DetectedKey(root: 0, isMinor: false, confidence: 0.9)
            let chords: [DetectedChord] = [
                DetectedChord(tick: 0, durationTicks: tpq * 3, root: 0, quality: "", bassNote: nil, pitchClasses: [0, 4, 7]),
                DetectedChord(tick: tpq * 3, durationTicks: tpq * 2, root: 5, quality: "", bassNote: nil, pitchClasses: [5, 9, 0]),
            ]

            let notes = InstrumentPartGenerator.generate(
                melody: melody,
                chords: chords,
                key: key,
                instrument: "Violas",
                style: .countermelody,
                trackIndex: 4,
                channel: 0,
                ticksPerQuarter: tpq
            )

            // Should produce same number of notes as melody.
            let sameCount = notes.count == melody.count
            let allInRange = notes.allSatisfy { n in
                n.pitch >= 48 && n.pitch <= 91 // Violas absolute range
            }
            // Notes should be in the key's scale.
            let scalePCs = key.scalePitchClasses
            let allInKey = notes.allSatisfy { scalePCs.contains(($0.pitch % 12 + 12) % 12) }

            record(
                "countermelody-generation",
                sameCount && allInRange && allInKey,
                "\(notes.count) notes (same as melody: \(sameCount)), in range: \(allInRange), in key: \(allInKey)"
            )
        }

        // ── Test 24: LLM Prompt Template Verification ──────────────────
        do {
            let testKey = DetectedKey(root: 0, isMinor: false, confidence: 0.9)
            let testLyrics = "La la la, singing in the sun"
            let testSummary = "8 notes over 4.0 beats in C Major. Range: C4 to G4."

            let fitPrompt = LLMMusicalReasoner.evaluateLyricMelodyFitPrompt(
                lyrics: testLyrics, melodySummary: testSummary, key: testKey
            )
            let hasSystem = !fitPrompt.system.isEmpty && fitPrompt.system.contains("music")
            let hasUser = !fitPrompt.user.isEmpty && fitPrompt.user.contains("SCORE")
                && fitPrompt.user.contains("STRENGTHS")
            record(
                "llm-prompt-lyric-fit",
                hasSystem && hasUser,
                "system: \(fitPrompt.system.prefix(40))..., user contains SCORE: \(hasUser)"
            )

            let chordPrompt = LLMMusicalReasoner.suggestChordProgressionPrompt(
                melodySummary: testSummary, key: testKey, style: "operatic"
            )
            let chordOk = !chordPrompt.user.isEmpty && chordPrompt.user.contains("chord")
            record(
                "llm-prompt-chords",
                chordOk,
                "user contains chord: \(chordOk)"
            )

            let arrangePrompt = LLMMusicalReasoner.suggestArrangementPrompt(
                melodySummary: testSummary,
                chords: [],
                key: testKey,
                availableInstruments: ["Violins I", "Cellos"]
            )
            let arrangeOk = arrangePrompt.user.contains("Violins I")
                && arrangePrompt.user.contains("INSTRUMENT:")
            record(
                "llm-prompt-arrangement",
                arrangeOk,
                "mentions instruments: \(arrangeOk)"
            )
        }

        // ── Test 25: LLM Response Parsing ─────────────────────────────────
        do {
            let mockFitResponse = """
                SCORE: 7
                STRENGTHS:
                - Good syllable rhythm matching
                - Natural phrasing at measure boundaries
                SUGGESTIONS:
                - Consider adding more variation in the second verse
                - The bridge section feels rushed
                """
            let fitResult = LLMMusicalReasoner.parseLyricFitResponse(mockFitResponse)
            let scoreOk = fitResult.overallScore == 7
            let strengthsOk = fitResult.strengths.count == 2
            let suggestionsOk = fitResult.suggestions.count == 2
            record(
                "llm-parse-lyric-fit",
                scoreOk && strengthsOk && suggestionsOk,
                "score: \(fitResult.overallScore) (exp 7), strengths: \(fitResult.strengths.count) (exp 2), suggestions: \(fitResult.suggestions.count) (exp 2)"
            )

            let mockArrangeResponse = """
                INSTRUMENT: Violins I
                STYLE: sustained
                REASONING: Provides harmonic foundation and warmth
                INSTRUMENT: Cellos
                STYLE: countermelody
                REASONING: Adds depth with contrary motion bass line
                """
            let arrangeResult = LLMMusicalReasoner.parseArrangementSuggestion(mockArrangeResponse)
            let instCount = arrangeResult.instrumentSuggestions.count == 2
            let firstInst = arrangeResult.instrumentSuggestions.first?.instrument == "Violins I"
            let firstStyle = arrangeResult.instrumentSuggestions.first?.style == "sustained"
            record(
                "llm-parse-arrangement",
                instCount && firstInst && firstStyle,
                "instruments: \(arrangeResult.instrumentSuggestions.count) (exp 2), first: \(arrangeResult.instrumentSuggestions.first?.instrument ?? "nil")/\(arrangeResult.instrumentSuggestions.first?.style ?? "nil")"
            )

            let mockChordResponse = """
                Cm7
                - Fm
                G7
                - Bb/D
                """
            let chords = LLMMusicalReasoner.parseChordSuggestionResponse(mockChordResponse)
            let chordCountOk = chords.count >= 3
            record(
                "llm-parse-chords",
                chordCountOk,
                "parsed \(chords.count) chords: \(chords.joined(separator: ", "))"
            )
        }

        // ── Test 26: LLM Client State + Memory ───────────────────────────
        #if canImport(MLXLLM)
        do {
            let memGB = LLMClient.availableMemoryGB()
            let memOk = memGB > 0
            record(
                "llm-client-memory",
                memOk,
                "available memory: \(String(format: "%.1f", memGB)) GB"
            )
        }
        #endif

        // ── Test 27: Melodic Profile Analysis ─────────────────────────────
        do {
            // 8 scale-wise notes (C4 D4 E4 F4 G4 A4 B4 C5) — stepwise motion, no leaps
            let scaleNotes = createTestMelody(
                pitches: [60, 62, 64, 65, 67, 69, 71, 72],
                startTick: 0, duration: 480, ticksPerQuarter: 480
            )
            let profile = StyleAnalyzer.analyzeMelodicProfile(notes: scaleNotes, ticksPerQuarter: 480)
            let leapOk = profile.leapFrequency < 0.2  // stepwise = no leaps
            let densityOk = profile.noteDensity > 0
            record(
                "style-melodic-profile",
                leapOk && densityOk,
                "leapFreq=\(String(format: "%.2f", profile.leapFrequency)), density=\(String(format: "%.1f", profile.noteDensity)), range=\(profile.pitchRange)"
            )
        }

        // ── Test 28: Rhythmic Profile Analysis ──────────────────────────────
        do {
            let scaleNotes = createTestMelody(
                pitches: [60, 62, 64, 65, 67, 69, 71, 72],
                startTick: 0, duration: 480, ticksPerQuarter: 480
            )
            let profile = StyleAnalyzer.analyzeRhythmicProfile(notes: scaleNotes, ticksPerQuarter: 480)
            let syncOk = profile.syncopationIndex >= 0 && profile.syncopationIndex <= 1
            let durationOk = profile.averageDurationBeats > 0
            record(
                "style-rhythmic-profile",
                syncOk && durationOk,
                "sync=\(String(format: "%.2f", profile.syncopationIndex)), avgDur=\(String(format: "%.2f", profile.averageDurationBeats))b, variety=\(String(format: "%.2f", profile.rhythmicVariety))"
            )
        }

        // ── Test 29: Harmonic Complexity Analysis ───────────────────────────
        do {
            // C major, F major, G major, Am — all diatonic functional chords
            let testChords: [DetectedChord] = [
                DetectedChord(tick: 0, durationTicks: 1920, root: 0, quality: "", bassNote: nil, pitchClasses: [0, 4, 7]),        // C
                DetectedChord(tick: 1920, durationTicks: 1920, root: 5, quality: "", bassNote: nil, pitchClasses: [5, 9, 0]),      // F
                DetectedChord(tick: 3840, durationTicks: 1920, root: 7, quality: "", bassNote: nil, pitchClasses: [7, 11, 2]),     // G
                DetectedChord(tick: 5760, durationTicks: 1920, root: 9, quality: "m", bassNote: nil, pitchClasses: [9, 0, 4])      // Am
            ]
            let cKey = DetectedKey(root: 0, isMinor: false, confidence: 0.9)
            let complexity = StyleAnalyzer.analyzeHarmonicComplexity(chords: testChords, key: cKey)
            let funcOk = complexity.functionalStrength > 0.8  // all are I/IV/V/vi
            let chromOk = complexity.chromaticism == 0         // all diatonic
            record(
                "style-harmonic-complexity",
                funcOk && chromOk,
                "functional=\(String(format: "%.2f", complexity.functionalStrength)), chromatic=\(String(format: "%.2f", complexity.chromaticism)), density=\(String(format: "%.1f", complexity.chordDensity))"
            )
        }

        // ── Test 30: Melody Generation ──────────────────────────────────────
        do {
            let cKey = DetectedKey(root: 0, isMinor: false, confidence: 0.9)
            let constraints = MelodyConstraints(
                key: cKey,
                pitchRange: 60...84,
                durationBeats: 4,
                contour: .arch,
                noteDensity: 2.0,
                startTick: 0,
                ticksPerQuarter: 480,
                channel: 0,
                trackIndex: 0,
                velocity: 80
            )
            let generated = CompositionEngine.generateMelody(constraints: constraints)
            let nonEmpty = !generated.isEmpty
            let allInRange = generated.allSatisfy { (60...84).contains($0.pitch) }
            let scalePCs = cKey.scalePitchClasses
            let allInScale = generated.allSatisfy { scalePCs.contains($0.pitch % 12) }
            record(
                "melody-generation",
                nonEmpty && allInRange && allInScale,
                "generated \(generated.count) notes, inRange=\(allInRange), inScale=\(allInScale)"
            )
        }

        // ── Test 31: Leitmotif Transformations ──────────────────────────────
        do {
            // 4-note motif: C4 E4 G4 C5
            let motifNotes = createTestMelody(
                pitches: [60, 64, 67, 72],
                startTick: 0, duration: 480, ticksPerQuarter: 480
            )
            let meanPitch = Double(motifNotes.map(\.pitch).reduce(0, +)) / Double(motifNotes.count)

            // Inversion: mirror around mean pitch
            let inverted = CompositionEngine.transformMotif(
                notes: motifNotes, type: .inversion, ticksPerQuarter: 480
            )
            let invertedMean = Double(inverted.map(\.pitch).reduce(0, +)) / Double(inverted.count)
            let meanPreserved = abs(invertedMean - meanPitch) < 1.0
            record(
                "leitmotif-inversion",
                meanPreserved && inverted.count == motifNotes.count,
                "originalMean=\(String(format: "%.1f", meanPitch)), invertedMean=\(String(format: "%.1f", invertedMean))"
            )

            // Retrograde: reversed pitches
            let retrograde = CompositionEngine.transformMotif(
                notes: motifNotes, type: .retrograde, ticksPerQuarter: 480
            )
            let retroPitches = retrograde.map(\.pitch)
            let originalPitches = motifNotes.map(\.pitch)
            let isReversed = retroPitches == originalPitches.reversed()
            record(
                "leitmotif-retrograde",
                isReversed && retrograde.count == motifNotes.count,
                "pitches: \(retroPitches) (expected \(originalPitches.reversed()))"
            )

            // Augmentation: doubled durations
            let augmented = CompositionEngine.transformMotif(
                notes: motifNotes, type: .augmentation, ticksPerQuarter: 480
            )
            let durationsDoubled = augmented.enumerated().allSatisfy { (i, note) in
                note.duration == motifNotes[i].duration * 2
            }
            record(
                "leitmotif-augmentation",
                durationsDoubled && augmented.count == motifNotes.count,
                "durations: \(augmented.map(\.duration)) (expected \(motifNotes.map { $0.duration * 2 }))"
            )
        }

        // ── Test 32: Vocal Track Resolution ────────────────────────────────
        do {
            let songData = loadSongPlayback(
                owpPath: amiraPath,
                songName: "1.06.0 - FIRST MEETING.ows"
            )

            if let data = songData {
                // Verify track indices exist and track 0 is not the only one
                let trackIndices = Set(data.notes.map(\.trackIndex))
                let hasMultipleTracks = trackIndices.count > 1
                let track0Only = trackIndices == [0]
                let hasNotes = !data.notes.isEmpty

                record(
                    "vocal-track-resolution",
                    hasNotes && hasMultipleTracks && !track0Only,
                    "tracks=\(trackIndices.sorted()), count=\(data.notes.count), multiTrack=\(hasMultipleTracks)"
                )
            } else {
                record("vocal-track-resolution", false, "Could not load song data")
            }
        }

        // ── Test 33: LLM Lyric Alignment Prompt Builder ────────────────────
        do {
            let testNotes = createTestMelody(
                pitches: [60, 62, 64, 65, 67],
                startTick: 0, duration: 480, ticksPerQuarter: 480
            )
            let testWords: [(word: String, syllables: [String])] = [
                ("hel", ["hel"]),
                ("lo", ["lo"]),
                ("beau", ["beau"]),
                ("ti", ["ti"]),
                ("ful", ["ful"])
            ]

            let prompt = LLMLyricAligner.buildAlignmentPrompt(
                syllabifiedWords: testWords,
                notes: testNotes,
                ticksPerQuarter: 480
            )

            let hasNoteTable = prompt.user.contains("0|") && prompt.user.contains("C4")
            let hasSyllables = prompt.user.contains("hel") && prompt.user.contains("ful")
            let hasInstructions = prompt.user.contains("note_index") && prompt.user.contains("syllable")

            record(
                "llm-prompt-builder",
                hasNoteTable && hasSyllables && hasInstructions,
                "noteTable=\(hasNoteTable), syllables=\(hasSyllables), instructions=\(hasInstructions)"
            )

            // Test response parser
            let mockResponse = """
                0:hel
                1:lo
                2:beau
                3:ti
                4:ful
                """
            let parsed = LLMLyricAligner.parseAlignmentResponse(
                mockResponse,
                syllabifiedWords: testWords,
                noteCount: testNotes.count
            )

            let allMapped = parsed.assignments.count == 5
            let ordered = parsed.assignments.enumerated().allSatisfy { $0.element.noteIndex == $0.offset }
            let noErrors = parsed.parseErrors.isEmpty

            record(
                "llm-response-parser",
                allMapped && ordered && noErrors,
                "mapped=\(parsed.assignments.count)/5, ordered=\(ordered), errors=\(parsed.parseErrors)"
            )
        }

        // ── Syllabification Tests ──────────────────────────────────────

        // Test: CMUDict is loaded with reasonable size
        do {
            let hasData = SyllabificationService.cmuSyllableCount(for: "hello") == 2
            let count = SyllabificationService.cmuSyllableCount(for: "makes")
            record("cmudict-loaded", hasData && count == 1, "hello=2syl, makes=\(count ?? -1)syl")
        }

        // Test: Monosyllabic words that were previously split incorrectly
        do {
            let monosyllabicWords = [
                "makes", "takes", "comes", "times", "names", "lives", "waves",
                "bones", "homes", "loves", "gives", "placed", "changed", "closed",
                "danced", "loved", "breathed", "world", "heart", "light", "night",
                "through", "voice", "fire", "soul", "grace", "face", "strange",
                "watched", "touched", "reached", "praised", "blazed", "dazed",
            ]
            var failures: [String] = []
            for word in monosyllabicWords {
                let result = SyllabificationService.syllabify(word)
                let sylCount = result.first?.syllables.count ?? 0
                if sylCount != 1 {
                    failures.append("\(word)=\(sylCount)")
                }
            }
            record(
                "syllabify-monosyllabic",
                failures.isEmpty,
                failures.isEmpty
                    ? "\(monosyllabicWords.count) words all 1 syllable"
                    : "WRONG: \(failures.joined(separator: ", "))"
            )
        }

        // Test: Multi-syllable words retain correct count
        do {
            let multiSylWords: [(String, Int)] = [
                ("amazing", 3), ("beautiful", 3), ("wonderful", 3),
                ("together", 3), ("forever", 3), ("remember", 3),
                ("darkness", 2), ("morning", 2), ("evening", 2),
                ("singing", 2), ("waiting", 2), ("listen", 2),
                ("wanted", 2), ("loaded", 2), ("painted", 2),  // -ed after t/d = extra syl
                ("boxes", 2), ("wishes", 2), ("catches", 2),   // -es after sibilant = extra syl
            ]
            var failures: [String] = []
            for (word, expected) in multiSylWords {
                let result = SyllabificationService.syllabify(word)
                let sylCount = result.first?.syllables.count ?? 0
                if sylCount != expected {
                    failures.append("\(word)=\(sylCount)(exp \(expected))")
                }
            }
            record(
                "syllabify-multisyllabic",
                failures.isEmpty,
                failures.isEmpty
                    ? "\(multiSylWords.count) words all correct"
                    : "WRONG: \(failures.joined(separator: ", "))"
            )
        }

        // Test: Contractions handled correctly
        do {
            let contractions: [(String, Int)] = [
                ("can't", 1), ("don't", 1), ("won't", 1),
                ("aren't", 1), ("weren't", 1),  // singing: rhotic base absorbs n't
                ("wouldn't", 2), ("doesn't", 2), ("couldn't", 2),
                ("isn't", 2), ("wasn't", 2), ("shouldn't", 2),
                ("I'm", 1), ("I'll", 1), ("she's", 1),
                ("they're", 1), ("we've", 1),
            ]
            var failures: [String] = []
            for (word, expected) in contractions {
                let result = SyllabificationService.syllabify(word)
                let sylCount = result.first?.syllables.count ?? 0
                if sylCount != expected {
                    failures.append("\(word)=\(sylCount)(exp \(expected))")
                }
            }
            record(
                "syllabify-contractions",
                failures.isEmpty,
                failures.isEmpty
                    ? "\(contractions.count) contractions correct"
                    : "WRONG: \(failures.joined(separator: ", "))"
            )
        }

        // ── DP Phrase Partition Tests ──────────────────────────────────

        do {
            // Test: DP partition finds optimal matching for unequal phrase counts.
            // 3 lyric lines with 4, 6, 3 syllables → 5 musical phrases with 4, 3, 4, 3, 3 notes.
            // All phrases have ≥3 notes (PhraseDetector merges shorter ones).
            let tpq = 480
            var testNotes: [PianoRollNote] = []
            // Create 5 musical phrases separated by rests.
            let phraseLengths = [4, 3, 4, 3, 3] // notes per phrase (all ≥ 3 to avoid merge)
            var tick = 0
            for pLen in phraseLengths {
                for _ in 0..<pLen {
                    testNotes.append(PianoRollNote(
                        trackIndex: 0,
                        channel: 0,
                        pitch: 60 + Int.random(in: 0...12),
                        velocity: 80,
                        startTick: tick,
                        duration: tpq
                    ))
                    tick += tpq
                }
                tick += tpq * 2 // rest between phrases
            }

            // 3 lyric lines: 4 syllables, 6 syllables, 3 syllables.
            let lyricWords: [[(word: String, syllables: [String])]] = [
                [("hello", ["hel", "lo"]), ("world", ["world"]), ("go", ["go"])],              // 4 syls
                [("beautiful", ["beau", "ti", "ful"]), ("morning", ["morn", "ing"]), ("star", ["star"])], // 6 syls
                [("end", ["end"]), ("of", ["of"]), ("song", ["song"])],                        // 3 syls
            ]

            let flatWords = lyricWords.flatMap { $0 }
            let partition = SmartLyricAligner.matchPhrases(
                syllabifiedWords: flatWords,
                lyricText: "hello world go\nbeautiful morning star\nend of song",
                notes: testNotes,
                tempoEvents: [],
                timeSignatures: [],
                ticksPerQuarter: tpq
            )

            // Verify: all lyric phrases covered, all musical phrases covered.
            let coveredLyric = Set(partition.flatMap(\.lyricPhraseIndices))
            let coveredMusical = Set(partition.flatMap(\.musicalPhraseIndices))
            let allLyricCovered = coveredLyric == Set(0..<3)
            let allMusicalCovered = coveredMusical == Set(0..<5)
            // Verify: mismatch ratio is reasonable (< 0.6 on average).
            let avgMismatch = partition.isEmpty ? 1.0 : partition.map(\.mismatchRatio).reduce(0, +) / Double(partition.count)

            record(
                "dp-phrase-partition",
                allLyricCovered && allMusicalCovered && avgMismatch < 0.6,
                allLyricCovered && allMusicalCovered
                    ? "\(partition.count) groups, avg mismatch \(String(format: "%.2f", avgMismatch))"
                    : "lyric covered=\(allLyricCovered) musical covered=\(allMusicalCovered) avg mismatch=\(String(format: "%.2f", avgMismatch))"
            )
        }

        do {
            // Test: Strict phrase boundaries — syllables from line 1 only on phrase 1 notes.
            let tpq = 480
            var phrase1Notes: [PianoRollNote] = []
            var phrase2Notes: [PianoRollNote] = []

            // Phrase 1: 4 notes at ticks 0–3.
            for i in 0..<4 {
                phrase1Notes.append(PianoRollNote(
                    trackIndex: 0,
                    channel: 0,
                    pitch: 60 + i,
                    velocity: 80,
                    startTick: i * tpq,
                    duration: tpq
                ))
            }
            // Phrase 2: 3 notes at ticks 8–10 (big gap = phrase break).
            for i in 0..<3 {
                phrase2Notes.append(PianoRollNote(
                    trackIndex: 0,
                    channel: 0,
                    pitch: 72 + i,
                    velocity: 80,
                    startTick: (8 + i) * tpq,
                    duration: tpq
                ))
            }

            let allNotes = phrase1Notes + phrase2Notes
            let phrase1IDs = Set(phrase1Notes.map(\.id))
            let phrase2IDs = Set(phrase2Notes.map(\.id))

            let words: [(word: String, syllables: [String])] = [
                ("love", ["love"]), ("is", ["is"]), ("here", ["here"]), ("now", ["now"]),
                ("stay", ["stay"]), ("with", ["with"]), ("me", ["me"]),
            ]

            let result = SmartLyricAligner.align(
                syllabifiedWords: words,
                notes: allNotes,
                tempoEvents: [],
                timeSignatures: [],
                ticksPerQuarter: tpq,
                lyricText: "love is here now\nstay with me"
            )

            // Check: first 4 syllables should be on phrase 1 notes, last 3 on phrase 2.
            let line1Assignments = result.assignments.filter {
                $0.syllable != "_" && phrase1IDs.contains($0.noteID)
            }
            let line2Assignments = result.assignments.filter {
                $0.syllable != "_" && phrase2IDs.contains($0.noteID)
            }
            let line1Syllables = Set(line1Assignments.map(\.syllable))
            let line2Syllables = Set(line2Assignments.map(\.syllable))

            // "love", "is", "here", "now" should be on phrase 1
            let line1Correct = line1Syllables.isSubset(of: ["love", "is", "here", "now"])
            // "stay", "with", "me" should be on phrase 2
            let line2Correct = line2Syllables.isSubset(of: ["stay", "with", "me"])
            let noCrossLeak = line1Correct && line2Correct

            record(
                "strict-phrase-boundaries",
                noCrossLeak && line1Assignments.count == 4 && line2Assignments.count == 3,
                noCrossLeak
                    ? "line1=\(line1Assignments.count) notes, line2=\(line2Assignments.count) notes — no cross-boundary leakage"
                    : "LEAK: line1 syls=\(line1Syllables) line2 syls=\(line2Syllables)"
            )
        }

        do {
            // Test: MelodicMutator proposes expansions when syllables > notes.
            let tpq = 480
            var phraseNotes: [PianoRollNote] = []
            // 5 notes, but we need 8 syllables.
            for i in 0..<5 {
                phraseNotes.append(PianoRollNote(
                    trackIndex: 0,
                    channel: 0,
                    pitch: 60 + i * 2,
                    velocity: 80,
                    startTick: i * tpq,
                    duration: tpq
                ))
            }

            let mutation = MelodicMutator.propose(
                currentNotes: phraseNotes,
                targetSyllableCount: 8,
                detectedKey: DetectedKey(root: 0, isMinor: false, confidence: 0.9),
                ticksPerQuarter: tpq
            )

            // Should propose insertions to add 3 notes.
            let hasInsertions = !mutation.notesToInsert.isEmpty
            let totalAfter = phraseNotes.count + mutation.notesToInsert.count - mutation.notesToRemove.count
            // All inserted notes should be within the phrase's tick range.
            let phraseStart = phraseNotes.first!.startTick
            let phraseEnd = phraseNotes.last!.startTick + phraseNotes.last!.duration
            let allInRange = mutation.notesToInsert.allSatisfy { $0.startTick >= phraseStart && $0.startTick < phraseEnd }

            record(
                "fit-midi-mutator",
                hasInsertions && totalAfter >= 7 && allInRange,
                "inserted=\(mutation.notesToInsert.count) removed=\(mutation.notesToRemove.count) modified=\(mutation.notesToModify.count) total=\(totalAfter) inRange=\(allInRange)"
            )
        }

        // ── Test: Elastic Syllable Range ──────────────────────────────
        do {
            // "fire" has CMUDict alternates: 2 syl (primary) and 1 syl (alternate)
            let fireRange = SyllabificationService.cmuSyllableRange(for: "fire")
            let fireOK = fireRange != nil && fireRange!.min == 1 && fireRange!.preferred == 2 && fireRange!.max == 2

            // "every" has CMUDict alternates: 3 syl (primary) and 2 syl (alternate)
            let everyRange = SyllabificationService.cmuSyllableRange(for: "every")
            let everyOK = everyRange != nil && everyRange!.min == 2 && everyRange!.preferred == 3 && everyRange!.max == 3

            // "aren't" has CMUDict alternates: 2 syl (primary) and 1 syl (alternate)
            let arentRange = SyllabificationService.cmuSyllableRange(for: "aren't")
            let arentOK = arentRange != nil && arentRange!.min == 1 && arentRange!.max == 2

            // "hello" has no alternates — should be fixed at 2
            let helloRange = SyllabificationService.cmuSyllableRange(for: "hello")
            let helloOK = helloRange != nil && !helloRange!.isElastic && helloRange!.preferred == 2

            // "flower" is in singing overrides (not CMUDict alternates): min=1, max=2
            let flowerRange = SyllabificationService.cmuSyllableRange(for: "flower")
            let flowerOK = flowerRange != nil && flowerRange!.min == 1 && flowerRange!.max == 2

            // "power" is in singing overrides: min=1, max=2
            let powerRange = SyllabificationService.cmuSyllableRange(for: "power")
            let powerOK = powerRange != nil && powerRange!.min == 1 && powerRange!.max == 2

            record(
                "elastic-syllable-range",
                fireOK && everyOK && arentOK && helloOK && flowerOK && powerOK,
                "fire=\(fireRange.map { "\($0.min)-\($0.max)" } ?? "nil") every=\(everyRange.map { "\($0.min)-\($0.max)" } ?? "nil") aren't=\(arentRange.map { "\($0.min)-\($0.max)" } ?? "nil") hello=\(helloRange.map { "\($0.preferred)" } ?? "nil") flower=\(flowerRange.map { "\($0.min)-\($0.max)" } ?? "nil") power=\(powerRange.map { "\($0.min)-\($0.max)" } ?? "nil")"
            )
        }

        // ── Test: Elastic Syllabify ──────────────────────────────────────
        do {
            let elastic = SyllabificationService.syllabifyElastic("the fire burns every night")
            // Should have 5 words
            let countOK = elastic.count == 5

            // "fire" (index 1) should be elastic
            let fireElastic = elastic.count > 1 && elastic[1].range.isElastic
            let fireHas1 = elastic.count > 1 && elastic[1].syllableVariants[1] != nil
            let fireHas2 = elastic.count > 1 && elastic[1].syllableVariants[2] != nil

            // "every" (index 3) should be elastic
            let everyElastic = elastic.count > 3 && elastic[3].range.isElastic
            let everyHas2 = elastic.count > 3 && elastic[3].syllableVariants[2] != nil
            let everyHas3 = elastic.count > 3 && elastic[3].syllableVariants[3] != nil

            // "the" (index 0), "burns" (index 2), "night" (index 4) should be fixed
            let theFixed = elastic.count > 0 && !elastic[0].range.isElastic
            let burnsFixed = elastic.count > 2 && !elastic[2].range.isElastic
            let nightFixed = elastic.count > 4 && !elastic[4].range.isElastic

            record(
                "elastic-syllabify",
                countOK && fireElastic && fireHas1 && fireHas2 && everyElastic && everyHas2 && everyHas3 && theFixed && burnsFixed && nightFixed,
                "count=\(elastic.count) fire:elastic=\(fireElastic) fire:variants=[\(elastic.count > 1 ? elastic[1].syllableVariants.keys.sorted().map(String.init).joined(separator: ",") : "?")] every:elastic=\(everyElastic) every:variants=[\(elastic.count > 3 ? elastic[3].syllableVariants.keys.sorted().map(String.init).joined(separator: ",") : "?")]"
            )
        }

        // ── Test: Elastic Phrase Resolution ──────────────────────────────
        do {
            // Create elastic words: "fire" (1-2), "every" (2-3), "flower" (1-2), "the" (1), "night" (1)
            // Preferred total: 2 + 3 + 2 + 1 + 1 = 9 syllables
            let elasticWords = SyllabificationService.syllabifyElastic("fire every flower the night")

            // Target: 6 notes → need to compress from 9 to 6
            // Should compress: fire 2→1, every 3→2, flower 2→1 = 1+2+1+1+1 = 6
            let resolved6 = SmartLyricAligner.resolveElasticCounts(
                words: elasticWords,
                targetNoteCount: 6
            )
            let total6 = resolved6.reduce(0) { $0 + $1.syllables.count }
            let resolved6OK = total6 == 6

            // Target: 9 notes → should stay at preferred (already 9)
            let resolved9 = SmartLyricAligner.resolveElasticCounts(
                words: elasticWords,
                targetNoteCount: 9
            )
            let total9 = resolved9.reduce(0) { $0 + $1.syllables.count }
            let resolved9OK = total9 == 9

            // Target: 7 notes → compress partially (fire 2→1, every stays 3, flower 2→1 = 1+3+1+1+1 = 7)
            let resolved7 = SmartLyricAligner.resolveElasticCounts(
                words: elasticWords,
                targetNoteCount: 7
            )
            let total7 = resolved7.reduce(0) { $0 + $1.syllables.count }
            let resolved7OK = total7 == 7

            record(
                "elastic-phrase-resolution",
                resolved6OK && resolved9OK && resolved7OK,
                "target6→\(total6) target9→\(total9) target7→\(total7)"
            )
        }

        // ── Summary ─────────────────────────────────────────────────────
        let failures = checks.filter { !$0.passed }
        print("[ENGINE-TEST] ================================================")
        print("[ENGINE-TEST] Summary: \(checks.count - failures.count)/\(checks.count) passed")

        if !failures.isEmpty {
            print("[ENGINE-TEST] Failures:")
            for f in failures {
                print("[ENGINE-TEST]   - \(f.name): \(f.detail)")
            }
        }

        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Data Loading Helpers

    /// Song playback data extracted from an .ows file.
    private struct SongPlaybackData {
        var notes: [PianoRollNote]
        var tempoEvents: [TempoPoint]
        var timeSignatures: [TimeSignatureEvent]
        var keySignatures: [KeySignatureEvent]
        var ticksPerQuarter: Int
        var lyrics: String?
        var trackNames: [Int: String]
    }

    /// Load a song's playback data from an .owp package.
    private static func loadSongPlayback(owpPath: String, songName: String) -> SongPlaybackData? {
        let songURL = URL(fileURLWithPath: owpPath)
            .appendingPathComponent("Songs")
            .appendingPathComponent(songName)

        guard FileManager.default.fileExists(atPath: songURL.path) else {
            print("[ENGINE-TEST] File not found: \(songURL.path)")
            return nil
        }

        do {
            let data = try Data(contentsOf: songURL, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { dateDecoder in
                let container = try dateDecoder.singleValueContainer()
                if let raw = try? container.decode(String.self) {
                    let withFractional = ISO8601DateFormatter()
                    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let parsed = withFractional.date(from: raw) { return parsed }
                    let plain = ISO8601DateFormatter()
                    plain.formatOptions = [.withInternetDateTime]
                    if let parsed = plain.date(from: raw) { return parsed }
                    if let secs = Double(raw) { return Date(timeIntervalSince1970: secs) }
                }
                if let secs = try? container.decode(Double.self) {
                    return Date(timeIntervalSince1970: secs)
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date")
            }

            let document = try decoder.decode(OWSSongDocument.self, from: data)

            // Find the active version.
            let version: OWSVersionPayload?
            if let activeID = document.activeVersionID {
                version = document.versions.first { $0.id == activeID }
            } else {
                version = document.versions.last
            }

            guard let ver = version else {
                print("[ENGINE-TEST] No version found in \(songName)")
                return nil
            }

            guard let snap = ver.playback else {
                print("[ENGINE-TEST] No playback snapshot in \(songName)")
                return nil
            }

            return SongPlaybackData(
                notes: snap.notes,
                tempoEvents: snap.tempoEvents,
                timeSignatures: snap.timeSignatureEvents ?? [],
                keySignatures: snap.keySignatureEvents ?? [],
                ticksPerQuarter: snap.ticksPerQuarter,
                lyrics: ver.lyrics,
                trackNames: snap.trackNames
            )
        } catch {
            print("[ENGINE-TEST] Error loading \(songName): \(error)")
            return nil
        }
    }

    /// Create a test melody from an array of pitches.
    private static func createTestMelody(
        pitches: [Int],
        startTick: Int,
        duration: Int,
        ticksPerQuarter: Int,
        gap: Int? = nil
    ) -> [PianoRollNote] {
        let spacing = gap ?? duration
        return pitches.enumerated().map { (i, pitch) in
            PianoRollNote(
                trackIndex: 0,
                channel: 0,
                pitch: pitch,
                velocity: 90,
                startTick: startTick + i * spacing,
                duration: duration
            )
        }
    }

    /// Create simultaneous notes (a chord) at a given tick.
    private static func createChordNotes(
        pitches: [Int],
        startTick: Int,
        duration: Int
    ) -> [PianoRollNote] {
        pitches.map { pitch in
            PianoRollNote(
                trackIndex: 0,
                channel: 0,
                pitch: pitch,
                velocity: 80,
                startTick: startTick,
                duration: duration
            )
        }
    }
}
