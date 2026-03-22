import Foundation

enum MIDIParseError: Error {
    case invalidHeader
    case unsupportedDivision
    case malformedTrack
}

struct MIDIParser {
    static func parse(_ data: Data) throws -> ParsedPianoRoll {
        // Minimum valid MIDI file: 14-byte header + at least 1 track header (8 bytes)
        guard data.count >= 14 else {
            throw MIDIParseError.invalidHeader
        }

        var reader = ByteReader(data: data)

        guard reader.readString(count: 4) == "MThd" else {
            throw MIDIParseError.invalidHeader
        }

        let headerLength = Int(reader.readUInt32())
        guard headerLength >= 6 else {
            throw MIDIParseError.invalidHeader
        }

        _ = reader.readUInt16() // format
        let trackCount = min(Int(reader.readUInt16()), 256)
        let division = Int(reader.readUInt16())

        if headerLength > 6 {
            _ = reader.readBytes(count: headerLength - 6)
        }

        guard (division & 0x8000) == 0 else {
            throw MIDIParseError.unsupportedDivision
        }

        let ticksPerQuarter = division

        var trackNames: [Int: String] = [:]
        var channelPrograms: [Int: Int] = [:]
        var trackChannelPrograms: [Int: [Int: Int]] = [:]
        var notes: [PianoRollNote] = []
        var tempoEvents: [TempoPoint] = []
        var timeSignatureEvents: [(tick: Int, numerator: Int, denominator: Int)] = []
        var keySignatureEvents: [(tick: Int, sharpsFlats: Int, isMinor: Bool)] = []
        var maxEndTick = 0
        var lyricEvents: [(tick: Int, text: String, trackIndex: Int)] = []

        for trackIndex in 0..<trackCount {
            guard reader.remaining >= 8 else {
                // Not enough data for another track chunk header; stop gracefully.
                break
            }
            guard reader.readString(count: 4) == "MTrk" else {
                throw MIDIParseError.malformedTrack
            }

            let trackLength = Int(reader.readUInt32())
            let trackEndOffset = min(reader.offset + trackLength, data.count)
            var absoluteTick = 0
            var runningStatus: UInt8 = 0
            var openNotes: [String: (startTick: Int, velocity: Int)] = [:]
            var currentTrackPrograms: [Int: Int] = [:]

            while reader.offset < trackEndOffset {
                let delta = Int(reader.readVariableLengthQuantity())
                absoluteTick = min(absoluteTick + delta, 40_000_000)

                var statusByte = reader.peekUInt8()
                if statusByte >= 0x80 {
                    statusByte = reader.readUInt8()
                    runningStatus = statusByte
                } else {
                    statusByte = runningStatus
                }

                if statusByte == 0xFF {
                    runningStatus = 0 // Meta events cancel running status per MIDI spec
                    let metaType = reader.readUInt8()
                    let length = Int(reader.readVariableLengthQuantity())
                    let bytes = reader.readBytes(count: length)

                    if metaType == 0x03,
                       let trackName = String(bytes: bytes, encoding: .utf8),
                       !trackName.isEmpty {
                        trackNames[trackIndex] = trackName
                    }

                    // FF 05: Lyric meta event — extract syllable text
                    if metaType == 0x05,
                       let lyricText = String(bytes: bytes, encoding: .utf8),
                       !lyricText.trimmingCharacters(in: .whitespaces).isEmpty {
                        lyricEvents.append((tick: absoluteTick, text: lyricText, trackIndex: trackIndex))
                    }

                    if metaType == 0x51, length == 3, bytes.count >= 3 {
                        let mpq = (Int(bytes[0]) << 16) | (Int(bytes[1]) << 8) | Int(bytes[2])
                        if mpq > 0 {
                            let bpm = 60_000_000.0 / Double(mpq)
                            tempoEvents.append(.init(tick: absoluteTick, bpm: bpm))
                        }
                    }

                    if metaType == 0x58, length >= 2, bytes.count >= 2 {
                        let numerator = Int(bytes[0])
                        let denominator = 1 << Int(bytes[1]) // stored as power of 2
                        if numerator > 0, denominator > 0 {
                            timeSignatureEvents.append((tick: absoluteTick, numerator: numerator, denominator: denominator))
                        }
                    }

                    if metaType == 0x59, length >= 2, bytes.count >= 2 {
                        let sf = Int(Int8(bitPattern: bytes[0])) // signed: negative = flats
                        let mi = bytes[1] // 0 = major, 1 = minor
                        keySignatureEvents.append((tick: absoluteTick, sharpsFlats: sf, isMinor: mi != 0))
                    }

                    continue
                }

                if statusByte == 0xF0 || statusByte == 0xF7 {
                    runningStatus = 0 // SysEx cancels running status per MIDI spec
                    let length = Int(reader.readVariableLengthQuantity())
                    _ = reader.readBytes(count: length)
                    continue
                }

                let command = statusByte & 0xF0
                let channel = Int(statusByte & 0x0F)

                switch command {
                case 0x80, 0x90:
                    let pitch = Int(reader.readUInt8())
                    let velocity = Int(reader.readUInt8())
                    let key = "\(channel):\(pitch)"

                    if command == 0x90 && velocity > 0 {
                        openNotes[key] = (startTick: absoluteTick, velocity: velocity)
                    } else if let open = openNotes.removeValue(forKey: key) {
                        let duration = max(1, absoluteTick - open.startTick)
                        let note = PianoRollNote(
                            trackIndex: trackIndex,
                            channel: channel,
                            pitch: pitch,
                            velocity: open.velocity,
                            startTick: open.startTick,
                            duration: duration
                        )
                        guard notes.count < 500_000 else {
                            reader.offset = trackEndOffset
                            break
                        }
                        notes.append(note)
                        maxEndTick = max(maxEndTick, note.startTick + note.duration)
                    }

                case 0xA0, 0xB0, 0xE0:
                    _ = reader.readBytes(count: 2)

                case 0xC0:
                    let program = Int(reader.readUInt8())
                    currentTrackPrograms[channel] = program
                    if channelPrograms[channel] == nil {
                        channelPrograms[channel] = program
                    }

                case 0xD0:
                    _ = reader.readBytes(count: 1)

                default:
                    // Unknown or unsupported status byte — skip to end of track
                    // rather than aborting the entire parse.
                    reader.offset = trackEndOffset
                }
            }

            if !currentTrackPrograms.isEmpty {
                trackChannelPrograms[trackIndex] = currentTrackPrograms
            }

            // Advance to the declared track end even if we consumed fewer bytes
            // (some MIDI files have padding), or if we hit EOF on a truncated file.
            reader.offset = trackEndOffset
        }

        let normalizedTempoEvents = normalizeTempoEvents(tempoEvents)
        let initialTempo = normalizedTempoEvents.first?.bpm ?? 120

        // Sort notes and lyric events
        var sortedNotes = notes.sorted(by: {
            if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            return $0.pitch < $1.pitch
        })
        let sortedLyrics = lyricEvents.sorted { $0.tick < $1.tick }

        // Match FF 05 lyric events to notes by tick proximity.
        // For each lyric event, find the nearest note (on the same track or any track)
        // within a tolerance window and assign the lyric as lyricSyllable.
        if !sortedLyrics.isEmpty {
            let tolerance = max(ticksPerQuarter / 4, 10)  // quarter-beat tolerance
            for lyric in sortedLyrics {
                var bestIdx = -1
                var bestDist = Int.max
                for (idx, note) in sortedNotes.enumerated() {
                    guard note.lyricSyllable == nil || note.lyricSyllable?.isEmpty == true else { continue }
                    let dist = abs(note.startTick - lyric.tick)
                    guard dist <= tolerance else {
                        continue
                    }
                    // Prefer same-track match
                    let sameTrack = note.trackIndex == lyric.trackIndex
                    let effectiveDist = sameTrack ? dist : dist + tolerance / 2
                    if effectiveDist < bestDist {
                        bestDist = effectiveDist
                        bestIdx = idx
                    }
                }
                if bestIdx >= 0 {
                    sortedNotes[bestIdx].lyricSyllable = lyric.text.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return ParsedPianoRoll(
            trackNames: trackNames,
            channelPrograms: channelPrograms,
            trackChannelPrograms: trackChannelPrograms,
            notes: sortedNotes,
            tempoEvents: normalizedTempoEvents,
            initialTempoBPM: initialTempo,
            ticksPerQuarter: ticksPerQuarter,
            lengthTicks: max(maxEndTick, ticksPerQuarter * 8),
            timeSignatureEvents: timeSignatureEvents.sorted(by: { $0.tick < $1.tick }),
            keySignatureEvents: keySignatureEvents.sorted(by: { $0.tick < $1.tick }),
            lyricEvents: sortedLyrics
        )
    }

    private static func normalizeTempoEvents(_ rawEvents: [TempoPoint]) -> [TempoPoint] {
        guard !rawEvents.isEmpty else {
            return [TempoPoint(tick: 0, bpm: 120)]
        }

        let sorted = rawEvents.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            return $0.bpm < $1.bpm
        }

        var dedupedByTick: [Int: TempoPoint] = [:]
        for event in sorted {
            dedupedByTick[event.tick] = event
        }

        var deduped = dedupedByTick.values.sorted { $0.tick < $1.tick }
        if deduped.first?.tick != 0 {
            deduped.insert(TempoPoint(tick: 0, bpm: deduped.first?.bpm ?? 120), at: 0)
        }
        return deduped
    }
}

private struct ByteReader {
    private let data: Data
    fileprivate var offset: Int

    /// Number of bytes remaining in the data.
    var remaining: Int { data.count - offset }

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    mutating func readUInt8() -> UInt8 {
        guard offset < data.count else { return 0 }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func peekUInt8() -> UInt8 {
        guard offset < data.count else { return 0 }
        return data[offset]
    }

    mutating func readUInt16() -> UInt16 {
        guard remaining >= 2 else { return 0 }
        let b1 = UInt16(readUInt8())
        let b2 = UInt16(readUInt8())
        return (b1 << 8) | b2
    }

    mutating func readUInt32() -> UInt32 {
        guard remaining >= 4 else { return 0 }
        let b1 = UInt32(readUInt8())
        let b2 = UInt32(readUInt8())
        let b3 = UInt32(readUInt8())
        let b4 = UInt32(readUInt8())
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    }

    mutating func readString(count: Int) -> String {
        let bytes = readBytes(count: count)
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    mutating func readBytes(count: Int) -> [UInt8] {
        let end = min(offset + count, data.count)
        let slice = data[offset..<end]
        offset = end
        return Array(slice)
    }

    mutating func readVariableLengthQuantity() -> UInt32 {
        var value: UInt32 = 0
        // VLQ is at most 4 bytes in MIDI; cap iterations to prevent infinite loops
        // on truncated data where every remaining byte has the continuation bit set.
        for _ in 0..<4 {
            guard offset < data.count else { break }
            let byte = readUInt8()
            value = (value << 7) | UInt32(byte & 0x7F)
            if (byte & 0x80) == 0 {
                break
            }
        }
        return value
    }
}
