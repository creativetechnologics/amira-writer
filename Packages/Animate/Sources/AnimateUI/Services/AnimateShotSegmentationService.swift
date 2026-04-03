import Foundation

@available(macOS 26.0, *)
@MainActor
struct AnimateShotSegmentationService {
    let store: AnimateStore
    let previewPlan: LLMAnimationPlan?

    func sceneFrameCount(for scene: AnimationScene) -> Int {
        let trackMax = store.orderedTimelineTracks(for: scene)
            .flatMap(\.keyframes)
            .map(\.frame)
            .max() ?? 0

        let planMax = max(
            previewPlan?.cameraMoves.map(\.endFrame).max() ?? 0,
            previewPlan?.shotPresetApplications.map(\.frame).max() ?? 0
        )

        let authoredShotMax = scene.shots.map(\.endFrame).max() ?? 0

        return max(1, trackMax, planMax, authoredShotMax + 1)
    }

    func shotSegments(for scene: AnimationScene) -> [AnimateShotSegment] {
        let totalFrames = sceneFrameCount(for: scene)
        let authoredShots = normalizedAuthoredShots(for: scene)

        if !authoredShots.isEmpty {
            return authoredShots.enumerated().map { index, shot in
                makeSegment(
                    id: shot.id.uuidString,
                    title: resolvedTitle(for: shot, at: shot.startFrame, index: index, scene: scene),
                    detail: resolvedDetail(
                        shotMetadata: (shot.cameraShot, shot.shotIntent, focusCharacterName(for: shot, scene: scene), shot.notes),
                        scene: scene,
                        frame: shot.startFrame
                    ),
                    startFrame: shot.startFrame,
                    endFrame: max(shot.startFrame, shot.endFrame),
                    scene: scene,
                    totalFrames: totalFrames,
                    provenance: .authored
                )
            }
        }

        let inferred = inferredShots(for: scene)
        let provenance: AnimateShotSegment.Provenance = hasPreviewOverlay(for: scene) ? .preview : .inferred
        return inferred.enumerated().map { index, shot in
            makeSegment(
                id: shot.id.uuidString,
                title: resolvedTitle(for: shot, at: shot.startFrame, index: index, scene: scene),
                detail: resolvedDetail(
                    shotMetadata: (shot.cameraShot, shot.shotIntent, focusCharacterName(for: shot, scene: scene), shot.notes),
                    scene: scene,
                    frame: shot.startFrame
                ),
                startFrame: shot.startFrame,
                endFrame: max(shot.startFrame, shot.endFrame),
                scene: scene,
                totalFrames: totalFrames,
                provenance: provenance
            )
        }
    }

    func projectSceneSegments() -> [AnimateProjectSceneSegment] {
        store.scenes.map { scene in
            AnimateProjectSceneSegment(
                id: scene.id,
                name: scene.name,
                estimatedFrames: sceneFrameCount(for: scene),
                characterCount: scene.characterIDs.count,
                shotCount: shotSegments(for: scene).count,
                isSelected: store.selectedSceneID == scene.id
            )
        }
    }

    func inferredShots(for scene: AnimationScene) -> [AnimationSceneShot] {
        let totalFrames = sceneFrameCount(for: scene)
        var boundaries: Set<Int> = [0]

        for track in cameraTracks(for: scene) {
            boundaries.formUnion(track.keyframes.map(\.frame))
        }

        if hasPreviewOverlay(for: scene) {
            boundaries.formUnion(previewPlan?.shotPresetApplications.map(\.frame) ?? [])
            boundaries.formUnion(previewPlan?.cameraMoves.map(\.startFrame) ?? [])
        }

        let starts = boundaries.filter { $0 >= 0 }.sorted()

        return starts.enumerated().map { index, startFrame in
            let nextStart = index + 1 < starts.count ? starts[index + 1] : totalFrames
            let endFrame = max(startFrame, nextStart - 1)
            let beat = beatLabel(for: scene, at: startFrame)

            return AnimationSceneShot(
                name: beat?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? beat!
                    : "Shot \(index + 1)",
                startFrame: startFrame,
                endFrame: endFrame,
                cameraShot: cameraShot(for: scene, at: startFrame),
                shotIntent: shotIntent(for: scene, at: startFrame),
                focusCharacterID: focusCharacterID(for: scene, at: startFrame),
                focusCharacterSlug: focusCharacterID(for: scene, at: startFrame).flatMap { id in
                    store.characters.first(where: { $0.id == id })?.owpSlug
                },
                notes: "",
                source: hasPreviewOverlay(for: scene) ? .scriptSync : .inferred,
                lockedBoundaries: false
            )
        }
    }

    private func cameraTracks(for scene: AnimationScene) -> [TimelineTrack] {
        store.orderedTimelineTracks(for: scene).filter {
            switch $0.role {
            case .cameraShot, .cameraBeat, .cameraIntent, .cameraFocus, .cameraDefaultShot:
                true
            default:
                false
            }
        }
    }

    private func timelineTrack(
        named trackName: String,
        in scene: AnimationScene
    ) -> TimelineTrack? {
        scene.tracks[trackName]
            ?? store.orderedTimelineTracks(for: scene).first(where: { $0.name == trackName })
    }

    private func framingCue(
        trackName: String,
        in scene: AnimationScene,
        at frame: Int
    ) -> String? {
        guard let track = timelineTrack(named: trackName, in: scene),
              let value = AnimationEngine.evaluate(track: track, at: frame),
              case .expression(let name) = value
        else {
            return nil
        }
        return name
    }

    private func cameraShot(for scene: AnimationScene, at frame: Int) -> CameraShot? {
        CameraShot(rawValue: framingCue(trackName: "camera:shot", in: scene, at: frame) ?? "")
            ?? CameraShot(rawValue: framingCue(trackName: "camera:default-shot", in: scene, at: frame) ?? "")
            ?? scene.directionTemplate?.defaultCameraShot
    }

    private func shotIntent(for scene: AnimationScene, at frame: Int) -> ShotIntent? {
        ShotIntent(rawValue: framingCue(trackName: "camera:intent", in: scene, at: frame) ?? "")
    }

    private func beatLabel(for scene: AnimationScene, at frame: Int) -> String? {
        framingCue(trackName: "camera:beat", in: scene, at: frame)
    }

    private func focusCharacterID(for scene: AnimationScene, at frame: Int) -> UUID? {
        if let slug = framingCue(trackName: "camera:focus", in: scene, at: frame),
           let characterID = store.characters.first(where: { $0.owpSlug == slug })?.id {
            return characterID
        }

        return scene.directionTemplate?.focusCharacterID
    }

    private func sceneCharacters(for scene: AnimationScene) -> [AnimationCharacter] {
        scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })
        }
    }

    private func normalizedAuthoredShots(for scene: AnimationScene) -> [AnimationSceneShot] {
        scene.shots
            .map { shot in
                var shot = shot
                shot.startFrame = max(0, shot.startFrame)
                shot.endFrame = max(shot.startFrame, shot.endFrame)
                if let focusSlug = shot.focusCharacterSlug,
                   let characterID = store.characters.first(where: { $0.owpSlug == focusSlug })?.id {
                    shot.focusCharacterID = characterID
                } else if let focusID = shot.focusCharacterID {
                    shot.focusCharacterSlug = store.characters.first(where: { $0.id == focusID })?.owpSlug
                }
                return shot
            }
            .sorted {
                if $0.startFrame == $1.startFrame {
                    return $0.endFrame < $1.endFrame
                }
                return $0.startFrame < $1.startFrame
            }
    }

    private func resolvedTitle(
        for shot: AnimationSceneShot,
        at frame: Int,
        index: Int,
        scene: AnimationScene
    ) -> String {
        let trimmedName = shot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        if let beat = beatLabel(for: scene, at: frame),
           !beat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return beat
        }

        return "Shot \(index + 1)"
    }

    private func resolvedDetail(
        shotMetadata: (CameraShot?, ShotIntent?, String?, String),
        scene: AnimationScene,
        frame: Int
    ) -> String {
        let (authoredShot, authoredIntent, focusName, notes) = shotMetadata
        let detailParts = [
            authoredShot?.displayName ?? cameraShot(for: scene, at: frame)?.displayName,
            authoredIntent?.displayName ?? shotIntent(for: scene, at: frame)?.displayName,
            focusName.map { "Focus \($0)" },
            notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        ].compactMap { $0 }

        return detailParts.isEmpty
            ? "Camera and character directions can be configured for this shot."
            : detailParts.joined(separator: " · ")
    }

    private func focusCharacterName(for shot: AnimationSceneShot, scene: AnimationScene) -> String? {
        if let focusID = shot.focusCharacterID {
            return sceneCharacters(for: scene).first(where: { $0.id == focusID })?.name
        }
        if let focusSlug = shot.focusCharacterSlug {
            return sceneCharacters(for: scene).first(where: { $0.owpSlug == focusSlug })?.name
        }
        return nil
    }

    private func hasPreviewOverlay(for scene: AnimationScene) -> Bool {
        store.selectedSceneID == scene.id && previewPlan != nil
    }

    private func makeSegment(
        id: String,
        title: String,
        detail: String,
        startFrame: Int,
        endFrame: Int,
        scene: AnimationScene,
        totalFrames: Int,
        provenance: AnimateShotSegment.Provenance
    ) -> AnimateShotSegment {
        let clampedEndFrame = min(max(startFrame, endFrame), max(0, totalFrames - 1))
        return AnimateShotSegment(
            id: id,
            title: title,
            detail: detail,
            startFrame: startFrame,
            endFrame: clampedEndFrame,
            containsCurrentFrame: store.selectedSceneID == scene.id && store.currentFrame >= startFrame && store.currentFrame <= clampedEndFrame,
            provenance: provenance
        )
    }
}
