import Foundation

/// Imports MusicXML (.xml, .musicxml) files into PianoRollNote arrays.
/// Supports score-partwise format with notes, rests, time/key signatures, and tempo.
@available(macOS 26.0, *)
enum MusicXMLImporter {

    struct ImportResult {
        var notes: [PianoRollNote]
        var trackNames: [Int: String]
        var tempoEvents: [TempoPoint]
        var timeSignatures: [TimeSignatureEvent]
        var keySignatures: [KeySignatureEvent]
        var ticksPerQuarter: Int
        var title: String?
        var lyrics: [(noteID: UUID, syllable: String)]
    }

    /// Parse a MusicXML file and return structured note data.
    static func importFile(at url: URL) throws -> ImportResult {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parse MusicXML from raw data.
    static func parse(data: Data) throws -> ImportResult {
        let delegate = MusicXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            throw NSError(domain: "MusicXMLImporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to parse MusicXML"])
        }

        return delegate.buildResult()
    }
}

// MARK: - SAX Parser Delegate

@available(macOS 26.0, *)
private class MusicXMLParserDelegate: NSObject, XMLParserDelegate {
    // Parse state
    private var currentElement = ""
    private var textBuffer = ""

    // Score metadata
    private var title: String?
    private var divisions: Int = 1  // ticks per quarter note

    // Part tracking
    private var partIDs: [String] = []
    private var partNames: [String: String] = [:]
    private var currentPartID: String?
    private var currentPartIndex: Int = -1

    // Measure tracking
    private var currentMeasureTick: Int = 0

    // Note building
    private var inNote = false
    private var noteIsRest = false
    private var noteIsChord = false
    private var noteStep = ""
    private var noteAlter = 0
    private var noteOctave = 4
    private var noteDuration = 0
    private var noteVoice = 1
    private var noteStaff = 1
    private var noteLyricSyllable: String?
    private var noteLyricType: String?  // "single", "begin", "middle", "end"

    // Forward/backup tracking
    private var currentTick: Int = 0

    // Collected results
    private var notes: [PianoRollNote] = []
    private var lyrics: [(noteID: UUID, syllable: String)] = []
    private var tempoEvents: [TempoPoint] = []
    private var timeSignatures: [TimeSignatureEvent] = []
    private var keySignatures: [KeySignatureEvent] = []

    // Time/key signature building
    private var tsNumerator = 0
    private var tsDenominator = 0
    private var ksFifths = 0
    private var ksMode = ""

    // Direction/sound
    private var inDirection = false
    private var directionTempo: Double?

    // Nesting tracking
    private var inAttributes = false
    private var inTimeSig = false
    private var inKeySig = false
    private var inPitch = false
    private var inLyric = false
    private var inPartList = false
    private var inScorePart = false
    private var inSound = false

    func buildResult() -> MusicXMLImporter.ImportResult {
        var trackNames: [Int: String] = [:]
        for (i, pid) in partIDs.enumerated() {
            if let name = partNames[pid] {
                trackNames[i] = name
            }
        }

        let tpq = max(1, divisions)

        return MusicXMLImporter.ImportResult(
            notes: notes,
            trackNames: trackNames,
            tempoEvents: tempoEvents.isEmpty ? [TempoPoint(tick: 0, bpm: 120)] : tempoEvents,
            timeSignatures: timeSignatures.isEmpty
                ? [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
                : timeSignatures,
            keySignatures: keySignatures.isEmpty
                ? [KeySignatureEvent(tick: 0, sharpsFlats: 0, isMinor: false)]
                : keySignatures,
            ticksPerQuarter: tpq,
            title: title,
            lyrics: lyrics
        )
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        currentElement = elementName
        textBuffer = ""

        switch elementName {
        case "part-list":
            inPartList = true
        case "score-part":
            inScorePart = true
            if let id = attributes["id"] {
                partIDs.append(id)
                currentPartID = id
            }
        case "part":
            if let id = attributes["id"] {
                currentPartID = id
                currentPartIndex = partIDs.firstIndex(of: id) ?? partIDs.count
                currentTick = 0
            }
        case "measure":
            currentMeasureTick = currentTick
        case "attributes":
            inAttributes = true
        case "time":
            inTimeSig = true
            tsNumerator = 0
            tsDenominator = 0
        case "key":
            inKeySig = true
            ksFifths = 0
            ksMode = ""
        case "note":
            inNote = true
            noteIsRest = false
            noteIsChord = false
            noteStep = "C"
            noteAlter = 0
            noteOctave = 4
            noteDuration = 0
            noteVoice = 1
            noteStaff = 1
            noteLyricSyllable = nil
            noteLyricType = nil
        case "rest":
            if inNote { noteIsRest = true }
        case "chord":
            if inNote { noteIsChord = true }
        case "pitch":
            if inNote { inPitch = true }
        case "lyric":
            if inNote { inLyric = true }
        case "direction":
            inDirection = true
            directionTempo = nil
        case "sound":
            if let tempoStr = attributes["tempo"], let bpm = Double(tempoStr) {
                if inDirection {
                    directionTempo = bpm
                } else {
                    tempoEvents.append(TempoPoint(tick: currentTick, bpm: bpm))
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "work-title":
            if !text.isEmpty { title = text }
        case "part-name":
            if inScorePart, let pid = currentPartID, !text.isEmpty {
                partNames[pid] = text
            }
        case "score-part":
            inScorePart = false
        case "part-list":
            inPartList = false
        case "divisions":
            if inAttributes, let d = Int(text), d > 0 {
                divisions = d
            }
        case "beats":
            if inTimeSig, let n = Int(text) { tsNumerator = n }
        case "beat-type":
            if inTimeSig, let d = Int(text) { tsDenominator = d }
        case "time":
            if inTimeSig && tsNumerator > 0 && tsDenominator > 0 {
                timeSignatures.append(TimeSignatureEvent(
                    tick: currentTick, numerator: tsNumerator, denominator: tsDenominator
                ))
            }
            inTimeSig = false
        case "fifths":
            if inKeySig, let f = Int(text) { ksFifths = f }
        case "mode":
            if inKeySig { ksMode = text }
        case "key":
            if inKeySig {
                keySignatures.append(KeySignatureEvent(
                    tick: currentTick, sharpsFlats: ksFifths, isMinor: ksMode == "minor"
                ))
            }
            inKeySig = false
        case "attributes":
            inAttributes = false

        // Pitch components
        case "step":
            if inPitch { noteStep = text }
        case "alter":
            if inPitch, let a = Int(text) { noteAlter = a }
        case "octave":
            if inPitch, let o = Int(text) { noteOctave = o }
        case "pitch":
            inPitch = false

        // Note duration and voice
        case "duration":
            if inNote, let d = Int(text) { noteDuration = d }
        case "voice":
            if inNote, let v = Int(text) { noteVoice = v }
        case "staff":
            if inNote, let s = Int(text) { noteStaff = s }

        // Lyric
        case "text":
            if inLyric { noteLyricSyllable = text }
        case "syllabic":
            if inLyric { noteLyricType = text }
        case "lyric":
            inLyric = false

        // Note end
        case "note":
            if inNote {
                finishNote()
                inNote = false
            }

        // Forward/backup
        case "forward":
            if let d = Int(text) {
                currentTick += d
            }
        case "backup":
            if let d = Int(text) {
                currentTick = max(0, currentTick - d)
            }

        // Direction
        case "direction":
            if let bpm = directionTempo {
                tempoEvents.append(TempoPoint(tick: currentTick, bpm: bpm))
            }
            inDirection = false

        default:
            break
        }

        currentElement = ""
    }

    // MARK: - Note Finalization

    private func finishNote() {
        guard !noteIsRest else {
            // Rests advance time but don't produce notes
            if !noteIsChord {
                currentTick += noteDuration
            }
            return
        }

        let midi = stepToMidi(step: noteStep, alter: noteAlter, octave: noteOctave)
        guard midi >= 0 && midi <= 127 else {
            if !noteIsChord { currentTick += noteDuration }
            return
        }

        // Scale duration from MusicXML divisions to target ticks-per-quarter
        // MusicXML duration is in units of divisions; our internal format uses ticksPerQuarter
        // Since we set ticksPerQuarter = divisions, duration maps 1:1
        let tickDuration = max(1, noteDuration)
        let startTick = noteIsChord ? max(0, currentTick - tickDuration) : currentTick

        let note = PianoRollNote(
            trackIndex: currentPartIndex,
            channel: 0,
            pitch: midi,
            velocity: 80,
            startTick: startTick,
            duration: tickDuration,
            lyricSyllable: formatLyricSyllable()
        )

        notes.append(note)

        if let syllable = note.lyricSyllable, !syllable.isEmpty {
            lyrics.append((noteID: note.id, syllable: syllable))
        }

        if !noteIsChord {
            currentTick += noteDuration
        }
    }

    private func formatLyricSyllable() -> String? {
        guard let syllable = noteLyricSyllable, !syllable.isEmpty else { return nil }
        switch noteLyricType {
        case "begin", "middle":
            return syllable + "-"
        default:
            return syllable
        }
    }

    private func stepToMidi(step: String, alter: Int, octave: Int) -> Int {
        let stepValues: [String: Int] = [
            "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
        ]
        guard let base = stepValues[step] else { return 60 }
        return (octave + 1) * 12 + base + alter
    }
}
