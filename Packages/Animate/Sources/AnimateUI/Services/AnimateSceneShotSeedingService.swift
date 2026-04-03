import Foundation

@available(macOS 26.0, *)
@MainActor
struct AnimateSceneShotSeedingService {
    let store: AnimateStore

    func seedReport(
        for scene: AnimationScene,
        songData: OWSSongData?,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> AnimateShotSeedReport {
        let lyricLines = lyricLineAnchors(from: songData, fps: store.fps)
        let shots = seededShots(for: scene, songData: songData, parseResult: parseResult)
        let warnings = buildWarnings(
            shots: shots,
            lyricLines: lyricLines,
            parseResult: parseResult
        )

        return AnimateShotSeedReport(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            scriptDirectionCount: parseResult?.directions.count ?? 0,
            cameraDirectionCount: parseResult?.directions.filter { $0.tag == .camera }.count ?? 0,
            objectDirectionCount: parseResult?.directions.filter { isObjectDirectionTag($0.tag) }.count ?? 0,
            lyricLineCount: lyricLines.count,
            seededShots: shots.map {
                AnimateShotSeedReport.SeededShot(
                    id: $0.id.uuidString,
                    title: $0.name,
                    startFrame: $0.startFrame,
                    endFrame: $0.endFrame,
                    source: $0.source.displayName,
                    detail: shotDetail($0)
                )
            },
            warnings: warnings
        )
    }

    func seedReportJSON(_ report: AnimateShotSeedReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    func seededShots(
        for scene: AnimationScene,
        songData: OWSSongData?,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> [AnimationSceneShot] {
        let lyricLines = lyricLineAnchors(from: songData, fps: store.fps)
        let cameraSeeded = seededCameraShots(for: scene, songData: songData, parseResult: parseResult, lyricLines: lyricLines)
        if !cameraSeeded.isEmpty {
            return cameraSeeded
        }

        if !lyricLines.isEmpty {
            let runID = UUID()
            return lyricLines.enumerated().map { index, line in
                AnimationSceneShot(
                    name: "Lyric \(index + 1)",
                    startFrame: line.startFrame,
                    endFrame: line.endFrame,
                    notes: line.text,
                    source: .scriptSync,
                    lockedBoundaries: false,
                    sourceDirectionTags: [],
                    sourceLineNumber: line.lineNumber,
                    sourceLyricExcerpt: line.text,
                    scriptSyncRunID: runID
                )
            }
        }

        return []
    }

    private func seededCameraShots(
        for scene: AnimationScene,
        songData: OWSSongData?,
        parseResult: SceneDirectionParser.ParseResult?,
        lyricLines: [LyricLineAnchor]
    ) -> [AnimationSceneShot] {
        guard let parseResult else { return [] }
        let bpm = songData?.tempoEvents.sorted(by: { $0.tick < $1.tick }).first?.bpm ?? 120
        let sceneCharacters = scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })
        }
        let objectDirections = parseResult.directions.compactMap { direction -> (direction: SceneDirection, range: (start: Int, end: Int))? in
            guard isObjectDirectionTag(direction.tag),
                  let timing = timing(for: direction),
                  let range = timing.toFrameRange(fps: store.fps, bpm: bpm) else {
                return nil
            }
            return (direction, (range.start, range.end))
        }

        var currentFrame = 0
        let runID = UUID()
        var result: [AnimationSceneShot] = []

        for direction in parseResult.directions {
            switch direction.tag {
            case .camera:
                let frameRange = resolvedFrameRange(
                    for: direction,
                    currentFrame: currentFrame,
                    fps: store.fps,
                    bpm: bpm
                )

                let shotLine = lyricLines.first(where: { overlaps($0.startFrame, $0.endFrame, frameRange.start, frameRange.end) })
                let focusCharacter = resolvedFocusCharacter(direction.parameters["focus"], sceneCharacters: sceneCharacters)
                let cameraShot = resolvedCameraShot(for: direction)
                let shotIntent = resolvedShotIntent(for: direction)
                let overlappingObjectDirections = objectDirections
                    .filter { overlaps($0.range.start, $0.range.end, frameRange.start, frameRange.end) }
                    .map(\.direction)
                let title = direction.parameters["label"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? shotLine?.text.nilIfEmpty
                    ?? "Shot \(result.count + 1)"

                let notes = [
                    "Seeded from script line \(direction.sourceLineNumber)",
                    shotLine?.text,
                    objectNoteSummary(for: overlappingObjectDirections)
                ]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: " · ")

                result.append(
                    AnimationSceneShot(
                        name: title,
                        startFrame: frameRange.start,
                        endFrame: max(frameRange.start, frameRange.end),
                        cameraShot: cameraShot,
                        shotIntent: shotIntent,
                        focusCharacterID: focusCharacter?.id,
                        focusCharacterSlug: focusCharacter?.owpSlug,
                        notes: notes,
                        source: .scriptSync,
                        lockedBoundaries: false,
                        sourceDirectionTags: Array(Set(([direction.tag.rawValue] + overlappingObjectDirections.map(\.tag.rawValue)))).sorted(),
                        sourceLineNumber: direction.sourceLineNumber,
                        sourceLyricExcerpt: shotLine?.text,
                        scriptSyncRunID: runID
                    )
                )

                currentFrame = max(currentFrame, frameRange.end)

            case .pause:
                currentFrame = max(currentFrame, advancedFrame(for: direction, currentFrame: currentFrame, fps: store.fps, bpm: bpm))
            default:
                continue
            }
        }

        return result
    }

    private func buildWarnings(
        shots: [AnimationSceneShot],
        lyricLines: [LyricLineAnchor],
        parseResult: SceneDirectionParser.ParseResult?
    ) -> [String] {
        var warnings: [String] = []

        if let parseResult, !parseResult.errors.isEmpty {
            warnings.append("Parse errors: \(parseResult.errors.count)")
        }
        if shots.isEmpty {
            warnings.append("No script-seeded shots could be derived from the current scene.")
        }
        if lyricLines.isEmpty {
            warnings.append("No lyric line timing anchors were available.")
        }

        return warnings
    }

    private func shotDetail(_ shot: AnimationSceneShot) -> String {
        [
            shot.cameraShot?.displayName,
            shot.shotIntent?.displayName,
            shot.sourceLyricExcerpt,
            shot.notes.nilIfEmpty
        ]
        .compactMap { $0?.nilIfEmpty }
        .joined(separator: " · ")
    }

    private func objectNoteSummary(for directions: [SceneDirection]) -> String? {
        let summaries = directions.compactMap { direction -> String? in
            let name = direction.primaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            switch direction.tag {
            case .object:
                return "Object \(name)"
            case .objectMove:
                return "Object move \(name)"
            case .objectState:
                return "Object state \(name)"
            case .objectVisibility:
                return "Object visibility \(name)"
            default:
                return nil
            }
        }
        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: ", ")
    }

    private func resolvedFrameRange(
        for direction: SceneDirection,
        currentFrame: Int,
        fps: Int,
        bpm: Double
    ) -> (start: Int, end: Int) {
        if let timing = timing(for: direction),
           let range = timing.toFrameRange(fps: fps, bpm: bpm) {
            return (max(0, range.start), max(range.start, range.end))
        }

        return (currentFrame, currentFrame + fps * 4)
    }

    private func advancedFrame(
        for direction: SceneDirection,
        currentFrame: Int,
        fps: Int,
        bpm: Double
    ) -> Int {
        if let timing = timing(for: direction),
           let range = timing.toFrameRange(fps: fps, bpm: bpm) {
            return currentFrame + max(1, range.end - range.start)
        }

        return currentFrame
    }

    private func timing(for direction: SceneDirection) -> DirectionTiming? {
        if let bars = direction.parameters["bars"] ?? direction.parameters["bar"] {
            return DirectionTiming.parse("bars:\(bars)")
        }
        if let beats = direction.parameters["beats"] ?? direction.parameters["beat"] {
            return DirectionTiming.parse("beats:\(beats)")
        }
        if let frames = direction.parameters["frames"] ?? direction.parameters["frame"] {
            return DirectionTiming.parse("frames:\(frames)")
        }
        return nil
    }

    private func isObjectDirectionTag(_ tag: DirectionTag) -> Bool {
        switch tag {
        case .object, .objectMove, .objectState, .objectVisibility:
            return true
        default:
            return false
        }
    }

    private func resolvedCameraShot(for direction: SceneDirection) -> CameraShot? {
        direction.parameters["to"].flatMap(CameraShot.init(rawValue:))
            ?? direction.parameters["shot"].flatMap(CameraShot.init(rawValue:))
            ?? direction.parameters["from"].flatMap(CameraShot.init(rawValue:))
            ?? CameraShot(rawValue: direction.primaryValue.lowercased())
    }

    private func resolvedShotIntent(for direction: SceneDirection) -> ShotIntent? {
        direction.parameters["intent"].flatMap { ShotIntent(rawValue: $0.lowercased()) }
            ?? ShotIntent(rawValue: direction.primaryValue.lowercased())
    }

    private func resolvedFocusCharacter(
        _ raw: String?,
        sceneCharacters: [AnimationCharacter]
    ) -> AnimationCharacter? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }

        return sceneCharacters.first {
            $0.owpSlug.lowercased() == raw || $0.name.lowercased() == raw
        }
    }

    private func lyricLineAnchors(from songData: OWSSongData?, fps: Int) -> [LyricLineAnchor] {
        guard let songData else { return [] }

        if let alignment = songData.lyricAlignments.first, !alignment.entries.isEmpty {
            let notesByID: [UUID: OWPNote] = Dictionary(uniqueKeysWithValues: songData.notes.map { ($0.id, $0) })
            let sorted = alignment.entries.sorted { a, b in
                let tickA = notesByID[a.noteID]?.startTick ?? 0
                let tickB = notesByID[b.noteID]?.startTick ?? 0
                if tickA != tickB { return tickA < tickB }
                return a.syllableIndex < b.syllableIndex
            }

            var wordGroups: [(wordIndex: Int, syllables: [(entry: OWPLyricAlignmentEntry, note: OWPNote)])] = []
            var currentWordIndex = -1

            for entry in sorted {
                guard let note = notesByID[entry.noteID] else { continue }
                if entry.wordIndex != currentWordIndex {
                    wordGroups.append((wordIndex: entry.wordIndex, syllables: []))
                    currentWordIndex = entry.wordIndex
                }
                wordGroups[wordGroups.count - 1].syllables.append((entry, note))
            }

            var lines: [LyricLineAnchor] = []
            var currentLineWords: [String] = []
            var currentStartTick: Int?
            var currentEndTick = 0
            let lineGapThreshold = songData.ticksPerQuarter * 2

            for group in wordGroups {
                guard let first = group.syllables.first,
                      let last = group.syllables.last else { continue }

                let word = group.syllables.compactMap { $0.note.lyricSyllable }.joined()
                let startTick = first.note.startTick
                let endTick = last.note.startTick + last.note.duration

                if let currentEnd = currentStartTick != nil ? currentEndTick : nil,
                   startTick - currentEnd > lineGapThreshold,
                   !currentLineWords.isEmpty,
                   let startTickForLine = currentStartTick {
                    lines.append(
                        LyricLineAnchor(
                            lineNumber: lines.count + 1,
                            text: currentLineWords.joined(separator: " "),
                            startFrame: songData.tickToFrame(startTickForLine, fps: fps),
                            endFrame: songData.tickToFrame(currentEndTick, fps: fps)
                        )
                    )
                    currentLineWords = []
                    currentStartTick = nil
                    currentEndTick = 0
                }

                if currentStartTick == nil {
                    currentStartTick = startTick
                }
                if !word.isEmpty {
                    currentLineWords.append(word)
                }
                currentEndTick = max(currentEndTick, endTick)
            }

            if let startTickForLine = currentStartTick, !currentLineWords.isEmpty {
                lines.append(
                    LyricLineAnchor(
                        lineNumber: lines.count + 1,
                        text: currentLineWords.joined(separator: " "),
                        startFrame: songData.tickToFrame(startTickForLine, fps: fps),
                        endFrame: songData.tickToFrame(currentEndTick, fps: fps)
                    )
                )
            }

            return lines
        }

        let lines = songData.extractLyrics()
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        let totalFrames = max(1, songData.tickToFrame(songData.lengthTicks, fps: fps))
        let chunk = max(1, totalFrames / lines.count)

        return lines.enumerated().map { index, line in
            let startFrame = index * chunk
            let endFrame = index == lines.count - 1 ? totalFrames : min(totalFrames, startFrame + chunk - 1)
            return LyricLineAnchor(
                lineNumber: index + 1,
                text: line,
                startFrame: startFrame,
                endFrame: endFrame
            )
        }
    }

    private func overlaps(_ lhsStart: Int, _ lhsEnd: Int, _ rhsStart: Int, _ rhsEnd: Int) -> Bool {
        max(lhsStart, rhsStart) <= min(lhsEnd, rhsEnd)
    }
}

@available(macOS 26.0, *)
private struct LyricLineAnchor: Sendable {
    var lineNumber: Int
    var text: String
    var startFrame: Int
    var endFrame: Int
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
