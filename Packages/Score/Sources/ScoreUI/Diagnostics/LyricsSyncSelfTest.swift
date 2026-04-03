import Foundation
// Combine no longer needed with @Observable

@available(macOS 26.0, *)
@MainActor
enum LyricsSyncSelfTest {
    private struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run() -> Int32 {
        var checks: [Check] = []

        func record(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(Check(name: name, passed: passed, detail: detail))
        }

        let store = ScoreStore()
        let songPath = "Songs/SelfTest.ows"
        let midiID = UUID()
        let libID = UUID()

        let dummyDoc = OWSSongDocument(songID: midiID, title: "SelfTest", canonicalTitle: "selftest", notes: "", updatedAt: Date(), activeVersionID: nil, versions: [], instrumentMappings: [:])
        store.songAssets = [OWSSongAsset(relativePath: songPath, document: dummyDoc)]
        store.librettoFiles = [ProjectTextFile(id: libID, relativePath: songPath, content: "CHAR\n\tsun moon star\n")]
        store.selectedMidiID = midiID
        store.selectedLibrettoID = libID
        store.pianoRollChannelKeyByTrackChannel = ["0:0": "vox"]

        let noteSun = PianoRollNote(trackIndex: 0, channel: 0, pitch: 60, velocity: 90, startTick: 0, duration: 240, lyricSyllable: "sun")
        let noteMoon = PianoRollNote(trackIndex: 0, channel: 0, pitch: 62, velocity: 90, startTick: 240, duration: 240, lyricSyllable: "moon")
        let noteStar = PianoRollNote(trackIndex: 0, channel: 0, pitch: 64, velocity: 90, startTick: 480, duration: 240, lyricSyllable: "star")
        store.pianoRollNotes = [noteSun, noteMoon, noteStar]

        // Build baseline alignments from current note syllables.
        let baselineLyrics = SyllabificationService.extractLyrics(from: store.selectedLibrettoFile?.content ?? "")
        let baselineWords = SyllabificationService.syllabify(baselineLyrics)
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: baselineWords)

        // A) lyrics-lane -> libretto via alignment mapping
        store.updateLibrettoFromSyllableEdit(
            noteID: noteMoon.id,
            newSyllable: "cloud",
            oldSyllable: "moon"
        )
        let afterAlignedEdit = store.selectedLibrettoFile?.content ?? ""
        record(
            "lane->libretto (aligned)",
            afterAlignedEdit.contains("\tsun cloud star"),
            afterAlignedEdit
        )

        // B) lyrics-lane -> libretto via text-search fallback (no alignments)
        store.pianoRollLyricAlignments = []
        store.updateLibrettoFromSyllableEdit(
            noteID: noteStar.id,
            newSyllable: "nova",
            oldSyllable: "star"
        )
        let afterFallbackEdit = store.selectedLibrettoFile?.content ?? ""
        record(
            "lane->libretto (fallback)",
            afterFallbackEdit.contains("\tsun cloud nova"),
            afterFallbackEdit
        )

        // C) libretto -> lyrics should rewrite from unconfirmed mappings when token-anchored
        // and unambiguous (one note per token).
        store.librettoFiles[0].content = "CHAR\n\tone two three\n"
        store.pianoRollNotes[0].lyricSyllable = "one"
        store.pianoRollNotes[1].lyricSyllable = "two"
        store.pianoRollNotes[2].lyricSyllable = "three"

        let wordsC = SyllabificationService.syllabify(
            SyllabificationService.extractLyrics(from: store.librettoFiles[0].content)
        )
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: wordsC)
        for i in store.pianoRollLyricAlignments.indices {
            for j in store.pianoRollLyricAlignments[i].entries.indices {
                store.pianoRollLyricAlignments[i].entries[j].confirmed = false
            }
        }

        store.updateSelectedLibrettoContent("CHAR\n\tone duo tres\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let unconfirmedAnchoredNotes = [
            store.pianoRollNotes[0].lyricSyllable ?? "",
            store.pianoRollNotes[1].lyricSyllable ?? "",
            store.pianoRollNotes[2].lyricSyllable ?? ""
        ]
        record(
            "libretto->lane (unconfirmed token-anchored)",
            unconfirmedAnchoredNotes == ["one", "duo", "tres"],
            unconfirmedAnchoredNotes.joined(separator: ",")
        )

        // D) ambiguous unconfirmed mappings (duplicate token IDs) should not propagate.
        store.librettoFiles[0].content = "CHAR\n\tone two three\n"
        store.pianoRollNotes[0].lyricSyllable = "one"
        store.pianoRollNotes[1].lyricSyllable = "two"
        store.pianoRollNotes[2].lyricSyllable = "three"

        let wordsD = SyllabificationService.syllabify(
            SyllabificationService.extractLyrics(from: store.librettoFiles[0].content)
        )
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: wordsD)

        if let alignIdx = store.pianoRollLyricAlignments.firstIndex(where: { $0.songPath == songPath && $0.trackKey == "vox" }),
           let sharedToken = store.pianoRollLyricAlignments[alignIdx].entries.first?.tokenID {
            for j in store.pianoRollLyricAlignments[alignIdx].entries.indices {
                store.pianoRollLyricAlignments[alignIdx].entries[j].confirmed = false
                store.pianoRollLyricAlignments[alignIdx].entries[j].tokenID = sharedToken
                store.pianoRollLyricAlignments[alignIdx].entries[j].wordIndex = 0
            }
        }

        store.updateSelectedLibrettoContent("CHAR\n\tone duo tres\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let ambiguousUnconfirmedNotes = [
            store.pianoRollNotes[0].lyricSyllable ?? "",
            store.pianoRollNotes[1].lyricSyllable ?? "",
            store.pianoRollNotes[2].lyricSyllable ?? ""
        ]
        record(
            "libretto->lane (skip ambiguous unconfirmed)",
            ambiguousUnconfirmedNotes == ["one", "two", "three"],
            ambiguousUnconfirmedNotes.joined(separator: ",")
        )

        // E) libretto -> lyrics should rewrite when mappings are confirmed.
        store.librettoFiles[0].content = "CHAR\n\tone two three\n"
        store.pianoRollNotes[0].lyricSyllable = "one"
        store.pianoRollNotes[1].lyricSyllable = "two"
        store.pianoRollNotes[2].lyricSyllable = "three"

        let wordsE = SyllabificationService.syllabify(
            SyllabificationService.extractLyrics(from: store.librettoFiles[0].content)
        )
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: wordsE)

        store.updateSelectedLibrettoContent("CHAR\n\tone duo tres\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let syncedNotes = [
            store.pianoRollNotes[0].lyricSyllable ?? "",
            store.pianoRollNotes[1].lyricSyllable ?? "",
            store.pianoRollNotes[2].lyricSyllable ?? ""
        ]
        record(
            "libretto->lane (confirmed)",
            syncedNotes == ["one", "duo", "tres"],
            syncedNotes.joined(separator: ",")
        )

        // F) token-ID anchoring should survive index shifts (word insertion before aligned words).
        store.librettoFiles[0].content = "CHAR\n\toak pine birch\n"
        store.pianoRollNotes[0].lyricSyllable = "oak"
        store.pianoRollNotes[1].lyricSyllable = "pine"
        store.pianoRollNotes[2].lyricSyllable = "birch"
        let wordsF = SyllabificationService.syllabify(
            SyllabificationService.extractLyrics(from: store.librettoFiles[0].content)
        )
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: wordsF)

        store.updateSelectedLibrettoContent("CHAR\n\tprologue oak pine birch\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let anchoredNotes = [
            store.pianoRollNotes[0].lyricSyllable ?? "",
            store.pianoRollNotes[1].lyricSyllable ?? "",
            store.pianoRollNotes[2].lyricSyllable ?? ""
        ]
        record(
            "libretto->lane (token anchored shift)",
            anchoredNotes == ["oak", "pine", "birch"],
            anchoredNotes.joined(separator: ",")
        )

        // G) whole-word mappings (multi-syllable words on one note) should round-trip
        // as whole words, not partial syllable fragments.
        let whole1 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 67, velocity: 90, startTick: 0, duration: 240, lyricSyllable: "gamma")
        let whole2 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 69, velocity: 90, startTick: 240, duration: 240, lyricSyllable: "delta")
        store.pianoRollNotes = [whole1, whole2]
        store.librettoFiles[0].content = "CHAR\n\tgamma delta\n"
        let wordsG = SyllabificationService.syllabify(
            SyllabificationService.extractLyrics(from: store.librettoFiles[0].content)
        )
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: wordsG)
        store.updateSelectedLibrettoContent("CHAR\n\tomega lambda\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let wholeWordNotes = [
            store.pianoRollNotes[0].lyricSyllable ?? "",
            store.pianoRollNotes[1].lyricSyllable ?? ""
        ]
        record(
            "libretto->lane (whole-word mapping)",
            wholeWordNotes == ["omega", "lambda"],
            wholeWordNotes.joined(separator: ",")
        )

        // H) drag/swap remap should keep note->word lock stable for future sidebar edits.
        let swap1 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 60, velocity: 90, startTick: 0, duration: 240, lyricSyllable: "one")
        let swap2 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 62, velocity: 90, startTick: 240, duration: 240, lyricSyllable: "two")
        let swap3 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 64, velocity: 90, startTick: 480, duration: 240, lyricSyllable: "three")
        store.pianoRollNotes = [swap1, swap2, swap3]
        store.librettoFiles[0].content = "CHAR\n\tone two three\n"
        let wordsH = SyllabificationService.syllabify(
            SyllabificationService.extractLyrics(from: store.librettoFiles[0].content)
        )
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: wordsH)

        // Simulate normal-mode drag swap between note 1 and note 2.
        store.pianoRollNotes[0].lyricSyllable = "two"
        store.pianoRollNotes[1].lyricSyllable = "one"
        store.remapLyricAlignments(noteRemap: [swap1.id: swap2.id, swap2.id: swap1.id])

        store.updateSelectedLibrettoContent("CHAR\n\tuno dos tres\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let swappedMappedNotes = [
            store.pianoRollNotes[0].lyricSyllable ?? "",
            store.pianoRollNotes[1].lyricSyllable ?? "",
            store.pianoRollNotes[2].lyricSyllable ?? ""
        ]
        record(
            "libretto->lane (drag swap lock)",
            swappedMappedNotes == ["dos", "uno", "tres"],
            swappedMappedNotes.joined(separator: ",")
        )

        // I) auto-aligner: equal note/syllable counts should avoid gratuitous melisma.
        let equalWords = SyllabificationService.syllabify("lumen aria")
        let equalSyllableCount = max(1, equalWords.reduce(0) { $0 + $1.syllables.count })
        var equalNotes: [PianoRollNote] = []
        equalNotes.reserveCapacity(equalSyllableCount)
        for i in 0..<equalSyllableCount {
            equalNotes.append(
                PianoRollNote(
                    trackIndex: 0,
                    channel: 0,
                    pitch: 60 + i,
                    velocity: 90,
                    startTick: i * 240,
                    duration: 240
                )
            )
        }
        let equalResult = LyricAligner.align(
            syllabifiedWords: equalWords,
            notes: equalNotes,
            ticksPerQuarter: 480
        )
        let equalHasMelisma = equalResult.assignments.contains { $0.syllable == "_" }
        record(
            "auto-align (no gratuitous melisma)",
            !equalHasMelisma,
            equalResult.assignments.map(\.syllable).joined(separator: ",")
        )

        // J) auto-aligner: phrase starts should prefer word starts over melisma.
        let phraseWords = SyllabificationService.syllabify("ever after")
        let phraseNotes: [PianoRollNote] = [
            PianoRollNote(trackIndex: 0, channel: 0, pitch: 60, velocity: 90, startTick: 0, duration: 180),
            PianoRollNote(trackIndex: 0, channel: 0, pitch: 61, velocity: 90, startTick: 180, duration: 120),
            PianoRollNote(trackIndex: 0, channel: 0, pitch: 62, velocity: 90, startTick: 300, duration: 120),
            // Phrase break (> 1 beat at 480 tpq)
            PianoRollNote(trackIndex: 0, channel: 0, pitch: 64, velocity: 90, startTick: 1080, duration: 240),
            PianoRollNote(trackIndex: 0, channel: 0, pitch: 65, velocity: 90, startTick: 1320, duration: 240)
        ]
        let phraseResult = LyricAligner.align(
            syllabifiedWords: phraseWords,
            notes: phraseNotes,
            ticksPerQuarter: 480
        )
        // Phrase start at note index 3 should not be melisma.
        let phraseStartSafe = phraseResult.assignments.count > 3 ? phraseResult.assignments[3].syllable != "_" : false
        record(
            "auto-align (phrase start not melisma)",
            phraseStartSafe,
            phraseResult.assignments.map(\.syllable).joined(separator: ",")
        )

        // K) duplicate-word edits should stay anchored to their specific notes.
        let dup1 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 60, velocity: 90, startTick: 0, duration: 240, lyricSyllable: "love")
        let dup2 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 62, velocity: 90, startTick: 240, duration: 240, lyricSyllable: "love")
        let dup3 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 64, velocity: 90, startTick: 480, duration: 240, lyricSyllable: "love")
        let dup4 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 65, velocity: 90, startTick: 720, duration: 240, lyricSyllable: "love")
        store.pianoRollNotes = [dup1, dup2, dup3, dup4]
        store.librettoFiles[0].content = "CHAR\n\tlove love love love\n"
        let dupWords = SyllabificationService.syllabify(
            SyllabificationService.extractLyrics(from: store.librettoFiles[0].content)
        )
        store.buildLyricAlignmentsFromNotes(trackKey: "vox", syllabifiedWords: dupWords)
        store.updateLibrettoFromSyllableEdit(noteID: dup2.id, newSyllable: "light", oldSyllable: "love")
        store.updateLibrettoFromSyllableEdit(noteID: dup4.id, newSyllable: "fire", oldSyllable: "love")
        let duplicateResult = store.selectedLibrettoFile?.content ?? ""
        record(
            "lane->libretto (duplicate words anchored)",
            duplicateResult.contains("\tlove light love fire"),
            duplicateResult
        )

        // L) stale mismatch should fail safely (no unrelated word corruption).
        let stale1 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 60, velocity: 90, startTick: 0, duration: 240, lyricSyllable: "one")
        let stale2 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 62, velocity: 90, startTick: 240, duration: 240, lyricSyllable: "two")
        let stale3 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 64, velocity: 90, startTick: 480, duration: 240, lyricSyllable: "three")
        let stale4 = PianoRollNote(trackIndex: 0, channel: 0, pitch: 65, velocity: 90, startTick: 720, duration: 240, lyricSyllable: "four")
        store.pianoRollNotes = [stale1, stale2, stale3, stale4]
        store.pianoRollLyricAlignments = []
        store.librettoFiles[0].content = "CHAR\n\talpha beta gamma delta\n"
        store.updateLibrettoFromSyllableEdit(noteID: stale3.id, newSyllable: "GAMMA2", oldSyllable: "three")
        let staleFallbackResult = store.selectedLibrettoFile?.content ?? ""
        record(
            "lane->libretto (stale mismatch no-op)",
            staleFallbackResult.contains("\talpha beta gamma delta"),
            staleFallbackResult
        )

        // M) lane->libretto edit should update librettoFiles.
        let contentBefore = store.librettoFiles.first?.content ?? ""
        store.pianoRollNotes[1].lyricSyllable = "beta"
        store.updateLibrettoFromSyllableEdit(noteID: stale2.id, newSyllable: "BETA2", oldSyllable: "beta")
        let contentAfter = store.librettoFiles.first?.content ?? ""
        let publishTriggered = contentAfter != contentBefore
        record(
            "lane->libretto (updates @Observable)",
            publishTriggered && contentAfter.contains("\talpha BETA2 gamma delta"),
            contentAfter
        )
        let failures = checks.filter { !$0.passed }
        for check in checks {
            print("[SELFTEST] \(check.passed ? "PASS" : "FAIL") \(check.name): \(check.detail)")
        }
        print("[SELFTEST] summary: \(checks.count - failures.count)/\(checks.count) passed")

        return failures.isEmpty ? 0 : 1
    }
}
