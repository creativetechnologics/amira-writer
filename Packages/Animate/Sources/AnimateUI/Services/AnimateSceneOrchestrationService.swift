import Foundation

@available(macOS 26.0, *)
@MainActor
struct AnimateSceneOrchestrationService {
    let store: AnimateStore
    let parsedPlan: LLMAnimationPlan?
    let parsedPlanErrorDescription: String?
    let hasPlanJSONText: Bool

    private var executionService: AnimateSceneExecutionService {
        AnimateSceneExecutionService(store: store, parsedPlan: parsedPlan)
    }

    func planReview(for scene: AnimationScene) -> AnimatePlanReview {
        planReview(for: scene, plan: parsedPlan)
    }

    func shotPlanSlicePreview(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> AnimateShotPlanSlicePreview? {
        guard let parsedPlan else { return nil }
        let slice = shotScopedPlanSlice(from: parsedPlan, shot: shot)
        let review = planReview(for: scene, plan: slice.plan)
        let applyPreview = planApplyPreview(for: scene, plan: slice.plan)

        var warnings = slice.warnings
        if slice.commandCounts.total == 0 {
            warnings.append("No current plan commands target this shot.")
        }

        return AnimateShotPlanSlicePreview(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            shotID: shot.id.uuidString,
            shotTitle: resolvedShotTitle(for: shot),
            frameRangeLabel: "\(shot.startFrame)–\(shot.endFrame)",
            commandCounts: slice.commandCounts,
            unanchoredCommandCount: slice.unanchoredCommandCount,
            warnings: warnings,
            plan: slice.plan,
            review: review,
            applyPreview: applyPreview
        )
    }

    func shotPlanSlicePreviewJSON(_ preview: AnimateShotPlanSlicePreview) -> String {
        encode(preview)
    }

    @discardableResult
    func applyShotPlanSlice(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> LLMAnimationValidationReport? {
        let report = LLMAnimationValidationReport(issues: [
            .init(
                severity: .warning,
                code: .invalidJSON,
                message: "Shot-slice apply is not enabled yet. Use Review Shot to inspect shot-scoped effects, then apply the full scene plan."
            )
        ])
        store.statusMessage = "Shot-slice apply is not enabled yet"
        return report
    }

    private func planReview(
        for scene: AnimationScene,
        plan: LLMAnimationPlan?
    ) -> AnimatePlanReview {
        let currentTracks = store.orderedTimelineTracks(for: scene)
        let currentTrackNames = Set(currentTracks.map(\.name))
        let currentFrames = sceneFrameCount(for: scene)

        guard let plan else {
            return AnimatePlanReview(
                currentTrackCount: currentTracks.count,
                proposedTrackCount: 0,
                currentFrames: currentFrames,
                proposedFrames: 0,
                newTracks: [],
                overlappingTracks: [],
                currentOnlyTracks: Array(currentTrackNames).sorted(),
                roleDeltas: roleDeltaRows(current: currentTracks, proposedTrackNames: [], includesCameraTrack: false),
                characterSetups: [],
                warnings: parsedPlanWarnings()
            )
        }

        let compiler = LLMAnimationPlanCompiler()
        let resolution = resolvedPlanApplication(for: plan, compiler: compiler)
        let warningMessages = resolution.issues.map { issue in
            "\(issue.severity.rawValue.uppercased()) · \(issue.code.rawValue): \(issue.message)"
        }

        guard resolution.issues.allSatisfy({ $0.severity != .error }),
              let compiled = resolution.compiled else {
            return AnimatePlanReview(
                currentTrackCount: currentTracks.count,
                proposedTrackCount: 0,
                currentFrames: currentFrames,
                proposedFrames: 0,
                newTracks: [],
                overlappingTracks: [],
                currentOnlyTracks: Array(currentTrackNames).sorted(),
                roleDeltas: roleDeltaRows(current: currentTracks, proposedTrackNames: [], includesCameraTrack: false),
                characterSetups: [],
                warnings: warningMessages
            )
        }

        let proposedTrackNames = Set(compiled.tracks.keys)
        let proposedCount = compiled.tracks.count + (compiled.cameraKeyframes.isEmpty ? 0 : 1)

        var warnings = warningMessages
        if !compiled.cameraKeyframes.isEmpty {
            warnings.append("Camera track will be regenerated from \(compiled.cameraKeyframes.count) compiled keyframes.")
        }
        if !currentTrackNames.intersection(proposedTrackNames).isEmpty {
            warnings.append("Applying this plan will replace overlapping scene tracks with the same names.")
        }

        return AnimatePlanReview(
            currentTrackCount: currentTracks.count,
            proposedTrackCount: proposedCount,
            currentFrames: currentFrames,
            proposedFrames: max(compiled.totalFrames, compiled.cameraKeyframes.map(\.frame).max() ?? 0),
            newTracks: Array(proposedTrackNames.subtracting(currentTrackNames)).sorted(),
            overlappingTracks: Array(currentTrackNames.intersection(proposedTrackNames)).sorted(),
            currentOnlyTracks: Array(currentTrackNames.subtracting(proposedTrackNames)).sorted(),
            roleDeltas: roleDeltaRows(
                current: currentTracks,
                proposedTrackNames: Array(proposedTrackNames),
                includesCameraTrack: !compiled.cameraKeyframes.isEmpty
            ),
            characterSetups: compiled.characterSetups.sorted { lhs, rhs in
                if lhs.enterFrame == rhs.enterFrame {
                    return lhs.characterName.localizedCaseInsensitiveCompare(rhs.characterName) == .orderedAscending
                }
                return lhs.enterFrame < rhs.enterFrame
            },
            warnings: warnings
        )
    }

    func planReviewJSON(_ review: AnimatePlanReview) -> String {
        encode(review)
    }

    func planApplyPreview(for scene: AnimationScene) -> AnimatePlanApplyPreview {
        planApplyPreview(for: scene, plan: parsedPlan)
    }

    private func planApplyPreview(
        for scene: AnimationScene,
        plan: LLMAnimationPlan?
    ) -> AnimatePlanApplyPreview {
        let currentTracks = store.orderedTimelineTracks(for: scene)
        let currentFrames = sceneFrameCount(for: scene)

        guard let plan else {
            return AnimatePlanApplyPreview(
                sceneID: scene.id.uuidString,
                sceneName: scene.name,
                currentTrackCount: currentTracks.count,
                proposedTrackCount: currentTracks.count,
                currentFrames: currentFrames,
                proposedFrames: currentFrames,
                effectCount: 0,
                actionableEffectCount: 0,
                effects: [],
                warnings: parsedPlanWarnings()
            )
        }

        let compiler = LLMAnimationPlanCompiler()
        let resolution = resolvedPlanApplication(for: plan, compiler: compiler)
        let warningMessages = resolution.issues.map {
            "\($0.severity.rawValue.uppercased()) · \($0.code.rawValue): \($0.message)"
        }

        guard resolution.issues.allSatisfy({ $0.severity != .error }),
              let compiled = resolution.compiled
        else {
            return AnimatePlanApplyPreview(
                sceneID: scene.id.uuidString,
                sceneName: scene.name,
                currentTrackCount: currentTracks.count,
                proposedTrackCount: currentTracks.count,
                currentFrames: currentFrames,
                proposedFrames: currentFrames,
                effectCount: 0,
                actionableEffectCount: 0,
                effects: [],
                warnings: warningMessages
            )
        }

        let effects = planApplyEffects(for: scene, compiled: compiled, sceneAudioPath: plan.sceneAudioPath)
        let actionableCount = effects.filter { $0.changeKind != .noChange }.count

        return AnimatePlanApplyPreview(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            currentTrackCount: currentTracks.count,
            proposedTrackCount: compiled.tracks.count + (compiled.cameraKeyframes.isEmpty ? 0 : 1),
            currentFrames: currentFrames,
            proposedFrames: max(compiled.totalFrames, compiled.cameraKeyframes.map(\.frame).max() ?? 0),
            effectCount: effects.count,
            actionableEffectCount: actionableCount,
            effects: effects,
            warnings: warningMessages
        )
    }

    func planApplyPreviewJSON(_ preview: AnimatePlanApplyPreview) -> String {
        encode(preview)
    }

    func dialogueVisemePreview(
        for scene: AnimationScene,
        visemeAnalyzer: @escaping @Sendable (URL, Int, String?) async throws -> [LipSyncEngine.VisemeKeyframe] = { url, fps, transcript in
            try await RhubarbLipSync().analyzeToVisemes(
                audioURL: url,
                fps: fps,
                dialogueText: transcript
            )
        }
    ) async -> AnimateDialogueVisemePreview {
        guard let parsedPlan else {
            return AnimateDialogueVisemePreview(
                sceneID: scene.id.uuidString,
                sceneName: scene.name,
                beatCount: 0,
                effectCount: 0,
                actionableEffectCount: 0,
                warnings: parsedPlanWarnings(),
                effects: []
            )
        }

        let compiler = LLMAnimationPlanCompiler()
        let resolution = resolvedPlanApplication(for: parsedPlan, compiler: compiler)
        let warningMessages = resolution.issues.map {
            "\($0.severity.rawValue.uppercased()) · \($0.code.rawValue): \($0.message)"
        }

        guard resolution.issues.allSatisfy({ $0.severity != .error }) else {
            return AnimateDialogueVisemePreview(
                sceneID: scene.id.uuidString,
                sceneName: scene.name,
                beatCount: resolution.resolvedPlan.dialogueBeats.count,
                effectCount: 0,
                actionableEffectCount: 0,
                warnings: warningMessages,
                effects: []
            )
        }

        let resolvedPlan = resolution.resolvedPlan
        let shotSegments = AnimateShotSegmentationService(store: store, previewPlan: nil)
            .shotSegments(for: scene)
        var warnings = warningMessages
        var effects: [AnimateDialogueVisemePreview.Effect] = []
        var simulatedTracks: [String: TimelineTrack] = [:]

        let beats = resolvedPlan.dialogueBeats.sorted(by: { $0.startFrame < $1.startFrame })
        if beats.isEmpty {
            warnings.append("No dialogue beats are present, so there are no generated viseme side effects to preview.")
        }

        for beat in beats {
            guard let audioPath = normalizedMediaPath(beat.audioPath),
                  let audioURL = resolvedMediaURL(for: audioPath),
                  FileManager.default.fileExists(atPath: audioURL.path) else {
                warnings.append("ERROR · missingAudioFile: Dialogue beat for \(beat.characterName) references missing audio '\(beat.audioPath)'.")
                continue
            }

            do {
                let visemes = try await visemeAnalyzer(audioURL, store.fps, beat.transcript)
                let adjustedKeyframes = LipSyncEngine
                    .visemesToTimelineKeyframes(visemes)
                    .map { keyframe in
                        var adjusted = keyframe
                        adjusted.frame += beat.startFrame
                        return adjusted
                    }

                let normalizedCharacterName = beat.characterName.trimmingCharacters(in: .whitespacesAndNewlines)
                let character = resolvedCharacter(named: normalizedCharacterName)
                let existingTrack = character.map { store.timelineTrack(for: $0.id, role: .mouth) } ?? nil
                let trackName = existingTrack?.name ?? "\(character?.name ?? normalizedCharacterName):mouth"
                let currentTrack = simulatedTracks[trackName] ?? existingTrack

                var proposedTrack = currentTrack ?? TimelineTrack(
                    name: trackName,
                    keyframes: [],
                    targetCharacterID: character?.id,
                    role: .mouth
                )
                proposedTrack.keyframes.append(contentsOf: adjustedKeyframes)
                proposedTrack.keyframes.sort { lhs, rhs in
                    if lhs.frame == rhs.frame {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.frame < rhs.frame
                }
                simulatedTracks[trackName] = proposedTrack

                let currentCount = currentTrack?.keyframes.count ?? 0
                let proposedCount = proposedTrack.keyframes.count
                let changeKind: AnimateExecutionPreview.Effect.ChangeKind = {
                    if adjustedKeyframes.isEmpty {
                        return .noChange
                    }
                    if currentTrack == nil {
                        return .create
                    }
                    return currentCount == proposedCount ? .noChange : .update
                }()
                let beatEndFrame = adjustedKeyframes.map { $0.frame }.max() ?? beat.startFrame

                effects.append(
                    AnimateDialogueVisemePreview.Effect(
                        characterName: character?.name ?? normalizedCharacterName,
                        trackName: trackName,
                        audioPath: audioPath,
                        transcriptExcerpt: trimmedTranscriptExcerpt(beat.transcript),
                        startFrame: beat.startFrame,
                        endFrame: beatEndFrame,
                        visemeCount: adjustedKeyframes.count,
                        currentValue: currentTrack.map { "\($0.keyframes.count) keyframes" } ?? nil,
                        proposedValue: "\(proposedCount) keyframes",
                        changeKind: changeKind,
                        detail: dialogueVisemeDetail(
                            characterName: character?.name ?? normalizedCharacterName,
                            visemeCount: adjustedKeyframes.count,
                            audioPath: audioPath,
                            changeKind: changeKind
                        ),
                        shotContexts: shotContexts(
                            for: beat.startFrame,
                            through: beatEndFrame,
                            shotSegments: shotSegments
                        )
                    )
                )
            } catch {
                warnings.append("ERROR · visemePreviewFailed: Could not preview generated visemes for \(beat.characterName): \(error.localizedDescription)")
            }
        }

        return AnimateDialogueVisemePreview(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            beatCount: beats.count,
            effectCount: effects.count,
            actionableEffectCount: effects.filter { $0.changeKind != .noChange }.count,
            warnings: warnings,
            effects: effects
        )
    }

    func dialogueVisemePreviewJSON(_ preview: AnimateDialogueVisemePreview) -> String {
        encode(preview)
    }

    func lightingPacket(for scene: AnimationScene) -> AnimateLightingPacket {
        let cast = sceneCharacters(for: scene)
        let background = backgroundPlate(for: scene)
        let automationPlan = store.selectedSceneAutomationPlan()
        let focusCharacterID = store.evaluatedCameraFocusCharacterID()
        let shot = store.evaluatedEffectiveCameraShot() ?? scene.directionTemplate?.defaultCameraShot
        let locationLabel = (background?.name ?? scene.name).lowercased()

        let lightWorld: AnimateLightingPacket.SharedLightWorld
        let practicals: [String]
        let zones: [String]

        if locationLabel.contains("night") {
            lightWorld = .init(name: "night_practical_mix", description: "Night exterior with practicals carrying the readable edge light.", temperature: "cool", contrast: "high")
            practicals = ["window glow", "street lantern", "fire basket"]
            zones = ["street plane", "far alley", "foreground faces"]
        } else if locationLabel.contains("sunset") {
            lightWorld = .init(name: "sunset_warm_edge", description: "Low warm sun with soft fill and strong background separation.", temperature: "warm", contrast: "medium")
            practicals = ["sun edge", "bounce from stone", "sky fill"]
            zones = ["roof edge", "horizon line", "subject fill plane"]
        } else if locationLabel.contains("clinic") {
            lightWorld = .init(name: "clinical_fluorescent_mix", description: "Flat fluorescent world with controlled subject protection and practical accents.", temperature: "neutral", contrast: "medium")
            practicals = ["fluorescent bank", "window spill", "exam practical"]
            zones = ["interior midground", "back wall", "subject plane"]
        } else if locationLabel.contains("courtyard") {
            lightWorld = .init(name: "courtyard_open_sky", description: "Open-sky daylight with wall bounce and soft face protection.", temperature: "warm-neutral", contrast: "medium")
            practicals = ["open sky", "wall bounce", "doorway spill"]
            zones = ["courtyard center", "wall edge", "entry threshold"]
        } else {
            lightWorld = .init(name: "daylight_grounded", description: "Grounded daylight with clean world key and balanced fill.", temperature: "neutral-warm", contrast: "medium")
            practicals = ["ambient daylight", "soft bounce", "set practical"]
            zones = ["foreground plane", "midground plate", "background separation"]
        }

        let focusName = focusCharacterID.flatMap { id in
            cast.first(where: { $0.id == id })?.name
        }

        let channels = [
            AnimateLightingPacket.Channel(name: "ch01_world_key", purpose: "Primary scene key that all characters share."),
            AnimateLightingPacket.Channel(name: "ch02_world_fill", purpose: "Global fill controlling readability without flattening the scene."),
            AnimateLightingPacket.Channel(name: "ch03_world_rim", purpose: "Rim / edge separation for silhouette clarity."),
            AnimateLightingPacket.Channel(name: "ch04_background_separation", purpose: "Keeps the place plate legible behind the cast."),
            AnimateLightingPacket.Channel(name: "ch05_practical_accent", purpose: "Small practicals or motivated accents that can rise per beat."),
            AnimateLightingPacket.Channel(name: "ch06_atmosphere_grade", purpose: "Scene-wide temperature, haze, and grade bias."),
            AnimateLightingPacket.Channel(name: "ch07_primary_subject_protect", purpose: "Protects the focus performer’s eyes, mouth, and facial plane."),
            AnimateLightingPacket.Channel(name: "ch08_secondary_subject_protect", purpose: "Protects secondary cast readability without breaking the shared world.")
        ]

        let characterPriorities = cast.enumerated().map { index, character in
            let summary = automationPlan?.characterSummaries.first(where: { $0.id == character.id })
            let isPrimary = focusCharacterID == character.id || (focusCharacterID == nil && index == 0)
            let channel = isPrimary ? "ch07_primary_subject_protect" : "ch08_secondary_subject_protect"
            var notes: [String] = []

            if isPrimary {
                notes.append("Prioritize face and mouth readability.")
            } else {
                notes.append("Maintain silhouette and supporting readability.")
            }

            if (summary?.activePackageVisemeCount ?? 0) > 0 {
                notes.append("Package carries viseme coverage for dialogue beats.")
            } else {
                notes.append("Watch for mouth coverage gaps on sung or spoken beats.")
            }

            if (summary?.approvedHeadPoseCount ?? 0) < 4 {
                notes.append("Head-angle coverage is still shallow.")
            } else {
                notes.append("Head-angle coverage supports internal relight reuse.")
            }

            return AnimateLightingPacket.CharacterPriority(
                characterID: character.id.uuidString,
                name: character.name,
                protectChannel: channel,
                priorityNotes: notes
            )
        }

        return AnimateLightingPacket(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            locationID: background?.id.uuidString,
            locationName: background?.name ?? "Unassigned place",
            approvedBackgroundImagePath: background?.resolvedApprovedImagePath,
            effectiveShot: shot?.displayName,
            shotIntent: store.evaluatedCameraShotIntent()?.displayName,
            beatLabel: store.evaluatedCameraBeatLabel(),
            executionBias: automationPlan?.effectiveExecutionMode.displayName ?? "Auto Recommend",
            lightingState: lightWorld.name,
            sharedLightWorld: lightWorld,
            zones: zones,
            practicals: practicals,
            channels: channels,
            characterPriorities: characterPriorities,
            focusCharacterName: focusName
        )
    }

    func lightingPacketJSON(_ packet: AnimateLightingPacket) -> String {
        encode(packet)
    }

    func sceneSyncPacket(
        for scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> AnimateSceneSyncPacket {
        let cast = sceneCharacters(for: scene)
        let background = backgroundPlate(for: scene)
        let automationPlan = store.selectedSceneAutomationPlan()
        let trackSummaries = trackRoleCounts(for: scene)
        let shotSegments = AnimateShotSegmentationService(store: store, previewPlan: nil)
            .shotSegments(for: scene)

        let characterPackets = cast.map { character in
            let summary = automationPlan?.characterSummaries.first(where: { $0.id == character.id })
            let preferredCostume = automationPlan?
                .characterSummaries.first(where: { $0.id == character.id })?
                .costumeSummaries.first?.costumeName

            return AnimateSceneSyncPacket.CharacterNode(
                id: character.id.uuidString,
                name: character.name,
                packageName: summary?.activePackageName,
                packageReady: summary?.activePackageValid ?? false,
                headPoseCount: summary?.approvedHeadPoseCount ?? 0,
                visemeCount: summary?.activePackageVisemeCount ?? 0,
                expressionCount: summary?.activePackageExpressionCount ?? 0,
                preferredCostume: preferredCostume
            )
        }

        let objectPackets: [AnimateSceneSyncPacket.ObjectNode] = scene.objectSetups.map { object in
            let currentState = store.evaluatedObjectCue(for: object.objectName, role: .drawing) ?? object.initialState
            let currentTransform = store.evaluatedObjectTransform(for: object.objectName)
                ?? CharacterTransform(
                    x: object.initialX,
                    y: object.initialY,
                    rotation: 0,
                    scaleX: 1,
                    scaleY: 1,
                    opacity: 1,
                    zOrder: object.zOrder
                )
            let currentVisibility = store.evaluatedObjectVisibility(for: object.objectName)
                ?? (opacity: object.opacity, visible: object.visible)
            let liveAttachmentTarget = store.evaluatedObjectCue(for: object.objectName, role: .action)
                .flatMap { cue -> String? in
                    guard cue.lowercased().hasPrefix("attach:") else { return nil }
                    let value = String(cue.dropFirst("attach:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
            let resolvedAttachmentTarget = liveAttachmentTarget ?? object.attachmentTarget
            let attachment = ObjectAttachmentReference.parse(resolvedAttachmentTarget)
            return AnimateSceneSyncPacket.ObjectNode(
                id: object.id.uuidString,
                name: object.objectName,
                currentState: currentState,
                approvedImagePath: object.resolvedApprovedImagePath,
                variantCount: max(object.imagePaths.count, object.stateImagePaths.count),
                hasResolvedArt: resolvedObjectArtPath(for: object, state: currentState) != nil,
                visible: currentVisibility.visible,
                opacity: currentVisibility.opacity,
                positionX: currentTransform.x,
                positionY: currentTransform.y,
                zOrder: currentTransform.zOrder,
                attachmentTarget: resolvedAttachmentTarget,
                attachmentKind: attachment?.kind.rawValue,
                attachmentSubject: attachment?.targetName,
                attachmentAnchor: attachment?.anchor
            )
        }

        let legacyDirections = (parseResult?.directions ?? []).map { direction in
            AnimateSceneSyncPacket.LegacyDirection(
                tag: direction.tag.rawValue,
                primaryValue: direction.primaryValue,
                lineNumber: direction.sourceLineNumber,
                parameters: direction.parameters
            )
        }

        let directionTemplate = scene.directionTemplate.map {
            AnimateSceneSyncPacket.DirectionTemplateNode(
                defaultCameraShot: $0.defaultCameraShot?.rawValue,
                focusCharacterSlug: $0.focusCharacterSlug,
                notes: $0.notes
            )
        }

        let automation = automationPlan.map {
            AnimateSceneSyncPacket.AutomationNode(
                recommendedExecutionMode: $0.recommendedExecutionMode.rawValue,
                effectiveExecutionMode: $0.effectiveExecutionMode.rawValue,
                readinessScore: $0.readinessScore,
                complexityScore: $0.complexityScore,
                summary: $0.summary,
                nextSteps: $0.recommendedNextSteps
            )
        }

        let camera = AnimateSceneSyncPacket.CameraNode(
            currentShot: store.evaluatedCameraShot()?.rawValue,
            defaultShot: store.evaluatedCameraDefaultShot()?.rawValue,
            effectiveShot: store.evaluatedEffectiveCameraShot()?.rawValue,
            focusCharacterID: store.evaluatedCameraFocusCharacterID()?.uuidString,
            shotIntent: store.evaluatedCameraShotIntent()?.rawValue,
            beatLabel: store.evaluatedCameraBeatLabel(),
            beatNotes: store.evaluatedCameraBeatNotes()
        )

        return AnimateSceneSyncPacket(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            owsSongPath: scene.owpSongPath,
            defaultAudioPath: scene.defaultAudioPath,
            backgroundName: background?.name,
            backgroundApprovedImagePath: background?.resolvedApprovedImagePath,
            cast: characterPackets,
            objects: objectPackets,
            directionTemplate: directionTemplate,
            automation: automation,
            camera: camera,
            shots: shotSegments.map {
                AnimateSceneSyncPacket.ShotNode(
                    id: $0.id,
                    title: $0.title,
                    detail: $0.detail,
                    startFrame: $0.startFrame,
                    endFrame: $0.endFrame,
                    startSeconds: secondsForSceneLocalFrame($0.startFrame),
                    endSeconds: secondsForSceneLocalFrame($0.endFrame),
                    startTimecode: sceneLocalTimecode(for: $0.startFrame),
                    endTimecode: sceneLocalTimecode(for: $0.endFrame),
                    durationFrames: $0.durationFrames,
                    durationTimecode: sceneLocalTimecode(for: $0.durationFrames),
                    provenance: $0.provenance.label
                )
            },
            trackRoles: trackSummaries,
            availableShotPresets: store.shotPresets.map(\.name).sorted(),
            legacyDirections: legacyDirections,
            lyrics: lyrics,
            parseErrorCount: parseResult?.errors.count ?? 0
        )
    }

    func sceneSyncPacketJSON(_ packet: AnimateSceneSyncPacket) -> String {
        encode(packet)
    }

    func orchestrationPacket(
        for scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult?,
        subsystemMetrics: [AnimateSceneExecutionPacket.SubsystemMetric]
    ) -> AnimateSceneOrchestrationPacket {
        AnimateSceneOrchestrationPacket(
            sync: sceneSyncPacket(for: scene, lyrics: lyrics, parseResult: parseResult),
            execution: executionService.sceneExecutionPacket(for: scene, subsystemMetrics: subsystemMetrics),
            lighting: lightingPacket(for: scene),
            review: planReview(for: scene)
        )
    }

    func orchestrationPacketJSON(_ packet: AnimateSceneOrchestrationPacket) -> String {
        encode(packet)
    }

    func scriptMigrationPrompt(for scene: AnimationScene) -> String {
        let cast = sceneCharacters(for: scene)
        let background = backgroundPlate(for: scene)
        let plan = store.selectedSceneAutomationPlan()
        let objectCatalog = scene.objectSetups.map(\.objectName).sorted()

        let castLine = cast.isEmpty
            ? "No cast linked yet."
            : cast.map(\.name).joined(separator: ", ")
        let objectLine = objectCatalog.isEmpty
            ? "No scene objects cataloged yet."
            : objectCatalog.joined(separator: ", ")

        let automationLine = plan.map {
            "Execution mode: \($0.effectiveExecutionMode.displayName). Readiness: \(Int($0.readinessScore * 100))%. Summary: \($0.summary)"
        } ?? "Execution mode has not been planned yet."

        let templateNotes = scene.directionTemplate?.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        You are updating a libretto scene from Amira Writer’s older animation-note format into the new Animate engine contract.

        Scene context
        - Scene name: \(scene.name)
        - Place/background: \(background?.name ?? "Unassigned")
        - Cast: \(castLine)
        - Scene objects: \(objectLine)
        - Audio path: \(scene.defaultAudioPath ?? scene.owpSongPath)
        - \(automationLine)

        Engine goals
        - Produce deterministic 2D animation instructions for a reusable kit-based pipeline.
        - Keep the plan compatible with a preview/timeline workflow similar to After Effects or Premiere.
        - Prefer reusable package coverage first; only request new assets when the scene truly needs unsupported poses, angles, expressions, or visemes.
        - Treat lighting and camera as first-class tracks, not vague prose notes.
        - Respect existing scene shots when they are present and use them as anchors for readable scene structure.

        Required output
        - Return valid JSON only.
        - Use the schema keys:
          sceneName, backgroundName, lighting, sceneAudioPath,
          characterPlacements, objectPlacements, motions, objectMotions,
          expressions, dialogueBeats, shadowCues, objectStateCues,
          cameraMoves, shotPresetApplications, notes
        - Frame-based items may optionally target an authored shot using shotName/shotID plus frameOffset.
        - Range-based items may optionally target an authored shot using shotName/shotID plus startFrameOffset/endFrameOffset.
        - Treat shot ranges and timecodes as scene-local only; do not use show-global timing.
        - Use normalized 0...1 coordinates for character placements, object placements, and motions.
        - Use only characters that already exist in the cast.
        - Use stable objectName values for props and set dressing; reuse the same objectName every time the same object appears again in the scene.
        - If a lyric or dialogue line is sung or spoken, add a dialogueBeat with transcript when possible.
        - Camera moves should be motivated, sparse, and readable for 2D staging.
        - Use notes for asset requests or staging warnings only, not for the main animation logic.

        Practical guidance
        - Favor stable body blocking over excessive motion.
        - Treat objects/props as first-class staging elements: place them, move them, and change their visible state using the dedicated object arrays instead of burying them in notes.
        - Use attachmentTarget on object commands when a prop is held, worn, or handed to a subject.
        - Attachment target forms now support: bare character name (legacy), character:name[:anchor], object:name[:anchor], or world:anchor.
        - Use attachmentTarget=none when the object should explicitly detach and return to world placement.
        - Keep camera intent readable: establishing, reveal, reaction, dialogue, movement, confrontation, insert, transition, emotional.
        - Use shotPresetApplications when the scene benefits from reusable shot grammar.
        - If scene shots already exist, align new camera and blocking changes to those shot boundaries unless the scene clearly needs a different cut structure.
        - If shot timing shifts, update scene-local shot timecodes rather than assuming the rest of the show moves with it.
        - Include lighting as a short readable phrase describing the scene light world and practicals.

        Existing direction notes
        \(templateNotes?.isEmpty == false ? templateNotes! : "No existing scene template notes were authored yet.")
        """
    }

    func librettoAuthorOperatorTemplate() -> String {
        """
        Use the master contract at `/Volumes/Storage VIII/Programming/Amira Writer/docs/specs/2026-03-31-libretto-visual-direction-master-contract.md` as binding.

        Rewrite the libretto scene by scene so Animate can interpret it immediately.

        Behave as both a director and cinematographer. Preserve the dramatic meaning, lyrics, and scene order. Do not paraphrase lyrics, do not merge or split scenes, and do not invent unsupported formatting.

        ## Scene packet
        - Scene name: {{SCENE_NAME}}
        - Song path: {{SONG_PATH}}
        - Audio path: {{AUDIO_PATH}}
        - Approved place/background: {{PLACE_BACKGROUND}}
        - Cast names: {{CAST_NAMES}}
        - Existing scene shots: {{EXISTING_SCENE_SHOTS}}
        - Recurring object names: {{RECURRING_OBJECTS}}
        - Timing notes: {{TIMING_NOTES}}
        - Additional directing guidance: {{DIRECTING_GUIDANCE}}
        - Operator notes: {{OPERATOR_NOTES}}

        ## Scene text
        {{SCENE_TEXT}}

        ## Required output
        - Return only the rewritten scene text unless explicitly asked for analysis.
        - Use the canonical bracketed Animate DSL from the master contract.
        - Keep critical visual logic inside bracket blocks.
        - Use unique shot labels inside the scene.
        - Keep all timing scene-local.
        - Treat objects/props as first-class scene elements.
        """
    }

    func librettoAuthorOperatorPrompt(
        for packet: AnimateSceneSyncPacket,
        overrides: AnimateLibrettoPromptOverrides
    ) -> String {
        let castNames = packet.cast.map(\.name).joined(separator: ", ")
        let objectNames = packet.objects.map(\.name).joined(separator: ", ")
        let shotNames = packet.shots.map(\.title).joined(separator: " | ")
        let timingNotes = overrides.timingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let directingGuidance = overrides.directingGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
        let operatorNotes = overrides.operatorNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let approvedObjects = overrides.approvedRecurringObjects.trimmingCharacters(in: .whitespacesAndNewlines)

        return librettoAuthorOperatorTemplate()
            .replacingOccurrences(of: "{{SCENE_NAME}}", with: packet.sceneName)
            .replacingOccurrences(of: "{{SONG_PATH}}", with: packet.owsSongPath)
            .replacingOccurrences(of: "{{AUDIO_PATH}}", with: packet.defaultAudioPath ?? "<scene audio path unavailable>")
            .replacingOccurrences(of: "{{PLACE_BACKGROUND}}", with: packet.backgroundName ?? "<approved place/background name>")
            .replacingOccurrences(of: "{{CAST_NAMES}}", with: castNames.isEmpty ? "<cast names>" : castNames)
            .replacingOccurrences(of: "{{EXISTING_SCENE_SHOTS}}", with: shotNames.isEmpty ? "<existing scene shots or none>" : shotNames)
            .replacingOccurrences(of: "{{RECURRING_OBJECTS}}", with: approvedObjects.isEmpty ? (objectNames.isEmpty ? "<recurring object names or none>" : objectNames) : approvedObjects)
            .replacingOccurrences(of: "{{TIMING_NOTES}}", with: timingNotes.isEmpty ? "<timing notes / phrase boundaries / musical cues>" : timingNotes)
            .replacingOccurrences(of: "{{DIRECTING_GUIDANCE}}", with: directingGuidance.isEmpty ? "<additional directing guidance>" : directingGuidance)
            .replacingOccurrences(of: "{{OPERATOR_NOTES}}", with: operatorNotes.isEmpty ? "<operator notes>" : operatorNotes)
            .replacingOccurrences(of: "{{SCENE_TEXT}}", with: packet.lyrics.isEmpty ? "<scene text>" : packet.lyrics)
    }

    private func parsedPlanWarnings() -> [String] {
        if let parsedPlanErrorDescription {
            return ["Plan JSON could not be parsed: \(parsedPlanErrorDescription)"]
        }

        if !hasPlanJSONText {
            return ["Paste or load an animation plan to preview the track diff before applying."]
        }

        return ["The current plan could not be reviewed."]
    }

    private func secondsForSceneLocalFrame(_ frame: Int) -> Double {
        guard store.fps > 0 else { return 0 }
        return Double(max(frame, 0)) / Double(store.fps)
    }

    private func sceneLocalTimecode(for frame: Int) -> String {
        let clampedFrame = max(frame, 0)
        guard store.fps > 0 else { return "00:00.00" }
        let totalSeconds = clampedFrame / store.fps
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let frameComponent = clampedFrame % store.fps
        let frameDigits = max(2, String(max(store.fps - 1, 0)).count)
        return String(format: "%02d:%02d.%0*d", minutes, seconds, frameDigits, frameComponent)
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

    private func resolvedPlanApplication(
        for plan: LLMAnimationPlan,
        compiler: LLMAnimationPlanCompiler
    ) -> (resolvedPlan: LLMAnimationPlan, compiled: CompiledScene?, issues: [LLMAnimationValidationIssue]) {
        let resolvedPlanAndIssues: (plan: LLMAnimationPlan, issues: [LLMAnimationValidationIssue])
        if let scene = store.selectedScene {
            resolvedPlanAndIssues = AnimatePlanShotAnchorResolver(store: store).resolve(plan, for: scene)
        } else {
            resolvedPlanAndIssues = (plan, [])
        }
        let resolvedPlan = resolvedPlanAndIssues.plan
        var issues = resolvedPlanAndIssues.issues + compiler.validate(resolvedPlan).issues

        let placementNames = resolvedPlan.characterPlacements.map(\.characterName)
        let motionNames = resolvedPlan.motions.map(\.characterName)
        let expressionNames = resolvedPlan.expressions.map(\.characterName)
        let dialogueNames = resolvedPlan.dialogueBeats.map(\.characterName)
        let shadowNames = resolvedPlan.shadowCues.map(\.characterName)
        let presetFocusNames = resolvedPlan.shotPresetApplications.compactMap(\.focusCharacterName)
        let presetOverrideNames = resolvedPlan.shotPresetApplications.flatMap { application in
            application.characterOverrides.map(\.characterName)
        }
        let referencedNames = placementNames + motionNames + expressionNames + dialogueNames + shadowNames + presetFocusNames + presetOverrideNames
        let referencedCharacterNames = Set(
            referencedNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        let knownCharacterNames = Set(
            store.characters.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        for missingName in referencedCharacterNames.subtracting(knownCharacterNames).sorted() {
            issues.append(.init(
                severity: .error,
                code: .unknownCharacter,
                message: "Animation plan references unknown character '\(missingName)'."
            ))
        }

        let resolvedPresetApplications = resolvedPlan.shotPresetApplications.map { application in
            (application, matchingShotPresets(named: application.presetName))
        }

        for (application, matches) in resolvedPresetApplications {
            let trimmedName = application.presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            if matches.isEmpty {
                issues.append(.init(
                    severity: .error,
                    code: .unknownShotPreset,
                    message: "Animation plan references unknown shot preset '\(trimmedName)'."
                ))
            } else if matches.count > 1 {
                issues.append(.init(
                    severity: .error,
                    code: .ambiguousShotPreset,
                    message: "Animation plan references shot preset '\(trimmedName)', but multiple presets share that name."
                ))
            }
        }

        guard issues.allSatisfy({ $0.severity != .error }) else {
            return (resolvedPlan, nil, issues)
        }

        var compiled = compiler.compile(resolvedPlan, fps: store.fps)
        let presetApplications = resolvedPresetApplications
            .compactMap { application, matches in
                matches.first.map { (application, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.0.frame == rhs.0.frame {
                    return normalizedShotPresetName(lhs.1.name) < normalizedShotPresetName(rhs.1.name)
                }
                return lhs.0.frame < rhs.0.frame
            }

        applyShotPresetApplications(presetApplications, to: &compiled)
        return (resolvedPlan, compiled, issues)
    }

    private func planApplyEffects(
        for scene: AnimationScene,
        compiled: CompiledScene,
        sceneAudioPath: String?
    ) -> [AnimatePlanApplyPreview.Effect] {
        var effects: [AnimatePlanApplyPreview.Effect] = []
        let shotSegments = AnimateShotSegmentationService(store: store, previewPlan: nil)
            .shotSegments(for: scene)

        let currentSceneName = scene.name
        let proposedSceneName = compiled.name.isEmpty ? currentSceneName : compiled.name
        effects.append(
            .init(
                scope: .sceneMetadata,
                title: "Scene name",
                target: "Scene",
                currentValue: currentSceneName,
                proposedValue: proposedSceneName,
                changeKind: previewChangeKind(current: currentSceneName, proposed: proposedSceneName),
                detail: previewDetail(
                    label: "scene name",
                    current: currentSceneName,
                    proposed: proposedSceneName,
                    noChangeDetail: "Scene name remains \(currentSceneName)."
                ),
                shotContexts: []
            )
        )

        if let backgroundName = compiled.backgroundName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !backgroundName.isEmpty {
            let currentBackground = backgroundPlate(for: scene)?.name
            let matchedBackground = store.backgrounds.first {
                $0.name.lowercased() == backgroundName.lowercased()
            }?.name
            effects.append(
                .init(
                    scope: .sceneMetadata,
                    title: "Background binding",
                    target: "Place",
                    currentValue: currentBackground,
                    proposedValue: matchedBackground ?? currentBackground,
                    changeKind: matchedBackground == nil
                        ? .noChange
                        : previewChangeKind(current: currentBackground, proposed: matchedBackground),
                    detail: matchedBackground == nil
                        ? "No place named \(backgroundName) exists, so background binding will stay unchanged."
                        : previewDetail(
                            label: "background",
                            current: currentBackground,
                            proposed: matchedBackground,
                            noChangeDetail: "Background already resolves to \(matchedBackground!)."
                        ),
                    shotContexts: []
                )
            )
        }

        let currentAudioPath = normalizedMediaPath(scene.defaultAudioPath)
        if let proposedAudioPath = normalizedMediaPath(sceneAudioPath) {
            effects.append(
                .init(
                    scope: .audioPath,
                    title: "Scene audio path",
                    target: "Audio",
                    currentValue: currentAudioPath,
                    proposedValue: proposedAudioPath,
                    changeKind: previewChangeKind(current: currentAudioPath, proposed: proposedAudioPath),
                    detail: previewDetail(
                        label: "audio path",
                        current: currentAudioPath,
                        proposed: proposedAudioPath,
                        noChangeDetail: "Scene audio path already matches the plan."
                    ),
                    shotContexts: []
                )
            )
        }

        for setup in compiled.characterSetups.sorted(by: { $0.enterFrame < $1.enterFrame }) {
            let shotContexts = shotContexts(
                for: setup.enterFrame,
                through: setup.enterFrame,
                shotSegments: shotSegments
            )
            guard let character = resolvedCharacter(named: setup.characterName) else {
                effects.append(
                    .init(
                        scope: .sceneMembership,
                        title: "Character link",
                        target: setup.characterName,
                        currentValue: nil,
                        proposedValue: nil,
                        changeKind: .noChange,
                        detail: "No character named \(setup.characterName) exists, so the scene cast will not change.",
                        startFrame: setup.enterFrame,
                        endFrame: setup.enterFrame,
                        shotContexts: shotContexts
                    )
                )
                continue
            }

            let alreadyLinked = scene.characterIDs.contains(character.id)
            effects.append(
                .init(
                    scope: .sceneMembership,
                    title: "Scene cast membership",
                    target: character.name,
                    currentValue: alreadyLinked ? "Linked" : "Not linked",
                    proposedValue: "Linked",
                    changeKind: alreadyLinked ? .noChange : .create,
                    detail: alreadyLinked
                        ? "\(character.name) is already part of the scene cast."
                        : "Add \(character.name) to the scene cast because the compiled plan stages them at frame \(setup.enterFrame).",
                    startFrame: setup.enterFrame,
                    endFrame: setup.enterFrame,
                    shotContexts: shotContexts
                )
            )
        }

        let currentTrackMap = Dictionary(
            store.orderedTimelineTracks(for: scene)
                .filter { $0.name != "camera" }
                .map { ($0.name, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        for name in compiled.tracks.keys.sorted() {
            let presentation = trackPresentation(for: name)
            let proposedTrack = TimelineTrack(
                name: name,
                keyframes: compiled.tracks[name] ?? [],
                role: trackRole(forTrackNamed: name)
            )
            let currentTrack = currentTrackMap[name]
            let frameRange = trackImpactRange(current: currentTrack, proposed: proposedTrack)
            let changeKind = previewChangeKind(
                current: currentTrack.flatMap(trackSignature),
                proposed: trackSignature(proposedTrack)
            )
            effects.append(
                .init(
                    scope: .timelineTrack,
                    title: presentation.title,
                    target: presentation.target,
                    currentValue: currentTrack.map { "\($0.keyframes.count) keyframes" },
                    proposedValue: "\(proposedTrack.keyframes.count) keyframes",
                    changeKind: changeKind,
                    detail: trackDetail(
                        name: presentation.target,
                        currentCount: currentTrack?.keyframes.count ?? 0,
                        proposedCount: proposedTrack.keyframes.count,
                        changeKind: changeKind
                    ),
                    startFrame: frameRange?.lowerBound,
                    endFrame: frameRange?.upperBound,
                    shotContexts: shotContexts(for: frameRange, shotSegments: shotSegments)
                )
            )
        }

        for name in currentTrackMap.keys.sorted().filter({ compiled.tracks[$0] == nil }) {
            let presentation = trackPresentation(for: name)
            let currentTrack = currentTrackMap[name]
            let frameRange = trackImpactRange(current: currentTrack, proposed: nil)
            effects.append(
                .init(
                    scope: .timelineTrack,
                    title: presentation.title,
                    target: presentation.target,
                    currentValue: currentTrack.map { "\($0.keyframes.count) keyframes" },
                    proposedValue: nil,
                    changeKind: .clear,
                    detail: "Remove \(presentation.target) because full plan apply replaces scene tracks wholesale.",
                    startFrame: frameRange?.lowerBound,
                    endFrame: frameRange?.upperBound,
                    shotContexts: shotContexts(for: frameRange, shotSegments: shotSegments)
                )
            )
        }

        let currentCameraTrack = store.timelineTrack(named: "camera")
        let proposedCameraTrack = compiled.cameraKeyframes.isEmpty
            ? nil
            : TimelineTrack(name: "camera", keyframes: compiled.cameraKeyframes, role: .camera)
        let cameraFrameRange = trackImpactRange(current: currentCameraTrack, proposed: proposedCameraTrack)
        let cameraChangeKind = previewChangeKind(
            current: currentCameraTrack.flatMap(trackSignature),
            proposed: proposedCameraTrack.flatMap(trackSignature)
        )
        effects.append(
            .init(
                scope: .cameraTrack,
                title: "Camera movement track",
                target: "camera",
                currentValue: currentCameraTrack.map { "\($0.keyframes.count) keyframes" },
                proposedValue: proposedCameraTrack.map { "\($0.keyframes.count) keyframes" },
                changeKind: cameraChangeKind,
                detail: trackDetail(
                    name: "camera",
                    currentCount: currentCameraTrack?.keyframes.count ?? 0,
                    proposedCount: proposedCameraTrack?.keyframes.count ?? 0,
                    changeKind: cameraChangeKind
                ),
                startFrame: cameraFrameRange?.lowerBound,
                endFrame: cameraFrameRange?.upperBound,
                shotContexts: shotContexts(for: cameraFrameRange, shotSegments: shotSegments)
            )
        )

        let currentFrames = sceneFrameCount(for: scene)
        let proposedFrames = max(compiled.totalFrames, compiled.cameraKeyframes.map(\.frame).max() ?? 0)
        effects.append(
            .init(
                scope: .sceneMetadata,
                title: "Frame range",
                target: "Timeline length",
                currentValue: "\(currentFrames)",
                proposedValue: "\(proposedFrames)",
                changeKind: previewChangeKind(current: "\(currentFrames)", proposed: "\(proposedFrames)"),
                detail: previewDetail(
                    label: "frame count",
                    current: "\(currentFrames)",
                    proposed: "\(proposedFrames)",
                    noChangeDetail: "Frame range remains \(currentFrames)."
                ),
                shotContexts: []
            )
        )

        return effects
    }

    private func roleDeltaRows(
        current: [TimelineTrack],
        proposedTrackNames: [String],
        includesCameraTrack: Bool
    ) -> [AnimatePlanRoleDelta] {
        let currentCounts = Dictionary(grouping: current) { $0.role ?? .custom }.mapValues(\.count)
        var proposedCounts: [TimelineTrackRole: Int] = [:]

        for name in proposedTrackNames {
            let role = trackRole(forTrackNamed: name)
            proposedCounts[role, default: 0] += 1
        }

        if includesCameraTrack {
            proposedCounts[.camera, default: 0] += 1
        }

        let allRoles = Set(currentCounts.keys).union(proposedCounts.keys)
        return allRoles
            .map { role in
                AnimatePlanRoleDelta(
                    role: role.displayLabel,
                    currentCount: currentCounts[role] ?? 0,
                    proposedCount: proposedCounts[role] ?? 0
                )
            }
            .sorted { $0.role < $1.role }
    }

    private func trackRole(forTrackNamed name: String) -> TimelineTrackRole {
        if name == "camera" {
            return .camera
        }

        if name.hasPrefix("object:") {
            let components = name.split(separator: ":").map(String.init)
            guard let suffix = components.last, components.count >= 3 else { return .custom }
            return TimelineTrackRole(trackSuffix: suffix)
        }

        let components = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return .custom }
        return TimelineTrackRole(trackSuffix: components[1])
    }

    private func trackPresentation(for name: String) -> (title: String, target: String) {
        if name.hasPrefix("object:") {
            let components = name.split(separator: ":").map(String.init)
            if components.count >= 3 {
                let objectName = components.dropFirst().dropLast().joined(separator: ":")
                let suffix = components.last ?? "track"
                let role = TimelineTrackRole(trackSuffix: suffix)
                return ("Scene object", "\(objectName):\(role.displayLabel)")
            }
            return ("Scene object", name)
        }

        if name == "camera" {
            return ("Camera track", "Camera")
        }

        let components = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return ("Timeline track", name) }
        let role = TimelineTrackRole(trackSuffix: components[1])
        return ("Timeline track", "\(components[0]):\(role.displayLabel)")
    }

    private func sceneFrameCount(for scene: AnimationScene) -> Int {
        max(
            store.totalFrames,
            store.orderedTimelineTracks(for: scene)
                .flatMap(\.keyframes)
                .map(\.frame)
                .max() ?? 0
        )
    }

    private func trackRoleCounts(for scene: AnimationScene) -> [AnimateSceneSyncPacket.TrackRoleCount] {
        let counts = Dictionary(grouping: store.orderedTimelineTracks(for: scene)) { track in
            trackRole(forTrackNamed: track.name).displayLabel
        }

        return counts.map { key, value in
            AnimateSceneSyncPacket.TrackRoleCount(role: key, count: value.count)
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.role < rhs.role
            }
            return lhs.count > rhs.count
        }
    }

    private func sceneCharacters(for scene: AnimationScene) -> [AnimationCharacter] {
        scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })
        }
    }

    private func backgroundPlate(for scene: AnimationScene) -> BackgroundPlate? {
        guard let backgroundID = scene.backgroundID else { return nil }
        return store.backgrounds.first(where: { $0.id == backgroundID })
    }

    private func matchingShotPresets(named name: String) -> [SceneShotPreset] {
        let normalizedName = normalizedShotPresetName(name)
        guard !normalizedName.isEmpty else { return [] }
        return store.shotPresets.filter { normalizedShotPresetName($0.name) == normalizedName }
    }

    private func normalizedShotPresetName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func resolvedCharacter(named name: String) -> AnimationCharacter? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty else { return nil }
        return store.characters.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }
    }

    private func applyShotPresetApplications(
        _ applications: [(LLMShotPresetApplication, SceneShotPreset)],
        to compiled: inout CompiledScene
    ) {
        var generatedCueKeys: Set<String> = []

        for (application, preset) in applications {
            let frame = application.frame
            let overridesByCharacterName = Dictionary(
                application.characterOverrides.map { override in
                    (
                        override.characterName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        override
                    )
                },
                uniquingKeysWith: { _, latest in latest }
            )
            var appliedOverrideCharacterNames: Set<String> = []

            if let cameraShot = application.cameraShot ?? preset.cameraShot {
                mergePresetExpressionCue(expression: cameraShot.rawValue, into: "camera:shot", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
            }
            if let defaultCameraShot = preset.defaultCameraShot {
                mergePresetExpressionCue(expression: defaultCameraShot.rawValue, into: "camera:default-shot", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
            }
            if let focusCharacter = application.focusCharacterName.flatMap({ resolvedCharacter(named: $0) }) ?? preset.focusCharacterSlug.flatMap({ slug in
                store.characters.first(where: { $0.owpSlug == slug })
            }) {
                mergePresetExpressionCue(expression: focusCharacter.owpSlug, into: "camera:focus", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
            }
            if let shotIntent = application.shotIntent ?? preset.shotIntent {
                mergePresetExpressionCue(expression: shotIntent.rawValue, into: "camera:intent", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
            }

            let beatLabel = trimmedMetadataOverride(application.beatLabel) ?? preset.name
            if !beatLabel.isEmpty {
                mergePresetExpressionCue(expression: beatLabel, into: "camera:beat", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
            }
            if let beatNotes = trimmedMetadataOverride(application.beatNotes) ?? trimmedMetadataOverride(preset.notes),
               !beatNotes.isEmpty {
                mergePresetExpressionCue(expression: beatNotes, into: "camera:notes", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
            }

            for cue in preset.characterCues {
                guard let character = store.characters.first(where: { $0.owpSlug == cue.characterSlug }) else {
                    continue
                }

                let characterNameKey = character.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let override = overridesByCharacterName[characterNameKey]
                if override != nil {
                    appliedOverrideCharacterNames.insert(characterNameKey)
                }

                if let facing = override?.facing ?? cue.facing {
                    mergePresetExpressionCue(expression: facing.rawValue, into: "\(character.name):facing", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let viewAngle = override?.viewAngle ?? cue.viewAngle {
                    mergePresetExpressionCue(expression: viewAngle.rawValue, into: "\(character.name):view", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let pose = override?.pose ?? cue.pose {
                    mergePresetExpressionCue(expression: pose.rawValue, into: "\(character.name):pose", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let expression = (override?.expression ?? cue.expression)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !expression.isEmpty {
                    mergePresetExpressionCue(expression: expression, into: "\(character.name):expression", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let action = (override?.action ?? cue.action)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !action.isEmpty {
                    mergePresetExpressionCue(expression: action, into: "\(character.name):action", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
            }

            for override in application.characterOverrides {
                let normalizedCharacterName = override.characterName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !appliedOverrideCharacterNames.contains(normalizedCharacterName),
                      let character = resolvedCharacter(named: override.characterName) else {
                    continue
                }

                if let facing = override.facing {
                    mergePresetExpressionCue(expression: facing.rawValue, into: "\(character.name):facing", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let viewAngle = override.viewAngle {
                    mergePresetExpressionCue(expression: viewAngle.rawValue, into: "\(character.name):view", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let pose = override.pose {
                    mergePresetExpressionCue(expression: pose.rawValue, into: "\(character.name):pose", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let expression = override.expression?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !expression.isEmpty {
                    mergePresetExpressionCue(expression: expression, into: "\(character.name):expression", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
                if let action = override.action?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !action.isEmpty {
                    mergePresetExpressionCue(expression: action, into: "\(character.name):action", at: frame, compiled: &compiled, generatedCueKeys: &generatedCueKeys)
                }
            }

            compiled.totalFrames = max(compiled.totalFrames, frame == 0 ? 1 : frame)
        }
    }

    private func mergePresetExpressionCue(
        expression: String,
        into trackName: String,
        at frame: Int,
        compiled: inout CompiledScene,
        generatedCueKeys: inout Set<String>
    ) {
        let cueKey = "\(trackName)|\(frame)"
        let keyframe = AnimationEngine.generateExpressionChange(expression: expression, at: frame)

        if let existingIndex = compiled.tracks[trackName]?.firstIndex(where: { $0.frame == frame && $0.kind == .expression }) {
            guard generatedCueKeys.contains(cueKey) else {
                return
            }
            compiled.tracks[trackName]?[existingIndex] = keyframe
        } else {
            compiled.tracks[trackName, default: []].append(keyframe)
        }

        compiled.tracks[trackName]?.sort { lhs, rhs in
            if lhs.frame == rhs.frame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.frame < rhs.frame
        }
        generatedCueKeys.insert(cueKey)
    }

    private func trimmedMetadataOverride(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMediaPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func previewChangeKind(
        current: String?,
        proposed: String?
    ) -> AnimateExecutionPreview.Effect.ChangeKind {
        if current == proposed {
            return .noChange
        }
        if current == nil, proposed != nil {
            return .create
        }
        if current != nil, proposed == nil {
            return .clear
        }
        return .update
    }

    private func previewDetail(
        label: String,
        current: String?,
        proposed: String?,
        noChangeDetail: String
    ) -> String {
        switch previewChangeKind(current: current, proposed: proposed) {
        case .create:
            return "Set \(label) to \(proposed ?? "empty")."
        case .update:
            return "Change \(label) from \(current ?? "empty") to \(proposed ?? "empty")."
        case .clear:
            return "Clear \(label), removing \(current ?? "empty")."
        case .noChange:
            return noChangeDetail
        case .activate, .switchSelection:
            return noChangeDetail
        }
    }

    private func trackSignature(_ track: TimelineTrack) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(track),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func trackDetail(
        name: String,
        currentCount: Int,
        proposedCount: Int,
        changeKind: AnimateExecutionPreview.Effect.ChangeKind
    ) -> String {
        switch changeKind {
        case .create:
            return "Create \(name) with \(proposedCount) keyframes."
        case .update:
            return "Replace \(name) from \(currentCount) to \(proposedCount) keyframes."
        case .clear:
            return "Remove \(name), clearing \(currentCount) keyframes."
        case .noChange:
            return "\(name) already matches the proposed keyframes."
        case .activate, .switchSelection:
            return "\(name) will change."
        }
    }

    private func trackImpactRange(
        current: TimelineTrack?,
        proposed: TimelineTrack?
    ) -> ClosedRange<Int>? {
        mergeRanges(trackFrameRange(current), trackFrameRange(proposed))
    }

    private func trackFrameRange(_ track: TimelineTrack?) -> ClosedRange<Int>? {
        guard let frames = track?.keyframes.map(\.frame),
              let minFrame = frames.min(),
              let maxFrame = frames.max() else {
            return nil
        }
        return minFrame...maxFrame
    }

    private func mergeRanges(
        _ lhs: ClosedRange<Int>?,
        _ rhs: ClosedRange<Int>?
    ) -> ClosedRange<Int>? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return min(lhs.lowerBound, rhs.lowerBound)...max(lhs.upperBound, rhs.upperBound)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        default:
            return nil
        }
    }

    private func shotContexts(
        for startFrame: Int,
        through endFrame: Int,
        shotSegments: [AnimateShotSegment]
    ) -> [AnimatePlanApplyPreview.Effect.ShotContext] {
        shotContexts(for: startFrame...max(startFrame, endFrame), shotSegments: shotSegments)
    }

    private func shotContexts(
        for frameRange: ClosedRange<Int>?,
        shotSegments: [AnimateShotSegment]
    ) -> [AnimatePlanApplyPreview.Effect.ShotContext] {
        guard let frameRange else { return [] }
        return shotSegments
            .filter { segment in
                segment.endFrame >= frameRange.lowerBound && segment.startFrame <= frameRange.upperBound
            }
            .map { segment in
                AnimatePlanApplyPreview.Effect.ShotContext(
                    id: segment.id,
                    title: segment.title,
                    frameRangeLabel: segment.frameRangeLabel
                )
            }
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func trimmedTranscriptExcerpt(_ transcript: String?) -> String? {
        guard let transcript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty else {
            return nil
        }
        if transcript.count <= 120 {
            return transcript
        }
        return String(transcript.prefix(117)) + "..."
    }

    private func dialogueVisemeDetail(
        characterName: String,
        visemeCount: Int,
        audioPath: String,
        changeKind: AnimateExecutionPreview.Effect.ChangeKind
    ) -> String {
        switch changeKind {
        case .create:
            return "Create a mouth track for \(characterName) and append \(visemeCount) generated viseme keyframes from \(audioPath)."
        case .update:
            return "Append \(visemeCount) generated viseme keyframes to \(characterName)’s mouth track from \(audioPath)."
        case .noChange:
            return visemeCount == 0
                ? "No generated viseme keyframes were returned for \(characterName) from \(audioPath)."
                : "\(characterName)’s mouth track already matches the generated viseme count for this beat."
        case .clear, .activate, .switchSelection:
            return "Generated viseme preview updated for \(characterName)."
        }
    }

    private func shotScopedPlanSlice(
        from plan: LLMAnimationPlan,
        shot: AnimationSceneShot
    ) -> (
        plan: LLMAnimationPlan,
        commandCounts: AnimateShotPlanSlicePreview.CommandCounts,
        unanchoredCommandCount: Int,
        warnings: [String]
    ) {
        let shotID = shot.id.uuidString
        let shotName = resolvedShotTitle(for: shot)

        let placements = plan.characterPlacements.compactMap { placement in
            matchingShotScopedPlacement(placement, shotID: shotID, shotName: shotName)
        }
        let objectPlacements = plan.objectPlacements.compactMap { placement in
            matchingShotScopedObjectPlacement(placement, shotID: shotID, shotName: shotName)
        }
        let motions = plan.motions.compactMap { motion in
            matchingShotScopedMotion(motion, shotID: shotID, shotName: shotName)
        }
        let objectMotions = plan.objectMotions.compactMap { motion in
            matchingShotScopedObjectMotion(motion, shotID: shotID, shotName: shotName)
        }
        let expressions = plan.expressions.compactMap { expression in
            matchingShotScopedExpression(expression, shotID: shotID, shotName: shotName)
        }
        let dialogueBeats = plan.dialogueBeats.compactMap { beat in
            matchingShotScopedDialogueBeat(beat, shotID: shotID, shotName: shotName)
        }
        let shadowCues = plan.shadowCues.compactMap { cue in
            matchingShotScopedShadowCue(cue, shotID: shotID, shotName: shotName)
        }
        let objectStateCues = plan.objectStateCues.compactMap { cue in
            matchingShotScopedObjectStateCue(cue, shotID: shotID, shotName: shotName)
        }
        let cameraMoves = plan.cameraMoves.compactMap { move in
            matchingShotScopedCameraMove(move, shotID: shotID, shotName: shotName)
        }
        let shotPresetApplications = plan.shotPresetApplications.compactMap { application in
            matchingShotScopedPresetApplication(application, shotID: shotID, shotName: shotName)
        }

        let unanchoredPointCount =
            plan.characterPlacements.filter(isUnanchored).count +
            plan.objectPlacements.filter(isUnanchored).count +
            plan.expressions.filter(isUnanchored).count +
            plan.dialogueBeats.filter(isUnanchored).count +
            plan.shadowCues.filter(isUnanchored).count +
            plan.objectStateCues.filter(isUnanchored).count +
            plan.shotPresetApplications.filter(isUnanchored).count
        let unanchoredRangeCount =
            plan.motions.filter(isUnanchored).count +
            plan.objectMotions.filter(isUnanchored).count +
            plan.cameraMoves.filter(isUnanchored).count
        let unanchoredCommandCount = unanchoredPointCount + unanchoredRangeCount

        var warnings: [String] = []
        if unanchoredCommandCount > 0 {
            warnings.append("\(unanchoredCommandCount) unanchored commands are excluded from shot-slice preview/apply.")
        }
        if plan.backgroundName != nil || plan.lighting != nil || plan.sceneAudioPath != nil {
            warnings.append("Scene metadata, lighting, and audio path stay at full-scene scope and are omitted from shot-slice apply.")
        }

        let slicedPlan = LLMAnimationPlan(
            schemaVersion: plan.schemaVersion,
            sceneName: plan.sceneName,
            backgroundName: nil,
            lighting: nil,
            sceneAudioPath: nil,
            characterPlacements: placements,
            objectPlacements: objectPlacements,
            motions: motions,
            objectMotions: objectMotions,
            expressions: expressions,
            dialogueBeats: dialogueBeats,
            shadowCues: shadowCues,
            objectStateCues: objectStateCues,
            cameraMoves: cameraMoves,
            shotPresetApplications: shotPresetApplications,
            notes: plan.notes + ["Shot slice for \(shotName)"]
        )

        return (
            slicedPlan,
            .init(
                placements: placements.count,
                objectPlacements: objectPlacements.count,
                motions: motions.count,
                objectMotions: objectMotions.count,
                expressions: expressions.count,
                dialogueBeats: dialogueBeats.count,
                shadowCues: shadowCues.count,
                objectStateCues: objectStateCues.count,
                cameraMoves: cameraMoves.count,
                presetApplications: shotPresetApplications.count
            ),
            unanchoredCommandCount,
            warnings
        )
    }

    private func resolvedShotTitle(for shot: AnimationSceneShot) -> String {
        let trimmed = shot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shot" : trimmed
    }

    private func matchesSelectedShot(
        shotID commandShotID: String?,
        shotName commandShotName: String?,
        selectedShotID: String,
        selectedShotName: String
    ) -> Bool {
        if let commandShotID = commandShotID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !commandShotID.isEmpty {
            return commandShotID == selectedShotID
        }
        if let commandShotName = commandShotName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !commandShotName.isEmpty {
            return commandShotName.caseInsensitiveCompare(selectedShotName) == .orderedSame
        }
        return false
    }

    private func isUnanchored(_ placement: LLMCharacterPlacement) -> Bool {
        placement.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        placement.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ placement: LLMObjectPlacement) -> Bool {
        placement.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        placement.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ motion: LLMCharacterMotion) -> Bool {
        motion.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        motion.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ motion: LLMObjectMotion) -> Bool {
        motion.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        motion.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ expression: LLMCharacterExpressionCue) -> Bool {
        expression.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        expression.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ beat: LLMDialogueBeat) -> Bool {
        beat.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        beat.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ cue: LLMCharacterShadowCue) -> Bool {
        cue.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        cue.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ cue: LLMObjectStateCue) -> Bool {
        cue.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        cue.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ move: LLMCameraMove) -> Bool {
        move.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        move.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func isUnanchored(_ application: LLMShotPresetApplication) -> Bool {
        application.shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        application.shotName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func matchingShotScopedPlacement(
        _ placement: LLMCharacterPlacement,
        shotID: String,
        shotName: String
    ) -> LLMCharacterPlacement? {
        guard matchesSelectedShot(shotID: placement.shotID, shotName: placement.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMCharacterPlacement(
            characterName: placement.characterName,
            frame: placement.frame,
            shotID: shotID,
            shotName: shotName,
            frameOffset: placement.frameOffset,
            position: placement.position,
            facing: placement.facing,
            viewAngle: placement.viewAngle,
            pose: placement.pose,
            emotion: placement.emotion,
            zOrder: placement.zOrder
        )
    }

    private func matchingShotScopedObjectPlacement(
        _ placement: LLMObjectPlacement,
        shotID: String,
        shotName: String
    ) -> LLMObjectPlacement? {
        guard matchesSelectedShot(shotID: placement.shotID, shotName: placement.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMObjectPlacement(
            objectName: placement.objectName,
            frame: placement.frame,
            shotID: shotID,
            shotName: shotName,
            frameOffset: placement.frameOffset,
            position: placement.position,
            state: placement.state,
            zOrder: placement.zOrder,
            opacity: placement.opacity,
            visible: placement.visible,
            attachmentTarget: placement.attachmentTarget
        )
    }

    private func matchingShotScopedMotion(
        _ motion: LLMCharacterMotion,
        shotID: String,
        shotName: String
    ) -> LLMCharacterMotion? {
        guard matchesSelectedShot(shotID: motion.shotID, shotName: motion.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMCharacterMotion(
            characterName: motion.characterName,
            startFrame: motion.startFrame,
            endFrame: motion.endFrame,
            shotID: shotID,
            shotName: shotName,
            startFrameOffset: motion.startFrameOffset,
            endFrameOffset: motion.endFrameOffset,
            from: motion.from,
            to: motion.to,
            easing: motion.easing,
            paceUnitsPerSecond: motion.paceUnitsPerSecond,
            facing: motion.facing,
            viewAngle: motion.viewAngle,
            pose: motion.pose,
            movementStyle: motion.movementStyle,
            zOrder: motion.zOrder
        )
    }

    private func matchingShotScopedObjectMotion(
        _ motion: LLMObjectMotion,
        shotID: String,
        shotName: String
    ) -> LLMObjectMotion? {
        guard matchesSelectedShot(shotID: motion.shotID, shotName: motion.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMObjectMotion(
            objectName: motion.objectName,
            startFrame: motion.startFrame,
            endFrame: motion.endFrame,
            shotID: shotID,
            shotName: shotName,
            startFrameOffset: motion.startFrameOffset,
            endFrameOffset: motion.endFrameOffset,
            from: motion.from,
            to: motion.to,
            easing: motion.easing,
            paceUnitsPerSecond: motion.paceUnitsPerSecond,
            state: motion.state,
            zOrder: motion.zOrder,
            attachmentTarget: motion.attachmentTarget
        )
    }

    private func matchingShotScopedExpression(
        _ expression: LLMCharacterExpressionCue,
        shotID: String,
        shotName: String
    ) -> LLMCharacterExpressionCue? {
        guard matchesSelectedShot(shotID: expression.shotID, shotName: expression.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMCharacterExpressionCue(
            characterName: expression.characterName,
            frame: expression.frame,
            shotID: shotID,
            shotName: shotName,
            frameOffset: expression.frameOffset,
            expression: expression.expression
        )
    }

    private func matchingShotScopedDialogueBeat(
        _ beat: LLMDialogueBeat,
        shotID: String,
        shotName: String
    ) -> LLMDialogueBeat? {
        guard matchesSelectedShot(shotID: beat.shotID, shotName: beat.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMDialogueBeat(
            characterName: beat.characterName,
            startFrame: beat.startFrame,
            shotID: shotID,
            shotName: shotName,
            frameOffset: beat.frameOffset,
            audioPath: beat.audioPath,
            transcript: beat.transcript,
            expression: beat.expression,
            action: beat.action
        )
    }

    private func matchingShotScopedShadowCue(
        _ cue: LLMCharacterShadowCue,
        shotID: String,
        shotName: String
    ) -> LLMCharacterShadowCue? {
        guard matchesSelectedShot(shotID: cue.shotID, shotName: cue.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMCharacterShadowCue(
            characterName: cue.characterName,
            frame: cue.frame,
            shotID: shotID,
            shotName: shotName,
            frameOffset: cue.frameOffset,
            style: cue.style,
            opacity: cue.opacity
        )
    }

    private func matchingShotScopedObjectStateCue(
        _ cue: LLMObjectStateCue,
        shotID: String,
        shotName: String
    ) -> LLMObjectStateCue? {
        guard matchesSelectedShot(shotID: cue.shotID, shotName: cue.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMObjectStateCue(
            objectName: cue.objectName,
            frame: cue.frame,
            shotID: shotID,
            shotName: shotName,
            frameOffset: cue.frameOffset,
            state: cue.state,
            opacity: cue.opacity,
            visible: cue.visible,
            attachmentTarget: cue.attachmentTarget
        )
    }

    private func matchingShotScopedCameraMove(
        _ move: LLMCameraMove,
        shotID: String,
        shotName: String
    ) -> LLMCameraMove? {
        guard matchesSelectedShot(shotID: move.shotID, shotName: move.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMCameraMove(
            movement: move.movement,
            startFrame: move.startFrame,
            endFrame: move.endFrame,
            shotID: shotID,
            shotName: shotName,
            startFrameOffset: move.startFrameOffset,
            endFrameOffset: move.endFrameOffset,
            fromShot: move.fromShot,
            toShot: move.toShot,
            easing: move.easing
        )
    }

    private func matchingShotScopedPresetApplication(
        _ application: LLMShotPresetApplication,
        shotID: String,
        shotName: String
    ) -> LLMShotPresetApplication? {
        guard matchesSelectedShot(shotID: application.shotID, shotName: application.shotName, selectedShotID: shotID, selectedShotName: shotName) else {
            return nil
        }
        return LLMShotPresetApplication(
            presetName: application.presetName,
            frame: application.frame,
            shotID: shotID,
            shotName: shotName,
            frameOffset: application.frameOffset,
            cameraShot: application.cameraShot,
            focusCharacterName: application.focusCharacterName,
            shotIntent: application.shotIntent,
            beatLabel: application.beatLabel,
            beatNotes: application.beatNotes,
            characterOverrides: application.characterOverrides
        )
    }

    private func resolvedMediaURL(for path: String) -> URL? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        if let projectRoot = (store.workingOWPURL ?? store.owpURL)?.deletingLastPathComponent() {
            let projectRelative = projectRoot.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: projectRelative.path) {
                return projectRelative
            }
        }

        if let animateURL = store.animateURL {
            let animateRelative = animateURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: animateRelative.path) {
                return animateRelative
            }
        }

        return nil
    }
}
