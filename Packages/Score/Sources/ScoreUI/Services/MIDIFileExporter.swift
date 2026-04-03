import Foundation

/// Exports PianoRollNotes to a Standard MIDI File (SMF) Format 1.
@available(macOS 26.0, *)
@MainActor
enum MIDIFileExporter {

    static func export(from store: ScoreStore, to outputURL: URL) throws {
        let data = generateSMF(from: store)
        try data.write(to: outputURL)
        NSLog("[MIDIFileExporter] Exported %d bytes to %@", data.count, outputURL.lastPathComponent)
    }

    static func generateSMF(from store: ScoreStore) -> Data {
        let tpq = UInt16(max(1, min(store.ticksPerQuarter, 32767)))
        let trackIndices = Set(store.pianoRollNotes.map(\.trackIndex)).sorted()

        // Build tracks: track 0 = tempo/meta, track 1..N = note data
        var tracks: [Data] = []

        // Track 0: tempo map + time signatures + key signatures
        tracks.append(buildTempoTrack(store: store, tpq: Int(tpq)))

        // Note tracks
        for trackIdx in trackIndices {
            let notes = store.pianoRollNotes
                .filter { $0.trackIndex == trackIdx && !$0.muted }
                .sorted { $0.startTick < $1.startTick }
            let trackName = store.pianoRollTrackNames[trackIdx] ?? "Track \(trackIdx)"
            tracks.append(buildNoteTrack(notes: notes, name: trackName))
        }

        // Assemble SMF
        var smf = Data()

        // Header chunk: MThd
        smf.append(contentsOf: [0x4D, 0x54, 0x68, 0x64]) // "MThd"
        smf.append(uint32BE: 6) // header length
        smf.append(uint16BE: 1) // format 1
        smf.append(uint16BE: UInt16(tracks.count))
        smf.append(uint16BE: tpq)

        // Track chunks
        for track in tracks {
            smf.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B]) // "MTrk"
            smf.append(uint32BE: UInt32(track.count))
            smf.append(track)
        }

        return smf
    }

    // MARK: - Track Builders

    private static func buildTempoTrack(store: ScoreStore, tpq: Int) -> Data {
        var events: [(tick: Int, data: [UInt8])] = []

        // Time signatures
        for ts in store.pianoRollTimeSignatures.sorted(by: { $0.tick < $1.tick }) {
            let denom = logBase2(ts.denominator)
            events.append((ts.tick, [0xFF, 0x58, 0x04, UInt8(ts.numerator), UInt8(denom), 24, 8]))
        }

        // Key signatures
        for ks in store.pianoRollKeySignatures.sorted(by: { $0.tick < $1.tick }) {
            let sf = Int8(ks.sharpsFlats)
            events.append((ks.tick, [0xFF, 0x59, 0x02, UInt8(bitPattern: sf), ks.isMinor ? 1 : 0]))
        }

        // Tempo events
        for tempo in store.pianoRollTempoEvents.sorted(by: { $0.tick < $1.tick }) {
            let usPerBeat = UInt32((60_000_000.0 / max(20.0, tempo.bpm)).rounded())
            events.append((tempo.tick, [
                0xFF, 0x51, 0x03,
                UInt8((usPerBeat >> 16) & 0xFF),
                UInt8((usPerBeat >> 8) & 0xFF),
                UInt8(usPerBeat & 0xFF)
            ]))
        }

        // Track name
        let nameBytes = Array("Tempo Map".utf8)
        events.insert((0, [0xFF, 0x03, UInt8(nameBytes.count)] + nameBytes), at: 0)

        // Sort by tick, then encode
        events.sort { $0.tick < $1.tick }
        return encodeTrackEvents(events)
    }

    private static func buildNoteTrack(notes: [PianoRollNote], name: String) -> Data {
        var events: [(tick: Int, data: [UInt8])] = []

        // Track name
        let nameBytes = Array(name.utf8)
        let nameLen = min(nameBytes.count, 127)
        events.append((0, [0xFF, 0x03, UInt8(nameLen)] + Array(nameBytes.prefix(nameLen))))

        // Note on/off pairs
        for note in notes {
            let ch = UInt8(min(max(note.channel, 0), 15))
            let pitch = UInt8(min(max(note.pitch, 0), 127))
            let vel = UInt8(min(max(note.velocity, 1), 127))
            events.append((note.startTick, [0x90 | ch, pitch, vel]))
            events.append((note.startTick + note.duration, [0x80 | ch, pitch, 0]))
        }

        // Sort: by tick, then note-off before note-on at same tick
        events.sort {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            let isOff0 = ($0.data.first ?? 0) & 0xF0 == 0x80
            let isOff1 = ($1.data.first ?? 0) & 0xF0 == 0x80
            return isOff0 && !isOff1
        }

        return encodeTrackEvents(events)
    }

    // MARK: - Encoding

    private static func encodeTrackEvents(_ events: [(tick: Int, data: [UInt8])]) -> Data {
        var data = Data()
        var lastTick = 0

        for event in events {
            let delta = max(0, event.tick - lastTick)
            data.append(contentsOf: variableLengthQuantity(delta))
            data.append(contentsOf: event.data)
            lastTick = event.tick
        }

        // End of track
        data.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])
        return data
    }

    private static func variableLengthQuantity(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        if v == 0 { return [0] }
        var bytes: [UInt8] = []
        bytes.append(UInt8(v & 0x7F))
        v >>= 7
        while v > 0 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        return bytes.reversed()
    }

    private static func logBase2(_ value: Int) -> Int {
        var v = max(1, value)
        var result = 0
        while v > 1 { v >>= 1; result += 1 }
        return result
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func append(uint16BE value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func append(uint32BE value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
