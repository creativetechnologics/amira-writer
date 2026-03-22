import Foundation

/// Analyzes a score and produces a chunk plan for Suno generation.
enum SunoChunkPlanner {

    static func plan(
        notes: [PianoRollNote],
        mappings: [String: InstrumentMapping],
        trackChannelToMappingKey: [String: String],
        tempoEvents: [TempoPoint],
        timeSignatures: [TimeSignatureEvent],
        markers: [MixMarker],
        autoDetectedSections: [SongSection] = [],
        manualSplitTicks: [Int] = [],
        ticksPerQuarter: Int,
        songLengthTicks: Int,
        songID: UUID = UUID(),
        config: SunoChunkConfig = SunoChunkConfig(),
        splitMode: SunoSplitMode = .structural,
        styleTemplate: String = ""
    ) -> SunoChunkPlan {
        let boundaries = computeBoundaries(
            notes: notes, markers: markers,
            autoDetectedSections: autoDetectedSections,
            manualSplitTicks: manualSplitTicks,
            tempoEvents: tempoEvents,
            ticksPerQuarter: ticksPerQuarter,
            songLengthTicks: songLengthTicks,
            splitMode: splitMode,
            config: config
        )

        var chunks: [SunoChunkSpec] = []
        for i in 0..<boundaries.count - 1 {
            let segStart = boundaries[i]
            let segEnd = boundaries[i + 1]
            let segNotes = notes.filter {
                $0.startTick >= segStart && $0.startTick < segEnd && !$0.muted
            }

            let density = analyzeDensity(
                notes: segNotes,
                trackChannelToMappingKey: trackChannelToMappingKey,
                config: config
            )

            let groups: [InstrumentGroup]
            if config.splitByInstrumentGroup {
                groups = splitByInstrumentGroup(
                    notes: segNotes,
                    trackChannelToMappingKey: trackChannelToMappingKey,
                    mappings: mappings,
                    density: density
                )
            } else {
                groups = [InstrumentGroup(
                    label: "Full Arrangement",
                    keys: activeInstrumentKeys(notes: segNotes, trackChannelToMappingKey: trackChannelToMappingKey)
                )]
            }

            let timeStart = ticksToSeconds(segStart, tempoEvents: tempoEvents, tpq: ticksPerQuarter)
            let timeEnd = ticksToSeconds(segEnd, tempoEvents: tempoEvents, tpq: ticksPerQuarter)

            for group in groups {
                let prompt = generatePrompt(
                    group: group, mappings: mappings,
                    notes: segNotes, density: density,
                    tempoEvents: tempoEvents,
                    tickStart: segStart,
                    ticksPerQuarter: ticksPerQuarter,
                    styleTemplate: styleTemplate
                )
                chunks.append(SunoChunkSpec(
                    tickStart: segStart, tickEnd: segEnd,
                    timeStart: timeStart, timeEnd: timeEnd,
                    instrumentGroup: group.keys,
                    groupLabel: group.label,
                    density: density,
                    generatedPrompt: prompt
                ))
            }
        }

        return SunoChunkPlan(
            songID: songID, chunks: chunks,
            styleTemplate: styleTemplate, config: config
        )
    }

    // MARK: - Private helpers

    private static func computeBoundaries(
        notes: [PianoRollNote],
        markers: [MixMarker],
        autoDetectedSections: [SongSection] = [],
        manualSplitTicks: [Int] = [],
        tempoEvents: [TempoPoint],
        ticksPerQuarter: Int,
        songLengthTicks: Int,
        splitMode: SunoSplitMode,
        config: SunoChunkConfig
    ) -> [Int] {
        var bounds: Set<Int> = [0, songLengthTicks]

        switch splitMode {
        case .noSplit:
            return [0, songLengthTicks]
        case .manualSplits:
            bounds.formUnion(manualSplitTicks.filter { $0 > 0 && $0 < songLengthTicks })
            return bounds.sorted()
        case .evenDuration:
            let totalSeconds = ticksToSeconds(songLengthTicks, tempoEvents: tempoEvents, tpq: ticksPerQuarter)
            guard totalSeconds > config.maxChunkDurationSeconds, config.maxChunkDurationSeconds > 1 else {
                return [0, songLengthTicks]
            }
            let chunkCount = Int(ceil(totalSeconds / config.maxChunkDurationSeconds))
            for idx in 1..<chunkCount {
                let targetSeconds = totalSeconds * Double(idx) / Double(chunkCount)
                let tick = tickAtSeconds(targetSeconds, tempoEvents: tempoEvents, tpq: ticksPerQuarter)
                if tick > 0 && tick < songLengthTicks {
                    bounds.insert(tick)
                }
            }
            return bounds.sorted()
        case .structural:
            break
        }

        for marker in markers {
            if marker.tick > 0 && marker.tick < songLengthTicks {
                bounds.insert(marker.tick)
            }
        }

        for section in autoDetectedSections {
            if section.startTick > 0 && section.startTick < songLengthTicks {
                bounds.insert(section.startTick)
            }
        }

        var sorted = bounds.sorted()
        var i = 0
        while i < sorted.count - 1 {
            let start = sorted[i]
            let end = sorted[i + 1]
            let duration = ticksToSeconds(end, tempoEvents: tempoEvents, tpq: ticksPerQuarter)
                - ticksToSeconds(start, tempoEvents: tempoEvents, tpq: ticksPerQuarter)
            if duration > config.maxChunkDurationSeconds && end - start > 1 {
                let mid = (start + end) / 2
                sorted.insert(mid, at: i + 1)
            } else {
                i += 1
            }
        }

        return sorted
    }

    private static func tickAtSeconds(_ seconds: Double, tempoEvents: [TempoPoint], tpq: Int) -> Int {
        guard seconds > 0, tpq > 0 else { return 0 }
        let sorted = tempoEvents.sorted { $0.tick < $1.tick }
        var elapsed: Double = 0
        var lastTick = 0
        var currentBPM = sorted.first?.bpm ?? 120.0

        for event in sorted {
            guard event.tick > lastTick else {
                currentBPM = event.bpm
                continue
            }
            let spanSeconds = Double(event.tick - lastTick) / Double(tpq) * (60.0 / currentBPM)
            if elapsed + spanSeconds >= seconds {
                let remaining = seconds - elapsed
                return lastTick + Int((remaining / (60.0 / currentBPM) * Double(tpq)).rounded())
            }
            elapsed += spanSeconds
            lastTick = event.tick
            currentBPM = event.bpm
        }

        return lastTick + Int(((seconds - elapsed) / (60.0 / currentBPM) * Double(tpq)).rounded())
    }

    private static func analyzeDensity(
        notes: [PianoRollNote],
        trackChannelToMappingKey: [String: String],
        config: SunoChunkConfig
    ) -> ChunkDensity {
        let activeKeys = Set(activeInstrumentKeys(notes: notes, trackChannelToMappingKey: trackChannelToMappingKey))
        let count = activeKeys.count
        if count >= config.densityThresholdDense { return .dense }
        if count >= config.densityThresholdMedium { return .medium }
        return .sparse
    }

    struct InstrumentGroup {
        var label: String
        var keys: [String]
    }

    private static func splitByInstrumentGroup(
        notes: [PianoRollNote],
        trackChannelToMappingKey: [String: String],
        mappings: [String: InstrumentMapping],
        density: ChunkDensity
    ) -> [InstrumentGroup] {
        let activeKeys = activeInstrumentKeys(notes: notes, trackChannelToMappingKey: trackChannelToMappingKey)

        switch density {
        case .sparse:
            return [InstrumentGroup(label: "Full Orchestra", keys: activeKeys)]
        case .medium:
            let mid = activeKeys.count / 2
            // If fewer than 2 keys, don't split — produces an empty group.
            guard mid > 0 else {
                return [InstrumentGroup(label: "Full Orchestra", keys: activeKeys)]
            }
            return [
                InstrumentGroup(label: "Group A", keys: Array(activeKeys[..<mid])),
                InstrumentGroup(label: "Group B", keys: Array(activeKeys[mid...])),
            ]
        case .dense:
            let groupSize = max(3, activeKeys.count / 3)
            var groups: [InstrumentGroup] = []
            for (i, chunk) in activeKeys.chunked(into: groupSize).enumerated() {
                // Use A-Z for first 26 groups, then numeric labels.
                let label = i < 26
                    ? "Group \(Character(UnicodeScalar(65 + i)!))"
                    : "Group \(i + 1)"
                groups.append(InstrumentGroup(
                    label: label,
                    keys: chunk
                ))
            }
            return groups
        }
    }

    private static func activeInstrumentKeys(
        notes: [PianoRollNote],
        trackChannelToMappingKey: [String: String]
    ) -> [String] {
        var activeKeys: [String] = []
        var seen: Set<String> = []
        for note in notes {
            let tcKey = "Track\(note.trackIndex)Ch\(note.channel)"
            if let mk = trackChannelToMappingKey[tcKey], !seen.contains(mk) {
                activeKeys.append(mk)
                seen.insert(mk)
            }
        }
        return activeKeys
    }

    /// Convert MIDI ticks to seconds using tempo events.
    static func ticksToSeconds(_ tick: Int, tempoEvents: [TempoPoint], tpq: Int) -> Double {
        guard tpq > 0 else { return 0 }
        var seconds: Double = 0
        var lastTick = 0
        var currentBPM: Double = 120.0

        let sorted = tempoEvents.sorted { $0.tick < $1.tick }
        for event in sorted where event.tick <= tick {
            let deltaTicks = event.tick - lastTick
            seconds += Double(deltaTicks) / Double(tpq) * (60.0 / currentBPM)
            lastTick = event.tick
            currentBPM = event.bpm
        }

        let remaining = tick - lastTick
        seconds += Double(remaining) / Double(tpq) * (60.0 / currentBPM)
        return seconds
    }

    static func generatePrompt(
        group: InstrumentGroup,
        mappings: [String: InstrumentMapping],
        notes: [PianoRollNote],
        density: ChunkDensity,
        tempoEvents: [TempoPoint],
        tickStart: Int,
        ticksPerQuarter: Int,
        styleTemplate: String = ""
    ) -> String {
        let instrumentNames = group.keys.compactMap { mappings[$0]?.displayName }

        // Get tempo at this position
        let sortedTempos = tempoEvents.sorted { $0.tick < $1.tick }
        let tempo = sortedTempos.last(where: { $0.tick <= tickStart })?.bpm ?? 120.0

        // Analyze velocity range for dynamics
        let velocities = notes.map { $0.velocity }
        let dynamicRange: ClosedRange<SunoPromptGenerator.Dynamic>? = {
            guard let minV = velocities.min(), let maxV = velocities.max() else { return nil }
            return SunoPromptGenerator.Dynamic.from(velocity: minV)...SunoPromptGenerator.Dynamic.from(velocity: maxV)
        }()

        // Check if any percussion instruments
        let hasPercussion = instrumentNames.contains(where: {
            $0.lowercased().contains("percussion") || $0.lowercased().contains("timpani") || $0.lowercased().contains("drum")
        })

        return SunoPromptGenerator.generate(
            instrumentNames: instrumentNames,
            styleTemplate: styleTemplate,
            tempo: tempo,
            keySignature: nil,
            timeSignature: nil,
            dynamicRange: dynamicRange,
            sectionLabel: nil,
            hasPercussion: hasPercussion
        )
    }
}

// Array chunking polyfill
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
