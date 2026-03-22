import Foundation

// MARK: - OWP Models (adapted from Novotro Score)
// Only includes types needed for animation: characters, lyrics, tempo, timing.

// MARK: - Characters

struct OPWCharacterImage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var filename: String
    var category: String

    init(id: UUID = UUID(), filename: String, category: String) {
        self.id = id
        self.filename = filename
        self.category = category
    }
}

struct OPWCharacter: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var description: String?
    var associatedChannelKeys: [String]
    var galleryCategories: [String]
    var images: [OPWCharacterImage]
    var colorHex: String?

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        associatedChannelKeys: [String] = [],
        galleryCategories: [String] = [],
        images: [OPWCharacterImage] = [],
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.associatedChannelKeys = associatedChannelKeys
        self.galleryCategories = galleryCategories
        self.images = images
        self.colorHex = colorHex
    }

    var directoryName: String {
        let safe = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? id.uuidString : safe
    }
}

struct OPWCharactersFile: Codable, Sendable {
    var version: Int
    var characters: [OPWCharacter]

    init(version: Int = 1, characters: [OPWCharacter] = []) {
        self.version = version
        self.characters = characters
    }
}

// MARK: - Tempo

struct OWPTempoPoint: Codable, Hashable, Identifiable, Sendable {
    var tick: Int
    var bpm: Double

    var id: String {
        "\(tick)-\(Int((bpm * 1000).rounded()))"
    }
}

// MARK: - Lyric Alignment (for lip sync)

struct OWPLyricAlignmentEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var wordIndex: Int
    var tokenID: UUID?
    var syllableIndex: Int
    var noteID: UUID
    var confirmed: Bool

    init(
        id: UUID = UUID(),
        wordIndex: Int,
        tokenID: UUID? = nil,
        syllableIndex: Int,
        noteID: UUID,
        confirmed: Bool = false
    ) {
        self.id = id
        self.wordIndex = wordIndex
        self.tokenID = tokenID
        self.syllableIndex = syllableIndex
        self.noteID = noteID
        self.confirmed = confirmed
    }
}

struct OWPLyricAlignment: Codable, Hashable, Sendable {
    var songPath: String
    var trackKey: String
    var entries: [OWPLyricAlignmentEntry]

    var coverage: Double {
        guard !entries.isEmpty else { return 0 }
        let confirmed = entries.filter(\.confirmed).count
        return Double(confirmed) / Double(entries.count)
    }
}

// MARK: - Piano Roll Note (for timing data)

struct OWPNote: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var trackIndex: Int
    var channel: Int
    var pitch: Int
    var velocity: Int
    var startTick: Int
    var duration: Int
    var lyricSyllable: String?

    init(
        id: UUID = UUID(),
        trackIndex: Int,
        channel: Int,
        pitch: Int,
        velocity: Int,
        startTick: Int,
        duration: Int,
        lyricSyllable: String? = nil
    ) {
        self.id = id
        self.trackIndex = trackIndex
        self.channel = channel
        self.pitch = pitch
        self.velocity = velocity
        self.startTick = startTick
        self.duration = max(1, duration)
        self.lyricSyllable = lyricSyllable
    }
}

// MARK: - Instrument Mapping (minimal for character association)

struct OWPInstrumentMapping: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var channelKey: String
    var displayName: String
    var trackRoleRaw: String?
    var colorHex: String?

    var isVocal: Bool {
        trackRoleRaw == "vocal"
    }
}

// MARK: - Cue Mapping

struct OWPCueMapping: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sectionPath: String
    var midiPath: String?
    var notes: String

    init(id: UUID = UUID(), sectionPath: String, midiPath: String? = nil, notes: String = "") {
        self.id = id
        self.sectionPath = sectionPath
        self.midiPath = midiPath
        self.notes = notes
    }
}

// MARK: - Index File

struct OWPIndexFile: Codable, Sendable {
    var version: Int
    var cueMappings: [OWPCueMapping]
    var instrumentMappings: [OWPInstrumentMapping]

    init(version: Int = 2, cueMappings: [OWPCueMapping] = [], instrumentMappings: [OWPInstrumentMapping] = []) {
        self.version = version
        self.cueMappings = cueMappings
        self.instrumentMappings = instrumentMappings
    }

    private enum CodingKeys: String, CodingKey {
        case version, cueMappings, instrumentMappings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        cueMappings = try c.decodeIfPresent([OWPCueMapping].self, forKey: .cueMappings) ?? []
        instrumentMappings = try c.decodeIfPresent([OWPInstrumentMapping].self, forKey: .instrumentMappings) ?? []
    }
}

// MARK: - OWS Song Data (what we extract from .ows files for animation)

struct OWSSongData: Codable, Sendable {
    var title: String
    var ticksPerQuarter: Int
    var tempoEvents: [OWPTempoPoint]
    var notes: [OWPNote]
    var trackNames: [Int: String]
    var lyricAlignments: [OWPLyricAlignment]
    var lengthTicks: Int
    /// Full lyrics text if stored in the OWS file (e.g. libretto lines).
    var lyricsText: String?

    init(
        title: String = "",
        ticksPerQuarter: Int = 480,
        tempoEvents: [OWPTempoPoint] = [],
        notes: [OWPNote] = [],
        trackNames: [Int: String] = [:],
        lyricAlignments: [OWPLyricAlignment] = [],
        lengthTicks: Int = 0,
        lyricsText: String? = nil
    ) {
        self.title = title
        self.ticksPerQuarter = ticksPerQuarter
        self.tempoEvents = tempoEvents
        self.notes = notes
        self.trackNames = trackNames
        self.lyricAlignments = lyricAlignments
        self.lengthTicks = lengthTicks
        self.lyricsText = lyricsText
    }

    /// Reconstruct lyrics from note syllables using alignment data.
    /// Groups syllables into words using alignment wordIndex, and groups
    /// words into lines using timing gaps between notes.
    func extractLyrics() -> String {
        // If we have stored lyrics, use them
        if let text = lyricsText, !text.isEmpty { return text }

        guard !lyricAlignments.isEmpty else {
            return extractLyricsFromNotes()
        }

        // Use the first alignment track
        let alignment = lyricAlignments[0]
        let notesByID: [UUID: OWPNote] = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        // Sort entries by note start tick, then by syllable index
        let sorted = alignment.entries.sorted { a, b in
            let tickA = notesByID[a.noteID]?.startTick ?? 0
            let tickB = notesByID[b.noteID]?.startTick ?? 0
            if tickA != tickB { return tickA < tickB }
            return a.syllableIndex < b.syllableIndex
        }

        // Group entries by wordIndex to form words
        var wordGroups: [(wordIndex: Int, syllables: [(entry: OWPLyricAlignmentEntry, note: OWPNote)])] = []
        var currentWordIndex = -1

        for entry in sorted {
            guard let note = notesByID[entry.noteID] else { continue }
            if entry.wordIndex != currentWordIndex {
                wordGroups.append((wordIndex: entry.wordIndex, syllables: []))
                currentWordIndex = entry.wordIndex
            }
            wordGroups[wordGroups.count - 1].syllables.append((entry: entry, note: note))
        }

        // Build words from syllables, insert line breaks at timing gaps
        var lines: [String] = []
        var currentLine: [String] = []
        var lastEndTick = 0
        let lineGapThreshold = ticksPerQuarter * 2  // half-note gap → new line

        for group in wordGroups {
            guard let firstNote = group.syllables.first?.note else { continue }

            // Check for a timing gap that warrants a new line
            if lastEndTick > 0, firstNote.startTick - lastEndTick > lineGapThreshold, !currentLine.isEmpty {
                lines.append(currentLine.joined(separator: " "))
                currentLine = []
            }

            // Build word from syllables
            let word = group.syllables
                .compactMap { $0.note.lyricSyllable }
                .joined()

            if !word.isEmpty {
                currentLine.append(word)
            }

            if let lastNote = group.syllables.last?.note {
                lastEndTick = lastNote.startTick + lastNote.duration
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine.joined(separator: " "))
        }

        return lines.joined(separator: "\n")
    }

    /// Fallback: extract lyrics directly from notes with lyricSyllable set.
    private func extractLyricsFromNotes() -> String {
        let vocalNotes = notes
            .filter { $0.lyricSyllable != nil && !($0.lyricSyllable?.isEmpty ?? true) }
            .sorted { $0.startTick < $1.startTick }

        guard !vocalNotes.isEmpty else { return "" }

        var lines: [String] = []
        var currentLine: [String] = []
        var lastEndTick = 0
        let lineGapThreshold = ticksPerQuarter * 2

        for note in vocalNotes {
            if lastEndTick > 0, note.startTick - lastEndTick > lineGapThreshold, !currentLine.isEmpty {
                lines.append(currentLine.joined())
                currentLine = []
            }

            let syllable = note.lyricSyllable ?? ""
            // Heuristic: if syllable starts with space or uppercase, start new word
            if syllable.hasPrefix(" ") || (syllable.first?.isUppercase == true && !currentLine.isEmpty) {
                currentLine.append(" ")
            }
            currentLine.append(syllable)

            lastEndTick = note.startTick + note.duration
        }

        if !currentLine.isEmpty {
            lines.append(currentLine.joined())
        }

        return lines.joined(separator: "\n")
    }

    /// Convert a tick position to seconds using the tempo map.
    func tickToSeconds(_ tick: Int) -> Double {
        guard !tempoEvents.isEmpty else {
            let bpm = 120.0
            return Double(tick) / Double(ticksPerQuarter) * (60.0 / bpm)
        }

        var seconds = 0.0
        var prevTick = 0
        var currentBPM = tempoEvents.first?.bpm ?? 120.0

        for event in tempoEvents.sorted(by: { $0.tick < $1.tick }) {
            if event.tick > tick { break }
            let deltaTicks = event.tick - prevTick
            seconds += Double(deltaTicks) / Double(ticksPerQuarter) * (60.0 / currentBPM)
            prevTick = event.tick
            currentBPM = event.bpm
        }

        let remainingTicks = tick - prevTick
        seconds += Double(remainingTicks) / Double(ticksPerQuarter) * (60.0 / currentBPM)
        return seconds
    }

    /// Convert a tick position to a frame number.
    func tickToFrame(_ tick: Int, fps: Int) -> Int {
        Int((tickToSeconds(tick) * Double(fps)).rounded())
    }
}
