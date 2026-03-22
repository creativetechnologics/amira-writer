import Foundation

@available(macOS 26.0, *)
@MainActor
enum MusicXMLExporter {

    // MARK: - Public API

    /// Exports the current score to MusicXML format and writes to the given URL.
    static func export(from store: ScoreStore, to outputURL: URL) throws {
        let xml = generateMusicXML(from: store)
        try xml.write(to: outputURL, atomically: true, encoding: .utf8)
        NSLog("[MusicXMLExporter] Exported to %@", outputURL.lastPathComponent)
    }

    /// Returns MusicXML string for the current score.
    static func generateMusicXML(from store: ScoreStore) -> String {
        let tpq = max(1, store.ticksPerQuarter)
        let divisions = tpq  // MusicXML divisions = ticks per quarter note

        // Gather track indices
        let trackIndices = Set(store.pianoRollNotes.map(\.trackIndex))
            .union(Set(store.pianoRollTrackNames.keys))
            .sorted()

        guard !trackIndices.isEmpty else {
            return emptyScore(divisions: divisions)
        }

        // Time signatures and key signatures
        let timeSigs = store.pianoRollTimeSignatures.sorted { $0.tick < $1.tick }
        let keySigs = store.pianoRollKeySignatures.sorted { $0.tick < $1.tick }
        let tempos = store.pianoRollTempoEvents.sorted { $0.tick < $1.tick }

        // Compute measure boundaries
        let totalTicks = max(store.pianoRollLengthTicks, store.pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? 0)
        let measures = computeMeasures(totalTicks: totalTicks, timeSigs: timeSigs, tpq: tpq)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <work>
            <work-title>\(escapeXML(store.metadata.name))</work-title>
          </work>
          <identification>
            <encoding>
              <software>Novotro Score</software>
              <encoding-date>\(dateString())</encoding-date>
            </encoding>
          </identification>
          <part-list>

        """

        // Part list
        for (partNum, trackIdx) in trackIndices.enumerated() {
            let partID = "P\(partNum + 1)"
            let name = store.pianoRollTrackNames[trackIdx] ?? "Track \(trackIdx)"
            xml += "    <score-part id=\"\(partID)\">\n"
            xml += "      <part-name>\(escapeXML(name))</part-name>\n"
            xml += "    </score-part>\n"
        }
        xml += "  </part-list>\n"

        // Parts
        for (partNum, trackIdx) in trackIndices.enumerated() {
            let partID = "P\(partNum + 1)"
            let trackNotes = store.pianoRollNotes
                .filter { $0.trackIndex == trackIdx && !$0.muted }
                .sorted { $0.startTick < $1.startTick }

            xml += "  <part id=\"\(partID)\">\n"

            for (measureIdx, measure) in measures.enumerated() {
                xml += "    <measure number=\"\(measureIdx + 1)\">\n"

                // Attributes on first measure or when time/key sig changes
                if measureIdx == 0 || measure.newTimeSig || measure.newKeySig {
                    xml += "      <attributes>\n"
                    if measureIdx == 0 {
                        xml += "        <divisions>\(divisions)</divisions>\n"
                    }
                    if measureIdx == 0 || measure.newKeySig {
                        let ks = keySigAt(tick: measure.startTick, keySigs: keySigs)
                        xml += "        <key>\n"
                        xml += "          <fifths>\(ks.sharpsFlats)</fifths>\n"
                        xml += "          <mode>\(ks.isMinor ? "minor" : "major")</mode>\n"
                        xml += "        </key>\n"
                    }
                    if measureIdx == 0 || measure.newTimeSig {
                        xml += "        <time>\n"
                        xml += "          <beats>\(measure.numerator)</beats>\n"
                        xml += "          <beat-type>\(measure.denominator)</beat-type>\n"
                        xml += "        </time>\n"
                    }
                    if measureIdx == 0 {
                        xml += "        <clef>\n"
                        xml += "          <sign>G</sign>\n"
                        xml += "          <line>2</line>\n"
                        xml += "        </clef>\n"
                    }
                    xml += "      </attributes>\n"
                }

                // Tempo direction
                if let tempo = tempoAt(tick: measure.startTick, tempos: tempos, measureIdx: measureIdx) {
                    xml += "      <direction placement=\"above\">\n"
                    xml += "        <direction-type>\n"
                    xml += "          <metronome>\n"
                    xml += "            <beat-unit>quarter</beat-unit>\n"
                    xml += "            <per-minute>\(Int(tempo))</per-minute>\n"
                    xml += "          </metronome>\n"
                    xml += "        </direction-type>\n"
                    xml += "        <sound tempo=\"\(Int(tempo))\"/>\n"
                    xml += "      </direction>\n"
                }

                // Notes in this measure
                let measureNotes = trackNotes.filter {
                    $0.startTick < measure.endTick && ($0.startTick + $0.duration) > measure.startTick
                }

                if measureNotes.isEmpty {
                    // Whole-measure rest
                    let restDuration = measure.endTick - measure.startTick
                    xml += "      <note>\n"
                    xml += "        <rest/>\n"
                    xml += "        <duration>\(restDuration)</duration>\n"
                    xml += "        <type>\(durationToType(restDuration, divisions: divisions))</type>\n"
                    xml += "      </note>\n"
                } else {
                    var currentTick = measure.startTick

                    for note in measureNotes {
                        let noteStart = max(note.startTick, measure.startTick)
                        let noteEnd = min(note.startTick + note.duration, measure.endTick)
                        let noteDuration = noteEnd - noteStart

                        // Rest before this note
                        if noteStart > currentTick {
                            let restDur = noteStart - currentTick
                            xml += "      <note>\n"
                            xml += "        <rest/>\n"
                            xml += "        <duration>\(restDur)</duration>\n"
                            xml += "        <type>\(durationToType(restDur, divisions: divisions))</type>\n"
                            xml += "      </note>\n"
                        }

                        // Dynamics as direction (before note)
                        if note.startTick >= measure.startTick {
                            let dynamic = velocityToDynamic(note.velocity)
                            xml += "      <direction placement=\"below\">\n"
                            xml += "        <direction-type>\n"
                            xml += "          <dynamics>\n"
                            xml += "            <\(dynamic)/>\n"
                            xml += "          </dynamics>\n"
                            xml += "        </direction-type>\n"
                            xml += "      </direction>\n"
                        }

                        // The note
                        let (step, alter, octave) = midiPitchToMusicXML(note.pitch)
                        xml += "      <note>\n"
                        xml += "        <pitch>\n"
                        xml += "          <step>\(step)</step>\n"
                        if alter != 0 {
                            xml += "          <alter>\(alter)</alter>\n"
                        }
                        xml += "          <octave>\(octave)</octave>\n"
                        xml += "        </pitch>\n"
                        xml += "        <duration>\(noteDuration)</duration>\n"
                        xml += "        <voice>1</voice>\n"
                        xml += "        <type>\(durationToType(noteDuration, divisions: divisions))</type>\n"

                        // Tie if note extends beyond measure
                        let tieStart = note.startTick + note.duration > measure.endTick
                        let tieStop = note.startTick < measure.startTick
                        if tieStart {
                            xml += "        <tie type=\"start\"/>\n"
                        }
                        if tieStop {
                            xml += "        <tie type=\"stop\"/>\n"
                        }

                        // Notations (tied elements)
                        if tieStart || tieStop {
                            xml += "        <notations>\n"
                            if tieStart {
                                xml += "          <tied type=\"start\"/>\n"
                            }
                            if tieStop {
                                xml += "          <tied type=\"stop\"/>\n"
                            }
                            xml += "        </notations>\n"
                        }

                        xml += "      </note>\n"

                        currentTick = noteEnd
                    }

                    // Trailing rest
                    if currentTick < measure.endTick {
                        let restDur = measure.endTick - currentTick
                        xml += "      <note>\n"
                        xml += "        <rest/>\n"
                        xml += "        <duration>\(restDur)</duration>\n"
                        xml += "        <type>\(durationToType(restDur, divisions: divisions))</type>\n"
                        xml += "      </note>\n"
                    }
                }

                xml += "    </measure>\n"
            }

            xml += "  </part>\n"
        }

        xml += "</score-partwise>\n"
        return xml
    }

    // MARK: - Measure Computation

    private struct MeasureInfo {
        let startTick: Int
        let endTick: Int
        let numerator: Int
        let denominator: Int
        let newTimeSig: Bool
        let newKeySig: Bool
    }

    private static func computeMeasures(totalTicks: Int, timeSigs: [TimeSignatureEvent], tpq: Int) -> [MeasureInfo] {
        var measures: [MeasureInfo] = []
        var tick = 0
        var tsIdx = 0
        var num = timeSigs.first?.numerator ?? 4
        var den = timeSigs.first?.denominator ?? 4

        while tick < totalTicks {
            var newTS = false
            // Check for time signature change
            while tsIdx < timeSigs.count && timeSigs[tsIdx].tick <= tick {
                if timeSigs[tsIdx].numerator != num || timeSigs[tsIdx].denominator != den {
                    num = timeSigs[tsIdx].numerator
                    den = timeSigs[tsIdx].denominator
                    newTS = true
                }
                tsIdx += 1
            }
            if measures.isEmpty { newTS = true }

            let measureLength = num * (tpq * 4 / den)
            let endTick = min(tick + measureLength, totalTicks)

            measures.append(MeasureInfo(
                startTick: tick,
                endTick: endTick,
                numerator: num,
                denominator: den,
                newTimeSig: newTS,
                newKeySig: measures.isEmpty
            ))
            tick = endTick
        }

        if measures.isEmpty {
            measures.append(MeasureInfo(startTick: 0, endTick: tpq * 4, numerator: 4, denominator: 4, newTimeSig: true, newKeySig: true))
        }

        return measures
    }

    // MARK: - Pitch Conversion

    /// Converts MIDI pitch (0-127) to MusicXML (step, alter, octave).
    private static func midiPitchToMusicXML(_ midi: Int) -> (String, Int, Int) {
        let noteNames: [(String, Int)] = [
            ("C", 0), ("C", 1), ("D", 0), ("D", 1), ("E", 0),
            ("F", 0), ("F", 1), ("G", 0), ("G", 1), ("A", 0), ("A", 1), ("B", 0)
        ]
        let noteIndex = midi % 12
        let octave = (midi / 12) - 1
        let (step, alter) = noteNames[noteIndex]
        return (step, alter, octave)
    }

    // MARK: - Duration Type

    private static func durationToType(_ duration: Int, divisions: Int) -> String {
        let ratio = Double(duration) / Double(divisions)
        if ratio >= 4.0 { return "whole" }
        if ratio >= 2.0 { return "half" }
        if ratio >= 1.0 { return "quarter" }
        if ratio >= 0.5 { return "eighth" }
        if ratio >= 0.25 { return "16th" }
        if ratio >= 0.125 { return "32nd" }
        return "64th"
    }

    // MARK: - Velocity to Dynamic

    private static func velocityToDynamic(_ velocity: Int) -> String {
        switch velocity {
        case 0..<24: return "ppp"
        case 24..<40: return "pp"
        case 40..<56: return "p"
        case 56..<72: return "mp"
        case 72..<88: return "mf"
        case 88..<104: return "f"
        case 104..<120: return "ff"
        default: return "fff"
        }
    }

    // MARK: - Helpers

    private static func keySigAt(tick: Int, keySigs: [KeySignatureEvent]) -> KeySignatureEvent {
        var result = KeySignatureEvent(tick: 0, sharpsFlats: 0, isMinor: false)
        for ks in keySigs where ks.tick <= tick {
            result = ks
        }
        return result
    }

    private static func tempoAt(tick: Int, tempos: [TempoPoint], measureIdx: Int) -> Double? {
        for tempo in tempos {
            if tempo.tick == tick || (measureIdx == 0 && tempo.tick == 0) {
                return tempo.bpm
            }
        }
        return nil
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func emptyScore(divisions: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1">
              <part-name>Part 1</part-name>
            </score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>\(divisions)</divisions>
                <time>
                  <beats>4</beats>
                  <beat-type>4</beat-type>
                </time>
                <clef>
                  <sign>G</sign>
                  <line>2</line>
                </clef>
              </attributes>
              <note>
                <rest/>
                <duration>\(divisions * 4)</duration>
                <type>whole</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
    }
}
