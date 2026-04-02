import Foundation
import simd

@available(macOS 26.0, *)
@MainActor
struct Animate3DSceneAdapter {
    func makeScenario(
        store: AnimateStore,
        mode: Animate3DScenarioMode
    ) -> Animate3DPreviewScenario {
        let selectedScene = store.selectedScene
        let lyrics = store.currentSongData?.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parseResult = lyrics.isEmpty ? nil : SceneDirectionParser.parse(lyrics)

        switch mode {
        case .auto:
            if let scene = selectedScene, hasLiveSceneSignals(scene: scene) {
                return selectedTimelineScenario(store: store, scene: scene, lyrics: lyrics, parseResult: parseResult)
            }
            if let scene = selectedScene,
               let parseResult,
               !parseResult.directions.isEmpty {
                return parsedDirectionsScenario(store: store, scene: scene, lyrics: lyrics, parseResult: parseResult)
            }
            return fixtureScenario(store: store)
        case .selectedScene:
            if let scene = selectedScene, hasLiveSceneSignals(scene: scene) {
                return selectedTimelineScenario(store: store, scene: scene, lyrics: lyrics, parseResult: parseResult)
            }
            if let scene = selectedScene,
               let parseResult,
               !parseResult.directions.isEmpty {
                return parsedDirectionsScenario(store: store, scene: scene, lyrics: lyrics, parseResult: parseResult)
            }
            var fallback = fixtureScenario(store: store)
            let checks = [
                Animate3DValidationCheck(
                    title: "Selected scene available",
                    passed: false,
                    severity: .error,
                    detail: selectedScene == nil
                        ? "No scene is selected in the 3D Animate sidebar."
                        : "The selected scene has no usable timeline tracks, shots, or parseable libretto directions yet."
                )
            ]
            fallback.validation = Animate3DValidationReport(
                ready: false,
                summary: "Scene mode requested, but the current scene could not yet drive a 3D translation test.",
                checks: checks,
                warnings: ["Fallback fixture loaded so the 3D pane stays usable."]
            )
            fallback.sourceSummary = "Requested selected-scene mode, but the current scene could not yet be translated; fallback fixture loaded."
            return fallback
        case .fixture:
            return fixtureScenario(store: store)
        }
    }

    func frameSnapshot(
        for scenario: Animate3DPreviewScenario,
        store: AnimateStore,
        rawFrame: Int,
        playbackStyle: Animate3DPlaybackStyle
    ) -> Animate3DFrameSnapshot {
        let displayFrame = playbackStyle.quantizedFrame(rawFrame, baseFPS: scenario.baseFPS)

        if let compiled = scenario.compiledScene {
            return compiledFrameSnapshot(
                scenario: scenario,
                compiled: compiled,
                rawFrame: rawFrame,
                displayFrame: displayFrame
            )
        }

        return selectedSceneFrameSnapshot(
            scenario: scenario,
            store: store,
            rawFrame: rawFrame,
            displayFrame: displayFrame
        )
    }

    func motionTrails(
        for scenario: Animate3DPreviewScenario,
        store: AnimateStore,
        playbackStyle: Animate3DPlaybackStyle
    ) async -> [Animate3DMotionTrail] {
        guard scenario.totalFrames > 1 else { return [] }

        // Base sample step from playback style, then coarsen for large frame counts
        // to keep total iterations reasonable (cap around ~250 samples max).
        var sampleStep = max(
            1,
            Int(round(Double(max(scenario.baseFPS, 1)) / Double(max(min(playbackStyle.targetVisualFPS, 12), 1))))
        )
        let maxSamples = 250
        if scenario.totalFrames / sampleStep > maxSamples {
            sampleStep = max(sampleStep, scenario.totalFrames / maxSamples)
        }

        var characterPoints: [String: [SIMD3<Double>]] = [:]
        var characterMeta: [String: (label: String, colorIndex: Int)] = [:]
        var objectPoints: [String: [SIMD3<Double>]] = [:]
        var objectMeta: [String: (label: String, colorIndex: Int)] = [:]

        var frames = Array(stride(from: 0, to: scenario.totalFrames, by: sampleStep))
        if frames.last != max(0, scenario.totalFrames - 1) {
            frames.append(max(0, scenario.totalFrames - 1))
        }

        // Yield periodically to prevent main-thread stalls on large scenes.
        let yieldInterval = 32
        for (iterIndex, frame) in frames.enumerated() {
            if iterIndex > 0, iterIndex.isMultiple(of: yieldInterval) {
                await Task.yield()
                if Task.isCancelled { return [] }
            }

            let snapshot = frameSnapshot(
                for: scenario,
                store: store,
                rawFrame: frame,
                playbackStyle: playbackStyle
            )

            for character in snapshot.characters where character.visible {
                characterMeta[character.id] = (character.name, character.colorIndex)
                appendTrailPoint(character.worldPosition, into: &characterPoints[character.id, default: []])
            }

            for (index, object) in snapshot.objects.enumerated() where object.visible {
                objectMeta[object.id] = (object.name, index)
                appendTrailPoint(object.worldPosition, into: &objectPoints[object.id, default: []])
            }
        }

        if Task.isCancelled { return [] }

        let characterTrails = characterMeta.compactMap { id, meta -> Animate3DMotionTrail? in
            guard let points = characterPoints[id], points.count > 1 else { return nil }
            return Animate3DMotionTrail(
                id: "character-\(id)",
                label: meta.label,
                kind: .character,
                colorIndex: meta.colorIndex,
                points: points
            )
        }

        let objectTrails = objectMeta.compactMap { id, meta -> Animate3DMotionTrail? in
            guard let points = objectPoints[id], points.count > 1 else { return nil }
            return Animate3DMotionTrail(
                id: "object-\(id)",
                label: meta.label,
                kind: .object,
                colorIndex: meta.colorIndex,
                points: points
            )
        }

        return (characterTrails + objectTrails)
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    // MARK: - Scenario Builders

    private func selectedTimelineScenario(
        store: AnimateStore,
        scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> Animate3DPreviewScenario {
        var cast = scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })?.name
        }
        if cast.isEmpty {
            // Fallback: resolve via character slugs stored on the scene
            cast = scene.characterSlugs.compactMap { slug in
                store.characters.first(where: { $0.owpSlug == slug })?.name
            }
        }
        if cast.isEmpty && !scene.characterSlugs.isEmpty {
            // Final fallback: use the slug strings themselves as display names
            cast = scene.characterSlugs.map { slug in
                slug.replacingOccurrences(of: "-", with: " ").localizedCapitalized
            }
        }
        let shots = shotMarkers(for: scene, store: store, parseResult: parseResult)
        let totalFrames = max(maxSceneFrame(for: scene), shots.map(\.endFrame).max() ?? 0, 96)
        let defaultShot = scene.directionTemplate?.defaultCameraShot ?? shots.first?.cameraShot ?? .medium
        let focusCharacterName = scene.directionTemplate?.focusCharacterID.flatMap { id in
            store.characters.first(where: { $0.id == id })?.name
        } ?? scene.directionTemplate?.focusCharacterSlug.flatMap { slug in
            store.characters.first(where: { $0.owpSlug == slug })?.name
        }

        let syncPacket = sceneSyncPacket(
            store: store,
            scene: scene,
            lyrics: lyrics,
            parseResult: parseResult
        )
        let diagnostics = diagnostics(for: scene, shotCount: shots.count)
        let parseIssueCount = syncPacket.parseErrorCount

        let checks = [
            Animate3DValidationCheck(
                title: "Selected scene available",
                passed: true,
                severity: .info,
                detail: "Using \(scene.name) as the live 3D translation source."
            ),
            Animate3DValidationCheck(
                title: "Cast available",
                passed: !cast.isEmpty,
                severity: cast.isEmpty ? .error : .info,
                detail: cast.isEmpty
                    ? "No characters are assigned to this scene yet."
                    : "\(cast.count) placeholder rig(s) will be created from the scene cast."
            ),
            Animate3DValidationCheck(
                title: "Camera signals available",
                passed: hasCameraSignals(scene: scene),
                severity: hasCameraSignals(scene: scene) ? .info : .warning,
                detail: hasCameraSignals(scene: scene)
                    ? "Camera shot/template/track information is available for 3D translation."
                    : "No explicit camera track was found; fallback shot presets will be used."
            ),
            Animate3DValidationCheck(
                title: "Motion or shot coverage",
                passed: hasMotionSignals(scene: scene),
                severity: hasMotionSignals(scene: scene) ? .info : .warning,
                detail: hasMotionSignals(scene: scene)
                    ? "The selected scene includes tracks or shot segments that can drive placeholder animation."
                    : "The scene is mostly static; placeholder rigs will still load for camera translation testing."
            ),
            Animate3DValidationCheck(
                title: "Attachment cues available",
                passed: hasAttachmentSignals(scene: scene),
                severity: hasAttachmentSignals(scene: scene) ? .info : .warning,
                detail: hasAttachmentSignals(scene: scene)
                    ? "Object attachment targets can be visualized as guide links in 3D."
                    : "No attachment targets were detected for props in this scene."
            ),
            Animate3DValidationCheck(
                title: "Framing metadata available",
                passed: hasFramingMetadata(syncPacket: syncPacket),
                severity: hasFramingMetadata(syncPacket: syncPacket) ? .info : .warning,
                detail: hasFramingMetadata(syncPacket: syncPacket)
                    ? "Shot intent, beat labels, or notes are available for validation overlays."
                    : "No framing intent/beat-note metadata was found; framing is still validated from shot size and focus."
            )
        ]

        let warnings = parseIssueCount > 0
            ? ["The loaded libretto contains \(parseIssueCount) parse issue(s); the live timeline source still remains usable."]
            : []

        return Animate3DPreviewScenario(
            id: "live-\(scene.id.uuidString)",
            sceneID: scene.id,
            sceneName: scene.name,
            sourceKind: .selectedTimeline,
            sourceSummary: "Live scene timeline translation using current camera, shot, and direction state.",
            backgroundName: syncPacket.backgroundName,
            baseFPS: max(store.fps, 1),
            totalFrames: totalFrames + 1,
            castNames: cast,
            objectNames: scene.objectSetups.map(\.objectName),
            defaultShot: defaultShot,
            focusCharacterName: focusCharacterName,
            shotMarkers: shots,
            parsedDirectionCount: parseResult?.directions.count ?? 0,
            parseErrorCount: parseResult?.errors.count ?? 0,
            validation: Animate3DValidationReport(
                ready: checks.allSatisfy { $0.passed || $0.severity != .error },
                summary: "Live-scene translation ready for \(cast.count) rig(s), \(scene.objectSetups.count) prop(s), and \(shots.count) shot segment(s).",
                checks: checks,
                warnings: warnings
            ),
            diagnostics: diagnostics,
            compiledScene: nil,
            syncPacket: syncPacket
        )
    }

    private func parsedDirectionsScenario(
        store: AnimateStore,
        scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult
    ) -> Animate3DPreviewScenario {
        let bpm = store.currentSongData?.tempoEvents.first?.bpm ?? 120
        let compiled = SceneDirectionParser.compile(
            directions: parseResult.directions,
            fps: max(store.fps, 1),
            bpm: bpm,
            beatsPerBar: 4
        )
        let firstCameraZoom = compiled.cameraKeyframes.first.flatMap { keyframe -> Double? in
            guard case .transform(let transform) = keyframe.value else { return nil }
            return cameraZoom(from: transform)
        }
        let defaultShot = scene.directionTemplate?.defaultCameraShot
            ?? inferredShot(fromZoom: firstCameraZoom)
            ?? .medium
        let focusCharacterName = scene.directionTemplate?.focusCharacterID.flatMap { id in
            store.characters.first(where: { $0.id == id })?.name
        } ?? scene.directionTemplate?.focusCharacterSlug.flatMap { slug in
            store.characters.first(where: { $0.owpSlug == slug })?.name
        } ?? compiled.characterSetups.first?.characterName
        let shots = shotMarkers(for: scene, store: store, parseResult: parseResult)
        let syncPacket = sceneSyncPacket(
            store: store,
            scene: scene,
            lyrics: lyrics,
            parseResult: parseResult
        )
        let diagnostics = diagnostics(for: compiled, shotCount: shots.count)

        let checks = [
            Animate3DValidationCheck(
                title: "Directions parsed",
                passed: !parseResult.directions.isEmpty,
                severity: parseResult.directions.isEmpty ? .error : .info,
                detail: parseResult.directions.isEmpty
                    ? "No bracketed scene directions were found in the selected libretto."
                    : "Parsed \(parseResult.directions.count) direction line(s) into a 3D placeholder scenario."
            ),
            Animate3DValidationCheck(
                title: "Placeholder cast resolved",
                passed: !compiled.characterSetups.isEmpty,
                severity: compiled.characterSetups.isEmpty ? .error : .info,
                detail: compiled.characterSetups.isEmpty
                    ? "Parsed directions did not produce any character setups."
                    : "\(compiled.characterSetups.count) placeholder rig(s) can be staged from parsed directions."
            ),
            Animate3DValidationCheck(
                title: "Camera translation available",
                passed: !compiled.cameraKeyframes.isEmpty || scene.directionTemplate?.defaultCameraShot != nil,
                severity: (!compiled.cameraKeyframes.isEmpty || scene.directionTemplate?.defaultCameraShot != nil) ? .info : .warning,
                detail: !compiled.cameraKeyframes.isEmpty
                    ? "Parsed directions produced \(compiled.cameraKeyframes.count) camera keyframe(s)."
                    : "No explicit camera keyframes were parsed; default shot fallback will be used."
            ),
            Animate3DValidationCheck(
                title: "Parse issues within tolerance",
                passed: parseResult.errors.isEmpty,
                severity: parseResult.errors.isEmpty ? .info : .warning,
                detail: parseResult.errors.isEmpty
                    ? "No libretto parse issues were detected."
                    : "\(parseResult.errors.count) parse issue(s) were found; successful directions are still being used."
            ),
            Animate3DValidationCheck(
                title: "Attachment directives parsed",
                passed: compiled.objectSetups.contains(where: { $0.attachmentTarget != nil }),
                severity: compiled.objectSetups.contains(where: { $0.attachmentTarget != nil }) ? .info : .warning,
                detail: compiled.objectSetups.contains(where: { $0.attachmentTarget != nil })
                    ? "Parsed directions include attach/detach cues that can be visualized in 3D."
                    : "No attachment directives were found in the parsed directions."
            ),
            Animate3DValidationCheck(
                title: "Framing metadata available",
                passed: hasFramingMetadata(syncPacket: syncPacket),
                severity: hasFramingMetadata(syncPacket: syncPacket) ? .info : .warning,
                detail: hasFramingMetadata(syncPacket: syncPacket)
                    ? "Shot intent, beat labels, or notes are available for validation overlays."
                    : "No framing intent/beat-note metadata was found in the parsed scenario."
            )
        ]

        return Animate3DPreviewScenario(
            id: "parsed-\(scene.id.uuidString)",
            sceneID: scene.id,
            sceneName: scene.name,
            sourceKind: .parsedDirections,
            sourceSummary: "Libretto-driven translation test built from parsed bracketed scene directions.",
            backgroundName: compiled.backgroundName ?? syncPacket.backgroundName,
            baseFPS: max(store.fps, 1),
            totalFrames: max(compiled.totalFrames + 1, 96),
            castNames: compiled.characterSetups.map(\.characterName),
            objectNames: compiled.objectSetups.map(\.objectName),
            defaultShot: defaultShot,
            focusCharacterName: focusCharacterName,
            shotMarkers: shots,
            parsedDirectionCount: parseResult.directions.count,
            parseErrorCount: parseResult.errors.count,
            validation: Animate3DValidationReport(
                ready: checks.allSatisfy { $0.passed || $0.severity != .error },
                summary: "Parsed-direction translation ready for \(compiled.characterSetups.count) rig(s) over \(max(compiled.totalFrames, 1)) frame(s).",
                checks: checks,
                warnings: parseResult.errors.map { "Line \($0.lineNumber): \($0.message)" }
            ),
            diagnostics: diagnostics,
            compiledScene: compiled,
            syncPacket: syncPacket
        )
    }

    private func fixtureScenario(store: AnimateStore) -> Animate3DPreviewScenario {
        let fallbackNames = Array(store.characters.prefix(2).map(\.name))
        let lead = fallbackNames.first ?? "Lead"
        let partner = fallbackNames.dropFirst().first ?? "Guide"
        let script = """
        [scene: \"3D Translation Test\" | bg=Debug Stage | lighting=day]
        [enter: \"\(lead)\" | position=center_left | facing=right | emotion=neutral | bars=1]
        [enter: \"\(partner)\" | position=center_right | facing=left | emotion=curious | bars=1]
        [object: \"marker_crate\" | position=center | y=0.64 | state=ready | layer=foreground]
        [object: \"signal_flag\" | position=center_right | y=0.58 | state=ready | attach_to=character:\(partner):hand_right | layer=foreground]
        [camera: hold | from=wide | to=wide | bars=1-2]
        [move: \"\(lead)\" | from=center_left | to=center | bars=3-4 | easing=ease_in_out]
        [action: \"\(partner)\" | point_toward_horizon | bars=3-4]
        [camera: pan_right | from=medium | to=medium_close | bars=3-4 | easing=ease_in_out]
        [pause: bars=5]
        """

        let parseResult = SceneDirectionParser.parse(script)
        let compiled = SceneDirectionParser.compile(
            directions: parseResult.directions,
            fps: 24,
            bpm: 120,
            beatsPerBar: 4
        )

        let checks = [
            Animate3DValidationCheck(
                title: "Fixture loaded",
                passed: true,
                severity: .info,
                detail: "A deterministic 3D translation fixture is available even without a ready project scene."
            ),
            Animate3DValidationCheck(
                title: "Placeholder rigs resolved",
                passed: compiled.characterSetups.count >= 2,
                severity: compiled.characterSetups.count >= 2 ? .info : .error,
                detail: "Fixture currently stages \(compiled.characterSetups.count) placeholder rig(s)."
            ),
            Animate3DValidationCheck(
                title: "Camera move staged",
                passed: !compiled.cameraKeyframes.isEmpty,
                severity: !compiled.cameraKeyframes.isEmpty ? .info : .error,
                detail: !compiled.cameraKeyframes.isEmpty
                    ? "Fixture includes a simple camera move for translation testing."
                    : "Fixture camera keyframes were not generated."
            )
        ]
        let diagnostics = diagnostics(for: compiled, shotCount: 2)

        return Animate3DPreviewScenario(
            id: "fixture-translation-test",
            sceneID: nil,
            sceneName: "3D Translation Test",
            sourceKind: .fixture,
            sourceSummary: "Built-in fallback scene for validating 2D direction and camera translation into placeholder 3D space.",
            backgroundName: compiled.backgroundName,
            baseFPS: 24,
            totalFrames: max(compiled.totalFrames + 1, 96),
            castNames: compiled.characterSetups.map(\.characterName),
            objectNames: compiled.objectSetups.map(\.objectName),
            defaultShot: .medium,
            focusCharacterName: compiled.characterSetups.first?.characterName,
            shotMarkers: [
                Animate3DShotMarker(
                    id: "fixture-shot-1",
                    title: "Opening Wide",
                    detail: "Establish the debug stage with both placeholder rigs.",
                    startFrame: 0,
                    endFrame: 47,
                    cameraShot: .wide,
                    shotIntent: "Establishing",
                    provenance: "fixture"
                ),
                Animate3DShotMarker(
                    id: "fixture-shot-2",
                    title: "Move In",
                    detail: "Translate movement and a modest camera push with pan-right intent.",
                    startFrame: 48,
                    endFrame: max(compiled.totalFrames, 95),
                    cameraShot: .mediumClose,
                    shotIntent: "Movement",
                    provenance: "fixture"
                )
            ],
            parsedDirectionCount: parseResult.directions.count,
            parseErrorCount: parseResult.errors.count,
            validation: Animate3DValidationReport(
                ready: checks.allSatisfy { $0.passed || $0.severity != .error },
                summary: "Fallback fixture ready for end-to-end 3D translation validation.",
                checks: checks,
                warnings: []
            ),
            diagnostics: diagnostics,
            compiledScene: compiled,
            syncPacket: nil
        )
    }

    // MARK: - Snapshots

    private func selectedSceneFrameSnapshot(
        scenario: Animate3DPreviewScenario,
        store: AnimateStore,
        rawFrame: Int,
        displayFrame: Int
    ) -> Animate3DFrameSnapshot {
        guard let sceneID = scenario.sceneID,
              let scene = store.scenes.first(where: { $0.id == sceneID }) else {
            return emptySnapshot(for: scenario, rawFrame: rawFrame, displayFrame: displayFrame)
        }

        // Resolve character IDs, falling back to slug-based lookup if IDs are empty
        let resolvedCharacterIDs: [UUID] = {
            if !scene.characterIDs.isEmpty { return scene.characterIDs }
            // Slug-based fallback when IDs haven't been remapped yet
            return scene.characterSlugs.compactMap { slug in
                store.characters.first(where: { $0.owpSlug == slug })?.id
            }
        }()

        let characters: [Animate3DCharacterSnapshot] = resolvedCharacterIDs.enumerated().map { offset, characterID in
            let character = store.characters.first(where: { $0.id == characterID })
            let fallback = fallbackTransform(index: offset, total: max(resolvedCharacterIDs.count, 1))
            let transform = store.evaluatedTransform(for: characterID, at: displayFrame) ?? fallback
            let visibility = store.evaluatedVisibility(for: characterID, at: displayFrame)
                ?? (opacity: transform.opacity, visible: transform.opacity > 0.01)
            let facing = store.evaluatedFacingDirection(for: characterID, at: displayFrame)
                ?? defaultFacing(for: transform)

            // Secondary motion from live scene transform track (use cached lookup)
            let transformTrack = store.cachedTimelineTrack(for: characterID, role: .transform)
            let motionData = computeSecondaryMotion(
                trackKeyframes: transformTrack?.keyframes,
                currentTransform: transform,
                at: displayFrame,
                baseFPS: scenario.baseFPS
            )

            var basePosition = worldPosition(from: transform)
            basePosition.y += motionData.bobOffset
            basePosition.x += motionData.headLag

            let poseStr = store.evaluatedPose(for: characterID, at: displayFrame)?.rawValue
            let actionStr = store.evaluatedAction(for: characterID, at: displayFrame)

            return Animate3DCharacterSnapshot(
                id: characterID.uuidString,
                name: character?.name ?? "Character \(offset + 1)",
                worldPosition: basePosition,
                yawDegrees: yawDegrees(for: facing),
                opacity: visibility.opacity,
                visible: visibility.visible,
                pose: poseStr,
                expression: store.evaluatedExpression(for: characterID, at: displayFrame),
                action: actionStr,
                colorIndex: offset,
                characterUUID: character?.id ?? characterID,
                assetFolderSlug: character?.assetFolderSlug,
                packageSelectionSlug: character?.owpSlug,
                preferredAngle: store.evaluatedViewAngle(for: characterID, at: displayFrame) ?? character?.preferredViewAngle,
                preferredPose: store.evaluatedPose(for: characterID, at: displayFrame),
                mouthCue: store.evaluatedMouthCue(for: characterID, at: displayFrame),
                movementSpeed: motionData.speed,
                isMoving: motionData.isMoving,
                actionHint: deriveActionHint(pose: poseStr, action: actionStr),
                secondaryBobOffset: motionData.bobOffset,
                headLagOffset: motionData.headLag
            )
        }

        let objects: [Animate3DObjectSnapshot] = scene.objectSetups.enumerated().map { offset, object in
            let transform = store.evaluatedObjectTransform(for: object.objectName, at: displayFrame)
                ?? CharacterTransform(
                    x: object.initialX,
                    y: object.initialY,
                    rotation: 0,
                    scaleX: 1,
                    scaleY: 1,
                    opacity: object.opacity,
                    zOrder: object.zOrder
                )
            let visibility = store.evaluatedObjectVisibility(for: object.objectName, at: displayFrame)
                ?? (opacity: object.opacity, visible: object.visible)
            let objectScale = max(transform.scaleX, transform.scaleY)
            return Animate3DObjectSnapshot(
                id: object.id.uuidString,
                name: object.objectName,
                worldPosition: worldPosition(from: transform),
                yawDegrees: transform.rotation,
                scale: objectScale,
                opacity: visibility.opacity,
                visible: visibility.visible,
                attachmentTarget: object.attachmentTarget
            )
        }

        let activeShot = scenario.shotMarkers.first(where: { $0.contains(frame: displayFrame) })
        let focusCharacterID = store.evaluatedCameraFocusCharacterID(at: displayFrame)
            ?? scene.directionTemplate?.focusCharacterID
            ?? scene.directionTemplate?.focusCharacterSlug.flatMap { slug in
                store.characters.first(where: { $0.owpSlug == slug })?.id
            }
        let focusCharacter = focusCharacterID.flatMap { id in
            characters.first(where: { $0.id == id.uuidString })
        } ?? characters.first
        let shot = store.evaluatedEffectiveCameraShot(at: displayFrame)
            ?? activeShot?.cameraShot
            ?? scenario.defaultShot
        let cameraTransform = store.evaluatedCameraTransform(at: displayFrame)
        let shotIntent = store.evaluatedCameraShotIntent(at: displayFrame)?.displayName
            ?? activeShot?.shotIntent
            ?? scenario.syncPacket?.camera.shotIntent
        let beatLabel = store.evaluatedCameraBeatLabel(at: displayFrame)
            ?? scenario.syncPacket?.camera.beatLabel
        let beatNotes = store.evaluatedCameraBeatNotes(at: displayFrame)

        // Camera smoothing: shot transition blend and drift
        let shotTransition = computeShotTransitionProgress(
            shotMarkers: scenario.shotMarkers,
            at: displayFrame,
            blendFrames: cameraBlendFrames(baseFPS: scenario.baseFPS)
        )
        let drift = AnimationEngine.cameraDrift(frame: displayFrame, baseFPS: scenario.baseFPS)

        var camera = cameraSnapshot(
            shot: shot,
            transform: cameraTransform,
            focusCharacter: focusCharacter,
            shotIntent: shotIntent,
            beatLabel: beatLabel,
            beatNotes: beatNotes
        )
        camera.shotTransitionProgress = shotTransition
        camera.driftOffset = drift
        camera.position = camera.position + drift

        return Animate3DFrameSnapshot(
            rawFrame: rawFrame,
            displayFrame: displayFrame,
            totalFrames: scenario.totalFrames,
            activeShotTitle: activeShot?.title,
            camera: camera,
            characters: characters,
            objects: objects
        )
    }

    private func compiledFrameSnapshot(
        scenario: Animate3DPreviewScenario,
        compiled: CompiledScene,
        rawFrame: Int,
        displayFrame: Int
    ) -> Animate3DFrameSnapshot {
        let characters: [Animate3DCharacterSnapshot] = compiled.characterSetups.enumerated().map { offset, setup in
            let fallback = CharacterTransform(
                x: setup.initialPosition,
                y: 0.58,
                rotation: 0,
                scaleX: 1,
                scaleY: 1,
                opacity: 1,
                zOrder: offset
            )
            let trackName = "\(setup.characterName):transform"
            let transform = evaluateTransformTrack(
                compiled.tracks[trackName],
                at: displayFrame
            ) ?? fallback
            let visibility = evaluateVisibilityTrack(
                compiled.tracks["\(setup.characterName):visibility"],
                at: displayFrame
            ) ?? (
                opacity: transform.opacity,
                visible: displayFrame >= setup.enterFrame && (setup.exitFrame.map { displayFrame <= $0 } ?? true)
            )
            let facing = evaluateFacing(
                compiled.tracks["\(setup.characterName):facing"],
                at: displayFrame
            ) ?? setup.initialFacing

            // Secondary motion: compute movement metadata from surrounding keyframes
            let motionData = computeSecondaryMotion(
                trackKeyframes: compiled.tracks[trackName],
                currentTransform: transform,
                at: displayFrame,
                baseFPS: scenario.baseFPS
            )

            var basePosition = worldPosition(from: transform)
            basePosition.y += motionData.bobOffset
            basePosition.x += motionData.headLag

            let poseStr = evaluateExpressionTrack(compiled.tracks["\(setup.characterName):pose"], at: displayFrame)
            let actionStr = evaluateExpressionTrack(compiled.tracks["\(setup.characterName):action"], at: displayFrame)

            return Animate3DCharacterSnapshot(
                id: setup.id.uuidString,
                name: setup.characterName,
                worldPosition: basePosition,
                yawDegrees: yawDegrees(for: facing),
                opacity: visibility.opacity,
                visible: visibility.visible,
                pose: poseStr,
                expression: evaluateExpressionTrack(compiled.tracks["\(setup.characterName):expression"], at: displayFrame) ?? setup.initialEmotion,
                action: actionStr,
                colorIndex: offset,
                movementSpeed: motionData.speed,
                isMoving: motionData.isMoving,
                actionHint: deriveActionHint(pose: poseStr, action: actionStr),
                secondaryBobOffset: motionData.bobOffset,
                headLagOffset: motionData.headLag
            )
        }

        let objects: [Animate3DObjectSnapshot] = compiled.objectSetups.map { object in
            let fallback = CharacterTransform(
                x: object.initialX,
                y: object.initialY,
                rotation: 0,
                scaleX: 1,
                scaleY: 1,
                opacity: object.opacity,
                zOrder: object.zOrder
            )
            let transform = evaluateTransformTrack(
                compiled.tracks["\(object.objectName):transform"],
                at: displayFrame
            ) ?? fallback
            let visibility = evaluateVisibilityTrack(
                compiled.tracks["\(object.objectName):visibility"],
                at: displayFrame
            ) ?? (
                opacity: object.opacity,
                visible: displayFrame >= object.enterFrame && (object.exitFrame.map { displayFrame <= $0 } ?? object.visible)
            )
            let objectScale = max(transform.scaleX, transform.scaleY)
            return Animate3DObjectSnapshot(
                id: object.id.uuidString,
                name: object.objectName,
                worldPosition: worldPosition(from: transform),
                yawDegrees: transform.rotation,
                scale: objectScale,
                opacity: visibility.opacity,
                visible: visibility.visible,
                attachmentTarget: object.attachmentTarget
            )
        }

        let activeShot = scenario.shotMarkers.first(where: { $0.contains(frame: displayFrame) })
        let focusCharacter = scenario.focusCharacterName.flatMap { name in
            characters.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        } ?? characters.first

        let cameraTransform = evaluateTransformTrack(compiled.cameraKeyframes, at: displayFrame)
        let shot = evaluateShot(from: compiled, at: displayFrame)
            ?? inferredShot(fromZoom: cameraTransform.map(cameraZoom(from:)))
            ?? activeShot?.cameraShot
            ?? scenario.defaultShot

        // Camera smoothing: compute shot transition and drift
        let shotTransition = computeShotTransitionProgress(
            shotMarkers: scenario.shotMarkers,
            at: displayFrame,
            blendFrames: cameraBlendFrames(baseFPS: scenario.baseFPS)
        )
        let drift = AnimationEngine.cameraDrift(frame: displayFrame, baseFPS: scenario.baseFPS)

        var camera = cameraSnapshot(
            shot: shot,
            transform: cameraTransform,
            focusCharacter: focusCharacter,
            shotIntent: activeShot?.shotIntent ?? scenario.syncPacket?.camera.shotIntent,
            beatLabel: scenario.syncPacket?.camera.beatLabel,
            beatNotes: scenario.syncPacket?.camera.beatNotes
        )
        camera.shotTransitionProgress = shotTransition
        camera.driftOffset = drift
        camera.position = camera.position + drift

        return Animate3DFrameSnapshot(
            rawFrame: rawFrame,
            displayFrame: displayFrame,
            totalFrames: scenario.totalFrames,
            activeShotTitle: activeShot?.title,
            camera: camera,
            characters: characters,
            objects: objects
        )
    }

    // MARK: - Evaluation Helpers

    private func evaluateTransformTrack(_ keyframes: [TimelineKeyframe]?, at frame: Int) -> CharacterTransform? {
        guard let keyframes else { return nil }
        return evaluateTrack(keyframes, at: frame).flatMap {
            guard case .transform(let transform) = $0 else { return nil }
            return transform
        }
    }

    private func evaluateVisibilityTrack(_ keyframes: [TimelineKeyframe]?, at frame: Int) -> (opacity: Double, visible: Bool)? {
        guard let keyframes else { return nil }
        return evaluateTrack(keyframes, at: frame).flatMap {
            guard case .visibility(let opacity, let visible) = $0 else { return nil }
            return (opacity, visible)
        }
    }

    private func evaluateExpressionTrack(_ keyframes: [TimelineKeyframe]?, at frame: Int) -> String? {
        guard let keyframes else { return nil }
        return evaluateTrack(keyframes, at: frame).flatMap {
            guard case .expression(let name) = $0 else { return nil }
            return name
        }
    }

    private func evaluateFacing(_ keyframes: [TimelineKeyframe]?, at frame: Int) -> FacingDirection? {
        guard let expression = evaluateExpressionTrack(keyframes, at: frame) else { return nil }
        return FacingDirection(rawValue: expression)
    }

    private func evaluateShot(from compiled: CompiledScene, at frame: Int) -> CameraShot? {
        let expression = evaluateExpressionTrack(compiled.tracks["camera:shot"], at: frame)
        return expression.flatMap(CameraShot.init(rawValue:))
    }

    private func evaluateTrack(_ keyframes: [TimelineKeyframe], at frame: Int) -> KeyframeValue? {
        AnimationEngine.evaluate(
            track: TimelineTrack(name: "preview", keyframes: keyframes),
            at: frame
        )
    }

    // MARK: - Mapping Helpers

    private func worldPosition(
        from transform: CharacterTransform,
        baseHeight: Double = 0
    ) -> SIMD3<Double> {
        let x = (transform.x - 0.5) * 12.0
        let z = (0.58 - transform.y) * 10.0
        return SIMD3<Double>(x, baseHeight, z)
    }

    private func yawDegrees(for facing: FacingDirection) -> Double {
        switch facing {
        case .camera: 0
        case .right: -90
        case .left: 90
        case .away: 180
        }
    }

    private func defaultFacing(for transform: CharacterTransform) -> FacingDirection {
        transform.x < 0.5 ? .right : .left
    }

    private func cameraSnapshot(
        shot: CameraShot?,
        transform: CharacterTransform?,
        focusCharacter: Animate3DCharacterSnapshot?,
        shotIntent: String?,
        beatLabel: String?,
        beatNotes: String?
    ) -> Animate3DCameraSnapshot {
        let resolvedShot = shot ?? .medium
        let preset = cameraPreset(for: resolvedShot)
        let zoom = max(0.7, min(transform.map(cameraZoom(from:)) ?? resolvedShot.zoomLevel, 2.8))
        let target = SIMD3<Double>(
            (focusCharacter?.worldPosition.x ?? 0) + (transform?.x ?? 0) * 6.0,
            1.35 + (transform?.y ?? 0) * 2.5,
            focusCharacter?.worldPosition.z ?? 0
        )
        let distance = max(2.8, preset.distance / max(zoom, 0.6))
        let position = SIMD3<Double>(
            target.x,
            preset.height,
            target.z + distance
        )

        return Animate3DCameraSnapshot(
            position: position,
            lookAt: target,
            fieldOfView: max(12, min(75, preset.fieldOfView / max(zoom, 0.8))),
            shot: resolvedShot,
            shotLabel: resolvedShot.displayName,
            shotIntent: shotIntent,
            beatLabel: beatLabel,
            focusCharacterName: focusCharacter?.name,
            beatNotes: beatNotes
        )
    }

    private func cameraZoom(from transform: CharacterTransform) -> Double {
        return max(transform.scaleX, transform.scaleY)
    }

    private func inferredShot(fromZoom zoom: Double?) -> CameraShot? {
        guard let zoom else { return nil }
        let candidates: [CameraShot] = [
            .extremeWide,
            .wide,
            .medium,
            .mediumClose,
            .close,
            .extremeClose
        ]
        var bestShot: CameraShot?
        var bestDistance = Double.greatestFiniteMagnitude
        for shot in candidates {
            let distance = abs(shot.zoomLevel - zoom)
            if distance < bestDistance {
                bestDistance = distance
                bestShot = shot
            }
        }
        return bestShot
    }

    private func cameraPreset(for shot: CameraShot) -> (distance: Double, height: Double, fieldOfView: Double) {
        switch shot {
        case .extremeWide: (18.0, 5.6, 68)
        case .wide: (14.0, 4.8, 58)
        case .medium: (10.0, 4.1, 44)
        case .mediumClose: (7.5, 3.6, 32)
        case .close: (5.8, 3.1, 24)
        case .extremeClose: (4.0, 2.8, 18)
        }
    }

    private func fallbackTransform(index: Int, total: Int) -> CharacterTransform {
        let denominator = max(total + 1, 2)
        let x = Double(index + 1) / Double(denominator)
        return CharacterTransform(
            x: x,
            y: 0.58,
            rotation: 0,
            scaleX: 1,
            scaleY: 1,
            opacity: 1,
            zOrder: index
        )
    }

    // MARK: - Secondary Motion Helpers

    /// Data produced by secondary motion computation for a single character.
    private struct SecondaryMotionData {
        var speed: Double
        var isMoving: Bool
        var bobOffset: Double
        var headLag: Double
    }

    /// Compute secondary motion (bob, head-lag) for a character based on surrounding keyframes.
    private func computeSecondaryMotion(
        trackKeyframes: [TimelineKeyframe]?,
        currentTransform: CharacterTransform,
        at frame: Int,
        baseFPS: Int
    ) -> SecondaryMotionData {
        guard let keyframes = trackKeyframes, !keyframes.isEmpty else {
            return SecondaryMotionData(speed: 0, isMoving: false, bobOffset: 0, headLag: 0)
        }

        let track = TimelineTrack(name: "motion-probe", keyframes: keyframes)
        let (before, after) = track.surroundingKeyframes(at: frame)

        guard let before,
              let after,
              after.frame > before.frame,
              frame < after.frame,
              case .transform(let tA) = before.value,
              case .transform(let tB) = after.value
        else {
            return SecondaryMotionData(speed: 0, isMoving: false, bobOffset: 0, headLag: 0)
        }

        let span = Double(after.frame - before.frame)
        let t = Double(frame - before.frame) / span

        // Convert to world-space deltas for speed calculation
        let posA = worldPosition(from: tA)
        let posB = worldPosition(from: tB)
        let totalDistance = simd_distance(posA, posB)
        let fps = max(Double(baseFPS), 1.0)
        let durationSeconds = span / fps
        let speed = durationSeconds > 0 ? totalDistance / durationSeconds : 0
        let isMoving = totalDistance > 0.05

        guard isMoving else {
            return SecondaryMotionData(speed: 0, isMoving: false, bobOffset: 0, headLag: 0)
        }

        let lateralDelta = posB.x - posA.x
        let bobOffset = AnimationEngine.secondaryBob(t: t, movementSpeed: speed / fps)
        let headLag = AnimationEngine.headLag(t: t, lateralDelta: lateralDelta, movementSpeed: speed / fps)

        return SecondaryMotionData(
            speed: speed,
            isMoving: true,
            bobOffset: bobOffset,
            headLag: headLag
        )
    }

    /// Derive a short action hint from pose/action strings for procedural animation.
    private func deriveActionHint(pose: String?, action: String?) -> String? {
        let combined = [pose, action]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")
        guard !combined.isEmpty else { return nil }

        let hints = [
            "walk", "run", "move", "stride", "cross",
            "point", "gesture", "present", "offer",
            "celebrate", "triumph", "jump",
            "sit", "kneel", "crouch", "bow",
            "fight", "attack", "defend",
            "listen", "think", "wait"
        ]
        return hints.first { combined.contains($0) }
    }

    /// Compute how far into a shot transition we are (0 = just entered, 1 = fully settled).
    private func computeShotTransitionProgress(
        shotMarkers: [Animate3DShotMarker],
        at frame: Int,
        blendFrames: Int
    ) -> Double {
        guard let activeShot = shotMarkers.first(where: { $0.contains(frame: frame) }) else {
            return 1.0
        }
        let framesIntoShot = frame - activeShot.startFrame
        guard framesIntoShot < blendFrames, blendFrames > 0 else {
            return 1.0
        }
        let t = Double(framesIntoShot) / Double(blendFrames)
        // Use ease-out for smooth camera settle
        return AnimationEngine.applyEasing(t, curve: .easeOut)
    }

    /// Number of frames to blend when the camera transitions between shots (~0.5s).
    private func cameraBlendFrames(baseFPS: Int) -> Int {
        max(4, Int(round(Double(max(baseFPS, 1)) * 0.5)))
    }

    // MARK: - Scene State Helpers

    private func shotMarkers(
        for scene: AnimationScene,
        store: AnimateStore,
        parseResult: SceneDirectionParser.ParseResult? = nil
    ) -> [Animate3DShotMarker] {
        if !scene.shots.isEmpty {
            return shotMarkers(from: scene.shots)
        }

        if let parseResult {
            let seededShots = AnimateSceneShotSeedingService(store: store).seededShots(
                for: scene,
                songData: store.currentSongData,
                parseResult: parseResult
            )
            if !seededShots.isEmpty {
                return shotMarkers(from: seededShots)
            }
        }

        return AnimateShotSegmentationService(store: store, previewPlan: nil)
            .shotSegments(for: scene)
            .map { segment in
                Animate3DShotMarker(
                    id: segment.id,
                    title: segment.title,
                    detail: segment.detail,
                    startFrame: segment.startFrame,
                    endFrame: segment.endFrame,
                    cameraShot: store.evaluatedCameraShot(at: segment.startFrame)
                        ?? scene.directionTemplate?.defaultCameraShot,
                    shotIntent: nil,
                    provenance: segment.provenance.label
                )
            }
    }

    private func shotMarkers(from shots: [AnimationSceneShot]) -> [Animate3DShotMarker] {
        shots.map { shot in
            Animate3DShotMarker(
                id: shot.id.uuidString,
                title: shot.name,
                detail: shot.notes,
                startFrame: shot.startFrame,
                endFrame: shot.endFrame,
                cameraShot: shot.cameraShot,
                shotIntent: shot.shotIntent?.displayName,
                provenance: shot.source.displayName
            )
        }
    }

    private func hasLiveSceneSignals(scene: AnimationScene) -> Bool {
        hasMotionSignals(scene: scene) || hasCameraSignals(scene: scene)
    }

    private func hasMotionSignals(scene: AnimationScene) -> Bool {
        scene.tracks.values.contains { !$0.keyframes.isEmpty } || !scene.shots.isEmpty || !scene.objectSetups.isEmpty
    }

    private func hasCameraSignals(scene: AnimationScene) -> Bool {
        scene.directionTemplate?.defaultCameraShot != nil
            || !scene.shots.isEmpty
            || scene.tracks["camera"] != nil
            || scene.tracks["camera:shot"] != nil
            || scene.tracks["camera:default-shot"] != nil
    }

    private func hasAttachmentSignals(scene: AnimationScene) -> Bool {
        scene.objectSetups.contains { setup in
            guard let target = setup.attachmentTarget?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !target.isEmpty
        }
    }

    private func hasFramingMetadata(syncPacket: AnimateSceneSyncPacket) -> Bool {
        [syncPacket.camera.shotIntent, syncPacket.camera.beatLabel, syncPacket.camera.beatNotes]
            .contains { value in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                return !trimmed.isEmpty
            }
    }

    private func maxSceneFrame(for scene: AnimationScene) -> Int {
        let trackMax = scene.tracks.values
            .flatMap(\.keyframes)
            .map(\.frame)
            .max() ?? 0
        let shotMax = scene.shots.map(\.endFrame).max() ?? 0
        let keyframeMax = scene.keyframes.map(\.frame).max() ?? 0
        return max(trackMax, shotMax, keyframeMax)
    }

    private func diagnostics(
        for scene: AnimationScene,
        shotCount: Int
    ) -> Animate3DTranslationDiagnostics {
        let objectNames = Set(scene.objectSetups.map { normalizedTrackSubjectName($0.objectName) })
        var characterTrackCount = 0
        var objectTrackCount = 0
        var cameraTrackCount = 0
        var focusCueCount = 0
        var beatCueCount = 0
        var noteCueCount = 0
        var unsupportedTrackNames: [String] = []

        for track in scene.tracks.values {
            let role = track.role ?? inferredTrackRole(for: track.name)
            if isSupportedCameraRole(role) {
                cameraTrackCount += 1
                switch role {
                case .cameraFocus:
                    focusCueCount += track.keyframes.count
                case .cameraBeat:
                    beatCueCount += track.keyframes.count
                case .cameraNotes:
                    noteCueCount += track.keyframes.count
                default:
                    break
                }
            } else if isSupportedRenderableRole(role) {
                let subject = normalizedTrackSubjectName(track.name)
                if objectNames.contains(subject) {
                    objectTrackCount += 1
                } else {
                    characterTrackCount += 1
                }
            } else if !track.keyframes.isEmpty {
                unsupportedTrackNames.append(track.name)
            }
        }

        let shotNotesCount = scene.shots.filter { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count

        return Animate3DTranslationDiagnostics(
            characterTrackCount: characterTrackCount,
            objectTrackCount: objectTrackCount,
            cameraTrackCount: cameraTrackCount,
            shotSegmentCount: shotCount,
            focusCueCount: focusCueCount + scene.shots.filter { $0.focusCharacterID != nil || ($0.focusCharacterSlug?.isEmpty == false) }.count,
            beatCueCount: beatCueCount,
            noteCueCount: noteCueCount + shotNotesCount,
            attachmentCount: attachmentCount(
                objectSetups: scene.objectSetups,
                trackMap: scene.tracks.mapValues(\.keyframes)
            ),
            unsupportedTrackNames: unsupportedTrackNames.sorted()
        )
    }

    private func diagnostics(
        for compiled: CompiledScene,
        shotCount: Int
    ) -> Animate3DTranslationDiagnostics {
        let objectNames = Set(compiled.objectSetups.map { normalizedTrackSubjectName($0.objectName) })
        var characterTrackCount = 0
        var objectTrackCount = 0
        var cameraTrackCount = compiled.cameraKeyframes.isEmpty ? 0 : 1
        var focusCueCount = 0
        var beatCueCount = 0
        var noteCueCount = 0
        var unsupportedTrackNames: [String] = []

        for (trackName, keyframes) in compiled.tracks {
            let role = inferredTrackRole(for: trackName)
            if isSupportedCameraRole(role) {
                cameraTrackCount += 1
                switch role {
                case .cameraFocus:
                    focusCueCount += keyframes.count
                case .cameraBeat:
                    beatCueCount += keyframes.count
                case .cameraNotes:
                    noteCueCount += keyframes.count
                default:
                    break
                }
            } else if isSupportedRenderableRole(role) {
                let subject = normalizedTrackSubjectName(trackName)
                if objectNames.contains(subject) {
                    objectTrackCount += 1
                } else {
                    characterTrackCount += 1
                }
            } else if !keyframes.isEmpty {
                unsupportedTrackNames.append(trackName)
            }
        }

        return Animate3DTranslationDiagnostics(
            characterTrackCount: characterTrackCount,
            objectTrackCount: objectTrackCount,
            cameraTrackCount: cameraTrackCount,
            shotSegmentCount: shotCount,
            focusCueCount: focusCueCount,
            beatCueCount: beatCueCount,
            noteCueCount: noteCueCount,
            attachmentCount: attachmentCount(
                objectSetups: compiled.objectSetups.map {
                    ObjectSetup(
                        objectName: $0.objectName,
                        initialX: $0.initialX,
                        initialY: $0.initialY,
                        initialState: $0.initialState,
                        enterFrame: $0.enterFrame,
                        exitFrame: $0.exitFrame,
                        zOrder: $0.zOrder,
                        opacity: $0.opacity,
                        visible: $0.visible,
                        attachmentTarget: $0.attachmentTarget
                    )
                },
                trackMap: compiled.tracks
            ),
            unsupportedTrackNames: unsupportedTrackNames.sorted()
        )
    }

    private func attachmentCount(
        objectSetups: [ObjectSetup],
        trackMap: [String: [TimelineKeyframe]]
    ) -> Int {
        let configured = objectSetups.filter {
            !($0.attachmentTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }.count
        let cues = trackMap.reduce(into: 0) { count, entry in
            let role = inferredTrackRole(for: entry.key)
            guard role == .action else { return }
            count += entry.value.reduce(into: 0) { cueCount, keyframe in
                guard case .expression(let name) = keyframe.value,
                      name.lowercased().hasPrefix("attach:") else { return }
                cueCount += 1
            }
        }
        return configured + cues
    }

    private func inferredTrackRole(for trackName: String) -> TimelineTrackRole {
        if trackName == "camera" {
            return .camera
        }
        if trackName.hasPrefix("camera:") {
            return TimelineTrackRole(trackSuffix: String(trackName.dropFirst("camera:".count)))
        }
        let suffix = trackName.split(separator: ":").last.map(String.init) ?? trackName
        return TimelineTrackRole(trackSuffix: suffix)
    }

    private func normalizedTrackSubjectName(_ trackName: String) -> String {
        trackName
            .split(separator: ":")
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }

    private func isSupportedCameraRole(_ role: TimelineTrackRole) -> Bool {
        switch role {
        case .camera, .cameraShot, .cameraDefaultShot, .cameraFocus, .cameraIntent, .cameraBeat, .cameraNotes:
            return true
        default:
            return false
        }
    }

    private func isSupportedRenderableRole(_ role: TimelineTrackRole) -> Bool {
        switch role {
        case .transform, .visibility, .facing, .pose, .expression, .action:
            return true
        default:
            return false
        }
    }

    private func sceneSyncPacket(
        store: AnimateStore,
        scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> AnimateSceneSyncPacket {
        AnimateSceneOrchestrationService(
            store: store,
            parsedPlan: nil,
            parsedPlanErrorDescription: nil,
            hasPlanJSONText: false
        )
        .sceneSyncPacket(for: scene, lyrics: lyrics, parseResult: parseResult)
    }

    private func emptySnapshot(
        for scenario: Animate3DPreviewScenario,
        rawFrame: Int,
        displayFrame: Int
    ) -> Animate3DFrameSnapshot {
        Animate3DFrameSnapshot(
            rawFrame: rawFrame,
            displayFrame: displayFrame,
            totalFrames: scenario.totalFrames,
            activeShotTitle: nil,
            camera: Animate3DCameraSnapshot(
                position: SIMD3<Double>(0, 4, 10),
                lookAt: SIMD3<Double>(0, 1, 0),
                fieldOfView: 45,
                shot: scenario.defaultShot,
                shotLabel: scenario.defaultShot?.displayName ?? "Medium",
                shotIntent: nil,
                beatLabel: nil,
                focusCharacterName: nil,
                beatNotes: nil
            ),
            characters: [],
            objects: []
        )
    }

    private func appendTrailPoint(_ point: SIMD3<Double>, into points: inout [SIMD3<Double>]) {
        guard let last = points.last else {
            points.append(point)
            return
        }

        let delta = simd_distance(last, point)
        if delta > 0.05 {
            points.append(point)
        }
    }
}
