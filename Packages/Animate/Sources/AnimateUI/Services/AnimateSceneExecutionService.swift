import Foundation

@available(macOS 26.0, *)
@MainActor
struct AnimateSceneExecutionService {
    let store: AnimateStore
    let parsedPlan: LLMAnimationPlan?

    private let packageLibrary = CharacterPackageLibrary()

    func sceneExecutionPacket(
        for scene: AnimationScene,
        subsystemMetrics: [AnimateSceneExecutionPacket.SubsystemMetric]
    ) -> AnimateSceneExecutionPacket {
        let cast = sceneCharacters(for: scene)
        let background = backgroundPlate(for: scene)
        let plan = store.selectedSceneAutomationPlan()

        let characterResolutions = cast.map { character in
            let package = store.animateURL.flatMap {
                packageLibrary.activePackage(
                    for: character.assetFolderSlug,
                    in: $0,
                    preferredActivePackageID: store.activePackageID(for: character.owpSlug)
                )
            }
            let summary = plan?.characterSummaries.first(where: { $0.id == character.id })
            let issueMessages = package?.validationReport.issues
                .filter { $0.severity == .error }
                .map(\.message) ?? []

            return AnimateSceneExecutionPacket.CharacterResolution(
                characterID: character.id.uuidString,
                characterSlug: character.assetFolderSlug,
                packageSelectionSlug: character.owpSlug,
                name: character.name,
                packageID: package?.id.uuidString,
                packageName: package?.manifest.displayName,
                packageKind: package?.manifest.packageKind.rawValue,
                packageValid: package?.validationReport.isValid == true,
                assetCount: package?.manifest.assets.count ?? 0,
                referenceAssetCount: package?.manifest.assets.filter { $0.role == .reference }.count ?? 0,
                basePoseCount: package?.manifest.assets.filter { $0.role == .basePose || $0.role == .turnaround || $0.role == .heroPose }.count ?? 0,
                headPoseCount: summary?.approvedHeadPoseCount ?? 0,
                visemeCount: summary?.activePackageVisemeCount ?? 0,
                expressionCount: summary?.activePackageExpressionCount ?? 0,
                preferredCostumeName: summary?.costumeSummaries.first?.costumeName,
                primaryAssetPath: package.flatMap { packageLibrary.primaryAssetURL(for: $0) }?.path,
                validationErrors: issueMessages,
                priorityWork: buildPriorityWork(for: character, summary: summary, package: package)
            )
        }

        let place = AnimateSceneExecutionPacket.PlaceResolution(
            placeID: background?.id.uuidString,
            name: background?.name ?? "Unassigned place",
            approvedImagePath: background?.resolvedApprovedImagePath,
            imageVariantCount: background?.imagePaths.count ?? 0,
            summary: background?.resolvedApprovedImagePath == nil
                ? "No approved plate selected for this scene yet."
                : "Approved place plate is available for timeline playback and lighting packets."
        )

        let objectResolutions = scene.objectSetups.map { object in
            let approved = object.resolvedApprovedImagePath
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
            let hasResolvedArt = resolvedObjectArtPath(for: object, state: currentState) != nil
            let liveAttachmentTarget = store.evaluatedObjectCue(for: object.objectName, role: .action)
                .flatMap { cue -> String? in
                    guard cue.lowercased().hasPrefix("attach:") else { return nil }
                    let value = String(cue.dropFirst("attach:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
            let resolvedAttachmentTarget = liveAttachmentTarget ?? object.attachmentTarget
            let attachment = ObjectAttachmentReference.parse(resolvedAttachmentTarget)
            return AnimateSceneExecutionPacket.ObjectResolution(
                objectID: object.id.uuidString,
                objectName: object.objectName,
                currentState: currentState,
                approvedImagePath: approved,
                variantCount: max(object.imagePaths.count, object.stateImagePaths.count),
                hasResolvedArt: hasResolvedArt,
                visible: currentVisibility.visible,
                opacity: currentVisibility.opacity,
                positionX: currentTransform.x,
                positionY: currentTransform.y,
                zOrder: currentTransform.zOrder,
                attachmentTarget: resolvedAttachmentTarget,
                attachmentKind: attachment?.kind.rawValue,
                attachmentSubject: attachment?.targetName,
                attachmentAnchor: attachment?.anchor,
                notes: object.notes
            )
        }

        return AnimateSceneExecutionPacket(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            executionMode: plan?.effectiveExecutionMode.displayName ?? "Auto Recommend",
            readinessScore: plan?.readinessScore ?? 0,
            complexityScore: plan?.complexityScore ?? 0,
            trackCount: store.orderedTimelineTracks(for: scene).count,
            place: place,
            subsystemMetrics: subsystemMetrics,
            characterResolutions: characterResolutions,
            objectResolutions: objectResolutions,
            unresolvedNeeds: sceneExecutionNeeds(
                scene: scene,
                plan: plan,
                characterResolutions: characterResolutions,
                objectResolutions: objectResolutions,
                background: background
            )
        )
    }

    func sceneExecutionPacketJSON(_ packet: AnimateSceneExecutionPacket) -> String {
        encode(packet)
    }

    func executionBundle(
        for scene: AnimationScene,
        packet: AnimateSceneExecutionPacket
    ) -> AnimateExecutionBundle {
        let template = scene.directionTemplate
        let inferredIntent = store.evaluatedCameraShotIntent() ?? inferredShotIntent(for: scene)
        let focusID = resolvedFocusCharacterID(for: scene)
        let recommendedPresets = store
            .suggestedShotPresets(for: inferredIntent, focusCharacterID: focusID, limit: 3)
            .map {
                AnimateExecutionBundle.RecommendedPreset(
                    id: $0.id,
                    name: $0.name,
                    summary: $0.notes.isEmpty
                        ? "\($0.shotIntent?.displayName ?? "No intent") · \($0.characterCues.count) character cues"
                        : $0.notes,
                    cameraShot: $0.cameraShot?.displayName,
                    shotIntent: $0.shotIntent?.displayName
                )
            }

        var actions: [AnimateExecutionBundle.Action] = []

        for resolution in packet.characterResolutions where resolution.packageID != nil && resolution.packageName != nil {
            if store.activePackageID(for: resolution.packageSelectionSlug) == nil {
                actions.append(
                    .init(
                        kind: .activatePackage,
                        title: "Activate \(resolution.packageName!)",
                        detail: "Persist the recommended package for \(resolution.name) so scene playback resolves deterministically.",
                        packageSelectionSlug: resolution.packageSelectionSlug,
                        packageID: resolution.packageID
                    )
                )
            }
        }

        if let shot = template?.defaultCameraShot,
           store.evaluatedCameraDefaultShot(at: 0) == nil {
            actions.append(
                .init(
                    kind: .cameraDefaultShot,
                    title: "Stage default shot",
                    detail: "Seed frame 0 with \(shot.displayName) as the scene’s default camera framing.",
                    cameraShot: shot.rawValue
                )
            )
        }

        if let shot = template?.defaultCameraShot,
           store.evaluatedCameraShot(at: 0) == nil {
            actions.append(
                .init(
                    kind: .cameraShot,
                    title: "Stage opening shot",
                    detail: "Seed frame 0 with \(shot.displayName) so the preview opens in a deterministic framing.",
                    cameraShot: shot.rawValue
                )
            )
        }

        if let focusID, store.evaluatedCameraFocusCharacterID(at: 0) == nil {
            let focusName = sceneCharacters(for: scene).first(where: { $0.id == focusID })?.name ?? "Focus character"
            actions.append(
                .init(
                    kind: .cameraFocus,
                    title: "Stage focus character",
                    detail: "Bind frame 0 camera focus to \(focusName) for shot recommendation and mouth/lighting protection.",
                    focusCharacterID: focusID.uuidString
                )
            )
        }

        if let intent = inferredIntent,
           store.evaluatedCameraShotIntent(at: 0) == nil {
            actions.append(
                .init(
                    kind: .cameraIntent,
                    title: "Stage shot intent",
                    detail: "Set frame 0 intent to \(intent.displayName) so routing and preset recommendations stay stable.",
                    shotIntent: intent.rawValue
                )
            )
        }

        if store.evaluatedCameraBeatLabel(at: 0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            actions.append(
                .init(
                    kind: .cameraBeatLabel,
                    title: "Stage opening beat label",
                    detail: "Set a readable beat marker at frame 0 to anchor timeline automation for the scene.",
                    beatLabel: "\(scene.name) Start"
                )
            )
        }

        return AnimateExecutionBundle(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            executionMode: packet.executionMode,
            inferredIntent: inferredIntent?.displayName,
            effectiveShot: store.evaluatedEffectiveCameraShot()?.displayName ?? template?.defaultCameraShot?.displayName,
            focusCharacterName: focusID.flatMap { id in sceneCharacters(for: scene).first(where: { $0.id == id })?.name },
            actions: actions,
            recommendedPresets: recommendedPresets,
            blockers: packet.unresolvedNeeds
                .filter { $0.severity == "error" }
                .map { "\($0.scope): \($0.title) — \($0.detail)" }
        )
    }

    func executionBundleJSON(_ bundle: AnimateExecutionBundle) -> String {
        encode(bundle)
    }

    func executionPreview(
        for scene: AnimationScene,
        bundle: AnimateExecutionBundle,
        packet: AnimateSceneExecutionPacket
    ) -> AnimateExecutionPreview {
        let effects = bundle.actions.compactMap { effect(for: $0, scene: scene, packet: packet) }
        let noChangeCount = effects.filter { $0.changeKind == .noChange }.count
        let packageCount = effects.filter { $0.scope == .packageSelection }.count
        let timelineCount = effects.filter { $0.scope == .timelineCue }.count

        var warnings = bundle.blockers
        if effects.isEmpty {
            warnings.append("No deterministic staging changes are pending.")
        }

        return AnimateExecutionPreview(
            sceneID: scene.id.uuidString,
            sceneName: scene.name,
            effectCount: effects.count,
            actionableEffectCount: effects.count - noChangeCount,
            packageEffectCount: packageCount,
            timelineEffectCount: timelineCount,
            noChangeEffectCount: noChangeCount,
            effects: effects,
            warnings: warnings
        )
    }

    func executionPreviewJSON(_ preview: AnimateExecutionPreview) -> String {
        encode(preview)
    }

    func shotPresetPreview(
        _ preset: SceneShotPreset,
        frame: Int = 0
    ) -> AnimatePresetPreview {
        var effects: [AnimateExecutionPreview.Effect] = []
        var warnings: [String] = []

        effects.append(
            framingEffect(
                actionKind: "shotPreset.cameraShot",
                title: "Apply shot cue",
                target: "Opening shot",
                trackName: "camera:shot",
                frame: frame,
                currentValue: explicitExpressionValue(trackName: "camera:shot", frame: frame),
                currentSource: hasExplicitExpression(trackName: "camera:shot", frame: frame) ? "existing frame cue" : "no explicit cue",
                proposedValue: preset.cameraShot?.displayName
            )
        )

        effects.append(
            framingEffect(
                actionKind: "shotPreset.defaultShot",
                title: "Apply default shot cue",
                target: "Scene default framing",
                trackName: "camera:default-shot",
                frame: frame,
                currentValue: explicitExpressionValue(trackName: "camera:default-shot", frame: frame) ?? store.evaluatedCameraDefaultShot(at: frame)?.displayName,
                currentSource: hasExplicitExpression(trackName: "camera:default-shot", frame: frame) ? "existing frame cue" : "scene template fallback",
                proposedValue: preset.defaultCameraShot?.displayName
            )
        )

        let focusCharacter = preset.focusCharacterSlug.flatMap { slug in
            store.characters.first(where: { $0.owpSlug == slug })
        }
        if preset.focusCharacterSlug != nil && focusCharacter == nil {
            warnings.append("Preset focus slug \(preset.focusCharacterSlug!) is unresolved; applying it will clear the explicit focus cue at frame \(frame).")
        }
        let currentExplicitFocusSlug = explicitExpressionValue(trackName: "camera:focus", frame: frame)
        let currentFocusName = currentExplicitFocusSlug.flatMap { slug in
            store.characters.first(where: { $0.owpSlug == slug })?.name
        } ?? store.evaluatedCameraFocusCharacterID(at: frame).flatMap { focusID in
            store.characters.first(where: { $0.id == focusID })?.name
        }
        effects.append(
            framingEffect(
                actionKind: "shotPreset.focus",
                title: "Apply focus cue",
                target: "Focused character",
                trackName: "camera:focus",
                frame: frame,
                currentValue: currentFocusName,
                currentSource: currentExplicitFocusSlug != nil ? "existing frame cue" : "scene template fallback",
                proposedValue: focusCharacter?.name
            )
        )

        effects.append(
            framingEffect(
                actionKind: "shotPreset.intent",
                title: "Apply intent cue",
                target: "Shot intent",
                trackName: "camera:intent",
                frame: frame,
                currentValue: explicitExpressionValue(trackName: "camera:intent", frame: frame) ?? store.evaluatedCameraShotIntent(at: frame)?.displayName,
                currentSource: hasExplicitExpression(trackName: "camera:intent", frame: frame) ? "existing frame cue" : "derived engine intent",
                proposedValue: preset.shotIntent?.displayName
            )
        )

        effects.append(
            framingEffect(
                actionKind: "shotPreset.beat",
                title: "Apply beat label",
                target: "Beat label",
                trackName: "camera:beat",
                frame: frame,
                currentValue: explicitExpressionValue(trackName: "camera:beat", frame: frame) ?? store.evaluatedCameraBeatLabel(at: frame),
                currentSource: hasExplicitExpression(trackName: "camera:beat", frame: frame) ? "existing frame cue" : "no explicit cue",
                proposedValue: preset.name
            )
        )

        effects.append(
            framingEffect(
                actionKind: "shotPreset.notes",
                title: "Apply beat notes",
                target: "Beat notes",
                trackName: "camera:notes",
                frame: frame,
                currentValue: explicitExpressionValue(trackName: "camera:notes", frame: frame),
                currentSource: hasExplicitExpression(trackName: "camera:notes", frame: frame) ? "existing frame cue" : "no explicit cue",
                proposedValue: trimmedOrNil(preset.notes)
            )
        )

        for cue in preset.characterCues {
            guard let character = store.characters.first(where: { $0.owpSlug == cue.characterSlug }) else {
                warnings.append("Preset cue references unresolved character slug \(cue.characterSlug); that cue will be skipped.")
                continue
            }

            effects.append(
                semanticEffect(
                    actionKind: "shotPreset.facing",
                    title: "\(character.name) facing",
                    target: character.name,
                    trackName: "\(character.name):facing",
                    frame: frame,
                    currentValue: explicitExpressionValue(trackName: "\(character.name):facing", frame: frame),
                    proposedValue: cue.facing?.rawValue
                )
            )
            effects.append(
                semanticEffect(
                    actionKind: "shotPreset.view",
                    title: "\(character.name) view angle",
                    target: character.name,
                    trackName: "\(character.name):view",
                    frame: frame,
                    currentValue: explicitExpressionValue(trackName: "\(character.name):view", frame: frame),
                    proposedValue: cue.viewAngle?.rawValue
                )
            )
            effects.append(
                semanticEffect(
                    actionKind: "shotPreset.pose",
                    title: "\(character.name) pose",
                    target: character.name,
                    trackName: "\(character.name):pose",
                    frame: frame,
                    currentValue: explicitExpressionValue(trackName: "\(character.name):pose", frame: frame),
                    proposedValue: cue.pose?.rawValue
                )
            )
            effects.append(
                semanticEffect(
                    actionKind: "shotPreset.expression",
                    title: "\(character.name) expression",
                    target: character.name,
                    trackName: "\(character.name):expression",
                    frame: frame,
                    currentValue: explicitExpressionValue(trackName: "\(character.name):expression", frame: frame),
                    proposedValue: trimmedOrNil(cue.expression)
                )
            )
            effects.append(
                semanticEffect(
                    actionKind: "shotPreset.action",
                    title: "\(character.name) action",
                    target: character.name,
                    trackName: "\(character.name):action",
                    frame: frame,
                    currentValue: explicitExpressionValue(trackName: "\(character.name):action", frame: frame),
                    proposedValue: trimmedOrNil(cue.action)
                )
            )
        }

        let normalizedEffects = effects.filter { effect in
            !(effect.changeKind == .noChange && effect.proposedValue == nil && effect.currentValue == nil)
        }
        let clearCount = normalizedEffects.filter { $0.changeKind == .clear }.count
        let actionableCount = normalizedEffects.filter { $0.changeKind != .noChange }.count

        return AnimatePresetPreview(
            presetID: preset.id,
            presetName: preset.name,
            frame: frame,
            effectCount: normalizedEffects.count,
            actionableEffectCount: actionableCount,
            clearEffectCount: clearCount,
            effects: normalizedEffects,
            warnings: warnings
        )
    }

    func shotPresetPreviewJSON(_ preview: AnimatePresetPreview) -> String {
        encode(preview)
    }

    func activateRecommendedPackages(for scene: AnimationScene) -> Int {
        guard let animateURL = store.animateURL else { return 0 }

        let cast = sceneCharacters(for: scene)
        var activated = 0

        for character in cast {
            guard let package = packageLibrary.activePackage(
                for: character.assetFolderSlug,
                in: animateURL,
                preferredActivePackageID: store.activePackageID(for: character.owpSlug)
            ) else {
                continue
            }

            store.setActivePackage(package.id, for: character.owpSlug)
            activated += 1
        }

        return activated
    }

    func applyExecutionBundle(_ bundle: AnimateExecutionBundle) -> Int {
        var applied = 0

        for action in bundle.actions {
            switch action.kind {
            case .activatePackage:
                guard let packageIDString = action.packageID,
                      let packageID = UUID(uuidString: packageIDString),
                      let packageSelectionSlug = action.packageSelectionSlug else {
                    continue
                }
                store.setActivePackage(packageID, for: packageSelectionSlug)
                applied += 1
            case .cameraDefaultShot:
                guard let raw = action.cameraShot,
                      let shot = CameraShot(rawValue: raw) else { continue }
                store.setCameraDefaultShotCue(shot, at: 0)
                applied += 1
            case .cameraShot:
                guard let raw = action.cameraShot,
                      let shot = CameraShot(rawValue: raw) else { continue }
                store.setCameraShotCue(shot, at: 0)
                applied += 1
            case .cameraFocus:
                guard let focusIDString = action.focusCharacterID,
                      let focusID = UUID(uuidString: focusIDString) else { continue }
                store.setCameraFocusCue(focusID, at: 0)
                applied += 1
            case .cameraIntent:
                guard let raw = action.shotIntent,
                      let intent = ShotIntent(rawValue: raw) else { continue }
                store.setCameraShotIntentCue(intent, at: 0)
                applied += 1
            case .cameraBeatLabel:
                store.setCameraBeatLabelCue(action.beatLabel, at: 0)
                applied += 1
            }
        }

        return applied
    }

    private func buildPriorityWork(
        for character: AnimationCharacter,
        summary: SceneAutomationCharacterSummary?,
        package: InstalledCharacterPackage?
    ) -> [String] {
        var items: [String] = []

        if summary?.approvedMasterSheetCount == 0 {
            items.append("choose master sheet")
        }
        if (summary?.approvedHeadPoseCount ?? 0) < 6 {
            items.append("complete 6-pose head grid")
        }
        if let summary, !summary.costumeSummaries.contains(where: { $0.approvedFullBodyPoseCount >= 6 }) {
            items.append("approve full-body costume sheet")
        }
        if (summary?.activePackageVisemeCount ?? 0) < 5 {
            items.append("expand viseme coverage")
        }
        if package == nil {
            items.append("import character package")
        } else if package?.validationReport.isValid == false {
            items.append("repair package manifest")
        }
        if items.isEmpty {
            items.append("ready for internal playback")
        }
        return items
    }

    private func sceneExecutionNeeds(
        scene: AnimationScene,
        plan: SceneAutomationPlan?,
        characterResolutions: [AnimateSceneExecutionPacket.CharacterResolution],
        objectResolutions: [AnimateSceneExecutionPacket.ObjectResolution],
        background: BackgroundPlate?
    ) -> [AnimateSceneExecutionPacket.UnresolvedNeed] {
        var needs: [AnimateSceneExecutionPacket.UnresolvedNeed] = []

        if background?.resolvedApprovedImagePath == nil {
            needs.append(.init(scope: "place", title: "Approved background plate", detail: "Choose an approved place image before expecting lighting or final scene playback to stay internal.", severity: "error"))
        }

        for character in characterResolutions {
            if character.packageName == nil {
                needs.append(.init(scope: character.name, title: "Active package missing", detail: "Import or activate a character package so the runtime has reusable rig assets.", severity: "error"))
            } else if !character.packageValid {
                needs.append(.init(scope: character.name, title: "Package validation", detail: character.validationErrors.first ?? "The active package still has validation issues.", severity: "error"))
            }

            if character.headPoseCount < 6 {
                needs.append(.init(scope: character.name, title: "Head turnaround incomplete", detail: "Complete the 6-pose head turnaround so mouth, blink, and look-at passes can remain internal.", severity: "warning"))
            }

            if character.visemeCount < 5 {
                needs.append(.init(scope: character.name, title: "Viseme coverage shallow", detail: "Dialogue/singing will be fragile until at least 5 mouth assets are available.", severity: "warning"))
            }
        }

        for object in objectResolutions where !object.hasResolvedArt {
            needs.append(.init(
                scope: object.objectName,
                title: "Object art missing",
                detail: "Assign approved art or state variants so this first-class scene object can render deterministically.",
                severity: "warning"
            ))
        }

        if let plan {
            for item in plan.checklist where item.readiness != .ready {
                needs.append(.init(
                    scope: "scene",
                    title: item.title,
                    detail: "\(item.detail) Current metric: \(item.metric).",
                    severity: item.readiness == .missing ? "error" : "warning"
                ))
            }
        }

        if let parsedPlan {
            let assetRequests = store.missingAssetRequests(for: parsedPlan)
            for request in assetRequests {
                needs.append(.init(
                    scope: request.characterName,
                    title: request.kind.rawValue,
                    detail: "\(request.reason) Target: \(request.target)",
                    severity: "warning"
                ))
            }
        }

        var seen = Set<String>()
        return needs.filter { need in
            let key = "\(need.scope)|\(need.title)|\(need.detail)"
            return seen.insert(key).inserted
        }
    }

    private func resolvedFocusCharacterID(for scene: AnimationScene) -> UUID? {
        if let focusID = store.evaluatedCameraFocusCharacterID() {
            return focusID
        }

        if let focusID = scene.directionTemplate?.focusCharacterID {
            return focusID
        }

        if let focusSlug = scene.directionTemplate?.focusCharacterSlug {
            return sceneCharacters(for: scene).first(where: { $0.owpSlug == focusSlug })?.id
        }

        return scene.characterIDs.first
    }

    private func inferredShotIntent(for scene: AnimationScene) -> ShotIntent? {
        let castCount = scene.characterIDs.count
        let shot = store.evaluatedEffectiveCameraShot() ?? scene.directionTemplate?.defaultCameraShot

        switch shot {
        case .extremeWide, .wide:
            return castCount > 2 ? .movement : .establishing
        case .medium:
            return castCount >= 2 ? .dialogue : .handoff
        case .mediumClose, .close, .extremeClose:
            return castCount >= 2 ? .dialogue : .emotional
        case .none:
            if castCount > 2 { return .movement }
            if castCount == 2 { return .dialogue }
            if castCount == 1 { return .emotional }
            return nil
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

    private func effect(
        for action: AnimateExecutionBundle.Action,
        scene: AnimationScene,
        packet: AnimateSceneExecutionPacket
    ) -> AnimateExecutionPreview.Effect? {
        switch action.kind {
        case .activatePackage:
            return packageEffect(for: action, packet: packet)
        case .cameraDefaultShot, .cameraShot, .cameraFocus, .cameraIntent, .cameraBeatLabel:
            return cueEffect(for: action, scene: scene)
        }
    }

    private func packageEffect(
        for action: AnimateExecutionBundle.Action,
        packet: AnimateSceneExecutionPacket
    ) -> AnimateExecutionPreview.Effect? {
        guard let packageIDString = action.packageID,
              let packageID = UUID(uuidString: packageIDString),
              let selectionSlug = action.packageSelectionSlug,
              let resolution = packet.characterResolutions.first(where: { $0.packageSelectionSlug == selectionSlug })
        else {
            return nil
        }

        let currentPackageID = store.activePackageID(for: selectionSlug)
        let currentPackage = currentInstalledPackage(for: resolution)
        let proposedPackage = installedPackages(for: resolution).first(where: { $0.id == packageID })
        let currentLabel = currentPackage?.manifest.displayName
        let proposedLabel = proposedPackage?.manifest.displayName ?? resolution.packageName ?? action.title

        let changeKind: AnimateExecutionPreview.Effect.ChangeKind
        let detail: String
        if currentPackageID == packageID {
            changeKind = .noChange
            detail = "\(resolution.name) already resolves to \(proposedLabel)."
        } else if currentPackageID == nil {
            changeKind = .activate
            detail = "Persist \(proposedLabel) as the first active package selection for \(resolution.name)."
        } else {
            changeKind = .switchSelection
            detail = "Switch \(resolution.name) from \(currentLabel ?? "unknown package") to \(proposedLabel)."
        }

        return AnimateExecutionPreview.Effect(
            actionKind: action.kind.rawValue,
            title: action.title,
            scope: .packageSelection,
            target: resolution.name,
            trackName: nil,
            frame: nil,
            currentValue: currentLabel,
            currentSource: currentPackageID == nil ? "no persisted selection" : "persisted active package",
            proposedValue: proposedLabel,
            changeKind: changeKind,
            detail: detail
        )
    }

    private struct CuePreviewState {
        var target: String
        var trackName: String
        var currentValue: String?
        var currentSource: String
        var proposedValue: String?
        var hasExplicitFrameZeroValue: Bool
    }

    private func cueEffect(
        for action: AnimateExecutionBundle.Action,
        scene: AnimationScene
    ) -> AnimateExecutionPreview.Effect? {
        guard let cue = cuePreviewState(for: action, scene: scene) else {
            return nil
        }

        let changeKind: AnimateExecutionPreview.Effect.ChangeKind = cue.hasExplicitFrameZeroValue ? .update : .create
        let detail = cue.hasExplicitFrameZeroValue
            ? "Update \(cue.trackName) at frame 0 from \(cue.currentValue ?? "empty") to \(cue.proposedValue ?? "empty")."
            : "Create \(cue.trackName) at frame 0 with \(cue.proposedValue ?? "empty") (\(cue.currentSource))."

        return AnimateExecutionPreview.Effect(
            actionKind: action.kind.rawValue,
            title: action.title,
            scope: .timelineCue,
            target: cue.target,
            trackName: cue.trackName,
            frame: 0,
            currentValue: cue.currentValue,
            currentSource: cue.currentSource,
            proposedValue: cue.proposedValue,
            changeKind: changeKind,
            detail: detail
        )
    }

    private func cuePreviewState(
        for action: AnimateExecutionBundle.Action,
        scene: AnimationScene
    ) -> CuePreviewState? {
        switch action.kind {
        case .cameraDefaultShot:
            let explicit = explicitExpressionValue(trackName: "camera:default-shot")
            return CuePreviewState(
                target: "Scene default framing",
                trackName: "camera:default-shot",
                currentValue: explicit ?? store.evaluatedCameraDefaultShot(at: 0)?.displayName,
                currentSource: explicit != nil ? "existing frame 0 cue" : "scene template fallback",
                proposedValue: action.cameraShot.flatMap(CameraShot.init(rawValue:))?.displayName,
                hasExplicitFrameZeroValue: explicit != nil
            )
        case .cameraShot:
            let explicit = explicitExpressionValue(trackName: "camera:shot")
            return CuePreviewState(
                target: "Opening shot",
                trackName: "camera:shot",
                currentValue: explicit,
                currentSource: explicit != nil ? "existing frame 0 cue" : "no explicit cue",
                proposedValue: action.cameraShot.flatMap(CameraShot.init(rawValue:))?.displayName,
                hasExplicitFrameZeroValue: explicit != nil
            )
        case .cameraFocus:
            let explicitSlug = explicitExpressionValue(trackName: "camera:focus")
            let currentFocusName = explicitSlug.flatMap { slug in
                store.characters.first(where: { $0.owpSlug == slug })?.name
            } ?? store.evaluatedCameraFocusCharacterID(at: 0).flatMap { id in
                sceneCharacters(for: scene).first(where: { $0.id == id })?.name
            }
            let proposedFocusName = action.focusCharacterID.flatMap(UUID.init(uuidString:)).flatMap { focusID in
                sceneCharacters(for: scene).first(where: { $0.id == focusID })?.name
            }
            return CuePreviewState(
                target: "Focused character",
                trackName: "camera:focus",
                currentValue: currentFocusName,
                currentSource: explicitSlug != nil ? "existing frame 0 cue" : "scene template fallback",
                proposedValue: proposedFocusName,
                hasExplicitFrameZeroValue: explicitSlug != nil
            )
        case .cameraIntent:
            let explicit = explicitExpressionValue(trackName: "camera:intent")
            return CuePreviewState(
                target: "Shot intent",
                trackName: "camera:intent",
                currentValue: explicit ?? store.evaluatedCameraShotIntent(at: 0)?.displayName,
                currentSource: explicit != nil ? "existing frame 0 cue" : "derived engine intent",
                proposedValue: action.shotIntent.flatMap(ShotIntent.init(rawValue:))?.displayName,
                hasExplicitFrameZeroValue: explicit != nil
            )
        case .cameraBeatLabel:
            let explicit = explicitExpressionValue(trackName: "camera:beat")
            return CuePreviewState(
                target: "Opening beat marker",
                trackName: "camera:beat",
                currentValue: explicit ?? store.evaluatedCameraBeatLabel(at: 0),
                currentSource: explicit != nil ? "existing frame 0 cue" : "no explicit cue",
                proposedValue: action.beatLabel,
                hasExplicitFrameZeroValue: explicit != nil
            )
        case .activatePackage:
            return nil
        }
    }

    private func currentInstalledPackage(
        for resolution: AnimateSceneExecutionPacket.CharacterResolution
    ) -> InstalledCharacterPackage? {
        installedPackages(for: resolution).first {
            $0.id == store.activePackageID(for: resolution.packageSelectionSlug)
        }
    }

    private func installedPackages(
        for resolution: AnimateSceneExecutionPacket.CharacterResolution
    ) -> [InstalledCharacterPackage] {
        guard let animateURL = store.animateURL else { return [] }
        return packageLibrary.installedPackages(
            for: resolution.characterSlug,
            in: animateURL,
            preferredActivePackageID: store.activePackageID(for: resolution.packageSelectionSlug)
        )
    }

    private func framingEffect(
        actionKind: String,
        title: String,
        target: String,
        trackName: String,
        frame: Int,
        currentValue: String?,
        currentSource: String,
        proposedValue: String?
    ) -> AnimateExecutionPreview.Effect {
        let changeKind = previewChangeKind(currentValue: currentValue, proposedValue: proposedValue)
        let detail = previewDetail(
            trackName: trackName,
            frame: frame,
            currentValue: currentValue,
            currentSource: currentSource,
            proposedValue: proposedValue,
            changeKind: changeKind
        )
        return AnimateExecutionPreview.Effect(
            actionKind: actionKind,
            title: title,
            scope: .timelineCue,
            target: target,
            trackName: trackName,
            frame: frame,
            currentValue: currentValue,
            currentSource: currentSource,
            proposedValue: proposedValue,
            changeKind: changeKind,
            detail: detail
        )
    }

    private func semanticEffect(
        actionKind: String,
        title: String,
        target: String,
        trackName: String,
        frame: Int,
        currentValue: String?,
        proposedValue: String?
    ) -> AnimateExecutionPreview.Effect {
        framingEffect(
            actionKind: actionKind,
            title: title,
            target: target,
            trackName: trackName,
            frame: frame,
            currentValue: currentValue,
            currentSource: currentValue == nil ? "no explicit cue" : "existing frame cue",
            proposedValue: proposedValue
        )
    }

    private func previewChangeKind(
        currentValue: String?,
        proposedValue: String?
    ) -> AnimateExecutionPreview.Effect.ChangeKind {
        let normalizedCurrent = trimmedOrNil(currentValue)
        let normalizedProposed = trimmedOrNil(proposedValue)
        if normalizedCurrent == normalizedProposed {
            return .noChange
        }
        if normalizedCurrent == nil, normalizedProposed != nil {
            return .create
        }
        if normalizedCurrent != nil, normalizedProposed == nil {
            return .clear
        }
        return .update
    }

    private func previewDetail(
        trackName: String,
        frame: Int,
        currentValue: String?,
        currentSource: String,
        proposedValue: String?,
        changeKind: AnimateExecutionPreview.Effect.ChangeKind
    ) -> String {
        switch changeKind {
        case .create:
            return "Create \(trackName) at frame \(frame) with \(proposedValue ?? "empty") (\(currentSource))."
        case .update:
            return "Update \(trackName) at frame \(frame) from \(currentValue ?? "empty") to \(proposedValue ?? "empty")."
        case .clear:
            return "Clear \(trackName) at frame \(frame); current source is \(currentSource)."
        case .activate, .switchSelection:
            return "Change \(trackName) selection."
        case .noChange:
            return "\(trackName) already matches the proposed value."
        }
    }

    private func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func explicitExpressionValue(trackName: String, frame: Int = 0) -> String? {
        guard let track = store.timelineTrack(named: trackName),
              let keyframe = track.keyframes.first(where: { $0.frame == frame && $0.kind == .expression }),
              case .expression(let name) = keyframe.value else {
            return nil
        }

        return name
    }

    private func hasExplicitExpression(trackName: String, frame: Int = 0) -> Bool {
        explicitExpressionValue(trackName: trackName, frame: frame) != nil
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
}
