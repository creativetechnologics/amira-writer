import Foundation

@available(macOS 26.0, *)
@MainActor
struct AnimateAssetRequirementsService {
    let store: AnimateStore

    func buildDatabase() async -> AnimateAssetRequirementDatabase {
        let projectURL = store.animateURL?.deletingLastPathComponent()
        let shotService = AnimateShotSegmentationService(store: store, previewPlan: nil)

        var sceneSummaries: [AnimateAssetRequirementDatabase.SceneSummary] = []
        var accumulators: [String: EntryAccumulator] = [:]

        for scene in store.scenes {
            let songData: OWSSongData?
            if scene.id == store.selectedSceneID {
                songData = store.currentSongData
            } else if let projectURL {
                songData = await AnimateProjectBridge.hydrateSongData(projectURL: projectURL, relativePath: scene.owpSongPath)
            } else {
                songData = nil
            }

            let lyrics = songData?.extractLyrics()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parseResult = lyrics.isEmpty ? nil : SceneDirectionParser.parse(lyrics)
            let sceneShots = authoredOrInferredShots(for: scene, shotService: shotService)
            let bpm = songData?.tempoEvents.sorted(by: { $0.tick < $1.tick }).first?.bpm ?? 120
            let placeName = resolvedPlaceName(for: scene, parseResult: parseResult)

            let placeOccurrence = AnimateAssetRequirementDatabase.Occurrence(
                sceneID: scene.id.uuidString,
                sceneName: scene.name,
                shotTitles: sceneShots.map(\.name).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                sourceLineNumbers: []
            )

            merge(
                key: placeCatalogKey(for: scene, resolvedPlaceName: placeName),
                into: &accumulators,
                kind: "place",
                name: placeName,
                status: resolvedPlaceStatus(for: scene),
                summary: scene.backgroundID == nil
                    ? "Scene place/background still needs a bound approved plate."
                    : (backgroundPlate(for: scene)?.resolvedApprovedImagePath == nil
                        ? "Place exists but still needs an approved plate."
                        : "Approved place plate is ready for scene playback."),
                approvedImagePath: backgroundPlate(for: scene)?.resolvedApprovedImagePath,
                variantCount: backgroundPlate(for: scene)?.imagePaths.count ?? 0,
                hasResolvedArt: backgroundPlate(for: scene)?.resolvedApprovedImagePath != nil,
                requiredStates: [],
                requiredAttachments: [],
                requiredCameraShots: sceneShots.compactMap { $0.cameraShot?.displayName },
                requiredShotIntents: sceneShots.compactMap { $0.shotIntent?.displayName },
                placementHints: [],
                occurrence: placeOccurrence
            )

            let directionGroups = groupedObjectDirections(parseResult?.directions ?? [])
            let setupGroups = Dictionary(grouping: scene.objectSetups) { normalizedKey($0.objectName) }
            let allObjectKeys = Set(directionGroups.keys).union(setupGroups.keys)

            var sceneUnresolvedCount = scene.backgroundID == nil || backgroundPlate(for: scene)?.resolvedApprovedImagePath == nil ? 1 : 0

            for objectKey in allObjectKeys.sorted() {
                let setups = setupGroups[objectKey] ?? []
                let directions = directionGroups[objectKey] ?? []
                let preferredName = setups.first?.objectName
                    ?? directions.first?.primaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? objectKey
                let resolvedArt = setups.contains { resolvedObjectArtPath(for: $0, state: $0.initialState) != nil }
                let approvedImagePath = setups.compactMap(\.resolvedApprovedImagePath).first
                let variantCount = setups.map { max($0.imagePaths.count, $0.stateImagePaths.count) }.max() ?? 0
                let status: AnimateAssetRequirementDatabase.Entry.Status = {
                    if setups.isEmpty { return .needsDefinition }
                    return resolvedArt ? .ready : .needsArt
                }()

                if status != .ready {
                    sceneUnresolvedCount += 1
                }

                let occurrences = buildObjectOccurrences(
                    scene: scene,
                    objectName: preferredName,
                    shots: sceneShots,
                    directions: directions,
                    bpm: bpm
                )
                let shotMatches = occurrences.flatMap(\.shotTitles)
                let matchingShots = sceneShots.filter { shotMatches.contains($0.name) }
                let attachmentTargets = Set(
                    setups.compactMap(\.attachmentTarget).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    + directions.compactMap { attachmentTarget(for: $0) }
                )
                let states = Set(
                    setups.compactMap(\.initialState).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    + directions.compactMap { directionState(for: $0) }
                )

                let placementHints = buildPlacementHints(
                    setups: setups,
                    directions: directions,
                    shots: sceneShots,
                    bpm: bpm
                )

                merge(
                    key: "object:\(objectKey)",
                    into: &accumulators,
                    kind: "object",
                    name: preferredName,
                    status: status,
                    summary: status == .needsDefinition
                        ? "Mentioned in libretto/scene directions but not yet cataloged as a scene object."
                        : (resolvedArt
                            ? "Scene object has catalog data and at least one resolved art source."
                            : "Scene object exists but still needs approved art or state variants."),
                    approvedImagePath: approvedImagePath,
                    variantCount: variantCount,
                    hasResolvedArt: resolvedArt,
                    requiredStates: Array(states).sorted(),
                    requiredAttachments: Array(attachmentTargets).sorted(),
                    requiredCameraShots: matchingShots.compactMap { $0.cameraShot?.displayName },
                    requiredShotIntents: matchingShots.compactMap { $0.shotIntent?.displayName },
                    placementHints: placementHints,
                    occurrence: mergedOccurrence(for: scene, objectName: preferredName, occurrences: occurrences)
                )
            }

            sceneSummaries.append(
                AnimateAssetRequirementDatabase.SceneSummary(
                    sceneID: scene.id.uuidString,
                    sceneName: scene.name,
                    placeName: placeName,
                    shotCount: sceneShots.count,
                    objectMentionCount: allObjectKeys.count,
                    unresolvedCount: sceneUnresolvedCount
                )
            )
        }

        let entries = accumulators.values
            .map(\.entry)
            .sorted {
                if $0.kind == $1.kind {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.kind.localizedCaseInsensitiveCompare($1.kind) == .orderedAscending
            }

        return AnimateAssetRequirementDatabase(
            generatedAt: Date(),
            summary: .init(
                sceneCount: sceneSummaries.count,
                entryCount: entries.count,
                readyCount: entries.filter { $0.status == .ready }.count,
                needsArtCount: entries.filter { $0.status == .needsArt }.count,
                needsDefinitionCount: entries.filter { $0.status == .needsDefinition }.count
            ),
            scenes: sceneSummaries.sorted { $0.sceneName.localizedCaseInsensitiveCompare($1.sceneName) == .orderedAscending },
            entries: entries
        )
    }

    func databaseJSON(_ database: AnimateAssetRequirementDatabase) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(database),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func authoredOrInferredShots(
        for scene: AnimationScene,
        shotService: AnimateShotSegmentationService
    ) -> [AnimationSceneShot] {
        let shots = scene.shots.isEmpty ? shotService.inferredShots(for: scene) : scene.shots
        return shots.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }
    }

    private func resolvedPlaceName(
        for scene: AnimationScene,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> String {
        if let background = nonEmpty(backgroundPlate(for: scene)?.name) {
            return background
        }
        if let sceneDirective = parseResult?.directions.first(where: { $0.tag == .scene }),
           let inferred = nonEmpty((sceneDirective.parameters["bg"] ?? sceneDirective.parameters["background"])?.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return inferred
        }
        return "Unassigned place"
    }

    private func resolvedPlaceStatus(
        for scene: AnimationScene
    ) -> AnimateAssetRequirementDatabase.Entry.Status {
        if scene.backgroundID == nil {
            return .needsDefinition
        }
        return backgroundPlate(for: scene)?.resolvedApprovedImagePath == nil ? .needsArt : .ready
    }

    private func groupedObjectDirections(_ directions: [SceneDirection]) -> [String: [SceneDirection]] {
        Dictionary(grouping: directions.filter { isObjectDirectionTag($0.tag) }) {
            normalizedKey($0.primaryValue)
        }
    }

    private func isObjectDirectionTag(_ tag: DirectionTag) -> Bool {
        switch tag {
        case .object, .objectMove, .objectState, .objectVisibility:
            return true
        default:
            return false
        }
    }

    private func directionState(for direction: SceneDirection) -> String? {
        nonEmpty(direction.parameters["state"]?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func attachmentTarget(for direction: SceneDirection) -> String? {
        nonEmpty((direction.parameters["attach_to"] ?? direction.parameters["holder"])?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func buildObjectOccurrences(
        scene: AnimationScene,
        objectName: String,
        shots: [AnimationSceneShot],
        directions: [SceneDirection],
        bpm: Double
    ) -> [AnimateAssetRequirementDatabase.Occurrence] {
        let timedShots = shotsForDirections(directions, shots: shots, bpm: bpm)
        guard !timedShots.isEmpty || !directions.isEmpty else {
            return []
        }

        return [
            AnimateAssetRequirementDatabase.Occurrence(
                sceneID: scene.id.uuidString,
                sceneName: scene.name,
                shotTitles: timedShots.map(\.name),
                sourceLineNumbers: Array(Set(directions.map(\.sourceLineNumber))).sorted()
            )
        ]
    }

    private func mergedOccurrence(
        for scene: AnimationScene,
        objectName: String,
        occurrences: [AnimateAssetRequirementDatabase.Occurrence]
    ) -> AnimateAssetRequirementDatabase.Occurrence {
        if let first = occurrences.first {
            return first
        }
        return AnimateAssetRequirementDatabase.Occurrence(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            shotTitles: [],
            sourceLineNumbers: []
        )
    }

    private func shotsForDirections(
        _ directions: [SceneDirection],
        shots: [AnimationSceneShot],
        bpm: Double
    ) -> [AnimationSceneShot] {
        guard !directions.isEmpty else { return shots }

        var matchedIDs = Set<UUID>()
        for direction in directions {
            guard let timing = timing(for: direction),
                  let range = timing.toFrameRange(fps: store.fps, bpm: bpm) else {
                continue
            }
            let start = max(0, range.start)
            let end = max(start, range.end)
            for shot in shots where overlaps(shot.startFrame, shot.endFrame, start, end) {
                matchedIDs.insert(shot.id)
            }
        }

        if matchedIDs.isEmpty {
            return shots
        }
        return shots.filter { matchedIDs.contains($0.id) }
    }

    private func buildPlacementHints(
        setups: [ObjectSetup],
        directions: [SceneDirection],
        shots: [AnimationSceneShot],
        bpm: Double
    ) -> [AnimateAssetRequirementDatabase.PlacementHint] {
        var hints: [AnimateAssetRequirementDatabase.PlacementHint] = setups.map { setup in
            .init(
                shotTitle: shots.first(where: { overlaps($0.startFrame, $0.endFrame, setup.enterFrame, setup.exitFrame ?? Int.max) })?.name,
                x: setup.initialX,
                y: setup.initialY,
                zOrder: setup.zOrder,
                attachmentTarget: setup.attachmentTarget,
                detail: "Scene object setup"
            )
        }

        for direction in directions {
            let overlapShots = shotsForDirections([direction], shots: shots, bpm: bpm)
            let position = nonEmpty(direction.parameters["position"]?.trimmingCharacters(in: .whitespacesAndNewlines))
            let detail = [
                position.map { "position=\($0)" },
                direction.parameters["state"].map { "state=\($0)" },
                attachmentTarget(for: direction).map { "attach=\($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: " · ")

            hints.append(
                .init(
                    shotTitle: overlapShots.first?.name,
                    x: nil,
                    y: direction.parameters["y"].flatMap(Double.init),
                    zOrder: direction.parameters["z"].flatMap(Int.init),
                    attachmentTarget: attachmentTarget(for: direction),
                    detail: detail.isEmpty ? "Script-directed object beat" : detail
                )
            )
        }

        return dedupedPlacementHints(hints)
    }

    private func dedupedPlacementHints(
        _ hints: [AnimateAssetRequirementDatabase.PlacementHint]
    ) -> [AnimateAssetRequirementDatabase.PlacementHint] {
        var seen = Set<String>()
        var result: [AnimateAssetRequirementDatabase.PlacementHint] = []
        for hint in hints {
            let x = hint.x.map { String($0) } ?? ""
            let y = hint.y.map { String($0) } ?? ""
            let z = hint.zOrder.map { String($0) } ?? ""
            let key = "\(hint.shotTitle ?? "")|\(x)|\(y)|\(z)|\(hint.attachmentTarget ?? "")|\(hint.detail)"
            if seen.insert(key).inserted {
                result.append(hint)
            }
        }
        return result
    }

    private func overlaps(_ lhsStart: Int, _ lhsEnd: Int, _ rhsStart: Int, _ rhsEnd: Int) -> Bool {
        max(lhsStart, rhsStart) <= min(lhsEnd, rhsEnd)
    }

    private func merge(
        key: String,
        into accumulators: inout [String: EntryAccumulator],
        kind: String,
        name: String,
        status: AnimateAssetRequirementDatabase.Entry.Status,
        summary: String,
        approvedImagePath: String?,
        variantCount: Int,
        hasResolvedArt: Bool,
        requiredStates: [String],
        requiredAttachments: [String],
        requiredCameraShots: [String],
        requiredShotIntents: [String],
        placementHints: [AnimateAssetRequirementDatabase.PlacementHint],
        occurrence: AnimateAssetRequirementDatabase.Occurrence
    ) {
        var accumulator = accumulators[key] ?? EntryAccumulator(
            entry: .init(
                key: key,
                kind: kind,
                name: name,
                status: status,
                summary: summary,
                approvedImagePath: approvedImagePath,
                variantCount: variantCount,
                hasResolvedArt: hasResolvedArt,
                requiredStates: [],
                requiredAttachments: [],
                requiredCameraShots: [],
                requiredShotIntents: [],
                placementHints: [],
                occurrences: []
            )
        )

        accumulator.entry.status = worstStatus(accumulator.entry.status, status)
        if accumulator.entry.approvedImagePath == nil {
            accumulator.entry.approvedImagePath = approvedImagePath
        }
        accumulator.entry.variantCount = max(accumulator.entry.variantCount, variantCount)
        accumulator.entry.hasResolvedArt = accumulator.entry.hasResolvedArt || hasResolvedArt
        accumulator.requiredStates.formUnion(requiredStates.filter { !$0.isEmpty })
        accumulator.requiredAttachments.formUnion(requiredAttachments.filter { !$0.isEmpty })
        accumulator.requiredCameraShots.formUnion(requiredCameraShots.filter { !$0.isEmpty })
        accumulator.requiredShotIntents.formUnion(requiredShotIntents.filter { !$0.isEmpty })
        accumulator.entry.placementHints.append(contentsOf: placementHints)
        accumulator.entry.occurrences.append(occurrence)

        let sceneCount = Set(accumulator.entry.occurrences.map(\.sceneID)).count
        let shotCount = Set(accumulator.entry.occurrences.flatMap(\.shotTitles)).count
        let statusLabel: String = {
            switch accumulator.entry.status {
            case .ready: return "ready"
            case .needsArt: return "needs art"
            case .needsDefinition: return "needs definition"
            }
        }()
        accumulator.entry.summary = "\(statusLabel.capitalized) · \(sceneCount) scene(s) · \(shotCount) shot context(s)"
        accumulator.entry.requiredStates = Array(accumulator.requiredStates).sorted()
        accumulator.entry.requiredAttachments = Array(accumulator.requiredAttachments).sorted()
        accumulator.entry.requiredCameraShots = Array(accumulator.requiredCameraShots).sorted()
        accumulator.entry.requiredShotIntents = Array(accumulator.requiredShotIntents).sorted()
        accumulator.entry.placementHints = dedupedPlacementHints(accumulator.entry.placementHints)
        accumulator.entry.occurrences = dedupedOccurrences(accumulator.entry.occurrences)

        accumulators[key] = accumulator
    }

    private func dedupedOccurrences(
        _ occurrences: [AnimateAssetRequirementDatabase.Occurrence]
    ) -> [AnimateAssetRequirementDatabase.Occurrence] {
        var seen = Set<String>()
        var result: [AnimateAssetRequirementDatabase.Occurrence] = []
        for occurrence in occurrences {
            let lines = occurrence.sourceLineNumbers.map(String.init).joined(separator: ",")
            let shots = occurrence.shotTitles.joined(separator: ",")
            let key = "\(occurrence.sceneID)|\(occurrence.sceneName)|\(shots)|\(lines)"
            if seen.insert(key).inserted {
                result.append(occurrence)
            }
        }
        return result
    }

    private func worstStatus(
        _ lhs: AnimateAssetRequirementDatabase.Entry.Status,
        _ rhs: AnimateAssetRequirementDatabase.Entry.Status
    ) -> AnimateAssetRequirementDatabase.Entry.Status {
        let rank: [AnimateAssetRequirementDatabase.Entry.Status: Int] = [
            .ready: 0,
            .needsArt: 1,
            .needsDefinition: 2
        ]
        return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
    }

    private func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func placeCatalogKey(
        for scene: AnimationScene,
        resolvedPlaceName: String
    ) -> String {
        if let backgroundID = scene.backgroundID {
            return "place:\(backgroundID.uuidString)"
        }
        let normalized = normalizedKey(resolvedPlaceName)
        if !normalized.isEmpty, normalized != "unassigned place" {
            return "place:\(normalized)"
        }
        return "place:scene:\(scene.id.uuidString)"
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

    private func backgroundPlate(for scene: AnimationScene) -> BackgroundPlate? {
        guard let backgroundID = scene.backgroundID else { return nil }
        return store.backgrounds.first(where: { $0.id == backgroundID })
    }

    private func resolvedObjectArtPath(
        for object: ObjectSetup,
        state: String
    ) -> String? {
        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let explicit = object.stateImagePaths.first(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedState
        })?.value,
           store.resolvedCharacterAssetURL(for: explicit) != nil {
            return explicit
        }

        if !normalizedState.isEmpty, normalizedState != "default",
           let variant = object.imagePaths.first(where: {
               URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains(normalizedState) &&
               store.resolvedCharacterAssetURL(for: $0) != nil
           }) {
            return variant
        }

        if let approved = object.resolvedApprovedImagePath,
           store.resolvedCharacterAssetURL(for: approved) != nil {
            return approved
        }

        return nil
    }
}

@available(macOS 26.0, *)
private struct EntryAccumulator {
    var entry: AnimateAssetRequirementDatabase.Entry
    var requiredStates: Set<String> = []
    var requiredAttachments: Set<String> = []
    var requiredCameraShots: Set<String> = []
    var requiredShotIntents: Set<String> = []
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
